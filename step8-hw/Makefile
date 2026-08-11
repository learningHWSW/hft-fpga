STEP1  = ../step1-sw-parser
STEP2  = ../step2-rtl-decoder
STEP3B = ../step3b-splitter
STEP4A = ../step4a-order-table
STEP4B = ../step4b-book
STEP5  = ../step5-board
STEP6  = ../step6-strategy

# the verified datapath, plus the three blocks this step adds
DPSRC = $(STEP2)/rtl/itch5_pkg.sv $(STEP2)/rtl/itch_decoder.sv \
        $(STEP3B)/rtl/mold_splitter.sv \
        $(STEP4A)/rtl/otable_mem.sv $(STEP4A)/rtl/order_table.sv \
        $(STEP4A)/rtl/order_table_pipe.sv \
        $(STEP4B)/rtl/price_ladder.sv $(STEP4B)/rtl/fast_bbo.sv $(STEP4B)/rtl/bbo_merge.sv $(STEP4B)/rtl/bbo_arb.sv \
        $(STEP5)/rtl/drop_fifo.sv $(STEP5)/rtl/fh_core.sv \
        $(STEP5)/rtl/eth_ip_udp_rx.sv $(STEP5)/rtl/cdc_fifo.sv \
        $(STEP6)/rtl/strategy.sv $(STEP6)/rtl/sweep_detect.sv \
        $(STEP6)/rtl/ouch_builder.sv $(STEP6)/rtl/tcp_tx.sv $(STEP6)/rtl/tx_replay_buf.sv $(STEP6)/rtl/tx_rto.sv \
        $(STEP5)/rtl/feed_ab_arb.sv $(STEP5)/rtl/igmp_query_detect.sv \
        $(STEP5)/rtl/tcp_rx.sv $(STEP5)/rtl/t2t_top.sv $(STEP5)/rtl/axil_regfile.sv \
        $(STEP5)/rtl/cfg_cdc.sv $(STEP5)/rtl/axis_tx_arb.sv \
        $(STEP5)/rtl/igmp_join.sv $(STEP5)/rtl/arp_responder.sv \
        $(STEP5)/rtl/t2t_axil.sv

SRC = $(DPSRC) rtl/eth_replay.sv rtl/eth_capture.sv rtl/lat_probe.sv rtl/lat_loaded.sv rtl/t2t_kernel.sv
TB  = tb/tb_t2t_kernel.sv
TOP = tb_t2t_kernel

# Phase B: the same datapath behind a real cmac_usplus with the GT in near-end
# loopback. SRC_B adds the blocks the MAC needs around it -- see rtl/cmac_wrap.sv
# for why the IP itself is stubbed in simulation and validated on the card.
SRC_B = $(DPSRC) rtl/eth_replay.sv rtl/eth_capture.sv rtl/lat_probe.sv \
        rtl/lat_loaded.sv rtl/axis_sf_fifo.sv rtl/axis_frame_filter.sv \
        rtl/cmac_wrap.sv rtl/t2t_kernel_b.sv
TOP_B = tb_t2t_kernel_b
DEFS_B = -d PHASE_B -d CMAC_SIM

# Stimulus. The synthetic feed is the default because it needs no download and
# still fires orders (4 of them); the real replay needs the NASDAQ capture in
# data/ and is selected with `make test-real`.
ITCH ?= $(STEP1)/test.itch
ETH  ?= $(STEP1)/test.eth
LOC  ?= 1
BASE ?= 1500000
GAP  ?= 48
RECS ?= 2048
QUIET ?= 256

# THE IMAGE IS NAMED AFTER ITS STIMULUS, and that is the whole fix for a trap
# that cost real debugging time. It used to be plain `replay.bin` for every
# stimulus, so switching ETH -- which is exactly what `make test-real` does --
# left the previous image in place whenever it happened to be newer than the
# .eth file. make saw an up-to-date target, xsim replayed the OLD stimulus, and
# `golden` regenerated for the NEW one: a 70-line-against-4-line diff that reads
# like a datapath regression and is nothing of the kind. A derived name cannot go
# stale, because a different stimulus is a different target.
REPLAY = replay-$(basename $(notdir $(ETH))).bin

# The testbench's replay memory model, mirrored from tb_t2t_kernel.sv
# (RMEM_BYTES). Packing checks it so an oversized image fails in seconds with a
# number, rather than after minutes of work inside xsim -- which is what the full
# 5 M replay used to do, since it packs to 327 MB.
TB_MAX_BYTES ?= 8388608

# The real feed, cut to a size simulation can hold. The count is part of the file
# name (step5-board builds it with a pattern rule), so asking for a different one
# builds a different slice instead of reusing the last.
RSMALL      ?= 100000
RSMALL_ITCH  = $(STEP5)/realsmall-$(RSMALL).itch
RSMALL_ETH   = $(STEP5)/realsmall-$(RSMALL).eth
# A gap of 512 idle cycles per frame is ten times the simulation time per
# frame, so the latency targets take a shorter slice than the throughput ones.
RSMALL_LAT  ?= 20000

# strategy knobs, identical to the step 5/6 golden invocations
ORDARGS = 2000 1 100 100 1000 65535 50

# ---------- Xilinx environment, sourced on demand ----------
# Every target below needs vivado/v++/xvlog on PATH, and forgetting to source
# settings64.sh first fails in a way that reads like a broken Makefile
# ("v++: command not found") rather than a missing environment. So each recipe
# that uses a Xilinx tool sources it ITSELF.
#
# Vivado's settings64.sh also sources Vitis's, so this one script provides
# vivado, v++ and xvlog together. Override for another install:
#   make xclbin-b XILINX_SETTINGS=/opt/Xilinx/2024.2/Vivado/settings64.sh
# Set it empty to use whatever is already on PATH.
XILINX_SETTINGS ?= /opt/Xilinx/2025.2.1/Vivado/settings64.sh

