#!/usr/bin/env python3
"""Synthetic ITCH 5.0 test-vector generator.

Produces a deterministic scenario for AAPL with MSFT noise interleaved,
covering message types S R A F E C X D U P.

Outputs:
  1. BinaryFILE framing (2B big-endian length + message), always written —
     step 1 parser and step 2 decoder TB consume this.
  2. Optional MoldUDP64 stream (--mold PATH) for the step 3a stripper:
     a sequence of UDP payloads, each prefixed with a 2B big-endian length
     so a TB can inject one payload per AXI-Stream packet.

     Packet plan (seq counts messages, not packets):
       seq=1   data, 4 msgs   (session open, directories)
       heartbeat (seq=5)
       seq=5   data, 6 msgs
       seq=11  data, 2 msgs   ** DROPPED — receiver must detect a gap of 2 **
       seq=13  data, 7 msgs
       seq=13  duplicate of the previous packet — receiver must drop it
       heartbeat (seq=20)
       seq=20  data, 2 msgs   (session close events)
       End of Session (count=0xFFFF)

     The two dropped messages are MSFT noise (X ref=100, D ref=101), so the
     expected AAPL top-of-book sequence below is unchanged with or without
     the gap.

Expected AAPL top-of-book sequence (price x qty):
  1. A ref=1  B 100@150.00          -> 150.00x100 | -
  2. A ref=2  S 100@150.10          -> 150.00x100 | 150.10x100
  3. A ref=3  B 200@150.05          -> 150.05x200 | 150.10x100
  4. E ref=3  exec 50               -> 150.05x150 | 150.10x100   (+trade)
  5. X ref=3  cancel 150            -> 150.00x100 | 150.10x100
  6. U ref=2 -> ref=4  300@150.08   -> 150.00x100 | 150.08x300
  7. A ref=5  S 100@150.07          -> 150.00x100 | 150.07x100
  8. D ref=5                        -> 150.00x100 | 150.08x300
  9. A ref=6  B  50@150.02          -> 150.02x50  | 150.08x300
 10. C ref=6  exec 50 @150.01       -> 150.00x100 | 150.08x300   (+trade)
 11. P hidden trade 75@150.04       -> (no BBO change, trade print only)
MSFT messages (locate 2) must all be ignored.
"""
import struct
import sys

AAPL = b"AAPL    "
MSFT = b"MSFT    "
LOC_AAPL, LOC_MSFT = 1, 2

msgs: list[bytes] = []
_t = 34_200_000_000_000  # 09:30:00.000000000 ET, ns since midnight


def tick(dt=1_000_000):
    global _t
    _t += dt
    return _t


def emit(body: bytes):
    msgs.append(body)


def hdr(mtype: bytes, locate: int) -> bytes:
    return struct.pack(">cHH", mtype, locate, 0) + tick().to_bytes(6, "big")


def sys_event(code: bytes):
    emit(hdr(b"S", 0) + code)


def directory(locate: int, stock: bytes):
    emit(hdr(b"R", locate) + stock
         + b"Q"                      # market category
         + b"N"                      # financial status
         + struct.pack(">I", 100)    # round lot size
         + b"N"                      # round lots only
         + b"C"                      # issue classification
         + b"  "                     # issue subtype
         + b"P"                      # authenticity
         + b"N"                      # short sale threshold
         + b"N"                      # IPO flag
         + b"1"                      # LULD reference price tier
         + b"N"                      # ETP flag
         + struct.pack(">I", 0)      # ETP leverage
         + b"N")                     # inverse indicator


def px(dollars: float) -> int:
    return round(dollars * 10000)


def add(locate, ref, side, shares, stock, price, mpid=None):
    body = (hdr(b"F" if mpid else b"A", locate)
            + struct.pack(">Q", ref) + side
            + struct.pack(">I", shares) + stock + struct.pack(">I", price))
    if mpid:
        body += mpid
    emit(body)


def execute(locate, ref, shares, match, price=None, printable=b"Y"):
    body = (hdr(b"C" if price is not None else b"E", locate)
            + struct.pack(">QIQ", ref, shares, match))
    if price is not None:
        body += printable + struct.pack(">I", price)
    emit(body)


def cancel(locate, ref, shares):
    emit(hdr(b"X", locate) + struct.pack(">QI", ref, shares))


def delete(locate, ref):
    emit(hdr(b"D", locate) + struct.pack(">Q", ref))


def replace(locate, orig, new, shares, price):
    emit(hdr(b"U", locate) + struct.pack(">QQII", orig, new, shares, price))


def hidden_trade(locate, side, shares, stock, price, match):
    emit(hdr(b"P", locate) + struct.pack(">Q", 0) + side
         + struct.pack(">I", shares) + stock + struct.pack(">I", price)
         + struct.pack(">Q", match))


sys_event(b"O")
sys_event(b"Q")
directory(LOC_AAPL, AAPL)
directory(LOC_MSFT, MSFT)

