#!/usr/bin/env python3
"""Tune the sweep strategy's two RTL knobs on real data instead of guessing.

FINDINGS section 5 fixed the sweep signal at >=3 levels, but with the gap
window held at 1 ms and judged on continuation percentage. Two things it did
not do, which this does:

  1. sweep the GAP window too (cfg_sweep_gap). Too small and one sweep gets cut
     into pieces that each miss MIN_LEVELS; too large and separate aggressions
     merge into a spurious run whose forward return is diluted. Neither is
     visible when gap is pinned.
  2. judge by a P&L PROXY, not just continuation: net = avg signed forward
     return in the sweep direction MINUS a round-trip cost, because a signal
     that continues 75% of the time but only a third of a tick is not tradeable
     once you cross the spread twice.

Method that keeps the grid cheap: the order book is independent of the two
knobs, so parse the feed ONCE (build the AAPL mid timeline and the list of
executions with direction/price), then for each (gap, min_levels) cell just
re-group the executions into runs and score them. One parse, whole grid.

The cost proxy is deliberately crude and stated: COST_TICKS * tick, a fixed
round-trip in price units, no queue position / fees / adverse selection. It
turns "does it continue" into "does it continue by more than it costs to
trade", which is the question that picks the operating point.

Usage: ./sweep_grid.py <capture.gz|.itch> <SYMBOL> [n_messages]
"""
import os
import sys
import gzip
import statistics
from bisect import bisect_left

# default grid, overridable with SWEEP_GAPS=us,us,... to probe the fine end
GAPS_NS   = [250_000, 500_000, 1_000_000, 2_000_000, 5_000_000]   # 0.25..5 ms
if os.environ.get("SWEEP_GAPS"):
    GAPS_NS = [int(float(x) * 1000) for x in os.environ["SWEEP_GAPS"].split(",")]
MIN_LVLS  = [2, 3, 4, 5]
HORIZONS  = [1_000_000, 10_000_000]        # 1 ms (primary), 10 ms
TICK      = 100                             # AAPL 1 cent in 1e-4 units
COST_TICKS = 1.0                            # round-trip: cross the spread twice
MIN_N     = 30                              # cells below this are too few to trust


def be(b):
    return int.from_bytes(b, "big")


def parse(path, sym, n):
    """One pass: return (mid_ts, mid_px, execs) where execs is a list of
    (ts, dir, price, shares) for every execution against a tracked order."""
    op = gzip.open if path.endswith(".gz") else open
    sym_b = sym.encode().ljust(8)[:8]
    L = None
    orders, bid, ask = {}, {}, {}
    mid_ts, mid_px, execs = [], [], []

    def note_mid(ts):
        if bid and ask:
            m = (max(bid) + min(ask)) // 2
            if not mid_px or mid_px[-1] != m:
                mid_ts.append(ts)
                mid_px.append(m)

    def add_lvl(d, price, qty):
        d[price] = d.get(price, 0) + qty

    def rem_lvl(d, price, qty):
        d[price] = d.get(price, 0) - qty
        if d[price] <= 0:
            d.pop(price, None)

    with op(path, "rb") as f:
        for _ in range(n):
            h = f.read(2)
            if len(h) < 2:
                break
            ln = (h[0] << 8) | h[1]
            if ln == 0:
                break
            m = f.read(ln)
            if len(m) < ln:
                break
            t = chr(m[0])
            if t == "R":
                if m[11:19] == sym_b:
                    L = (m[1] << 8) | m[2]
                continue
            if L is None:
                continue
            ts = be(m[5:11])
            if t in "AF":
                if be(m[1:3]) != L:
                    continue
                ref = be(m[11:19]); side = chr(m[19])
                shares = be(m[20:24]); price = be(m[32:36])
                orders[ref] = [side, price, shares]
                add_lvl(bid if side == "B" else ask, price, shares)
                note_mid(ts)
            elif t in "EC":
                ref = be(m[11:19]); shares = be(m[19:23])
                o = orders.get(ref)
                if o is None:
                    continue
                side, price = o[0], o[1]
                delta = min(shares, o[2])
                rem_lvl(bid if side == "B" else ask, price, delta)
                o[2] -= shares
                if o[2] <= 0:
                    orders.pop(ref, None)
                # execution against a resting ask = buy sweep (+1), bid = sell (-1)
                execs.append((ts, +1 if side == "S" else -1, price, delta))
                note_mid(ts)
            elif t == "X":
                ref = be(m[11:19]); shares = be(m[19:23])
                o = orders.get(ref)
                if o is None:
                    continue
                rem_lvl(bid if o[0] == "B" else ask, o[1], min(shares, o[2]))
                o[2] -= shares
                if o[2] <= 0:
                    orders.pop(ref, None)
                note_mid(ts)
            elif t == "D":
                ref = be(m[11:19])
                o = orders.pop(ref, None)
                if o is None:
                    continue
                rem_lvl(bid if o[0] == "B" else ask, o[1], o[2])
                note_mid(ts)
            elif t == "U":
                old = be(m[11:19]); new = be(m[19:27])
                shares = be(m[27:31]); price = be(m[31:35])
                o = orders.pop(old, None)
                if o is None:
                    continue
                rem_lvl(bid if o[0] == "B" else ask, o[1], o[2])
                orders[new] = [o[0], price, shares]
                add_lvl(bid if o[0] == "B" else ask, price, shares)
                note_mid(ts)
    return L, mid_ts, mid_px, execs


