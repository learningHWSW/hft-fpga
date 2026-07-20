#!/usr/bin/env python3
"""Golden for step 4b (and the 4a+4b chain): the BBO sequence for one symbol.

Reads an ITCH BinaryFILE, filters to one stock locate, resolves each order by
ref (exact map), maintains an aggregated price->qty ladder per side, and prints
the top-of-book whenever best bid/ask price or qty changes — the same records
price_ladder.sv emits. This is step 1's book model, re-emitted in a canonical
format the RTL TB matches byte-for-byte (empty side = 0:0).

Line format (must stay identical to tb_price_ladder.sv):
  <ts> bid=<price>:<qty> ask=<price>:<qty>

Usage: ./dump_bbo.py <file.itch> <locate>
"""
import sys


def be(b):
    return int.from_bytes(b, "big")


def main(path, L):
    data = open(path, "rb").read()
    orders = {}                  # ref -> [side, price, qty]
    bid = {}                     # price -> qty
    ask = {}                     # price -> qty
    out = []
    lb = (0, 0, 0, 0)            # last (bidpx, bidqty, askpx, askqty)
    i = 0

    def ladder(side):
        return bid if side == "B" else ask

    def add_lvl(side, price, qty):
        d = ladder(side)
        d[price] = d.get(price, 0) + qty

    def rem_lvl(side, price, qty):
        d = ladder(side)
        d[price] = d.get(price, 0) - qty
        if d[price] <= 0:
            d.pop(price, None)

    def emit(ts):
        nonlocal lb
        bp = max(bid) if bid else 0
        bq = bid[bp] if bid else 0
        ap = min(ask) if ask else 0
        aq = ask[ap] if ask else 0
        cur = (bp, bq, ap, aq)
        if cur != lb:
            lb = cur
            out.append(f"{ts} bid={bp}:{bq} ask={ap}:{aq}")

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
            emit(ts)
        elif t in "ECX":
            ref = be(m[11:19]); shares = be(m[19:23])
            o = orders.get(ref)
            if o is None:
                continue
            delta = min(shares, o[2])
            rem_lvl(o[0], o[1], delta)
            o[2] -= shares
            if o[2] <= 0:
                del orders[ref]
            emit(ts)
        elif t == "D":
            ref = be(m[11:19])
            o = orders.get(ref)
            if o is None:
                continue
            rem_lvl(o[0], o[1], o[2])
            del orders[ref]
            emit(ts)
        elif t == "U":
            old = be(m[11:19]); new = be(m[19:27])
            shares = be(m[27:31]); price = be(m[31:35])
            o = orders.get(old)
            if o is None:
                continue
            rem_lvl(o[0], o[1], o[2])
            del orders[old]
            orders[new] = [o[0], price, shares]
            add_lvl(o[0], price, shares)
            emit(ts)
    sys.stdout.write("\n".join(out) + ("\n" if out else ""))


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], int(sys.argv[2]))
