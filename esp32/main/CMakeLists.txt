idf_component_register(
    SRCS
        "app_main.c"
        "control_event.c"
        "midi_bridge.c"
        "pedal_refresh.c"
        "practice_protocol.c"
        "phone_command.c"
        "phone_uart.c"
        "protocol_vectors.c"
        "score_store.c"
        "uart_link.c"
        "usb_midi_host.c"
    INCLUDE_DIRS "."
    REQUIRES driver usb nvs_flash esp_partition esp_timer
)
