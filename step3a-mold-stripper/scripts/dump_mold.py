#!/usr/bin/env python3
"""Golden dump for the MoldUDP64 stripper.

Parses a .mold file (2B BE length-prefixed UDP payloads, see gen_itch.py)
and prints, in stream order:
  - one canonical decode line per delivered message (format shared with
    step 2 via dump_itch.fmt_msg — must stay identical to the TB's log)
  - "GAP expected=E got=S missing=N" when a sequence gap is detected
  - "HB seq=S" per heartbeat
  - "EOS seq=S" at End of Session

Receiver model mirrors mold_stripper.sv: expected_seq resets to 1; a gap is
seq > expected on any packet (data or heartbeat); a data packet with
seq < expected is a duplicate and silently dropped (counted, not logged).
"""
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "step2-rtl-decoder", "scripts"))
from dump_itch import fmt_msg  # noqa: E402

EOS_COUNT = 0xFFFF


def main(path: str):
    blob = open(path, "rb").read()
    i, expected = 0, 1
    while i + 2 <= len(blob):
        (plen,) = struct.unpack_from(">H", blob, i)
        i += 2
        pkt = blob[i:i + plen]
        i += plen
        seq, count = struct.unpack_from(">QH", pkt, 10)
        if count == EOS_COUNT:
            print(f"EOS seq={seq}")
            break
        if seq > expected:
            print(f"GAP expected={expected} got={seq} missing={seq - expected}")
        if count == 0:
            print(f"HB seq={seq}")
            expected = max(expected, seq)
            continue
        if seq < expected:
            continue  # duplicate: dropped, not logged
        j = 20
        for _ in range(count):
            (ml,) = struct.unpack_from(">H", pkt, j)
            j += 2
            print(fmt_msg(pkt[j:j + ml]))
            j += ml
        expected = seq + count


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "test.mold")
