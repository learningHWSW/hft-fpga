# Step 8 — on real silicon (Alveo U55C)

Every earlier step was verified in simulation and taken through synthesis and
place & route, but never executed on a card — the top-level README says so
plainly, and "no physical card" is the first item under *What is not done*. This
step removes that caveat. There is a real U55C in this machine, and this
directory is what puts the tick-to-trade datapath on it and checks the result
against the same golden the testbenches use.

## The machine

| | |
|---|---|
| Card | **Alveo U55C** at `0000:08:00.1`, shell `xilinx_u55c_gen3x16_xdma_base_3` |
| Also present | Alveo U250 at `0000:07:00.1` (unused here) |
| Runtime | XRT 2.18.179 (2024.2 branch), `xocl` + `xclmgmt` loaded, device ready |
| Platform | `xilinx_u55c_gen3x16_xdma_3_202210_1` (generated 2022.1) |
| Host OS | Ubuntu 22.04, kernel 5.15 — a real machine, **not** WSL |
| QSFP28 cages | **empty** — no transceivers, no cables |
| JTAG | **no cable attached** |

The last two rows drive every design decision below.

## Why an .xclbin and not the OpenNIC shell

Step 5 established OpenNIC as the natural long-term host, and `t2t_axil` was
written for its 322 MHz user box. It is still the right answer eventually, and it
is **not** what this step does, for one reason: OpenNIC *replaces the card's
shell*, which means programming over JTAG or writing the configuration flash.
There is no JTAG cable on this machine, so a bad flash write would leave no
recovery path — the card would need physical access with a programmer to come
back.

An `.xclbin` loads into the shell's reconfigurable partition instead. Worst case
is a card reset. That is the entire argument: this is the *safe* way onto real
hardware, not the fastest-in-theory one. `t2t_axil` already has exactly the shape
a Vitis kernel needs — one AXI4-Lite control slave plus a 512-bit AXI-Stream in
and out — so the wrapper is thin.

## Toolchain: 2026.1 is installed, and unusable

Both Vivado/Vitis **2026.1** and **2025.2.1** are installed, and newer is
normally better. 2026.1 does not work here:

```
$ vivado -mode batch -source lic.tcl      # 2026.1
ERROR: Vivado Design Suite cannot be launched because a valid license was not found.
```

It fails at **tool launch** — it cannot execute a bare `puts`, so this is not a
device-licensing question. There is no license file anywhere on the host
(`XILINXD_LICENSE_FILE` unset, no `~/.Xilinx/*.lic`), and 2022.2 / 2025.2.1 both
run license-free on `xcu55c`. So **2025.2.1 is the newest usable version**, which
is also what the top-level README already documents. If a 2026.1 license is
added later, nothing here depends on the version except the paths in
`syn/build_xclbin.sh`.

The platform is a 2022.1 development platform, so tool, platform and runtime span
three releases. Rather than assume that works, a throwaway `vadd` kernel was
built first — tens of minutes instead of hours — and v++ answered the question
directly:

```
INFO: [v++ 60-1302] Platform 'xilinx_u55c_gen3x16_xdma_3_202210_1.xpfm'
                    has been explicitly enabled for this release.
```

Explicitly supported, not merely tolerated. And the probe was then **loaded onto
the card**, which is the part no amount of reading the release notes can settle:

```
$ xrt-smi program --device 0000:08:00.1 --user vadd.xclbin
INFO: xrt-smi program succeeded on 0000:08:00.1

$ xrt-smi examine -d 0000:08:00.1 --report dynamic-regions
  Device Status: HEALTHY
    Xclbin UUID: 621BD7B4-C6D0-3B6A-3D9D-B3E7A4E16913
    PL Compute Units
      |0  ||vadd:vadd_1  ||0x800000  ||0  ||(IDLE)  |
```

So a 2025.2.1-built `.xclbin`, targeting a 2022.1 platform, loads and runs under
XRT 2.18.179 on the flashed `base_3` shell — three releases apart, and fine. That
same probe also confirmed the memory topology this design's host relies on: the
banks are tagged `HBM[0]` and `HBM[1]` with *Bank Used: Yes*, which is exactly
what `mem_index()` in `host/t2t_run.cpp` matches, rather than assuming bank 0 and
1 and silently reading zeroes off the wrong one.

## Phase A (this build): the datapath on silicon, CMAC-less

The QSFP cages are empty, so the first thing to prove on the card is the
datapath, not the optics. Two blocks stand in for the MAC:

```
   HBM ──► eth_replay ──► t2t_axil (the whole step 1-7 datapath) ──► eth_capture ──► HBM
           (frames out          rx 512b            tx 512b            (frames in
            of memory)                                                 to memory)
                                     ▲
                          s_axi_control ── AXI4-Lite ── host (XRT)
```

`eth_replay` reads the **same `.eth` stimulus file the simulations replay** and
drives it into the RX port exactly as the CMAC would; `eth_capture` records every
frame the design transmits. So the order frames coming off the card are
byte-for-byte comparable with `step6-strategy`'s golden — a hardware run that is
*checkable*, not merely one that does not crash.

Phase B swaps `eth_replay` for a real `cmac_usplus` in **GT near-end loopback**,
which needs no optics, and nothing downstream changes.

### Two clocks, on purpose

`ap_clk` (300 MHz) carries the control plane, both HBM masters and the
injector/capture pair — it stands in for the CMAC domain. `ap_clk_2` (220 MHz) is
the datapath core, the frequency step 5 closed post-route. They are asynchronous,
so `cdc_fifo` is genuinely exercised on the card; a single-clock build would
optimise away the crossing the real design depends on.

### Record format

The host pads the unaligned `.eth` stream into 64-byte-aligned records
(`scripts/pack_eth.py`), because consuming a bare length-prefixed stream in
hardware would need a barrel shifter to find each frame's first byte inside a
512-bit beat — a second `mold_splitter`, the hardest block in the project, rebuilt
for no design reason.

```
byte 0..1    frame length, little-endian uint16   (0 = end of image)
byte 64..    the frame bytes
```

Capture uses the identical layout with a fixed 2 KB stride, so **one parser reads
both directions**. The stride is not laziness: an AXI burst may not cross a 4 KB
boundary, and a burst of at most 2 KB starting on a 2 KB boundary provably cannot.
Only the beats actually used are written, so the padding costs address space, not
bandwidth.

## Status

| Task | Status |
|---|---|
| Kernel RTL (`eth_replay`, `eth_capture`, `t2t_kernel`) | written |
| Elaborates under Vivado 2025.2.1 (and 2022.2) | 0 errors, 0 critical warnings |
| **Harness verified in simulation, diffed against the golden** | **PASS** |
| Packaged as a Vitis `.xo` (CDC constraints included) | DONE |
| Toolchain→runtime→card path proven with a probe `.xclbin` | **loads, card HEALTHY** |
| Kernel meets timing out of context (`ap_clk` +0.553 / `ap_clk_2` +0.503 at 200 MHz) | DONE |
| CDC crossings cut out of context (`report_clock_interaction`) | Asynchronous Groups |
| Two real kernel clocks generated (300 MHz + 200 MHz) | verified in the clock summary |
| CDC groups applied at **top-level implementation** (TCL hook) | "groups APPLIED" in the impl log |
| `.xclbin` linked, **all timing constraints met**, 0 violated paths | DONE |
| Latency probe unit-tested (attribution, exclusion, orphans, buckets) | `make test-latprobe` |
| Real NASDAQ capture downloaded and sliced (5 M msgs, AAPL) | 1.13 M frames, 327 MB packed |
| **Programmed onto the card, synthetic replay == golden** | **PASS on silicon** |
| **Real 5 M-message AAPL replay == golden** | **PASS on silicon, 70/70 frames** |
| **Tick-to-trade latency measured on silicon** | **220 ns min / 281 ns mean, 70 samples, 0 excluded** |
| **Loaded (burst) latency, without threading a tag** | **measured on silicon**, load swept to saturation |
| Core clock settled at 215 MHz, 0 failing endpoints | `ap_clk` +0.153 / `ap_clk_2` +0.015 |
| Phase B RTL (`cmac_wrap`, `axis_sf_fifo`, `axis_frame_filter`, `t2t_kernel_b`) | written |
| **Phase B verified in simulation against the same golden** | **PASS through the MAC**, at gap 48 and gap 512 |
| Phase B packaged as a `.xo` with the CMAC IP inside | DONE |
| GT connects to `io_gt_qsfp0_00` on the real kernel | "SERIAL PORT CONNECTED" |
| Three clock domains found and cut at implementation | "three asynchronous groups APPLIED" |
| **Phase B routes with all timing met** (300 / 200 / **322.269** MHz) | DONE — 0 of 538,495 endpoints failing |
| `cmac_usplus` bitstream licence | DONE — **granted**, `make gate-license` PASSES |
| **Phase B bitstream** | DONE — `t2t_b.xclbin`, 53.1 MB, linked in 1 h 13 m |
| **Phase B on the card, through a real 100 G MAC** | **PASS on silicon**, 70/70 frames == golden, link up, 0 MAC errors |
| **Wire-to-wire latency measured** | **515.1 ns min / 579.1 ns mean**, 70 samples, 0 excluded |
| Card-vs-simulation disagreement at gap 512 | RESOLVED — the card now matches at every gap from 48 to 4096 |
| **Saturation wedge (`sent=0` until a device reset)** | **FIXED** — ladder BRAM had no clear-on-reset; verified recovering with no reset |

Both phases are on the card and measured. **Phase B ran**: the `cmac_usplus`
brought its link up in near-end PMA loopback (`aligned=1 link_up=1`), passed
1,127,130 frames with `rx_err=0 underrun=0 overflow=0`, and produced 70 order
frames byte-identical to the golden. That is the first **wire-to-wire** figure
this repository has ever been able to quote, and it is below.

The current Phase A `.xclbin` — the one carrying the loaded probe, 215 MHz and
the signed-position fix — links in 1 h 17 m with every constraint met:

| clock | frequency | WNS | failing endpoints |
|---|---|---|---|
| `clk_kernel_00_unbuffered_net` (`ap_clk`) | 300.000 MHz | +0.153 ns | 0 |
| `clk_out1_ulp_clk_wiz_0` (`ap_clk_2`, the core) | **215.000 MHz** | **+0.015 ns** | 0 |
| `hbm_aclk` | 450.000 MHz | +0.018 ns | 0 |
| `dma_ip_axi_aclk_1` (platform DMA) | — | +0.003 ns | 0 |

