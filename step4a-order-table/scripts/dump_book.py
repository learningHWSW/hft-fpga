#!/usr/bin/env python3
"""Golden for the step-4a order table.

Reads an ITCH BinaryFILE (2B BE length + message), filters to the tracked
stock locate(s), and prints one book-delta record per processed message — the
same record order_table.sv emits. Several locates may be given, comma
separated: one table shared by several symbols is the multi-symbol design point,
and the golden has to model the shared table rather than be run once per symbol,
because what is under test is that deltas keep their symbol through a structure
that no longer stores the locate per order. Uses an exact ref->{locate,side,price,qty} map;
valid as the golden only because the RTL table is sized so it never overflows
for the tracked symbol (data/FINDINGS.md §4.2 — confirmed by the TB's
overflow_cnt==0 check).

Line format (must stay byte-identical with tb_order_table.sv):
  <type> locate=<L> side=<c> rem=<price>:<qty> add=<price>:<qty>
rem/add are 0:0 when the message doesn't move that side.

Usage: ./dump_book.py <file.itch> <locate>[,<locate>...]
"""
import sys


def be(b):
    return int.from_bytes(b, "big")


def line(t, loc, side, rp, rq, ap, aq):
    return f"{t} locate={loc} side={side} rem={rp}:{rq} add={ap}:{aq}"


def main(path, tracked):
    data = open(path, "rb").read()
    book = {}          # ref -> [locate, side, price, qty]
    i = 0
    out = []
    while i + 2 <= len(data):
        ln = be(data[i:i+2]); i += 2
        if ln == 0:
            break
        m = data[i:i+ln]; i += ln
        t = chr(m[0])
        if t in "AF":
            loc = be(m[1:3])
            if loc not in tracked:
                continue
            ref = be(m[11:19]); side = chr(m[19])
            shares = be(m[20:24]); price = be(m[32:36])
            book[ref] = [loc, side, price, shares]
            out.append(line(t, loc, side, 0, 0, price, shares))
        elif t in "ECX":
            ref = be(m[11:19]); shares = be(m[19:23])
            e = book.get(ref)
            if e is None:
                continue
            delta = min(shares, e[3])
            out.append(line(t, e[0], e[1], e[2], delta, 0, 0))
            e[3] -= shares
            if e[3] <= 0:
                del book[ref]
        elif t == "D":
            ref = be(m[11:19])
            e = book.get(ref)
            if e is None:
                continue
            out.append(line(t, e[0], e[1], e[2], e[3], 0, 0))
            del book[ref]
        elif t == "U":
            old = be(m[11:19]); new = be(m[19:27])
            shares = be(m[27:31]); price = be(m[31:35])
            e = book.get(old)
            if e is None:
                continue
            del book[old]
            out.append(line("U", e[0], e[1], e[2], e[3], price, shares))
            book[new] = [e[0], e[1], price, shares]
        # other message types: no book effect
    sys.stdout.write("\n".join(out) + ("\n" if out else ""))


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], {int(x) for x in sys.argv[2].split(",")})
