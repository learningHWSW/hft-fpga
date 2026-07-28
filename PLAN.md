# Revised plan — ITCH tick-to-trade (U55C, SystemVerilog RTL)

A rewrite of the original plan (an HLS-based draft) to match the current state of
the repo. Step 1 (C golden parser) and step 2 (64-bit SV decoder, golden diff
PASS) are done.

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
                                      OUCH builder ──► TX (stretch, session in SW)
```

- The market-data path has **no backpressure** anywhere (tready=1). Absorption is
  in FIFOs, overflow is drop + counter. (The principle established in step 2.)
- The symbol filter is a locate-based bitmap (SW sets it from the R message,
  shadow/commit registers).

## 2. Stage-by-stage plan

### Step 3a — MoldUDP64 stripper + message splitter (64-bit first)
- Strip the MoldUDP64 header (20 B), MsgCount loop, heartbeat handling,
  **seq gap detection** (counter + SW interrupt/flag).
- Split message boundaries by the length prefix -> emit on the step-2 decoder
  interface (tlast per message).
- Add a MoldUDP64 wrapping mode to gen_itch.py (including gap / heartbeat /
  beat-boundary-straddling cases).
- **DoD**: golden diff PASS with gap/heartbeat/boundary cases (xsim + Verilator).

### Step 3b — 512-bit width extension + realignment (technical core 1) ✅
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

### Step 4a — order table (technical core 2) ✅
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

### Step 4b — top-of-book / price ladder ✅
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

### Step 5 — U55C real board
- Receive UDP/IP with CMAC + verilog-ethernet (or a vendor IP), IGMP join. Check
  U55C example-design compatibility up front.
- Host reporting: stream BBO changes / gap events over QDMA; control registers
  (symbol bitmap, parameters) are shadow/commit.
- **DoD**: replay gear (or tcpreplay 100G) -> wire receive -> BBO matches
  simulation. Measure MAC-receive-to-BBO-update latency (a cycle counter,
  converted to ns).

### Step 6 (stretch) — OUCH fire
- The session (SoupBinTCP establishment / retransmit / heartbeat) is SW; **the
  FPGA takes the established session's seq/ack in shadow registers and only
  assembles + fires the hot-path packet**.
- Trigger: a step-4b BBO event -> comparator -> a pre-staged order template.
- Keep it as a design document even if it does not get built (holding the
  original's §8 policy).

## 3. Measurement checklist (common to every stage)

- On each step's completion: latency p50/p99 (cycles -> ns), resources
  (LUT/FF/BRAM/URAM), max clock.
- Real-data baseline: RTL multiple over the step-1 SW throughput (M msg/s).
- Drop/gap/overflow counters are built into every module as standard.
- Cut-through decode (fire the instant the last needed field arrives) is a
  separate optimisation commit **after the whole pipe is complete** — compare
  before/after latency on the same replay.

## 4. Priority

1. **3a -> 3b -> 4a -> 4b** in fixed order. 4a (order table) is the technical
   core of this project — up to here is a complete portfolio.
2. Step 5 when board access is available.
3. Step 6 when time allows. It has value as a document alone.
