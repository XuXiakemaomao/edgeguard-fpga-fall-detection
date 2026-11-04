`timescale 1ns / 1ps
// roi_judge
// 功能：将二值掩码分块并标记前景块
// 输入：clk、rst_n、de_in、hs_in、vs_in、fg_mask_in等
// 输出：de_out、hs_out、vs_out、fg_mask、frame_end、block_state等
module roi_judge #(
    parameter W  = 640,
    parameter H  = 360,
    parameter BW = 16,
    parameter BH = 15,
    parameter MIN_MATCHES = 32
)(
    input  wire clk,
    input  wire rst_n,
    input  wire de_in,
    input  wire hs_in,
    input  wire vs_in,
    input  wire fg_mask_in,
    output reg  de_out,
    output reg  hs_out,
    output reg  vs_out,
    output reg  fg_mask,
    output reg  frame_end,
    output reg  [((W/BW)*(H/BH))-1:0] block_state,
    output reg  [9:0] dbg_block_count,
    input  wire [31:0] pix_in,
    output wire [31:0] pix_out
);
    localparam NC = W / BW;      // blocks per row
    localparam NR = H / BH;      // block rows
    localparam NB = NC * NR;
    localparam CW  = ($clog2(NC) > 0) ? $clog2(NC) : 1;  // block_col width
    localparam RW  = ($clog2(NR) > 0) ? $clog2(NR) : 1;  // block_row width
    localparam BIW = ($clog2(BW) > 0) ? $clog2(BW) : 1;  // col_in_block width
    localparam BJW = ($clog2(BH) > 0) ? $clog2(BH) : 1;  // row_in_block width

    reg [CW-1:0] block_col;
    reg [RW-1:0] block_row;
    reg [BIW-1:0] col_in_block;
    reg [BJW-1:0] row_in_block;

    wire [RW-1:0] next_block_row = (row_in_block == BH-1) ? block_row + 1'b1 : block_row;
    wire [BJW-1:0] next_row_in_block = (row_in_block == BH-1) ? {BJW{1'b0}} : row_in_block + 1'b1;

    // Coordinate state is updated after the current pixel has been classified.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            block_col <= 0; block_row <= 0;
            col_in_block <= 0; row_in_block <= 0;
        end else if (de_in) begin
            if (vs_in) begin
                block_col <= 0; block_row <= 0;
                col_in_block <= (BW > 1) ? 1'b1 : 1'b0;
                row_in_block <= 0;
            end else if (hs_in) begin
                block_col <= 0;
                col_in_block <= (BW > 1) ? 1'b1 : 1'b0;
                block_row <= next_block_row;
                row_in_block <= next_row_in_block;
            end else if (col_in_block == BW-1) begin
                col_in_block <= 0;
                block_col <= block_col + 1'b1;
            end else begin
                col_in_block <= col_in_block + 1'b1;
            end
        end
    end

    // --------------------- streaming per-block counters ---------------------
    reg [7:0] mask_ct [0:NC-1];
    integer i;

    // One-clock commit of the block-row that just completed:
    //  - frame-start marker commits the final block-row of the previous frame
    //  - an internal line marker (not frame start) with row_in_block == BH-1
    //    commits the block-row that just ended.
    wire commit_last = vs_in && de_in;
    wire commit_mid  = hs_in && de_in && (row_in_block == BH-1) && !vs_in;
    wire commit_en   = commit_last || commit_mid;
    wire [RW-1:0] commit_row = block_row;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i=0; i<NC; i=i+1) mask_ct[i] <= 8'd0;
        end else if (de_in) begin
            if (vs_in) begin
                for (i=1; i<NC; i=i+1) mask_ct[i] <= 8'd0;
                mask_ct[0] <= fg_mask_in ? 8'd1 : 8'd0;
            end else if (hs_in) begin
                if (row_in_block == BH-1) begin
                    for (i=1; i<NC; i=i+1) mask_ct[i] <= 8'd0;
                    mask_ct[0] <= fg_mask_in ? 8'd1 : 8'd0;
                end else begin
                    if (fg_mask_in && mask_ct[0] != 8'hff)
                        mask_ct[0] <= mask_ct[0] + 8'd1;
                end
            end else if (fg_mask_in && (block_col < NC) && (block_row < NR)) begin
                if (mask_ct[block_col] != 8'hff)
                    mask_ct[block_col] <= mask_ct[block_col] + 8'd1;
            end
        end
    end

    // Publish the committed block-row into block_state (one segment per row).
    wire [NC-1:0] commit_result;
    genvar g;
    generate
        for (g=0; g<NC; g=g+1) begin : GEN_CMP
            assign commit_result[g] = (mask_ct[g] >= MIN_MATCHES);
        end
        for (g=0; g<NR; g=g+1) begin : GEN_BLOCK
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    block_state[g*NC +: NC] <= {NC{1'b0}};
                else if (commit_en && commit_row == g[RW-1:0])
                    block_state[g*NC +: NC] <= commit_result;
            end
        end
    endgenerate

    // ---- 诊断：当前帧被判为运动的块数（每帧 vs_in 时锁存上一帧总数） ----
    reg  [5:0] commit_pop;
    integer bj;
    always @(*) begin
        commit_pop = 6'd0;
        for (bj = 0; bj < NC; bj = bj + 1)
            commit_pop = commit_pop + commit_result[bj];
    end
    reg [9:0] block_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            block_cnt <= 10'd0;
            dbg_block_count <= 10'd0;
        end else if (vs_in && de_in) begin
            // 最后一行 commit 与 vs_in 同拍，一起计入
            dbg_block_count <= block_cnt + {4'd0, commit_pop};
            block_cnt <= 10'd0;
        end else if (commit_en) begin
            block_cnt <= block_cnt + {4'd0, commit_pop};
        end
    end

    reg frame_active;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_active <= 1'b0;
            frame_end <= 1'b0;
        end else begin
            frame_end <= 1'b0;
            if (vs_in && de_in) begin
                if (frame_active)
                    frame_end <= 1'b1;
                frame_active <= 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_out <= 0; hs_out <= 0; vs_out <= 0; fg_mask <= 0;
        end else begin
            de_out <= de_in;
            hs_out <= hs_in;
            vs_out <= vs_in;
            fg_mask <= de_in && fg_mask_in;
        end
    end

    assign pix_out = pix_in;
endmodule
