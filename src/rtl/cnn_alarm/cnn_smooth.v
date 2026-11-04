`timescale 1ns/1ps
// cnn_smooth
// 功能：CNN 结果的连续确认与释放
// 输入：clk、rst_n、result_valid、pred、track_update、track_valid等
// 输出：fall_confirm、fall_suspect、cnt_fall、cnt_clear、locked_id
module cnn_smooth #(
    parameter N = 3,                 // consecutive fall results to confirm
    parameter M = 5                  // consecutive non-fall results to release
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       result_valid,  // one pulse per completed inference
    input  wire [1:0] pred,          // 0 normal, 1 fall, 2 other
    input  wire       track_update,
    input  wire       track_valid,
    input  wire [7:0] track_id,
    output reg        fall_confirm,
    output reg        fall_suspect,
    output reg  [7:0] cnt_fall,
    output reg  [7:0] cnt_clear,
    output reg  [7:0] locked_id
);
    // One-cycle command snapshot: the compare/reset cone must not start at the
    // packed track bus (that path was the last whole-chip timing violation).
    reg       cmd_v, cmd_tv;
    reg [7:0] cmd_id;
    always @(posedge clk) begin
        if (!rst_n) begin
            cmd_v <= 1'b0; cmd_tv <= 1'b0; cmd_id <= 8'd0;
        end else begin
            cmd_v  <= track_update;
            cmd_tv <= track_valid;
            cmd_id <= track_id;
        end
    end

    wire target_changed = cmd_v && (!cmd_tv || (cmd_id != locked_id));

    always @(posedge clk) begin
        if (!rst_n) begin
            fall_confirm <= 1'b0;
            fall_suspect <= 1'b0;
            cnt_fall     <= 8'd0;
            cnt_clear    <= 8'd0;
            locked_id    <= 8'd0;
        end else if (target_changed) begin
            fall_confirm <= 1'b0;
            fall_suspect <= 1'b0;
            cnt_fall     <= 8'd0;
            cnt_clear    <= 8'd0;
            locked_id    <= cmd_id;
        end else if (cmd_v) begin
            locked_id <= cmd_id;
        end else if (result_valid) begin
            if (pred == 2'd1) begin
                cnt_clear <= 8'd0;
                if (cnt_fall != 8'hFF) cnt_fall <= cnt_fall + 8'd1;
                if (cnt_fall + 8'd1 >= N) begin
                    fall_confirm <= 1'b1;
                    fall_suspect <= 1'b0;
                end else if (cnt_fall + 8'd1 >= N-1) begin
                    fall_suspect <= 1'b1;
                end
            end else begin
                cnt_fall     <= 8'd0;
                fall_suspect <= 1'b0;
                if (fall_confirm) begin
                    if (cnt_clear + 8'd1 >= M) begin
                        fall_confirm <= 1'b0;
                        cnt_clear    <= 8'd0;
                    end else begin
                        cnt_clear <= cnt_clear + 8'd1;
                    end
                end
            end
        end
    end
endmodule
