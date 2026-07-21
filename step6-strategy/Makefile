# Step 6 — strategy trigger + risk gate.
#
# Stimulus is a BBO log, which is what step 4b emits, so this stage is tested
# on its own rather than through the whole chain: a mismatch here is a rule or
# risk-gate bug, never a book bug.
#
# LOCPATH: Vivado's rdiArgs.sh hardcodes LC_ALL=en_US.UTF-8, which this WSL
# image does not ship; scripts/setup-xsim-locale.sh builds it rootless.
export LOCPATH := $(HOME)/.locale

STEP4B = ../step4b-book
STEP5  = ../step5-board

ITCH ?= $(STEP5)/real.itch
LOC  ?= 13

VSRC = rtl/strategy.sv rtl/ouch_builder.sv rtl/tcp_tx.sv tb/tb_strategy.sv
VFLAGS = --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD \
         -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -j 0

.PHONY: test test-xsim check-frames clean

# bbo_in.log is the shared stimulus: the golden reads it, and so does the RTL
bbo_in.log:
	python3 $(STEP4B)/scripts/dump_bbo.py $(ITCH) $(LOC) > bbo_in.log

test: bbo_in.log
	python3 scripts/dump_orders.py bbo_in.log > orders_gold.log
	verilator $(VFLAGS) -o stratsim --top-module tb_strategy $(VSRC)
	./obj_dir/stratsim +bbo=bbo_in.log +out=orders_rtl.log +pkt=ouch_rtl.log +frm=frames_rtl.log
	diff orders_gold.log orders_rtl.log && echo "PASS: orders == golden ($(ITCH) loc=$(LOC))"
	python3 scripts/dump_ouch.py orders_gold.log > ouch_gold.log
	diff ouch_gold.log ouch_rtl.log && echo "PASS: OUCH packets == golden"
	python3 scripts/dump_tcp.py ouch_gold.log > frames_gold.log
	diff frames_gold.log frames_rtl.log && echo "PASS: TCP frames == golden"
	python3 scripts/check_frames.py frames_rtl.log

test-xsim: bbo_in.log
	python3 scripts/dump_orders.py bbo_in.log > orders_gold.log
	xvlog -sv $(VSRC)
	xelab -debug typical tb_strategy -s tb_strategy_sim
	xsim tb_strategy_sim -testplusarg bbo=bbo_in.log -testplusarg out=orders_rtl.log -testplusarg pkt=ouch_rtl.log -testplusarg frm=frames_rtl.log -runall
	diff orders_gold.log orders_rtl.log && echo "PASS: orders == golden (xsim)"
	python3 scripts/dump_ouch.py orders_gold.log > ouch_gold.log
	diff ouch_gold.log ouch_rtl.log && echo "PASS: OUCH packets == golden (xsim)"

# independent re-derivation of the checksums; skips if scapy is absent
check-frames:
	python3 scripts/check_frames.py frames_rtl.log

clean:
	rm -rf obj_dir xsim.dir *.log *.jou *.pb *.wdb
