# Step 6 — strategy trigger + risk gate

Everything before this is a feed handler: it reconstructs the book and stops at
a BBO. This is the first stage that decides to *do* something. It consumes the
BBO stream and emits order intents; the OUCH builder that turns those into wire
bytes is the next piece.

## The rule

An order-book imbalance taker — size resting heavily on one side with a tight
spread is the classic signal for an imminent move:

```
tight = both sides present and (ask - bid) <= cfg_max_spread
buy   = tight and bid_qty >= (ask_qty << cfg_ratio_shift) and ask_qty >= cfg_min_qty
sell  = tight and ask_qty >= (bid_qty << cfg_ratio_shift) and bid_qty >= cfg_min_qty
```

A buy lifts the offer, a sell hits the bid, and size is capped at what is
actually resting there. The ratio is a **shift, not a multiply**: no DSP, and
no rounding for the golden and the RTL to disagree about. Synthesis confirms
zero DSPs.

Orders fire on the **rising edge** of a signal. A condition that holds across a
thousand BBO updates must send one order, not a thousand — that is the
difference between a strategy and a runaway loop. The edge state advances on
every record, including ones the risk gate blocks, so a blocked signal does not
re-arm and fire later on stale conditions.

## The risk gate

Not deferred to "later", because a strategy without one is not a smaller
version of a real thing, it is a different and much worse thing:

| control | effect |
|---|---|
| `cfg_enable` | kill switch |
| `cfg_pos_limit` | \|position\| after the order may not exceed it |
| `cfg_max_inflight` | orders sent but not yet acknowledged |
| *(validity)* | shares must satisfy OUCH's `0 < shares < 1,000,000` |

The shares check is a **validity** test rather than a risk one, so it runs first
and keeps the risk counters meaningful. OUCH 4.2 requires shares greater than zero
and less than a million; nothing guaranteed that, because the quantity is
`min(resting, cfg_order_qty)` — a zero-size level with `cfg_min_qty = 0` yields
zero shares, and any `cfg_order_qty` at or above a million passes straight
through. The venue would reject such an order, and a rejection message is an
expensive way to learn about a misconfigured register.

It **rejects and counts** (`blk_qty_cnt`) rather than clamping. Clamping would
send a different order from the one the strategy decided on and hide the
misconfiguration that caused it — the same reasoning as the blocked transmit path
dropping rather than queueing. The golden models the identical rule, so the two
cannot diverge the moment a configuration actually trips it.

Each rejection reason is counted separately, so a strategy that is quiet can be
told apart from one that is blocked — they look identical from the outside
otherwise.

Two deliberate choices worth naming:

**Position moves optimistically**, as though every order fills in full. This is
wrong, but wrong in the safe direction: an unfilled order still consumes
position budget, so the error can only ever suppress trading, never permit more
of it. The host now closes that loop — [step 7](../step7-host/) decodes Order
Accepted / Executed / Rejected, pulses `cfg_order_ack` to release the in-flight
limiter, and keeps the true position against which this optimistic one is the
safe approximation.

**A blocked transmit path drops the order and counts it, never queues it.** A
queued order here is a stale order — by the time the path drains, the book that
justified it has moved. The counter is what keeps that loss visible.

## Parameters are measured, not assumed

The first parameter guess — 2-cent max spread, 4:1 ratio — fired **one order in
1779 BBO records** and exercised no risk gate at all. Measuring the replay
instead:

| spread percentile | 10th | 25th | 50th | 75th | 90th |
|---|---|---|---|---|---|
| 1e-4 units | 500 | 900 | 1700 | 2900 | 4100 |

A 17-cent median spread is nothing like real AAPL, whose inside market is
usually a cent wide.

**Re-derived from the full day, and the diagnosis was worse than "thin".** The
5 M-message slice is not merely a truncated book — it is **entirely pre-market**.
Measuring every BBO change across the whole session and splitting by trading
period (`FINDINGS §5.2`):

| session | records | p10 | p25 | **p50** | p75 | p90 |
|---|---|---|---|---|---|---|
| pre-market | 1,921 | 500 | 900 | **1700** | 2900 | 4000 |
| **regular hours** | **422,301** | **100** | **200** | **300** | **400** | **500** |

The 17 cents above is reproduced exactly as the pre-market median. Real AAPL
during regular hours is **3 cents**, 96.1 % of quotes inside 5 cents.

**Which means `max_spread = 2000` selects nothing.** Every RTH quote is inside a
20-cent threshold, so the "tight spread" half of the signal was not filtering at
all. Sweeping it against the 422,301 RTH records:

| `max_spread` | 100 | 200 | 300 | 400 | 2000 |
|---|---|---|---|---|---|
| orders, `ratio_shift=1` | 6,365 | 14,689 | 22,645 | 26,474 | 28,230 |
| orders, `ratio_shift=2` | 1,734 | 4,743 | 8,175 | 10,505 | 11,599 |

2000 and 400 differ by 6 %: the threshold is inert above ~400. A **venue**
operating point taken from this data is `max_spread=100` (one tick, the tightest
11.9 % of quotes) with `ratio_shift=2`, giving 1,734 orders across the session.

Two things this does and does not settle. It fixes the **calibration** — the
threshold now describes a genuinely tight market. It does **not** establish an
edge: that needs the forward-return treatment §5 gave the sweep signal, and until
that exists the imbalance signal still tests the mechanism only. The sweep is the
signal with measured forward returns behind it.

**The test parameters below are deliberately unchanged.** Every golden here is
generated from the pre-market slice, where a 100-unit threshold fires almost
nothing and no risk gate would ever bind. Test parameters exist to exercise the
gates; venue parameters come from the table above. Conflating the two is what
produced this finding.

Chosen from that: `max_spread=2000`, `ratio_shift=1`, `min_qty=100`,
`order_qty=100`, `pos_limit=1000`, `max_inflight=4`, `ack_gap=50`. The last
three were picked so the gates actually bind — otherwise the test proves
nothing about them:

| | orders |
|---|---|
| no position limit | 106 |
| `pos_limit=1000` | 70 |
| `+ ack_gap=50` (in-flight limiter bites) | 52 |

## Verification

`make test` runs the BBO log through both the golden and the RTL and diffs:

```
TB done: 1779 records, 52 orders (pos=400 inflight=1)
  blocked: position=21 inflight=33 tx-full=0
PASS: orders == golden
```

Stimulus is the BBO log step 4b already produces, not raw ITCH. The book model
is verified at step 4b and re-deriving it here would only mean a book bug could
masquerade as a strategy bug.

Acks are scheduled by **BBO record index**, not cycle count — the golden and
the TB have to agree exactly on when the in-flight limiter releases, and the
record index is the only clock they share.

Two things this does *not* prove, stated plainly:

* Records are presented one at a time, not back to back. BBO updates are
  inherently sparse (1779 across 5 M messages, one per ~2800), so this is the
  realistic pattern, but the pipeline's back-to-back behaviour is unproven.
* `o_ready` is tied high, so the drop-on-backpressure path is exercised only in
  the sense that its counter is asserted to be zero.

### A race that made this testbench lie, and only under one simulator

Worth recording because it is the kind of bug a passing test hides. `drive_bbo`
originally set the DUT's inputs with blocking assignments immediately after
`@(posedge clk)` — the same edge the DUT samples on. That is a race, and the two
simulators resolved it in opposite directions:

| | orders | result |
|---|---|---|
| Verilator | 4 | PASS |
| xsim | 3 | FAIL — every order shifted to the *following* record's timestamp and price, and the last order vanished entirely because there was no further record to shift onto |

Nothing was wrong with `strategy.sv`. The DUT was sampling each BBO one record
late, so the log looked like a design that fired on the wrong book — and under
Verilator it looked like nothing at all. The fix is to drive stimulus on the
**negedge**, which is what every other testbench in this repo already does
(`tb_t2t.sv`, `tb_t2t_axil_full.sv`); `tb_strategy.sv` was the outlier. Both
simulators now agree.

The lesson is not "use negedge" but that a golden-diff regression is only as
trustworthy as the stimulus timing beneath it: this test passed for as long as it
was only ever run under Verilator.

## The OUCH builder

Turns an order intent into the bytes that go on the wire. Per PLAN §6 the
**session is software's job** — login, sequence recovery, retransmission and
heartbeats all live on the host, which hands this block nothing but static
configuration. What stays in hardware is the only part that has to be fast:
assembling and firing the packet the instant the book says to.

That makes it a constant concatenation of registered configuration with three
live fields (side, shares, price) — pure wiring, **one cycle, no state machine,
no memory**. The packet is 52 bytes, so it fits in a single 512-bit beat.

```
SoupBinTCP  0..1  Packet Length     2  big-endian (= 50)
            2     Packet Type       1  'U' unsequenced data
OUCH 4.2    3     Message Type      1  'O' enter order
            4..17 Order Token      14
            18    Buy/Sell          1
            19..22 Shares           4  big-endian
            23..30 Stock            8  ASCII, space padded
            31..34 Price            4  big-endian, 1e-4 units
            35..38 Time in Force    4  big-endian (0 = IOC)
            39..42 Firm             4
            43/44/45  Display / Capacity / Sweep eligible
            46..49 Minimum Quantity 4  big-endian
            50/51 Cross Type / Customer Type
```