Design-wide WNS is +0.003 ns over 526,076 endpoints, none failing, hold met at
+0.009 ns. The design-wide figure belongs to the **platform's** DMA clock, not to
anything this kernel owns; the core's own margin is the +0.015 ns row.

The simulation result is the one worth stating precisely, because it is what
makes the hardware run trustworthy rather than hopeful — `make test-xsim`, on the
synthetic feed:

```
TB: kernel id = 54324b31 (expect 54324b31)
TB: order table initialised after 2234 polls
TB: frames injected = 8
TB: captured 7 frames = 4 orders + 3 other (IGMP/ARP)
TB: st_rx_drop = 0   st_ot_overflow = 0   st_sent = 4   st_frame_cnt = 4   st_tx_drop = 0
PASS: kernel HBM->HBM order frames == golden
```

Both register windows work (the harness's own `T2K1` identity and the forwarded
`t2t_axil` file at `+0x1000`), the injector and capture agree on the record
format, and the four order frames are byte-identical to `dump_tcp.py`'s output.
Everything the kernel adds on top of the verified datapath is therefore tested
before an hours-long build, which is the only reason to write a testbench for a
harness at all.

## Measuring latency instead of summing it

`data/FINDINGS.md` §7.1 gives unloaded tick-to-trade as ~135 ns by **summing
per-stage FSM state counts**, with a stated error bar of ±1 cycle per stage over
eleven stages. `tb_t2t.sv` tried to measure it properly and documented why it
could only do the back half: frames keep arriving while an order is in flight, so
a "time of the most recent frame" stamp is overwritten by a *later* frame than the
one that caused the order — it reported `min=1`, a meaningless lower bound.
Attributing an order to its causing frame in general needs a tag threaded through
every stage of the datapath.

`rtl/lat_probe.sv` does not need the tag, because on the card the feed comes from
`eth_replay` and **the inter-frame gap is ours to set**. Make the gap exceed the
pipeline depth and only one frame is ever in flight, so "the most recent frame"
*is* the causing frame. No datapath change, no tag, no risk to verified RTL.

The assumption is checked rather than asserted: a sample counts only if its frame
arrived after at least `cfg_quiet` idle RX cycles — a provably empty pipeline —
and samples failing that test are **excluded and counted**, so a run made under
the wrong conditions shows up as a number instead of a wrong answer. The probe
taps the two stream ends only and never touches the datapath, so it cannot
perturb what it measures.

### Measured on silicon

The real 5 M-message AAPL session, replayed from HBM on the U55C, `ap_clk` 300 MHz
/ core 200 MHz, injector gap 512 so every frame meets an empty pipeline:

```
harness : injected=1127057 captured=73 overflow=0 stalls=66
rx      : frames_in=1127057 kept=1122567 cdc_drop=0 hwm=6
feed    : gap=0 ot_overflow=0 oob=465 drops(beat=0 msg=0 delta=0)
strategy: sent=70 pos=800 blocked(pos=36 inflight=0 txfull=0)
tx      : frames=70 next_seq=10000e38 cdc_drop=0

latency : samples=70 excluded=0 orphans=0 (quiet=256 gap=512)
          min=66 cyc (220.0 ns)  avg=84.2 cyc (280.8 ns)  max=133 cyc (443.3 ns)
          hist[2^6..] = 69      hist[2^7..] = 1

PASS: ON CARD real-data order frames == golden      (70/70, byte-identical)
```

**Wire-to-order, measured on hardware: 220 ns minimum, 281 ns mean, 443 ns worst,
over 70 attributable samples with none excluded.** The distribution is tight —
69 of 70 in a single power-of-two bucket — which is what an unloaded pipeline
should look like.

Three of those counters are independent confirmations rather than mere outputs:

- `kept=1,122,567` is *exactly* the good-frame count `mold2eth.py` reported when it
  built the stimulus, so `eth_ip_udp_rx`'s multicast/UDP filter on real traffic
  agrees with the software packer to the frame — including rejecting all 4,490
  frames that were meant to be rejected.
- `oob=465` is *exactly* the out-of-band figure step 4b measured for this AAPL
  session ("465 cases over AAPL's 5M, all deep/stub"). The price ladder's band
  behaviour reproduced on silicon, message for message.
- `gap=0` confirms the real feed has no sequence gaps, so the A/B recovery path is
  not perturbing this run (unlike the synthetic feed — see below).

### The same measurement in simulation, for comparison

Synthetic feed, `make test-latency` (gap 512, quiet 256), core at 200 MHz:

```
TB: latency samples=4 excluded=0 orphans=0
TB: latency (RX cycles) min=107 max=173 avg=131
```

At `ap_clk` = 300 MHz that is **357 ns minimum, 437 ns mean, 577 ns worst** over
four orders, with nothing excluded — every order attributable.

The probe responds to the core clock the way it should, which is a small check on
the instrument as well as the design:

| core clock | min | avg | max (RX cycles) |
|---|---|---|---|
| 220 MHz | 98 | 120 | 158 |
| 200 MHz | 107 | 131 | 173 |

+9 cycles on the minimum for a 10 % slower core — the core-domain part of the path
scaling with the core period, while the `ap_clk`-domain part (frame reception, the
HBM-side FIFOs) does not.

### Latency under load, without threading a tag

`lat_probe` answers the unloaded case and is honest about refusing everything
else. `FINDINGS §7.2`'s burst tail — where the queue dominates and the answer is
microseconds — needs the opposite: a measurement that works precisely when the
pipeline is *full*. `rtl/lat_loaded.sv` is that probe.

The obvious implementation is a timestamp carried alongside every message through
splitter, decoder, order table, ladder, strategy, builder and framer: eight
verified modules, every interface widened, every golden re-confirmed. **None of
that was necessary, because the datapath already threads a unique per-message
field end to end** — the ITCH timestamp. `itch_msg_t.timestamp` survives into
`order_table.o_ts`, into `price_ladder.o_ts`, into `strategy.o_ts`, and `t2t_top`
carries it out as `ord_ts`: *the exchange timestamp of the message that caused
this order*. The identity is already at both ends; only the arrival time was
missing.

So the probe records, for each decoded message, the local cycle at which it
appeared, keyed by its ITCH timestamp; when an order fires citing that timestamp,
the difference is how long that message spent in the machine. The datapath change
is **two observation output ports** — `o_dec_valid`/`o_dec_ts` on `fh_core`, and
the pass-throughs above them. Adding an output cannot change behaviour, which is
the point: these modules are verified and stay that way, confirmed by re-running
step 5's chain test and unit suite afterwards.

The correlation slot is a **fold** of the timestamp, not its low bits — ITCH
timestamps are nanoseconds since midnight and consecutive messages are hundreds
to thousands of nanoseconds apart, which clusters exactly the way `FINDINGS §4`
found raw `order_ref`s clustering in the order table (24,142 overflows raw versus
132 mixed). Same lesson, same one-XOR fix.

The two probes are complementary, and the synthetic run shows it directly at gap
48 — below the quiet window, so `lat_probe` refuses every sample while
`lat_loaded` measures all four:

```
TB: latency samples=0 excluded=4 orphans=0            <- unloaded probe, correctly refuses
TB: loaded-latency samples=4 misses=0                 <- loaded probe, measures anyway
TB: loaded latency (core cycles) min=33 max=73 avg=51
PASS: kernel HBM->HBM order frames == golden
```

**What it measures, precisely:** decoder output to order emit, in *core* clock
cycles. That interval contains the message FIFO, the order table, the delta FIFO,
the ladder and the strategy — every queue on the path, which is where §7.2's burst
tail lives. It excludes the fixed front end (RX, CDC, splitter, decode), which
does not queue and is already inside `lat_probe`'s figure. The two numbers are
complementary, not comparable: wire-to-order under load is this plus that fixed
front end.

A `misses` counter is exposed alongside: an order citing a message whose slot has
since been reused counts as a miss rather than a wrong latency. On the synthetic
run it is zero.

#### Measured on silicon

The probe first reproduces simulation exactly on the same synthetic stimulus —
min 33, avg 51.2, max 73 core cycles on the card against min 33, avg 51, max 73 in
xsim. Checking an instrument against a known answer before asking it an unknown
one is the whole reason that run was done first.

Then the real 5 M-message AAPL replay, sweeping `--gap` to vary offered load. 70
orders and 70 samples with 0 misses at every non-saturated point:

| offered | msg drops | golden | min | mean | max |
|---|---|---|---|---|---|
| 25.1 M msg/s | 0 | PASS | 107.0 ns | **159.2 ns** | 330.2 ns |
| 29.6 M msg/s | 0 | PASS | 107.0 ns | **172.7 ns** | 358.1 ns |
| 32.6 M msg/s | 0 | PASS | 107.0 ns | **184.5 ns** | 432.6 ns |
| 36.1 M msg/s | 0 | PASS | 107.0 ns | **206.1 ns** | 567.4 ns |
| 40.6 M msg/s | 0 | PASS | 107.0 ns | **237.9 ns** | **730.2 ns** |
| 46.3 M msg/s | 389,994 | DIFF | — saturated — | | |

The floor never moves (23 cycles at every load), the mean grows 1.49× while the
max grows 2.21× over the same range — the tail is the thing that degrades — and
saturation arrives abruptly between 40.6 and 46.3 M msg/s. Every non-saturated
point is byte-identical to the golden: the design degrades by dropping and
counting, never by emitting a wrong order. Full analysis in `FINDINGS §7.5.1`.

The binding limit is **messages per second, not bytes per second**, which is worth
stating because it is easy to get wrong: a 512-bit beat carries several ITCH
messages and the order table costs ~6 core cycles each, so the design saturates at
a byte rate far below what the 512-bit path could carry. A load sweep computed
from beat rate will put the knee in the wrong place by a factor of three.

#### A saturating run wedged the card until a device reset — fixed

**Was:** after any run that drops messages, the next run produced `sent=0` even at
a gap known-good from clean — RX counters identical (`kept=1,122,567`, `oob=465`),
zero drops, no orders. `K_CTRL_SOFT_RESET`, which does hold `core_rst_n` and does
re-run the order table's clear sweep, did not recover it; only `xrt-smi reset` did,
so the sweep above reset the device before every point.

