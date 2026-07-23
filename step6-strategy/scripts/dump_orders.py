#!/usr/bin/env python3
"""Golden for step 6: the order sequence a BBO stream triggers.

Consumes the BBO log that step 4b already produces (dump_bbo.py / the RTL's
bbo_rtl.log), not raw ITCH. The book model is verified at step 4b and there is
no reason to re-derive it here; feeding both the golden and the RTL the same
BBO records isolates what step 6 actually adds — the rule and the risk gate.

THE RULE (order-book imbalance taker). For each BBO record:

  two-sided   both sides present
  tight       (ask - bid) <= MAX_SPREAD
  buy signal  tight and bid_qty >= ask_qty * 2**RATIO_SHIFT and ask_qty >= MIN_QTY
  sell signal tight and ask_qty >= bid_qty * 2**RATIO_SHIFT and bid_qty >= MIN_QTY

Resting size heavily on the bid with a tight spread is the classic imbalance
signal for an imminent up-tick, so the buy lifts the offer; the sell is the
mirror. It is deliberately the simplest rule that is still a real signal and
still exactly reproducible in RTL: the ratio is a SHIFT, not a multiply, so
there is no DSP and no rounding to disagree about.

Orders fire on the RISING EDGE of a signal, never while it merely persists —
without that, a condition true across a thousand BBO updates sends a thousand
orders. Size is min(ORDER_QTY, resting size on the side being taken).

THE RISK GATE, which is not optional even in a first cut:
  * enable      a kill switch
  * position    |position| may not exceed POS_LIMIT after the order
  * in flight   at most MAX_INFLIGHT orders unacknowledged

Acks are modelled as arriving ACK_GAP BBO records after the order was sent.
Real acks arrive on their own clock, but the golden has to be reproducible in
the testbench without tying it to cycle counts, and the BBO record index is
something both sides agree on exactly. Without any ack model at all the
in-flight counter saturates and trading stops forever after MAX_INFLIGHT
orders, which is why this is here rather than deferred.

Position is updated OPTIMISTICALLY, as if every order fills in full. That is
wrong in the real world, but wrong in the safe direction: an unfilled order
still consumes position budget, so the error can only ever suppress trading,
never permit more of it. Wiring real fills back from the host is future work.

Line format (must stay identical to tb_strategy.sv):
  <ts> <BUY|SELL> qty=<qty> px=<price>

Usage: ./dump_orders.py <bbo.log> [max_spread] [ratio_shift] [min_qty]
                                  [order_qty] [pos_limit] [max_inflight] [ack_gap]
"""
import sys

# Defaults; the RTL TB passes the same numbers as parameters. They are MEASURED
# against this replay, not assumed: the first guess (2-cent max spread, 4:1
# ratio) fired one order in 1779 BBO records and exercised no risk gate at all.
#
# The spread here is much wider than real AAPL, whose inside market is usually a
# cent: the book is reconstructed from a 5 M-message slice, so it starts empty
# and only ever holds the orders the slice happens to contain. Median spread
# comes out at 1700 (17 cents), 10th percentile 500. Strategy parameters have to
# be read off the data that actually exists, and a rule tuned on this slice is
# tuned for a thin book, not for AAPL.
MAX_SPREAD   = 2000     # ~p60 of the observed spread
RATIO_SHIFT  = 1        # resting size ratio of 2:1
MIN_QTY      = 100
ORDER_QTY    = 100
POS_LIMIT    = 1000     # binds: 106 orders unlimited -> 70 with the limit
MAX_INFLIGHT = 4
ACK_GAP      = 50       # binds: 62 orders at gap 20 -> 52 at gap 50


def load_bbo(path):
    ev = []
    for line in open(path):
        f = line.split()
        if len(f) != 3:
            continue
        ts = int(f[0])
        bp, bq = (int(x) for x in f[1][4:].split(":"))
        ap, aq = (int(x) for x in f[2][4:].split(":"))
        ev.append((ts, "BBO", bp, bq, ap, aq))
    return ev


