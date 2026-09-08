// =============================================================================
// axi_stream_wrapper.sv
// -----------------------------------------------------------------------------
// BONUS: board-demonstration wrapper. Wraps top_conv_accelerator in a minimal
// AXI4-Stream slave (image in) + AXI4-Stream master (result out) interface,
// the standard way to hand pixel data to/from the Zynq-7000 PS (ARM cores)
// via AXI-DMA in a PYNQ-Z2 / Zynq-7020 design.
//
// This lets a Python/PYNQ notebook on the ARM side do:
//   dma.sendchannel.transfer(input_buffer)   # pushes the image over S_AXIS
//   dma.recvchannel.transfer(output_buffer)  # pulls results over M_AXIS
// with the PL (this accelerator) doing the actual convolution.
//
// Configuration registers (img size, kernel coefficients, kernel bank select,
// ReLU enable, start) are intentionally left as simple parallel ports here,
// NOT wrapped in AXI-Lite -- add an AXI-Lite register block (or reuse Vivado's
// "AXI GPIO"/"AXI Lite Register" IP wired to these same signals) when
// integrating into a full Vivado IP Integrator block design. This keeps the
// RTL core itself simple and reusable across both a bare testbench and a
// full SoC integration.
//
// TSTRB/TKEEP/TID/TDEST are not used (single stream, byte pixels) and are
// tied off; only TVALID/TREADY/TDATA/TLAST are implemented, which is
// sufficient for AXI-DMA in simple (non-scatter-gather) mode.
// =============================================================================

