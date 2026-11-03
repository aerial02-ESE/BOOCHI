#include "score_store.h"

#include <string.h>
#include "esp_partition.h"
#include "esp_log.h"

#define SCORE_PARTITION_SUBTYPE 0x40
#define SCORE_MAGIC 0x3131534dUL /* MS11 in little-endian storage */
#define SCORE_HEADER_SIZE 16U

static const char *TAG = "score_store";
static const esp_partition_t *s_partition;
static uint8_t s_records[SCORE_MAX_RECORDS * SCORE_RECORD_SIZE];
static uint8_t s_note_meta[SCORE_MAX_RECORDS];
static uint16_t s_count;
static uint16_t s_expected;
static uint16_t s_crc;
static bool s_uploading;
static bool s_valid;

static bool decode_record(const uint8_t *bytes, score_note_event_t *event);

static uint8_t duration_class(uint32_t ms)
{
    if (ms < 250U) return 0U;  /* short: two underlines */
    if (ms < 750U) return 1U;  /* medium: plain digit */
    if (ms < 1500U) return 2U; /* long: one trailing dash */
    return 3U;                 /* very long: two trailing dashes */
}

static void rebuild_note_meta(void)
{
    uint16_t active[3][128] = {{0}}; /* index + 1, zero = no onset */
    uint32_t previous_onset = 0;
    bool had_onset = false;
    memset(s_note_meta, 0, sizeof(s_note_meta));
    for (uint16_t i = 0; i < s_count; ++i) {
        score_note_event_t event;
        if (!decode_record(s_records + (size_t)i * SCORE_RECORD_SIZE, &event))
            continue;
        uint16_t *held = &active[event.instrument][event.note];
        if (*held != 0U) {
            score_note_event_t onset;
            const uint16_t onset_index = (uint16_t)(*held - 1U);
            if (decode_record(s_records + (size_t)onset_index * SCORE_RECORD_SIZE,
                              &onset))
                s_note_meta[onset_index] = (s_note_meta[onset_index] & 0x0cU) |
                    duration_class(event.at_ms - onset.at_ms);
            *held = 0U;
        }
        if (event.on) {
            uint8_t flags = 1U; /* unmatched note has a medium marker */
            if (had_onset && event.at_ms == previous_onset) flags |= 0x04U;
            if (had_onset && event.at_ms - previous_onset >= 750U) flags |= 0x08U;
            s_note_meta[i] = flags;
            *held = (uint16_t)(i + 1U);
            previous_onset = event.at_ms;
            had_onset = true;
        }
    }
}

static uint16_t crc_step(uint16_t crc, uint8_t byte)
{
    crc ^= (uint16_t)byte << 8;
    for (unsigned bit = 0; bit < 8; ++bit)
        crc = (crc & 0x8000U) ? (uint16_t)((crc << 1) ^ 0x1021U) :
                               (uint16_t)(crc << 1);
    return crc;
}

static uint16_t crc_bytes(const uint8_t *data, size_t length)
{
    uint16_t crc = 0xffffU;
    for (size_t i = 0; i < length; ++i) crc = crc_step(crc, data[i]);
    return crc;
}

static uint32_t read_u32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static bool decode_record(const uint8_t *bytes, score_note_event_t *event)
{
    if (bytes[0] != SCORE_RECORD_TYPE || bytes[4] > 127U ||
        bytes[5] > 127U || bytes[6] != 0U || bytes[7] != 0U)
        return false;
    event->instrument = bytes[1] >> 6;
    event->on = (bytes[1] & 0x20U) != 0U;
    event->at_ms = ((uint32_t)(bytes[1] & 0x1fU) << 16) |
                   ((uint32_t)bytes[2] << 8) | bytes[3];
    event->note = bytes[4];
    event->velocity = bytes[5];
    return event->instrument <= 2U && event->at_ms <= 600000U &&
           (event->on ? event->velocity > 0U : event->velocity == 0U);
}

esp_err_t score_store_init(void)
{
    s_partition = esp_partition_find_first(ESP_PARTITION_TYPE_DATA,
                                            SCORE_PARTITION_SUBTYPE, "score");
    if (s_partition == NULL || s_partition->size < SCORE_HEADER_SIZE + sizeof(s_records))
        return ESP_ERR_NOT_FOUND;
    uint8_t header[SCORE_HEADER_SIZE];
    esp_err_t err = esp_partition_read(s_partition, 0, header, sizeof(header));
    if (err != ESP_OK) return err;
    if (read_u32(header) != SCORE_MAGIC || header[4] != 1U ||
        header[5] != 0U || header[10] != 0U || header[11] != 0U)
        return ESP_OK; /* Blank or older Flash contents are not a song. */
    const uint16_t count = (uint16_t)header[6] | ((uint16_t)header[7] << 8);
    const uint16_t stored_crc = (uint16_t)header[8] | ((uint16_t)header[9] << 8);
    if (count == 0U || count > SCORE_MAX_RECORDS) return ESP_OK;
    err = esp_partition_read(s_partition, SCORE_HEADER_SIZE, s_records,
                             (size_t)count * SCORE_RECORD_SIZE);
    if (err != ESP_OK) return err;
    if (crc_bytes(s_records, (size_t)count * SCORE_RECORD_SIZE) != stored_crc)
        return ESP_OK;
    uint32_t previous = 0;
    for (uint16_t i = 0; i < count; ++i) {
        score_note_event_t event;
        if (!decode_record(s_records + (size_t)i * SCORE_RECORD_SIZE, &event) ||
            event.at_ms < previous) return ESP_OK;
        previous = event.at_ms;
    }
    s_count = count;
    s_valid = true;
    rebuild_note_meta();
    ESP_LOGI(TAG, "loaded %u score events from Flash", count);
    return ESP_OK;
}

