#!/usr/bin/env python3
"""Does the order-book imbalance signal predict anything?

FINDINGS §5.2 fixed the imbalance parameters -- they had been tuned on a slice
that turned out to be entirely pre-market -- and said plainly that fixing the
calibration is not the same as establishing an edge: "That needs the
forward-return treatment §5 gave the sweep signal". This is that treatment.

THE RULE, copied from strategy.sv rather than paraphrased, including the part
that is easy to leave out:

    two_sided = bid and ask both present
    tight     = (ask_px - bid_px) <= max_spread
    buy       = tight and bid_qty >= (ask_qty << shift) and ask_qty >= min_qty
    sell      = tight and ask_qty >= (bid_qty << shift) and bid_qty >= min_qty
    fire      = the RISING EDGE of buy or sell

The edge detector is not a detail. A condition that holds across a thousand
consecutive BBO records is one order in the hardware, and measuring the
condition instead of the edge would count the same opportunity a thousand times
and average away exactly the thing under test.

WHAT IS MEASURED. For each event, the signed mid move at several horizons: for a
buy, mid(t+h) - mid(t), and the negative of that for a sell, so a positive number
always means "the market went the way the order was pointed". Reported as the
share of events that continued, the median, and the mean.

AND WHAT IT IS COMPARED AGAINST, which §5 did not have and this needs. A
continuation rate means nothing on its own -- a market that ticks up 55 % of the
time makes any long look prescient -- so the same statistic is computed over two
wider cohorts drawn from the same session:

    fired     the rising edges the deployed parameters actually produce
    leaning   every record whose sizes meet the ratio, thresholds and edge
              detector ignored -- does the filtering earn its place?
    all       every two-sided record, direction taken from whichever side is
              larger -- the population the signal is drawn from

If `fired` does not beat `all`, the signal is selecting nothing, whatever its
absolute continuation rate looks like.

TIES ARE REPORTED, NOT HIDDEN. At a 1 ms horizon the mid usually has not moved
at all, and a continuation rate computed as (moved favourably) / (all events)
silently mixes "wrong" with "nothing happened". Both are printed.

Input is the raw BBO stream from itch_parser (ITCH_BBO_RAW=1):
    ts_ns bid_px bid_qty ask_px ask_qty
Usage: ./imbalance_edge.py <bbo_raw.txt> [--max-spread N] [--ratio-shift N] ...
"""
import argparse
import bisect
import statistics
import sys

# NASDAQ regular hours, nanoseconds since midnight. The whole point of FINDINGS
# §5.2 is that the earlier numbers came from outside this window.
RTH_START = 9 * 3600 * 10**9 + 30 * 60 * 10**9
RTH_END = 16 * 3600 * 10**9


def load(path):
    ts, bp, bq, ap, aq = [], [], [], [], []
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) != 5:
                continue
            ts.append(int(p[0]))
            bp.append(int(p[1]))
            bq.append(int(p[2]))
            ap.append(int(p[3]))
            aq.append(int(p[4]))
    return ts, bp, bq, ap, aq


def pct(sorted_vals, q):
    if not sorted_vals:
        return 0.0
    k = min(len(sorted_vals) - 1, max(0, int(q * len(sorted_vals))))
    return sorted_vals[k]


def summarise(name, rets, costs, horizon_ns):
    """One cohort at one horizon.

    `costs` is the half-spread paid to cross at entry, per event, in the same
    1e-4 units as the moves. The signal's direction is only half the question;
    a taker pays that half-spread to act on it, so the net column is the one
    that decides whether any of this is worth doing.
    """
    n = len(rets)
    if n == 0:
        return f"{name:>8} {horizon_ns//1000000:>5} ms   (no events)"
    up = sum(1 for r in rets if r > 0)
    down = sum(1 for r in rets if r < 0)
    flat = n - up - down
    moved = up + down
    cont_moved = (100.0 * up / moved) if moved else 0.0
    srt = sorted(rets)
    net = [r - c for r, c in zip(rets, costs)]
    return ("{:>8} {:>5} ms  n={:<7} up={:5.1f}% flat={:5.1f}% down={:5.1f}%  "
            "(of moved {:5.1f}%)  p25={:+.0f} med={:+.0f} p75={:+.0f}  "
            "mean={:+.1f}  net of half-spread={:+.1f} ({:4.1f}% > 0)".format(
                name, horizon_ns // 1000000, n,
                100.0 * up / n, 100.0 * flat / n, 100.0 * down / n, cont_moved,
                pct(srt, 0.25), statistics.median(rets), pct(srt, 0.75),
                statistics.fmean(rets), statistics.fmean(net),
                100.0 * sum(1 for x in net if x > 0) / n))


