/*
 * 统一控制事件协议 v1：64-bit 固定布局（大端字节序，见 docs/product-system-project-plan.md §7）。
 *
 * 字节 B0..B7 拼成的 64-bit 字里，B0 在最高字节：
 *   B0:[7:6]=version  [5:0]=type
 *   B1:[7:4]=source   [3:0]=channel
 *   B2:[7:4]=instrument [3:0]=flags
 *   B3:[7:0]=id        B4:[7:0]=value_hi  B5:[7:0]=value_lo
 *   B6:[7:0]=aux       B7:[7:0]=seq
 * 字节级黄金向量见 docs/protocol-v1-golden-vectors.json。
 */
`ifndef CONTROL_EVENT64_DEFS_VH
`define CONTROL_EVENT64_DEFS_VH

`define CE64_WIDTH 64

`define CE64_VERSION_MSB 63
`define CE64_VERSION_LSB 62
`define CE64_TYPE_MSB    61
`define CE64_TYPE_LSB    56
`define CE64_SOURCE_MSB  55
`define CE64_SOURCE_LSB  52
`define CE64_CHANNEL_MSB 51
`define CE64_CHANNEL_LSB 48
`define CE64_INSTR_MSB   47
`define CE64_INSTR_LSB   44
`define CE64_FLAGS_MSB   43
`define CE64_FLAGS_LSB   40
`define CE64_ID_MSB      39
`define CE64_ID_LSB      32
`define CE64_VALUE_MSB   31
`define CE64_VALUE_LSB   16
`define CE64_AUX_MSB     15
`define CE64_AUX_LSB     8
`define CE64_SEQ_MSB     7
`define CE64_SEQ_LSB     0

`define CE64_VERSION_V1 2'b01

/* type（docs §7.2）。 */
`define CE64_TYPE_NOP          6'h00
`define CE64_TYPE_NOTE_ON      6'h01
`define CE64_TYPE_NOTE_OFF     6'h02
`define CE64_TYPE_PITCH_BEND   6'h03
`define CE64_TYPE_PRESSURE     6'h04
`define CE64_TYPE_MODULATION   6'h05
`define CE64_TYPE_SUSTAIN      6'h06
`define CE64_TYPE_PROGRAM      6'h07
`define CE64_TYPE_EFFECT_CTRL  6'h08
`define CE64_TYPE_ALL_NOTES_OFF 6'h09
`define CE64_TYPE_TRANSPORT    6'h0A
`define CE64_TYPE_PARAM_CTRL   6'h0B
`define CE64_TYPE_SCORE_VIEW   6'h0C
`define CE64_TYPE_SCORE_LED    6'h0D

/* source（docs §7.3）。 */
`define CE64_SRC_USB_MIDI 4'd0
`define CE64_SRC_KEYBED   4'd1
`define CE64_SRC_PHONE    4'd2
`define CE64_SRC_PAD      4'd2
`define CE64_SRC_PITCH    4'd3
`define CE64_SRC_MOD      4'd4
`define CE64_SRC_PANEL    4'd5
`define CE64_SRC_PEDAL    4'd6
`define CE64_SRC_APP      4'd7
`define CE64_SRC_SCORE    4'd8
`define CE64_SRC_TEST     4'd9
`define CE64_SRC_FPGA     4'd10

/* instrument（docs §7.3）。 */
`define CE64_INST_PIANO 4'd0
`define CE64_INST_BASS  4'd1
`define CE64_INST_DRUM  4'd2
`define CE64_INST_PHYS  4'd3

/* flags（B2[3:0]）。 */
`define CE64_FLAG_PER_NOTE    0
`define CE64_FLAG_FROM_SCORE  1
`define CE64_FLAG_RELATIVE    2

/* 由 8 个字节（B0..B7）拼成 64-bit 事件字。 */
`define CE64_PACK(b0, b1, b2, b3, b4, b5, b6, b7) \
    {b0, b1, b2, b3, b4, b5, b6, b7}

`endif
