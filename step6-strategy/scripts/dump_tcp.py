#!/usr/bin/env python3
"""Golden for the minimal TCP transmit engine: OUCH packets -> Ethernet frames.

Reads the hex packet log dump_ouch.py produces and wraps each one in
TCP/IPv4/Ethernet, printing one hex line per frame — the same thing
tb_strategy.sv writes from the RTL, so the two can be diffed.

SCOPE. This is a transmit-only data path for an ALREADY ESTABLISHED
connection. The three-way handshake, retransmission, window probing, RST
handling and teardown all live in software, which writes the resulting
connection state into shadow registers. The hardware does exactly one thing:
put a segment on the wire the instant the strategy produces one.

What that costs is stated plainly rather than hidden: there is NO
retransmission here. A dropped segment is a dropped order, and recovery is
the host's problem. That is a deliberate trade — a retransmit buffer would add
state and latency to the one path that exists to be fast — but it means this
cannot be pointed at an exchange and left alone.

Flow control is honoured by construction rather than by logic: the strategy's
in-flight limiter caps outstanding orders at cfg_max_inflight (4), which is
4 x 52 = 208 bytes of unacknowledged payload. Any TCP window is far larger, so
the sender cannot overrun the receiver. The risk gate doubles as flow control.

FRAME LAYOUT (106 bytes = 14 + 20 + 20 + 52):

  Ethernet  0..5    dst MAC
            6..11   src MAC
            12..13  0x0800
  IPv4      14      0x45 (version 4, IHL 5)
            15      DSCP/ECN 0
            16..17  total length = 92
            18..19  identification (increments per frame)
            20..21  0x4000 don't fragment
            22      TTL 64
            23      protocol 6 (TCP)
            24..25  header checksum
            26..29  src IP
            30..33  dst IP
  TCP       34..35  src port
            36..37  dst port
            38..41  sequence number (advances by 52 per segment)
            42..45  acknowledgement number (shadow register from the host)
            46      data offset 0x50
            47      flags 0x18 (PSH|ACK)
            48..49  window
            50..51  checksum
            52..53  urgent pointer 0
  Payload   54..105 the SoupBinTCP + OUCH packet

Usage: ./dump_tcp.py <ouch.log>
"""
import sys

DST_MAC  = bytes.fromhex("aabbccddeeff")
SRC_MAC  = bytes.fromhex("001122334455")
SRC_IP   = "10.0.0.2"
DST_IP   = "10.0.0.9"
SRC_PORT = 40001
DST_PORT = 4001
INIT_SEQ = 0x10000000
INIT_ACK = 0x20000000
INIT_ID  = 0x1000
WINDOW   = 65535


def ip2b(s):
    return bytes(int(x) for x in s.split("."))


def csum(data):
    """One's complement sum, as required for both IP and TCP checksums."""
    if len(data) % 2:
        data += b"\0"
    s = 0
    for i in range(0, len(data), 2):
        s += (data[i] << 8) | data[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def frame(payload, seq, ack, ident):
    src_ip, dst_ip = ip2b(SRC_IP), ip2b(DST_IP)
    total_len = 20 + 20 + len(payload)

    ip = bytes([0x45, 0x00]) + total_len.to_bytes(2, "big") \
        + ident.to_bytes(2, "big") + b"\x40\x00" + bytes([64, 6]) \
        + b"\x00\x00" + src_ip + dst_ip
    ip = ip[:10] + csum(ip).to_bytes(2, "big") + ip[12:]

    tcp = SRC_PORT.to_bytes(2, "big") + DST_PORT.to_bytes(2, "big") \
        + seq.to_bytes(4, "big") + ack.to_bytes(4, "big") \
        + bytes([0x50, 0x18]) + WINDOW.to_bytes(2, "big") \
        + b"\x00\x00" + b"\x00\x00"
    pseudo = src_ip + dst_ip + bytes([0, 6]) + (20 + len(payload)).to_bytes(2, "big")
    tcp = tcp[:16] + csum(pseudo + tcp + payload).to_bytes(2, "big") + tcp[18:]

    return DST_MAC + SRC_MAC + b"\x08\x00" + ip + tcp + payload


def main(path):
    seq, ident, n = INIT_SEQ, INIT_ID, 0
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        payload = bytes.fromhex(line)
        print(frame(payload, seq, INIT_ACK, ident).hex())
        seq = (seq + len(payload)) & 0xFFFFFFFF
        ident = (ident + 1) & 0xFFFF
        n += 1
    print(f"# frames={n} next_seq={seq:#x}", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1])
