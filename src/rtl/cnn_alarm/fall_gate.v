`timescale 1ns/1ps
// fall_gate
// 功能：CNN 摔倒确认的证据门控
// 输入：clk、rst_n、result_valid、pred、signed、primary_update等
// 输出：fall_confirm、confident、motion_sig
module fall_gate #(
    parameter USE_MOTION     = 0,    // 1=高度塌陷也参与门控; 0=只认置信度(E2 仅诊断)
    parameter CONF_MARGIN    = 4,    // logit 边距(0~255)，越大越严格
    parameter COLLAPSE_NUM   = 7,    // 高度塌陷阈值 = h < h_ref*NUM/DEN
    parameter COLLAPSE_DEN   = 10,
    parameter COLLAPSE_HOLD  = 60,   // 塌陷证据保持帧数(60=1s@60fps)
    parameter DECAY_SHIFT    = 5     // h_ref 每帧衰减 h_ref/32(约3%)
) (
    input  wire        clk,
    input  wire        rst_n,
    // ---- 每次 CNN 推理完成一拍 ----
    input  wire        result_valid,
    input  wire [1:0]  pred,          // 0 normal / 1 fall / 2 other
    input  wire signed [7:0] logit0,
    input  wire signed [7:0] logit1,
    input  wire signed [7:0] logit2,
    // ---- 主目标快照(帧级) ----
    input  wire        primary_update, // 每帧一次脉冲
    input  wire        primary_valid,
    input  wire [7:0]  primary_id,
    input  wire [11:0] primary_h,
    // ---- 平滑后的原始确认 ----
    input  wire        fall_confirm_raw,
    // ---- 门控结果 ----
    output wire        fall_confirm,
    output reg         confident,      // 最近一次推理是否为“置信 fall”
    output reg         motion_sig      // 当前目标是否观察到高度塌陷(带保持)
);

    // ---------------------------------------------------------------- E1 置信度
    // logit 为 8bit 有符号；用 9bit 有符号做差，避免比较时位宽/符号混乱。
    wire signed [8:0] s_l0 = $signed({1'b0, logit0});
    wire signed [8:0] s_l1 = $signed({1'b0, logit1});
    wire signed [8:0] s_l2 = $signed({1'b0, logit2});
    wire signed [8:0] s_m  = CONF_MARGIN[8:0];
    wire confident_now = (pred == 2'd1) &&
                         (s_l1 > s_l0 + s_m) &&
                         (s_l1 > s_l2 + s_m);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            confident <= 1'b0;
        end else if (result_valid) begin
            confident <= confident_now;
        end
    end

    // ---------------------------------------------------------------- E2 高度塌陷
    // h_ref 跟踪主目标“近期最大高度”，带缓慢衰减：
    //   - 新目标/无目标：复位到当前 h(或 0)
    //   - h 增大：立即跟随
    //   - h 减小：每帧衰减 h_ref/32，只对“远快于透视变慢”的突变敏感
    reg [11:0] h_ref;
    reg [7:0]  locked_id;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_ref     <= 12'd0;
            locked_id <= 8'd0;
        end else if (primary_update) begin
            if (!primary_valid) begin
                h_ref <= 12'd0;
            end else if (locked_id != primary_id) begin
                locked_id <= primary_id;
                h_ref     <= primary_h;
            end else if (primary_h > h_ref) begin
                h_ref <= primary_h;
            end else if (h_ref > (h_ref >> DECAY_SHIFT)) begin
                h_ref <= h_ref - (h_ref >> DECAY_SHIFT);
            end
        end
    end

    // h < h_ref * NUM/DEN  <=>  h*DEN < h_ref*NUM
    wire [15:0] h_times_den  = {4'd0, primary_h} * COLLAPSE_DEN;
    wire [15:0] href_times_n = {4'd0, h_ref}     * COLLAPSE_NUM;
    wire collapse_now = primary_valid && (h_ref != 12'd0) &&
                        (h_times_den < href_times_n);

    reg [7:0] collapse_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            motion_sig   <= 1'b0;
            collapse_cnt <= 8'd0;
        end else if (primary_update && (!primary_valid || locked_id != primary_id)) begin
            motion_sig   <= 1'b0;
            collapse_cnt <= 8'd0;
        end else if (collapse_now) begin
            motion_sig   <= 1'b1;
            collapse_cnt <= COLLAPSE_HOLD[7:0];
        end else if (motion_sig && primary_update) begin
            if (collapse_cnt == 8'd0) motion_sig <= 1'b0;
            else                       collapse_cnt <= collapse_cnt - 8'd1;
        end
    end

    // ---------------------------------------------------------------- 门控锁存
    reg gate_ok;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gate_ok <= 1'b0;
        end else if (primary_update && (!primary_valid || locked_id != primary_id)) begin
            gate_ok <= 1'b0;
        end else if (!fall_confirm_raw) begin
            gate_ok <= 1'b0;
        end else if (result_valid && pred == 2'd1 &&
                     (confident_now || (USE_MOTION && collapse_now))) begin
            gate_ok <= 1'b1;
        end
    end

    assign fall_confirm = fall_confirm_raw && gate_ok;

endmodule
