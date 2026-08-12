# Real-data measurements — 2019-12-30 NASDAQ TotalView-ITCH 5.0

A full day (268,744,780 messages, 7.71 GB uncompressed, 03:04:32–20:05:00 ET).
Measurement tool: [step1-sw-parser/itch_hist.c](../step1-sw-parser/itch_hist.c),
raw report: [hist_full.txt](hist_full.txt). 0 out-of-order ts, 0 order-table
miss-ops -> the parser and table models are self-consistent on real data.

## 1. Message-type mix (design priorities)

| Type | Share | Book action | Implication |
|---|---|---|---|
| A | 43.59% | new insert | most frequent. The insert path is hot |
| D | 42.55% | full delete | almost tied with insert — **the delete path is just as hot** |
| U | 8.05% | delete + insert (two hash ops) | dominates the hot-path cycle budget |
| E | 2.13% | qty decrement | |
| X | 1.04% | partial cancel | |
| I, P, F etc. | ~2.6% | (mostly no book impact) | |

A+D+U+E+X = **97.4%**. **The three A/D/U are 94%** — making just the
insert/delete/replace paths of the book engine II=1 is effectively line rate.
avg message length 28.7 B, max 50 B ('I' NOII).

## 2. Step 3b — splitter input FIFO size (fixed by measurement)

Model: arrival = serialise (len+2) B onto the 100G wire (respecting the timestamp
lower bound), drain = 1 msg / 3.103 ns (322.265625 MHz, 1 msg/cycle).

**Worst backlog over the day = 76 msgs / 2356 bytes** @ 15:59:56.7 (a
near-close burst).

| Backlog (at arrival) | Occurrences | Share |
|---|---|---|
| 1 msg (idle) | 265.8M | 98.9% |
| 2–3 | 2.94M | 1.09% |
| 4–7 | 24k | 0.009% |
| >= 64 | 85 | 3e-7 |

**Conclusion**: a **256-entry (2^8) input FIFO gives 3.4× headroom over 76**. In
512-b beats, 2356 B ÷ 64 B/beat ≈ 37 beats -> a **64-deep 512-b FIFO (4 KB) is
enough**. With backlog >=2 only 1% of the time, the FIFO is nearly empty most of
the time.

> Note (conservative direction): the arrival model omits MoldUDP64/UDP/Eth packet
> overhead and inter-packet gaps, so arrivals are denser than reality -> 76 is an
> upper bound (safe side). The real ITCH-only backlog is smaller.

## 3. Per-window message density (burst characteristics)

| Window | p50 | p99 | p99.9 | p99.99 | max |
|---|---|---|---|---|---|
| 1 µs | 1 | 2 | 4 | 16 | 501 |
| 10 µs | 1 | 6 | 16 | 25 | 501 |
| 100 µs | 2 | 19 | 66 | 126 | 506 |
| 1 ms | 6 | 90 | 340 | 1066 | 1822 |

Up to 501 messages exist within 1 µs (≈ an instantaneous 500 Mmsg/s burst), but
p99.99 is 16 so the sustained load is low — the reason the small FIFO of §2
absorbs it. Micro-bursts happen but are short.

## 4. Step 4a — order table design point (fixed by measurement)

Measurement tools: [otable_sim.c](../step1-sw-parser/otable_sim.c) (d-way
set-assoc overflow sweep, raw [otable_sweep.txt](otable_sweep.txt)),
[sym_conc.c](../step1-sw-parser/sym_conc.c) (per-symbol peak,
[sym_conc.txt](sym_conc.txt)).

### 4.1 All symbols = HBM, confirmed
Concurrent live-order peak ~1.92M (all symbols). d-way set-associative overflow
sweep (over the day):

| Capacity | 2-way | 4-way | 8-way |
|---|---|---|---|
| 8.39M (load ~23%) | 48190 ppm | 4356 ppm | **75 ppm** |
| 4.19M (load ~44%) | 163131 ppm | 57003 ppm | 11551 ppm |

- **No configuration reaches 0 overflow** (even 8-way/23% drops 10,490 over the
  day).
- 8.39M × ~152b ≈ 159 MB ≫ VU35P URAM (~11.5 MB). -> **all symbols = HBM**.
- **Way count dominates overflow**: at the same capacity, 2->4->8-way drops by
  orders of magnitude.
- **Raw low bits > mixing hash** (in every configuration): order_ref is
  monotonically increasing, so the low bits already round-robin. A multiply-shift
  mix actually induces clustering. -> **do not add a hash mixer.**

### 4.2 Symbol filter = URAM (the hot-path design)
Per-symbol concurrent live-order peak (over the day):

| Symbol | Peak | | Symbol | Peak |
|---|---|---|---|---|
| AMZN | 37,068 | | NVDA | 12,800 |
| AAPL | 27,110 | | AMD | 11,614 |
| MSFT | 23,005 | | NFLX | 11,560 |
| TSLA | 17,482 | | ROKU | 10,072 |
| FB | 14,736 | | (top-16 cumulative) | ~231K |

**A reversal (found by measurement): the filter table needs a mixing hash, not
the raw low bits.** §4.1's "monotonic ref -> round-robin" holds **only for the
all-symbols aggregate**; filtering to one symbol makes that symbol's ref subset
cluster in the low bits. AAPL full-day overflow (loc=13 filter,
[otable_aapl2.txt](otable_aapl2.txt)):

| config | slots | load% | overflow | ppm |
|---|---|---|---|---|
| 16b ×4 **raw** | 262K | 10.1 | 24,142 | 33920 |
| 16b ×4 **mix** | 262K | 10.3 | 132 | 174 |
| **16b ×8 mix** | 524K | 5.2 | **0** | **0** |
| 18b ×4 mix | 1.05M | 2.6 | 0 | 0 |

- mix reduces overflow 180× over raw. -> **the filter table uses a mixing hash.**
- **Adopted design point (step 4a RTL): `2^16 sets × 8-way + mixing hash`** — AAPL
  full-day overflow 0. 524K slots × ~153b ≈ 80 Mbit ≈ 10 MB (87% of VU35P URAM
  ~11.5 MB).
- Cheaper alternative: `16b ×4` (≈5 MB, 43% URAM) — ~100/day (about 110–170 ppm)
  deep-order drops, negligible BBO impact. Tag compression / HBM for multi-symbol
  or URAM savings is a follow-on.

### 4.3 Which mixer to use — no multiply needed (a question synthesis raised)
The §4.2 mix was a 64×64 multiply-shift, but once the memory problem was fixed,
**that multiply became the critical path** (a multi-DSP cascade, 4.6 ns —
step5-board/README.md). So "does a cheaper mixer suffice" was re-measured (AAPL
filter, over the day, [hash_sweep.txt](hash_sweep.txt)):

| 16b × 8way | overflow | maxset | hardware cost |
|---|---|---|---|
| mul64 (multiply-shift) | 0 | 7 | 64×64 multiply, DSP cascade |
| **xorfold** (`r^(r>>16)^(r>>32)^(r>>48)`) | **0** | **6** | **0 DSP, ~2 LUT levels** |
| mul32 (fold to 32 bits then 32×32) | 0 | 5 | 32×32 multiply |
| raw low bits | 3 | 8 | lowest |

- **Pure XOR folding matches the multiply at 0 overflow**, and its worst-set
  occupancy is even lower (6 vs 7). -> **no multiply needed. No pipelining
  needed either.**
- Even at the tighter 16b×4, xorfold (95) / mul32 (84) beat mul64 (132).
- Lesson: applying the "multiply-shift is a good mixer" folklore straight to this
  workload wastes DSPs and wrecks timing. Here too, measurement reversed the
  folklore.

### 4.4 How many symbols fit one table — measured, and the README was wrong

"Multi-symbol needs the HBM path" was in the README from the start. It is true of
ALL symbols (§4.1: 1.92 M concurrent orders, ~159 MB) and false of the case
anyone would actually build next, which is a handful of names. Measured by
replaying the union of the top-K symbols through the table
(`otable_sim ... loc=393,13,...`, K taken from [sym_conc.txt](sym_conc.txt)):

| tracked | peak live orders | smallest zero-overflow geometry | slots | URAM | of device |
|---|---|---|---|---|---|
| 1 (AMZN) | 37,068 | **2^13 × 16** (deployed) | 131,072 | 64 | 6.7 % |
| 2 (+AAPL) | 64,175 | 2^14 × 16 | 262,144 | 128 | 13 % |
| 4 (+MSFT, TSLA) | 104,613 | 2^15 × 16 | 524,288 | 256 | 27 % |
| 8 (+FB, CSCO, NVDA, AMD) | 156,993 | 2^15 × 16 | 524,288 | 256 | 27 % |
| 16 | 230,412 | 2^16 × 16 | 1,048,576 | 512 | 53 % |

**Sixteen symbols fit in URAM.** The device has 960 URAM288 and the whole design
currently uses 66. Nothing here needs HBM; what needs HBM is the all-symbols
table, which is a different design.

**The deployed geometry holds exactly one symbol.** At 2^13 × 16 a second symbol
overflows 821 times over the day (824 ppm) and four overflow 79,085 times
(4.4 %). Worst-set occupancy is already 16 of 16 with AMZN alone — the zero is
real but it has no headroom, so NSYM and SETS_BITS have to move together. That is
why `order_table` refuses to imply one from the other.

**4 and 8 symbols cost the same.** Both close at 2^15 × 16, so once the table is
paid for at four names the next four are free. 16 at 2^15 misses by 2,336 inserts
(369 ppm) — close enough that a 16-symbol design is a judgement about whether a
few hundred ppm of deep-order drops matter, not a capacity wall.

**Peaks coincide; do not count on diversification.** The peak of the SUM is within
0.6 % of the sum of the peaks at every K (64,175 against 64,178 at K=2; 156,888
against 157,223 at K=8). Symbol activity peaks together, because the events that
move one name move the market. Sizing a shared table on the assumption that peaks
spread out would be sizing it for a day that does not happen.

**What the entry costs.** Nothing it was not already paying. §4.2 removed the
per-entry locate as "8.4 Mbit of a constant" and got the entry to 130 bits, which
is what fits two URAM columns (144 b). Multi-symbol puts back an INDEX, not a
locate: 4 bits for 16 symbols, 14 bits available. The order table's per-symbol
cost is the capacity above, not the width.

**What is NOT in this table** was the rest of the chain, which has since been
built (`NSYM` now runs the whole datapath, not just the table). The second half
of the cost, measured the same way — one `synth_design` at `NSYM = 1` against
one at `NSYM = 2`, everything else identical, `make -C step5-board synth-t2t
NSYM=2`:

