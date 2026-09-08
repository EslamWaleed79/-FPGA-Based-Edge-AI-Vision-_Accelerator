`timescale 1ns/1ps

module tb_conv_accelerator;

    // ---- parameters (must match golden_model.py invocation / config.txt) ----
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

    // ---- DUT ----
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
    int ker_mem   [0:N*N-1];
    int exp_mem   [0:IMG_H_MAX*IMG_W_MAX-1]; // sized generously; only first out_total used
    int out_total;
    int mismatches;
    int first_mismatch_idx;

    // ---- file reading ----
    task automatic read_config(input string fname);
        int fd;
        fd = $fopen(fname, "r");
        if (fd == 0) begin
            $fatal(1, "Could not open %s", fname);
        end
        $fscanf(fd, "%d %d %d %d %d", H, W, N_cfg, OUTW_cfg, RELU_cfg);
        $fclose(fd);
        $display("[TB] config.txt -> H=%0d W=%0d N=%0d OUT_W=%0d RELU=%0d", H, W, N_cfg, OUTW_cfg, RELU_cfg);
        if (N_cfg != N)
            $fatal(1, "Testbench N=%0d does not match config.txt N=%0d -- regenerate vectors or change TB parameter", N, N_cfg);
    endtask

    task automatic read_img_file(input string fname, input int count);
        int fd, i, v;
        fd = $fopen(fname, "r");
        if (fd == 0) $fatal(1, "Could not open %s", fname);
        for (i = 0; i < count; i++) begin
            if ($fscanf(fd, "%d", v) != 1)
                $fatal(1, "Unexpected EOF reading %s at index %0d", fname, i);
            img_mem[i] = v;
        end
        $fclose(fd);
    endtask

    task automatic read_ker_file(input string fname, input int count);
        int fd, i, v;
        fd = $fopen(fname, "r");
        if (fd == 0) $fatal(1, "Could not open %s", fname);
        for (i = 0; i < count; i++) begin
            if ($fscanf(fd, "%d", v) != 1)
                $fatal(1, "Unexpected EOF reading %s at index %0d", fname, i);
            ker_mem[i] = v;
        end
        $fclose(fd);
    endtask

    task automatic read_exp_file(input string fname, input int count);
        int fd, i, v;
        fd = $fopen(fname, "r");
        if (fd == 0) $fatal(1, "Could not open %s", fname);
        for (i = 0; i < count; i++) begin
            if ($fscanf(fd, "%d", v) != 1)
                $fatal(1, "Unexpected EOF reading %s at index %0d", fname, i);
            exp_mem[i] = v;
        end
        $fclose(fd);
    endtask

    // ---- kernel loading ----
    task automatic load_kernel();
        int r, c, idx;
        idx = 0;
        for (r = 0; r < N; r++) begin
            for (c = 0; c < N; c++) begin
                @(posedge clk);
                cfg_kernel_wr_en   <= 1'b1;
                cfg_kernel_wr_bank <= 1'b0;
                cfg_kernel_wr_row  <= r[$clog2(N)-1:0];
                cfg_kernel_wr_col  <= c[$clog2(N)-1:0];
                cfg_kernel_wr_data <= ker_mem[idx][KER_W-1:0];
                idx++;
            end
        end
        @(posedge clk);
        cfg_kernel_wr_en <= 1'b0;
    endtask

    // ---- output capture / scoreboard ----
    int out_idx;

    initial begin
        out_idx    = 0;
        mismatches = 0;
        first_mismatch_idx = -1;
    end

    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            if (out_idx < out_total) begin
                if (out_pixel !== exp_mem[out_idx][OUT_W-1:0]) begin
                    if (first_mismatch_idx == -1) begin
                        first_mismatch_idx = out_idx;
                        $display("[TB] FIRST MISMATCH at index %0d: DUT=%0d  EXPECTED=%0d",
                                 out_idx, $signed(out_pixel), $signed(exp_mem[out_idx][OUT_W-1:0]));
                    end
                    mismatches++;
                end
            end
            out_idx++;
        end
    end

    // ---- pixel streaming driver ----
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

    // ---- main test sequence ----
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

        // reset
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // load vectors
        read_config("config.txt");
        read_img_file("input_image.txt", H*W);
        read_ker_file("kernel.txt", N*N);
        out_total = H*W;  // SAME-PADDING: every input pixel yields one output pixel
        read_exp_file("expected_output.txt", out_total);
        cfg_relu_en = RELU_cfg[0];

        // load kernel into DUT
        load_kernel();

        // configure geometry & start frame
        @(posedge clk);
        cfg_img_width  <= W[$clog2(IMG_W_MAX+1)-1:0];
        cfg_img_height <= H[$clog2(IMG_H_MAX+1)-1:0];
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        // stream the frame (fork so we can wait on 'done' concurrently)
        fork
            stream_frame();
        join_none

        // wait for completion
        wait (done == 1'b1);
        repeat (5) @(posedge clk); // allow scoreboard to settle

        // ---- report ----
        $display("[TB] Captured %0d output pixels (expected %0d)", out_idx, out_total);
        if (out_idx == out_total && mismatches == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("TEST FAILED  (mismatches=%0d, first_mismatch_idx=%0d, captured=%0d/%0d)",
                      mismatches, first_mismatch_idx, out_idx, out_total);
        end

        $finish;
    end

    // safety timeout
    initial begin
        #2_000_000;
        $display("TEST FAILED (TIMEOUT)");
        $finish;
    end

endmodule
