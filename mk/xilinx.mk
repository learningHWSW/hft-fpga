# The Xilinx toolchain, pinned. Included by every step that runs a Xilinx tool.
#
# WHY THIS EXISTS. Step 8 learned it the expensive way and wrote it down: the
# tools are only on PATH if something put them there, ~/.bashrc on this machine
# puts an OLDER install there, and a build that succeeds against the wrong
# version is worse than one that fails. Step 8 has been guarded since; steps
# 2-6 were not, so `make test` in those directories ran on whatever `xvlog`
# happened to be first on PATH while their READMEs reported a different version.
# Two halves of one project, verified on two toolchains, and nothing said so.
#
# WHAT IT DOES. Source XILINX_SETTINGS if set, fail loudly if it is unreadable
# or if sourcing it fails, and then fail loudly if the tool the caller needs is
# still not on PATH. Silence is never a fallback.
#
#   make test                                     # the pinned install
#   make test XILINX_SETTINGS=/opt/.../settings64.sh   # a different one
#   make test XILINX_SETTINGS=                    # deliberately, whatever is on PATH
#   make which-tools                              # what the recipes will use
#
# EVERY recipe that runs a Xilinx tool must go through $(XSETUP). One that does
# not is invisible: it works, and it works with the wrong tool. Step 8's two
# v++ link steps missed it once and packaged with 2025.2.1 while linking with
# 2023.2.
#
# THE DEFAULT IS THE VERSION THE CARD IS BUILT WITH, deliberately. Step 5's
# out-of-context synthesis exists as a proxy for the card's timing, and a proxy
# produced by a different tool than the bitstream is a weaker proxy than it
# looks. Note that this MOVES the fMAX baseline: every number in
# data/FINDINGS.md 7.6.x and 7.7 was produced by 2023.2, which is what these
# directories silently used. See 7.6.4 for the measured difference.
SHELL := /bin/bash

XILINX_SETTINGS ?= /opt/Xilinx/2025.2.1/Vivado/settings64.sh

# The tool whose absence makes the guard fail. Simulation steps need xvlog;
# step 8 overrides this with v++ before including, because a Vitis install can
# be missing the linker and still answer `xvlog`.
XTOOL ?= xvlog

XSETUP = { if [ -n "$(XILINX_SETTINGS)" ]; then \
             [ -r "$(XILINX_SETTINGS)" ] || { echo "ERROR: XILINX_SETTINGS=$(XILINX_SETTINGS) is not readable."; exit 1; }; \
             . "$(XILINX_SETTINGS)" >/dev/null || { echo "ERROR: sourcing $(XILINX_SETTINGS) failed."; exit 1; }; \
           fi; \
           command -v $(XTOOL) >/dev/null 2>&1 \
           || { echo "ERROR: no $(XTOOL) on PATH. Point XILINX_SETTINGS at a settings64.sh, or set it empty to use PATH."; exit 1; }; } &&

# Reports what the recipes will ACTUALLY use, which is the one question a
# version mismatch makes you ask. Step 8's own version of this target could not
# have caught its v++ bug -- it reported what XSETUP provides, and the bug was a
# recipe that did not go through XSETUP -- so read it as "what the guarded
# recipes use", not "what every recipe here uses".
.PHONY: which-tools
which-tools: ## Info|which Xilinx tools the recipes will actually use
	@echo "XILINX_SETTINGS = $(if $(XILINX_SETTINGS),$(XILINX_SETTINGS),<empty: using PATH>)"
	@$(XSETUP) for t in xvlog xelab xsim vivado v++; do \
	   p=$$(command -v $$t 2>/dev/null || echo "(not found)"); \
	   printf '  %-7s %s\n' "$$t" "$$p"; \
	 done; \
	 v=$$(xvlog -version 2>/dev/null | head -1); echo "  version $$v"
