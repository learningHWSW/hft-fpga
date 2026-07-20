#!/usr/bin/env python3
"""Wrap a BinaryFILE ITCH stream into a MoldUDP64 packet stream (.mold).

The real NASDAQ capture is BinaryFILE framing (2B BE length + message, no
MoldUDP64 envelope). To exercise the step-3b 512-bit realigning splitter on
real data we must re-wrap it: group messages into MoldUDP64 packets so that
message boundaries land at varied byte offsets inside 64-byte (512-bit) beats
— multiple messages ending and starting within one beat, messages straddling
beat boundaries. That realignment is exactly what step 3b implements.

Output .mold format is identical to gen_itch.py --mold: a sequence of UDP
payloads, each with a 2B BE length prefix. Golden is dump_mold.py (reads the
same file), so whatever packetization / heartbeats we emit here, the golden
reflects it and the RTL diff stays valid.

Packetization: packet message counts cycle through a fixed pattern (varied so
offsets scatter), with a heartbeat inserted periodically, ending in EOS. No
synthetic gaps/dups here — step3a's synthetic test.mold already covers those;
this stresses realignment at scale.

Usage: ./itch2mold.py <in[.gz]> <out.mold> [max_msgs]
"""
import gzip
import struct
import sys

SESSION = b"MOLDREAL01"   # 10 bytes
EOS_COUNT = 0xFFFF
PKT_PATTERN = [1, 2, 3, 5, 8, 4, 7, 6]   # messages per packet, cycled
HB_EVERY = 97             # heartbeat after every Nth data packet


def read_msgs(path, max_msgs):
    op = gzip.open if path.endswith(".gz") else open
    with op(path, "rb") as f:
        n = 0
        while True:
            h = f.read(2)
            if len(h) < 2:
                break
            ln = (h[0] << 8) | h[1]
            if ln == 0:
                break
            m = f.read(ln)
            if len(m) < ln:
                break
            yield m
            n += 1
            if max_msgs and n >= max_msgs:
                break


def main(inp, outp, max_msgs):
    def packet(seq, count, payload=b""):
        pkt = SESSION + struct.pack(">QH", seq, count) + payload
        return struct.pack(">H", len(pkt)) + pkt

    out = bytearray()
    seq = 1
    pi = 0            # pattern index
    data_pkts = 0
    n_msgs = 0
    buf = []
    it = read_msgs(inp, max_msgs)

    def flush(want):
        nonlocal seq, data_pkts, n_msgs
        body = b"".join(struct.pack(">H", len(m)) + m for m in buf)
        out.extend(packet(seq, want, body))
        seq += want
        data_pkts += 1
        n_msgs += want
        buf.clear()

    done = False
    while not done:
        want = PKT_PATTERN[pi % len(PKT_PATTERN)]
        pi += 1
        for _ in range(want):
            try:
                buf.append(next(it))
            except StopIteration:
                done = True
                break
        if buf:
            flush(len(buf))
        if not done and data_pkts % HB_EVERY == 0:
            out.extend(packet(seq, 0))          # heartbeat
    out.extend(packet(seq, EOS_COUNT))          # end of session

    with open(outp, "wb") as f:
        f.write(out)
    got = selfcheck(bytes(out))
    assert got == n_msgs, (got, n_msgs)
    print(f"wrote {outp}: {len(out)} bytes, {n_msgs} msgs in {data_pkts} packets")


def selfcheck(blob):
    i, expected, got = 0, 1, 0
    while i < len(blob):
        (plen,) = struct.unpack_from(">H", blob, i)
        i += 2
        pkt = blob[i:i + plen]
        i += plen
        assert pkt[:10] == SESSION
        seq, count = struct.unpack_from(">QH", pkt, 10)
        if count == EOS_COUNT:
            break
        if count == 0:
            expected = max(expected, seq)
            continue
        assert seq == expected, (seq, expected)
        j = 20
        for _ in range(count):
            (ml,) = struct.unpack_from(">H", pkt, j)
            j += 2 + ml
            got += 1
        assert j == len(pkt)
        expected = seq + count
    return got


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 0)
