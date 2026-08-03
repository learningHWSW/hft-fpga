# Top-level CDC exceptions, applied as a Vivado implementation pre-hook.
#
# WHY A HOOK AND NOT THE PACKAGED XDC. syn/t2t_kernel_cdc.xdc travels inside the
# .xo and is delivered correctly (it appears in prj.gen/.../ulp_t2t_kernel_1_0/src/),
# but with SCOPED_TO_REF it applies to the IP's own out-of-context synthesis --
# not to the top-level implementation, where place and route actually happen. The
# evidence is in the init timing report: the 1,565 crossings between the two
# kernel clocks are TIMED rather than cut, and hold fails on every one of them
# (WHS -0.571, THS -348 over 614 paths one way and 951 the other).
#
# Those are false paths. cdc_fifo is the textbook construction -- Gray-coded
# pointers, ASYNC_REG synchronisers -- so hardware is unaffected, but the router
# will spend real effort inserting delay to "fix" hold on paths that do not need
# it, and may not converge. The constraint has to exist where the router can see
# it.
#
# A .tcl hook also sidesteps the trap that silently voided the first version of
# the XDC: an .xdc is parsed with a restricted command set and rejects `if`
# ("CRITICAL WARNING: [Designutils 20-1307]"), whereas a Tcl hook is real Tcl.
# That matters here because the clock names are NOT known in advance -- Vitis
# generates the second clock through a clock wizard whose net is named
# clk_out1_ulp_clk_wiz_0, not ap_clk_2 -- so the clocks must be discovered by
# following the kernel's clock pins rather than looked up by name.
#
# Wired in via: --config with run.impl_1.STEPS.OPT_DESIGN.TCL.PRE

puts "=== t2t CDC hook: locating the kernel's two clock domains ==="

# Find the clocks by the pins they actually drive inside the kernel instance,
# which is robust to whatever the platform decides to call the nets.
set ap_pins  [get_pins -quiet -hier -filter {NAME =~ *t2t_kernel_1*/ap_clk}]
set ap2_pins [get_pins -quiet -hier -filter {NAME =~ *t2t_kernel_1*/ap_clk_2}]

set c_ap  [get_clocks -quiet -of_objects $ap_pins]
set c_ap2 [get_clocks -quiet -of_objects $ap2_pins]

# Fall back to the known generated names if the pin lookup comes up empty (for
# example if the hierarchy is flattened before this hook runs).
if {[llength $c_ap] == 0} {
  set c_ap [get_clocks -quiet clk_kernel_00_unbuffered_net]
}
if {[llength $c_ap2] == 0} {
  set c_ap2 [get_clocks -quiet clk_out1_ulp_clk_wiz_0]
}

puts "=== t2t CDC hook: ap_clk  -> $c_ap"
puts "=== t2t CDC hook: ap_clk_2 -> $c_ap2"

if {[llength $c_ap] && [llength $c_ap2] && ![string equal $c_ap $c_ap2]} {
  # The whole design is built around these two domains being asynchronous:
  # cdc_fifo crosses them with Gray pointers, cfg_cdc with a synchronised enable.
  set_clock_groups -name t2t_kernel_async_impl -asynchronous \
    -group $c_ap -group $c_ap2
  puts "=== t2t CDC hook: asynchronous clock groups APPLIED ==="

  # Bound the one multi-bit crossing that needs coherency rather than merely
  # being cut: cfg_cdc's config snapshot must land well before the enable that
  # tells the core to sample it. Single-bit synchronisers need nothing beyond
  # the groups above plus their ASYNC_REG attribute.
  set core_p [get_property PERIOD $c_ap2]
  set cfg_src [get_cells -quiet -hier -filter {NAME =~ *u_cfg_cdc/snap_reg[*]}]
  set cfg_dst [get_cells -quiet -hier -filter {NAME =~ *u_cfg_cdc/dst_data_reg[*]}]
  if {[llength $cfg_src] && [llength $cfg_dst]} {
    set_max_delay -datapath_only -from $cfg_src -to $cfg_dst $core_p
    set_bus_skew                 -from $cfg_src -to $cfg_dst $core_p
    puts "=== t2t CDC hook: cfg_cdc datapath bounded to $core_p ns ==="
  } else {
    puts "WARNING: t2t CDC hook found no cfg_cdc snapshot registers"
  }
} else {
  puts "ERROR: t2t CDC hook could not identify two distinct kernel clocks -- \
crossings will be timed as synchronous and hold will fail on all of them"
}
