`timescale 1ns / 1ps
// video_input_monitor
// 功能：检测输入视频宽度和高度
// 输入：clk、rst_n、de_in、hs_in、vs_in
// 输出：input_ok、measured_width、measured_height、frame_heartbeat、frame_counter
module video_input_monitor #(
    parameter EXPECT_W = 1280,
    parameter EXPECT_H = 720,
    parameter GOOD_FRAMES = 2,
    parameter TIMEOUT_CYCLES = 5000000
)(
    input  wire clk,
    input  wire rst_n,
    input  wire de_in,
    input  wire hs_in,
    input  wire vs_in,
    output reg  input_ok,
    output reg [11:0] measured_width,
    output reg [11:0] measured_height,
    output reg frame_heartbeat,
    output reg [31:0] frame_counter
);
    reg de_d, vs_d;
    wire de_rise = de_in && !de_d;
    wire de_fall = !de_in && de_d;
    wire vs_rise = vs_in && !vs_d;

    reg [11:0] line_pixels;
    reg [11:0] frame_lines;
    reg width_error;
    reg frame_seen;
    reg [7:0] good_count;
    reg [31:0] timeout_count;
    wire previous_frame_good = frame_seen && !width_error &&
                               (frame_lines == EXPECT_H) &&
                               (measured_width == EXPECT_W);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_d <= 0; vs_d <= 0;
            line_pixels <= 0; frame_lines <= 0;
            width_error <= 0; frame_seen <= 0; good_count <= 0;
            input_ok <= 0; measured_width <= 0; measured_height <= 0;
            frame_heartbeat <= 0; frame_counter <= 0;
            timeout_count <= 0;
        end else begin
            de_d <= de_in;
            vs_d <= vs_in;

            if (vs_rise) begin
                measured_height <= frame_lines;
                frame_heartbeat <= ~frame_heartbeat;
                frame_counter <= frame_counter + 1'b1;
                timeout_count <= 0;
                if (previous_frame_good) begin
                    if (good_count < GOOD_FRAMES) good_count <= good_count + 1'b1;
                    if (good_count >= GOOD_FRAMES-1) input_ok <= 1'b1;
                end else if (frame_seen) begin
                    good_count <= 0;
                    input_ok <= 1'b0;
                end
                frame_seen <= 1'b1;
                frame_lines <= 0;
                width_error <= 1'b0;
                if (de_in) line_pixels <= 12'd1;
                else line_pixels <= 0;
            end else begin
                if (timeout_count < TIMEOUT_CYCLES)
                    timeout_count <= timeout_count + 1'b1;
                else begin
                    input_ok <= 1'b0;
                    good_count <= 0;
                end

                if (de_rise) begin
                    line_pixels <= 12'd1;
                end else if (de_in) begin
                    if (line_pixels != 12'hfff)
                        line_pixels <= line_pixels + 1'b1;
                end

                if (de_fall) begin
                    measured_width <= line_pixels;
                    frame_lines <= frame_lines + 1'b1;
                    if (line_pixels != EXPECT_W) begin
                        width_error <= 1'b1;
                        input_ok <= 1'b0;
                        good_count <= 0;
                    end
                end
            end
        end
    end

    wire _unused_hs = hs_in;
endmodule
