# Elaborate t2t_kernel out of context -- a fast syntax/connectivity check before
# committing to a v++ build, which takes hours and reports RTL errors late.
#
#   vivado -mode batch -source syn/elab_kernel.tcl [-tclargs synth]
# With "synth" it runs a full out-of-context synthesis instead, for utilisation
# and a first look at the harness's timing cost on top of the datapath.
set mode [lindex $argv 0]
if {$mode eq ""} { set mode elab }

set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
set repo [file dirname $root]
set part xcu55c-fsvh2892-2L-e

set srcs [list \
  $repo/step2-rtl-decoder/rtl/itch5_pkg.sv \
  $repo/step2-rtl-decoder/rtl/itch_decoder.sv \
  $repo/step3b-splitter/rtl/mold_splitter.sv \
  $repo/step4a-order-table/rtl/otable_mem.sv \
  $repo/step4a-order-table/rtl/order_table.sv \
  $repo/step4a-order-table/rtl/order_table_pipe.sv \
  $repo/step4b-book/rtl/price_ladder.sv $repo/step4b-book/rtl/fast_bbo.sv \
  $repo/step4b-book/rtl/bbo_merge.sv \
  $repo/step5-board/rtl/drop_fifo.sv \
  $repo/step5-board/rtl/fh_core.sv \
  $repo/step5-board/rtl/eth_ip_udp_rx.sv \
  $repo/step5-board/rtl/cdc_fifo.sv \
  $repo/step6-strategy/rtl/strategy.sv \
  $repo/step6-strategy/rtl/sweep_detect.sv \
  $repo/step6-strategy/rtl/ouch_builder.sv \
  $repo/step6-strategy/rtl/tcp_tx.sv $repo/step6-strategy/rtl/tx_replay_buf.sv \
  $repo/step5-board/rtl/feed_ab_arb.sv \
  $repo/step5-board/rtl/igmp_query_detect.sv \
  $repo/step5-board/rtl/tcp_rx.sv $repo/step5-board/rtl/t2t_top.sv \
  $repo/step5-board/rtl/axil_regfile.sv \
  $repo/step5-board/rtl/cfg_cdc.sv \
  $repo/step5-board/rtl/axis_tx_arb.sv \
  $repo/step5-board/rtl/igmp_join.sv \
  $repo/step5-board/rtl/arp_responder.sv \
  $repo/step5-board/rtl/t2t_axil.sv \
  $root/rtl/eth_replay.sv \
  $root/rtl/eth_capture.sv \
  $root/rtl/lat_probe.sv \
  $root/rtl/lat_loaded.sv \
  $root/rtl/t2t_kernel.sv ]

create_project -in_memory -part $part
foreach f $srcs { read_verilog -sv $f }
set_property verilog_define {OTABLE_XPM} [current_fileset]

if {$mode eq "synth"} {
  set outdir $here/out_kernel
  file mkdir $outdir
  # ap_clk stands in for the CMAC domain (300 MHz from the platform), ap_clk_2 is
  # the datapath core. Declared asynchronous: the cdc_fifo crossings are real.
  set fh [open $outdir/clocks.xdc w]
  puts $fh "create_clock -name ap_clk   -period 3.333 \[get_ports ap_clk\]"
  puts $fh "create_clock -name ap_clk_2 -period 4.651 \[get_ports ap_clk_2\]"
  close $fh
  read_xdc $outdir/clocks.xdc                ;# clocks only: ports exist pre-synth
  synth_design -top t2t_kernel -part $part -mode out_of_context

  # The CDC exceptions are the SAME file the kernel package ships, so this run
  # also checks that its clock lookups resolve and its cell filters actually
  # match something. Read after synth_design: the cell-based exceptions need a
  # netlist (get_cells finds nothing on an elaborated-only design).
  read_xdc $here/t2t_kernel_cdc.xdc
  # every domain pair must read "Asynchronous Groups" here, or the crossings are
  # being timed as real paths -- which is exactly what sank the first build
  report_clock_interaction -file $outdir/clock_interaction.rpt
  report_utilization -file $outdir/util_synth.rpt
  report_timing_summary -delay_type max -max_paths 10 -file $outdir/timing_synth.rpt
  foreach ck {ap_clk ap_clk_2} {
    set p [get_timing_paths -max_paths 1 -delay_type max -to [get_clocks $ck]]
    if {[llength $p]} { puts "SUMMARY_WNS_$ck: [get_property SLACK $p]" }
  }
  write_checkpoint -force $outdir/post_synth.dcp
  puts "=== SYNTH OK ==="
} else {
  synth_design -top t2t_kernel -part $part -mode out_of_context -rtl -rtl_skip_ip
  puts "=== ELAB OK under [version -short] ==="
}
