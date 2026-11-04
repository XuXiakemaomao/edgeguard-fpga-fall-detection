`timescale 1ns / 1ps
// scans
// 输入：dist_matrix、dist_threshold、prev_valid_mask、cur_num、clk、rst_n等
// 输出：matched_idx、match_valid、min_dist、match_done
// This module scans the whole distance matrix in multiple passes. Each pass
// takes the globally smallest available (current ROI, history track) pair,
// then removes both from the candidate set. One current ROI can match at most
// one history track and vice versa. The matrix is only 4x8, so the frame-level
// scan cost is small compared with the video blanking interval.
module match_machine #(
    parameter MAX_ROI   = 4,
    parameter MAX_TRACK = 8,
    parameter DIST_W    = 13,
    parameter IDX_W     = 3
)(
    input  wire [MAX_ROI*MAX_TRACK*DIST_W-1:0] dist_matrix,
    input  wire [DIST_W-1:0] dist_threshold,
    input  wire [MAX_TRACK-1:0] prev_valid_mask,
    input  wire [3:0] cur_num,
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    output reg [MAX_ROI*IDX_W-1:0] matched_idx,
    output reg [MAX_ROI-1:0] match_valid,
    output reg [MAX_ROI*DIST_W-1:0] min_dist,
    output reg match_done
);
    localparam S_IDLE = 2'd0;
    localparam S_SCAN = 2'd1;
    localparam S_TAKE = 2'd2;
    localparam S_NEXT = 2'd3;

    reg [1:0] state;
    reg [1:0] scan_i;
    reg [2:0] scan_j;
    reg [3:0] matched_count;
    reg [MAX_ROI-1:0] used_cur;
    reg [MAX_TRACK-1:0] used_hist;

    reg best_found;
    reg [DIST_W-1:0] best_dist;
    reg [1:0] best_i;
    reg [2:0] best_j;

    wire [DIST_W-1:0] scan_dist =
        dist_matrix[(scan_i*MAX_TRACK + scan_j)*DIST_W +: DIST_W];
    wire scan_available =
        (scan_i < cur_num) && !used_cur[scan_i] &&
        prev_valid_mask[scan_j] && !used_hist[scan_j] &&
        (scan_dist < dist_threshold);
    wire scan_better =
        scan_available &&
        (!best_found || (scan_dist < best_dist));

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            scan_i <= 2'd0;
            scan_j <= 3'd0;
            matched_count <= 4'd0;
            used_cur <= 4'd0;
            used_hist <= 8'd0;
            best_found <= 1'b0;
            best_dist <= {DIST_W{1'b1}};
            best_i <= 2'd0;
            best_j <= 3'd0;
            matched_idx <= {MAX_ROI*IDX_W{1'b0}};
            match_valid <= {MAX_ROI{1'b0}};
            min_dist <= {MAX_ROI*DIST_W{1'b1}};
            match_done <= 1'b0;
        end else begin
            match_done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        scan_i <= 2'd0;
                        scan_j <= 3'd0;
                        matched_count <= 4'd0;
                        used_cur <= 4'd0;
                        used_hist <= 8'd0;
                        best_found <= 1'b0;
                        best_dist <= {DIST_W{1'b1}};
                        matched_idx <= {MAX_ROI*IDX_W{1'b0}};
                        match_valid <= {MAX_ROI{1'b0}};
                        min_dist <= {MAX_ROI*DIST_W{1'b1}};
                        state <= S_SCAN;
                    end
                end

                S_SCAN: begin
                    if (scan_better) begin
                        best_found <= 1'b1;
                        best_dist <= scan_dist;
                        best_i <= scan_i;
                        best_j <= scan_j;
                    end

                    if ((scan_i == MAX_ROI-1) && (scan_j == MAX_TRACK-1)) begin
                        state <= S_TAKE;
                    end else if (scan_j == MAX_TRACK-1) begin
                        scan_j <= 3'd0;
                        scan_i <= scan_i + 1'b1;
                    end else begin
                        scan_j <= scan_j + 1'b1;
                    end
                end

                S_TAKE: begin
                    if (!best_found || (matched_count >= cur_num)) begin
                        match_done <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        match_valid[best_i] <= 1'b1;
                        matched_idx[best_i*IDX_W +: IDX_W] <= best_j[IDX_W-1:0];
                        min_dist[best_i*DIST_W +: DIST_W] <= best_dist;
                        used_cur[best_i] <= 1'b1;
                        used_hist[best_j] <= 1'b1;
                        matched_count <= matched_count + 1'b1;
                        state <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    scan_i <= 2'd0;
                    scan_j <= 3'd0;
                    best_found <= 1'b0;
                    best_dist <= {DIST_W{1'b1}};
                    state <= S_SCAN;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
