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
make test-real         # real data 500k slice, AAPL locate 13
make test-real-xsim    # the above, xsim
```

The golden is `scripts/dump_book.py` (exact map). An empty diff against the RTL's
book-delta log is PASS. The TB additionally checks **0 drops** (the table is
always ready in time) and **0 overflow** (sized to the symbol).

### The testbench was wrong twice, and it looked like an RTL bug

`make test` failed on unmodified sources with the five inserts present and every
lookup (E, X, U, D, C) missing — which reads exactly like a broken order table. It
was a broken testbench, in two independent ways:

- **It never waited for `init_done`**, which was not even connected. The table
  holds `s_ready` low for `SETS` cycles while it sweeps clear, and the testbench
  drove straight through that window: inserts still emitted their add-deltas (an
  `A` needs no lookup) while every write was overwritten by the sweep's zeros, so
  every later lookup missed.
- **It fed faster than `s_ready` allowed**, dropping three messages. This module
  is a correctness-first FSM, 2 cycles per message and 3 for `U`, and applies real
  backpressure. The full chain absorbs that with the message FIFO in `fh_core`;
  this testbench feeds the decoder directly with no such buffer, so a 0–2 cycle
  inter-message gap let a short message finish decoding while the table was still
  busy.

The full chain never had either problem, because `fh_core` exports `init_done` and
the kernel gates the feed on it. So the integrated tests passed and only the unit
test was wrong — which is the more dangerous way round, and worth remembering when
a unit test disagrees with a system that works.

## Design (measurement-based, data/FINDINGS.md §4)

- **d-way set-associative, mixing hash**: for the all-symbols aggregate, monotonic
  refs round-robin so the raw low bits suffice, but **filtering to one symbol
  makes that symbol's ref subset cluster in the low bits** (raw 16b×4 = 24142
  overflows vs mix = 132). So the filter table uses a multiply-shift mixing hash —
  a measured result that is the exact opposite of the all-symbols case.
- **URAM-resident via the symbol filter**: A/F enter only when their locate is in
  the tracked set. E/C/X/D/U look up by ref — if stored, it is a tracked symbol.
  The all-symbols table is 8M+ entries (HBM territory), but filtering the symbols
  puts it in URAM.
- **`NSYM` symbols share one table** (default 1). The set is `track_locate`
  packed 16 bits per symbol; the entry stores a symbol **index**, not a locate,
  because a D or X carries no locate of its own and the delta still has to reach
  the right book. Four bits covers sixteen symbols and the entry had fourteen
  spare inside its two URAM columns, so the width cost is zero — the cost is
  capacity, and it is measured: 2 symbols need `2^14 × 16`, 4 and 8 need
  `2^15 × 16`, 16 need `2^16 × 16` (FINDINGS §4.4). The deployed `2^13 × 16`
  holds exactly one, with a worst set already at 16 of 16, which is why `NSYM`
  does not quietly resize the table. `make test-multi` runs two symbols through
  one table against the golden.
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
- **II=1 pipelining is built**, not pending: `rtl/order_table_pipe.sv` is a
  verified drop-in with identical ports and byte-identical output, selected with
  `+define+OT_PIPE`. Unloaded latency is the same either way — 5 cycles — so it
  buys throughput, not latency, which is worth knowing before reaching for it.

## The entry select was the whole design's critical path

Measured on the routed 215 MHz kernel, **92 of the 200 worst core-clock endpoints
were this module's `sel_ent` register** — against 11 in the price ladder, which is
where the project's notes had been pointing for a long time. The worst path ran
10 logic levels at +0.011 ns, roughly half logic delay and half routing, so no
amount of floorplanning could have moved it.

The depth came from doing the selection twice. The way comparators already produce
a **one-hot** vector, because `order_ref` is unique — the premise of keying the
table on it. Collapsing that to a binary `hit_way` and using it to drive a 16:1
mux over 130-bit entries inserts a priority encoder between the compare and the
mux purely to re-derive what the compare already knew.

Selecting straight off the one-hot removes the encoder:

| | before | after |
|---|---|---|
| core clock margin at 215 MHz | +0.011 ns | **+0.099 ns** |
| worst endpoint | `sel_ent_reg`, 10 levels | moved to the ladder |
| latency | — | unchanged |

Nine times the margin for no cycles. A simulation-only assertion states the
uniqueness assumption rather than trusting it, and `hit_way` is still produced for
the write address, which is consumed a cycle later and off this path.

## URAM cannot be initialised

`initial mem[s] = '0` works in simulation and in BRAM and is a lie on the device:
URAM comes up indeterminate, every `valid` bit is whatever the silicon felt like,
and the first lookup hits garbage that looks like live orders. The table therefore
sweeps itself clear after reset and holds `init_done` low until it finishes. The
feed must not be enabled before that rises — `s_ready` is low throughout, and the
no-backpressure market-data path ignores `s_ready` by design, so anything started
early silently loses its first `SETS` messages.

That is not hypothetical. It is exactly what made this step's own testbench fail
(below).

## Structure

```
rtl/order_table.sv     — d-way set-assoc, filter, book-delta output (FSM)
tb/tb_order_table.sv   — file -> itch_decoder(64b) -> order_table, drop/overflow checks
scripts/dump_book.py   — golden (exact map, same record format)
```

The measurement tools are in step1: `otable_sim.c` (overflow sweep, `loc=N`
filter), `sym_conc.c` (per-symbol concurrency peak), `itch_slice.py` (real-data
slice extraction).
