# HFT FPGA Tick-to-Trade — AMD Alveo U55C

A low-latency **tick-to-trade** pipeline in SystemVerilog RTL: NASDAQ **ITCH 5.0**
market data in off the wire, an order out to the exchange, entirely on the FPGA.

## Introduction

The FPGA parses the feed, maintains an L2 order book, runs two measured trading
signals, and assembles the OUCH / SoupBinTCP / TCP order frame — wire to wire,
with no host in the hot path. The software half owns only what is stateful and
not latency-critical: session login, heartbeats, order-acknowledgement feedback
and register configuration.

Two commitments shape the whole project:

**Every stage is diffed against a software golden.** A C or Python reference
emits a canonical log, the self-checking testbench emits the same format, and the
Makefile diffs them. An empty diff is the only pass. The OUCH/TCP output is
checked a third time by an independent decoder, so a mistake shared by the RTL
and its golden cannot agree with itself unnoticed.

**Every design parameter is measured, not guessed.** FIFO depths, hash function,
table geometry, price-band width and the strategy thresholds all come from a real
full trading day of NASDAQ data ([`data/FINDINGS.md`](data/FINDINGS.md)), and
several of those measurements reversed the intuitive choice.

### Results on silicon

Measured on a real Alveo U55C, replaying a 5-million-message NASDAQ AAPL session:

| | |
|---|---|
| **Wire-to-wire, through a real 100 G MAC** | **518.2 ns** min / 579.4 ns mean, 70 samples |
| In-fabric only (first RX beat to first TX beat) | 206.7 ns min |
| Order frames vs. the software golden | **70 / 70 byte-identical**, zero drops |
| MAC frames passed | 1,127,130 with `rx_err=0 underrun=0 overflow=0` |
| Full chain post-route (out of context) | **225.5 MHz** best of four directive sets (221.7 worst), above the 195.3 MHz a 100 Gb/s wire demands |

Under load the floor never moves (23 core cycles, 107 ns), but from 25.1 to
40.6 M msg/s the mean grows 1.49× while the **max grows 2.21×, to 730 ns** —
quoting a mean for this design would mislead. Saturation is a knee rather than a
shoulder, between 40.6 and 46.3 M msg/s, which is 20–40× the real NASDAQ peak.
Every non-saturated point is byte-identical to the golden: the pipeline degrades
by **dropping and counting**, never by emitting a wrong order.

Every figure above was measured **before `fast_bbo` was wired in**, so it describes
the ladder-only book path. That path is still what a deferred delta takes; most
deltas now take a shorter one, and the order frames are unchanged either way. The
card has not been re-measured, and the MAC half — the larger half — cannot move.
This section used to add that the fast path costs 9.5 MHz of post-route frequency.
It does not: that was one build against one build, and across four implementation
directive sets per configuration the fast path is 3.0 MHz *faster* best-to-best
with a 5.3 MHz spread inside either — no measurable difference, and a 9.5 MHz
penalty excluded. Its real price is **+1.6 % LUTs and +2.1 % registers**
([FINDINGS §7.7](data/FINDINGS.md), [step4b-book](step4b-book/)).

> Design rationale and per-step definition-of-done: [PLAN.md](PLAN.md).
> End-to-end data-path design: [ARCHITECTURE.md](ARCHITECTURE.md).
> The measurements behind every sizing decision: [data/FINDINGS.md](data/FINDINGS.md).

## Key Features

### Data path

**RX — market data in.** The feed arrives on two lines and is filtered, stripped
and re-joined before a single message stream reaches the decoder.

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
                                                                            the ladder's records,
                                                                                   sooner
