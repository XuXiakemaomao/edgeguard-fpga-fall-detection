`timescale 1ns/1ps
// cnn_core
// 功能：8 位整数 CNN 计算核，完成卷积、池化、全局平均池化和三分类输出
// 输入：clk、rst_n、start、bank、roi_we、roi_wbank等
// 输出：busy、done、logit0、logit1、logit2、pred等
module cnn_core (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [1:0]  bank,
    output reg         busy,
    output reg         done,
    output reg  [7:0]  logit0,
    output reg  [7:0]  logit1,
    output reg  [7:0]  logit2,
    output reg  [1:0]  pred,
    output reg         result_invalid,
    input  wire        roi_we,
    input  wire [1:0]  roi_wbank,
    input  wire [11:0] roi_waddr,
    input  wire [7:0]  roi_wdata,
    input  wire        dbg_en,
    input  wire [2:0]  dbg_sel,
    input  wire [14:0] dbg_addr,
    output reg  [7:0]  dbg_data
);
    // 量化参数直接内联，避免 Vivado project 模式下 include 搜索路径不一致。
    // 与 rtl/qparams.vh（gen_model.py 生成）保持一致。
    localparam signed [15:0] M_L1  = 16'sd16515;
    localparam [5:0]         QS_L1 = 6'd22;
    localparam signed [15:0] M_L2  = 16'sd18166;
    localparam [5:0]         QS_L2 = 6'd21;
    localparam signed [15:0] M_L3  = 16'sd18791;
    localparam [5:0]         QS_L3 = 6'd22;
    localparam signed [15:0] M_FC  = 16'sd31369;
    localparam [5:0]         QS_FC = 6'd20;
    // ---------------------------------------------------------------- memories
    reg [7:0] roi [0:6911];
    reg [7:0] f1  [0:18431];
    reg [7:0] p1  [0:4607];
    reg [7:0] f2  [0:9215];
    reg [7:0] p2  [0:2303];
    reg [7:0] f3  [0:4607];
    reg [7:0] gap [0:31];

    reg [7:0]  w1 [0:71];
    reg [7:0]  w2 [0:1151];
    reg [7:0]  w3 [0:4607];
    reg [7:0]  w4 [0:95];
    reg [31:0] b1 [0:7];
    reg [31:0] b2 [0:15];
    reg [31:0] b3 [0:31];
    reg [31:0] b4 [0:2];

    integer ii;
    initial begin
        for (ii = 0; ii < 6912; ii = ii + 1) roi[ii] = 8'd0;
        for (ii = 0; ii < 18432; ii = ii + 1) f1[ii] = 8'd0;
        for (ii = 0; ii < 9216; ii = ii + 1) f2[ii] = 8'd0;
        $readmemh("../../../weights/w1.mem", w1);
        $readmemh("../../../weights/w2.mem", w2);
        $readmemh("../../../weights/w3.mem", w3);
        $readmemh("../../../weights/w4.mem", w4);
        $readmemh("../../../weights/b1.mem", b1);
        $readmemh("../../../weights/b2.mem", b2);
        $readmemh("../../../weights/b3.mem", b3);
        $readmemh("../../../weights/b4.mem", b4);
    end

    // ---------------------------------------------------------------- states
    localparam S_IDLE = 5'd0,
               S_BIAS = 5'd1,
               S_BIASC= 5'd2,
               S_PIX  = 5'd3,
               S_ADDR = 5'd4,
               S_MAC  = 5'd5,
               S_CAP  = 5'd6,
               S_OUT  = 5'd7,
               S_P1A  = 5'd8,
               S_P1R  = 5'd9,
               S_P1C  = 5'd10,
               S_P1W  = 5'd11,
               S_P2A  = 5'd12,
               S_P2R  = 5'd13,
               S_P2C  = 5'd14,
               S_P2W  = 5'd15,
               S_GAPA = 5'd16,
               S_GAPR = 5'd17,
               S_GAPC = 5'd18,
               S_GAPW = 5'd19,
               S_FCB  = 5'd20,
               S_FBC  = 5'd21,
               S_FC   = 5'd22,
               S_FCC  = 5'd23,
               S_FCW  = 5'd24,
               S_FIN  = 5'd25;

    reg [4:0]  state;
    reg [1:0]  layer;
    reg [1:0]  bank_r;
    reg [5:0]  ih, iw, oh, ow, icn, ocn;
    reg [11:0] ihiw;
    reg [5:0]  oc, oy, ox;
    reg [4:0]  ic;
    reg [3:0]  k;
    reg [2:0]  in_sel;
    reg signed [31:0] acc;
    reg signed [31:0] bias_q;
    reg        ib_r;
    reg [1:0]  ps;
    reg [7:0]  maxv;
    reg [7:0]  gi;
    reg [31:0] gsum;
    reg [1:0]  foc;
    reg [4:0]  fk;
    reg signed [31:0] facc;

    reg [14:0] raddr_r;
    reg [14:0] ic_base;
    reg [14:0] out_off_r;
    reg [12:0] waddr_r;
    wire       rd_in  = (state == S_MAC) || (state == S_P1R) || (state == S_P2R) || (state == S_GAPR);
    wire       rd_w   = (state == S_MAC);
    wire       rd_b   = (state == S_BIAS);
    wire       rd_b4  = (state == S_FCB);
    wire       rd_w4  = (state == S_FC);
    wire [4:0] raddr_b = oc[4:0];
    reg [7:0]  dout_in, dout_w;
    reg signed [31:0] dout_b, dout_b4;
    reg [7:0]  dout_w4;

    // ---------------------------------------------------------------- quantisation
    // M/S are latched per layer at S_BIAS.  Driving the requant multiplier
    // directly from the layer register created a layer -> mux -> multiplier ->
    // BRAM write-data path that failed whole-chip timing by 2.7 ns.
    reg signed [15:0] m_r;
    reg [5:0]         s_r;

    function [7:0] requant8;
        input signed [31:0] a;
        input signed [15:0] m;
        input [5:0]        s;
        reg signed [63:0] p;
        reg signed [63:0] q;
        begin
            p = a * m;
            if (p >= 0) q = (p + (64'sd1 <<< (s - 1))) >>> s;
            else        q = -(((-p) + (64'sd1 <<< (s - 1))) >>> s);
            if (q > 64'sd127)       requant8 = 8'd127;
            else if (q < -64'sd128) requant8 = 8'h80;
            else                    requant8 = q[7:0];
        end
    endfunction

    function [7:0] gapq;
        input signed [31:0] s;
        reg signed [63:0] t;
        begin
            t = (s * 64'sd116508 + 64'sd8388608) >>> 24;
            if (t > 64'sd127)       gapq = 8'd127;
            else if (t < -64'sd128) gapq = 8'h80;
            else                    gapq = t[7:0];
        end
    endfunction

    // ---------------------------------------------------------------- address maths
    wire [3:0] kh = k / 4'd3;
    wire [3:0] kw = k - (k / 4'd3) * 4'd3;
    wire signed [7:0] sy_s = $signed({2'b0, oy}) + $signed({4'b0, kh}) - 8'sd1;
    wire signed [7:0] sx_s = $signed({2'b0, ox}) + $signed({4'b0, kw}) - 8'sd1;
    wire inb = (sy_s >= 0) && (sy_s < $signed({2'b0, ih})) &&
               (sx_s >= 0) && (sx_s < $signed({2'b0, iw}));
    wire [5:0] sy = (sy_s < 0) ? 6'd0 : (sy_s >= $signed({2'b0, ih})) ? (ih - 6'd1) : sy_s[5:0];
    wire [5:0] sx = (sx_s < 0) ? 6'd0 : (sx_s >= $signed({2'b0, iw})) ? (iw - 6'd1) : sx_s[5:0];

    // ic*ihiw is maintained incrementally in ic_base, so the address path only
    // contains one multiply (sy*iw) instead of two cascaded DSPs.  The old
    // expression failed setup by -0.225 ns at 74.25 MHz.
    wire [14:0] conv_off = ic_base + sy * iw + sx;
    wire [12:0] roi_off  = bank_r * 13'd2304 + conv_off[12:0];
    wire [14:0] pool_off = oc * ihiw + (oy * 2 + ps[1]) * iw + (ox * 2 + ps[0]);
    wire [14:0] gap_off  = oc * 12'd144 + gi;
    wire [14:0] out_off  = oc * oh * ow + oy * ow + ox;
    wire [12:0] w_off    = (oc * icn + ic) * 9 + k;

    wire [7:0] rq  = requant8(acc, m_r, s_r);
    wire [7:0] rqa = rq[7] ? 8'd0 : rq;

    // ---------------------------------------------------------------- read ports
    always @(posedge clk) begin
        if (rd_in) begin
            case (in_sel)
                3'd0: dout_in <= roi[raddr_r[12:0]];
                3'd1: dout_in <= p1[raddr_r[12:0]];
                3'd2: dout_in <= p2[raddr_r[11:0]];
                3'd3: dout_in <= f1[raddr_r[14:0]];
                3'd4: dout_in <= f2[raddr_r[13:0]];
                default: dout_in <= f3[raddr_r[12:0]];
            endcase
        end
        if (rd_w) begin
            case (layer)
                2'd1: dout_w <= w1[waddr_r[6:0]];
                2'd2: dout_w <= w2[waddr_r[10:0]];
                default: dout_w <= w3[waddr_r[12:0]];
            endcase
        end
        if (rd_b) begin
            case (layer)
                2'd1: dout_b <= b1[raddr_b[2:0]];
                2'd2: dout_b <= b2[raddr_b[3:0]];
                default: dout_b <= b3[raddr_b[4:0]];
            endcase
        end
        if (rd_b4) dout_b4 <= b4[foc];
        if (rd_w4) dout_w4 <= w4[foc*32 + fk];
    end

    // ---------------------------------------------------------------- write ports
    // The feature-map write is registered one cycle after S_OUT.  Writing
    // combinationally put the whole layer -> mux -> requant cone onto the BRAM
    // data/enable pins, which failed whole-chip timing.  Writes are >= 5 cycles
    // apart, so a one-cycle pending slot never collides.
    reg        wr_pend;
    reg [14:0] wr_addr_r;
    reg [7:0]  wr_data_r;
    reg [1:0]  wr_layer_r;

    // Control registers: single driver, async reset is fine here.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_pend    <= 1'b0;
            wr_addr_r  <= 15'd0;
            wr_data_r  <= 8'd0;
            wr_layer_r <= 2'd0;
        end else begin
            if (state == S_OUT) begin
                wr_pend    <= 1'b1;
                wr_addr_r  <= out_off_r;
                wr_data_r  <= rqa;
                wr_layer_r <= layer;
            end else if (wr_pend) begin
                wr_pend <= 1'b0;
            end
        end
    end

    // Memory write ports MUST stay in a plain clocked block (no async reset),
    // otherwise Vivado cannot infer the feature-map RAM (Synth 8-3391:
    // "RAM is sensitive to asynchronous reset signal").
    always @(posedge clk) begin
        if (roi_we) roi[roi_wbank*2304 + roi_waddr] <= roi_wdata;
        if (wr_pend) begin
            case (wr_layer_r)
                2'd1: f1[wr_addr_r[14:0]] <= wr_data_r;
                2'd2: f2[wr_addr_r[13:0]] <= wr_data_r;
                default: f3[wr_addr_r[12:0]] <= wr_data_r;
            endcase
        end
        if (state == S_P1W) p1[out_off_r[12:0]] <= maxv;
        if (state == S_P2W) p2[out_off_r[11:0]] <= maxv;
        if (state == S_GAPW) gap[oc[4:0]] <= gapq(gsum);
    end

    // ---------------------------------------------------------------- debug
    always @(posedge clk) begin
        if (dbg_en) begin
            case (dbg_sel)
                3'd0: dbg_data <= f1[dbg_addr];
                3'd1: dbg_data <= f2[dbg_addr[13:0]];
                3'd2: dbg_data <= f3[dbg_addr[12:0]];
                default: dbg_data <= roi[bank_r*2304 + dbg_addr[11:0]];
            endcase
        end
    end

    // ---------------------------------------------------------------- FSM
    always @(posedge clk) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            busy           <= 1'b0;
            done           <= 1'b0;
            logit0         <= 8'd0;
            logit1         <= 8'd0;
            logit2         <= 8'd0;
            pred           <= 2'd0;
            result_invalid <= 1'b0;
            oc <= 6'd0; oy <= 6'd0; ox <= 6'd0; ic <= 5'd0; k <= 4'd0;
            m_r <= M_L1; s_r <= QS_L1;
            // wr_pend / wr_addr_r / wr_data_r / wr_layer_r are owned by the
            // feature-map write always block above (it has its own reset).
            acc <= 32'd0; bias_q <= 32'd0; ib_r <= 1'b0; ps <= 2'd0; maxv <= 8'd0;
            gi <= 8'd0; gsum <= 32'd0; foc <= 2'd0; fk <= 5'd0; facc <= 32'd0;
            layer <= 2'd1; in_sel <= 3'd0; bank_r <= 2'd0;
            ih <= 6'd48; iw <= 6'd48; oh <= 6'd48; ow <= 6'd48; icn <= 6'd1; ocn <= 6'd8;
            ihiw <= 12'd2304;
            raddr_r <= 15'd0; waddr_r <= 13'd0; out_off_r <= 15'd0;
            ic_base <= 15'd0;
        end else begin
            done  <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy           <= 1'b1;
                        bank_r         <= bank;
                        result_invalid <= 1'b0;
                        layer          <= 2'd1;
                        in_sel         <= 3'd0;
                        ih <= 6'd48; iw <= 6'd48; oh <= 6'd48; ow <= 6'd48;
                        icn <= 6'd1; ocn <= 6'd8; ihiw <= 12'd2304;
                        oc <= 6'd0;
                        state <= S_BIAS;
                    end
                end

                S_BIAS: begin
                    case (layer)
                        2'd1:    begin m_r <= M_L1; s_r <= QS_L1; end
                        2'd2:    begin m_r <= M_L2; s_r <= QS_L2; end
                        2'd3:    begin m_r <= M_L3; s_r <= QS_L3; end
                        default: begin m_r <= M_FC; s_r <= QS_FC; end
                    endcase
                    state   <= S_BIASC;
                end
                S_BIASC: begin
                    bias_q <= dout_b;
                    oy     <= 6'd0;
                    ox     <= 6'd0;
                    state  <= S_PIX;
                end
                S_PIX: begin
                    acc <= bias_q;
                    ic  <= 5'd0;
                    k   <= 4'd0;
                    ic_base <= 15'd0;
                    state <= S_ADDR;
                end
                S_ADDR: begin
                    raddr_r <= (in_sel == 3'd0) ? {2'd0, roi_off} : conv_off;
                    waddr_r <= w_off;
                    ib_r    <= inb;
                    state   <= S_MAC;
                end
                S_MAC: begin
                    state <= S_CAP;
                end
                S_CAP: begin
                    if (ib_r) acc <= acc + $signed(dout_w) * $signed(dout_in);
                    if (ic == icn - 6'd1 && k == 4'd8) begin
                        out_off_r <= oc * oh * ow + oy * ow + ox;
                        state <= S_OUT;
                    end else begin
                        if (k == 4'd8) begin
                            k  <= 4'd0;
                            ic <= ic + 5'd1;
                            ic_base <= ic_base + {3'd0, ihiw};
                        end else begin
                            k <= k + 4'd1;
                        end
                        state <= S_ADDR;
                    end
                end
                S_OUT: begin
                    if (ox == ow - 6'd1) begin
                        ox <= 6'd0;
                        if (oy == oh - 6'd1) begin
                            oy <= 6'd0;
                            if (oc == ocn - 6'd1) begin
                                oc <= 6'd0;
                                if (layer == 2'd1) begin
                                    ih <= 6'd48; iw <= 6'd48; oh <= 6'd24; ow <= 6'd24;
                                    icn <= 6'd8; ocn <= 6'd8; in_sel <= 3'd3;
                                    ihiw <= 12'd2304;
                                    oc <= 6'd0; oy <= 6'd0; ox <= 6'd0; ps <= 2'd0;
                                    maxv <= 8'd0;
                                    state <= S_P1A;
                                end else if (layer == 2'd2) begin
                                    ih <= 6'd24; iw <= 6'd24; oh <= 6'd12; ow <= 6'd12;
                                    icn <= 6'd16; ocn <= 6'd16; in_sel <= 3'd4;
                                    ihiw <= 12'd576;
                                    oc <= 6'd0; oy <= 6'd0; ox <= 6'd0; ps <= 2'd0;
                                    maxv <= 8'd0;
                                    state <= S_P2A;
                                end else begin
                                    ih <= 6'd12; iw <= 6'd12;
                                    icn <= 6'd32; ocn <= 6'd32; ihiw <= 12'd144;
                                    oc <= 6'd0; gi <= 8'd0; gsum <= 32'd0;
                                    in_sel <= 3'd5;
                                    state <= S_GAPA;
                                end
                            end else begin
                                oc    <= oc + 6'd1;
                                state <= S_BIAS;
                            end
                        end else begin
                            oy    <= oy + 6'd1;
                            state <= S_PIX;
                        end
                    end else begin
                        ox    <= ox + 6'd1;
                        state <= S_PIX;
                    end
                end

                // ---- pool 1: f1 48x48x8 -> p1 24x24x8
                S_P1A: begin
                    raddr_r <= pool_off;
                    state   <= S_P1R;
                end
                S_P1R: begin
                    state <= S_P1C;
                end
                S_P1C: begin
                    maxv <= (ps == 2'd0) ? dout_in : ((dout_in > maxv) ? dout_in : maxv);
                    if (ps == 2'd3) begin
                        ps        <= 2'd0;
                        out_off_r <= oc * oh * ow + oy * ow + ox;
                        state     <= S_P1W;
                    end else begin
                        ps    <= ps + 2'd1;
                        state <= S_P1A;
                    end
                end
                S_P1W: begin
                    if (ox == 6'd23) begin
                        ox <= 6'd0;
                        if (oy == 6'd23) begin
                            oy <= 6'd0;
                            if (oc == 6'd7) begin
                                layer  <= 2'd2;
                                in_sel <= 3'd1;
                                ih <= 6'd24; iw <= 6'd24; oh <= 6'd24; ow <= 6'd24;
                                icn <= 6'd8; ocn <= 6'd16; ihiw <= 12'd576;
                                oc <= 6'd0;
                                state <= S_BIAS;
                            end else begin
                                oc    <= oc + 6'd1;
                                maxv  <= 8'd0;
                                ps    <= 2'd0;
                                state <= S_P1A;
                            end
                        end else begin
                            oy   <= oy + 6'd1;
                            maxv <= 8'd0;
                            ps   <= 2'd0;
                            state <= S_P1A;
                        end
                    end else begin
                        ox   <= ox + 6'd1;
                        maxv <= 8'd0;
                        ps   <= 2'd0;
                        state <= S_P1A;
                    end
                end

                // ---- pool 2: f2 24x24x16 -> p2 12x12x16
                S_P2A: begin
                    raddr_r <= pool_off;
                    state   <= S_P2R;
                end
                S_P2R: begin
                    state <= S_P2C;
                end
                S_P2C: begin
                    maxv <= (ps == 2'd0) ? dout_in : ((dout_in > maxv) ? dout_in : maxv);
                    if (ps == 2'd3) begin
                        ps        <= 2'd0;
                        out_off_r <= oc * oh * ow + oy * ow + ox;
                        state     <= S_P2W;
                    end else begin
                        ps    <= ps + 2'd1;
                        state <= S_P2A;
                    end
                end
                S_P2W: begin
                    if (ox == 6'd11) begin
                        ox <= 6'd0;
                        if (oy == 6'd11) begin
                            oy <= 6'd0;
                            if (oc == 6'd15) begin
                                layer  <= 2'd3;
                                in_sel <= 3'd2;
                                ih <= 6'd12; iw <= 6'd12; oh <= 6'd12; ow <= 6'd12;
                                icn <= 6'd16; ocn <= 6'd32; ihiw <= 12'd144;
                                oc <= 6'd0;
                                state <= S_BIAS;
                            end else begin
                                oc    <= oc + 6'd1;
                                maxv  <= 8'd0;
                                ps    <= 2'd0;
                                state <= S_P2A;
                            end
                        end else begin
                            oy   <= oy + 6'd1;
                            maxv <= 8'd0;
                            ps   <= 2'd0;
                            state <= S_P2A;
                        end
                    end else begin
                        ox   <= ox + 6'd1;
                        maxv <= 8'd0;
                        ps   <= 2'd0;
                        state <= S_P2A;
                    end
                end

                // ---- GAP
                S_GAPA: begin
                    raddr_r <= gap_off;
                    state   <= S_GAPR;
                end
                S_GAPR: begin
                    state <= S_GAPC;
                end
                S_GAPC: begin
                    gsum <= gsum + {24'd0, dout_in};
                    if (gi == 8'd143) begin
                        state <= S_GAPW;
                    end else begin
                        gi    <= gi + 8'd1;
                        state <= S_GAPA;
                    end
                end
                S_GAPW: begin
                    if (oc == 6'd31) begin
                        foc   <= 2'd0;
                        state <= S_FCB;
                    end else begin
                        oc    <= oc + 6'd1;
                        gi    <= 8'd0;
                        gsum  <= 32'd0;
                        state <= S_GAPA;
                    end
                end

                // ---- FC 32 -> 3
                S_FCB: begin
                    state <= S_FBC;
                end
                S_FBC: begin
                    facc <= dout_b4;
                    fk   <= 5'd0;
                    state <= S_FC;
                end
                S_FC: begin
                    state <= S_FCC;
                end
                S_FCC: begin
                    facc <= facc + $signed(dout_w4) * $signed(gap[fk]);
                    if (fk == 5'd31) begin
                        state <= S_FCW;
                    end else begin
                        fk    <= fk + 5'd1;
                        state <= S_FC;
                    end
                end
                S_FCW: begin
                    case (foc)
                        2'd0: logit0 <= requant8(facc, M_FC, QS_FC);
                        2'd1: logit1 <= requant8(facc, M_FC, QS_FC);
                        default: logit2 <= requant8(facc, M_FC, QS_FC);
                    endcase
                    if (foc == 2'd2) begin
                        state <= S_FIN;
                    end else begin
                        foc   <= foc + 2'd1;
                        state <= S_FCB;
                    end
                end
                S_FIN: begin
                    if ($signed(logit0) >= $signed(logit1) && $signed(logit0) >= $signed(logit2))
                        pred <= 2'd0;
                    else if ($signed(logit1) >= $signed(logit2))
                        pred <= 2'd1;
                    else
                        pred <= 2'd2;
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
