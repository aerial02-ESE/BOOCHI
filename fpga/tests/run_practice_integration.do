onerror {quit -code 1 -force}
onbreak {resume}
if {![file isdirectory tests/work_practice_integration]} {vlib tests/work_practice_integration}
vmap work tests/work_practice_integration
vlog +incdir+src +incdir+rtl/audio rtl/*.v rtl/audio/*.v rtl/led/*.v rtl/usb/*.v rtl/input/*.v
vlog -sv tests/tb_dual_led88.sv tests/tb_practice_led.sv tests/tb_practice_integration.sv
foreach bench {tb_dual_led88 tb_practice_led tb_practice_integration} {
vsim -voptargs=+acc work.$bench
onfinish stop
run -all
quit -sim
}
quit -code 0 -force
