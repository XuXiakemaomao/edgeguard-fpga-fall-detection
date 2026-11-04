//中心点计算模块
//  cx = (x0+x1)>>1, cy = (y0+y1)>>1
//  注意：x0+x1 最大 8190，必须用 13 位求和，否则 12 位加法会丢掉最高进位
//        （原写法在 x0+x1>4095 时结果错误，例如 (2000,2500) 会算成 202）
`timescale 1ns/1ps
// centroid_calc
// 功能：计算目标框中心点
// 输入：roi_box
// 输出：center
module centroid_calc(
    input  [47:0] roi_box,   // {x0[11:0], y0[11:0], x1[11:0], y1[11:0]}
    output [23:0] center     // {cx[11:0], cy[11:0]}
);
    wire [12:0] x_sum = {1'b0, roi_box[47:36]} + {1'b0, roi_box[23:12]};
    wire [12:0] y_sum = {1'b0, roi_box[35:24]} + {1'b0, roi_box[11:0]};

    assign center = {x_sum[12:1], y_sum[12:1]};
endmodule
//centroid_calc
