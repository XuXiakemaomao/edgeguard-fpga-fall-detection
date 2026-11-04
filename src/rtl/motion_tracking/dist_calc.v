//曼哈顿距离计算模块
`timescale 1ns/1ps
// dist_calc
// 功能：曼哈顿距离计算
// 输入：center1、center2
// 输出：distance
module dist_calc#(
    parameter DIST_W = 13
)(
    input  wire [23:0] center1,
    input  wire [23:0] center2,
    output wire [DIST_W-1:0] distance // 扩展到13位防溢出
);
    wire [11:0] cx1 = center1[23:12];
    wire [11:0] cy1 = center1[11:0];
    wire [11:0] cx2 = center2[23:12];
    wire [11:0] cy2 = center2[11:0];

    wire [DIST_W-1:0] dx = (cx1 > cx2) ? (cx1 - cx2) : (cx2 - cx1);
    wire [DIST_W-1:0] dy = (cy1 > cy2) ? (cy1 - cy2) : (cy2 - cy1);

    assign distance = dx + dy;
endmodule
