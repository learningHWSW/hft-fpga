#!/usr/bin/env python3
"""Measure the sweep / momentum-ignition signal on real ITCH, before any RTL.

A sweep is an aggressive marketable order (or a burst of them) walking through
resting liquidity on one side of the book. In ITCH it is NOT a Delete/Cancel
(the order's own owner pulling it) — it is an EXECUTION (E, Order Executed;
C, Executed with Price) against a resting order, which means a real trade took
that liquidity. The resting order's side tells the aggressor's direction:

  execution against a resting ASK  -> someone lifted the offer -> BUY sweep  (up)
  execution against a resting BID  -> someone hit the bid      -> SELL sweep (down)

A sweep event is a maximal run of same-direction executions with < GAP_NS
between consecutive ones, and it QUALIFIES as a sweep if the run consumes at
least MIN_LEVELS distinct price levels (the inside price is being walked, not
just topped up at one level).

The detection is the easy half. The half that decides whether this is worth
trading is the FORWARD RETURN: after a sweep, does the mid-price keep moving in
the sweep's direction, or does it revert? A momentum-ignition strategy takes
the same side as the sweep expecting continuation, so the signal only has value
if the signed forward return in the sweep direction is positive AND larger than
the cost of crossing the spread. This script measures that at several horizons
rather than assuming it.

CAVEAT stated up front: this runs on one symbol's slice of one day. A positive
forward return here is evidence the mechanism is real, not a tradeable edge —
transaction costs, queue position, and adverse selection are not modelled, and
one symbol-day is not a backtest.

Line format per detected sweep (so an RTL TB can diff the DETECTION half):
  <ts_end> <BUY|SELL> levels=<n> shares=<q> dur_ns=<d>

Summary (forward returns, the VALIDATION half) goes to stderr.

Usage: ./dump_sweep.py <file.itch> <locate> [min_levels] [gap_ns]
"""
import sys
from bisect import bisect_left


def be(b):
    return int.from_bytes(b, "big")


