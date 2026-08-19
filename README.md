# HFT FPGA Tick-to-Trade — AMD Alveo U55C

A low-latency **tick-to-trade** pipeline in SystemVerilog RTL: NASDAQ **ITCH 5.0**
market data in off the wire, an order out to the exchange, entirely on the FPGA.

The FPGA parses the feed, maintains an L2 order book, runs two measured trading
signals, and assembles the OUCH / SoupBinTCP / TCP order frame — wire to wire,
with no host in the hot path. Software owns only what is stateful and not
latency-critical: session login, heartbeats, ack/fill feedback, register config.

Two commitments shape the project:

- **Every stage is diffed against a software golden.** A C or Python reference
  emits a canonical log, the self-checking testbench emits the same format, and
  `make test` diffs them; an empty diff is the only pass. The OUCH/TCP output is
  checked a third time by an independent decoder.
- **Every design parameter is measured, not guessed.** FIFO depths, hash
  function, table geometry, price-band width and the strategy thresholds all come
  from a full trading day of NASDAQ data ([`data/FINDINGS.md`](data/FINDINGS.md)).

> Design rationale and per-step definition-of-done: [PLAN.md](PLAN.md) ·
> End-to-end data-path design: [ARCHITECTURE.md](ARCHITECTURE.md) ·
> The measurements behind every sizing decision: [data/FINDINGS.md](data/FINDINGS.md)

## Results on silicon

Measured on a real Alveo U55C, replaying a 5-million-message NASDAQ AAPL session:

| | |
|---|---|
| **Wire-to-wire, through a real 100 G MAC** | **459.2 ns** min / 539.9 mean / 735.4 max, 70 samples, none excluded |
| Decoder-to-order under load | **14 core cycles** min / 27.2 mean / 64 max |
| In-fabric only (first RX beat to first TX beat) | **160.0 ns** min / 231.8 mean |
| Fast book path vs. the ladder | 1,174 of 1,779 BBO records answered early, **`st_bbo_mismatch = 0`** |
| Order frames vs. the software golden | **70 / 70 byte-identical**, zero drops |
| MAC frames passed | 1,127,130 with `rx_err=0 underrun=0 overflow=0` |
| Full chain post-route (out of context) | **225.5 MHz** best of four directive sets, above the 195.3 MHz a 100 Gb/s wire demands |

- The MAC is the larger half: ~300 ns of the 459.2 ns, of which only ~9–12 ns is
  ours. The fabric is ~167 ns.
- **471.7 → 459.2 ns** at the minimum, measured on the card: exactly **4 wire
  cycles**, from deleting two CDC synchronisers on a single-clock FIFO
  (`SAME_CLOCK`) and one core cycle of decode (`CUT_THROUGH`). Mean 551.9 → 539.9
  and max 747.8 → 735.4 move by the same 12 ns, which is what a fixed cost coming
  out looks like. 70/70 frames still byte-identical, `st_bbo_mismatch = 0`, MAC
  `underrun = 0`.
- The floor never moves under load — **14 core cycles at every offered rate** —
  but from 25 to 41 M msg/s the mean grows 1.59× while the **max grows 2.03×, to
  688 ns**. Quoting a mean for this design would mislead.
- Saturation is a knee, between 41 and 47 M msg/s — 20–40× the real NASDAQ peak.
  The pipeline degrades by **dropping and counting**, never by emitting a wrong
  order; every non-saturated point is byte-identical to the golden.
- `fast_bbo` bought **515.1 → 471.7 ns** wire-to-wire and 23 → 14 core cycles
  loaded, moved the saturation knee not at all, and costs +1.6 % LUTs / +2.1 %
  registers with no measurable fMAX change across four directive sets
  ([FINDINGS §7.5–7.7](data/FINDINGS.md)).

## Data path

**RX — market data in.** The feed arrives on two lines, filtered, stripped and
re-joined before a single message stream reaches the decoder.

