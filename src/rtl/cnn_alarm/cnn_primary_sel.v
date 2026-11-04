`timescale 1ns/1ps
// cnn_primary_sel
// 功能：主目标选择，按面积、编号和槽位排序
// 输入：clk、rst_n、track_update、track_valid、track_id、track_cx等
// 输出：primary_valid、primary_idx、primary_id、primary_cx、primary_cy、primary_w等
module cnn_primary_sel #(
    parameter MAX_ROI = 4
) (
    input  wire clk,
    input  wire rst_n,
    input  wire track_update,
    input  wire [MAX_ROI-1:0]       track_valid,
    input  wire [MAX_ROI*8-1:0]     track_id,
    input  wire [MAX_ROI*12-1:0]    track_cx,
    input  wire [MAX_ROI*12-1:0]    track_cy,
    input  wire [MAX_ROI*12-1:0]    track_w,
    input  wire [MAX_ROI*12-1:0]    track_h,
    output reg                      primary_valid,
    output reg  [1:0]               primary_idx,
    output reg  [7:0]               primary_id,
    output reg  [11:0]              primary_cx,
    output reg  [11:0]              primary_cy,
    output reg  [11:0]              primary_w,
    output reg  [11:0]              primary_h,
    output reg                      primary_update
);
    // ---------------- stage 1: area register ----------------
    reg [23:0] area_q [0:MAX_ROI-1];
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < MAX_ROI; i = i + 1) area_q[i] <= 24'd0;
        end else if (track_update) begin
            for (i = 0; i < MAX_ROI; i = i + 1)
                area_q[i] <= track_w[i*12 +: 12] * track_h[i*12 +: 12];
        end
    end

    // ---------------- combinational selection ----------------
    integer j;
    reg [23:0] area;
    reg [23:0] best_area;
    reg [7:0]  id;
    reg        take;
    reg        sel_valid;
    reg [1:0]  sel_idx;
    reg [7:0]  sel_id;
    reg [11:0] sel_cx, sel_cy, sel_w, sel_h;
    always @* begin
        sel_valid = 1'b0;
        sel_idx   = 2'd0;
        sel_id    = 8'd0;
        sel_cx    = 12'd0;
        sel_cy    = 12'd0;
        sel_w     = 12'd0;
        sel_h     = 12'd0;
        best_area = 24'd0;
        for (j = 0; j < MAX_ROI; j = j + 1) begin
            area = area_q[j];
            id   = track_id[j*8 +: 8];
            take = 1'b0;
            if (track_valid[j]) begin
                if (!sel_valid) begin
                    take = 1'b1;
                end else if (area > best_area) begin
                    take = 1'b1;
                end else if (area == best_area) begin
                    if (id < sel_id) take = 1'b1;
                    else if (id == sel_id && j[1:0] < sel_idx) take = 1'b1;
                end
            end
            if (take) begin
                sel_valid = 1'b1;
                sel_idx   = j[1:0];
                sel_id    = id;
                sel_cx    = track_cx[j*12 +: 12];
                sel_cy    = track_cy[j*12 +: 12];
                sel_w     = track_w[j*12 +: 12];
                sel_h     = track_h[j*12 +: 12];
                best_area = area;
            end
        end
    end

    // ---------------- stage 2: output register ----------------
    reg upd_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            primary_valid <= 1'b0;
            primary_idx   <= 2'd0;
            primary_id    <= 8'd0;
            primary_cx    <= 12'd0;
            primary_cy    <= 12'd0;
            primary_w     <= 12'd0;
            primary_h     <= 12'd0;
            primary_update <= 1'b0;
            upd_d1        <= 1'b0;
        end else begin
            primary_valid <= sel_valid;
            primary_idx   <= sel_idx;
            primary_id    <= sel_id;
            primary_cx    <= sel_cx;
            primary_cy    <= sel_cy;
            primary_w     <= sel_w;
            primary_h     <= sel_h;
            primary_update <= upd_d1;
            upd_d1        <= track_update;
        end
    end
endmodule
