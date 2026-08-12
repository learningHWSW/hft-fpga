#!/usr/bin/env python3
"""Read a set of synth_t2t.tcl transcripts and answer one question: does the
knob that varies across them cost fMAX, or does it cost nothing and the tool is
noisy? The knob is USE_FAST_BBO or NSYM, whichever actually differs between the
transcripts given.

WHY THIS SCRIPT EXISTS. The fast book path was measured once against the ladder
alone -- 218.6 MHz vs 209.1 MHz -- and that 9.5 MHz went into the README as the
price of the feature. One build of each cannot support that claim. Place and
route are heuristic searches; the same netlist built with a different directive
lands somewhere else, and the difference between two arbitrary landings is not a
property of the netlist. The baseline build closed with 0.043 ns of slack, about
two picoseconds per percent of a LUT delay, which is exactly the regime where
the tool's own spread swamps a real effect.

So: build each configuration under every directive set, and compare the
DISTRIBUTIONS. The comparison that means something is the best of each -- the
best build is what would actually ship, and it is the one number a directive
sweep is for -- with the spread reported next to it so the reader can see
whether the gap between the two bests is larger than the gap within either.

Input is whatever synth_t2t.tcl printed. The lines it looks for:
    SUMMARY_BUILD: fast=1 dirset=explore nsym=1 period=4.618 outdir=...
    SUMMARY_IMPL_FMAX_MHZ_core_clk: 213.4
    SUMMARY_IMPL_WNS_core_clk: -0.062
    SUMMARY_IMPL_TNS: -4.195  SUMMARY_IMPL_FAILING: 105
    SUMMARY_IMPL_WORST_core_clk: <pin> -> <pin> levels=15
Runs that did not reach implementation are listed as incomplete rather than
silently dropped -- a sweep that quietly lost half its points would read as a
clean result.

Usage: sweep_report.py <transcript> [<transcript> ...]
"""
import re
import sys


def parse(path):
    """One transcript -> a dict, or None if it never got to a build line."""
    txt = open(path, errors="replace").read()
    m = re.search(r"SUMMARY_BUILD: fast=(\d+) dirset=(\S+)(?: nsym=(\d+))? period=(\S+)",
                  txt)
    if not m:
        return None
    r = {"path": path, "fast": int(m.group(1)), "dirset": m.group(2),
         # nsym is optional so transcripts written before it existed still parse
         "nsym": int(m.group(3)) if m.group(3) else 1,
         "period": float(m.group(4))}

    def grab(pat, cast=float):
        g = re.search(pat, txt)
        return cast(g.group(1)) if g else None

    r["fmax"] = grab(r"SUMMARY_IMPL_FMAX_MHZ_core_clk: (\S+)")
    r["wns"] = grab(r"SUMMARY_IMPL_WNS_core_clk: (\S+)")
    r["cmac"] = grab(r"SUMMARY_IMPL_FMAX_MHZ_cmac_clk: (\S+)")
    r["tns"] = grab(r"SUMMARY_IMPL_TNS: (\S+)")
    r["failing"] = grab(r"SUMMARY_IMPL_FAILING: (\d+)", int)
    w = re.search(r"SUMMARY_IMPL_WORST_core_clk: (.*)", txt)
    r["worst"] = w.group(1).strip() if w else ""
    return r


def owner(pin):
    """The module a path endpoint belongs to, e.g. u_fh/u_split. Which block
    holds the critical path is the actionable half of the answer: a cost that
    lands on the block you added is a cost you can design away, and one that
    lands somewhere else is the placer redistributing slack."""
    parts = pin.split("/")
    return "/".join(parts[:-1]) if len(parts) > 1 else pin


def main(argv):
    runs, incomplete = [], []
    for p in argv[1:]:
        r = parse(p)
        if r is None or r["fmax"] is None:
            incomplete.append(p)
        else:
            runs.append(r)
    if not runs:
        sys.stderr.write("no completed implementation runs in the given files\n")
        return 1

    period = runs[0]["period"]
    print(f"core_clk constrained at {period} ns "
          f"({1000.0/period:.1f} MHz); fMAX = 1000/(period - WNS)\n")
    hdr = ("{:<8} {:>4} {:<9} {:>9} {:>9} {:>9} {:>8}   {}"
           .format("fast_bbo", "nsym", "dirset", "fMAX MHz", "WNS ns", "TNS ns",
                   "failing", "worst core_clk path is in"))
    print(hdr)
    print("-" * len(hdr))
    for r in sorted(runs, key=lambda x: (x["nsym"], x["fast"], -x["fmax"])):
        src = r["worst"].split(" -> ")[0]
        print("{:<8} {:>4} {:<9} {:>9.1f} {:>9.3f} {:>9.3f} {:>8}   {}"
              .format(r["fast"], r["nsym"], r["dirset"], r["fmax"], r["wns"],
                      r["tns"] if r["tns"] is not None else float("nan"),
                      r["failing"] if r["failing"] is not None else "?",
                      owner(src)))

    print()
    # Group on whichever axis this sweep actually varied. A sweep that moved
    # NSYM and a sweep that moved USE_FAST_BBO are asking different questions,
    # and labelling both "fast_bbo / ladder only" would answer neither.
    axis = "nsym" if len({r["nsym"] for r in runs}) > 1 else "fast"
    labels = ({v: f"NSYM={v}" for v in sorted({r["nsym"] for r in runs})}
              if axis == "nsym" else {0: "ladder only", 1: "fast_bbo"})
    best = {}
    for v in sorted({r[axis] for r in runs}):
        got = [r["fmax"] for r in runs if r[axis] == v]
        if not got:
            continue
        best[v] = max(got)
        print("{:<13} n={}  best {:.1f} MHz  worst {:.1f} MHz  "
              "spread within config {:.1f} MHz"
              .format(labels.get(v, str(v)), len(got), max(got), min(got),
                      max(got) - min(got)))

    if len(best) == 2:
        lo, hi = sorted(best)
        cost = best[lo] - best[hi]
        spread = max(
            (max(x["fmax"] for x in runs if x[axis] == v)
             - min(x["fmax"] for x in runs if x[axis] == v))
            for v in best)
        what = ("a second symbol" if axis == "nsym" else "the fast path")
        print(f"\nbest-to-best cost of {what}: {cost:+.1f} MHz")
        print(f"largest spread within a single configuration: {spread:.1f} MHz")
        # The comparison the whole sweep exists to make. A difference smaller
        # than the spread inside either configuration is not measurable here --
        # which is a real finding, not a failure to find one.
        if abs(cost) <= spread:
            print("=> the difference is within the tool's own run-to-run "
                  "spread: not a measurable cost at this sample size.")
        else:
            print("=> the difference exceeds the spread within either "
                  "configuration: a real cost.")

    if incomplete:
        print("\nincomplete runs (no post-route summary):")
        for p in incomplete:
            print(f"  {p}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