| | NSYM=1 | NSYM=2 | per extra symbol |
|---|---|---|---|
| CLB LUTs | 55,933 | 88,620 | **+32,687 (+58 %)** |
| registers | 33,942 | 44,482 | +10,540 (+31 %) |
| DSP48E2 | 2 | 4 | +2 (the ladder's divide-by-tick) |
| BRAM36 / BRAM18 | 48 / 4 | 48 / 4 | unchanged |
| URAM288 | 66 | 68 | +2 |
| synthesis core_clk WNS | +0.123 ns | +0.123 ns | unchanged |

**A symbol costs about a third of the current design in LUTs.** That is the
price ladder (27.5 k of it) plus its own `fast_bbo`, `bbo_merge` and
`sweep_detect`, plus the merge — everything a *book* belongs to is replicated,
and everything the *wire* belongs to is not. Four symbols would be roughly 155 k
LUTs, ~12 % of the device: comfortable, and still not the binding constraint.

**The binding constraint is the table, and it is not in that LUT number.** The
build above keeps `OT_SETS_BITS = 13`, which the capacity table above says is
enough for exactly one symbol — two need 2^14 × 16, i.e. **128 URAM instead of
64**. The synthesis script does not raise it automatically, on purpose: the two
parameters move together for a reason the tool cannot see, and a build that
silently resized the table would hide half the answer.

**Run on the card.** A Phase B bitstream at `NSYM=2`, `OT_SETS_BITS=14` — real
`cmac_usplus`, GT in near-end loopback — tracking AAPL (locate 13, band
2,800,000) and QQQ (locate 6556, band 2,100,000) through the same real 5 M
replay, with the second symbol configured over the per-symbol register block:

| | |
|---|---|
| AAPL orders | **70, identical to the single-symbol golden** on side/shares/price, in order |
| QQQ orders | 9,763, **every price inside its own ladder band** |
| positions | sym0 **+800**, sym1 **−500** — independent |
| BBO records | 90,397 (64,392 early / 26,005 late), `st_bbo_mismatch = 0` |
| `st_bbo_arb_drop` | 0 |
| frames | built 9,833, captured 9,833, `cdc_drop=0`, `rx_err=0` |

**The band check is the one that matters.** A second book that had silently
inherited symbol 0's configuration — the failure mode a shared ladder base would
produce — emits *AAPL* prices under QQQ's name, and those fall outside QQQ's
band by a factor of ten. Zero of 9,763 do. Together with AAPL's 70 orders being
byte-for-byte the single-symbol result, that is the claim the whole multi-symbol
design makes: each book behaves as though it were the only one.

**An unconfigured symbol slot is inert only if something makes it inert.** The
first single-symbol run taken *after* the two-symbol one reproduced the
two-symbol result exactly -- 9,833 orders, not 70 -- because configuration
registers survive a run: XRT does not reprogram the device when the same xclbin
is already loaded, so a run configuring fewer symbols than the last one inherits
the rest. Nothing was wrong with the datapath; the measurement was of a
configuration nobody had asked for, and it would have been read as an AAPL-only
number. `t2t_run` now writes EVERY slot the build has, giving unused ones locate
0xFFFF -- a locate no NASDAQ stock carries -- rather than 0, which the order
table would match. With that, the single-symbol run on the two-symbol bitstream
gives 70 orders and 1,174/605 again, and switching between the two
configurations is repeatable in both directions.

**A second book is not a second AAPL.** QQQ produces 90,397 BBO records against
AAPL's 1,779 over the identical replay, and 9,763 orders against 70. The first
attempt at this run overflowed an 8,192-record capture that had been sized for
the single-symbol rate and lost 3,025 beats in the CDC behind it — a harness
limit, correctly reported by `t2t_run` rather than diffed into a mystery. The
latency figures from this run are therefore **not comparable** with the
single-symbol ones (154 vs 152 cycles minimum, but at 140× the order rate).

**It met timing at 300 MHz with no automatic frequency scaling**, which neither
single-symbol build did — both were scaled for a sub-100 ps miss in the capture
DMA. That is placement luck on a larger design rather than evidence that more
logic closes more easily, and it is recorded as an observation, not a result.

**Post-route, across four directive sets per configuration** (`make sweep-t2t
SWEEP_FAST=1 SWEEP_NSYM="1 2"`, then the same at `OT_SETS_BITS=14`):

| | best fMAX | worst | spread | builds that met timing |
|---|---|---|---|---|
| NSYM=1, 2^13 × 16 | 220.0 MHz | 218.6 | 1.4 MHz | 4 of 4 |
| NSYM=2, 2^13 × 16 | **220.7 MHz** | 219.4 | 1.3 MHz | 4 of 4 |
| NSYM=2, 2^14 × 16 | 217.9 MHz | **211.4** | **6.5 MHz** | **1 of 4** |

**The books are free and the table is not.** Replicating the ladder, the fast-BBO
tracker and the sweep detector for a second symbol costs −0.7 MHz best to best,
inside a 1.4 MHz spread: not measurable. Doubling the order table to the geometry
that second symbol actually *needs* costs 2.8 MHz at the best directive, blows the
spread out from 1.3 to 6.5 MHz, and leaves **three of four builds missing timing**
(7, 3 and 33 failing endpoints). Only `netdly` closes.

**That is the URAM cascade, and §4.1 predicted it.** The worst paths in the failing
builds are the message FIFO's BRAM and `u_otab/g_way[3].u_mem/.../mem_reg_uram_0`
— the same cascaded-URAM region that made 2^16 × 8 unshippable and drove the
choice of 2^13 × 16 in the first place. 2^14 is two URAM deep per way instead of
one; it is survivable where 2^16 was not, but it is where the difficulty lives.

**So the two parameters moving together is not bookkeeping, it is the whole
result.** `order_table` refuses to imply `SETS_BITS` from `NSYM`, and
`synth_t2t.tcl` refuses to raise it automatically, precisely so that a
multi-symbol build cannot quietly become a timing problem nobody attributed. A
two-symbol design is shippable — 217.9 MHz still clears the 195.3 MHz the wire
demands — but it is directive-sensitive in a way the single-symbol build is not,
and that is a fact worth knowing before committing to four names rather than
after.

Cell counts confirm the split: NSYM=1→2 at the same geometry is +32,687 LUTs and
+2 URAM; the resize adds a further **+64 URAM** (68 → 132) and eight LUTs.

## 5. Sweep (momentum ignition) signal — measured on real data (step 6 strategy)

A sweep = an aggressive marketable order walking one side's resting liquidity
across several levels. In ITCH it is not D/X (the owner's cancel) but an
**execution (E/C)** consuming the resting size — resting ASK consumed = a buy
sweep (up), resting BID consumed = a sell sweep (down). It qualifies as a sweep
when same-direction executions continue within a gap and consume >= MIN_LEVELS
distinct price levels.

**Detection is the easy half. What decides the trading value is the forward
return** — after a sweep, does the mid continue in that direction (continuation)
or revert? A momentum-ignition strategy takes the sweep's direction, so the
signed forward return has to be positive to mean anything.

AAPL, the first 40M feed-message slice of the day (loc=13,
[dump_sweep.py](../step6-strategy/scripts/dump_sweep.py)):

| Sweep size | Events | +1ms continuation | +1ms median | +100ms continuation |
|---|---|---|---|---|
| >=2 levels | 554 | 58.5% | +50 (½ tick) | 63.0% |
| >=3 levels | 88 | **75.0%** | +100 (1 tick) | 75.0% |
| >=4 levels | 26 | 76.9% | +125 | 76.9% |

- **Sample size flipped the conclusion.** In the first 5M slice (early session,
  n=23) short-term continuation was 39% — under 50% (reversion) with only the mean
  positive, noise pulled up by a few outliers. Growing to 40M stabilises
  continuation at 58–63% across horizons. A sweep is a rare event you cannot see
  in a small window.
- **The bigger the sweep, the stronger the continuation** (monotonic): from
  >=2 -> >=3 -> >=4 levels, +1ms continuation is 58.5% -> 75.0% -> 76.9%, and the
  median move +50 -> +100 -> +125. Exactly what the momentum-ignition hypothesis
  predicts — a bigger ignition draws a bigger follow-through. Adopted signal
  point: **>=3 levels** (88 events, 75% continuation, median 1 tick).
- **Stated limits**: one symbol, one day. Transaction cost, queue position and
  adverse selection are unmodelled. A positive forward return is evidence the
  mechanism is real, not a tradeable edge. The median 1-tick move is the same
  order of magnitude as the cost of crossing AAPL's real 1-tick spread — the edge
  is thin, which is exactly why 22 ns latency and cost management are the alpha.

### 5.1 Tuning the two knobs on real data — gap dominates (cfg_sweep_gap / min_levels)

§5 chose the signal point at >=3 levels but judged it on continuation % alone,
with the **gap window pinned at 1 ms**. gap is a knob too (cfg_sweep_gap): too
small and one sweep is cut into pieces that each miss MIN_LEVELS; too large and
separate aggressions merge into one run whose forward return is diluted. And the
metric was changed from continuation % to a **P&L proxy** — net = avg +1ms return
in the sweep direction − a round-trip cost (1 tick = 100, crossing the spread
twice). The book state is independent of the two knobs, so the 40M feed is parsed
**once** to build the mid timeline and the execution list, then the
(gap, min_levels) grid is re-scored cheaply
([sweep_grid.py](../step6-strategy/scripts/sweep_grid.py), AAPL loc=13, 40M
messages, 10155 executions).

net/trade (1e-4 units, +ve = continuation beyond cost):

| gap↓ \ min_levels→ | 2 | 3 | 4 |
|---|---|---|---|
| **0.10 ms** | +43.8 (n=232) | +241.1 (n=28) | +277.8 (n=9) |
| **0.25 ms** | +19.9 (n=296) | **+152.6 (n=38)** | +185.0 (n=10) |
| **0.50 ms** | +2.5 (n=387) | +109.4 (n=53) | +157.7 (n=13) |
| **1.00 ms** (§5) | −24.8 (n=541) | +33.0 (n=88) | +56.0 (n=25) |
| **2.00 ms** | −36.8 (n=599) | −10.5 (n=114) | −12.9 (n=35) |
| **5.00 ms** | −42.7 (n=704) | −20.8 (n=149) | −28.7 (n=47) |

- **gap is the dominant knob, and §5's 1 ms was bad.** At 1 ms, ml=2 has net −24.8
  and **loses money**, and ml=3 is only +33. Dropping gap to 0.25 ms lifts ml=3 to
  +152.6. As gap grows 0.25 -> 5 ms every cell degrades monotonically — the
  "separate aggressions merge and dilute" mechanism. §5 missed it because gap was
  pinned.
- **There is no knee — it is a frequency/purity frontier.** net/trade improves
  monotonically across the tested range (5 ms -> 0.10 ms) while n falls (ml>=3:
  53 -> 38 -> 28). That drop in n is not real sweeps being split but mostly
  **merges being rejected** (what a wide window bundled into one was actually
  separate aggressions). Total capture net×n is flat for ml=3 across 0.10–0.35 ms
  (5800–6750).
- **Adopted: gap = 0.25 ms (250,000 ns), min_levels = 3.** The auto-optimiser picks
  gap=0.10 ms · ml=2 by net×n (total 10150), but that is the thin-edge/high-freq
  corner at +43.8/trade, the most exposed to the costs the model omits (queue
  position, adverse selection, fees). Per §5's "the edge is thin" caveat, **margin
  is preferred over frequency**: 0.25 ms · ml=3 has net **+152.6/trade** (survives
  2.5× the cost proxy), 81.6% continuation, n=38, net×n 5800 — a robust interior
  point on the plateau. min_levels=3, chosen on continuation % in §5, is here
  **re-confirmed on a P&L basis**.
- **Limits**: still one symbol, one day, and the cost proxy is crude (fixed 1-tick
  round trip, no queue/adverse selection). No U-turn was seen below 0.10 ms, so
  0.25 ms is a **robustness choice**, not a proven global optimum. The deployment
  config's sweep_gap (e.g. the CFG in
  [test_session.py](../step7-host/tests/test_session.py)) was lowered 1 ms ->
  0.25 ms.

### 5.2 The imbalance parameters were tuned on pre-market data (full-day fix)

The strategy's spread threshold was derived from the first 5 M messages of the
day, and every document in this project carried the caveat that this was "a thin
reconstructed book, not real AAPL". Measured over the **full day** with
`itch_parser`, split by session, that caveat turns out to have understated the
problem — the 5 M slice is not merely thin, it is **entirely pre-market**:

| session | records | p10 | p25 | **p50** | p75 | p90 | p99 |
|---|---|---|---|---|---|---|---|
| pre-market (04:00–09:30) | 1,921 | 500 | 900 | **1700** | 2900 | 4000 | 9300 |
| **regular hours (09:30–16:00)** | **422,301** | **100** | **200** | **300** | **400** | **500** | **700** |
| post (16:00–20:05) | 435 | 400 | 800 | 1300 | 2000 | 2900 | 22400 |

Spreads in 1e-4 units; 424,657 two-sided BBO records over the day.

**The 17-cent median the parameters were chosen against is the pre-market
distribution**, reproduced here exactly (p50 1700). Real AAPL during regular hours
is **3 cents**, with 96.1 % of quotes inside 5 cents and 11.9 % at a single tick.

**So `max_spread = 2000` selects nothing.** Every RTH quote is inside a 20-cent
threshold, which means the "tight spread" half of the signal was not a filter at
all. Sweeping the threshold against the 422,301 RTH records shows where it starts
to bind:

| `max_spread` | 100 | 200 | 300 | 400 | 2000 |
|---|---|---|---|---|---|
| orders, `ratio_shift=1` (2:1) | 6,365 | 14,689 | 22,645 | 26,474 | 28,230 |
| orders, `ratio_shift=2` (4:1) | 1,734 | 4,743 | 8,175 | 10,505 | 11,599 |

2000 and 400 differ by 6 %: the threshold is inert above ~400. A **venue operating
point** derived from this data rather than from pre-market is `max_spread = 100`
(one tick — what "tight" actually means for AAPL, the tightest 11.9 % of quotes)
with `ratio_shift = 2` (4:1 size imbalance), giving 1,734 orders across the
session, roughly one per 13 seconds.

**What this fixes and what it does not.** It fixes the calibration: the parameters
now describe a genuinely tight market instead of a threshold that admits
everything. It does **not** establish an edge. That needs the forward-return
treatment §5 gave the sweep signal — does the mid actually move in the taken
direction after an imbalance fires — and until that is measured, the imbalance
signal tests the mechanism only. The sweep signal remains the one with measured
forward returns behind it.

**The test configuration is deliberately not changed.** Every golden in the repo
is generated from the 5 M pre-market slice, where a 100-unit threshold fires
almost nothing and the risk gates would never bind. Test parameters are chosen so
the gates are exercised; venue parameters are chosen from the data above. Those
are different jobs and conflating them is what produced this finding in the first
place.

### 5.3 Does the imbalance signal have an edge? Predictive, and not tradeable

§5.2 fixed the calibration and said what was still missing: the forward-return
treatment §5 gave the sweep. Same method, full day, regular hours only
([imbalance_edge.py](../step6-strategy/scripts/imbalance_edge.py),
`make -C step6-strategy imbalance-edge`).

The rule is taken from `strategy.sv` including the **rising-edge detector**,
which is not a detail: the condition holds across long runs of BBO records and
the hardware sends one order per run, so measuring the condition rather than the
edge would count one opportunity thousands of times.

A continuation rate means nothing on its own, so each cohort is measured against
the population it is drawn from:

| cohort | what it is | events (RTH) |
|---|---|---|
| `fired` | rising edges at the venue point (`max_spread=100`, `shift=2`) | 2,411 |
| `leaning` | the size ratio alone — no spread filter, no edge detector | 110,396 |
| `all` | every two-sided record, direction = the bigger side | 374,800 |

Signed mid move, +1 ms, AAPL 2019-12-30, 1e-4 units:

| cohort | n | up | flat | down | of moves, continued | mean | net of half-spread |
|---|---|---|---|---|---|---|---|
| `fired` | 1,600 | 40.1 % | 46.6 % | 13.4 % | **75.0 %** | **+22.7** | **−27.3** |
| `leaning` | 68,257 | 42.2 % | 37.0 % | 20.9 % | 66.9 % | +21.8 | −118.6 |
| `all` | 233,622 | 38.6 % | 37.9 % | 23.4 % | 62.3 % | +15.2 | −138.6 |

**The signal is real.** Three of four resolved moves continue in the direction
the order was pointed, against 62 % for the population — 642 up against 214 down,
about 7.7 standard deviations from the population rate, so not a small-sample
artefact. It holds at longer horizons too: 70.4 % at +10 ms and 69.6 % at +100 ms,
against 60.8 % and 59.9 %.

**And it does not pay.** The conditional mean move is **+22.7**, i.e. 0.23 cents.
Entry costs half the spread, and `max_spread = 100` admits only one-tick markets,
so **50 is the floor** — the predicted move is under half the cost of acting on
it before any exit, fee or queue effect. Net of that half-spread the mean is
**−27.3** and only 23 % of events clear it. No horizon changes this: −31.2 at
+10 ms, −28.6 at +100 ms.

**Selectivity makes it worse, which is the opposite of the sweep.** §5 found the
momentum signal strengthened monotonically with size (58.5 % → 75.0 % → 76.9 %).
Imbalance decays:

| `ratio_shift` | 1 (2:1) | 2 (4:1) | 3 (8:1) | 4 (16:1) | 5 (32:1) |
|---|---|---|---|---|---|
| fired (RTH) | 8,772 | 2,411 | 507 | 242 | 125 |
| of moves, continued | 73.3 % | 75.0 % | 67.6 % | 62.8 % | 63.9 % |
| mean move | +24.4 | +22.7 | +8.5 | **+0.3** | +5.7 |

At 16:1 the signal is gone. An extreme queue imbalance is not a stronger version
of a mild one — a mild lean predicts the next tick, an extreme one at a one-tick
spread is a book about to be replenished or a queue nobody will cross. Whatever
the mechanism, the data says do not look for the edge by tightening the ratio.

**What the spread filter is actually for.** `leaning` predicts almost as well as
`fired` (+21.8 against +22.7): the direction lives in the size ratio, and
tightness adds nothing to prediction. What it does is cut the cost — net −118.6
to −27.3 — because it refuses to cross a wide market. It earns its place
economically, not predictively.

**Conclusion.** The imbalance signal has measurable predictive content and no
tradeable edge as a spread-crossing taker on this symbol-day. That is a real
answer to the question §5.2 left open, and it does not generalise past one
symbol and one day. Making it pay needs a bigger move (the sweep signal, which
has one) or an entry that does not cross — and this design is a taker by
construction, so the second is a different machine, not a parameter.

**The deployed parameters do not change.** `shift=1` and `shift=2` are a wash for
prediction (73.3 % against 75.0 %, means within 2), so the choice between them
still rests on order rate as §5.2 said, and the test configuration stays on the
pre-market slice for the reason given there.

## 6. Is II=1 needed — measurement answers (order table throughput vs latency)

The order table is a correctness-first FSM at 6 cycles per message (11 for U),
~36.7 M msg/s at 220 MHz. Rather than **assume** II=1 (a pipeline, 1 message per
cycle) is needed, it was re-measured on a real 100G arrival trace (the 2-server
backlog sim in [itch_hist.c](../step1-sw-parser/itch_hist.c): the same wire drains
two queues, splitter and order table, at their own service rates).

Full day:

| Server | Max backlog | 512-msg FIFO drops |
|---|---|---|
| splitter (1 msg/cy @ 322 MHz) | 76 msgs / 2356 B | 0 |
| order table (6 cy/msg @ 220 MHz) | **453 msgs** / 14043 B | **0** |

- **Throughput does not need II=1.** The 6 cy/msg FSM absorbs the day's worst burst
  (453 msgs, the 501 msg/µs spike at 15:59:56) with 0 drops into fh_core's existing
  512-deep msg FIFO. That is not luck but measured headroom (453/512, 12%).
- **What II=1 actually buys is latency during a burst.** A 453-msg backlog means a
  message at the queue tail waits 453 × 27 ns ≈ **12.4 µs** to reach the order
  table — precisely the latency at the burst moment where trading opportunities
  cluster, which is the point in tick-to-trade.
- The model is conservative (safe side): it omits MoldUDP64/UDP/Eth packet
  overhead, so arrivals are denser than reality -> the real backlog is lower.

**Conclusion**: the order is (1) cheap cycle savings — 2^13×16 has a 2-deep URAM
cascade (not the old 16-deep), so RD_LAT can be lowered -> reduce 6 cy/msg and
shrink the burst latency proportionally; (2) if still short, full II=1 (a pipeline
+ hazard forwarding), the big job. Measurement nailed down that latency, not
drops, is the target.

### 6.1 full II=1 pipe — verification and synthesis (order_table_pipe)

full II=1 was actually built
([order_table_pipe.sv](../step4a-order-table/rtl/order_table_pipe.sv), a
hazard-stall pipe, a drop-in with ports identical to the iterative order_table).
It was pressed all the way with golden diffs:

- Submodule synthetic golden PASS, real-data 5M BBO == golden (0 drops, 0
  overflow), collision-stress order-table output **byte-identical** to iterative
  (2250==2250).
- Full chain (t2t_top, `+define+OT_PIPE`) wire -> order frames byte-identical to
  non-pipe: `PASS: pipe wire -> order frames == golden`, gap 0 / ot_overflow 0 /
  beat·msg·delta drops 0 (oob=465 are deep quotes outside the ladder band,
  dropped by design).

**Synthesis (pre place & route, optimistic)** — `OT_PIPE=1 make synth-t2t`,
xcu55c, OT=2^13×16:

| Metric | Value |
|---|---|
| LUT | 55,234 |
| FF (FDRE) | 17,978 |
| URAM288 | 66 |
| BRAM (36/18) | 31 / 2 |
| DSP | 2 |
| cmac_clk (322.27 MHz) WNS | +1.304 ns (met) |
| core_clk (216.5 MHz target) WNS | **−0.298 ns** (missed, Fmax est. 203.4 MHz) |

- **The critical path is not the II=1 pipe.** The worst path is mold_splitter's
  `msglen_reg[6] -> vcnt_reg[7]` (21 logic levels, route-dominated 71.8%) — the
  arithmetic chain from message length to a valid-byte count, a path shared with
  non-pipe too. The pipe order table itself closed timing locally.
- **The real requirement is 195.3 MHz** (5.120 ns, 512b × 195.3M = 100 Gb/s floor);
  216.5 was a headroom target. At the 4.899 ns data-path delay (4.916 ns arrival),
  195.3 MHz gives slack **+0.204 ns -> met**. So even the optimistic synthesis
  number already satisfies 100G line rate.
- LUT grew over iterative (pipeline stages + a hazard shift register). Trading that
  cost to remove the burst-time order-table wait (§6's ~12.4 µs) with one message
  per cycle is II=1's exchange.

**Closing 216.5 MHz by retiming (splitter msglen -> vcnt).** The retiming flagged
for the −0.298 path above was actually applied: `msglen+2` (the value both consume
and msg_ready use) is precomputed into a register (`mlen2`) from `win_next`, moving
that +2 adder out of the head of the msglen -> consume -> vcnt chain and into
**parallel** with the msglen register. mlen2 ≡ msglen+2, so behaviour is exactly
the same — real-data 5M BBO and the full chain wire -> order frames are both
**byte-identical** (both PASS).

| | before retiming | after retiming |
|---|---|---|
| core_clk WNS (216.5 MHz) | −0.298 ns | **+0.152 ns (MET)** |
| logic levels | 21 | **18** |
| data-path delay | 4.899 ns | 4.446 ns |
| worst path | mold_splitter `msglen->vcnt` | price_ladder `r_add_diff->r_fwd` |

- **216.5 MHz is MET at synthesis** (0 failing endpoints, total violation
  0.000 ns). Removing one +2 adder (a carry chain ~3 levels) took 4.899 -> 4.446 ns
  and flipped the sign.
- **The bottleneck left the splitter** — now price_ladder's add-diff -> forward path
  is the limiter (synth +0.152, post-route +0.196). If more headroom is needed
  next, that is the target.

**Post-route measurement (`OT_PIPE=1 make impl-t2t`, xcu55c, 216.5 MHz target).**
The old worry that "this family's post-route was worse than synthesis" is reversed:
after retiming the limiting path is route-dominated and P&R slightly beat the synth
estimate:

| Metric | post-route |
|---|---|
| Overall WNS (core, 216.5 MHz) | **+0.196 ns (MET)**, 0 failing endpoints |
| core Fmax | ≈ 226 MHz |
| cmac_clk WNS (322.27 MHz) | +0.567 ns |
| critical path | price_ladder `r_add_diff->r_fwd`, 16 logic levels |
| LUT / FF | 44,511 / 18,553 |
| URAM / BRAM / DSP | 66 / 32 / 2 |

- **The II=1 full tick-to-trade chain closes 216.5 MHz post-route** (+0.196 ns).
  Now measured, not a synth estimate. LUT dropped from synth 55k as opt/place
  trimmed it to 44.5k.
- Meeting the headroom target (216.5) rather than the line-rate floor (195.3) on
  real P&R means the core frequency that buys the burst latency (§7, II=1 takes
  10.04 -> 0.95 µs) matches the sim assumption (220).
- **The full wrapper (t2t_axil, 3 clocks) also closes post-route** (`impl-axil`):
  core +0.056, axil_clk +0.547, cmac +0.281 ns, overall +0.056 MET, 0 errors. The
  async clock groups held through P&R (otherwise the cross-domain paths would show
  huge violations). 46,371 LUT / 23,817 FF / 66 URAM / 40 BRAM / 2 DSP — the whole
  integrated design (datapath + regfile + CDC + arbiter + IGMP) places, routes and
  closes timing.

## 7. Latency budget — tick-to-trade per stage + II=1's burst effect (measured)

§6 concluded II=1 is for **burst latency**. Here that latency is summed exactly in
two parts: (A) the unloaded tick-to-trade of one message with the pipe empty, and
(B) the added wait when the queue builds during the day's worst burst.

### 7.1 Unloaded budget (stage depth × domain clock)

Pipe depth of each RTL stage on the wire-in -> order-out path (core 4.618 ns =
216.5 MHz, CMAC 3.103 ns). Cycle counts are read from each FSM (±1 cy/stage, not
gate-level).

| Stage (core domain) | Cycles | Note |
|---|---|---|
| cdc_fifo RX (CMAC->core) | ~3 | SYNC_FF=2 + registered read |
| eth_ip_udp_rx | ~2 | header strip + realign |
| beat FIFO + mold_splitter | ~2 | to the first message |
| itch_decoder | 1 | 512b, 1 msg/beat |
| msg FIFO + order_table | 5 | iterative and pipe **identical** (PDEPTH+1) |
| **[imbalance]** price_ladder | ~10 | RMW-split FSM (deep for timing) |
| **[sweep]** sweep_detect | ~1 | taps the order-table delta directly -> **bypasses the ladder** |
| strategy | 2 | stage1 eval + stage2 gate/emit |
| ouch_builder | 1 | no state machine, combinational |
| tcp_tx | ~2 | first beat at CALC |
| cdc_fifo TX (core->CMAC) | ~3 CMAC | ≈ 9.3 ns |

- **Sweep path ≈ 19 core cycles ≈ 90 ns**, **imbalance path ≈ 28 core cycles ≈
  135 ns** (+TX cdc ~9 ns). MAC/PHY serialisation and wire propagation are outside
  our RTL and not included.
- **The sweep (momentum) path is faster**: sweep_detect takes the order-table delta
  directly and skips the 11-cycle price_ladder. The very strategy tuned in §6 is
  the low-latency path.
- **Unloaded latency is the same for iterative and pipe** — the order table's
  single-message latency is 5 cy either way. II=1 changes nothing here. This
  latency comes mostly from FSMs deliberately split deep for timing closure (ladder
  10 cy, table 5 cy) — traded against Fmax.

### 7.1.1 Cut-through decode: measured as a no-op, and not built

PLAN §3 held cut-through decode — "fire the instant the last needed field
arrives" — as a deferred optimisation to be done once the pipe was complete, with
a before/after comparison on the same replay. The pipe is complete, so this is
that evaluation. **The answer is that the width change already took the win.**

The idea dates from when the datapath was 64 bits (steps 2 and 3a), where a
message spanned several beats and there was a real window between "the field I
need has arrived" and "the message has ended". At 512 bits that window is gone:

- `MAX_MSG_BYTES = 50` — the largest ITCH 5.0 message ('I', NOII);
- `mold_splitter` at `DATA_W=512` emits `m_tlast = 1` on **every** beat, 64 bytes
  per beat.

So every message is delivered complete in a single beat, and `itch_decoder`
registers it one cycle later. A cut-through variant could only collapse that one
register stage — **1 core cycle, 4.65 ns at 215 MHz**. Against the measured
in-fabric path that is 2.2 % (of 206.7 ns), and against wire-to-wire 0.9 % (of
515.1 ns).

The cost is the wrong shape for this design: it means decoding a 512-bit beat
into `itch_msg_t` combinationally — field extraction plus type dispatch across
some twenty message types — and putting that ahead of the register, in the core
domain whose worst path is already 21 logic levels and whose margin was just
clawed back from +0.011 ns to +0.099 ns (§7.6.2). Every timing fix in this project
has gone the other way: *adding* register stages to break combinational depth.

**Not built.** Recorded here so the deferred item is closed with arithmetic rather
than left looking undone. If the datapath ever narrows again, the idea comes back
with it.

### 7.2 Burst tail latency (full day 268.7M messages, itch_hist 3-server)

The same 100G arrival trace drains splitter, iterative and II=1 pipe at their own
service rates, and the queuing wait (tail) each message actually experiences is
tracked directly:

| Server | max backlog | **burst tail latency** |
|---|---|---|
| splitter (1 cy @322 MHz) | 76 msgs | 0.23 µs |
| order table iterative (5–9 cy @220) | 443 msgs | **10.04 µs** |
| order table II=1 pipe (1 cy @220) | 211 msgs | **0.95 µs** |

- **II=1 cuts the burst tail 10.04 µs -> 0.95 µs, 10.6×** (confirming §6's ~12.4 µs
  estimate with a precise measurement). The worst moment is 15:59:56 for both (the
  spike just before the close).
- **The pipe is not zero either — because the core is slower than the wire.** The
  pipe drains at 220 msg/µs while the splitter pushes at 322 msg/µs, so a residual
  backlog (211) builds. But it drains 5× faster than iterative's 44 msg/µs, so the
  tail falls from single-digit µs to sub-µs. A 216.5 MHz core cannot remove burst
  queuing, only **cut it by an order of magnitude**.

### 7.3 Combined — worst-burst tick-to-trade

Unloaded (A) + burst tail (B):

| | unloaded | + burst tail | = worst tick-to-trade |
|---|---|---|---|
| iterative | ~135 ns | 10.04 µs | **~10.2 µs** |
| II=1 pipe | ~135 ns | 0.95 µs | **~1.1 µs** |

- **~135 ns when idle, queue-dominated in a burst.** So II=1's entire value is in
  the burst (re-confirming §6's conclusion): worst tick-to-trade **~10 µs -> ~1 µs**.
- **Limits**: (1) unloaded cycles are datapath pipe depth, not gate-level (±1
  cy/stage), and exclude MAC/PHY/wire. (2) The backlog model charges the order
  table full FSM latency for **every** message (§6's assumption) — iterative
  actually skips non-tracked symbols faster, so 10.04 µs is a **conservative upper
  bound**, while the pipe's 1 cy is exact regardless of type (only rare hazard
  stalls ignored). So 10.6× is an upper-ish estimate of the benefit. (3) The core
  220 MHz model (post-route 216.5).

### 7.4 Measured on silicon (step 8) — the unloaded half, no longer summed

§7.1 above is a **sum of per-stage FSM state counts**. Step 8 measures the same
path on a real U55C with a hardware probe (`step8-hw/rtl/lat_probe.sv`), replaying
this same 5 M-message AAPL session out of HBM:

| | source | wire-to-order |
|---|---|---|
| §7.1 estimate | summed stage depth, ±1 cy/stage | ~135 ns |
| **step 8, measured on silicon** | 70 attributable samples, 0 excluded | **220 ns min, 281 ns mean, 443 ns max** |

**These are not the same measurement, and the difference is mostly definitional
rather than error.** The probe stamps the frame's *first RX beat*; §7.1 starts
after the RX clock crossing and counts core cycles only. Frame reception, the beat
FIFO and both CDC crossings are inside the measured number and outside the summed
one. The measured core also runs at 200 MHz here, not the 216.5 MHz §7.1 assumes
(step 8 traded 20 MHz for timing margin inside the shell's pblock). Adding those
back accounts for the bulk of the gap.

What the measurement adds that the sum could not:

- a **distribution** rather than a point — 69 of 70 samples in one power-of-two
  bucket, i.e. genuinely tight when the pipeline is empty;
- a **guard**: samples whose frame did not arrive into a provably empty pipeline
  are excluded and counted, so the number cannot quietly be an under-estimate.
  This run excluded none;
- **corroboration of two other numbers in this file** from the same silicon run:
  the RX filter kept exactly the 1,122,567 good frames `mold2eth.py` produced, and
  the price ladder reported exactly the 465 out-of-band cases §4/step 4b measured.

### 7.5 The burst tail: a second probe, and no threaded tag after all

§7.4's probe requires an empty pipeline to attribute an order to its frame, which
is by definition not the case during a burst — so it cannot answer §7.2, and every
sample taken under load would be excluded rather than wrong. The obvious remedy is
a timestamp threaded through splitter, decoder, order table, ladder, strategy,
builder and framer: seven verified modules whose interfaces would all have to
widen and whose goldens would all have to be re-confirmed.

That work turned out to be unnecessary. **The datapath already threads a unique
per-message field end to end** — the ITCH timestamp. `itch_msg_t.timestamp`
survives into `order_table.o_ts`, into `price_ladder.o_ts`, into `strategy.o_ts`,
and `t2t_top` exposes it as `ord_ts`, meaning "the exchange timestamp of the
message that caused this order". The message's identity is therefore already at
both ends of the path; the only thing missing was *when it arrived*. `lat_loaded`
records that, keyed by timestamp, and subtracts when the order fires. Two
observation taps, no datapath change.

It measures decoder-output to order-emit, which contains the message FIFO, the
order table, the delta FIFO, the ladder and the strategy — every queue on the
path, which is where §7.2's tail lives. It excludes the fixed front end, which
does not queue and is already inside §7.4's figure, so the two probes bracket the
whole.

In simulation (synthetic feed, 215 MHz core): **min 33, mean 51, max 73 core
cycles** — 153/237/340 ns — with 0 misses. That is the unloaded shape of this
interval, not the burst tail; the offered load in that run is one frame at a time.
The card reproduces those three numbers bit-for-bit on the same stimulus, which is
the probe being checked against a known answer before it is asked an unknown one.

### 7.5.1 The burst tail, measured on silicon

Run on the card against the real 5 M-message AAPL replay, sweeping `--gap` (idle
`ap_clk` cycles between injected frames) to vary offered load. 70 orders, 70
samples, 0 misses at every non-saturated point; core 215 MHz, 4.651 ns/cycle:

| offered | msg drops | golden | min | mean | max |
|---|---|---|---|---|---|
| 25.1 M msg/s | 0 | PASS | 23 cy / 107.0 ns | 34.2 cy / **159.2 ns** | 71 cy / 330.2 ns |
| 29.6 M msg/s | 0 | PASS | 23 cy / 107.0 ns | 37.1 cy / **172.7 ns** | 77 cy / 358.1 ns |
| 32.6 M msg/s | 0 | PASS | 23 cy / 107.0 ns | 39.7 cy / **184.5 ns** | 93 cy / 432.6 ns |
| 36.1 M msg/s | 0 | PASS | 23 cy / 107.0 ns | 44.3 cy / **206.1 ns** | 122 cy / 567.4 ns |
| 40.6 M msg/s | 0 | PASS | 23 cy / 107.0 ns | 51.1 cy / **237.9 ns** | 157 cy / **730.2 ns** |
| 46.3 M msg/s | 389,994 | DIFF | — saturated — | | |

Four things this says that the model could not:

1. **The floor is load-independent.** `min` is 23 cycles / 107.0 ns at every point.
   An empty pipeline costs what it costs, and load never improves or erodes it.
2. **The tail degrades 2.2× faster than the mean.** Across the same 1.6× increase
   in offered rate the mean grows 1.49× (159 → 238 ns) while the max grows 2.21×
   (330 → 730 ns). That divergence is the burst tail, and it is why quoting a mean
   for this design would be misleading.
3. **Saturation is sharp, not gradual** — zero drops at 40.6 M msg/s, then 389,994
   dropped messages at 46.3 M. There is no soft shoulder to operate on.
4. **Degradation is by dropping, never by lying.** Every non-saturated point is
   byte-identical to the golden; the saturated one drops and counts. The design
   has no regime in which it emits a *wrong* order.

**A second book lowers the saturation point, and the table is why.** Same card,
same replay, same gap ladder, `NSYM=2` tracking AAPL and QQQ:

| gap | offered | msg drops | orders | AAPL vs golden | loaded min / mean / max |
|---|---|---|---|---|---|
| 48 | 25.3 M msg/s | 0 | 9,833 | PASS | 13 / 54.8 / 483 cy |
| 40 | 29.9 M msg/s | 0 | 9,833 | PASS | 16 / 80.8 / 749 cy |
| 36 | 32.8 M msg/s | 0 | 9,833 | PASS | 16 / 99.9 / 885 cy |
| 32 | 36.4 M msg/s | 0 | 9,833 | PASS | 16 / 121.2 / 1018 cy |
| 28 | 40.9 M msg/s | **111,370** | 25 | — saturated — | |
| 24 | 46.6 M msg/s | 712,250 | 14 | — saturated — | |

**The knee moves from between gap 28/24 to between gap 32/28** — from ~46.6 to
~40.9 M msg/s, about 12 % of absorbable rate for the second name. Single-symbol
runs gap 28 with zero drops; two symbols drop 111,370 messages there.

**That locates the bottleneck, which was the point of running this.** The
ladders are replicated, so K books keep K ladders' throughput; if the ladders
bound, a second one would cost nothing. The order table is *shared*, and it
admits inserts for every tracked symbol — QQQ contributes roughly fifty times
AAPL's book traffic — so its 2-3 cycles per message is doing far more work per
unit time. **Adding a symbol is nearly free in fMAX (§4.4), costs 58 % in LUTs,
and costs throughput at the table.** Those three are separate budgets and this
is the one that was unmeasured.

**The tail degrades much faster too.** Across the same 1.4× rise in offered rate
the mean grows 2.2× (54.8 → 121.2 cycles) against 1.35× for one book, and the
max reaches 1,018 cycles where one book reached 112 at the same gap. Two books
means 9,833 orders instead of 70, so this is a busier machine at every point,
not only a shorter-fused one.

**Saturated, it still does not lie.** At gap 28 and 24 the AAPL diff fails —
correctly, because messages were dropped and the golden covers a feed that was
not delivered — but QQQ's prices are *still* every one inside its own band. The
design degrades by dropping and counting, and even overloaded it did not emit a
single order at a wrong price.

**Re-measured with the fast book path.** The table above is the ladder-only
datapath. Same card, same replay, same gap ladder, `fast_bbo` in place:

| gap | offered | msg drops | golden | min | mean | max |
|---|---|---|---|---|---|---|
| 48 | 25.3 M msg/s | 0 | PASS | 23 → **14 cy** / 65.1 ns | 34.2 → **28.6 cy** / 132.9 ns | 71 → 73 cy / 339.5 ns |
| 40 | 29.9 M msg/s | 0 | PASS | 23 → **14 cy** | 37.1 → **31.4 cy** / 146.0 ns | 77 → 78 cy / 362.8 ns |
| 36 | 32.8 M msg/s | 0 | PASS | 23 → **14 cy** | 39.7 → **34.0 cy** / 158.1 ns | 93 → **84 cy** / 390.7 ns |
| 32 | 36.4 M msg/s | 0 | PASS | 23 → **14 cy** | 44.3 → **38.6 cy** / 179.5 ns | 122 → **112 cy** / 520.9 ns |
| 28 | 40.9 M msg/s | 0 | PASS | 23 → **14 cy** | 51.1 → **45.4 cy** / 211.3 ns | 157 → **148 cy** / 688.4 ns |
| 24 | 46.6 M msg/s | **389,995** | DIFF | — saturated — | | |

Three things, and the third is the one that matters:

1. **The floor improves by the same 9 cycles at every load.** 23 → 14 cycles at
   all five non-saturated points, exactly as the floor was itself load-independent
   before. A shorter common path is shorter whatever else is happening.
2. **The mean improves at every point** by 5.6 to 5.8 cycles — the same constant,
   which is what a change to the common path should look like and not what a
   change to queueing behaviour would.
3. **The saturation knee did not move at all.** Still between gap 28 and gap 24,
   and the saturated point drops **389,995** messages against the ladder-only
   run's 389,994 — one message different across a 5 M-message replay on a
   separately placed and routed bitstream. `fast_bbo` buys latency and buys
   **no throughput whatsoever**, which in hindsight is exactly right: it runs
   *beside* the ladder, gated on the ladder's own accept, so the ladder still
   processes every delta and the rate the design can absorb is unchanged. The
   task that produced this measurement asked whether the knee would move; it does
   not, and that is a fact about where the bottleneck is, not a disappointment.

**The tail diverges slightly less.** Over the same 1.6× rise in offered rate the
mean now grows 1.59× (was 1.49×) while the max grows **2.03× (was 2.21×)**, so
the tail-to-mean divergence falls from 1.48 to 1.28. The absolute worst case at
40.9 M msg/s is **688 ns, down from 730**. The conclusion §7.5.1 drew — quoting a
mean for this design misleads — survives; it is just marginally less extreme.

**The gap ladder is recorded here because it was not recorded the first time.**
The original table gave only derived message rates, so reproducing it meant
re-deriving the gaps from the frame count and the clock. The independent variable
belongs in the table with the results.

The measured tail is **730 ns, not the ~10 µs §7.2's model predicted** — but the
two are not measuring the same thing and the model is not thereby refuted. §7.2
models a full trading day's worst 1 ms burst arriving at a server pipeline; this
sweeps a uniform offered rate over a 5 M-message slice. What the silicon result
does establish is the shape (flat floor, superlinear tail, sharp knee) and the
saturation point, neither of which was previously measured on hardware.

Context for the rates: the design saturates above 40 M msg/s, which is **20–40×
the real NASDAQ peak** this project sized itself against. The load at which the
tail reaches 730 ns is not a rate this feed will present.

**Reproducing this needed a device reset between runs, and no longer does.** A run
that saturated left the datapath in a state the soft reset did not clear: the next
run, even at a gap with zero drops, produced `sent=0` with the RX counters
otherwise identical, and only `xrt-smi reset` recovered it. Root-caused to the
price ladder's quantity arrays, initialised by an `initial` block — correct at
power-on, meaningless at reset, and invisible to simulation because `initial` runs
at time 0 there. Fixed with an explicit clear-on-reset sweep and **verified on
silicon**: a saturating run (`drops(msg=1,682,346)`, `sent=0`) followed with no
device reset by `--gap 512` now gives `sent=70`, golden matched. See
step8-hw/README.md.

### 7.5.2 Composing the two probes: the bracket, measured

`lat_probe` reports RX beat to TX beat; `lat_loaded` reports decoder to order.
They are deliberately different intervals — `lat_loaded` excludes the fixed front
end because it does not queue, which is what lets it work without a tag threaded
through every stage. The consequence is that the two headline numbers cannot be
compared directly, and the fix is not to rebuild the probe (supplying it an
RX-beat stamp means threading beat-arrival time through the splitter, exactly what
the design avoids) but to **measure the constant between them**.

Both probes report from the same run, so subtracting is legitimate. Phase A, real
5 M AAPL, gap 512, unloaded:

| | |
|---|---|
| `lat_probe` min (RX beat → TX beat) | 206.7 ns |
| `lat_loaded` min (decoder → order) | 107.0 ns |
| **fixed front end + back end** | **99.7 ns** |

That 99.7 ns is RX, CDC, splitter and decode on the way in, plus builder, framer
and TX CDC on the way out — the part that does not queue. So **wire-to-order under
load = `lat_loaded` + 99.7 ns**, which composes the two tables in this section
rather than leaving them incommensurable. At the 40.6 M msg/s point the tail
becomes 730.2 + 99.7 ≈ **830 ns** in-fabric, and adding the measured MAC term from
§7.6 puts a fully loaded wire-to-wire worst case near 1.1 µs.

A slot-index detail worth recording, because it is the same lesson as §4: the
correlation table indexes on an **XOR fold** of the timestamp, not its low bits.
ITCH timestamps are nanoseconds since midnight and consecutive messages are
hundreds to thousands of nanoseconds apart, so raw low bits cluster exactly the
way raw `order_ref`s clustered in the order table (24,142 overflows raw vs 132
mixed). One XOR, same fix.

### 7.6 Wire-to-wire, through a real MAC (step 8 Phase B)

§7.4 measures from the first RX beat *inside the fabric*. A frame on a real
network has also crossed the MAC's receive path to get there, and the order has
to cross its transmit path to leave — neither of which any number in this file
has ever included.

Phase B puts a `cmac_usplus` in the design with the GT in near-end PMA loopback,
and that geometry makes the full measurement available from a single observation
point. Writing `T_rx` and `T_tx` for the MAC's two halves and `D` for the design,
stamping the *feed* frame as it leaves MAC RX and resolving when the *order*
returns through MAC RX gives `D + T_tx + T_rx`; wire-to-wire on a real network is
`T_rx + D + T_tx`. The same three terms, so the loopback measures the real thing,
overcounting only the SerDes round trip inside the GT.

Verified in simulation against the same golden as every other run — the order
frames are byte-identical after a round trip through the MAC, at both stimulus
gaps (48 and 512). The design also **implements with all timing met**, including
the MAC's own 322.269 MHz clock (see below for the shipped build's numbers).

**Simulation cannot supply the number, by construction.** Phase B adds ~145 ns to
the unloaded interval in simulation (403.4 ns against Phase A's 256.7 ns at the
minimum), and that delta is nearly constant across min, mean and max — because
124.1 ns of it is `cmac_wrap.sv`'s `MAC_LAT = 40` cycles, a constant the
behavioural stand-in chooses. The residual ~20 ns is real design cost
(store-and-forward fill plus the frame filter); the MAC, PCS and SerDes term is
not measured at all. The real IP needs GT models and tens of microseconds of link
training to simulate.

**Measured on silicon.** The bitstream loaded, the MAC brought its link up in
near-end PMA loopback (`aligned=1 link_up=1`), and the real 5 M-message AAPL
replay passed 1,127,130 frames through the IP with `rx_err=0 underrun=0
overflow=0`, producing 70 order frames byte-identical to the golden.

Both bitstreams were run back to back on identical stimulus (real 5 M AAPL, gap
512), so the MAC term is attributable rather than inferred:

| | Phase A (in fabric) | Phase B (through the MAC) | delta |
|---|---|---|---|
| min | 62 cy / **206.7 ns** | 166 cy / **515.1 ns** | +308.4 ns |
| mean | 78.9 cy / 263.0 ns | 186.6 cy / 579.1 ns | +316.1 ns |
| max | 124 cy / 413.3 ns | 239 cy / 741.6 ns | +328.3 ns |
| samples / excluded | 70 / 0 | 70 / 0 | |
| golden | PASS | PASS | |

Phase B's core runs 15 MHz slower (200 against 215 MHz). The loaded probe isolates
what that costs: 23 core cycles in both, 107.0 against 115.0 ns, so roughly 10 ns
of the delta across the core-domain path is clock rather than MAC. **That leaves
about 300 ns for MAC TX, MAC RX, the SerDes round trip, the store-and-forward fill
and the frame filter.**

### 7.6.0 The same measurement with the fast book path (added later)

Everything above is the ladder-only datapath. `fast_bbo` went in afterwards, and
the Phase B bitstream was rebuilt and re-run on the identical stimulus (real 5 M
AAPL, gap 512, same MAC, same loopback), so the two are directly comparable:

Both bitstreams were rebuilt and both phases re-run, so the whole table moves
together rather than mixing a fresh number with a stale one:

| real 5 M AAPL, gap 512 | ladder only | with `fast_bbo` | delta |
|---|---|---|---|
| **Phase B** wire-to-wire min | 166 cy / 515.1 ns | 152 cy / **471.7 ns** | **−43.4 ns** |
| Phase B mean | 186.6 cy / 579.1 ns | 177.8 cy / **551.9 ns** | −27.2 ns |
| Phase B max | 239 cy / 741.6 ns | 241 cy / 747.8 ns | +6.2 ns |
| **Phase A** in-fabric min | 62 cy / 206.7 ns | 50 cy / **166.7 ns** | **−40.0 ns** |
| Phase A mean | 78.9 cy / 263.0 ns | 70.9 cy / **236.4 ns** | −26.6 ns |
| Phase A max | 124 cy / 413.3 ns | 125 cy / 416.7 ns | +3.4 ns |
| loaded (decode→order) min | 23 core cy | **14 core cy** | −9 cycles |
| samples / excluded | 70 / 0 | 70 / 0 | |
| `st_bbo_mismatch` | n/a | **0** | |
| golden | PASS | PASS | |

**Two quantities in this table must NOT have moved, and did not.** `fast_bbo`
sits between the two probes, so neither the MAC term (Phase B minus Phase A) nor
the fixed front end + back end (Phase A minus the loaded probe) should change:

| | ladder only | with `fast_bbo` | delta |
|---|---|---|---|
| MAC TX + RX + SerDes round trip | 308.4 ns | 305.0 ns | −3.4 ns |
| fixed front end + back end | 99.7 ns | 101.6 ns | +1.9 ns |

Those are four independent 70-sample measurements across four separately placed
and routed bitstreams, and the two invariants reproduce to within a few
nanoseconds. That is worth more than either headline number on its own: it says
the improvement is where the change is, and that the decomposition in §7.5.2 was
measuring something real rather than an artefact of one build.

**The fast path's own claim, checked on silicon.** It was measured in simulation
to answer 1,174 of 1,779 records "about ten cycles early"; the loaded probe on
the card puts the floor nine core cycles lower. The card also reports the same
1,174 / 605 early/late split the simulation did, which is the sharper
confirmation — the two ran the same book on the same data and agreed on which
records took the short path.

**The max moved the wrong way, by 2 cycles.** With 70 samples that is noise, and
saying so is the point: a change that improves the min and the mean and leaves
the max alone is what a shorter common path looks like, and dressing 6 ns up as
a regression or explaining it away would both be overreading.

**`st_bbo_mismatch = 0` across 1.13 M frames.** This is the counter that exists
because the fast path can be wrong in a way a golden diff cannot see — if
`fast_bbo` claimed certainty and the ladder then disagreed, and the strategy had
already acted on the early answer, the order stream could still match a golden
built from the same wrong book. It is zero, on real data, on silicon.

**Phase A was rebuilt too**, which is what makes the invariant check above
possible. It also needed no clock scaling, unlike Phase B, where one path in the
harness's capture DMA missed by 13 ps and Vitis dropped `ap_clk` from 300 to
298.8 MHz. That path is not in the datapath and `ap_clk_2` — the core clock
these cycle counts are taken in — was not scaled in either build.

**Simulation was wrong by a factor of two**, as the paragraph above predicted it
would be: it put the same delta at ~145 ns, because `MAC_LAT = 40` is a constant a
testbench author chose. This is the clearest case in the project of why a
behavioural stand-in cannot substitute for silicon.

**What it reorders.** The datapath is no longer the larger half: ~207 ns of fabric
against ~300 ns of MAC and SerDes. Cycle-shaving in the price ladder or
cut-through decode attacks the smaller term. See `step8-hw/README.md` for the
full account.

### 7.6.1 Where the 300 ns goes, and why almost none of it is ours

The obvious follow-up is to attack that term. Breaking it down first says not to
bother with the parts we own:

| term | ns | ours? |
|---|---|---|
| core clock, 215 → 200 MHz across the core-domain path | ~10 | yes, and deliberate |
| `axis_sf_fifo` store-and-forward fill, 2-beat order frame | ~6 | yes |
| `axis_frame_filter`, decided on the first beat | ~3–6 | yes |
| **CMAC TX + GT SerDes round trip + CMAC RX** | **~285** | **no — vendor IP** |

So roughly **95 % of the term is inside `cmac_usplus` and the GT**, and the
configuration is already the low-latency one: `INCLUDE_RS_FEC 0` (the single
biggest latency option, and it is off), `RX_FLOW_CONTROL 0`, `TX_FLOW_CONTROL 0`,
`INCLUDE_STATISTICS_COUNTERS 0`, AXIS rather than the AXI control interface. PG203
further states the RX path does no buffering beyond the pipelining its operations
require and passes data through cut-through, so there is no buffer sitting there
to remove.

The two pieces we could change are worth ~9–12 ns of a 515 ns path, about 2 %.
Making `axis_sf_fifo` cut-through would recover ~6 ns of that and reintroduce
exactly the MAC underrun it was written to prevent — `tx_axis_tvalid` must be
followed by a beat every cycle until `tlast`, and a source fed from HBM through an
arbiter cannot promise that. Not a trade worth taking.

**The honest conclusion is that this term is close to irreducible with this IP.**
The only real lever is to stop using the vendor MAC — a thin custom PCS/MAC that
skips the standards-compliant pipeline, which is what the ultra-low-latency
industry actually does and is a substantial project with real correctness risk. It
should be entered deliberately, not as an optimisation pass.

### 7.6.2 What multi-symbol costs the single-symbol build — real, and mostly structural

Wiring `NSYM` through the datapath moved the `NSYM = 1` build from **225.5 to
220.0 MHz** best-of-four. That is outside the spread within either
configuration, so §7.7's standard says it has to be explained rather than
waved at.

**First: it is not the tool.** The pre-refactor commit was re-swept in an
isolated worktree, days later, and reproduced *exactly* — 225.5 / 225.5 / 221.7
/ 221.7 with the fast path and 222.5 / 218.3 / 218.3 / 217.2 without, matching
the original run to the decimal on all eight builds. **Vivado is deterministic
here**, which this project had asserted in a comment and never checked. Every
conclusion drawn from a directive sweep rests on that, so it is worth having
measured: a sweep is comparing designs, not sampling a random process.

**One real cause found, and it is small.** The sweep synthesises `t2t_top`, so
the status-bus growth is out of scope — that lives in `t2t_axil`. Inside
`t2t_top` exactly one change added hardware rather than renaming it: the delta
FIFO carries the symbol tag, and `SYMW` is 1 even at `NSYM = 1`, because a
zero-width field cannot sit in a packed vector. A 512-deep FIFO was therefore a
bit wider to carry no information. Making the tag conditional on `NSYM > 1`
recovers **218.6 → 220.7 MHz** at the default and explore directives.

**Most of it is not that.** Best-of-four goes 220.0 → 220.7, still ~4.8 MHz
short of 225.5. What remains is the hierarchy: the ladder, `fast_bbo`,
`bbo_merge` and `sweep_detect` now sit inside a `for (genvar k) begin : g_sym`
generate, which renames every instance and redraws the boundaries the placer
groups on. No logic was added — the worst path is in the ladder either way —
but the placement is not the same placement.

**So the honest accounting is that multi-symbol costs the single-symbol build
about 5 MHz, and roughly one fifth of that is removable.** The rest is the price
of the structure that makes a second book possible at all, and it is paid
whether or not the second book exists. At 220.7 MHz against the 195.3 MHz the
wire demands there is no pressure to reclaim it, and removing it would mean
giving up the generate — but it is a cost, it is reproducible, and it should not
be filed under noise the way the fast path's supposed 9.5 MHz was.

#### 7.6.3 More than half of that 4.8 MHz is the two blocks' NAMES

The paragraph above blames the hierarchy and proposes flattening it. Before
duplicating ~110 lines of `fh_core` to test that, one control: build the
identical netlist under different generate-block LABELS. Nothing else changes —
same logic, same parameters, same directives, same everything.

| the two labels, in source order | default | explore | fanout | netdly | best |
|---|---|---|---|---|---|
| `g_sweep` / `g_sym` — as shipped | 220.7 | 220.7 | 220.0 | 217.4 | 220.7 |
| `g_sweep_detector_lane` / `g_symbol_lane_slot` | 220.7 | 220.7 | 220.0 | 217.4 | 220.7 |
| `g_swp` / `g_lane` | 223.4 | 223.4 | 220.5 | 219.5 | **223.4** |
| `g_zweep` / `g_sym` | 223.4 | — | — | — | **223.4** |

**Renaming as such does nothing**: the long-name build reproduces the shipped
one to the decimal on all four directives, which is Vivado's determinism
confirmed a third time. What moves fMAX is which of the two labels sorts FIRST.
Shipped, `g_sweep` sorts before `g_sym`; the long names preserve that order and
reproduce it exactly; both variants that reverse it gain the same 2.7 MHz. The
last row changes **one character** of the shipped name — `g_sweep` → `g_zweep`,
same length, same everything else — and lands on the same 223.4 as the variant
that renamed both blocks.

**So 2.7 of the 4.8 MHz is not the hierarchy at all.** It is the order the tool
walks two sibling generate blocks in, which no amount of restructuring
addresses and which nothing in the RTL is entitled to control. That kills the
flat-hierarchy rewrite as a plan: a ~3 MHz effect from a block name is the noise
floor any two-hierarchy comparison would have to beat, and four builds cannot.

Two things follow, and the second is a temptation worth naming:

* the 4.8 MHz should be read as "at most ~2 MHz of hierarchy, plus ~2.7 MHz of
  where the placer happened to start" — closer to the fast path's supposed
  9.5 MHz (§7.7) than the paragraph above allowed;
* **2.7 MHz is available for free by renaming a block**, reproducibly, and it is
  not being taken. A name chosen to game the placer is a trap for the next
  reader — it looks like a typo, it has no reason anyone could infer from the
  code, and it survives only until the next edit perturbs placement anyway. The
  design clears its 195.3 MHz requirement by 25 MHz. If that margin ever
  disappears this is a lever, and it is written down here rather than
  rediscovered.

#### 7.6.4 Every fMAX number above was produced by a tool nobody had pinned

Steps 1-6 took whatever `xvlog` and `vivado` came first on `PATH`. On this
machine that is **2023.2**, while step 8 has always sourced **2025.2.1** and
every one of those READMEs reported 2025.2. So the simulation suite and the card
build ran on different toolchains, the fMAX sweeps ran on the older one, and
nothing in the repository said so.

That is now fixed -- one guard in `mk/xilinx.mk`, included by every step
including step 8, sourcing the pinned install and failing loudly rather than
falling back (`make which-tools` reports what any directory will use). The
suite passes 29/29 on the pinned version, real-data replays included.

**But pinning MOVES the instrument**, so it was measured rather than announced.
Identical RTL, identical directives, one commit, only the tool differs:

| dirset | 2023.2 | 2025.2.1 |
|---|---|---|
| default | 220.7 | 221.0 |
| explore | 220.7 | 221.0 |
| fanout | 220.0 | 220.4 |
| netdly | 217.4 | **223.4** |
| **best of four** | 220.7 | **223.4** |

Not worse anywhere; +0.3 to +0.4 on three directives and **+6.0 MHz on netdly**,
which alone moves best-of-four by 2.7. (223.4 is also what reversing two
generate labels gave on 2023.2 in §7.6.3. Two unrelated causes landing on the
same number is a coincidence, not a pattern -- worth saying because it looks
like one.)

**What that does to everything above.** Each table here is still internally
valid: every row in it came from one tool. What is no longer valid is comparing
a NEW build against an OLD table, and a 6 MHz version effect is the same size as
the effects §7.6.2 and §7.7 are reasoning about -- §7.7 in particular concludes
that two configurations differ by less than the spread within either, and both
halves of that were measured on 2023.2. Those tables need their own re-run
before being quoted against a 2025.2.1 build.

The accident is at least loud now. `sweep_report.py` globbed `syn/sweep-f*.log`
and printed two freshly rebuilt 2025.2.1 rows beside two stale 2023.2 rows as
one experiment -- which is how this section's own numbers were nearly recorded
wrong. It now parses the version out of each transcript, prints it per row, and
refuses to present a mixed set as a comparison. A report that cannot say which
tool produced a row is §4.5 wearing a different hat.

### 7.7 What the fast book path costs in fMAX — nothing measurable, and the README was wrong

The README carried "**218.6 → 209.1 MHz**, the price of `fast_bbo`" from the day
the fast path was integrated. That number came from one build of each
configuration, and a single pair cannot support it: place and route are
heuristic searches, and the difference between two arbitrary landings is not a
property of the netlist. The baseline build closed with **0.043 ns** of slack —
about two picoseconds per percent of a LUT delay — which is exactly the regime
where the tool's own spread swamps the effect being measured.

So: both configurations, four implementation directive sets each, everything
else identical, one commit, `make sweep-t2t`. Vivado exposes no placement seed,
so directive triples (place / phys_opt / route, chosen together because they
interact) are the way to sample its run-to-run spread.

| `USE_FAST_BBO` | directives | fMAX | WNS | failing | worst core_clk path is in |
|---|---|---|---|---|---|
| 0 | netdly  | 222.5 | +0.123 | 0 | `u_fh/u_ladder` |
| 0 | default | 218.3 | +0.037 | 0 | `u_fh/u_ladder` |
| 0 | explore | 218.3 | +0.037 | 0 | `u_fh/u_ladder` |
| 0 | fanout  | 217.2 | +0.014 | 0 | `u_fh/u_msg_fifo` |
| 1 | default | **225.5** | +0.183 | 0 | `u_tcp` |
| 1 | explore | **225.5** | +0.183 | 0 | `u_tcp` |
| 1 | fanout  | 221.7 | +0.107 | 0 | `u_tcp_rx` |
| 1 | netdly  | 221.7 | +0.108 | 0 | `u_tcp` |

**The cost is not there.** Best to best the fast path is **3.0 MHz faster**, and
the spread WITHIN a single configuration is **5.3 MHz** — larger than the gap
between them. The honest statement is not "fast_bbo is free" and certainly not
"fast_bbo is faster"; it is that **at this sample size there is no measurable
difference**, and a 9.5 MHz penalty is firmly excluded: the slowest fast build
beats three of the four ladder-only builds.

**Every one of the eight closes at 216.5 MHz with zero failing endpoints.** The
build that produced 209.1 had 105. Whatever that build was, it is not
reproducible at the current design state, and the method that produced it could
not have told a real effect from a placement accident either way.

**The path I had blamed does not appear at all.** `cc6448b` located the cost
precisely — `u_fh/u_split/vcnt_reg`, 15 levels, 69 % route, the MoldUDP64
splitter's byte-count carry chain — and that path is not the critical path in
any of these eight builds. Locating a path in the one build that happened to
show it is not the same as establishing that the feature put it there.

**What the fast path does cost is area, and that is small**: +896 LUT (+1.6 %)
and +705 FF (+2.1 %), with BRAM, URAM and DSP unchanged. That is the real price,
and it buys 1,174 of 1,779 BBO records delivered ~10 cycles early (§ step4b).

One suggestive detail, offered as an observation rather than a claim: with the
fast path in, the worst core-clock path **moves out of the book entirely** —
every ladder-only build is limited by `price_ladder` or the message FIFO
feeding it, and every fast build is limited by the TCP engine at the far end.
That is consistent with `fast_bbo` taking work off the ladder's occupancy scan,
which is what it was built to do, but four builds per configuration is not
enough to assert a mechanism.

### 4.5 `OTABLE_XPM` never reaches the card build (and the URAM count hid it)

`otable_mem` selects between an instantiated `xpm_memory_sdpram` and a
behavioural array on `` `ifdef OTABLE_XPM ``, and the stated purpose is that
"synthesis builds the same table the simulations verify". Checked, because it
was asserted here without ever being checked:

| flow | what is actually built |
|---|---|
| simulation (every step) | behavioural array — no Makefile sets the define |
| step 5 out-of-context synthesis and the fMAX sweeps | **XPM macro** |
| step 8 Vitis card build | behavioural array |

**The define reaches exactly one of the three.** `synth_t2t.tcl` sets it and
plain Vivado honours it, so every fMAX number in §7.7 and §4.4 is an XPM build.
Vitis does not: `ipx::package_project` carries sources, not the packaging
project's `verilog_define`, and grepping the whole link tree finds `OTABLE_XPM`
only as the `` `ifdef `` text in four copies of the source. The
`xpm_memory_base` that does appear in the kernel's synthesis log comes from
`cmac_usplus_0_fifo` → `xpm_fifo_sync` — the MAC IP's own FIFO.

**Why nobody noticed, including me.** Both branches carry
`(* ram_style = "ultra" *)`, so the URAM count is identical either way — 66 at
2^13 × 16 whichever compiles. I used exactly that number as evidence the define
was working, which it never was: the observation cannot distinguish the two
cases, and I should have picked a check that could.

**What it costs, honestly: probably nothing, and it is not nothing that it is
unverified.** The module's header commits the two branches to identical depth,
width and read latency, every golden passes either way, and both map to URAM.
But the card measurements and the OOC fMAX sweeps are therefore built from
*different* memory descriptions, which is a difference between two things this
file compares. The behavioural branch also exists only because Verilator could
not elaborate XPM, and Verilator is gone.

**Fixed: there is nothing to select any more.** The `` `ifdef ``, the
behavioural array and the four `set_property verilog_define {OTABLE_XPM}` lines
are gone; every flow compiles the macro. `-L xpm` went on *every* `xelab` line
in steps 4a, 4b, 5, 6 and 8, not only the ones that reach `otable_mem` today —
"only the ones that happen to" is the entire subject of this finding. The suite
passes end to end: 27 targets across steps 2–8, real-data replays included,
every golden byte-identical, and the transcripts now show
`Compiling module xpm.xpm_memory_sdpram` where they used to show an inferred
array.

**It cost a property, and that is worth more words than the fix was.** The
behavioural array deliberately did not initialise, so a build with
`order_table`'s post-reset clear sweep removed showed X out of the first lookup.
XPM's simulation model zeroes itself — measured, not read off the source, since
the source can be read both ways: an unwritten location reads `0`, and
`USE_MEM_INIT(0)` does not change that (it gates an `$info`, not the loop that
fills the array). So the simulator now models UltraRAM as coming up in exactly
the state the sweep exists to produce, and a build without the sweep would pass
every golden in this project while coming up on the device holding garbage that
looks like live orders.

**And the card was rebuilt on it, which is the only flow the change actually
altered.** Phase A relinked on the pinned toolchain (1 h 22 m, 0 errors), routed
timing met with 0 failing endpoints of 563,470 — the kernel clocks at +0.603 ns
(core) and +0.174 ns, the design's tightest path being the platform's own
`dma_ip_axi_aclk` at +0.003 ns, which is shell logic and common to every build
here. The 5 M AAPL replay is **byte-identical to the golden, 70/70 frames**, and
every measured number lands on the previous build's: in-fabric 166.7 ns min /
236.2 mean against 166.7 / 236.4, loaded 14 / 27.2 / 64 core cycles against
14 / 27.2 / 64, and `bbo early=1174 late=605 mismatch=0` against 1,174 of 1,779.
**Phase B, through the real MAC, reproduces the headline figure too**:
wire-to-wire 471.7 ns min / 551.7 mean / 747.8 max against the recorded
471.7 / 551.9 / 747.8, with the minimum and maximum identical and the mean
0.2 ns apart — one 322 MHz cycle spread across 70 samples. `rx_err`,
`underrun` and `overflow` all zero over 1,127,130 MAC frames.

The two memory descriptions are interchangeable on silicon as well as in
simulation — which was the belief this section started by refusing to accept
without evidence (`data/card-xpm-rebuild.txt`).

That property is now a test rather than an accident — `step4a make test-clear`,
which writes garbage into the memory model before reset and requires the table
not to see it. **Its second half is the part that matters**: the same garbage is
poked back in *after* the sweep and the same delete must now find it. Without
that control a poke that landed somewhere the FSM never reads would produce an
identical clean miss, and the test would pass while checking nothing. Writing
the control is also what caught the first version of the test being wrong: it
poisoned both ways of a set with the same `order_ref`, which tripped
`order_table`'s own one-hot assertion — garbage that violates the design's
stated premise tests the assertion, not the sweep.

## 8. The one number this design has never had: venue acknowledgement latency

`tx_rto` decides an order was lost when `cfg_rto_cycles` pass without the
acknowledgement number advancing. That constant, and `cfg_rto_retries` beside
it, are **the only numbers in this design chosen without evidence** — everything
else in this file was measured before it was built. They could not be measured,
because the input they need is the distribution of venue acknowledgement
latency and nothing has ever answered these orders except a Python generator.
A timeout below the round trip resends orders the venue already has; one far
above it gives back the reason for doing this in hardware.

**So the instrument is built before the thing it measures exists.**
`ack_latency` (step 6) watches the same two signals `tx_rto` does — `tcp_tx`'s
`seq_num` and `tcp_rx`'s `peer_ack` — and needs no new taps in the datapath: a
send is `seq_num` advancing, an acknowledgement is `peer_ack` passing the value
it took. Seven status registers at `0x198`–`0x1B0` carry last/min/max/samples,
a 64-bit sum for the mean, and the count of measurements thrown away.

**What the number is.** Kernel to kernel: from the cycle `tcp_tx` commits the
frame's sequence number to the cycle `peer_ack` covers it. It therefore
*excludes* the MAC, SerDes and framing in both directions — about 300 ns the
round trip (§7.6.1) — and includes our transmit tail, the venue's entire
turnaround, and our receive path. Add the MAC's share for a wire figure.

**Three decisions worth stating, because each discards data on purpose:**

* *One measurement at a time.* Acknowledgements are cumulative — an ack covering
  the third frame covers the first two and says nothing about when the venue saw
  either — so frames sent while a measurement is running go unmeasured rather
  than being credited with a latency the wire never showed. `st_ack_samples`
  against `st_frame_cnt` says how many.
* *A resend poisons the sample.* If the frame being timed was retransmitted, the
  ack may be answering either copy, and the difference between them is exactly
  the timeout under test. Counted in `st_ack_lost`, not averaged in.
* *No counterparty, no samples.* Under GT loopback nothing acknowledges
  anything, `peer_ack` never moves, and the probe reports zero samples forever.
  That is the correct output: a latency of 0 and a latency never measured look
  identical in a table and mean opposite things, so the host prints
  "no counterparty" rather than a row of zeros.

**Verified in the integrated kernel, both directions**, which is the part a
unit test cannot do:

| step 8 run | replies injected | samples | measured |
|---|---|---|---|
| `test-xsim` (HBM→HBM) | none | 0 | — |
| `test-session` | 4 | 1 | 170 cycles |
| `test-b` (through the MAC) | none | 0 | — |
| `test-b-session` | 4 | 1 | 168 cycles |

One sample from four replies is the cumulative-ack rule working: all four orders
leave before any reply arrives, so only the first is timed. **Those cycle counts
are the simulated harness's turnaround, not a venue's** — they demonstrate the
instrument, and are not a latency figure for anything.

**Making that table possible required fixing the simulated venue**, which is a
finding of its own. Every generated reply carried the same acknowledgement
number — the card's *initial* sequence number, i.e. "I have received none of
your orders" however many arrived. It was sufficient for what the generator was
written for (do replies reach the host decoder intact) and it silently made the
session untestable for everything that depends on acknowledgement: `tx_rto`'s
loss detector and this probe both watch `peer_ack`, and neither can do anything
with an ack that never advances. Replies now acknowledge the orders they
answer, one per reply.

**It costs nothing to carry.** One place-and-route at the default directive with
the probe in: **220.7 MHz, 0 failing endpoints** — the same number to the
decimal that this configuration gave before it existed, and URAM/BRAM/DSP
unchanged (66 / 48+4 / 2). The worst core path is in `tcp_tx`, not here. That is
what a probe hanging off two registers already in the design should cost, and it
was measured rather than assumed.

**The two constants remain guesses**, and are now labelled as such wherever they
appear rather than sitting unmarked among measured values. What closes this is a
counterparty, not more simulation.

## Reproduce

```sh
cd step1-sw-parser && make itch_hist
./itch_hist ../data/12302019.NASDAQ_ITCH50.gz > ../data/hist_full.txt
# first N only: ./itch_hist <file.gz> 100000000

# fast_bbo fMAX cost (§7.7): both configurations x four directive sets, 8 impl
# runs, ~40 min on 32 cores. Prints the two distributions with the spread WITHIN
# each next to the gap BETWEEN them.
cd step5-board && make sweep-t2t

# The order table's clear sweep (§4.5): garbage poked into the memory model
# before reset, with the control that pokes it back afterwards. Seconds.
cd step4a-order-table && make test-clear

# The acknowledgement-latency probe (§8): the arithmetic, the sequence-space
# wrap, and the four cases where a measurement must NOT be recorded. Seconds.
cd step6-strategy && make test-acklat
# ... and end to end, where replies actually arrive and one gets timed:
cd step8-hw && make test-session

# The generate-label naming effect (§7.6.3): one build per label variant.
# Change the two `begin :` labels in step5-board/rtl/fh_core.sv so that the
# sweep block sorts AFTER the ladder block, and re-run one directive.
cd step5-board && make sweep-t2t SWEEP_FAST=1 SWEEP_NSYM=1 SWEEP_DIRSETS=default

# II=1 backlog + burst tail latency (§6, §7): the 3-server sim is built into
# itch_hist, one pass over the whole file
cd step1-sw-parser && make itch_hist && ./itch_hist ../data/12302019.NASDAQ_ITCH50.gz

# Sweep signal (§5): needs a large slice — sweeps are rare
python3 step1-sw-parser/itch_slice.py data/12302019.NASDAQ_ITCH50.gz aapl_big.itch 40000000 AAPL
python3 step6-strategy/scripts/dump_sweep.py aapl_big.itch 13 3 1000000 >/dev/null   # summary on stderr

# Multi-symbol capacity (§4.4): the union of the top-K symbols through one table
cd step1-sw-parser && make otable_sim
./otable_sim ../data/12302019.NASDAQ_ITCH50.gz loc=393,13          # 2 symbols
./otable_sim ../data/12302019.NASDAQ_ITCH50.gz loc=393,13,5291,7992

# Imbalance edge (§5.3): the FULL day, regular hours only -- the point of §5.2 is
# that a slice is pre-market. ~40 s for the book, ~2 min for the statistics.
make -C step6-strategy imbalance-edge
make -C step6-strategy imbalance-edge IMARGS="--ratio-shift 4"   # the decay
```
