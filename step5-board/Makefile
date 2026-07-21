STEP1  = ../step1-sw-parser
STEP2  = ../step2-rtl-decoder
STEP3B = ../step3b-splitter
STEP4A = ../step4a-order-table
STEP4B = ../step4b-book

SRC = $(STEP2)/rtl/itch5_pkg.sv $(STEP2)/rtl/itch_decoder.sv \
      $(STEP3B)/rtl/mold_splitter.sv $(STEP4A)/rtl/order_table.sv \
      $(STEP4B)/rtl/price_ladder.sv rtl/drop_fifo.sv rtl/fh_core.sv
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
# order-table size for synthesis (production 2^16x8 needs XPM macros, see README)
OT_SETS_BITS ?= 9
OT_WAYS ?= 8
# target period: 3.103 = 322.27 MHz (CMAC box), 4.000 = 250 MHz (QDMA box)
PERIOD ?= 4.000
synth:
	vivado -mode batch -nojournal -nolog -notrace -source syn/synth_ooc.tcl -tclargs $(PART) synth $(OT_SETS_BITS) $(OT_WAYS) $(PERIOD)
impl:
	vivado -mode batch -nojournal -nolog -notrace -source syn/synth_ooc.tcl -tclargs $(PART) impl $(OT_SETS_BITS) $(OT_WAYS) $(PERIOD)

clean:
	rm -rf obj_dir xsim.dir *.log *.jou *.pb *.wdb bbo_*.log real.itch real.mold syn/out

.PHONY: test test-verilator golden test-real stress synth impl clean

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
