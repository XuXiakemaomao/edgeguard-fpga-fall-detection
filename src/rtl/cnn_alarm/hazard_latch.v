`timescale 1ns/1ps
// hazard_latch
// 功能：摔倒告警保持
// 输入：clk、rst_n、vs、fall_evt、clear
// 输出：alarm
module hazard_latch #(
    parameter HOLD_FRAMES = 300   // 5s @60Hz
)(
    input  wire clk,
    input  wire rst_n,
    input  wire vs,          // 每帧一次的帧开始脉冲(像素域)
    input  wire fall_evt,    // 当前存在摔倒证据(可为电平)
    input  wire clear,       // 手动解除(高有效)
    output reg  alarm
);
    reg [15:0] hold_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alarm    <= 1'b0;
            hold_cnt <= 16'd0;
        end else if (clear) begin
            alarm    <= 1'b0;
            hold_cnt <= 16'd0;
        end else if (fall_evt) begin
            alarm    <= 1'b1;
            hold_cnt <= HOLD_FRAMES;
        end else if (alarm && vs) begin
            if (hold_cnt != 16'd0)
                hold_cnt <= hold_cnt - 1'b1;
            else
                alarm <= 1'b0;
        end
    end
endmodule
