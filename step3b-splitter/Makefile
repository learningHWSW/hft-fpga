STEP1 = ../step1-sw-parser
STEP2 = ../step2-rtl-decoder
STEP3A = ../step3a-mold-stripper
SRC   = $(STEP2)/rtl/itch5_pkg.sv $(STEP2)/rtl/itch_decoder.sv rtl/mold_splitter.sv
TB    = tb/tb_mold_splitter.sv
TOP   = tb_mold_splitter
GOLD  = $(STEP3A)/scripts/dump_mold.py

# Default stimulus: the synthetic mold from step 1 (has gap+dup+hb+eos).
# Real-data run:  make test-real  (or REAL=1 and set MOLD/RMSGS)
MOLD  ?= $(STEP1)/test.mold

# WSL: point glibc at the user-built locale so xsim doesn't abort.
export LOCPATH := $(HOME)/.locale

# ---------- xsim (Vivado 2025.2) — primary; source settings64.sh first ----------
test: golden
	xvlog -sv $(SRC) $(TB)
	xelab -debug typical $(TOP) -s $(TOP)_sim
	xsim $(TOP)_sim -runall -testplusarg mold=$(MOLD)
	diff splitter_gold.log splitter_rtl.log && echo "PASS: RTL == golden ($(MOLD))"

# ---------- verilator (no Vivado needed) ----------
test-verilator: golden
	verilator --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -j 0 -o tbsim --top-module $(TOP) $(SRC) $(TB)
	./obj_dir/tbsim +mold=$(MOLD)
	diff splitter_gold.log splitter_rtl.log && echo "PASS: RTL == golden ($(MOLD))"

golden: $(MOLD)
	python3 $(GOLD) $(MOLD) > splitter_gold.log

$(STEP1)/test.mold:
	cd $(STEP1) && python3 gen_itch.py test.itch --mold test.mold

# ---- real-data replay (first RMSGS messages of the NASDAQ capture) ----
RCAP   ?= ../data/12302019.NASDAQ_ITCH50.gz
RMSGS  ?= 1000000
real.mold:
	python3 $(STEP1)/itch2mold.py $(RCAP) real.mold $(RMSGS)

test-real:
	$(MAKE) test-verilator MOLD=real.mold

test-real-xsim:
	$(MAKE) test MOLD=real.mold

clean:
	rm -rf obj_dir xsim.dir *.log *.jou *.pb *.wdb splitter_*.log real*.mold *.out

.PHONY: test test-verilator golden test-real test-real-xsim clean
