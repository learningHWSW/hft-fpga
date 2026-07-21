#!/usr/bin/env python3
"""Golden for the OUCH builder: order intents -> wire bytes.

Reads the order log dump_orders.py produces and emits one hex line per packet,
which is what tb_strategy.sv writes from the RTL so the two can be diffed.

WIRE FORMAT — SoupBinTCP framing around an OUCH 4.2 Enter Order:

  SoupBinTCP
    0..1   Packet Length      2  big-endian, counts the type byte + payload
    2      Packet Type        1  'U' = Unsequenced Data (client -> server)
  OUCH 4.2 Enter Order
    3      Message Type       1  'O'
    4..17  Order Token       14  alphanumeric, must be unique per order
    18     Buy/Sell           1  'B' / 'S'
    19..22 Shares             4  big-endian
    23..30 Stock              8  ASCII, space padded
    31..34 Price              4  big-endian, 1e-4 units
    35..38 Time in Force      4  big-endian (0 = IOC)
    39..42 Firm               4  ASCII
    43     Display            1
    44     Capacity           1
    45     Intermarket Sweep  1
    46..49 Minimum Quantity   4  big-endian
    50     Cross Type         1
    51     Customer Type      1

  52 bytes total: 3 of SoupBinTCP + 49 of OUCH.

CAVEAT WORTH READING BEFORE THIS TOUCHES AN EXCHANGE: the field offsets and
widths above are from the OUCH 4.2 layout, but the single-character ENUM values
(display, capacity, sweep eligibility, cross type, customer type) are the part
most easily gotten wrong from memory, and a wrong capacity code is a
compliance problem rather than a bug. They are all host-configurable for
exactly that reason, and the defaults here are placeholders to be confirmed
against the current NASDAQ specification.

Price passes through unscaled: ITCH and OUCH both use 1e-4 units, so the
book's price is already the order's price.

The order token is a 6-character prefix plus the order counter in 8 hex
digits. Hex, not decimal, because converting binary to decimal in RTL costs a
divider and buys nothing — the token only has to be unique, not readable.

Usage: ./dump_ouch.py <orders.log> [stock] [firm] [token_prefix]
"""
import sys

STOCK        = "AAPL"
FIRM         = "HFT1"
TOKEN_PREFIX = "FPGA01"
TIF          = 0          # IOC
DISPLAY      = "Y"
CAPACITY     = "P"
SWEEP        = "N"
MIN_QTY      = 0
CROSS_TYPE   = "N"
CUST_TYPE    = "N"


def build(seq, is_buy, qty, price, stock, firm, prefix):
    token = (prefix[:6].ljust(6) + f"{seq:08X}").encode()
    body = b"O" + token
    body += b"B" if is_buy else b"S"
    body += qty.to_bytes(4, "big")
    body += stock[:8].ljust(8).encode()
    body += price.to_bytes(4, "big")
    body += TIF.to_bytes(4, "big")
    body += firm[:4].ljust(4).encode()
    body += DISPLAY.encode() + CAPACITY.encode() + SWEEP.encode()
    body += MIN_QTY.to_bytes(4, "big")
    body += CROSS_TYPE.encode() + CUST_TYPE.encode()
    assert len(body) == 49, len(body)
    return (len(body) + 1).to_bytes(2, "big") + b"U" + body


def main(path, stock, firm, prefix):
    seq = 0
    for line in open(path):
        # <ts> <BUY|SELL> qty=<qty> px=<price>
        f = line.split()
        if len(f) != 4:
            continue
        is_buy = f[1] == "BUY"
        qty = int(f[2][4:])
        price = int(f[3][3:])
        print(build(seq, is_buy, qty, price, stock, firm, prefix).hex())
        seq += 1
    print(f"# packets={seq}", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    a = sys.argv[2:]
    main(sys.argv[1],
         a[0] if len(a) > 0 else STOCK,
         a[1] if len(a) > 1 else FIRM,
         a[2] if len(a) > 2 else TOKEN_PREFIX)
