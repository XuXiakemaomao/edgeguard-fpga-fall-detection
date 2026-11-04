`timescale 1ns / 1ps
// shake_gate
// 功能：背景初始化完成前抑制前景掩码
// 输入：clk、rst_n、de_in、hs_in、vs_in、fg_mask_in等
// 输出：de_out、hs_out、vs_out、fg_mask、pix_out
module shake_gate #(
    parameter W = 640,
    parameter H = 360,
    parameter ENABLE_SCENE_GATE = 1
)(
    input  wire clk,
    input  wire rst_n,
    input  wire de_in,
    input  wire hs_in,
    input  wire vs_in,
    input  wire fg_mask_in,
    input  wire scene_change,
    input  wire initialized,
    input  wire [31:0] pix_in,
    output reg  de_out,
    output reg  hs_out,
    output reg  vs_out,
    output reg  fg_mask,
    output wire [31:0] pix_out
);
    wire ready = initialized && (!ENABLE_SCENE_GATE || !scene_change);
    reg [31:0] pix_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_r <= 0;
            de_out <= 0; hs_out <= 0; vs_out <= 0; fg_mask <= 0;
        end else begin
            pix_r <= pix_in;
            de_out <= de_in;
            hs_out <= hs_in;
            vs_out <= vs_in;
            fg_mask <= de_in && ready && fg_mask_in;
        end
    end
    assign pix_out = pix_r;
    wire _unused = (W == 0) || (H == 0);
endmodule
