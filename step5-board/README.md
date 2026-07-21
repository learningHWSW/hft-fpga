# Step 5 — board integration (U55C)

Wires the whole parse → order-book chain at **CMAC width (512-bit)** into one
synthesizable core (`fh_core`), verifies it end-to-end against the software
golden, and takes it through **real Vivado synthesis for the actual U55C part**
to get resource and timing facts that simulation cannot give.

## What runs here, and what is blocked

This machine has Vivado/Vitis 2025.2 and the `xcu55c-fsvh2892-2L-e` part, but
**no Alveo card, no XRT, and no Vitis platform installed** (and it is WSL2, which
cannot do PCIe passthrough to an Alveo anyway). So:

| Task | Status |
|---|---|
| 512-bit end-to-end integration + functional verification | ✅ done |
| Synthesis for the real U55C part (resource / timing) | ✅ done (see below) |
| CMAC 100G + UDP/IP front end | ⛔ needs board bring-up + GT/refclk config |
| QDMA host reporting, `xclbin` packaging | ⛔ needs a Vitis platform (`xilinx_u55c_gen3x16_*`) + XRT |
| Hardware replay / measured MAC-to-BBO latency | ⛔ needs a card |

The Vitis packaging follows the `rtl_kernels` pattern in
[Vitis_Accel_Examples](https://github.com/Xilinx/Vitis_Accel_Examples) (RTL
kernel + AXI-Stream, `v++` link against a platform). That flow cannot be run
until a platform and XRT are installed; the RTL boundary here (`fh_core`, pure
AXI-Stream in / status + BBO out) is already the shape such a kernel needs.

## Run

```sh
make test              # synthetic .mold -> BBO, diffed vs golden (xsim)
make test-verilator    # same under Verilator
make test-real         # 5 M real AAPL messages end-to-end
make stress            # same at gap=0 (synthetic over-drive; see below)
make synth             # out-of-context synthesis for xcu55c
make impl              # + place & route
```

## Integration: `fh_core`

```
in(512b) -> [beat FIFO] -> mold_splitter -> itch_decoder
         -> [msg FIFO]  -> order_table   -> [delta FIFO] -> price_ladder -> BBO
```

The 64-bit testbenches never exposed a rate problem because the decoder was the
bottleneck there. At 512-bit the producer is *faster* than the consumers: the
splitter sustains 1 msg/cycle while the order table is a correctness-first FSM
(2 cy/msg, 3 for `U`) and the ladder takes 3 cy/record. Every no-backpressure
boundary therefore gets a `drop_fifo` — an elastic FIFO that **drops and counts**
on overflow rather than stalling the wire, which is the market-data policy the
whole design follows. The drop counters and high-water marks are the evidence
for whether the depths are right.

## Results

**Functional (end-to-end, first time at CMAC width)**

| Stimulus | Result |
|---|---|
| synthetic `test.mold` (gap+dup+heartbeat+EOS) | PASS — 10 BBO updates, gap_total=2, dup=1 |
| real AAPL, 5 M messages | PASS — **1779 BBO updates, identical to the 64-bit chain and the golden** |

At realistic pacing both runs show **zero drops** and tiny FIFO occupancy —
high-water marks of **beat=3, msg=4, delta=3** entries out of 512. The chain has
large margin at real feed rates.

**Saturation (synthetic over-drive, `gap=0`)**

Injecting one 64-byte beat every cycle is 20.6 GB/s ≈ **165 Gb/s, i.e. 1.65× a
100G line** — deliberately beyond spec. There the design collapses as expected:
3.2 M beat drops, framing breaks, no coherent book. The binding constraints are
the splitter's 1 msg/cycle drain (≈30 B/cycle of ITCH payload) and the order
table's 2 cy/msg. This quantifies the II=1 gap already flagged in steps 4a/4b.
A proper 100G-paced test (with real UDP/IP/Mold packet overheads, which lower the
effective message rate) is the follow-up measurement.

**Synthesis for `xcu55c-fsvh2892-2L-e`** — and the finding that matters:

```
ERROR: [Synth 8-4556] size of variable 'bank' is too large to handle;
       the size of the variable is 80216064, the limit is 1000000
```

