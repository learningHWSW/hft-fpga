"""SoupBinTCP 3.00 framing — the session layer OUCH runs over.

This is the control plane the FPGA does NOT do (per PLAN §6): login, sequence
recovery and heartbeats are software's job, and the hardware only assembles and
fires the order payload once a session exists. This module is the shared
protocol used by both the host session manager and the mock exchange, so the
two cannot drift — the same trick as the RTL goldens.

Packet framing: a 2-byte big-endian length (counting the type byte + payload)
then a 1-byte type then the payload.

  client -> server        server -> client
  'L' Login Request       'A' Login Accepted
  'U' Unsequenced Data    'J' Login Rejected
  'O' Logout Request      'S' Sequenced Data
  'R' Client Heartbeat    'H' Server Heartbeat
                          'Z' End of Session

The FPGA's transmit path emits SoupBinTCP 'U' (Unsequenced Data) packets — that
is what ouch_builder wraps — so the order flow is client 'U' up, server 'S'
down (Order Accepted / Executed / etc.).
"""
import struct

# client -> server
LOGIN_REQUEST     = b"L"
UNSEQUENCED_DATA  = b"U"
LOGOUT_REQUEST    = b"O"
CLIENT_HEARTBEAT  = b"R"
# server -> client
LOGIN_ACCEPTED    = b"A"
LOGIN_REJECTED    = b"J"
SEQUENCED_DATA    = b"S"
SERVER_HEARTBEAT  = b"H"
END_OF_SESSION    = b"Z"


def pack(ptype: bytes, payload: bytes = b"") -> bytes:
    """One SoupBinTCP packet: length (type+payload) then type then payload."""
    body = ptype + payload
    return struct.pack(">H", len(body)) + body


def login_request(username: str, password: str, session: str = "",
                  seq: int = 1) -> bytes:
    # Username 6, Password 10, Requested Session 10, Requested Seq 20 (ASCII)
    p = (username[:6].ljust(6).encode()
         + password[:10].ljust(10).encode()
         + session[:10].rjust(10).encode()
         + str(seq).rjust(20).encode())
    return pack(LOGIN_REQUEST, p)


def login_accepted(session: str, seq: int) -> bytes:
    p = session[:10].ljust(10).encode() + str(seq).rjust(20).encode()
    return pack(LOGIN_ACCEPTED, p)


def parse_login_accepted(payload: bytes):
    return payload[:10].decode().strip(), int(payload[10:30].decode())


def unsequenced(payload: bytes) -> bytes:
    return pack(UNSEQUENCED_DATA, payload)


def sequenced(payload: bytes) -> bytes:
    return pack(SEQUENCED_DATA, payload)


class Reader:
    """Incremental SoupBinTCP de-framer over a byte stream (a socket)."""

    def __init__(self):
        self.buf = bytearray()

    def feed(self, data: bytes):
        self.buf += data

    def packets(self):
        """Yield (type_byte, payload) for every complete packet buffered."""
        while len(self.buf) >= 2:
            (blen,) = struct.unpack_from(">H", self.buf, 0)
            if len(self.buf) < 2 + blen:
                return
            body = bytes(self.buf[2:2 + blen])
            del self.buf[:2 + blen]
            yield body[:1], body[1:]
