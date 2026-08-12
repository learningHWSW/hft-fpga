# Step 6 — strategy trigger + risk gate.
#
# Stimulus is a BBO log, which is what step 4b emits, so this stage is tested
# on its own rather than through the whole chain: a mismatch here is a rule or
# risk-gate bug, never a book bug.
#

STEP4B = ../step4b-book
STEP5  = ../step5-board

ITCH ?= $(STEP5)/real.itch
LOC  ?= 13

VSRC = rtl/strategy.sv rtl/ouch_builder.sv rtl/tcp_tx.sv rtl/tx_replay_buf.sv tb/tb_strategy.sv

.PHONY: test test-combined test-xsim test-msym check-frames test-sweep test-replay test-rto test-acklat imbalance-edge clean

# bbo_in.log is the shared stimulus: the golden reads it, and so does the RTL
bbo_in.log:
	python3 $(STEP4B)/scripts/dump_bbo.py $(ITCH) $(LOC) > bbo_in.log

# alias: the xsim recipe is the only one now.
test: test-xsim

# combined strategy: imbalance (BBO) + sweep, one risk gate. The golden merges
# both trigger streams by timestamp; the TB drives the same merged order.
test-combined: bbo_in.log
	python3 scripts/dump_sweep.py $(SWITCH) $(SWLOC) $(SWMIN) $(SWGAP) > sweep_in.log 2>/dev/null
	python3 scripts/dump_orders.py bbo_in.log 2000 1 100 100 1000 4 50 sweep_in.log > orders_gold.log
	xvlog -sv $(VSRC)
	xelab -debug typical -L xpm tb_strategy -s tb_strategy_sim
	xsim tb_strategy_sim -runall -testplusarg bbo=bbo_in.log -testplusarg sweep=sweep_in.log \
	     -testplusarg out=orders_rtl.log -testplusarg pkt=ouch_rtl.log -testplusarg frm=frames_rtl.log
	diff orders_gold.log orders_rtl.log && echo "PASS: combined orders == golden ($(SWITCH) loc=$(SWLOC))"
	python3 scripts/dump_ouch.py orders_gold.log > ouch_gold.log
	diff ouch_gold.log ouch_rtl.log && echo "PASS: combined OUCH == golden"
	python3 scripts/dump_tcp.py ouch_gold.log > frames_gold.log
	diff frames_gold.log frames_rtl.log && echo "PASS: combined TCP frames == golden"

test-xsim: bbo_in.log
	python3 scripts/dump_orders.py bbo_in.log > orders_gold.log
	xvlog -sv $(VSRC)
	xelab -debug typical -L xpm tb_strategy -s tb_strategy_sim
	xsim tb_strategy_sim -testplusarg bbo=bbo_in.log -testplusarg out=orders_rtl.log -testplusarg pkt=ouch_rtl.log -testplusarg frm=frames_rtl.log -runall
	diff orders_gold.log orders_rtl.log && echo "PASS: orders == golden (xsim)"
	python3 scripts/dump_ouch.py orders_gold.log > ouch_gold.log
	diff ouch_gold.log ouch_rtl.log && echo "PASS: OUCH packets == golden (xsim)"

# Multi-symbol: the SAME BBO log presented to two symbols, which is the worst
# case for shared state -- so each symbol's order stream must still be the
# ordinary single-symbol golden. cfg_max_inflight is raised out of the way
# because it is shared BY DESIGN (one session, one replay buffer); everything
# else in the golden's configuration is unchanged, including cfg_pos_limit,
# which is per symbol and does bind. See tb_strategy_msym.sv.
MSYM_SRC = rtl/strategy.sv rtl/ouch_builder.sv tb/tb_strategy_msym.sv
test-msym: bbo_in.log
	python3 scripts/dump_orders.py bbo_in.log 2000 1 100 100 1000 65535 50 > orders_gold_msym.log
	xvlog -sv $(MSYM_SRC)
	xelab -debug typical -L xpm tb_strategy_msym -s tb_strategy_msym_sim
	xsim tb_strategy_msym_sim -testplusarg bbo=bbo_in.log \
	     -testplusarg out0=orders_rtl_s0.log -testplusarg out1=orders_rtl_s1.log -runall
	diff orders_gold_msym.log orders_rtl_s0.log
	diff orders_gold_msym.log orders_rtl_s1.log
	@echo "PASS: two symbols, each == the single-symbol golden, own stock in OUCH"

