`timescale 1ns/1ps
// fusion_decision
// 功能：结合 CNN 结果和几何状态输出最终行为状态
// 输入：target_valid、fall_confirm、geom_moving、geom_still
// 输出：final_state、final_valid
module fusion_decision (
    input  wire       target_valid,
    input  wire       fall_confirm,
    input  wire       geom_moving,
    input  wire       geom_still,
    output reg  [1:0] final_state,   // 0 walk, 1 stay, 2 fall, 3 other
    output reg        final_valid
);
    always @* begin
        final_valid = target_valid;
        if (!target_valid)     final_state = 2'd3;
        else if (fall_confirm) final_state = 2'd2;
        else if (geom_moving)  final_state = 2'd0;
        else if (geom_still)   final_state = 2'd1;
        else                   final_state = 2'd3;
    end
endmodule
