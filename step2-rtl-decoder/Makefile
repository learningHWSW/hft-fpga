SRC  = rtl/itch5_pkg.sv rtl/itch_decoder.sv
TB   = tb/tb_itch_decoder.sv
TOP  = tb_itch_decoder
ITCH ?= ../step1-sw-parser/test.itch

# WSL: Vivado's wrapper forces LC_ALL=en_US.UTF-8; point glibc at the
# user-built locale so xsim doesn't abort. See scripts/setup-xsim-locale.sh.
export LOCPATH := $(HOME)/.locale

# ---------- xsim (Vivado/Vitis) — primary; source settings64.sh first ----------
test: golden
	xvlog -sv $(SRC) $(TB)
	xelab -debug typical $(TOP) -s $(TOP)_sim
	xsim $(TOP)_sim -runall -testplusarg itch=$(ITCH)
	diff decode_gold.log decode_rtl.log && echo "PASS: RTL == golden"

# ---------- verilator (no Vivado needed) ----------
test-verilator: golden
	verilator --binary --timing --timescale 1ns/1ps -Wno-TIMESCALEMOD -j 0 -o tbsim --top-module $(TOP) $(SRC) $(TB)
	./obj_dir/tbsim +itch=$(ITCH)
	diff decode_gold.log decode_rtl.log && echo "PASS: RTL == golden"

golden: $(ITCH)
	python3 scripts/dump_itch.py $(ITCH) > decode_gold.log

$(ITCH):
	$(MAKE) -C $(dir $(ITCH)) test

clean:
	rm -rf obj_dir xsim.dir *.log *.jou *.pb *.wdb decode_*.log

.PHONY: test test-verilator golden clean
