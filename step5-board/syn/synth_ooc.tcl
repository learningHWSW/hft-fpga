# Out-of-context synthesis / implementation of fh_core for the real U55C device.
#
# No Alveo platform or card is needed for this: it targets the raw part
# (xcu55c-fsvh2892-2L-e) and answers the two questions the simulation cannot —
# does the design fit the VU35P, and does it close timing at the 100G CMAC
# datapath clock (322.265625 MHz, 3.103 ns)?
#
#   vivado -mode batch -source syn/synth_ooc.tcl -tclargs <part> <synth|impl>
#
# Reports land in syn/out/.
set part [lindex $argv 0]
set mode [lindex $argv 1]
if {$part eq ""} { set part xcu55c-fsvh2892-2L-e }
if {$mode eq ""} { set mode synth }

set here    [file dirname [file normalize [info script]]]
set root    [file dirname $here]
set repo    [file dirname $root]
set outdir  $here/out
file mkdir $outdir

set srcs [list \
  $repo/step2-rtl-decoder/rtl/itch5_pkg.sv \
  $repo/step2-rtl-decoder/rtl/itch_decoder.sv \
  $repo/step3b-splitter/rtl/mold_splitter.sv \
  $repo/step4a-order-table/rtl/order_table.sv \
  $repo/step4b-book/rtl/price_ladder.sv \
  $root/rtl/drop_fifo.sv \
  $root/rtl/fh_core.sv ]

create_project -in_memory -part $part
foreach f $srcs { read_verilog -sv $f }

# Constraints must be read in BEFORE synth_design — create_clock needs an
# open design, so it lives in the XDC rather than being called here.
set period 3.103
read_xdc $here/fh_core.xdc

# Order-table size for THIS synthesis run. The production point (2^16 sets x
# 8 ways = 80 Mbit) cannot be inferred from a behavioral array: Vivado caps a
# single variable at 1 Mbit ([Synth 8-4556]). Production must instantiate XPM /
# URAM macros. To still measure the surrounding logic (barrel shifters,
# priority encoders, FSMs), synthesize with a table small enough to infer.
set ot_sets_bits [expr {[lindex $argv 2] ne "" ? [lindex $argv 2] : 9}]
set ot_ways      [expr {[lindex $argv 3] ne "" ? [lindex $argv 3] : 8}]

puts "=== synth_design: part=$part period=${period}ns OT=2^${ot_sets_bits}x${ot_ways} ==="
synth_design -top fh_core -part $part -mode out_of_context \
  -generic OT_SETS_BITS=$ot_sets_bits -generic OT_WAYS=$ot_ways

file mkdir $outdir   ;# re-create: a `make clean` may have removed it mid-run
report_utilization -hierarchical -file $outdir/util_synth.rpt
report_utilization              -file $outdir/util_synth_flat.rpt
report_timing_summary -delay_type max -max_paths 10 -file $outdir/timing_synth.rpt
write_checkpoint -force $outdir/post_synth.dcp

# concise console summary
set wns [get_property SLACK [get_timing_paths -max_paths 1 -delay_type max]]
puts "SUMMARY_SYNTH_WNS: $wns"
puts "SUMMARY_SYNTH_FMAX_MHZ: [format %.1f [expr {1000.0/($period - $wns)}]]"
foreach t {LUT FDRE RAMB36E2 RAMB18E2 URAM288 DSP48E2} {
  puts "SUMMARY_CELL_$t: [llength [get_cells -hier -quiet -filter "REF_NAME =~ $t*"]]"
}

if {$mode eq "impl"} {
  puts "=== opt/place/route ==="
  opt_design
  place_design
  phys_opt_design
  route_design
  report_utilization -file $outdir/util_impl.rpt
  report_timing_summary -delay_type max -max_paths 10 -file $outdir/timing_impl.rpt
  write_checkpoint -force $outdir/post_route.dcp
  set wns2 [get_property SLACK [get_timing_paths -max_paths 1 -delay_type max]]
  puts "SUMMARY_IMPL_WNS: $wns2"
  puts "SUMMARY_IMPL_FMAX_MHZ: [format %.1f [expr {1000.0/($period - $wns2)}]]"
}
puts "=== DONE mode=$mode ==="
