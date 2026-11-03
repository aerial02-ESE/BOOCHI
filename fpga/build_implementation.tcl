open_project tang_mega_60k_spectrum_keys.gprj
set_option -top_module tang_mega_60k_usbhost_top
set_option -use_sspi_as_gpio 1
set_option -use_i2c_as_gpio 1
set_option -place_option 2
set_option -route_option 2
set_option -convert_sdp32_36_to_sdp16_18 0
run all
