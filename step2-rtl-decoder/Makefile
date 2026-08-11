SRC  = rtl/itch5_pkg.sv rtl/itch_decoder.sv
TB   = tb/tb_itch_decoder.sv
TOP  = tb_itch_decoder
ITCH ?= ../step1-sw-parser/test.itch

# ---------- xsim (Vivado/Vitis) — primary; source settings64.sh first ----------
test: golden
	xvlog -sv $(SRC) $(TB)
	xelab -debug typical $(TOP) -s $(TOP)_sim
	xsim $(TOP)_sim -runall -testplusarg itch=$(ITCH)
	diff decode_gold.log decode_rtl.log && echo "PASS: RTL == golden"

golden: $(ITCH)
	python3 scripts/dump_itch.py $(ITCH) > decode_gold.log

$(ITCH):
	$(MAKE) -C $(dir $(ITCH)) test

clean:
	rm -rf xsim.dir *.log *.jou *.pb *.wdb decode_*.log

.PHONY: test golden clean
