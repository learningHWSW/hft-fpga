#!/usr/bin/env python3
"""Check what the card re-sent by itself.

With automatic retransmission enabled, the capture holds more order frames than
the strategy built, and the whole claim about safety rests on WHAT the extra ones
are: a resend must be the original bytes again -- same TCP sequence number, same
OUCH order token -- because that is what makes the venue discard it as a
duplicate instead of filling it twice. A "retransmission" that differs anywhere
is a second order wearing the first one's name.

So this compares against the golden the run already has:

  * the frames the strategy built must appear, in order, and be byte-identical
    to the golden -- retransmission must not perturb the original stream;
  * every extra frame must be byte-identical to one of them -- and it says which,
    so a resend of the wrong slot shows up as an age, not as a mystery.

Usage: check_resend.py <golden.log> <captured.log> [min_resends]
Both files are the hex-per-line format pack_eth.py unpack prints.
"""
import sys


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: check_resend.py <golden.log> <captured.log> "
                         "[min_resends]\n")
        return 2
    gold = [l.strip() for l in open(argv[1]) if l.strip()]
    got = [l.strip() for l in open(argv[2]) if l.strip()]
    want_min = int(argv[3]) if len(argv) > 3 else 1

    if len(got) < len(gold):
        print(f"FAIL: {len(got)} frames captured, golden has {len(gold)}")
        return 1

    # The originals, in order and unchanged.
    for i, (g, c) in enumerate(zip(gold, got)):
        if g != c:
            print(f"FAIL: frame {i} differs from the golden")
            return 1

    extra = got[len(gold):]
    if len(extra) < want_min:
        print(f"FAIL: expected at least {want_min} retransmission(s), saw {len(extra)}")
        return 1

    # Every extra frame is one of the originals, sent again.
    index = {frame: i for i, frame in enumerate(gold)}
    ages = []
    for k, frame in enumerate(extra):
        if frame not in index:
            print(f"FAIL: retransmission {k} is not a copy of any frame sent")
            return 1
        # age counted the way tx_replay_buf indexes: 0 is the most recent.
        ages.append(len(gold) - 1 - index[frame])

    print(f"PASS: {len(gold)} orders unchanged, {len(extra)} resent "
          f"(replay ages {ages})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
