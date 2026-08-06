"""OUCH 4.2 message encode/decode.

The Enter Order layout here is the EXACT one the FPGA emits — it must match
step6-strategy/scripts/dump_ouch.py and rtl/ouch_builder.sv byte for byte, so
the host and mock exchange decode what the hardware actually sends. tests verify
that against the RTL's real output (ouch_rtl.log).

CAVEAT, the same one flagged in ouch_builder.sv: the single-character enum codes
(display, capacity, sweep eligibility, cross type, customer type) and the exact
Order Accepted / Executed layouts are the part most easily gotten wrong from
memory. They are modelled consistently between host and mock here, but must be
confirmed against the current NASDAQ OUCH 4.2 specification before this talks to
a real exchange.
"""
import struct

ENTER_ORDER    = b"O"   # client -> exchange
ORDER_ACCEPTED = b"A"   # exchange -> client
EXECUTED       = b"E"   # exchange -> client (fill)
CANCELED       = b"C"
REJECTED       = b"J"


def enter_order(token: bytes, is_buy: bool, shares: int, stock: str,
                price: int, tif: int = 0, firm: str = "HFT1",
                display: bytes = b"A", capacity: bytes = b"P",
                sweep: bytes = b"N", min_qty: int = 0,
                cross: bytes = b"N", cust: bytes = b"N") -> bytes:
    """49-byte OUCH Enter Order — the body ouch_builder assembles."""
    body = ENTER_ORDER
    body += token[:14].ljust(14, b" ")
    body += b"B" if is_buy else b"S"
    body += struct.pack(">I", shares)
    body += stock[:8].ljust(8).encode()
    body += struct.pack(">I", price)
    body += struct.pack(">I", tif)
    body += firm[:4].ljust(4).encode()
    body += display + capacity + sweep
    body += struct.pack(">I", min_qty)
    body += cross + cust
    assert len(body) == 49, len(body)
    return body


def parse_enter_order(body: bytes) -> dict:
    assert body[:1] == ENTER_ORDER
    return {
        "token":   body[1:15],
        "is_buy":  body[15:16] == b"B",
        "shares":  struct.unpack(">I", body[16:20])[0],
        "stock":   body[20:28].decode().strip(),
        "price":   struct.unpack(">I", body[28:32])[0],
        "tif":     struct.unpack(">I", body[32:36])[0],
        "firm":    body[36:40].decode().strip(),
        "display": body[40:41], "capacity": body[41:42], "sweep": body[42:43],
        "min_qty": struct.unpack(">I", body[43:47])[0],
        "cross":   body[47:48], "cust": body[48:49],
    }


# ---- exchange -> client. Layouts modelled for the mock; see the caveat above.
def order_accepted(token: bytes, is_buy: bool, shares: int, stock: str,
                   price: int, order_ref: int) -> bytes:
    return (ORDER_ACCEPTED + token[:14].ljust(14, b" ")
            + (b"B" if is_buy else b"S") + struct.pack(">I", shares)
            + stock[:8].ljust(8).encode() + struct.pack(">I", price)
            + struct.pack(">Q", order_ref))


def parse_order_accepted(body: bytes) -> dict:
    return {"token": body[1:15], "is_buy": body[15:16] == b"B",
            "shares": struct.unpack(">I", body[16:20])[0],
            "stock": body[20:28].decode().strip(),
            "price": struct.unpack(">I", body[28:32])[0],
            "order_ref": struct.unpack(">Q", body[32:40])[0]}


def executed(token: bytes, shares: int, price: int, match_ref: int) -> bytes:
    return (EXECUTED + token[:14].ljust(14, b" ")
            + struct.pack(">I", shares) + struct.pack(">I", price)
            + struct.pack(">Q", match_ref))


def parse_executed(body: bytes) -> dict:
    # matches executed(): 'E'(1) token(14) shares(4) price(4) match_ref(8)
    return {"token": body[1:15],
            "shares": struct.unpack(">I", body[15:19])[0],
            "price": struct.unpack(">I", body[19:23])[0],
            "match_ref": struct.unpack(">Q", body[23:31])[0]}


def rejected(token: bytes, reason: bytes = b"O") -> bytes:
    return REJECTED + token[:14].ljust(14, b" ") + reason


def msg_type(body: bytes) -> bytes:
    return body[:1]
