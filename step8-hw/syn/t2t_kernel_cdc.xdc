# Timing exceptions for t2t_kernel's clock-domain crossings.
#
# WHY THIS FILE EXISTS: without it the build fails, spectacularly and
# misleadingly. The Vitis flow derives ap_clk and ap_clk_2 from the same clocking
# wizard, so Vivado treats them as SYNCHRONOUS and times every cdc_fifo Gray-code
# pointer path and every toggle synchroniser as a genuine 300 <-> 220 MHz
# transfer. Measured on the first attempt, mid-route:
#
#   INFO: [Route 35-416] Intermediate Timing Summary | WNS=-1.292 | TNS=-2573.227
#   WARNING: [Route 35-3387] High violations detected on bus-skew constraints
#
# and later WNS=-2.657 / TNS=-21179. None of those are real paths, and no amount
# of routing effort fixes them, because the requirement itself is wrong: between
# two clocks that are related but incommensurate the setup window collapses
# towards their beat period. The whole design is BUILT around these crossings
# being asynchronous (see cdc_fifo.sv, which is deliberately written the textbook
# way with Gray pointers and ASYNC_REG), so the constraints have to say so.
#
# step5-board/syn/t2t_axil_cdc.xdc does this job for the out-of-context flow, and
# this is that file rewritten for the kernel. The difference is the clock count:
# step 5 has three domains (cmac_clk, core_clk, axil_clk), whereas here the CMAC
# stand-in and the control plane both run on ap_clk, so the grouping collapses to
# two. The exceptions themselves are unchanged in intent.
#
# Packaged with SCOPED_TO_REF t2t_kernel, so `get_ports ap_clk` resolves inside
# the IP instance rather than at the top of the platform. PROCESSING_ORDER LATE,
# because the cell-based exceptions need the synthesised netlist to exist.

# NO CONTROL FLOW BELOW. An .xdc is not a Tcl script: Vivado parses it with a
# restricted command set, and a defensive `if` around each constraint is rejected
# with "CRITICAL WARNING: [Designutils 20-1307] Command 'if' is not supported in
# the xdc constraint file" -- after which the guarded constraints are simply not
# applied. That failure is silent in the sense that matters: the build proceeds,
# the clock groups are missing, and the only evidence is a timing report that
# blames the design. Straight-line constraints only.

set apclk  [get_clocks -of_objects [get_ports ap_clk]]
set apclk2 [get_clocks -of_objects [get_ports ap_clk_2]]

# ---- 1. the two domains are mutually asynchronous ----
# This single statement is what removes the tens of thousands of nanoseconds of
# meaningless TNS above. What it does NOT do is make a multi-bit bus crossing
# coherent -- that needs a bounded datapath, added below for the crossings that
# actually require it.
set_clock_groups -name t2t_kernel_async -asynchronous -group $apclk -group $apclk2

# The core period is the natural bound for a crossing that must land within one
# core cycle. Read from the clock rather than hardcoded, so changing
# --clock.freqHz does not silently invalidate the exceptions.
set core_p [get_property PERIOD $apclk2]

# ---- 2. cfg_cdc: quasi-static config, snapshot + synchronised enable ----
# axil_regfile drives cfg_bus; on commit cfg_cdc latches it into `snap` (ap_clk)
# and sends a toggle-synchronised enable to the core, which samples `snap` only
# when that enable fires a few cycles later. Correctness depends on `snap`
# reaching the core capture flops WELL BEFORE the enable, so bound the datapath
# to one core period and hold the inter-bit skew inside it. Single-bit
# synchronisers (the toggle itself, the FIFO Gray pointers, the soft-reset
# crossing in t2t_kernel) need nothing here: the async groups plus ASYNC_REG
# cover them.
set cfg_src [get_cells -hier -filter {NAME =~ *u_cfg_cdc/snap_reg[*]}]
set cfg_dst [get_cells -hier -filter {NAME =~ *u_cfg_cdc/dst_data_reg[*]}]
set_max_delay -datapath_only -from $cfg_src -to $cfg_dst $core_p
set_bus_skew                 -from $cfg_src -to $cfg_dst $core_p

# ---- 3. status resync (core -> ap_clk), diagnostic counters ----
# A monitoring read may catch a counter mid-increment: documented and tolerated
# in t2t_axil, so no bus-skew coherency is required. Just bound the hop into the
# first synchroniser stage so a read is never wildly skewed. (set_bus_skew is not
# used here: its sources are counter flops scattered across the datapath, and
# -from a clock is unsupported.)
set st_dst [get_cells -hier -filter {NAME =~ *st_sync0_reg[*]}]
set_max_delay -datapath_only -from $apclk2 -to $st_dst $core_p
