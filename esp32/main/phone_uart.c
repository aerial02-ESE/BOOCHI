#include "phone_uart.h"

#include <string.h>

#include "driver/uart.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include <stdatomic.h>
#include "sdkconfig.h"

#define PHONE_PORT UART_NUM_2
#define PHONE_RX_GPIO 28
#define PHONE_TX_GPIO 29

static const char *TAG = "phone_uart";
static music_phone_command_cb_t s_callback;
static void *s_context;
static atomic_bool s_ready;

#define PHONE_MAX_PAYLOAD 20
typedef struct {
    uint8_t length;
    uint8_t payload[PHONE_MAX_PAYLOAD];
} phone_tx_item_t;

static QueueHandle_t s_tx_queue;

static void phone_tx_task(void *arg)
{
    (void)arg;
    phone_tx_item_t item;
    while (xQueueReceive(s_tx_queue, &item, portMAX_DELAY) == pdTRUE) {
        uint8_t frame[PHONE_MAX_PAYLOAD + 6] = {0xA5, 0x5A, 1, item.length};
        memcpy(frame + 4, item.payload, item.length);
        const uint16_t crc = smk25_crc16_ccitt_false(frame + 2, item.length + 2);
        frame[item.length + 4] = (uint8_t)(crc >> 8);
        frame[item.length + 5] = (uint8_t)crc;
        uart_write_bytes(PHONE_PORT, frame, item.length + 6);
    }
}

static bool valid_frame(const uint8_t *frame)
{
    return frame[0] == 0xA5 && frame[1] == 0x5A &&
           frame[2] == 1 && frame[3] == SMK25_CONTROL_EVENT_SIZE &&
           smk25_crc16_ccitt_false(frame + 2, 10) ==
               (((uint16_t)frame[12] << 8) | frame[13]);
}

static void phone_rx_task(void *arg)
{
    (void)arg;
    uint8_t frame[SMK25_UART_FRAME_SIZE];
    uint8_t chunk[64];
    size_t used = 0;
    bool session_active = false;
    TickType_t last_rx = 0;
    for (;;) {
        const int count = uart_read_bytes(PHONE_PORT, chunk, sizeof(chunk), pdMS_TO_TICKS(50));
        for (int i = 0; i < count; ++i) {
            frame[used++] = chunk[i];
            if (used != sizeof(frame)) {
                continue;
            }
            if (!valid_frame(frame)) {
                memmove(frame, frame + 1, --used);
                continue;
            }

            static const uint8_t heartbeat[SMK25_CONTROL_EVENT_SIZE] = {0x40};
            const uint8_t *payload = frame + 4;
            if (memcmp(payload, heartbeat, sizeof(heartbeat)) == 0 ||
                s_callback(payload, s_context)) {
                last_rx = xTaskGetTickCount();
                session_active = true;
            } else {
                ESP_LOGW(TAG, "Phone payload rejected (type 0x%02x)", payload[0]);
            }
            used = 0;
        }
        if (session_active && xTaskGetTickCount() - last_rx >= pdMS_TO_TICKS(2000)) {
            const uint8_t off[SMK25_CONTROL_EVENT_SIZE] = {0x49, 0x1f};
            s_callback(off, s_context);
            session_active = false;
            used = 0;
            ESP_LOGW(TAG, "Phone link timeout; released phone notes");
        }
    }
}

esp_err_t music_phone_uart_start(music_phone_command_cb_t callback, void *context)
{
    if (callback == NULL || CONFIG_SMK25_FPGA_UART_PORT == PHONE_PORT) {
        return ESP_ERR_INVALID_ARG;
    }
    const uart_config_t config = {
        .baud_rate = CONFIG_MUSIC_PHONE_UART_BAUD,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };
    esp_err_t err = uart_driver_install(PHONE_PORT, 2048, 2048, 0, NULL, 0);
    if (err != ESP_OK) {
        return err;
    }
    err = uart_param_config(PHONE_PORT, &config);
    if (err == ESP_OK) {
        err = uart_set_pin(PHONE_PORT, PHONE_TX_GPIO, PHONE_RX_GPIO, UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE);
    }
    TaskHandle_t tx_task = NULL;
    if (err == ESP_OK) {
        s_tx_queue = xQueueCreate(64, sizeof(phone_tx_item_t));
        if (s_tx_queue == NULL ||
            xTaskCreate(phone_tx_task, "phone_uart_tx", 3072, NULL, 4, &tx_task) != pdPASS) {
            err = ESP_ERR_NO_MEM;
        }
    }
    if (err == ESP_OK) {
        s_callback = callback;
        s_context = context;
        if (xTaskCreate(phone_rx_task, "phone_uart_rx", 4096, NULL, 6, NULL) != pdPASS) {
            err = ESP_ERR_NO_MEM;
        }
    }
    if (err != ESP_OK) {
        if (tx_task != NULL) vTaskDelete(tx_task);
        if (s_tx_queue != NULL) vQueueDelete(s_tx_queue);
        uart_driver_delete(PHONE_PORT);
        return err;
    }
    s_ready = true;
    ESP_LOGI(TAG, "UART2 RX GPIO%d TX GPIO%d at %d baud, 8N1",
             PHONE_RX_GPIO, PHONE_TX_GPIO, CONFIG_MUSIC_PHONE_UART_BAUD);
    return ESP_OK;
}

void music_phone_uart_publish_raw(const uint8_t *payload, size_t length)
{
    if (!atomic_load(&s_ready) || (length != 8 && length != 20)) {
        return;
    }
    phone_tx_item_t item = { .length = (uint8_t)length };
    memcpy(item.payload, payload, length);
    // Feedback may be dropped if the module cannot keep up. Never stall FPGA events.
    xQueueSend(s_tx_queue, &item, 0);
}

void music_phone_uart_publish(const smk25_control_event_t *event)
{
    music_phone_uart_publish_raw(event->bytes, SMK25_CONTROL_EVENT_SIZE);
}
