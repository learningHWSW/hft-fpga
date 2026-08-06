# Follow-up to slr_analysis.tcl: which cells own the worst core-clock paths, and
# is the delay in logic or in routing? Read-only.
open_checkpoint _x_a/link/vivado/vpl/prj/prj.runs/impl_1/level0_wrapper_routed.dcp

set core [get_clocks -quiet clk_out1_ulp_clk_wiz_0]
puts "\n=== core clock ==="
puts "  name   : [get_property NAME $core]"
puts "  period : [get_property PERIOD $core] ns"

set paths [get_timing_paths -quiet -from $core -to $core -max_paths 10 -sort_by slack]
puts "\n=== 10 worst core-clock setup paths ==="
puts [format "  %-8s %-7s %-9s %-9s %s" slack levels logic route endpoint]
foreach p $paths {
  set slk [get_property SLACK $p]
  set lvl [get_property LOGIC_LEVELS $p]
  set lg  [get_property DATAPATH_LOGIC_DELAY $p]
  set rt  [get_property DATAPATH_NET_DELAY $p]
  set dst [get_property NAME [get_property ENDPOINT_PIN $p]]
  # strip the long platform prefix so the module is readable
  regsub {^level0_i/ulp/t2t_kernel_1/inst/} $dst {} dst
  puts [format "  %-8s %-7s %-9s %-9s %s" $slk $lvl $lg $rt $dst]
}

# Which module do the worst endpoints belong to?
puts "\n=== worst-path endpoints, grouped by module ==="
array set owner {}
foreach p [get_timing_paths -quiet -from $core -to $core -max_paths 200 -sort_by slack] {
  set dst [get_property NAME [get_property ENDPOINT_PIN $p]]
  if {![regsub {^level0_i/ulp/t2t_kernel_1/inst/} $dst {} dst]} { continue }
  set mod [join [lrange [split $dst /] 0 3] /]
  if {[info exists owner($mod)]} { incr owner($mod) } else { set owner($mod) 1 }
}
foreach m [lsort -command {apply {{a b} {expr {$::owner($b) - $::owner($a)}}}} [array names owner]] {
  puts [format "  %5d  %s" $owner($m) $m]
}

close_project
