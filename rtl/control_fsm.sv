module control_fsm #(
    parameter int CNT_W = 32
) (
    input  logic              clk,
    input  logic              rst_n,

    input  logic               start,           // pulse: begin a new frame
    input  logic [CNT_W-1:0]   cfg_pix_total,    // IMG_H * IMG_W (total input pixels)
    input  logic [CNT_W-1:0]   cfg_out_total,    // (IMG_H-N+1)*(IMG_W-N+1) (total valid outputs)

    input  logic               out_valid_pulse,  // pulses once per valid output pixel from mac_array

    output logic               frame_clear,      // 1-cycle pulse: clear line buffer state
    output logic               in_ready,         // 1 while FSM is in RUN (may accept in_valid)
    output logic               busy,
    output logic               done              // 1-cycle pulse when the frame is complete
);

    typedef enum logic [2:0] {S_IDLE, S_LOAD, S_RUN, S_DRAIN, S_DONE} state_t;
    state_t state, state_n;

    logic [CNT_W-1:0] out_cnt, out_cnt_n;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            out_cnt <= '0;
        end else begin
            state   <= state_n;
            out_cnt <= out_cnt_n;
        end
    end

    always_comb begin
        state_n     = state;
        out_cnt_n   = out_cnt;
        frame_clear = 1'b0;
        in_ready    = 1'b0;
        busy        = 1'b1;
        done        = 1'b0;

        unique case (state)
            S_IDLE: begin
                busy = 1'b0;
                if (start) state_n = S_LOAD;
            end

            S_LOAD: begin
                frame_clear = 1'b1;
                out_cnt_n   = '0;
                state_n     = S_RUN;
            end

            S_RUN: begin
                in_ready = 1'b1;
                if (out_valid_pulse)
                    out_cnt_n = out_cnt + 1'b1;
              
                if (out_cnt_n == cfg_out_total)
                    state_n = S_DONE;
                else if (!out_valid_pulse && out_cnt == cfg_out_total)
                    state_n = S_DONE;
            end

            S_DRAIN: begin
            
                if (out_valid_pulse)
                    out_cnt_n = out_cnt + 1'b1;
                if (out_cnt_n == cfg_out_total)
                    state_n = S_DONE;
            end

            S_DONE: begin
                done    = 1'b1;
                state_n = S_IDLE;
            end

            default: state_n = S_IDLE;
        endcase
    end

endmodule
