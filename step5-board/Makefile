include ../mk/xilinx.mk

STEP1  = ../step1-sw-parser
STEP2  = ../step2-rtl-decoder
STEP3B = ../step3b-splitter
STEP4A = ../step4a-order-table
STEP4B = ../step4b-book

SRC = $(STEP2)/rtl/itch5_pkg.sv $(STEP2)/rtl/itch_decoder.sv \
      $(STEP3B)/rtl/mold_splitter.sv $(STEP4A)/rtl/otable_mem.sv $(STEP4A)/rtl/order_table.sv \
      $(STEP4A)/rtl/order_table_pipe.sv \
      $(STEP4B)/rtl/price_ladder.sv $(STEP4B)/rtl/fast_bbo.sv $(STEP4B)/rtl/bbo_merge.sv $(STEP4B)/rtl/bbo_arb.sv \
      rtl/drop_fifo.sv ../step6-strategy/rtl/sweep_detect.sv rtl/fh_core.sv
TB  = tb/tb_fh_core.sv
TOP = tb_fh_core

# synthetic stimulus: mold stream + the equivalent .itch for the BBO golden
MOLD ?= $(STEP1)/test.mold
ITCH ?= $(STEP1)/test.itch
LOC  ?= 1
BASE ?= 1500000
GAP  ?= 24

# ---------- functional: end-to-end 512-bit chain vs BBO golden ----------
test: golden
	$(XSETUP) xvlog -sv $(SRC) $(TB)
	$(XSETUP) xelab -debug typical -L xpm $(TOP) -s $(TOP)_sim
	$(XSETUP) xsim $(TOP)_sim -runall -testplusarg mold=$(MOLD) -testplusarg loc=$(LOC) \
	     -testplusarg base=$(BASE) -testplusarg gap=$(GAP)
	diff bbo_gold.log bbo_rtl.log && echo "PASS: BBO == golden ($(MOLD) loc=$(LOC) gap=$(GAP))"

golden: $(ITCH)
	python3 $(STEP4B)/scripts/dump_bbo.py $(ITCH) $(LOC) > bbo_gold.log

$(STEP1)/test.itch $(STEP1)/test.mold:
	cd $(STEP1) && python3 gen_itch.py test.itch --mold test.mold

# ---------- multi-symbol: two tracked books through one chain ----------
# The goldens are the SINGLE-symbol goldens for each locate, because that is
# exactly the claim: with NSYM=2 each book's BBO sequence must be the one a
# build tracking that symbol alone would emit. See tb_fh_core_msym.sv.
#
# The stimulus is the gap-free variant. The default plan drops a packet, and
# the two messages in it are MSFT's cancel and delete -- untracked noise when
# only AAPL is tracked, and half of MSFT's book when it is not.
CLEAN_ITCH = $(STEP1)/test_clean.itch
CLEAN_MOLD = $(STEP1)/test_clean.mold
$(CLEAN_ITCH) $(CLEAN_MOLD):
	cd $(STEP1) && python3 gen_itch.py test_clean.itch --mold test_clean.mold --clean

MSYM_SRC = $(SRC)
test-msym: $(CLEAN_ITCH) $(CLEAN_MOLD)
	python3 $(STEP4B)/scripts/dump_bbo.py $(CLEAN_ITCH) 1 > bbo_gold_s0.log
	python3 $(STEP4B)/scripts/dump_bbo.py $(CLEAN_ITCH) 2 > bbo_gold_s1.log
	$(XSETUP) xvlog -sv $(MSYM_SRC) tb/tb_fh_core_msym.sv
	$(XSETUP) xelab -debug typical -L xpm tb_fh_core_msym -s tb_fh_core_msym_sim
	$(XSETUP) xsim tb_fh_core_msym_sim -runall -testplusarg mold=$(CLEAN_MOLD)
	diff bbo_gold_s0.log bbo_rtl_s0.log
	diff bbo_gold_s1.log bbo_rtl_s1.log
	@echo "PASS: two tracked books, each == its own single-symbol golden"

# ---------- real-data replay (AAPL locate 13) ----------
RCAP  ?= ../data/12302019.NASDAQ_ITCH50.gz
RMSGS ?= 5000000
real.itch:
	python3 $(STEP1)/itch_slice.py $(RCAP) real.itch $(RMSGS) AAPL
real.mold: real.itch
	python3 $(STEP1)/itch2mold.py real.itch real.mold

