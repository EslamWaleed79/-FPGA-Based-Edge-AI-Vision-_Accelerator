# Table 1. Required Table Format
### (as specified in the competition announcement, Section "Deliverables")

Target/design values shown below are for the **default configuration**: N=3 (3×3 kernel),
32×32 input image, 8-bit unsigned input, 8-bit signed kernel, 16-bit signed output,
targeting a **Xilinx Artix-7** device (assumed — no board specified in the announcement).

Functional-correctness rows (Input image size, Input/Kernel precision, Architecture type,
Multipliers/MACs, Pipeline stages, Latency, Throughput, Verification status) are backed by
RTL simulation (Section 6 of the architecture report). FPGA-implementation rows (utilization,
max frequency, power, FOM) are **placeholder estimates** — no Vivado license/toolchain was
available in this environment — and are clearly marked for replacement with actual
`report_utilization` / `report_timing_summary` / `report_power` numbers before final
submission.

| Parameter | Specification | Team Result (target) | Units | Comments |
|---|---|---|---|---|
| Input image size | ≥ 32×32, grayscale/single-channel | 32×32 (parameterizable up to `IMG_W_MAX`×`IMG_H_MAX`) | pixels | Verified in sim at 32×32 |
| Input precision | Fixed-point unsigned | 8-bit unsigned | bits | 0…255 range; justified in Report §3.1 |
| Kernel precision | 8-bit signed fixed-point/integer | 8-bit signed | bits | −128…+127 range; programmable via `cfg_kernel_wr_*` |
| Architecture type | — | Fully-pipelined parallel MAC array + shift-register/row-buffer line buffer (streaming, "valid" conv) | — | See Report §1–§4 |
| Multipliers / MACs | — | 9 (N²=3²) parallel signed multipliers | count | 1 DSP48E1 per multiplier (Artix-7) |
| Pipeline stages | — | 3 (multiply → adder-tree → ReLU/saturate) + line-buffer fill latency | stages | II = 1 (fully pipelined) |
| Latency | — | ≈ (N−1)·IMG_W + N + 3 ≈ **70** (for 32×32, N=3) | clock cycles | Cycles from `start` to first valid output pixel |
| Throughput | 1 output pixel/cycle (bonus target) | **1** | pixels/cycle | Steady-state, verified in sim (900/900 back-to-back outputs) |
| FPGA utilization — LUTs | — | ~900 *(estimate)* | LUTs | **[TO BE UPDATED WITH ACTUAL VIVADO/QUARTUS SYNTHESIS REPORT]** |
| FPGA utilization — FFs | — | ~350 *(estimate)* | FFs | **[TO BE UPDATED WITH ACTUAL VIVADO/QUARTUS SYNTHESIS REPORT]** |
| FPGA utilization — DSPs | — | 9 | DSP48E1 slices | One per 8×8 multiplier; exact count, not an estimate |
| FPGA utilization — BRAMs | — | 0 *(estimate — likely LUTRAM at 32-wide rows)* | 36Kb BRAM | **[TO BE UPDATED WITH ACTUAL VIVADO/QUARTUS SYNTHESIS REPORT]**; scales to real BRAM usage for wider images |
| Maximum frequency | — | ~150 *(estimate)* | MHz | **[TO BE UPDATED WITH ACTUAL VIVADO/QUARTUS SYNTHESIS REPORT]**; Artix-7 −1 speed grade assumption |
| Power estimate | — | ~0.15 *(estimate)* | W | **[TO BE UPDATED WITH ACTUAL VIVADO/QUARTUS SYNTHESIS REPORT]**; dynamic power only, XPE/Vivado power report needed |
| Verification status | — | **PASSED** — 900/900 output pixels bit-exact vs. Python golden model (N=3, with and without ReLU); 784/784 for N=5 parameterization check | — | See `sim_log_relu0.txt` |
| FOM = Throughput / (Power × (LUTs + 50·DSPs + 100·BRAMs)) | — | ≈ **0.00494** *(estimate, from placeholder utilization/power above)* | pixels/cycle/W/resource-unit | Recompute once actual synthesis numbers are available |

**Note on placeholders:** every row flagged `[TO BE UPDATED WITH ACTUAL VIVADO/QUARTUS
SYNTHESIS REPORT]` is a rough, order-of-magnitude engineering estimate based on the known
resource cost of 9× 8-bit DSP-mapped multiplies, a shallow 3-stage pipeline, and a small
(32-deep) LUTRAM-based line buffer — it is **not** a substitute for running synthesis and
implementation and must be replaced with real tool output before submission, per the
competition's judging criteria (FPGA resource usage, timing closure, power estimate).
