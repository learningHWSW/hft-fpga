# Step 5 — board integration (U55C)

Wires the whole parse → order-book chain at **CMAC width (512-bit)** into one
synthesizable core (`fh_core`), verifies it end-to-end against the software
golden, and takes it through **real Vivado synthesis for the actual U55C part**
to get resource and timing facts that simulation cannot give.

## What runs here, and what is blocked

This machine has Vivado 2025.2 and the `xcu55c-fsvh2892-2L-e` part, but **no
Alveo card** (and it is WSL2, which cannot do PCIe passthrough to an Alveo).

| Task | Status |
|---|---|
| 512-bit end-to-end integration + functional verification | ✅ done |
| Ethernet/IPv4/UDP receive front end — the wire path closes | ✅ done |
| Synthesis and place & route for the real U55C part | ✅ done (see below) |
| OpenNIC shell buildable for U55C on this toolchain | ✅ verified (see below) |
| Clock crossing to the CMAC's 322 MHz (`cdc_fifo`) | ✅ verified, meets 322 MHz |
| Full tick-to-trade chain integrated and simulated | ✅ done (`t2t_top`) |
| Line rate, **feed path alone** (≥195.3 MHz) | ✅ met — 216.5 MHz |
| Line rate, **full chain** | ❌ **missed — ~160 MHz, a cluster of ladder/table paths** |
| Order table at its verified size in hardware | ✅ 2^16 × 8 as URAM (258 of 960) |
| Hardware replay / measured MAC-to-BBO latency | ⛔ needs a card |

### OpenNIC is a viable host — and it removes two blockers

