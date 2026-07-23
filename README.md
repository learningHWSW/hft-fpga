# HFT FPGA Tick-to-Trade — AMD Alveo U55C

A low-latency **tick-to-trade** pipeline in SystemVerilog RTL: NASDAQ **ITCH
5.0** market data in off the wire, an order out to the exchange. It parses the
feed, maintains an L2 order book, runs two measured trading signals, and
assembles the OUCH/SoupBinTCP/TCP order frame — all on the FPGA, wire to wire.
Every stage is verified by a self-checking testbench whose canonical log is
diffed against a software golden model, and every design parameter is chosen
from measurements on a real full trading day of NASDAQ data — not guesswork.

**The whole chain closes timing on the real U55C part at 220.0 MHz post-route**,
above the 195.3 MHz that a 100 Gb/s wire demands at 512-bit width. It is
verified functionally against the golden, but has **not** run on a physical
card — this machine has the part and toolchain but no Alveo, so measured
MAC-to-order latency is future work.

Target board: **Alveo U55C** (UltraScale+ VU35P, HBM2 16 GB, QSFP28 ×2 for
100 GbE, PCIe Gen4). The QSFP cages are on the card, so the FPGA can receive
multicast market data directly off the wire instead of going through a host NIC
— the long-term goal that motivates the whole pipeline.

> Design rationale and per-step DoD live in [PLAN.md](PLAN.md). The end-to-end
> data-path design is in [ARCHITECTURE.md](ARCHITECTURE.md). Measurement results
> that drove the sizing decisions are in [data/FINDINGS.md](data/FINDINGS.md).

## Roadmap

| Step | Content | Status |
|---|---|---|
| 1  | ITCH 5.0 software reference parser (golden model) | ✅ [step1-sw-parser](step1-sw-parser/) |
| 2  | SystemVerilog ITCH decoder + self-checking TB | ✅ [step2-rtl-decoder](step2-rtl-decoder/) |
| 3a | MoldUDP64 stripper + message splitter (64-bit, sequence-gap detect) | ✅ [step3a-mold-stripper](step3a-mold-stripper/) |
| 3b | 512-bit (CMAC width) realignment — multiple message boundaries per beat | ✅ [step3b-splitter](step3b-splitter/) |
| 4a | Order table — order_ref hash (URAM), size/ways from real data | ✅ [step4a-order-table](step4a-order-table/) |
| 4b | Top-of-book engine — price ladder (L2), BBO | ✅ [step4b-book](step4b-book/) |
| 5  | U55C integration: Eth/IP/UDP RX, CDC to the CMAC clock, full-chain synth + P&R | ✅ [step5-board](step5-board/) |
| 6  | Strategy (imbalance + sweep), risk gate, OUCH + SoupBinTCP + TCP transmit | ✅ [step6-strategy](step6-strategy/) |
| 7  | Host software — SoupBinTCP session, register config, ack/fill feedback | ✅ [step7-host](step7-host/) |

All steps are complete and pass on xsim and Verilator, on synthetic vectors and
a real NASDAQ trading day. The full chain (`t2t_top`) is integrated, verified
end to end, and taken through real Vivado synthesis and place & route for the
`xcu55c-fsvh2892-2L-e` part.

## Data path

