"""End-to-end host tests over a real loopback TCP socket against the mock
exchange. Run: python3 -m tests.test_session  (from step7-host/).

Three things are proven:
  1. configuration -- every cfg_* register the RTL needs is written, and the
     serialized image round-trips through the widths the RTL declares;
  2. the SoupBinTCP session and OUCH round-trip -- login, send orders, receive
     Order Accepted + Executed, and the host's in-flight release and position
     bookkeeping track the fills;
  3. interop with the FPGA -- the OUCH bytes the RTL actually emitted
     (step6's ouch_rtl.log, if present) are sent verbatim and the mock exchange,
     an independent decoder, accepts every one.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from host import regmap, ouch
from host.session import HostSession
from host.mock_exchange import MockExchange

CFG = dict(
    group_ip="233.54.12.1", udp_port=26477, track_locate=13, band_base=2800000,
    max_spread=2000, ratio_shift=1, min_qty=100, order_qty=100, pos_limit=1000,
    max_inflight=4, sweep_en=True, sweep_min_levels=3, sweep_gap=250000,  # FINDINGS 5.1
    dst_mac="aa:bb:cc:dd:ee:ff", src_mac="00:11:22:33:44:55",
    src_ip="10.0.0.2", dst_ip="10.0.0.9", src_port=40001, dst_port=4001,
    init_seq=0x10000000, ack_num=0x20000000, window=65535, init_id=0x1000,
)

fails = 0


def check(cond, msg):
    global fails
    print(("PASS" if cond else "FAIL") + ": " + msg)
    if not cond:
        fails += 1


def test_configuration():
    dev = regmap.Device()
    HostSession(dev).configure(**CFG)
    img = dev.dump()
    total = sum(w for _, w in regmap.REGS)
    check(len(img) == total, f"register image is {total} bytes ({len(img)})")
    # spot-check a couple of fields decode back
    off = 0
    vals = {}
    for name, w in regmap.REGS:
        vals[name] = int.from_bytes(img[off:off + w], "big")
        off += w
    check(vals["cfg_track_locate"] == 13, "cfg_track_locate == 13")
    check(vals["cfg_sweep_min_levels"] == 3, "cfg_sweep_min_levels == 3")
    # cfg_stock is ASCII little-endian ("AAPL    ", byte 0 in low byte)
    stock = vals["cfg_stock"].to_bytes(8, "little").decode()
    check(stock == "AAPL    ", f"cfg_stock decodes to {stock!r}")


def test_session_roundtrip():
    ex = MockExchange(fill=True).start()
    try:
        dev = regmap.Device()
        # role="host": this is the host's OWN account, so it may send orders and
        # must NOT hand the connection to the card.
        s = HostSession(dev, role="host")
        s.configure(**CFG)
        s.connect("127.0.0.1", ex.port)
        check(dev.load_pulsed == 0,
              "host's own session does not pulse cfg_load")

        s.send_order(is_buy=True, shares=100, price=2896000)
        s.send_order(is_buy=False, shares=100, price=2890300)
        s.poll(0.5)

        check(s.accepted == 2, f"2 orders accepted ({s.accepted})")
        check(s.filled == 2, f"2 fills received ({s.filled})")
        check(s.inflight == 0, f"in-flight released to 0 ({s.inflight})")
        check(dev.order_acks == 2, f"cfg_order_ack pulsed twice ({dev.order_acks})")
        check(s.position == 0, f"position 0 after buy+sell 100 ({s.position})")
        check(len(ex.received) == 2, "exchange received both orders")
        s.logout()
    finally:
        ex.stop()


def test_fpga_interop():
    """Send the OUCH bytes the RTL actually produced, if available."""
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(here, "..", "..", "step6-strategy", "ouch_rtl.log"),
        os.path.join(here, "fixtures", "ouch_rtl.log"),
    ]
    path = next((p for p in candidates if os.path.exists(p)), None)
    if path is None:
        print("SKIP: no ouch_rtl.log (run step6 `make test` first) -- "
              "FPGA interop unverified")
        return
    lines = [l.strip() for l in open(path) if l.strip()]
    bodies = [bytes.fromhex(l)[3:] for l in lines]   # strip 3-byte SoupBinTCP

    ex = MockExchange(fill=False).start()
    try:
        s = HostSession(regmap.Device(), role="host")
        s.configure(**CFG)
        s.connect("127.0.0.1", ex.port)
        for b in bodies:
            s.send_ouch_payload(b)
        s.poll(1.0)
        check(len(ex.received) == len(bodies),
              f"exchange decoded all {len(bodies)} FPGA orders "
              f"({len(ex.received)})")
        check(s.accepted == len(bodies),
              f"host saw {len(bodies)} accepts ({s.accepted})")
        # the exchange's decode of the first order matches the OUCH bytes
        if ex.received:
            first = ex.received[0]
            ref = ouch.parse_enter_order(bodies[0])
            check(first["stock"] == ref["stock"] and first["price"] == ref["price"]
                  and first["shares"] == ref["shares"] and first["is_buy"] == ref["is_buy"],
                  "exchange decode of FPGA order matches its OUCH bytes")
        s.logout()
    finally:
        ex.stop()


def test_two_independent_sessions():
    """The arrangement that replaces split-sender TCP.

    OUCH 4.2: "Each physical OUCH host port is bound to a NASDAQ-assigned
    logical OUCH Account. On a given day, every order entered on OUCH is
    uniquely identified by the combination of the logical OUCH Account and the
    participant-created Token field."

    So the card gets its own port and account and is the ONLY sender on that
    byte stream, and the host gets its own. Nothing has to be forwarded and
    neither side needs the other's TCP sequence numbers.
    """
    ex = MockExchange(fill=False).start()
    try:
        dev = regmap.Device()

        # 1. the card's session: the host establishes it and hands it over
        fpga = HostSession(dev, role="fpga")
        fpga.configure(**CFG)
        acct_fpga = fpga.connect("127.0.0.1", ex.port)
        check(dev.load_pulsed == 1, "card's session pulses cfg_load once")

        # 2. the host's own session: separate connection, separate account
        host = HostSession(dev, role="host")
        host.connect("127.0.0.1", ex.port)
        acct_host = host.session
        check(acct_fpga != acct_host,
              f"two distinct OUCH accounts ({acct_fpga} vs {acct_host})")
        check(dev.load_pulsed == 1,
              "host's session did not hand the card a second connection")

        # 3. the host must refuse to write into the card's byte stream
        refused = False
        try:
            fpga.send_order(is_buy=True, shares=100, price=2896000)
        except RuntimeError:
            refused = True
        check(refused, "refuses to send orders on the card's session")

        # 4. identity is (account, token): the SAME token on two accounts is two
        #    different orders, which is what removes any need to coordinate
        #    token spaces between the card and the host.
        host2 = HostSession(regmap.Device(), role="host")
        host2.connect("127.0.0.1", ex.port)
        token = b"SAMETOKEN00001"
        body = ouch.enter_order(token, True, 100, "AAPL", 2896000, firm="HFT1")
        host.send_ouch_payload(body)
        host2.send_ouch_payload(body)
        host.poll(0.5); host2.poll(0.5)

        same_tok = [o for o in ex.received if o["token"] == token]
        check(len(same_tok) == 2,
              f"same token accepted on both accounts ({len(same_tok)})")
        check(len({o["account"] for o in same_tok}) == 2,
              "the two arrived on different accounts")

        fpga.logout(); host.logout(); host2.logout()
    finally:
        ex.stop()


if __name__ == "__main__":
    test_configuration()
    test_session_roundtrip()
    test_fpga_interop()
    test_two_independent_sessions()
    print(f"\n{'ALL PASS' if fails == 0 else str(fails) + ' FAILED'}")
    sys.exit(1 if fails else 0)