**The counters said where it was not.** RX identical to a clean run means frames
arrive and are kept. `oob=465` identical means the deltas reach the *price ladder*
and are classified the same way. And `strategy: sent=0 blocked(pos=0 inflight=0
txfull=0)` means the signal never fired **and** was never gated — which acquits the
risk gate and points at the book itself.

**Cause: an `initial` block standing in for a reset.** `price_ladder.sv` initialised
`bidq`/`askq` with `initial`. That is correct for power-on and meaningless at reset:
the arrays infer BRAM, whose contents the bitstream loads once, and `rst_n` clears
the occupancy flops but cannot touch the memory. Because the update path is
read-modify-write, stale quantities compound — an add accumulates onto a stale
value, a later removal computes a nonzero remainder and never releases the level,
the book fills with phantom levels, best bid and best ask cross, the spread never
reads tight, and the strategy stops firing silently. Only a device reprogram
recovered it because reprogramming is what reloads `initial`.

**Simulation cannot see this**, which is why it survived every testbench: `initial`
runs at time 0 there, so the array looks cleared either way. `order_table.sv`
already carried the same lesson for URAM, which cannot be initialised at all —
BRAM is the narrower case that comes up *correct* and only diverges once something
asserts reset without reloading the bitstream, so the earlier fix did not
generalise. The general rule this design now follows: **if a memory's contents
matter after reset, sweep it; `initial` is a power-on convenience, not a reset.**

**Fixed and verified on silicon.** An explicit clear-on-reset sweep over both
arrays, `i_ready` held low while it runs. On the rebuilt bitstream, a genuinely
saturating run (`--gap 16`, `drops(msg=1,682,346)`, `sent=0`) followed immediately
by `--gap 512` with **no device reset**:

```
strategy: sent=70 pos=800 blocked(pos=36 inflight=0 txfull=0)
tx      : frames=70 next_seq=10000e38 cdc_drop=0
latency : samples=70 excluded=0  min=62 cyc (206.7 ns)  avg=78.9  max=124
PASS: recovered from saturation with NO device reset, golden matched
```

The build closes at the same 215 MHz with all timing met (design WNS +0.003 ns,
core +0.011 ns, 0 of 525,165 endpoints failing), and the sweep costs no latency —
33/51/73 core cycles unchanged. The load sweep no longer needs its per-point reset.

This cost real time and nearly produced a wrong conclusion: the first sweep looked
like a dead card, because the failures were being read off `feed: gap=` (MoldUDP64
sequence gaps, which report garbage in this state) instead of
`drops(msg=)`, which is the counter that actually says the pipeline overran. Two
different faults — genuine saturation and this wedge — were being seen as one.

One process note worth keeping: the first attempt at the verification above ran
the saturating pass and the recovery pass in one script, and the saturating pass
silently did nothing because the device had not finished coming back from an
earlier reset. The recovery pass then "passed" from a clean card — a green result
that tested nothing. The precondition has to be *asserted*, not assumed: the run
above is only meaningful because `drops(msg=1,682,346)` was confirmed first.

### The synthetic feed at wide gaps: an open card-versus-simulation disagreement

On the card, the synthetic stimulus matched the golden at gap 48 and **did not**
at gap 512 — 6 order frames instead of 4, the second reading `BUY @ 1501000`
where the golden says `SELL @ 1500000`. The explanation recorded at the time was
that `gen_itch.py` deliberately builds `test.mold` with a sequence gap and a
duplicate (`gaps=[(11,2)], dups=1`), that `feed_ab_arb` recovers gaps on a
**timeout**, and that how long it waits relative to the next frame's arrival is
exactly what the gap knob changes — so the set of messages reaching the book
would be gap-dependent by design.

**Simulation does not reproduce that**, and it should, because the timeout is
counted in cycles and the gap knob is counted in cycles. Sweeping the injector
across two orders of magnitude, on the current RTL:

| gap (idle cycles) | 48 | 128 | 256 | 512 | 1024 | 4096 |
|---|---|---|---|---|---|---|
| orders sent | 4 | 4 | 4 | 4 | 4 | 4 |
| byte-identical to golden | yes | yes | yes | yes | yes | yes |

Phase B agrees at 48, 512 and 4096 as well. So the timing-dependence the
explanation predicts is not visible anywhere in simulation, and the explanation
should not be trusted until the card is re-run — a plausible-sounding cause that
the testbench contradicts is a hypothesis, not a finding.

What is *not* in doubt is the real feed: `itch2mold.py` repacks contiguous
sequences, so it has `gap=0`, the recovery timeout never fires, and the golden
diff holds at any injector gap. That is why the silicon latency run above is both
attributable *and* golden-verified, and why nothing quoted from it depends on
resolving this.

#### Resolved: the card agrees, and the bitstream was stale

Re-run on the card across the same sweep the testbench was put through, resetting
the device before each point:

| gap (idle cycles) | 48 | 128 | 256 | 512 | 1024 | 4096 |
|---|---|---|---|---|---|---|
| orders sent | 4 | 4 | 4 | 4 | 4 | 4 |
| byte-identical to golden | yes | yes | yes | yes | yes | yes |

**Four at every gap, golden PASS at every gap** — including 512, where the card
previously produced six. The card and the testbench now agree exactly, so the
earlier observation belonged to a bitstream predating the current RX path
(`feed_ab_arb` was integrated in `46c95d6`), which is the benign of the two
possibilities this section was written to distinguish.

The timeout-race explanation is therefore **withdrawn**, not confirmed: it
predicted gap-dependence that neither the testbench nor the current bitstream
shows. It is kept above rather than deleted because the reasoning was sound and
only the premise was stale, and because a plausible cause that the testbench
contradicts is exactly the kind of thing worth leaving visible after it turns out
to be wrong.

### Testing the instrument, not just the datapath

`lat_probe` produces the number that gets quoted, which makes it exactly the wrong
thing to leave tested-by-implication. The full-chain run shows it gives plausible
values; it cannot construct the cases that decide whether those values are
*attributable*. `make test-latprobe` drives each one directly:

| case | what it pins down |
|---|---|
| order with no preceding frame | counted as an orphan, not measured against a zero stamp |
| properly quiet frame | one sample, and its value equals the testbench's own reading |
| second order from the *same* frame | also counted, strictly larger, min/max correct |
| IGMP report and ARP reply on TX | ignored — `axis_tx_arb` merges them onto the same port |
| **frame arriving too soon after another frame** | **excluded and counted, not reported short** |
| histogram and running sum | bucket total equals the sample count; sum equals the samples |
| `clear` | every counter returns to zero |

The expected latency is **re-derived independently**: the testbench watches the
same two observable events (first RX beat, first accepted TX beat) with its own
cycle counter and its own framing trackers, and requires the DUT to agree. A
shared bug would have to be a shared misreading of the interface rather than a
shared line of code — the same reason step 6 re-derives its checksums with scapy.

Writing it immediately corrected a misconception of mine about the guard. My first
attempt at the exclusion case simply idled for `cfg_quiet - 1` cycles and expected
a rejection; the probe accepted the sample and was right to. `cfg_quiet` counts
consecutive idle **RX** cycles, and TX traffic does not reset that count — which is
correct, because what makes attribution unsafe is *another frame* still being
processed, not an outgoing report. Provoking the guard needs a preceding RX frame,
and the test now says so explicitly.

Two things are worth reading carefully before comparing that to §7.1's 135 ns,
because they are **not the same measurement**:

- **This starts earlier.** The stamp is the frame's *first RX beat*. The ITCH
  message that triggers the order sits somewhere inside the frame, so at stamp
  time the causal message has not arrived yet — frame reception is inside this
  number and outside §7.1's. For wire-to-trade that is the honest place to start:
  the wire is where the clock starts.
- **The spread is real, not noise.** One MoldUDP64 frame carries many messages, so
  a single frame legitimately produces several orders at increasing delays from
  the same arrival. `min` is the closest analogue to §7.1's single-message path.

So the summed estimate is not refuted — it measured stage depth in core cycles
from the RX CDC onward, and it is roughly consistent once frame reception and both
clock crossings are added back. What changes is that the headline number now has a
measurement behind it, and a histogram, and a guard that says when not to trust
it. Latency **under load** — FINDINGS §7.2's burst tail, where the queue dominates
and the answer is microseconds — genuinely does need the threaded tag, because a
burst has many frames in flight by definition. That remains future work, and is
stated here rather than quietly folded into these numbers.

## Resources and timing, and one self-inflicted critical path

Out-of-context synthesis of the whole kernel for `xcu55c-fsvh2892-2L-e`,
`ap_clk` 300 MHz / `ap_clk_2` 220 MHz:

| | kernel | step 5's `t2t_axil` | delta |
|---|---|---|---|
| CLB LUTs | 54,977 (4.2 %) | 46,371 | +8,606 |
| CLB Registers | 45,546 (1.8 %) | 23,817 | +21,729 |
| Block RAM | 64.5 | 40 | +24.5 |
| URAM | **66** | 66 | **unchanged** |
| DSP | 2 | 2 | unchanged |

URAM not moving is the expected result and the one worth checking: the order
table is the design, and the harness must not touch it.

**The first synthesis missed 300 MHz, and the critical path was mine, not the
datapath's:**

```
Slack (VIOLATED): -0.196ns
  Source:      u_replay/rptr_reg[2]/C
  Destination: u_replay/araddr_q_reg[60]/D
  Logic Levels: 18  (CARRY8=10 LUT2=2 LUT3=2 LUT5=2 LUT6=2)
```

Two avoidable mistakes in `eth_replay`, both of the same kind — computing
something combinationally that did not need to be:

1. Read credit was recomputed every cycle as `DEPTH - (wptr - rptr) - inflight`:
   two 32-bit subtracts and a signed compare, which dragged the buffer's *read
   pointer* onto the critical path.
2. That result then gated a **64-bit address adder** whose operand came from
   `beats_left → this_burst → shift`, chaining a second carry path onto the first.