bool score_store_begin(uint16_t expected)
{
    if (expected == 0U || expected > SCORE_MAX_RECORDS) return false;
    s_expected = expected;
    s_count = 0;
    s_crc = 0xffffU;
    s_uploading = true;
    s_valid = false;
    return true;
}

bool score_store_append(const uint8_t bytes[SCORE_RECORD_SIZE])
{
    score_note_event_t event;
    if (!s_uploading || s_count >= s_expected || !decode_record(bytes, &event))
        return false;
    if (s_count != 0U) {
        score_note_event_t previous;
        (void)decode_record(s_records + (size_t)(s_count - 1U) * SCORE_RECORD_SIZE,
                            &previous);
        if (event.at_ms < previous.at_ms) return false;
    }
    memcpy(s_records + (size_t)s_count * SCORE_RECORD_SIZE, bytes, SCORE_RECORD_SIZE);
    for (unsigned i = 0; i < SCORE_RECORD_SIZE; ++i) s_crc = crc_step(s_crc, bytes[i]);
    ++s_count;
    return true;
}

bool score_store_commit(uint16_t expected_crc)
{
    if (!s_uploading || s_count != s_expected || s_crc != expected_crc)
        return false;
    uint8_t header[SCORE_HEADER_SIZE] = { 'M', 'S', '1', '1', 1, 0,
        (uint8_t)s_count, (uint8_t)(s_count >> 8),
        (uint8_t)s_crc, (uint8_t)(s_crc >> 8), 0, 0, 0, 0, 0, 0 };
    const size_t bytes = SCORE_HEADER_SIZE + (size_t)s_count * SCORE_RECORD_SIZE;
    const size_t erase_bytes = (bytes + 4095U) & ~4095U;
    esp_err_t err = esp_partition_erase_range(s_partition, 0, erase_bytes);
    if (err == ESP_OK)
        err = esp_partition_write(s_partition, SCORE_HEADER_SIZE, s_records,
                                  (size_t)s_count * SCORE_RECORD_SIZE);
    if (err == ESP_OK)
        err = esp_partition_write(s_partition, 0, header, sizeof(header));
    if (err == ESP_OK) {
        uint8_t verify_header[SCORE_HEADER_SIZE];
        err = esp_partition_read(s_partition, 0, verify_header, sizeof(verify_header));
        if (err == ESP_OK && memcmp(header, verify_header, sizeof(header)) != 0)
            err = ESP_FAIL;
    }
    if (err == ESP_OK) {
        uint8_t verify[256];
        uint16_t verify_crc = 0xffffU;
        const size_t record_bytes = (size_t)s_count * SCORE_RECORD_SIZE;
        for (size_t offset = 0; offset < record_bytes && err == ESP_OK;
             offset += sizeof(verify)) {
            const size_t part = record_bytes - offset < sizeof(verify) ?
                                record_bytes - offset : sizeof(verify);
            err = esp_partition_read(s_partition, SCORE_HEADER_SIZE + offset,
                                     verify, part);
            if (err == ESP_OK)
                for (size_t i = 0; i < part; ++i)
                    verify_crc = crc_step(verify_crc, verify[i]);
        }
        if (err == ESP_OK && verify_crc != s_crc) err = ESP_FAIL;
    }
    s_uploading = false;
    s_valid = err == ESP_OK;
    if (s_valid) rebuild_note_meta();
    if (err != ESP_OK) ESP_LOGE(TAG, "score Flash commit failed: %s", esp_err_to_name(err));
    else ESP_LOGI(TAG, "stored %u score events", s_count);
    return err == ESP_OK;
}

uint16_t score_store_count(void) { return s_valid ? s_count : 0U; }

bool score_store_get(uint16_t index, score_note_event_t *event)
{
    return s_valid && index < s_count && event != NULL &&
           decode_record(s_records + (size_t)index * SCORE_RECORD_SIZE, event);
}

uint8_t score_store_note_meta(uint16_t index)
{
    return s_valid && index < s_count ? s_note_meta[index] : 0U;
}