```
        CMAC RX 322 MHz            core clock (~220 MHz)                              CMAC TX
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

**Two clocks on purpose.** The core does not run at the CMAC's 322.265625 MHz
and does not need to: 512 bits at 322 MHz is 165 Gb/s of interface bandwidth for
a 100 Gb/s wire, so the throughput floor is 12.5 GB/s ÷ 64 B = **195.3 MHz**. The
core measures 220 MHz post-route and is joined to the CMAC by a dual-clock FIFO
(`cdc_fifo`) on both the receive and transmit sides.

The market-data path never applies backpressure to the wire: bursts are
absorbed by FIFOs (sized from measurement), and overflow is dropped and
counted. See [ARCHITECTURE.md](ARCHITECTURE.md).

## Results on the real part

Full chain, `xcu55c-fsvh2892-2L-e`, post-route (core 4.618 ns / CMAC 3.103 ns):

| | |
|---|---|
| core_clk | **220.0 MHz** (WNS +0.072 ns) — clears the 195.3 MHz line-rate floor |
| cmac_clk | meets 322.265625 MHz (WNS +0.330 ns) |
| CLB LUTs / registers | 44,908 / 17,617 (~3.4 % / 0.7 %) |
| URAM / BRAM / DSP | 66 / 32 / 2 |
| all timing constraints | **met** |

The order table is the measured 2^13 × 16 design point (full trading day, zero
overflow), instantiated as URAM. Getting here meant closing timing through a
cluster of ~160 MHz paths in the book engine — the decisive fix was splitting
the price ladder's read-modify-write, worth +65 MHz where earlier register
stages bought only single digits. The path there is documented candidly in
[step5-board/README.md](step5-board/README.md), missed predictions included.

## Trading signals (measured, then built)

Two signals share one risk gate (position limit, in-flight limit, kill switch):

- **Order-book imbalance** — resting size heavily on one side with a tight
  spread, a taker into the imminent move.
- **Sweep / momentum ignition** — an aggressive order walking one side of the
  book across several levels. Measured on a real 40 M-message slice before any
  RTL: ≥3-level sweeps continue in their direction ~75 % of the time over the
  next millisecond, and bigger sweeps continue harder (`data/FINDINGS.md §5`).

Both fire orders all the way to a TCP frame, verified bit-exact against the
golden ([step6-strategy](step6-strategy/)). The parameters are tuned on a thin
reconstructed book, so they test the *mechanism*, not a tradeable edge — the
honest caveat is kept front and center in the step-6 README.

## Toolchain

xsim (Vivado 2025.2) is the primary flow; Verilator 5.036 is a no-Vivado
fallback. Each step directory has both:

```sh
source /opt/Xilinx/2025.2/Vivado/settings64.sh
cd step4b-book && make test              # xsim
cd step4b-book && make test-verilator    # Verilator
```

Every step's `make test` regenerates its software golden, runs the RTL, and
passes only if the RTL log and the golden are byte-identical. Real-data replays
are available where relevant via `make test-real` (Verilator) /
`make test-real-xsim`.

### WSL note (one-time)

Vivado's launcher hard-codes `LC_ALL=en_US.UTF-8`, a locale this WSL image does
not ship, so xsim aborts with a `std::locale` error. Build a user-local copy of
that locale once (no root needed):

```sh
scripts/setup-xsim-locale.sh     # creates ~/.locale/en_US.UTF-8
```

`~/.bashrc` and each Makefile export `LOCPATH=$HOME/.locale`, so after running
the script once, `make test` works.

## Real data

The measurements and real-data replays use the free NASDAQ TotalView-ITCH
full-day capture (2019-12-30, ~3.5 GB gz, ~269 M messages). It is not committed;
download it into `data/`:

```sh
cd data && curl -O "https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/12302019.NASDAQ_ITCH50.gz"
```

## Verification philosophy

- **One golden per stage.** A C or Python reference produces a canonical log; the
  self-checking SV testbench emits the same format; the Makefile diffs them.
- **Measure, don't guess.** FIFO depths, hash function, table size and
  associativity, and price-band width are all chosen from measured statistics of
  a real trading day (`data/FINDINGS.md`), and re-confirmed by the RTL replays.
- **Real data closes the loop.** The order-book chain is replayed against a real
  AAPL session and its BBO sequence is cross-checked to the independent step-1 C
  model, byte for byte. The strategy's OUCH/TCP output is checked the same way,
  and re-derived a third time by scapy so an author's mistake in the golden and
  the RTL cannot agree with itself.
- **The whole chain, not just the parts.** `t2t_top` is executed end to end
  (wire frames in, order frames out) with two incommensurate clocks, because
  synthesis will happily wire two correct blocks together wrongly.

## What is not done

Honest scope, all of it stated in the step READMEs:

- **No physical card.** Simulation gives exact cycle counts; nanoseconds on
  silicon need an Alveo in a slot. No latency number here is measured hardware.
- **Split-sender TCP is modelled, not solved.** The host session, register
  config, login/heartbeat and ack/fill feedback are built and tested
  ([step7-host](step7-host/)), including decoding the FPGA's real OUCH bytes with
  an independent implementation. What still needs a card: on hardware the FPGA
  and host are two senders on one TCP connection, so their sequence numbers must
  be coordinated and inbound segments forwarded — the host owns the socket in the
  test instead.
- **No retransmission** in the transmit path (fire-and-forget), and the OUCH
  enum codes are placeholders to confirm against the current NASDAQ spec.

Per-step READMEs (Korean) carry the detailed design notes for each block.
