# Step 3a — MoldUDP64 stripper + sequence gap detection

Takes MoldUDP64 packets (UDP payload), re-frames them into a per-ITCH-message
AXI-Stream, and detects sequence gaps / heartbeats / duplicates / EOS. The
output follows the step-2 decoder input contract (tlast per message) — the TB
actually chains the decoder for an integration check.

## Run

```sh
make test            # xsim
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
- **This module is a behavioural reference and is not instantiated anywhere.**
  It is a byte-granular random-access buffer, so its synthesis footprint is
  large; the 512-bit line-rate version (step 3b) replaces it in the datapath and
  was written against this as the golden. It is the only module in the
  repository with a testbench and no instantiation, and that is deliberate — the
  two are diffed against the same `dump_mold.py`, so keeping the simple one
  runnable is what makes the fast one trustworthy. Deleting it would save a file
  and lose the reference.
- **frame_err_cnt**: a counter for framing anomalies (short header / length
  mismatch / buffer overrun). It must be 0 on a clean stream, which the TB checks
  at the end.

## Status

- xsim: PASS — 19/21 msgs delivered, `gap_total=2`, `dup=1`,
  `frame_err=0`, EOS detected. The two undelivered messages are the deliberate
  sequence gap, and they are MSFT noise, so the tracked symbol's book is
  unaffected — which is the point of that scenario.
- Historically also PASS under Verilator, on the same numbers. That flow is gone
  (the project runs on xsim alone); the agreement is recorded because two
  independent simulators reaching the same 19/21 is worth more than one.