The fixes are that credit is now an **incremental register** (issue `-BURST`,
emitter pop `+1`; a returning beat leaves it alone, because it only converts a
promised slot into an occupied one) and that bursts are **fixed length**, so the
address is one 64-bit add off two registers. The image is padded host-side to a
whole number of bursts to make that safe.

| | WNS `ap_clk` | WNS `ap_clk_2` |
|---|---|---|
| combinational credit, variable burst | **−0.196 ns** (fails) | +0.079 ns |
| registered credit, fixed burst | **+0.553 ns** (meets) | +0.079 ns |

0.749 ns for slightly *fewer* LUTs (55,125 → 54,977), and the replay is
bit-identical — same four orders, same 98/158/120-cycle latency, same golden
diff. `ap_clk_2` does not move, which is the confirmation that nothing in the
datapath was disturbed. The path now runs from the TX arbiter's select into the
capture block's byte accumulator at 2.762 ns, with the popcount as the next thing
to attack if that domain ever needs to reach 322 MHz for Phase B.

## Two clocks means asking for two clocks

The design has two clock domains on purpose, and getting Vitis to actually build
two took three attempts. Each failure looked like a design problem and was not.

**Attempt 1 — `--clock.freqHz`.** Deprecated in 2025.2, accepted with a warning,
and then ignored:

```
WARNING: [v++ 60-1603] The supplied option 'clock.freqHz' is deprecated.
```

The entire kernel — all 126,400 endpoints, order-table URAMs included — was built
on the platform's default 300 MHz. The datapath closes at 200-220 MHz, so it
missed by **1.789 ns** on the order table's URAM read path. A deprecated option
that still parses is the expensive kind.

**Attempt 2 — `--freqhz`.** The current spelling, no warning, and the config graph
recorded exactly what was asked for:

```
ap_clk"   xd:frequency="300000000"
ap_clk_2" xd:frequency="200000000"
```

The result was **bit-identical**: WNS −1.789, the same 300 MHz clock, the same
path. The tell was the identical third decimal place. `dr.bd.tcl` showed the
request arriving as a property —
`set_property HDL_ATTRIBUTE.ap_clk_2.FREQ_HZ {200000000}` — and nothing binding
the pin to a clock. **Setting a frequency is not the same as binding a clock.**

**Attempt 3 — `--clock.id`.** Which fails informatively if pointed at the wrong
clock:

```
ERROR: [CFGEN 83-2244] --clock.id directive specified with clock id 0, which is
not a fixed clock. Only fixed clocks can be used as reference clocks to generate
additional clocks. Clock ids for fixed clocks are {2}.
```

So the platform's clock IDs 0 (300 MHz) and 1 (500 MHz) are *scalable outputs*,
and ID 2 (100 MHz) is the only *fixed reference* from which a new clock can be
generated. With `--clock.id 2:t2t_kernel_1.ap_clk_2` Vitis instantiates a clock
wizard off that reference and the second domain finally exists:

| clock | period | endpoints | setup WNS |
|---|---|---|---|
| `clk_out1_ulp_clk_wiz_0` (core) | 5.000 ns / **200 MHz** | 48,082 | **+0.257** |
| `clk_kernel_00` (`ap_clk`) | 3.333 ns / 300 MHz | 76,807 | **+0.161** |

Note the generated clock is called `clk_out1_ulp_clk_wiz_0`, not `ap_clk_2` —
which is why the CDC hook below discovers clocks by following the kernel's clock
pins instead of looking them up by name.

**The cheap way to test this.** `--to_step vpl.create_bd` stops the link right
after the block design is built, which is where clock binding happens: about a
minute, against two hours for a full build. Every one of these attempts could
have been diagnosed that way, and the last one was.

**And the check that catches it.** The kernel clock summary in
`hw_bb_locked_timing_summary_init.rpt` appears roughly 25 minutes in and states
the frequencies outright. Reading it is how attempt 3 was confirmed and how
attempts 1 and 2 should have been caught, instead of waiting for a placement WNS
that blamed the order table for running at a frequency nobody intended.

## The constraint that has to travel inside the .xo

The first link ran for two hours and was never going to close, for a reason that
had nothing to do with the RTL. Mid-route:

```
INFO: [Route 35-416] Intermediate Timing Summary | WNS=-1.292 | TNS=-2573.227
WARNING: [Route 35-3387] High violations detected on bus-skew constraints
... later:  WNS=-2.657 | TNS=-21179.570
```

`v++` builds the platform's constraint set and knows nothing about this design's
internal clock domains. It derives `ap_clk` and `ap_clk_2` from the same clocking
wizard, so Vivado treated them as **synchronous** and timed all 1,565 `cdc_fifo`
Gray-pointer and synchroniser paths as genuine 300 ↔ 220 MHz transfers. Between
two related but incommensurate clocks the setup window collapses toward their beat
period — here **0.30 ns** — so no routing effort could ever have met it. The whole
point of `cdc_fifo` is that those paths are asynchronous; the constraints simply
never said so, because
[step5-board/syn/t2t_axil_cdc.xdc](../step5-board/syn/t2t_axil_cdc.xdc) is read by
the out-of-context flow and does not ship with the kernel.

The fix is `syn/t2t_kernel_cdc.xdc`, packaged **into the `.xo`** with
`SCOPED_TO_REF t2t_kernel` and `PROCESSING_ORDER late`, so it travels with the
kernel and is applied against the synthesised netlist.

"Into the `.xo`" has to be taken literally. Adding the file from `syn/` records
its path in `component.xml` *relative to the component root* — `../syn/...` —
which escapes the IP, and `v++` unpacks the `.xo` into an `ip_repo` of its own
where no such directory exists:

```
CRITICAL WARNING: [IP_Flow 19-663] Failed to copy file
  '.../_x/link/int/xo/ip_repo/syn/t2t_kernel_cdc.xdc', it does not exist.
ERROR: [IP_Flow 19-167] Failed to deliver one or more file(s).
ERROR: [VPL 19-98] Generation of the IP CORE failed.
```

That one kills the link about a minute in, which is at least a cheap failure. The
packaging script copies the file to `packaged_kernel/src/` and adds it by its
in-component path, and `unzip -l t2t_kernel.xo` is the check that it actually
shipped.

### Shipped, delivered, and still not applied

It ships and it is delivered — and it still does not constrain place and route.
`SCOPED_TO_REF t2t_kernel` scopes it to the IP, so it reaches the IP's own
out-of-context synthesis and stops there. The top-level implementation never sees
it, and the init timing report says so plainly: the 1,565 crossings between the
two kernel clocks (614 one way, 951 the other — the same counts
`report_clock_interaction` reports out of context) are **timed rather than cut**,
with hold failing on every one of them (`WHS -0.571`, `THS -348`).

Those are false paths — `cdc_fifo` is Gray-coded with `ASYNC_REG` synchronisers,
so silicon is unaffected — but the router spends real effort inserting delay to
fix hold on paths that never needed it.

The answer is `syn/impl_cdc_hook.tcl`, applied at top-level implementation via
`--config` (`run.impl_1.STEPS.OPT_DESIGN.TCL.PRE`). Being a `.tcl` rather than an
`.xdc` it may use `if`, and it finds the clocks by following the kernel's clock
pins because the generated core clock is named `clk_out1_ulp_clk_wiz_0` rather
than `ap_clk_2`. The ini is generated with an **absolute** path, because Vivado
resolves `TCL.PRE` relative to the deeply nested implementation run directory —
a repo-relative path resolves to nothing and the hook silently never runs, which
is the same failure mode as the packaged XDC, one level up.

Three variations on one lesson: a constraint file that exists, that is packaged,
and that is delivered has still done nothing until a report says the paths are
cut.

### An .xdc is not a Tcl script

Worth its own note, because the first version of that file looked correct and did
nothing. Each constraint was wrapped in `if {[llength $apclk]} { ... }` as a
defensive guard against empty lookups. Vivado's XDC parser accepts only a
restricted command set:

```
CRITICAL WARNING: [Designutils 20-1307] Command 'if' is not supported
                  in the xdc constraint file. [t2t_kernel_cdc.xdc:37]
```

The guarded constraints were skipped, the build carried on, and the only symptom
was a timing report blaming the design. `report_clock_interaction` is what
settles it, and the `synth` target now writes one every run:

| | `ap_clk → ap_clk_2` | `ap_clk_2 → ap_clk` |
|---|---|---|
| with `if` guards (silently skipped) | `-0.38` — No Common Clock, **Timed (unsafe)** | `-0.08` — Timed (unsafe) |
| straight-line constraints | **Ignored — Asynchronous Groups** | **Ignored — Asynchronous Groups** |

Two rules earned here: constraints that matter belong inside the packaged kernel,
and a constraint file that "looks applied" is worth nothing next to a clock
interaction report that says *Asynchronous Groups*.

## Two clocks means asking for two clocks

The datapath closes at 200 MHz and the harness runs at 300, so the kernel needs
two genuinely different clocks. Getting them took three failed builds, and the
failures all looked like a timing problem in the design when none of them was.

**A frequency request is not a clock.** `--freqhz 200000000:t2t_kernel_1.ap_clk_2`
is accepted, appears in the config graph, and even reaches the block design as
`HDL_ATTRIBUTE.ap_clk_2.FREQ_HZ {200000000}` — and does nothing. The whole kernel
lands on the platform's default clock:

```
clk_kernel_00_unbuffered_net  3.333 ns  300.000 MHz   126,400 endpoints   WNS -1.789
clk_kernel_01_unbuffered_net  2.000 ns  500.000 MHz         434 endpoints
```

126,400 endpoints — the entire datapath, order-table URAMs included — being asked
to run at 300 MHz. The failing path was real and the design was innocent:

```
Source:      .../u_fh/u_otab/g_way[7].u_mem/mem_reg_uram_0/CLK  (URAM288)
Destination: .../u_fh/u_otab/sel_ent_reg[qty][4]/D
Path Group:  clk_kernel_00_unbuffered_net  {period=3.333ns}
```

The tell was that two consecutive builds produced **bit-identical** WNS of −1.789.
A design responding to a changed constraint does not repeat itself to three
decimal places.

**Binding needs a fixed reference clock**, and the platform says which:

```
ERROR: [CFGEN 83-2244] --clock.id directive specified with clock id 0, which is
not a fixed clock. Only fixed clocks can be used as reference clocks to generate
additional clocks. Clock ids for fixed clocks are {2}.
```