```

**TX — order out.** The order frame crosses back to the CMAC clock and wins
arbitration against the control traffic, so a membership report can never delay a
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

- **No backpressure to the wire.** Bursts are absorbed by FIFOs sized from
  measurement; overflow is dropped and counted. A market-data front end that
  stalls the MAC is a broken one.
- **Two clocks on purpose.** 512 bits at 322 MHz is 165 Gb/s of interface
  bandwidth for a 100 Gb/s wire, so the throughput floor is 12.5 GB/s ÷ 64 B =
  **195.3 MHz**. The core runs 215 MHz and joins the CMAC through dual-clock
  FIFOs on both sides.
- **Order table sized by measurement** — `hash(order_ref)` into 2¹³ × 16 URAM.
  A full trading day gives zero overflow, and an XOR fold beats a multiply-shift
  mixer at lower cost (`FINDINGS §4`).
- **Several symbols, one chain.** `NSYM` replicates everything a book belongs to
  — ladder, fast-BBO tracker, sweep detector, the strategy's edge state and
  position — and shares everything the *wire* belongs to: one order table, one
  TCP session, one in-flight budget. The delta stream is demultiplexed by symbol
  and the book streams merged back tagged, so K names cost K ladders' area but
  keep K ladders' throughput rather than sharing one. Each book's output is
  byte-identical to what a single-symbol build tracking that name alone emits.
- **Two signals, one risk gate.** Order-book imbalance, and sweep / momentum
  ignition. The sweep path taps the order-table delta and skips the ladder
  entirely — 19 core cycles against imbalance's 28. Only one of the two has a
  forward return that beats the cost of acting on it, and the measurements say
  which (`FINDINGS` §5, §5.3).
- **Most book updates skip the ladder scan too.** `fast_bbo` answers a delta from
  two registers when it can prove the answer (91 % of real deltas) and says "ask
  the ladder" when it cannot; `bbo_merge` rejoins the two so the record stream is
  the one the ladder alone would have produced — merged on value against a shared
  baseline, so the two change-detectors agree by construction. On the real replay
  that is **1,779 records, unchanged, 1,174 of them delivered ~10 cycles early,
  zero disagreements**. On the step-8 kernel's synthetic chain the loaded-latency
  probe's four samples move **33 → 24 core cycles** at the minimum, 51 → 47 mean.
- **Risk gate is not deferred**: kill switch, position limit, in-flight limit,
  and a shares-range check, each rejection counted separately so a quiet strategy
  is distinguishable from a blocked one — and every one of those counters is in
  the register map, so the distinction is one a host can actually make. That now
  holds for the wrapper as a whole: **all 32 of `t2t_top`'s status outputs are
  published, and none terminates in `t2t_axil`.** (Block-internal counters below
  that boundary — the feed arbiter's source split, `fast_bbo`'s own tallies —
  are still tied off where they are redundant with a published one.)
  `step7-host/tests/test_regmap.py` checks the host's list against the RTL read
  mux itself, so the two cannot drift apart quietly.
- **The order session is maintained on the card.** `tcp_tx` takes its
  acknowledgement number from `tcp_rx`, which advances it as the venue's segments
  arrive rather than reading a shadow register software has to keep fresh;
  `tx_replay_buf` keeps the last 16 assembled frames; and `tx_rto` re-sends the
  oldest of them when the acknowledgement stops moving, so a lost order is
  recovered in the fabric rather than after a host has read a capture buffer. A
  resend is idempotent twice over — same TCP sequence number, same OUCH token,
  which the venue is required to ignore — which is what makes it safe to do in
  hardware at all. Login, heartbeats and fill accounting stay software's.
- **Runs on real silicon** as a Vitis kernel, replaying from HBM, with a real
  `cmac_usplus` and the GT in near-end loopback so MAC, PCS and SerDes are inside
  the measurement.

### Roadmap

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

### Prerequisites

#### Hardware Requirements

| | |
|---|---|
| **Simulation only** | any x86-64 Linux host. No FPGA needed |
| **On silicon** | **AMD Alveo U55C** (UltraScale+ VU35P, HBM2 16 GB, QSFP28 ×2, PCIe Gen4) |
| Shell / platform | `xilinx_u55c_gen3x16_xdma_base_3` / `xilinx_u55c_gen3x16_xdma_3_202210_1` |
| Host for builds | ≥ 32 GB RAM (a bitstream link peaks near 20 GB); 32 cores keeps a link near 70 minutes |
| Disk | ~50 GB — the ITCH capture is 3.5 GB compressed, and Vitis temp directories reach 1.4 GB per build |
| Optics | **not required.** The 100 G measurement uses the GT in near-end PMA loopback |

#### Software Requirements

| | Version used | Notes |
|---|---|---|
| Vivado / Vitis | **2025.2.1** | provides `vivado`, `v++`, `xvlog`, `xelab`, `xsim` |
| XRT | 2.18.179 (2024.2) | only for running on the card |
| Python | 3.8+ | goldens and packing scripts; standard library only |
| GCC | C++17 | host runner and the step-1 C model |
| Verilator | 5.036 | **optional** — a no-Vivado fallback for most testbenches |
| OS | Ubuntu 22.04, kernel 5.15 | the machine this was measured on |
| Locale | `en_US.UTF-8` present | Vivado's launcher hard-codes it; if absent, xsim aborts with a `std::locale` error. `sudo locale-gen en_US.UTF-8` |

A `cmac_usplus` licence is required **only** to generate the Phase B bitstream.
AMD issues it at no cost. Synthesis, implementation and timing closure all work
without it; only `write_bitstream` is refused. `make gate-license` proves the
checkout in seconds rather than failing an hour into a build.

## Installation

```sh
git clone https://github.com/learningHWSW/hft-fpga.git
cd hft-fpga
```

**1. Real market data (for the real-data replays).** The free NASDAQ
TotalView-ITCH full-day capture. It is not committed:

```sh
cd data && curl -O "https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/12302019.NASDAQ_ITCH50.gz"
```

3.5 GB compressed, ~269 M messages, 2019-12-30. Synthetic vectors are generated
by the testbenches and need no download, so the simulation suite runs without it.

**2. Xilinx tools.** No `source settings64.sh` needed for step 8 — its recipes
source it themselves. Override the install with
`XILINX_SETTINGS=/path/to/settings64.sh`, and check what will actually be used
with `make which-tools`. Earlier steps expect the tools already on `PATH`.

## Compilation and execution

### Simulation

Every step's `make test` regenerates its software golden, runs the RTL, and
passes only if the two logs are byte-identical.

```sh
cd step4b-book && make test            # xsim (primary)
cd step4b-book && make test-verilator  # Verilator (no Vivado)
```

| Step | Command | What it proves |
|---|---|---|
| 1 | `make test` | the C golden parses a real day self-consistently |
| 2 | `make test` | ITCH decode == golden |
| 3a / 3b | `make test`, `make test-real-xsim` | MoldUDP64 strip and 512-bit realignment |
| 4a | `make test`, `make test-real-xsim`, `make test-multi` | order table == golden, zero overflow, and two symbols share one table |
| 4b | `make test`, `make test-real-xsim`, `make test-merge-xsim` | BBO sequence == golden, and the fast/slow rejoin preserves it |
| 5 | `make test-t2t`, `make test-units-xsim`, `make test-tcprx`, `make test-msym` | the whole chain, two clocks, wire frames in and session frames back, and two tracked books each reproducing its own single-symbol golden |
| 6 | `make test-xsim`, `make test-replay`, `make test-rto`, `make test-msym` | orders and OUCH/TCP bytes == golden, when a resend is decided, and that no per-book strategy state is shared between symbols |
| 7 | `make test` | session, register map, two independent OUCH sessions |
| 8 | `make test-xsim`, `make test-b`, `make test-session`, `make test-rto`, `make test-real` | the Vitis kernel, HBM to HBM, through the MAC, the venue's replies back to the host, the card re-sending an unacknowledged order, and the real feed as far as the memory model holds |

### Synthesis and place & route

```sh
cd step5-board
make synth-t2t          # out-of-context synthesis of the full chain
make impl-t2t           # place & route for xcu55c-fsvh2892-2L-e
```

### Building for the card

```sh
cd step8-hw
make help               # every target, grouped, with what each costs

