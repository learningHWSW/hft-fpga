#!/usr/bin/env python3
"""Translate between the `.eth` stimulus files the simulations use and the
64-byte-aligned record images the on-card harness reads and writes.

Why this is a host-side script and not RTL. A `.eth` file is a bare stream of
{2-byte big-endian length, frame bytes} with no alignment, so an injector reading
it directly would need a barrel shifter to locate each frame's first byte inside
a 512-bit beat -- i.e. a second mold_splitter, the hardest block in the project,
rebuilt for no design reason (step8-hw/rtl/eth_replay.sv says the same). Padding
here is a dozen lines of Python and costs only HBM address space.

The record layout is identical in both directions, so ONE parser serves the
replay image and the capture image:

    byte 0..1    frame length, little-endian uint16   (0 = end of image)
    byte 64..    the frame bytes

`unpack` classifies frames exactly as tb_t2t_axil_full.sv does -- ARP by
ethertype, then IPv4 protocol 6 (TCP order) or 2 (IGMP report) -- so the order
frames it prints are byte-for-byte comparable with the testbench's log and
therefore with step 6's golden. Reusing the testbench's classification instead of
reinventing it is the point: the hardware run is checked against the same golden,
not against a second implementation that could agree with its own mistake.
"""
import sys

BEAT = 64                      # bytes per 512-bit beat
RECORD_BEATS = 32              # capture stride, mirrors eth_capture.sv
RECORD_BYTES = RECORD_BEATS * BEAT

# The injector reads fixed-length bursts (eth_replay.sv BURST), because a
# variable length put a carry chain on its critical path and cost 300 MHz. That
# moves one obligation here: the image must be a whole number of bursts, or the
# final burst would read past the buffer. Padding is zeros, which parse as
# zero-length headers -- harmless, since the real terminator is reached first.
BURST_BEATS = 16
BURST_BYTES = BURST_BEATS * BEAT


def read_eth(path):
    """Yield frames from a `.eth` file: 2-byte big-endian length, then bytes."""
    with open(path, "rb") as f:
        while True:
            hdr = f.read(2)
            if len(hdr) < 2:
                return
            n = (hdr[0] << 8) | hdr[1]
            if n == 0 or n > 4000:
                raise ValueError(f"bad frame length {n} in {path}")
            frame = f.read(n)
            if len(frame) < n:
                raise ValueError(f"truncated frame in {path}")
            yield frame


def pack(eth_path, out_path):
    """`.eth` -> replay image. Returns (frames, beats) for the host to program
    into the harness registers; beats is what eth_replay's cfg_beats needs."""
    beats = 0
    frames = 0
    with open(out_path, "wb") as o:
        for frame in read_eth(eth_path):
            hdr = bytearray(BEAT)
            hdr[0] = len(frame) & 0xFF
            hdr[1] = (len(frame) >> 8) & 0xFF
            o.write(hdr)
            body = frame + bytes((-len(frame)) % BEAT)   # pad to a whole beat
            o.write(body)
            beats += 1 + len(body) // BEAT
            frames += 1
        o.write(bytearray(BEAT))                          # terminator: length 0
        beats += 1
        # round the image up to a whole number of read bursts
        pad_beats = (-beats) % BURST_BEATS
        o.write(bytearray(pad_beats * BEAT))
        beats += pad_beats
    return frames, beats


def unpack(cap_path, n_records):
    """Capture image -> per-frame bytes, in the order the card emitted them."""
    out = []
    with open(cap_path, "rb") as f:
        blob = f.read()
    for i in range(n_records):
        off = i * RECORD_BYTES
        if off + BEAT > len(blob):
            break
        n = blob[off] | (blob[off + 1] << 8)
        if n == 0 or off + BEAT + n > len(blob):
            break
        out.append(blob[off + BEAT: off + BEAT + n])
    return out


def classify(frame):
    """'arp' | 'tcp' | 'igmp' | 'other' -- the same test tb_t2t_axil_full uses."""
    if len(frame) < 24:
        return "other"
    if frame[12] == 0x08 and frame[13] == 0x06:
        return "arp"
    if frame[23] == 6:
        return "tcp"
    if frame[23] == 2:
        return "igmp"
    return "other"


def main(argv):
    if len(argv) >= 4 and argv[1] == "pack":
        frames, beats = pack(argv[2], argv[3])
        # stdout is consumed by the Makefile / host, so keep it machine-readable
        print(f"frames={frames} beats={beats}")
        return 0

    if len(argv) >= 4 and argv[1] == "unpack":
        cap, n = argv[2], int(argv[3])
        counts = {"tcp": 0, "igmp": 0, "arp": 0, "other": 0}
        for frame in unpack(cap, n):
            kind = classify(frame)
            counts[kind] += 1
            if kind == "tcp":                 # the order frames the golden covers
                print(frame.hex())
        sys.stderr.write(
            "orders={tcp} igmp={igmp} arp={arp} other={other}\n".format(**counts))
        return 0

    sys.stderr.write(
        "usage: pack_eth.py pack <in.eth> <out.bin>\n"
        "       pack_eth.py unpack <capture.bin> <n_records>   # orders to stdout\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
