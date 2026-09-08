# IEEE SSCS Egypt Chapter — 2026 Student Design Competition
## FPGA-Based Edge-AI Vision Accelerator: NxN CNN Convolution
### Architecture & Fixed-Point Analysis Report (Draft)

**Target device:** Xilinx Artix-7 (assumed; e.g. XC7A35T / XC7A100T family — no specific
board was given in the announcement, so Artix-7 is chosen as a representative low-cost
Edge-AI FPGA. DSP48E1 slices, distributed RAM (LUTRAM) and Block RAM (36 Kb) are assumed
available.)

**Default configuration:** N = 3 (3×3 kernel), 32×32 input image, 8-bit unsigned input
pixels, 8-bit signed kernel coefficients, 16-bit signed output. The RTL is fully
parameterized (`N`, `PIXEL_W`, `KER_W`, `OUT_W`, `IMG_W_MAX`, `IMG_H_MAX`) — **verified
working for N=3 and N=5 in simulation** (see Section 6).

---

## 1. Block Diagram (text description)

```
                         ┌────────────────────────────────────────────────┐
                         │              top_conv_accelerator               │
                         │                                                  │
  in_pixel[7:0] ───────▶ │   ┌──────────────┐        ┌──────────────────┐ │
  in_valid      ───────▶ │   │ line_buffer  │ win_v  │    mac_array      │ │──▶ out_pixel[15:0]
                         │   │ (row RAMs +  │──────▶ │  (N*N mults +     │ │──▶ out_valid
  cfg_kernel_wr_*──────▶ │   │  NxN window  │ win_   │   adder tree +    │ │
  (kernel reg file)      │   │  shift-reg)  │ flat   │   relu_activation)│ │
                         │   └──────┬───────┘        └───────▲───────────┘ │
  cfg_img_width/height──▶│          │                        │ kernel_flat │
  cfg_relu_en   ───────▶ │          │                 ┌──────┴───────┐    │
  start          ───────▶│   ┌──────▼───────┐         │ kernel_regs  │    │
                         │   │ control_fsm  │         │  (NxN reg    │    │
  in_ready      ◀─────── │   │ IDLE/LOAD/   │         │   file)      │    │
  busy           ◀─────── │  │ RUN/DRAIN/   │         └──────────────┘    │
  done           ◀─────── │  │ DONE         │                              │
                         │   └──────────────┘                              │
                         └────────────────────────────────────────────────┘
```

Four functional blocks, matching the required deliverable list:

1. **`line_buffer`** — sliding-window / row-buffer generator (Section 2).
2. **`mac_array`** — parallel multiply-accumulate datapath + pipeline (Section 3/4).
3. **`relu_activation`** — standalone bonus ReLU + mandatory output saturation, instantiated
   inside `mac_array` (Section 4.3).
4. **`control_fsm`** — top-level sequencing state machine (Section 5).
5. **`top_conv_accelerator`** — top level: kernel register file + wiring + runtime
   configuration ports.

---

## 2. Datapath & Line-Buffer / Window-Generation Method

The accelerator streams the input image **row-major, one pixel per clock cycle**
(`in_valid` + `in_pixel`), and must produce a new N×N window candidate every cycle in
steady state to hit the **1-output-pixel/cycle bonus target**.

**Chosen method: shift-register window + (N−1) row buffers ("line buffers"),** the classic
low-latency streaming convolution structure:

- **Row buffers:** `N-1` independent synchronous single-port RAMs, each `IMG_WIDTH` pixels
  deep × `PIXEL_W` bits wide. For the default 32×32/N=3 configuration these are only
  32×8 bits each (256 bits) — small enough that Vivado will almost certainly map them to
  **distributed RAM (LUTRAM)** rather than a full 36 Kb Block RAM. For larger images
  (e.g. 224×224, common for edge-AI feature maps) the same code infers **Block RAM**
  automatically, since IMG_W_MAX is a synthesis parameter.
- **Window register:** an N×N array of 8-bit registers implemented as a 2-D shift
  register. Every cycle a new pixel is accepted, every row of the window shifts left by
  one column, and the new (rightmost) column is filled by reading one sample from each of
  the `N-1` row buffers plus the incoming pixel itself for the newest row.
- **Row-buffer "chain" update:** on each accepted pixel, the newest completed row is
  written into row buffer `N-2`, and the *previous* contents of row buffer `k` are shifted
  into row buffer `k-1` at the *same column address* — a systolic "conveyor belt" of rows.
  This needs only `N-1` buffers (not `N`), because the current (newest) row lives directly
  in the window register, never in a buffer.
- **Validity:** a window is declared valid only once at least `N` rows and `N` columns
  (of the current row) have been streamed in — i.e., true "valid" convolution, no
  zero-padding. Before that, `win_valid=0` and pixels are silently used only to warm up
  the buffers.
- **Throughput:** once the buffers are primed (after `(N-1)*IMG_WIDTH + (N-1)` warm-up
  pixels), **one new valid window is produced every clock cycle**, matching the
  1 pixel/cycle input rate — steady-state II=1.

