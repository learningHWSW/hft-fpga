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
    m = re.search(r"SUMMARY_BUILD: fast=(\d+) dirset=(\S+)(?: nsym=(\d+))?"
                  r"(?: sets=(\d+))?(?: ways=\d+)?(?: ct=(\d+))? period=(\S+)", txt)
    if not m:
        return None
    r = {"path": path, "fast": int(m.group(1)), "dirset": m.group(2),
         # nsym is optional so transcripts written before it existed still parse
         "nsym": int(m.group(3)) if m.group(3) else 1,
         # ...and so is sets, which reached this line even later. Deliberately
         # NOT defaulted to 13: a transcript that predates the field could have
         # been any geometry, and the 2^14 sweep behind FINDINGS 4.4 is exactly
         # such a transcript. Backfilling the default would print a specific
         # wrong number where the honest answer is that the build did not say.
         "sets": int(m.group(4)) if m.group(4) else None,
         # ct DOES default, and the asymmetry with sets is deliberate. A
         # transcript predating the sets= field could have been built at any
         # geometry, so guessing one would print a specific wrong number. A
         # transcript predating ct= was built before CUT_THROUGH existed, so it
         # can only have been 0 -- that is a fact about the source, not a guess.
         "ct": int(m.group(5)) if m.group(5) else 0,
         "period": float(m.group(6))}

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
    # WHICH TOOL BUILT THIS ROW. Not a decoration: these transcripts accumulate
    # in syn/ and the glob picks up whatever is there, so a sweep re-run on a
    # new install lands in the same table as the old one's leftovers and reads
    # as one experiment. That happened the day the toolchain was pinned -- two
    # rows rebuilt on 2025.2.1, two stale rows from 2023.2, one table, no way to
    # tell. fMAX is version-dependent (FINDINGS 7.6.4), so a mixed table is not
    # a comparison of anything.
    v = re.search(r"Vivado v(\S+)", txt)
    r["tool"] = v.group(1) if v else "?"
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
    tools = sorted({r["tool"] for r in runs})
    if len(tools) > 1:
        print("!! MIXED TOOLCHAIN: " + ", ".join(tools))
        print("!! fMAX is version-dependent, so the rows below are not one")
        print("!! experiment. Delete syn/sweep-f*.log and re-run the whole set.\n")
    else:
        print(f"built by Vivado {tools[0]}\n")
    unknown = [r for r in runs if r["sets"] is None]
    if unknown:
        print(f"!! {len(unknown)} transcript(s) predate the sets= field, so their table")
        print("!! geometry is unknown and shown as '?'. Two builds differing only in")
        print("!! geometry are indistinguishable here -- re-run them to get it labelled.\n")
    hdr = ("{:<8} {:>4} {:>5} {:>3} {:<9} {:>9} {:>9} {:>9} {:>8} {:<9}  {}"
           .format("fast_bbo", "nsym", "sets", "ct", "dirset", "fMAX MHz", "WNS ns",
                   "TNS ns", "failing", "tool", "worst core_clk path is in"))
    print(hdr)
    print("-" * len(hdr))
    for r in sorted(runs, key=lambda x: (x["nsym"], x["sets"] or 0, x["fast"],
                                         x["ct"], -x["fmax"])):
        src = r["worst"].split(" -> ")[0]
        print("{:<8} {:>4} {:>5} {:>3} {:<9} {:>9.1f} {:>9.3f} {:>9.3f} {:>8} {:<9}  {}"
              .format(r["fast"], r["nsym"], (f"2^{r['sets']}" if r["sets"] else "?"),
                      r["ct"], r["dirset"],
                      r["fmax"], r["wns"],
                      r["tns"] if r["tns"] is not None else float("nan"),
                      r["failing"] if r["failing"] is not None else "?",
                      r["tool"], owner(src)))

    print()
    # A CONFIGURATION is every knob except the directive set -- the directive is
    # what a sweep varies to sample the tool, everything else defines what is
    # being built. Grouping on one knob at a time was wrong the moment two could
    # move together: a table holding NSYM=1 at 2^13 and NSYM=2 at 2^14 was
    # reported as the cost of "a second symbol", when the geometry had moved too.
    KNOBS = (("fast_bbo", "fast"), ("NSYM", "nsym"), ("sets", "sets"),
             ("cut_through", "ct"))

    def key(r):
        return tuple(r[k] for _, k in KNOBS)

    def label(k):
        return "  ".join(
            f"{name}={v}" if name != "sets"
            else (f"table=2^{v}" if v else "table=?")
            for (name, _), v in zip(KNOBS, k))

    groups = {}
    for r in runs:
        groups.setdefault(key(r), []).append(r)

    # The label line grew a fourth knob and outran the fixed 34-column field it
    # used to be printed in, which silently pushed every number out of line.
    # Width it to what is actually there.
    LBLW = max(34, max(len(label(k)) for k in groups) + 2)

    # Builds that MISSED TIMING are not part of a spread. A configuration where
    # three of four directives fail is not "noisy", it is a configuration that
    # does not close, and averaging the failures in reports a closure problem as
    # tool variance. They are counted and named instead.
    stats = {}
    for k in sorted(groups, key=lambda t: tuple(x or 0 for x in t)):
        g = groups[k]
        closing = [r for r in g if r["failing"] == 0]
        failed = [r for r in g if r["failing"] != 0]
        line = "{:<{w}} n={}".format(label(k), len(g), w=LBLW)
        if closing:
            f = [r["fmax"] for r in closing]
            stats[k] = (max(f), max(f) - min(f))
            line += ("  closes {}/{}  best {:.1f} MHz  worst {:.1f} MHz  "
                     "spread {:.1f} MHz".format(len(closing), len(g),
                                                max(f), min(f), max(f) - min(f)))
        else:
            line += "  closes 0/{}  NO DIRECTIVE MEETS TIMING".format(len(g))
        print(line)
        if failed:
            print("{:<{w}}    missed timing: {}".format(
                "", ", ".join(f"{r['dirset']}({r['failing']})" for r in
                              sorted(failed, key=lambda x: x["dirset"])), w=LBLW))

    if len(groups) == 2:
        a, b = sorted(groups, key=lambda t: tuple(x or 0 for x in t))
        moved = [name for (name, _), va, vb in zip(KNOBS, a, b) if va != vb]
        print()
        if len(moved) > 1:
            # The guard that would have caught the misreading above.
            print("!! these two configurations differ in " + " AND ".join(moved) +
                  ", so no")
            print("!! single-knob cost can be attributed. Re-run varying one.")
        elif len(stats) < 2:
            print("no best-to-best comparison: a configuration has no build "
                  "that meets timing,")
            print("which is the finding -- it is not a slower build, it is not "
                  "a shippable one.")
        else:
            cost = stats[a][0] - stats[b][0]
            spread = max(s[1] for s in stats.values())
            print(f"best-to-best cost of {moved[0]}: {cost:+.1f} MHz")
            print(f"largest spread within a single configuration: {spread:.1f} MHz")
            # A difference smaller than the spread inside either configuration is
            # not measurable here -- a real finding, not a failure to find one.
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
