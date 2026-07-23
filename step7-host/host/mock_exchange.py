"""A mock NASDAQ OUCH/SoupBinTCP exchange, for testing the host without a real
venue.

It is the independent decoder the host is checked against: it accepts a
SoupBinTCP login, receives the OUCH Enter Orders the host (or the FPGA) sends,
and responds with Order Accepted and — for marketable IOC orders — Executed.
Because it shares no code path with the host's ENCODER (host.ouch.enter_order
builds bytes; the exchange PARSES them), a byte-for-byte round-trip proves the
encoding is correct, not merely self-consistent.

The matching engine is a STUB, and labelled as one: every order is accepted,
and filled in full at its limit price. A real venue matches against a real book;
that is not what this is for. What it verifies is the protocol and the host's
bookkeeping (in-flight release, position from fills), not execution quality.
"""
import socket
import struct
import threading

from . import soupbin, ouch


class MockExchange:
    def __init__(self, host="127.0.0.1", port=0, fill=True):
        self.fill = fill
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind((host, port))
        self.srv.listen(1)
        self.port = self.srv.getsockname()[1]
        self.order_ref = 0
        self.match_ref = 0
        self.received = []            # parsed Enter Orders, for assertions
        self._thread = None
        self._stop = False

    def start(self):
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()
        return self

    def stop(self):
        self._stop = True
        try:
            self.srv.close()
        except OSError:
            pass
        if self._thread:
            self._thread.join(timeout=2)

    def _serve(self):
        try:
            conn, _ = self.srv.accept()
        except OSError:
            return
        reader = soupbin.Reader()
        conn.settimeout(0.2)
        logged_in = False
        while not self._stop:
            try:
                data = conn.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                break
            if not data:
                break
            reader.feed(data)
            for ptype, payload in reader.packets():
                if ptype == soupbin.LOGIN_REQUEST:
                    conn.sendall(soupbin.login_accepted("SESS01", 1))
                    logged_in = True
                elif ptype == soupbin.LOGOUT_REQUEST:
                    conn.sendall(soupbin.pack(soupbin.END_OF_SESSION))
                    conn.close()
                    return
                elif ptype == soupbin.CLIENT_HEARTBEAT:
                    pass
                elif ptype == soupbin.UNSEQUENCED_DATA and logged_in:
                    self._on_order(conn, payload)

    def _on_order(self, conn, body):
        if ouch.msg_type(body) != ouch.ENTER_ORDER:
            return
        o = ouch.parse_enter_order(body)
        self.received.append(o)
        self.order_ref += 1
        conn.sendall(soupbin.sequenced(
            ouch.order_accepted(o["token"], o["is_buy"], o["shares"],
                                o["stock"], o["price"], self.order_ref)))
        if self.fill:
            self.match_ref += 1
            conn.sendall(soupbin.sequenced(
                ouch.executed(o["token"], o["shares"], o["price"], self.match_ref)))
