#!/usr/bin/env python3
"""No-hardware USB-MIDI packet replay / wire-format golden-vector test.

This intentionally reimplements the small v1 mapping in plain Python.  It does
not import the firmware source: a shared implementation error therefore cannot
make a vector pass by itself.  The C implementation is compiled by idf.py build.
"""

from dataclasses import dataclass


NOTE_ON = 0x01
NOTE_OFF = 0x02
PITCH_BEND = 0x03
PRESSURE = 0x04
MODULATION = 0x05
SUSTAIN = 0x06
PROGRAM = 0x07
ALL_NOTES_OFF = 0x09
PIANO = 0
BASS = 1


def scale7(value: int) -> int:
    return ((value & 0x7F) * 65535 + 63) // 127


def scale14(value: int) -> int:
    return ((value & 0x3FFF) * 65535 + 8191) // 16383


def crc16_ccitt_false(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def pack(event_type: int, source: int, channel: int, instrument: int, event_id: int, value: int) -> bytes:
    return bytes((0x40 | event_type, ((source & 0x0F) << 4) | (channel & 0x0F), instrument << 4, event_id,
                  value >> 8, value & 0xFF, 0, 0))


def uart_frame(event: bytes) -> bytes:
    prefix = bytes((0xA5, 0x5A, 0x01, 0x08)) + event
    return prefix + crc16_ccitt_false(prefix[2:]).to_bytes(2, "big")


@dataclass
class Bridge:
    source: int
    programs: list
    owners: list

    @classmethod
    def create(cls, source: int = 0):
        return cls(source, [0] * 16, [[None] * 128 for _ in range(16)])

    @staticmethod
    def instrument(program: int) -> int:
        return BASS if 32 <= program <= 39 else PIANO

    def decode(self, packet: bytes) -> bytes | None:
        assert len(packet) == 4, "USB-MIDI Event Packet must be four bytes"
        status, data0, data1 = packet[1], packet[2] & 0x7F, packet[3] & 0x7F
        if status < 0x80 or (status >> 4) == 0x0F:
            return None
        command, channel = status >> 4, status & 0x0F
        inst = self.instrument(self.programs[channel])
        if command == 0x8:
            inst = self.owners[channel][data0] if self.owners[channel][data0] is not None else inst
            self.owners[channel][data0] = None
            return pack(NOTE_OFF, self.source, channel, inst, data0, scale7(data1))
        if command == 0x9:
            if data1 == 0:
                inst = self.owners[channel][data0] if self.owners[channel][data0] is not None else inst
                self.owners[channel][data0] = None
                return pack(NOTE_OFF, self.source, channel, inst, data0, 0)
            self.owners[channel][data0] = inst
            return pack(NOTE_ON, self.source, channel, inst, data0, scale7(data1))
        if command == 0xA:
            return pack(PRESSURE, self.source, channel, inst, data0, scale7(data1))
        if command == 0xB:
            if data0 == 1:
                return pack(MODULATION, self.source, channel, inst, data0, scale7(data1))
            if data0 == 64:
                return pack(SUSTAIN, self.source, channel, inst, data0, scale7(data1))
            if data0 in (120, 123):
                self.owners = [[None] * 128 for _ in range(16)]
                return pack(ALL_NOTES_OFF, self.source, 0, PIANO, 0, 0)
            return None
        if command == 0xC:
            self.programs[channel] = data0
            return pack(PROGRAM, self.source, channel, self.instrument(data0), data0, 0)
        if command == 0xD:
            return pack(PRESSURE, self.source, channel, inst, 0, scale7(data0))
        if command == 0xE:
            return pack(PITCH_BEND, self.source, channel, inst, 0, scale14(data0 | data1 << 7))
        return None


def hx(text: str) -> bytes:
    return bytes.fromhex(text)


def verify(bridge: Bridge, name: str, packet: str, event: str, frame: str) -> None:
    actual_event = bridge.decode(hx(packet))
    expected_event, expected_frame = hx(event), hx(frame)
    assert actual_event == expected_event, f"{name}: ControlEvent mismatch: {actual_event!r} != {expected_event!r}"
    actual_frame = uart_frame(actual_event)
    assert actual_frame == expected_frame, f"{name}: UART frame mismatch: {actual_frame!r} != {expected_frame!r}"
    print(f"PASS {name}: {actual_frame.hex(' ').upper()}")


def main() -> None:
    bridge = Bridge.create()
    # First byte is the USB-MIDI CIN/cable byte captured from Bulk-IN; parser uses MIDI bytes 1..3.
    verify(bridge, "Program 34 (bass)", "0C C0 22 00", "47 00 10 22 00 00 00 00", "A5 5A 01 08 47 00 10 22 00 00 00 00 C0 F8")
    verify(bridge, "Note On velocity 100", "09 90 3C 64", "41 00 10 3C C9 92 00 00", "A5 5A 01 08 41 00 10 3C C9 92 00 00 DD 4B")
    verify(bridge, "Note On zero = Note Off (owner retained)", "09 90 3C 00", "42 00 10 3C 00 00 00 00", "A5 5A 01 08 42 00 10 3C 00 00 00 00 43 B4")
    verify(bridge, "Note On before explicit Note Off", "09 90 3C 7F", "41 00 10 3C FF FF 00 00", "A5 5A 01 08 41 00 10 3C FF FF 00 00 0F 01")
    verify(bridge, "Explicit Note Off", "08 80 3C 40", "42 00 10 3C 81 02 00 00", "A5 5A 01 08 42 00 10 3C 81 02 00 00 86 58")
    verify(bridge, "Polyphonic Aftertouch", "0A A0 3C 7F", "44 00 10 3C FF FF 00 00", "A5 5A 01 08 44 00 10 3C FF FF 00 00 47 BF")
    verify(bridge, "Channel Pressure", "0D D0 40 00", "44 00 10 00 81 02 00 00", "A5 5A 01 08 44 00 10 00 81 02 00 00 81 56")
    verify(bridge, "Pitch Bend centre", "0E E0 00 40", "43 00 10 00 80 02 00 00", "A5 5A 01 08 43 00 10 00 80 02 00 00 30 FA")
    verify(bridge, "CC1 Modulation", "0B B0 01 40", "45 00 10 01 81 02 00 00", "A5 5A 01 08 45 00 10 01 81 02 00 00 6C D4")
    verify(bridge, "CC64 Sustain", "0B B0 40 7F", "46 00 10 40 FF FF 00 00", "A5 5A 01 08 46 00 10 40 FF FF 00 00 5E B4")
    verify(bridge, "CC120 All Notes Off", "0B B0 78 00", "49 00 00 00 00 00 00 00", "A5 5A 01 08 49 00 00 00 00 00 00 00 08 5A")
    verify(bridge, "CC123 All Notes Off", "0B B0 7B 00", "49 00 00 00 00 00 00 00", "A5 5A 01 08 49 00 00 00 00 00 00 00 08 5A")


if __name__ == "__main__":
    main()
