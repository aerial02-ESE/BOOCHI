#include "usb_midi_host.h"

#include <stdbool.h>
#include <string.h>

#include "esp_intr_alloc.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "usb/usb_host.h"

#define USB_AUDIO_CLASS        0x01U
#define USB_MIDI_SUBCLASS       0x03U
#define USB_DESC_INTERFACE      0x04U
#define USB_DESC_ENDPOINT       0x05U
#define USB_EP_DIR_IN           0x80U
#define USB_EP_XFER_BULK        0x02U
#define MIDI_TRANSFER_BYTES     64U
#define MAX_MIDI_DEVICES        1U

typedef struct midi_host_state_s midi_host_state_t;

typedef struct {
    midi_host_state_t *host;
    usb_device_handle_t device;
    usb_transfer_t *transfer;
    uint8_t interface_number;
    uint8_t endpoint_in;
    uint8_t source;
    bool interface_claimed;
    bool transfer_in_flight;
    bool device_gone;
} midi_device_t;

struct midi_host_state_s {
    smk25_usb_midi_host_config_t config;
    usb_host_client_handle_t client;
    midi_device_t devices[MAX_MIDI_DEVICES];
};

static const char *TAG = "usb_midi_smk25";
static midi_host_state_t s_host;

static bool find_midi_bulk_in(const usb_config_desc_t *config, uint8_t *interface_number,
                              uint8_t *endpoint_in)
{
    const uint8_t *cursor = (const uint8_t *)config;
    const uint8_t *end = cursor + config->wTotalLength;
    bool in_midi_interface = false;
    while (cursor + 2 <= end) {
        const uint8_t length = cursor[0];
        const uint8_t type = cursor[1];
        if (length < 2U || cursor + length > end) {
            break;
        }
        if (type == USB_DESC_INTERFACE && length >= 9U) {
            in_midi_interface = cursor[5] == USB_AUDIO_CLASS &&
                                cursor[6] == USB_MIDI_SUBCLASS && cursor[3] == 0U;
            if (in_midi_interface) {
                *interface_number = cursor[2];
            }
        } else if (type == USB_DESC_ENDPOINT && length >= 7U && in_midi_interface) {
            const uint8_t address = cursor[2];
            const uint8_t attributes = cursor[3] & 0x03U;
            if ((address & USB_EP_DIR_IN) != 0U && attributes == USB_EP_XFER_BULK) {
                *endpoint_in = address;
                return true;
            }
        }
        cursor += length;
    }
    return false;
}

static int source_for_device(midi_host_state_t *host, usb_device_handle_t device)
{
    usb_device_info_t info = {0};
    if (usb_host_device_info(device, &info) != ESP_OK) {
        return -1;
    }
    /* Only the directly attached SMK-25 belongs on this USB controller. */
    if (info.parent.dev_hdl == NULL) {
        return 0;
    }
    ESP_LOGW(TAG, "ignoring MIDI address %u behind unsupported hub port %u", info.dev_addr,
             info.parent.port_num);
    return -1;
}

static midi_device_t *find_free_slot(midi_host_state_t *host, uint8_t source)
{
    for (size_t i = 0; i < MAX_MIDI_DEVICES; ++i) {
        if (host->devices[i].device != NULL && host->devices[i].source == source) {
            return NULL;
        }
    }
    for (size_t i = 0; i < MAX_MIDI_DEVICES; ++i) {
        if (host->devices[i].device == NULL) {
            return &host->devices[i];
        }
    }
    return NULL;
}

static void close_device(midi_device_t *midi, bool notify_disconnect)
{
    midi_host_state_t *host = midi->host;
    if (midi->transfer_in_flight || host == NULL) {
        return;
    }
    if (midi->transfer != NULL) {
        usb_host_transfer_free(midi->transfer);
    }
    if (midi->interface_claimed) {
        usb_host_interface_release(host->client, midi->device, midi->interface_number);
    }
    if (midi->device != NULL) {
        usb_host_device_close(host->client, midi->device);
    }
    const uint8_t source = midi->source;
    memset(midi, 0, sizeof(*midi));
    if (notify_disconnect && host->config.disconnect_cb != NULL) {
        host->config.disconnect_cb(source, host->config.context);
    }
}

