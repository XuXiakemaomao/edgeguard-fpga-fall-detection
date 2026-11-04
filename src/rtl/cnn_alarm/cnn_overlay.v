`timescale 1ns/1ps
// cnn_overlay
// 功能：CNN 状态可视化叠加显示
// 输入：clk、de_in、rgb_in、x、primary_valid、primary_cx等
// 输出：de_out、rgb_out
module cnn_overlay #(
    parameter MAX_ROI = 4,
    parameter LINE_W  = 2
)(
    input  wire        clk, rst_n,
    input  wire        de_in, hs_in, vs_in,
    input  wire [23:0] rgb_in,
    input  wire [15:0] x, y,
    input  wire        primary_valid,
    input  wire [11:0] primary_cx, primary_cy, primary_w, primary_h,
    input  wire [1:0]  final_state,
    input  wire [1:0]  pred,          // 0 normal, 1 fall, 2 other
    input  wire        fall_confirm,
    input  wire        fall_suspect,
    input  wire        alarm,          // 危险保持：整帧红边框
    output reg         de_out, hs_out, vs_out,
    output reg  [23:0] rgb_out
);
    localparam [23:0] GREEN  = 24'h00FF00;
    localparam [23:0] BLUE   = 24'h0070FF;
    localparam [23:0] RED    = 24'hFF2020;
    localparam [23:0] YELLOW = 24'hFFFF00;
    localparam [23:0] GRAY   = 24'h606060;
    localparam [23:0] C_BG   = 24'h181818;

    // ---------------- primary box geometry (640 domain -> 720p) ----------------
    wire [12:0] cx2 = {1'b0, primary_cx} << 1;
    wire [12:0] cy2 = {1'b0, primary_cy} << 1;
    wire [12:0] w2  = {1'b0, primary_w}  << 1;
    wire [12:0] h2  = {1'b0, primary_h}  << 1;
    wire [12:0] x0  = (cx2 > (w2>>1)) ? (cx2 - (w2>>1)) : 13'd0;
    wire [12:0] y0  = (cy2 > (h2>>1)) ? (cy2 - (h2>>1)) : 13'd0;
    wire [12:0] x1  = cx2 + (w2>>1);
    wire [12:0] y1  = cy2 + (h2>>1);

    wire box_outer = (x >= {3'd0,x0}) && (x <= {3'd0,x1}) &&
                     (y >= {3'd0,y0}) && (y <= {3'd0,y1});
    wire [12:0] xi0 = x0 + LINE_W;
    wire [12:0] yi0 = y0 + LINE_W;
    wire [12:0] xi1 = (x1 > xi0) ? (x1 - LINE_W) : x0;
    wire [12:0] yi1 = (y1 > yi0) ? (y1 - LINE_W) : y0;
    wire box_inner = (x >= {3'd0,xi0}) && (x <= {3'd0,xi1}) &&
                     (y >= {3'd0,yi0}) && (y <= {3'd0,yi1});
    wire box_hit = primary_valid && box_outer && !box_inner;
    wire alarm_border = de_in && alarm &&
        ((x < 16'd8) || (x >= 16'd1272) || (y < 16'd8) || (y >= 16'd712));

    wire [23:0] state_color = (final_state == 2'd0) ? GREEN :
                              (final_state == 2'd1) ? BLUE  :
                              (final_state == 2'd2) ? RED   : YELLOW;

    // ---------------- top-left 4-row status panel ----------------
    wire [15:0] yy    = (y >= 16'd8) ? (y - 16'd8) : 16'd0;
    wire [1:0]  line  = yy[5:4];
    wire        line_ok = (yy < 16'd64);
    wire        panel_x = (x >= 16'd8) && (x < 16'd42);

    reg [3:0]  pval;
    reg [23:0] pcolor;
    reg        plit;
    always @(*) begin
        case (line)
            2'd0: begin pval = {2'b0, final_state}; pcolor = state_color; plit = 1'b1; end
            2'd1: begin pval = {3'b0, fall_confirm}; pcolor = fall_confirm ? RED : GRAY; plit = fall_confirm; end
            2'd2: begin pval = {3'b0, fall_suspect}; pcolor = fall_suspect ? YELLOW : GRAY; plit = fall_suspect; end
            default: begin
                pval = primary_valid ? {2'b0, pred} : 4'd0;
                pcolor = !primary_valid ? GRAY :
                         (pred == 2'd0) ? GREEN :
                         (pred == 2'd1) ? RED : YELLOW;
                plit = primary_valid;
            end
        endcase
    end

    wire [15:0] line_y0 = 16'd8 + {line, 4'd0};
    wire [15:0] ly = (y >= line_y0) ? (y - line_y0) : 16'd0;
    wire [2:0]  row = ly[3:1];
    wire        in_row = (ly < 16'd14);

    wire [15:0] lx = (x >= 16'd20) ? (x - 16'd20) : 16'd0;
    wire [2:0]  c  = lx[3:1];
    wire        c_in = (x >= 16'd20) && (lx < 16'd10) && in_row;
    wire [2:0]  cc = (c > 3'd4) ? 3'd4 : c;

    reg [4:0] glyph [0:79];
    integer gi;
    initial begin
        for (gi = 0; gi < 80; gi = gi + 1) glyph[gi] = 5'b00000;
        glyph[ 0]=5'b01110; glyph[ 1]=5'b10001; glyph[ 2]=5'b10001;
        glyph[ 3]=5'b10001; glyph[ 4]=5'b10001; glyph[ 5]=5'b10001; glyph[ 6]=5'b01110;
        glyph[ 8]=5'b00100; glyph[ 9]=5'b01100; glyph[10]=5'b00100;
        glyph[11]=5'b00100; glyph[12]=5'b00100; glyph[13]=5'b00100; glyph[14]=5'b01110;
        glyph[16]=5'b01110; glyph[17]=5'b10001; glyph[18]=5'b00001;
        glyph[19]=5'b00010; glyph[20]=5'b00100; glyph[21]=5'b01000; glyph[22]=5'b11111;
        glyph[24]=5'b11111; glyph[25]=5'b00010; glyph[26]=5'b00100;
        glyph[27]=5'b00010; glyph[28]=5'b00001; glyph[29]=5'b10001; glyph[30]=5'b01110;
        glyph[32]=5'b00010; glyph[33]=5'b00110; glyph[34]=5'b01010;
        glyph[35]=5'b10010; glyph[36]=5'b11111; glyph[37]=5'b00010; glyph[38]=5'b00010;
        glyph[40]=5'b11111; glyph[41]=5'b10000; glyph[42]=5'b11110;
        glyph[43]=5'b00001; glyph[44]=5'b00001; glyph[45]=5'b10001; glyph[46]=5'b01110;
        glyph[48]=5'b00110; glyph[49]=5'b01000; glyph[50]=5'b10000;
        glyph[51]=5'b11110; glyph[52]=5'b10001; glyph[53]=5'b10001; glyph[54]=5'b01110;
        glyph[56]=5'b11111; glyph[57]=5'b00001; glyph[58]=5'b00010;
        glyph[59]=5'b00100; glyph[60]=5'b01000; glyph[61]=5'b01000; glyph[62]=5'b01000;
        glyph[64]=5'b01110; glyph[65]=5'b10001; glyph[66]=5'b10001;
        glyph[67]=5'b01110; glyph[68]=5'b10001; glyph[69]=5'b10001; glyph[70]=5'b01110;
        glyph[72]=5'b01110; glyph[73]=5'b10001; glyph[74]=5'b10001;
        glyph[75]=5'b01111; glyph[76]=5'b00001; glyph[77]=5'b00010; glyph[78]=5'b01100;
    end

    wire [6:0] gidx = {pval, row};
    wire digit_on = c_in && glyph[gidx][3'd4 - cc];
    wire swatch_on = (x >= 16'd8) && (x < 16'd16) &&
                     (y >= line_y0) && (y < (line_y0 + 16'd8));

    reg [23:0] rgb_comb;
    always @(*) begin
        rgb_comb = rgb_in;
        if (de_in && alarm_border)
            rgb_comb = RED;
        else if (de_in && box_hit)
            rgb_comb = state_color;
        else if (de_in && panel_x && line_ok) begin
            if (digit_on)
                rgb_comb = pcolor;
            else if (swatch_on)
                rgb_comb = plit ? pcolor : C_BG;
            else
                rgb_comb = C_BG;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rgb_out <= 24'd0;
            de_out <= 1'b0; hs_out <= 1'b0; vs_out <= 1'b0;
        end else begin
            rgb_out <= rgb_comb;
            de_out <= de_in; hs_out <= hs_in; vs_out <= vs_in;
        end
    end
endmodule
