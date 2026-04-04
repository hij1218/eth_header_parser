# Clock constraint: 312.5 MHz (3.2 ns period)
create_clock -period 3.200 -name clk [get_ports clk]

# Clock uncertainty (6% of period = 0.192 ns)
set_clock_uncertainty 0.192 [get_clocks clk]
