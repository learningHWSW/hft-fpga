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
    ("cfg_igmp_en", 1), ("cfg_igmp_interval", 4), ("cfg_group_ip_b", 4),
]
_WIDTH = dict(REGS)


# ---- AXI4-Lite word map (mirrors step5-board/rtl/axil_regfile.sv) ----
# The RTL and the host must agree on which 32-bit word each register lands in.
# Both follow one rule -- one word per register in REG order, wide fields
# (>4 bytes) split into a low word then a high word -- so the offsets are
# derived here rather than hand-listed, and match the RTL by construction.
# tests/test_regmap.py parses the RTL localparams and diffs them against this.
def _word_offsets():
    off, idx = {}, 0
    for name, w in REGS:
        n = 1 if w <= 4 else 2          # 48/64-bit fields take two words
        off[name] = [4 * (idx + k) for k in range(n)]
        idx += n
    return off, idx


WORD_OFFSET, NCFG = _word_offsets()
CTRL_OFFSET    = 4 * NCFG               # 0x9C: write bit0=load, bit1=order_ack
STATUS_BASE    = 0x100
ID_OFFSET      = 0x1FC
ID_VALUE       = 0x54325430            # "T2T0"
CTRL_LOAD      = 0x1
CTRL_ORDER_ACK = 0x2

# status counters, read-only, in t2t_top st_* order (offset = STATUS_BASE+4*i)
STATUS = [
    "st_rx_drop", "st_rx_hwm", "st_init_done", "st_frames_in", "st_frames_kept",
    "st_gap_total", "st_ot_overflow", "st_pl_oob", "st_beat_drop", "st_msg_drop",
    "st_delta_drop", "st_sent", "st_blk_pos", "st_blk_inflight", "st_blk_txfull",
    "st_position", "st_seq_num", "st_frame_cnt", "st_tx_drop",
]
STATUS_OFFSET = {name: STATUS_BASE + 4 * i for i, name in enumerate(STATUS)}


def reg_words(name: str, value: int):
    """Decompose a register value into the (byte_offset, 32-bit word) AXI-Lite
    writes the RTL expects: low word first, then the high word for 48/64-bit
    fields. This is the actual bus transaction a driver issues over QDMA."""
    offs = WORD_OFFSET[name]
    return [(offs[k], (value >> (32 * k)) & 0xFFFFFFFF) for k in range(len(offs))]


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

    def axil_writes(self):
        """The whole config as the ordered (byte_offset, 32-bit word) AXI-Lite
        writes a driver issues over QDMA -- the transport the RTL register file
        (axil_regfile.sv) decodes. Off a card this is what a real board's write
        stream would be; on a card these go straight to the BAR."""
        out = []
        for name, _ in REGS:
            out += reg_words(name, self.regs[name])
        return out
