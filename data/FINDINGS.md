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

The measured tail is **730 ns, not the ~10 µs §7.2's model predicted** — but the
two are not measuring the same thing and the model is not thereby refuted. §7.2
models a full trading day's worst 1 ms burst arriving at a server pipeline; this
sweeps a uniform offered rate over a 5 M-message slice. What the silicon result
does establish is the shape (flat floor, superlinear tail, sharp knee) and the
saturation point, neither of which was previously measured on hardware.

Context for the rates: the design saturates above 40 M msg/s, which is **20–40×
the real NASDAQ peak** this project sized itself against. The load at which the
tail reaches 730 ns is not a rate this feed will present.

**Reproducing this needed a device reset between runs, and now it should not.** A
run that saturates left the datapath in a state the soft reset did not clear: the
next run, even at a gap with zero drops, produced `sent=0` with the RX counters
otherwise identical, and only `xrt-smi reset` recovered it. Root-caused to the
price ladder's quantity arrays, which were initialised by an `initial` block —
correct at power-on, meaningless at reset, and invisible to simulation. Fixed
with an explicit clear-on-reset sweep; see step8-hw/README.md.

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

**Simulation was wrong by a factor of two**, as the paragraph above predicted it
would be: it put the same delta at ~145 ns, because `MAC_LAT = 40` is a constant a
testbench author chose. This is the clearest case in the project of why a
behavioural stand-in cannot substitute for silicon.

**What it reorders.** The datapath is no longer the larger half: ~207 ns of fabric
against ~300 ns of MAC and SerDes. Cycle-shaving in the price ladder or
cut-through decode attacks the smaller term, and anyone optimising from here
should start inside that 300 ns. See `step8-hw/README.md` for the full account.

## Reproduce

```sh
cd step1-sw-parser && make itch_hist
./itch_hist ../data/12302019.NASDAQ_ITCH50.gz > ../data/hist_full.txt
# first N only: ./itch_hist <file.gz> 100000000

# II=1 backlog + burst tail latency (§6, §7): the 3-server sim is built into
# itch_hist, one pass over the whole file
cd step1-sw-parser && make itch_hist && ./itch_hist ../data/12302019.NASDAQ_ITCH50.gz

# Sweep signal (§5): needs a large slice — sweeps are rare
python3 step1-sw-parser/itch_slice.py data/12302019.NASDAQ_ITCH50.gz aapl_big.itch 40000000 AAPL
python3 step6-strategy/scripts/dump_sweep.py aapl_big.itch 13 3 1000000 >/dev/null   # summary on stderr
```
