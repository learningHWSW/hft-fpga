#!/usr/bin/env python3
"""Independent check of the generated Ethernet frames, using scapy.

Why this exists separately from the golden diff: dump_tcp.py and tcp_tx.sv were
written from the same understanding of the TCP/IP checksum, so they can agree
with each other and both be wrong. Scapy is a third implementation that shares
no code and no author with either, which is the only thing that makes it
evidence rather than an echo.

For every frame it re-derives the IP and TCP checksums from scratch and
compares them with the ones in the frame, then sanity-checks the header fields
that a wrong constant would corrupt silently.

Skips (exit 0) with a message if scapy is not installed, so it can sit in the
Makefile without becoming a hard dependency.

Usage: ./check_frames.py <frames.log> [expected_payload_len]
"""
import sys

try:
    from scapy.all import Ether, IP, TCP, raw
except ImportError:
    print("SKIP: scapy not installed (pip install scapy) — checksums unverified")
    sys.exit(0)


def main(path, payload_len):
    bad = n = 0
    prev_seq = None
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        n += 1
        pkt = Ether(bytes.fromhex(line))
        ours = (pkt[IP].chksum, pkt[TCP].chksum)

        # force scapy to recompute both from scratch
        q = pkt.copy()
        del q[IP].chksum
        del q[TCP].chksum
        q = Ether(raw(q))
        if (q[IP].chksum, q[TCP].chksum) != ours:
            bad += 1
            print(f"FAIL frame {n}: ip ours={ours[0]:#06x} scapy={q[IP].chksum:#06x} "
                  f"tcp ours={ours[1]:#06x} scapy={q[TCP].chksum:#06x}")

        pl = len(pkt[TCP].payload)
        if pl != payload_len:
            bad += 1
            print(f"FAIL frame {n}: payload {pl} bytes, expected {payload_len}")
        if pkt[IP].len != 20 + 20 + payload_len:
            bad += 1
            print(f"FAIL frame {n}: IP total length {pkt[IP].len}")
        if pkt[TCP].flags != "PA":
            bad += 1
            print(f"FAIL frame {n}: TCP flags {pkt[TCP].flags}, expected PA")

        # sequence numbers must advance by exactly the payload length
        if prev_seq is not None and pkt[TCP].seq != (prev_seq + payload_len) % (1 << 32):
            bad += 1
            print(f"FAIL frame {n}: seq {pkt[TCP].seq}, expected {prev_seq + payload_len}")
        prev_seq = pkt[TCP].seq

    if bad:
        print(f"FAIL: {bad} problem(s) across {n} frames")
        sys.exit(1)
    print(f"PASS: {n} frames verified independently by scapy "
          f"(checksums, lengths, flags, sequence advance)")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 52)
