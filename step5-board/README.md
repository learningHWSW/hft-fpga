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
