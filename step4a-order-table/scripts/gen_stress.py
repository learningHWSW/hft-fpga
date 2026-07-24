#!/usr/bin/env python3
"""Adversarial ITCH stream that HAMMERS the order table's same-set hazard path.

Real data collides on a set only ~0.06% of the time (8192 sets, ~5-deep
pipeline), so the pipelined order_table_pipe's hazard-stall logic is barely
exercised by a normal replay. This builds the worst case on purpose:

  * back-to-back same-REF operations (insert then immediately execute/delete),
    which are the same set by construction -- the read-after-write the stall
    must catch, or the execute misses the just-inserted order;
  * bursts of inserts whose refs are chosen to land in the SAME set, so the
    free-way allocation hazard fires (each insert must see the previous ones'
    occupied ways);
  * U (replace) interleaved with same-set traffic, which drains and re-fills
    the pipe.

Both the iterative order_table and order_table_pipe run this through the same
step-1 golden; if the stall logic is wrong the pipe's book diverges here even
though it matches on real data.

Usage: ./gen_stress.py <out.itch>
"""
import importlib.util
import struct
import sys

# reuse gen_itch's message builders without running its scenario
here = __file__.rsplit("/", 1)[0]
spec = importlib.util.spec_from_file_location(
    "gen_itch_helpers", here + "/../../step1-sw-parser/gen_itch.py")

# gen_itch runs its scenario on import, so instead pull its helpers by execing
# only the function defs we need. Simplest: replicate the tiny builders here.
LOC = 1
STOCK = b"AAPL    "
_t = 0
msgs = []


def tick(dt=1000):
    global _t
    _t += dt
    return _t


def hdr(mtype, locate):
    return struct.pack(">cHH", mtype, locate, 0) + tick().to_bytes(6, "big")


def add(ref, side, shares, price):
    msgs.append(hdr(b"A", LOC) + struct.pack(">Q", ref) + side
                + struct.pack(">I", shares) + STOCK + struct.pack(">I", price))


def execute(ref, shares, match):
    msgs.append(hdr(b"E", LOC) + struct.pack(">QIQ", ref, shares, match))


def cancel(ref, shares):
    msgs.append(hdr(b"X", LOC) + struct.pack(">QI", ref, shares))


def delete(ref):
    msgs.append(hdr(b"D", LOC) + struct.pack(">Q", ref))


def replace(orig, new, shares, price):
    msgs.append(hdr(b"U", LOC) + struct.pack(">QQII", orig, new, shares, price))


def sys_event(code):
    msgs.append(hdr(b"S", 0) + code)


def directory():
    msgs.append(hdr(b"R", LOC) + STOCK + b"Q" + b"N" + struct.pack(">I", 100)
                + b"N" + b"C" + b"  " + b"P" + b"N" + b"N" + b"1" + b"N"
                + struct.pack(">I", 0) + b"N")


def px(d):
    return round(d * 10000)


def build():
    sys_event(b"O")
    directory()
    match = 900000
    ref = 1

    # 1) back-to-back same-ref: add then immediately execute-to-empty then a new
    #    add reusing the price level. The execute MUST see the add (same set).
    for i in range(200):
        p = px(150.00 + (i % 20) * 0.01)
        add(ref, b"B", 100, p)
        execute(ref, 100, match); match += 1     # consumes it fully
        ref += 1

    # 2) add then partial-execute then cancel then delete-nothing, same ref
    for i in range(200):
        p = px(151.00 + (i % 20) * 0.01)
        add(ref, b"S", 300, p)
        execute(ref, 100, match); match += 1     # 300 -> 200
        cancel(ref, 100)                          # 200 -> 100
        delete(ref)                               # gone
        ref += 1

    # 3) a burst of live orders on nearby refs (same-set clustering), then
    #    execute them in the same order -- keeps many orders live and collides
    live = []
    for i in range(300):
        p = px(150.50 + (i % 10) * 0.01)
        add(ref, b"B" if i % 2 else b"S", 100 + i, p)
        live.append((ref, 100 + i))
        ref += 1
    for r, sh in live:
        execute(r, sh, match); match += 1

    # 4) U (replace) interleaved with same-ref adds, exercising the drain path
    for i in range(150):
        p = px(152.00 + (i % 10) * 0.01)
        add(ref, b"B", 200, p)
        new = ref + 1000000
        replace(ref, new, 150, p + 100)           # U: old ref -> new ref
        execute(new, 150, match); match += 1       # consume the replacement
        ref += 2

    sys_event(b"C")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    build()
    blob = bytearray()
    for m in msgs:
        blob += struct.pack(">H", len(m)) + m
    open(sys.argv[1], "wb").write(bytes(blob))
    print(f"wrote {sys.argv[1]}: {len(msgs)} messages")
