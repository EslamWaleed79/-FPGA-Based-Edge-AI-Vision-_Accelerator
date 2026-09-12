module axi_stream_wrapper #(
    parameter int PIXEL_W      = 8,
    parameter int KER_W        = 8,
    parameter int N            = 3,
    parameter int OUT_W        = 16,
    parameter int IMG_W_MAX    = 32,
    parameter int IMG_H_MAX    = 32,
    parameter int NUM_KERNELS = 4,
    parameter int COL_CNT_W    = $clog2(IMG_W_MAX+1),
    parameter int ROW_CNT_W    = $clog2(IMG_H_MAX+1),
    parameter int KIDX_W       = $clog2(N),
    parameter int KBANK_W      = (NUM_KERNELS > 1) ? $clog2(NUM_KERNELS) : 1,
    parameter int M_AXIS_TDATA_WIDTH = 32,
    parameter int S_AXIS_TDATA_WIDTH = 32
) (
    input  logic clk,
    input  logic rst_n,

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

    input  logic                          s_axis_tvalid,
    output logic                          s_axis_tready,
    input  logic [S_AXIS_TDATA_WIDTH-1:0] s_axis_tdata,   // 32-bit beat from AXI-DMA
    input  logic                          s_axis_tlast,

    output logic                          m_axis_tvalid,
    input  logic                          m_axis_tready,
    output logic [M_AXIS_TDATA_WIDTH-1:0] m_axis_tdata,
    output logic                          m_axis_tlast
);

    // Asynchronous CDC Synchronization for GPIO-driven control inputs
    (* ASYNC_REG = "TRUE" *) logic [COL_CNT_W-1:0] cfg_img_width_meta, cfg_img_width_sync;
    (* ASYNC_REG = "TRUE" *) logic [ROW_CNT_W-1:0] cfg_img_height_meta, cfg_img_height_sync;
    (* ASYNC_REG = "TRUE" *) logic cfg_relu_en_meta, cfg_relu_en_sync;
    (* ASYNC_REG = "TRUE" *) logic start_meta, start_sync;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_img_width_meta  <= '0;
            cfg_img_width_sync  <= '0;
            cfg_img_height_meta <= '0;
            cfg_img_height_sync <= '0;
            cfg_relu_en_meta    <= 1'b0;
            cfg_relu_en_sync    <= 1'b0;
            start_meta          <= 1'b0;
            start_sync          <= 1'b0;
        end else begin
            cfg_img_width_meta  <= cfg_img_width;
            cfg_img_width_sync  <= cfg_img_width_meta;

            cfg_img_height_meta <= cfg_img_height;
            cfg_img_height_sync <= cfg_img_height_meta;

            cfg_relu_en_meta    <= cfg_relu_en;
            cfg_relu_en_sync    <= cfg_relu_en_meta;

            start_meta          <= start;
            start_sync          <= start_meta;
        end
    end

    logic core_in_valid, core_in_ready;
    logic [PIXEL_W-1:0] core_in_pixel;

    assign core_in_valid = s_axis_tvalid;
    assign core_in_pixel = s_axis_tdata[PIXEL_W-1:0]; // Extract lower pixel byte
    assign s_axis_tready = core_in_ready;

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
                skid_valid <= 1'b1;
                skid_data  <= core_out_pixel;
            end else if (skid_valid && m_axis_tready) begin
                skid_valid <= 1'b0;
            end
        end
    end

    assign m_axis_tvalid = skid_valid || core_out_valid;
    assign m_axis_tdata  = {{(M_AXIS_TDATA_WIDTH-OUT_W){1'b0}},
                            (skid_valid ? skid_data : core_out_pixel)};
    assign m_axis_tlast  = 1'b0;

    top_conv_accelerator #(
        .PIXEL_W     (PIXEL_W),
        .KER_W       (KER_W),
        .N           (N),
        .OUT_W       (OUT_W),
        .IMG_W_MAX   (IMG_W_MAX),
        .IMG_H_MAX   (IMG_H_MAX),
        .NUM_KERNELS (NUM_KERNELS)
    ) u_core (
        .clk                 (clk),
        .rst_n               (rst_n),
        .cfg_img_width       (cfg_img_width_sync),       // Connected to synchronized signal
        .cfg_img_height      (cfg_img_height_sync),      // Connected to synchronized signal
        .cfg_relu_en         (cfg_relu_en_sync),         // Connected to synchronized signal
        .cfg_kernel_wr_en    (cfg_kernel_wr_en),
        .cfg_kernel_wr_bank  (cfg_kernel_wr_bank),
        .cfg_kernel_wr_row   (cfg_kernel_wr_row),
        .cfg_kernel_wr_col   (cfg_kernel_wr_col),
        .cfg_kernel_wr_data  (cfg_kernel_wr_data),
        .cfg_kernel_sel      (cfg_kernel_sel),
        .start               (start_sync),               // Connected to synchronized signal
        .busy                (busy),
        .done                (done),
        .in_valid            (core_in_valid),
        .in_pixel            (core_in_pixel),
        .in_ready            (core_in_ready),
        .out_valid           (core_out_valid),
        .out_pixel           (core_out_pixel)
    );

endmodule