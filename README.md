# HFT FPGA Tick-to-Trade — AMD Alveo U55C

A low-latency **tick-to-trade** pipeline in SystemVerilog RTL: NASDAQ **ITCH
5.0** market data in off the wire, an order out to the exchange. It parses the
feed, maintains an L2 order book, runs two measured trading signals, and
assembles the OUCH/SoupBinTCP/TCP order frame — all on the FPGA, wire to wire.
Every stage is verified by a self-checking testbench whose canonical log is
diffed against a software golden model, and every design parameter is chosen
from measurements on a real full trading day of NASDAQ data — not guesswork.

**The whole chain closes timing on the real U55C part at 220.0 MHz post-route**,
above the 195.3 MHz that a 100 Gb/s wire demands at 512-bit width, and it is
verified functionally against the golden at every stage.

**It now runs on a real Alveo U55C** ([step 8](step8-hw/)). A 5-million-message
NASDAQ AAPL session replayed from HBM on the card produces **70 order frames
byte-identical to the software golden**, with zero drops anywhere in the chain, and
the measured wire-to-order latency is **220 ns minimum, 281 ns mean** over 70
attributable samples. The QSFP cages on this machine are empty, so that run
replayed the feed from device memory rather than taking it off the wire.

**And it now runs through a real 100 G MAC.** The `cmac_usplus` build loads, its
link comes up in GT near-end PMA loopback with no optics attached, and the same
5 M-message replay passes **1,127,130 frames through the MAC with zero receive
errors, underruns or overflows**, producing the same 70 order frames
byte-identical to the golden. That puts MAC, PCS and SerDes inside the
measurement and gives the project its first **wire-to-wire** figure:
**515.1 ns minimum, 579.1 ns mean** over 70 attributable samples.

**The burst tail is measured too, on the card, not modelled.** Sweeping offered
load across the same 5 M-message replay, the floor never moves — 23 core cycles,
107 ns, at every point — but from 25.1 to 40.6 M msg/s the mean grows 1.49× while
the **max grows 2.21×, to 730 ns**, and that divergence is the tail: quoting a
mean for this design would be misleading. Saturation is a knee rather than a
shoulder, between 40.6 and 46.3 M msg/s, which is 20–40× the real NASDAQ peak the
design was sized against. Every non-saturated point is byte-identical to the
golden, so the pipeline degrades by dropping and counting and has no regime in
which it emits a wrong order (`data/FINDINGS.md` §7.5).

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
| 1  | ITCH 5.0 software reference parser (golden model) | Done — [step1-sw-parser](step1-sw-parser/) |
| 2  | SystemVerilog ITCH decoder + self-checking TB | Done — [step2-rtl-decoder](step2-rtl-decoder/) |
| 3a | MoldUDP64 stripper + message splitter (64-bit, sequence-gap detect) | Done — [step3a-mold-stripper](step3a-mold-stripper/) |
| 3b | 512-bit (CMAC width) realignment — multiple message boundaries per beat | Done — [step3b-splitter](step3b-splitter/) |
| 4a | Order table — order_ref hash (URAM), size/ways from real data | Done — [step4a-order-table](step4a-order-table/) |
| 4b | Top-of-book engine — price ladder (L2), BBO | Done — [step4b-book](step4b-book/) |
| 5  | U55C integration: Eth/IP/UDP RX, CDC to the CMAC clock, full-chain synth + P&R | Done — [step5-board](step5-board/) |
| 6  | Strategy (imbalance + sweep), risk gate, OUCH + SoupBinTCP + TCP transmit | Done — [step6-strategy](step6-strategy/) |
| 7  | Host software — SoupBinTCP session, register config, ack/fill feedback | Done — [step7-host](step7-host/) |
| 8  | **On real silicon** — Vitis kernel on an Alveo U55C, replay from HBM, measured latency | In progress — [step8-hw](step8-hw/) |

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

