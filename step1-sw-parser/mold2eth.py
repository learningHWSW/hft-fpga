#!/usr/bin/env python3
"""Wrap MoldUDP64 packets in Ethernet/IPv4/UDP frames (.eth) for the step-5
receive front end.

Input is a .mold file (2B BE length-prefixed UDP payloads, from gen_itch.py
--mold or itch2mold.py); output uses the same convention, 2B BE length then
the frame, so a testbench can inject one frame per AXI-Stream packet.

The frame layout is the one eth_ip_udp_rx accepts: untagged IPv4 (IHL=5) over
UDP to a multicast group. A few deliberately wrong frames are mixed in — a
non-IPv4 EtherType and a right-protocol/wrong-port frame — so the parser's
reject counters get exercised rather than assumed.

Usage: ./mold2eth.py <in.mold> <out.eth> [group_ip] [udp_port]
"""
import struct
import sys

SRC_MAC = bytes.fromhex("001122334455")
SRC_IP  = "10.0.0.1"


def ip2int(s):
    a, b, c, d = (int(x) for x in s.split("."))
    return (a << 24) | (b << 16) | (c << 8) | d


def mcast_mac(group_ip):
    # 01:00:5e + low 23 bits of the group address
    g = ip2int(group_ip)
    return bytes([0x01, 0x00, 0x5E, (g >> 16) & 0x7F, (g >> 8) & 0xFF, g & 0xFF])


def frame(payload, group_ip, port, ethertype=0x0800, dst_port=None):
    dst_port = port if dst_port is None else dst_port
    udp = struct.pack(">HHHH", 12345, dst_port, 8 + len(payload), 0) + payload
    ip = struct.pack(">BBHHHBBH", 0x45, 0, 20 + len(udp), 0, 0, 64, 17, 0) \
         + struct.pack(">I", ip2int(SRC_IP)) + struct.pack(">I", ip2int(group_ip))
    eth = mcast_mac(group_ip) + SRC_MAC + struct.pack(">H", ethertype)
    return eth + ip + udp


def main(inp, outp, group_ip, port):
    blob = open(inp, "rb").read()
    out = bytearray()
    i = n = 0
    n_bad = 0
    while i + 2 <= len(blob):
        (plen,) = struct.unpack_from(">H", blob, i)
        i += 2
        payload = blob[i:i + plen]
        i += plen
        f = frame(payload, group_ip, port)
        out += struct.pack(">H", len(f)) + f
        n += 1
        # every 500th packet, precede it with two frames that must be rejected
        if n % 500 == 0:
            bad1 = frame(payload, group_ip, port, ethertype=0x0806)      # ARP
            bad2 = frame(payload, group_ip, port, dst_port=port ^ 1)     # wrong port
            for b in (bad1, bad2):
                out += struct.pack(">H", len(b)) + b
            n_bad += 2
    open(outp, "wb").write(bytes(out))
    print(f"wrote {outp}: {len(out)} bytes, {n} good frames, {n_bad} reject frames")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2],
         sys.argv[3] if len(sys.argv) > 3 else "233.54.12.1",
         int(sys.argv[4]) if len(sys.argv) > 4 else 26477)
