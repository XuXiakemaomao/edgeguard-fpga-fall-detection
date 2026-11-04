`timescale 1ns / 1ps
// mask_cleanup_3x3
// 功能：3×3 邻域二值滤波，去除孤立噪点
// 输入：clk、rst_n、de_in、hs_in、vs_in、mask_in等
// 输出：mask_out、de_out、hs_out、vs_out、pix_out
module mask_cleanup_3x3 #(
    parameter W     = 640,
    parameter V_ACT = 360
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        de_in,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        mask_in,
    input  wire [2:0]  mode,
    input  wire [31:0] pix_in,
    output reg         mask_out,
    output reg         de_out,
    output reg         hs_out,
    output reg         vs_out,
    output wire [31:0] pix_out
);
    reg [15:0] x;
    reg [15:0] y;
    wire [15:0] x_cur = (vs_in || hs_in) ? 16'd0 : x;
    wire [15:0] y_cur = vs_in ? 16'd0 : (hs_in ? y + 16'd1 : y);
    wire in_range = (x_cur < W) && (y_cur < V_ACT);

    // At column x, line_1/line_2 still contain the two preceding rows before
    // this clock edge.  No RAM reset is used so Vivado may infer memories.
    (* ram_style = "distributed" *) reg line_1 [0:W-1];
    (* ram_style = "distributed" *) reg line_2 [0:W-1];

    reg top_1, top_2;
    reg mid_1, mid_2;
    reg bot_1, bot_2;
    wire top_0 = (x_cur < W) ? line_2[x_cur] : 1'b0;
    wire mid_0 = (x_cur < W) ? line_1[x_cur] : 1'b0;
    wire [3:0] window_sum = top_2 + top_1 + top_0 +
                            mid_2 + mid_1 + mid_0 +
                            bot_2 + bot_1 + mask_in;

    reg filtered;
    always @(*) begin
        case (mode)
            3'd0: filtered = mid_1;                 // causal bypass (1,1 delay)
            3'd1: filtered = (window_sum >= 4'd5);  // 5-of-9 majority
            3'd2: filtered = (window_sum == 4'd9);  // erosion
            3'd3: filtered = (window_sum != 4'd0);  // dilation
            3'd4: filtered = (window_sum == 4'd9);  // conservative fallback
            3'd5: filtered = (window_sum != 4'd0);
            default: filtered = mid_1;
        endcase
    end

    always @(posedge clk) begin
        if (de_in && in_range) begin
            line_1[x_cur] <= mask_in;
            line_2[x_cur] <= line_1[x_cur];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x <= 0;
            y <= 0;
            top_1 <= 0; top_2 <= 0;
            mid_1 <= 0; mid_2 <= 0;
            bot_1 <= 0; bot_2 <= 0;
            mask_out <= 0;
            de_out <= 0;
            hs_out <= 0;
            vs_out <= 0;
        end else begin
            de_out <= de_in;
            hs_out <= hs_in;
            vs_out <= vs_in;
            mask_out <= (de_in && in_range && x_cur >= 2 && y_cur >= 2) ? filtered : 1'b0;

            if (de_in && in_range) begin
                if (vs_in) begin
                    x <= (W > 1) ? 16'd1 : 16'd0;
                    y <= 0;
                end else if (hs_in) begin
                    x <= (W > 1) ? 16'd1 : 16'd0;
                    y <= (y == V_ACT-1) ? 16'd0 : y + 16'd1;
                end else if (x == W-1) begin
                    x <= 0;
                end else begin
                    x <= x + 16'd1;
                end

                top_2 <= top_1; top_1 <= top_0;
                mid_2 <= mid_1; mid_1 <= mid_0;
                bot_2 <= bot_1; bot_1 <= mask_in;
            end
        end
    end

    assign pix_out = pix_in;
endmodule
