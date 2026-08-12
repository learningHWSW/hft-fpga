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
CTRL_OFFSET    = 4 * NCFG               # 0xA8: write bit0=load, bit1=order_ack,
                                        #       bit2=resend_req
# The replay buffer's age selector sits one word ABOVE ctrl rather than inside
# the config block, because it is an argument to a pulse and not state the
# datapath reads continuously. It is therefore its own anchor: putting it in REGS
# would grow NCFG and move CTRL, which is a shipped offset.
RESEND_AGE_OFFSET = CTRL_OFFSET + 4     # 0xAC: which stored frame to re-send
# Automatic retransmission (tx_rto), above ctrl for the same reason. Off unless
# RTO_EN is written: with it clear the transmit path is what it was before the
# detector existed, which is why it is not in REGS with the rest of the setup.
#
# WHATEVER YOU WRITE TO THE TWO BELOW IS A GUESS, and it is worth knowing that
# before choosing one. Every other number this project configures was measured
# first; these two cannot be, because the only correct input is the distribution
# of venue acknowledgement latency and nothing has ever acknowledged an order
# here. Too low and the card resends orders the venue already has; too high and
# a lost order is noticed milliseconds late, which is the reason for doing this
# in hardware at all. st_ack_* (below) is the instrument that will answer it the
# first time a real counterparty answers; until st_ack_samples is nonzero, treat
# any value here as arbitrary. FINDINGS section 8.
RTO_EN_OFFSET      = CTRL_OFFSET + 8    # 0xB0: bit0 enables the detector
RTO_CYCLES_OFFSET  = CTRL_OFFSET + 12   # 0xB4: idle core cycles before a resend (GUESS)
RTO_RETRIES_OFFSET = CTRL_OFFSET + 16   # 0xB8: attempts per unacknowledged frame (GUESS)
# ---- per-symbol configuration block (mirrors axil_regfile's A_SYM) ----
# Symbol 0's locate, band base and stock keep the registers they have always
# had, in REGS above. Symbols 1 and up live here, four words each, in the gap
# between the RTO words and the status base -- so nothing that has shipped
# moves, at the cost of the map being asymmetric in the first symbol. That is
# the right trade: making the map pretty would repoint four offsets that hosts
# have already been compiled against.
#
# Sixteen words is four symbols, i.e. NSYM up to 5. Beyond that both this and
# the order table need extending, and the table is the harder one (FINDINGS
# §4.4 measures how much bigger it has to be at each K).
SYM_BASE       = 0x0C0
SYM_STRIDE     = 16                     # 4 words per symbol
SYM_MAX        = 5                      # symbol 0 + four in the block


def sym_offsets(k: int):
    """Byte offsets of symbol k's {locate, band_base, stock_lo, stock_hi}.

    Symbol 0 answers from the original registers, so a caller can loop over
    every tracked symbol without special-casing the first one."""
    if k == 0:
        return {"track_locate": WORD_OFFSET["cfg_track_locate"][0],
                "band_base":    WORD_OFFSET["cfg_band_base"][0],
                "stock_lo":     WORD_OFFSET["cfg_stock"][0],
                "stock_hi":     WORD_OFFSET["cfg_stock"][1]}
    if not 1 <= k < SYM_MAX:
        raise ValueError(f"symbol {k} is outside the register map (0..{SYM_MAX-1})")
    b = SYM_BASE + SYM_STRIDE * (k - 1)
    return {"track_locate": b, "band_base": b + 4,
            "stock_lo": b + 8, "stock_hi": b + 12}


STATUS_BASE    = 0x100
ID_OFFSET      = 0x1FC
ID_VALUE       = 0x54325430            # "T2T0"
CTRL_LOAD      = 0x1
CTRL_ORDER_ACK = 0x2
CTRL_RESEND    = 0x4

# Status counters, read-only (offset = STATUS_BASE + 4*i), and the list is
# APPEND-ONLY. The first nineteen are in t2t_top st_* order; anything published
# later goes at the end, because an offset that has shipped in t2t_regs.h cannot
# move without silently repointing a host that was not rebuilt.
# tests/test_regmap.py diffs this order against the RTL read mux.
STATUS = [
    "st_rx_drop", "st_rx_hwm", "st_init_done", "st_frames_in", "st_frames_kept",
    "st_gap_total", "st_ot_overflow", "st_pl_oob", "st_beat_drop", "st_msg_drop",
    "st_delta_drop", "st_sent", "st_blk_pos", "st_blk_inflight", "st_blk_txfull",
    "st_position", "st_seq_num", "st_frame_cnt", "st_tx_drop",
    # published later: the fast/slow book split, then the order session inbound
    "st_bbo_early", "st_bbo_late", "st_bbo_mismatch",
    "st_rx_peer_ack", "st_rx_ooo", "st_rx_dup", "st_rx_sess_frames",
    # and the card's own retransmissions
    "st_rto_fired", "st_rto_gaveup",
    # the replay buffer behind them, and the last rejection reason the RTL
    # counted but the map did not carry
    "st_rb_stored", "st_rb_resent", "st_rb_drop", "st_blk_qty",
    # Per-symbol positions for symbols 1..4. Symbol 0 stays at st_position,
    # where it has always been. Always four entries whatever NSYM the build
    # has, because a map whose LENGTH depended on a build parameter would not
    # be a contract; symbols a build does not have read zero, which is also
    # their position. A single summed "net position" is deliberately not
    # offered: long one name and short another is not flat.
    "st_position_1", "st_position_2", "st_position_3", "st_position_4",
    # BBO records lost merging the per-symbol book streams. Zero by
    # construction (bbo_arb does the arithmetic); published because the
    # alternative is a silent hole in one symbol's stream.
    "st_bbo_arb_drop",
    # Build geometry, read-only and constant: byte 0 NSYM, byte 1 OT_SETS_BITS,
    # byte 2 OT_WAYS. Not a counter -- it is here because a bitstream that
    # cannot say what it is gets configured as something it is not, and the
    # status page is the one place a host already reads.
    "st_build_geom",
    # Venue acknowledgement latency, in CORE CYCLES, from ack_latency.sv. The
    # number tx_rto's cfg_rto_cycles should have been chosen from: it never was,
    # because nothing has ever acknowledged an order on this bench.
    #
    # READ st_ack_samples FIRST. Zero means no counterparty has ever answered --
    # the normal state under GT loopback -- and the other five words are then
    # meaningless rather than small. The mean is st_ack_sum / st_ack_samples,
    # with the sum split low word first like every other 64-bit field here.
    #
    # The sum's two halves are two separate bus reads of a counter that is still
    # moving, so they can tear -- the same exposure the latency probe's own
    # 64-bit sum has, and it is left alone for the same reason: samples arrive
    # microseconds apart at most, a torn read costs one wrong mean, and freezing
    # the counters to read them would put a handshake in the datapath to serve a
    # diagnostic. Read st_ack_samples either side if a single mean has to be
    # exact.
    "st_ack_last", "st_ack_min", "st_ack_max", "st_ack_samples",
    "st_ack_sum_lo", "st_ack_sum_hi",
    # measurements thrown away: the frame was retransmitted while being timed
    # (so the ack answers one of two copies), or nothing answered at all
    "st_ack_lost",
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