# A SIMULATION-SIZED slice of the same real feed. The 5 M one exists to be
# replayed on the card: packed it is 327 MB, and the kernel testbench's memory
# model holds 8 MB, so a simulation of the full replay is not a slow test, it is
# an impossible one. This is the largest prefix that fits, kept under its own
# names so nothing here clobbers the artefacts the card flow depends on.
#
# What it covers is the FEED path on real data -- framing, the splitter, the
# table, the book -- and not the order path: orders are rare in this feed (one in
# the first million messages), so a prefix this size fires none. That is a
# statement about the stimulus, not a gap in the test, and step8's test-real
# prints the golden's order count so an empty diff cannot be mistaken for
# coverage.
# THE SIZE IS IN THE NAME, for the same reason step8's replay image carries its
# stimulus: a slice built once and named `realsmall` would be silently reused
# when someone asked for a different message count, since the rule has no
# prerequisite that changes. As a pattern rule the count cannot go stale.
realsmall-%.itch:
	python3 $(STEP1)/itch_slice.py $(RCAP) $@ $* AAPL
realsmall-%.mold: realsmall-%.itch
	python3 $(STEP1)/itch2mold.py $< $@
realsmall-%.eth: realsmall-%.mold
	python3 $(STEP1)/mold2eth.py $< $@
# Without this make treats the .itch and .mold as intermediates of the chain
# above and DELETES them once the .eth exists -- and the .itch is what the
# golden is generated from, so the next target to ask for it finds the .eth "up
# to date" and no source to build a golden against.
.SECONDARY: realsmall-%.itch realsmall-%.mold

test-real: real.mold
	$(MAKE) test MOLD=real.mold ITCH=real.itch LOC=13 BASE=2800000

# full-line-rate stress: shows where the correctness-first FSMs saturate
stress: real.mold
	$(MAKE) test MOLD=real.mold ITCH=real.itch LOC=13 BASE=2800000 GAP=0

# ---------- synthesis / implementation for the real U55C device ----------
PART ?= xcu55c-fsvh2892-2L-e
# Order-table geometry, instantiated as URAM so synthesis builds exactly what
# the simulations verify. 2^13 x 16 is the measured zero-overflow point chosen
# for cascade depth rather than capacity -- see order_table.sv.
OT_SETS_BITS ?= 13
OT_WAYS ?= 16
# target period: 3.103 = 322.27 MHz (CMAC box), 4.000 = 250 MHz (QDMA box)
PERIOD ?= 4.000
synth:
	$(XSETUP) vivado -mode batch -nojournal -nolog -notrace -source syn/synth_ooc.tcl -tclargs $(PART) synth $(OT_SETS_BITS) $(OT_WAYS) $(PERIOD)
impl:
	$(XSETUP) vivado -mode batch -nojournal -nolog -notrace -source syn/synth_ooc.tcl -tclargs $(PART) impl $(OT_SETS_BITS) $(OT_WAYS) $(PERIOD)

# end-to-end simulation of the full chain, diffed against step 6's golden.
# max_inflight is disabled (see tb_t2t.sv) because nothing drives the ack.
STEP6 = ../step6-strategy
test-t2t: real.eth
	python3 $(STEP4B)/scripts/dump_bbo.py real.itch 13 > t2t_bbo.log
	python3 $(STEP6)/scripts/dump_orders.py t2t_bbo.log 2000 1 100 100 1000 65535 50 > t2t_orders.log
	python3 $(STEP6)/scripts/dump_ouch.py t2t_orders.log > t2t_ouch.log
	python3 $(STEP6)/scripts/dump_tcp.py t2t_ouch.log > t2t_gold.log
	$(XSETUP) xvlog -sv $(SRC) rtl/eth_ip_udp_rx.sv rtl/cdc_fifo.sv $(STEP6)/rtl/strategy.sv $(STEP6)/rtl/ouch_builder.sv $(STEP6)/rtl/tcp_tx.sv $(STEP6)/rtl/tx_replay_buf.sv $(STEP6)/rtl/tx_rto.sv $(STEP6)/rtl/ack_latency.sv rtl/feed_ab_arb.sv rtl/igmp_query_detect.sv rtl/tcp_rx.sv rtl/t2t_top.sv tb/tb_t2t.sv
	$(XSETUP) xelab -debug typical -L xpm tb_t2t -s tb_t2t_sim
	$(XSETUP) xsim tb_t2t_sim -runall -testplusarg eth=real.eth -testplusarg loc=13 \
	     -testplusarg base=2800000 -testplusarg gap=48 -testplusarg frm=t2t_rtl.log
	diff t2t_gold.log t2t_rtl.log && echo "PASS: wire -> order frames == golden"

