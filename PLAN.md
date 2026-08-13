# Revised plan — ITCH tick-to-trade (U55C, SystemVerilog RTL)

A rewrite of the original plan (an HLS-based draft) to match the current state of
the repo.

**Status: every step is done.** The chain runs on a real Alveo U55C, through a
real 100 G MAC, producing order frames byte-identical to the software golden. The
plan is kept as written — including the predictions that turned out wrong — and
each step carries what it actually cost. See [ARCHITECTURE.md](ARCHITECTURE.md)
for the design and [data/FINDINGS.md](data/FINDINGS.md) for the measurements.

## 0. What changed from the original (the improvements)

| # | Original | Improvement | Rationale |
|---|---|---|---|
| 1 | Described in HLS terms (`hls::stream`, `DATAFLOW`, II=1) | Re-stated in SV RTL terms. The performance metric is not "II" but **msg/cycle @ 322.27 MHz (the CMAC 512-bit clock)** | The project settled on RTL (step 2 done) |
| 2 | Symbol -> hash-table lookup | **Use the stock locate (2 B) directly as an array index** — it is in every message header and is a dense small integer over a day. A symbol hash itself is unnecessary | Found by confirming the protocol in step 1 |
| 3 | Two lookups in the book: symbol hash + order_ref hash | Hash **only order_ref**. `hash(order_ref) -> {locate, side, level_idx, qty}` | Follows from #2 |
| 4 | Parser handles one message at a time, no width discussion | **State the throughput**: the worst case (all 'D', 19 B + 2 B len) is ~3 message boundaries per 512-bit beat. But the real peak is a few M msg/s -> **a 1 msg/cycle splitter + an input FIFO (burst absorption) + an overflow counter**. FIFO depth is set by measuring the real burst distribution | 322 M msg/s (1 msg/cycle) is two orders of magnitude over the real feed. Multiple boundaries within a beat are only an instantaneous peak |
| 5 | Gap recovery only mentioned | Decided: **the HW does gap detection + a counter + session reset only; retransmit/rewind is SW** (not the hot path) | Promoting the original's recommendation to a decision |
| 6 | Assumes HBM is used | **URAM-first for the hot path, HBM deferred**. Filtering to the tracked symbols keeps the order table on-chip. Consider HBM only when all-symbol tracking becomes necessary — measure the peak concurrent live-order count on real data first | HBM latency (hundreds of ns) is unsuited to the market-data hot path |
| 7 | Stage A/B/C split (with a PCIe DMA stage) | **Shrink the PCIe injection stage**: simulation already replays real data (the step-1 real-data pipe), so PCIe is only the "host reporting/control path". Stage B as a data-injection path is dropped | AF_XDP -> DMA -> FPGA injection is a lot of work for the verification value. TB replay verifies the same thing more precisely |
| 8 | 'U' (Replace) described as a plain cancel + add | 'U' has **no stock/side fields** -> inherited by looking up the old ref. 'E'/'X'/'D' also require a lookup. **The book engine's cycle budget is sized on 'U' (lookup + delete + insert, two hash operations)** | Re-checking the spec. This is where the throughput bottleneck is decided |
| 9 | Verification described piecemeal | **Apply the golden-diff pattern consistently across every stage**: each step's C/Python golden emits a canonical log, the RTL TB emits the same format, an empty diff is PASS. A replay of the first N million real messages is pinned as the regression | The method already proven in step 2 |

## 1. Target architecture

```
QSFP28 ──► CMAC(100G) ──► eth/ip/udp parser ──► MoldUDP64 stripper ──► msg splitter
              512b@322M      (filter+checksum)     (seq gap detect)      (boundary realign)
                                                                              │ itch raw msg
                                                                              ▼
   host(PCIe) ◄── BBO/event report ◄── top-of-book engine ◄── order table ◄── itch decoder
                                        (per-locate ladder)   (ref hash, URAM)  (step 2 extended)
                                            │
                                            ▼ trigger
                                      OUCH builder ──► TX (session in SW)
```

- The market-data path has **no backpressure** anywhere (tready=1). Absorption is
  in FIFOs, overflow is drop + counter. (The principle established in step 2.)
- The symbol filter is a locate-based bitmap (SW sets it from the R message,
  shadow/commit registers).

Two ways the built design differs from this target, kept here rather than
retrofitted because the divergence is the interesting part
([ARCHITECTURE.md](ARCHITECTURE.md) describes what exists):

