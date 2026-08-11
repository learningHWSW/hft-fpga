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


## Fast top-of-book (`fast_bbo.sv`) — wired into the chain

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

### The rejoin (`bbo_merge.sv`) — how integration settled it

The hard part was never the module, it was **ordering**. The strategy fires on the
*rising edge* of a condition evaluated per BBO record, so the record sequence must
not change or different orders come out. Two things make that safe:

**Drive the fast path from the ladder's ACCEPT, not from the delta stream.**
`price_ladder` accepts a delta only from IDLE and asserts `o_valid` in that same
cycle, so gating `fast_bbo.i_valid` on `i_valid && i_ready` fixes the arrival order
for every delta k:

```
accept(k)          lad(k-1) lands here too
  +1 cycle         fast(k)
  +11 cycles       lad(k), if the BBO changed -- and this is accept(k+1)
  +12 cycles       fast(k+1)
```

A fast record therefore cannot overtake a deferred one: `fast_bbo` goes stale on a
deferral and only a ladder record clears it, and that record is already out. The
ordering hazard is removed by the tap point rather than by a reorder buffer.

**Merge on value, not on source.** The two streams are not in one-to-one
correspondence — one record per delta against one per *change* — so `bbo_merge`
keeps the last BBO it emitted and emits only what differs from it. That is
`price_ladder`'s own S_OUT test against its `o_*` registers, so the two
change-detectors share a definition and a baseline and agree by construction. The
duplicate ladder record for a delta the fast path already answered arrives equal
and is dropped; no per-delta tag is needed, and no change can be lost, because
dropping only ever happens on equality.

`mismatch_cnt` counts the ladder contradicting an early answer, which `fast_bbo`'s
contract forbids. It comes out of `fh_core` and `t2t_top` as `st_bbo_mismatch` and
is in the AXI-Lite register map at `0x154`, beside `st_bbo_early` (`0x14C`) and
`st_bbo_late` (`0x150`). `t2t_run` prints all three and **fails the run** if
mismatch is nonzero, so the property is enforced on hardware rather than inferred
from a frame diff whose golden could share the same wrong book.

**Measured on the real 5 M AAPL replay**, `fh_core` with the fast path in the
datapath, BBO stream diffed against the software golden:

```
TB done: 1779 BBO updates (gap=24)
  fast bbo : early=1174 late=605 (65% early) mismatch=0
PASS: BBO == golden (real.mold loc=13 gap=24)
```

**The same 1,779 records as the ladder alone, 65 % of them delivered ten cycles
sooner.** The realized 65 % is below the 91 % *answerable*, exactly as expected: a
record following a deferral still waits for it, so how deferrals cluster decides
the average. The 605 late records are the 605 deferrals.

**It is not free in area, and it is not measurably costly in timing.** Both
statements needed a sweep to make, and the first version of this section made
the second one wrongly.

What it costs in area, out-of-context place & route of the full `t2t_top` chain
at the 4.618 ns core target, `USE_FAST_BBO = 0` against `1`:

| | ladder only | with the fast path |
|---|---|---|
| CLB LUTs | 54,939 | 55,835 (+896, +1.6 %) |
| registers | 33,236 | 33,941 (+705, +2.1 %) |
| BRAM / URAM / DSP | 52 / 66 / 2 | unchanged |

What it costs in fMAX is nothing this can measure. This section used to report
**218.6 → 209.1 MHz** and attribute the 9.5 MHz to a specific carry chain in the
MoldUDP64 splitter. That was one build against one build. Across four
implementation directive sets per configuration:

| | ladder only | with the fast path |
|---|---|---|
| best post-route core_clk Fmax | 222.5 MHz | **225.5 MHz** |
| worst | 217.2 MHz | 221.7 MHz |
| spread within the configuration | 5.3 MHz | 3.8 MHz |
| builds with failing endpoints | 0 of 4 | 0 of 4 |

The gap between the two bests (3.0 MHz, in the fast path's favour) is smaller
than the spread inside either, so the measurement does not resolve a difference
— but it does exclude a 9.5 MHz penalty, since the slowest fast build beats
three of the four ladder-only builds. The splitter path that was blamed is not
the critical path in any of the eight. `data/FINDINGS.md` §7.7 has the full
table and the method.

## `bbo_arb` — merging K books into one tagged stream

With `NSYM` tracked symbols there are `NSYM` price ladders, each with its own
occupancy bitmaps and its own pipeline. `bbo_arb` turns their outputs into the
single tagged stream the strategy consumes.

**The ladders run concurrently on purpose.** They are fed from one serialized
delta FIFO, and the demux pops as soon as the ladder that OWNS the delta is
ready — so a delta for symbol B is issued while symbol A's ladder is still
working. The ladder is the slowest stage in the chain (5–7 cycles per delta
against the order table's 2–3 per message), so serializing them would divide the
feed rate the design can absorb by `NSYM`. The price is that two ladders can
finish on the same cycle, which is what this module is for.

**What is ordered and what is not**, because this is the part that is easy to
assume wrongly:

- **Per symbol, order is exact.** One ladder is an in-order pipeline and its
  records enter one queue and leave in the same order. This is the invariant the
  strategy depends on — its edge detector, latched BBO and position are all per
  symbol, so per-symbol order is the whole of what correctness needs.
- **Across symbols, order is not preserved**, and no consumer may assume it.
  Ladder pipelines are not fixed-length (a record touching one level skips a
  state that a two-level record does not), so symbol B's later delta can produce
  an earlier record than symbol A's. The merged stream's timestamps are therefore
  **not monotonic**. Nothing downstream compares timestamps across symbols; a
  consumer that wanted to would need a reorder buffer here and a bound on how
  long to wait.

**Depth is two, and that is a proof rather than a guess.** A ladder cannot
produce two records closer together than its pipeline is long — five cycles at
the very least — and the arbiter drains one per cycle, so with `NSYM ≤ 2 × 5` a
queue can never be asked to hold more than two. The overflow is counted anyway
(`st_bbo_arb_drop`, in the register map): a dropped BBO record would otherwise be
a silent hole in one symbol's stream.

**`NSYM = 1` is a wire**, not a one-deep queue that happens to be transparent.
The strategy's sweep path reads a *registered* BBO, so inserting a cycle here
would re-time sweep against imbalance and change which orders fire. Every
existing golden is a single-symbol golden, so that has to cost nothing.

**Verified at `NSYM = 2` against the single-symbol goldens** (`make -C
step5-board test-msym`): AAPL at locate 1 and MSFT at locate 2, from the same
stimulus, split by tag and diffed against `dump_bbo.py` for each locate
separately. 10 records and 4 records, both exact, `mismatch = 0`,
`arb_drop = 0`. Using the existing per-locate goldens is the point — a
two-symbol golden written beside this RTL could share a mistake with it.

End to end, on the step-8 kernel's synthetic chain, the loaded-latency probe's four
samples read **min 33 → 24 core cycles** (`USE_FAST_BBO = 0` against the default),
mean 51 → 47, with the max moving 73 → 74: the rejoin is a registered stage, so a
deferred record pays one cycle for what the certain ones save nine or ten of. Four
samples is a direction, not a distribution — the honest latency number for the fast
path is still the one nobody has taken, on the card. Order frames stay
byte-identical HBM-to-HBM and through the MAC model.
