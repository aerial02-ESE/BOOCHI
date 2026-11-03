`timescale 1ns / 1ps

// USB CRC helpers for a Full-Speed host link.
//
// ULPI PHYs handle bit-stuffing and NRZI only; the Link must supply the packet
// CRC (ULPI 1.1: "To force a Hi-Speed transmit error, the Link must transmit an
// inverted CRC at the end of the packet").  These are the standard USB
// algorithms:
//   * CRC5  for token packets: G(x)=x^5+x^2+1, init 5'h1F, reflected, the
//     result is complemented and placed in bits [7:3] of the third token byte.
//   * CRC16 for data packets: G(x)=x^16+x^15+x^2+1 (reflected 0xA001),
//     init 16'hFFFF, the result is complemented and sent LSB first.
//
// Reference check values (RevEng catalogue, also used by tb_usb_crc):
//   CRC-16/USB("123456789") = 0xB4C8
//   CRC5 (addr=0, ep=0)     = 0x02  -> token bytes 0x00, 0x10
//   Received data + CRC residue with init 0xFFFF = 0xB001
module usb_crc16_stream (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        init,   // synchronous load of 16'hFFFF
    input  wire        valid,  // process one byte
    input  wire [7:0]  data,
    output reg  [15:0] crc
);
    // Reflected CRC-16/USB step for one byte (LSB first).
    function [15:0] crc_step;
        input [15:0] c;
        input [7:0]  d;
        integer i;
        reg [15:0] x;
        begin
            x = c ^ {8'h00, d};
            for (i = 0; i < 8; i = i + 1)
                x = x[0] ? ((x >> 1) ^ 16'hA001) : (x >> 1);
            crc_step = x;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            crc <= 16'hFFFF;
        else if (init)
            crc <= 16'hFFFF;
        else if (valid)
            crc <= crc_step(crc, data);
    end
endmodule

// Combinational token CRC5 and the two data bytes that follow the PID.
module usb_token_crc5 (
    input  wire [6:0] addr,
    input  wire [3:0] ep,
    output wire [7:0] byte1,  // ADDR[6:0] | ENDP[0]<<7
    output wire [7:0] byte2   // ENDP[3:1] | CRC5[4:0]<<3
);
    reg [4:0] c;
    integer i;

    always @(*) begin
        c = 5'h1F;
        for (i = 0; i < 7; i = i + 1)
            c = (c[0] ^ addr[i]) ? ((c >> 1) ^ 5'h14) : (c >> 1);
        for (i = 0; i < 4; i = i + 1)
            c = (c[0] ^ ep[i]) ? ((c >> 1) ^ 5'h14) : (c >> 1);
        c = ~c;
    end

    assign byte1 = {ep[0], addr};
    assign byte2 = {c, ep[3:1]};
endmodule