- **The symbol filter is a single `track_locate` register, not a bitmap.** One
  tracked symbol is what fits URAM at the measured geometry, and a bitmap would
  have implied multi-symbol capacity the table does not have. Multi-symbol needs
  the HBM path this plan defers in §0 item 6, and the filter widens with it.
- **The trigger is two signals, not one comparator.** Imbalance takes the BBO from
  the ladder as drawn; sweep detection taps the order-table delta *before* the
  ladder and skips it entirely, which is why it runs 19 core cycles against 28.
  That second path does not exist in this diagram.

## 2. Stage-by-stage plan

### Step 3a — MoldUDP64 stripper + message splitter (64-bit first) — done
- Strip the MoldUDP64 header (20 B), MsgCount loop, heartbeat handling,
  **seq gap detection** (counter + SW interrupt/flag).
- Split message boundaries by the length prefix -> emit on the step-2 decoder
  interface (tlast per message).
- Add a MoldUDP64 wrapping mode to gen_itch.py (including gap / heartbeat /
  beat-boundary-straddling cases).
- **DoD**: golden diff PASS with gap/heartbeat/boundary cases (xsim + Verilator).

### Step 3b — 512-bit width extension + realignment (technical core 1) — done
- Generalise the splitter to 512-bit: realign where a message ends and another
  starts within one beat, up to 3 boundaries per beat. -> [step3b-splitter/rtl/mold_splitter.sv](step3b-splitter/rtl/mold_splitter.sv).
  A 2-beat (128 B) window + barrel shift does fill/emit concurrently to hold
  **1 msg/cycle**.
- Design: 1 msg/cycle output + an upstream elastic FIFO. **FIFO depth fixed
  (measured, [data/FINDINGS.md](data/FINDINGS.md))**: worst backlog over the day
  is 76 msgs / 2356 B -> a **256-entry (2^8) input FIFO** or a 512-bit-wide
  **64-deep beat FIFO (4 KB)**. Backlog >=2 is only 1%, so it sits nearly empty
  most of the time. (The FIFO is instantiated in step 5, when joined to CMAC.)
- The decoder (step 2) is reused by just matching the width — `itch_decoder
  #(.DATA_W(512))` unchanged.
- **DoD met**: real-data replay (2019-12-30) diff PASS — Verilator 1M msg, xsim
  50k msg, and the synthetic test.mold (gap/dup/hb/eos) on both flows. The real
  data is a BinaryFILE, so [itch2mold.py](step1-sw-parser/itch2mold.py) repacks
  it into multi-message MoldUDP64 to stimulate realignment.

### Step 4a — order table (technical core 2) — done
- `hash(order_ref) -> {locate, side, price, qty}`, d-way set-associative, URAM.
  -> [step4a-order-table/rtl/order_table.sv](step4a-order-table/rtl/order_table.sv).
  Emits a book delta (rem/add level) per message.
- **Design point fixed by measurement** ([data/FINDINGS.md](data/FINDINGS.md) §4):
  all-symbols is HBM (8M+ entries, no configuration reaches zero overflow).
  **Symbol filter -> URAM**. A reversal found: the filter table needs a **mixing
  hash, not raw** (a single symbol's refs cluster in the low bits; raw 16b×4 =
  24142 vs mix = 132 overflows). Adopted `2^16×8 + mix` -> zero overflow on AAPL
  over the day.
- **Verified**: synthetic test.itch (every op type) xsim + Verilator PASS,
  real-data AAPL slice (500K xsim, 5M Verilator, including real U/X) PASS.
  0 drops, 0 overflow.
- **Performance (next)**: currently a correctness-first FSM (2 cy/msg, 3 for U).
  II=1 pipelining (read/modify/write + forwarding, dual-port U) is the follow-on
  — compare throughput before/after.
- 'U' handling (lookup -> delete -> insert) is the most cycles — the per-message
  cycle budget is sized on it.
- golden: extend the step-1 parser to emit an order-table op log
  (insert/erase/modify + result).
- **DoD**: table-state diff PASS on real-data replay, collision/occupancy report.

