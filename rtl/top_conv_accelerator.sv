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


    logic [KBANK_W-1:0] active_bank_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)         active_bank_r <= '0;
        else if (start)     active_bank_r <= cfg_kernel_sel;
    end

   
    logic [N*N*KER_W-1:0] kernel_flat;
    genvar gk;
    generate
        for (gk = 0; gk < N*N; gk++) begin : g_kernel_flatten
            assign kernel_flat[(gk+1)*KER_W-1 -: KER_W] = kernel_regs[active_bank_r][gk / N][gk % N];
        end
    endgenerate

 
    logic [CNT_W-1:0] pix_total;
    logic [CNT_W-1:0] out_total;

    assign pix_total = cfg_img_width * cfg_img_height;
    assign out_total = pix_total;

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
