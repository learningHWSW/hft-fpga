# Step 4a — order table (order_ref reverse lookup)

The second technical core of this project. ITCH's E/C/X/D/U messages carry only
an `order_ref`, so updating the book requires reversing `order_ref -> {locate,
side, price, qty}` in O(1). This table does that reverse lookup and, per message,
emits the price levels the book will move on as a book delta (the input to step
4b's price ladder).

## Run

```sh
make test              # xsim, synthetic test.itch (all types A/F/E/C/X/D/U), AAPL locate 1
make test-verilator    # Verilator, same
make test-real         # real data 500k slice, AAPL locate 13 (Verilator)
make test-real-xsim    # the above, xsim
```

The golden is `scripts/dump_book.py` (exact map). An empty diff against the RTL's
book-delta log is PASS. The TB additionally checks **0 drops** (the table is
always ready in time) and **0 overflow** (sized to the symbol).

## Design (measurement-based, data/FINDINGS.md §4)

- **d-way set-associative, mixing hash**: for the all-symbols aggregate, monotonic
  refs round-robin so the raw low bits suffice, but **filtering to one symbol
  makes that symbol's ref subset cluster in the low bits** (raw 16b×4 = 24142
  overflows vs mix = 132). So the filter table uses a multiply-shift mixing hash —
  a measured result that is the exact opposite of the all-symbols case.
- **URAM-resident via the symbol filter**: A/F enter only when their locate equals
  `track_locate`. E/C/X/D/U look up by ref — if stored, it is a tracked symbol.
  The all-symbols table is 8M+ entries (HBM territory), but filtering the symbol
  puts it in URAM.
- **Adopted size**: `2^16 sets × 8-way + mix` = 524K slots. AAPL peak 27K -> load
  ~5%. The full-day AAPL filter measurement confirms **0 overflow** (FINDINGS
  §4.2). ~10 MB URAM. The cheaper alternative `16b×4 mix` (~5 MB) drops 132 deep
  orders over the day (negligible BBO impact).
- **book-delta output**: per message, `rem` (the level to subtract: D/E/C/X, and
  U's old) + `add` (the level to increase: A/F, and U's new). Only U touches two
  levels; the rest touch one. side/locate are inherited from the looked-up
  original order (matching the golden down to U's side inheritance and C
  subtracting at the stored display price, not the execution price).

## Status / performance

- xsim (Vivado 2025.2): synthetic test.itch PASS (10 records, all types), real
  data 500k AAPL slice PASS.
- Verilator: synthetic PASS, real data **5M AAPL slice PASS** (6740 records —
  including real A/F/E/X/D/U, 0 drops, 0 overflow, miss = lookups for other
  symbols).
- **Correctness-first FSM**: after IDLE accept, one cycle per set access -> simple
  ops 2 cy/msg, U 3 cy/msg. The 2-cycle spacing + same-cycle NBA writeback make
  the same-set hazard between messages disappear without forwarding. On the 64-bit
  input a message spans several beats, so the decoder does not emit faster than
  this and there are no drops.
- **Next (performance)**: II=1 pipelining (read/modify/write + forwarding, U uses
  dual-port to access two sets at once). Now that the correctness baseline is set,
  as a separate commit comparing throughput before/after on the same replay.

## Structure

```
rtl/order_table.sv     — d-way set-assoc, filter, book-delta output (FSM)
tb/tb_order_table.sv   — file -> itch_decoder(64b) -> order_table, drop/overflow checks
scripts/dump_book.py   — golden (exact map, same record format)
```

The measurement tools are in step1: `otable_sim.c` (overflow sweep, `loc=N`
filter), `sym_conc.c` (per-symbol concurrency peak), `itch_slice.py` (real-data
slice extraction).