# bash, NOT the default /bin/sh. settings64.sh uses `source` internally, which is
# a bashism: under dash it dies with "source: not found", rc=127. That failure is
# silent if anything else is on PATH -- and on this machine ~/.bashrc puts Vitis
# 2023.2 there, so make happily built with 2023.2 instead of the 2025.2.1 this
# project is verified against. A wrong-version build that SUCCEEDS is worse than
# one that fails, so this pins the shell and the settings failure is now fatal
# rather than a silent fallback.
#
# EVERY recipe that runs a Xilinx tool must go through $(XSETUP), and the two
# v++ link steps did not. The halves of a bitstream build then came from
# different installs: package_kernel*.tcl ran under 2025.2.1 while v++ came off
# PATH at 2023.2, and the link died with "The XO file was created in version
# 2025.2, which is later than the software version you are currently running".
# That failure is at least loud. The dangerous order is the other one -- an
# older .xo linked by a NEWER v++ is accepted, and the build succeeds against a
# toolchain the project was never verified on.
#
# `make which-tools` did not catch this and could not have: it reports the tools
# XSETUP provides, which is precisely what the link was not using. It describes
# the recipes again now that the recipes agree with it.
SHELL := /bin/bash

XSETUP = { if [ -n "$(XILINX_SETTINGS)" ]; then \
             [ -r "$(XILINX_SETTINGS)" ] || { echo "ERROR: XILINX_SETTINGS=$(XILINX_SETTINGS) is not readable."; exit 1; }; \
             . "$(XILINX_SETTINGS)" >/dev/null || { echo "ERROR: sourcing $(XILINX_SETTINGS) failed."; exit 1; }; \
           fi; \
           command -v v++ >/dev/null 2>&1 \
           || { echo "ERROR: no Xilinx tools on PATH. Point XILINX_SETTINGS at a settings64.sh."; exit 1; }; } &&

PART ?= xcu55c-fsvh2892-2L-e
XPFM ?= /opt/xilinx/platforms/xilinx_u55c_gen3x16_xdma_3_202210_1/xilinx_u55c_gen3x16_xdma_3_202210_1.xpfm

.PHONY: help which-tools test-latprobe test test-xsim test-session test-b-session test-rto test-latency test-gap-independent test-real test-real-latency \
        test-b test-b-latency test-b-real test-sffifo cmac gate-license xo-b xclbin-b run-card-b run-card-b-latency \
        golden clean clean-build distclean real-image run-card-real run-card-b-real elab synth xo xclbin host run-card run-card-latency card-info

# alias: the xsim recipe is the only one now.
test: test-xsim  ## Simulate|full chain HBM->HBM, diffed against golden

test-xsim: golden $(REPLAY) ## Simulate|same, in xsim -- the flow that works where the card is
	@$(XSETUP) xvlog -sv $(SRC) $(TB)
	@$(XSETUP) xelab -debug typical $(TOP) -s $(TOP)_sim
	@$(XSETUP) xsim $(TOP)_sim -runall -testplusarg eth=$(REPLAY) -testplusarg cap=capture.bin \
	  -testplusarg gap=$(GAP) -testplusarg loc=$(LOC) -testplusarg base=$(BASE) -testplusarg quiet=$(QUIET)
	python3 scripts/pack_eth.py unpack capture.bin $(RECS) > k_rtl.log
	diff k_gold.log k_rtl.log && echo "PASS: kernel HBM->HBM order frames == golden"

# ---------- the order session's inbound half ----------
# Everything else the card receives is market data. This appends the venue's own
# frames -- TCP, addressed to the card, carrying SoupBinTCP-framed OUCH replies --
# to the feed stimulus, and checks the two things that can break:
#
#   1. the orders are UNCHANGED. Inbound traffic advances tcp_rx's rcv_nxt, which
#      is the acknowledgement number tcp_tx puts on the wire, so a reply that
#      lands mid-flow would legitimately change every order after it. The replies
#      are appended AFTER the feed for exactly that reason, and this diff is what
#      proves they did not overtake it.
#   2. the replies come back out of host memory intact, in order, and decode to
#      the messages that went in -- through the same capture image and the same
#      parser the card run uses.
#
# The image has its own name rather than reusing replay.bin: same stimulus file,
# different contents, and make cannot tell those apart by timestamp.
CARD_IP ?= 10.0.0.2
SESS_N  ?= 4
test-session: golden ## Simulate|the venue's replies: RX -> capture -> host OUCH decode
	python3 scripts/gen_session.py --count $(SESS_N) --eth session.eth --golden s_gold.log
	cat $(ETH) session.eth > session_stim.eth
	python3 scripts/pack_eth.py pack session_stim.eth session_replay.bin
	@$(XSETUP) xvlog -sv $(SRC) $(TB)
	@$(XSETUP) xelab -debug typical $(TOP) -s $(TOP)_sim
	@$(XSETUP) xsim $(TOP)_sim -runall -testplusarg eth=session_replay.bin \
	  -testplusarg cap=session_capture.bin \
	  -testplusarg gap=$(GAP) -testplusarg loc=$(LOC) -testplusarg base=$(BASE) \
	  -testplusarg quiet=$(QUIET)
	python3 scripts/pack_eth.py unpack session_capture.bin $(RECS) $(CARD_IP) > ks_rtl.log
	diff k_gold.log ks_rtl.log \
	  && echo "PASS: order frames unchanged by inbound session traffic"
	python3 scripts/dump_session.py session_capture.bin $(RECS) --local-ip $(CARD_IP) > s_rtl.log
	diff s_gold.log s_rtl.log \
	  && echo "PASS: the venue's OUCH replies == golden, decoded from the capture"

