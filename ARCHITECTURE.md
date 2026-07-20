# Architecture

This document describes the end-to-end design of the ITCH feed handler: the
data path, each block's algorithm and interface, the measured facts that drove
the sizing decisions, and how correctness is verified. For per-step build/run
details see each step's README; for the roadmap and per-step DoD see
[PLAN.md](PLAN.md); for the raw measurement numbers see
[data/FINDINGS.md](data/FINDINGS.md).

## 1. Overview

The pipeline turns a 100 GbE stream of NASDAQ MoldUDP64/ITCH into a live L2
top-of-book:

```
QSFP28 ─► CMAC(100G) ─► eth/ip/udp ─► mold_splitter ─► itch_decoder ─► order_table ─► price_ladder ─► BBO
            512b @          (step 5,      (step 3b)        (step 2)      (step 4a)       (step 4b)      + book
          322.265625 MHz    planned)   realign to msgs   field extract  ref→{px,qty}   L2 aggregate    deltas
```

Two principles shape every block:

- **Never backpressure the wire.** Market data cannot be paused. Each stage
  either sustains line rate or is fronted by an elastic FIFO sized from measured
  burst statistics; anything beyond that is dropped and counted, never stalled
  upstream into the MAC.
- **Measure, then size.** FIFO depth, hash function, table capacity and
  associativity, and the price-ladder band are all fixed from statistics of a
  real full trading day and re-confirmed by RTL replay, not chosen by intuition.

Clock is the 100G CMAC datapath clock, 322.265625 MHz (512-bit @ ~322 MHz =
~165 Gb/s raw, comfortably above 100G line rate).

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

## 8. Status and next steps

Steps 1–4b are complete: the parse → order-book core runs at design intent on
both xsim and Verilator and matches the software model on a real trading day.

Remaining work:

- **Performance.** Stages 4a and 4b are correctness-first FSMs (2–3 cycles per
  record). The II=1 pipelines (order table with same-set forwarding and
  dual-ported `U`; ladder with a pipelined best-scan and BRAM-backed quantities)
  are the next commits — to be compared before/after on the same replay.
- **Step 5 — board bring-up.** CMAC 100G RX with a UDP/IP front end feeding the
  existing splitter, QDMA for host reporting/config (shadow/commit registers),
  and measured MAC-to-BBO latency.
- **Step 6 (stretch) — OUCH order entry.** SoupBinTCP session managed in
  software; the FPGA assembles and fires from pre-staged sequence/ack state on a
  BBO trigger.