- **Loopback is not a cable.** The wire-to-wire figure is measured with the GT in
  near-end PMA loopback, which needs no optics: frames are 64b/66b encoded,
  serialized at 25.78125 Gb/s on four lanes, recovered, aligned and FCS-checked
  before reaching the datapath. Because the loopback returns what we transmit,
  it measures `D + T_tx + T_rx` — the same three terms as true wire-to-wire, but
  overcounting by the SerDes round trip inside the GT. A cabled two-port
  measurement against a real feed source is still the honest end state, and the
  QSFP cages on this machine are empty.
- **The MAC is now the larger half of the latency, and it is not yet attacked.**
  Running both bitstreams back to back on identical stimulus puts ~207 ns in the
  fabric and **~300 ns in the MAC, SerDes, store-and-forward fill and frame
  filter**. Simulation had predicted ~145 ns for that term and was wrong by a
  factor of two, which is exactly what a hard-coded `MAC_LAT` constant is worth.
  It is also close to irreducible: **~285 ns of it is inside `cmac_usplus` and
  the GT**, which are already generated with the low-latency options (RS-FEC off,
  flow control off, statistics off) and whose RX path is cut-through by design.
  Our own contribution is ~9–12 ns, about 2 % of the path, and recovering the
  largest piece of it would mean reintroducing the MAC underrun the
  store-and-forward FIFO exists to prevent (`data/FINDINGS.md` §7.6.1). The only
  real lever is a thin custom PCS/MAC in place of the vendor one — a project, not
  an optimisation pass.
- **The loaded and unloaded latencies are different intervals — now composable,
  still not one number.** The burst tail probe reports *decoder-to-order* while
  the wire figure is *first-RX-beat to first-TX-beat*, because excluding the
  non-queueing front end is what lets the tail be measured without threading a tag
  through every stage. Both probes report from the same run, so the constant
  between them is now measured rather than assumed: **99.7 ns** of fixed front and
  back end (`data/FINDINGS.md` §7.5.2). Wire-to-order under load is the tail plus
  that constant. A single probe spanning the whole path under load would still be
  better, and would cost the tag-threading this design was built to avoid.
- **Split-sender TCP is gone rather than solved; the inbound path replaces it as
  the open item.** OUCH 4.2 binds each physical port to its own logical account
  and scopes order identity to *(account, token)*, so the card gets its own port
  and is the only sender on that byte stream. No sequence coordination, no
  forwarding, and no shared token space — the tests prove the last of those by
  sending the same token on two accounts and getting two distinct orders
  ([step7-host](step7-host/)). The cost is provisioning: a second account has to
  be obtained, since NASDAQ assigns them. **What still needs a card** is the
  *inbound* direction on the card's own connection — acks and fills arrive at the
  card's MAC and the FPGA does not parse TCP, so reaching the host with them is
  unsolved.
- **Retransmission is built and proven, but not wired in.** The transmit path is
  still fire-and-forget end to end. The spec made this far cheaper than expected:
  client-to-host messages are explicitly designed to be "benignly resent", and an
  Enter Order carrying a previously used token is *ignored* by the venue, so a
  replay buffer cannot double-fill and needs no dedup protocol — only that the
  original token is preserved. `tx_replay_buf.sv` does that by storing the
  assembled frame rather than the order intent (re-deriving one would mint a new
  token and a new TCP sequence number), adds no latency to the live path, and is
  bounded by the risk gate's in-flight limit. `make test-replay` checks those
  properties directly. What is missing is the integration into `t2t_top` and its
  control register.
- **The OUCH codes are checked against the spec, and one was changed.** Every
  offset and enum is verified against O*U*C*H 4.2 (updated October 2025): the
  layout is exact and every code is legal, so the "placeholder" caveat is retired
  ([step6-strategy](step6-strategy/)). The check surfaced that `Display = "Y"`
  means *Anonymous-Price to Comply* rather than "yes, display" — a legal code
  with different semantics, which a golden that agrees with itself can never
  catch. It is now **`"A"`, Attributable-Price to Display**. Still open: the
  spec's `0 < shares < 1,000,000` range is not enforced in hardware.

Per-step READMEs (Korean) carry the detailed design notes for each block.