make cmac               # generate the cmac_usplus IP (once, Phase B only)
make gate-license       # prove the licence before spending an hour
make xclbin             # Phase A -> t2t.xclbin     (~1 h 10 m)
make xclbin-b           # Phase B -> t2t_b.xclbin   (~1 h 15 m)
```

### Running on the card

```sh
source /opt/xilinx/xrt/setup.sh

make run-card-real      # Phase A, real 5 M AAPL replay
make run-card-b-real    # Phase B, the same replay through the real MAC
```

Both diff the captured order frames against the golden and print `PASS` only on
a byte-identical match. `RGAP=<n>` varies the injector spacing to sweep offered
load; the saturation knee is between `RGAP=24` and `RGAP=16`.

### Cleaning

Three tiers, because they cost very different amounts to undo:

```sh
make clean          # logs, sim scratch, small captures      (seconds)
make clean-build    # + packaged kernels, .xo, v++ temp dirs (minutes)
make distclean      # + bitstreams, ip/, replay image        (HOURS — asks first)
```

## What is not done

Honest scope, all of it stated in the per-step READMEs.

### Measurement

- **Loopback is not a cable.** The wire-to-wire figure is measured with the GT in
  near-end PMA loopback: frames are 64b/66b encoded, serialized at 25.78125 Gb/s
  on four lanes, recovered, aligned and FCS-checked. That is the same
  `D + T_tx + T_rx` a real wire gives, but a cabled two-port measurement against a
  live feed is still the honest end state, and the QSFP cages here are empty.
- **Post-route frequency is only sweep-backed at one design point.** The fMAX
  figures here are the best of four implementation directive sets, because one
  build against one build cannot measure place & route — that lesson cost a
  wrong claim in this README, which asserted a 9.5 MHz penalty for `fast_bbo`
  that a sweep does not reproduce and attributed it to a specific carry chain
  that is not critical in any of the eight builds (`FINDINGS` §7.7). What is
  swept is `NSYM = 1`, both `USE_FAST_BBO` settings. `NSYM = 2` has been
  synthesised but not placed and routed, so its area cost is measured and its
  timing cost is not — and by the standard this project now holds itself to,
  that means no timing claim is made about it at all.
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
  the ladder already does. Setting aside the design tops (`t2t_kernel`,
  `t2t_kernel_b`), the only module with a testbench and no instantiation is
  `mold_stripper`, and that is on purpose — it is step 3a's 64-bit reference,
  superseded by `mold_splitter` at CMAC width and kept because the two are
  diffed against the same golden.
- **The fast path has not run on the card.** Its evidence is simulation: the BBO
  sequence over the real 5 M replay, and the order frames HBM-to-HBM and through
  the MAC model. What a card run would now say for itself is readable —
  `st_bbo_mismatch` counts the one thing that could break quietly (`fast_bbo`
  certain and wrong) and is in the register map, printed by `t2t_run` and a
  failing condition for the run — but nobody has taken that run.
- **Retransmission is automatic, and off by default.** `tx_rto` watches the
  acknowledgement number `tcp_rx` tracks and asks `tx_replay_buf` for the oldest
  unacknowledged frame when it stops advancing. It arms only after the venue has
  acknowledged something at least once, caps its attempts, counts both, and drives
  one pulse — the live stream is untouched and a replay only ever goes out when
  the path is idle. `cfg_rto_en` starts at 0, so a design that wants the old
  fire-and-forget behaviour has it. What is still not automatic is *policy*: the
  timeout and retry count are numbers a host writes, and no measurement here says
  what they should be on a real venue.
- **Multi-symbol is wired end to end and has never been built for the card.**
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
  and watching symbol 1 fall to zero orders. What has not happened is a
  bitstream. `NSYM = 1` is what every card measurement in this README describes,
  and both halves of the cost are measured (`FINDINGS` §4.4): a second symbol is
  **+32,687 LUTs (+58 %) and +2 DSP** with no BRAM change, and the table it
  feeds has to grow from 64 URAM to 128, because 2¹³ × 16 holds exactly one
  name. Four symbols would be ~12 % of the device's LUTs. The register map holds
  five: symbols 1–4 have a config block at `0x0C0`–`0x0FF` and positions at
  `0x180`–`0x18C`, while symbol 0 keeps the registers it always had, because
  moving it would repoint offsets that shipped. A real multi-symbol build is a
  sizing decision now, not a rebuild.
- **The multi-symbol tests are xsim-only.** Every other stage has both an xsim
  and a Verilator path, deliberately — the two disagree about races, and one
  such disagreement (a testbench driving stimulus on the sampling edge) was
  caught precisely because both were run. `test-msym` in steps 5 and 6 has no
  Verilator twin yet, so that particular cross-check is not protecting the
  newest RTL.
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

## License

This project is licensed under the **GNU General Public License v3.0** — see
[LICENSE](LICENSE) for the full text.

Copyright (c) 2026 jinsuklee

In short: you may use, study, modify and redistribute this work, and any
derivative you *distribute* must also be GPL-3.0 and ship its source. Running it
privately, including for trading, carries no obligation to publish anything. The
licence also grants patent rights from contributors, which matters more here than
in most projects.

Third-party components are **not** covered by the above and keep their own terms:

| Component | Terms |
|---|---|
| NASDAQ TotalView-ITCH data | NASDAQ's. Downloaded directly from them and **not redistributed here** — `data/*.gz` is deliberately not committed |
| ITCH 5.0, OUCH 4.2, SoupBinTCP 3.00 specifications | NASDAQ's. This repository implements them; it does not reproduce them |
| `cmac_usplus` | AMD/Xilinx IP, used under the licence AMD issues for it and not included here |
| AMD Vitis / Vivado, XRT, the U55C platform | AMD's, under their own licence terms |

Note that the GPL covers this repository's own source. It does not and cannot
relicense the AMD IP a bitstream is built against, nor the exchange
specifications the protocol blocks implement.