The production order table (2^16 sets × 8 ways × 153 b = **80 Mbit**) **cannot be
inferred from a behavioral SystemVerilog array** — Vivado caps a single variable
at 1 Mbit. This is invisible in simulation and is the concrete next task:
instantiate `xpm_memory_sdpram` / URAM macros (which is the right way to build a
10 MB on-chip table anyway) instead of relying on inference. It also re-confirms
the step-4a sizing note: 80 Mbit is ~87% of the VU35P's ~90 Mbit of URAM, i.e.
the design was always at the edge for a single symbol.

To still measure the surrounding logic, synthesis runs with the table scaled to
an inferable size (`OT_SETS_BITS=9`, `OT_WAYS=8` by default; override on the
`make synth` command line). See `syn/out/` for the full reports.

### Measured: `xcu55c-fsvh2892-2L-e`, target 3.103 ns (322.265625 MHz), OT = 2^9 × 8

Three synthesis defects were found and fixed (details in the git history); the
numbers below are before, after the first two, and after all three:

| | initial | +way split, +sync reads | +flat storage, +2-level scan | +XOR-fold hash |
|---|---|---|---|---|
| CLB LUTs | 317,572 | 223,414 | 48,375 | **48,311** (3.7%) |
| CLB Registers | 576,039 | 573,770 | 11,709 | **11,709** (0.4%) |
| Block RAM | 0 | 16 | 32+8 | **32 × RAMB36 + 8 × RAMB18** |
| URAM | 0 | 2 | 2 | 2 |
| DSP | 22 | 22 | 22 | **2** |
| WNS | −4.811 ns | −3.669 ns | −3.396 ns | **−3.290 ns** |
| Fmax | 126 MHz | 148 MHz | 154 MHz | **156 MHz** |
| synthesis runtime | ~40 min | ~18 min | ~4 min | ~5 min |

Area collapsed — 85% fewer LUTs, 98% fewer registers — and the storage finally
lives in block RAM. Timing improved far less: **154 MHz against a 322 MHz
requirement**, so the design still does not close.

After the memory fixes the critical path became arithmetic — the order table's
64×64 multiply-shift hash, a multi-DSP cascade sitting combinationally between
the input FIFO's BRAM output and the table's read address (6.184 ns, 15 logic
levels, 4.646 ns of it DSP). Pipelining it would have cost two extra cycles per
message and still not fit, since the multiply alone exceeds the 3.103 ns
period. Measuring cheaper mixers instead showed the multiply was unnecessary:
a plain XOR fold gives the *same* zero overflow with a *lower* worst-case set
occupancy (data/FINDINGS.md §4.3). Swapping it in removed 20 of the 22 DSPs.

That moved the critical path into the ladder's output stage (group encode ->
part-select -> within-group encode -> price arithmetic -> BBO compare -> output
enable, all in one cycle), which was then split three ways: `S_BQ` resolves the
best indices, `S_PX` converts index to price and captures the quantities,
`S_OUT` only compares.

### Place & route

Synthesis timing is optimistic — it estimates routing. The real number is
post-route, and it is **worse**, not better:

| | post-synth | post-route |
|---|---|---|
| before the S_OUT split | −3.290 ns (156 MHz) | −4.490 ns (**132 MHz**) |
| after the S_OUT split | −3.442 ns (153 MHz) | −3.765 ns (**146 MHz**) |

The split is worth ~14 MHz on the number that counts, even though it made the
synthesis estimate slightly worse — a reminder to judge timing after routing.

Post-route resource use (the real figures):

| | used | device | % |
|---|---|---|---|
| CLB LUTs | 43,330 | 1,303,680 | 3.32% |
| CLB Registers | 12,184 | 2,607,360 | 0.47% |
| Block RAM | 36 | 2,016 | 1.79% |
| URAM | 2 | 960 | 0.21% |
| DSP | 2 | 9,024 | 0.02% |

Place & route completes cleanly and the design occupies ~3% of the device, so
there is ample room for the CMAC/UDP front end and more symbols.

**Timing remains the open item: 146 MHz against the 322.265625 MHz target.**
The post-route critical path is now the price-to-index conversion:

```
u_delta_fifo BRAM read  ->  in_band()/to_idx() ((price-base)/TICK)  ->  ladder qty URAM address
-3.765 ns
```

i.e. the ladder's IDLE state takes the FIFO's output and drives a memory
address through a divide in the same cycle. The fix is the same shape as the
previous ones: register the record first, convert to an index in the next
cycle, then address the memory.

