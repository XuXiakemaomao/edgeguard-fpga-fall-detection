`timescale 1ns/1ps
// cnn_roi_crop
// 功能：从 640×360 视频流裁剪 48×48 目标区域
// 输入：clk、rst_n、gray、de、hs、vs等
// 输出：we、addr、data、done、done_bank、busy等
module cnn_roi_crop #(
    parameter W = 640,
    parameter H = 360,
    parameter R = 48
) (
    input  wire        clk,
    input  wire        rst_n,
    // video in
    input  wire [7:0]  gray,
    input  wire        de,
    input  wire        hs,
    input  wire        vs,
    input  wire [15:0] frame_id,
    // track snapshot
    input  wire        track_update,
    input  wire        track_valid,
    input  wire [7:0]  track_id,
    input  wire [11:0] track_cx,
    input  wire [11:0] track_cy,
    input  wire [11:0] track_w,
    input  wire [11:0] track_h,
    // control
    input  wire        start,
    input  wire [1:0]  bank,
    // ROI write port
    output wire        we,
    output wire [11:0] addr,
    output wire [7:0]  data,
    output reg         done,
    output reg  [1:0]  done_bank,
    output reg         busy,
    output reg         timeout,
    // snapshot / debug
    output reg  [15:0] snap_frame,
    output reg  [7:0]  snap_id,
    output reg  [11:0] snap_x0,
    output reg  [11:0] snap_y0,
    output reg  [11:0] snap_w,
    output reg  [11:0] snap_h
);
    localparam S_IDLE  = 3'd0,
               S_PREP  = 3'd1,
               S_WAIT  = 3'd2,
               S_FRAME = 3'd3,
               S_DRAIN = 3'd4,
               S_SNAP  = 3'd5;

    localparam SQ_IDLE     = 3'd0,
               SQ_RD_A     = 3'd1,
               SQ_RD_B     = 3'd2,
               SQ_RD_C     = 3'd3,
               SQ_SCAN     = 3'd4,
               SQ_SCAN_END = 3'd5;

    localparam W_IDLE = 2'd0, W_WR = 2'd1;

    // ---------------------------------------------------------------- box geometry
    // Declared before the combinational geometry wires to avoid Vivado
    // "used before its declaration" warnings.
    reg [11:0] cx_r, cy_r, w_r, h_r;
    wire signed [15:0] cx_s = $signed({4'd0, cx_r});
    wire signed [15:0] cy_s = $signed({4'd0, cy_r});
    wire signed [15:0] w_s  = $signed({4'd0, w_r});
    wire signed [15:0] h_s  = $signed({4'd0, h_r});
    wire signed [15:0] x0_i = cx_s - (w_s >>> 1);
    wire signed [15:0] y0_i = cy_s - (h_s >>> 1);
    wire signed [15:0] x1_i = x0_i + w_s - 16'sd1;
    wire signed [15:0] y1_i = y0_i + h_s - 16'sd1;

    wire signed [15:0] x0_c = (x0_i < 0) ? 16'sd0 : x0_i;
    wire signed [15:0] y0_c = (y0_i < 0) ? 16'sd0 : y0_i;
    wire signed [15:0] x1_c = (x1_i > W-1) ? W-1 : x1_i;
    wire signed [15:0] y1_c = (y1_i > H-1) ? H-1 : y1_i;
    wire               box_ok = (w_s > 0) && (h_s > 0) && (x1_c >= x0_c) && (y1_c >= y0_c);

    // ---------------------------------------------------------------- registers
    reg [2:0]  state;
    reg [2:0]  seq_state;
    reg [5:0]  prep_i;
    reg        prep_ph;
    reg [16:0] mul_x, mul_y;

    reg [11:0] x0r, y0r, src_w, src_h;
    reg [11:0] sx_tab [0:47];
    reg [8:0]  sy_tab [0:47];

    reg [1:0]  bank_r;
    reg [7:0]  id_r;
    reg [8:0]  y_cur;
    reg [9:0]  x_cur;
    reg        capturing;

    reg        scan_needed;
    reg [5:0]  scan_first, scan_last;
    reg [5:0]  scan_i;
    reg        pend_needed;
    reg [5:0]  pend_first, pend_last;
    reg [5:0]  rd_first, rd_last;
    reg        rd_sel;
    reg        seq_after_scan;

    // ---------------------------------------------------------------- line cache
    reg  [7:0]  lbuf [0:2*W-1];
    wire        line_start = de && (hs || vs);
    wire        wr_sel  = vs ? 1'b0 : (line_start ? ~y_cur[0] : y_cur[0]);
    wire [9:0]  wx      = line_start ? 10'd0 : x_cur;
    wire [10:0] wr_addr = wr_sel ? (11'd640 + {1'b0, wx}) : {1'b0, wx};
    wire        wr_en   = de && (capturing || (state == S_WAIT && vs));

    reg  [5:0]  rd_cnt;
    wire [11:0] lbuf_rax  = {1'b0, sx_tab[rd_cnt]};
    wire [10:0] lbuf_raddr_w = rd_sel ? (11'd640 + lbuf_rax[10:0]) : lbuf_rax[10:0];
    wire        lbuf_re = (seq_state == SQ_RD_A);
    reg  [7:0]  lbuf_dout;
    always @(posedge clk) begin
        if (wr_en) lbuf[wr_addr] <= gray;
        if (lbuf_re) lbuf_dout <= lbuf[lbuf_raddr_w];
    end

    // ---------------------------------------------------------------- input quantisation
    wire [7:0] qin_data;
    qin_rom u_qin (
        .clk(clk),
        .addr(lbuf_dout),
        .data(qin_data)
    );

    // ---------------------------------------------------------------- row record queue
    // 8 entries x 48 pixels, addressed as {head, dx}.  A combinational read
    // keeps the drain at one destination write per cycle so a small box with a
    // large per-row fan-out never backs the queue up.
    reg  [7:0]  fifo_mem [0:8*64-1];
    reg  [2:0]  f_head, f_tail;
    reg  [7:0]  f_valid;
    reg  [5:0]  f_first [0:7];
    reg  [5:0]  f_last  [0:7];
    reg  [5:0]  wr_dx, wr_dy;
    reg  [1:0]  wstate;
    reg  [6:0]  rows_done;
    reg         overflow;
    reg  [1:0]  drain_vs;

    wire [8:0] fifo_waddr = {f_tail, rd_cnt};
    wire [8:0] fifo_raddr = {f_head, wr_dx};
    wire       fifo_we    = (seq_state == SQ_RD_C);
    wire [7:0] fifo_rdata = fifo_mem[fifo_raddr];
    always @(posedge clk) begin
        if (fifo_we) fifo_mem[fifo_waddr] <= qin_data;
    end

    // ---------------------------------------------------------------- ROI write port
    assign we   = (wstate == 2'd1);
    assign addr = wr_dy * 6'd48 + wr_dx;
    assign data = fifo_rdata;

    // ---------------------------------------------------------------- prep arithmetic
    wire [16:0] mul_x_n = ({11'd0, prep_i} * 2 + 17'd1) * src_w;
    wire [16:0] mul_y_n = ({11'd0, prep_i} * 2 + 17'd1) * src_h;
    wire [31:0] sx_prod = mul_x * 32'd43691;
    wire [31:0] sy_prod = mul_y * 32'd43691;
    wire [11:0] sx_off  = sx_prod[31:22];
    wire [8:0]  sy_off  = sy_prod[30:22];

    wire _unused = track_update;

    // end of the last active line: triggers the final row read-out without
    // depending on the next vs (the row data is complete at this pixel)
    wire frame_end_now = de && (x_cur == W-1) && (y_cur == H-1);

    // ---------------------------------------------------------------- main FSM
    always @(posedge clk) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            seq_state      <= SQ_IDLE;
            prep_i         <= 6'd0;
            prep_ph        <= 1'b0;
            mul_x          <= 17'd0;
            mul_y          <= 17'd0;
            x0r            <= 12'd0;
            y0r            <= 12'd0;
            src_w          <= 12'd0;
            src_h          <= 12'd0;
            bank_r         <= 2'd0;
            cx_r           <= 12'd0;
            cy_r           <= 12'd0;
            w_r            <= 12'd0;
            h_r            <= 12'd0;
            id_r           <= 8'd0;
            y_cur          <= 9'd0;
            x_cur          <= 10'd0;
            capturing      <= 1'b0;
            scan_needed    <= 1'b0;
            scan_first     <= 6'd0;
            scan_last      <= 6'd0;
            scan_i         <= 6'd0;
            pend_needed    <= 1'b0;
            pend_first     <= 6'd0;
            pend_last      <= 6'd0;
            rd_first       <= 6'd0;
            rd_last        <= 6'd0;
            rd_sel         <= 1'b0;
            seq_after_scan <= 1'b0;
            f_head         <= 3'd0;
            f_tail         <= 3'd0;
            f_valid        <= 8'd0;
            rd_cnt         <= 6'd0;
            wr_dx          <= 6'd0;
            wr_dy          <= 6'd0;
            wstate         <= W_IDLE;
            rows_done      <= 7'd0;
            overflow       <= 1'b0;
            drain_vs       <= 2'd0;
            done           <= 1'b0;
            done_bank      <= 2'd0;
            busy           <= 1'b0;
            timeout        <= 1'b0;
            snap_frame     <= 16'd0;
            snap_id        <= 8'd0;
            snap_x0        <= 12'd0;
            snap_y0        <= 12'd0;
            snap_w         <= 12'd0;
            snap_h         <= 12'd0;
        end else begin
            done    <= 1'b0;
            timeout <= 1'b0;

            // ---------------------------------------------------- stream counters
            if (de) begin
                x_cur <= line_start ? 10'd1 : x_cur + 10'd1;
                if (vs)              y_cur <= 9'd0;
                else if (line_start) y_cur <= y_cur + 9'd1;
            end
            if (line_start) rd_sel <= y_cur[0];  // y_cur is the line that just ended

            // ---------------------------------------------------- main state
            case (state)
                S_IDLE: begin
                    capturing <= 1'b0;
                    if (start && track_valid) begin
                        // stage 1: register the raw snapshot only.  Geometry is
                        // evaluated in S_SNAP so the 12-bit adders / comparators
                        // never depend on the live track bus in the same cycle
                        // (that cone was the -9.2 ns whole-chip violation).
                        cx_r <= track_cx;
                        cy_r <= track_cy;
                        w_r  <= track_w;
                        h_r  <= track_h;
                        id_r <= track_id;
                        bank_r <= bank;
                        state <= S_SNAP;
                    end
                end

                S_SNAP: begin
                    if (box_ok) begin
                        x0r         <= x0_c[11:0];
                        y0r         <= y0_c[11:0];
                        src_w       <= x1_c[11:0] - x0_c[11:0] + 12'd1;
                        src_h       <= y1_c[11:0] - y0_c[11:0] + 12'd1;
                        snap_id     <= id_r;
                        snap_x0     <= x0_c[11:0];
                        snap_y0     <= y0_c[11:0];
                        snap_w      <= x1_c[11:0] - x0_c[11:0] + 12'd1;
                        snap_h      <= y1_c[11:0] - y0_c[11:0] + 12'd1;
                        busy        <= 1'b1;
                        prep_i      <= 6'd0;
                        prep_ph     <= 1'b0;
                        x_cur       <= 10'd0;
                        y_cur       <= 9'd0;
                        f_head      <= 3'd0;
                        f_tail      <= 3'd0;
                        f_valid     <= 8'd0;
                        rows_done   <= 7'd0;
                        overflow    <= 1'b0;
                        drain_vs    <= 2'd0;
                        pend_needed <= 1'b0;
                        wstate      <= W_IDLE;
                        seq_state   <= SQ_IDLE;
                        state       <= S_PREP;
                    end else begin
                        state <= S_IDLE;
                    end
                end

                S_PREP: begin
                    if (prep_ph == 1'b0) begin
                        mul_x   <= mul_x_n;
                        mul_y   <= mul_y_n;
                        prep_ph <= 1'b1;
                    end else begin
                        sx_tab[prep_i] <= x0r + sx_off;
                        sy_tab[prep_i] <= y0r + sy_off;
                        prep_ph <= 1'b0;
                        if (prep_i == R-1) state <= S_WAIT;
                        else               prep_i <= prep_i + 6'd1;
                    end
                end

                S_WAIT: begin
                    if (vs) begin
                        snap_frame  <= frame_id;
                        y_cur       <= 9'd0;
                        capturing   <= 1'b1;
                        scan_needed <= 1'b0;
                        scan_first  <= 6'd0;
                        scan_last   <= 6'd0;
                        scan_i      <= 6'd0;
                        seq_state   <= SQ_SCAN;
                        state       <= S_FRAME;
                    end
                end

                S_FRAME: begin
                    if (frame_end_now) begin
                        rd_first       <= pend_first;
                        rd_last        <= pend_last;
                        rd_sel         <= y_cur[0];
                        rd_cnt         <= 6'd0;
                        seq_after_scan <= 1'b0;
                        capturing      <= 1'b0;
                        if (pend_needed) seq_state <= SQ_RD_A;
                        else begin seq_state <= SQ_IDLE; state <= S_DRAIN; end
                    end else if (line_start) begin
                        rd_first  <= pend_first;
                        rd_last   <= pend_last;
                        rd_cnt    <= 6'd0;
                        seq_after_scan <= !vs;
                        if (vs) begin
                            capturing <= 1'b0;
                            if (pend_needed) seq_state <= SQ_RD_A;
                            else begin seq_state <= SQ_IDLE; state <= S_DRAIN; end
                        end else begin
                            if (pend_needed) seq_state <= SQ_RD_A;
                            else begin
                                scan_i      <= 6'd0;
                                scan_needed <= 1'b0;
                                seq_state   <= SQ_SCAN;
                            end
                        end
                    end
                end

                S_DRAIN: begin
                    if (vs) begin
                        drain_vs <= drain_vs + 2'd1;
                        if (drain_vs == 2'd1 && rows_done != 7'd48) begin
                            timeout <= 1'b1;
                            busy    <= 1'b0;
                            state   <= S_IDLE;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase

            // ---------------------------------------------------- line sequence
            case (seq_state)
                SQ_IDLE: ;
                SQ_RD_A: seq_state <= SQ_RD_B;
                SQ_RD_B: seq_state <= SQ_RD_C;
                SQ_RD_C: begin
                    if (!f_valid[f_tail]) begin
                        if (rd_cnt == R-1) begin
                            f_first[f_tail] <= rd_first;
                            f_last[f_tail]  <= rd_last;
                            f_valid[f_tail] <= 1'b1;
                            f_tail          <= f_tail + 3'd1;
                            rd_cnt          <= 6'd0;
                            if (seq_after_scan) begin
                                scan_i      <= 6'd0;
                                scan_needed <= 1'b0;
                                seq_state   <= SQ_SCAN;
                            end else begin
                                seq_state   <= SQ_IDLE;
                                state       <= S_DRAIN;
                            end
                        end else begin
                            rd_cnt    <= rd_cnt + 6'd1;
                            seq_state <= SQ_RD_A;
                        end
                    end else begin
                        // queue full: drop the crop, never publish a partial ROI
                        overflow  <= 1'b1;
                        seq_state <= SQ_IDLE;
                        state     <= S_DRAIN;
                    end
                end
                SQ_SCAN: begin
                    if (sy_tab[scan_i] == y_cur) begin
                        if (!scan_needed) scan_first <= scan_i;
                        scan_last   <= scan_i;
                        scan_needed <= 1'b1;
                    end
                    if (scan_i == R-1) begin
                        scan_i    <= 6'd0;
                        seq_state <= SQ_SCAN_END;
                    end else begin
                        scan_i    <= scan_i + 6'd1;
                    end
                end
                SQ_SCAN_END: begin
                    pend_needed <= scan_needed;
                    pend_first  <= scan_first;
                    pend_last   <= scan_last;
                    seq_state   <= SQ_IDLE;
                end
                default: seq_state <= SQ_IDLE;
            endcase

            // ---------------------------------------------------- drain engine
            case (wstate)
                W_IDLE: begin
                    if (f_head != f_tail) begin
                        wr_dx  <= 6'd0;
                        wr_dy  <= f_first[f_head];
                        wstate <= W_WR;
                    end
                end
                W_WR: begin
                    if (wr_dx == R-1) begin
                        wr_dx <= 6'd0;
                        if (wr_dy == f_last[f_head]) begin
                            rows_done <= rows_done + (f_last[f_head] - f_first[f_head] + 6'd1);
                            f_valid[f_head] <= 1'b0;
                            f_head    <= f_head + 3'd1;
                            wstate    <= W_IDLE;
                        end else begin
                            wr_dy  <= wr_dy + 6'd1;
                        end
                    end else begin
                        wr_dx  <= wr_dx + 6'd1;
                    end
                end
                default: wstate <= W_IDLE;
            endcase

            // completion / abort
            if (state == S_DRAIN && rows_done == 7'd48 && !overflow && wstate == W_IDLE
                && f_head == f_tail) begin
                done      <= 1'b1;
                done_bank <= bank_r;
                busy      <= 1'b0;
                state     <= S_IDLE;
            end
        end
    end
endmodule