# ---------- automatic retransmission, in the chain ----------
# tx_rto's own testbench proves the decision; this proves the wiring, which is
# the half a unit test cannot reach: detector -> tx_replay_buf -> the wire.
#
# The session stimulus is what makes it possible. tx_rto arms only once peer_ack
# has moved, so it needs the venue's frames to exist -- and those frames
# acknowledge nothing the card sent, which is exactly the shape of a loss. With a
# short timeout the card notices and re-sends by itself.
#
# The order golden is NOT the check here, because a retransmission legitimately
# adds frames to the capture. check_resend.py holds the stronger property: the
# originals are unchanged and in order, and every extra frame is byte-identical
# to one of them -- same sequence number, same OUCH token, which is what makes
# the venue discard it rather than fill it twice.
RTO_CYCLES ?= 2000
test-rto: golden ## Simulate|the card notices an unacknowledged order and re-sends it
	python3 scripts/gen_session.py --count 1 --eth session.eth --golden s_gold.log
	cat $(ETH) session.eth > session_stim.eth
	python3 scripts/pack_eth.py pack session_stim.eth session_replay.bin
	@$(XSETUP) xvlog -sv $(SRC) $(TB)
	@$(XSETUP) xelab -debug typical $(TOP) -s $(TOP)_sim
	@$(XSETUP) xsim $(TOP)_sim -runall -testplusarg eth=session_replay.bin \
	  -testplusarg cap=session_capture.bin -testplusarg rto=$(RTO_CYCLES) \
	  -testplusarg gap=$(GAP) -testplusarg loc=$(LOC) -testplusarg base=$(BASE) \
	  -testplusarg quiet=$(QUIET)
	python3 scripts/pack_eth.py unpack session_capture.bin $(RECS) $(CARD_IP) > kr_rtl.log
	python3 scripts/check_resend.py k_gold.log kr_rtl.log 1

# Latency measurement run. The probe only accepts a sample whose frame arrived
# into a provably empty pipeline, so the injector gap must exceed the quiet
# window -- see rtl/lat_probe.sv for why that is what makes the number
# attributable without threading a tag through the datapath.
# Uses the GAP-FREE stimulus. The default test.mold injects a sequence gap and a
# duplicate, and feed_ab_arb recovers gaps on a timeout, so which messages reach
# the book depends on the injector spacing -- measured on the card, the default
# stimulus matches the golden at gap 48 and yields 6 orders instead of 4 at gap
# 512. A latency run exists precisely to change the gap, so it must not use a
# stimulus whose correct answer moves with it.
test-latency: $(STEP1)/test_clean.eth ## Simulate|unloaded latency probe, gap 512, gap-free stimulus
	$(MAKE) test-xsim GAP=512 QUIET=$(QUIET) \
	  ITCH=$(STEP1)/test_clean.itch ETH=$(STEP1)/test_clean.eth

# The proof that it worked: the same stimulus must give the same golden-identical
# frames at two very different gaps.
test-gap-independent: $(STEP1)/test_clean.eth ## Simulate|golden must hold at gap 48 AND 512
	$(MAKE) test-xsim GAP=48  QUIET=$(QUIET) ITCH=$(STEP1)/test_clean.itch ETH=$(STEP1)/test_clean.eth
	$(MAKE) test-xsim GAP=512 QUIET=$(QUIET) ITCH=$(STEP1)/test_clean.itch ETH=$(STEP1)/test_clean.eth
	@echo "PASS: golden holds at gap 48 AND gap 512 (stimulus is gap-independent)"

$(STEP1)/test_clean.itch $(STEP1)/test_clean.eth:
	cd $(STEP1) && python3 gen_itch.py test_clean.itch --mold test_clean.mold --clean
	cd $(STEP1) && python3 mold2eth.py test_clean.mold test_clean.eth

# ---------- Phase B in simulation ----------
# The claim: putting the streams through a MAC, an arbiter, two store-and-forward
# FIFOs and a protocol filter leaves the order frames BYTE-IDENTICAL. So this
# diffs against exactly the same golden as `test-xsim`, which is what makes the
# comparison worth running -- a Phase B golden of its own would prove nothing.
test-b: golden $(REPLAY) ## Simulate|Phase B: the same golden, through the MAC model
	@$(XSETUP) xvlog -sv $(DEFS_B) $(SRC_B) $(TB)
	@$(XSETUP) xelab -debug typical -L xpm $(TOP_B) -s $(TOP_B)_sim
	@$(XSETUP) xsim $(TOP_B)_sim -runall -testplusarg eth=$(REPLAY) -testplusarg cap=capture.bin \
	  -testplusarg gap=$(GAP) -testplusarg loc=$(LOC) -testplusarg base=$(BASE) -testplusarg quiet=$(QUIET)
	python3 scripts/pack_eth.py unpack capture.bin $(RECS) > kb_rtl.log
	diff k_gold.log kb_rtl.log && echo "PASS: Phase B (through the MAC) order frames == golden"

# The same session test, through the MAC. Phase B needs no capture merge at all:
# the GT loopback puts everything transmitted back on RX, the capture filter
# already takes every TCP frame off that stream, and the venue's replies are TCP.
# So this exercises the inbound path over a route the Phase A test cannot -- the
# frames go out through the MAC, come back through PCS and SerDes, and are
# reassembled from the capture by the same parser.
test-b-session: golden ## Simulate|Phase B: the venue's replies, through the MAC
	python3 scripts/gen_session.py --count $(SESS_N) --eth session.eth --golden s_gold.log
	cat $(ETH) session.eth > session_stim.eth
	python3 scripts/pack_eth.py pack session_stim.eth session_replay.bin
	@$(XSETUP) xvlog -sv $(DEFS_B) $(SRC_B) $(TB)
	@$(XSETUP) xelab -debug typical -L xpm $(TOP_B) -s $(TOP_B)_sim
	@$(XSETUP) xsim $(TOP_B)_sim -runall -testplusarg eth=session_replay.bin \
	  -testplusarg cap=session_capture.bin \
	  -testplusarg gap=$(GAP) -testplusarg loc=$(LOC) -testplusarg base=$(BASE) \
	  -testplusarg quiet=$(QUIET)
	python3 scripts/pack_eth.py unpack session_capture.bin $(RECS) $(CARD_IP) > ksb_rtl.log
	diff k_gold.log ksb_rtl.log \
	  && echo "PASS: Phase B order frames unchanged by inbound session traffic"
	python3 scripts/dump_session.py session_capture.bin $(RECS) --local-ip $(CARD_IP) > sb_rtl.log
	diff s_gold.log sb_rtl.log \
	  && echo "PASS: Phase B OUCH replies == golden, decoded from the capture"

