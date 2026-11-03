`timescale 1ns / 1ps

// 64-bit ControlEvent asynchronous FIFO (USB 60 MHz -> audio 50 MHz).
// Standard Gray-pointer CDC: data crosses only through the dual-clock memory,
// every pointer is Gray-coded and synchronized with two flops per direction.
// DEPTH must be a power of two >= 4.
module event_cdc_fifo #(
    parameter integer DATA_WIDTH  = 64,
    parameter integer DEPTH       = 16,
    parameter integer COUNT_WIDTH = 32
) (
    // Write side (USB/ULPI clock domain)
    input  wire                     wr_clk,
    input  wire                     wr_rst_n,
    input  wire                     wr_valid,
    output wire                     wr_ready,
    input  wire [DATA_WIDTH-1:0]    wr_data,
    output reg  [COUNT_WIDTH-1:0]   overflow_count,

    // Read side (audio/system clock domain)
    input  wire                     rd_clk,
    input  wire                     rd_rst_n,
    output wire                     rd_valid,
    input  wire                     rd_ready,
    output wire [DATA_WIDTH-1:0]    rd_data,
    output reg  [COUNT_WIDTH-1:0]   underflow_count
);
    function integer clog2;
        input integer value;
        integer remaining;
        begin
            clog2 = 0;
            remaining = value - 1;
            while (remaining > 0) begin
                clog2 = clog2 + 1;
                remaining = remaining >> 1;
            end
        end
    endfunction

    localparam integer AW = clog2(DEPTH);
    localparam integer PW = AW + 1;

    // synthesis translate_off
    initial begin
        if (DATA_WIDTH < 1 || COUNT_WIDTH < 1 || DEPTH < 4 ||
            ((DEPTH & (DEPTH - 1)) != 0)) begin
            $display("ERROR event_cdc_fifo: widths must be >= 1 and DEPTH must be a power of two >= 4");
            $finish;
        end
    end
    // synthesis translate_on

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [PW-1:0] wr_bin, wr_gray;
    reg [PW-1:0] rd_bin, rd_gray;
    reg          wr_full, rd_empty;

    (* async_reg = "true" *) reg [PW-1:0] rd_gray_s1_wr, rd_gray_s2_wr;
    (* async_reg = "true" *) reg [PW-1:0] wr_gray_s1_rd, wr_gray_s2_rd;

    wire wr_accept = wr_valid && wr_ready;
    wire rd_accept = rd_valid && rd_ready;

    wire [PW-1:0] wr_bin_next  = wr_bin + {{(PW-1){1'b0}}, wr_accept};
    wire [PW-1:0] wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;
    wire [PW-1:0] rd_bin_next  = rd_bin + {{(PW-1){1'b0}}, rd_accept};
    wire [PW-1:0] rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;
    wire wr_full_next  = (wr_gray_next == {~rd_gray_s2_wr[PW-1:PW-2],
                                           rd_gray_s2_wr[PW-3:0]});
    wire rd_empty_next = (rd_gray_next == wr_gray_s2_rd);

    // Never acknowledge data while either local state machine is held in
    // reset.  Advertising ready/valid during reset can make an upstream or
    // downstream endpoint retire a transfer that this FIFO did not perform.
    assign wr_ready = wr_rst_n && !wr_full;
    assign rd_valid = rd_rst_n && !rd_empty;
    assign rd_data  = mem[rd_bin[AW-1:0]];

    // Write domain
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin <= {PW{1'b0}};
            wr_gray <= {PW{1'b0}};
            wr_full <= 1'b0;
            overflow_count <= {COUNT_WIDTH{1'b0}};
        end else begin
            if (wr_accept)
                mem[wr_bin[AW-1:0]] <= wr_data;
            wr_bin  <= wr_bin_next;
            wr_gray <= wr_gray_next;
            wr_full <= wr_full_next;
            if (wr_valid && wr_full && !(&overflow_count))
                overflow_count <= overflow_count + 1'b1;
        end
    end

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_gray_s1_wr <= {PW{1'b0}};
            rd_gray_s2_wr <= {PW{1'b0}};
        end else begin
            rd_gray_s1_wr <= rd_gray;
            rd_gray_s2_wr <= rd_gray_s1_wr;
        end
    end

    // Read domain
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_bin <= {PW{1'b0}};
            rd_gray <= {PW{1'b0}};
            rd_empty <= 1'b1;
            underflow_count <= {COUNT_WIDTH{1'b0}};
        end else begin
            rd_bin   <= rd_bin_next;
            rd_gray  <= rd_gray_next;
            rd_empty <= rd_empty_next;
            if (rd_ready && rd_empty && !(&underflow_count))
                underflow_count <= underflow_count + 1'b1;
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_gray_s1_rd <= {PW{1'b0}};
            wr_gray_s2_rd <= {PW{1'b0}};
        end else begin
            wr_gray_s1_rd <= wr_gray;
            wr_gray_s2_rd <= wr_gray_s1_rd;
        end
    end

endmodule