Price needs no conversion — ITCH and OUCH both use 1e-4 units, so the book's
price is already the order's price.

The order token is a 6-character prefix plus the order counter as **8 hex
digits**, not decimal: binary-to-decimal costs a divider and buys nothing when
the token only has to be unique, not readable.

**A caveat that matters more than the code.** The field offsets and widths are
structural and are verified by decoding a generated packet, but the
single-character *enum values* — display, capacity, sweep eligibility, cross
type, customer type — are the part of the spec most easily gotten wrong from
memory, and a wrong capacity code is a compliance problem rather than a bug.
Every one of them is a configuration input rather than a constant, so the host
can correct them without a rebuild. They are **no longer placeholders**: all five
are now checked field by field against the published spec, and one of them turned
out to be wrong in exactly the way this paragraph warned about (see below).

### Verified two ways

The golden diff proves the RTL and the Python agree; it does not prove either
is right. So a generated packet is also decoded field by field:

```
total bytes: 52     soup len: 50    soup type: U    msg type: O
token: FPGA0100000000    side: S    shares: 100
stock: 'AAPL    '        price: 2890300 => $289.0300    tif: 0
firm: 'HFT1'   disp/cap/sw: A P N   min qty: 0   cross/cust: N N
```

which matches the first order log line, `... SELL qty=100 px=2890300`. All 52
tokens across the run are unique.

### Verified a third way: against the published spec