# independent re-derivation of the checksums; skips if scapy is absent
check-frames:
	python3 scripts/check_frames.py frames_rtl.log

# sweep detector: decoder -> order_table -> sweep_detect, diffed vs golden.
# The detection half only; forward-return validation is Python analysis.
STEP2 = ../step2-rtl-decoder
STEP4A = ../step4a-order-table
STEP5 = ../step5-board
SWMIN ?= 2
SWGAP ?= 1000000
SWITCH ?= $(STEP5)/real.itch
SWLOC ?= 13
SWSRC = $(STEP2)/rtl/itch5_pkg.sv $(STEP2)/rtl/itch_decoder.sv \
        $(STEP4A)/rtl/otable_mem.sv $(STEP4A)/rtl/order_table.sv \
        $(STEP5)/rtl/drop_fifo.sv rtl/sweep_detect.sv tb/tb_sweep.sv
test-sweep:
	python3 scripts/dump_sweep.py $(SWITCH) $(SWLOC) $(SWMIN) $(SWGAP) > sweep_gold.log 2>sweep_sum.txt
	xvlog -sv $(SWSRC)
	xelab -debug typical -L xpm tb_sweep -s tb_sweep_sim
	xsim tb_sweep_sim -runall -testplusarg itch=$(SWITCH) -testplusarg loc=$(SWLOC) \
	     -testplusarg min=$(SWMIN) -testplusarg gap=$(SWGAP)
	diff sweep_gold.log sweep_rtl.log && echo "PASS: sweeps == golden ($(SWITCH) loc=$(SWLOC) min=$(SWMIN))"
	@cat sweep_sum.txt

# ---------- does the imbalance signal predict anything? ----------
# FINDINGS 5.2 fixed the imbalance parameters and said the calibration is not an
# edge; this is the forward-return study that answers the other half. It needs
# the FULL day, not a slice -- the whole finding in 5.2 was that the slice
# everything else uses is pre-market -- so it reads the capture directly through
# the reference parser rather than through a .itch extract.
#
# ITCH_BBO_RAW=1 is the parser's integer BBO mode: ns timestamps and 1e-4 prices,
# because a study over 424k records cannot afford to parse a formatted clock.
STEP1 = ../step1-sw-parser
RCAP ?= ../data/12302019.NASDAQ_ITCH50.gz
IMSYM ?= AAPL

aapl_bbo.txt: $(RCAP)
	$(MAKE) -C $(STEP1) itch_parser
	ITCH_BBO_RAW=1 $(STEP1)/itch_parser $(RCAP) $(IMSYM) > $@

imbalance-edge: aapl_bbo.txt
	python3 scripts/imbalance_edge.py $< $(IMARGS)

clean:
	rm -rf xsim.dir *.log *.jou *.pb *.wdb
	# not aapl_bbo.txt: 40 s of the full capture to rebuild, and nothing else
	# in this directory depends on being able to delete it quickly

# Self-checking, no golden needed: the replay buffer's contract is that a resent
# frame is byte-identical to the original and that a resend never delays a live
# order. Both are checked directly.
test-replay:
	xvlog -sv rtl/tx_replay_buf.sv tb/tb_tx_replay_buf.sv
	xelab -debug typical -L xpm tb_tx_replay_buf -s tb_tx_replay_buf_sim
	xsim tb_tx_replay_buf_sim -runall

# the other half of a retransmission: deciding there was one to make
test-rto:
	xvlog -sv rtl/tx_rto.sv tb/tb_tx_rto.sv
	xelab -debug typical -L xpm tb_tx_rto -s tb_tx_rto_sim
	xsim tb_tx_rto_sim -runall

# the number tx_rto's two constants should have been chosen from, measured in
# hardware off the same two signals tx_rto watches
test-acklat:
	xvlog -sv rtl/ack_latency.sv tb/tb_ack_latency.sv
	xelab -debug typical -L xpm tb_ack_latency -s tb_ack_latency_sim
	xsim tb_ack_latency_sim -runall
