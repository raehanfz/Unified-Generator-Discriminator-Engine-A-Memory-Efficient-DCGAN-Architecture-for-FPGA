## Clock signal (assuming a 100MHz onboard oscillator)
set_property -dict { PACKAGE_PIN W5   IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -add -name sys_clk_pin -period 20.00 -waveform {0 5} [get_ports clk]