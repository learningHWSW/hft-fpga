# Out-of-context synthesis / implementation of the FULL tick-to-trade chain
# (t2t_top) for the real U55C device — wire in, order frame out.
#
# Differs from synth_ooc.tcl in one structural way: this design has TWO clocks.
# The CMAC datapath runs at 322.265625 MHz and the core at its own, slower rate
# joined by cdc_fifo, so both must be declared and then declared asynchronous
# to each other. Without the clock group, Vivado times the Gray-code pointer
# crossings as if they were synchronous and reports enormous, meaningless
# violations.
#
#   vivado -mode batch -source syn/synth_t2t.tcl \
#          -tclargs <part> <synth|impl> <ot_sets_bits> <ot_ways> <core_period>
#
# Reports land in syn/out_t2t/.
set part   [lindex $argv 0]
set mode   [lindex $argv 1]
if {$part eq ""} { set part xcu55c-fsvh2892-2L-e }
if {$mode eq ""} { set mode synth }

set here   [file dirname [file normalize [info script]]]
set root   [file dirname $here]
set repo   [file dirname $root]
set outdir $here/out_t2t
file mkdir $outdir

set srcs [list \
  $repo/step2-rtl-decoder/rtl/itch5_pkg.sv \
  $repo/step2-rtl-decoder/rtl/itch_decoder.sv \
  $repo/step3b-splitter/rtl/mold_splitter.sv \
  $repo/step4a-order-table/rtl/otable_mem.sv $repo/step4a-order-table/rtl/order_table.sv \
  $repo/step4b-book/rtl/price_ladder.sv \
  $root/rtl/drop_fifo.sv \
  $root/rtl/fh_core.sv \
  $root/rtl/eth_ip_udp_rx.sv \
  $root/rtl/cdc_fifo.sv \
  $repo/step6-strategy/rtl/strategy.sv $repo/step6-strategy/rtl/sweep_detect.sv \
  $repo/step6-strategy/rtl/ouch_builder.sv \
  $repo/step6-strategy/rtl/tcp_tx.sv \
  $root/rtl/t2t_top.sv ]

create_project -in_memory -part $part
foreach f $srcs { read_verilog -sv $f }
set_property verilog_define OTABLE_XPM [current_fileset]

# Constraints must be read BEFORE synth_design: create_clock needs an open
# design, so they live in an XDC rather than being called here.
#   cmac_clk 3.103 ns = 322.265625 MHz, fixed by the 100G MAC
#   core_clk is the variable under test; 4.618 ns = 216.5 MHz is what the
#   feed path measured post-route, and 5.120 ns = 195.3 MHz is the floor that
#   100 Gb/s actually demands.
set period [expr {[lindex $argv 4] ne "" ? [lindex $argv 4] : 4.618}]
set gen_xdc $outdir/clocks.xdc
set fh [open $gen_xdc w]
puts $fh "create_clock -name cmac_clk -period 3.103 \[get_ports cmac_clk\]"
puts $fh "create_clock -name core_clk -period $period \[get_ports core_clk\]"
puts $fh "set_clock_groups -asynchronous \\"
puts $fh "  -group \[get_clocks cmac_clk\] -group \[get_clocks core_clk\]"
close $fh
read_xdc $gen_xdc

# The order table is an instantiated XPM/URAM macro now, so synthesis builds
# the same 2^16 x 8 the simulations verify. OTABLE_XPM selects the real macro
# over the behavioural model Verilator uses.
set ot_sets_bits [expr {[lindex $argv 2] ne "" ? [lindex $argv 2] : 13}]
set ot_ways      [expr {[lindex $argv 3] ne "" ? [lindex $argv 3] : 16}]

puts "=== synth_design: part=$part core=${period}ns cmac=3.103ns OT=2^${ot_sets_bits}x${ot_ways} ==="
synth_design -top t2t_top -part $part -mode out_of_context \
  -generic OT_SETS_BITS=$ot_sets_bits -generic OT_WAYS=$ot_ways

file mkdir $outdir
report_utilization -hierarchical -file $outdir/util_synth.rpt
report_utilization              -file $outdir/util_synth_flat.rpt
report_timing_summary -delay_type max -max_paths 10 -file $outdir/timing_synth.rpt
write_checkpoint -force $outdir/post_synth.dcp

proc summarize {tag period} {
  # report per clock: the worst path overall can belong to either domain
  foreach ck {cmac_clk core_clk} {
    set p [get_timing_paths -max_paths 1 -delay_type max -to [get_clocks $ck]]
    if {[llength $p]} {
      set s [get_property SLACK $p]
      puts "SUMMARY_${tag}_WNS_$ck: $s"
    }
  }
  set w [get_property SLACK [get_timing_paths -max_paths 1 -delay_type max]]
  puts "SUMMARY_${tag}_WNS: $w"
  puts "SUMMARY_${tag}_CORE_FMAX_MHZ: [format %.1f [expr {1000.0/($period - $w)}]]"
}
summarize SYNTH $period
foreach t {LUT FDRE RAMB36E2 RAMB18E2 URAM288 DSP48E2} {
  puts "SUMMARY_CELL_$t: [llength [get_cells -hier -quiet -filter "REF_NAME =~ $t*"]]"
}

if {$mode eq "impl"} {
  puts "=== opt/place/route ==="
  opt_design
  place_design
  phys_opt_design
  route_design
  report_utilization -hierarchical -file $outdir/util_impl_hier.rpt
  report_utilization              -file $outdir/util_impl.rpt
  report_timing_summary -delay_type max -max_paths 10 -file $outdir/timing_impl.rpt
  write_checkpoint -force $outdir/post_route.dcp
  summarize IMPL $period
}
puts "=== DONE mode=$mode ==="
