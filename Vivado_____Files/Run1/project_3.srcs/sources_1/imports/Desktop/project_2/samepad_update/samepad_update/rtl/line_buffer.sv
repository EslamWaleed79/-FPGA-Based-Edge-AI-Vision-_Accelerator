// =============================================================================
// line_buffer.sv
// -----------------------------------------------------------------------------
// Sliding-window generator for an N x N convolution accelerator.
//
// Architecture:
//   - (N-1) "row buffers" implemented as simple synchronous single-port RAMs
//     (infers Xilinx Block RAM / distributed RAM depending on IMG_WIDTH).
//     Each row buffer holds one full row of the image (IMG_WIDTH pixels).
//   - A small NxN register array ("window") built from shift registers holds
//     the current convolution window. Every clock cycle that a new pixel is
//     accepted, ALL columns of the window shift left by one and the new
//     column (built from the incoming pixel + the N-1 row-buffer read data)
//     is inserted on the right.
//   - This structure needs only N-1 row buffers (not N), because the "newest"
//     row lives directly in the window register, not in a buffer.
//   - Steady-state throughput: 1 pixel accepted / 1 window candidate produced
//     per clock cycle (the "1 output pixel per cycle" bonus target), once the
//     pipeline has filled.
//
// NOTE ON PORT STYLE: the NxN window is exposed as a FLATTENED packed vector
// (win_flat) rather than a 2D unpacked array port. Multi-dimensional unpacked
// array ports have inconsistent support across simulators/synthesis tools;
// flattening is the portable, synthesis-safe convention used throughout this
// design. Bit [ (r*N+c+1)*PIXEL_W-1 : (r*N+c)*PIXEL_W ] = win[r][c].
//
// Window validity:
//   Because top and left edges are padded with zeros, every accepted pixel
//   yields a valid convolution window. win_valid simply follows in_valid_d.
// =============================================================================

module line_buffer #(
    parameter int PIXEL_W  = 8,     // input pixel width (unsigned)
    parameter int N        = 3,     // kernel size (NxN window)
    parameter int IMG_W    = 32,    // image width in pixels (max supported)
    parameter int COL_CNT_W = $clog2(IMG_W+1),
    parameter int ROW_CNT_W = 16
) (
    input  logic                                  clk,
    input  logic                                  rst_n,

    input  logic                                  cfg_img_width_valid, // pulse: latch img_width below
    input  logic [COL_CNT_W-1:0]                  cfg_img_width,       // runtime image width (<= IMG_W)

    input  logic                                  clear,     // synchronous clear (new frame)
    input  logic                                  in_valid,  // new pixel presented
    input  logic [PIXEL_W-1:0]                    in_pixel,  // raster-scan pixel-in (row-major)

    output logic                                  win_valid,           // win_flat holds a valid NxN window
    output logic [N*N*PIXEL_W-1:0]                win_flat             // flattened NxN window, row-major
);

    // ---------------------------------------------------------------------
    // Runtime image width register (kept <= IMG_W, the max the row buffers
    // were sized for). Parameterizable at synthesis via IMG_W; the actual
    // frame width can be set at runtime for smaller frames.
    // ---------------------------------------------------------------------
    logic [COL_CNT_W-1:0] img_width_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                      img_width_r <= IMG_W[COL_CNT_W-1:0];
        else if (cfg_img_width_valid)    img_width_r <= cfg_img_width;
    end

    // ---------------------------------------------------------------------
    // Row buffers: N-1 independent single-port synchronous RAMs.
    // row_buf[k] holds the row that is (N-1-k) rows "above" the row
    // currently being streamed in.
    // ---------------------------------------------------------------------
    (* ram_style = "distributed" *)
    logic [PIXEL_W-1:0] row_ram [N-1][IMG_W];
    logic [COL_CNT_W-1:0] wr_col;      // current column index within the row
    logic [ROW_CNT_W-1:0] wr_row;      // current row index (only compared >= N-1)

    logic [PIXEL_W-1:0] row_rd [N-1];
    genvar gi;
    generate
        for (gi = 0; gi < N-1; gi++) begin : g_row_rd
            assign row_rd[gi] = row_ram[gi][wr_col];
        end
    endgenerate

    // ---------------------------------------------------------------------
    // Column / row counters
    // ---------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_col <= '0;
            wr_row <= '0;
        end else if (clear) begin
            wr_col <= '0;
            wr_row <= '0;
        end else if (in_valid) begin
            if (wr_col == img_width_r - 1) begin
                wr_col <= '0;
                wr_row <= wr_row + 1'b1;
            end else begin
                wr_col <= wr_col + 1'b1;
            end
        end
    end

    // ---------------------------------------------------------------------
    // Row buffer update: shift chain so row_ram[N-2] always holds the most
    // recently completed row, row_ram[0] holds the oldest row still needed.
    // ---------------------------------------------------------------------
    generate
        for (gi = 0; gi < N-1; gi++) begin : g_row_wr
            always_ff @(posedge clk) begin
                if (in_valid) begin
                    if (gi == N-2)
                        row_ram[gi][wr_col] <= in_pixel;
                    else
                        row_ram[gi][wr_col] <= row_ram[gi+1][wr_col];
                end
            end
        end
    endgenerate

    // ---------------------------------------------------------------------
    // NxN window shift register (kept as an internal unpacked array for
    // readability; flattened onto win_flat below for the module boundary).
    // win[r][c]: r=0 is the oldest row (top of kernel), r=N-1 is newest row.
    // ---------------------------------------------------------------------
    logic [PIXEL_W-1:0] win [N][N];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int r = 0; r < N; r++)
                for (int c = 0; c < N; c++)
                    win[r][c] <= '0;
        end else if (in_valid) begin
            for (int r = 0; r < N; r++) begin
                for (int c = 0; c < N-1; c++) begin
                    win[r][c] <= win[r][c+1];              // shift left
                end
            end
            for (int r = 0; r < N-1; r++)
                win[r][N-1] <= row_rd[r];                  // new sample from row buffer r
            win[N-1][N-1] <= in_pixel;                     // new sample = incoming pixel
        end
    end

    // -----------------------------------------------------------------
    // Pipeline Delay Registers (MUST be declared BEFORE g_flatten)
    // -----------------------------------------------------------------
    logic in_valid_d;
    logic [COL_CNT_W-1:0] wr_col_d;
    logic [ROW_CNT_W-1:0] wr_row_d;

    // -----------------------------------------------------------------
    // Flatten win[][] -> win_flat, WITH per-tap zero-masking for
    // same-padding (causal/trailing-window convolution).
    // -----------------------------------------------------------------
    generate
        for (gi = 0; gi < N*N; gi++) begin : g_flatten
            localparam int RR = gi / N;
            localparam int CC = gi % N;
            logic tap_valid;
            assign tap_valid = (wr_row_d >= (N-1-RR)) && (wr_col_d >= (N-1-CC));
            assign win_flat[(gi+1)*PIXEL_W-1 -: PIXEL_W] = tap_valid ? win[RR][CC] : '0;
        end
    endgenerate

    // ---------------------------------------------------------------------
    // Update Delay Registers
    // ---------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_valid_d <= 1'b0;
            wr_col_d   <= '0;
            wr_row_d   <= '0;
        end else begin
            in_valid_d <= in_valid & ~clear;
            wr_col_d   <= wr_col;
            wr_row_d   <= wr_row;
        end
    end

    // ---------------------------------------------------------------------
    // Window validity: Every accepted pixel yields an output window.
    // ---------------------------------------------------------------------
    assign win_valid = in_valid_d;

endmodule