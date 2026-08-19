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
#          -tclargs <part> <synth|impl> <ot_sets_bits> <ot_ways> <core_period> \
#                   <use_fast_bbo> <directive_set> <nsym>
#
# THE LAST TWO ARGUMENTS EXIST TO MAKE THIS BUILD COMPARABLE WITH ITSELF.
# Asking "what did feature X cost in fMAX?" needs two builds that differ only in
# X, and asking "is that cost real or is it placement noise?" needs several of
# each. Two things used to be in the way, and both have now bitten:
#
#   * USE_FAST_BBO was read from the RTL default, so switching it meant editing
#     t2t_top.sv -- and a build left running with the file in the other state
#     silently produced the wrong answer;
#   * every run wrote to syn/out_t2t/, so two runs in parallel overwrote each
#     other's reports and the survivor looked authoritative.
#
# So the parameter is a -generic, and the output directory is NAMED AFTER THE
# BUILD (step8's replay images learned the same lesson): syn/out_t2t-f1-explore/
# can only ever hold a fast build run with the explore directives. A run that
# differs in any knob cannot land on top of one that differs in another.
set part   [lindex $argv 0]
set mode   [lindex $argv 1]
if {$part eq ""} { set part xcu55c-fsvh2892-2L-e }
if {$mode eq ""} { set mode synth }

# USE_FAST_BBO: 1 keeps fast_bbo + bbo_merge, 0 leaves price_ladder alone. The
# BBO sequence is identical either way (step4b/tb_bbo_merge.sv); this is purely
# the latency-vs-timing knob.
set fast [expr {[lindex $argv 5] ne "" ? [lindex $argv 5] : 1}]

# Implementation directive sets. place/phys_opt/route are chosen together
# because they interact -- an aggressive placer with the default router is not a
# point anyone would ship. Vivado exposes no placement seed, so varying
# directives is the only way to sample the tool's run-to-run spread, and without
# that spread a single-build fMAX delta cannot be told apart from noise.
array set dirsets {
  default {Default            Default                  Default}
  explore {Explore            Explore                  Explore}
  netdly  {ExtraNetDelay_high AggressiveExplore        NoTimingRelaxation}
  fanout  {AltSpreadLogic_medium AggressiveFanoutOpt   AggressiveExplore}
}
# Tracked symbols. One order table holds all of them and everything downstream
# is replicated, so this is the knob that says what a second name costs. It does
# NOT raise OT_SETS_BITS with it -- that is deliberate, because the two move
# together for capacity reasons the tool cannot see (FINDINGS §4.4: two symbols
# need 2^14 sets), and a build that silently resized the table would hide the
# fact that the area answer has two halves.
set nsym [expr {[lindex $argv 7] ne "" ? [lindex $argv 7] : 1}]

# CUT_THROUGH: decode the splitter's beat combinationally instead of the cycle
# after it (itch_decoder.sv). Simulation already says the message stream is
# identical and arrives a core cycle sooner; the only open question is what the
# combinational type dispatch costs THIS clock, which is what a sweep at both
# settings answers. A -generic for exactly the reason USE_FAST_BBO is one.
set ct [expr {[lindex $argv 8] ne "" ? [lindex $argv 8] : 1}]

# FLAT_SCAN: price_ladder's group-select structure. The ladder is 51 % of the
# kernel's LUTs and owns the core-clock critical path, so this is swept for an
# AREA delta as much as an fMAX one.
set fs [expr {[lindex $argv 9] ne "" ? [lindex $argv 9] : 0}]
set dset [expr {[lindex $argv 6] ne "" ? [lindex $argv 6] : "default"}]
if {![info exists dirsets($dset)]} {
  error "unknown directive set '$dset'; have: [lsort [array names dirsets]]"
}
lassign $dirsets($dset) d_place d_phys d_route

set here   [file dirname [file normalize [info script]]]
set root   [file dirname $here]
set repo   [file dirname $root]

# The order table geometry. Read HERE rather than beside its use below, because
# it is part of the build's identity and so has to be in the directory name:
# NSYM=2 at 2^13 and NSYM=2 at 2^14 are different builds that answer different
# questions, and until this was in the name they wrote to the same directory.
# That is not hypothetical -- the 2^14 sweep behind FINDINGS 4.4 was one command
# away from being overwritten by its own re-run.
set ot_sets_bits [expr {[lindex $argv 2] ne "" ? [lindex $argv 2] : 13}]
set ot_ways      [expr {[lindex $argv 3] ne "" ? [lindex $argv 3] : 16}]

set outdir $here/out_t2t-f$fast-$dset[expr {$nsym > 1 ? "-n$nsym" : ""}][expr {$ot_sets_bits != 13 ? "-s$ot_sets_bits" : ""}][expr {$ct ? "-ct" : ""}][expr {$fs ? "-fs" : ""}]
file mkdir $outdir

set srcs [list \
  $repo/step2-rtl-decoder/rtl/itch5_pkg.sv \
  $repo/step2-rtl-decoder/rtl/itch_decoder.sv \
  $repo/step3b-splitter/rtl/mold_splitter.sv \
  $repo/step4a-order-table/rtl/otable_mem.sv $repo/step4a-order-table/rtl/order_table.sv $repo/step4a-order-table/rtl/order_table_pipe.sv \
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
  $root/rtl/feed_ab_arb.sv $root/rtl/igmp_query_detect.sv $root/rtl/tcp_rx.sv $root/rtl/t2t_top.sv ]