Ids 0 (300 MHz) and 1 (500 MHz) are scalable *outputs*; id 2 (100 MHz) is the only
fixed *reference*. With `--clock.id 2:t2t_kernel_1.ap_clk_2` alongside the
frequency, Vitis instantiates a clock wizard off that reference and a second clock
actually appears:

| clock | period | endpoints | setup WNS |
|---|---|---|---|
| `clk_out1_ulp_clk_wiz_0` (core) | 5.000 ns / **200 MHz** | 48,082 | **+0.257** |
| `clk_kernel_00` (`ap_clk`) | 3.333 ns / 300 MHz | 76,807 | **+0.161** |

Note the name: the generated core clock is `clk_out1_ulp_clk_wiz_0`, not anything
containing `ap_clk_2`. Anything that looks clocks up by name has to cope with that.

### The constraints have to be where the router can see them

`syn/t2t_kernel_cdc.xdc` is packaged into the `.xo` and *is* delivered — it appears
in `prj.gen/.../ulp_t2t_kernel_1_0/src/`. But `SCOPED_TO_REF` confines it to the
IP's own out-of-context synthesis, so at top-level implementation the 1,565
crossings were still being timed, with hold failing on every one (`WHS -0.571`,
`THS -348` over 614 paths one way and 951 the other).

`syn/impl_cdc_hook.tcl`, wired in through `--config` as an `OPT_DESIGN.TCL.PRE`
hook, applies them where place and route actually run. It finds the clocks by
following the kernel's clock pins rather than by name — necessary, given
`clk_out1_ulp_clk_wiz_0` — and being a `.tcl` rather than an `.xdc`, `if` is legal
in it. Confirmed in the implementation log:

```
t2t CDC hook: ap_clk  -> clk_kernel_00_unbuffered_net
t2t CDC hook: ap_clk_2 -> clk_out1_ulp_clk_wiz_0
t2t CDC hook: asynchronous clock groups APPLIED
```

### One read port, or the router gives up

With the clocks right and the crossings cut, the build then failed in *routing*:

```
ERROR: [VPL 35-2] Design is not legally routed. There are 4797 node overlaps.
ERROR: [VPL 18-1000] partially-conflicted nets: u_capture/rd[459]_i_2_n_0,
                     u_capture/rd[463]_i_2_n_0, u_capture/rd[441]_i_2_n_0 ...
```

Every named net is a bit of one multiplexer. `eth_capture` read its frame buffer
from two states with two different index expressions (`fbuf[0]` and
`fbuf[wcnt+1]`), which cannot map onto a block RAM read port — so Vivado built a
576-bit-wide 32:1 mux in LUTs, and the congestion defeated the router. Collapsing
it to a single `fbuf[rd_addr]` with one address register infers simple dual-port
block RAM and the mux disappears. The `ram_style = "block"` attribute was already
there and did not help: an attribute is a request, and two read expressions make
it unsatisfiable.

## Why the real latency measurement belongs on the card

Not a preference — a measurement. Orders are rare in this feed, and they cluster
later in the session:

| AAPL slice | BBO records | orders fired |
|---|---|---|
| 300 k messages | 7 | 1 |
| 1 M messages | 238 | 1 |
| 5 M messages | 1,779 | **52** |

A histogram built on one sample says nothing, so a real latency distribution needs
the whole 5 M-message replay. Packed, that is **327 MB / 1,127,057 frames /
5.11 M beats** — and with the inter-frame gap the latency probe requires
(512 cycles, so each frame meets an empty pipeline) it is roughly 600 M cycles.

- **In xsim:** hours, for a number the hardware can produce exactly.
- **On the card:** ~2 seconds at 300 MHz, and it fits in one 512 MB HBM bank.

So simulation keeps the synthetic feed as the functional golden-diff check (four
orders, deterministic, seconds to run), and the real distribution is a hardware
job. That asymmetry is the point of this step rather than an obstacle in it.

The packed image also carries the 4,490 frames `mold2eth.py` classes as rejects
alongside the 1,122,567 good ones, deliberately: they exercise the
`eth_ip_udp_rx` multicast/UDP filter on real traffic, and the filtering shows up
as the gap between `st_frames_in` and `st_frames_kept`.

## Phase B groundwork: reaching the QSFP from a Vitis kernel

Phase B replaces `eth_replay` with a real `cmac_usplus` in GT near-end loopback,
so that MAC, PHY and SerDes are *inside* the latency number rather than outside
it. Before writing any of that, two gates were tested, because both are cheap to
check and expensive to assume.

**Gate 1 — is the MAC available?** `xilinx.com:ip:cmac_usplus:3.1` exists for
`xcu55c`. Yes.

**Gate 2 — will `v++` connect a kernel to the QSFP?** This one took several
experiments and the answer is *only if you do it yourself*:

- there is **no** `--connectivity.gt` directive (the family is `nk`, `noc.*`,
  `region`, `sc`, `slr`, `sp`, `spalloc.*`);
- declaring a `gt_serial_port` bus interface of the correct type
  (`xilinx.com:interface:gt:1.0` / `gt_rtl:1.0`, port maps `GRX_P/GRX_N/GTX_P/
  GTX_N`) changes nothing — the generated `dr.bd.tcl` instantiates the kernel and
  makes no GT connection at all;
- renaming that interface to the platform's own resource name (`io_gt_qsfp0_00`)
  does not help either.

What *does* work is connecting it by hand at the one point where both sides exist
as block-design objects, through `--advanced.param
compiler.userPostSysLinkOverlayTcl=<tcl>` (`gtgate/gt_connect.tcl`):

```
GT hook: gt_pin=1 gt_port=1  rc_pin=1 rc_port=1
GT hook: intf ports on the BD: ... /io_clk_qsfp0_refclka_00 /io_clk_qsfp1_refclka_00
                                   /io_gt_qsfp0_00 /io_gt_qsfp1_00
GT hook: SERIAL PORT CONNECTED
GT hook: REFCLK CONNECTED
```

Both QSFP groups and both reference clocks are reachable. The platform had been
telling us so all along — `ext_metadata.json` declares `io_gt_qsfp0_00` on
`QUAD_X0Y6` with refclk `io_clk_qsfp0_refclka_00`, and the platform's own
`postopt.tcl` package-pins `io_gt_qsfp0_00_gtx_p[0..3]` and friends — but nothing
in the flow wires a user kernel to them.

`gtgate/` holds the throwaway kernel that established this: a control slave and
four differential lane groups, nothing else. It exists to answer the connectivity
question in minutes rather than discovering the answer inside an hours-long build,
the same way `--to_step vpl.create_bd` answered the clock-binding question.

**Gate 3 — does the MAC configure for this card's quad?** `syn/gen_cmac.tcl`
generates it, and every parameter is read back rather than assumed:

```
CMAC_CFG CMAC_CAUI4_MODE = 1          CMAC_CFG GT_GROUP_SELECT = X0Y24~X0Y27
CMAC_CFG NUM_LANES = 4x25             CMAC_CFG INCLUDE_RS_FEC = 0
CMAC_CFG GT_REF_CLK_FREQ = 161.1328125  CMAC_CFG USER_INTERFACE = AXIS
=== CMAC GENERATED ===
```

The one trap: `GT_GROUP_SELECT` wants the **lane range**, not the quad name. The
platform says `QUAD_X0Y6`, and the IP rejects `X0Y6` outright — valid values are
`X0Y24~X0Y27` (quad 6, i.e. qsfp0) and `X0Y28~X0Y31` (qsfp1). Reading the
parameters back after setting them is what catches that class of thing, the same
way the clock summary caught a frequency that was recorded and ignored.

Two facts from the generated interface settle the remaining design questions:

- **`gt_loopback_in` exists**, so near-end loopback is a port on the MAC — the
  QSFP cages stay empty and no optics are needed, exactly as Phase B assumed.
- Its GT pins are named `gt_rxp_in` / `gt_rxn_in` / `gt_txp_out` / `gt_txn_out`
  with `gt_ref_clk_p/n` — **the same names the gate kernel already connected**, so
  the packaging proven in Gate 2 carries over unchanged.
- `gt_txusrclk2` is the 322.265625 MHz stream clock the MAC hands back, which
  becomes the kernel's stream-side clock in place of `ap_clk`.

## Phase B (built): the frames become signals

All three gates passed, so Phase B is `rtl/t2t_kernel_b.sv` — the same datapath,
with a real `cmac_usplus` and the GT in near-end PMA loopback:

```
  HBM -> eth_replay -> [S&F] --\
                                >-- arb -> CMAC TX -> GT serializer
  t2t_axil TX ------> [S&F] --/                          |
                                                  near-end PMA loopback
                                                         |
  t2t_axil RX <---------------------------- CMAC RX <----/
  eth_capture <- [CDC] <- TCP filter <-----------'
```

Every feed frame is now 64b/66b encoded, serialized at 25.78125 Gb/s on four
lanes, recovered by the GT's CDR, block-locked, lane-aligned, FCS-checked and
handed back. The order frames the strategy produces make the same trip outward.
The golden diff therefore means something stronger than it did in Phase A: not
"the datapath computes the right orders" but "the right orders come off a 100
Gb/s MAC".

The datapath itself is untouched. `t2t_axil` is instantiated with exactly the
clocks it was written for — a 322.265625 MHz wire side, a slower core, a separate
AXI-Lite domain — which Phase A had to fake with `ap_clk`. This is the first
build in which the CMAC clock in the design is an actual CMAC clock.

### Near-end loopback makes the measurement wire-to-wire

The probe taps are **both on the MAC's RX port**, and that is the whole point.
Write `T_rx` for the MAC's receive latency, `T_tx` for its transmit latency, and
`D` for everything this design does between them. Stamping when the *feed* frame
emerges from MAC RX and resolving when the *order* frame comes back in through
MAC RX measures

```
D + T_tx + T_rx
```

because the order has to cross the transmitter, the serial loop and the receiver
to return. Wire-to-wire on a real network is

```
T_rx + D + T_tx
```

— the same three terms. So Phase B measures the number this project has only ever
*summed*, with both halves of a real 100G MAC inside it, and the only overcount
is the SerDes round trip inside the GT.

