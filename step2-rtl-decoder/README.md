# Step 2 — SystemVerilog ITCH decoder + self-checking simulation

xsim (Vivado/Vitis) is the primary flow. Verilator is the fallback for
environments without Vivado.

## Run

```sh
# Vivado/Vitis environment (after sourcing settings64.sh)
make test

# environment without Vivado
make test-verilator
```

Both flows: the TB injects the test.itch made by step 1's `gen_itch.py` as an
AXI-Stream -> the decoder output is logged to `decode_rtl.log` -> **an empty diff
against `scripts/dump_itch.py` (golden) is PASS**.

## Structure

```
rtl/itch5_pkg.sv     — offset/size constants + itch_msg_t (an SV mirror of step1's itch5.h)
rtl/itch_decoder.sv  — AXI-Stream (64-bit) input, itch_msg_t + a valid pulse output
tb/tb_itch_decoder.sv— file-injection driver + canonical-log monitor
scripts/dump_itch.py — a golden log in the same format from the same file
```

## Design decisions (current state)

- **Interface**: one packet (tlast) per message on AXI-Stream. Removing the
  framing (MoldUDP64 or the file's length prefix) is the upstream (step 3) job.
- **store-then-decode**: extract all fields in parallel + a valid pulse on the
  cycle after tlast. Simple and clear for functional verification. The latency
  optimisation (cut-through — fire the instant the last needed field arrives)
  comes after the pipeline is complete.
- **s_tready = constant 1**: the market-data path never backpressures the wire.
  If a downstream is slow it is absorbed in a FIFO, and overflow is drop + gap
  handling.
- **length check**: if the received length != the spec length, `m_len_err` — for
  detecting an upstream framing bug or a feed anomaly.

## xsim tips

- To see waveforms: since `xelab -debug typical` is in effect, open with
  `xsim tb_itch_decoder_sim -gui -testplusarg itch=...`.
- For regressions, `-runall` (batch) is faster. It can also be combined with
  xelab via the `-R` option.

## Next (step 3+)

1. Generalise the decoder to 512-bit (100G CMAC) width — the core challenge: the
   realignment where several messages end and start within one beat. The current
   64-bit version stays as the reference.
2. Combine a MoldUDP64 stripper (with sequence-gap detection) + a
   UDP/IP/Ethernet parser.
3. The order table + top-of-book engine (the step-1 C model is the golden).