test-b-latency: ## Simulate|Phase B at gap 512
	$(MAKE) test-b GAP=512 QUIET=$(QUIET)

test-b-real: ## Simulate|Phase B on the real feed, bounded like test-real
	$(MAKE) -C $(STEP5) realsmall-$(RSMALL_LAT).eth realsmall-$(RSMALL_LAT).itch
	$(MAKE) test-b ITCH=$(STEP5)/realsmall-$(RSMALL_LAT).itch \
	  ETH=$(STEP5)/realsmall-$(RSMALL_LAT).eth \
	  LOC=13 BASE=2800000 RECS=8192 GAP=512

# Real-data replay: needs data/12302019.NASDAQ_ITCH50.gz (see top-level README).
# xsim: the only simulator this project uses,
# and a target that silently needs it is a target that does not run where it
# matters.
# The full 5 M replay packs to 327 MB and the testbench's memory model holds 8,
# so this runs the largest prefix of the same real feed that simulation can
# actually hold. It used to point at the full image and fail every time -- after
# minutes of packing -- which is the other half of the stale-image trap: a target
# that cannot work is worse than one that is missing.
#
# What it covers is the feed path on real data. Orders are rare enough in this
# feed that a prefix this size fires none, so the golden is usually empty and the
# diff is not the interesting part -- the counters the testbench checks are
# (frames in/kept, zero drops, zero overflow). The order count is printed so
# nobody reads an empty diff as coverage. For orders on real data, the card:
# `make run-card-real`.
test-real: ## Simulate|real feed, bounded to what the memory model holds
	$(MAKE) -C $(STEP5) realsmall-$(RSMALL).eth realsmall-$(RSMALL).itch
	$(MAKE) test-xsim ITCH=$(RSMALL_ITCH) ETH=$(RSMALL_ETH) \
	  LOC=13 BASE=2800000 RECS=8192
	@echo "test-real: golden holds $$(grep -c . k_gold.log) order frame(s);" \
	      "orders are rare this early in the feed -- the full replay is a card run"

# ---------- the real-data replay image, for CARD runs ----------
# Simulation packs $(ETH) into replay.bin through the generic rule above. The
# card wants the same thing built once from the real feed and kept, because
# packing 222 MB is not something to redo per run -- and because the slice it
# comes from is a long pipeline over the 7.7 GB full-day capture:
#
#   data/12302019.NASDAQ_ITCH50.gz          the free NASDAQ TotalView-ITCH day
#     -> itch_slice.py  (5 M msgs, AAPL)    real.itch
#     -> itch2mold.py                       real.mold   MoldUDP64, CONTIGUOUS
#     -> mold2eth.py                        real.eth    Ethernet/IPv4/UDP
#     -> pack_eth.py pack                   real_replay.bin  64-B aligned records
#
# The contiguous part matters: itch2mold emits unbroken sequences, so this image
# has gap=0, feed_ab_arb's recovery timeout never fires, and the golden diff holds
# at ANY injector gap. That is what makes a latency run from this image both
# attributable and golden-verified, unlike the synthetic feed which deliberately
# carries a sequence gap and a duplicate.
#
# 1,127,057 frames / 5,110,000 beats / 312 MB. Kept by clean and clean-build;
# only distclean removes it, and it asks first.
real_replay.bin: $(STEP5)/real.eth scripts/pack_eth.py
	python3 scripts/pack_eth.py pack $(STEP5)/real.eth $@

# Both of these live in step 5 and are delegated, not duplicated. real.itch is
# needed as well as real.eth: the golden is computed from the ITCH messages, the
# replay image from the Ethernet frames, and they are different files. Cleaning
# step 5 can leave real.eth behind while removing the real.itch it came from,
# which is exactly the state that broke `make run-card-b-real` with
# "No rule to make target '../step5-board/real.itch'".
$(STEP5)/real.eth:
	$(MAKE) -C $(STEP5) real.eth

$(STEP5)/real.itch:
	$(MAKE) -C $(STEP5) real.itch

# The golden for the real slice, which the card runs diff against. Depends on the
# .itch, not the .eth -- dump_bbo.py reads messages, not frames.
real_gold.log: $(STEP5)/real.itch
	$(MAKE) golden ITCH=$(STEP5)/real.itch LOC=13 GPFX=real

# ---------- the card, on real data ----------
# The runs the measured numbers in README.md come from. GAP=512 spaces the
# injector wide enough for lat_probe to attribute samples; lower it to sweep
# offered load (the knee is between GAP=24 and GAP=16).
RGAP ?= 512
run-card-real: host/t2t_run real_replay.bin real_gold.log ## Card|Phase A, real 5M AAPL   [RGAP=512]
	$(call need_xclbin,t2t.xclbin,xclbin,1 h 10 m)
	./host/t2t_run --xclbin t2t.xclbin --replay real_replay.bin \
	  --capture real_capture.bin --device $(BDF) --gap $(RGAP) \
	  --loc 13 --base 2800000 --records 8192 --quiet 256 \
	  --clk-mhz $(shell echo $(AP_CLK) | awk '{print $$1/1000000}') \
	  --core-mhz $(shell echo $(CORE_CLK) | awk '{print $$1/1000000}')
	python3 scripts/pack_eth.py unpack real_capture.bin 8192 $(CARD_IP) > real_hw.log
	diff real_gold.log real_hw.log && echo "PASS: ON CARD, real 5M AAPL == golden"
	@python3 scripts/dump_session.py real_capture.bin 8192 --local-ip $(CARD_IP) || true

