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
  optimisation (cut-through — fire the instant the last needed field arrives) was
  deferred until the pipeline was complete, and has now been **evaluated and
  dropped**: at the 512-bit width this decoder is instantiated at, every ITCH
  message (max 50 B) arrives inside one 64-byte beat, so there is no
  partial-message window left and cut-through could only collapse this one
  register stage — 1 cycle, 4.65 ns, in exchange for a full combinational decode
  on the core clock. `data/FINDINGS.md` §7.1.1 has the arithmetic. The idea was
  sound when this module was 64 bits wide; the width change took the win instead.
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

## Where this went

All three are built; kept as the plan they came from.

1. **512-bit generalisation.** The decoder itself needed only a width parameter —
   `itch_decoder #(.DATA_W(512))` is unchanged. The realignment, several messages
   ending and starting inside one beat, is a separate module:
   [step3b-splitter](../step3b-splitter/).
2. **MoldUDP64 stripper with sequence-gap detection**
   ([step3a](../step3a-mold-stripper/)) and the UDP/IP/Ethernet front end
   ([step5-board](../step5-board/)).
3. **Order table and top-of-book engine** ([step4a](../step4a-order-table/),
   [step4b](../step4b-book/)), with the step-1 C model as the golden throughout.

One consequence of the width change is worth noting here, because this module's
header used to promise the opposite: at 512 bits every ITCH message (max 50 B)
arrives inside one 64-byte beat, so the cut-through variant that fires per-field
before `tlast` has no partial-message window left to exploit. It was evaluated and
dropped — see the design-choices note above and `data/FINDINGS.md` §7.1.1.
