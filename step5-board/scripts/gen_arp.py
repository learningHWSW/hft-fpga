#!/usr/bin/env python3
"""Golden ARP reply frame for tb_arp_responder.

Independent construction of the reply arp_responder.sv builds for a given
who-has request: our MAC/IP answering a requester's MAC/IP. ARP has no checksum,
so this is pure field placement -- but building it separately still catches a
byte-order or offset bug that would otherwise be made once and checked against
itself. Output is one hex byte per line ($readmemh-friendly), 60-byte frame.

  python3 gen_arp.py <our_mac> <our_ip> <req_mac> <req_ip> > arp_gold.mem
  e.g.  gen_arp.py 00:11:22:33:44:55 10.0.0.2 aa:bb:cc:dd:ee:ff 10.0.0.9
"""
import sys


def mac2b(s):
    return bytes(int(x, 16) for x in s.split(":"))


def ip2b(s):
    return bytes(int(x) for x in s.split("."))


def build(our_mac, our_ip, req_mac, req_ip):
    om, oi = mac2b(our_mac), ip2b(our_ip)
    rm, ri = mac2b(req_mac), ip2b(req_ip)
    eth = rm + om + bytes([0x08, 0x06])                 # dst=requester, src=us, ARP
    arp = bytes([0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x02])  # HW/proto, reply
    arp += om + oi + rm + ri                            # sha/spa=us, tha/tpa=requester
    frame = eth + arp
    frame += bytes(60 - len(frame))                     # pad to the 60-byte minimum
    return frame


if __name__ == "__main__":
    for byte in build(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]):
        print(f"{byte:02x}")