Resolving on the beat the MAC *accepts* for transmission was tried first and is
strictly weaker: it excludes `T_rx` and `T_tx` both, and so measures the fabric,
which Phase A already measured. `lat_probe` needed no change to do the better
one, because it already tells the two frame types apart by protocol — and in
loopback they arrive on the same port.

### Four consequences of loopback, and what each cost

**Everything transmitted comes back.** The datapath needs no help — `eth_ip_udp_rx`
filters on MAC, IP and UDP port, so returning TCP and ARP frames fall out there
exactly as junk on a real network would. The *capture* path has no such filter
and it is the path the golden diff reads, so `axis_frame_filter` picks the order
frames out by protocol first. In Phase A capture recorded IGMP and ARP too; in
Phase B the capture count must equal the order count exactly, which is a stronger
check and is asserted in the testbench.

**Our own orders would have destroyed the samples they are evidence of.** An
order frame reappearing on RX a few hundred nanoseconds after it left lands in
the middle of the window where the second and later orders from the same feed
frame are still being emitted. If it re-stamped, `stamp_ok` would go false and
every one of those would be *excluded* rather than measured. `lat_probe` now
stamps only on IPv4/UDP. `idle_cnt` is deliberately **not** filtered the same
way: a returning order really does occupy the RX path, so it must break the quiet
window. Only the decision of *what to stamp* is narrowed, never the check on
whether the pipeline was empty. `tb_lat_probe.sv` case 7 is exactly this.

**A CMAC TX port that starves mid-frame corrupts the frame.** Not a bubble — an
underrun (`tx_unfout`), and the frame goes onto the wire damaged. A source fed
from HBM through an arbiter cannot promise a beat every cycle, so `axis_sf_fifo`
promises it instead: a frame becomes visible to the reader only once its `tlast`
has been written. Two beats of latency on the order path (~6 ns at 322 MHz) to
remove a corruption mode. `eth_replay` grew an `m_tready` for the same reason;
Phase A ties it high, so the stall logic constant-folds away and that build is
unchanged.

**Gray code is only safe for a value that changes by one.** The obvious
store-and-forward implementation is a commit pointer that jumps to the end of
each frame at `tlast`, crossed as Gray like `cdc_fifo`'s pointers. That is wrong,
and silently so: a commit pointer moves by the whole frame length, twenty-odd
bits changing together, and a synchroniser can latch an address that was never
written. What crosses is a frame **count**, which does increment by one. The
reader's frame count then has to advance in the same cycle as the pop it belongs
to — the payload memory is synchronous and the port register adds a second slot,
so gating the pop on a count that only advanced two cycles later let the reader
run past the end of the last committed frame and emit whatever the array held. A
one-bit shadow array, read asynchronously at the pop address, closes that.

### Simulation

`make test-b` runs the Phase B kernel against **the same golden** as `test-xsim`
— same stimulus file, same configuration, same capture parser. A Phase B golden
of its own would prove nothing; the claim being tested is that a round trip
through a MAC leaves the order frames byte-identical. It is the same testbench
file too, behind `` `PHASE_B ``, so only the DUT is substituted.

```
TB: CMAC link up (aligned=1) after 1 polls
TB: MAC tx frames  = 15      MAC rx frames = 15    rx errors = 0
TB: MAC tx underrun= 0       capture CDC drops = 0
TB: filter passed  = 4       dropped = 11 (feed + IGMP/ARP)
TB: st_rx_drop = 0   st_ot_overflow = 0   st_tx_drop = 0   capture overflow = 0
TB: latency samples=4 excluded=0 orphans=0
TB: latency (RX cycles) min=130 max=196 avg=160
TB: loaded-latency samples=4 misses=0
TB: loaded latency (core cycles) min=33 max=73 avg=51
PASS: Phase B (through the MAC) order frames == golden
```

Fifteen frames into the GT, fifteen back, zero FCS errors and zero underrun, and
the four orders byte-identical to the golden. `excluded=0` is the loopback filter
working: without it every order after the first from a given frame would be
thrown away. The golden holds at **both** stimulus gaps — 48 and 512 — so the
Phase B result is gap-independent in the same sense Phase A is.

The loaded-latency figures are **identical to Phase A's** (33 / 51 / 73 core
cycles). That is the expected answer, not a null result: the loaded probe
measures decoder-to-order, an interval entirely inside the core, which bolting a
MAC onto the front should not move. It not moving is a consistency check passing.

#### The unloaded delta is a testbench constant, not a MAC measurement

The unloaded probe counts `wire_clk` cycles in Phase B and `ap_clk` cycles in
Phase A, so converting both to nanoseconds on the same synthetic stimulus:

| | cycles (min/avg/max) | period | ns (min/avg/max) |
|---|---|---|---|
| Phase A (`make test-latency`) | 77 / 106 / 139 | 3.3333 ns | 256.7 / 353.3 / 463.3 |
| Phase B (`make test-b-latency`) | 130 / 160 / 196 | 3.10303 ns | 403.4 / 496.5 / 608.2 |
| **delta** | | | **146.7 / 143.2 / 144.9** |

That delta is suspiciously flat across the whole distribution, and the reason is
that **most of it is a constant this testbench chose**: `cmac_wrap.sv` under
`` `CMAC_SIM `` is a behavioural stand-in whose `MAC_LAT = 40` cycles is 124.1 ns
by construction. The residual ~20 ns (6–7 wire cycles) is genuine design cost —
store-and-forward FIFO fill plus the frame filter — but the MAC, PCS and SerDes
term is a parameter, not a measurement.

**So no wire-to-wire latency may be quoted from simulation.** The real IP needs GT
models and tens of microseconds of link training to simulate, and its latency is
obtainable only on the card. What the testbench legitimately exercises is the
kernel logic Phase B adds around the MAC: the arbiter, the store-and-forward
FIFOs, the RX split, the frame filter, and both probes operating across a port
that deasserts `tready` and returns whole frames asynchronously.

### Testing the FIFO the whole thing depends on

Every Phase B frame goes through `axis_sf_fifo`, and a bug in it surfaces in the
kernel testbench as a corrupted order frame with no indication of where it came
from. So it gets driven directly (`make test-sffifo`): random frame lengths
including 1 beat and the 24-beat Ethernet maximum, random write stalls and read
backpressure, and — the check that matters — a per-frame assertion that its
**first** beat never leaves before its **last** beat was written.

Run at four clock ratios, because the failure modes are not symmetric:

| writer → reader | 300 → 322 MHz (feed path) | 300 → 100 MHz | 100 → 322 MHz | equal (order path) |
|---|---|---|---|---|
| high-water mark | 26 / 64 | **64 / 64** | 24 / 64 | 26 / 64 |
| early releases | 0 | 0 | 0 | 0 |
| result | pass | pass | pass | pass |

The slow-reader column is the one worth having: the array goes completely full,
`s_tready` deasserts and the writer has to honour it, and still no frame is
released early and `tvalid` never drops mid-frame with the reader asking — which
is exactly the underrun the MAC would see.

A test that cannot fail is worth nothing, so it was checked against the defect it
was written for. Reintroducing the original frame-count bug — advancing the count
when the last beat reaches the output port rather than when it is fetched — the
testbench reports immediately:

```
FAIL: beat emitted with nothing expected (t=91568)
FAIL: data mismatch at out-beat 1: got ...0001 expected ...0000
```

i.e. the reader ran past the committed region and everything shifted by one beat,
which is precisely the failure and precisely where it starts.

### Three details that decide whether it works at all

**FCS.** The IP is generated with `C_TX_FCS_INS_ENABLE=1` and `C_RX_DELETE_FCS=1`,
so a frame handed in comes back byte-identical. That is not a detail — it is what
keeps the Phase A golden valid. If RX kept the FCS, every captured order frame
would carry four extra bytes and every diff would fail for a reason with nothing
to do with the design.

**Bring-up order.** The receiver cannot align until the transmitter is sending
something, and in loopback the only transmitter is this one. So `ctl_tx_send_rfi`
drives remote-fault ordered sets — valid line traffic, not data — until
`stat_rx_aligned` rises, and only then does `ctl_tx_enable` go high. Data offered
before that would be discarded inside the IP, so `s_tready` is held low until the
link is up rather than accepting frames into a hole, and the kernel refuses a
replay start while the link is down. Otherwise a link that never trained would
look like a datapath that produced nothing.

**init_clk is 100 MHz, exactly.** The IP is generated with `GT_DRP_CLK=100.00`,
which sizes the GT reset controller's internal timers. Feeding it `ap_clk`'s 300
MHz would make every one of those three times too short — the sort of thing that
produces a GT that *sometimes* comes up. A `BUFGCE_DIV` of three off `ap_clk`
gives 100.000 MHz with no MMCM and no extra IP in the kernel, and it joins
`ap_clk`'s group in the CDC hook because the two are genuinely related.

### The build routes, and then is refused a bitstream

Phase B implements completely and **meets every timing constraint**, with the
real CMAC clock in the design:

| clock | frequency | WNS | failing endpoints |
|---|---|---|---|
| `clk_kernel_00_unbuffered_net` (`ap_clk`) | 300.000 MHz | +0.039 ns | 0 |
| `clk_out1_ulp_clk_wiz_0` (`ap_clk_2`) | 215.000 MHz | +0.004 ns | 0 |
| `txoutclk_out[0]` (`wire_clk`, the MAC) | **322.269 MHz** | +0.039 ns | 0 |
| `init_clk` (BUFGCE_DIV ÷3) | 100.000 MHz | +7.187 ns | 0 |

Design-wide WNS +0.003 ns, 0 of 538,539 endpoints failing, "All user specified
timing constraints are met". The 322.269 MHz row is the one that matters: the
datapath runs at the MAC's real recovered clock, and the `init_clk` row confirms
the `BUFGCE_DIV` produced exactly the 100.000 MHz the IP was generated for.

Then `write_bitstream` refused:

```
ERROR: [Common 17-69] Command failed: This design contains one or more cells
for which bitstream generation is not permitted:
level0_i/ulp/t2t_kernel_b_1/inst/u_cmac/u_cmac/inst/i_cmac_usplus_0_top
The following IP(s) require licenses greater than a Design Linking license
to generate bitstream:  cmac_usplus
```

