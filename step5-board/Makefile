STEP1  = ../step1-sw-parser
STEP2  = ../step2-rtl-decoder
STEP3B = ../step3b-splitter
STEP4A = ../step4a-order-table
STEP4B = ../step4b-book

SRC = $(STEP2)/rtl/itch5_pkg.sv $(STEP2)/rtl/itch_decoder.sv \
      $(STEP3B)/rtl/mold_splitter.sv $(STEP4A)/rtl/otable_mem.sv $(STEP4A)/rtl/order_table.sv \
      $(STEP4A)/rtl/order_table_pipe.sv \
      $(STEP4B)/rtl/price_ladder.sv rtl/drop_fifo.sv ../step6-strategy/rtl/sweep_detect.sv rtl/fh_core.sv
TB  = tb/tb_fh_core.sv
TOP = tb_fh_core

# synthetic stimulus: mold stream + the equivalent .itch for the BBO golden
MOLD ?= $(STEP1)/test.mold
ITCH ?= $(STEP1)/test.itch
LOC  ?= 1
BASE ?= 1500000
GAP  ?= 24

export LOCPATH := $(HOME)/.locale

# ---------- functional: end-to-end 512-bit chain vs BBO golden ----------
test: golden
	xvlog -sv $(SRC) $(TB)
	xelab -debug typical $(TOP) -s $(TOP)_sim
	xsim $(TOP)_sim -runall -testplusarg mold=$(MOLD) -testplusarg loc=$(LOC) \
	     -testplusarg base=$(BASE) -testplusarg gap=$(GAP)
	diff bbo_gold.log bbo_rtl.log && echo "PASS: BBO == golden ($(MOLD) loc=$(LOC) gap=$(GAP))"

test-verilator: golden
	verilator --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -j 0 -o tbsim --top-module $(TOP) $(SRC) $(TB)
	./obj_dir/tbsim +mold=$(MOLD) +loc=$(LOC) +base=$(BASE) +gap=$(GAP)
	diff bbo_gold.log bbo_rtl.log && echo "PASS: BBO == golden ($(MOLD) loc=$(LOC) gap=$(GAP))"

golden: $(ITCH)
	python3 $(STEP4B)/scripts/dump_bbo.py $(ITCH) $(LOC) > bbo_gold.log

$(STEP1)/test.itch $(STEP1)/test.mold:
	cd $(STEP1) && python3 gen_itch.py test.itch --mold test.mold

# ---------- real-data replay (AAPL locate 13) ----------
RCAP  ?= ../data/12302019.NASDAQ_ITCH50.gz
RMSGS ?= 5000000
real.itch:
	python3 $(STEP1)/itch_slice.py $(RCAP) real.itch $(RMSGS) AAPL
real.mold: real.itch
	python3 $(STEP1)/itch2mold.py real.itch real.mold

test-real: real.mold
	$(MAKE) test-verilator MOLD=real.mold ITCH=real.itch LOC=13 BASE=2800000

# full-line-rate stress: shows where the correctness-first FSMs saturate
stress: real.mold
	$(MAKE) test-verilator MOLD=real.mold ITCH=real.itch LOC=13 BASE=2800000 GAP=0

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
	vivado -mode batch -nojournal -nolog -notrace -source syn/synth_ooc.tcl -tclargs $(PART) synth $(OT_SETS_BITS) $(OT_WAYS) $(PERIOD)
impl:
	vivado -mode batch -nojournal -nolog -notrace -source syn/synth_ooc.tcl -tclargs $(PART) impl $(OT_SETS_BITS) $(OT_WAYS) $(PERIOD)

# end-to-end simulation of the full chain, diffed against step 6's golden.
# max_inflight is disabled (see tb_t2t.sv) because nothing drives the ack.
STEP6 = ../step6-strategy
test-t2t: real.eth
	python3 $(STEP4B)/scripts/dump_bbo.py real.itch 13 > t2t_bbo.log
	python3 $(STEP6)/scripts/dump_orders.py t2t_bbo.log 2000 1 100 100 1000 65535 50 > t2t_orders.log
	python3 $(STEP6)/scripts/dump_ouch.py t2t_orders.log > t2t_ouch.log
	python3 $(STEP6)/scripts/dump_tcp.py t2t_ouch.log > t2t_gold.log
	verilator --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -j 0 -o t2tsim --top-module tb_t2t $(SRC) rtl/eth_ip_udp_rx.sv rtl/cdc_fifo.sv $(STEP6)/rtl/strategy.sv $(STEP6)/rtl/ouch_builder.sv $(STEP6)/rtl/tcp_tx.sv rtl/igmp_query_detect.sv rtl/t2t_top.sv tb/tb_t2t.sv
	./obj_dir/t2tsim +eth=real.eth +loc=13 +base=2800000 +gap=48 +frm=t2t_rtl.log
	diff t2t_gold.log t2t_rtl.log && echo "PASS: wire -> order frames == golden"

