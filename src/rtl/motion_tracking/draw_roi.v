`timescale 1ns/1ps
// draw_roi
// 功能：用稳定跟踪框绘制目标红框
// 输入：clk、de_in、rgb_in、x_cnt、track_valid、track_cx
// 输出：de_out、rgb_out
module draw_roi #(
    parameter MAX_ROI = 4,
    parameter LINE_W  = 2
)(
    input  wire        clk, rst_n,
    input  wire        de_in, hs_in, vs_in,
    input  wire [23:0] rgb_in,
    input  wire [15:0] x_cnt, y_cnt,            // 720p 域，与 rgb_in/de_in 对齐
    input  wire [MAX_ROI-1:0]     track_valid,
    input  wire [MAX_ROI*12-1:0]  track_cx, track_cy, track_w, track_h,
    output reg         de_out, hs_out, vs_out,
    output reg  [23:0] rgb_out
);
    localparam RED = 24'hFF0000;

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

    wire any_hit = |hit;

    // ---- 2 拍流水对齐 + 上色（与 draw_track 同构，避免像素域时序错误）----
    reg        de_r, hs_r, vs_r, hit_r;
    reg [23:0] rgb_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_r<=0; hs_r<=0; vs_r<=0; hit_r<=0; rgb_r<=0;
        end else begin
            de_r<=de_in; hs_r<=hs_in; vs_r<=vs_in;
            hit_r<=any_hit; rgb_r<=rgb_in;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_out<=0; hs_out<=0; vs_out<=0; rgb_out<=0;
        end else begin
            de_out<=de_r; hs_out<=hs_r; vs_out<=vs_r;
            rgb_out <= (de_r && hit_r) ? RED : rgb_r;
        end
    end
endmodule