def main():
    ap_ = argparse.ArgumentParser()
    ap_.add_argument("bbo")
    ap_.add_argument("--max-spread", type=int, default=100,
                     help="1e-4 units; FINDINGS 5.2's venue operating point")
    ap_.add_argument("--ratio-shift", type=int, default=2)
    ap_.add_argument("--min-qty", type=int, default=100)
    ap_.add_argument("--horizons", default="1,10,100",
                     help="milliseconds, comma separated")
    args = ap_.parse_args()

    horizons = [int(x) * 10**6 for x in args.horizons.split(",")]
    ts, bp, bq, ap, aq = load(args.bbo)
    n = len(ts)
    if n == 0:
        sys.stderr.write("no BBO records\n")
        return 1

    mid = [((bp[i] + ap[i]) / 2.0) if (bp[i] and ap[i]) else None for i in range(n)]

    def fwd(i, h):
        """Signed mid change from record i to the last record at or before
        ts[i]+h. None when either end is one-sided -- a mid needs two sides."""
        if mid[i] is None:
            return None
        j = bisect.bisect_right(ts, ts[i] + h) - 1
        if j <= i or mid[j] is None:
            return None
        return mid[j] - mid[i]

    # cohorts: index -> +1 for a buy (long), -1 for a sell
    fired, leaning, allrec = {}, {}, {}
    prev_buy = prev_sell = False

    for i in range(n):
        two_sided = bp[i] != 0 and ap[i] != 0
        tight = two_sided and (ap[i] - bp[i]) <= args.max_spread
        buy = tight and bq[i] >= (aq[i] << args.ratio_shift) and aq[i] >= args.min_qty
        sell = tight and aq[i] >= (bq[i] << args.ratio_shift) and bq[i] >= args.min_qty
        fire_buy, fire_sell = buy and not prev_buy, sell and not prev_sell
        prev_buy, prev_sell = buy, sell

        if not (RTH_START <= ts[i] < RTH_END) or not two_sided:
            continue
        if fire_buy:
            fired[i] = +1
        elif fire_sell:
            fired[i] = -1
        # "leaning": the size ratio alone, no spread filter and no edge
        if bq[i] >= (aq[i] << args.ratio_shift):
            leaning[i] = +1
        elif aq[i] >= (bq[i] << args.ratio_shift):
            leaning[i] = -1
        # "all": whichever side is bigger, which is the weakest possible read
        # of the same idea
        if bq[i] != aq[i]:
            allrec[i] = +1 if bq[i] > aq[i] else -1

    print(f"records={n}  RTH two-sided={len(allrec)}  "
          f"max_spread={args.max_spread} ratio_shift={args.ratio_shift} "
          f"min_qty={args.min_qty}")
    print(f"fired={len(fired)}  leaning={len(leaning)}  all={len(allrec)}")
    print()
    for h in horizons:
        for name, cohort in (("fired", fired), ("leaning", leaning), ("all", allrec)):
            rets, costs = [], []
            for i, sgn in cohort.items():
                d = fwd(i, h)
                if d is not None:
                    rets.append(sgn * d)
                    costs.append((ap[i] - bp[i]) / 2.0)
            print(summarise(name, rets, costs, h))
        print()

    # What the order pays to get in: it crosses, so half the spread each way.
    spreads = [ap[i] - bp[i] for i in fired] or [0]
    print("cost to cross at the fired events: median spread "
          f"{statistics.median(spreads):.0f}, so {statistics.median(spreads)/2:.0f} "
          "each way in the same units as the moves above")
    return 0


if __name__ == "__main__":
    sys.exit(main())
