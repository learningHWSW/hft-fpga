#!/usr/bin/env python3
"""Copy the first N messages of an ITCH BinaryFILE stream (gz aware) into a
plain .itch BinaryFILE — a small, sim-friendly slice of the real capture for
the step-4a order-table TB (file -> decoder -> order_table).

Also prints the stock-locate of a requested symbol (from 'R' directory
messages) so the TB / golden can be told which locate to track.

Usage: ./itch_slice.py <in[.gz]> <out.itch> <n_msgs> [SYMBOL]
"""
import gzip
import struct
import sys


def main(inp, outp, n, sym):
    op = gzip.open if inp.endswith(".gz") else open
    sym_b = sym.encode().ljust(8)[:8] if sym else None
    loc = None
    out = bytearray()
    with op(inp, "rb") as f:
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
            if m[0:1] == b"R" and sym_b is not None and m[11:19] == sym_b:
                loc = (m[1] << 8) | m[2]
            out += h + m
    with open(outp, "wb") as fo:
        fo.write(out)
    print(f"wrote {outp}: {len(out)} bytes")
    if sym:
        print(f"{sym} locate = {loc}")


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]),
         sys.argv[4] if len(sys.argv) > 4 else None)
