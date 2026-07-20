# HFT FPGA Feed Handler — AMD Alveo U55C

A low-latency NASDAQ **ITCH 5.0** feed handler that parses the market-data wire
and maintains top-of-book, built in SystemVerilog RTL. Every stage is verified
by a self-checking testbench whose canonical log is diffed against a software
golden model, and every design parameter is chosen from measurements on a real
full trading day of NASDAQ data — not guesswork.

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
| 5  | U55C board: CMAC(100G)+UDP/IP RX, QDMA reporting, measured latency | planned |
| 6  | (stretch) OUCH order entry — session in SW, hot-path assembly in FPGA | planned |

Steps 1–4b (the full parse → order-book core) are complete and pass on both
xsim and Verilator, on synthetic vectors and on a real NASDAQ trading day.

## Data path

```
QSFP28 ─► CMAC(100G) ─► eth/ip/udp ─► MoldUDP64 splitter ─► ITCH decoder ─► order table ─► price ladder ─► BBO
            512b@322M     (step 5)      (step 3a/3b)          (step 2)       (step 4a)       (step 4b)
                                        seq-gap detect       field extract   ref→{px,qty}    L2 book
```

The market-data path never applies backpressure to the wire: bursts are
absorbed by FIFOs (sized from measurement), and overflow is dropped and
counted. See [ARCHITECTURE.md](ARCHITECTURE.md).

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
  model, byte for byte.

Per-step READMEs (Korean) carry the detailed design notes for each block.