```
                            ┌─► eth/ip/udp A ─► drop_fifo ─┐
QSFP28 ─► CMAC ─► cdc_fifo ─┤   filter + strip             ├─► feed_ab_arb ─► mold_splitter
  RX      100G    322→215   │                              │   redundant-feed   realign to
          322MHz    MHz     └─► eth/ip/udp B ─► drop_fifo ─┘   gap recovery      messages
                            │                                                        │
                            ├─► igmp_query_detect                                    ▼
                            │   (arms a report on TX)                          itch_decoder
                            │                                                  field extract
                            └─► tcp_rx                                               │
                                the live ack for tcp_tx,      ┌──────────────────────┤ book delta
                                replies to the capture        ▼                      ▼
                                                        sweep_detect            order_table
                                                        momentum, skips         ref→{px,qty}
                                                        the ladder             ┌─────┴─────┐
                                                                               ▼           ▼
                                                                          fast_bbo    price_ladder
                                                                          most deltas  L2 scan,
                                                                          in 1 cycle   11 cycles
                                                                               └─────┬─────┘
                                                                                     ▼
                                                                                 bbo_merge
```

**TX — order out.** The order frame crosses back to the CMAC clock and wins
arbitration against control traffic, so a membership report can never delay a
trade.

```
     sweep ─┐
            ├─► strategy ─► ouch_builder ─► tcp_tx ─► tx_replay_buf ─► cdc_fifo ─┐
     BBO ───┘   + risk gate  OUCH 4.2 /     TCP/IPv4  last 16 frames    215→322  │
                             SoupBinTCP      /Eth     tx_rto re-sends    MHz     │
                                                                                 ▼
    QSFP28 ◄─ CMAC ◄─ axis_tx_arb ◄──────────────────────────────────────────────┘ orders take the
       ▲       TX          ▲                                                       priority port
       │                   │
       │                   └─ axis_tx_arb ◄─ igmp_join      control traffic,
       │                                  ◄─ arp_responder  yields to orders
       │
       └─ Phase B puts the GT in near-end loopback, so everything transmitted
          returns on RX and the measurement spans MAC, PCS and SerDes
```

## Design decisions

- **No backpressure to the wire.** FIFOs sized from measurement; overflow is
  dropped and counted. A front end that stalls the MAC is a broken one.
- **Two clocks on purpose.** The throughput floor is 12.5 GB/s ÷ 64 B =
  **195.3 MHz**; the core runs 215 MHz and joins the 322 MHz CMAC through
  dual-clock FIFOs on both sides.
- **Order table sized by measurement** — `hash(order_ref)` into 2¹³ × 16 URAM.
  A full trading day gives zero overflow, and an XOR fold beats a multiply-shift
  mixer at lower cost (`FINDINGS §4`).
- **Several symbols, one chain.** `NSYM` replicates everything a book owns —
  ladder, fast-BBO tracker, sweep detector, edge state, position — and shares
  everything the *wire* owns: one order table, one TCP session, one in-flight
  budget. Each book is byte-identical to a single-symbol build tracking that
  name. Verified at `NSYM = 2` on silicon (AAPL + QQQ); costs +58 % LUTs and
  ~12 % of absorbable message rate.
- **Most book updates skip the ladder scan.** `fast_bbo` answers from two
  registers when it can prove the answer (91 % of real deltas); `bbo_merge`
  rejoins the two so the record stream is exactly the ladder's, merged on value
  against a shared baseline.
- **Cut-through decode is on by default, and it is free.** `itch_decoder`
  decodes the beat's wires rather than registering the beat and decoding the
  register: one core cycle, 4.65 ns, byte-identical decode log. Swept at four
  directives per setting, it closes **4/4** at **223.6 MHz** best against the
  ladder-only build's 222.2 — 1.4 MHz *faster*, inside a 4.8 MHz spread, so no
  measurable cost — and it is **−1,161 LUTs and −361 flops**, because deleting
  the byte collector removes more than the combinational decode adds
  ([FINDINGS §7.1.1b](data/FINDINGS.md)). It is on the card: its cycle is part of
  the 471.7 → 459.2 ns above. The default is the width's answer
  rather than a preference — `CUT_THROUGH = (DATA_W >= 8*MAX_MSG_BYTES)` — on at
  the 512-bit datapath that ships, off at the 64 bits steps 2–4 drive their
  goldens through, where a message spans beats and it could never fire. Asking
  for it at 64 bits is still an elaboration error.
