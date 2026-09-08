module relu_activation #(
    parameter int ACC_W = 21,
    parameter int OUT_W = 16
) (
    input  logic                    relu_en,
    input  logic signed [ACC_W-1:0] acc_in,
    output logic signed [OUT_W-1:0] out_pixel
);

    localparam logic signed [OUT_W-1:0] OUT_MAX = {1'b0, {(OUT_W-1){1'b1}}};
    localparam logic signed [OUT_W-1:0] OUT_MIN = {1'b1, {(OUT_W-1){1'b0}}};

    logic signed [ACC_W-1:0] post_relu;
    logic signed [ACC_W-1:0] out_max_ext, out_min_ext;

    assign out_max_ext = {{(ACC_W-OUT_W){OUT_MAX[OUT_W-1]}}, OUT_MAX};
    assign out_min_ext = {{(ACC_W-OUT_W){OUT_MIN[OUT_W-1]}}, OUT_MIN};

    // ReLU: if enabled and the value is negative (MSB=1), clamp to 0
    assign post_relu = (relu_en && acc_in[ACC_W-1]) ? '0 : acc_in;

    always_comb begin
        if (post_relu > out_max_ext)
            out_pixel = OUT_MAX;
        else if (post_relu < out_min_ext)
            out_pixel = OUT_MIN;
        else
            out_pixel = post_relu[OUT_W-1:0];
    end

endmodule
