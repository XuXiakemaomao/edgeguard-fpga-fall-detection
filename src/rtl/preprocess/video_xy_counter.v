`timescale 1ns / 1ps
// video_xy_counter
// 功能：生成活动像素坐标
// 输入：clk、rst_n、de_in、hs_in、vs_in
// 输出：x、y、line_start、frame_start
module video_xy_counter #(
    parameter W = 1280,
    parameter H = 720
)(
    input  wire clk,
    input  wire rst_n,
    input  wire de_in,
    input  wire hs_in,
    input  wire vs_in,
    output wire [15:0] x,
    output wire [15:0] y,
    output wire line_start,
    output wire frame_start
);
    reg de_d, vs_d;
    reg frame_pending;
    reg [15:0] x_reg, y_reg;
    wire vs_rise = vs_in && !vs_d;
    assign line_start = de_in && !de_d;
    assign frame_start = line_start && (frame_pending || vs_rise);
    assign x = line_start ? 16'd0 : x_reg;
    assign y = line_start ? ((frame_pending || vs_rise) ? 16'd0 :
                             ((y_reg == H-1) ? 16'd0 : y_reg + 16'd1)) : y_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_d <= 0; vs_d <= 0; frame_pending <= 1'b1;
            x_reg <= 0; y_reg <= 0;
        end else begin
            de_d <= de_in;
            vs_d <= vs_in;
            if (vs_rise) frame_pending <= 1'b1;
            if (de_in) begin
                if (line_start) begin
                    x_reg <= (W > 1) ? 16'd1 : 16'd0;
                    if (frame_pending || vs_rise) begin
                        y_reg <= 0;
                        frame_pending <= 1'b0;
                    end else begin
                        y_reg <= (y_reg == H-1) ? 16'd0 : y_reg + 16'd1;
                    end
                end else if (x_reg == W-1) begin
                    x_reg <= 0;
                end else begin
                    x_reg <= x_reg + 16'd1;
                end
            end
        end
    end
    wire _unused_hs = hs_in;
endmodule
