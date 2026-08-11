STEP1 = ../step1-sw-parser
STEP2 = ../step2-rtl-decoder
SRC   = $(STEP2)/rtl/itch5_pkg.sv $(STEP2)/rtl/itch_decoder.sv rtl/otable_mem.sv rtl/order_table.sv
TB    = tb/tb_order_table.sv
TOP   = tb_order_table

# Default: synthetic test.itch, track AAPL (locate 1 in that file).
ITCH ?= $(STEP1)/test.itch
LOC  ?= 1

# ---------- xsim (Vivado 2025.2) — primary; source settings64.sh first ----------
test: golden
	xvlog -sv $(SRC) $(TB)
	xelab -debug typical $(TOP) -s $(TOP)_sim
	xsim $(TOP)_sim -runall -testplusarg itch=$(ITCH) -testplusarg loc=$(LOC)
	diff book_gold.log book_rtl.log && echo "PASS: RTL == golden ($(ITCH) loc=$(LOC))"

# ---------- verilator (no Vivado needed) ----------
test-verilator: golden
	verilator --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -j 0 -o tbsim --top-module $(TOP) $(SRC) $(TB)
	./obj_dir/tbsim +itch=$(ITCH) +loc=$(LOC)
	diff book_gold.log book_rtl.log && echo "PASS: RTL == golden ($(ITCH) loc=$(LOC))"

golden: $(ITCH)
	python3 scripts/dump_book.py $(ITCH) $(LOC) > book_gold.log

# ---------- two symbols in one table ----------
# The multi-symbol design point (FINDINGS 4.4). What it proves is not capacity --
# that was measured over the full day -- but that a delta still knows which book
# it belongs to once the entry stores a symbol INDEX instead of a locate. A
# delete carries no locate of its own, so getting this wrong sends AAPL's cancel
# to AMZN's ladder and the diff below is the only thing that would say so.
LOC2 ?= 2
test-multi:
	python3 scripts/dump_book.py $(ITCH) $(LOC),$(LOC2) > book_gold.log
	xvlog -sv -d TB_NSYM=2 $(SRC) $(TB)
	xelab -debug typical $(TOP) -s $(TOP)_msim
	xsim $(TOP)_msim -runall -testplusarg itch=$(ITCH) -testplusarg loc=$(LOC) \
	     -testplusarg loc2=$(LOC2)
	diff book_gold.log book_rtl.log \
	  && echo "PASS: two symbols in one table == golden (loc=$(LOC),$(LOC2))"

$(STEP1)/test.itch:
	cd $(STEP1) && python3 gen_itch.py test.itch

# ---- real-data slice (first RMSGS messages, tracking AAPL locate 13) ----
RCAP  ?= ../data/12302019.NASDAQ_ITCH50.gz
RMSGS ?= 500000
real.itch:
	python3 $(STEP1)/itch_slice.py $(RCAP) real.itch $(RMSGS) AAPL

test-real: real.itch
	$(MAKE) test-verilator ITCH=real.itch LOC=13

test-real-xsim: real.itch
	$(MAKE) test ITCH=real.itch LOC=13

clean:
	rm -rf obj_dir xsim.dir *.log *.jou *.pb *.wdb book_*.log real.itch

.PHONY: test test-verilator test-multi golden test-real test-real-xsim clean
