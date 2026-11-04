// Frame-level behaviour classifier.
//
// Motion is not decided from one adjacent-frame delta. ROI centres move in
// block-quantised jumps, so a slow target can remain unchanged for many frames
// and then jump 16/32 pixels. The previous implementation then alternated
// between STILL and MOV. This version uses a dead-band anchor and a movement
// hold window, which bridges the quantisation gaps while still settling to
// STILL shortly after a target really stops.
//
// A fall is only considered after a target has existed for FALL_MIN_AGE frames,
// is wide (lying posture), has grown substantially, and is not touching the
// image border. This rejects partial entry at the left/right edge, which was a
// major source of false FALL events.
`timescale 1ns / 1ps
// behavior
// 功能：帧级行为分类，输出移动、静止、徘徊和摔倒四个分数
// 输入：clk、rst_n、track_update、track_valid、track_id、track_cx等
// 输出：st_moving、st_still、st_loiter、st_fall、evt_fall、evt_loiter等
module behavior #(
    parameter MAX_ROI          = 4,
    parameter ID_WIDTH         = 8,
    parameter STILL_DIST       = 4,
    parameter STILL_N          = 6,
    parameter MOVE_HOLD_FRAMES = 45,
    parameter LOITER_RANGE     = 40,
    parameter LOITER_TIME      = 180,
    parameter LOITER_MIN_PATH  = 80,
    parameter FALL_WH_RATIO    = 2,
    parameter FALL_STILL_N     = 10,
    parameter FALL_MIN_AGE     = 30,
    parameter EDGE_MARGIN      = 4,
    parameter IMG_W            = 640,
    parameter IMG_H            = 360
)(
    input  wire clk,
    input  wire rst_n,
    input  wire        track_update,
    input  wire [MAX_ROI-1:0]          track_valid,
    input  wire [MAX_ROI*ID_WIDTH-1:0] track_id,
    input  wire [MAX_ROI*12-1:0]       track_cx,
    input  wire [MAX_ROI*12-1:0]       track_cy,
    input  wire [MAX_ROI*12-1:0]       track_w,
    input  wire [MAX_ROI*12-1:0]       track_h,
    output reg [MAX_ROI-1:0] st_moving,
    output reg [MAX_ROI-1:0] st_still,
    output reg [MAX_ROI-1:0] st_loiter,
    output reg [MAX_ROI-1:0] st_fall,
    output reg [MAX_ROI-1:0] evt_fall,
    output reg [MAX_ROI-1:0] evt_loiter,
    output reg [MAX_ROI*8-1:0] moving_score,
    output reg [MAX_ROI*8-1:0] still_score,
    output reg [MAX_ROI*8-1:0] loiter_score,
    output reg [MAX_ROI*8-1:0] fall_score,
    output reg               behavior_update
);
    reg [MAX_ROI-1:0]  lvalid;
    reg [ID_WIDTH-1:0] lid  [0:MAX_ROI-1];
    reg [11:0]         lcx  [0:MAX_ROI-1];
    reg [11:0]         lcy  [0:MAX_ROI-1];
    reg [11:0]         lw   [0:MAX_ROI-1];
    reg [11:0]         lh   [0:MAX_ROI-1];

    reg [11:0] anchor_cx [0:MAX_ROI-1];
    reg [11:0] anchor_cy [0:MAX_ROI-1];
    reg        prev_valid [0:MAX_ROI-1];
    reg [ID_WIDTH-1:0] prev_id [0:MAX_ROI-1];
    reg [7:0]  move_hold [0:MAX_ROI-1];
    reg [7:0]  still_cnt [0:MAX_ROI-1];
    reg [7:0]  age_cnt [0:MAX_ROI-1];
    reg [11:0] loit_cx [0:MAX_ROI-1], loit_cy [0:MAX_ROI-1];
    reg [15:0] loiter_cnt [0:MAX_ROI-1];
    reg [15:0] path_len [0:MAX_ROI-1];
    reg        path_ok [0:MAX_ROI-1];
    reg        time_ok [0:MAX_ROI-1];
    reg [23:0] area_ref [0:MAX_ROI-1];
    reg [1:0]  fall_state [0:MAX_ROI-1];
    reg [7:0]  fall_cnt [0:MAX_ROI-1];

    localparam FS_NORMAL=0, FS_SUSPECT=1, FS_FALL=2;
    localparam S_IDLE=0, S_PROC=1, S_DONE=2;
    reg [2:0] state;
    reg [2:0] k;
    integer i;

    wire [11:0] p_cx = lcx[k];
    wire [11:0] p_cy = lcy[k];
    wire [11:0] p_w  = lw[k];
    wire [11:0] p_h  = lh[k];
    wire [23:0] area = p_w * p_h;

    wire signed [12:0] dx_s = {1'b0, p_cx} - {1'b0, anchor_cx[k]};
    wire signed [12:0] dy_s = {1'b0, p_cy} - {1'b0, anchor_cy[k]};
    wire [12:0] adx = dx_s[12] ? (~dx_s[12:0] + 13'd1) : dx_s[12:0];
    wire [12:0] ady = dy_s[12] ? (~dy_s[12:0] + 13'd1) : dy_s[12:0];
    wire [13:0] anchor_delta = {1'b0, adx} + {1'b0, ady};
    wire moved_now = anchor_delta > STILL_DIST;
    wire [7:0] move_hold_next = moved_now ? MOVE_HOLD_FRAMES :
                                ((move_hold[k] != 0) ? move_hold[k] - 1'b1 : 8'd0);
    wire moving_now = (move_hold_next != 0);
    wire [7:0] still_cnt_next = moving_now ? 8'd0 :
                   ((still_cnt[k] >= STILL_N) ? still_cnt[k] : still_cnt[k] + 1'b1);
    wire still_now = !moving_now && (still_cnt_next >= STILL_N);
    wire moving_out = !still_now;

    // 徘徊判定：目标是否仍停留在"徘徊锚点"的半径内。
    // 旧实现用累计外接范围，直线/匀速移动时范围慢慢涨到阈值后复位，
    // 会让 LOI 分数出现 0->30 的锯齿；锚点半径在离开半径时立即重锚，
    // 直线移动不会累积，只有真正绕小范围活动才会让 loiter_cnt 增长。
    wire signed [12:0] ldx_s = {1'b0, p_cx} - {1'b0, loit_cx[k]};
    wire signed [12:0] ldy_s = {1'b0, p_cy} - {1'b0, loit_cy[k]};
    wire [12:0] ladx = ldx_s[12] ? (~ldx_s[12:0] + 13'd1) : ldx_s[12:0];
    wire [12:0] lady = ldy_s[12] ? (~ldy_s[12:0] + 13'd1) : ldy_s[12:0];
    wire [13:0] loiter_dist = {1'b0, ladx} + {1'b0, lady};
    wire loiter_frame = moving_now && (loiter_dist < LOITER_RANGE);
    wire [15:0] loiter_cnt_next = loiter_frame ? loiter_cnt[k] + 1'b1 : 16'd0;
    wire [15:0] path_len_next = loiter_frame ?
                                path_len[k] + anchor_delta : 16'd0;
    // 直线移动时 loiter_dist 会先超过 LOITER_RANGE 并清零 path_len，
    // 因此 path_len 永远到不了 LOITER_MIN_PATH(80 > RANGE=40)；
    // 只有小范围来回走才能让 path_len 在半径内累积到 80。
    wire loiter_credible = loiter_frame && path_ok[k];
    wire loiter_now = loiter_credible && time_ok[k];

    // A surviving target must be old enough and fully inside the frame before
    // its shape change can arm a fall. Partial entry/exit is not a fall.
    wire [12:0] half_w = {1'b0, p_w} >> 1;
    wire [12:0] half_h = {1'b0, p_h} >> 1;
    wire [13:0] box_x0 = ({1'b0, p_cx} > half_w) ? ({1'b0, p_cx} - half_w) : 14'd0;
    wire [13:0] box_y0 = ({1'b0, p_cy} > half_h) ? ({1'b0, p_cy} - half_h) : 14'd0;
    wire [13:0] box_x1 = {1'b0, p_cx} + half_w;
    wire [13:0] box_y1 = {1'b0, p_cy} + half_h;
    wire at_image_edge =
        (box_x0 <= EDGE_MARGIN) || (box_x1 >= IMG_W-1-EDGE_MARGIN) ||
        (box_y0 <= EDGE_MARGIN) || (box_y1 >= IMG_H-1-EDGE_MARGIN);
    wire wide_posture = (p_w * 2) > (p_h * 3);
    wire area_burst = (area * 4) > (area_ref[k] * 3);
    wire fall_transition_candidate =
        (age_cnt[k] >= FALL_MIN_AGE) && !at_image_edge &&
        wide_posture && area_burst;

    reg [1:0] next_fs;
    reg [7:0] next_fc;
    always @(*) begin
        next_fs = fall_state[k];
        next_fc = fall_cnt[k];
        case (fall_state[k])
            FS_NORMAL: begin
                if (fall_transition_candidate) begin
                    next_fs = FS_SUSPECT;
                    next_fc = 0;
                end else begin
                    next_fs = FS_NORMAL;
                    next_fc = 0;
                end
            end
            FS_SUSPECT: begin
                if (!wide_posture)
                    begin next_fs = FS_NORMAL; next_fc = 0; end
                else if (still_now) begin
                    next_fc = fall_cnt[k] + 1'b1;
                    if (next_fc >= FALL_STILL_N)
                        next_fs = FS_FALL;
                    else
                        next_fs = FS_SUSPECT;
                end else begin
                    next_fs = FS_SUSPECT;
                    next_fc = 0;
                end
            end
            FS_FALL: begin
                if (moving_now && !wide_posture) begin
                    next_fs = FS_NORMAL;
                    next_fc = 0;
                end else begin
                    next_fs = FS_FALL;
                    next_fc = fall_cnt[k];
                end
            end
            default: begin next_fs = FS_NORMAL; next_fc = 0; end
        endcase
    end

    wire is_new = lvalid[k] && (!prev_valid[k] || (lid[k] != prev_id[k]));

    // ---- 0..100 置信度打分（仅用于输出，不参与任何状态判定）----
    // 移动分：只要处于移动保持期就 >0，随位移增大爬升到 100。
    wire [15:0] ms_raw = 16'd30 + ({2'b0, anchor_delta} << 2);
    wire [7:0]  moving_score_w = moving_out ?
                    ((ms_raw > 16'd100) ? 8'd100 : ms_raw[7:0]) : 8'd0;
    // 静止分：still_cnt 每帧逼近 STILL_N，满则 100。
    wire [15:0] ss_raw = still_cnt[k] * 8'd17;
    wire [7:0]  still_score_w = still_now ?
                    8'd100 : ((ss_raw > 16'd100) ? 8'd100 : ss_raw[7:0]);
    // 徘徊分：loiter_cnt 逼近 LOITER_TIME，达到即 100。
    wire [15:0] ls_raw = (loiter_cnt[k] * 16'd9) >> 4;
    wire [7:0]  loiter_score_w = loiter_now ? 8'd100 :
                    (loiter_credible ?
                     ((ls_raw > 16'd100) ? 8'd100 : ls_raw[7:0]) : 8'd0);
    // 跌倒疑似分：SUSPECT 阶段随 fall_cnt 爬升，FALL 锁定为 100。
    wire [7:0]  fall_score_w = (fall_state[k] == FS_FALL) ? 8'd100 :
                    ((fall_state[k] == FS_SUSPECT) ?
                     ((fall_cnt[k] >= 8'd10) ? 8'd100 : fall_cnt[k] * 8'd10) : 8'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            k <= 0;
            behavior_update <= 0;
            lvalid <= 0;
            st_moving <= 0;
            st_still <= 0;
            st_loiter <= 0;
            st_fall <= 0;
            evt_fall <= 0;
            evt_loiter <= 0;
            moving_score <= 0;
            still_score <= 0;
            loiter_score <= 0;
            fall_score <= 0;
            for (i = 0; i < MAX_ROI; i = i + 1) begin
                lid[i] <= 0; lcx[i] <= 0; lcy[i] <= 0; lw[i] <= 0; lh[i] <= 0;
                anchor_cx[i] <= 0; anchor_cy[i] <= 0;
                prev_valid[i] <= 0; prev_id[i] <= 0;
                move_hold[i] <= 0; still_cnt[i] <= 0; age_cnt[i] <= 0;
                loit_cx[i] <= 0; loit_cy[i] <= 0;
                loiter_cnt[i] <= 0; area_ref[i] <= 0;
                path_len[i] <= 0;
                path_ok[i] <= 0; time_ok[i] <= 0;
                fall_state[i] <= FS_NORMAL; fall_cnt[i] <= 0;
            end
        end else begin
            behavior_update <= 0;
            case (state)
                S_IDLE: begin
                    if (track_update) begin
                        lvalid <= track_valid;
                        for (i = 0; i < MAX_ROI; i = i + 1) begin
                            lid[i] <= track_id[i*ID_WIDTH +: ID_WIDTH];
                            lcx[i] <= track_cx[i*12 +: 12];
                            lcy[i] <= track_cy[i*12 +: 12];
                            lw[i]  <= track_w[i*12 +: 12];
                            lh[i]  <= track_h[i*12 +: 12];
                        end
                        evt_fall <= 0;
                        evt_loiter <= 0;
                        k <= 0;
                        state <= S_PROC;
                    end
                end

                S_PROC: begin
                    if (lvalid[k]) begin
                        if (is_new) begin
                            anchor_cx[k] <= p_cx;
                            anchor_cy[k] <= p_cy;
                            prev_valid[k] <= 1'b1;
                            prev_id[k] <= lid[k];
                            move_hold[k] <= 0;
                            still_cnt[k] <= 0;
                            age_cnt[k] <= 1;
                            loit_cx[k] <= p_cx; loit_cy[k] <= p_cy;
                            loiter_cnt[k] <= 0;
                            path_len[k] <= 0;
                            path_ok[k] <= 1'b0; time_ok[k] <= 1'b0;
                            area_ref[k] <= area;
                            fall_state[k] <= FS_NORMAL;
                            fall_cnt[k] <= 0;
                            st_moving[k] <= 1'b1;
                            st_still[k] <= 1'b0;
                            st_loiter[k] <= 1'b0;
                            st_fall[k] <= 1'b0;
                            moving_score[k*8 +: 8] <= 8'd30;
                            still_score[k*8 +: 8] <= 8'd0;
                            loiter_score[k*8 +: 8] <= 8'd0;
                            fall_score[k*8 +: 8] <= 8'd0;
                        end else begin
                            if (moved_now) begin
                                anchor_cx[k] <= p_cx;
                                anchor_cy[k] <= p_cy;
                            end
                            move_hold[k] <= move_hold_next;
                            still_cnt[k] <= still_cnt_next;
                            if (age_cnt[k] != 8'hff)
                                age_cnt[k] <= age_cnt[k] + 1'b1;
                            st_moving[k] <= moving_out;
                            st_still[k]  <= still_now;

                            if (loiter_frame) begin
                                // 保持在锚点半径内：锚点不动，累计时间与路径
                                loiter_cnt[k] <= loiter_cnt_next;
                                path_len[k] <= path_len_next;
                            end else begin
                                // 离开半径：立即以当前位置重锚，直线移动不会累积
                                loit_cx[k] <= p_cx; loit_cy[k] <= p_cy;
                                loiter_cnt[k] <= 0;
                                path_len[k] <= 0;
                            end
                            path_ok[k] <= loiter_frame && (path_len_next >= LOITER_MIN_PATH);
                            time_ok[k] <= loiter_frame && (loiter_cnt_next >= LOITER_TIME);
                            st_loiter[k] <= loiter_now;
                            evt_loiter[k] <= loiter_now && (loiter_cnt[k] < LOITER_TIME);
                            moving_score[k*8 +: 8] <= moving_score_w;
                            still_score[k*8 +: 8] <= still_score_w;
                            loiter_score[k*8 +: 8] <= loiter_score_w;
                            fall_score[k*8 +: 8] <= fall_score_w;

                            if ((fall_state[k] == FS_NORMAL) && !fall_transition_candidate)
                                area_ref[k] <= ((area_ref[k] * 3) + area) >> 2;
                            fall_state[k] <= next_fs;
                            fall_cnt[k] <= next_fc;
                            st_fall[k] <= (next_fs == FS_FALL);
                            evt_fall[k] <= (fall_state[k] == FS_SUSPECT) &&
                                           (next_fs == FS_FALL);
                        end
                    end else begin
                        prev_valid[k] <= 1'b0;
                        move_hold[k] <= 0;
                        still_cnt[k] <= 0;
                        age_cnt[k] <= 0;
                        loiter_cnt[k] <= 0;
                        path_len[k] <= 0;
                        path_ok[k] <= 1'b0; time_ok[k] <= 1'b0;
                        st_moving[k] <= 1'b0;
                        st_still[k] <= 1'b0;
                        st_loiter[k] <= 1'b0;
                        st_fall[k] <= 1'b0;
                        moving_score[k*8 +: 8] <= 8'd0;
                        still_score[k*8 +: 8] <= 8'd0;
                        loiter_score[k*8 +: 8] <= 8'd0;
                        fall_score[k*8 +: 8] <= 8'd0;
                    end

                    if (k == MAX_ROI-1)
                        state <= S_DONE;
                    else
                        k <= k + 1'b1;
                end

                S_DONE: begin
                    behavior_update <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