# full chain with the II=1 pipelined order table
test-t2t-pipe: real.eth
	python3 $(STEP4B)/scripts/dump_bbo.py real.itch 13 > t2t_bbo.log
	python3 $(STEP6)/scripts/dump_orders.py t2t_bbo.log 2000 1 100 100 1000 65535 50 > t2t_orders.log
	python3 $(STEP6)/scripts/dump_ouch.py t2t_orders.log > t2t_ouch.log
	python3 $(STEP6)/scripts/dump_tcp.py t2t_ouch.log > t2t_gold.log
	$(XSETUP) xvlog -sv -d OT_PIPE $(SRC) rtl/eth_ip_udp_rx.sv rtl/cdc_fifo.sv $(STEP6)/rtl/strategy.sv $(STEP6)/rtl/ouch_builder.sv $(STEP6)/rtl/tcp_tx.sv $(STEP6)/rtl/tx_replay_buf.sv $(STEP6)/rtl/tx_rto.sv $(STEP6)/rtl/ack_latency.sv rtl/feed_ab_arb.sv rtl/igmp_query_detect.sv rtl/tcp_rx.sv rtl/t2t_top.sv tb/tb_t2t.sv
	$(XSETUP) xelab -debug typical -L xpm -d OT_PIPE tb_t2t -s tb_t2t_pipe_sim
	$(XSETUP) xsim tb_t2t_pipe_sim -runall -testplusarg eth=real.eth -testplusarg loc=13 \
	     -testplusarg base=2800000 -testplusarg gap=48 -testplusarg frm=t2t_rtl.log
	diff t2t_gold.log t2t_rtl.log && echo "PASS: pipe wire -> order frames == golden"

# full tick-to-trade chain (t2t_top): two clocks, wire in -> order frame out
#
# FAST selects the fast_bbo path (1) or the ladder alone (0), and DIRSET picks
# an implementation directive triple -- both go to the build as knobs rather
# than as edits, and both appear in the output directory name, so no two
# configurations can overwrite each other's reports.
T2T_PERIOD ?= 4.618
FAST       ?= 1
DIRSET     ?= default
NSYM       ?= 1
T2T_ARGS    = $(PART) impl $(OT_SETS_BITS) $(OT_WAYS) $(T2T_PERIOD)
synth-t2t:
	$(XSETUP) vivado -mode batch -nojournal -nolog -notrace -source syn/synth_t2t.tcl -tclargs $(PART) synth $(OT_SETS_BITS) $(OT_WAYS) $(T2T_PERIOD) $(FAST) $(DIRSET) $(NSYM)
impl-t2t:
	$(XSETUP) vivado -mode batch -nojournal -nolog -notrace -source syn/synth_t2t.tcl -tclargs $(T2T_ARGS) $(FAST) $(DIRSET) $(NSYM)

# The fast_bbo timing question: is the post-route fMAX difference between
# FAST=0 and FAST=1 a real cost of the feature, or is it the tool's run-to-run
# spread? One build of each cannot tell those apart, so this runs both across
# every directive set and prints the two distributions side by side. Four
# concurrent Vivados is comfortable on 32 cores; each is given 8.
#   make sweep-t2t          # 8 impl runs, ~40 min
#   make sweep-t2t-report   # re-print the table from existing runs
# The axes are separate variables so the sweep can answer more than the one
# question it was written for. SWEEP_FAST=1 SWEEP_NSYM="1 2" asks what a second
# symbol costs in fMAX; the defaults ask what fast_bbo costs. Log names carry
# every axis, for the same reason the output directories do.
SWEEP_DIRSETS = default explore netdly fanout
SWEEP_FAST   ?= 0 1
SWEEP_NSYM   ?= 1
# The order-table geometry is part of a build's identity too, and it was NOT in
# these names: a NSYM=2 sweep at 2^13 and one at 2^14 wrote to the same logs and
# the same output directories. Tagged the same way synth_t2t.tcl tags the
# directory -- omitted at the default so existing artefacts keep their names.
SWEEP_SETS_TAG = $(if $(filter-out 13,$(OT_SETS_BITS)),-s$(OT_SETS_BITS))
sweep-t2t:
	@$(XSETUP) for n in $(SWEEP_NSYM); do \
	  for f in $(SWEEP_FAST); do \
	    for d in $(SWEEP_DIRSETS); do \
	      echo "=== launching fast=$$f nsym=$$n dirset=$$d ==="; \
	      vivado -mode batch -nojournal -nolog -notrace -source syn/synth_t2t.tcl \
	        -tclargs $(T2T_ARGS) $$f $$d $$n > syn/sweep-f$$f-n$$n$(SWEEP_SETS_TAG)-$$d.log 2>&1 & \
	    done; \
	    wait; \
	  done; \
	done
	@$(MAKE) --no-print-directory sweep-t2t-report

