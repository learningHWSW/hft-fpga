"""The device register map: every cfg_* input of t2t_top, and how the host
builds its value from high-level settings.

On the real board these are AXI-Lite registers reached over QDMA/PCIe. Without a
card the Device below writes them to a dict and can dump them, so the host code
is identical whether or not silicon is present -- only the transport changes.
The point of listing them here is that the host and the RTL agree on exactly
what has to be configured before the feed is enabled; the field widths mirror
the port declarations in step5-board/rtl/t2t_top.sv.

Names and widths are kept 1:1 with the RTL ports so a mismatch is a diff, not a
silent bug -- REG lists (name, bytes).
"""
import struct

# (name, width_bytes) — mirrors t2t_top's cfg_* ports, in declaration order
REGS = [
    ("cfg_group_ip", 4), ("cfg_udp_port", 2), ("cfg_track_locate", 2),
    ("cfg_band_base", 4),
    ("cfg_enable", 1), ("cfg_max_spread", 4), ("cfg_ratio_shift", 1),
    ("cfg_min_qty", 4), ("cfg_order_qty", 4), ("cfg_pos_limit", 4),
    ("cfg_max_inflight", 2),
    ("cfg_sweep_en", 1), ("cfg_sweep_min_levels", 4), ("cfg_sweep_gap", 6),
    ("cfg_token_prefix", 6), ("cfg_stock", 8), ("cfg_firm", 4), ("cfg_tif", 4),
    ("cfg_ouch_min_qty", 4), ("cfg_display", 1), ("cfg_capacity", 1),
    ("cfg_sweep", 1), ("cfg_cross", 1), ("cfg_cust", 1),
    ("cfg_dst_mac", 6), ("cfg_src_mac", 6), ("cfg_src_ip", 4), ("cfg_dst_ip", 4),
    ("cfg_src_port", 2), ("cfg_dst_port", 2), ("cfg_init_seq", 4),
    ("cfg_ack_num", 4), ("cfg_window", 2), ("cfg_init_id", 2),
]
_WIDTH = dict(REGS)


def ip2int(s: str) -> int:
    a, b, c, d = (int(x) for x in s.split("."))
    return (a << 24) | (b << 16) | (c << 8) | d


def mac2int(s: str) -> int:
    return int(s.replace(":", ""), 16)


def ascii_le(s: str, n: int) -> int:
    """Pack an n-char ASCII string with byte 0 in the low byte -- the order the
    RTL reads cfg_token_prefix/cfg_stock/cfg_firm (byte 0 in bits[7:0])."""
    b = s[:n].ljust(n).encode()
    return int.from_bytes(b, "little")


class Device:
    """The set of cfg_* registers. Off a card this is a dict; the transport
    (AXI-Lite over QDMA) is the only thing a real board changes."""

    def __init__(self):
        self.regs = {name: 0 for name, _ in REGS}
        self.load_pulsed = 0
        self.order_acks = 0        # count of cfg_order_ack pulses issued

    def write(self, name: str, value: int):
        if name not in _WIDTH:
            raise KeyError(f"unknown register {name}")
        limit = 1 << (8 * _WIDTH[name])
        if not (0 <= value < limit):
            raise ValueError(f"{name}={value} does not fit {_WIDTH[name]} bytes")
        self.regs[name] = value

    def pulse_load(self):
        """cfg_load: hand the (software-established) connection to the FPGA."""
        self.load_pulsed += 1

    def pulse_order_ack(self):
        """cfg_order_ack: release one in-flight slot when the exchange acks."""
        self.order_acks += 1

    def dump(self) -> bytes:
        """Serialise the whole map big-endian, in REG order -- a stand-in for a
        BAR image, and something a test can checksum."""
        out = bytearray()
        for name, w in REGS:
            out += self.regs[name].to_bytes(w, "big")
        return bytes(out)
