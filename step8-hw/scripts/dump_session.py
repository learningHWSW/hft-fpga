#!/usr/bin/env python3
"""Decode the venue's OUCH replies out of the card's capture image.

This is the last link of the inbound path: tcp_rx filters the session frames out
of the RX stream, the kernel merges them into the same capture area the order
frames go to, the DMA puts that area in host memory -- and this reassembles a
byte stream from it and hands the messages to step 7's decoder.

DIRECTION IS THE ONLY THING THAT SEPARATES THEM. Both directions of the session
are TCP frames between the same two addresses, sitting in one buffer. An inbound
frame is the one addressed TO the card, so `--local-ip` decides, and nothing here
depends on capture order or on a tag the RTL would have had to carry.

REASSEMBLY, and why it is not just concatenation. Frames are put back in
sequence-number order and overlaps are trimmed, because that is what a TCP
receiver does and the capture is a record of what arrived, not of what was
accepted: a retransmission the card ignored is still in the buffer. Sorting by
sequence rather than by arrival also means a capture that wrapped or interleaved
does not silently produce a corrupt message stream. A genuine hole is reported
rather than papered over -- the messages after it would be misframed, and saying
so is more useful than printing them.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "step7-host"))

from host import ouch, soupbin      # noqa: E402
from pack_eth import unpack         # noqa: E402


def ip2int(s):
    a, b, c, d = (int(x) for x in s.split("."))
    return (a << 24) | (b << 16) | (c << 8) | d


def be32(b, off):
    return (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3]


def be16(b, off):
    return (b[off] << 8) | b[off + 1]


def inbound_segments(frames, local_ip):
    """(seq, payload) for every TCP frame addressed to us, payloads only."""
    out = []
    for fr in frames:
        if len(fr) < 54 or fr[12] != 0x08 or fr[13] != 0x00:
            continue                      # not IPv4
        ihl = (fr[14] & 0x0F) * 4
        if fr[23] != 6:
            continue                      # not TCP
        if be32(fr, 30) != local_ip:      # IPv4 destination
            continue                      # outbound: an order we sent
        ip_total = be16(fr, 16)
        tcp_off = 14 + ihl
        doff = (fr[tcp_off + 12] >> 4) * 4
        seq = be32(fr, tcp_off + 4)
        # The payload length comes from the IP total length, not from the frame
        # length: the frame may carry Ethernet padding, and counting that as
        # payload would insert zeros into the stream.
        pay_len = ip_total - ihl - doff
        if pay_len <= 0:
            continue
        start = tcp_off + doff
        out.append((seq, bytes(fr[start:start + pay_len])))
    return out


def reassemble(segments):
    """Sequence-ordered byte stream, overlaps trimmed. Returns (data, holes)."""
    if not segments:
        return b"", []
    segments = sorted(segments, key=lambda s: s[0])
    base = segments[0][0]
    data = bytearray()
    holes = []
    nxt = base
    for seq, payload in segments:
        if seq + len(payload) <= nxt:
            continue                                  # wholly a retransmission
        if seq > nxt:
            holes.append((nxt, seq))
            nxt = seq                                 # resume; the gap is reported
        skip = nxt - seq
        data += payload[skip:]
        nxt = seq + len(payload)
    return bytes(data), holes


def describe(body):
    """One canonical line per OUCH message, matching gen_session.py's golden."""
    t = ouch.msg_type(body)
    if t == b"A":
        m = ouch.parse_order_accepted(body)
        return "A token={} side={} shares={} stock={} price={} ref={}".format(
            m["token"].decode().strip(), "B" if m["is_buy"] else "S",
            m["shares"], m["stock"], m["price"], m["order_ref"])
    if t == b"E":
        m = ouch.parse_executed(body)
        return "E token={} shares={} price={} match={}".format(
            m["token"].decode().strip(), m["shares"], m["price"], m["match_ref"])
    if t == b"J":
        return "J token={} reason={}".format(
            body[1:15].decode().strip(), body[15:16].decode())
    return "? type={} len={}".format(t.decode(errors="replace"), len(body))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("records", type=int)
    ap.add_argument("--local-ip", default="10.0.0.2",
                    help="the card's IP: frames addressed here are inbound")
    args = ap.parse_args()

    frames = unpack(args.capture, args.records)
    segs = inbound_segments(frames, ip2int(args.local_ip))
    data, holes = reassemble(segs)

    rd = soupbin.Reader()
    rd.feed(data)
    n = 0
    for ptype, payload in rd.packets():
        if ptype == soupbin.SEQUENCED_DATA:
            print(describe(payload))
            n += 1
        elif ptype == soupbin.SERVER_HEARTBEAT:
            pass                                      # nothing to decode
        else:
            print("soup type={}".format(ptype.decode(errors="replace")))

    leftover = len(rd.buf)
    sys.stderr.write(
        "session: {} frames in, {} inbound, {} payload bytes, {} messages"
        "{}{}\n".format(
            len(frames), len(segs), len(data), n,
            ", {} HOLES".format(len(holes)) if holes else "",
            ", {} trailing bytes".format(leftover) if leftover else ""))
    # A partial packet left in the reader means the stream was cut mid-message,
    # which is a transport failure however plausible the messages before it look.
    return 1 if (holes or leftover) else 0


if __name__ == "__main__":
    sys.exit(main())
