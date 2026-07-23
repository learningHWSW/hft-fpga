# Architecture

This document describes the end-to-end design of the ITCH feed handler: the
data path, each block's algorithm and interface, the measured facts that drove
the sizing decisions, and how correctness is verified. For per-step build/run
details see each step's README; for the roadmap and per-step DoD see
[PLAN.md](PLAN.md); for the raw measurement numbers see
[data/FINDINGS.md](data/FINDINGS.md).

## 1. Overview

The pipeline is a full **tick-to-trade** path: a 100 GbE stream of NASDAQ
MoldUDP64/ITCH in, an OUCH order frame out, wire to wire on the FPGA.

```
        CMAC RX                     core clock domain (~220 MHz)                          CMAC TX
QSFP28 ─► CMAC ─► cdc_fifo ─► eth/ip/udp ─► mold_splitter ─► itch_decoder ─► order_table ─► price_ladder ─► BBO
          100G   clock cross   (step 5)      (step 3b)         (step 2)       (step 4a)      (step 4b)      │
          322MHz                filter+strip realign to msgs   field extract  ref→{px,qty}  L2 aggregate    │
                                                                   │                                        ▼
                                              sweep_detect ◄────────┤  delta stream               strategy (imbalance
                                              (step 6, momentum)    │                              + sweep, risk gate)
                                                                    ▼                                       │
                             CMAC ◄─ cdc_fifo ◄─ tcp_tx ◄─ ouch_builder ◄──────────────────────────────────┘
                             TX     clock cross  TCP/IP/Eth  OUCH 4.2 / SoupBinTCP                       (step 6)
```

Everything from the UDP strip to the OUCH builder runs in one core clock domain,
joined to the CMAC's 322.265625 MHz by a dual-clock FIFO on each side (§9). The
core need only clear 195.3 MHz (512 b × 195.3 MHz = 100 Gb/s); it measures 220
MHz post-route on the U55C, so the crossing — not a faster core — is what makes
the design both correct and buildable.

Two principles shape every block:

- **Never backpressure the wire.** Market data cannot be paused. Each stage
  either sustains line rate or is fronted by an elastic FIFO sized from measured
  burst statistics; anything beyond that is dropped and counted, never stalled
  upstream into the MAC.
- **Measure, then size.** FIFO depth, hash function, table capacity and
  associativity, and the price-ladder band are all fixed from statistics of a
  real full trading day and re-confirmed by RTL replay, not chosen by intuition.

There are two clocks: the CMAC datapath at 322.265625 MHz (512-bit @ ~322 MHz =
~165 Gb/s raw, above 100G line rate) and the core clock. The core is the design
under timing pressure and runs slower; §9 covers why that is correct and how the
two are joined.

## 2. Protocol framing

NASDAQ wraps ITCH messages in **MoldUDP64** over UDP multicast:

```
MoldUDP64 packet: [ Session 10B | SeqNum 8B | MsgCount 2B ] then MsgCount × [ MsgLen 2B | ITCH message ]
```

- `MsgCount == 0` is a heartbeat. `MsgCount == 0xFFFF` is end-of-session.
- Sequence gaps (a `SeqNum` beyond expected) mean UDP loss; the hardware detects
  and counts them but does not recover — retransmission/rewind is a
  software/exception path, off the hot path.

ITCH 5.0 messages are **fixed-length, big-endian, fixed-offset** — the length is
fully determined by the type byte. That makes field extraction a set of pure
byte-lane selects (no shifts, no multiplies) — ideal for FPGA. The book is
driven by a small subset: `A`/`F` add, `E`/`C` execute, `X` cancel, `D` delete,
`U` replace. On the measured day these are 94% of traffic (A 43.6%, D 42.6%,
U 8.1%), so insert / delete / replace are the only hot paths that matter.

Every update/delete message carries only an 8-byte `order_ref`; the book must
resolve `order_ref → {symbol, side, price, qty}` in O(1). That single
requirement dictates the order-table design (§5).

## 3. Stage 2 — ITCH decoder

