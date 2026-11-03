create_clock -name sys_clk_50m -period 20.000 [get_ports {sys_clk_50m}]
# Two USB3300 CLKOUTs from HOST v4 on Dock J13 (U1=B17, U3=E17).  They are
# asynchronous to the system clock and to each other.  Events cross through
# event_cdc_fifo.
create_clock -name ulpi0_clk -period 16.667 [get_ports {ulpi0_clk}]
create_clock -name ulpi1_clk -period 16.667 [get_ports {ulpi1_clk}]
set_clock_groups -asynchronous -group [get_clocks {sys_clk_50m}] -group [get_clocks {ulpi0_clk}] -group [get_clocks {ulpi1_clk}]