add(LOC_MSFT, 100, b"B", 500, MSFT, px(430.00))          # noise, ignored
add(LOC_AAPL, 1, b"B", 100, AAPL, px(150.00))            # 1
add(LOC_AAPL, 2, b"S", 100, AAPL, px(150.10))            # 2
add(LOC_MSFT, 101, b"S", 500, MSFT, px(430.50))          # noise
add(LOC_AAPL, 3, b"B", 200, AAPL, px(150.05))            # 3
execute(LOC_AAPL, 3, 50, match=9001)                      # 4
cancel(LOC_MSFT, 100, 250)                                # noise ┐ mold: dropped
delete(LOC_MSFT, 101)                                     # noise ┘ packet (gap)
cancel(LOC_AAPL, 3, 150)                                  # 5
replace(LOC_AAPL, 2, 4, 300, px(150.08))                  # 6
add(LOC_AAPL, 5, b"S", 100, AAPL, px(150.07), mpid=b"VIRT")  # 7 ('F' message)
delete(LOC_AAPL, 5)                                       # 8
add(LOC_AAPL, 6, b"B", 50, AAPL, px(150.02))              # 9
execute(LOC_AAPL, 6, 50, match=9002, price=px(150.01))    # 10 ('C' message)
hidden_trade(LOC_AAPL, b"B", 75, AAPL, px(150.04), 9003)  # 11

sys_event(b"M")
sys_event(b"C")

# ---------------------------------------------------------------------------
# MoldUDP64 packing
# ---------------------------------------------------------------------------
SESSION = b"MOLDTST001"  # 10B
EOS_COUNT = 0xFFFF       # End of Session marker per spec

# (kind, msg_count): "data" emits, "lost" consumes seq but emits nothing,
# "dup" re-emits the previous data packet (receiver must drop it),
# "hb" is a heartbeat, "eos" ends the session. data+lost counts must sum
# to len(msgs).
MOLD_PLAN = [
    ("data", 4),
    ("hb",   0),
    ("data", 6),
    ("lost", 2),
    ("data", 7),
    ("dup",  0),
    ("hb",   0),
    ("data", 2),
    ("eos",  0),
]

# Gap-free variant: the same 21 messages, contiguous, no "lost" and no "dup".
#
# WHY IT EXISTS. The default plan deliberately injects a sequence gap and a
# duplicate so the recovery paths get exercised, and that is the right default.
# But feed_ab_arb recovers a gap on a TIMEOUT -- it holds a message waiting for
# the missing sequence on the other line, then gives up -- so which messages
# reach the book depends on how the injector's inter-frame spacing lines up with
# that timer. Measured on the card: this stimulus matches the golden at gap 48
# and produces 6 orders instead of 4 at gap 512.
#
# That makes the default stimulus unusable for any run whose whole point is a
# different gap, such as a latency measurement, because the software golden
# models no timing at all and therefore has exactly one right answer. With no gap
# to recover, the timeout never fires and the golden holds at any spacing --
# which is also why the real feed is immune (itch2mold.py emits contiguous
# sequences, st_gap_total=0).
MOLD_PLAN_CLEAN = [
    ("data", 4),
    ("hb",   0),
    ("data", 6),
    ("data", 2),
    ("data", 7),
    ("hb",   0),
    ("data", 2),
    ("eos",  0),
]


def mold_pack(msgs: list[bytes], plan) -> bytes:
    out = bytearray()

    def packet(seq: int, count: int, payload: bytes = b"") -> bytes:
        pkt = SESSION + struct.pack(">QH", seq, count) + payload
        return struct.pack(">H", len(pkt)) + pkt

    seq, i = 1, 0
    last_data = b""
    for kind, n in plan:
        if kind == "hb":
            out += packet(seq, 0)
        elif kind == "eos":
            out += packet(seq, EOS_COUNT)
        elif kind == "dup":
            assert last_data, "dup needs a preceding data packet"
            out += last_data
        else:
            body = b"".join(struct.pack(">H", len(m)) + m
                            for m in msgs[i:i + n])
            if kind == "data":
                last_data = packet(seq, n, body)
                out += last_data
            seq += n
            i += n
    assert i == len(msgs), f"plan covers {i} of {len(msgs)} messages"
    return bytes(out)


def mold_selfcheck(blob: bytes, n_total: int):
    """Re-parse as a receiver would; verify framing, seq continuity, gap
    size, and that duplicates (seq < expected) are droppable."""
    i, expected_seq, got, gaps, dups = 0, 1, 0, [], 0
    while i < len(blob):
        (plen,) = struct.unpack_from(">H", blob, i)
        i += 2
        pkt = blob[i:i + plen]
        i += plen
        assert pkt[:10] == SESSION
        seq, count = struct.unpack_from(">QH", pkt, 10)
        if count == EOS_COUNT:
            break
        if seq > expected_seq:
            gaps.append((expected_seq, seq - expected_seq))
            expected_seq = seq
        if count == 0:
            continue
        if seq < expected_seq:
            dups += 1
            continue
        j = 20
        for _ in range(count):
            (mlen,) = struct.unpack_from(">H", pkt, j)
            j += 2 + mlen
            got += 1
        assert j == len(pkt), "trailing bytes in packet"
        expected_seq = seq + count
    lost = sum(n for _, n in gaps)
    assert got + lost == n_total, (got, lost, n_total)
    return got, gaps, dups


path = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") \
    else "test.itch"
with open(path, "wb") as f:
    f.write(b"".join(struct.pack(">H", len(m)) + m for m in msgs))
print(f"wrote {path}: {len(msgs)} msgs")

if "--mold" in sys.argv:
    mold_path = sys.argv[sys.argv.index("--mold") + 1]
    # --clean selects the contiguous plan; the default keeps the gap and
    # duplicate that exercise recovery.
    plan = MOLD_PLAN_CLEAN if "--clean" in sys.argv else MOLD_PLAN
    blob = mold_pack(msgs, plan)
    got, gaps, dups = mold_selfcheck(blob, len(msgs))
    with open(mold_path, "wb") as f:
        f.write(blob)
    print(f"wrote {mold_path}: {len(blob)} bytes, "
          f"{got} msgs delivered, gaps={gaps}, dups={dups}")
