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

**RX — market data in.** Two feed lines, filtered and stripped independently, then
re-joined into one message stream. `feed_ab_arb` recovers a sequence gap on one
line from the other; the two `drop_fifo`s absorb bursts and count what they cannot.

```
                           ┌─► eth_ip_udp_rx A ─► drop_fifo ─┐
QSFP28 ─► CMAC ─► cdc_fifo ─┤   MAC/IP/UDP filter            ├─► feed_ab_arb ─► mold_splitter
  RX      100G    322→215   │   + header strip               │   A/B redundant   realign to
         322 MHz   MHz      └─► eth_ip_udp_rx B ─► drop_fifo ─┘   gap recovery    message
                            │                                                     boundaries
                            ├─► igmp_query_detect  arms a report on TX                 │
                            └─► tcp_rx             the order session's                 ▼
                                inbound half, to the harness's capture
                                                                                 itch_decoder
                                                                                 field extract
                                                                                       │
                                                            ┌──────────────────────────┤ book
                                                            ▼                          ▼ delta
                                                      sweep_detect               order_table
                                                      momentum; bypasses         ref→{px,qty}
                                                      the ladder entirely              │
                                                                                       ▼
                                                                                 price_ladder
                                                                                  L2 → BBO
                                                                                       │
                                                                    fast_bbo ─────► bbo_merge ─► BBO
                                                                    1 cycle for      the ladder's own
                                                                    most deltas      records, sooner
```

**TX — order out.** The assembled frame crosses back to the CMAC clock, then two
chained arbiters merge it with control traffic. Orders sit on the priority port of
the outer arbiter, so an IGMP report or an ARP reply can never delay a trade.

```
     sweep ─┐
            ├─► strategy ─► ouch_builder ─► tcp_tx ─► cdc_fifo ─┐
     BBO ───┘   imbalance +  OUCH 4.2 /     TCP/IPv4   215→322  │
                risk gate    SoupBinTCP      /Eth       MHz     │
                                                                ▼
    QSFP28 ◄─ CMAC ◄─ u_tx_arb ◄───────────────────────────────┘ s0, priority
       ▲       TX        ▲
       │                 └─ u_ctrl_arb ◄─ igmp_join       s1, yields to orders
       │                                ◄─ arp_responder
       │
       └─ Phase B puts the GT in near-end PMA loopback, so everything transmitted
          returns on RX; the measured interval therefore spans MAC, PCS and SerDes
```

Everything from the UDP strip to the OUCH builder runs in one core clock domain,
joined to the CMAC's 322.265625 MHz by a dual-clock FIFO on each side (§9). The
core need only clear 195.3 MHz (512 b × 195.3 MHz = 100 Gb/s); it measures 220
MHz post-route out of context and runs at 215 MHz inside the Vitis kernel, so the
crossing — not a faster core — is what makes the design both correct and
buildable.

The whole path has since been **executed on a real Alveo U55C**, first replaying
from HBM and then through a real `cmac_usplus` with the GT in near-end loopback,
so MAC, PCS and SerDes are inside the measurement (§10).

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
  multiply-shift mix at the same size overflows only 132. This is the exact
  opposite of the all-symbol conclusion, and only measurement surfaces it.

- **Two later measurements moved the design point off that first answer**, and
  both are worth following because the first answer was reasonable:

  *The mixer does not need a multiply.* Once the memory problem was fixed the
  64×64 multiply-shift became the critical path — a multi-DSP cascade, 4.6 ns. A
  pure XOR fold (`r ^ r>>16 ^ r>>32 ^ r>>48`) was measured over the same full day
  and matches it at **zero overflow** with a *lower* worst-set occupancy (6 vs 7),
  for no DSPs and about two LUT levels (`FINDINGS §4.3`).

  *The geometry is set by URAM cascade depth, not capacity.* At 2^16 deep each
  way is 16 URAM primitives chained, so every access walks a 16-long cascade and
  256 URAM must be placed; three separate critical paths in a row were logic
  reaching those cascaded pins. At **2^13 × 16** the chain is 2 long and the whole
  table is 64 URAM.

  **The deployed design point is therefore `2^13 sets × 16 ways` with an XOR-fold
  hash**, zero overflow over the full trading day.

The deployed implementation is a correctness-first FSM (one cycle per set access:
2 cycles/message, 3 for `U`); the two-cycle spacing plus same-cycle NBA writeback
makes cross-message same-set accesses hazard-free without forwarding. An II=1
pipeline (`order_table_pipe`, read/modify/write with forwarding, `U` served by a
dual-ported memory) exists as a verified drop-in with identical ports and
byte-identical output, selected with `+define+OT_PIPE`. Unloaded latency is the
same either way — 5 cycles — so II=1 buys throughput, not latency.