def load_sweep(path):
    ev = []
    for line in open(path):
        f = line.split()
        if len(f) < 2 or f[1] not in ("BUY", "SELL"):
            continue
        ev.append((int(f[0]), "SWEEP", f[1] == "BUY"))
    return ev


def main(path, max_spread, ratio_shift, min_qty, order_qty, pos_limit, max_inflight,
         ack_gap, sweep_path=None):
    # Merge the BBO stream and (optionally) the sweep stream in timestamp order.
    # Both trigger sources share one risk gate, so they have to be processed in
    # the same order the hardware sees them; the testbench drives exactly this
    # merged order. Stable sort keeps each log's internal order and, at an equal
    # timestamp, puts BBO events before sweep events -- the tiebreak the TB uses.
    events = load_bbo(path)
    if sweep_path:
        events += load_sweep(sweep_path)
    order_key = {"BBO": 0, "SWEEP": 1}
    events.sort(key=lambda e: (e[0], order_key[e[1]]))

    pos = 0
    inflight = 0
    prev_buy = prev_sell = False
    bbo_ok = False
    # held BBO for sweep pricing -- latched only on a TWO-SIDED update, matching
    # the RTL, which keeps the last complete book when a side momentarily empties
    lbid_px = lbid_qty = lask_px = lask_qty = 0
    out = []
    acks_at = {}                # BBO record index -> orders acknowledged then
    rec = 0

    def gate_and_emit(ts, is_buy, qty, px):
        nonlocal pos, inflight
        # sweep and imbalance share this gate exactly
        if inflight >= max_inflight:
            return
        newpos = pos + qty if is_buy else pos - qty
        if newpos > pos_limit or newpos < -pos_limit:
            return
        out.append(f"{ts} {'BUY' if is_buy else 'SELL'} qty={qty} px={px}")
        pos = newpos
        inflight += 1
        acks_at[rec + ack_gap] = acks_at.get(rec + ack_gap, 0) + 1

    for e in events:
        ts, kind = e[0], e[1]

        if kind == "BBO":
            _, _, bp, bq, ap, aq = e         # this event's BBO
            rec += 1
            inflight -= acks_at.pop(rec, 0)  # acks land before this record

            two_sided = bp != 0 and ap != 0
            if two_sided:
                bbo_ok = True
                lbid_px, lbid_qty, lask_px, lask_qty = bp, bq, ap, aq

            # imbalance rule is on THIS event's book, not the held one
            tight = two_sided and (ap - bp) <= max_spread
            buy = tight and bq >= (aq << ratio_shift) and aq >= min_qty
            sell = tight and aq >= (bq << ratio_shift) and bq >= min_qty
            fire_buy = buy and not prev_buy
            fire_sell = sell and not prev_sell
            prev_buy, prev_sell = buy, sell

            if fire_buy:
                gate_and_emit(ts, True, min(order_qty, aq), ap)
            elif fire_sell:
                gate_and_emit(ts, False, min(order_qty, bq), bp)

        else:  # SWEEP: take the same side at the last held (two-sided) BBO
            is_buy = e[2]
            if not bbo_ok:
                continue
            if is_buy:
                gate_and_emit(ts, True, min(order_qty, lask_qty), lask_px)
            else:
                gate_and_emit(ts, False, min(order_qty, lbid_qty), lbid_px)

    print("\n".join(out))
    print(f"# orders={len(out)} position={pos} inflight={inflight}", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    a = sys.argv[2:]
    main(sys.argv[1],
         int(a[0]) if len(a) > 0 else MAX_SPREAD,
         int(a[1]) if len(a) > 1 else RATIO_SHIFT,
         int(a[2]) if len(a) > 2 else MIN_QTY,
         int(a[3]) if len(a) > 3 else ORDER_QTY,
         int(a[4]) if len(a) > 4 else POS_LIMIT,
         int(a[5]) if len(a) > 5 else MAX_INFLIGHT,
         int(a[6]) if len(a) > 6 else ACK_GAP,
         a[7] if len(a) > 7 else None)
