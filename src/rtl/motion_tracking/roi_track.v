`timescale 1ns/1ps
// roi_track
// 功能：多目标跟踪，维持目标编号和稳定槽位
// 输入：roi_done、roi_num、roi_boxes、dist_threshold、clk、rst_n
// 输出：track_done、track_num、track_data、track_wh、track_quality、stable_update等
module roi_track #(
    parameter MAX_ROI = 4,
    parameter MAX_TRACK = 8,
    parameter DIST_W = 13,
    parameter IDX_W = 3,
    parameter LOST_THRESHOLD = 180,
    parameter CONFIRM_AGE    = 2,
    parameter DRAW_HOLD      = 12,
    parameter QUALITY_INC    = 8,
    parameter QUALITY_DEC    = 4
)(
    input  wire roi_done,
    input  wire [3:0] roi_num,
    input  wire [MAX_ROI*48-1:0] roi_boxes,
    input  wire [DIST_W-1:0] dist_threshold,
    input  wire clk,
    input  wire rst_n,
    output reg  track_done,
    output reg  [3:0] track_num,
    output reg  [MAX_TRACK*32-1:0] track_data,
    output reg  [MAX_TRACK*24-1:0] track_wh,  // 每目标 {w[11:0], h[11:0]}(640域像素)
    output reg  [MAX_ROI*8-1:0]    track_quality,
    output reg                      stable_update,
    output reg  [3:0]               stable_num,
    output reg  [MAX_ROI*32-1:0]    stable_data,
    output reg  [MAX_ROI*24-1:0]    stable_wh,
    output reg  [MAX_ROI*8-1:0]     stable_age,
    output reg  [MAX_ROI*8-1:0]     stable_lost,
    output reg  [MAX_ROI*8-1:0]     stable_quality
);
    // 1. 帧锁存
    reg [MAX_ROI*48-1:0] cur_boxes;
    reg [3:0] cur_num;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_boxes <= 0;
            cur_num   <= 0;
        end else if (roi_done) begin
            cur_boxes <= roi_boxes;
            cur_num   <= roi_num;
        end
    end

    // 2. 计算 ROI 中心点
    wire [MAX_ROI*24-1:0] cur_center;
    genvar i;
    generate
        for (i = 0; i < MAX_ROI; i = i + 1) begin : GEN_CENTROID
            wire [47:0] box;
            wire [23:0] center;
            assign box = cur_boxes[i*48 +: 48];
            centroid_calc u_centroid_calc (
                .roi_box(box),
                .center(center)
            );
            assign cur_center[i*24 +: 24] = center;
        end
    endgenerate

    // 2b. 计算 ROI 宽高（640 域像素）：w=x1-x0, h=y1-y0
    wire [MAX_ROI*24-1:0] cur_wh;
    generate
        for (i = 0; i < MAX_ROI; i = i + 1) begin : GEN_WH
            wire [47:0] box = cur_boxes[i*48 +: 48];
            assign cur_wh[i*24 +: 24] = { (box[23:12] - box[47:36] + 12'd1),
                                           (box[11:0]  - box[35:24] + 12'd1) };
        end
    endgenerate

    // 3. ID 表声明
    reg [7:0]  id_table_id    [0:MAX_TRACK-1];
    reg [23:0] id_table_center[0:MAX_TRACK-1];
    reg [7:0]  id_table_lost  [0:MAX_TRACK-1];
    reg [7:0]  id_table_age   [0:MAX_TRACK-1];
    reg [7:0]  id_table_quality [0:MAX_TRACK-1];
    reg        id_table_valid [0:MAX_TRACK-1];
    reg [11:0] id_table_w     [0:MAX_TRACK-1];
    reg [11:0] id_table_h     [0:MAX_TRACK-1];
    reg [7:0]  id_counter;

    wire [MAX_TRACK-1:0] prev_valid_mask;
    generate
        for (i = 0; i < MAX_TRACK; i = i + 1) begin : GEN_VALID_VEC
            assign prev_valid_mask[i] = id_table_valid[i];
        end
    endgenerate

    // 4. 计算距离矩阵
    wire [MAX_ROI*MAX_TRACK*DIST_W-1:0] dist_matrix;
    // 时序修复：距离矩阵打一拍，拆开 centroid/dist_calc 与匹配比较树的长组合链
    reg  [MAX_ROI*MAX_TRACK*DIST_W-1:0] dist_matrix_reg;
    always @(posedge clk) dist_matrix_reg <= dist_matrix;
    genvar k, t;
    generate
        for (k = 0; k < MAX_ROI; k = k + 1) begin : GEN_DIST_ROW
            for (t = 0; t < MAX_TRACK; t = t + 1) begin : GEN_DIST_COL
                dist_calc #(
                    .DIST_W(DIST_W)
                ) u_dist_calc (
                    .center1(cur_center[k*24 +: 24]),
                    .center2(id_table_center[t]),
                    .distance(dist_matrix[(k*MAX_TRACK+t)*DIST_W +: DIST_W])
                );
            end
        end
    endgenerate

    // 5. 距离匹配与仲裁
    reg match_start;
    wire [MAX_ROI*IDX_W-1:0] matched_idx;
    wire [MAX_ROI-1:0]       match_valid;
    wire [MAX_ROI*DIST_W-1:0] min_dist;
    wire                     match_done;
    wire [MAX_ROI-1:0]       arb_valid;

    match_machine #(MAX_ROI, MAX_TRACK, DIST_W, IDX_W) u_match_machine (
        .dist_matrix(dist_matrix_reg),
        .dist_threshold(dist_threshold),
        .prev_valid_mask(prev_valid_mask),
        .cur_num(cur_num),
        .clk(clk),
        .rst_n(rst_n),
        .start(match_start),
        .matched_idx(matched_idx),
        .match_valid(match_valid),
        .min_dist(min_dist),
        .match_done(match_done)
    );

    match_arbiter #(MAX_ROI, MAX_TRACK, DIST_W, IDX_W) u_arb (
        .cur_num(cur_num),
        .match_valid(match_valid),
        .matched_idx(matched_idx),
        .min_dist(min_dist),
        .arb_valid(arb_valid)
    );

    // 6. 状态机与 ID 更新管理
    localparam S_IDLE = 3'd0, S_CALC = 3'd1, S_WAIT = 3'd2,
               S_UPDATE = 3'd3, S_NEW = 3'd4, S_PACK = 3'd5;
    reg [2:0] state;
    reg [3:0] new_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            match_start <= 1'b0;
            new_cnt <= 4'd0;
        end else begin
            case (state)
                S_IDLE: if (roi_done) state <= S_CALC;
                S_CALC: begin match_start <= 1'b1; state <= S_WAIT; end
                S_WAIT: begin
                    match_start <= 1'b0;
                    if (match_done) state <= S_UPDATE;
                end
                S_UPDATE: begin new_cnt <= 4'd0; state <= S_NEW; end
                S_NEW: begin
                    if (new_cnt >= MAX_ROI) state <= S_PACK;
                    else new_cnt <= new_cnt + 1'b1;
                end
                S_PACK: state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end

    // 未匹配目标掩码
    wire [MAX_ROI-1:0] unmatched_mask;
    generate
        for (i = 0; i < MAX_ROI; i = i + 1) begin : GEN_UNMATCH
            assign unmatched_mask[i] = (i < cur_num) && (!arb_valid[i]);
        end
    endgenerate

    // 空闲槽位查找 (参数化优先级编码)
    wire [MAX_TRACK-1:0] free_mask = ~prev_valid_mask;
    wire                 free_found = |free_mask;
    reg  [IDX_W-1:0]     free_idx;
    integer p;
    always @(*) begin
        free_idx = {IDX_W{1'b0}};
        for (p = MAX_TRACK-1; p >= 0; p = p - 1) begin
            if (free_mask[p]) free_idx = p[IDX_W-1:0];
        end
    end

    // ID 表并行更新
    genvar gj;
    generate
        for (gj = 0; gj < MAX_TRACK; gj = gj + 1) begin : GEN_SLOT_UPDATE
            reg m;
            reg [23:0] center_w;
            reg [11:0] w_w, h_w;
            integer ii;
            always @(*) begin
                m = 1'b0;
                center_w = 24'd0;
                w_w = 12'd0;
                h_w = 12'd0;
                for (ii = 0; ii < MAX_ROI; ii = ii + 1) begin
                    // 注意：matched_idx 是 MAX_ROI 个 IDX_W 位字段打包，必须做字段选择；
                    // 写成 matched_idx[ii] 只是取 1 个 bit，会把槽位更新搞乱
                    if (ii < cur_num && arb_valid[ii] &&
                        (matched_idx[ii*IDX_W +: IDX_W] == gj)) begin
                        m = 1'b1;
                        center_w = cur_center[ii*24 +: 24];
                        w_w = cur_wh[ii*24 + 23 -: 12];
                        h_w = cur_wh[ii*24 + 11 -: 12];
                    end
                end
            end

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    id_table_id[gj] <= 8'd0;
                    id_table_center[gj] <= 24'd0;
                    id_table_lost[gj] <= 8'd0;
                    id_table_age[gj] <= 8'd0;
                    id_table_quality[gj] <= 8'd0;
                    id_table_valid[gj] <= 1'b0;
                    id_table_w[gj] <= 12'd0;
                    id_table_h[gj] <= 12'd0;
                end else if (state == S_UPDATE) begin
                    if (m) begin
                        id_table_center[gj] <= center_w;
                        id_table_w[gj] <= w_w;
                        id_table_h[gj] <= h_w;
                        id_table_lost[gj] <= 8'd0;
                        if (id_table_age[gj] != 8'hff)
                            id_table_age[gj] <= id_table_age[gj] + 1'b1;
                        if (id_table_quality[gj] < 8'd100) begin
                            if (8'd100 - id_table_quality[gj] >= QUALITY_INC)
                                id_table_quality[gj] <= id_table_quality[gj] + QUALITY_INC;
                            else
                                id_table_quality[gj] <= 8'd100;
                        end
                        id_table_valid[gj] <= 1'b1;
                    end else if (id_table_valid[gj]) begin
                        if (id_table_lost[gj] + 1 >= LOST_THRESHOLD) begin
                            id_table_valid[gj] <= 1'b0;
                            id_table_lost[gj] <= 8'd0;
                            id_table_age[gj] <= 8'd0;
                            id_table_quality[gj] <= 8'd0;
                        end else begin
                            id_table_lost[gj] <= id_table_lost[gj] + 1'b1;
                            if (id_table_quality[gj] > QUALITY_DEC)
                                id_table_quality[gj] <= id_table_quality[gj] - QUALITY_DEC;
                            else
                                id_table_quality[gj] <= 8'd0;
                        end
                    end
                end else if (state == S_NEW) begin
                    if (new_cnt < MAX_ROI && unmatched_mask[new_cnt] && free_found && free_idx == gj) begin
                        id_table_id[gj] <= id_counter;
                        id_table_center[gj] <= cur_center[new_cnt*24 +: 24];
                        id_table_w[gj] <= cur_wh[new_cnt*24 + 23 -: 12];
                        id_table_h[gj] <= cur_wh[new_cnt*24 + 11 -: 12];
                        id_table_lost[gj] <= 8'd0;
                        id_table_age[gj] <= 8'd1;
                        id_table_quality[gj] <= 8'd60;
                        id_table_valid[gj] <= 1'b1;
                    end
                end
            end
        end
    endgenerate

    // ID 计数器
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) id_counter <= 8'd0;
        else if (state == S_NEW && new_cnt < MAX_ROI && unmatched_mask[new_cnt] && free_found)
            id_counter <= id_counter + 1'b1;
    end

    // 打包输出：active 用于 behavior，stable 用于显示和 CNN 主目标
    integer pack_idx, ii_pack, stable_idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            track_data <= 0;
            track_wh <= 0;
            track_quality <= 0;
            track_num <= 0;
            track_done <= 1'b0;
            stable_update <= 1'b0;
            stable_num <= 0;
            stable_data <= 0;
            stable_wh <= 0;
            stable_age <= 0;
            stable_lost <= 0;
            stable_quality <= 0;
        end else if (state == S_PACK) begin
            pack_idx = 0;
            stable_idx = 0;
            track_data <= 0;
            track_wh <= 0;
            track_quality <= 0;
            stable_data <= 0;
            stable_wh <= 0;
            stable_age <= 0;
            stable_lost <= 0;
            stable_quality <= 0;
            for (ii_pack = 0; ii_pack < MAX_TRACK; ii_pack = ii_pack + 1) begin
                if (id_table_valid[ii_pack] && id_table_lost[ii_pack] == 0) begin
                    track_data[pack_idx*32 +: 32] <= {id_table_id[ii_pack], id_table_center[ii_pack]};
                    track_wh[pack_idx*24 +: 24]   <= {id_table_w[ii_pack], id_table_h[ii_pack]};
                    if (pack_idx < MAX_ROI)
                        track_quality[pack_idx*8 +: 8] <= id_table_quality[ii_pack];
                    pack_idx = pack_idx + 1;
                end
                if (stable_idx < MAX_ROI &&
                    id_table_valid[ii_pack] &&
                    id_table_age[ii_pack] >= CONFIRM_AGE &&
                    id_table_lost[ii_pack] <= DRAW_HOLD) begin
                    stable_data[stable_idx*32 +: 32] <=
                        {id_table_id[ii_pack], id_table_center[ii_pack]};
                    stable_wh[stable_idx*24 +: 24] <=
                        {id_table_w[ii_pack], id_table_h[ii_pack]};
                    stable_age[stable_idx*8 +: 8] <= id_table_age[ii_pack];
                    stable_lost[stable_idx*8 +: 8] <= id_table_lost[ii_pack];
                    stable_quality[stable_idx*8 +: 8] <= id_table_quality[ii_pack];
                    stable_idx = stable_idx + 1;
                end
            end
            track_num <= pack_idx[3:0];
            stable_num <= stable_idx[3:0];
            track_done <= 1'b1;
            stable_update <= 1'b1;
        end else begin
            track_done <= 1'b0;
            stable_update <= 1'b0;
        end
    end
endmodule