# full chain with the II=1 pipelined order table
test-t2t-pipe: real.eth
	python3 $(STEP4B)/scripts/dump_bbo.py real.itch 13 > t2t_bbo.log
	python3 $(STEP6)/scripts/dump_orders.py t2t_bbo.log 2000 1 100 100 1000 65535 50 > t2t_orders.log
	python3 $(STEP6)/scripts/dump_ouch.py t2t_orders.log > t2t_ouch.log
	python3 $(STEP6)/scripts/dump_tcp.py t2t_ouch.log > t2t_gold.log
	verilator --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -j 0 -DOT_PIPE -o t2tpipe --top-module tb_t2t $(SRC) rtl/eth_ip_udp_rx.sv rtl/cdc_fifo.sv $(STEP6)/rtl/strategy.sv $(STEP6)/rtl/ouch_builder.sv $(STEP6)/rtl/tcp_tx.sv rtl/igmp_query_detect.sv rtl/t2t_top.sv tb/tb_t2t.sv
	./obj_dir/t2tpipe +eth=real.eth +loc=13 +base=2800000 +gap=48 +frm=t2t_rtl.log
	diff t2t_gold.log t2t_rtl.log && echo "PASS: pipe wire -> order frames == golden"

# full tick-to-trade chain (t2t_top): two clocks, wire in -> order frame out
T2T_PERIOD ?= 4.618
synth-t2t:
	vivado -mode batch -nojournal -nolog -notrace -source syn/synth_t2t.tcl -tclargs $(PART) synth $(OT_SETS_BITS) $(OT_WAYS) $(T2T_PERIOD)
impl-t2t:
	vivado -mode batch -nojournal -nolog -notrace -source syn/synth_t2t.tcl -tclargs $(PART) impl $(OT_SETS_BITS) $(OT_WAYS) $(T2T_PERIOD)

# t2t_axil wrapper (three clocks): synth checks the 3-clock XDC applies cleanly
synth-axil:
	vivado -mode batch -nojournal -nolog -notrace -source syn/synth_axil.tcl -tclargs $(PART) synth $(OT_SETS_BITS) $(OT_WAYS) $(T2T_PERIOD) 4.000
impl-axil:
	vivado -mode batch -nojournal -nolog -notrace -source syn/synth_axil.tcl -tclargs $(PART) impl $(OT_SETS_BITS) $(OT_WAYS) $(T2T_PERIOD) 4.000

clean:
	rm -rf obj_dir xsim.dir *.log *.jou *.pb *.wdb *.mem *.hex *.frames bbo_*.log real.itch real.mold syn/out syn/out_t2t syn/out_axil

.PHONY: test test-verilator golden test-real test-cdc test-t2t test-axil test-igmp test-igmpq test-arp test-ab test-cfgcdc test-txarb test-axil-top test-axil-full lint-opennic stress synth impl synth-t2t impl-t2t synth-axil impl-axil clean

# ---------- AXI4-Lite register file (host config surface) ----------
# Self-checking, no golden file needed: writes then reads back every register.
test-axil:
	verilator --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -j 0 -o axilsim --top-module tb_axil_regfile rtl/axil_regfile.sv tb/tb_axil_regfile.sv
	./obj_dir/axilsim

# ---------- t2t_axil wrapper: AXI-Lite control plane + CDC + TX arbiter ------
# Unit checks for the new crossing/arbiter logic, then a wrapper smoke test that
# drives AXI config across three async clocks and catches the IGMP report on tx.
test-cfgcdc:
	verilator --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -j 0 -o cfgcdcsim --top-module tb_cfg_cdc rtl/cfg_cdc.sv tb/tb_cfg_cdc.sv
	./obj_dir/cfgcdcsim

test-txarb:
	verilator --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -j 0 -o txarbsim --top-module tb_axis_tx_arb rtl/axis_tx_arb.sv tb/tb_axis_tx_arb.sv
	./obj_dir/txarbsim

TAXIL_SRC = ../step2-rtl-decoder/rtl/itch5_pkg.sv ../step2-rtl-decoder/rtl/itch_decoder.sv \
  ../step3b-splitter/rtl/mold_splitter.sv ../step4a-order-table/rtl/otable_mem.sv \
  ../step4a-order-table/rtl/order_table.sv ../step4a-order-table/rtl/order_table_pipe.sv \
  ../step4b-book/rtl/price_ladder.sv rtl/drop_fifo.sv rtl/fh_core.sv rtl/eth_ip_udp_rx.sv \
  rtl/cdc_fifo.sv ../step6-strategy/rtl/strategy.sv ../step6-strategy/rtl/sweep_detect.sv \
  ../step6-strategy/rtl/ouch_builder.sv ../step6-strategy/rtl/tcp_tx.sv \
  rtl/igmp_query_detect.sv rtl/t2t_top.sv \
  rtl/axil_regfile.sv rtl/cfg_cdc.sv rtl/axis_tx_arb.sv rtl/igmp_join.sv rtl/arp_responder.sv rtl/t2t_axil.sv
