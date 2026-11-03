`timescale 1ns / 1ps

// Fair 2:1 merge of two ControlEvent streams (USB and UART) into one
// valid/ready stream.  Round-robin: after serving input 0 the next grant goes
// to input 1 when both are valid, so neither source can starve.
module event_arbiter (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in0_valid,
    output wire        in0_ready,
    input  wire [63:0] in0_data,

    input  wire        in1_valid,
    output wire        in1_ready,
    input  wire [63:0] in1_data,

    output wire        out_valid,
    input  wire        out_ready,
    output wire [63:0] out_data
);
    reg last;   // 1 = input 0 was served most recently, so prefer input 1

    wire serve0 = in0_valid && (!in1_valid || !last);
    wire serve1 = in1_valid && (!in0_valid || last);

    assign out_valid = serve0 || serve1;
    assign out_data  = serve0 ? in0_data : in1_data;
    assign in0_ready = out_ready && serve0;
    assign in1_ready = out_ready && serve1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            last <= 1'b0;
        else if (out_valid && out_ready)
            last <= serve0;
    end

endmodule