A Design Linking entitlement — which is what Vivado falls back to with no licence
file present, and this machine had none, nor `XILINXD_LICENSE_FILE` nor
`LM_LICENSE_FILE` — permits synthesis and implementation but not a bitstream. AMD
issues the 100G CMAC licence at no cost, but it has to be generated on the
licensing portal and installed, which needs the account holder.

**That has since been done.** A node-locked licence is now installed at
`~/.Xilinx/Xilinx.lic` and the gate passes (see below). The first licence
obtained carried the feature `cmac` — the UltraScale MAC — which does *not*
satisfy an UltraScale+ `cmac_usplus` checkout; it had to be regenerated with the
`cmac_usplus` feature before the gate would pass. The two names differ by one
suffix and the portal offers both.

**This should have been Gate 4, and it wasn't.** Three gates were checked before
writing a line of Phase B — is the IP available, will `v++` connect the GT, does
the MAC configure for this quad — precisely so that an hours-long build would not
be the thing that discovered a blocker. The one gate not checked was whether the
IP may be turned into a bitstream, and that is the one that stopped it, 68 minutes
into implementation. **Availability in the catalogue is a different question from
permission to build**, and every earlier step succeeding says nothing about the
last one, because Design Linking is precisely the entitlement that lets synthesis
and implementation through.

That gate now exists as `make gate-license` (`syn/gate_license.tcl`), and
`xclbin-b` depends on it. With the licence installed it reports:

```
=== LICENCE GATE: environment ===
  XILINXD_LICENSE_FILE = <unset>
  LM_LICENSE_FILE      = <unset>
  licence files  : /home/wlstjr4425/.Xilinx/Xilinx.lic
=== LICENCE GATE: cmac_usplus ===
  VLNV           : xilinx.com:ip:cmac_usplus:3.1
  all keys       : cmac_usplus@2020.05 cmac_an_lt@2020.05
                   ieee802d3_rs_fec_full@2018.04 ieee802d3_rs_fec_only@2018.04
  gated feature  : cmac_usplus   (optional AN/LT and RS-FEC keys not required
                   by this design's configuration)
  ---> LICENSED. FlexLM grants a checkout of 'cmac_usplus'.
=== LICENCE GATE: PASS -- every listed IP may be built into a bitstream ===
```

The feature that matters is **`cmac_usplus`**; `cmac_an_lt` (auto-negotiation and
link training) and the two RS-FEC keys are for configurations this design does
not use (`INCLUDE_RS_FEC 0`, no AN/LT), so the gate deliberately checks only the
base feature rather than demanding all four. The check discriminates rather than
failing everything — pointed at `axi_register_slice` or `clk_wiz` it reports an
empty key list and passes. Takes seconds; the omission cost 68 minutes.

One correction worth recording, because the first version of this gate gave a
false answer: it originally read the IP's `LICENSE_STATUS` property, which
reports what the *catalogue* believes and does not attempt a checkout. It now
shells out to `lmutil lmdiag` and requires FlexLM to actually grant the feature,
which is the only question that matches what `write_bitstream` will ask. On this
host `lmutil` additionally needs invoking through `/lib64/ld-linux-x86-64.so.2`,
because it is linked against an LSB loader the distribution does not ship.

`SKIP_LICENSE_GATE=1` overrides it, which is worth having: implementation and the
timing report above are entirely valid without a licence, and reproducing them is
a legitimate reason to run the build. Only `write_bitstream` is refused.

### With the licence in hand, the next blocker was timing

The licence being installed did not produce a bitstream. The first `make xclbin-b`
run after it was granted got through synthesis, placement and routing — and was
then stopped 7 minutes into bitstream generation by Vitis's own timing gate:

```
ERROR: [VPL 101-2] design did not meet timing ...
system clock: clk_out1_ulp_clk_wiz_0; slack: -0.022 ns
```

`write_bitstream` was never reached, so this says nothing about the licence; the
gate that refused it is `_full_write_bitstream_pre.tcl`, which requires WNS ≥ 0 on
every unscalable system clock. Two domains had failed:

| clock | frequency | WNS | TNS | failing endpoints |
|---|---|---|---|---|
| `clk_kernel_00_unbuffered_net` (`ap_clk`) | 300 MHz | **−0.134 ns** | −5.128 | 78 of 35,323 |
| `clk_out1_ulp_clk_wiz_0` (`ap_clk_2`) | 210 MHz | −0.022 ns | −0.179 | 19 of 52,836 |

Only the core clock is named in the error because `ap_clk` is *scalable* and the
core clock is not, but `ap_clk` is by far the worse of the two, and that matters:
lowering `CORE_CLK_B` alone — the obvious reading of a −0.022 ns miss — would have
bought another failed 1 h 20 m build.

The worst `ap_clk` path is inside the capture harness:

```
Source:      u_capture/bytes_acc_reg[3]/C
Destination: u_capture/bytes_acc_reg[13]/D     -0.134 ns
Data Path Delay: 3.211ns (logic 0.917ns (28.6%)  route 2.294ns (71.4%))
Logic Levels: 6  (CARRY8=5 LUT2=1)
```

This is **not** the path the input pipeline stage at `eth_capture.sv:120` was
added to fix — that one ran from the TX arbiter's select through a 512-bit mux
into the popcount, and it is still fixed. This is the accumulator's own carry
chain, and it is **71 % routing**. Phase A meets the same path at +0.153 ns with
identical logic; what changed is that a CMAC and its GT now share the pblock. So
restructuring the adder would be aiming at the wrong term — the delay is in the
wires, not the levels.

The response was therefore to back off both clocks rather than touch the RTL:
`ap_clk` 300 → **250 MHz**, `ap_clk_2` 210 → **200 MHz**. Both remain above what
the design actually requires — the core floor is the 195.3 MHz that 100 Gb/s
demands at 512-bit width, and `ap_clk` at 250 MHz still moves 16 GB/s of replay
against a 12.5 GB/s line rate. Neither number is a compromise of a claim; they
are headroom that was being spent for nothing.

That was the reasoning. Only half of it turned out to be operative — `ap_clk` is a
scalable platform clock and ignored the request entirely, staying at 300 MHz and
closing there anyway. See the next section, because the way it closed says
something about the path that the original diagnosis only predicted.

The core clock had already been dropped once before that, 215 → 210 MHz, for a
separate reason: `ap_clk_2` closed at 215 MHz with **+0.004 ns**, against
+0.048 ns for the same clock in Phase A at the time. The core logic is identical
— what changed is the placement pressure from a CMAC and its GT in the same
reconfigurable partition. 0.004 ns is about 0.1 % of the period, which is not
margin. The timing failure above then took it the rest of the way, which is why
`CORE_CLK_B` now defaults to **200 MHz** — still well above the 195.3 MHz that
100 Gb/s demands at 512-bit width, which is the only number that actually
constrains this clock.

Phase A has since tightened too, for a reason worth separating from the above:
adding the loaded-latency probe took `ap_clk_2` from +0.048 ns to **+0.015 ns** at
the same 215 MHz. That is the cost of the probe's hash table and its comparator,
not a placement effect, and it is the clearest evidence available that 215 MHz is
the ceiling for this design on this platform rather than a round number someone
liked.

### The rebuild produced a bitstream — and only one of the two backoffs did anything

`make xclbin-b` linked in **1 h 13 m** and wrote `t2t_b.xclbin` (53.1 MB) with
`t2t_b.ltx` beside it. This is the first Phase B bitstream that exists. Every
timing constraint is met:

| clock | frequency | WNS | failing endpoints |
|---|---|---|---|
| `clk_kernel_00_unbuffered_net` (`ap_clk`) | 300.000 MHz | +0.022 ns | 0 of 35,242 |
| `clk_out1_ulp_clk_wiz_0` (`ap_clk_2`, the core) | **200.000 MHz** | +0.108 ns | 0 of 53,249 |
| `txoutclk_out[0]` (`wire_clk`, the MAC) | **322.269 MHz** | +0.052 ns | 0 of 13,895 |
| `init_clk` (BUFGCE_DIV ÷3) | 100.000 MHz | +8.436 ns | 0 of 392 |

Design-wide WNS +0.003 ns, hold +0.009 ns, 0 of 538,495 endpoints failing, "All
user specified timing constraints are met". As in Phase A, the design-wide figure
belongs to the platform's own `dma_ip_axi_aclk_1` and not to anything this kernel
owns — the kernel's tightest domain is `ap_clk` at +0.022 ns.

**The `ap_clk` backoff never happened.** The Makefile asks for it and `cfgen`
receives it — `-clock.freqHz 250000000:t2t_kernel_b_1.ap_clk` is there in the log
— and `v++` then discards it:

```
ADVISORY: [AUTO-FREQ-SCALING-08] For clock clk_kernel_00_unbuffered_net, the auto
scaled frequency 302.0 MHz exceeds the original specified frequency. The compiler
will select the original specified frequency of 300.0 MHz.
...
Kernel (DATA) clock: ulp_ucs/aclk_kernel_00 = 300
```

The routed report confirms it: 3.333 ns, 300.000 MHz. `ap_clk` is the platform's
*scalable* DATA clock, and auto frequency scaling treats the platform's 300 MHz as
"the original specified frequency" and a `--freqhz` below it as a floor to scale
*up* from, not a ceiling to obey. Requesting a lower frequency on a scalable clock
is a no-op here.

So the design that passed is 300 / 200 / 322.269 MHz, and **the only change that
took effect was the core clock, 210 → 200 MHz**. That is worth stating plainly
because the reasoning behind the two-clock backoff was right for the wrong
mechanism: `ap_clk` did not close because it was given a longer period, it closed
because relieving 10 MHz of pressure on `ap_clk_2` freed enough routing for
`u_capture`'s byte accumulator to make its original 300 MHz period. It went from
−0.134 ns to +0.022 ns without its constraint moving at all. The path was diagnosed
as 71 % routing and congestion-bound rather than logic-bound, and this is that
diagnosis confirmed the hard way: a congested path was fixed by decongesting a
*different* clock domain.

`AP_CLK_B` is left at 250 MHz in the Makefile with this comment attached rather
than deleted, because the request is harmless and its removal would delete the
evidence of what it does.

Resources, against the Phase A kernel built from the same datapath:

| | LUT | LUTAsMem | REG | BRAM | URAM | DSP |
|---|---|---|---|---|---|---|
| Phase A (`t2t_kernel`) | 50,685 | 0 | 29,111 | 75 | 66 | 2 |
| Phase B (`t2t_kernel_b`) | **52,387** | 338 | **34,871** | **101** | 66 | 2 |

The whole cost of putting a real 100 G MAC, a store-and-forward FIFO and a frame
filter in the path is +1,702 LUT, +5,760 registers and +26 BRAM — 4.4 % of the
part's LUTs in total. URAM and DSP do not move, because the order table and the
ladder are unchanged.

**What this does and does not establish.** Phase B now "implements, meets timing
at 300/200/322.269 MHz, passes the golden in simulation, is licensed, and has a
bitstream". It does **not** yet establish "runs" — nothing has been loaded from
`t2t_b.xclbin`. The wire-to-wire number this whole phase exists to produce is one
`make run-card-b` away and is not quoted anywhere until that has happened.

### It runs: wire-to-wire on silicon, through a real MAC

The bitstream loaded, the MAC brought its link up in near-end PMA loopback with
no optics attached, and the datapath produced the golden's frames on the far side
of it. Real 5 M-message AAPL replay, `--gap 512`:

```
CMAC link   : aligned=1 link_up=1
harness : injected=1127057 captured=70 overflow=0 stalls=0
rx      : frames_in=1127130 kept=1122567 cdc_drop=0 hwm=5
feed    : gap=0 ot_overflow=0 oob=465 drops(beat=0 msg=0 delta=0)
mac     : tx=1127130 rx=1127130 rx_err=0 underrun=0 overflow=0
loopback: filter passed=70 dropped=1127060 cap_cdc_drop=0 hwm(feed=7 ord=3)
latency : samples=70 excluded=0 orphans=0
          min=166 cyc (515.1 ns)  avg=186.6 cyc (579.1 ns)  max=239 cyc (741.6 ns)
PASS: ON CARD, THROUGH THE MAC, real 5M AAPL order frames == golden
```

1,127,130 frames through the real IP with **zero receive errors, zero underruns
and zero overflows**, and `kept=1,122,567 / oob=465` — the same counters Phase A
reports, which is the check that the MAC changed the path and not the answer.

**The MAC costs more than twice what simulation said.** Both bitstreams were run
back to back on the identical stimulus, so the difference is attributable:

| real 5 M AAPL, gap 512 | Phase A (in fabric) | Phase B (through the MAC) | delta |
|---|---|---|---|
| min | 62 cy / **206.7 ns** | 166 cy / **515.1 ns** | +308.4 ns |
| mean | 78.9 cy / 263.0 ns | 186.6 cy / 579.1 ns | +316.1 ns |
| max | 124 cy / 413.3 ns | 239 cy / 741.6 ns | +328.3 ns |
| samples / excluded | 70 / 0 | 70 / 0 | |
| golden | PASS | PASS | |

Phase B's core runs 15 MHz slower (200 against 215 MHz), and the loaded probe
isolates exactly what that costs: **23 core cycles in both**, 107.0 ns against
115.0 ns, so the clock accounts for about 8 ns of the delta on that segment and
of order 10 ns across the whole core-domain path. **That leaves roughly 300 ns
for MAC TX, MAC RX, the SerDes round trip, the store-and-forward fill and the
frame filter.**

Simulation predicted ~145 ns for the same delta. It was wrong by a factor of two,
exactly as this document warned it would be — `MAC_LAT = 40` is a constant a
testbench author chose, not a measurement of an IP. The warning is now retired
and replaced by a number.

**What this reorders.** The datapath is no longer the larger half of the problem:
~207 ns of fabric against ~300 ns of MAC and SerDes. Shaving cycles off the price
ladder or adding cut-through decode attacks the smaller term.

**And almost none of the 300 ns is ours.** Breaking it down before optimising it:

| term | ns | ours? |
|---|---|---|
| core clock, 215 → 200 MHz across the core-domain path | ~10 | yes, and deliberate |
| `axis_sf_fifo` store-and-forward fill, 2-beat order frame | ~6 | yes |
| `axis_frame_filter`, decided on the first beat | ~3–6 | yes |
| **CMAC TX + GT SerDes round trip + CMAC RX** | **~285** | **no — vendor IP** |

The CMAC is already generated with the low-latency options: `INCLUDE_RS_FEC 0`
(the biggest single latency knob, off), both flow-control blocks off, statistics
counters off, AXIS rather than the AXI control interface. PG203 adds that the RX
path buffers nothing beyond the pipelining its operations need and is cut-through,
so there is no buffer in there to delete either.

That leaves ~9–12 ns of a 515 ns path that we could touch, about 2 %. Making
`axis_sf_fifo` cut-through would recover ~6 ns of it and reintroduce precisely the
underrun the module exists to prevent — once `tx_axis_tvalid` rises the MAC wants
a beat every cycle to `tlast`, and a source fed from HBM through an arbiter cannot
promise that. The earlier suggestion in this document that the FIFO was worth
attacking does not survive the arithmetic.

**So the term is close to irreducible with this IP.** The only real lever is not
using the vendor MAC — a thin custom PCS/MAC skipping the standards-compliant
pipeline, which is what the ultra-low-latency industry does and is a project in
its own right, with correctness risk to match. Worth entering deliberately, not as
an optimisation pass.

One caveat kept from the design section: loopback returns what we transmit, so
this measures `D + T_tx + T_rx` and overcounts true wire-to-wire by the SerDes
round trip inside the GT. It is the same three terms, not a substitute for a
cabled two-port measurement.

### The core clock was the prerequisite

Phase B reintroduces the constraint that made 200 MHz look thin: real 100 Gb/s
needs the core at ≥195.3 MHz at 512-bit width. That is why the core clock was
settled first, at 215 MHz — measured against the order table's URAM rather than
chosen.

## Register map

`s_axi_control` is 8 KB, split in two:

| Range | Contents |
|---|---|
| `0x0040`–`0x007F` | harness: replay/capture base, beats, gap, start, counters |
| `0x0080`–`0x00FF` | unloaded latency probe (`lat_probe`), wire cycles |
| `0x0100`–`0x01DC` | loaded latency probe (`lat_loaded`), core cycles |
| `0x0200`–`0x0228` | **Phase B only**: MAC status and the loopback paths |
| `0x1000`–`0x1FFF` | **`t2t_axil`'s own register file, unchanged** |

The Phase B block is what says whether a run can be believed at all: `0x0200`
carries `rx_aligned`/`link_up`, and beside it sit the TX underrun count (a frame
started and then starved — the failure `axis_sf_fifo` exists to prevent), the RX
error count (frames that came back with bad FCS or lost alignment), and the
capture CDC drop count. Each invalidates the capture in a different way, so the
host calls each out separately rather than folding them into one warning. On a
Phase A bitstream these offsets read `0xDEADBEEF`, which is why the host checks
the kernel ID — `T2K1` or `T2K2` — before reading them, and picks the
cycles-to-nanoseconds conversion from it too (300 MHz vs the CMAC's 322.265625).

So every offset in `step7-host/host/regmap.py` applies verbatim at `+0x1000`, and
`host/t2t_regs.h` is *generated* from that same Python (`scripts/gen_regs_h.py`)
rather than retyped — extending the guarantee `step7-host/tests/test_regmap.py`
already gives between the RTL and the host model to the C++ host as well.

Nothing sits below `0x0040`: XRT reserves the first 16 bytes of a kernel's
register space and refuses accesses there. The kernel is declared
`user_managed` (`syn/kernel.xml`) precisely because this design is not a compute
kernel to be launched and awaited — it is a resident datapath with a register
control plane, which is what `regmap.py` has always modelled.

The host is C++ rather than Python because the `pyxrt` shipped with this XRT
exposes no `xrt::ip` binding at all — its `kernel` class has no register
accessors.

## Run

```sh
source /opt/Xilinx/2025.2.1/Vivado/settings64.sh

make test-xsim          # harness in simulation, diffed against the golden
make elab               # quick RTL check for the whole kernel
make synth              # out-of-context synthesis: utilisation + timing

source /opt/Xilinx/2025.2.1/Vitis/settings64.sh
make xo                 # package the kernel
make xclbin             # link for the U55C (hours)

source /opt/xilinx/xrt/setup.sh
make host               # build the XRT host
make run-card           # program the card, replay, diff against the golden
make card-info          # what the card currently reports
```

Phase B, which puts the same frames through a real 100G MAC in GT near-end
loopback:

```sh
make test-b             # Phase B in simulation, against the SAME golden
make test-b-latency     # ...with a gap wide enough for samples to qualify

make gate-license       # Gate 4: may the IP become a bitstream? (seconds)
make cmac               # generate cmac_usplus for QUAD_X0Y6 (once)
make xo-b               # package the Phase B kernel, CMAC IP included
make xclbin-b           # link (hours) -> t2t_b.xclbin; runs the gate first
make xclbin-b SKIP_LICENSE_GATE=1   # ...or build anyway, for the timing report

make run-card-b         # on the card, through the MAC, diff against the golden
```

The two builds use separate temp directories (`_x_a`, `_x_b`) so one does not
overwrite the other's reports — which is not hypothetical: an interrupted Phase B
run wiped Phase A's routed timing report inside two minutes of starting.

The real-data replay (`make test-real`, `make test-b-real`) needs the NASDAQ
capture in `data/`; the default synthetic feed needs no download and still fires
four orders.

## Two fixes this step forced elsewhere in the repo

Both are declaration-order only — no logic changed — and both were latent:

- `step4a-order-table/rtl/order_table_pipe.sv` read `u_hit0` and friends in the
  write-port `always_comb` above where they were declared;
  `step6-strategy/rtl/tcp_tx.sv` did the same with `hold`. Vivado *synthesis*
  tolerates a forward reference; `xvlog` rejects it outright, so neither file
  would compile for simulation under this toolchain. The declarations moved up.
- The step 5 Makefile pattern `export LOCPATH := $(HOME)/.locale` is a WSL
  workaround for a locale Vitis hardcodes. On a machine that ships
  `en_US.utf8` system-wide it is actively harmful — it replaces the search path,
  glibc then finds nothing, and v++ aborts with
  `locale::facet::_S_create_c_locale name not valid`. Here it is applied only
  when the user-local copy actually exists.