# Phase B: the same replay through the real MAC. Wire cycles are counted at the
# CMAC's clock, not ap_clk, so the host has to be told which one the probe used.
run-card-b-real: host/t2t_run real_replay.bin real_gold.log ## Card|Phase B, real 5M AAPL, through the MAC  [RGAP=512]
	$(call need_xclbin,t2t_b.xclbin,xclbin-b,1 h 15 m)
	./host/t2t_run --xclbin t2t_b.xclbin --replay real_replay.bin \
	  --capture real_capture.bin --device $(BDF) --gap $(RGAP) \
	  --loc 13 --base 2800000 --records 8192 --quiet 256 \
	  --clk-mhz 322.265625 \
	  --core-mhz $(shell echo $(CORE_CLK_B) | awk '{print $$1/1000000}')
	python3 scripts/pack_eth.py unpack real_capture.bin 8192 $(CARD_IP) > real_hw.log
	diff real_gold.log real_hw.log \
	  && echo "PASS: ON CARD, THROUGH THE MAC, real 5M AAPL == golden"
	@python3 scripts/dump_session.py real_capture.bin 8192 --local-ip $(CARD_IP) || true

# Real-data latency. The point of this target was more orders than the synthetic
# feed's four -- and the prefix that fits in simulation has none at all, so in
# simulation it measures the feed path and not the order path. The histogram it
# was written for comes from the card: `make run-card-latency`.
test-real-latency: ## Simulate|real feed at gap 512 (no orders this early: see run-card-latency)
	$(MAKE) -C $(STEP5) realsmall-$(RSMALL_LAT).eth realsmall-$(RSMALL_LAT).itch
	$(MAKE) test-xsim ITCH=$(STEP5)/realsmall-$(RSMALL_LAT).itch \
	  ETH=$(STEP5)/realsmall-$(RSMALL_LAT).eth \
	  LOC=13 BASE=2800000 RECS=8192 GAP=512

# ---------- golden: the step 4b/6 chain, unchanged ----------
# Output prefix for the golden logs. The synthetic flow uses k_*; the real-data
# flow passes GPFX=real so the two goldens cannot overwrite each other -- which
# they silently did before, leaving run-card-*-real diffing against whichever
# golden was generated last.
GPFX ?= k

golden: $(ITCH) ## Data|regenerate the software golden logs
	python3 $(STEP4B)/scripts/dump_bbo.py $(ITCH) $(LOC) > $(GPFX)_bbo.log
	python3 $(STEP6)/scripts/dump_orders.py $(GPFX)_bbo.log $(ORDARGS) > $(GPFX)_orders.log
	python3 $(STEP6)/scripts/dump_ouch.py $(GPFX)_orders.log > $(GPFX)_ouch.log
	python3 $(STEP6)/scripts/dump_tcp.py $(GPFX)_ouch.log > $(GPFX)_gold.log

$(STEP1)/test.itch $(STEP1)/test.eth:
	cd $(STEP1) && python3 gen_itch.py test.itch --mold test.mold
	cd $(STEP1) && python3 mold2eth.py test.mold test.eth

# 64-byte-aligned replay image the injector reads out of HBM
$(REPLAY): $(ETH) scripts/pack_eth.py
	python3 scripts/pack_eth.py pack $(ETH) $@ --max-bytes $(TB_MAX_BYTES)

# ---------- Vivado: elaboration and out-of-context synthesis ----------
elab: ## Build|elaborate the kernel in Vivado (fast syntax/wiring check)
	@$(XSETUP) vivado -mode batch -nojournal -nolog -notrace -source syn/elab_kernel.tcl
synth: ## Build|out-of-context synthesis of the kernel
	@$(XSETUP) vivado -mode batch -nojournal -nolog -notrace -source syn/elab_kernel.tcl -tclargs synth

# ---------- Vitis: package the kernel and link an .xclbin for the card --------
# ap_clk carries the control plane, both HBM masters and the injector/capture
# pair (the CMAC stand-in); ap_clk_2 is the datapath core. The two are
# asynchronous, so the cdc_fifo crossings are exercised on the card rather than
# optimised away.
#
# CORE_CLK is 215 MHz, and that number is measured rather than chosen. Inside the
# shell the kernel sits in a reconfigurable-partition pblock competing with the
# platform's own logic for routing, so step 5's out-of-context 220 MHz is an upper
# bound, not a promise. A 220 MHz build routed with exactly one datapath path
# short -- the order table's URAM read:
#   Source:      u_fh/u_otab/g_way[3].u_mem/mem_reg_uram_0/CLK  (URAM288)
#   Destination: u_fh/u_otab/sel_ent_reg[price][29]/D
#   Slack (VIOLATED) -0.013 ns  @ 4.545 ns
# i.e. the datapath tops out near 219.4 MHz here. 215 takes ~2 % margin off that
# measured ceiling, and still clears the 195.3 MHz that 100 Gb/s demands at
# 512-bit width -- which Phase B needs and the HBM replay does not.
#
# (The same build had 9 other violations, all in the latency probes rather than
# the datapath; those were pipelined instead of paid for in clock speed. A probe
# must not set the Fmax of the thing it measures.)
AP_CLK   ?= 300000000
CORE_CLK ?= 215000000
CU        = t2t_kernel_1

# The second kernel clock needs a REFERENCE clock to be generated from, and the
# platform is picky about which:
#   ERROR: [CFGEN 83-2244] --clock.id directive specified with clock id 0, which
#   is not a fixed clock. Only fixed clocks can be used as reference clocks to
#   generate additional clocks. Clock ids for fixed clocks are {2}.
# So ids 0 (300 MHz) and 1 (500 MHz) are scalable OUTPUTS, and id 2 (100 MHz) is
# the only fixed reference. Asking for a frequency alone (--freqhz) set the
# FREQ_HZ property on the pin but never bound it to a generated clock, which is
# how the whole datapath ended up on the default 300 MHz twice over.
REF_CLK_ID ?= 2

