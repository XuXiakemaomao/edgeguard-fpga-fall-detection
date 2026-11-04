`timescale 1ns / 1ps
// background_adaptive
// 功能：自适应背景建模，用背景样本和前一帧样本判断运动并吸收静止前景
// 输入：clk、rst_n、de_in、hs_in、vs_in、gray_in等
// 输出：fg_mask、scene_change、initialized、de_out、hs_out、vs_out等
module background_adaptive #(
    parameter W              = 640,
    parameter H              = 360,
    parameter N              = 4,
    parameter MATCH_DIST     = 20,
    parameter MIN_MATCHES    = 2,
    parameter CHANGE_PERCENT = 80,
    parameter PERCENT        = 80,
    parameter TH_MIN         = 8,
    parameter TH_MAX         = 30,
    parameter ABSORB_PERIOD  = 90,     // 每 90 帧(约1.5s@60Hz)检查一次静止前景
    parameter STATIC_FRAMES  = 30      // 连续 30 帧(约0.5s)无运动才允许吸收
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        de_in,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire [7:0]  gray_in,
    output reg         fg_mask,
    output reg         scene_change,
    output reg         initialized,
    output reg         de_out,
    output reg         hs_out,
    output reg         vs_out,
    output reg         frame_end,
    output reg  [7:0]  threshold,
    output reg         threshold_valid,
    output wire [17:0] dbg_fg_count,
    input  wire [31:0] pix_in,
    output wire [31:0] pix_out
);
    localparam RW = ($clog2(H) > 0) ? $clog2(H) : 1;   // row width
    localparam CW = ($clog2(W) > 0) ? $clog2(W) : 1;   // col width
    localparam AW = RW + CW;                            // linear pixel address
    localparam [AW-1:0] W_A = W;

    reg [RW-1:0] row;
    reg [CW-1:0] col;
    wire [RW-1:0] row_cur = vs_in ? {RW{1'b0}} : (hs_in ? row + 1'b1 : row);
    wire [CW-1:0] col_cur = (vs_in || hs_in) ? {CW{1'b0}} : col;
    wire [AW-1:0] addr = row_cur * W_A + {{(AW-CW){1'b0}}, col_cur};

    (* ram_style = "block" *) reg [15:0] mem [0:W*H-1];

    reg [15:0] read_word;
    reg [7:0] gray_d1;
    reg de_d1, hs_d1, vs_d1;
    reg [AW-1:0] addr_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row <= 0; col <= 0;
        end else if (de_in) begin
            if (vs_in) begin
                row <= 0;
                col <= (W > 1) ? 1'b1 : 1'b0;
            end else if (hs_in) begin
                row <= (row == H-1) ? {RW{1'b0}} : row + 1'b1;
                col <= (W > 1) ? 1'b1 : 1'b0;
            end else if (col == W-1) begin
                col <= 0;
            end else begin
                col <= col + 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if (de_in && addr < W*H) read_word <= mem[addr];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gray_d1 <= 0; de_d1 <= 0; hs_d1 <= 0; vs_d1 <= 0; addr_d1 <= 0;
        end else begin
            de_d1 <= de_in;
            hs_d1 <= hs_in;
            vs_d1 <= vs_in;
            if (de_in) begin
                gray_d1 <= gray_in;
                addr_d1 <= addr;
            end
        end
    end

    reg [3:0] frame_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_cnt <= 0;
            initialized <= 0;
        end else if (vs_in && de_in) begin
            if (frame_cnt < N) frame_cnt <= frame_cnt + 1'b1;
            else initialized <= 1'b1;
        end
    end

    wire [7:0] d_bg   = (gray_d1 >= read_word[15:8]) ? gray_d1-read_word[15:8] : read_word[15:8]-gray_d1;
    wire [7:0] d_prev = (gray_d1 >= read_word[7:0])  ? gray_d1-read_word[7:0]  : read_word[7:0]-gray_d1;
    wire fg_comb     = d_bg   > threshold;   // 相对背景的前景(存在性)
    wire motion_comb = d_prev > threshold;   // 相对上一帧的运动

    reg [15:0] absorb_cnt;
    reg        absorb_mode;
    reg        motion_seen;      // 本帧是否出现运动
    reg [15:0] static_cnt;       // 连续无运动帧数
    wire       scene_static = (static_cnt >= STATIC_FRAMES);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            absorb_cnt  <= 16'd0;
            absorb_mode <= 1'b0;
            motion_seen <= 1'b0;
            static_cnt  <= 16'd0;
        end else if (vs_out) begin
            // 帧边界：结算上一帧的运动情况
            static_cnt <= motion_seen ? 16'd0 :
                          ((static_cnt < STATIC_FRAMES) ? static_cnt + 1'b1 : static_cnt);
            motion_seen <= 1'b0;
            if (absorb_cnt >= ABSORB_PERIOD-1) begin
                absorb_cnt  <= 16'd0;
                absorb_mode <= 1'b1;
            end else begin
                absorb_cnt  <= absorb_cnt + 1'b1;
                absorb_mode <= 1'b0;
            end
        end else if (de_d1 && motion_comb) begin
            motion_seen <= 1'b1;
        end
    end

    // 只有"整帧连续 STATIC_FRAMES 帧没有运动"时才允许吸收静止前景。
    // 运动中的物体内部是均匀色、逐像素帧差为 0，若只看 !motion_comb 会把
    // 它的内部吸进背景，随后留下白色拖影，这正是 v7.1 首版红框拉长/分裂的
    // 原因。整帧运动门控保证只要画面里还有运动，就完全不吸收。
    wire update_bg = !initialized || !fg_comb || scene_change ||
                     (absorb_mode && scene_static && !motion_comb);
    wire [7:0] bg_next = update_bg ? gray_d1 : read_word[15:8];
    // prev 每帧都写当前像素，保证帧差始终是真正的相邻帧差。
    wire [15:0] write_word = {bg_next, gray_d1};

    // 写端口每像素都写一次(更新 prev)，bg 字段按 update_bg 决定是否刷新。
    reg [15:0]  wr_word;
    reg [AW-1:0] wr_addr;
    reg         wr_de;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_word <= 16'd0;
            wr_addr <= {AW{1'b0}};
            wr_de   <= 1'b0;
        end else begin
            wr_de   <= de_d1;
            wr_word <= write_word;
            wr_addr <= addr_d1;
        end
    end
    always @(posedge clk) begin
        // rst_n gating removes the REQP-1839/1840 async-reset-on-RAM-address
        // advisory (same treatment as downsample_2x2's pair_ram in v4.4).
        if (rst_n && wr_de && wr_addr < W*H) mem[wr_addr] <= wr_word;
    end

    wire [7:0] diff_hist = d_bg;
    reg [7:0] diff_hist_r;
    reg de_d2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin diff_hist_r <= 0; de_d2 <= 0; end
        else begin diff_hist_r <= diff_hist; de_d2 <= de_d1; end
    end

    // Histogram: 18-bit bins (one frame has at most W*H = 230400 pixels).
    // Cleared in parallel on the frame-start marker (vs_in).  The 256-entry
    // parallel clear has a fan-out of only 256, which is not a timing risk.
    reg [17:0] hist [0:255];
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i=0; i<256; i=i+1) hist[i] <= 0;
        end else if (vs_in) begin
            for (i=0; i<256; i=i+1) hist[i] <= 0;
        end else if (de_d2 && initialized) begin
            hist[diff_hist_r] <= hist[diff_hist_r] + 1'b1;
        end
    end

    reg [CW-1:0] out_col;
    reg [RW-1:0] out_row;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin out_col <= 0; out_row <= 0; end
        else if (de_out) begin
            if (vs_out) begin out_col <= (W > 1) ? 1'b1 : 1'b0; out_row <= 0; end
            else if (hs_out) begin out_col <= (W > 1) ? 1'b1 : 1'b0; out_row <= (out_row==H-1)?{RW{1'b0}}:out_row+1'b1; end
            else if (out_col == W-1) begin
                out_col <= 0;
            end
            else out_col <= out_col + 1'b1;
        end
    end
    wire out_last = de_out && (out_row == H-1) && (out_col == W-1);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) frame_end <= 0;
        else frame_end <= out_last;
    end

    reg [17:0] fg_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fg_count <= 0;
        else if (vs_out) fg_count <= 0;
        else if (de_out && fg_mask) fg_count <= fg_count + 1'b1;
    end
    assign dbg_fg_count = fg_count;
    localparam [24:0] CHANGED_PIXELS = W * H * CHANGE_PERCENT;
    wire [24:0] fg_scaled = fg_count * 100;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || !initialized) scene_change <= 0;
        else if (frame_end) scene_change <= (fg_scaled >= CHANGED_PIXELS);
    end

    localparam HIST_IDLE=0, HIST_FIND=1, HIST_SMOOTH=2, HIST_DONE=3;
    reg [1:0] hist_state;
    reg [7:0] hist_idx, found_threshold;
    reg [17:0] hist_sum;
    wire [18:0] next_sum = {1'b0, hist_sum} + {1'b0, hist[hist_idx]};
    wire [24:0] next_scaled = next_sum * 100;
    localparam [24:0] TARGET_SUM = W * H * PERCENT;
    wire [9:0] smooth_sum = threshold * 3 + found_threshold;
    wire [7:0] smooth_value = smooth_sum[9:2];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hist_state <= HIST_IDLE; hist_idx <= 0; hist_sum <= 0;
            found_threshold <= 0; threshold <= MATCH_DIST; threshold_valid <= 0;
        end else begin
            case (hist_state)
                HIST_IDLE: if (frame_end && initialized) begin hist_state<=HIST_FIND; hist_idx<=0; hist_sum<=0; end
                HIST_FIND: begin
                    hist_sum <= next_sum[17:0];
                    if (next_scaled >= TARGET_SUM) begin
                        found_threshold <= hist_idx;
                        hist_state <= HIST_SMOOTH;
                    end else if (hist_idx < 255) hist_idx <= hist_idx + 1'b1;
                    else begin found_threshold <= 255; hist_state <= HIST_SMOOTH; end
                end
                HIST_SMOOTH: begin
                    if (smooth_value < TH_MIN) threshold <= TH_MIN;
                    else if (smooth_value > TH_MAX) threshold <= TH_MAX;
                    else threshold <= smooth_value;
                    threshold_valid <= 1'b1;
                    hist_state <= HIST_DONE;
                end
                HIST_DONE: if (vs_in) hist_state <= HIST_IDLE;
                default: hist_state <= HIST_IDLE;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin fg_mask<=0; de_out<=0; hs_out<=0; vs_out<=0; end
        else begin
            fg_mask <= (initialized && de_d1) ? fg_comb : 1'b0;
            de_out <= de_d1;
            hs_out <= hs_d1;
            vs_out <= vs_d1;
        end
    end

    reg [31:0] pix_d1, pix_d2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin pix_d1<=0; pix_d2<=0; end
        else begin pix_d1<=pix_in; pix_d2<=pix_d1; end
    end
    assign pix_out = pix_d2;
endmodule

