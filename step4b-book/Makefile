STEP1 = ../step1-sw-parser
STEP2 = ../step2-rtl-decoder
STEP4A = ../step4a-order-table
SRC   = $(STEP2)/rtl/itch5_pkg.sv $(STEP2)/rtl/itch_decoder.sv \
        $(STEP4A)/rtl/otable_mem.sv $(STEP4A)/rtl/order_table.sv $(STEP4A)/rtl/order_table_pipe.sv rtl/price_ladder.sv rtl/fast_bbo.sv \
        ../step5-board/rtl/drop_fifo.sv
TB    = tb/tb_price_ladder.sv
TOP   = tb_price_ladder

# Default: synthetic test.itch, track AAPL (locate 1 in that file, ~$150 band).
ITCH ?= $(STEP1)/test.itch
LOC  ?= 1
BASE ?= 1500000

# ---------- xsim (Vivado 2025.2) — primary; source settings64.sh first ----------
test: golden
	xvlog -sv $(SRC) $(TB)
	xelab -debug typical $(TOP) -s $(TOP)_sim
	xsim $(TOP)_sim -runall -testplusarg itch=$(ITCH) -testplusarg loc=$(LOC) -testplusarg base=$(BASE)
	diff bbo_gold.log bbo_rtl.log && echo "PASS: BBO == golden ($(ITCH) loc=$(LOC))"

# ---------- verilator (no Vivado needed) ----------
test-verilator: golden
	verilator --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -j 0 -o tbsim --top-module $(TOP) $(SRC) $(TB)
	./obj_dir/tbsim +itch=$(ITCH) +loc=$(LOC) +base=$(BASE)
	diff bbo_gold.log bbo_rtl.log && echo "PASS: BBO == golden ($(ITCH) loc=$(LOC))"

# II=1 pipelined order table (order_table_pipe) against the SAME golden
test-pipe: golden
	verilator --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -j 0 -DOT_PIPE -o tbpipe --top-module $(TOP) $(SRC) $(TB)
	./obj_dir/tbpipe +itch=$(ITCH) +loc=$(LOC) +base=$(BASE)
	diff bbo_gold.log bbo_rtl.log && echo "PASS: pipe BBO == golden ($(ITCH) loc=$(LOC))"

test-pipe-real:
	$(MAKE) test-pipe ITCH=../step5-board/real.itch LOC=13 BASE=2800000

golden: $(ITCH)
	python3 scripts/dump_bbo.py $(ITCH) $(LOC) > bbo_gold.log

$(STEP1)/test.itch:
	cd $(STEP1) && python3 gen_itch.py test.itch

# ---- real-data slice (AAPL locate 13) ----
RCAP  ?= ../data/12302019.NASDAQ_ITCH50.gz
RMSGS ?= 5000000
real.itch:
	python3 $(STEP1)/itch_slice.py $(RCAP) real.itch $(RMSGS) AAPL

test-real: real.itch
	$(MAKE) test-verilator ITCH=real.itch LOC=13 BASE=2800000

test-real-xsim: real.itch
	$(MAKE) test ITCH=real.itch LOC=13 BASE=2800000

clean:
	rm -rf obj_dir xsim.dir *.log *.jou *.pb *.wdb bbo_*.log real.itch

.PHONY: test test-verilator golden test-real test-real-xsim clean
