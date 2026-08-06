"""Host session manager — the software half of the tick-to-trade path.

Responsibilities, all of which the FPGA deliberately does NOT do:
  * configure the device (all cfg_* registers) before the feed is enabled;
  * establish the TCP connection and log in over SoupBinTCP;
  * hand the established connection state to the FPGA (cfg_load) so the hardware
    can inject order segments on it at low latency;
  * process inbound Order Accepted / Executed / Rejected, maintaining the true
    position and pulsing cfg_order_ack to release the in-flight limiter;
  * send Client Heartbeats and answer Server Heartbeats.

WHAT IS AND IS NOT REAL HERE. The SoupBinTCP framing, login, heartbeat and the
OUCH decode are real and run over a real TCP socket against the mock exchange.
The register configuration is real host code writing a Device (a card would
change only the transport). What a card is genuinely needed for -- and what is
therefore modelled, not solved -- is that on hardware the FPGA and the host are
two senders on ONE TCP connection, so their sequence numbers must be
coordinated and inbound segments forwarded from the FPGA to the host. Here the
host owns the socket and can also send the FPGA's OUCH payloads itself, which
proves the protocol round-trip but not that split-sender coordination.
"""
import socket
import time

from . import soupbin, ouch, regmap


class HostSession:
    def __init__(self, dev: regmap.Device, stock: str = "AAPL",
                 firm: str = "HFT1", token_prefix: str = "FPGA01"):
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
        # the login succeeded, so hand the connection to the FPGA
        self.dev.pulse_load()
        return self.session

    def send_order(self, is_buy: bool, shares: int, price: int):
        """Assemble and send one OUCH Enter Order (what the FPGA does on the
        hot path; here in software so the round-trip can be exercised)."""
        token = (self.token_prefix[:6].ljust(6) + f"{self.token_seq:08X}").encode()
        body = ouch.enter_order(token, is_buy, shares, self.stock, price,
                                firm=self.firm)
        self.sock.sendall(soupbin.unsequenced(body))
        self.pending[token] = {"is_buy": is_buy, "shares": shares, "price": price}
        self.token_seq += 1
        self.inflight += 1
        return token

    def send_ouch_payload(self, body: bytes):
        """Inject an OUCH body the FPGA produced verbatim (interop proof)."""
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
