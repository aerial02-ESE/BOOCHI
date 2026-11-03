#include "control_event.h"

uint16_t smk25_crc16_ccitt_false(const uint8_t *data, size_t length)
{
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < length; ++i) {
        crc ^= (uint16_t)data[i] << 8;
        for (unsigned bit = 0; bit < 8; ++bit) {
            crc = (crc & 0x8000U) ? (uint16_t)((crc << 1) ^ 0x1021U)
                                  : (uint16_t)(crc << 1);
        }
    }
    return crc;
}

uint16_t smk25_scale7(uint8_t value)
{
    value &= 0x7FU;
    return (uint16_t)(((uint32_t)value * 65535U + 63U) / 127U);
}

uint16_t smk25_scale14(uint16_t value)
{
    value &= 0x3FFFU;
    return (uint16_t)(((uint32_t)value * 65535U + 8191U) / 16383U);
}

void smk25_control_event_pack(smk25_control_event_t *event,
                              uint8_t type, uint8_t source, uint8_t channel,
                              uint8_t instrument, uint8_t flags, uint8_t id,
                              uint16_t value, uint8_t aux, uint8_t seq)
{
    event->bytes[0] = (uint8_t)(0x40U | (type & 0x3FU));
    event->bytes[1] = (uint8_t)(((source & 0x0FU) << 4) | (channel & 0x0FU));
    event->bytes[2] = (uint8_t)(((instrument & 0x0FU) << 4) | (flags & 0x0FU));
    event->bytes[3] = id;
    event->bytes[4] = (uint8_t)(value >> 8);
    event->bytes[5] = (uint8_t)value;
    event->bytes[6] = aux;
    event->bytes[7] = seq;
}

size_t smk25_uart_frame_encode(const smk25_control_event_t *event,
                               uint8_t frame[SMK25_UART_FRAME_SIZE])
{
    frame[0] = 0xA5;
    frame[1] = 0x5A;
    frame[2] = 0x01;
    frame[3] = SMK25_CONTROL_EVENT_SIZE;
    for (size_t i = 0; i < SMK25_CONTROL_EVENT_SIZE; ++i) {
        frame[4 + i] = event->bytes[i];
    }
    const uint16_t crc = smk25_crc16_ccitt_false(&frame[2], 10);
    frame[12] = (uint8_t)(crc >> 8);
    frame[13] = (uint8_t)crc;
    return SMK25_UART_FRAME_SIZE;
}
