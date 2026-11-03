`timescale 1ns / 1ps
`include "src/control_event64_defs.vh"

// Offline score player: reads timed NOTE_ON/NOTE_OFF entries from a ROM and
// feeds them into the normal ControlEvent stream, so the FPGA can guide a
// performance (and drive the LED guide) without a phone or PC.
//
// ROM entry (32 bit):
//   [31:20] delta_ms   [19:16] type (1=on, 2=off, 3=end)
//   [15:9]  note       [8:2]   velocity
module score_player #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer TICK_CYCLES = CLK_FREQ_HZ / 1000,
    parameter integer SCORE_DEPTH = 512,
    parameter integer ADDR_W      = 9,
    parameter         SCORE_FILE  = "src/score_demo.mem"
) (
    input  wire         clk,
    input  wire         rst_n,
    output wire         out_valid,
    output wire [63:0]  out_data,
    input  wire         out_ready,
    output reg  [127:0] expected_notes,
    output reg          done
);
    function integer clog2;
        input integer value;
        integer temporary;
        begin
            temporary = value - 1;
            clog2 = 0;
            while (temporary > 0) begin
                temporary = temporary >> 1;
                clog2 = clog2 + 1;
            end
        end
    endfunction

    // TICK_CYCLES is 50,000 in the production 50 MHz build.  The previous
    // fixed 12-bit counter wrapped at 4,095, so ms_tick never asserted on
    // hardware even though the reduced-cycle testbench passed.
    localparam integer TICK_W = (TICK_CYCLES <= 1) ? 1 : clog2(TICK_CYCLES);

    localparam [1:0] ST_LOAD = 2'd0,
                     ST_WAIT = 2'd1,
                     ST_SEND = 2'd2,
                     ST_DONE = 2'd3;

    reg [31:0] rom [0:SCORE_DEPTH-1];
    initial $readmemh(SCORE_FILE, rom);

    reg [1:0]       state;
    reg [ADDR_W-1:0] pc;
    reg [31:0]      entry;
    reg [11:0]      remain;
    reg [TICK_W-1:0] tick_cnt;
    reg             first;
    reg [7:0]       seq;

    wire [11:0] delta   = entry[31:20];
    wire [3:0]  kind    = entry[19:16];
    wire [6:0]  note    = entry[15:9];
    wire [6:0]  vel     = entry[8:2];
    wire        ms_tick = (TICK_CYCLES <= 1) ||
                          (tick_cnt == TICK_CYCLES - 1);

    assign out_valid = state == ST_SEND;
    assign out_data  = {
        2'b01, ((kind == 4'd1) ? `CE64_TYPE_NOTE_ON : `CE64_TYPE_NOTE_OFF),
        4'd0, 4'd0,       // source 0 (mapper accepts source < 2), channel 0
        4'd0, 4'd0,       // instrument 0, no flags
        1'b0, note,
        vel, 1'b0,
        8'd0,             // value low
        8'd0,             // aux
        seq
    };

    // Registered ROM read keeps the table in BSRAM.
    always @(posedge clk)
        entry <= rom[pc];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_LOAD;
            pc             <= {ADDR_W{1'b0}};
            remain         <= 12'd0;
            tick_cnt       <= {TICK_W{1'b0}};
            first          <= 1'b0;
            seq            <= 8'd0;
            expected_notes <= 128'd0;
            done           <= 1'b0;
        end else begin
            if (ms_tick) tick_cnt <= {TICK_W{1'b0}};
            else         tick_cnt <= tick_cnt + 1'b1;

            case (state)
                ST_LOAD: begin
                    first <= 1'b1;
                    state <= ST_WAIT;
                end
                ST_WAIT: begin
                    if (first) begin
                        remain <= delta;
                        first  <= 1'b0;
                    end else if (remain == 12'd0) begin
                        if (kind == 4'd3) begin
                            done  <= 1'b1;
                            state <= ST_DONE;
                        end else begin
                            state <= ST_SEND;
                        end
                    end else if (ms_tick) begin
                        remain <= remain - 1'b1;
                    end
                end
                ST_SEND: begin
                    if (out_ready) begin
                        if (kind == 4'd1)
                            expected_notes[note] <= 1'b1;
                        else if (kind == 4'd2)
                            expected_notes[note] <= 1'b0;
                        seq  <= seq + 1'b1;
                        pc   <= pc + 1'b1;
                        state <= ST_LOAD;
                    end
                end
                default: begin
                    done  <= 1'b1;
                    state <= ST_DONE;
                end
            endcase
        end
    end

endmodule
