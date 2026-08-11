#!/usr/bin/env python3
"""Read a set of synth_t2t.tcl transcripts and answer one question: does
USE_FAST_BBO cost fMAX, or does it cost nothing and the tool is noisy?

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
    SUMMARY_BUILD: fast=1 dirset=explore period=4.618 outdir=...
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
    m = re.search(r"SUMMARY_BUILD: fast=(\d+) dirset=(\S+) period=(\S+)", txt)
    if not m:
        return None
    r = {"path": path, "fast": int(m.group(1)), "dirset": m.group(2),
         "period": float(m.group(3))}

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
    hdr = ("{:<8} {:<9} {:>9} {:>9} {:>9} {:>8}   {}"
           .format("fast_bbo", "dirset", "fMAX MHz", "WNS ns", "TNS ns",
                   "failing", "worst core_clk path is in"))
    print(hdr)
    print("-" * len(hdr))
    for r in sorted(runs, key=lambda x: (x["fast"], -x["fmax"])):
        src = r["worst"].split(" -> ")[0]
        print("{:<8} {:<9} {:>9.1f} {:>9.3f} {:>9.3f} {:>8}   {}"
              .format(r["fast"], r["dirset"], r["fmax"], r["wns"],
                      r["tns"] if r["tns"] is not None else float("nan"),
                      r["failing"] if r["failing"] is not None else "?",
                      owner(src)))

    print()
    best = {}
    for f in (0, 1):
        got = [r["fmax"] for r in runs if r["fast"] == f]
        if not got:
            continue
        best[f] = max(got)
        name = "fast_bbo" if f else "ladder only"
        print("{:<13} n={}  best {:.1f} MHz  worst {:.1f} MHz  "
              "spread within config {:.1f} MHz"
              .format(name, len(got), max(got), min(got), max(got) - min(got)))

    if 0 in best and 1 in best:
        cost = best[0] - best[1]
        spread = max(
            (max(x["fmax"] for x in runs if x["fast"] == f)
             - min(x["fmax"] for x in runs if x["fast"] == f))
            for f in (0, 1))
        print(f"\nbest-to-best cost of the fast path: {cost:+.1f} MHz")
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