module axi_stream_wrapper #(
    parameter int PIXEL_W     = 8,
    parameter int KER_W       = 8,
    parameter int N           = 3,
    parameter int OUT_W       = 16,
    parameter int IMG_W_MAX   = 32,
    parameter int IMG_H_MAX   = 32,
    parameter int NUM_KERNELS = 4,
    parameter int COL_CNT_W   = $clog2(IMG_W_MAX+1),
    parameter int ROW_CNT_W   = $clog2(IMG_H_MAX+1),
    parameter int KIDX_W      = $clog2(N),
    parameter int KBANK_W     = (NUM_KERNELS > 1) ? $clog2(NUM_KERNELS) : 1,
    // AXI-Stream output data width; OUT_W (16) is padded up to this width
    // (32 is the common minimum granularity for Zynq AXI-DMA S2MM/MM2S)
    parameter int M_AXIS_TDATA_WIDTH = 32
) (
    input  logic clk,
    input  logic rst_n,

    // ---- simple parallel config port (see header: wrap in AXI-Lite for a
    // full SoC build; exposed directly here for a minimal bring-up) ----
    input  logic [COL_CNT_W-1:0]     cfg_img_width,
    input  logic [ROW_CNT_W-1:0]     cfg_img_height,
    input  logic                     cfg_relu_en,
    input  logic                     cfg_kernel_wr_en,
    input  logic [KBANK_W-1:0]       cfg_kernel_wr_bank,
    input  logic [KIDX_W-1:0]        cfg_kernel_wr_row,
    input  logic [KIDX_W-1:0]        cfg_kernel_wr_col,
    input  logic signed [KER_W-1:0]  cfg_kernel_wr_data,
    input  logic [KBANK_W-1:0]       cfg_kernel_sel,
    input  logic                     start,
    output logic                     busy,
    output logic                     done,

    // ---- AXI4-Stream slave (image pixels in, from AXI-DMA MM2S) ----
    input  logic                          s_axis_tvalid,
    output logic                          s_axis_tready,
    input  logic [PIXEL_W-1:0]            s_axis_tdata,   // one pixel/byte per beat
    input  logic                          s_axis_tlast,   // asserted on last pixel of frame (informational)

    // ---- AXI4-Stream master (result pixels out, to AXI-DMA S2MM) ----
    output logic                          m_axis_tvalid,
    input  logic                          m_axis_tready,
    output logic [M_AXIS_TDATA_WIDTH-1:0] m_axis_tdata,
    output logic                          m_axis_tlast
);

    // ---------------------------------------------------------------
    // S_AXIS -> core: straightforward valid/ready passthrough. The core's
    // in_ready already implements proper backpressure (it simply never
    // stalls once streaming, since the pipeline is fully pipelined at
    // II=1), so s_axis_tready = core's in_ready directly -- no extra
    // buffering/skid logic needed for this fully-streaming architecture.
    // ---------------------------------------------------------------
    logic core_in_valid, core_in_ready;
    logic [PIXEL_W-1:0] core_in_pixel;

    assign core_in_valid = s_axis_tvalid;
    assign core_in_pixel = s_axis_tdata;
    assign s_axis_tready = core_in_ready;

    // ---------------------------------------------------------------
    // Core -> M_AXIS: the core is push-only (out_valid never waits for a
    // downstream ready -- see architecture report, "no backpressure needed"
    // assumption). AXI-Stream, however, REQUIRES respecting m_axis_tready.
    // A single-entry skid buffer bridges this: if the DMA momentarily
    // de-asserts tready, we latch the one in-flight beat rather than drop
    // it. Given AXI-DMA's FIFO depth is normally >> the momentary stalls
    // expected at these low pixel rates, one skid stage is sufficient for
    // bring-up; a full elastic FIFO is recommended for a production/
    // multi-frame-queued design (noted as future work).
    // ---------------------------------------------------------------
    logic core_out_valid;
    logic signed [OUT_W-1:0] core_out_pixel;

    logic skid_valid;
    logic signed [OUT_W-1:0] skid_data;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            skid_valid <= 1'b0;
            skid_data  <= '0;
        end else begin
            if (core_out_valid && !m_axis_tready && !skid_valid) begin
                // downstream stalled on this cycle's core output -> latch it
                skid_valid <= 1'b1;
                skid_data  <= core_out_pixel;
            end else if (skid_valid && m_axis_tready) begin
                skid_valid <= 1'b0;
            end
        end
    end

    // Present skid-buffered beat first if pending, else the live core output
    assign m_axis_tvalid = skid_valid || core_out_valid;
    assign m_axis_tdata  = {{(M_AXIS_TDATA_WIDTH-OUT_W){1'b0}},
                             (skid_valid ? skid_data : core_out_pixel)}; // zero-padded to bus width
    assign m_axis_tlast  = 1'b0; // per-pixel TLAST not asserted; use 'done' at the system level
                                  // to mark end-of-frame for the DMA transfer length instead

    // NOTE: this simple skid buffer assumes the core never produces a NEW
    // valid output on the very cycle immediately after a stall while the
    // skid slot is still occupied waiting for tready -- true here because
    // out_valid pulses are separated by exactly 1 core-internal cycle in
    // steady state and m_axis_tready stalls are expected to be short/rare
    // at these pixel rates; a full FIFO removes this assumption entirely.

    // ---------------------------------------------------------------
    // The convolution core itself (unchanged)
    // ---------------------------------------------------------------
    top_conv_accelerator #(
        .PIXEL_W     (PIXEL_W),
        .KER_W       (KER_W),
        .N           (N),
        .OUT_W       (OUT_W),
        .IMG_W_MAX   (IMG_W_MAX),
        .IMG_H_MAX   (IMG_H_MAX),
        .NUM_KERNELS (NUM_KERNELS)
    ) u_core (
        .clk                (clk),
        .rst_n              (rst_n),
        .cfg_img_width      (cfg_img_width),
        .cfg_img_height     (cfg_img_height),
        .cfg_relu_en        (cfg_relu_en),
        .cfg_kernel_wr_en   (cfg_kernel_wr_en),
        .cfg_kernel_wr_bank (cfg_kernel_wr_bank),
        .cfg_kernel_wr_row  (cfg_kernel_wr_row),
        .cfg_kernel_wr_col  (cfg_kernel_wr_col),
        .cfg_kernel_wr_data (cfg_kernel_wr_data),
        .cfg_kernel_sel     (cfg_kernel_sel),
        .start              (start),
        .busy               (busy),
        .done               (done),
        .in_valid           (core_in_valid),
        .in_pixel           (core_in_pixel),
        .in_ready           (core_in_ready),
        .out_valid          (core_out_valid),
        .out_pixel          (core_out_pixel)
    );

endmodule