def runs_for_gap(execs, gap):
    """Group executions into maximal same-direction runs with < gap between
    consecutive ones. Level count is the frontier count (furthest price walked
    in the sweep direction), exactly what the RTL sweep_detect holds -- one
    register, not a set. Returns (ts_end, dir, levels)."""
    out = []
    run_dir = 0
    frontier = 0
    lvl = 0
    last = 0
    for ts, d, price, _q in execs:
        if run_dir != 0 and (d != run_dir or ts - last > gap):
            out.append((last, run_dir, lvl))
            run_dir = 0
        if run_dir == 0:
            run_dir, frontier, lvl = d, price, 1
        elif (d > 0 and price > frontier) or (d < 0 and price < frontier):
            lvl += 1
            frontier = price
        last = ts
    if run_dir != 0:
        out.append((last, run_dir, lvl))
    return out


def main(path, sym, n):
    L, mid_ts, mid_px, execs = parse(path, sym, n)
    if not execs:
        sys.exit(f"no executions for {sym} in first {n} messages")

    def fwd(t):
        j = bisect_left(mid_ts, t)
        return mid_px[j] if j < len(mid_px) else mid_px[-1]

    cost = COST_TICKS * TICK
    print(f"# {sym} locate={L}  messages={n}  executions={len(execs)}  "
          f"mid points={len(mid_px)}")
    print(f"# cost proxy = {COST_TICKS} tick round-trip = {cost:.0f} (1e-4 units); "
          f"net = avg signed +1ms return - cost")
    print(f"# {'gap(ms)':>8} {'minlv':>5} {'n':>5} {'cont%':>6} "
          f"{'avgR':>7} {'medR':>6} {'net/trade':>9} {'net*n':>10}")

    best = None
    for gap in GAPS_NS:
        runs = runs_for_gap(execs, gap)
        for ml in MIN_LVLS:
            sw = [(te, d) for (te, d, lv) in runs if lv >= ml]
            if not sw:
                continue
            rets = [(fwd(te + HORIZONS[0]) - fwd(te)) * d for te, d in sw]
            n_sw = len(rets)
            avg = sum(rets) / n_sw
            cont = sum(1 for r in rets if r > 0) / n_sw * 100
            net = avg - cost
            tot = net * n_sw
            print(f"# {gap/1e6:>8.2f} {ml:>5} {n_sw:>5} {cont:>6.1f} "
                  f"{avg:>7.1f} {statistics.median(rets):>6.1f} "
                  f"{net:>9.1f} {tot:>10.0f}")
            if n_sw >= MIN_N and (best is None or tot > best[0]):
                best = (tot, gap, ml, n_sw, cont, avg, net)

    if best:
        _tot, gap, ml, n_sw, cont, avg, net = best
        print(f"#\n# BEST (net*n, n>={MIN_N}): gap={gap/1e6:.2f}ms "
              f"min_levels={ml}  n={n_sw} cont={cont:.1f}% "
              f"avgR={avg:+.1f} net/trade={net:+.1f}")
    else:
        print(f"#\n# no cell with n>={MIN_N}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2],
         int(sys.argv[3]) if len(sys.argv) > 3 else 40_000_000)
