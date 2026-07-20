#!/usr/bin/env python3
"""Golden decode dump: prints one canonical line per ITCH message.

Line formats must stay byte-identical with tb_itch_decoder.sv's log_msg().
fmt_msg() is imported by step 3a's dump_mold.py — the format lives here only.
"""
import sys


def be(b: bytes) -> int:
    return int.from_bytes(b, "big")


def fmt_msg(m: bytes) -> str:
    t = chr(m[0])
    loc = be(m[1:3])
    ts = be(m[5:11])
    if t == "S":
        return f"S locate={loc} ts={ts} event={chr(m[11])}"
    if t == "R":
        return f"R locate={loc} ts={ts} stock='{m[11:19].decode()}'"
    if t in "AF":
        return (f"{t} locate={loc} ts={ts} ref={be(m[11:19])} side={chr(m[19])} "
                f"shares={be(m[20:24])} stock='{m[24:32].decode()}' price={be(m[32:36])}")
    if t == "E":
        return f"E locate={loc} ts={ts} ref={be(m[11:19])} shares={be(m[19:23])} match={be(m[23:31])}"
    if t == "C":
        return (f"C locate={loc} ts={ts} ref={be(m[11:19])} shares={be(m[19:23])} "
                f"match={be(m[23:31])} printable={chr(m[31])} price={be(m[32:36])}")
    if t == "X":
        return f"X locate={loc} ts={ts} ref={be(m[11:19])} shares={be(m[19:23])}"
    if t == "D":
        return f"D locate={loc} ts={ts} ref={be(m[11:19])}"
    if t == "U":
        return (f"U locate={loc} ts={ts} ref={be(m[11:19])} newref={be(m[19:27])} "
                f"shares={be(m[27:31])} price={be(m[31:35])}")
    if t == "P":
        return (f"P locate={loc} ts={ts} side={chr(m[19])} shares={be(m[20:24])} "
                f"stock='{m[24:32].decode()}' price={be(m[32:36])} match={be(m[36:44])}")
    return f"{t} locate={loc} ts={ts}"


def main(path: str):
    data = open(path, "rb").read()
    i = 0
    while i + 2 <= len(data):
        ln = be(data[i:i + 2])
        i += 2
        if ln == 0:
            break
        print(fmt_msg(data[i:i + ln]))
        i += ln


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "test.itch")
