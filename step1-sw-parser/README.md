# Step 1 — ITCH 5.0 software reference parser (golden model)

A golden model to learn the protocol by hand before building the SystemVerilog
decoder (step 2), and then to produce the expected values for the cocotb
testbenches that follow.

## Build / test

```sh
make test          # generate synthetic data + run the parser
```

- `gen_itch.py` — generate a synthetic ITCH file from a known scenario (the
  expected BBO sequence is in a comment at the top of the file). Also used as the
  stimulus for the step-2 TB.
  - With `--mold test.mold` it also emits the same scenario as a **MoldUDP64
    packet stream** (for the step-3a stripper). Includes two heartbeats, a
    2-message sequence gap (only MSFT noise is lost, so the AAPL BBO is
    unchanged), and End-of-Session. File format: a 2-byte BE length prefix per
    UDP payload. See the comment at the top of the script for the packet plan.
    Right after generation it must pass a self-check (re-parse, sequence
    continuity, gap size) before the file is written.
- `itch_parser.c` — the parser + a single-symbol top-of-book. Prints whenever the
  BBO changes.
- `itch5.h` — the message size/offset table. **The file that step 2 carries over
  verbatim into a SystemVerilog package.**

## Running on real data

NASDAQ publishes a real full-day capture for free (5–6 GB compressed, 10 GB+
uncompressed):

```sh
# find the filename at https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/ , then
wget https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/<date>.NASDAQ_ITCH50.gz
./itch_parser <date>.NASDAQ_ITCH50.gz AAPL 1000000 > bbo.log   # first 1M messages only
```

A full day is on the order of 300–400M messages. Note the message-type
distribution and the software throughput (M msg/s) from the stats on stderr —
it becomes the baseline against the FPGA.

## What the protocol confirms -> RTL design points

1. **Every message is fixed length, and the length is decided by the first
   (type) byte.** -> the RTL decoder knows the remaining length the moment it
   sees the type byte. The state machine is simple, and only boundary
   realignment needs handling.

2. **Every field is big-endian, byte aligned.** -> field extraction is pure
   byte-lane select. No multiplies/shifts.

3. **The symbol filter is a 2-byte stock locate, not an 8-byte symbol compare.**
   The locate is in the header (offset 1), the same position in every message.
   -> in hardware, put the subscribed symbols' locates in a small CAM/LUT and
   early-drop looking only at the header. Learn the locate from the 'R'
   (directory) message.

4. **E/X/D/U messages have no price or side** — the resting order must be found
   by its order reference. -> an order table (hash -> URAM/HBM on the U55C) is
   mandatory in RTL, and this is the real difficulty of the feed handler. This
   parser's open-addressing hash is that reference implementation.

5. **'U' (replace) inherits the original order's side/stock**, and 'C' (exec
   with price) executes at the message's price but **leaves the book at the
   original order's display price**. These corner cases become RTL verification
   items.

6. **File framing (a 2-byte length prefix) differs from wire framing
   (MoldUDP64).** The real receive path is: Ethernet -> IP -> UDP -> MoldUDP64
   header (session 10 B + seq 8 B + count 2 B) -> [len(2) + msg] × count.
   -> the RTL pipeline needs one more MoldUDP64 stripper stage, and
   sequence-number gap detection (packet loss -> snapshot/re-request) happens
   there too.

## Next (step 2)

In a cocotb + Verilator environment:
1. `itch5.h` -> `itch5_pkg.sv` (type/size/offset constants)
2. An ITCH decoder module taking an AXI-Stream input (64-bit @ ~322 MHz, or
   512-bit for the U55C's 100G path) — extract per-type fields in parallel and
   emit them on an internal struct bus
3. Diff this parser's output (BBO log) against the RTL simulation output
