# HFT FPGA Tick-to-Trade — AMD Alveo U55C

A low-latency **tick-to-trade** pipeline in SystemVerilog RTL: NASDAQ **ITCH 5.0**
market data in off the wire, an order out to the exchange, entirely on the FPGA.

## Introduction

The FPGA parses the feed, maintains an L2 order book, runs two measured trading
signals, and assembles the OUCH / SoupBinTCP / TCP order frame — wire to wire,
with no host in the hot path. The software half owns only what is stateful and
not latency-critical: session login, heartbeats, acknowledgement feedback and
register configuration.

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
| Full chain post-route (out of context) | **220.0 MHz**, above the 195.3 MHz a 100 Gb/s wire demands |

Under load the floor never moves (23 core cycles, 107 ns), but from 25.1 to
40.6 M msg/s the mean grows 1.49× while the **max grows 2.21×, to 730 ns** —
quoting a mean for this design would mislead. Saturation is a knee rather than a
shoulder, between 40.6 and 46.3 M msg/s, which is 20–40× the real NASDAQ peak.
Every non-saturated point is byte-identical to the golden: the pipeline degrades
by **dropping and counting**, never by emitting a wrong order.

> Design rationale and per-step definition-of-done: [PLAN.md](PLAN.md).
> End-to-end data-path design: [ARCHITECTURE.md](ARCHITECTURE.md).
> The measurements behind every sizing decision: [data/FINDINGS.md](data/FINDINGS.md).

## Key Features

### Data path