sweep-t2t-report:
	@python3 scripts/sweep_report.py syn/sweep-f*.log

# t2t_axil wrapper (three clocks): synth checks the 3-clock XDC applies cleanly
synth-axil:
	$(XSETUP) vivado -mode batch -nojournal -nolog -notrace -source syn/synth_axil.tcl -tclargs $(PART) synth $(OT_SETS_BITS) $(OT_WAYS) $(T2T_PERIOD) 4.000 $(NSYM)
impl-axil:
	$(XSETUP) vivado -mode batch -nojournal -nolog -notrace -source syn/synth_axil.tcl -tclargs $(PART) impl $(OT_SETS_BITS) $(OT_WAYS) $(T2T_PERIOD) 4.000 $(NSYM)

clean:
	rm -rf xsim.dir *.log *.jou *.pb *.wdb *.mem *.hex *.frames bbo_*.log real.itch real.mold syn/out syn/out_t2t syn/out_axil
	rm -f  realsmall-*.itch realsmall-*.mold realsmall-*.eth

.PHONY: test-msym test-tcprx test-axil-xsim test-axil-msym-xsim test-cfgcdc-xsim test-txarb-xsim test-cdc-xsim test-units-xsim test golden test-real test-cdc test-t2t test-axil test-igmp test-igmpq test-arp test-ab test-cfgcdc test-txarb test-axil-top test-axil-full lint-opennic stress synth impl synth-t2t impl-t2t sweep-t2t sweep-t2t-report synth-axil impl-axil clean

# The self-checking unit tests. These began as xsim twins of Verilator targets,
# written because Verilator was absent on the machine with the actual U55C --
# which had made most of the suite unrunnable exactly where the hardware is.
# They are now the only form: the project runs on xsim alone. The testbenches
# check themselves, so no golden is needed and each is three lines.
#
# A two-clock testbench is not a reason to reach for another simulator, whatever
# the old comments here implied: xsim runs multiple clocks fine, and
# step8-hw/tb/tb_t2t_kernel.sv uses two.
define XSIM_UNIT
	$(XSETUP) xvlog -sv $(2)
	$(XSETUP) xelab -debug typical -L xpm $(1) -s $(1)_xsim
	$(XSETUP) xsim $(1)_xsim -runall
endef

# alias: the xsim recipe is the only one now.
test-axil: test-axil-xsim

test-axil-xsim:
	$(call XSIM_UNIT,tb_axil_regfile,rtl/axil_regfile.sv tb/tb_axil_regfile.sv)

test-cfgcdc-xsim:
	$(call XSIM_UNIT,tb_cfg_cdc,rtl/cfg_cdc.sv tb/tb_cfg_cdc.sv)

test-txarb-xsim:
	$(call XSIM_UNIT,tb_axis_tx_arb,rtl/axis_tx_arb.sv tb/tb_axis_tx_arb.sv)

test-cdc-xsim:
	$(call XSIM_UNIT,tb_cdc_fifo,rtl/cdc_fifo.sv tb/tb_cdc_fifo.sv)

# every self-checking unit test
# The per-symbol config block, which only exists at NSYM>1 and which a
# multi-symbol card run depends on entirely. See the testbench header.
test-axil-msym-xsim:
	$(call XSIM_UNIT,tb_axil_regfile_msym,rtl/axil_regfile.sv tb/tb_axil_regfile_msym.sv)

test-units-xsim: test-axil-xsim test-axil-msym-xsim test-cfgcdc-xsim test-txarb-xsim test-cdc-xsim
	@echo "PASS: all self-checking unit tests ran under xsim"

# alias: the xsim recipe is the only one now.
test-cfgcdc: test-cfgcdc-xsim