t2t_kernel.xo: $(SRC) syn/kernel.xml syn/package_kernel.tcl syn/t2t_kernel_cdc.xdc
	@$(XSETUP) vivado -mode batch -nojournal -nolog -notrace -source syn/package_kernel.tcl

xo: t2t_kernel.xo ## Build|package Phase A as a Vitis .xo
# --freqhz, NOT --clock.freqHz. The latter is deprecated in 2025.2 and, far worse,
# is accepted with only a warning and then ignored: the build ran the ENTIRE
# datapath -- order table URAMs included -- at the platform's default 300 MHz
# instead of the requested 220, and missed timing by 1.789 ns on a path that
# closes comfortably at its intended clock. A deprecated option that still parses
# is the expensive kind, so the frequency is verified in the routed report rather
# than assumed from the command line (see README, "Two clocks means asking for
# two clocks").
xclbin: t2t_kernel.xo ## Build|link Phase A bitstream -> t2t.xclbin       (~1h10m)
	./syn/gen_vitis_ini.sh > syn/vitis.ini
	@$(XSETUP) v++ -l -t hw --platform $(XPFM) \
	  --config syn/vitis.ini \
	  --connectivity.sp $(CU).replay_buf:HBM[0] \
	  --connectivity.sp $(CU).capture_buf:HBM[1] \
	  --clock.id $(REF_CLK_ID):$(CU).ap_clk_2 \
	  --freqhz $(AP_CLK):$(CU).ap_clk \
	  --freqhz $(CORE_CLK):$(CU).ap_clk_2 \
	  --report_level 2 --save-temps --temp_dir _x_a \
	  -o t2t.xclbin t2t_kernel.xo

# ---------- Phase B: the same kernel behind a real 100G MAC ----------
# Generate the CMAC first: syn/gen_cmac.tcl configures it for the GT quad and
# reference clock this card's platform actually declares (QUAD_X0Y6 = lanes
# X0Y24~X0Y27, io_clk_qsfp0_refclka_00), which is not a datasheet default.
CU_B = t2t_kernel_b_1

# Phase B gets its own clocks, both below Phase A's, and both are measured.
#
# The Phase B design first routed at 215 MHz with all timing met -- but with
# WNS +0.004 ns on ap_clk_2, against +0.048 ns for the same clock in Phase A.
# The core logic is identical; what changed is the placement pressure from a
# CMAC and its GT sitting in the same reconfigurable partition. 0.004 ns is
# about 0.1 % of the period, which is not margin, it is luck -- the next run
# with any tool or floorplan difference could land on the other side of zero.
# 210 MHz was the first response to that.
#
# It was not enough, and the reason is worth keeping. Adding the loaded-latency
# probe to the kernel cost Phase A 33 ps on this clock (+0.048 -> +0.015); in
# Phase B, on top of the CMAC's placement pressure, the 210 MHz run came back
# at -0.022 ns AND -0.134 ns on ap_clk, 78 endpoints failing. Vitis names only
# the core clock in the error because ap_clk is scalable and this one is not,
# so reading the error alone would have sent the next build after 22 ps while
# the real problem was five times larger and elsewhere.
#
# The ap_clk failure is u_capture's byte accumulator, 71 % routing -- congestion,
# not logic depth, and the same path meets +0.153 ns in Phase A. So both clocks
# back off rather than the RTL changing. Both stay above what the design needs:
# 200 MHz clears the 195.3 MHz that 100 Gb/s demands at 512-bit width, and
# ap_clk at 250 MHz still moves 16 GB/s of replay against a 12.5 GB/s line rate.
AP_CLK_B   ?= 250000000
CORE_CLK_B ?= 200000000

cmac: ## Build|generate the cmac_usplus IP (needed once, for Phase B)
	@$(XSETUP) vivado -mode batch -nojournal -nolog -notrace -source syn/gen_cmac.tcl

# Gate 4: may the IP be turned into a BITSTREAM? A different question from "is
# it in the catalogue", and the only one that gates delivery. Asking it cost
# seconds; not asking it cost a 68-minute implementation run that met every
# timing constraint and was then refused by write_bitstream. See
# syn/gate_license.tcl. xclbin-b depends on this deliberately.
gate-license: ## Build|prove FlexLM grants cmac_usplus BEFORE an hour of build
	@$(XSETUP) vivado -mode batch -nojournal -nolog -notrace -source syn/gate_license.tcl \
	  | tee license_gate.log
	@grep -q "LICENCE GATE: PASS" license_gate.log || \
	  { echo ""; \
	    echo "REFUSING to start a build whose IP cannot be turned into a bitstream."; \
	    echo "Install the licence for the key(s) listed above, then re-run."; \
	    echo "Override with 'make xclbin-b SKIP_LICENSE_GATE=1' to build anyway"; \
	    echo "(implementation and the timing report are still valid without it)."; \
	    exit 1; }

SRC_B_FILES = $(SRC_B) syn/kernel_b.xml syn/package_kernel_b.tcl syn/t2t_kernel_cdc.xdc
t2t_kernel_b.xo: $(SRC_B_FILES)
	@$(XSETUP) vivado -mode batch -nojournal -nolog -notrace -source syn/package_kernel_b.tcl

xo-b: t2t_kernel_b.xo ## Build|package Phase B (CMAC inside) as a .xo
# The GT connection is made by a post-sys-link hook rather than a connectivity
# directive, because v++ has no --connectivity.gt and declaring the interface is
# not enough on its own (measured -- see syn/gt_connect.tcl).
ifndef SKIP_LICENSE_GATE
XCLBIN_B_DEPS = gate-license
endif

xclbin-b: t2t_kernel_b.xo $(XCLBIN_B_DEPS) ## Build|link Phase B bitstream -> t2t_b.xclbin     (~1h13m)
	./syn/gen_vitis_ini_b.sh > syn/vitis_b.ini
	@$(XSETUP) v++ -l -t hw --platform $(XPFM) \
	  --config syn/vitis_b.ini \
	  --connectivity.sp $(CU_B).replay_buf:HBM[0] \
	  --connectivity.sp $(CU_B).capture_buf:HBM[1] \
	  --clock.id $(REF_CLK_ID):$(CU_B).ap_clk_2 \
	  --freqhz $(AP_CLK_B):$(CU_B).ap_clk \
	  --freqhz $(CORE_CLK_B):$(CU_B).ap_clk_2 \
	  --report_level 2 --save-temps --temp_dir _x_b \
	  -o t2t_b.xclbin t2t_kernel_b.xo