Two implementation details matter more than they look:

- **The entry select is a one-hot OR, not a priority encoder followed by a mux.**
  The way comparators already produce a one-hot vector (`order_ref` is unique,
  which is the premise of keying on it); collapsing it to a binary index and using
  that to drive a 16:1 mux over 130-bit entries re-derives what the compare
  already knew, and measured as the design's critical path — 10 logic levels,
  +0.011 ns. Selecting straight off the one-hot took the core from +0.011 ns to
  **+0.099 ns** at the same 215 MHz, for no latency.
- **URAM cannot be initialised**, so the table sweeps itself clear on reset and
  holds `init_done` low until it finishes. `initial mem = 0` works in simulation
  and in BRAM and is a lie on the device.

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

- **The quantity arrays sweep clear on reset**, like the order table's. They infer
  BRAM, and `initial` sets BRAM contents when the *bitstream* loads, not when
  `rst_n` asserts. Since the update path is read-modify-write, a soft reset that
  cleared the occupancy flops but left stale quantities behind made adds
  accumulate onto stale values and removals leave nonzero remainders, so levels
  never released: the book filled with phantom levels, best bid and ask crossed,
  the spread never read tight and the strategy stopped firing silently. Simulation
  cannot see this — `initial` runs at time 0 there — and it was found only on
  silicon.

**A fast top-of-book path runs beside the ladder.** `fast_bbo` keeps only best
bid/ask and applies each delta to them directly. Exactly one delta shape needs the
ladder's scan — a removal that empties the best level, because the next best is
whatever the occupancy bitmap says; everything else is a comparison and an add or
subtract. Measured on the real AAPL replay, **91 % of book updates are answerable
in one cycle instead of ten**, with zero cases of claiming certainty and being
wrong across 1,174 cross-checks against the ladder. It never approximates: it
either knows or defers.

`bbo_merge` is the rejoin, and two decisions make it safe. It is driven from the
ladder's **accept** handshake, which fixes the arrival order — `lad(k-1)`, then
`fast(k)`, then `lad(k)` on the next accept — so a fast record cannot overtake a
deferred one and no reorder buffer is needed. And it merges **on value against the
last record it emitted**, which is `price_ladder`'s own change test against its
`o_*` registers: two change-detectors sharing a definition and a baseline agree by
construction, so the duplicate ladder record for an already-answered delta arrives
equal and is dropped, and no change can be lost because dropping only happens on
equality. On the real replay the merged stream is the same 1,779 records, 1,174 of
them delivered ten cycles early, `mismatch_cnt = 0`.

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
three live fields. Every offset and enum is verified against the published
specification (Version 4.2, updated October 2025) rather than written from memory
— which caught `Display = "Y"`, a legal code meaning *Anonymous-Price to Comply*
rather than "yes, display"; it is now `"A"`, *Attributable-Price to Display*. A
golden that agrees with itself can never catch that class of error.

**`tcp_tx`** wraps the packet in TCP/IPv4/Ethernet, computing both checksums as
one's-complement adder trees (the payload sum registered in its own cycle to meet
timing). The hot path is fire-and-forget, and flow control is satisfied by
construction because the in-flight limiter caps unacknowledged payload far below
any TCP window.

**Retransmission is available but not wired in.** The specification makes it far
smaller than it looks: client-to-host messages are designed to be "benignly
resent", and an Enter Order carrying a previously used token is *ignored*, so a
resend cannot double-fill and needs no dedup protocol. `tx_replay_buf` keeps the
last N transmitted frames — N already bounded by the in-flight limiter — and
stores the **assembled bytes**, not the order intent: re-deriving a frame would
mint a new token and a new TCP sequence number, which is a different order and a
hole in the stream. It adds no latency, since the live frame passes through while
the ring is written in parallel and a replay only goes out when the path is idle.

**The card gets its own OUCH session, rather than sharing the host's connection.**
Two senders on one TCP connection must coordinate sequence numbers and forward
inbound segments — genuinely hard, and unnecessary: OUCH scopes order identity to
*(account, token)* and binds each account to a physical port, so a second port
deletes the problem instead of managing it (`step7-host`). The inbound direction
on that connection is now handled too: `tcp_rx` filters the venue's segments out
of the RX stream by 4-tuple, maintains `rcv_nxt` as the acknowledgement number
`tcp_tx` sends, and passes the frames whole to the step-8 harness, which merges
them into the same capture area the orders use. The host reassembles them by
sequence number and decodes the OUCH (`scripts/dump_session.py`). The FPGA still
does not *terminate* TCP -- no reordering buffer, no retransmission logic, no
window management -- because a receiver that only has to recognise in-order
segments and count the rest does not need to.

