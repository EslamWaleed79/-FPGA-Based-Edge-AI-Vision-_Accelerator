module axi_stream_wrapper #(
    parameter int PIXEL_W      = 8,
    parameter int KER_W        = 8,
    parameter int N            = 3,
    parameter int OUT_W        = 16,
    parameter int IMG_W_MAX    = 32,
    parameter int IMG_H_MAX    = 32,
    parameter int NUM_KERNELS  = 4,

    parameter int COL_CNT_W    = $clog2(IMG_W_MAX + 1),
    parameter int ROW_CNT_W    = $clog2(IMG_H_MAX + 1),
    parameter int KIDX_W       = $clog2(N),
    parameter int KBANK_W      = (NUM_KERNELS > 1) ? $clog2(NUM_KERNELS) : 1,

    parameter int M_AXIS_TDATA_WIDTH = 32,
    parameter int S_AXIS_TDATA_WIDTH = 32
) (
    input  logic clk,
    input  logic rst_n,

    // ------------------------------------------------------------
    // Accelerator configuration
    // ------------------------------------------------------------
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

    // ------------------------------------------------------------
    // AXI4-Stream input (DMA MM2S)
    // 32-bit AXI beat, lower PIXEL_W bits contain the pixel
    // ------------------------------------------------------------
    input  logic                          s_axis_tvalid,
    output logic                          s_axis_tready,
    input  logic [S_AXIS_TDATA_WIDTH-1:0] s_axis_tdata,
    input  logic                          s_axis_tlast,

    // ------------------------------------------------------------
    // AXI4-Stream output (DMA S2MM)
    // ------------------------------------------------------------
    output logic                           m_axis_tvalid,
    input  logic                           m_axis_tready,
    output logic [M_AXIS_TDATA_WIDTH-1:0]  m_axis_tdata,
    output logic                           m_axis_tlast
);

    // ============================================================
    // GPIO CONTROL CDC
    // ============================================================

    (* ASYNC_REG = "TRUE" *)
    logic [COL_CNT_W-1:0] cfg_img_width_meta;
    (* ASYNC_REG = "TRUE" *)
    logic [COL_CNT_W-1:0] cfg_img_width_sync;

    (* ASYNC_REG = "TRUE" *)
    logic [ROW_CNT_W-1:0] cfg_img_height_meta;
    (* ASYNC_REG = "TRUE" *)
    logic [ROW_CNT_W-1:0] cfg_img_height_sync;

    (* ASYNC_REG = "TRUE" *)
    logic cfg_relu_en_meta;
    (* ASYNC_REG = "TRUE" *)
    logic cfg_relu_en_sync;

    (* ASYNC_REG = "TRUE" *)
    logic start_meta;
    (* ASYNC_REG = "TRUE" *)
    logic start_sync;

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
        end
        else begin
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

    // ============================================================
    // START RISING-EDGE DETECTOR
    // ============================================================

    logic start_sync_d;
    logic start_rise;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_sync_d <= 1'b0;
        end
        else begin
            start_sync_d <= start_sync;
        end
    end

    assign start_rise = start_sync && !start_sync_d;

    // ============================================================
    // AXI INPUT -> CORE
    // ============================================================

    logic                   core_in_valid;
    logic                   core_in_ready;
    logic [PIXEL_W-1:0]     core_in_pixel;

    assign core_in_valid = s_axis_tvalid;

    // Current hardware contract:
    // AXI DMA sends 32-bit words.
    // One 8-bit pixel occupies the lower 8 bits.
    assign core_in_pixel = s_axis_tdata[PIXEL_W-1:0];

    // Accelerator controls whether another input beat can be accepted.
    assign s_axis_tready = core_in_ready;

    // Input TLAST is intentionally not used.
    // The MM2S DMA transfer length defines the input frame size.
    logic unused_s_axis_tlast;
    assign unused_s_axis_tlast = s_axis_tlast;

    // ============================================================
    // CORE OUTPUT
    // ============================================================

    logic                    core_out_valid;
    logic signed [OUT_W-1:0] core_out_pixel;

    // ============================================================
    // OUTPUT FIFO
    //
    // The accelerator has no out_ready/backpressure signal.
    // Therefore a FIFO is used to absorb temporary DMA stalls.
    // ============================================================

    localparam int FIFO_DEPTH = 32;
    localparam int FIFO_ADDR_W = $clog2(FIFO_DEPTH);
    localparam int FIFO_PTR_W  = FIFO_ADDR_W + 1;

    logic signed [OUT_W-1:0] fifo_mem [0:FIFO_DEPTH-1];

    logic [FIFO_PTR_W-1:0] fifo_wr_ptr;
    logic [FIFO_PTR_W-1:0] fifo_rd_ptr;

    logic                   fifo_full;
    logic                   fifo_empty;

    logic signed [OUT_W-1:0] fifo_dout;

    logic fifo_wr_en;
    logic fifo_rd_en;

    // ------------------------------------------------------------
    // FIFO status
    // ------------------------------------------------------------

    assign fifo_empty = (fifo_wr_ptr == fifo_rd_ptr);

    assign fifo_full =
        (fifo_wr_ptr[FIFO_PTR_W-1] != fifo_rd_ptr[FIFO_PTR_W-1]) &&
        (fifo_wr_ptr[FIFO_ADDR_W-1:0] ==
         fifo_rd_ptr[FIFO_ADDR_W-1:0]);

    // ------------------------------------------------------------
    // AXI output handshake
    //
    // FIFO data remains stable while tvalid=1 and tready=0.
    // ------------------------------------------------------------

    assign m_axis_tvalid = !fifo_empty;

    assign fifo_rd_en =
        m_axis_tvalid && m_axis_tready;

    // Allow simultaneous read/write when FIFO is full.
    assign fifo_wr_en =
        core_out_valid && (!fifo_full || fifo_rd_en);

    // ------------------------------------------------------------
    // FIFO storage and pointers
    // ------------------------------------------------------------

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr_ptr <= '0;
            fifo_rd_ptr <= '0;
        end
        else begin

            if (fifo_wr_en) begin
                fifo_mem[fifo_wr_ptr[FIFO_ADDR_W-1:0]]
                    <= core_out_pixel;

                fifo_wr_ptr <= fifo_wr_ptr + 1'b1;
            end

            if (fifo_rd_en) begin
                fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
            end
        end
    end

    // Asynchronous read from register-array FIFO.
    // Data is stable as long as fifo_rd_ptr does not advance.
    assign fifo_dout =
        fifo_mem[fifo_rd_ptr[FIFO_ADDR_W-1:0]];

    // ============================================================
    // OUTPUT DATA WIDTH / SIGN EXTENSION
    //
    // Core output is signed OUT_W bits.
    // AXI output is M_AXIS_TDATA_WIDTH bits.
    // ============================================================

    assign m_axis_tdata =
        {{(M_AXIS_TDATA_WIDTH-OUT_W){fifo_dout[OUT_W-1]}},
         fifo_dout};

    // ============================================================
    // FRAME-LATCHED OUTPUT COUNT
    // ============================================================

    logic [31:0] total_out_pixels_latched;
    logic [31:0] out_pixel_cnt;

    // Capture width * height once per frame.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_out_pixels_latched <= 32'd0;
        end
        else if (start_rise) begin
            total_out_pixels_latched <=
                {16'd0, cfg_img_width_sync} *
                {16'd0, cfg_img_height_sync};
        end
    end

    // Count accepted output AXI beats.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_pixel_cnt <= 32'd0;
        end
        else if (start_rise) begin
            out_pixel_cnt <= 32'd0;
        end
        else if (fifo_rd_en) begin

            if (out_pixel_cnt >=
                (total_out_pixels_latched - 32'd1)) begin

                out_pixel_cnt <= 32'd0;

            end
            else begin
                out_pixel_cnt <= out_pixel_cnt + 32'd1;
            end
        end
    end

    // ------------------------------------------------------------
    // TLAST
    //
    // Assert TLAST only on the final ACCEPTED output beat.
    // ------------------------------------------------------------

    assign m_axis_tlast =
        m_axis_tvalid &&
        m_axis_tready &&
        (total_out_pixels_latched > 32'd0) &&
        (out_pixel_cnt ==
         (total_out_pixels_latched - 32'd1));

    // ============================================================
    // CONVOLUTION ACCELERATOR
    // ============================================================

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

        .cfg_img_width      (cfg_img_width_sync),
        .cfg_img_height     (cfg_img_height_sync),
        .cfg_relu_en        (cfg_relu_en_sync),

        .cfg_kernel_wr_en   (cfg_kernel_wr_en),
        .cfg_kernel_wr_bank (cfg_kernel_wr_bank),
        .cfg_kernel_wr_row  (cfg_kernel_wr_row),
        .cfg_kernel_wr_col  (cfg_kernel_wr_col),
        .cfg_kernel_wr_data (cfg_kernel_wr_data),

        .cfg_kernel_sel     (cfg_kernel_sel),

        .start              (start_sync),

        .busy               (busy),
        .done               (done),

        .in_valid           (core_in_valid),
        .in_pixel           (core_in_pixel),
        .in_ready           (core_in_ready),

        .out_valid          (core_out_valid),
        .out_pixel          (core_out_pixel)
    );

endmodule
