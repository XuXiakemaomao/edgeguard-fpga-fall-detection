`timescale 1ns/1ps
// cnn_state_merge
// 功能：将融合状态写回主目标状态位
// 输入：final_state、primary_idx、alarm、st_moving、st_still、st_loiter等
// 输出：m_moving、m_still、m_loiter、m_fall
module cnn_state_merge #(
    parameter MAX_ROI = 4
) (
    input  wire [1:0]  final_state,
    input  wire [1:0]  primary_idx,
    input  wire        alarm,          // 危险保持：主目标槽位强制 fall=1
    input  wire [MAX_ROI-1:0] st_moving,
    input  wire [MAX_ROI-1:0] st_still,
    input  wire [MAX_ROI-1:0] st_loiter,
    input  wire [MAX_ROI-1:0] st_fall,
    output wire [MAX_ROI-1:0] m_moving,
    output wire [MAX_ROI-1:0] m_still,
    output wire [MAX_ROI-1:0] m_loiter,
    output wire [MAX_ROI-1:0] m_fall
);
    genvar g;
    generate
        for (g = 0; g < MAX_ROI; g = g + 1) begin : merge
            wire sel = (g[1:0] == primary_idx);
            assign m_moving[g] = sel ? (final_state == 2'd0) : st_moving[g];
            assign m_still[g]  = sel ? (final_state == 2'd1) : st_still[g];
            assign m_loiter[g] = sel ? 1'b0                 : st_loiter[g];
            assign m_fall[g]   = sel ? ((final_state == 2'd2) || alarm) : st_fall[g];
        end
    endgenerate
endmodule
