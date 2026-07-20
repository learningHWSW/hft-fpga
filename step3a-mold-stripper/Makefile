STEP2 = ../step2-rtl-decoder
SRC   = $(STEP2)/rtl/itch5_pkg.sv $(STEP2)/rtl/itch_decoder.sv rtl/mold_stripper.sv
TB    = tb/tb_mold_stripper.sv
TOP   = tb_mold_stripper
MOLD ?= ../step1-sw-parser/test.mold

# WSL: Vivado's wrapper forces LC_ALL=en_US.UTF-8; point glibc at the
# user-built locale so xsim doesn't abort. See scripts/setup-xsim-locale.sh.
export LOCPATH := $(HOME)/.locale

# ---------- xsim (Vivado/Vitis) — primary; source settings64.sh first ----------
test: golden
	xvlog -sv $(SRC) $(TB)
	xelab -debug typical $(TOP) -s $(TOP)_sim
	xsim $(TOP)_sim -runall -testplusarg mold=$(MOLD)
	diff mold_gold.log mold_rtl.log && echo "PASS: RTL == golden"

# ---------- verilator (no Vivado needed) ----------
test-verilator: golden
	verilator --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD -j 0 -o tbsim --top-module $(TOP) $(SRC) $(TB)
	./obj_dir/tbsim +mold=$(MOLD)
	diff mold_gold.log mold_rtl.log && echo "PASS: RTL == golden"

golden: $(MOLD)
	python3 scripts/dump_mold.py $(MOLD) > mold_gold.log

$(MOLD):
	cd $(dir $(MOLD)) && python3 gen_itch.py test.itch --mold $(notdir $(MOLD))

clean:
	rm -rf obj_dir xsim.dir *.log *.jou *.pb *.wdb mold_*.log

.PHONY: test test-verilator golden clean
