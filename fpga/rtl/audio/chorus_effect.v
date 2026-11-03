/*
 * Stereo chorus: one short delay line per channel, two read taps modulated by
 * a single slow LFO in opposite directions. The dry signal is the current
 * input; the wet signal is the delayed copy. wet_gain=0 is bypass.
 *
 * Delay base is 1024 samples (~21 ms at 48.828 kHz); LFO depth is +/-128
 * samples. The two read taps move in opposite directions to create width.
 */
`timescale 1ns / 1ps

module chorus_effect #(
    parameter integer DATA_WIDTH = 24,
    parameter integer MAX_DELAY  = 2048,
    parameter integer ADDR_WIDTH = 11,
    parameter integer GAIN_SHIFT = 8,
    parameter integer LFO_INC    = 172 // ~0.5 Hz at 48.828 kHz
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
    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_READ = 2'd1;
    localparam [1:0] S_OUT  = 2'd2;
    localparam [ADDR_WIDTH-1:0] BASE_DELAY = 1024;
    localparam [23:0] LFO_STEP = LFO_INC;

    reg [DATA_WIDTH-1:0] mem_left  [0:MAX_DELAY-1];
    reg [DATA_WIDTH-1:0] mem_right [0:MAX_DELAY-1];

    reg [1:0] state;
    reg [ADDR_WIDTH-1:0] wptr;
    reg [ADDR_WIDTH-1:0] rd_left, rd_right;
    reg [11:0] history_count;
    reg [23:0] lfo_phase;
    reg signed [DATA_WIDTH-1:0] dry_left, dry_right;
    reg signed [DATA_WIDTH-1:0] delayed_left, delayed_right;

    wire [15:0] lfo_tri = lfo_phase[23] ? ~lfo_phase[22:7] : lfo_phase[22:7];
    wire signed [16:0] lfo_centered = $signed({1'b0, lfo_tri}) - 17'sd32768;
    wire signed [16:0] lfo_offset = lfo_centered >>> 8; // +/-128 samples
    wire [ADDR_WIDTH-1:0] base_addr = wptr - BASE_DELAY;
    wire [ADDR_WIDTH-1:0] offset_bits = lfo_offset[ADDR_WIDTH-1:0];
    wire history_ok = (history_count >= 12'd1153);

    function signed [DATA_WIDTH-1:0] saturate;
        input signed [DATA_WIDTH+GAIN_SHIFT+1:0] value;
        localparam signed [DATA_WIDTH-1:0] MAXV = {1'b0, {(DATA_WIDTH-1){1'b1}}};
        localparam signed [DATA_WIDTH-1:0] MINV = {1'b1, {(DATA_WIDTH-1){1'b0}}};
        begin
            if (value > MAXV)
                saturate = MAXV;
            else if (value < MINV)
                saturate = MINV;
            else
                saturate = value[DATA_WIDTH-1:0];
        end
    endfunction

    wire signed [DATA_WIDTH+GAIN_SHIFT+1:0] dry_ext_left =
        {{(GAIN_SHIFT+2){dry_left[DATA_WIDTH-1]}}, dry_left};
    wire signed [DATA_WIDTH+GAIN_SHIFT+1:0] dry_ext_right =
        {{(GAIN_SHIFT+2){dry_right[DATA_WIDTH-1]}}, dry_right};
    wire signed [DATA_WIDTH:0] diff_left  = $signed(delayed_left)  - $signed(dry_left);
    wire signed [DATA_WIDTH:0] diff_right = $signed(delayed_right) - $signed(dry_right);
    wire signed [DATA_WIDTH+GAIN_SHIFT:0] wet_left_product  =
        diff_left  * $signed({1'b0, wet_gain});
    wire signed [DATA_WIDTH+GAIN_SHIFT:0] wet_right_product =
        diff_right * $signed({1'b0, wet_gain});
    wire signed [DATA_WIDTH+GAIN_SHIFT+1:0] mixed_left =
        dry_ext_left  + (wet_left_product  >>> GAIN_SHIFT);
    wire signed [DATA_WIDTH+GAIN_SHIFT+1:0] mixed_right =
        dry_ext_right + (wet_right_product >>> GAIN_SHIFT);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            wptr <= {ADDR_WIDTH{1'b0}};
            rd_left <= {ADDR_WIDTH{1'b0}};
            rd_right <= {ADDR_WIDTH{1'b0}};
            history_count <= 12'd0;
            lfo_phase <= 24'd0;
            dry_left <= {DATA_WIDTH{1'b0}};
            dry_right <= {DATA_WIDTH{1'b0}};
            delayed_left <= {DATA_WIDTH{1'b0}};
            delayed_right <= {DATA_WIDTH{1'b0}};
            out_valid <= 1'b0;
            out_left <= {DATA_WIDTH{1'b0}};
            out_right <= {DATA_WIDTH{1'b0}};
        end else begin
            out_valid <= 1'b0;
            case (state)
                S_IDLE: if (in_valid) begin
                    mem_left[wptr]  <= in_left;
                    mem_right[wptr] <= in_right;
                    dry_left  <= in_left;
                    dry_right <= in_right;
                    rd_left  <= base_addr + offset_bits;
                    rd_right <= base_addr - offset_bits;
                    lfo_phase <= lfo_phase + LFO_STEP;
                    wptr <= wptr + 1'b1;
                    if (history_count < 12'd2048)
                        history_count <= history_count + 1'b1;
                    state <= S_READ;
                end
                S_READ: begin
                    delayed_left  <= history_ok ? mem_left[rd_left]  : {DATA_WIDTH{1'b0}};
                    delayed_right <= history_ok ? mem_right[rd_right] : {DATA_WIDTH{1'b0}};
                    state <= S_OUT;
                end
                S_OUT: begin
                    out_left  <= saturate(mixed_left);
                    out_right <= saturate(mixed_right);
                    out_valid <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
