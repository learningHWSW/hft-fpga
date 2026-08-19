include ../mk/xilinx.mk

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
# price_ladder's group-select structure (price_ladder.sv). The BBO sequence is
# identical either way -- the two forms differ only on an empty side, which
# never reaches an output -- so the same golden diff is the check, run twice.
FS ?= 0

test: golden
	$(XSETUP) xvlog -sv $(SRC) $(TB)
	$(XSETUP) xelab -debug typical -L xpm $(TOP) -s $(TOP)_sim -generic_top "FLAT_SCAN=$(FS)"
	$(XSETUP) xsim $(TOP)_sim -runall -testplusarg itch=$(ITCH) -testplusarg loc=$(LOC) -testplusarg base=$(BASE)
	diff bbo_gold.log bbo_rtl.log && echo "PASS: BBO == golden ($(ITCH) loc=$(LOC))"

# II=1 pipelined order table (order_table_pipe) against the SAME golden
# Same golden, same stimulus, the II=1 pipelined table swapped in by -d OT_PIPE.
# xelab takes defines with -d, and they have to reach BOTH steps: xvlog parses
# the `ifdef, xelab elaborates what it selected.
test-pipe: golden
	$(XSETUP) xvlog -sv -d OT_PIPE $(SRC) $(TB)
	$(XSETUP) xelab -debug typical -L xpm -d OT_PIPE $(TOP) -s $(TOP)_pipe_sim
	$(XSETUP) xsim $(TOP)_pipe_sim -runall -testplusarg itch=$(ITCH) -testplusarg loc=$(LOC) -testplusarg base=$(BASE)
	diff bbo_gold.log bbo_rtl.log && echo "PASS: pipe BBO == golden ($(ITCH) loc=$(LOC))"

test-pipe-real:
	$(MAKE) test-pipe ITCH=../step5-board/real.itch LOC=13 BASE=2800000

# alias: the xsim recipe is the only one now.
test-merge: test-merge-xsim

test-merge-xsim:
	$(XSETUP) xvlog -sv rtl/bbo_merge.sv tb/tb_bbo_merge.sv
	$(XSETUP) xelab -debug typical -L xpm tb_bbo_merge -s tb_bbo_merge_sim
	$(XSETUP) xsim tb_bbo_merge_sim -runall

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
	$(MAKE)  ITCH=real.itch LOC=13 BASE=2800000

test-real-xsim: real.itch
	$(MAKE) test ITCH=real.itch LOC=13 BASE=2800000

# the same golden, one-hot group select
test-flat-xsim:
	$(MAKE) test FS=1

test-flat-real-xsim:
	$(MAKE) test-real-xsim FS=1

clean:
	rm -rf xsim.dir *.log *.jou *.pb *.wdb bbo_*.log real.itch

.PHONY: test test-merge test-merge-xsim golden test-real test-real-xsim test-flat-xsim test-flat-real-xsim clean
