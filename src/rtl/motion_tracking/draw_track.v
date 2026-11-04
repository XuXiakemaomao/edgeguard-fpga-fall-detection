// draw_track —— 用 tracking 的 {cx,cy,w,h} 画框，并按行为状态上色(720p 域)
// 颜色: 摔倒=红, 徘徊=黄, 停止=蓝, 移动=绿
`timescale 1ns/1ps
// draw_track
// 功能：按行为状态给跟踪目标上色
// 输入：clk、de_in、rgb_in、x_cnt、input_ok、alarm等
// 输出：de_out、rgb_out
module draw_track #(
    parameter MAX_ROI = 4,
    parameter LINE_W  = 2,
    parameter W       = 1280,
    parameter H       = 720
)(
    input  wire clk, rst_n,
    input  wire de_in, hs_in, vs_in,
    input  wire [23:0] rgb_in,
    input  wire [15:0] x_cnt, y_cnt,        // 720p 域，与 rgb_in/de_in 对齐
    input  wire        input_ok,
    input  wire        alarm,               // 危险保持：整帧红边框提示
    input  wire [MAX_ROI-1:0]          track_valid,
    input  wire [MAX_ROI*12-1:0]       track_cx, track_cy, track_w, track_h,
    input  wire [MAX_ROI-1:0]          st_fall, st_loiter, st_still, st_moving,
    output reg  de_out, hs_out, vs_out,
    output reg  [23:0] rgb_out
);

    localparam RED    = 24'hFF0000;
    localparam YELLOW = 24'hFFFF00;
    localparam BLUE   = 24'h0000FF;
    localparam GREEN  = 24'h00FF00;

    wire input_border = de_in &&
        ((x_cnt < 4) || (x_cnt >= W-4) || (y_cnt < 4) || (y_cnt >= H-4));
    // 告警用更粗的 8px 红框，避免和输入状态 4px 边框混淆
    wire alarm_border = de_in && alarm &&
        ((x_cnt < 8) || (x_cnt >= W-8) || (y_cnt < 8) || (y_cnt >= H-8));

    // ---- 每槽：框边界(720p 域, 坐标×2) + 是否命中边框 ----
    wire [MAX_ROI-1:0] hit;
    genvar g;
    generate
    for (g=0; g<MAX_ROI; g=g+1) begin : gen_box
        wire [12:0] cx2 = {1'b0, track_cx[g*12 +: 12]} << 1;
        wire [12:0] cy2 = {1'b0, track_cy[g*12 +: 12]} << 1;
        wire [12:0] w2  = {1'b0, track_w[g*12 +: 12]} << 1;
        wire [12:0] h2  = {1'b0, track_h[g*12 +: 12]} << 1;
        wire [12:0] x0  = (cx2 > (w2>>1)) ? (cx2 - (w2>>1)) : 13'd0;
        wire [12:0] y0  = (cy2 > (h2>>1)) ? (cy2 - (h2>>1)) : 13'd0;
        wire [12:0] x1  = cx2 + (w2>>1);
        wire [12:0] y1  = cy2 + (h2>>1);

        wire in_outer = (x_cnt >= {3'd0,x0}) && (x_cnt <= {3'd0,x1}) &&
                        (y_cnt >= {3'd0,y0}) && (y_cnt <= {3'd0,y1});
        wire [12:0] xi0 = x0 + LINE_W;
        wire [12:0] yi0 = y0 + LINE_W;
        wire [12:0] xi1 = (x1 > xi0) ? (x1 - LINE_W) : x0;
        wire [12:0] yi1 = (y1 > yi0) ? (y1 - LINE_W) : y0;
        wire in_inner = (x_cnt >= {3'd0,xi0}) && (x_cnt <= {3'd0,xi1}) &&
                        (y_cnt >= {3'd0,yi0}) && (y_cnt <= {3'd0,yi1});
        assign hit[g] = track_valid[g] && in_outer && !in_inner;
    end
    endgenerate

    // ---- 颜色优先级: fall > loiter > still > moving ----
    wire any_fall   = |(hit & st_fall);
    wire any_loiter = |(hit & st_loiter);
    wire any_still  = |(hit & st_still);
    wire any_moving = |(hit & st_moving);
    wire any_hit    = any_fall | any_loiter | any_still | any_moving;
    wire [23:0] sel_color = any_fall   ? RED :
                            any_loiter ? YELLOW :
                            any_still  ? BLUE :
                            any_moving ? GREEN : 24'd0;

    // ---- 2 拍流水对齐 + 上色 ----
    reg de_r, hs_r, vs_r, hit_r, border_r, input_ok_r, alarm_border_r;
    reg [23:0] rgb_r, color_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_r<=0; hs_r<=0; vs_r<=0; hit_r<=0; border_r<=0; alarm_border_r<=0;
            input_ok_r<=0; rgb_r<=0; color_r<=0;
        end else begin
            de_r<=de_in; hs_r<=hs_in; vs_r<=vs_in;
            hit_r<=any_hit; border_r<=input_border; input_ok_r<=input_ok;
            alarm_border_r<=alarm_border;
            rgb_r<=rgb_in; color_r<=sel_color;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_out<=0; hs_out<=0; vs_out<=0; rgb_out<=0;
        end else begin
            de_out<=de_r; hs_out<=hs_r; vs_out<=vs_r;
            if (de_r && alarm_border_r)
                rgb_out <= RED;
            else if (de_r && border_r)
                rgb_out <= input_ok_r ? GREEN : RED;
            else if (de_r && hit_r)
                rgb_out <= color_r;
            else
                rgb_out <= rgb_r;
        end
    end
endmodule
