`timescale 1ns/1ps
// rgb2gray
// 功能：RGB 转灰度
// 输入：clk、rst_n、de_in、hs_in、vs_in、color
// 输出：gray、de_out、hs_out、vs_out、pix_out
module rgb2gray (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        de_in,      // 数据有效
    input  wire        hs_in,      // 行同步
    input  wire        vs_in,      // 场同步
    input  wire [23:0] color,      // 24 位 RGB
    output reg  [7:0]  gray,       // 灰度
    output reg         de_out,     // 以下三个比输入晚 4 拍
    output reg         hs_out,
    output reg         vs_out,
    output wire [31:0] pix_out     // 旁路输出：{color延迟4拍, gray}
);
    reg [7:0]  cl_red, cl_green, cl_blue;
    reg [15:0] per_red, per_green, per_blue, sum1;
    reg de1, de2, de3;
    reg hs1, hs2, hs3;
    reg vs1, vs2, vs3;

    // 旁路：color 延迟 4 拍，和 gray 对齐
    reg [23:0] color_d1, color_d2, color_d3, color_d4;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            color_d1<=0; color_d2<=0; color_d3<=0; color_d4<=0;
        end else begin
            color_d1<=color; color_d2<=color_d1; color_d3<=color_d2; color_d4<=color_d3;
        end
    end
    assign pix_out = {color_d4, gray};

    // 级1：取分量
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cl_red<=0; cl_green<=0; cl_blue<=0;
            de1<=0; hs1<=0; vs1<=0;
        end else begin
            cl_red<=color[23:16]; cl_green<=color[15:8]; cl_blue<=color[7:0];
            de1<=de_in; hs1<=hs_in; vs1<=vs_in;
        end
    end

    // 级2：加权乘法
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            per_red<=0; per_green<=0; per_blue<=0;
            de2<=0; hs2<=0; vs2<=0;
        end else begin
            per_red<=77*cl_red; per_green<=150*cl_green; per_blue<=29*cl_blue;
            de2<=de1; hs2<=hs1; vs2<=vs1;
        end
    end

    // 级3：求和
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum1<=0; de3<=0; hs3<=0; vs3<=0;
        end else begin
            sum1<=per_red+per_green+per_blue;
            de3<=de2; hs3<=hs2; vs3<=vs2;
        end
    end

    // 级4：移位输出
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gray<=0; de_out<=0; hs_out<=0; vs_out<=0;
        end else begin
            gray<=sum1>>8;
            de_out<=de3; hs_out<=hs3; vs_out<=vs3;
        end
    end
endmodule