test-axil-top:
	python3 scripts/gen_igmp.py 233.54.12.1 10.0.0.2 00:11:22:33:44:55 > igmp_gold.mem
	verilator --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -j 0 -o taxilsim --top-module tb_t2t_axil $(TAXIL_SRC) tb/tb_t2t_axil.sv
	./obj_dir/taxilsim

# full datapath THROUGH the wrapper: real replay + AXI config, order frames
# diffed against step 6's golden; IGMP reports (incl. a query-triggered one)
# ride the same TX through the arbiter.
test-axil-full: real.eth
	python3 $(STEP4B)/scripts/dump_bbo.py real.itch 13 > t2t_bbo.log
	python3 $(STEP6)/scripts/dump_orders.py t2t_bbo.log 2000 1 100 100 1000 65535 50 > t2t_orders.log
	python3 $(STEP6)/scripts/dump_ouch.py t2t_orders.log > t2t_ouch.log
	python3 $(STEP6)/scripts/dump_tcp.py t2t_ouch.log > t2t_gold.log
	verilator --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -j 0 -o taxilfull --top-module tb_t2t_axil_full $(TAXIL_SRC) tb/tb_t2t_axil_full.sv
	./obj_dir/taxilfull +eth=real.eth +frm=t2t_axil_rtl.log
	diff t2t_gold.log t2t_axil_rtl.log && echo "PASS: wrapper AXI-config -> order frames == golden"

# ---------- OpenNIC integration: elaborate the box adapter ----------
# Proves t2t_user_322mhz wires t2t_axil to the box interface correctly, using a
# stub for the core-clock MMCM (the real IP is a Vivado clk_wiz; see opennic/).
lint-opennic:
	verilator --lint-only -sv -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT --top-module t2t_user_322mhz $(TAXIL_SRC) opennic/t2t_core_clk_stub.sv opennic/t2t_user_322mhz.sv
	@echo "PASS: t2t_user_322mhz elaborates against t2t_axil"

# ---------- A/B line arbiter (redundant-feed gap recovery) ----------
# Two lines with different drops must merge to the clean golden stream; a
# double-line gap must be skipped (ev_gap). gen_ab.py builds both cases.
test-ab:
	verilator --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -j 0 -o absim --top-module tb_feed_ab rtl/feed_ab_arb.sv tb/tb_feed_ab.sv
	python3 scripts/gen_ab.py recover 30
	./obj_dir/absim +gap=0
	diff ab_gold.hex ab_rtl.hex && echo "PASS: A/B recover == golden (single-line drops filled)"
	python3 scripts/gen_ab.py gap 30
	./obj_dir/absim +gap=1
	diff ab_gold.hex ab_rtl.hex && echo "PASS: A/B double-gap skipped == golden"

# ---------- ARP responder (answer who-has our IP) ----------
test-arp:
	python3 scripts/gen_arp.py 00:11:22:33:44:55 10.0.0.2 aa:bb:cc:dd:ee:ff 10.0.0.9 > arp_gold.mem
	verilator --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -j 0 -o arpsim --top-module tb_arp_responder rtl/arp_responder.sv tb/tb_arp_responder.sv
	./obj_dir/arpsim

# ---------- IGMPv2 membership report (multicast join) ----------
# Golden frame from an independent Python build; TB diffs every emitted frame
# against it byte-for-byte. Group/src match tb_igmp_join.sv defaults.
test-igmpq:
	verilator --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -j 0 -o igmpqsim --top-module tb_igmp_query_detect rtl/igmp_query_detect.sv tb/tb_igmp_query_detect.sv
	./obj_dir/igmpqsim

test-igmp:
	python3 scripts/gen_igmp.py 233.54.12.1 10.0.0.2 00:11:22:33:44:55 > igmp_gold.mem
	verilator --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -j 0 -o igmpsim --top-module tb_igmp_join rtl/igmp_join.sv tb/tb_igmp_join.sv
	./obj_dir/igmpsim

# ---------- clock crossing (CMAC 322 MHz -> core clock) ----------
# Two clocks, so this is Verilator-only: the checks are about pointer
# synchronisation, not about the ITCH golden.
test-cdc:
	verilator --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -j 0 -o cdcsim --top-module tb_cdc_fifo rtl/cdc_fifo.sv tb/tb_cdc_fifo.sv
	./obj_dir/cdcsim

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
	verilator --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -j 0 -o wtbsim --top-module $(WTB) $(WSRC) tb/tb_wire_to_bbo.sv
	./obj_dir/wtbsim +eth=$(WETH) +loc=$(LOC) +base=$(BASE) +gap=$(GAP)
	diff bbo_gold.log bbo_rtl.log && echo "PASS: wire->BBO == golden"

real.eth: real.mold
	python3 $(STEP1)/mold2eth.py real.mold real.eth

test-wire-real: real.eth
	$(MAKE) test-wire ITCH=real.itch LOC=13 BASE=2800000 WETH=real.eth
	@true