def main(path, L, min_levels, gap_ns):
    data = open(path, "rb").read()
    orders = {}                 # ref -> [side, price, shares]
    bid, ask = {}, {}           # price -> aggregated qty
    mid_ts, mid_px = [], []     # mid-price timeline, in 1e-4 units
    sweeps = []                 # (ts_end, dir, levels, shares, dur_ns)

    # in-progress run state
    run_dir = 0                 # +1 buy sweep, -1 sell sweep, 0 idle
    run_levels = set()          # distinct prices (diagnostic only)
    run_lvl_cnt = 0             # levels the sweep has WALKED (frontier count)
    run_frontier = 0            # furthest price reached in the sweep direction
    run_shares = 0
    run_start = 0
    run_last = 0
    n_nonmono = 0               # runs where distinct-count != frontier-count

    def best_mid():
        if not bid or not ask:
            return None
        return (max(bid) + min(ask)) // 2

    def note_mid(ts):
        m = best_mid()
        if m is not None and (not mid_px or mid_px[-1] != m):
            mid_ts.append(ts)
            mid_px.append(m)

    def add_lvl(side, price, qty):
        d = bid if side == "B" else ask
        d[price] = d.get(price, 0) + qty

    def rem_lvl(side, price, qty):
        d = bid if side == "B" else ask
        d[price] = d.get(price, 0) - qty
        if d[price] <= 0:
            d.pop(price, None)

    def close_run():
        nonlocal run_dir, run_levels, run_lvl_cnt, run_frontier, run_shares, n_nonmono
        # Level count is the number of levels the sweep WALKED, tracked by a
        # single frontier price (furthest reached in the sweep direction) rather
        # than a set — which is all the RTL can hold. For a marketable order
        # walking the book the execution prices are monotonic, so the frontier
        # count equals the distinct-price count; n_nonmono records the runs
        # where they differ (interleaved aggressors, or two sweeps merged by the
        # gap window), so the choice is measured rather than assumed.
        if run_dir != 0:
            if len(run_levels) != run_lvl_cnt:
                n_nonmono += 1
            if run_lvl_cnt >= min_levels:
                sweeps.append((run_last,
                               "BUY" if run_dir > 0 else "SELL",
                               run_lvl_cnt, run_shares, run_last - run_start))
        run_dir = 0
        run_levels = set()
        run_lvl_cnt = 0
        run_shares = 0

    i = 0
    while i + 2 <= len(data):
        ln = be(data[i:i+2]); i += 2
        if ln == 0:
            break
        m = data[i:i+ln]; i += ln
        t = chr(m[0]); ts = be(m[5:11])

        if t in "AF":
            if be(m[1:3]) != L:
                continue
            ref = be(m[11:19]); side = chr(m[19])
            shares = be(m[20:24]); price = be(m[32:36])
            orders[ref] = [side, price, shares]
            add_lvl(side, price, shares)
            note_mid(ts)

        elif t in "EC":
            ref = be(m[11:19]); shares = be(m[19:23])
            o = orders.get(ref)
            if o is None:
                continue
            side, price = o[0], o[1]
            delta = min(shares, o[2])
            rem_lvl(side, price, delta)
            o[2] -= shares
            if o[2] <= 0:
                orders.pop(ref, None)

            # aggressor: consuming an ask is a buy sweep, a bid is a sell sweep
            d = +1 if side == "S" else -1
            if run_dir != 0 and (d != run_dir or ts - run_last > gap_ns):
                close_run()
            if run_dir == 0:
                run_dir = d
                run_start = ts
                run_frontier = price
                run_lvl_cnt = 1                 # first level of the run
            elif (d > 0 and price > run_frontier) or (d < 0 and price < run_frontier):
                run_lvl_cnt += 1                # walked one level further out
                run_frontier = price
            run_levels.add(price)
            run_shares += delta
            run_last = ts
            note_mid(ts)

        elif t == "X":
            ref = be(m[11:19]); shares = be(m[19:23])
            o = orders.get(ref)
            if o is None:
                continue
            rem_lvl(o[0], o[1], min(shares, o[2]))
            o[2] -= shares
            if o[2] <= 0:
                orders.pop(ref, None)
            note_mid(ts)

        elif t == "D":
            ref = be(m[11:19])
            o = orders.pop(ref, None)
            if o is None:
                continue
            rem_lvl(o[0], o[1], o[2])
            note_mid(ts)

        elif t == "U":
            old = be(m[11:19]); new = be(m[19:27])
            shares = be(m[27:31]); price = be(m[31:35])
            o = orders.pop(old, None)
            if o is None:
                continue
            rem_lvl(o[0], o[1], o[2])
            orders[new] = [o[0], price, shares]
            add_lvl(o[0], price, shares)
            note_mid(ts)
    close_run()

    # Diffable line: the fields the RTL sweep_detect reproduces exactly. dur_ns
    # is informative but not carried on the RTL's sweep pulse, so it stays out
    # of the diff and in the summary instead.
    for s in sweeps:
        print(f"{s[0]} {s[1]} levels={s[2]} shares={s[3]}")

    # ---- validation: forward mid return in the sweep's direction ----
    horizons = [1_000_000, 10_000_000, 100_000_000, 1_000_000_000]  # 1,10,100,1000 ms
    def fwd_mid(t):
        j = bisect_left(mid_ts, t)
        return mid_px[j] if j < len(mid_px) else mid_px[-1]

    print(f"# sweeps={len(sweeps)} (min_levels={min_levels} gap={gap_ns}ns) "
          f"on {path} loc={L}", file=sys.stderr)
    print(f"# non-monotonic runs (set != change-count, RTL would differ): "
          f"{n_nonmono}", file=sys.stderr)
    if sweeps:
        import statistics
        print(f"# levels: med={statistics.median(s[2] for s in sweeps)} "
              f"max={max(s[2] for s in sweeps)}   "
              f"shares: med={statistics.median(s[3] for s in sweeps)}",
              file=sys.stderr)
        print("# forward mid return in the sweep direction (1e-4 units), "
              "signed so +ve = continuation:", file=sys.stderr)
        for h in horizons:
            rets = []
            for ts_end, d, *_ in sweeps:
                mnow = fwd_mid(ts_end)
                rets.append((fwd_mid(ts_end + h) - mnow) * (1 if d == "BUY" else -1))
            avg = sum(rets) / len(rets)
            pos = sum(1 for r in rets if r > 0) / len(rets)
            print(f"#   +{h//1_000_000:>4} ms: avg={avg:+7.1f}  "
                  f"continued={pos*100:4.1f}%  median={statistics.median(rets):+.1f}",
                  file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    a = sys.argv[3:]
    main(sys.argv[1], int(sys.argv[2]),
         int(a[0]) if len(a) > 0 else 2,
         int(a[1]) if len(a) > 1 else 1_000_000)
