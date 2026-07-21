create_clock -name cmac_clk -period 3.103 [get_ports cmac_clk]
create_clock -name core_clk -period 4.618 [get_ports core_clk]
set_clock_groups -asynchronous \
  -group [get_clocks cmac_clk] -group [get_clocks core_clk]