The two checks above prove the RTL and the Python agree, and that the bytes decode
to the intended values. Neither can catch a field that both sides encode the same
way and the *exchange* reads differently. So every offset and every enum was
checked against **O*U*C*H Version 4.2, updated October 2025**
([nasdaqtrader.com](https://www.nasdaqtrader.com/content/technicalsupport/specifications/tradingproducts/ouch4.2.pdf)).

**The layout is exact.** All fourteen fields of Enter Order, offsets 0 to 48,
49 bytes total, match byte for byte (the builder's comment numbers them from the
start of the SoupBinTCP frame, so subtract the 3-byte header):

| Field | Spec offset | Len | Ours |
|---|---|---|---|
| Type `O` / Order Token / Buy-Sell | 0 / 1 / 15 | 1 / 14 / 1 | same |
| Shares / Stock / Price | 16 / 20 / 28 | 4 / 8 / 4 | same |
| Time in Force / Firm | 32 / 36 | 4 / 4 | same |
| Display / Capacity / Sweep | 40 / 41 / 42 | 1 / 1 / 1 | same |
| Minimum Quantity | 43 | 4 | same |
| Cross Type / Customer Type | 47 / 48 | 1 / 1 | same |

**Every code we emit is a legal value**: `B`/`S` for buy and sell, `TIF = 0`
(Immediate or Cancel, confirmed in Data Types), Capacity `P` = principal, sweep
eligibility `N` = not eligible, Cross Type `N` = no cross (continuous market),
Customer Type `N` = not a retail designated order. The "placeholder" caveat that
stood here is therefore retired: nothing we send would be rejected as malformed.

Two things the check found that the golden diff structurally could not:

- **`Display` was `"Y"`, a legal code that does not mean what it looks like — now
  `"A"`.** In OUCH 4.2, `Y` is *Anonymous-Price to Comply*, not "yes, display
  this"; the attributable displayed order is `A` = *Attributable-Price to
  Display*. Both are accepted by the exchange, so this is precisely the failure
  mode a self-agreeing golden cannot see — the RTL and the Python emitted the
  same byte and the diff passed while both carried the same wrong assumption.

  Note the codes bundle **two** attributes, so the change moves both at once:
  attribution (anonymous → attributable) and re-pricing handling (Price to Comply
  → Price to Display). The OUCH spec lists the codes without defining those two
  behaviours; they are NASDAQ equity rules.

  **Resolved to `"A"`.** The value lives in five places that must agree or the
  golden diff breaks — `dump_ouch.py`, the host's `session.py` and `ouch.py`, the
  card runner, and four testbenches that write the register directly — and all of
  them now carry `A` (0x41). Verified on the emitted bytes rather than the config:
  decoding a golden frame gives `display 'A' capacity 'P' sweep 'N'`.
- **The Shares range is not enforced in hardware.** The spec requires shares
  "greater than zero and less than 1,000,000". We emit
  `min(resting_qty, cfg_order_qty)` with no clamp, so the upper bound holds only
  if the host sets `cfg_order_qty` below a million, and the lower bound only
  because the imbalance path gates on `i_ask_qty >= cfg_min_qty` — with
  `cfg_min_qty = 0`, a zero-share order is reachable. Deliberately left as
  documentation rather than a silent clamp: clamping would hide a misconfigured
  register, and a rejected order is more informative than a quietly resized one.

## The TCP transmit engine

OUCH runs over SoupBinTCP over TCP, so the packet needs a carrier. This is a
**transmit-only data path for an already established connection**: the
handshake, retransmission, window probing, RST handling and teardown all live
in software, which writes the resulting connection state into shadow registers
and pulses `cfg_load`. The hardware does one thing — put a segment on the wire
the instant the strategy produces one.

The frame is 106 bytes (14 Ethernet + 20 IPv4 + 20 TCP + 52 payload), emitted
as two 512-bit beats.

**There is no retransmission.** A dropped segment is a dropped order and
recovery is the host's problem. That is a deliberate trade — a retransmit
buffer means holding every sent segment plus a timer each, which is state and
latency on the one path that exists to be fast — but it is the single biggest
reason this cannot be pointed at an exchange and left unattended.

**Flow control is satisfied by construction, not by logic.** The strategy's
in-flight limiter caps outstanding orders at 4, i.e. 4 x 52 = 208 bytes of
unacknowledged payload, far below any window a peer would advertise. The risk
gate doubles as TCP flow control, so this block never has to track the window
to be safe.

### The checksum did not fit in one cycle

I wrote that the one's complement adder tree would fit in a single cycle. It
did not: **WNS -0.107 ns**, seven failing endpoints. The TCP checksum spans 42
words (12 pseudo-header, 10 header, 26 payload), and folding that *plus*
assembling the 106-byte frame in one cycle is over budget at 216.5 MHz.

Giving the payload sum its own cycle (`CALC`) fixes it: **-0.107 → +1.438 ns**,
about 314 MHz. The cost is one cycle of latency on the hot path.

There is a way to get that cycle back, deliberately not taken: the OUCH builder
already assembles the payload combinationally and has 3.9 ns of slack, so it
could emit the payload's one's complement sum alongside the packet for free.
That would spread TCP's checksum into a module that otherwise knows nothing
about TCP, and one cycle out of the ~25 in this path is not yet worth the
coupling. It is written down so the option is there when latency is being
squeezed for real.

### Verified against a third implementation

`dump_tcp.py` and `tcp_tx.sv` were written from the same understanding of the
checksum, so agreeing with each other proves nothing about correctness — they
can be wrong together. `scripts/check_frames.py` uses **scapy**, which shares
no code and no author with either, to re-derive both checksums from scratch and
check lengths, flags and sequence advance:

```
PASS: 52 frames verified independently by scapy
      (checksums, lengths, flags, sequence advance)
```

Scapy's decode of the first frame: IPv4 len 92, DF, TTL 64, proto tcp,
10.0.0.2 → 10.0.0.9, seq 0x10000000, ack 0x20000000, flags PA, window 65535,
payload starting `00 32 55 4f` — length 50, `U`, `O`. It skips rather than
fails when scapy is absent, so it is not a hard dependency.

## Resources and timing

Out-of-context synthesis for `xcu55c-fsvh2892-2L-e` at the core's 4.618 ns:

| | `strategy` | `ouch_builder` | `tcp_tx` |
|---|---|---|---|
| CLB LUTs | 598 | — | 890 |
| CLB registers | 471 | 396 | 1343 |
| DSPs | **0** | **0** | **0** |
| WNS | **+2.251 ns** | **+3.898 ns** | **+1.438 ns** (~314 MHz) |

Both sit far off the critical path — the core clock is 216.5 MHz — so there is
room for a much richer rule before timing becomes the constraint. The builder
is fast because it is only wiring.

`ouch_builder` synthesis emits 96 warnings, all of one kind: `m_tdata[416]`
through `[511]` are driven by constants. That is 12 bytes × 8 bits, exactly the
unused tail of the 64-byte beat beyond the 52-byte packet, which `m_tkeep`
masks off. Expected, not a defect.

## A second signal: sweep detection

The imbalance rule above works on the BBO. A different, latency-native signal
is the **sweep** (momentum ignition): an aggressive marketable order walking one
side of the book across several price levels. It was measured on real data
before any RTL (see `data/FINDINGS.md §5`): ≥3-level sweeps continue in their
direction ~75 % of the time over the next millisecond, median one tick, and
bigger sweeps continue harder — the monotonic relation the ignition thesis
predicts, measured rather than assumed.

`sweep_detect.sv` runs on the order table's delta stream, so it sees the
executions the book actually resolves. In ITCH a sweep is an **execution**
(E, C) consuming a resting order, not a Delete/Cancel; the resting side gives
the direction (ask consumed → buy sweep). A run is same-direction executions
within `cfg_gap`, and it fires when it has walked `cfg_min_levels` levels.

The one design decision worth naming: "levels walked" is a **frontier count**,
not a set of prices — the hardware keeps a single register (the furthest price
reached in the sweep direction) and counts a level when an execution pushes past
it. A marketable order walks the book monotonically, so this equals the
distinct-price count a set would give; the golden tracks both and reports zero
disagreement on qualifying sweeps, so the one-register simplification is
measured, not assumed.

`make test-sweep` runs the real AAPL replay through the decoder, the real
2^13 × 16 URAM order table, and the detector, and diffs the fired sweeps
against `dump_sweep.py`:

```
TB done: 23 sweeps (min=2 gap=1000000) overflow=0 msg_drop=0
PASS: sweeps == golden
```

(The TB paces injection on the message-FIFO level: at full injection it
over-drives the 6-cycle-per-message table and the FIFO drops, which is the
`stress` regime — pacing keeps every execution reaching the detector so the
diff is meaningful.) OOC synthesis: 204 LUT, 292 FF, 0 DSP, WNS +2.418 ns
(~432 MHz), no warnings. The forward-return validation stays in Python; this
block only detects.

### Firing orders, and it holds line rate

The sweep pulse feeds `strategy` as a second trigger sharing the one risk
gate; a buy sweep takes the same side (buys) at the latest latched BBO. Verified
bit-exact at the strategy level (`make test-combined`): the golden merges the
BBO and sweep streams by timestamp through the same gate, then out through the
OUCH builder and TCP engine. 67 orders (52 imbalance + 15 sweep), and every OUCH
packet and TCP frame matches.

Wired into the full chain (`t2t_top`), sweep_detect taps the order-table delta
stream inside `fh_core` and its pulse reaches the strategy. Place & route of the
whole chain with the sweep path in: **core_clk +0.072 ns = 220.0 MHz, all
constraints met** — above the 195.3 MHz line-rate floor, ~4 MHz below the
224.3 MHz without it. The core critical path is unchanged (the ladder's
price-to-index divide); sweep_detect sits off it, a 204-LUT block on the
already-registered delta stream. 44,908 LUT, 66 URAM.

## Files

```
rtl/strategy.sv          the rule, the risk gate
rtl/ouch_builder.sv      order intent -> SoupBinTCP + OUCH 4.2 bytes
rtl/tcp_tx.sv            OUCH packet -> TCP/IPv4/Ethernet frame
rtl/sweep_detect.sv      momentum-ignition detector on the delta stream
scripts/dump_orders.py   golden model for the rule — the specification, in Python
scripts/dump_ouch.py     golden model for the OUCH wire format
scripts/dump_tcp.py      golden model for the TCP/IP framing
scripts/dump_sweep.py    sweep golden + forward-return validation
scripts/check_frames.py  independent scapy re-derivation of the checksums
tb/tb_strategy.sv        self-checking TB for the chain, diffed against both
tb/tb_sweep.sv           self-checking TB for the sweep detector
```

## What is still missing for tick-to-trade

The chain now runs wire → book → decision → order bytes. What it does not have:

1. **Retransmission.** The hot path still fires and forgets, but the buffer that
   makes recovery possible is built and proven:
   [`tx_replay_buf.sv`](rtl/tx_replay_buf.sv), `make test-replay`. The spec makes
   it far smaller than it looks — an Enter Order carrying a previously used token
   is *ignored*, so a resend cannot double-fill and needs no dedup protocol. It is
   **not wired into `t2t_top`**.
2. **The handshake itself.** Written — [step 7](../step7-host/) establishes the
   connection over SoupBinTCP, logs in, loads the shadow registers and pulses
   `cfg_load`. What still has no answer is the *inbound* direction on hardware:
   acks arrive at the card's MAC and the FPGA does not parse TCP.
3. **Real fills.** The host reports back (item above); the FPGA's own position
   stays deliberately optimistic, which errs only toward suppressing trades.
4. **Measured latency.** Measured. [Step 8](../step8-hw/) puts the chain on an
   Alveo U55C: **206.7 ns** in fabric and **518.2 ns** wire-to-wire through a real
   100 G MAC, 70 of 70 order frames byte-identical to the golden. The sweep and
   imbalance paths were 19 and 28 core cycles in this document's budget; on
   silicon the whole in-fabric path measures 62 cycles at the probe's clock.