## 10. Results, measured on silicon

**Post-route, out of context** (`xcu55c-fsvh2892-2L-e`): core_clk **220.0 MHz**,
above the 195.3 MHz floor; cmac_clk meets 322.265625 MHz; all timing constraints
met. Closing that meant working through a cluster of ~160 MHz paths in the book
engine, and the decisive fix was splitting the price ladder's read-modify-write
(+65 MHz where earlier register stages bought single digits). The candid path,
missed predictions included, is in `step5-board/README.md`.

**As a Vitis kernel on the card**, 215 MHz core, all timing met, 0 of 525,146
endpoints failing. Kernel resources with the real MAC included: 52,387 LUT,
34,871 FF, 101 BRAM, 66 URAM, 2 DSP — about 4.4 % of the part's LUTs.

**Executed on a real Alveo U55C**, replaying a 5 M-message NASDAQ AAPL session:

| | |
|---|---|
| Wire-to-wire, through a real 100 G MAC | **518.2 ns** min / 579.4 ns mean, 70 samples |
| In fabric only (first RX beat to first TX beat) | 206.7 ns min |
| Decoder to order (the queueing part) | 107.0 ns min |
| Order frames vs. the software golden | **70 / 70 byte-identical**, zero drops |
| MAC frames | 1,127,130 with `rx_err=0 underrun=0 overflow=0` |

The three intervals are **not** comparable as-is, and the constant between them is
measured rather than assumed: 206.7 − 107.0 = **99.7 ns** of fixed front and back
end (RX, CDC, splitter, decode inbound; builder, framer, TX CDC outbound), the
part that does not queue. Wire-to-order under load is the queueing figure plus
that constant.

**Under load** the floor never moves — 23 core cycles at every offered rate — but
from 25.1 to 40.6 M msg/s the mean grows 1.49× while the **max grows 2.21×, to
730 ns**. That divergence is the queueing tail, and it is why quoting a mean for
this design would mislead. Saturation is a knee rather than a shoulder, between
40.6 and 46.3 M msg/s, which is 20–40× the real NASDAQ peak the design was sized
against. Every non-saturated point is byte-identical to the golden: the pipeline
degrades by **dropping and counting**, never by emitting a wrong order.

**The MAC is the larger half of the path**, which reorders what is worth
optimising: ~207 ns of fabric against **~300 ns** of MAC, SerDes and framing. Of
that ~300 ns, about 285 ns is inside `cmac_usplus` and the GT — already generated
with RS-FEC and flow control off, and with an RX path the vendor documents as
cut-through — leaving ~9–12 ns that is ours. Simulation had predicted ~145 ns for
that term and was wrong by a factor of two, because the behavioural MAC's latency
is a constant a testbench author chose. Cycle-shaving in the ladder or the decoder
attacks the smaller term.

## 11. What is not done

- **Loopback is not a cable.** The wire-to-wire figure uses the GT in near-end PMA
  loopback: frames are 64b/66b encoded, serialized at 25.78125 Gb/s on four lanes,
  recovered, aligned and FCS-checked, so it is the same `D + T_tx + T_rx` a real
  wire gives. A cabled two-port measurement against a live feed is still the
  honest end state.
- **Inbound on the card's own TCP connection** works end to end in simulation --
  RX to capture to a decoded OUCH message -- and has never met a real venue. The
  generator that produced the replies is Python, so what is proven is the
  transport, not interoperability with an exchange.
- **Nothing proven is left unintegrated.** `fast_bbo`, `tx_replay_buf` and
  `tcp_rx` were the three modules with a self-checking testbench and no
  instantiation (§6, §9); all three are now in `t2t_top`, and the goldens are
  byte-identical across the change. What the fast path has not had is a card run.
- **Cut-through decode was evaluated and dropped.** At 512-bit width every ITCH
  message (max 50 B) arrives in one 64-byte beat, so there is no partial-message
  window left: it could only collapse the decoder's single register stage, 1 cycle
  and 4.65 ns, in exchange for a full combinational decode on the core clock
  (`FINDINGS §7.1.1`). The idea was sound when the datapath was 64 bits; the width
  change took the win instead.
- **Floorplanning the ladder will not help**, despite its paths being 86 % routing.
  The failing endpoints sit four columns and three rows apart — already adjacent —
  so the delay is congestion and fanout from the 4,096-flop occupancy scan, not
  span. The lever is restructuring that scan.
- **The strategy parameters are tuned on a thin reconstructed book**, not real
  AAPL: they test the mechanism, not a tradeable edge.
- **The OUCH Shares range** (`0 < shares < 1,000,000`) is not enforced in hardware;
  it holds by configuration only.
