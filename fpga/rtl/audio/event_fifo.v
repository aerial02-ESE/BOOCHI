/*
 * 通用同步事件 FIFO（ready/valid）。
 *
 * 用于 64-bit ControlEvent 与 96-bit TimedEvent（target[31:0] + event[63:0]）。
 * 满时 wr_valid 握手被拒并增加饱和 overflow_count；空时 rd_valid 为 0。DEPTH 为 2 的幂。
 */
module event_fifo #(
    parameter integer DATA_WIDTH = 64,
    parameter integer DEPTH = 16,
    parameter integer COUNT_WIDTH = 32
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     wr_valid,
    output wire                     wr_ready,
    input  wire [DATA_WIDTH-1:0]    wr_data,
    output wire                     rd_valid,
    input  wire                     rd_ready,
    output wire [DATA_WIDTH-1:0]    rd_data,
    output reg  [COUNT_WIDTH-1:0]   overflow_count
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

    localparam integer AW = clog2(DEPTH);

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1] /* synthesis syn_ramstyle="block_ram" */;
    reg [DATA_WIDTH-1:0] ram_head;
    reg [DATA_WIDTH-1:0] bypass_head;
    reg bypass_valid;
    reg [AW-1:0] wptr;
    reg [AW-1:0] rptr;
    reg [AW:0] count;

    wire full  = (count == DEPTH[AW:0]);
    wire empty = (count == {(AW+1){1'b0}});
    wire push  = wr_valid && wr_ready;
    wire pop   = rd_valid && rd_ready;

    // Do not advertise space while the FIFO is held in reset: the reset branch
    // ignores pushes, so a ready pulse there would let the upstream drop an
    // event without it being counted as an overflow.
    assign wr_ready = !full && rst_n;
    assign rd_valid = !empty;
    assign rd_data = bypass_valid ? bypass_head : ram_head;

    // Prefetch the next head on a pop. A write that becomes the only
    // entry uses bypass data, independent of RAM read-during-write behavior.
    wire [AW-1:0] read_address = pop ? rptr + 1'b1 : rptr;
    wire push_to_head = push && (empty || (pop && count == 1));

    always @(posedge clk) begin
        if (push)
            mem[wptr] <= wr_data;
        ram_head <= mem[read_address];
        if (push_to_head)
            bypass_head <= wr_data;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= {AW{1'b0}};
            rptr <= {AW{1'b0}};
            count <= {(AW+1){1'b0}};
            overflow_count <= {COUNT_WIDTH{1'b0}};
            bypass_valid <= 1'b0;
        end else begin
            if (push)
                wptr <= wptr + 1'b1;
            if (push_to_head || pop)
                bypass_valid <= push_to_head;
            if (pop)
                rptr <= rptr + 1'b1;
            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
            if (wr_valid && !wr_ready && overflow_count != {COUNT_WIDTH{1'b1}})
                overflow_count <= overflow_count + 1'b1;
        end
    end
endmodule
