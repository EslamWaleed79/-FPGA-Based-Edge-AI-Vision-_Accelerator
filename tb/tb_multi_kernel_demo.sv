`timescale 1ns/1ps

module tb_multi_kernel_demo;

    localparam int PIXEL_W     = 8;
    localparam int KER_W       = 8;
    localparam int N           = 3;
    localparam int OUT_W       = 16;
    localparam int IMG_W_MAX   = 32;
    localparam int IMG_H_MAX   = 32;
    localparam int NUM_KERNELS = 4;
    localparam int KBANK_W     = $clog2(NUM_KERNELS);
    localparam int CLK_PERIOD  = 10;

    logic clk = 0;
    logic rst_n = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    logic [$clog2(IMG_W_MAX+1)-1:0] cfg_img_width;
    logic [$clog2(IMG_H_MAX+1)-1:0] cfg_img_height;
    logic                            cfg_relu_en;

    logic                            cfg_kernel_wr_en;
    logic [KBANK_W-1:0]               cfg_kernel_wr_bank;
    logic [$clog2(N)-1:0]            cfg_kernel_wr_row;
    logic [$clog2(N)-1:0]            cfg_kernel_wr_col;
    logic signed [KER_W-1:0]         cfg_kernel_wr_data;
    logic [KBANK_W-1:0]               cfg_kernel_sel;

    logic start, busy, done;
    logic in_valid;
    logic [PIXEL_W-1:0] in_pixel;
    logic in_ready;
    logic out_valid;
    logic signed [OUT_W-1:0] out_pixel;

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

    int H, W, N_cfg, OUTW_cfg, RELU_cfg;
    int img_mem [0:IMG_H_MAX*IMG_W_MAX-1];
    int ker0_mem [0:N*N-1];
    int ker1_mem [0:N*N-1];
    int exp0_mem [0:IMG_H_MAX*IMG_W_MAX-1];
    int exp1_mem [0:IMG_H_MAX*IMG_W_MAX-1];
    int out_total;

    task automatic read_config(input string fname);
        int fd;
        fd = $fopen(fname, "r");
        if (fd == 0) $fatal(1, "Could not open %s", fname);
        $fscanf(fd, "%d %d %d %d %d", H, W, N_cfg, OUTW_cfg, RELU_cfg);
        $fclose(fd);
        if (N_cfg != N) $fatal(1, "TB N=%0d != config N=%0d", N, N_cfg);
    endtask

    task automatic read_img(input string fname, input int count);
        int fd, i, v;
        fd = $fopen(fname, "r");
        if (fd == 0) $fatal(1, "Could not open %s", fname);
        for (i = 0; i < count; i++) begin
            if ($fscanf(fd, "%d", v) != 1) $fatal(1, "EOF reading %s @ %0d", fname, i);
            img_mem[i] = v;
        end
        $fclose(fd);
    endtask

    task automatic read_ker0(input string fname, input int count);
        int fd, i, v;
        fd = $fopen(fname, "r");
        if (fd == 0) $fatal(1, "Could not open %s", fname);
        for (i = 0; i < count; i++) begin
            if ($fscanf(fd, "%d", v) != 1) $fatal(1, "EOF reading %s @ %0d", fname, i);
            ker0_mem[i] = v;
        end
        $fclose(fd);
    endtask

    task automatic read_ker1(input string fname, input int count);
        int fd, i, v;
        fd = $fopen(fname, "r");
        if (fd == 0) $fatal(1, "Could not open %s", fname);
        for (i = 0; i < count; i++) begin
            if ($fscanf(fd, "%d", v) != 1) $fatal(1, "EOF reading %s @ %0d", fname, i);
            ker1_mem[i] = v;
        end
        $fclose(fd);
    endtask

    task automatic read_exp0(input string fname, input int count);
        int fd, i, v;
        fd = $fopen(fname, "r");
        if (fd == 0) $fatal(1, "Could not open %s", fname);
        for (i = 0; i < count; i++) begin
            if ($fscanf(fd, "%d", v) != 1) $fatal(1, "EOF reading %s @ %0d", fname, i);
            exp0_mem[i] = v;
        end
        $fclose(fd);
    endtask

    task automatic read_exp1(input string fname, input int count);
        int fd, i, v;
        fd = $fopen(fname, "r");
        if (fd == 0) $fatal(1, "Could not open %s", fname);
        for (i = 0; i < count; i++) begin
            if ($fscanf(fd, "%d", v) != 1) $fatal(1, "EOF reading %s @ %0d", fname, i);
            exp1_mem[i] = v;
        end
        $fclose(fd);
    endtask

    // load a kernel array (bank 0 source) into a specific hardware bank
    task automatic load_kernel_bank0(input int bank);
        int r, c, idx;
        idx = 0;
        for (r = 0; r < N; r++) begin
            for (c = 0; c < N; c++) begin
                @(posedge clk);
                cfg_kernel_wr_en   <= 1'b1;
                cfg_kernel_wr_bank <= bank[KBANK_W-1:0];
                cfg_kernel_wr_row  <= r[$clog2(N)-1:0];
                cfg_kernel_wr_col  <= c[$clog2(N)-1:0];
                cfg_kernel_wr_data <= ker0_mem[idx][KER_W-1:0];
                idx++;
            end
        end
        @(posedge clk);
        cfg_kernel_wr_en <= 1'b0;
    endtask

    task automatic load_kernel_bank1(input int bank);
        int r, c, idx;
        idx = 0;
        for (r = 0; r < N; r++) begin
            for (c = 0; c < N; c++) begin
                @(posedge clk);
                cfg_kernel_wr_en   <= 1'b1;
                cfg_kernel_wr_bank <= bank[KBANK_W-1:0];
                cfg_kernel_wr_row  <= r[$clog2(N)-1:0];
                cfg_kernel_wr_col  <= c[$clog2(N)-1:0];
                cfg_kernel_wr_data <= ker1_mem[idx][KER_W-1:0];
                idx++;
            end
        end
        @(posedge clk);
        cfg_kernel_wr_en <= 1'b0;
    endtask

    int out_idx;
    int mismatches;
    int first_mismatch_idx;
    int active_exp_select; // 0 = checking against exp0_mem, 1 = exp1_mem

    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            logic signed [OUT_W-1:0] expected;
            expected = (active_exp_select == 0) ? exp0_mem[out_idx][OUT_W-1:0]
                                                : exp1_mem[out_idx][OUT_W-1:0];
            if (out_idx < out_total) begin
                if (out_pixel !== expected) begin
                    if (first_mismatch_idx == -1) begin
                        first_mismatch_idx = out_idx;
                        $display("[TB] FIRST MISMATCH (bank select=%0d) at idx %0d: DUT=%0d EXPECTED=%0d",
                                 active_exp_select, out_idx, out_pixel, expected);
                    end
                    mismatches++;
                end
            end
            out_idx++;
        end
    end

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

    task automatic run_one_frame(input int bank_sel, input int exp_select);
        out_idx = 0;
        active_exp_select = exp_select;
        @(posedge clk);
        cfg_img_width  <= W[$clog2(IMG_W_MAX+1)-1:0];
        cfg_img_height <= H[$clog2(IMG_H_MAX+1)-1:0];
        cfg_kernel_sel <= bank_sel[KBANK_W-1:0];
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        stream_frame();
        wait (done == 1'b1);
        repeat (5) @(posedge clk);
        $display("[TB] Frame done: bank_sel=%0d  captured=%0d/%0d  mismatches_so_far=%0d",
                  bank_sel, out_idx, out_total, mismatches);
    endtask

    initial begin
        start = 0; in_valid = 0; in_pixel = 0;
        cfg_kernel_wr_en = 0; cfg_kernel_wr_bank = 0;
        cfg_kernel_wr_row = 0; cfg_kernel_wr_col = 0; cfg_kernel_wr_data = 0;
        cfg_kernel_sel = 0; cfg_relu_en = 0;
        mismatches = 0; first_mismatch_idx = -1; out_idx = 0;

        rst_n = 0; #150; repeat (5) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

        read_config("config_bank0.txt");
        read_img("input_image.txt", H*W);
        read_ker0("kernel_bank0.txt", N*N);
        read_ker1("kernel_bank1.txt", N*N);
        out_total = H*W;  // SAME-PADDING: every input pixel yields one output pixel
        read_exp0("expected_output_bank0.txt", out_total);
        read_exp1("expected_output_bank1.txt", out_total);

        $display("[TB] Preloading BOTH kernel banks (single config pass) ...");
        load_kernel_bank0(0);
        load_kernel_bank1(1);

        $display("[TB] ==== Frame 1: selecting bank 0, NO reload since preload ====");
        cfg_relu_en = 0; // Disable ReLU for the first frame
        run_one_frame(0, 0);

        $display("[TB] ==== Frame 2: selecting bank 1, NO reload since preload ====");
        cfg_relu_en = 1; // Enable ReLU for the second frame to match the Python model
        run_one_frame(1, 1);

        $display("[TB] Total mismatches across both frames = %0d (first at global idx meaning varies per-frame; see above)", mismatches);
        if (mismatches == 0) begin
            $display("MULTI-KERNEL TEST PASSED");
        end else begin
            $display("MULTI-KERNEL TEST FAILED (mismatches=%0d)", mismatches);
        end
        $finish;
    end

    initial begin
        #4_000_000;
        $display("MULTI-KERNEL TEST FAILED (TIMEOUT)");
        $finish;
    end

endmodule
