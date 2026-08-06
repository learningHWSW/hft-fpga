# Where does the datapath actually sit, and does it straddle an SLR boundary?
#
# The routed utilisation report answers this for the whole device but cannot
# attribute a crossing to the kernel: the platform's own SLR1<->SLR0 traffic (HBM,
# PCIe) dominates the counts. This opens the routed checkpoint and asks the
# question per module.
#
# Read-only. Produces a report; changes nothing.
open_checkpoint _x_a/link/vivado/vpl/prj/prj.runs/impl_1/level0_wrapper_routed.dcp

set K level0_i/ulp/t2t_kernel_1/inst

puts "\n=== SLR occupancy, per datapath module ==="
puts [format "%-34s %8s %8s %8s %8s" module SLR0 SLR1 SLR2 total]
foreach {name path} [list \
    kernel        "$K" \
    ladder        "$K/u_t2t/u_t2t/u_fh/u_ladder" \
    order_table   "$K/u_t2t/u_t2t/u_fh/u_otab" \
    splitter      "$K/u_t2t/u_t2t/u_fh/u_split" \
    decoder       "$K/u_t2t/u_t2t/u_fh/u_dec" \
    strategy      "$K/u_t2t/u_t2t/u_strat" \
    capture       "$K/u_capture" \
    replay        "$K/u_replay" \
  ] {
  set cells [get_cells -quiet -hier -filter "NAME =~ $path/*"]
  if {[llength $cells] == 0} { continue }
  array set n {0 0 1 0 2 0}
  foreach c $cells {
    set s [get_sites -quiet -of_objects $c]
    if {$s eq ""} { continue }
    set slr [get_slrs -quiet -of_objects $s]
    if {$slr eq ""} { continue }
    regexp {SLR(\d)} $slr -> i
    incr n($i)
  }
  set tot [expr {$n(0)+$n(1)+$n(2)}]
  puts [format "%-34s %8d %8d %8d %8d" $name $n(0) $n(1) $n(2) $tot]
  array unset n
}

puts "\n=== worst setup paths in the core clock domain ==="
set paths [get_timing_paths -max_paths 8 -sort_by slack \
             -filter {GROUP =~ *clk_out1_ulp_clk_wiz_0*}]
foreach p $paths {
  set src [get_property STARTPOINT_PIN $p]
  set dst [get_property ENDPOINT_PIN $p]
  set slk [get_property SLACK $p]
  set lvl [get_property LOGIC_LEVELS $p]
  puts [format "  %7.3f ns  levels=%-3s  %s" $slk $lvl $dst]
  puts [format "                        from %s" $src]
}

puts "\n=== does any core-clock path cross an SLR? ==="
set crossing 0
foreach p $paths {
  set a [get_slrs -quiet -of_objects [get_sites -quiet -of_objects [get_cells -quiet -of_objects [get_property STARTPOINT_PIN $p]]]]
  set b [get_slrs -quiet -of_objects [get_sites -quiet -of_objects [get_cells -quiet -of_objects [get_property ENDPOINT_PIN $p]]]]
  if {$a ne "" && $b ne "" && $a ne $b} {
    incr crossing
    puts "  CROSSES: $a -> $b  slack [get_property SLACK $p]"
  }
}
if {$crossing == 0} { puts "  none of the 8 worst core-clock paths cross an SLR boundary" }

puts "\n=== routing vs logic on the worst path ==="
set p [lindex $paths 0]
puts "  slack        [get_property SLACK $p] ns"
puts "  logic delay  [get_property DATAPATH_LOGIC_DELAY $p] ns"
puts "  route delay  [get_property DATAPATH_NET_DELAY $p] ns"
puts "  levels       [get_property LOGIC_LEVELS $p]"

close_project