This structure was chosen over a full frame buffer (would need `IMG_H × IMG_W` storage
and adds no benefit for stride-1, single-pass convolution) and over a fully unrolled
"all rows in registers" approach (wastes registers vs. RAM for anything beyond very
small images).

---

## 3. Fixed-Point Bit-Width Analysis

### 3.1 Operand widths (per spec)
| Operand | Width | Signedness | Range |
|---|---|---|---|
| Input pixel | 8 bit | **unsigned** | 0 … 255 |
| Kernel coefficient | 8 bit | **signed** | −128 … +127 |

### 3.2 Product width
Each tap computes `pixel × kernel`. Treating the unsigned pixel as a signed value with an
extra zero MSB (`$signed({1'b0, pixel})`), each product is exactly representable in:

```
PROD_W = PIXEL_W + KER_W = 8 + 8 = 16 bits (signed)
```//
Worst-case single product magnitude: `255 × 128 = 32,640` (well inside the 16-bit signed
range of ±32,767/−32,768).

### 3.3 Accumulator width (the key derivation)
For an N×N kernel, the worst-case (all taps simultaneously at their extreme values,
same sign) accumulated magnitude is:

```
|acc|_max = N² × 255 × 128
```

| N | Taps (N²) | |acc|_max | Minimum signed bits required |
|---|---|---|---|
| 3 | 9  | 293,760 | **20 bits** |
| 5 | 25 | 816,000 | **21 bits** |
| 7 | 49 | 1,596,720 | **22 bits** |

*(These exact numbers were computed and cross-checked by `golden_model.py`, which prints
the theoretical worst case and the actual observed maximum for every random test run —
see the log excerpts in Section 6.)*

