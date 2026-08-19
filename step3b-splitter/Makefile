include ../mk/xilinx.mk

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

# ---------- xsim (Vivado 2025.2) — primary; source settings64.sh first ----------
# CUT_THROUGH decodes the beat combinationally instead of the cycle after it
# (itch_decoder.sv). It is the DEFAULT now, so this tracks the RTL default
# rather than contradicting it -- a Makefile that passed CUT_THROUGH=0 into a
# design whose default is 1 would test the path that does not ship. The golden
# must not move either way -- only when it is produced -- so the same diff is
# the check, and the TB additionally asserts the decode latency is the cycle
# count the parameter claims. Without that second check a generic that failed
# to apply would pass this target silently.
CT ?= 1

test: golden
	$(XSETUP) xvlog -sv $(SRC) $(TB)
	$(XSETUP) xelab -debug typical $(TOP) -s $(TOP)_sim -generic_top "CUT_THROUGH=$(CT)"
	$(XSETUP) xsim $(TOP)_sim -runall -testplusarg mold=$(MOLD)
	diff splitter_gold.log splitter_rtl.log && echo "PASS: RTL == golden ($(MOLD), CUT_THROUGH=$(CT))"

# Explicit, for when the default is what is in question.
test-ct-xsim:
	$(MAKE) test CT=1

test-ct-real-xsim:
	$(MAKE) test CT=1 MOLD=real.mold

# The store-then-decode path, which is still the only one that can work when a
# message spans beats. Not dead code: it is what steps 2 and 3a run at 64 bits,
# and the same golden has to come out of it.
test-noct-xsim:
	$(MAKE) test CT=0

test-noct-real-xsim:
	$(MAKE) test CT=0 MOLD=real.mold

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
	$(MAKE)  MOLD=real.mold

test-real-xsim:
	$(MAKE) test MOLD=real.mold

clean:
	rm -rf xsim.dir *.log *.jou *.pb *.wdb splitter_*.log real*.mold *.out

.PHONY: test golden test-real test-real-xsim test-ct-xsim test-ct-real-xsim test-noct-xsim test-noct-real-xsim clean