# alias: the xsim recipe is the only one now.
test-txarb: test-txarb-xsim

TAXIL_SRC = ../step2-rtl-decoder/rtl/itch5_pkg.sv ../step2-rtl-decoder/rtl/itch_decoder.sv \
  ../step3b-splitter/rtl/mold_splitter.sv ../step4a-order-table/rtl/otable_mem.sv \
  ../step4a-order-table/rtl/order_table.sv ../step4a-order-table/rtl/order_table_pipe.sv \
  ../step4b-book/rtl/price_ladder.sv ../step4b-book/rtl/fast_bbo.sv \
  ../step4b-book/rtl/bbo_merge.sv rtl/drop_fifo.sv rtl/fh_core.sv rtl/eth_ip_udp_rx.sv \
  rtl/cdc_fifo.sv ../step6-strategy/rtl/strategy.sv ../step6-strategy/rtl/sweep_detect.sv \
  ../step6-strategy/rtl/ouch_builder.sv ../step6-strategy/rtl/tcp_tx.sv \
  ../step6-strategy/rtl/tx_replay_buf.sv ../step6-strategy/rtl/tx_rto.sv ../step6-strategy/rtl/ack_latency.sv \
  rtl/feed_ab_arb.sv rtl/igmp_query_detect.sv rtl/tcp_rx.sv rtl/t2t_top.sv \
  rtl/axil_regfile.sv rtl/cfg_cdc.sv rtl/axis_tx_arb.sv rtl/igmp_join.sv rtl/arp_responder.sv rtl/t2t_axil.sv
test-axil-top:
	python3 scripts/gen_igmp.py 233.54.12.1 10.0.0.2 00:11:22:33:44:55 > igmp_gold.mem
	$(XSETUP) xvlog -sv $(TAXIL_SRC) tb/tb_t2t_axil.sv
	$(XSETUP) xelab -debug typical -L xpm tb_t2t_axil -s tb_t2t_axil_sim
	$(XSETUP) xsim tb_t2t_axil_sim -runall

# full datapath THROUGH the wrapper: real replay + AXI config, order frames
# diffed against step 6's golden; IGMP reports (incl. a query-triggered one)
# ride the same TX through the arbiter.
test-axil-full: real.eth
	python3 $(STEP4B)/scripts/dump_bbo.py real.itch 13 > t2t_bbo.log
	python3 $(STEP6)/scripts/dump_orders.py t2t_bbo.log 2000 1 100 100 1000 65535 50 > t2t_orders.log
	python3 $(STEP6)/scripts/dump_ouch.py t2t_orders.log > t2t_ouch.log
	python3 $(STEP6)/scripts/dump_tcp.py t2t_ouch.log > t2t_gold.log
	$(XSETUP) xvlog -sv $(TAXIL_SRC) tb/tb_t2t_axil_full.sv
	$(XSETUP) xelab -debug typical -L xpm tb_t2t_axil_full -s tb_t2t_axil_full_sim
	$(XSETUP) xsim tb_t2t_axil_full_sim -runall -testplusarg eth=real.eth \
	     -testplusarg frm=t2t_axil_rtl.log
	diff t2t_gold.log t2t_axil_rtl.log && echo "PASS: wrapper AXI-config -> order frames == golden"

# ---------- OpenNIC integration: elaborate the box adapter ----------
# Proves t2t_user_322mhz wires t2t_axil to the box interface correctly, using a
# stub for the core-clock MMCM (the real IP is a Vivado clk_wiz; see opennic/).
# Elaboration, not lint: xsim has no --lint-only, so this builds a snapshot and
# throws it away. It proves the same thing the lint did -- that every port of
# t2t_axil is connected and every width agrees -- which is the only question a
# box adapter with no behaviour of its own can get wrong.
lint-opennic:
	$(XSETUP) xvlog -sv $(TAXIL_SRC) opennic/t2t_core_clk_stub.sv opennic/t2t_user_322mhz.sv
	$(XSETUP) xelab -debug typical -L xpm t2t_user_322mhz -s t2t_user_322mhz_elab
	@echo "PASS: t2t_user_322mhz elaborates against t2t_axil"

