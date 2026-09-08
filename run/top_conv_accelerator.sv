// =============================================================================
// top_conv_accelerator.sv
// -----------------------------------------------------------------------------
// Top-level FPGA-based Edge-AI vision accelerator: NxN CNN convolution,
// stride 1, "valid" (no zero-pad) mode, 1 output pixel/cycle steady-state
// throughput, optional ReLU activation (bonus), multi-kernel bank (bonus).
//
// Default: N=3, PIXEL_W=8 (unsigned), KER_W=8 (signed), OUT_W=16 (signed),
// but fully parameterizable up to N=IMG_W_MAX/2-ish (limited by row buffer
// depth = IMG_W_MAX and window size).
//
// BONUS -- multiple kernels: the kernel register file is a bank of
// NUM_KERNELS independent NxN kernels (default 4). Any bank can be
// (re)written at any time via cfg_kernel_wr_bank/row/col/data; the ACTIVE
// bank for a given frame is chosen via cfg_kernel_sel and is latched
// internally at the moment 'start' is pulsed (same latch pattern used for
// cfg_img_width), so a frame's kernel selection cannot change mid-stream.
// This lets a design run several different filters (e.g. Sobel-X, Sobel-Y,
// blur, sharpen) back-to-back on consecutive frames without reloading
// coefficients between frames -- useful for the edge-detection demo and for
// any application needing several fixed filters resident simultaneously.
//
// Usage sequence:
//   1. For each kernel bank you want to preload: assert cfg_kernel_wr_en for
//      N*N cycles, sweeping cfg_kernel_wr_row/col with cfg_kernel_wr_bank
//      held at the target bank index. Coefficients persist across frames
//      until rewritten (kernel is "configurable" per spec item #3).
//   2. Set cfg_img_height / cfg_img_width (<= IMG_H_MAX / IMG_W_MAX),
//      cfg_relu_en, and cfg_kernel_sel (which preloaded bank to use for the
//      NEXT frame) as desired.
//   3. Pulse 'start' for 1 cycle -- this latches cfg_img_width and
//      cfg_kernel_sel for the duration of the frame.
//   4. Stream the frame row-major, one pixel per cycle, driving in_valid=1
//      and in_pixel, whenever in_ready=1 (accelerator is always ready to
//      accept 1 pixel/cycle once started -- no backpressure needed since
//      the whole pipeline, including line buffer and MAC array, is fully
//      pipelined at II=1).
//   5. Valid output pixels appear on out_pixel/out_valid, raster-scan order
//      of the (IMG_H-N+1) x (IMG_W-N+1) output feature map, starting a
//      fixed pipeline latency after streaming begins.
//   6. 'done' pulses for 1 cycle once the last output pixel has been
//      produced. Repeat from step 2 for the next frame (optionally with a
//      different cfg_kernel_sel) -- no need to reload coefficients if the
//      desired kernel is already resident in a bank.
// =============================================================================