`itch_decoder` takes a `DATA_W`-bit AXI-Stream carrying one ITCH message per
`tlast` frame and emits a decoded superset struct (`itch_msg_t`) plus a 1-cycle
valid pulse. It is **store-then-decode**: bytes are collected into a small buffer
and all fields are extracted in parallel the cycle after `tlast`. Field
extractors are byte-lane selects into that buffer. `s_tready` is a constant 1 —
the module never stalls the wire.

The same module is used unchanged at both 64-bit (steps 2/3a/4) and 512-bit
(step 3b): every ITCH message (≤50 B) fits in one 512-bit beat, so at CMAC width
one message is one beat, and the decoder simply collects a single beat and
decodes. It also handles back-to-back single-beat messages correctly because
decode happens the cycle after each beat and reads only the fields within that
message's length.

## 4. Stage 3 — MoldUDP64 splitter and realignment

### 3a — behavioral stripper (64-bit)

`mold_stripper` is a store-and-forward reference: it buffers a whole UDP payload,
walks `MsgCount` messages using the per-message length prefixes, and re-frames
each ITCH message as its own AXI-Stream packet for the decoder. It tracks
sequence continuity (gap / duplicate / heartbeat / EOS) with counters and event
pulses, mirroring the software receiver model. It exists to validate the framing
and sequence logic in isolation; it is not line-rate.

### 3b — realigning splitter (512-bit) — the technical centerpiece

At CMAC width a 64-byte beat holds ~2–3 whole messages, and message boundaries
fall at arbitrary byte offsets — messages start and end mid-beat and straddle
beats. `mold_splitter` realigns this stream to one message per beat at
**1 msg/cycle**.

It keeps a **two-beat (128-byte) sliding window** as a flat vector. Each cycle,
concurrently:

- `consume` — remove the front bytes of a completed message (`2 + len`), the
  20-byte MoldUDP64 header, or 0 when the front is not yet complete;
- `accept` — append one input beat at the tail iff there is room after this
  cycle's consume (`s_tready` reflects that room).

Both happen the same cycle via barrel shifts (`win >> consume`, then OR-in the
beat at `vcnt - consume`). Doing fill and drain concurrently is what sustains
1 msg/cycle even when a beat packs three messages — which is exactly the rate the
input FIFO sizing assumes. A window invariant guarantees progress: an incomplete
front implies occupancy ≤ 52 B (< one beat), so there is always room to accept a
beat, and occupancy never exceeds 128 B.

Packet boundaries come from framing (header `MsgCount` + message lengths), not
from `tlast`, so the byte stream is self-delimiting and packets concatenate
naturally in the window.

**Input FIFO sizing (measured).** Modeling arrival as 100G wire serialization
and drain as 1 msg/cycle, the worst-case backlog over the whole trading day is
**76 messages / 2356 bytes**; backlog ≥ 2 occurs in only ~1% of arrivals. So a
256-entry (or 64-deep 512-bit beat) input FIFO absorbs every burst with margin.
This is the concrete payoff of the concurrent fill+drain design — a slower
either/or splitter would need a far larger FIFO.

## 5. Stage 4a — order table

The order table answers the O(1) reverse lookup `order_ref → {locate, side,
price, qty}` and emits, per message, the price level(s) the book must move: a
`rem` level (D/E/C/X and U's old side) and/or an `add` level (A/F and U's new
side). `U` is the only message touching two levels; everything else touches one.

It is **d-way set-associative** on `order_ref`, with the whole table
**symbol-filtered** so it fits URAM: only `A`/`F` whose stock-locate matches
`track_locate` are inserted; every later message that resolves to a stored order
is by construction a tracked-symbol order.

The interesting design work here is entirely measurement-driven:

- **Full-market tracking needs HBM.** Peak simultaneous live orders across all
  symbols is ~1.92 M. No set-associative configuration reaches zero overflow
  (8-way at 23% load still drops ~10 k/day), and 8 M entries × ~152 b ≈ 159 MB
  far exceeds the VU35P's ~11.5 MB of URAM. Full-market therefore lives in HBM.

