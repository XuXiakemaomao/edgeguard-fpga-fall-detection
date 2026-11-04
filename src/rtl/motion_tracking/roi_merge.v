`timescale 1ns / 1ps
// roi_merge
// 功能：块级连通域提取，生成候选目标框
// 输入：clk、rst_n、block_state、block_valid
// 输出：roi_done、roi_num、roi_boxes
module roi_merge #(
    parameter NC          = 40,
    parameter NR          = 24,
    parameter BW          = 16,
    parameter BH          = 15,
    parameter MAX_ROI     = 4,
    parameter MIN_BLOCKS  = 8,
    parameter MIN_WIDTH   = 2,
    parameter MIN_HEIGHT  = 2,
    parameter MAX_BLOCKS  = 576,
    parameter MIN_DENSITY_PERCENT = 15
)(
    input  wire clk,
    input  wire rst_n,
    input  wire [NC*NR-1:0] block_state,
    input  wire             block_valid,
    output reg              roi_done,
    output reg  [3:0]       roi_num,
    output reg  [MAX_ROI*48-1:0] roi_boxes
);
    localparam NB = NC * NR;
    localparam SW = ($clog2(NB) > 0) ? $clog2(NB) : 1;
    localparam CW = ($clog2(NC) > 0) ? $clog2(NC) : 1;
    localparam RW = ($clog2(NR) > 0) ? $clog2(NR) : 1;

    localparam S_IDLE     = 3'd0;
    localparam S_SEEK     = 3'd1;
    localparam S_EXPAND   = 3'd2;
    localparam S_EXP_SCAN = 3'd3;
    localparam S_EXP_END  = 3'd4;
    localparam S_OUT      = 3'd5;

    reg [2:0] state;
    reg [NB-1:0] block_reg;
    reg [NB-1:0] visited;
    reg [NB-1:0] frontier;
    reg [NB-1:0] frontier_next;

    reg [RW-1:0] seek_row;
    reg [CW-1:0] seek_col;
    reg [RW-1:0] seed_row;
    reg [CW-1:0] seed_col;

    reg [RW-1:0] scan_row;
    reg [CW-1:0] scan_col;
    reg         added_any;

    reg [9:0]    comp_area;
    reg [CW-1:0] comp_x0;
    reg [CW-1:0] comp_x1;
    reg [RW-1:0] comp_y0;
    reg [RW-1:0] comp_y1;

    // Candidate list kept sorted by descending component area.
    reg [3:0]    cand_num;
    reg [9:0]    cand_area [0:MAX_ROI-1];
    reg [CW-1:0] cand_x0   [0:MAX_ROI-1];
    reg [CW-1:0] cand_x1   [0:MAX_ROI-1];
    reg [RW-1:0] cand_y0   [0:MAX_ROI-1];
    reg [RW-1:0] cand_y1   [0:MAX_ROI-1];

    wire          seek_in_range = (seek_row < NR);
    wire [SW-1:0] seek_idx_raw = (seek_row * NC) + seek_col;
    wire [SW-1:0] seek_idx = seek_in_range ? seek_idx_raw : {SW{1'b0}};
    wire [SW-1:0] scan_idx = (scan_row * NC) + scan_col;
    wire [NB-1:0] seed_one = {{(NB-1){1'b0}}, 1'b1} << seek_idx;

    wire [SW-1:0] idx_n  = (scan_row != 0) ? (scan_idx - NC) : {SW{1'b0}};
    wire [SW-1:0] idx_s  = (scan_row != NR-1) ? (scan_idx + NC) : {SW{1'b0}};
    wire [SW-1:0] idx_w  = (scan_col != 0) ? (scan_idx - 1'b1) : {SW{1'b0}};
    wire [SW-1:0] idx_e  = (scan_col != NC-1) ? (scan_idx + 1'b1) : {SW{1'b0}};
    wire [SW-1:0] idx_nw = ((scan_row != 0) && (scan_col != 0)) ?
                           (scan_idx - NC - 1'b1) : {SW{1'b0}};
    wire [SW-1:0] idx_ne = ((scan_row != 0) && (scan_col != NC-1)) ?
                           (scan_idx - NC + 1'b1) : {SW{1'b0}};
    wire [SW-1:0] idx_sw = ((scan_row != NR-1) && (scan_col != 0)) ?
                           (scan_idx + NC - 1'b1) : {SW{1'b0}};
    wire [SW-1:0] idx_se = ((scan_row != NR-1) && (scan_col != NC-1)) ?
                           (scan_idx + NC + 1'b1) : {SW{1'b0}};

    wire has_n  = (scan_row != 0) && frontier[idx_n];
    wire has_s  = (scan_row != NR-1) && frontier[idx_s];
    wire has_w  = (scan_col != 0) && frontier[idx_w];
    wire has_e  = (scan_col != NC-1) && frontier[idx_e];
    wire has_nw = (scan_row != 0) && (scan_col != 0) && frontier[idx_nw];
    wire has_ne = (scan_row != 0) && (scan_col != NC-1) && frontier[idx_ne];
    wire has_sw = (scan_row != NR-1) && (scan_col != 0) && frontier[idx_sw];
    wire has_se = (scan_row != NR-1) && (scan_col != NC-1) && frontier[idx_se];
    wire has_frontier_neighbor =
        has_n | has_s | has_w | has_e | has_nw | has_ne | has_sw | has_se;

    wire add_cell = block_reg[scan_idx] && !visited[scan_idx] &&
                    has_frontier_neighbor;

    // Insertion point for a newly completed component. The list is sorted
    // largest first; ties keep the earlier component.
    reg [3:0] insert_pos;
    reg       insert_ok;
    integer j;
    always @(*) begin
        insert_pos = MAX_ROI;
        insert_ok  = 1'b0;
        for (j = 0; j < MAX_ROI; j = j + 1) begin
            if (!insert_ok && (comp_area > cand_area[j])) begin
                insert_pos = j;
                insert_ok  = 1'b1;
            end
        end
        if (!insert_ok && (cand_num < MAX_ROI)) begin
            insert_pos = cand_num;
            insert_ok  = 1'b1;
        end
    end

    wire [5:0] comp_width  = comp_x1 - comp_x0 + 1'b1;
    wire [5:0] comp_height = comp_y1 - comp_y0 + 1'b1;
    wire [11:0] comp_bbox_area = comp_width * comp_height;
    wire [17:0] comp_scaled = comp_area * 100;
    wire [17:0] bbox_scaled = comp_bbox_area * MIN_DENSITY_PERCENT;
    wire comp_density_ok = comp_scaled >= bbox_scaled;
    wire comp_filter_ok =
        (comp_area >= MIN_BLOCKS) &&
        (comp_area <= MAX_BLOCKS) &&
        (comp_width >= MIN_WIDTH) &&
        (comp_height >= MIN_HEIGHT) &&
        comp_density_ok;

    wire [11:0] out_x0 [0:MAX_ROI-1];
    wire [11:0] out_y0 [0:MAX_ROI-1];
    wire [11:0] out_x1 [0:MAX_ROI-1];
    wire [11:0] out_y1 [0:MAX_ROI-1];
    genvar g;
    generate
        for (g = 0; g < MAX_ROI; g = g + 1) begin : GEN_SCALE
            assign out_x0[g] = {6'd0, cand_x0[g]} * BW;
            assign out_y0[g] = {6'd0, cand_y0[g]} * BH;
            assign out_x1[g] = {6'd0, cand_x1[g]} * BW + (BW-1);
            assign out_y1[g] = {6'd0, cand_y1[g]} * BH + (BH-1);
        end
    endgenerate

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            block_reg <= {NB{1'b0}};
            visited <= {NB{1'b0}};
            frontier <= {NB{1'b0}};
            frontier_next <= {NB{1'b0}};
            seek_row <= {RW{1'b0}};
            seek_col <= {CW{1'b0}};
            seed_row <= {RW{1'b0}};
            seed_col <= {CW{1'b0}};
            scan_row <= {RW{1'b0}};
            scan_col <= {CW{1'b0}};
            added_any <= 1'b0;
            comp_area <= 10'd0;
            comp_x0 <= {CW{1'b0}};
            comp_x1 <= {CW{1'b0}};
            comp_y0 <= {RW{1'b0}};
            comp_y1 <= {RW{1'b0}};
            cand_num <= 4'd0;
            roi_done <= 1'b0;
            roi_num <= 4'd0;
            roi_boxes <= {MAX_ROI*48{1'b0}};
            for (k = 0; k < MAX_ROI; k = k + 1) begin
                cand_area[k] <= 10'd0;
                cand_x0[k] <= {CW{1'b0}};
                cand_x1[k] <= {CW{1'b0}};
                cand_y0[k] <= {RW{1'b0}};
                cand_y1[k] <= {RW{1'b0}};
            end
        end else begin
            roi_done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (block_valid) begin
                        block_reg <= block_state;
                        visited <= {NB{1'b0}};
                        frontier <= {NB{1'b0}};
                        frontier_next <= {NB{1'b0}};
                        seek_row <= {RW{1'b0}};
                        seek_col <= {CW{1'b0}};
                        cand_num <= 4'd0;
                        for (k = 0; k < MAX_ROI; k = k + 1) begin
                            cand_area[k] <= 10'd0;
                            cand_x0[k] <= {CW{1'b0}};
                            cand_x1[k] <= {CW{1'b0}};
                            cand_y0[k] <= {RW{1'b0}};
                            cand_y1[k] <= {RW{1'b0}};
                        end
                        state <= S_SEEK;
                    end
                end

                S_SEEK: begin
                    if (!seek_in_range) begin
                        state <= S_OUT;
                    end else if (block_reg[seek_idx] && !visited[seek_idx]) begin
                        seed_row <= seek_row;
                        seed_col <= seek_col;
                        visited[seek_idx] <= 1'b1;
                        frontier <= seed_one;
                        comp_area <= 10'd1;
                        comp_x0 <= seek_col;
                        comp_x1 <= seek_col;
                        comp_y0 <= seek_row;
                        comp_y1 <= seek_row;
                        state <= S_EXPAND;
                    end else if (seek_col == NC-1) begin
                        seek_col <= {CW{1'b0}};
                        if (seek_row == NR-1)
                            state <= S_OUT;
                        else
                            seek_row <= seek_row + 1'b1;
                    end else begin
                        seek_col <= seek_col + 1'b1;
                    end
                end

                S_EXPAND: begin
                    frontier_next <= {NB{1'b0}};
                    added_any <= 1'b0;
                    scan_row <= {RW{1'b0}};
                    scan_col <= {CW{1'b0}};
                    state <= S_EXP_SCAN;
                end

                S_EXP_SCAN: begin
                    if (add_cell) begin
                        visited[scan_idx] <= 1'b1;
                        frontier_next[scan_idx] <= 1'b1;
                        added_any <= 1'b1;
                        comp_area <= comp_area + 1'b1;
                        if (scan_col < comp_x0) comp_x0 <= scan_col;
                        if (scan_col > comp_x1) comp_x1 <= scan_col;
                        if (scan_row < comp_y0) comp_y0 <= scan_row;
                        if (scan_row > comp_y1) comp_y1 <= scan_row;
                    end

                    if (scan_col == NC-1) begin
                        scan_col <= {CW{1'b0}};
                        if (scan_row == NR-1)
                            state <= S_EXP_END;
                        else
                            scan_row <= scan_row + 1'b1;
                    end else begin
                        scan_col <= scan_col + 1'b1;
                    end
                end

                S_EXP_END: begin
                    if (added_any) begin
                        frontier <= frontier_next;
                        state <= S_EXPAND;
                    end else begin
                        if (comp_filter_ok && insert_ok) begin
                            for (k = MAX_ROI-1; k > 0; k = k - 1) begin
                                if (k > insert_pos) begin
                                    cand_area[k] <= cand_area[k-1];
                                    cand_x0[k]   <= cand_x0[k-1];
                                    cand_x1[k]   <= cand_x1[k-1];
                                    cand_y0[k]   <= cand_y0[k-1];
                                    cand_y1[k]   <= cand_y1[k-1];
                                end
                            end
                            cand_area[insert_pos] <= comp_area;
                            cand_x0[insert_pos]   <= comp_x0;
                            cand_x1[insert_pos]   <= comp_x1;
                            cand_y0[insert_pos]   <= comp_y0;
                            cand_y1[insert_pos]   <= comp_y1;
                            if (cand_num < MAX_ROI)
                                cand_num <= cand_num + 1'b1;
                        end

                        // The seed was the first active, unvisited cell from the
                        // current seek position. Resume immediately after it.
                        if (seed_col == NC-1) begin
                            seek_col <= {CW{1'b0}};
                            seek_row <= seed_row + 1'b1;
                        end else begin
                            seek_col <= seed_col + 1'b1;
                            seek_row <= seed_row;
                        end
                        state <= S_SEEK;
                    end
                end

                S_OUT: begin
                    roi_num <= cand_num;
                    roi_boxes <= {MAX_ROI*48{1'b0}};
                    for (k = 0; k < MAX_ROI; k = k + 1) begin
                        if (k < cand_num)
                            roi_boxes[k*48 +: 48] <= {
                                out_x0[k],
                                out_y0[k],
                                out_x1[k],
                                out_y1[k]
                            };
                        else
                            roi_boxes[k*48 +: 48] <= 48'd0;
                    end
                    roi_done <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
