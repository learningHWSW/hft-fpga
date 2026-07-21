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

Each rejection reason is counted separately, so a strategy that is quiet can be
told apart from one that is blocked — they look identical from the outside
otherwise.

Two deliberate choices worth naming:

**Position moves optimistically**, as though every order fills in full. This is
wrong, but wrong in the safe direction: an unfilled order still consumes
position budget, so the error can only ever suppress trading, never permit more
of it. Wiring real fills back from the host is future work.

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
usually a cent wide. The reason is the data: the book is reconstructed from a
5 M-message slice, so it starts empty and only ever contains the orders that
slice happens to carry. **A rule tuned here is tuned for a thin book, not for
AAPL** — the parameters are right for testing the mechanism and would have to
be re-derived from a full trading day before they meant anything about markets.

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

## Resources and timing

Out-of-context synthesis for `xcu55c-fsvh2892-2L-e` at the core's 4.618 ns:

| | |
|---|---|
| CLB LUTs | 598 |
| CLB registers | 471 |
| DSPs | **0** |
| WNS | **+2.251 ns** (~422 MHz) |

Three times the headroom of the core clock, so the strategy is nowhere near
the critical path and there is room for a much richer rule before timing
becomes the constraint.

## Files

```
rtl/strategy.sv          the rule, the risk gate
scripts/dump_orders.py   golden model — the specification, in Python
tb/tb_strategy.sv        self-checking TB, diffed against the golden
```
