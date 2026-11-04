`timescale 1ns/1ps
// qin_rom
// 功能：输入量化查找表
// 输入：clk、addr
// 输出：data
module qin_rom (
    input  wire       clk,
    input  wire [7:0] addr,
    output reg  [7:0] data
);
    reg [7:0] rom [0:255];
    initial $readmemh("../../../weights/qin.mem", rom);
    always @(posedge clk) data <= rom[addr];
endmodule
