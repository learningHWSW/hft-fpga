include ../mk/xilinx.mk

STEP2 = ../step2-rtl-decoder
SRC   = $(STEP2)/rtl/itch5_pkg.sv $(STEP2)/rtl/itch_decoder.sv rtl/mold_stripper.sv
TB    = tb/tb_mold_stripper.sv
TOP   = tb_mold_stripper
MOLD ?= ../step1-sw-parser/test.mold

# ---------- xsim (Vivado/Vitis) — primary; source settings64.sh first ----------
test: golden
	$(XSETUP) xvlog -sv $(SRC) $(TB)
	$(XSETUP) xelab -debug typical $(TOP) -s $(TOP)_sim
	$(XSETUP) xsim $(TOP)_sim -runall -testplusarg mold=$(MOLD)
	diff mold_gold.log mold_rtl.log && echo "PASS: RTL == golden"

golden: $(MOLD)
	python3 scripts/dump_mold.py $(MOLD) > mold_gold.log

$(MOLD):
	cd $(dir $(MOLD)) && python3 gen_itch.py test.itch --mold $(notdir $(MOLD))

clean:
	rm -rf xsim.dir *.log *.jou *.pb *.wdb mold_*.log

.PHONY: test golden clean
