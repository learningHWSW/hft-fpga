# Step 3a — MoldUDP64 stripper + sequence gap detection

Takes MoldUDP64 packets (UDP payload), re-frames them into a per-ITCH-message
AXI-Stream, and detects sequence gaps / heartbeats / duplicates / EOS. The
output follows the step-2 decoder input contract (tlast per message) — the TB
actually chains the decoder for an integration check.

## Run

```sh
make test            # xsim (Vivado/Vitis environment)
make test-verilator  # environment without Vivado
```

If test.mold is missing it is generated automatically by step 1's
`gen_itch.py --mold`. Scenario: two heartbeats, a 2-message gap (seq 11–12
lost), one duplicate packet, EOS.

## Structure

```
rtl/mold_stripper.sv   — the stripper (store-and-forward, 64-bit reference)
tb/tb_mold_stripper.sv — file injection -> stripper -> step2 itch_decoder chain
scripts/dump_mold.py   — golden (message lines reuse step2 dump_itch.fmt_msg)
```

Decode lines and event lines (`GAP expected=.. got=.. missing=..`, `HB seq=..`,
`EOS seq=..`) are logged interleaved in stream order in one file; an empty diff
against the golden is PASS. A gap event always comes before that packet's
messages.

## Design decisions

- **Sequence tracking**: expected=1 at reset. A gap (seq > expected) is detected
  on both data and heartbeats — a pulse + `gap_total` accumulation, then continue
  at the new seq. A duplicate (seq < expected) drops the whole packet +
  `dup_cnt`. **Retransmit request / rewind is the SW job** (PLAN.md §0-5).
- **store-and-forward + s_tready**: buffer the whole packet, then walk its
  messages. s_tready=0 during drain. The per-message tlast re-framing can be up
  to ~1.14× slower than the input because of padding, so an absorption FIFO
  (overflow drop + counter) is mandatory behind the real wire — the same
  principle of never backpressuring the MAC.
- **This module is a behavioural reference**: a byte-granular random-access
  buffer, so its synthesis footprint is large. The 512-bit line-rate version
  (step 3b) replaces it using this as the golden.
- **frame_err_cnt**: a counter for framing anomalies (short header / length
  mismatch / buffer overrun). It must be 0 on a clean stream, which the TB checks
  at the end.

## Status

- xsim (Vivado 2025.2): PASS
- Verilator: PASS
- Both deliver 19/21 msgs, gap_total=2, dup=1, frame_err=0, EOS detected