# On the card, Phase B measures wire cycles at the CMAC's 322.265625 MHz rather
# than ap_clk's 300, so the host has to be told which clock the probe counted.
run-card-b: host/t2t_run golden $(REPLAY) ## Card|Phase B, synthetic feed, through the MAC
	$(call need_xclbin,t2t_b.xclbin,xclbin-b,1 h 15 m)
	./host/t2t_run --xclbin t2t_b.xclbin --replay $(REPLAY) --capture capture.bin \
	  --device $(BDF) --gap $(GAP) --loc $(LOC) --base $(BASE) --records $(RECS) \
	  --quiet $(QUIET) --clk-mhz 322.265625 \
	  --core-mhz $(shell echo $(CORE_CLK_B) | awk '{print $$1/1000000}')
	python3 scripts/pack_eth.py unpack capture.bin $(RECS) > kb_hw.log
	diff k_gold.log kb_hw.log && echo "PASS: ON CARD, THROUGH THE MAC, order frames == golden"

run-card-b-latency: ## Card|Phase B, synthetic feed at gap 512
	$(MAKE) run-card-b GAP=512

# Fail early, and say what to do. Without this a run-card target builds every
# prerequisite -- the replay image, the golden -- and only then dies inside the
# host tool with "FAIL: No such file 't2t.xclbin'", which says what is wrong but
# not that the fix is an hour-long link. Same philosophy as gate-license: find out
# before spending the time, not after.
define need_xclbin
@[ -r "$(1)" ] || { echo "ERROR: $(1) not found -- nothing to load onto the card."; \
  echo "       Build it first:   make $(2)"; \
  echo "       That takes roughly $(3), and $(1) is not created until it finishes."; \
  exit 1; }
endef

# ---------- host: build, then run on the real card ----------
XRT ?= /opt/xilinx/xrt
BDF ?= 0000:08:00.1

# regenerated whenever the register map moves, so the host cannot drift from the
# RTL: regmap.py is already diffed against axil_regfile.sv by step 7's tests
host/t2t_regs.h: ../step7-host/host/regmap.py scripts/gen_regs_h.py
	python3 scripts/gen_regs_h.py > $@

host/t2t_run: host/t2t_run.cpp host/t2t_regs.h
	g++ -std=c++17 -O2 -Wall -I$(XRT)/include -Ihost host/t2t_run.cpp \
	  -o $@ -L$(XRT)/lib -lxrt_coreutil -pthread

host: host/t2t_run ## Card|build the host runner
# THE POINT OF THIS DIRECTORY: replay on real silicon, then diff the frames the
# card emitted against the same golden the simulations use.
run-card: host/t2t_run golden $(REPLAY) ## Card|Phase A, synthetic feed
	$(call need_xclbin,t2t.xclbin,xclbin,1 h 10 m)
	./host/t2t_run --xclbin t2t.xclbin --replay $(REPLAY) --capture capture.bin \
	  --device $(BDF) --gap $(GAP) --loc $(LOC) --base $(BASE) --records $(RECS) \
	  --quiet $(QUIET) --clk-mhz $(shell echo $(AP_CLK) | awk '{print $$1/1000000}') \
	  --core-mhz $(shell echo $(CORE_CLK) | awk '{print $$1/1000000}')
	python3 scripts/pack_eth.py unpack capture.bin $(RECS) $(CARD_IP) > k_hw.log
	diff k_gold.log k_hw.log && echo "PASS: ON CARD order frames == golden"
	@python3 scripts/dump_session.py capture.bin $(RECS) --local-ip $(CARD_IP) || true

# Latency on silicon: the gap must exceed the quiet window for samples to be
# attributable, so this runs the same replay with the injector spaced out.
run-card-latency: ## Card|Phase A, synthetic feed at gap 512
	$(MAKE) run-card GAP=512

# what the card currently thinks it is
card-info: ## Card|what the card currently thinks it is
	$(XRT)/bin/xrt-smi examine -d $(BDF)

# ---------- cleaning, in three tiers ----------
#
# WHY TIERED, and it is not tidiness. The single `clean` this replaces removed
# *.xclbin in the same breath as *.log. A bitstream here takes 1 h 10 m to link,
# so "clean up the logs" silently cost two builds -- including the Phase B one
# that produced the only wire-to-wire measurement this project has. It also
# removed host/t2t_regs.h, which is GENERATED but also TRACKED, so a clean left
# the working tree dirty and looked like someone had deleted a source file.
#
# So the rule is: each tier only removes things that cost about as much to
# recreate as the tier's name suggests.
#
#   clean        seconds to minutes   logs, simulator scratch, small captures
#   clean-build  minutes              packaged kernels, .xo, v++ temp dirs
#   distclean    HOURS                bitstreams, generated IP, the replay image
#
# Nothing in any tier removes a tracked file. host/t2t_regs.h is regenerated by
# its own rule when it is out of date, so there is no reason to delete it.
clean: ## Clean|logs, sim scratch, small captures        (seconds)
	rm -rf xsim.dir .Xil xsim*.jou xsim*.log
	rm -f  *.log *.jou *.pb *.wdb *.wcfg
	# small, regenerated by the next `make test`/`make run-card`
	rm -f  replay-*.bin capture.bin rc_*.bin rc16.bin real_capture*.bin
	# metadata that is meaningless once its .xclbin is gone; the .xclbin itself
	# is NOT removed here -- see distclean
	rm -f  *.ltx *.xclbin.info *.xclbin.link_summary
	rm -f  k_*.log kb_*.log real_*.log rh_*.log s_*.log ks_*.log
	rm -f  session.eth session_stim.eth session_replay.bin session_capture.bin
	@echo "clean: logs, simulator scratch and small captures removed"
	@echo "       bitstreams, ip/ and real_replay.bin kept (see clean-build, distclean)"