static void transfer_callback(usb_transfer_t *transfer)
{
    midi_device_t *midi = (midi_device_t *)transfer->context;
    midi_host_state_t *host = midi->host;
    midi->transfer_in_flight = false;
    if (transfer->status == USB_TRANSFER_STATUS_COMPLETED) {
        const int complete_bytes = transfer->actual_num_bytes & ~3;
        for (int offset = 0; offset < complete_bytes; offset += 4) {
            if (host->config.packet_cb != NULL) {
                host->config.packet_cb(midi->source, &transfer->data_buffer[offset], host->config.context);
            }
        }
    } else if (transfer->status != USB_TRANSFER_STATUS_NO_DEVICE &&
               transfer->status != USB_TRANSFER_STATUS_CANCELED) {
        ESP_LOGW(TAG, "source %u bulk-IN status=%d", midi->source, transfer->status);
    }
    if (!midi->device_gone) {
        transfer->num_bytes = MIDI_TRANSFER_BYTES;
        const esp_err_t err = usb_host_transfer_submit(transfer);
        if (err == ESP_OK) {
            midi->transfer_in_flight = true;
        } else {
            ESP_LOGE(TAG, "source %u bulk-IN resubmit: %s", midi->source, esp_err_to_name(err));
            midi->device_gone = true;
        }
    }
}

static void open_device(midi_host_state_t *host, uint8_t address)
{
    usb_device_handle_t device = NULL;
    bool claimed = false;
    uint8_t interface_number = 0;
    uint8_t endpoint_in = 0;
    midi_device_t *slot = NULL;
    esp_err_t err = usb_host_device_open(host->client, address, &device);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "open USB address %u: %s", address, esp_err_to_name(err));
        return;
    }
    const usb_config_desc_t *config = NULL;
    err = usb_host_get_active_config_descriptor(device, &config);
    if (err != ESP_OK || !find_midi_bulk_in(config, &interface_number, &endpoint_in)) {
        /* The CH334F Hub itself reaches here; it is not a MIDI endpoint. */
        usb_host_device_close(host->client, device);
        return;
    }
    const int source = source_for_device(host, device);
    slot = source >= 0 ? find_free_slot(host, (uint8_t)source) : NULL;
    if (slot == NULL) {
        ESP_LOGW(TAG, "no available source slot for USB address %u", address);
        usb_host_device_close(host->client, device);
        return;
    }
    err = usb_host_interface_claim(host->client, device, interface_number, 0);
    if (err != ESP_OK) {
        goto fail;
    }
    claimed = true;
    memset(slot, 0, sizeof(*slot));
    slot->host = host;
    slot->device = device;
    slot->interface_number = interface_number;
    slot->endpoint_in = endpoint_in;
    slot->source = (uint8_t)source;
    slot->interface_claimed = true;
    err = usb_host_transfer_alloc(MIDI_TRANSFER_BYTES, 0, &slot->transfer);
    if (err != ESP_OK) {
        goto fail;
    }
    slot->transfer->device_handle = device;
    slot->transfer->bEndpointAddress = endpoint_in;
    slot->transfer->callback = transfer_callback;
    slot->transfer->context = slot;
    slot->transfer->num_bytes = MIDI_TRANSFER_BYTES;
    err = usb_host_transfer_submit(slot->transfer);
    if (err != ESP_OK) {
        goto fail;
    }
    slot->transfer_in_flight = true;
    ESP_LOGI(TAG, "source %u: MIDI address %u, interface %u, bulk-IN 0x%02x",
             slot->source, address, interface_number, endpoint_in);
    return;

