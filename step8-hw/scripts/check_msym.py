#!/usr/bin/env python3
"""Check a multi-symbol card run: split the captured order stream by stock, and
diff each symbol's orders against the golden for that symbol alone.

WHY THIS IS NOT A PLAIN DIFF. With NSYM > 1 the orders from every book share one
TCP session, so they interleave, and two fields necessarily differ from any
single-symbol golden: the OUCH order token (one counter for one session, so
symbol B's orders consume numbers symbol A's would otherwise have) and the TCP
sequence number (one byte stream). A byte-for-byte comparison would therefore
fail on a run that is completely correct, and "ignore the bytes that differ"
would be indistinguishable from ignoring a bug.

So the comparison is on the fields that carry the DECISION -- side, shares,
price, in order -- which is exactly what a book and a strategy determine and
what a shared session cannot change. The claim being tested is the one the RTL
makes: each book behaves as though it were the only one.

WHAT A GOLDEN IS HERE. For symbol 0 it is the ordinary single-symbol golden,
the same file the NSYM=1 card run is diffed against. For the others there is no
golden -- nothing has ever traded them -- so what is checked is weaker and
stated as such: that the symbol produced orders at all, that every one carries
its own stock, and that its prices lie inside its configured ladder band. A
second book that silently emitted symbol 0's prices under symbol 1's name would
fail that last check, which is the failure this is really looking for.

Usage:
  check_msym.py <captured.log> <symbol0_golden.log> <STOCK0>[:base] [<STOCK1>[:base] ...]

Both logs are the hex-per-line format pack_eth.py unpack prints.
"""
import sys

# Ethernet(14) + IPv4(20) + TCP(20); the OUCH message starts after SoupBin's
# 2-byte length and 1-byte type, and ouch_builder writes the packet from byte 0.
HDR = 54
LADDER_SPAN = 4096 * 100          # price_ladder LEVELS * TICK, in 1e-4 units


def orders(path):
    """[(stock, side, shares, price)] in the order the frames were sent."""
    out = []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        b = bytes.fromhex(line)
        if len(b) < HDR + 35:
            continue
        p = b[HDR:]
        if p[2:4] != b"UO":       # SoupBin unsequenced + OUCH Enter Order
            continue
        out.append((p[23:31].decode(errors="replace"),
                    chr(p[18]),
                    int.from_bytes(p[19:23], "big"),
                    int.from_bytes(p[31:35], "big")))
    return out


def main(argv):
    if len(argv) < 4:
        sys.stderr.write(__doc__)
        return 2
    got = orders(argv[1])
    gold = orders(argv[2])
    want = []
    for spec in argv[3:]:
        name, _, base = spec.partition(":")
        want.append((name.ljust(8), int(base) if base else None))

    fails = 0

    def check(cond, msg):
        nonlocal fails
        print(("PASS: " if cond else "FAIL: ") + msg)
        if not cond:
            fails += 1

    by = {n: [] for n, _ in want}
    unknown = []
    for o in got:
        (by[o[0]] if o[0] in by else unknown).append(o)

    check(not unknown,
          f"every captured order carries a configured stock "
          f"({len(unknown)} did not)")

    # symbol 0 has a golden: the decisions must match it exactly, in order
    s0 = want[0][0]
    g = [o[1:] for o in gold]
    h = [o[1:] for o in by.get(s0, [])]
    check(h == g,
          f"{s0.strip()}: {len(h)} orders match the single-symbol golden's "
          f"{len(g)} on side/shares/price, in order")
    if h != g:
        for i, (a, b) in enumerate(zip(g, h)):
            if a != b:
                print(f"        first difference at order {i}: "
                      f"golden {a} vs captured {b}")
                break

    # the rest have no golden; check what can be checked without one
    for name, base in want[1:]:
        lst = by.get(name, [])
        check(lst, f"{name.strip()}: produced orders ({len(lst)})")
        if not lst:
            print("        a second symbol that produces nothing usually means "
                  "the BITSTREAM was built with NSYM=1 -- the per-symbol config "
                  "registers exist in the map whatever the build has, so the "
                  "host's --sym writes land and are simply never read")
        if lst and base is not None:
            oob = [o for o in lst if not base <= o[3] < base + LADDER_SPAN]
            check(not oob,
                  f"{name.strip()}: every price inside its own ladder band "
                  f"[{base}, {base + LADDER_SPAN}) ({len(oob)} outside)")
            if oob:
                print(f"        e.g. {oob[0]} -- a price from another book "
                      f"would look exactly like this")

    print(f"\n{len(got)} orders captured: " +
          ", ".join(f"{n.strip()}={len(by.get(n, []))}" for n, _ in want))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