```
        CMAC RX 322 MHz            core clock 215 MHz                          CMAC TX
QSFP28 ─► CMAC ─► cdc_fifo ─► eth/ip/udp ─► MoldUDP64 ─► ITCH ─► order ─► price ─► BBO
          100G   (clock       filter+strip   splitter    decode   table    ladder    │
                  crossing)    (step 5)       (step 3b)   (step 2) (step 4a)(step 4b) │
                                                              │                       ▼
                                        sweep_detect ◄────────┤              strategy (imbalance
                                        (momentum, step 6)    │               + sweep, risk gate)
                                                              ▼                       │
                          CMAC ◄─ cdc_fifo ◄─ tcp_tx ◄─ ouch_builder ◄────────────────┘
                          TX              (TCP/IP/Eth)  (OUCH 4.2 / SoupBinTCP)
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
- **Two signals, one risk gate.** Order-book imbalance, and sweep / momentum
  ignition. The sweep path taps the order-table delta and skips the ladder
  entirely — 19 core cycles against imbalance's 28.
- **Risk gate is not deferred**: kill switch, position limit, in-flight limit,
  each rejection counted separately so a quiet strategy is distinguishable from a
  blocked one.
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
| 4b | Top-of-book engine — price ladder (L2), BBO | Done — [step4b-book](step4b-book/) |
| 5 | U55C integration: Eth/IP/UDP RX, CDC, full-chain P&R | Done — [step5-board](step5-board/) |
| 6 | Strategy, risk gate, OUCH + SoupBinTCP + TCP transmit | Done — [step6-strategy](step6-strategy/) |
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

A `cmac_usplus` licence is required **only** to generate the Phase B bitstream.
AMD issues it at no cost. Synthesis, implementation and timing closure all work
without it; only `write_bitstream` is refused. `make gate-license` proves the
checkout in seconds rather than failing an hour into a build.

## Installation

```sh
git clone https://github.com/learningHWSW/hft-fpga.git
cd hft-fpga
```

**1. Locale for xsim (one time).** Vivado's launcher hard-codes
`LC_ALL=en_US.UTF-8`; where that locale is absent, xsim aborts with a
`std::locale` error. Build a user-local copy — no root needed:

```sh
scripts/setup-xsim-locale.sh          # creates ~/.locale/en_US.UTF-8
```

Each Makefile exports `LOCPATH` when that directory exists, so nothing else is
needed afterwards.

**2. Real market data (for the real-data replays).** The free NASDAQ
TotalView-ITCH full-day capture. It is not committed:

```sh
cd data && curl -O "https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/12302019.NASDAQ_ITCH50.gz"
```

3.5 GB compressed, ~269 M messages, 2019-12-30. Synthetic vectors are generated
by the testbenches and need no download, so the simulation suite runs without it.

**3. Xilinx tools.** No `source settings64.sh` needed for step 8 — its recipes
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
| 4a | `make test`, `make test-real-xsim` | order table == golden, zero overflow |
| 4b | `make test`, `make test-real-xsim` | BBO sequence == golden |
| 5 | `make test-t2t`, `make test-units-xsim` | the whole chain, two clocks, wire frames in |
| 6 | `make test-xsim`, `make test-replay` | orders and OUCH/TCP bytes == golden |
| 7 | `make test` | session, register map, two independent OUCH sessions |
| 8 | `make test-xsim`, `make test-b` | the Vitis kernel, HBM to HBM, and through the MAC |

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

Honest scope, all of it stated in the per-step READMEs:

- **Loopback is not a cable.** The wire-to-wire figure is measured with the GT in
  near-end PMA loopback: frames are 64b/66b encoded, serialized at 25.78125 Gb/s
  on four lanes, recovered, aligned and FCS-checked. That is the same
  `D + T_tx + T_rx` a real wire gives, but a cabled two-port measurement against
  a live feed is still the honest end state, and the QSFP cages here are empty.
- **The MAC is the larger half of the latency, and untouched.** ~207 ns in the
  fabric against **~300 ns** in MAC, SerDes and framing. It is close to
  irreducible: ~285 ns of it is inside `cmac_usplus` and the GT, already generated
  with RS-FEC and flow control off, and only ~9–12 ns of the term is ours. The
  only real lever is a thin custom PCS/MAC — a project, not an optimisation pass.
- **Split-sender TCP is gone rather than solved; inbound replaces it.** OUCH 4.2
  scopes order identity to *(account, token)* and binds each account to a physical
  port, so giving the card its own port deletes the sequence-coordination problem
  ([step7-host](step7-host/)). What still needs a card is the *inbound* direction:
  acks and fills arrive at the card's MAC, and the FPGA does not parse TCP.
- **Two modules are proven but not integrated.** `fast_bbo` answers 91 % of real
  book updates in one cycle instead of ten, never approximating; `tx_replay_buf`
  makes retransmission idempotent. Both have self-checking testbenches; neither is
  wired into `t2t_top`.
- **The strategy parameters are tuned on a thin reconstructed book**, not on real
  AAPL. They test the *mechanism*, not a tradeable edge, and would have to be
  re-derived from a full trading day before they meant anything about markets.
- **Shares range is not enforced in hardware.** OUCH requires
  `0 < shares < 1,000,000`; the design emits `min(resting, cfg_order_qty)` with no
  clamp, so it holds only by configuration.

## License

Copyright (c) 2026 jinsuklee. All rights reserved.

No licence is granted for this repository. It is published as a portfolio and
reference work: you are welcome to read it, and to cite or link to it, but use,
modification, redistribution and derivative works are not permitted without
written permission from the author.

Third-party components are not covered by the above and keep their own terms:

| Component | Terms |
|---|---|
| NASDAQ TotalView-ITCH data | NASDAQ's. Downloaded directly from them and **not redistributed here** — `data/*.gz` is deliberately not committed |
| ITCH 5.0, OUCH 4.2, SoupBinTCP 3.00 specifications | NASDAQ's. This repository implements them; it does not reproduce them |
| `cmac_usplus` | AMD/Xilinx IP, used under the licence AMD issues for it and not included here |
| AMD Vitis / Vivado, XRT, the U55C platform | AMD's, under their own licence terms |

If you want this code under an open-source licence, open an issue — the intent is
to keep it readable rather than to restrict it, and a permissive licence can be
added on request.