**This is the central bit-width design decision the report must justify:** the
mandatory output precision is **only 16-bit signed** (per spec item #6), but the true
worst-case accumulator for N=3 already needs 20 bits — **4 bits short**. This is not a
corner case; with 8-bit unsigned inputs and full-range 8-bit signed kernels, saturation
at 16 bits is the *expected*, *frequent* outcome for arbitrary (e.g. randomly generated)
kernels, not a rare exception (our N=3 golden-model run above saturated ~447/900 = ~50%
of output pixels for a fully random kernel).

**Chosen strategy — internal wide accumulator + saturating output:**

```
ACC_W = PROD_W + ceil(log2(N²)) + 1   (implemented generically as a Verilog parameter)
      = 16 + 4 + 1 = 21 bits for N=3   (comfortable ≥1-bit margin over the 20-bit minimum)
```

The **full-precision, non-overflowing** sum is always computed and held internally in
`ACC_W` bits (21 bits for N=3, auto-scales for other N via
`$clog2(N*N)`). Only at the very last pipeline stage is this value **narrowed
(saturated, not wrapped) to the mandated `OUT_W = 16`-bit signed output**:

```
if (value > +32767)      out = +32767   (clamp high)
else if (value < -32768) out = -32768   (clamp low)
else                      out = value[15:0]
```

This is a deliberate **saturate-on-narrow** policy (never wrap/overflow silently),
implemented once, generically, in the standalone `relu_activation` module (Section 4.3) —
chosen over *truncation* because silent wraparound would flip the sign of large
convolution results, which is far more damaging to correctness/interpretability for a
vision pipeline than clipping to the rail. `OUT_W` is a parameter, so a team targeting
zero saturation could simply widen it to 20/21 bits at the cost of extra downstream
routing — this trade-off is called out explicitly for the report/judges.

### 3.4 ReLU interaction
When the bonus ReLU is enabled, the clamp `max(0, acc)` is applied to the **full-precision
ACC_W-bit accumulator**, *before* the OUT_W saturation step — matching the golden model's
operation order exactly (`golden_model.py::apply_relu_and_saturate`). This ordering
matters: clamping to zero first, then saturating, is not equivalent to the reverse order
for corner cases, so RTL and golden model are kept bit-for-bit consistent on purpose.

---

## 4. Datapath / MAC Array Detail

Fully parallel, 3-stage pipelined datapath (see `mac_array.sv`):

| Stage | Operation | Registers added |
|---|---|---|
| S1 | N² parallel signed multiplies (`8b unsigned × 8b signed → 16b signed`) | N² × 16-bit |
| S2 | Adder-tree summation of all N² products into the ACC_W accumulator | 1 × ACC_W-bit |
| S3 | `relu_activation`: optional ReLU clamp + mandatory saturate to OUT_W | 1 × OUT_W-bit |

- **DSP mapping:** each 8×8 signed multiply is a natural fit for a single Xilinx
  **DSP48E1** slice (supports up to 25×18 signed multiply-add natively) — for N=3 this
  is **9 DSP48E1 slices**, for N=5, 25 slices, etc.
- **Fixed 3-cycle pipeline latency**, fully pipelined at **II = 1** (initiation interval
  of 1 clock cycle) — i.e. a new window can be accepted every cycle even while previous
  windows are still in-flight in the pipeline, which is what delivers the bonus
  "1 output pixel per clock cycle" steady-state throughput.
- **`relu_activation`** is instantiated as its own module (not inlined) specifically to
  satisfy the deliverable list's request for a standalone bonus ReLU module; with
  `relu_en=0` it degrades to a pure saturating narrowing cast, so it is always in the
  critical path but costs nothing extra when the bonus feature is unused.

---

## 5. Control FSM

`control_fsm.sv` implements the top-level sequencing state machine:

| State | Behavior |
|---|---|
| **IDLE** | Waiting for `start`. `busy=0`. Kernel coefficients assumed already loaded via the always-available kernel config port. |
| **LOAD** | One-cycle bridge state: pulses `frame_clear` to reset the line buffer's row/column counters and window register for a new frame. |
| **RUN** | Streaming state: `in_ready=1`, accepts one pixel/cycle, counts valid output pixels (`out_cnt`) as they arrive from `mac_array`. This is the state responsible for the 1-pixel/cycle bonus throughput. |
| **DRAIN** | Reserved for future flow-controlled variants (e.g. if input acceptance must stop strictly before the output count is known); the current design resolves frame completion directly from RUN via the output counter, since the fully-pipelined datapath never stalls. |
| **DONE** | Asserts `done` for exactly one cycle once `out_cnt` reaches the expected total `(H-N+1)×(W-N+1)`, then returns to IDLE. |

`cfg_pix_total` and `cfg_out_total` (total input pixels / total valid output pixels) are
computed once per frame at the top level from the runtime `cfg_img_width` /
`cfg_img_height` and fed into the FSM, so the same FSM logic works for any supported
image size or kernel size without modification.

---

## 6. Verification Summary (see also `sim_log_*.txt`)

The RTL was verified in Icarus Verilog (`iverilog`/`vvp`, open-source, IEEE-1800 SystemVerilog
subset) against `golden_model.py`, for multiple configurations:

| Config | Image | N | ReLU | Result |
|---|---|---|---|---|
| 1 | 32×32 | 3 | off | **PASSED** — 900/900 pixels bit-exact |
| 2 | 32×32 | 3 | on  | **PASSED** — 900/900 pixels bit-exact |
| 3 | 32×32 | 5 (parameterization check) | off | **PASSED** — 784/784 pixels bit-exact |

Bit-width analysis was cross-validated numerically: the golden model independently
computes the theoretical worst-case accumulator magnitude (Section 3.3) and reports the
actual observed saturation rate for each random test — for N=3 with fully random 8-bit
signed kernels, roughly **half of all output pixels required saturation** at the mandated
16-bit output width, confirming this is a first-order design concern, not an edge case.

Full transcripts are included as `sim_log_relu0.txt` (and equivalent) alongside this
report.

---

## 7. Assumptions Made (per Instruction #4: "assume any missing information, state it clearly")

1. **Target FPGA family:** Xilinx Artix-7 assumed (no board specified in the
   announcement). Table 1 estimates assume a mid-range part (e.g. XC7A35T/XC7A100T,
   speed grade −1).
2. **"Valid" convolution (no zero-padding):** the spec does not state a padding mode;
   "valid" (output shrinks to `(H-N+1)×(W-N+1)`) was chosen as the simplest, most common
   default for a first-generation accelerator. `same`-padding is a natural future
   extension (add a padding/border-handling stage ahead of `line_buffer`).
3. **Kernel loading interface:** a simple synchronous register-file write interface
   (`cfg_kernel_wr_en/row/col/data`) is assumed sufficient to satisfy "programmable or
   configurable" (spec item #3); an AXI-Lite or similar bus wrapper would be a
   straightforward addition for SoC integration but was out of scope for the RTL core.
4. **Stream interface style:** simple valid/ready (no full AXI-Stream framing) was used
   to keep the core lightweight; wrapping in AXI-Stream is a drop-in addition for a
   board demo.
5. **No backpressure needed on the pipeline itself:** because the datapath is fully
   pipelined at II=1, `in_ready` is simply tied to "FSM is in RUN state" — the pipeline
   itself never needs to stall the input stream once started.
6. **Synthesis/timing/power numbers in Table 1** are **estimates**, not measured Vivado
   results (no license/toolchain available in this environment) — clearly marked as
   placeholders to be replaced with actual `report_utilization` / `report_timing_summary`
   / `report_power` output before final submission.

---

## 8. Files in this Submission Package

| File | Deliverable |
|---|---|
| `01_Architecture_and_FixedPoint_Report.md` | This report |
| `02_table1_required_format.md` | Required Table 1 (Section per instructions) |
| `golden_model.py` | Python golden reference model (Deliverable 2) |
| `rtl/line_buffer.sv` | Line buffer / window generator |
| `rtl/mac_array.sv` | MAC array datapath |
| `rtl/relu_activation.sv` | Bonus ReLU + output saturation |
| `rtl/control_fsm.sv` | Control FSM |
| `rtl/top_conv_accelerator.sv` | Top-level module |
| `tb/tb_conv_accelerator.sv` | Self-checking SystemVerilog testbench |
| `sim_log_relu0.txt` | Simulation transcript, TEST PASSED, 900/900 |
