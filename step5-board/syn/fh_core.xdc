# 100G CMAC datapath clock: 322.265625 MHz -> 3.103 ns.
# Read before synth_design so the constraint is in force during synthesis
# (create_clock cannot run before a design exists).
create_clock -name clk -period 3.103 [get_ports clk]
