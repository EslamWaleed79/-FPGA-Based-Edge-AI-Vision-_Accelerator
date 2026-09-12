// =============================================================================
// mac_array.sv
// -----------------------------------------------------------------------------
// Fully-parallel NxN multiply-accumulate datapath.
//
//   - N*N signed multipliers run in parallel (one per kernel tap), each
//     computing  product[r][c] = $signed({1'b0, pixel[r][c]}) * kernel[r][c]
//     i.e. UNSIGNED pixel * SIGNED kernel coefficient -> SIGNED product.
//     (Xilinx synthesis maps these directly onto DSP48E1 slices in
//      pre-adder + multiplier mode.)
//   - An adder tree sums all N*N products into a single wide signed
//     accumulator (registered).
//   - The accumulator is intentionally wider (ACC_W) than the required
//     output width (OUT_W) to absorb the full dynamic range of the sum
//     with ZERO internal overflow (see report for the bit-growth proof).
//   - The standalone relu_activation module performs the optional ReLU
//     clamp and the mandatory output saturation (spec item #6).
//
// Ports use FLATTENED packed vectors for the window and kernel (win_flat,
// kernel_flat) rather than 2D unpacked array ports, for portability across
// simulation/synthesis tools (see line_buffer.sv header for rationale).
// Bit [ (r*N+c+1)*W-1 : (r*N+c)*W ] = element [r][c], row-major.
//
// Pipeline (3 stages -> fixed 3-cycle latency from a valid window to a
// valid output pixel), fully pipelined for 1 new window in / 1 result out
// per clock cycle in steady state:
//   S1: N*N parallel signed multiplies                (registered)
//   S2: adder-tree summation into ACC_W accumulator    (registered)
//   S3: ReLU (optional) + saturate to OUT_W             (registered)
// =============================================================================

module mac_array #(
    parameter int PIXEL_W = 8,             // unsigned input pixel width
    parameter int KER_W   = 8,             // signed kernel coefficient width
    parameter int N       = 3,             // kernel dimension (NxN taps)
    parameter int OUT_W   = 16,            // required hardware output width (signed)
    parameter int PROD_W  = PIXEL_W + KER_W,                 // product width (signed)
    parameter int TAPS    = N*N,
    parameter int ACC_W   = PROD_W + $clog2(TAPS) + 1         // accumulator width w/ headroom
) (
    input  logic                          clk,
    input  logic                          rst_n,

    input  logic                          win_valid,
    input  logic [N*N*PIXEL_W-1:0]        win_flat,          // flattened unsigned pixel window
    input  logic [N*N*KER_W-1:0]          kernel_flat,        // flattened signed kernel coeffs
    input  logic                          relu_en,             // 1 = apply ReLU before output

    output logic                          out_valid,
    output logic signed [OUT_W-1:0]       out_pixel
);

    // -------------------------------------------------------------------
    // Unflatten inputs into local 2D views (readability only; synthesizes
    // to plain wires, no extra logic).
    // -------------------------------------------------------------------
    logic [PIXEL_W-1:0]        win    [N][N];
    logic signed [KER_W-1:0]   kernel [N][N];

    genvar gu;
    generate
        for (gu = 0; gu < N*N; gu++) begin : g_unflatten
            assign win[gu / N][gu % N]    = win_flat[(gu+1)*PIXEL_W-1 -: PIXEL_W];
            assign kernel[gu / N][gu % N] = kernel_flat[(gu+1)*KER_W-1 -: KER_W];
        end
    endgenerate

    // -------------------------------------------------------------------
    // Stage 1: N*N parallel signed multiplies (registered)
    // -------------------------------------------------------------------
    logic signed [PROD_W-1:0] prod_s1 [N][N];
    logic                     win_valid_s1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int r = 0; r < N; r++)
                for (int c = 0; c < N; c++)
                    prod_s1[r][c] <= '0;
            win_valid_s1 <= 1'b0;
        end else begin
            for (int r = 0; r < N; r++)
                for (int c = 0; c < N; c++)
                    // unsigned pixel -> zero-extend by 1 bit -> unambiguous signed multiply
                    prod_s1[r][c] <= $signed({1'b0, win[r][c]}) * kernel[r][c];
            win_valid_s1 <= win_valid;
        end
    end

    // -------------------------------------------------------------------
    // Stage 2: adder-tree summation (registered), sign-extended to ACC_W
    // -------------------------------------------------------------------
    logic signed [ACC_W-1:0] acc_s2;
    logic                    win_valid_s2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_s2       <= '0;
            win_valid_s2 <= 1'b0;
        end else begin
            logic signed [ACC_W-1:0] sum;
            sum = '0;
            for (int r = 0; r < N; r++)
                for (int c = 0; c < N; c++)
                    sum += {{(ACC_W-PROD_W){prod_s1[r][c][PROD_W-1]}}, prod_s1[r][c]};
            acc_s2       <= sum;
            win_valid_s2 <= win_valid_s1;
        end
    end

    // -------------------------------------------------------------------
    // Stage 3: standalone ReLU + saturate module (combinational), registered
    // at this stage's output.
    // -------------------------------------------------------------------
    logic signed [OUT_W-1:0] relu_out_comb;

    relu_activation #(
        .ACC_W (ACC_W),
        .OUT_W (OUT_W)
    ) u_relu (
        .relu_en   (relu_en),
        .acc_in    (acc_s2),
        .out_pixel (relu_out_comb)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_pixel <= '0;
            out_valid <= 1'b0;
        end else begin
            out_pixel <= relu_out_comb;
            out_valid <= win_valid_s2;
        end
    end

endmodule