[open-nic-shell](https://github.com/Xilinx/open-nic-shell) provides the CMAC
subsystem, the QDMA subsystem and a packet adapter, with two user-logic boxes:
a 322.265625 MHz one on the CMAC side and a 250 MHz one on the QDMA side. Both
present 512-bit AXI-Stream with 64-bit tkeep — the shape `fh_core` already has.

Its README lists Vivado 2020.x–2022.1 and this machine has 2025.2, so the
version gap was checked rather than assumed: **the shell builds for `au55c` on
Vivado 2025.2 with zero errors**, generating 100 IP cores including
`cmac_usplus_0` complete with a synthesised `.dcp`. Nothing in the flow pins IP
versions (`create_ip -name cmac_usplus -vendor xilinx.com`, no `-version`),
which is why the gap does not bite. The board file ships in the repo and no
Vitis platform or XRT is needed. Implementation was not run (`-impl 0`);
`build.tcl` does hardcode `-flow {Vivado Implementation 2020}`, which may need
a one-line change there.

So the earlier blockers — GT/refclk bring-up and a Vitis platform — are gone.
What remains is timing: the 322 MHz box is the tick-to-trade path (CMAC RX and
TX in the same box, so wire-to-wire never touches PCIe), and the design does
not yet run that fast.

### The clock that actually matters

At 512 bits a beat is 64 bytes, so sustaining a 100 Gb/s line needs
12.5 GB/s ÷ 64 B = **195.3 MHz**. That, not 250 MHz, is the throughput
threshold; 250 MHz and 322 MHz are the two boxes' clocks. For reference the
measured feed load is far below line rate — p99.99 of 16 messages per
microsecond, and the input FIFO's high-water mark on a 5 M-message replay is
5 entries out of 512.

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
eth frames -> eth_ip_udp_rx -> [beat FIFO] -> mold_splitter -> itch_decoder
                            -> [msg FIFO]  -> order_table   -> [delta FIFO]
                            -> price_ladder -> BBO
```

`eth_ip_udp_rx` is deliberately not a general network stack. A receive-only
multicast feed needs three checks — IPv4 with IHL=5, protocol UDP, and the
configured group/port — plus a header strip; everything else (VLAN, IHL != 5,
non-UDP, wrong group) is dropped and counted. Pinning the accepted layout is
what makes it cheap: with a fixed 42-byte header the payload realignment is a
constant concatenation of the previous beat's top 22 bytes with this beat's low
42, so this stage needs no variable barrel shifter at all.

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
(Superseded — see the 250 MHz section below, which takes this to 166.8 MHz
post-route and retargets the clock to the 195.3 MHz that 100 Gb/s needs.)
The post-route critical path at this point was the price-to-index conversion:

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
rtl/eth_ip_udp_rx.sv  — Ethernet/IPv4/UDP strip + group filter (fixed 42B header)
rtl/fh_core.sv        — 512-bit chain + elastic FIFOs + status block
rtl/drop_fifo.sv      — elastic FIFO with drop-on-full accounting + high-water mark
tb/tb_fh_core.sv      — .mold beats -> BBO (golden = step 4b's dump_bbo.py)
tb/tb_wire_to_bbo.sv  — Ethernet frames -> parser -> fh_core -> BBO
syn/synth_ooc.tcl     — OOC synthesis/implementation, target period as an argument
```

`make test-wire` / `test-wire-real` run the wire path. On the 5 M-message AAPL
replay: 1,127,057 frames in, 1,122,567 kept, 2,245 rejected as non-IPv4 and
2,245 on group/port — exactly the counts `mold2eth.py` injects — with 1779 BBO
updates matching the golden and zero drops.

### Timing work at the 250 MHz target (4.000 ns)

With the memories fixed the bottleneck moved around the design, one stage at a
time. Each step below was verified against the software golden on real data
before the next was attempted:

| change | synth Fmax | LUTs |
|---|---|---|
| starting point (S_OUT split) | 153 MHz | 52,000 |
| register the record before price→index | 179.7 MHz | 51,961 |
| split the order table's read-modify-write | 200.2 MHz | 51,952 |
| drop the divide from the band check | **203.3 MHz** | **42,374** |
| register the splitter's front message length | 203.3 MHz | 42,374 |

Place & route on that last netlist (77 min, far longer than the ~16 min of the
earlier hopeless runs — the router works harder when the target is within
reach):

| | synth | post-route |
|---|---|---|
| WNS @ 4.000 ns | −0.919 ns | **−1.996 ns** |
| Fmax | 203.3 MHz | **166.8 MHz** |
| failing endpoints | 78 / 17,752 | 9,800 / 18,216 |

| resource | post-route | of U55C |
|---|---|---|
| CLB LUTs | 34,273 | 2.63 % |
| CLB registers | 12,250 | 0.47 % |
| Block RAM tiles | 36 | 1.79 % |
| URAM | 2 | 0.21 % |
| DSPs | 2 | 0.02 % |

Resources are a rounding error on this part; **timing is the whole story.** The
design does not meet 250 MHz, and 166.8 MHz is also short of the 195.3 MHz that
100 Gb/s actually requires — so as it stands this core cannot absorb a saturated
wire, though it clears the ~4 Mmsg/s the real feed peaks at by a wide margin.

### Registering the URAM address — the line-rate threshold is met

Acting on the path above (give the best-level scan its own cycle so the
quantity URAMs' address pins are driven by a flop, `S_BQ` → new `S_RDQ`):

| | before | after |
|---|---|---|
| synth WNS @ 4.000 ns | −0.919 ns | −0.727 ns |
| **post-route WNS** | −1.996 ns | **−0.618 ns** |
| **post-route Fmax** | 166.8 MHz | **216.5 MHz** |
| failing endpoints | 9,800 | 7,658 |
| total negative slack | −8,763 ns | −1,653 ns |
| LUTs | 34,273 | 37,542 |

**216.5 MHz clears the 195.3 MHz that 100 Gb/s needs.** The core can absorb a
saturated wire; 250 MHz is still missed, but 250 MHz was never the requirement
— it is one of OpenNIC's box clocks, not a throughput bound (see §"the clock
that actually matters"). The remaining gap is closed architecturally by an
asynchronous FIFO between the CMAC's 322 MHz and the core's own slower clock,
not by more timing work.

One cycle of latency and ~3,300 LUTs bought 50 MHz. The read-modify-write
structure is unchanged, so the two-stage best-level resolution is pure cost on
paper — it pays only because URAM sites are fixed and whatever drives their
address pins gets stretched across the die.

The new worst path is the other end of the same memory: URAM data out →
subtract/compare → occupancy bit (`askq_reg_uram_0/CLK` → `askocc_reg[2044]/D`,
8 logic levels, 1.928 ns logic / 2.617 ns route). It is much more balanced than
before — 42% logic against 58% route, where the old path was 27/73 — which
means the easy placement win has been taken and further gains would need the
ladder's read-modify-write split across cycles. Not worth doing until there is
a reason to run faster than 216 MHz.

Two things are worth taking from this. The largest single win came from
*removing* arithmetic rather than pipelining it: `(price-base)/TICK < LEVELS`
is the same as `(price-base) < LEVELS*TICK`, and dropping that divide took
9,500 LUTs with it. And the last change bought nothing — registering the
splitter's `msglen` moved the path's name but not its delay, because the length
was a bare bit-select with no logic in it. Pipelining only helps where there is
logic to split.

The remaining critical path is **routing, not logic**, before and after P&R —
but it is not the same path, and that matters:

* after synthesis it was the splitter's 1024-bit barrel shifter, 1.381 ns logic
  against 3.521 ns route (72%);
* after routing it is the ladder's group-occupancy bit driving the quantity
  URAM's address (`bid_gany_reg[21]` → `bidq_reg_uram_0/ADDR_A[2]`), 15 logic
  levels, 1.458 ns logic against 4.014 ns route (73%).

I had written that the barrel shifter was the thing to restructure next. The
routed result says otherwise: the shifter placed better than estimated, and the
real bottleneck is that the best-of-book occupancy scan feeds a hard block's
address pins, which are fixed in place and pull the logic that drives them
across the die. That is why the failing endpoint count exploded from 78 to
9,800 — it is not one path missing narrowly but a broad set of ladder paths
sitting just under the line, which is the signature of a placement/fanout
problem rather than a depth problem.

So the next move is **not** more pipeline stages. In order of expected value:
register the ladder's occupancy bits into a dedicated address stage so the
URAM address comes straight out of a flop; then floorplan the ladder into a
Pblock near its URAMs. Both are cheap to try; adding logic levels is not the
issue when 73% of the delay is wire.

## The clock crossing: `cdc_fifo`

Since the core runs at 216.5 MHz and the CMAC hands over beats at 322.265625
MHz, the two are joined by a dual-clock FIFO rather than by making the core
faster. This is the cheaper answer *and* the more honest one: the CMAC
interface carries 165 Gb/s of bandwidth for a 100 Gb/s wire, so beats arrive
on ~61% of cycles and a slower reader keeps up as long as it exceeds 195.3 MHz.

The crossing is written the textbook way, because a dual-clock FIFO that is
subtly wrong still passes casual tests: pointers carry a guard bit so full and
empty do not alias at the wrap, cross as Gray code, and go through two
`ASYNC_REG` flops. The payload memory itself is never synchronised — the
pointer handshake is what makes it safe.

`make test-cdc` drives it from two incommensurate, phase-offset clocks:

| phase | offered | received | dropped | hwm |
|---|---|---|---|---|
| below capacity (61% duty, reader ready) | 12,304 | 12,304 | 0 | 18 / 256 |
| reader stalling 40% | 24,513 | 20,719 | 3,794 | 255 / 256 |
| forced overflow (100% duty, 90% stall) | 44,512 | 22,361 | 22,151 | 255 / 256 |

Received values must be strictly increasing (catching duplication and
reordering) and `offered == received + dropped` must hold exactly, so an
overflowing FIFO is provably counting what it discards rather than losing it.
At realistic load only 18 of 256 entries are ever used; the depth stays at 256
because it costs 8.5 BRAM and the margin is worth more than the tiles.

Synthesis for the U55C: 56 LUTs, 113 FFs, 8.5 BRAM, **zero LUTRAM**, no
warnings — the payload array maps to block RAM as intended.

Two bugs worth recording, both found by the testbench rather than by reading:

* **`32'(wbin - rbin_w)` was wrong for occupancy.** The cast sets the context
  width, so both 9-bit pointers widened to 32 bits *before* subtracting and a
  wrapped pointer pair reported 4,294,967,039 instead of a real depth. Modular
  arithmetic has to happen at the pointer width.
* **`$urandom(seed)` reseeds on every call**, so it returns the same value
  forever. The first testbench ran the writer at 100% duty no matter what duty
  was set — which presented as the FIFO dropping beats below capacity, i.e. as
  a DUT bug. Replaced with an explicit xorshift.

## The full chain: `t2t_top` place & route

The whole tick-to-trade path — CMAC RX → CDC → UDP parser → feed handler →
strategy → OUCH builder → TCP framer → CDC → CMAC TX — built for the real part
at a 4.618 ns core clock and the CMAC's fixed 3.103 ns.

| | synth | post-route |
|---|---|---|
| core_clk WNS | −0.156 ns | **−0.595 ns** |
| **core_clk Fmax** | 209.5 MHz | **191.8 MHz** |
| cmac_clk WNS | +1.304 ns | **+0.480 ns** (meets 322.265625 MHz) |

| resource | post-route | of U55C |
|---|---|---|
| CLB LUTs | 35,548 | 2.73 % |
| CLB registers | 15,158 | 0.58 % |
| Block RAM tiles | 52 | 2.58 % |
| URAM | 2 | 0.21 % |
| DSPs | 2 | 0.02 % |

### It misses line rate, by 1.8 %

**191.8 MHz is below the 195.3 MHz that 512 bits at 100 Gb/s requires.** The
feed path alone closed at 216.5 MHz; adding the strategy, the encoders and the
two clock crossings costs 25 MHz and drops it under the bar. As it stands the
full chain cannot absorb a saturated wire — it clears the ~4 Mmsg/s the real
feed peaks at with room to spare, but that is a different and much weaker claim.

The CMAC side is fine: +0.480 ns, and its worst path is inside the receive
CDC (`wbin_reg` → the FIFO's BRAM write enable), which is exactly where a
322 MHz path should be.

The core-side critical path is the price ladder's group-occupancy scan again —
`bid_gany_reg[48]` → `q_bbi_reg[5]`, 13 logic levels, **1.260 ns logic against
3.934 ns route (75.7 %)**. Registering the URAM address earlier moved the scan
off the memory's address pins; what is left is the scan itself. Note the route
delay grew from 2.617 ns to 3.934 ns on the *same* logic, so this is placement
pressure from the larger design rather than anything new — which is why the
next move is a Pblock for the ladder, not more pipelining.

### The order table at its real size: 163.5 MHz

The table is now an instantiated XPM/URAM macro at 2^16 x 8, the size every
simulation runs, so the gap described below is closed — synthesis and
simulation finally build the same design. What that costs:

| | 2^9 table (inferred) | 2^16 table (URAM) |
|---|---|---|
| synth core_clk WNS | −0.156 ns | −0.156 ns |
| **post-route core_clk WNS** | −0.595 ns | **−1.500 ns** |
| **post-route Fmax** | 191.8 MHz | **163.5 MHz** |
| cmac_clk WNS | +0.480 ns | +0.267 ns (meets) |
| CLB LUTs | 35,548 | 37,075 |
| CLB registers | 15,158 | 16,218 |
| Block RAM tiles | 52 | 32 |
| **URAM** | 2 | **258** (26.9 %) |

Synthesis reported *identical* timing for a table 128× larger, which is not a
coincidence: at that stage the worst path was the splitter's `msglen → vcnt` in
both runs, and the table was not on it. Place & route tells the real story —
**163.5 MHz against the 195.3 MHz line rate needs, 16 % short** where the
stand-in table was 1.8 % short.

The routed critical path is the table itself now:

```
u_fh/u_msg_fifo/mem_reg_4 (BRAM)
  -> hash(order_ref)
  -> u_otab/g_way[3]/…/mem_reg_uram_31/CAS_IN_ADDR_A   (URAM cascade)
5.562 ns: logic 2.318 ns, route 3.244 ns
```

The FIFO's block RAM output goes through the XOR-fold hash and straight into
the address pins of a **32-deep URAM cascade** in a single cycle. This is the
same defect as the price ladder's, in a new place: combinational logic driving
a hard block's address, where the block's sites are fixed and the cascade adds
its own propagation. The fix is the same — register the hash so the URAM
address comes out of a flop — and it is the next thing to do, not more
pipelining elsewhere.

Worth being explicit that this is a *real* number replacing an optimistic one.
The earlier 191.8 MHz was measured on a design that could not hold a trading
day's orders; 163.5 MHz is measured on one that can.

#### Registering the hash bought 3 MHz, and moved the problem one pin over

| | before | after |
|---|---|---|
| post-route core_clk WNS | −1.500 ns | −1.380 ns |
| post-route Fmax | 163.5 MHz | **166.7 MHz** |
| cmac_clk WNS | +0.267 ns | +0.027 ns |

The address path did come off the critical list. What replaced it is the same
memory's **write data** pins:

```
u_otab/sel_ent_reg[qty]  ->  qty - shares  ->  …/mem_reg_uram_15/CAS_IN_DIN_B
5.648 ns: logic 1.830 ns, route 3.818 ns (67.6 %)
```

Three times now the critical path has been combinational logic reaching a hard
block's pins — the ladder's URAM address, the table's URAM address, and now the
table's URAM data. Registering each one individually is chasing the symptom.

**The cause is cascade depth, and it points at a different design point.** Each
way is 65,536 deep, which is 16 URAM primitives cascaded (4,096 each) and 2
wide: 32 URAM per way, 256 in total, and every access walks a 16-long chain.
The size sweep already measured an alternative with zero overflow:

| | slots | max occ | URAM/way | **cascade depth** | total URAM |
|---|---|---|---|---|---|
| 2^16 × 8 (deployed) | 524,288 | 6/8 | 32 | **16** | 256 |
| 2^13 × 16 | 131,072 | 12/16 | 4 | **2** | 64 |

2^13 × 16 holds a full trading day with more proportional headroom (12/16 vs
6/8), uses a quarter of the URAM, and shortens the cascade from 16 to 2. The
cost is 16-way comparators instead of 8.

I chose 2^16 × 8 earlier on the reasoning that URAM was plentiful and timing
was scarce, so the low-risk move was to leave the lookup logic untouched. That
was half right: URAM *count* is not the constraint, but URAM *cascade depth*
is, and I did not weigh it. The routed evidence says the memory's geometry
matters more here than the comparator width, so the next experiment is
2^13 × 16 rather than another register stage.

### ⚠ (Superseded) These numbers are for a 4,096-entry order table

`fh_core` defaults to `OT_SETS_BITS = 16` (65,536 sets × 8 ways = 524,288
entries) and **every simulation in this project runs at that size**. Synthesis
and implementation run at `OT_SETS_BITS = 9` — 4,096 entries, 128× smaller —
because a behavioural array that large cannot be inferred ([Synth 8-4556]).

So the design that was verified and the design that was implemented are not the
same design. Everything above understates area and probably overstates Fmax.
`ot_overflow = 0` in simulation says nothing about the synthesized size: the
measured per-symbol peak is 37,068 concurrent orders (data/FINDINGS.md §4.2),
which a 4,096-entry table cannot hold.

Closing that gap — instantiating the table as XPM/URAM at the measured size of
2^13 × 8 = 65,536 entries — is the next task, and it has to happen before any
of these numbers should be quoted as the design's.

## Next

Done: order table mapped to real memory, synchronous reads in `drop_fifo` and
the ladder, hierarchical best-of-book scan, the Ethernet/IPv4/UDP front end,
line-rate timing (216.5 MHz ≥ 195.3 MHz), and the CMAC clock crossing.

1. **Tick-to-trade proper.** Everything so far is a feed handler: it produces a
   BBO and stops. The strategy, the OUCH encoder and the TCP transmit path do
   not exist yet, and they are what the project is named after.
2. **OpenNIC integration** — `fh_core` plus `cdc_fifo` into the 322 MHz box.
   Deferred deliberately: the shell is verified to build, but with no card
   there is nothing to learn by wiring it that simulation does not already say.
3. Only once there is a reason to exceed 216 MHz is more timing work justified;
   the next step there is splitting the ladder's read-modify-write.

**A limit worth stating plainly: measured MAC-to-BBO latency needs a card.**
Simulation gives exact cycle counts, and cycle counts are not nanoseconds on
silicon. Until an Alveo is in a slot, no latency claim here is measured.
