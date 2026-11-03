#include "uart_link.h"

#include "driver/uart.h"
#include "driver/gpio.h"
#include "esp_log.h"
#include "sdkconfig.h"

static const char *TAG = "smk25_uart";
static bool s_enabled;

esp_err_t smk25_uart_link_init(void)
{
    s_enabled = false;
    if (CONFIG_SMK25_FPGA_UART_TX_GPIO < 0) {
        ESP_LOGW(TAG, "FPGA UART TX GPIO is unset; physical UART output remains disabled");
        return ESP_OK;
    }

    const uart_port_t port = (uart_port_t)CONFIG_SMK25_FPGA_UART_PORT;
    const uart_config_t config = {
        .baud_rate = CONFIG_SMK25_FPGA_UART_BAUD,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };
    /* RX carries CRC-protected practice snapshots; TX keeps the unique event stream. */
    esp_err_t err = uart_driver_install(port, 1024, 256, 0, NULL, 0);
    if (err != ESP_OK) {
        return err;
    }
    err = uart_param_config(port, &config);
    if (err == ESP_OK) {
        err = uart_set_pin(port, CONFIG_SMK25_FPGA_UART_TX_GPIO,
                           CONFIG_SMK25_FPGA_UART_RX_GPIO<0 ? UART_PIN_NO_CHANGE : CONFIG_SMK25_FPGA_UART_RX_GPIO,
                           UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE);
        if(err==ESP_OK&&CONFIG_SMK25_FPGA_UART_RX_GPIO>=0)
            gpio_set_pull_mode((gpio_num_t)CONFIG_SMK25_FPGA_UART_RX_GPIO,GPIO_PULLUP_ONLY);
    }
    if (err != ESP_OK) {
        uart_driver_delete(port);
        return err;
    }
    s_enabled = true;
    ESP_LOGI(TAG, "DNESP32P4 UART%d TX GPIO%d, %d baud, 8N1", CONFIG_SMK25_FPGA_UART_PORT,
             CONFIG_SMK25_FPGA_UART_TX_GPIO, CONFIG_SMK25_FPGA_UART_BAUD);
    ESP_LOGI(TAG, "FPGA feedback RX GPIO%d (-1 disables feedback)",CONFIG_SMK25_FPGA_UART_RX_GPIO);
    return ESP_OK;
}

bool smk25_uart_link_is_enabled(void)
{
    return s_enabled;
}

esp_err_t smk25_uart_link_send(const smk25_control_event_t *event)
{
    if (event == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!s_enabled) {
        return ESP_OK;
    }
    uint8_t frame[SMK25_UART_FRAME_SIZE];
    smk25_uart_frame_encode(event, frame);
    const int written = uart_write_bytes((uart_port_t)CONFIG_SMK25_FPGA_UART_PORT,
                                         frame, sizeof(frame));
    return written == (int)sizeof(frame) ? ESP_OK : ESP_FAIL;
}