### Step 4b — top-of-book / price ladder — done
- A price ladder (aggregate qty per level, L2), BBO by a priority scan over an
  occupancy bitmap. -> [step4b-book/rtl/price_ladder.sv](step4b-book/rtl/price_ladder.sv).
  `cfg_base` sets the band's start price (a re-centring hook); out-of-band is
  dropped + `oob_cnt` (measuring how often that low-frequency path fires — 465
  cases over AAPL's 5M, all deep/stub, BBO unchanged).
- **golden**: [dump_bbo.py](step4b-book/scripts/dump_bbo.py) = the step-1 book
  model's canonical format. Cross-checked byte-for-byte against the step-1 C
  parser's BBO (synthetic and real data).
- **DoD met**: the whole `decoder -> order_table -> price_ladder` chain diff PASS
  on the AAPL BBO sequence — synthetic xsim + Verilator, real data xsim 500k +
  Verilator 5M (1779 BBO). 0 drops, 0 overflow.
- **Performance (next)**: correctness-first FSM (3 cy/record). Pipelining the
  best-level search + moving qty to BRAM is the follow-on. Measured latency and
  L3 (fixed slots per level) come later.

### Step 5 — U55C integration — done
- Eth/IPv4/UDP receive front end, MoldUDP64 strip, IGMP join and query response,
  ARP responder, A/B redundant-feed arbitration with gap recovery.
- Two clock domains joined by `cdc_fifo` on both sides — gray pointers,
  `ASYNC_REG`, drop-rather-than-stall on the market-data side.
- Control plane behind AXI-Lite (`t2t_axil`), shadow/commit for the config that
  must change coherently.
- **DoD met**: full chain `t2t_top` simulated end to end with wire frames in and
  order frames out, and taken through synthesis and place & route for
  `xcu55c-fsvh2892-2L-e` — **220.0 MHz post-route**, above the 195.3 MHz floor,
  all constraints met.
- **What it cost**: closing timing meant a cluster of ~160 MHz paths in the book
  engine. The decisive fix was splitting the price ladder's read-modify-write
  (+65 MHz, where earlier register stages bought single digits). Two predictions
  in this plan were wrong and are documented as such in `step5-board/README.md`.

### Step 6 — strategy, risk gate, OUCH fire — done
Listed as a stretch goal that might stay a design document. It was built.

- The session (SoupBinTCP establishment / retransmit / heartbeat) is SW; the FPGA
  takes the established session's seq/ack in shadow registers and only assembles
  and fires the hot-path packet — the split held exactly as planned.
- **Two** triggers, not one: order-book imbalance off the BBO, and sweep /
  momentum ignition tapping the order-table delta directly, which skips the
  ladder and runs 19 core cycles against imbalance's 28.
- Both signals were **measured on real data before any RTL** (`FINDINGS §5`):
  ≥3-level sweeps continue in their direction ~75 % of the time over the next
  millisecond. Sample size flipped that conclusion once — the first 5 M slice
  said 39 %, i.e. reversion, on 23 events.
- Risk gate is not deferred: kill switch, position limit, in-flight limit, each
  rejection counted separately.
- **DoD met**: orders and the OUCH/SoupBinTCP/TCP bytes diff clean against the
  golden, and are re-derived a third time by scapy and by an independent Python
  decoder so a shared mistake cannot agree with itself.

### Step 7 — host software — done
- SoupBinTCP session, login/heartbeat, register configuration, ack/fill feedback
  driving `cfg_order_ack` and the true position.
- **Two independent OUCH sessions** rather than two senders on one TCP
  connection: the spec scopes order identity to *(account, token)* and binds each
  account to a physical port, so a second port deletes the coordination problem
  instead of managing it.
- **DoD met**: the whole round trip over a real loopback socket against a mock
  exchange that parses OUCH independently, including feeding it the bytes the RTL
  actually emitted.

### Step 8 — on real silicon — done
Not in the original plan at all; the plan stopped at "measure latency on the
board". This is that, done properly.

- A Vitis RTL kernel wrapping `t2t_axil`, replaying a real NASDAQ session from
  HBM and capturing order frames back to HBM, so the datapath is checked and
  timed on the part rather than in xsim.
- **Phase A**: the datapath on silicon, MAC-less. 70/70 order frames
  byte-identical to the golden, **206.7 ns** in-fabric minimum.
- **Phase B**: a real `cmac_usplus` with the GT in near-end PMA loopback, so MAC,
  PCS and SerDes are inside the measurement. 1,127,130 frames through the IP with
  zero receive errors, and the project's first **wire-to-wire** figure:
  **518.2 ns** minimum, 579.4 ns mean.
- **Load swept on the card**, not modelled: the floor never moves, the max grows
  2.21× to 730 ns, and saturation is a knee between 40.9 and 46.6 M msg/s — 20–40×
  the real NASDAQ peak. Every non-saturated point is byte-identical to the golden.
- **DoD met**, and it replaced the original one: the plan asked for
  MAC-receive-to-BBO latency; what exists is wire-to-order through a real MAC,
  golden-verified, with the load curve behind it.

## 3. Measurement checklist (common to every stage)

- On each step's completion: latency p50/p99 (cycles -> ns), resources
  (LUT/FF/BRAM/URAM), max clock.
- Real-data baseline: RTL multiple over the step-1 SW throughput (M msg/s).
- Drop/gap/overflow counters are built into every module as standard.
- Cut-through decode (fire the instant the last needed field arrives) was held as
  a separate optimisation commit **after the whole pipe is complete**. Now
  evaluated and **not built**: at 512-bit width every ITCH message (max 50 B)
  arrives in one 64-byte beat, so there is no partial-message window left to
  exploit and the most it can save is the decoder's single register stage —
  1 cycle, 4.65 ns, 2.2 % of the in-fabric path — in exchange for a full
  combinational decode on the core clock. See `data/FINDINGS.md` §7.1.1.

## 4. Priority — as planned, and as it went

The original order held: **3a -> 3b -> 4a -> 4b**, then the board, then the
stretch goal. Step 4a was correctly identified as the technical core, and it is
where the two most useful measurements came from (§0 items 2 and 3).

Two things the plan got wrong about its own ordering, both worth keeping:

- **"Step 6 when time allows. It has value as a document alone."** It was built,
  and building it is what produced the OUCH/TCP byte-exactness check that later
  caught a legal-but-wrong `Display` code. A design document would not have.
- **The plan stopped at the board.** It had no step 8, and treated "measure
  latency on hardware" as the last line of step 5. Getting a real number turned
  out to be its own project — a Vitis kernel, an HBM replay harness, two latency
  probes, a licence gate, and two bitstreams — and it is where most of the
  surprises lived, because simulation cannot see a BRAM that a reset does not
  clear, or a MAC whose real latency is twice the testbench's constant.

### What is worth doing next

Ordered by value, with the measurement that justifies each:

1. **Nothing in the datapath, first.** The MAC is ~300 ns of a ~518 ns path and
   the fabric is ~207 ns, so cycle-shaving attacks the smaller term. Know that
   before spending time on it.
2. ~~**Integrate `fast_bbo`**~~ — **done.** The rejoin (`bbo_merge`) is driven
   from the ladder's accept, which fixes the arrival order, and merges on value
   against a shared baseline, which makes the duplicate suppression fall out of
   the ladder's own change test. The BBO sequence is unchanged on the real replay
   (1,779 records, 1,174 of them ten cycles early), and the plan was right that
   the ordering was the whole job.
3. ~~**Integrate `tx_replay_buf`**~~ — **done**, and it was small for the reason
   given. It has since grown the other half: `tx_rto` watches the acknowledgement
   number and re-sends the oldest unacknowledged frame by itself, which the plan
   assumed would stay software's. Finishing the inbound path is what changed the
   answer — the replies reach software through a capture buffer read in batches,
   so a host-timed resend is a resend some milliseconds late.
4. ~~**Solve inbound on the card's own TCP connection.**~~ — **done in
   simulation.** `tcp_rx` is wired in, the acknowledgement number the card sends
   is live, and the replies reach the host: merged into the capture area the
   orders use and decoded from it (`step8-hw/scripts/dump_session.py`). Both
   phases pass, with the order frames byte-identical either way. What remains is
   not code — it is a venue to answer the orders.
5. **A cabled two-port measurement** against a live feed, replacing near-end
   loopback. Needs optics and a feed source.
6. ~~**Re-derive the strategy parameters from a full trading day.**~~ — **done,
   and it answered more than it was asked.** The calibration was wrong because
   the slice was pre-market (FINDINGS §5.2), and the forward-return study that
   followed (§5.3) settled the open question: the imbalance signal predicts
   direction — 75 % continuation against a 62 % population — and still loses to
   the half-spread it must cross, at every ratio and horizon measured. The
   mechanism is real; the economics are not, for a taker.