fail:
    ESP_LOGW(TAG, "MIDI address %u setup: %s", address, esp_err_to_name(err));
    if (slot != NULL && slot->device != NULL) {
        slot->transfer_in_flight = false;
        close_device(slot, false);
    } else {
        if (claimed) {
            usb_host_interface_release(host->client, device, interface_number);
        }
        usb_host_device_close(host->client, device);
    }
}

static void client_event_callback(const usb_host_client_event_msg_t *event_msg, void *arg)
{
    midi_host_state_t *host = (midi_host_state_t *)arg;
    if (event_msg->event == USB_HOST_CLIENT_EVENT_NEW_DEV) {
        open_device(host, event_msg->new_dev.address);
    } else if (event_msg->event == USB_HOST_CLIENT_EVENT_DEV_GONE) {
        for (size_t i = 0; i < MAX_MIDI_DEVICES; ++i) {
            midi_device_t *midi = &host->devices[i];
            if (midi->device == event_msg->dev_gone.dev_hdl) {
                midi->device_gone = true;
                if (midi->transfer_in_flight) {
                    usb_host_endpoint_halt(midi->device, midi->endpoint_in);
                    usb_host_endpoint_flush(midi->device, midi->endpoint_in);
                }
            }
        }
    }
}

static void usb_client_task(void *arg)
{
    midi_host_state_t *host = (midi_host_state_t *)arg;
    const usb_host_client_config_t client_config = {
        .is_synchronous = false,
        .max_num_event_msg = 16,
        .async = {.client_event_callback = client_event_callback, .callback_arg = host},
    };
    ESP_ERROR_CHECK(usb_host_client_register(&client_config, &host->client));
    uint8_t addresses[8];
    int count = 0;
    if (usb_host_device_addr_list_fill(8, addresses, &count) == ESP_OK) {
        for (int i = 0; i < count; ++i) {
            open_device(host, addresses[i]);
        }
    }
    for (;;) {
        const esp_err_t err = usb_host_client_handle_events(host->client, pdMS_TO_TICKS(100));
        if (err != ESP_OK && err != ESP_ERR_TIMEOUT) {
            ESP_LOGE(TAG, "USB client event loop: %s", esp_err_to_name(err));
        }
        for (size_t i = 0; i < MAX_MIDI_DEVICES; ++i) {
            midi_device_t *midi = &host->devices[i];
            if (midi->device_gone && !midi->transfer_in_flight) {
                close_device(midi, true);
            }
        }
    }
}

static void usb_daemon_task(void *arg)
{
    (void)arg;
    const usb_host_config_t host_config = {
        .skip_phy_setup = false,
        .root_port_unpowered = false,
        .intr_flags = ESP_INTR_FLAG_LEVEL1,
        .enum_filter_cb = NULL,
    };
    ESP_ERROR_CHECK(usb_host_install(&host_config));
    ESP_LOGI(TAG, "USB Host ready: direct SMK-25 root device only");
    ESP_ERROR_CHECK(xTaskCreate(usb_client_task, "midi_usb_client", 5120, &s_host, 5, NULL) == pdPASS
                        ? ESP_OK : ESP_ERR_NO_MEM);
    for (;;) {
        uint32_t flags = 0;
        const esp_err_t err = usb_host_lib_handle_events(portMAX_DELAY, &flags);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "USB daemon event loop: %s", esp_err_to_name(err));
        }
    }
}

esp_err_t smk25_usb_midi_host_start(const smk25_usb_midi_host_config_t *config)
{
    if (config == NULL || config->packet_cb == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    memset(&s_host, 0, sizeof(s_host));
    s_host.config = *config;
    return xTaskCreate(usb_daemon_task, "midi_usb_daemon", 4096, NULL, 6, NULL) == pdPASS
               ? ESP_OK : ESP_ERR_NO_MEM;
}
