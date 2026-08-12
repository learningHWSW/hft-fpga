#!/usr/bin/env python3
"""Generate the venue's side of the order session: Ethernet/IPv4/TCP frames
carrying SoupBinTCP-framed OUCH replies, plus the golden they decode to.

WHY THIS EXISTS. Everything else the card receives is market data, which is
UDP multicast and reaches the book. The order session is the other direction of
the connection the card transmits on, and nothing in the repository produced a
frame of it: tb_tcp_rx builds segments by hand at the unit level, and the replay
images are feed captures. So the capture path for inbound replies had no
stimulus, and a path with no stimulus is a path nobody has run.

WHAT IT PRODUCES, and why in this order:

  --eth     frames for the replay image, appended to a feed stimulus. They are
            addressed venue -> card so tcp_rx's tuple filter accepts them, and
            their sequence numbers start at the ack number the harness writes
            into cfg_ack_num, because tcp_rx only accepts a segment that starts
            where rcv_nxt is.
  --golden  one line per OUCH message, in the format dump_session.py prints
            after decoding what the card captured. The diff between them is the
            whole test.

The payload is built with step 7's own encoders (host/ouch.py, host/soupbin.py)
rather than hand-packed bytes here. That is deliberate and is NOT the "golden
shares code with the thing it checks" mistake: the hardware does not encode or
interpret these bytes at all, it transports them. What is under test is whether
the bytes that went in come back out of host memory intact, in order, with the
frame boundaries and payload offsets right -- so the encoder only has to be a
consistent generator, and reusing the host's keeps the two ends honest about
what a reply actually looks like.

SEQUENCE NUMBERS ARE THE SUBTLE PART. tcp_rx accepts a segment only when its
sequence number equals rcv_nxt (or covers it), so the frames must form an
unbroken byte stream from cfg_ack_num onward. Emit them out of order or leave a
gap and they are counted in st_rx_ooo and dropped -- correctly, which is why the
generator advances seq by exactly the payload length of the previous frame.
"""
import argparse
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "step7-host"))

from host import ouch, soupbin  # noqa: E402


def ip2int(s):
    a, b, c, d = (int(x) for x in s.split("."))
    return (a << 24) | (b << 16) | (c << 8) | d


def mac2bytes(s):
    return bytes(int(x, 16) for x in s.split(":"))


def ipv4_checksum(hdr):
    total = 0
    for i in range(0, len(hdr), 2):
        total += (hdr[i] << 8) | hdr[i + 1]
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


def tcp_frame(src_mac, dst_mac, src_ip, dst_ip, src_port, dst_port,
              seq, ack, payload, ip_id):
    """One Ethernet/IPv4/TCP frame, 20-byte IP and TCP headers (no options).

    The header layout matches what tcp_rx parses: IHL=5 so the TCP header starts
    at byte 34, data offset 5 so the payload starts at 54. A frame with options
    would still be parsed correctly by the RTL -- it reads both fields -- but
    keeping it minimal means a wrong offset shows up as garbage rather than as a
    coincidentally plausible shift.
    """
    tcp = struct.pack(">HHIIBBHHH",
                      src_port, dst_port, seq, ack,
                      5 << 4,          # data offset 5, no flags in this nibble
                      0x18,            # PSH|ACK
                      0xFFFF,          # window
                      0,               # checksum: not checked by tcp_rx
                      0)               # urgent pointer
    tcp += payload

    total_len = 20 + len(tcp)
    ip = struct.pack(">BBHHHBBH4s4s",
                     0x45, 0, total_len, ip_id, 0x4000, 64, 6, 0,
                     struct.pack(">I", src_ip), struct.pack(">I", dst_ip))
    ip = ip[:10] + struct.pack(">H", ipv4_checksum(ip)) + ip[12:]

    frame = dst_mac + src_mac + b"\x08\x00" + ip + tcp
    # Pad to the 60-byte Ethernet minimum (FCS is the MAC's business). A short
    # frame would be legal on this path but is not what a wire ever carries.
    if len(frame) < 60:
        frame += b"\x00" * (60 - len(frame))
    return frame


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=4,
                    help="OUCH replies to generate (one per frame)")
    ap.add_argument("--seq", type=lambda x: int(x, 0), default=0x20000000,
                    help="first TCP sequence number = the harness's cfg_ack_num")
    ap.add_argument("--ack", type=lambda x: int(x, 0), default=0x10000000,
                    help="what the venue acknowledges = the card's cfg_init_seq")
    # A VENUE THAT ACKNOWLEDGES NOTHING is not a venue. Every reply used to
    # carry the same ack -- the card's INITIAL sequence number -- which says "I
    # have received none of your orders" however many arrived. That was enough
    # for what this generator was written for (do the replies reach the host
    # decoder intact) and it silently made the session untestable for anything
    # that depends on acknowledgement: tx_rto's loss detector and ack_latency's
    # measurement both watch peer_ack, and neither can do anything with an ack
    # that never advances.
    #
    # So reply i now acknowledges i+1 order frames, each ACK-BYTES long. That is
    # what a venue receiving a burst and answering one at a time looks like, and
    # it is what lets step 8's session run check the latency probe end to end.
    # --ack-bytes 0 restores the old fixed ack for anyone who wants it.
    ap.add_argument("--ack-bytes", type=int, default=52,
                    help="payload bytes per order frame the venue acknowledges "
                         "as it replies (0 = never advance the ack)")
    ap.add_argument("--venue-ip", default="10.0.0.9")
    ap.add_argument("--card-ip", default="10.0.0.2")
    ap.add_argument("--venue-port", type=int, default=4001)
    ap.add_argument("--card-port", type=int, default=40001)
    ap.add_argument("--venue-mac", default="aa:bb:cc:dd:ee:ff")
    ap.add_argument("--card-mac", default="00:11:22:33:44:55")
    ap.add_argument("--stock", default="AAPL")
    ap.add_argument("--eth", required=True, help="frames, .eth format")
    ap.add_argument("--golden", required=True, help="expected decode, one line per message")
    args = ap.parse_args()

    seq = args.seq
    frames, golden = [], []

    for i in range(args.count):
        # Tokens match the ones ouch_builder emits: the prefix the harness
        # configures, then a zero-padded decimal counter.
        token = ("FPGA01%08d" % i).encode()[:14].ljust(14, b" ")
        is_buy = (i % 2 == 0)
        shares = 100
        price = 2_800_000 + 100 * i
        order_ref = 0x5000 + i

        body = ouch.order_accepted(token, is_buy, shares, args.stock, price, order_ref)
        payload = soupbin.sequenced(body)

        frames.append(tcp_frame(
            mac2bytes(args.venue_mac), mac2bytes(args.card_mac),
            ip2int(args.venue_ip), ip2int(args.card_ip),
            args.venue_port, args.card_port,
            seq, args.ack + args.ack_bytes * (i + 1), payload,
            ip_id=0x7000 + i))
        seq += len(payload)

        golden.append("A token={} side={} shares={} stock={} price={} ref={}".format(
            token.decode().strip(), "B" if is_buy else "S", shares,
            args.stock, price, order_ref))

    with open(args.eth, "wb") as f:
        for fr in frames:
            f.write(struct.pack(">H", len(fr)) + fr)

    with open(args.golden, "w") as f:
        for line in golden:
            f.write(line + "\n")

    sys.stderr.write("gen_session: {} frames, seq {:#x}..{:#x}\n".format(
        len(frames), args.seq, seq))
    return 0


if __name__ == "__main__":
    sys.exit(main())