- **A single filtered symbol needs a *mix* hash — the counterintuitive result.**
  `order_ref` is roughly monotonic, so its low bits round-robin across sets —
  *for all symbols combined*. But one symbol's refs are a correlated subset of
  that monotonic sequence and **cluster** in the low bits. Measured on AAPL
  (peak ~27 k live): raw low-bits at 2^16×4 overflows 24,142 times/day; a
  multiply-shift mix at the same size overflows only 132. The adopted design
  point is **2^16 sets × 8-way + multiply-shift mix**, which overflows **zero**
  times over the full day (~10 MB URAM). This is the exact opposite of the
  all-symbol conclusion, and only measurement surfaces it.

The current implementation is a correctness-first FSM (one cycle per set access:
2 cycles/message, 3 for `U`); the two-cycle spacing plus same-cycle NBA
writeback makes cross-message same-set accesses hazard-free without forwarding.
At 64-bit input a message spans several beats, so the decoder never presents
faster than this keeps up. An II=1 pipeline (read/modify/write with forwarding,
`U` served by a dual-ported memory) is the planned performance follow-up.

## 6. Stage 4b — price ladder / top-of-book

`price_ladder` consumes the order table's book-delta stream and keeps an **L2
book**: one aggregated quantity per price level per side. It emits the BBO (best
bid/ask price + quantity) whenever it changes.

- **Price → level index** is `(price - cfg_base) / TICK`. `TICK = 100` (a cent in
  1e-4 units) is a compile-time constant, so synthesis degrades the divide to a
  multiply-shift. `cfg_base` is a runtime input: software sets the band's start
  price per symbol — this is also the re-centering hook.
- **Best-of-book** is found by a priority scan over a per-side **occupancy
  bitmap** held in registers (best bid = highest occupied level, best ask =
  lowest), so the scan is combinational.
- **Bounded band.** Prices outside the `LEVELS`-wide band are dropped and counted
  (`oob_cnt`). This is by design — deep/stub quotes far from the inside market
  cannot become the BBO, so dropping them leaves the BBO exact. On a 5 M-message
  AAPL replay, 465 prices fall outside the band and the BBO sequence still
  matches the golden bit-for-bit. `oob_cnt` also quantifies how often the
  low-frequency re-centering path would fire.

L2 is the starting point (aggregate qty per level); per-level order counts and a
fixed-slot approximate L3 are future extensions.

## 7. Verification