# Everything v++ and Vivado regenerate from the RTL and the Tcl. Minutes, not
# hours -- the .xo is repackaged in well under a minute and _x_* is pure scratch.
clean-build: clean ## Clean|+ packaged kernels, .xo, v++ temp dirs   (minutes)
	rm -rf packaged_kernel packaged_kernel_b tmp_kernel_pack tmp_kernel_b_pack \
	       tmp_cmac syn/out_kernel _x _x_a _x_b _xbgate _xg .ipcache \
	       reports_b_fail analyzer_input \
	       gtgate/_xg gtgate/packaged gtgate/tmp_pack gtgate/analyzer_input
	rm -f  *.xo host/t2t_run
	@echo "clean-build: packaged kernels, .xo and v++ temp directories removed"
	@echo "             bitstreams and ip/ kept (see distclean)"

# The expensive tier. Each of these is an hour or more, or a long pipeline over
# the 7.7 GB ITCH capture, so it asks first rather than assuming.
#   *.xclbin        ~1 h 10 m each to link
#   ip/             `make cmac`, a Vivado IP generation
#   real_replay.bin `make -C ../step5-board real.eth` then pack_eth, over the
#                   full-day capture
distclean: clean-build ## Clean|+ bitstreams, ip/, real_replay.bin       (HOURS, asks)
	@echo "distclean removes work measured in HOURS:"
	@echo "  *.xclbin        ~1 h 10 m each to relink"
	@echo "  ip/             requires 'make cmac'"
	@echo "  real_replay.bin requires rebuilding from the full-day ITCH capture"
	@printf "proceed? [y/N] "; read a; [ "$$a" = "y" ] || { echo "aborted"; exit 1; }
	rm -rf ip
	rm -f  *.xclbin real_replay.bin
	@echo "distclean: done"

# ---------- unit test for the latency instrument itself ----------
# lat_probe's number gets quoted, so its guard logic (quiet window, exclusion,
# orphans, bucket placement) is driven directly rather than tested by implication
# through the full chain. The expected latency is re-derived by the testbench
# from the same interface events, independently of the DUT.
test-latprobe: ## Simulate|unit-test the latency instrument itself
	@$(XSETUP) xvlog -sv rtl/lat_probe.sv tb/tb_lat_probe.sv
	@$(XSETUP) xelab -debug typical tb_lat_probe -s tb_lat_probe_sim
	@$(XSETUP) xsim tb_lat_probe_sim -runall

# ---------- unit test for the store-and-forward FIFO ----------
# Every Phase B frame goes through this module, and a bug in it shows up in the
# kernel testbench as a corrupted order frame with no indication of where it came
# from. So it is driven directly: random frame lengths including 1 beat and the
# 24-beat Ethernet maximum, random write stalls and read backpressure, and a
# check per frame that its FIRST beat never leaves before its LAST beat was
# written -- which is the store-and-forward guarantee the CMAC depends on.
#
# Run at four clock ratios, because the failure modes are not symmetric: a reader
# faster than the writer is the feed path, a slower one fills the array and
# exercises s_tready, and equal clocks are the order path.
test-sffifo: ## Simulate|store-and-forward FIFO at four clock ratios
	@$(XSETUP) xvlog -sv rtl/axis_sf_fifo.sv tb/tb_axis_sf_fifo.sv
	@$(XSETUP) xelab -debug typical tb_axis_sf_fifo -s tb_sf_sim
	@$(XSETUP) xsim tb_sf_sim -runall -testplusarg wper=1.6665 -testplusarg rper=1.5515
	@$(XSETUP) xsim tb_sf_sim -runall -testplusarg wper=1.6665 -testplusarg rper=5.0
	@$(XSETUP) xsim tb_sf_sim -runall -testplusarg wper=5.0    -testplusarg rper=1.5515
	@$(XSETUP) xsim tb_sf_sim -runall -testplusarg wper=1.5515 -testplusarg rper=1.5515

# Convenience alias: build the replay image and nothing else.
real-image: real_replay.bin ## Data|build real_replay.bin from the full-day capture
	@ls -la real_replay.bin

# Diagnostic: which Xilinx tools will the recipes actually use?
which-tools: ## Info|which Xilinx tools the recipes will actually use
	@$(XSETUP) echo "vivado : $$(command -v vivado)"; \
	  echo "v++    : $$(command -v v++)"; \
	  echo "xvlog  : $$(command -v xvlog)"

# ---------- help ----------
# Reads the `## Group|description` tags on the rules themselves, so it cannot
# drift out of step with the targets the way a hand-written list does.
.DEFAULT_GOAL := help
help: ## Info|this list
	@echo "step8-hw -- tick-to-trade on the Alveo U55C"
	@echo
	@echo "No 'source settings64.sh' needed; recipes source it themselves."
	@echo "Override with XILINX_SETTINGS=<path>, or set it empty to use PATH."
	@echo
	@awk 'BEGIN{FS="## "; split("Simulate Build Card Data Clean Info",ord," "); \
	          for(i in ord) rank[ord[i]]=i } \
	     /^[a-zA-Z_][a-zA-Z0-9_.-]*:.*## / { \
	          split($$2,a,"|"); t=$$1; sub(/:.*/,"",t); \
	          printf "%d\t%s\t%s\t%s\n", rank[a[1]], a[1], t, a[2] }' $(MAKEFILE_LIST) \
	  | sort -k1,1n -s \
	  | awk -F'\t' '{ if ($$2!=g) { g=$$2; printf "\n%s\n", toupper(g) } \
	                   printf "  %-22s %s\n", $$3, $$4 }' 
	@echo
	@echo "Typical: make xclbin-b && make run-card-b-real"
