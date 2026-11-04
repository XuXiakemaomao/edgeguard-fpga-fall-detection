`timescale 1ns / 1ps
// downsample_2x2
// 功能：2×2 灰度下采样
// 输入：clk、rst_n、de_in、hs_in、vs_in、gray_in
// 输出：de_out、hs_out、vs_out、gray_out
module downsample_2x2 #(
    parameter W_IN = 1280,
    parameter H_IN = 720
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       de_in,
    input  wire       hs_in,
    input  wire       vs_in,
    input  wire [7:0] gray_in,
    output reg        de_out,
    output reg        hs_out,
    output reg        vs_out,
    output reg  [7:0] gray_out
);
    localparam W_OUT = W_IN / 2;

    reg de_d, vs_d;
    reg frame_pending;
    reg [15:0] row, col;
    wire de_rise = de_in & ~de_d;
    wire vs_rise = vs_in & ~vs_d;
    wire frame_start_now = de_rise & (frame_pending | vs_rise);
    wire [15:0] row_cur = de_rise ? ((frame_pending | vs_rise) ? 16'd0 : row + 16'd1) : row;
    wire [15:0] col_cur = de_rise ? 16'd0 : col;

    reg [7:0] even_lo, odd_lo;
    (* ram_style = "block" *) reg [15:0] pair_ram [0:W_OUT-1];
    reg [15:0] pair_dout;

    wire even_row = ~row_cur[0];
    wire odd_row  =  row_cur[0];
    wire even_col = ~col_cur[0];
    wire odd_col  =  col_cur[0];
    wire [15:0] block_idx = col_cur >> 1;
    wire pair_we = rst_n && de_in && even_row && odd_col && (block_idx < W_OUT);
    wire pair_re = de_in && odd_row  && even_col && (block_idx < W_OUT);
    wire [15:0] pair_wdata = {gray_in, even_lo};

    wire valid_s0 = de_in && odd_row && odd_col && (col_cur < W_IN) && (row_cur < H_IN);
    wire hs_s0 = valid_s0 && (col_cur == 16'd1);
    wire vs_s0 = hs_s0 && (row_cur == 16'd1);

    always @(posedge clk) begin
        if (pair_we) pair_ram[block_idx] <= pair_wdata;
        if (pair_re) pair_dout <= pair_ram[block_idx];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_d <= 1'b0;
            vs_d <= 1'b0;
            frame_pending <= 1'b1;
            row <= 16'd0;
            col <= 16'd0;
            even_lo <= 8'd0;
            odd_lo <= 8'd0;
        end else begin
            de_d <= de_in;
            vs_d <= vs_in;
            if (vs_rise) frame_pending <= 1'b1;

            if (de_in) begin
                if (even_row && even_col) even_lo <= gray_in;
                if (odd_row  && even_col) odd_lo  <= gray_in;

                if (de_rise) begin
                    row <= (frame_pending | vs_rise) ? 16'd0 : row + 16'd1;
                    col <= 16'd1;
                    if (frame_pending | vs_rise) frame_pending <= 1'b0;
                end else begin
                    col <= col + 16'd1;
                end
            end
        end
    end

    reg [7:0] prev_hi_s1, prev_lo_s1, odd_hi_s1, odd_lo_s1;
    reg valid_s1, hs_s1, vs_s1;
    reg [9:0] sum01_s2, sum23_s2;
    reg valid_s2, hs_s2, vs_s2;
    reg [10:0] sum_s3;
    reg valid_s3, hs_s3, vs_s3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_hi_s1 <= 0; prev_lo_s1 <= 0; odd_hi_s1 <= 0; odd_lo_s1 <= 0;
            valid_s1 <= 0; hs_s1 <= 0; vs_s1 <= 0;
            sum01_s2 <= 0; sum23_s2 <= 0; valid_s2 <= 0; hs_s2 <= 0; vs_s2 <= 0;
            sum_s3 <= 0; valid_s3 <= 0; hs_s3 <= 0; vs_s3 <= 0;
            gray_out <= 0; de_out <= 0; hs_out <= 0; vs_out <= 0;
        end else begin
            prev_hi_s1 <= pair_dout[15:8];
            prev_lo_s1 <= pair_dout[7:0];
            odd_hi_s1  <= gray_in;
            odd_lo_s1  <= odd_lo;
            valid_s1 <= valid_s0;
            hs_s1 <= hs_s0;
            vs_s1 <= vs_s0;

            sum01_s2 <= {2'b0, prev_hi_s1} + {2'b0, prev_lo_s1};
            sum23_s2 <= {2'b0, odd_hi_s1}  + {2'b0, odd_lo_s1};
            valid_s2 <= valid_s1;
            hs_s2 <= hs_s1;
            vs_s2 <= vs_s1;

            sum_s3 <= {1'b0, sum01_s2} + {1'b0, sum23_s2};
            valid_s3 <= valid_s2;
            hs_s3 <= hs_s2;
            vs_s3 <= vs_s2;

            gray_out <= sum_s3[9:2];
            de_out <= valid_s3;
            hs_out <= hs_s3;
            vs_out <= vs_s3;
        end
    end

    wire _unused_hs = hs_in;
    wire _unused_frame_start = frame_start_now;
endmodule
