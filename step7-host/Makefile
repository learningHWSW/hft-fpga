# Step 7 — host software (session / control plane).
#
# Pure Python: the host is the control plane (session, config, ack/fill
# bookkeeping), not the hot path, so it needs no Vivado and no FPGA. `make test`
# spins up the mock exchange on loopback and round-trips real orders through it.

STEP6 = ../step6-strategy

.PHONY: test fpga-fixture clean

test:
	python3 -m tests.test_regmap
	python3 -m tests.test_session

# regenerate the FPGA OUCH bytes the interop test replays (needs Verilator).
# The test SKIPs gracefully if this has not been run.
fpga-fixture:
	$(MAKE) -C $(STEP6) test-combined >/dev/null
	@mkdir -p tests/fixtures
	@cp $(STEP6)/ouch_rtl.log tests/fixtures/ouch_rtl.log
	@echo "captured $(STEP6)/ouch_rtl.log -> tests/fixtures/"

clean:
	rm -rf tests/__pycache__ host/__pycache__ tests/fixtures
