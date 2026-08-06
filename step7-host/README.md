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
coordination.

The OUCH enum codes are no longer placeholders — every offset and value is now
checked against O*U*C*H 4.2 (updated October 2025); see
[step6-strategy](../step6-strategy/) for what that found.

### The protocol says not to solve split-sender at all

Reading the spec for the enum check turned up the answer to the harder problem
above. Two sentences decide it:

> Each physical OUCH host port is bound to a NASDAQ-assigned logical OUCH
> Account. On a given day, every order entered on OUCH is uniquely identified by
> the combination of the logical OUCH Account and the participant-created Token
> field.

Order identity is scoped **per account**, and an account is bound to a *physical
port*. So giving the FPGA its own port and account makes the coordination problem
disappear rather than be managed: two sockets, two sequence spaces, and tokens
that only have to be unique within their own account. Nothing has to be forwarded
between the FPGA and the host, and neither has to know the other's sequence
numbers.

What remains is commercial rather than technical — accounts are "NASDAQ-assigned",
so a second port has to be provisioned. That is worth confirming before any
engineering effort goes into coordinating two senders on one connection, because
if the second port is available then that engineering is wasted.

### Retransmission is idempotent by construction

The same reading settles the shape of a retransmit buffer, which the transmit
path does not yet have. The spec is explicit that client-to-host messages are
non-guaranteed and designed for benign resend:

> Therefore, all host-bound messages are designed so that they can be benignly
> resent for robust recovery from connection and application failures.

and, for Enter Order specifically:

> If you send an Enter Order Message with a previously used Order Token, the new
> order will be ignored.

So resending an order carrying its original token cannot double-fill: the venue
discards the duplicate. A replay buffer therefore needs no dedup protocol, no
negotiation and no state machine beyond "keep the last N frames and re-send on
request" — and N is already bounded by the risk gate's `cfg_max_inflight`. This
makes the feature considerably smaller than it looks, provided the token is
preserved on resend rather than regenerated, which is the one thing that would
break it.