# ---------- A/B line arbiter (redundant-feed gap recovery) ----------
# Two lines with different drops must merge to the clean golden stream; a
# double-line gap must be skipped (ev_gap). gen_ab.py builds both cases.
test-ab:
	$(XSETUP) xvlog -sv rtl/feed_ab_arb.sv tb/tb_feed_ab.sv
	$(XSETUP) xelab -debug typical -L xpm tb_feed_ab -s tb_feed_ab_sim
	python3 scripts/gen_ab.py recover 30
	$(XSETUP) xsim tb_feed_ab_sim -runall -testplusarg gap=0
	diff ab_gold.hex ab_rtl.hex && echo "PASS: A/B recover == golden (single-line drops filled)"
	python3 scripts/gen_ab.py gap 30
	$(XSETUP) xsim tb_feed_ab_sim -runall -testplusarg gap=1
	diff ab_gold.hex ab_rtl.hex && echo "PASS: A/B double-gap skipped == golden"

# ---------- ARP responder (answer who-has our IP) ----------
test-arp:
	python3 scripts/gen_arp.py 00:11:22:33:44:55 10.0.0.2 aa:bb:cc:dd:ee:ff 10.0.0.9 > arp_gold.mem
	$(XSETUP) xvlog -sv rtl/arp_responder.sv tb/tb_arp_responder.sv
	$(XSETUP) xelab -debug typical -L xpm tb_arp_responder -s tb_arp_responder_sim
	$(XSETUP) xsim tb_arp_responder_sim -runall

# ---------- IGMPv2 membership report (multicast join) ----------
# Golden frame from an independent Python build; TB diffs every emitted frame
# against it byte-for-byte. Group/src match tb_igmp_join.sv defaults.
test-igmpq:
	$(XSETUP) xvlog -sv rtl/igmp_query_detect.sv tb/tb_igmp_query_detect.sv
	$(XSETUP) xelab -debug typical -L xpm tb_igmp_query_detect -s tb_igmp_query_detect_sim
	$(XSETUP) xsim tb_igmp_query_detect_sim -runall

test-igmp:
	python3 scripts/gen_igmp.py 233.54.12.1 10.0.0.2 00:11:22:33:44:55 > igmp_gold.mem
	$(XSETUP) xvlog -sv rtl/igmp_join.sv tb/tb_igmp_join.sv
	$(XSETUP) xelab -debug typical -L xpm tb_igmp_join -s tb_igmp_join_sim
	$(XSETUP) xsim tb_igmp_join_sim -runall

# alias: the xsim recipe is the only one now.
test-cdc: test-cdc-xsim

# ---------- wire path: Ethernet frames -> parser -> feed handler -> BBO ----------
WTB = tb_wire_to_bbo
WSRC = $(SRC) rtl/eth_ip_udp_rx.sv
test.eth: $(STEP1)/test.mold
	python3 $(STEP1)/mold2eth.py $(STEP1)/test.mold test.eth

# WETH is the frame file to replay; it must match ITCH, or the diff is against
# a golden the simulation never saw. This rule used to hardcode test.eth while
# test-wire-real passed WETH=real.eth, so the real-data run silently replayed
# the 8-frame smoke file and diffed it against the 1779-line real golden.
WETH ?= test.eth
test-wire: $(WETH)
	python3 $(STEP4B)/scripts/dump_bbo.py $(ITCH) $(LOC) > bbo_gold.log
	$(XSETUP) xvlog -sv $(WSRC) tb/tb_wire_to_bbo.sv
	$(XSETUP) xelab -debug typical -L xpm $(WTB) -s $(WTB)_sim
	$(XSETUP) xsim $(WTB)_sim -runall -testplusarg eth=$(WETH) -testplusarg loc=$(LOC) \
	     -testplusarg base=$(BASE) -testplusarg gap=$(GAP)
	diff bbo_gold.log bbo_rtl.log && echo "PASS: wire->BBO == golden"

real.eth: real.mold
	python3 $(STEP1)/mold2eth.py real.mold real.eth

test-wire-real: real.eth
	$(MAKE) test-wire ITCH=real.itch LOC=13 BASE=2800000 WETH=real.eth
	@true

# Self-checking, no golden needed: tcp_rx's contract is its sequence bookkeeping,
# and every way of getting that wrong is silent on the wire.
test-tcprx:
	$(XSETUP) xvlog -sv rtl/tcp_rx.sv tb/tb_tcp_rx.sv
	$(XSETUP) xelab -debug typical -L xpm tb_tcp_rx -s tb_tcp_rx_sim
	$(XSETUP) xsim tb_tcp_rx_sim -runall