create_project -in_memory -part $part
# Capped so four of these can run at once on a 32-core box without thrashing.
# Thread count does not change the result -- Vivado's placer and router are
# deterministic for a given directive regardless of how many threads run them --
# so a sweep run in parallel is comparable with one run serially.
set_param general.maxThreads 8
foreach f $srcs { read_verilog -sv $f }
set defs {}
if {[info exists ::env(OT_PIPE)]} { lappend defs OT_PIPE }
if {[llength $defs]} { set_property verilog_define $defs [current_fileset] }

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

# The order table is an instantiated XPM/URAM macro, so synthesis builds the
# same 2^16 x 8 the simulations verify -- and since otable_mem no longer
# selects between two descriptions (FINDINGS 4.5), that is now true of the card
# build as well, which it was not when this comment first claimed it.
# (ot_sets_bits and ot_ways are read near the top, with the output directory
# name that depends on them.)

puts "=== synth_design: part=$part core=${period}ns cmac=3.103ns OT=2^${ot_sets_bits}x${ot_ways} fast_bbo=$fast nsym=$nsym cut_through=$ct flat_scan=$fs ==="
synth_design -top t2t_top -part $part -mode out_of_context \
  -generic OT_SETS_BITS=$ot_sets_bits -generic OT_WAYS=$ot_ways \
  -generic USE_FAST_BBO=$fast -generic NSYM=$nsym -generic CUT_THROUGH=$ct \
  -generic FLAT_SCAN=$fs

# Cheap insurance against the generic silently not applying: with USE_FAST_BBO=0
# the generate block leaves no fast_bbo cells at all, and with 1 it must leave
# some. A -generic that misses (wrong name, wrong top) fails this line rather
# than producing a plausible-looking build of the wrong thing.
set nfast [llength [get_cells -hier -quiet \
             -filter {REF_NAME =~ "fast_bbo*" || NAME =~ "*u_fast*"}]]
if {($fast && $nfast == 0) || (!$fast && $nfast != 0)} {
  error "USE_FAST_BBO=$fast did not take: $nfast fast_bbo cells in the netlist"
}
# Same insurance for NSYM: one price_ladder per tracked symbol, so a generic
# that missed would build a single-symbol design and report its area as the
# multi-symbol answer.
set nlad [llength [get_cells -hier -quiet -filter {REF_NAME =~ "price_ladder*"}]]
if {$nlad != $nsym} {
  error "NSYM=$nsym did not take: $nlad price_ladder instances in the netlist"
}
# CUT_THROUGH gets NO equivalent check, deliberately, rather than a guessed one.
# The other two knobs add or remove whole instances, which is a signature that
# cannot be mistaken. This one moves a register barrier: at DATA_W=512 the byte
# collector goes dead and synthesis removes ~512 flops, which IS a signature but
# a flop count is not a stable thing to assert against across tool versions, and
# a guard that fails a good build is worse than no guard. The simulation side
# does have one -- step 3b's testbench asserts the decode latency, so a generic
# that misses there fails rather than passing a golden diff.
puts "=== CUT_THROUGH=$ct (no netlist assertion; see the comment above) ==="

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
      # fMAX must be computed from the path's OWN clock period. cmac_clk is
      # 3.103 ns whatever core_clk is set to, and dividing its slack by the core
      # period would report a number for a clock that does not exist.
      set ckp [get_property PERIOD [get_clocks $ck]]
      puts "SUMMARY_${tag}_FMAX_MHZ_$ck: [format %.1f [expr {1000.0/($ckp - $s)}]]"
      # Where the worst path in this domain actually is. A one-line answer to
      # "did the thing I changed become the critical path, or did it just move
      # the placement around?" -- which is the whole question when comparing
      # two builds whose fMAX differ.
      puts "SUMMARY_${tag}_WORST_$ck: [get_property STARTPOINT_PIN $p] -> \
[get_property ENDPOINT_PIN $p] levels=[get_property LOGIC_LEVELS $p]"
    }
  }
  set w [get_property SLACK [get_timing_paths -max_paths 1 -delay_type max]]
  puts "SUMMARY_${tag}_WNS: $w"
  puts "SUMMARY_${tag}_CORE_FMAX_MHZ: [format %.1f [expr {1000.0/($period - $w)}]]"
  # Failing endpoints and total violation: WNS is one path, and a build whose
  # single worst path is bad but whose TNS is tiny is a different problem from
  # one with hundreds of endpoints just over the line.
  set tns 0.0 ; set nfail 0
  foreach p [get_timing_paths -max_paths 4000 -delay_type max -slack_lesser_than 0] {
    set tns [expr {$tns + [get_property SLACK $p]}] ; incr nfail
  }
  puts "SUMMARY_${tag}_TNS: [format %.3f $tns]  SUMMARY_${tag}_FAILING: $nfail"
}
summarize SYNTH $period
foreach t {LUT FDRE RAMB36E2 RAMB18E2 URAM288 DSP48E2} {
  puts "SUMMARY_CELL_$t: [llength [get_cells -hier -quiet -filter "REF_NAME =~ $t*"]]"
}

if {$mode eq "impl"} {
  puts "=== opt/place/route: dirset=$dset place=$d_place phys=$d_phys route=$d_route ==="
  opt_design
  place_design    -directive $d_place
  phys_opt_design -directive $d_phys
  route_design    -directive $d_route
  report_utilization -hierarchical -file $outdir/util_impl_hier.rpt
  report_utilization              -file $outdir/util_impl.rpt
  report_timing_summary -delay_type max -max_paths 10 -file $outdir/timing_impl.rpt
  write_checkpoint -force $outdir/post_route.dcp
  summarize IMPL $period
}
puts "SUMMARY_BUILD: fast=$fast dirset=$dset nsym=$nsym sets=$ot_sets_bits ways=$ot_ways ct=$ct fs=$fs period=$period outdir=[file tail $outdir]"
puts "=== DONE mode=$mode ==="
