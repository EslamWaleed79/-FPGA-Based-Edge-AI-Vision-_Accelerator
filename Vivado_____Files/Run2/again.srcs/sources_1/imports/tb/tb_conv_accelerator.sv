`timescale 1ns/1ps

module tb_conv_accelerator;

    // ============================================================
    // Parameters
    // ============================================================
    localparam int PIXEL_W     = 8;
    localparam int KER_W       = 8;
    localparam int N           = 3;
    localparam int OUT_W       = 16;
    localparam int IMG_W_MAX   = 32;
    localparam int IMG_H_MAX   = 32;
    localparam int NUM_KERNELS = 4; // Matches the implemented netlist

    localparam int IMG_W_BITS  = $clog2(IMG_W_MAX + 1);
    localparam int IMG_H_BITS  = $clog2(IMG_H_MAX + 1);
    localparam int KER_IDX_BITS = $clog2(N);
    localparam int KBANK_W     = (NUM_KERNELS > 1) ? $clog2(NUM_KERNELS) : 1;

    localparam real CLK_PERIOD = 15.0;

    // ============================================================
    // Clock / Reset
    // ============================================================
    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #(CLK_PERIOD / 2.0) clk = ~clk;

    // ============================================================
    // DUT configuration
    // ============================================================
    logic [IMG_W_BITS-1:0]   cfg_img_width;
    logic [IMG_H_BITS-1:0]   cfg_img_height;
    logic                    cfg_relu_en;
    logic                    cfg_kernel_wr_en;
    logic [KBANK_W-1:0]      cfg_kernel_wr_bank; // Now explicitly 2-bit
    logic [KER_IDX_BITS-1:0] cfg_kernel_wr_row;
    logic [KER_IDX_BITS-1:0] cfg_kernel_wr_col;
    logic signed [KER_W-1:0] cfg_kernel_wr_data;
    logic [KBANK_W-1:0]      cfg_kernel_sel;     // Now explicitly 2-bit

    logic start, busy, done;
    logic                    in_valid;
    logic [PIXEL_W-1:0]      in_pixel;
    logic                    in_ready;
    logic                    out_valid;
    logic signed [OUT_W-1:0] out_pixel;

    // ============================================================
    // DUT
    // ============================================================
    top_conv_accelerator #(
        .PIXEL_W     (PIXEL_W),
        .KER_W       (KER_W),
        .N           (N),
        .OUT_W       (OUT_W),
        .IMG_W_MAX   (IMG_W_MAX),
        .IMG_H_MAX   (IMG_H_MAX),
        .NUM_KERNELS (NUM_KERNELS)
    ) dut (
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
        .in_valid           (in_valid),
        .in_pixel           (in_pixel),
        .in_ready           (in_ready),
        .out_valid          (out_valid),
        .out_pixel          (out_pixel)
    );

    // ============================================================
    // Test vector storage
    // ============================================================
    int H, W, N_cfg, OUTW_cfg, RELU_cfg;
    int img_mem [0:IMG_H_MAX*IMG_W_MAX-1];
    int ker_mem [0:N*N-1];
    int exp_mem [0:IMG_H_MAX*IMG_W_MAX-1];
    int out_total, mismatches, first_mismatch_idx, out_idx;

    // ============================================================
    // File reading
    // ============================================================
    task automatic read_config(input string fname);
        int fd;
        fd = $fopen(fname, "r");
        if (fd == 0) $fatal(1, "[TB] Could not open %s", fname);
        if ($fscanf(fd, "%d %d %d %d %d", H, W, N_cfg, OUTW_cfg, RELU_cfg) != 5)
            $fatal(1, "[TB] Invalid config file %s", fname);
        $fclose(fd);
        $display("[TB] config.txt -> H=%0d W=%0d N=%0d OUT_W=%0d RELU=%0d", H, W, N_cfg, OUTW_cfg, RELU_cfg);
        if (N_cfg != N) $fatal(1, "[TB] Testbench N mismatch");
    endtask

    task automatic read_img_file(input string fname, input int count);
        int fd, i, v;
        fd = $fopen(fname, "r");
        if (fd == 0) $fatal(1, "[TB] Could not open %s", fname);
        for (i = 0; i < count; i = i + 1) begin
            if ($fscanf(fd, "%d", v) != 1) $fatal(1, "[TB] EOF/error reading %s", fname);
            img_mem[i] = v;
        end
        $fclose(fd);
    endtask

    task automatic read_ker_file(input string fname, input int count);
        int fd, i, v;
        fd = $fopen(fname, "r");
        if (fd == 0) $fatal(1, "[TB] Could not open %s", fname);
        for (i = 0; i < count; i = i + 1) begin
            if ($fscanf(fd, "%d", v) != 1) $fatal(1, "[TB] EOF/error reading %s", fname);
            ker_mem[i] = v;
        end
        $fclose(fd);
    endtask

    task automatic read_exp_file(input string fname, input int count);
        int fd, i, v;
        fd = $fopen(fname, "r");
        if (fd == 0) $fatal(1, "[TB] Could not open %s", fname);
        for (i = 0; i < count; i = i + 1) begin
            if ($fscanf(fd, "%d", v) != 1) $fatal(1, "[TB] EOF/error reading %s", fname);
            exp_mem[i] = v;
        end
        $fclose(fd);
    endtask

    // ============================================================
    // Kernel loading (Drive on Negedge for Post-Impl timing safety)
    // ============================================================
    task automatic load_kernel();
        int r, c, idx;
        idx = 0;
        for (r = 0; r < N; r = r + 1) begin
            for (c = 0; c < N; c = c + 1) begin
                @(negedge clk);
                cfg_kernel_wr_en   = 1'b1;
                cfg_kernel_wr_bank = 2'd0; // Write to bank 0
                cfg_kernel_wr_row  = r[KER_IDX_BITS-1:0];
                cfg_kernel_wr_col  = c[KER_IDX_BITS-1:0];
                cfg_kernel_wr_data = $signed(ker_mem[idx]);
                idx = idx + 1;
            end
        end
        @(negedge clk);
        cfg_kernel_wr_en   = 1'b0;
        cfg_kernel_wr_bank = 2'd0;
        cfg_kernel_wr_row  = '0;
        cfg_kernel_wr_col  = '0;
        cfg_kernel_wr_data = '0;
    endtask

    // ============================================================
    // Pixel streaming (Drive on Negedge)
    // ============================================================
    task automatic stream_frame();
        int i;
        i = 0;
        while (i < H * W) begin
            @(negedge clk);
            if (in_ready) begin
                in_valid = 1'b1;
                in_pixel = img_mem[i][PIXEL_W-1:0];
                i = i + 1;
            end else begin
                in_valid = 1'b0;
                in_pixel = '0;
            end
        end
        @(negedge clk);
        in_valid = 1'b0;
        in_pixel = '0;
    endtask

    // ============================================================
    // Output scoreboard
    // ============================================================
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            if (out_idx >= out_total) begin
                $display("[TB] ERROR: DUT produced unexpected extra output at index %0d", out_idx);
            end else begin
                if ($signed(out_pixel) !== $signed(exp_mem[out_idx][OUT_W-1:0])) begin
                    if (first_mismatch_idx == -1) begin
                        first_mismatch_idx = out_idx;
                        $display("[TB] FIRST MISMATCH at index %0d: DUT=%0d EXPECTED=%0d", 
                            out_idx, $signed(out_pixel), $signed(exp_mem[out_idx][OUT_W-1:0]));
                    end
                    mismatches = mismatches + 1;
                end
            end
            out_idx = out_idx + 1;
        end
    end

    // ============================================================
    // Main test
    // ============================================================
    initial begin
        start              = 1'b0;
        in_valid           = 1'b0;
        in_pixel           = '0;
        cfg_img_width      = '0;
        cfg_img_height     = '0;
        cfg_relu_en        = 1'b0;
        cfg_kernel_wr_en   = 1'b0;
        cfg_kernel_wr_bank = 2'd0;
        cfg_kernel_wr_row  = '0;
        cfg_kernel_wr_col  = '0;
        cfg_kernel_wr_data = '0;
        cfg_kernel_sel     = 2'd0;
        out_idx            = 0;
        mismatches         = 0;
        first_mismatch_idx = -1;

        rst_n = 1'b0;
        #150;
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        read_config("config.txt");
        read_img_file("input_image.txt", H * W);
        read_ker_file("kernel.txt", N * N);
        out_total = H * W;
        read_exp_file("expected_output.txt", out_total);
        cfg_relu_en = RELU_cfg[0];

        $display("[TB] Loading kernel...");
        load_kernel();
        $display("[TB] Kernel loading complete.");

        @(negedge clk);
        cfg_img_width  = W[IMG_W_BITS-1:0];
        cfg_img_height = H[IMG_H_BITS-1:0];

        @(negedge clk);
        cfg_kernel_sel = 2'd0;

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        fork
            stream_frame();
        join_none

        wait (done == 1'b1);
        repeat (5) @(posedge clk);

        $display("");
        $display("============================================================");
        $display("TEST RESULT");
        $display("============================================================");
        $display("[TB] Captured %0d output pixels (expected %0d)", out_idx, out_total);
        $display("[TB] Mismatches = %0d", mismatches);
        if (out_idx == out_total && mismatches == 0) begin
            $display("[TB] TEST PASSED");
        end else begin
            $display("[TB] TEST FAILED (mismatches=%0d, first_mismatch_idx=%0d, captured=%0d/%0d)", 
                mismatches, first_mismatch_idx, out_idx, out_total);
        end
        $display("============================================================");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("[TB] TEST FAILED (TIMEOUT)");
        $finish;
    end
endmodule