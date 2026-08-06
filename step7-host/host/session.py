"""Host session manager — the software half of the tick-to-trade path.

Responsibilities, all of which the FPGA deliberately does NOT do:
  * configure the device (all cfg_* registers) before the feed is enabled;
  * establish the TCP connection and log in over SoupBinTCP;
  * hand the established connection state to the FPGA (cfg_load) so the hardware
    can inject order segments on it at low latency;
  * process inbound Order Accepted / Executed / Rejected, maintaining the true
    position and pulsing cfg_order_ack to release the in-flight limiter;
  * send Client Heartbeats and answer Server Heartbeats.

TWO SESSIONS, NOT ONE SHARED CONNECTION. This used to model the FPGA and the
host as two senders on ONE TCP connection, which needs their sequence numbers
coordinated and inbound segments forwarded -- hard, and a rich source of silent
stream corruption. The spec removes the need:

    "Each physical OUCH host port is bound to a NASDAQ-assigned logical OUCH
     Account. On a given day, every order entered on OUCH is uniquely identified
     by the combination of the logical OUCH Account and the participant-created
     Token field."

Order identity is scoped per account and an account binds to a port, so the card
gets its own port and account and is the only sender on that byte stream, and the
host gets its own. Nothing is forwarded and neither side needs the other's
sequence numbers. Token spaces need no coordination either: the same token on two
accounts is two different orders.

`role` selects which of the two a HostSession is. role="fpga" is established and
logged in by the host and then handed over with cfg_load; it REFUSES to send
orders, because writing into the stream the card is sending on is precisely the
problem the second account exists to delete. role="host" is the host's own
account and never touches the card.

The remaining requirement is commercial rather than technical: a second port has
to be provisioned, since accounts are NASDAQ-assigned.

WHAT IS AND IS NOT REAL HERE. The SoupBinTCP framing, login, heartbeat and the
OUCH decode are real and run over real TCP sockets against the mock exchange,
which now serves one account per connection. The register configuration is real
host code writing a Device (a card would change only the transport). What still
needs a card is the inbound path on the card's own connection: acks and fills for
its orders arrive at the card's MAC, and the FPGA does not parse TCP, so getting
them to the host is unsolved here.
"""
import socket
import time

from . import soupbin, ouch, regmap


