# Out-of-context synthesis / implementation of the t2t_axil wrapper -- the whole
# tick-to-trade datapath behind its AXI-Lite control plane. This is the module
# an OpenNIC user box instantiates.
#
# Differs from synth_t2t.tcl by one domain: t2t_axil adds axil_clk (the QDMA
# side) on top of cmac_clk and core_clk, so THREE clocks are created and all
# three declared asynchronous. The crossing exceptions live in t2t_axil_cdc.xdc.
#
#   vivado -mode batch -source syn/synth_axil.tcl \
#          -tclargs <part> <synth|impl> <ot_sets_bits> <ot_ways> <core_ns> <axil_ns>
#
# Reports land in syn/out_axil/.
set part   [lindex $argv 0]
set mode   [lindex $argv 1]
if {$part eq ""} { set part xcu55c-fsvh2892-2L-e }
if {$mode eq ""} { set mode synth }

set here   [file dirname [file normalize [info script]]]
set root   [file dirname $here]
set repo   [file dirname $root]
# Tracked symbols. Worth a knob here and not only in synth_t2t.tcl: this is the
# wrapper where NSYM widens two hand-packed buses (CFGW and STW), and an
# off-by-one in either is a width error synthesis catches and no simulation at
# NSYM=1 ever would.
set nsym [expr {[lindex $argv 6] ne "" ? [lindex $argv 6] : 1}]
set outdir $here/out_axil[expr {$nsym > 1 ? "-n$nsym" : ""}]
file mkdir $outdir

set srcs [list \
  $repo/step2-rtl-decoder/rtl/itch5_pkg.sv \
  $repo/step2-rtl-decoder/rtl/itch_decoder.sv \
  $repo/step3b-splitter/rtl/mold_splitter.sv \
  $repo/step4a-order-table/rtl/otable_mem.sv $repo/step4a-order-table/rtl/order_table.sv \
  $repo/step4a-order-table/rtl/order_table_pipe.sv \
  $repo/step4b-book/rtl/price_ladder.sv $repo/step4b-book/rtl/fast_bbo.sv \
  $repo/step4b-book/rtl/bbo_merge.sv \
  $repo/step4b-book/rtl/bbo_arb.sv \
  $root/rtl/drop_fifo.sv \
  $root/rtl/fh_core.sv \
  $root/rtl/eth_ip_udp_rx.sv \
  $root/rtl/cdc_fifo.sv \
  $repo/step6-strategy/rtl/strategy.sv $repo/step6-strategy/rtl/sweep_detect.sv \
  $repo/step6-strategy/rtl/ouch_builder.sv \
  $repo/step6-strategy/rtl/tcp_tx.sv $repo/step6-strategy/rtl/tx_replay_buf.sv $repo/step6-strategy/rtl/tx_rto.sv $repo/step6-strategy/rtl/ack_latency.sv \
  $root/rtl/feed_ab_arb.sv $root/rtl/igmp_query_detect.sv $root/rtl/tcp_rx.sv $root/rtl/t2t_top.sv \
  $root/rtl/axil_regfile.sv $root/rtl/cfg_cdc.sv $root/rtl/axis_tx_arb.sv \
  $root/rtl/igmp_join.sv $root/rtl/arp_responder.sv $root/rtl/t2t_axil.sv ]

create_project -in_memory -part $part
foreach f $srcs { read_verilog -sv $f }
set defs {}
if {[info exists ::env(OT_PIPE)]} { lappend defs OT_PIPE }
if {[llength $defs]} { set_property verilog_define $defs [current_fileset] }

# clocks: cmac fixed by the MAC, core is the datapath under test, axil is QDMA
set core_ns [expr {[lindex $argv 4] ne "" ? [lindex $argv 4] : 4.618}]
set axil_ns [expr {[lindex $argv 5] ne "" ? [lindex $argv 5] : 4.000}]
set gen_xdc $outdir/clocks.xdc
set fh [open $gen_xdc w]
puts $fh "create_clock -name cmac_clk -period 3.103 \[get_ports cmac_clk\]"
puts $fh "create_clock -name core_clk -period $core_ns \[get_ports core_clk\]"
puts $fh "create_clock -name axil_clk -period $axil_ns \[get_ports axil_clk\]"
close $fh
read_xdc $gen_xdc                       ;# clocks only (ports exist pre-synth)

set ot_sets_bits [expr {[lindex $argv 2] ne "" ? [lindex $argv 2] : 13}]
set ot_ways      [expr {[lindex $argv 3] ne "" ? [lindex $argv 3] : 16}]

puts "=== synth_design t2t_axil: core=${core_ns}ns axil=${axil_ns}ns cmac=3.103ns nsym=$nsym ==="
synth_design -top t2t_axil -part $part -mode out_of_context \
  -generic OT_SETS_BITS=$ot_sets_bits -generic OT_WAYS=$ot_ways \
  -generic NSYM=$nsym

# CDC exceptions reference the synthesised netlist, so apply them now
read_xdc $here/t2t_axil_cdc.xdc         ;# async groups + max_delay/bus_skew

report_utilization -file $outdir/util_synth.rpt
report_timing_summary -delay_type max -max_paths 10 -file $outdir/timing_synth.rpt
# confirm the exceptions took: every domain pair should read "Asynchronous Groups"
report_clock_interaction -file $outdir/clock_interaction.rpt
write_checkpoint -force $outdir/post_synth.dcp

proc summarize {tag ns} {
  foreach ck {cmac_clk core_clk axil_clk} {
    set p [get_timing_paths -max_paths 1 -delay_type max -to [get_clocks $ck]]
    if {[llength $p]} { puts "SUMMARY_${tag}_WNS_$ck: [get_property SLACK $p]" }
  }
  set w [get_property SLACK [get_timing_paths -max_paths 1 -delay_type max]]
  puts "SUMMARY_${tag}_WNS: $w"
}
summarize SYNTH $core_ns
foreach t {LUT FDRE RAMB36E2 URAM288 DSP48E2} {
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
  summarize IMPL $core_ns
}
puts "=== DONE mode=$mode ==="