Every stage has one software golden and a self-checking SV testbench that emit
the *same* canonical text; the Makefile passes only if they are byte-identical.
The golden format is defined in exactly one place and shared (e.g. step-3's
golden imports step-2's message formatter) so the stages cannot drift.

The full order-book chain (`decoder → order_table → price_ladder`) is verified
two ways at once: its RTL BBO log matches the step-4b golden, and that golden is
independently cross-checked byte-for-byte against the step-1 C parser's BBO —
on both the synthetic scenario (which exercises every message type, including
`U` side-inheritance and `C` resting-price semantics) and a real AAPL session.

The signal and order-entry stages extend the same method. The sweep detector's
fired sweeps match a Python golden through the real URAM order table; the
strategy's order stream — imbalance and sweep merged through one risk gate —
matches its golden all the way out through the OUCH builder and TCP engine, and
the emitted frames are re-derived a third time by scapy so a shared mistake in
the golden and the RTL cannot quietly agree with itself. Finally `t2t_top` runs
the whole chain wire-to-order-frame with two clocks, because a golden per block
does not catch two correct blocks wired together wrongly.
Real-data replays run under Verilator (up to 5 M messages) and under xsim.

Each testbench also asserts the invariants that must hold for the measured design
point: no dropped messages, `overflow_cnt == 0` (table sized for the symbol),
and the BBO diff (which would fail if an out-of-band price should have been the
inside market).

Two toolchain portability lessons are baked in: all modules carry a `timescale`
(xsim requires it globally once any TB has one), and continuous-assign
expressions never call a function that reads a module signal by side effect —
under xsim such a function has no sensitivity to that signal and its output
sticks at X (this cost real debugging time in step 3b; every TB now carries a
stall watchdog to catch such hangs immediately).

## 8. Stage 5 — front end, clock crossing, integration

**`eth_ip_udp_rx`** strips Ethernet/IPv4/UDP off a multicast market-data frame.
It is deliberately not a general stack: a receive-only feed needs three checks
(IPv4 with IHL=5, protocol UDP, the configured group/port) and a header strip.
Pinning the accepted layout to a fixed 42-byte header makes the payload
realignment a constant concatenation — the previous beat's top 22 bytes with
this beat's low 42 — so this stage needs no barrel shifter at all.

**Two clocks.** The CMAC datapath is fixed at 322.265625 MHz, but the core does
not need that: 512 bits at 322 MHz is 165 Gb/s for a 100 Gb/s wire, so the
throughput floor is 12.5 GB/s ÷ 64 B = **195.3 MHz**. The core runs at its own,
slower rate and is joined to the CMAC by **`cdc_fifo`**, a dual-clock FIFO, on
both the RX and TX sides. It is written the textbook way — pointers one bit wider
than the address so full/empty do not alias at the wrap, crossing as Gray code
through two `ASYNC_REG` flops, payload memory never synchronised because the
pointer handshake makes it safe — and the two domains are declared asynchronous
in the XDC. The write side never stalls; it drops and counts, like every other
market-data boundary.

**`t2t_top`** wires the whole chain together and is executed end to end in
simulation (real replay, two incommensurate clocks), because synthesis will
build a design whose correct blocks are connected wrongly without complaint.

## 9. Stage 6 — strategy, risk gate, order entry

**Two signals, one gate.** `strategy` fires on the rising edge of an order-book
imbalance (resting size heavily on one side, tight spread) and on a sweep pulse
from `sweep_detect`. `sweep_detect` taps the order table's delta stream and
counts an aggressive order walking one side of the book across price levels
(executions E/C, not cancels); it counts "levels walked" with a single frontier
register rather than a set of prices, which equals the distinct-price count for
a monotonic sweep (measured: zero disagreement). Both triggers pass one risk
gate — position limit, in-flight limit, kill switch — each rejection reason
counted so a quiet strategy is distinguishable from a blocked one. Position
moves optimistically (as if every order fills), which errs only toward
suppressing trades, never permitting more.

The signals are **measured before they are built** (`data/FINDINGS.md §5`): a
≥3-level sweep continues in its direction ~75 % of the time over the next
millisecond, and bigger sweeps continue harder — the monotonic relation the
momentum-ignition thesis predicts.

**`ouch_builder`** turns an order intent into OUCH 4.2 over SoupBinTCP: per the
session/hot-path split, login and sequence recovery are software's job, and the
hardware is a one-cycle constant concatenation of registered configuration with
three live fields. **`tcp_tx`** wraps that in TCP/IPv4/Ethernet, computing both
checksums as one's-complement adder trees (the payload sum registered in its own
cycle to meet timing). There is no retransmission — a dropped segment is a
dropped order and recovery is the host's — and flow control is satisfied by
construction because the in-flight limiter caps unacknowledged payload far below
any TCP window.

## 10. Results and what is not done

Full chain, `xcu55c-fsvh2892-2L-e`, post-route: core_clk **220.0 MHz** (above the
195.3 MHz floor), cmac_clk meets 322.265625 MHz, all timing constraints met;
44,908 LUT, 66 URAM, 2 DSP. The order table is the measured 2^13 × 16 point
instantiated as URAM. Closing timing meant working through a cluster of ~160 MHz
paths in the book engine; the decisive fix was splitting the price ladder's
read-modify-write (+65 MHz where earlier register stages bought single digits) —
the full, candid path with its missed predictions is in `step5-board/README.md`.

Not done, and stated plainly: no physical card, so no measured hardware latency;
host software (SoupBinTCP session, handshake, ack feedback, fills) is absent; the
transmit path does not retransmit; and the OUCH enum codes are placeholders to
confirm against the current NASDAQ specification.
