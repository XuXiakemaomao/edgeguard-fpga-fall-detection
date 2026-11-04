`timescale 1ns/1ps
// dpram_8
// 功能：单写单读的 8 位双口存储
// 输入：clk、we、waddr、wdata、re、raddr
// 输出：rdata
module dpram_8 #(
    parameter AW = 18
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [7:0]    wdata,
    input  wire          re,
    input  wire [AW-1:0] raddr,
    output reg  [7:0]    rdata
);
    reg [7:0] mem [0:(1<<AW)-1];
    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        if (re) rdata <= mem[raddr];
    end
endmodule