module top_conv_accelerator #(
    parameter int PIXEL_W     = 8,      // unsigned input pixel width
    parameter int KER_W       = 8,      // signed kernel coefficient width
    parameter int N           = 3,      // kernel dimension (configurable at synth time)
    parameter int OUT_W       = 16,     // required minimum 16-bit signed output
    parameter int IMG_W_MAX   = 32,     // max supported image width  (row buffer depth)
    parameter int IMG_H_MAX   = 32,     // max supported image height
    parameter int NUM_KERNELS = 4,      // BONUS: number of resident kernel banks
    parameter int COL_CNT_W   = $clog2(IMG_W_MAX+1),
    parameter int ROW_CNT_W   = $clog2(IMG_H_MAX+1),
    // CNT_W sized to the actual max pixel/output count for this frame geometry
    // (NOT a wasteful fixed 32 bits) -- directly reduces FF/LUT count in the
    // FSM's counters and comparators, which matters for the FoM's resource
    // term. Override explicitly if you need a very large max frame size.
    parameter int CNT_W       = $clog2(IMG_W_MAX*IMG_H_MAX+1),
    parameter int KIDX_W      = $clog2(N),
    parameter int KBANK_W     = (NUM_KERNELS > 1) ? $clog2(NUM_KERNELS) : 1
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // ---- runtime configuration ----
    input  logic [COL_CNT_W-1:0]     cfg_img_width,     // e.g. 32
    input  logic [ROW_CNT_W-1:0]     cfg_img_height,    // e.g. 32
    input  logic                     cfg_relu_en,        // bonus: 1 = enable ReLU

    // BONUS: multi-kernel bank write + select interface
    input  logic                     cfg_kernel_wr_en,
    input  logic [KBANK_W-1:0]       cfg_kernel_wr_bank,  // which bank to write
    input  logic [KIDX_W-1:0]        cfg_kernel_wr_row,
    input  logic [KIDX_W-1:0]        cfg_kernel_wr_col,
    input  logic signed [KER_W-1:0]  cfg_kernel_wr_data,
    input  logic [KBANK_W-1:0]       cfg_kernel_sel,      // active bank for NEXT frame (latched at start)

    // ---- control ----
    input  logic                     start,
    output logic                     busy,
    output logic                     done,

    // ---- pixel-streaming input (raster scan, row-major) ----
    input  logic                     in_valid,
    input  logic [PIXEL_W-1:0]       in_pixel,
    output logic                     in_ready,

    // ---- pixel-streaming output (raster scan, row-major) ----
    output logic                     out_valid,
    output logic signed [OUT_W-1:0]  out_pixel
);

    // ---------------------------------------------------------------
    // BONUS: multi-kernel bank register file (NUM_KERNELS x NxN, signed).
    // Each bank is independently writable at any time via
    // cfg_kernel_wr_bank/row/col/data; persists across frames per bank.
    // ---------------------------------------------------------------
    logic signed [KER_W-1:0] kernel_regs [NUM_KERNELS][N][N];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int b = 0; b < NUM_KERNELS; b++)
                for (int r = 0; r < N; r++)
                    for (int c = 0; c < N; c++)
                        kernel_regs[b][r][c] <= '0;
        end else if (cfg_kernel_wr_en) begin
            kernel_regs[cfg_kernel_wr_bank][cfg_kernel_wr_row][cfg_kernel_wr_col] <= cfg_kernel_wr_data;
        end
    end

    // Active bank for the CURRENT frame: latched at 'start' so a frame's
    // kernel selection is stable for its whole duration even if cfg_kernel_sel
    // changes while streaming (mirrors the cfg_img_width latch in line_buffer).
    logic [KBANK_W-1:0] active_bank_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)         active_bank_r <= '0;
        else if (start)     active_bank_r <= cfg_kernel_sel;
    end

    // Flatten kernel_regs[active_bank_r] -> kernel_flat for the mac_array
    // port boundary (see line_buffer.sv header for rationale on flattened
    // array ports).
    logic [N*N*KER_W-1:0] kernel_flat;
    genvar gk;
    generate
        for (gk = 0; gk < N*N; gk++) begin : g_kernel_flatten
            assign kernel_flat[(gk+1)*KER_W-1 -: KER_W] = kernel_regs[active_bank_r][gk / N][gk % N];
        end
    endgenerate

    // ---------------------------------------------------------------
    // Frame geometry -> total input pixel count / total valid output count
    // (combinational multiply; only recomputed continuously, cheap at this
    // size and off the critical streaming path).
    // ---------------------------------------------------------------
    logic [CNT_W-1:0] pix_total;
    logic [CNT_W-1:0] out_total;
    logic [COL_CNT_W-1:0] out_w_dim;
    logic [ROW_CNT_W-1:0] out_h_dim;

    assign out_w_dim = cfg_img_width  - (N-1);
    assign out_h_dim = cfg_img_height - (N-1);
    assign pix_total = cfg_img_width * cfg_img_height;
    assign out_total = out_w_dim * out_h_dim;

    // ---------------------------------------------------------------
    // Control FSM
    // ---------------------------------------------------------------
    logic frame_clear;
    logic fsm_in_ready;
    logic out_valid_pulse;

    control_fsm #(
        .CNT_W (CNT_W)
    ) u_fsm (
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (start),
        .cfg_pix_total    (pix_total),
        .cfg_out_total    (out_total),
        .out_valid_pulse  (out_valid_pulse),
        .frame_clear      (frame_clear),
        .in_ready         (fsm_in_ready),
        .busy             (busy),
        .done             (done)
    );

    assign in_ready = fsm_in_ready;

    // Only feed line buffer / datapath when the FSM has accepted the pixel
    logic lb_in_valid;
    assign lb_in_valid = in_valid && in_ready;

    // ---------------------------------------------------------------
    // Line buffer / window generator
    // ---------------------------------------------------------------
    logic                    win_valid;
    logic [N*N*PIXEL_W-1:0]  win_flat;

    line_buffer #(
        .PIXEL_W   (PIXEL_W),
        .N         (N),
        .IMG_W     (IMG_W_MAX),
        .COL_CNT_W (COL_CNT_W),
        .ROW_CNT_W (ROW_CNT_W)
    ) u_line_buffer (
        .clk                  (clk),
        .rst_n                (rst_n),
        .cfg_img_width_valid  (start),          // latch width at start-of-frame
        .cfg_img_width        (cfg_img_width),
        .clear                (frame_clear),
        .in_valid             (lb_in_valid),
        .in_pixel             (in_pixel),
        .win_valid            (win_valid),
        .win_flat             (win_flat)
    );

    // ---------------------------------------------------------------
    // MAC array (multiply-accumulate + ReLU + saturate)
    // ---------------------------------------------------------------
    mac_array #(
        .PIXEL_W (PIXEL_W),
        .KER_W   (KER_W),
        .N       (N),
        .OUT_W   (OUT_W)
    ) u_mac_array (
        .clk          (clk),
        .rst_n        (rst_n),
        .win_valid    (win_valid),
        .win_flat     (win_flat),
        .kernel_flat  (kernel_flat),
        .relu_en      (cfg_relu_en),
        .out_valid    (out_valid),
        .out_pixel    (out_pixel)
    );

    assign out_valid_pulse = out_valid;

endmodule
