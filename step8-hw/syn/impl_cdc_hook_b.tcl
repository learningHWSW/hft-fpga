# Top-level CDC exceptions for the Phase B kernel: THREE asynchronous domains.
#
# impl_cdc_hook.tcl explains why this is a Tcl hook and not the packaged .xdc --
# the packaged file is scoped to the kernel's out-of-context synthesis, not to
# the top-level implementation where place and route happen, and an .xdc rejects
# the `if` needed to discover clock names that Vitis invents. All of that still
# applies. What changes here is the third domain.
#
# ap_clk and ap_clk_2 both come from the platform's clocking wizard, so Vivado
# believes they are synchronous and will time every cdc_fifo Gray pointer between
# them unless told otherwise. wire_clk is different in kind: it is gt_txusrclk2,
# recovered by the CMAC from the QSFP reference oscillator, and it is
# asynchronous to the platform's clocks as a matter of physics rather than of
# constraint style. Vivado still has to be told, because it will not infer that
# two unrelated clock trees are unrelated.
#
# FINDING wire_clk. There is no port to ask about -- it is generated inside the
# MAC IP -- and its clock name depends on what the IP's own constraints call it,
# which is not a contract. So it is found by asking which clock drives a register
# that is UNAMBIGUOUSLY in that domain: axis_sf_fifo's committed-frame-count
# synchroniser on the feed FIFO's READ side, which by construction runs on the
# MAC clock. That is a register this repo wrote, in a module this repo controls,
# rather than an internal name of a vendor IP.
#
# init_clk goes in ap_clk's group rather than its own. It is a BUFGCE_DIV of
# three off ap_clk, so those two ARE related and paths between them should be
# timed normally; grouping them together says exactly that, while still cutting
# init_clk against the core and the wire.
#
# Wired in via: --config with run.impl_1.STEPS.OPT_DESIGN.TCL.PRE

puts "=== t2t Phase B CDC hook: locating three clock domains ==="

set ap_pins  [get_pins -quiet -hier -filter {NAME =~ *t2t_kernel_b_1*/ap_clk}]
set ap2_pins [get_pins -quiet -hier -filter {NAME =~ *t2t_kernel_b_1*/ap_clk_2}]

set c_ap  [get_clocks -quiet -of_objects $ap_pins]
set c_ap2 [get_clocks -quiet -of_objects $ap2_pins]

if {[llength $c_ap] == 0}  { set c_ap  [get_clocks -quiet clk_kernel_00_unbuffered_net] }
if {[llength $c_ap2] == 0} { set c_ap2 [get_clocks -quiet clk_out1_ulp_clk_wiz_0] }

# the MAC's stream clock, via a register this design owns
set w_cells [get_cells -quiet -hier -filter {NAME =~ *u_feed_fifo/pw_sync_q_reg*}]
set c_w {}
if {[llength $w_cells]} {
  set c_w [get_clocks -quiet -of_objects [get_pins -quiet -of_objects $w_cells -filter {REF_PIN_NAME == C}]]
}
# fall back to the CMAC's own output pin if the FIFO registers were renamed
if {[llength $c_w] == 0} {
  set w_pins [get_pins -quiet -hier -filter {NAME =~ *u_cmac*gt_txusrclk2*}]
  set c_w [get_clocks -quiet -of_objects $w_pins]
}

# init_clk: the BUFGCE_DIV output. Related to ap_clk, so it joins its group.
set i_pins [get_pins -quiet -hier -filter {NAME =~ *u_init_div/O}]
set c_i [get_clocks -quiet -of_objects $i_pins]

# a clock can be reported more than once through different pins
set c_ap  [lsort -unique $c_ap]
set c_ap2 [lsort -unique $c_ap2]
set c_w   [lsort -unique $c_w]
set c_i   [lsort -unique $c_i]

puts "=== t2t Phase B CDC hook: ap_clk   -> $c_ap"
puts "=== t2t Phase B CDC hook: ap_clk_2 -> $c_ap2"
puts "=== t2t Phase B CDC hook: wire_clk -> $c_w"
puts "=== t2t Phase B CDC hook: init_clk -> $c_i"

set g_ap [concat $c_ap $c_i]

if {[llength $c_ap] && [llength $c_ap2] && [llength $c_w]} {
  set_clock_groups -name t2t_kernel_b_async_impl -asynchronous \
    -group $g_ap -group $c_ap2 -group $c_w
  puts "=== t2t Phase B CDC hook: three asynchronous groups APPLIED ==="

  # cfg_cdc's config snapshot must land well before the enable that tells the
  # core to sample it -- the one multi-bit crossing here that needs coherency
  # rather than merely being cut. Single-bit synchronisers (FIFO Gray pointers,
  # the soft-reset and clear crossings, the status resyncs) need nothing beyond
  # the groups above plus their ASYNC_REG attribute.
  set core_p [get_property PERIOD $c_ap2]
  set cfg_src [get_cells -quiet -hier -filter {NAME =~ *u_cfg_cdc/snap_reg[*]}]
  set cfg_dst [get_cells -quiet -hier -filter {NAME =~ *u_cfg_cdc/dst_data_reg[*]}]
  if {[llength $cfg_src] && [llength $cfg_dst]} {
    set_max_delay -datapath_only -from $cfg_src -to $cfg_dst $core_p
    set_bus_skew                 -from $cfg_src -to $cfg_dst $core_p
    puts "=== t2t Phase B CDC hook: cfg_cdc datapath bounded to $core_p ns ==="
  } else {
    puts "WARNING: t2t Phase B CDC hook found no cfg_cdc snapshot registers"
  }
} else {
  puts "ERROR: t2t Phase B CDC hook could not identify all three clock domains -- \
crossings will be timed as synchronous and hold will fail on all of them"
}