Per-module after all three fixes:

| Module | LUTs | FFs | BRAM | URAM |
|---|---|---|---|---|
| `price_ladder` | 28,971 | 8,720 | 0 | 2 |
| `mold_splitter` | 7,313 | 1,675 | 0 | 0 |
| `delta` FIFO | 1,735 | 63 | 3 | 0 |
| `order_table` | 1,262 | 508 | 16+8 | 0 |
| `itch_decoder` | 1,058 | 684 | 0 | 0 |
| `msg` FIFO | 236 | 63 | 5 | 0 |
| `beat` FIFO | 208 | 63 | 8 | 0 |

`price_ladder` is now the largest block — its 4096-bit occupancy bitmaps and
the variable part-selects into them are the next area target.

| | Used | Device | % |
|---|---|---|---|
| CLB LUTs | 317,572 | 1,303,680 | 24.4% |
| CLB Registers | 576,039 | 2,607,360 | 22.1% |
| Block RAM | **0** | 2,016 | 0% |
| URAM | **0** | 960 | 0% |
| DSP | 22 | 9,024 | 0.2% |

**WNS −4.811 ns → Fmax ≈ 126 MHz, against the 322.27 MHz requirement (2.5× off).**

Per module (LUT / FF):

| Module | LUTs | FFs | LUTRAM |
|---|---|---|---|
| `order_table` | 227,359 | 564,963 | 0 |
| `price_ladder` | 49,218 | 8,527 | 15,360 |
| `drop_fifo` (delta) | 22,411 | 144 | 1,728 |
| `mold_splitter` | 7,277 | 1,655 | 0 |
| `drop_fifo` (beat) | 7,173 | 86 | 5,280 |
| `itch_decoder` | 964 | 583 | 0 |

Three concrete defects, none of which simulation could show:

1. **No memory is inferred anywhere — 0 BRAM, 0 URAM.** The order table's
   626 Kbit of storage became 565 k flip-flops. Cause: `bank[way][set]` is
   written with a *variable way index*, so the tool cannot map it to a memory
   primitive. Each way must be its own array with a decoded write enable
   (a `generate` per way), which also unblocks the production size via XPM.
2. **Asynchronous reads force distributed RAM.** `drop_fifo` reads
   `mem[rptr]` combinationally and `price_ladder`'s qty arrays are async-read;
   both become LUTRAM plus wide muxes instead of block RAM.
3. **The critical path is one giant combinational cycle**: delta-FIFO read
   pointer → async RAM read (`RAMD64E`) → price→index divide → occupancy-bit
   update, 33 logic levels (13 × CARRY8). It needs pipelining, and the
   best-of-book scan needs to be hierarchical rather than a flat 4096-bit
   priority chain (which is also why synthesis takes ~40 min).

Note the scale: this is 24% of the device with an order table **128× smaller**
than the production point. The design as written is not implementable — fixing
(1) and (2) is a prerequisite for any board work.

## Structure

```
rtl/fh_core.sv     — 512-bit chain + elastic FIFOs + status block
rtl/drop_fifo.sv   — elastic FIFO with drop-on-full accounting + high-water mark
tb/tb_fh_core.sv   — .mold beats -> BBO, canonical log (golden = step 4b's dump_bbo.py)
syn/synth_ooc.tcl  — OOC synthesis/implementation for the real part
syn/fh_core.xdc    — 322.265625 MHz CMAC datapath clock
```

## Next (priority order, set by the synthesis results above)

1. **Make the order table map to real memory.** Split `bank` into per-way
   arrays with a decoded write enable so each way is a single-write/single-read
   memory; then move the production size onto `xpm_memory_sdpram` (URAM). This
   removes ~227 k LUTs and ~565 k FFs and is the prerequisite for everything else.
2. **Synchronous reads in `drop_fifo` and the ladder's qty arrays** so they
   become block RAM instead of LUTRAM, and drop off the critical path.
3. **Pipeline the ladder**: split price→index from the occupancy update, and
   replace the flat 4096-bit best-of-book scan with a hierarchical one.
4. Re-run synthesis; only then is the II=1 work (PLAN.md) worth measuring.
5. CMAC + UDP/IP front end and QDMA reporting once a platform/card is available.
