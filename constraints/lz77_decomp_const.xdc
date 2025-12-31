#150 Mhz system clock on top level port clk
create_clock -name sys_clk -period 7.500 [get_ports clk]
