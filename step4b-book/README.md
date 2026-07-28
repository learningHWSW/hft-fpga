# Step 4b — price ladder / top-of-book (BBO)

Takes step 4a's book-delta stream (a side's rem/add level) and maintains an L2
order book — one aggregate qty per side and price level. Emits whenever the
best-of-book (BBO: best bid/ask price + qty) changes, and that sequence must
match the step-1 golden. This cross-checks the whole `decoder -> order_table ->
price_ladder` chain against the step-1 C model.

## Run

```sh
make test              # xsim, synthetic test.itch (AAPL locate 1, $150 band)
make test-verilator    # Verilator, same
make test-real         # real data 5M AAPL slice (Verilator, $280 band)
make test-real-xsim    # the above, xsim
```

The golden `scripts/dump_bbo.py` re-emits the step-1 book model in the canonical
format. Independent check: `dump_bbo.py`'s output matches the step-1 C parser's
BBO byte-for-byte (synthetic and real data). An empty diff of the RTL BBO log
against the golden is PASS.

## Design (measurement-based, data/FINDINGS.md §3)

- **price -> level index**: `idx = (price - cfg_base) / TICK`. TICK=100 ($0.01) is
  a compile constant, so at synthesis the division degrades to a multiply-shift.
  `cfg_base` is the band's start price the software sets per symbol (a re-centring
  hook, PLAN §2.1).
- **Fixed band of LEVELS levels**: a price outside the band is dropped + `oob_cnt`.
  **oob is by design, not an error** (PLAN §2.1: drop deep levels outside the
  band). An oob price is far from the BBO and never becomes best, so the BBO diff
  still passes — the diff is the correctness gate. Measured: 465 oob over AAPL's
  5M slice (all deep/stub quotes, BBO unchanged).
- **Best search**: a priority scan over a per-side occupancy bitmap (registers) —
  best bid = highest occupied level, best ask = lowest. Combinational, so it is
  immediate on each update.
- **Start with L2**: only `{qty sum}` per level. Order count per level and
  approximate L3 are follow-ons.

## Status / performance

- xsim (Vivado 2025.2): synthetic PASS, real data 500k AAPL PASS.
- Verilator: synthetic PASS, real data **5M AAPL PASS** (1779 BBO updates, 0
  drops, 0 overflow). The whole chain matches the step-1 C model.
- **Correctness-first FSM**: 3 cycles per record for rem/add/eval. The input is
  rate-limited by the decoder and order table, so 0 drops. Pipelining the best
  search and moving qty to BRAM (registered read) is the follow-on optimisation.

## Structure

```
rtl/price_ladder.sv    — L2 ladder, occupancy-based BBO, oob counter (FSM)
tb/tb_price_ladder.sv  — file -> decoder -> order_table -> price_ladder chain
scripts/dump_bbo.py    — golden (step 1 book model, canonical format; cross-checked with step1)
```
