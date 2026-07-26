# Timing exceptions for the t2t_axil wrapper's clock-domain crossings.
#
# The create_clock statements live in the flow script (periods vary per run);
# this file holds the period-independent exceptions and is the constraint set an
# OpenNIC user box imports alongside its own clock definitions. It reads the
# three clocks by name: cmac_clk (322.27 MHz), core_clk (~216 MHz), axil_clk
# (~250 MHz, QDMA). The cell-based exceptions reference the post-synthesis
# netlist, so this file is read AFTER synth_design (get_cells finds nothing on
# an elaborated-only design).
#
# WHY THIS FILE EXISTS. Without the asynchronous clock groups, Vivado times the
# Gray-code FIFO pointers and the toggle synchronisers as if the domains were
# synchronous and reports enormous, meaningless setup violations. The groups cut
# those false paths. What the groups do NOT do is guarantee that a MULTI-BIT bus
# crossing arrives coherently -- that needs a bounded datapath, added below only
# for the two multi-bit crossings that require it.

# ---- 1. the three domains are mutually asynchronous ----
set_clock_groups -name t2t_async -asynchronous \
  -group [get_clocks cmac_clk] \
  -group [get_clocks core_clk] \
  -group [get_clocks axil_clk]

set core_p [get_property PERIOD [get_clocks core_clk]]

# ---- 2. cfg_cdc: quasi-static config, snapshot + synchronised enable ----
# axil_regfile drives cfg_bus; on commit cfg_cdc latches it into `snap` (axil)
# and sends a toggle-synchronised enable to the core. The core samples `snap`
# only when that enable fires, ~2-3 core cycles later. Correctness depends on
# `snap` reaching the core capture flops WELL BEFORE the enable -- so bound the
# datapath to one core period and hold the inter-bit skew inside it. Single-bit
# synchronisers (the toggle itself, the FIFO Gray pointers) are handled by the
# async groups above plus their ASYNC_REG attribute and need nothing here.
set cfg_src [get_cells -hier -filter {NAME =~ *u_cfg_cdc/snap_reg[*]}]
set cfg_dst [get_cells -hier -filter {NAME =~ *u_cfg_cdc/dst_data_reg[*]}]
set_max_delay -datapath_only -from $cfg_src -to $cfg_dst $core_p
set_bus_skew                 -from $cfg_src -to $cfg_dst $core_p

# ---- 3. status resync (core -> axil), diagnostic counters ----
# A monitoring read may catch a counter mid-increment (documented, tolerated),
# so no bus-skew coherency is required here -- just bound the core->axil hop into
# the first synchroniser stage so a read is never wildly skewed. (set_bus_skew
# is not used: its sources are counter flops scattered across the datapath, and
# -from a clock is unsupported; the max_delay bound is what this crossing needs.)
set st_dst [get_cells -hier -filter {NAME =~ *st_sync0_reg[*]}]
set_max_delay -datapath_only -from [get_clocks core_clk] -to $st_dst $core_p
