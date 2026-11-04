`timescale 1ns / 1ps
// mask_display
// 功能：显示上一帧运动掩码
// 输入：clk、rst_n、de_in、hs_in、vs_in、mask_in等
// 输出：de_out、hs_out、vs_out、rgb_out
module mask_display #(
    parameter W = 640,
    parameter H = 360
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        de_in,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        mask_in,
    input  wire        de_ref,
    input  wire        hs_ref,
    input  wire        vs_ref,
    input  wire [23:0] rgb_ref,
    output reg         de_out,
    output reg         hs_out,
    output reg         vs_out,
    output reg [23:0]  rgb_out
);
    localparam DISP_W = W * 2;
    localparam DISP_H = H * 2;
    localparam MASK_COLOR = 24'h00ffff; // cyan foreground, distinct from ROI red
    localparam BLACK  = 24'h000000;

    localparam WCW = ($clog2(W) > 0) ? $clog2(W) : 1;     // write col width
    localparam WRW = ($clog2(H) > 0) ? $clog2(H) : 1;     // write row width
    localparam RCW = ($clog2(DISP_W) > 0) ? $clog2(DISP_W) : 1; // read col width
    localparam RRW = ($clog2(DISP_H) > 0) ? $clog2(DISP_H) : 1; // read row width
    localparam PAW = ($clog2(W*H) > 0) ? $clog2(W*H) : 1;  // pixel addr width
    localparam ADDR_W = PAW + 1;                            // +1 bank-select bit
    localparam DEPTH  = 2 * W * H;

    // Single packed dual-frame buffer.  Bank select is the address MSB.
    (* ram_style = "block" *) reg mask_mem [0:DEPTH-1];

    // ------------------------- mask writer -------------------------
    reg [WCW-1:0] w_col;
    reg [WRW-1:0] w_row;
    reg           wr_bank;
    reg           write_seen;
    reg           bank0_valid, bank1_valid;

    wire [WCW-1:0] w_col_cur = (vs_in || hs_in) ? {WCW{1'b0}} : w_col;
    wire [WRW-1:0] w_row_cur = vs_in ? {WRW{1'b0}} : (hs_in ? w_row + 1'b1 : w_row);
    wire [PAW-1:0] w_pix = (w_row_cur * W) + w_col_cur;
    wire        w_valid = de_in && (w_col_cur < W) && (w_row_cur < H);
    // On the frame-start marker the bank is flipped; the first pixel belongs
    // to the NEW bank (mirrors the original write_sel semantics).
    wire        w_bank = vs_in ? ~wr_bank : wr_bank;

    always @(posedge clk) begin
        if (rst_n && w_valid) mask_mem[{w_bank, w_pix}] <= mask_in;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_col <= 0;
            w_row <= 0;
            wr_bank <= 1'b0;
            write_seen <= 1'b0;
            bank0_valid <= 1'b0;
            bank1_valid <= 1'b0;
        end else begin
            if (vs_in) begin
                // The bank selected by the old wr_bank was written during the
                // frame that just ended.
                if (write_seen) begin
                    if (wr_bank) bank1_valid <= 1'b1;
                    else         bank0_valid <= 1'b1;
                end
                wr_bank <= ~wr_bank;
                write_seen <= de_in;
                w_col <= de_in ? 1'b1 : {WCW{1'b0}};
                w_row <= {WRW{1'b0}};
            end else if (de_in) begin
                write_seen <= 1'b1;
                if (hs_in) begin
                    w_col <= 1'b1;
                    w_row <= w_row + 1'b1;
                end else begin
                    w_col <= w_col + 1'b1;
                end
            end
        end
    end

    // ------------------------ display reader ------------------------
    reg [RCW-1:0] r_col;
    reg [RRW-1:0] r_row;
    reg           marker_timing;

    wire ref_marker = de_ref && (vs_ref || (marker_timing && hs_ref));
    wire [RCW-1:0] r_col_cur = ref_marker ? {RCW{1'b0}} : r_col;
    wire [RRW-1:0] r_row_cur = (de_ref && vs_ref) ? {RRW{1'b0}} :
                               ((de_ref && marker_timing && hs_ref) ? r_row + 1'b1 : r_row);
    wire [PAW-1:0] r_pix = ((r_row_cur >> 1) * W) + (r_col_cur >> 1);
    wire        r_bank = ~wr_bank;   // display the previously completed bank

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_col <= 0;
            r_row <= 0;
            marker_timing <= 1'b0;
        end else begin
            if (de_ref && (hs_ref || vs_ref))
                marker_timing <= 1'b1;

            if (vs_ref) begin
                r_col <= de_ref ? 1'b1 : {RCW{1'b0}};
                r_row <= {RRW{1'b0}};
            end else if (de_ref) begin
                if (marker_timing && hs_ref) begin
                    r_col <= 1'b1;
                    r_row <= r_row + 1'b1;
                end else if (!marker_timing && r_col == DISP_W-1) begin
                    r_col <= {RCW{1'b0}};
                    r_row <= (r_row == DISP_H-1) ? {RRW{1'b0}} : r_row + 1'b1;
                end else begin
                    r_col <= r_col + 1'b1;
                end
            end
        end
    end

    reg r_data;
    reg read_valid;
    always @(posedge clk) begin
        r_data <= mask_mem[{r_bank, r_pix}];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_valid <= 1'b0;
        end else begin
            if (de_ref && r_col_cur < DISP_W && r_row_cur < DISP_H)
                read_valid <= r_bank ? bank1_valid : bank0_valid;
            else
                read_valid <= 1'b0;
        end
    end

    // The RAM is synchronous: read data arrives one cycle after the read
    // address.  Delay video timing two cycles total so de_out/hs_out/vs_out
    // stay aligned with the read data, exactly as in the original design.
    reg de_d, hs_d, vs_d;
    reg [23:0] rgb_ref_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_d <= 1'b0; hs_d <= 1'b0; vs_d <= 1'b0;
            rgb_ref_d1 <= 24'd0;
            de_out <= 1'b0; hs_out <= 1'b0; vs_out <= 1'b0;
            rgb_out <= BLACK;
        end else begin
            de_d <= de_ref;
            hs_d <= hs_ref;
            vs_d <= vs_ref;
            rgb_ref_d1 <= rgb_ref;
            de_out <= de_d;
            hs_out <= hs_d;
            vs_out <= vs_d;
            // The mask/read-valid pipeline is one cycle behind the reference
            // stream when rgb_out is registered. Using rgb_ref_d2 made the
            // background one pixel older than de and the mask data, producing
            // a horizontally shifted/tearing image. rgb_ref_d1 is the value
            // aligned with r_data/de_out here.
            //
            // Keep the original image at full brightness and use cyan for the
            // foreground. The previous quarter-brightness background made the
            // 640x360 mask look like a noisy silhouette.
            rgb_out <= (read_valid && r_data) ? MASK_COLOR : rgb_ref_d1;
        end
    end
endmodule
