#!/usr/bin/env python3
"""Synthetic A/B MoldUDP64 streams for tb_feed_ab.

Builds N sequenced packets, then splits them across two redundant lines with
DIFFERENT drops so neither line alone is complete but their union is -- exactly
the single-line-loss case A/B arbitration exists to recover. The golden is the
clean, in-order stream the merge must reconstruct.

  mode "recover": drop packet i on A if i%3==1, on B if i%3==2  -> union complete
  mode "gap":     additionally drop one packet on BOTH lines    -> a true gap the
                  merge must skip (ev_gap), golden omits it

Each packet fits one 512-bit beat (<=64 B): 20-byte MoldUDP64 header (session,
seq, count) + `count` messages of (2-byte len + payload). Payload encodes the
packet index so frames are distinct and the diff is meaningful.

Outputs (in the cwd): ab_a.frames, ab_b.frames (2-byte length-prefixed binary,
the format the TB reads) and ab_gold.hex (one hex line per golden frame).

  python3 gen_ab.py <recover|gap> [n_packets]
"""
import sys

SESSION = b"ABSESSION1"          # 10 bytes
COUNT   = 2                      # messages per packet
MSGLEN  = 12                     # bytes per message body


def packet(seq, idx):
    body = SESSION + seq.to_bytes(8, "big") + COUNT.to_bytes(2, "big")
    for m in range(COUNT):
        msg = bytes([idx & 0xFF, m]) + bytes(MSGLEN - 2)   # idx,msg then zeros
        body += len(msg).to_bytes(2, "big") + msg
    return body


def main(mode, n):
    pkts, seq = [], 1
    for i in range(n):
        pkts.append((i, seq, packet(seq, i)))
        seq += COUNT

    both_gap = (n // 2) if mode == "gap" else -1     # packet dropped on both lines
    drop_a = {i for i, _, _ in pkts if i % 3 == 1} | ({both_gap} if both_gap >= 0 else set())
    drop_b = {i for i, _, _ in pkts if i % 3 == 2} | ({both_gap} if both_gap >= 0 else set())

    def write_frames(path, drop):
        with open(path, "wb") as f:
            for i, _s, p in pkts:
                if i in drop:
                    continue
                f.write(len(p).to_bytes(2, "big") + p)

    write_frames("ab_a.frames", drop_a)
    write_frames("ab_b.frames", drop_b)

    with open("ab_gold.hex", "w") as f:
        for i, _s, p in pkts:
            if i == both_gap:              # a true double-gap is not recoverable
                continue
            f.write(p.hex() + "\n")

    kept = sum(1 for i, _, _ in pkts if i != both_gap)
    print(f"{mode}: {n} packets, gold {kept}, "
          f"A drops {len(drop_a)}, B drops {len(drop_b)}"
          + (f", both-gap pkt {both_gap}" if both_gap >= 0 else ""), file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 30)
