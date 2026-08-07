# Is a ladder pblock even expressible here? Read-only probe.
#
# A Vitis kernel lives inside the platform's reconfigurable-partition pblock, so
# any pblock of ours has to be a sub-region of that one. This asks what that
# region actually is, and where the ladder's cells ended up inside it, so a
# floorplan can be derived from measurement rather than guessed.
open_checkpoint _x_a/link/vivado/vpl/prj/prj.runs/impl_1/level0_wrapper_routed.dcp

puts "\n=== existing pblocks ==="
foreach pb [get_pblocks -quiet] {
  puts [format "  %-28s ranges: %s" $pb [get_property GRID_RANGES $pb]]
}

set K level0_i/ulp/t2t_kernel_1/inst
set lad "$K/u_t2t/u_t2t/u_fh/u_ladder"

puts "\n=== where the ladder actually sits ==="
set cells [get_cells -quiet -hier -filter "NAME =~ $lad/*"]
puts "  ladder cells: [llength $cells]"
set xs {}; set ys {}
foreach c $cells {
  set s [get_sites -quiet -of_objects $c]
  if {$s eq ""} continue
  set n [get_property NAME $s]
  if {[regexp {SLICE_X(\d+)Y(\d+)} $n -> x y]} { lappend xs $x; lappend ys $y }
}
if {[llength $xs]} {
  set xs [lsort -integer $xs]; set ys [lsort -integer $ys]
  puts "  occupied X: [lindex $xs 0] .. [lindex $xs end]"
  puts "  occupied Y: [lindex $ys 0] .. [lindex $ys end]"
  puts "  placed slices: [llength $xs]"
}

puts "\n=== the worst ladder path, and how far it reaches ==="
set core [get_clocks -quiet clk_out1_ulp_clk_wiz_0]
foreach p [get_timing_paths -quiet -from $core -to $core -max_paths 3 -sort_by slack] {
  set d [get_property NAME [get_property ENDPOINT_PIN $p]]
  if {![string match "*u_ladder*" $d]} continue
  set sc [get_cells -quiet -of_objects [get_property STARTPOINT_PIN $p]]
  set dc [get_cells -quiet -of_objects [get_property ENDPOINT_PIN $p]]
  puts "  slack [get_property SLACK $p]  route [get_property DATAPATH_NET_DELAY $p] ns"
  puts "    from site [get_property NAME [get_sites -quiet -of_objects $sc]]"
  puts "    to   site [get_property NAME [get_sites -quiet -of_objects $dc]]"
}
close_project
