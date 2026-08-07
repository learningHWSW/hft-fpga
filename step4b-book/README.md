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


## Fast top-of-book (`fast_bbo.sv`) — built, measured, not wired in

`price_ladder` is ~10 of the imbalance path's ~28 core cycles. It earns that
depth: 4,096 levels per side and a grouped priority scan is the only way to answer
"what is the best level now" *in general*. But the general question is not the hot
one — `sweep_detect` already runs 19 cycles instead of 28 by tapping the
order-table delta and skipping the ladder entirely.

`fast_bbo` gives the imbalance path the same shortcut. It keeps only best
bid/ask and their sizes, and applies each delta to them directly:

| delta | needs the scan? |
|---|---|
| add better than the best | no — that *is* the new best |
| add at the best | no — size increases |
| add or remove at a worse price | no — best unchanged |
| remove at the best, partial | no — size decreases |
| **remove at the best, emptying it** | **yes — the next best is whatever the bitmap says** |

**It never approximates.** The project's headline property is that there is no
regime in which it emits a wrong order, and an approximate fast path is exactly
how a claim like that gets quietly lost. So `o_certain` low means "ask the
ladder", never "here is a guess".

**Measured on the real AAPL replay**, observing the same delta stream the ladder
consumes and cross-checked against the ladder's own output:

```
FAST_BBO: certain=6135 defer=605 (91% early), checked=1174 wrong=0
```

**91 % of real book updates answered in one cycle instead of ten, and zero cases
of certain-and-wrong over 1,174 cross-checks.** The synthetic testbench
(`tb_fast_bbo`, a full level-map reference rather than a second copy of the rules)
reports 98 % — quoted here only to show why the real number is the one that counts:
how often a removal empties the best level depends entirely on the message mix,
and D is 42.6 % of a real feed.

### The bug worth recording

The first real run reported **0 % early** — it deferred forever. The cause is a
timing coincidence the synthetic bench could not produce: `price_ladder` asserts
`o_valid` in its final state and `i_ready` in the next, so the BBO for delta N−1
arrives in the *same cycle* the ladder accepts delta N. Measured: **9 of 10
handshakes coincide.** The resync's `stale <= 0` and the deferral's `stale <= 1`
then landed in one evaluation, the deferral won, and the module never escaped.

The fix is a forwarding path — when the ladder is speaking this cycle, its record
*is* the book before this delta — and it is the same shape as the order table's
`r_fwd` and the ladder's own removal-to-add forward. Third time this design has
needed that pattern.

### What integration still has to decide

The module is proven; wiring it in is not done, and the hard part is **ordering**.
The strategy fires on the *rising edge* of a condition evaluated per BBO record,
so the record sequence must not change or different orders come out. A fast record
must therefore be held behind any earlier deferred one — otherwise record k
overtakes k−1 and the edges move. Get that right and the output stays
byte-identical to today's, with only the latency changing; get it wrong and the
golden diff will say so loudly, which is the good case.

Note also that the realized saving is below the headline 91 %: a fast record
following a deferral still waits for it, so how deferrals cluster decides the
average. The 91 % is the fraction *answerable* early, not the fraction that will
be delivered early.
