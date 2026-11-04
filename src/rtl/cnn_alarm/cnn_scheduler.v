`timescale 1ns/1ps
// cnn_scheduler
// 功能：CNN 任务调度，管理三个缓存区和单一计算核
// 输入：clk、rst_n、track_update、track_valid、track_id、primary_idx等
// 输出：crop_start、crop_bank、core_start、core_bank、result_valid、result_logits等
module cnn_scheduler (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        track_update,
    input  wire        track_valid,
    input  wire [7:0]  track_id,
    input  wire [1:0]  primary_idx,
    input  wire [15:0] frame_id,
    // crop
    output wire        crop_start,
    output wire [1:0]  crop_bank,
    input  wire        crop_busy,
    input  wire        crop_done,
    input  wire [1:0]  crop_done_bank,
    // core
    output reg         core_start,
    output reg  [1:0]  core_bank,
    input  wire        core_busy,
    input  wire        core_done,
    input  wire [23:0] logits,
    // result
    output reg         result_valid,
    output reg  [23:0] result_logits,
    output reg  [15:0] task_frame_id,
    output reg  [7:0]  task_track_id,
    output reg  [1:0]  task_primary_idx,
    // stats
    output reg  [15:0] drop_count,
    output reg  [15:0] bank_stall,
    output wire        busy
);
    localparam B_FREE = 2'd0, B_CROP = 2'd1, B_READY = 2'd2, B_CORE = 2'd3;

    reg [5:0] bstate;                 // 3 x 2 bits

    // ready slot
    reg        rd_valid;
    reg [1:0]  rd_bank;
    reg [15:0] rd_frame;
    reg [7:0]  rd_id;
    reg [1:0]  rd_idx;
    // crop descriptor
    reg [15:0] cd_frame;
    reg [7:0]  cd_id;
    reg [1:0]  cd_idx;
    // core descriptor
    reg [15:0] cc_frame;
    reg [7:0]  cc_id;
    reg [1:0]  cc_idx;

    integer bi;
    reg free_found;
    reg [1:0] free_idx;

    always @* begin
        free_found = 1'b0;
        free_idx   = 2'd0;
        for (bi = 0; bi < 3; bi = bi + 1) begin
            if (!free_found && (bstate[2*bi +: 2] == B_FREE)) begin
                free_found = 1'b1;
                free_idx   = bi[1:0];
            end
        end
    end

    assign busy       = core_busy;

    // One-cycle command snapshot: the control logic never sees the live track
    // bus combinationally (that cone was the remaining whole-chip violation).
    reg        cmd_v;
    reg        cmd_tv;
    reg [7:0]  cmd_id;
    reg [1:0]  cmd_idx;
    reg [15:0] cmd_frame;
    always @(posedge clk) begin
        if (!rst_n) begin
            cmd_v <= 1'b0; cmd_tv <= 1'b0; cmd_id <= 8'd0;
            cmd_idx <= 2'd0; cmd_frame <= 16'd0;
        end else begin
            cmd_v     <= track_update;
            cmd_tv    <= track_valid;
            cmd_id    <= track_id;
            cmd_idx   <= primary_idx;
            cmd_frame <= frame_id;
        end
    end

    assign crop_start = cmd_v && cmd_tv && !crop_busy && free_found;
    assign crop_bank  = free_idx;

    always @(posedge clk) begin
        if (!rst_n) begin
            bstate        <= 6'd0;
            rd_valid      <= 1'b0;
            rd_bank       <= 2'd0;
            rd_frame      <= 16'd0;
            rd_id         <= 8'd0;
            rd_idx        <= 2'd0;
            cd_frame      <= 16'd0;
            cd_id         <= 8'd0;
            cd_idx        <= 2'd0;
            cc_frame      <= 16'd0;
            cc_id         <= 8'd0;
            cc_idx        <= 2'd0;
            core_start    <= 1'b0;
            core_bank     <= 2'd0;
            result_valid  <= 1'b0;
            result_logits <= 24'd0;
            task_frame_id <= 16'd0;
            task_track_id <= 8'd0;
            task_primary_idx <= 2'd0;
            drop_count    <= 16'd0;
            bank_stall    <= 16'd0;
        end else begin
            core_start   <= 1'b0;
            result_valid <= 1'b0;

            // 1) target lost or id changed: invalidate the ready task
            if (cmd_v && rd_valid &&
                (!cmd_tv || (cmd_id != rd_id))) begin
                bstate[2*rd_bank +: 2] <= B_FREE;
                rd_valid               <= 1'b0;
                drop_count             <= drop_count + 16'd1;
            end

            // 2) new crop accepted (combinational start, registered bookkeeping)
            if (crop_start) begin
                bstate[2*free_idx +: 2] <= B_CROP;
                cd_frame <= cmd_frame;
                cd_id    <= cmd_id;
                cd_idx   <= cmd_idx;
            end else if (cmd_v && cmd_tv && !crop_busy && !free_found) begin
                bank_stall <= bank_stall + 16'd1;
            end

            // 3) crop finished
            if (crop_done) begin
                if (rd_valid) begin
                    bstate[2*rd_bank +: 2] <= B_FREE;
                    drop_count             <= drop_count + 16'd1;
                end
                rd_valid <= 1'b1;
                rd_bank  <= crop_done_bank;
                rd_frame <= cd_frame;
                rd_id    <= cd_id;
                rd_idx   <= cd_idx;
                bstate[2*crop_done_bank +: 2] <= B_READY;
            end

            // 4) core finished
            if (core_done) begin
                result_valid     <= 1'b1;
                result_logits    <= logits;
                task_frame_id    <= cc_frame;
                task_track_id    <= cc_id;
                task_primary_idx <= cc_idx;
                bstate[2*core_bank +: 2] <= B_FREE;
            end

            // 5) launch the core when a ready task exists and the core is idle
            if (rd_valid && !core_busy && !core_start) begin
                core_start            <= 1'b1;
                core_bank             <= rd_bank;
                bstate[2*rd_bank +: 2] <= B_CORE;
                cc_frame              <= rd_frame;
                cc_id                 <= rd_id;
                cc_idx                <= rd_idx;
                rd_valid              <= 1'b0;
            end
        end
    end
endmodule
