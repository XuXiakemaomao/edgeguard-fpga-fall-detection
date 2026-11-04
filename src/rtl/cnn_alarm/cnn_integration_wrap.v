`timescale 1ns/1ps
// cnn_integration_wrap
// 功能：CNN 子系统接入层，负责裁剪、调度、平滑、证据门控和状态融合
// 输入：clk_pix、rst_n、gray_360p、de_ds、hs_ds、vs_ds等
// 输出：final_state、final_valid、fall_confirm、fall_suspect、gate_confident、gate_motion等
module cnn_integration_wrap #(
    parameter MAX_ROI = 4
) (
    input  wire        clk_pix,
    input  wire        rst_n,
    // ---- video stream from the v5.0 main chain (640x360 domain) ----
    input  wire [7:0]  gray_360p,
    input  wire        de_ds,
    input  wire        hs_ds,
    input  wire        vs_ds,
    input  wire [15:0] frame_id,
    // ---- ROI boxes (passthrough / diagnostics; not used by the CNN) ----
    input  wire        roi_done,
    input  wire [3:0]  roi_num,
    input  wire [MAX_ROI*48-1:0] roi_boxes,
    // ---- tracking snapshot ----
    input  wire        track_update,
    input  wire [MAX_ROI-1:0]    track_valid,
    input  wire [MAX_ROI*8-1:0]  track_id,
    input  wire [MAX_ROI*12-1:0] track_cx,
    input  wire [MAX_ROI*12-1:0] track_cy,
    input  wire [MAX_ROI*12-1:0] track_w,
    input  wire [MAX_ROI*12-1:0] track_h,
    // ---- geometry behaviour (read-only) ----
    input  wire [MAX_ROI-1:0] st_moving,
    input  wire [MAX_ROI-1:0] st_still,
    input  wire [MAX_ROI-1:0] st_loiter,
    input  wire [MAX_ROI-1:0] st_fall,
    input  wire        behavior_update,
    // ---- fused result ----
    output wire [1:0]  final_state,     // 0 walk / 1 stay / 2 fall / 3 other
    output wire        final_valid,
    output wire        fall_confirm,    // gated by fall_gate (confidence OR height-collapse)
    output wire        fall_suspect,
    output wire        gate_confident,  // fall_gate E1 evidence (debug)
    output wire        gate_motion,     // fall_gate E2 evidence (debug)
    output wire        result_valid,    // one pulse per completed inference
    output wire [7:0]  logit0,
    output wire [7:0]  logit1,
    output wire [7:0]  logit2,
    output wire [7:0]  task_track_id,
    output wire [15:0] task_frame_id,
    output wire [15:0] drop_count,
    // ---- extra context for the integration layer ----
    output wire [1:0]  primary_idx,
    output wire        core_busy,
    output wire        primary_valid,
    output wire [11:0] primary_cx, primary_cy, primary_w, primary_h,
    output wire [1:0]  pred
);
    // ---------------------------------------------------------------- track snapshot
    // The 48-bit packed track bus comes from roi_track and fans out to every
    // CNN block; using it combinationally created the last whole-chip timing
    // violation (track_wh -> cnn_smooth/cmd_id).  Snapshot it once here and
    // distribute the registered copy.
    reg        tk_upd;
    reg [MAX_ROI-1:0]    tk_valid;
    reg [MAX_ROI*8-1:0]  tk_id;
    reg [MAX_ROI*12-1:0] tk_cx, tk_cy, tk_w, tk_h;
    always @(posedge clk_pix) begin
        if (!rst_n) begin
            tk_upd <= 1'b0;
            tk_valid <= {MAX_ROI{1'b0}};
            tk_id <= {MAX_ROI*8{1'b0}};
            tk_cx <= {MAX_ROI*12{1'b0}};
            tk_cy <= {MAX_ROI*12{1'b0}};
            tk_w  <= {MAX_ROI*12{1'b0}};
            tk_h  <= {MAX_ROI*12{1'b0}};
        end else begin
            tk_upd <= track_update;
            if (track_update) begin
                tk_valid <= track_valid;
                tk_id    <= track_id;
                tk_cx    <= track_cx;
                tk_cy    <= track_cy;
                tk_w     <= track_w;
                tk_h     <= track_h;
            end
        end
    end

    // ---------------------------------------------------------------- primary target
    wire        primary_update;
    wire [7:0]  primary_id;

    cnn_primary_sel #(.MAX_ROI(MAX_ROI)) u_sel (
        .clk(clk_pix), .rst_n(rst_n), .track_update(tk_upd),
        .track_valid(tk_valid), .track_id(tk_id),
        .track_cx(tk_cx), .track_cy(tk_cy),
        .track_w(tk_w), .track_h(tk_h),
        .primary_valid(primary_valid), .primary_idx(primary_idx),
        .primary_id(primary_id), .primary_cx(primary_cx),
        .primary_cy(primary_cy), .primary_w(primary_w), .primary_h(primary_h),
        .primary_update(primary_update)
    );

    // ---------------------------------------------------------------- ROI crop
    wire        crop_start;
    wire [1:0]  crop_bank;
    wire        crop_busy, crop_done;
    wire [1:0]  crop_done_bank;
    wire        roi_we;
    wire [11:0] roi_addr;
    wire [7:0]  roi_data;
    wire        crop_timeout;
    wire [15:0] crop_frame;
    wire [7:0]  crop_id;
    wire [11:0] crop_x0, crop_y0, crop_w, crop_h;

    cnn_roi_crop #(.W(640), .H(360), .R(48)) u_crop (
        .clk(clk_pix), .rst_n(rst_n),
        .gray(gray_360p), .de(de_ds), .hs(hs_ds), .vs(vs_ds),
        .frame_id(frame_id),
        .track_update(primary_update), .track_valid(primary_valid),
        .track_id(primary_id),
        .track_cx(primary_cx), .track_cy(primary_cy),
        .track_w(primary_w), .track_h(primary_h),
        .start(crop_start), .bank(crop_bank),
        .we(roi_we), .addr(roi_addr), .data(roi_data),
        .done(crop_done), .done_bank(crop_done_bank), .busy(crop_busy),
        .timeout(crop_timeout),
        .snap_frame(crop_frame), .snap_id(crop_id),
        .snap_x0(crop_x0), .snap_y0(crop_y0),
        .snap_w(crop_w), .snap_h(crop_h)
    );

    // ---------------------------------------------------------------- scheduler
    wire        core_start;
    wire [1:0]  core_bank;
    wire        core_done;
    wire [7:0]  core_l0, core_l1, core_l2;
    wire [1:0]  core_pred;
    wire        core_invalid;
    wire [23:0] result_logits;

    wire [23:0] core_logits = {core_l0, core_l1, core_l2};

    cnn_scheduler u_sched (
        .clk(clk_pix), .rst_n(rst_n),
        .track_update(primary_update), .track_valid(primary_valid),
        .track_id(primary_id), .primary_idx(primary_idx), .frame_id(frame_id),
        .crop_start(crop_start), .crop_bank(crop_bank),
        .crop_busy(crop_busy), .crop_done(crop_done),
        .crop_done_bank(crop_done_bank),
        .core_start(core_start), .core_bank(core_bank),
        .core_busy(core_busy), .core_done(core_done),
        .logits(core_logits),
        .result_valid(result_valid), .result_logits(result_logits),
        .task_frame_id(task_frame_id),
        .task_track_id(task_track_id),
        .task_primary_idx(),
        .drop_count(drop_count), .bank_stall(),
        .busy()
    );

    // ---------------------------------------------------------------- core
    cnn_core u_core (
        .clk(clk_pix), .rst_n(rst_n),
        .start(core_start), .bank(core_bank),
        .busy(core_busy), .done(core_done),
        .logit0(core_l0), .logit1(core_l1), .logit2(core_l2),
        .pred(core_pred), .result_invalid(core_invalid),
        .roi_we(roi_we), .roi_wbank(crop_bank), .roi_waddr(roi_addr),
        .roi_wdata(roi_data),
        .dbg_en(1'b0), .dbg_sel(3'd0), .dbg_addr(15'd0), .dbg_data()
    );

    assign logit0 = core_l0;
    assign logit1 = core_l1;
    assign logit2 = core_l2;
    assign pred   = core_pred;

    // ---------------------------------------------------------------- smooth
    wire fall_confirm_raw;
    cnn_smooth #(.N(3), .M(5)) u_smooth (
        .clk(clk_pix), .rst_n(rst_n),
        .result_valid(result_valid), .pred(core_pred),
        .track_update(primary_update), .track_valid(primary_valid),
        .track_id(primary_id),
        .fall_confirm(fall_confirm_raw), .fall_suspect(fall_suspect),
        .cnt_fall(), .cnt_clear(), .locked_id()
    );

    // ---- 证据门控：抑制低置信度、无高度塌陷的 fall 误判 ----
    wire gate_confident_w, gate_motion_w;
    fall_gate #(
        .USE_MOTION(0),
        .CONF_MARGIN(8),
        .COLLAPSE_NUM(7),
        .COLLAPSE_DEN(10),
        .COLLAPSE_HOLD(60),
        .DECAY_SHIFT(5)
    ) u_gate (
        .clk(clk_pix), .rst_n(rst_n),
        .result_valid(result_valid), .pred(core_pred),
        .logit0(core_l0), .logit1(core_l1), .logit2(core_l2),
        .primary_update(primary_update), .primary_valid(primary_valid),
        .primary_id(primary_id), .primary_h(primary_h),
        .fall_confirm_raw(fall_confirm_raw),
        .fall_confirm(fall_confirm),
        .confident(gate_confident_w), .motion_sig(gate_motion_w)
    );
    assign gate_confident = gate_confident_w;
    assign gate_motion    = gate_motion_w;

    // ---------------------------------------------------------------- fusion
    wire geom_moving = st_moving[primary_idx];
    wire geom_still  = st_still[primary_idx];

    fusion_decision u_fusion (
        .target_valid(primary_valid),
        .fall_confirm(fall_confirm),
        .geom_moving(geom_moving),
        .geom_still(geom_still),
        .final_state(final_state),
        .final_valid(final_valid)
    );

    // reserved / passthrough inputs: intentionally unused, kept for the frozen
    // interface so the wrapper can be dropped in without touching the port list
    wire _unused = ^{roi_done, roi_num, roi_boxes, st_loiter, st_fall,
                     behavior_update, core_invalid, crop_timeout, crop_frame,
                     crop_id, crop_x0, crop_y0, crop_w, crop_h, result_logits};
endmodule
