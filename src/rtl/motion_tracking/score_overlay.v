`timescale 1ns/1ps
// score_overlay
// 功能：行为评分面板显示
// 输入：clk、rgb_in、de_in、x、track0_valid、moving_score等
// 输出：rgb_out、de_out
module score_overlay #(
    parameter MAX_ROI = 4   // 仅保留语义, 本模块固定显示槽位 0
)(
    input  wire        clk, rst_n,
    input  wire [23:0] rgb_in,
    input  wire        de_in, hs_in, vs_in,
    input  wire [15:0] x, y,
    input  wire        track0_valid,
    input  wire [7:0]  moving_score,
    input  wire [7:0]  still_score,
    input  wire [7:0]  loiter_score,
    input  wire [7:0]  fall_score,
    output reg  [23:0] rgb_out,
    output reg         de_out, hs_out, vs_out
);
    // ---- 面板几何(720p 域) ----
    localparam [15:0] OX = 16'd8;
    localparam [15:0] OY = 16'd8;

    localparam [23:0] C_MOV = 24'h00FF00;
    localparam [23:0] C_STL = 24'h0070FF;
    localparam [23:0] C_LOI = 24'hFFFF00;
    localparam [23:0] C_FAL = 24'hFF2020;
    localparam [23:0] C_BG  = 24'h181818;
    localparam [23:0] C_OFF = 24'h303030;

    // ---- 帧开始(vs 上升沿)：锁存分数并预计算三位数字 ----
    reg vs_d;
    wire frame_start;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) vs_d <= 1'b0;
        else        vs_d <= vs_in;
    end
    assign frame_start = vs_in && !vs_d;

    // 无目标时分数按 0 处理，避免把陈旧分数显示成 000 之外的数字
    wire [7:0] ms = track0_valid ? moving_score : 8'd0;
    wire [7:0] ss = track0_valid ? still_score  : 8'd0;
    wire [7:0] ls = track0_valid ? loiter_score : 8'd0;
    wire [7:0] fs = track0_valid ? fall_score   : 8'd0;

    reg [3:0] dig100 [0:3];
    reg [3:0] dig10  [0:3];
    reg [3:0] dig1   [0:3];
    reg [3:0] row_active;
    integer fi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (fi = 0; fi < 4; fi = fi + 1) begin
                dig100[fi] <= 4'd0;
                dig10[fi]  <= 4'd0;
                dig1[fi]   <= 4'd0;
            end
            row_active <= 4'd0;
        end else if (frame_start) begin
            dig100[0] <= ms / 8'd100;
            dig10[0]  <= (ms / 8'd10) % 4'd10;
            dig1[0]   <= ms % 4'd10;
            dig100[1] <= ss / 8'd100;
            dig10[1]  <= (ss / 8'd10) % 4'd10;
            dig1[1]   <= ss % 4'd10;
            dig100[2] <= ls / 8'd100;
            dig10[2]  <= (ls / 8'd10) % 4'd10;
            dig1[2]   <= ls % 4'd10;
            dig100[3] <= fs / 8'd100;
            dig10[3]  <= (fs / 8'd10) % 4'd10;
            dig1[3]   <= fs % 4'd10;
            row_active <= {4{track0_valid}};
        end
    end

    // ---- 行选择(组合)：line = (y - OY) / 16 ----
    wire [15:0] yy = (y >= OY) ? (y - OY) : 16'd0;
    wire [1:0]  line = yy[5:4];
    wire        line_ok = (yy < 16'd64);
    wire        panel_x = (x >= OX) && (x < (OX + 16'd46));
    wire        active = row_active[line];

    wire [23:0] lcolor = (line == 2'd0) ? C_MOV :
                         (line == 2'd1) ? C_STL :
                         (line == 2'd2) ? C_LOI : C_FAL;

    // ---- 行内局部坐标与字形列 ----
    wire [15:0] line_y0 = OY + {line, 4'd0};
    wire [15:0] ly  = (y >= line_y0) ? (y - line_y0) : 16'd0;
    wire [2:0]  row = ly[3:1];
    wire        in_row = (ly < 16'd14);

    wire [15:0] d0x = OX + 16'd8 + 16'd4;      // 20
    wire [15:0] d1x = d0x + 16'd12;            // 32
    wire [15:0] d2x = d1x + 16'd12;            // 44
    wire [15:0] lx0 = (x >= d0x) ? (x - d0x) : 16'd0;
    wire [15:0] lx1 = (x >= d1x) ? (x - d1x) : 16'd0;
    wire [15:0] lx2 = (x >= d2x) ? (x - d2x) : 16'd0;
    wire [2:0]  c0 = lx0[3:1];
    wire [2:0]  c1 = lx1[3:1];
    wire [2:0]  c2 = lx2[3:1];
    wire c0_in = (x >= d0x) && (lx0 < 16'd10) && in_row;
    wire c1_in = (x >= d1x) && (lx1 < 16'd10) && in_row;
    wire c2_in = (x >= d2x) && (lx2 < 16'd10) && in_row;
    wire [2:0] cc0 = (c0 > 3'd4) ? 3'd4 : c0;
    wire [2:0] cc1 = (c1 > 3'd4) ? 3'd4 : c1;
    wire [2:0] cc2 = (c2 > 3'd4) ? 3'd4 : c2;

    // ---- 5x7 数字字形 ROM：index = digit*8 + row, bit[4] 为最左列 ----
    reg [4:0] glyph [0:79];
    integer gi;
    initial begin
        for (gi = 0; gi < 80; gi = gi + 1) glyph[gi] = 5'b00000;
        glyph[ 0] = 5'b01110; glyph[ 1] = 5'b10001; glyph[ 2] = 5'b10001;
        glyph[ 3] = 5'b10001; glyph[ 4] = 5'b10001; glyph[ 5] = 5'b10001; glyph[ 6] = 5'b01110;
        glyph[ 8] = 5'b00100; glyph[ 9] = 5'b01100; glyph[10] = 5'b00100;
        glyph[11] = 5'b00100; glyph[12] = 5'b00100; glyph[13] = 5'b00100; glyph[14] = 5'b01110;
        glyph[16] = 5'b01110; glyph[17] = 5'b10001; glyph[18] = 5'b00001;
        glyph[19] = 5'b00010; glyph[20] = 5'b00100; glyph[21] = 5'b01000; glyph[22] = 5'b11111;
        glyph[24] = 5'b11111; glyph[25] = 5'b00010; glyph[26] = 5'b00100;
        glyph[27] = 5'b00010; glyph[28] = 5'b00001; glyph[29] = 5'b10001; glyph[30] = 5'b01110;
        glyph[32] = 5'b00010; glyph[33] = 5'b00110; glyph[34] = 5'b01010;
        glyph[35] = 5'b10010; glyph[36] = 5'b11111; glyph[37] = 5'b00010; glyph[38] = 5'b00010;
        glyph[40] = 5'b11111; glyph[41] = 5'b10000; glyph[42] = 5'b11110;
        glyph[43] = 5'b00001; glyph[44] = 5'b00001; glyph[45] = 5'b10001; glyph[46] = 5'b01110;
        glyph[48] = 5'b00110; glyph[49] = 5'b01000; glyph[50] = 5'b10000;
        glyph[51] = 5'b11110; glyph[52] = 5'b10001; glyph[53] = 5'b10001; glyph[54] = 5'b01110;
        glyph[56] = 5'b11111; glyph[57] = 5'b00001; glyph[58] = 5'b00010;
        glyph[59] = 5'b00100; glyph[60] = 5'b01000; glyph[61] = 5'b01000; glyph[62] = 5'b01000;
        glyph[64] = 5'b01110; glyph[65] = 5'b10001; glyph[66] = 5'b10001;
        glyph[67] = 5'b01110; glyph[68] = 5'b10001; glyph[69] = 5'b10001; glyph[70] = 5'b01110;
        glyph[72] = 5'b01110; glyph[73] = 5'b10001; glyph[74] = 5'b10001;
        glyph[75] = 5'b01111; glyph[76] = 5'b00001; glyph[77] = 5'b00010; glyph[78] = 5'b01100;
    end

    wire [6:0] gidx0 = {dig100[line], row};
    wire [6:0] gidx1 = {dig10[line],  row};
    wire [6:0] gidx2 = {dig1[line],   row};
    wire d0_on = c0_in && glyph[gidx0][3'd4 - cc0];
    wire d1_on = c1_in && glyph[gidx1][3'd4 - cc1];
    wire d2_on = c2_in && glyph[gidx2][3'd4 - cc2];
    wire digit_on = d0_on | d1_on | d2_on;

    wire swatch_on = (x >= OX) && (x < (OX + 16'd8)) &&
                     (y >= line_y0) && (y < (line_y0 + 16'd8));

    // ---- 覆盖优先级：数字 > 色块 > 面板背景 > 原图 ----
    reg [23:0] rgb_comb;
    always @(*) begin
        rgb_comb = rgb_in;
        if (de_in && panel_x && line_ok) begin
            if (digit_on)
                rgb_comb = lcolor;
            else if (swatch_on)
                rgb_comb = active ? lcolor : C_OFF;
            else
                rgb_comb = C_BG;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rgb_out <= 24'd0;
            de_out  <= 1'b0;
            hs_out  <= 1'b0;
            vs_out  <= 1'b0;
        end else begin
            rgb_out <= rgb_comb;
            de_out  <= de_in;
            hs_out  <= hs_in;
            vs_out  <= vs_in;
        end
    end
endmodule
