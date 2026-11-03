onerror {quit -code 1 -force}
onbreak {resume}
if {![file isdirectory tests/work_usb88_led]} {vlib tests/work_usb88_led}
vmap work tests/work_usb88_led
vlog +incdir+src +incdir+rtl/audio rtl/*.v rtl/audio/*.v rtl/usb/*.v rtl/led/*.v rtl/input/*.v
vlog -sv tests/tb_dual_led88.sv tests/tb_usb88_led_outputs.sv
vsim -voptargs=+acc work.tb_usb88_led_outputs
onfinish stop
run -all
quit -code 0 -force
