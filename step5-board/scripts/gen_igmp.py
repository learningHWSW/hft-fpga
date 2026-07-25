#!/usr/bin/env python3
"""Golden IGMPv2 membership-report frame for tb_igmp_join.

An independent implementation of the frame igmp_join.sv builds: it constructs
the Ethernet/IPv4(+Router Alert)/IGMP bytes and computes the two one's-complement
checksums from scratch, so a bug shared with the RTL would have to be made twice
in two different languages to hide. Output is one hex byte per line
($readmemh-friendly), the 60-byte padded minimum Ethernet frame.

  python3 gen_igmp.py <group_ip> <src_ip> <src_mac> > igmp_gold.mem
  e.g.  python3 gen_igmp.py 233.54.12.1 10.0.0.2 00:11:22:33:44:55
"""
import sys


def ip2b(s):
    return bytes(int(x) for x in s.split("."))


def mac2b(s):
    return bytes(int(x, 16) for x in s.split(":"))


def csum(b):
    s = 0
    for i in range(0, len(b), 2):
        s += (b[i] << 8) | b[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def build(group, src_ip, src_mac):
    g = ip2b(group)
    # multicast destination MAC: 01:00:5e + low 23 bits of the group IP
    dmac = bytes([0x01, 0x00, 0x5E, g[1] & 0x7F, g[2], g[3]])
    eth = dmac + mac2b(src_mac) + bytes([0x08, 0x00])

    # IPv4 header, 24 bytes (IHL=6, Router Alert option), checksum field zero
    ip = bytes([0x46, 0x00,          # ver 4, IHL 6, TOS 0
                0x00, 0x20,          # total length 32
                0x00, 0x00,          # identification
                0x00, 0x00,          # flags / fragment offset
                0x01, 0x02,          # TTL 1, protocol 2 (IGMP)
                0x00, 0x00])         # header checksum placeholder
    ip += ip2b(src_ip) + g          # source, destination = group
    ip += bytes([0x94, 0x04, 0x00, 0x00])   # Router Alert option
    ip = ip[:10] + csum(ip).to_bytes(2, "big") + ip[12:]

    # IGMPv2 message, 8 bytes
    igmp = bytes([0x16, 0x00, 0x00, 0x00]) + g   # type report, max resp 0, csum 0
    igmp = igmp[:2] + csum(igmp).to_bytes(2, "big") + igmp[4:]

    frame = eth + ip + igmp
    frame += bytes(60 - len(frame))   # pad to the 60-byte minimum
    return frame


if __name__ == "__main__":
    group, src_ip, src_mac = sys.argv[1], sys.argv[2], sys.argv[3]
    for byte in build(group, src_ip, src_mac):
        print(f"{byte:02x}")