- **Cut-through on the order FIFO, by contrast, recovers nothing, and the
  formula says so.** `axis_sf_fifo` releases a frame once
  `CT_MIN = L − (L−1)/W_GAP_MAX` beats are resident, which for a 2-beat order
  frame behind a 215 MHz writer is the whole frame: no interior to cut through.
  The 6.21 ns on that path turned out to be CDC synchronisers on a FIFO with
  both ports on one clock, and deleting them gave up nothing — also on the card,
  and the other half of the 12.5 ns
  ([FINDINGS §7.1.1a, §7.6.1a](data/FINDINGS.md)).
- **Two signals, one risk gate.** Order-book imbalance, and sweep / momentum
  ignition (19 core cycles against imbalance's 28). Only the sweep has a forward
  return that beats the cost of acting on it (`FINDINGS §5, §5.3`).
- **Risk gate is not deferred**: kill switch, position limit, in-flight limit,
  shares-range check — each rejection counted separately and published, so a
  quiet strategy is distinguishable from a blocked one. All 32 of `t2t_top`'s
  status outputs reach the register map, and `step7-host/tests/test_regmap.py`
  checks the host's list against the RTL read mux.
- **The order session is maintained on the card.** `tcp_tx` takes its ack number
  from `tcp_rx`; `tx_replay_buf` keeps the last 16 frames; `tx_rto` re-sends the
  oldest when the ack stops moving. A resend is idempotent twice over — same TCP
  sequence number, same OUCH token. Login, heartbeats and fill accounting stay
  software's.
- **Runs on real silicon** as a Vitis kernel, replaying from HBM, with a real
  `cmac_usplus` and the GT in near-end loopback so MAC, PCS and SerDes are inside
  the measurement.

## Roadmap

| Step | Content | Status |
|---|---|---|
| 1 | ITCH 5.0 software reference parser (golden model) | Done — [step1-sw-parser](step1-sw-parser/) |
| 2 | SystemVerilog ITCH decoder + self-checking TB | Done — [step2-rtl-decoder](step2-rtl-decoder/) |
| 3a | MoldUDP64 stripper + splitter, sequence-gap detect | Done — [step3a-mold-stripper](step3a-mold-stripper/) |
| 3b | 512-bit realignment, multiple message boundaries per beat | Done — [step3b-splitter](step3b-splitter/) |
| 4a | Order table — `order_ref` hash in URAM, sized from real data | Done — [step4a-order-table](step4a-order-table/) |
| 4b | Top-of-book engine — price ladder (L2), BBO, fast path + rejoin | Done — [step4b-book](step4b-book/) |
| 5 | U55C integration: Eth/IP/UDP RX, TCP session RX, CDC, full-chain P&R | Done — [step5-board](step5-board/) |
| 6 | Strategy, risk gate, OUCH + SoupBinTCP + TCP transmit, replay buffer | Done — [step6-strategy](step6-strategy/) |
| 7 | Host software — session, register config, ack/fill feedback | Done — [step7-host](step7-host/) |
| 8 | On real silicon — Vitis kernel, HBM replay, measured latency | Done — [step8-hw](step8-hw/) |

## Quick Start

### Requirements

| | |
|---|---|
| **Simulation only** | any x86-64 Linux host. No FPGA needed |
| **On silicon** | **AMD Alveo U55C** (VU35P, HBM2 16 GB, QSFP28 ×2), shell `xilinx_u55c_gen3x16_xdma_base_3` |
| Optics | **not required** — the 100 G measurement uses the GT in near-end PMA loopback |
| Build host | ≥ 32 GB RAM, ~50 GB disk; 32 cores keeps a bitstream link near 70 minutes |
| Vivado / Vitis | **2025.2.1**, and `vivado`/`v++`/`xvlog`/`xelab`/`xsim` must all come from the *same* install |
| XRT | 2.18.179 — only for running on the card |
| Python / GCC | 3.8+ (standard library only) / C++17 |
| OS, locale | Ubuntu 22.04, and `en_US.UTF-8` must exist or xsim aborts (`sudo locale-gen en_US.UTF-8`) |

Every step sources `XILINX_SETTINGS` through one shared guard
([`mk/xilinx.mk`](mk/xilinx.mk)) and fails loudly rather than falling back to
whatever is on `PATH`; `make which-tools` in any step prints what its recipes
will use.

```sh
make test                                        # the pinned install
make test XILINX_SETTINGS=/opt/Xilinx/2024.2/Vivado/settings64.sh
make test XILINX_SETTINGS=                       # deliberately, whatever is on PATH
```

A `cmac_usplus` licence is required **only** to generate the Phase B bitstream
(AMD issues it at no cost); `make gate-license` proves the checkout in seconds.

### Install

```sh
git clone https://github.com/learningHWSW/hft-fpga.git
cd hft-fpga

# Real market data, for the real-data replays. Not committed: 3.5 GB, ~269 M messages.
cd data && curl -O "https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/12302019.NASDAQ_ITCH50.gz"
```

Synthetic vectors are generated by the testbenches, so the simulation suite runs
without the download.

### Simulate

Every step's `make test` regenerates its golden, runs the RTL, and passes only if
the two logs are byte-identical.

| Step | Command | What it proves |
|---|---|---|
| 1 | `make test` | the C golden parses a real day self-consistently |
| 2 | `make test` | ITCH decode == golden |
| 3a / 3b | `make test`, `make test-real-xsim`, `make test-ct-xsim` | MoldUDP64 strip, 512-bit realignment, and the same decode log a cycle earlier under cut-through |
| 4a | `make test`, `make test-real-xsim`, `make test-multi`, `make test-clear` | order table == golden, zero overflow, two symbols share one table, post-reset sweep clears URAM |
| 4b | `make test`, `make test-real-xsim`, `make test-merge-xsim` | BBO sequence == golden, and the fast/slow rejoin preserves it |
| 5 | `make test-t2t`, `make test-units-xsim`, `make test-tcprx`, `make test-msym`, `make test-t2t-ct` | the whole chain, two clocks, wire frames in and session frames back, and order frames unmoved by cut-through decode |
| 6 | `make test-xsim`, `make test-replay`, `make test-rto`, `make test-msym`, `make test-acklat` | OUCH/TCP bytes == golden, resend decisions, no per-book state shared, ack-latency probe |
| 7 | `make test` | session, register map, two independent OUCH sessions |
| 8 | `make test-xsim`, `make test-b`, `make test-session`, `make test-rto`, `make test-real`, `make test-sffifo-ct` | the Vitis kernel, HBM to HBM, through the MAC, replies back to the host, and that a cut-through FIFO releases frames early without ever starving its port |

### Synthesize, build, run

```sh
cd step5-board
make synth-t2t          # out-of-context synthesis of the full chain
make impl-t2t           # place & route for xcu55c-fsvh2892-2L-e

cd ../step8-hw
make help               # every target, grouped, with what each costs
make cmac               # generate the cmac_usplus IP (once, Phase B only)
make gate-license       # prove the licence before spending an hour

make design-bitstream   # the default design (Phase B) -> t2t_b.xclbin (~1 h 15 m)
source /opt/xilinx/xrt/setup.sh
make design-run         # the default design, real 5 M AAPL replay through the MAC
```

**Phase B is the default design** — the datapath behind a real `cmac_usplus`,
which is what every headline number above is measured on. `PHASE=a` selects the
CMAC-less build, which is kept because it is the only one that measures the
fabric alone. The explicitly named targets are unchanged and still say which
artefact they produce:

```sh
make xclbin             # Phase A -> t2t.xclbin     (~1 h 10 m)
make xclbin-b           # Phase B -> t2t_b.xclbin   (~1 h 15 m)
make run-card-real      # Phase A, real 5 M AAPL replay
make run-card-b-real    # Phase B, the same replay through the real MAC
```

Both diff the captured order frames against the golden and print `PASS` only on a
byte-identical match. `RGAP=<n>` varies injector spacing to sweep offered load;
the saturation knee is between `RGAP=28` and `RGAP=24`.

### Clean

```sh
make clean          # logs, sim scratch, small captures      (seconds)
make clean-build    # + packaged kernels, .xo, v++ temp dirs (minutes)
make distclean      # + bitstreams, ip/, replay image        (HOURS — asks first)
```

<!--
## What is not done

Honest scope, all of it stated in the per-step READMEs.

### Measurement

- **Loopback is not a cable.** The wire-to-wire figure is measured with the GT in
  near-end PMA loopback: frames are 64b/66b encoded, serialized at 25.78125 Gb/s
  on four lanes, recovered, aligned and FCS-checked. That is the same
  `D + T_tx + T_rx` a real wire gives, but a cabled two-port measurement against a
  live feed is still the honest end state, and the QSFP cages here are empty.
- **Post-route frequency is sweep-backed, and one configuration is fragile.** The
  fMAX figures here are the best of four implementation directive sets, because one
  build against one build cannot measure place & route — that lesson cost a
  wrong claim in this README, which asserted a 9.5 MHz penalty for `fast_bbo`
  that a sweep does not reproduce and attributed it to a specific carry chain
  that is not critical in any of the eight builds (`FINDINGS` §7.7). What is swept
  is `NSYM = 1` at both `USE_FAST_BBO` settings, and `NSYM = 2` at both order-table
  geometries (`FINDINGS` §4.4). All four configurations now produce a shippable
  build on every directive. `NSYM = 2` at 2¹⁴ × 16 used to close on **one**
  directive of four — and on a *different* one after the toolchain was pinned,
  which is what ruled out simply pinning the directive that worked. Two structural
  fixes took it from 143 failing endpoints to 2 (§4.4.1); what remains is two
  builds missing the out-of-context yardstick by **0.001 ns on one endpoint** —
  the smallest violation the tool can report — against a constraint sitting 21 MHz
  above the 195.3 MHz the wire demands. Quoted as what it is: a reference line
  those builds miss, not a requirement.
- **The MAC is the larger half of the latency, and untouched.** ~207 ns in the
  fabric against **~300 ns** in MAC, SerDes and framing. It is close to
  irreducible: ~285 ns sits inside `cmac_usplus` and the GT, already generated with
  RS-FEC and flow control off, and only ~9–12 ns of the term is ours. The one real
  lever is a thin custom PCS/MAC — a project, not an optimisation pass.

### Integration

- **Nothing proven is left unwired.** `tx_replay_buf`, `tcp_rx` and `fast_bbo`
  were the three modules with a self-checking testbench and no instantiation; all
  three are in `t2t_top`, along with `tx_rto` and `bbo_arb` since, each verified
  byte-identical against every existing golden. The rejoin `fast_bbo` needed is
  `bbo_merge`, and what makes it safe is documented where it lives
  ([step4b-book](step4b-book/)): drive the fast path from the ladder's accept so
  a record cannot overtake a deferred one, and merge on value against a shared
  baseline so the duplicate suppression falls out of the same change-detection
  the ladder already does. Walking instantiations from every design top
  (`t2t_kernel`, `t2t_kernel_b`, `t2t_user_322mhz`, `t2t_axil`, `t2t_top`), exactly
  two RTL modules are left in no hierarchy, and both are deliberate:
  `mold_stripper` is step 3a's 64-bit reference, superseded by `mold_splitter` at
  CMAC width and kept because the two are diffed against the same golden; and
  `gt_gate` is the Phase B feasibility kernel, a control slave and four
  differential lane groups built to ask whether `v++` would wire a user kernel to
  `io_gt_qsfp0_00` before the MAC work was committed to. It is packaged as its own
  `.xo` ([step8-hw/gtgate](step8-hw/gtgate/)) rather than instantiated, and its GT
  pins are undriven on purpose.
- **The fast path has run on the card, in both phases.** Both bitstreams were
  rebuilt with `fast_bbo` and re-run on the real 5 M AAPL replay: 70/70 order
  frames byte-identical either way, `st_bbo_mismatch = 0` across 1.13 M frames,
  wire-to-wire 515.1 → 471.7 ns and in-fabric 206.7 → 166.7 ns at the minimum
  (`FINDINGS` §7.6.0). The load sweep has been re-run on it too, so the burst-tail
  figures above are the shipped datapath and not the ladder-only one: the floor is
  nine core cycles lower at *every* offered rate, the max grows 2.03× to 688.4 ns
  rather than 2.21× to 730 ns, and the saturation knee does not move at all —
  389,995 messages dropped at the same gap against the earlier build's 389,994
  (§7.5.1). The `NSYM = 2` half of that sweep was run with the fast path already
  in, so nothing in §7.5.1 is ladder-only now except the original single-symbol
  table, kept as the before-and-after.
- **Retransmission is automatic, and off by default.** `tx_rto` watches the
  acknowledgement number `tcp_rx` tracks and asks `tx_replay_buf` for the oldest
  unacknowledged frame when it stops advancing. It arms only after the venue has
  acknowledged something at least once, caps its attempts, counts both, and drives
  one pulse — the live stream is untouched and a replay only ever goes out when
  the path is idle. `cfg_rto_en` starts at 0, so a design that wants the old
  fire-and-forget behaviour has it. What is still not automatic is *policy*: the
  timeout and retry count are numbers a host writes, and no measurement here says
  what they should be on a real venue.
- **Multi-symbol has run on the card.**
  `NSYM` runs the whole chain, not just the table: one order table tags each
  delta with its book, a demux feeds `NSYM` price ladders, `bbo_arb` merges
  their streams back with a symbol tag, and the strategy's edge detector,
  latched BBO and position are per name while the in-flight limit stays shared
  — it counts orders on one TCP session, and the resource it limits is the wire,
  not the book. The OUCH Stock field is per symbol; nothing else in an Enter
  Order is. Verified two ways at `NSYM = 2`, both against the *single*-symbol
  goldens rather than one written beside the new RTL: two genuinely different
  books each reproduce their own locate's golden, and the same BBO log driven
  into both symbols reproduces the order golden twice over — the worst case for
  shared state, and confirmed sensitive by temporarily sharing the edge detector
  and watching symbol 1 fall to zero orders. Then on silicon: a Phase B
  bitstream at `NSYM = 2`, `OT_SETS_BITS = 14`, tracking AAPL and QQQ through
  the real 5 M replay. **AAPL's 70 orders are identical to the single-symbol
  golden**; QQQ produced 9,763 with **every price inside its own ladder band**
  — the check that would catch a book silently inheriting another's
  configuration; the two positions moved independently (+800 / −500); and
  `st_bbo_mismatch` and `st_bbo_arb_drop` were both zero across 90,397 BBO
  records. `NSYM = 1` is still what every *latency* figure in this README
  describes, and those are not comparable: a second book raises the order rate
  140×. Load-swept too, which located a cost the area numbers do not show —
  **the saturation knee moves from ~46.6 to ~40.9 M msg/s**, because the ladders
  are replicated but the order table is *shared* and admits every tracked
  symbol's inserts. Adding a name is nearly free in fMAX, costs 58 % in LUTs,
  and costs ~12 % of absorbable message rate; those are three separate budgets. The cost is measured post-route in both halves (`FINDINGS` §4.4). The
  books are free: replicating the ladder, fast-BBO tracker and sweep detector
  costs **+32,687 LUTs (+58 %)** and **no measurable fMAX** — 220.7 MHz best of
  four directive sets against 220.0 at one symbol, inside the spread. The table
  is not free: growing it to the 2¹⁴ × 16 a second name needs adds **+64 URAM**,
  and it used to leave **three of four builds missing timing** — the cascaded-URAM
  region that made the larger geometry unshippable in the first place. That has
  been fixed at two measured paths rather than worked around: capping the order
  table's URAM cascade at the depth the shipping geometry already uses, and fusing
  `fast_bbo`'s quantity update from two serial carry chains into one. **143 failing
  endpoints became 2**, and every directive now builds between 216.5 and
  219.8 MHz (`FINDINGS` §4.4.1). Neither fix costs a cycle. What is *not* claimed
  is four of four: two builds still miss the out-of-context yardstick by a
  picosecond, which says more about the yardstick than the design. `NSYM` and
  `OT_SETS_BITS` remain separate knobs that move together by hand, because the
  table still costs what it costs. The register map holds five symbols: 1–4 have a config block
  at `0x0C0`–`0x0FF` and positions at `0x180`–`0x18C`, while symbol 0 keeps the
  registers it always had, because moving it would repoint offsets that shipped.
- **All three flows build the same order table, and did not used to.**
  `otable_mem` selected between an XPM macro and a behavioural array on an
  `` `ifdef `` that reached exactly one of the three flows that compile it: step
  5's synthesis honoured it, while every simulation and the Vitis card build
  silently compiled the other branch. Both carried `ram_style="ultra"`, so the
  URAM count — the obvious check — was identical either way and could not tell
  them apart. There is one implementation now (`FINDINGS` §4.5), and the whole
  suite passes on it. The change also *cost* a property: the behavioural array
  came up X, which is what would have caught the order table's post-reset clear
  sweep being deleted, and XPM's model comes up zeroed instead. `step4a make
  test-clear` replaces the accident with a test.
- **Inbound is complete in simulation and has never met a real venue.** The
  acknowledgement number `tcp_tx` sends is live (`cfg_ack_num` is only the initial
  value from the handshake; hardware advances it as segments arrive), the session
  counters are in the register map, and the replies now reach the host: the
  frames `tcp_rx` keeps are merged into the same capture area the order frames
  use, and `scripts/dump_session.py` reassembles them by sequence number and
  decodes the OUCH. Verified both ways — HBM-to-HBM and through the MAC model —
  against generated replies, with the order frames byte-identical either way. What
  has not happened is a card run: nothing has answered these orders except a
  Python generator, and the QSFP cages are empty.
- **Retransmission policy is two guessed numbers, and the instrument for them is
  now built.** `cfg_rto_cycles` and `cfg_rto_retries` are the only values in this
  design chosen without measurement — the mechanism was decided on evidence, the
  constants were not — because what they need is the distribution of venue
  acknowledgement latency. `ack_latency` measures it in hardware off the two
  signals `tx_rto` already watches, publishes last/min/max/samples/sum/discarded
  at `0x198`–`0x1B0`, and reports **zero samples** under GT loopback rather than
  a plausible-looking zero. It is verified in both directions in the kernel
  simulation (`FINDINGS` §8) and is waiting for a counterparty, not for more
  simulation. The two constants are labelled as guesses wherever they appear.

### Signal

- **The imbalance signal predicts, and does not pay.** It has now had the
  forward-return treatment the sweep signal got, over the full day's regular
  hours (`data/FINDINGS.md` §5.3). Three of four resolved 1 ms moves continue in
  the direction the order was pointed — 75 % against 62 % for the population it is
  drawn from, ~7.7σ, and it holds at 10 ms and 100 ms. But the move is **+22.7**
  (0.23 cents) and entry costs half the spread, which at a one-tick threshold is
  **50** — so net of crossing the mean is **−27.3** and 23 % of events clear it.
  Tightening the ratio destroys it rather than concentrating it (mean +22.7 at
  4:1, **+0.3** at 16:1), which is the opposite of what the sweep does. The
  mechanism is real; the economics are not, for a taker. Calibration was fixed
  earlier (§5.2): the old 5 M slice was *entirely pre-market*, so the deployed
  `max_spread = 2000` selected nothing where AAPL's real regular-hours spread is
  3 cents. Test parameters stay as they are on purpose — the goldens run on that
  pre-market slice, where a tight threshold would never exercise the risk gates.
-->

## License

**GNU General Public License v3.0** — see [LICENSE](LICENSE). Copyright (c) 2026
jinsuklee. You may use, study, modify and redistribute this work; any derivative
you *distribute* must also be GPL-3.0 and ship its source. Running it privately,
including for trading, carries no obligation to publish anything.

Third-party components keep their own terms and are **not** covered by the above:

| Component | Terms |
|---|---|
| NASDAQ TotalView-ITCH data | NASDAQ's. Downloaded directly from them and **not redistributed here** — `data/*.gz` is deliberately not committed |
| ITCH 5.0, OUCH 4.2, SoupBinTCP 3.00 specifications | NASDAQ's. This repository implements them; it does not reproduce them |
| `cmac_usplus` | AMD/Xilinx IP, used under the licence AMD issues for it and not included here |
| AMD Vitis / Vivado, XRT, the U55C platform | AMD's, under their own licence terms |

The GPL covers this repository's own source. It does not and cannot relicense the
AMD IP a bitstream is built against, nor the exchange specifications the protocol
blocks implement.
