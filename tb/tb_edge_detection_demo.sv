`timescale 1ns/1ps

module tb_edge_detection_demo;

    // ---- parameters (must match golden_model_sobel.py invocation) ----
    localparam int PIXEL_W   = 8;
    localparam int KER_W     = 8;
    localparam int N         = 3;
    localparam int OUT_W     = 16;
    localparam int IMG_W_MAX = 32;
    localparam int IMG_H_MAX = 32;
    localparam int CLK_PERIOD = 10; // 100 MHz test clock

    logic clk = 0;
    logic rst_n = 0;

    logic [$clog2(IMG_W_MAX+1)-1:0] cfg_img_width;
    logic [$clog2(IMG_H_MAX+1)-1:0] cfg_img_height;
    logic                            cfg_relu_en;

    logic                            cfg_kernel_wr_en;
    logic [0:0]                      cfg_kernel_wr_bank; // single-bank use: tie to 0
    logic [$clog2(N)-1:0]            cfg_kernel_wr_row;
    logic [$clog2(N)-1:0]            cfg_kernel_wr_col;
    logic signed [KER_W-1:0]         cfg_kernel_wr_data;
    logic [0:0]                      cfg_kernel_sel;     // single-bank use: tie to 0

    logic start, busy, done;
    logic in_valid;
    logic [PIXEL_W-1:0] in_pixel;
    logic in_ready;
    logic out_valid;
    logic signed [OUT_W-1:0] out_pixel;

    // ---- clock ----
    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- DUT (same top-level as the mandatory-spec TB) ----
    top_conv_accelerator #(
        .PIXEL_W   (PIXEL_W),
        .KER_W     (KER_W),
        .N         (N),
        .OUT_W     (OUT_W),
        .IMG_W_MAX (IMG_W_MAX),
        .IMG_H_MAX (IMG_H_MAX)
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

    // ---- test vector storage ----
    int H, W, N_cfg, OUTW_cfg, RELU_cfg;
    int img_mem   [0:IMG_H_MAX*IMG_W_MAX-1];
    int ker_x_mem [0:N*N-1];
    int ker_y_mem [0:N*N-1];
    int exp_x_mem [0:IMG_H_MAX*IMG_W_MAX-1]; // sized generously; only first out_total used
    int exp_y_mem [0:IMG_H_MAX*IMG_W_MAX-1];
    int out_total;

    // per-pass scoreboard state (reset between the X pass and Y pass)
    int     out_idx;
    int     mismatches;
    int     first_mismatch_idx;
    int     active_pass;      // 0 = Sobel X (compare vs exp_x_mem), 1 = Sobel Y (vs exp_y_mem)
    logic   scoreboard_en;

    // ---- file reading: config (decimal, same convention as config.txt) ----
    task automatic read_config(input string fname);
        int fd;
        fd = $fopen(fname, "r");
        if (fd == 0) $fatal(1, "Could not open %s", fname);
        $fscanf(fd, "%d %d %d %d %d", H, W, N_cfg, OUTW_cfg, RELU_cfg);
        $fclose(fd);
        $display("[TB-EDGE] config_sobel.txt -> H=%0d W=%0d N=%0d OUT_W=%0d RELU=%0d",
                  H, W, N_cfg, OUTW_cfg, RELU_cfg);
        if (N_cfg != N)
            $fatal(1, "TB N=%0d does not match config_sobel.txt N=%0d", N, N_cfg);
    endtask

    // ---- file reading: HEX vectors, one explicit task per target array ----
    task automatic read_img_file_hex(input string fname, input int count);
        int fd, i, v;
        fd = $fopen(fname, "r");
        if (fd == 0) $fatal(1, "Could not open %s", fname);
        for (i = 0; i < count; i++) begin
            if ($fscanf(fd, "%h", v) != 1)
                $fatal(1, "Unexpected EOF reading %s at index %0d", fname, i);
            img_mem[i] = v;
        end
        $fclose(fd);
    endtask

    task automatic read_kerx_file_hex(input string fname, input int count);
        int fd, i, v;
        fd = $fopen(fname, "r");
        if (fd == 0) $fatal(1, "Could not open %s", fname);
        for (i = 0; i < count; i++) begin
            if ($fscanf(fd, "%h", v) != 1)
                $fatal(1, "Unexpected EOF reading %s at index %0d", fname, i);
            ker_x_mem[i] = v;
        end
        $fclose(fd);
    endtask

    task automatic read_kery_file_hex(input string fname, input int count);
        int fd, i, v;
        fd = $fopen(fname, "r");
        if (fd == 0) $fatal(1, "Could not open %s", fname);
        for (i = 0; i < count; i++) begin
            if ($fscanf(fd, "%h", v) != 1)
                $fatal(1, "Unexpected EOF reading %s at index %0d", fname, i);
            ker_y_mem[i] = v;
        end
        $fclose(fd);
    endtask

    task automatic read_expx_file_hex(input string fname, input int count);
        int fd, i, v;
        fd = $fopen(fname, "r");
        if (fd == 0) $fatal(1, "Could not open %s", fname);
        for (i = 0; i < count; i++) begin
            if ($fscanf(fd, "%h", v) != 1)
                $fatal(1, "Unexpected EOF reading %s at index %0d", fname, i);
            exp_x_mem[i] = v;
        end
        $fclose(fd);
    endtask

    task automatic read_expy_file_hex(input string fname, input int count);
        int fd, i, v;
        fd = $fopen(fname, "r");
        if (fd == 0) $fatal(1, "Could not open %s", fname);
        for (i = 0; i < count; i++) begin
            if ($fscanf(fd, "%h", v) != 1)
                $fatal(1, "Unexpected EOF reading %s at index %0d", fname, i);
            exp_y_mem[i] = v;
        end
        $fclose(fd);
    endtask

    // ---- kernel loading: explicit X/Y variants (overwrites kernel_regs in
    // the DUT in place; no reset needed between passes) ----
    task automatic load_kernel_x();
        int r, c, idx;
        idx = 0;
        for (r = 0; r < N; r++) begin
            for (c = 0; c < N; c++) begin
                @(posedge clk);
                cfg_kernel_wr_en   <= 1'b1;
                cfg_kernel_wr_row  <= r[$clog2(N)-1:0];
                cfg_kernel_wr_col  <= c[$clog2(N)-1:0];
                cfg_kernel_wr_data <= ker_x_mem[idx][KER_W-1:0];
                idx++;
            end
        end
        @(posedge clk);
        cfg_kernel_wr_en <= 1'b0;
    endtask

    task automatic load_kernel_y();
        int r, c, idx;
        idx = 0;
        for (r = 0; r < N; r++) begin
            for (c = 0; c < N; c++) begin
                @(posedge clk);
                cfg_kernel_wr_en   <= 1'b1;
                cfg_kernel_wr_row  <= r[$clog2(N)-1:0];
                cfg_kernel_wr_col  <= c[$clog2(N)-1:0];
                cfg_kernel_wr_data <= ker_y_mem[idx][KER_W-1:0];
                idx++;
            end
        end
        @(posedge clk);
        cfg_kernel_wr_en <= 1'b0;
    endtask

    // ---- output capture / scoreboard (active_pass selects exp_x_mem/exp_y_mem) ----
    always @(posedge clk) begin
        if (rst_n && scoreboard_en && out_valid) begin
            if (out_idx < out_total) begin
                int exp_val;
                exp_val = (active_pass == 0) ? exp_x_mem[out_idx][OUT_W-1:0]
                                              : exp_y_mem[out_idx][OUT_W-1:0];
                if (out_pixel !== exp_val[OUT_W-1:0]) begin
                    if (first_mismatch_idx == -1) begin
                        first_mismatch_idx = out_idx;
                        $display("[TB-EDGE] FIRST MISMATCH at index %0d: DUT=%0d EXPECTED=%0d",
                                  out_idx, $signed(out_pixel), $signed(exp_val[OUT_W-1:0]));
                    end
                    mismatches++;
                end
            end
            out_idx++;
        end
    end

    // ---- pixel streaming driver (same image both passes) ----
    task automatic stream_frame();
        int i;
        i = 0;
        while (i < H*W) begin
            @(posedge clk);
            if (in_ready) begin
                in_valid <= 1'b1;
                in_pixel <= img_mem[i][PIXEL_W-1:0];
                i++;
            end else begin
                in_valid <= 1'b0;
            end
        end
        @(posedge clk);
        in_valid <= 1'b0;
    endtask

    // ---- shared pass sequencing (kernel already loaded by caller) ----
    task automatic run_frame_and_wait(input int pass_sel, output int pass_mismatches,
                                       output int pass_captured);
        out_idx            = 0;
        mismatches         = 0;
        first_mismatch_idx = -1;
        active_pass        = pass_sel;
        scoreboard_en      = 1'b0;

        @(posedge clk);
        cfg_img_width  <= W[$clog2(IMG_W_MAX+1)-1:0];
        cfg_img_height <= H[$clog2(IMG_H_MAX+1)-1:0];
        @(posedge clk);
        scoreboard_en <= 1'b1;
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        stream_frame();

        wait (done == 1'b1);
        repeat (5) @(posedge clk); // allow scoreboard to settle on trailing out_valid pulses
        scoreboard_en <= 1'b0;

        pass_mismatches = mismatches;
        pass_captured   = out_idx;
    endtask

    // ---- main test sequence ----
    int x_mismatches, x_captured;
    int y_mismatches, y_captured;

    initial begin
        // defaults
        start              = 1'b0;
        in_valid           = 1'b0;
        in_pixel           = '0;
        cfg_kernel_wr_en   = 1'b0;
        cfg_kernel_wr_bank = 1'b0;
        cfg_kernel_wr_row  = '0;
        cfg_kernel_wr_col  = '0;
        cfg_kernel_wr_data = '0;
        cfg_kernel_sel     = 1'b0;
        cfg_relu_en        = 1'b0;
        scoreboard_en      = 1'b0;

        // reset
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // load vectors (all hex except config_sobel.txt)
        read_config("config_sobel.txt");
        cfg_relu_en = RELU_cfg[0];
        out_total = H * W;  // SAME-PADDING: every input pixel yields one output pixel

        read_img_file_hex ("image_sobel.txt",          H*W);
        read_kerx_file_hex("kernel_sobel_x.txt",        N*N);
        read_kery_file_hex("kernel_sobel_y.txt",        N*N);
        read_expx_file_hex("expected_sobel_x_out.txt",  out_total);
        read_expy_file_hex("expected_sobel_y_out.txt",  out_total);

        // ---- pass 1: Sobel X ----
        $display("[TB-EDGE] ---- Pass 1: Sobel X ----");
        load_kernel_x();
        run_frame_and_wait(0, x_mismatches, x_captured);
        $display("[TB-EDGE] Sobel X pass: captured=%0d/%0d mismatches=%0d",
                  x_captured, out_total, x_mismatches);

        // ---- pass 2: Sobel Y (reconfigure the SAME running DUT, no reset) ----
        $display("[TB-EDGE] ---- Pass 2: Sobel Y ----");
        load_kernel_y();
        run_frame_and_wait(1, y_mismatches, y_captured);
        $display("[TB-EDGE] Sobel Y pass: captured=%0d/%0d mismatches=%0d",
                  y_captured, out_total, y_mismatches);

        // ---- report ----
        if (x_captured == out_total && x_mismatches == 0 &&
            y_captured == out_total && y_mismatches == 0) begin
            $display("EDGE DETECTION DEMO PASSED");
        end else begin
            $display("EDGE DETECTION DEMO FAILED  (X: captured=%0d/%0d mismatches=%0d | Y: captured=%0d/%0d mismatches=%0d)",
                      x_captured, out_total, x_mismatches, y_captured, out_total, y_mismatches);
        end

        $finish;
    end

    // safety timeout (2x the mandatory-spec TB's, since this runs two passes)
    initial begin
        #4_000_000;
        $display("EDGE DETECTION DEMO FAILED (TIMEOUT)");
        $finish;
    end

endmodule