class HostSession:
    def __init__(self, dev: regmap.Device, stock: str = "AAPL",
                 firm: str = "HFT1", token_prefix: str = "FPGA01",
                 role: str = "fpga"):
        # role="fpga": this session's orders are sent BY THE CARD. The host
        #   establishes it, logs in, and hands the connection over with
        #   cfg_load; it must not then write orders into the same byte stream.
        # role="host": the host's own session on its own OUCH account, for
        #   manual or supervisory orders. It never touches the card.
        if role not in ("fpga", "host"):
            raise ValueError("role must be 'fpga' or 'host'")
        self.role = role
        self.dev = dev
        self.stock = stock
        self.firm = firm
        self.token_prefix = token_prefix
        self.sock = None
        self.reader = soupbin.Reader()
        self.session = ""
        self.next_seq = 1
        # order bookkeeping
        self.token_seq = 0
        self.inflight = 0
        self.position = 0
        self.pending = {}          # token -> intent dict
        self.accepted = 0
        self.filled = 0
        self.rejected = 0
        self.log = []

    # ---- configuration -------------------------------------------------
    def configure(self, *, group_ip, udp_port, track_locate, band_base,
                  max_spread, ratio_shift, min_qty, order_qty, pos_limit,
                  max_inflight, sweep_en, sweep_min_levels, sweep_gap,
                  dst_mac, src_mac, src_ip, dst_ip, src_port, dst_port,
                  init_seq, ack_num, window, init_id,
                  igmp_en=True, igmp_interval=3_000_000, group_ip_b=None):
        d = self.dev
        d.write("cfg_group_ip", regmap.ip2int(group_ip))
        d.write("cfg_udp_port", udp_port)
        d.write("cfg_track_locate", track_locate)
        d.write("cfg_band_base", band_base)
        d.write("cfg_max_spread", max_spread)
        d.write("cfg_ratio_shift", ratio_shift)
        d.write("cfg_min_qty", min_qty)
        d.write("cfg_order_qty", order_qty)
        d.write("cfg_pos_limit", pos_limit)
        d.write("cfg_max_inflight", max_inflight)
        d.write("cfg_sweep_en", 1 if sweep_en else 0)
        d.write("cfg_sweep_min_levels", sweep_min_levels)
        d.write("cfg_sweep_gap", sweep_gap)
        d.write("cfg_token_prefix", regmap.ascii_le(self.token_prefix, 6))
        d.write("cfg_stock", regmap.ascii_le(self.stock, 8))
        d.write("cfg_firm", regmap.ascii_le(self.firm, 4))
        d.write("cfg_tif", 0)
        d.write("cfg_ouch_min_qty", 0)
        for name, ch in [("cfg_display", "A"), ("cfg_capacity", "P"),
                         ("cfg_sweep", "N"), ("cfg_cross", "N"), ("cfg_cust", "N")]:
            d.write(name, ord(ch))
        d.write("cfg_dst_mac", regmap.mac2int(dst_mac))
        d.write("cfg_src_mac", regmap.mac2int(src_mac))
        d.write("cfg_src_ip", regmap.ip2int(src_ip))
        d.write("cfg_dst_ip", regmap.ip2int(dst_ip))
        d.write("cfg_src_port", src_port)
        d.write("cfg_dst_port", dst_port)
        d.write("cfg_init_seq", init_seq)
        d.write("cfg_ack_num", ack_num)
        d.write("cfg_window", window)
        d.write("cfg_init_id", init_id)
        d.write("cfg_igmp_en", 1 if igmp_en else 0)
        d.write("cfg_igmp_interval", igmp_interval)
        # B-line multicast group for A/B gap recovery; default to A (single feed)
        d.write("cfg_group_ip_b", regmap.ip2int(group_ip_b) if group_ip_b else regmap.ip2int(group_ip))

    # ---- session -------------------------------------------------------
    def connect(self, host, port, username="TRADER", password="pw", timeout=5):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.sendall(soupbin.login_request(username, password, "", self.next_seq))
        ptype, payload = self._recv_one()
        if ptype != soupbin.LOGIN_ACCEPTED:
            raise RuntimeError(f"login rejected: {ptype!r}")
        self.session, self.next_seq = soupbin.parse_login_accepted(payload)
        # Only the card's session is handed over. The host's own session is a
        # separate TCP connection on a separate OUCH account, and pulsing load
        # for it would point the card at the wrong stream.
        if self.role == "fpga" and self.dev is not None:
            self.dev.pulse_load()
        return self.session

    def send_order(self, is_buy: bool, shares: int, price: int):
        """Assemble and send one OUCH Enter Order on THIS session.

        Refused on the card's session. With two independent sessions there is
        no reason for the host to write into the stream the card is sending on,
        and every reason not to: two senders on one TCP connection is exactly
        the coordination problem the second account exists to delete. The card
        sends its own orders; this is for the host's own account.
        """
        if self.role == "fpga":
            raise RuntimeError(
                "refusing to send on the card's session -- the card owns this "
                "byte stream. Use a role='host' session on its own account.")
        token = (self.token_prefix[:6].ljust(6) + f"{self.token_seq:08X}").encode()
        body = ouch.enter_order(token, is_buy, shares, self.stock, price,
                                firm=self.firm)
        self.sock.sendall(soupbin.unsequenced(body))
        self.pending[token] = {"is_buy": is_buy, "shares": shares, "price": price}
        self.token_seq += 1
        self.inflight += 1
        return token

    def send_ouch_payload(self, body: bytes):
        """Inject an OUCH body the card produced verbatim.

        This is an INTEROP PROOF, not the deployed path: it shows the host and
        the card agree byte for byte on the OUCH encoding. On hardware the card
        sends these itself, on its own session. Allowed only on a role='host'
        session so it can never be mistaken for the real arrangement.
        """
        if self.role == "fpga":
            raise RuntimeError(
                "refusing to inject on the card's session -- see send_order")
        info = ouch.parse_enter_order(body)
        self.sock.sendall(soupbin.unsequenced(body))
        self.pending[info["token"]] = info
        self.inflight += 1
        return info["token"]

    def poll(self, budget=0.5):
        """Drain inbound packets for up to `budget` seconds."""
        end = time.time() + budget
        self.sock.settimeout(0.05)
        while time.time() < end:
            try:
                data = self.sock.recv(65536)
            except socket.timeout:
                continue
            if not data:
                break
            self.reader.feed(data)
            for ptype, payload in self.reader.packets():
                self._handle(ptype, payload)

    def _handle(self, ptype, payload):
        if ptype == soupbin.SERVER_HEARTBEAT:
            self.sock.sendall(soupbin.pack(soupbin.CLIENT_HEARTBEAT))
            return
        if ptype != soupbin.SEQUENCED_DATA:
            return
        mt = ouch.msg_type(payload)
        if mt == ouch.ORDER_ACCEPTED:
            info = ouch.parse_order_accepted(payload)
            self.accepted += 1
            self.inflight = max(0, self.inflight - 1)
            self.dev.pulse_order_ack()          # release one in-flight slot
            self.log.append(("accepted", info["token"]))
        elif mt == ouch.EXECUTED:
            info = ouch.parse_executed(payload)
            p = self.pending.get(info["token"])
            signed = info["shares"] if (p and p["is_buy"]) else -info["shares"]
            self.position += signed             # the TRUE position, from fills
            self.filled += 1
            self.log.append(("executed", info["token"], signed))
        elif mt == ouch.REJECTED:
            self.rejected += 1
            self.inflight = max(0, self.inflight - 1)
            self.dev.pulse_order_ack()
            self.log.append(("rejected", payload[1:15]))

    def logout(self):
        try:
            self.sock.sendall(soupbin.pack(soupbin.LOGOUT_REQUEST))
        finally:
            self.sock.close()

    def _recv_one(self):
        self.sock.settimeout(5)
        while True:
            for ptype, payload in self.reader.packets():
                return ptype, payload
            data = self.sock.recv(65536)
            if not data:
                raise RuntimeError("connection closed during login")
            self.reader.feed(data)
