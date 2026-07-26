# Create the core-clock MMCM IP (t2t_core_clk) for the OpenNIC build.
#
# Generates core_clk = 200 MHz from cmac_clk = 322.265625 MHz. 200 MHz sits
# between the 100 Gb/s floor (195.3 MHz) and the datapath's post-route Fmax
# (~226 MHz), so the core has margin on both sides. Source this from the
# open-nic-shell build after the project is created, before synthesis:
#
#   source .../create_t2t_core_clk.tcl
#
# The generated module name is t2t_core_clk, matching the instance in
# t2t_user_322mhz.sv. locked is exported so the core reset can wait for it.
create_ip -name clk_wiz -vendor xilinx.com -library ip -module_name t2t_core_clk
set_property -dict [list \
  CONFIG.PRIMITIVE                {MMCM} \
  CONFIG.PRIM_IN_FREQ             {322.265625} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
  CONFIG.USE_LOCKED               {true} \
  CONFIG.USE_RESET                {true} \
  CONFIG.RESET_TYPE               {ACTIVE_HIGH} \
  CONFIG.RESET_PORT               {reset} \
  CONFIG.CLK_IN1_BOARD_INTERFACE  {Custom} \
  CONFIG.PRIM_SOURCE              {Global_buffer} \
] [get_ips t2t_core_clk]
generate_target all [get_ips t2t_core_clk]
