/*
 * Compact stereo-spread reverb.
 *
 * A mono Schroeder-style core (2 damped comb filters + 1 allpass) is fed from
 * (L+R)/2. The dry L/R pass through unchanged; the wet output is added to L,
 * while R receives a short delayed copy of the wet output. That keeps the dry
 * mix truly stereo and gives the reverb tail a wider image without duplicating
 * the whole reverb network.
 *
 * wet_gain=0 is bypass. Internal storage is 16-bit; the input/output are 24-bit.
 */
`timescale 1ns / 1ps

module reverb_effect #(
    parameter integer DATA_WIDTH  = 24,
    parameter integer MEM_DEPTH   = 2048,
    parameter integer MEM_AW      = 11,
    parameter integer AP_DEPTH    = 512,
    parameter integer AP_AW       = 9,
    parameter integer SPREAD_DEPTH = 1024,
    parameter integer SPREAD_AW   = 10,
    parameter integer GAIN_SHIFT  = 8,
    parameter integer D1          = 1116,
    parameter integer D2          = 1277,
    parameter integer D3          = 225,
    parameter integer D4          = 512,
    parameter [7:0]   FB1         = 8'd178,
    parameter [7:0]   FB2         = 8'd172,
    parameter [7:0]   AP_FB       = 8'd128
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          in_valid,
    input  wire signed [DATA_WIDTH-1:0]  in_left,
    input  wire signed [DATA_WIDTH-1:0]  in_right,
    input  wire [GAIN_SHIFT-1:0]         wet_gain,
    output reg                           out_valid,
    output reg  signed [DATA_WIDTH-1:0]  out_left,
    output reg  signed [DATA_WIDTH-1:0]  out_right
);
    localparam [3:0] S_IDLE = 4'd0;
    localparam [3:0] S_C1R  = 4'd1;
    localparam [3:0] S_C1W  = 4'd2;
    localparam [3:0] S_C2R  = 4'd3;
    localparam [3:0] S_C2W  = 4'd4;
    localparam [3:0] S_APR  = 4'd5;
    localparam [3:0] S_APW  = 4'd6;
    localparam [3:0] S_SPR  = 4'd7;
    localparam [3:0] S_SPW  = 4'd8;
    localparam [3:0] S_OUT  = 4'd9;
    localparam [3:0] S_C1_COMMIT = 4'd10;
    localparam [3:0] S_C2_COMMIT = 4'd11;
    localparam [3:0] S_AP_COMMIT = 4'd12;

    localparam [MEM_AW-1:0] D1_BITS = D1;
    localparam [MEM_AW-1:0] D2_BITS = D2;
    localparam [AP_AW-1:0] D3_BITS = D3;
    localparam [SPREAD_AW-1:0] D4_BITS = D4;

    reg signed [15:0] mem1 [0:MEM_DEPTH-1];
    reg signed [15:0] mem2 [0:MEM_DEPTH-1];
    reg signed [15:0] mem_ap [0:AP_DEPTH-1];
    reg signed [15:0] mem_spread [0:SPREAD_DEPTH-1];

    reg [3:0] state;
    reg [MEM_AW-1:0] w1, w2;
    reg [AP_AW-1:0] wa;
    reg [SPREAD_AW-1:0] ws;
    reg [MEM_AW-1:0] r1, r2;
    reg [AP_AW-1:0] ra;
    reg [SPREAD_AW-1:0] rs;
    reg [11:0] history_count;

    reg signed [15:0] mono16;
    reg signed [DATA_WIDTH-1:0] dry_l, dry_r;
    reg signed [15:0] last1, last2;
    reg signed [15:0] c1v, c2v, apv, spv;
    reg signed [15:0] comb1_sum, comb_sum, ap_out;
    reg signed [15:0] comb1_write, comb2_write, ap_write;

    localparam integer MAX_COMB_DELAY = (D1 > D2) ? D1 : D2;
    localparam integer MAX_AP_DELAY = (D3 > D4) ? D3 : D4;
    localparam integer MAX_HISTORY = (MAX_COMB_DELAY > MAX_AP_DELAY) ? MAX_COMB_DELAY : MAX_AP_DELAY;
    reg history_ok; // Snapshot the count BEFORE accepting the current input.


    function signed [15:0] sat16;
        input signed [23:0] value;
        begin
            if (value > 24'sd32767)
                sat16 = 16'sd32767;
            else if (value < -24'sd32768)
                sat16 = -16'sd32768;
            else
                sat16 = value[15:0];
        end
    endfunction

    function signed [DATA_WIDTH-1:0] sat24;
        input signed [DATA_WIDTH+GAIN_SHIFT:0] value;
        localparam signed [DATA_WIDTH-1:0] MAXV = {1'b0, {(DATA_WIDTH-1){1'b1}}};
        localparam signed [DATA_WIDTH-1:0] MINV = {1'b1, {(DATA_WIDTH-1){1'b0}}};
        begin
            if (value > MAXV)
                sat24 = MAXV;
            else if (value < MINV)
                sat24 = MINV;
            else
                sat24 = value[DATA_WIDTH-1:0];
        end
    endfunction

    // Average two 16-bit core samples: widen to 17 bits before the shift, or
    // two large same-sign values wrap a 16-bit add.
    wire signed [16:0] damp1 = ($signed(c1v) + $signed(last1)) >>> 1;
    wire signed [16:0] damp2 = ($signed(c2v) + $signed(last2)) >>> 1;
    // The wet core is 16-bit, so feed it the (L+R)>>9 average. Widen the sum
    // before shifting: two 24-bit samples would wrap a 24-bit add.
    wire signed [DATA_WIDTH:0]   mono_sum   = $signed(in_left) + $signed(in_right);
    wire signed [DATA_WIDTH:0]   mono_shift = mono_sum >>> 9;
    wire signed [15:0] mono_scaled =
        (mono_shift > 25'sd32767) ? 16'sd32767 :
        (mono_shift < -25'sd32768) ? -16'sd32768 :
        mono_shift[15:0];
    wire signed [23:0] fb1_product = damp1 * $signed({1'b0, FB1});
    wire signed [23:0] fb2_product = damp2 * $signed({1'b0, FB2});
    wire signed [23:0] fb1 = fb1_product >>> 8;
    wire signed [23:0] fb2 = fb2_product >>> 8;
    wire signed [23:0] comb1_in = {{8{mono16[15]}}, mono16} + fb1;
    wire signed [23:0] comb2_in = {{8{mono16[15]}}, mono16} + fb2;
    wire signed [15:0] comb_sum_next = (comb1_sum >>> 1) + (c2v >>> 1);

    wire signed [23:0] ap_fb_product = apv * $signed({1'b0, AP_FB});
    wire signed [23:0] ap_fb = ap_fb_product >>> 8;
    wire signed [23:0] ap_in = {{8{comb_sum[15]}}, comb_sum} + ap_fb;
    // The allpass output can reach 1.5x full scale; keep 17 bits here and
    // saturate when it is stored, instead of wrapping inside 16 bits.
    wire signed [16:0] ap_out_next = $signed(apv) - $signed(comb_sum >>> 1);

    wire signed [DATA_WIDTH-1:0] wet_l_ext = {ap_out, {(DATA_WIDTH-16){1'b0}}};
    wire signed [DATA_WIDTH-1:0] wet_r_ext = {spv, {(DATA_WIDTH-16){1'b0}}};
    wire signed [DATA_WIDTH+GAIN_SHIFT:0] wet_l_product =
        wet_l_ext * $signed({1'b0, wet_gain});
    wire signed [DATA_WIDTH+GAIN_SHIFT:0] wet_r_product =
        wet_r_ext * $signed({1'b0, wet_gain});
    // Keep every operand of the final sumry a signed wire.  A concatenation is
    // unsigned, and an addition with one unsigned operand turns the whole
    // expression unsigned: the arithmetically shifted negative wet value would
    // be read as >2^25 and the dry sign extension would be lost.
    wire signed [DATA_WIDTH+GAIN_SHIFT:0] dry_ext_l =
        {{(GAIN_SHIFT+1){dry_l[DATA_WIDTH-1]}}, dry_l};
    wire signed [DATA_WIDTH+GAIN_SHIFT:0] dry_ext_r =
        {{(GAIN_SHIFT+1){dry_r[DATA_WIDTH-1]}}, dry_r};
    // S_SPW already occupies a full clock before S_OUT. Register the wet
    // products there, so the RAM-read/multiply and final add/saturate do not
    // share a single 50 MHz combinational path.
    reg signed [DATA_WIDTH+GAIN_SHIFT:0] wet_shift_l, wet_shift_r;
    wire signed [DATA_WIDTH+GAIN_SHIFT:0] mix_l = dry_ext_l + wet_shift_l;
    wire signed [DATA_WIDTH+GAIN_SHIFT:0] mix_r = dry_ext_r + wet_shift_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            w1 <= {MEM_AW{1'b0}};
            w2 <= {MEM_AW{1'b0}};
            wa <= {AP_AW{1'b0}};
            ws <= {SPREAD_AW{1'b0}};
            r1 <= {MEM_AW{1'b0}};
            r2 <= {MEM_AW{1'b0}};
            ra <= {AP_AW{1'b0}};
            rs <= {SPREAD_AW{1'b0}};
            history_count <= 12'd0;
            history_ok <= 1'b0;
            mono16 <= 16'sd0;
            dry_l <= 16'sd0;
            dry_r <= 16'sd0;
            last1 <= 16'sd0;
            last2 <= 16'sd0;
            c1v <= 16'sd0;
            c2v <= 16'sd0;
            apv <= 16'sd0;
            spv <= 16'sd0;
            comb1_sum <= 16'sd0;
            comb_sum <= 16'sd0;
            ap_out <= 16'sd0;
            comb1_write <= 16'sd0;
            comb2_write <= 16'sd0;
            ap_write <= 16'sd0;
            wet_shift_l <= 0;
            wet_shift_r <= 0;
            out_valid <= 1'b0;
            out_left <= {DATA_WIDTH{1'b0}};
            out_right <= {DATA_WIDTH{1'b0}};
        end else begin
            out_valid <= 1'b0;
            case (state)
                S_IDLE: if (in_valid) begin
                    history_ok <= (history_count >= MAX_HISTORY);
                    dry_l <= in_left;
                    dry_r <= in_right;
                    mono16 <= mono_scaled;
                    r1 <= w1 - D1_BITS;
                    r2 <= w2 - D2_BITS;
                    ra <= wa - D3_BITS;
                    rs <= ws - D4_BITS;
                    if (history_count < 12'd2048)
                        history_count <= history_count + 1'b1;
                    state <= S_C1R;
                end
                S_C1R: begin
                    c1v <= history_ok ? mem1[r1] : 16'sd0;
                    state <= S_C1W;
                end
                S_C1W: begin
                    last1 <= c1v;
                    comb1_write <= sat16(comb1_in);
                    comb1_sum <= c1v;
                    state <= S_C1_COMMIT;
                end
                S_C1_COMMIT: begin
                    mem1[w1] <= comb1_write;
                    w1 <= w1 + 1'b1;
                    state <= S_C2R;
                end
                S_C2R: begin
                    c2v <= history_ok ? mem2[r2] : 16'sd0;
                    state <= S_C2W;
                end
                S_C2W: begin
                    last2 <= c2v;
                    comb2_write <= sat16(comb2_in);
                    comb_sum <= comb_sum_next;
                    state <= S_C2_COMMIT;
                end
                S_C2_COMMIT: begin
                    mem2[w2] <= comb2_write;
                    w2 <= w2 + 1'b1;
                    state <= S_APR;
                end
                S_APR: begin
                    apv <= history_ok ? mem_ap[ra] : 16'sd0;
                    state <= S_APW;
                end
                S_APW: begin
                    ap_write <= sat16(ap_in);
                    ap_out <= sat16(ap_out_next);
                    state <= S_AP_COMMIT;
                end
                S_AP_COMMIT: begin
                    mem_ap[wa] <= ap_write;
                    wa <= wa + 1'b1;
                    state <= S_SPR;
                end
                S_SPR: begin
                    spv <= history_ok ? mem_spread[rs] : 16'sd0;
                    state <= S_SPW;
                end
                S_SPW: begin
                    mem_spread[ws] <= ap_out;
                    ws <= ws + 1'b1;
                    wet_shift_l <= wet_l_product >>> GAIN_SHIFT;
                    wet_shift_r <= wet_r_product >>> GAIN_SHIFT;
                    state <= S_OUT;
                end
                S_OUT: begin
                    out_left  <= sat24(mix_l);
                    out_right <= sat24(mix_r);
                    out_valid <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
