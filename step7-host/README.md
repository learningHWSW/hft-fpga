# Step 7 — host software (the session / control plane)

The FPGA does the hot path: parse → book → decide → assemble the order frame,
wire to wire. It deliberately does **not** do the session — login, sequence
recovery, heartbeats, acknowledgement feedback, fills — because none of that is
latency-critical and all of it is stateful (PLAN §6). That is this directory:
the software half that makes the hardware usable.

Pure Python, no Vivado, no card. The host is the control plane, not the fast
path, so Python is the right tool and the tests run anywhere.

## What it does

| Piece | Role |
|---|---|
| `host/soupbin.py` | SoupBinTCP 3.00 framing — login, sequenced/unsequenced data, heartbeats |
| `host/ouch.py` | OUCH 4.2 encode/decode — the **exact** Enter Order layout the FPGA emits |
| `host/regmap.py` | every `cfg_*` register of `t2t_top`, and how the host builds its value |
| `host/session.py` | connect, log in, configure the device, process acks/fills, drive `cfg_order_ack` |
| `host/mock_exchange.py` | a stub NASDAQ venue to test against over loopback TCP |

The flow the host runs:

1. **Configure the device.** Write all `cfg_*` registers (feed group/port,
   tracked symbol, band base, strategy and sweep parameters, the OUCH template,
   and the TCP connection state). On a card these are AXI-Lite writes over
   QDMA; off a card `regmap.Device` writes a dict and can serialise the whole
   map, so the host code is identical either way — only the transport changes.
2. **Establish the connection and log in** over SoupBinTCP, then pulse
   `cfg_load` to hand the established connection to the FPGA.
3. **Process inbound** Order Accepted / Executed / Rejected: release the
   in-flight limiter (`cfg_order_ack`) on each ack, and update the **true**
   position from fills — the FPGA's position is optimistic (every order assumed
   filled), and this is where reality corrects it.
4. **Heartbeats** both directions keep the session alive.

## Verification

`make test` proves three things over a real loopback socket:

```
PASS: register image is 110 bytes
PASS: cfg_stock decodes to 'AAPL    '
PASS: cfg_load pulsed once after login
PASS: 2 orders accepted / 2 fills / in-flight released to 0 / position 0
PASS: exchange decoded all 67 FPGA orders
PASS: exchange decode of FPGA order matches its OUCH bytes
```

The last two are the ones that matter most. The mock exchange **parses** OUCH;
the host and FPGA **encode** it. So feeding the exchange the bytes the RTL
actually emitted (`step6-strategy/ouch_rtl.log`, captured by `make
fpga-fixture`) and having it decode all 67 orders proves the hardware's OUCH
encoding is wire-valid against an independent implementation — the same
"cross-check with something that shares no code" method as the RTL goldens and
the scapy frame check. The test SKIPs this gracefully if the fixture is absent.

## What is real, and what a card is still needed for

**Real and tested:** SoupBinTCP framing/login/heartbeat, OUCH decode, the
register configuration, and the host's ack/fill bookkeeping — all over a real
TCP socket against an independent decoder.

**A stub, and labelled one:** the mock exchange's matching engine accepts every
order and fills it at its limit price. It tests the protocol and the host's
bookkeeping, not execution quality.

**Genuinely needs a card, so modelled rather than solved:** on hardware the FPGA
and the host are two senders on **one** TCP connection, so their sequence
numbers must be coordinated and inbound segments forwarded from the FPGA to the
host. Here the host owns the socket and can also send the FPGA's OUCH payloads
itself, which proves the protocol round-trip but not that split-sender
coordination. And the OUCH enum codes (display, capacity, cross, customer type)
remain placeholders to confirm against the current NASDAQ specification before
this talks to a real venue.
