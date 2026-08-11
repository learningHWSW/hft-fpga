"""The AXI-Lite address map is a contract between two files: the host derives
word offsets in regmap.py, the RTL hard-codes them as A_* localparams in
step5-board/rtl/axil_regfile.sv. If they ever drift, a host write lands in the
wrong register and nothing complains -- exactly the silent-mismatch class this
project makes a point of turning into a diff.

So this test parses the RTL localparams and diffs them against the host map.
It also round-trips values through reg_words (the wide-field split) and checks
the control/status/ID anchors. Run: python3 -m tests.test_regmap (from step7-host/).
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from host import regmap

RTL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "..", "step5-board", "rtl", "axil_regfile.sv")

# RTL A_* localparam name -> (host register name, word part: 0=lo, 1=hi)
A_TO_REG = {
    "GROUP_IP": ("cfg_group_ip", 0), "UDP_PORT": ("cfg_udp_port", 0),
    "TRACK_LOCATE": ("cfg_track_locate", 0), "BAND_BASE": ("cfg_band_base", 0),
    "ENABLE": ("cfg_enable", 0), "MAX_SPREAD": ("cfg_max_spread", 0),
    "RATIO_SHIFT": ("cfg_ratio_shift", 0), "MIN_QTY": ("cfg_min_qty", 0),
    "ORDER_QTY": ("cfg_order_qty", 0), "POS_LIMIT": ("cfg_pos_limit", 0),
    "MAX_INFLIGHT": ("cfg_max_inflight", 0), "SWEEP_EN": ("cfg_sweep_en", 0),
    "SWEEP_MINLV": ("cfg_sweep_min_levels", 0),
    "SWEEP_GAP_LO": ("cfg_sweep_gap", 0), "SWEEP_GAP_HI": ("cfg_sweep_gap", 1),
    "TOKEN_LO": ("cfg_token_prefix", 0), "TOKEN_HI": ("cfg_token_prefix", 1),
    "STOCK_LO": ("cfg_stock", 0), "STOCK_HI": ("cfg_stock", 1),
    "FIRM": ("cfg_firm", 0), "TIF": ("cfg_tif", 0),
    "OUCH_MINQ": ("cfg_ouch_min_qty", 0), "DISPLAY": ("cfg_display", 0),
    "CAPACITY": ("cfg_capacity", 0), "SWEEP": ("cfg_sweep", 0),
    "CROSS": ("cfg_cross", 0), "CUST": ("cfg_cust", 0),
    "DSTMAC_LO": ("cfg_dst_mac", 0), "DSTMAC_HI": ("cfg_dst_mac", 1),
    "SRCMAC_LO": ("cfg_src_mac", 0), "SRCMAC_HI": ("cfg_src_mac", 1),
    "SRC_IP": ("cfg_src_ip", 0), "DST_IP": ("cfg_dst_ip", 0),
    "SRC_PORT": ("cfg_src_port", 0), "DST_PORT": ("cfg_dst_port", 0),
    "INIT_SEQ": ("cfg_init_seq", 0), "ACK_NUM": ("cfg_ack_num", 0),
    "WINDOW": ("cfg_window", 0), "INIT_ID": ("cfg_init_id", 0),
    "IGMP_EN": ("cfg_igmp_en", 0), "IGMP_INTERVAL": ("cfg_igmp_interval", 0),
    "GROUP_IP_B": ("cfg_group_ip_b", 0),
}
# anchors that are not per-register config words
ANCHORS = {"CTRL", "STAT", "ID", "RESEND_AGE", "RTO_EN", "RTO_CYCLES",
           "RTO_RETRIES",
           # base of the per-symbol config block; its contents are derived from
           # it on both sides (regmap.sym_offsets), so the anchor is the contract
           "SYM"}

fails = 0


def check(cond, msg):
    global fails
    print(("PASS" if cond else "FAIL") + ": " + msg)
    if not cond:
        fails += 1


def parse_rtl_localparams():
    """Every `A_<NAME>=<int>` in the RTL -> {NAME: index}."""
    text = open(RTL).read()
    return {m.group(1): int(m.group(2))
            for m in re.finditer(r"\bA_([A-Z0-9_]+)\s*=\s*(\d+)", text)}


def test_rtl_matches_host():
    a = parse_rtl_localparams()
    check(len(a) > 0, f"parsed A_* localparams from axil_regfile.sv ({len(a)})")

    # every config A_* the RTL declares maps to the host offset it expects
    for key, idx in a.items():
        if key in ANCHORS:
            continue
        check(key in A_TO_REG, f"A_{key} is a known register")
        if key not in A_TO_REG:
            continue
        name, part = A_TO_REG[key]
        want = regmap.WORD_OFFSET[name][part] // 4
        check(want == idx, f"A_{key}=word{idx} matches host {name}[{part}]=word{want}")

    # and every host word the RTL should have is actually declared
    declared = {A_TO_REG[k] for k in a if k in A_TO_REG}
    for name, offs in regmap.WORD_OFFSET.items():
        for part in range(len(offs)):
            check((name, part) in declared, f"RTL declares {name}[{part}]")

    # control / status / ID anchors
    check(a.get("CTRL", -1) * 4 == regmap.CTRL_OFFSET,
          f"CTRL at 0x{regmap.CTRL_OFFSET:X}")
    check(a.get("STAT", -1) * 4 == regmap.STATUS_BASE,
          f"status base at 0x{regmap.STATUS_BASE:X}")
    check(a.get("ID", -1) * 4 == regmap.ID_OFFSET,
          f"ID at 0x{regmap.ID_OFFSET:X}")
    # RESEND_AGE arrived with tx_replay_buf and was never added here, so this
    # check failed from that commit until the counters were published: A_* in the
    # RTL, absent from the host map, and the test said so on every run.
    check(a.get("RESEND_AGE", -1) * 4 == regmap.RESEND_AGE_OFFSET,
          f"resend age at 0x{regmap.RESEND_AGE_OFFSET:X}")
    for key, off in (("RTO_EN", regmap.RTO_EN_OFFSET),
                     ("RTO_CYCLES", regmap.RTO_CYCLES_OFFSET),
                     ("RTO_RETRIES", regmap.RTO_RETRIES_OFFSET)):
        check(a.get(key, -1) * 4 == off, f"A_{key} at 0x{off:X}")


def test_status_order_matches_rtl():
    """The config words were diffed against the RTL from the start; the STATUS
    list was not, and it is the half that grows. Every counter published since
    has been an append to two files that nothing forced to agree -- so parse the
    read mux and diff the order, which is the whole contract for a read-only
    register: word N of the map must be the counter the RTL returns at A_STAT+N.
    """
    text = open(RTL).read()
    mux = {int(m.group(1)): m.group(2)
           for m in re.finditer(r"A_STAT\+(\d+):\s*readmux\s*=\s*\{?[^;]*?"
                                r"\b(st_[a-z0-9_]+)\b", text)}
    check(len(mux) > 0, f"parsed the status read mux ({len(mux)} entries)")
    check(len(mux) == len(regmap.STATUS),
          f"RTL returns {len(mux)} status words, host maps {len(regmap.STATUS)}")
    for i, name in enumerate(regmap.STATUS):
        check(mux.get(i) == name,
              f"A_STAT+{i} is {name} (RTL: {mux.get(i)}) @ 0x{regmap.STATUS_OFFSET[name]:X}")


def test_per_symbol_block_matches_rtl():
    """The per-symbol config block is derived on both sides from one anchor, so
    the anchor is the whole contract -- and an anchor that drifted would put
    symbol 1's stock somewhere the RTL is not reading, which no other test here
    would notice."""
    a = parse_rtl_localparams()
    check("SYM" in a, "axil_regfile declares A_SYM")
    if "SYM" not in a:
        return
    check(4 * a["SYM"] == regmap.SYM_BASE,
          f"A_SYM word {a['SYM']} = 0x{4*a['SYM']:X}, host SYM_BASE "
          f"0x{regmap.SYM_BASE:X}")
    # symbol 0 answers from the registers it has always had, not from the block
    s0 = regmap.sym_offsets(0)
    check(s0["track_locate"] == regmap.WORD_OFFSET["cfg_track_locate"][0],
          "symbol 0's locate is still cfg_track_locate")
    check(s0["stock_hi"] == regmap.WORD_OFFSET["cfg_stock"][1],
          "symbol 0's stock is still cfg_stock")
    # the block is four words per symbol, ordered locate/base/stock_lo/stock_hi
    for k in range(1, regmap.SYM_MAX):
        o = regmap.sym_offsets(k)
        base = regmap.SYM_BASE + regmap.SYM_STRIDE * (k - 1)
        check([o["track_locate"], o["band_base"], o["stock_lo"], o["stock_hi"]]
              == [base, base + 4, base + 8, base + 12],
              f"symbol {k} occupies 0x{base:X}..0x{base+12:X}")
    # and it must not run into the status page
    last = regmap.sym_offsets(regmap.SYM_MAX - 1)["stock_hi"]
    check(last < regmap.STATUS_BASE,
          f"the block ends at 0x{last:X}, below the status base "
          f"0x{regmap.STATUS_BASE:X}")
    # asking for a symbol the map cannot hold is an error, not a silent alias
    try:
        regmap.sym_offsets(regmap.SYM_MAX)
        check(False, f"sym_offsets({regmap.SYM_MAX}) is refused")
    except ValueError:
        check(True, f"sym_offsets({regmap.SYM_MAX}) is refused")


def test_reg_words_roundtrip():
    # 64-bit, 48-bit and 32-bit values split into words and reassemble
    cases = {
        "cfg_stock": 0x5566_7788_1122_3344,
        "cfg_sweep_gap": 0x9911_AABB_CCDD,
        "cfg_dst_mac": 0xAABB_CCDD_EEFF,
        "cfg_band_base": 2800000,
        "cfg_track_locate": 13,
    }
    for name, val in cases.items():
        words = regmap.reg_words(name, val)
        # lo word first, then hi -- reassemble little-word-endian
        got = sum(w << (32 * k) for k, (_off, w) in enumerate(words))
        check(got == val, f"{name} round-trips through reg_words (0x{val:X})")
        # offsets are contiguous and word-aligned
        offs = [o for o, _ in words]
        check(offs == regmap.WORD_OFFSET[name], f"{name} offsets match map")


def test_axil_writes_cover_config():
    dev = regmap.Device()
    dev.write("cfg_track_locate", 13)
    dev.write("cfg_stock", regmap.ascii_le("AAPL    ", 8))
    writes = dev.axil_writes()
    # one entry per config word: 34 registers, 5 of them wide -> 39 words
    check(len(writes) == regmap.NCFG, f"axil_writes emits {regmap.NCFG} words ({len(writes)})")
    offs = [o for o, _ in writes]
    check(offs == sorted(offs), "axil_writes offsets are in ascending order")
    check(len(set(offs)) == len(offs), "axil_writes offsets are unique")
    # the value we set shows up at its mapped offset
    lo_off = regmap.WORD_OFFSET["cfg_track_locate"][0]
    check(dict(writes)[lo_off] == 13, "cfg_track_locate=13 lands at its offset")


if __name__ == "__main__":
    test_rtl_matches_host()
    test_status_order_matches_rtl()
    test_per_symbol_block_matches_rtl()
    test_reg_words_roundtrip()
    test_axil_writes_cover_config()
    print(f"\n{'ALL PASS' if fails == 0 else str(fails) + ' FAILED'}")
    sys.exit(1 if fails else 0)
