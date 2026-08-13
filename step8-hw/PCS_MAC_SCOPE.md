# Scoping a thin custom PCS/MAC

Status: **scope only.** Nothing here is built, and the first item is a
measurement whose result decides whether the rest is worth attempting.

`FINDINGS` §7.6.1 ends by naming a thin custom PCS/MAC as "the only real lever"
on the MAC term, and immediately says it "should be entered deliberately, not as
an optimisation pass". This document is that deliberation.

## 1. What the term is, and how well it is known

The MAC round trip is one of the better-measured numbers in this project. It was
obtained twice, as a *difference* between two probes across four separately
placed and routed bitstreams (`FINDINGS` §7.6.0):

| | ladder-only build | with `fast_bbo` |
|---|---|---|
| MAC TX + RX + SerDes round trip | 308.4 ns | 305.0 ns |

`fast_bbo` sits between the two probes, so this term *must not* have moved, and
it reproduced to 3.4 ns. Call it **~306 ns ± 2**. That is the budget under
discussion, against a 471.7 ns wire-to-wire minimum — about 65 % of the whole
path.

§7.6.1 splits it by ownership:

| term | ns | ours? |
|---|---|---|
| core clock, 215 → 200 MHz across the core-domain path | ~10 | yes, deliberate |
| `axis_sf_fifo` store-and-forward fill, 2-beat order frame | ~6 | yes |
| `axis_frame_filter`, decided on the first beat | ~3–6 | yes |
| **CMAC TX + GT SerDes round trip + CMAC RX** | **~285** | **no — vendor IP** |

## 2. What is already ruled out

The IP is generated in its low-latency configuration, and this was a deliberate
choice rather than a default (`syn/gen_cmac.tcl`):

- `INCLUDE_RS_FEC 0` — the single largest latency option, off
- `RX_FLOW_CONTROL 0`, `TX_FLOW_CONTROL 0`
- `INCLUDE_STATISTICS_COUNTERS 0`
- AXIS user interface rather than the AXI control interface
- CAUI-4, 4 lanes × 25.78125 Gb/s

PG203 further states the RX path buffers nothing beyond the pipelining its
operations require and passes data through cut-through. There is no idle buffer
to delete.

Of the ~19 ns we *do* own, §7.6.1 already rejected the one candidate: making
`axis_sf_fifo` cut-through recovers ~6 ns and reintroduces the MAC underrun it
exists to prevent, because a source fed from HBM through an arbiter cannot
promise a beat every cycle until `tlast`. That trade stays rejected.

So the question is entirely about the ~285 ns inside the vendor IP.

## 3. The thing we did not know — now measured

**ANSWERED, 2026-08-13.** The gate below was built and run
([../data/pma-vs-pcs-loopback.txt](../data/pma-vs-pcs-loopback.txt)). The GT PMA
round trip is **9.3 ns**, three cycles at 322.265625 MHz, reproduced exactly
across two independent bring-ups. So the split is:

| | ns | share | |
|---|---|---|---|
| GT PMA — serializer, deserializer, CDR, elastic buffer | ~9.3 | 3 % | irreducible |
| **CMAC MAC + PCS** | **~276** | **90 %** | **what a custom block replaces** |
| ours (core-clock crossing, `axis_sf_fifo`, frame filter) | ~19 | 6 % | already rejected in §7.6.1 |

That is the *opposite* of the pessimistic case this section was written to guard
against. The PMA is not the obstacle; near enough all of the vendor term is in
the standards-compliant MAC and PCS pipeline, which is exactly what a thin
custom block replaces. The prize is ~276 ns against a 471.7 ns wire-to-wire
minimum — well over half the path.

It bounds the prize, not the winnings. A custom block still has to frame,
encode, scramble, lock and deskew; what it can drop is worst-case provisioning,
above all a deskew buffer sized for the skew budget 100GBASE-R demands rather
than the skew a short link presents. §4 and §5 stand unchanged, and so does the
recommendation in §6.3: the central trade is deskew sized to a real link, and
there is still no real link here.

The original reasoning is kept below, because it is why the measurement was
worth taking.

---

## 3a. The thing we did not know, and had to measure first

**~285 ns is not one number, it is two, and only one of them is attackable.**

    ~285 ns  =  GT PMA          (serializer, CDR, deserializer, elastic buffer)
             +  CMAC MAC + PCS  (framing, FCS, 64B/66B, scramble, alignment
                                 markers, lane deskew, block lock)

A custom PCS/MAC replaces the second term. It **cannot** touch the first: the
GTY transceiver is a hard block, and any design that puts bits on a QSFP28 cage
goes through the same serializer and the same CDR. If the split is 200/85 in the
PMA's favour, the entire project is chasing 85 ns and is not worth starting. If
it is 60/225, the case is very different.

Nothing in this repository measures that split, and no honest estimate of the
project's value exists without it.

### The cheap gate

This project has a habit worth reusing here — `step8-hw/gtgate/gt_gate.sv` exists
because a minimal feasibility kernel answered "will `v++` wire a user kernel to
`io_gt_qsfp0_00`?" for the cost of one block-design build, before hours were
committed to Phase B. The same move is available.

`cmac_wrap.sv` already drives `gt_loopback_in`, and `t2t_kernel_b.sv` already
exposes loopback as a *runtime* register bit (`R_CTRL` bit 4, write-enabled by
bit 5). Today it selects two of the GT's modes:

    000  no loopback
    010  near-end PMA loopback     <- what every Phase B measurement uses

The GT also offers **near-end PCS loopback**, which `cmac_wrap.sv`'s own header
describes precisely: it "turns back before the serializer". That is exactly the
cut we need.

    (near-end PMA round trip) − (near-end PCS round trip)
        = GT serializer + deserializer + CDR + elastic buffer
        = the part a custom PCS/MAC can never recover

The remainder, minus our ~19 ns, is the CMAC's own MAC+PCS latency — the
addressable budget.

**Cost of this measurement:** widen the loopback register field from one bit to
the three the GT mode already needs, and rebuild one Phase B bitstream.
`lat_probe` needs no change; it already reports RX beat to TX beat, and the
comparison is between two runs of the *same* bitstream, so placement luck cancels
in a way it does not across builds. Two runs of `t2t_run`, one register write
apart.

This is the only work in this document that should be started before the number
it produces has been read.

## 4. What a custom PCS/MAC actually entails

Assuming the gate says the addressable term is large enough, the build is:

**TX.** MAC framing and FCS insertion, 64B/66B encode, scramble, distribute to
20 PCS lanes, insert alignment markers, gearbox to 4 physical lanes. This
direction is comparatively easy — it is a pipeline with no adaptivity in it, and
its latency is close to the sum of its stages.

**RX.** Block lock, alignment-marker lock, lane reorder and **deskew**,
descramble, decode, FCS check. This direction is the whole difficulty, and the
deskew buffer is where a standards-compliant receiver spends its latency: it must
absorb the worst-case inter-lane skew the standard requires it to tolerate, which
is far more than a short DAC to a colocated switch actually presents.

**That gap is the entire thesis of the project.** A receiver that sizes its
deskew buffer for skew *measured on the link it will run on*, rather than for the
standard's budget, is smaller and faster — and is no longer a compliant 100GBASE-R
receiver. It works on the link it was tuned for. This is what the ultra-low-latency
industry does, and it is a deliberate trade of generality for nanoseconds, not a
free optimisation.

## 5. Risk, and what it costs beyond RTL

- **Correctness risk is high and not simulation-shaped.** The failure mode is a
  receiver that locks on a good day and does not on a bad one, or that silently
  mis-deskews under conditions the bench never produced. `cmac_wrap.sv` already
  records that `cmac_usplus` "cannot usefully be simulated here" — it needs
  unisim GT models and tens of microseconds of alignment before a frame moves.
  A custom PCS inherits that problem and loses the vendor's validation with it.
- **It deletes the thing that currently makes Phase B trustworthy.** Every silicon
  measurement in this project is anchored by a byte-identical golden diff through
  a *vendor* MAC. Replacing the MAC means the golden no longer isolates the
  datapath from the link.
- **The QSFP cages are empty.** Near-end PMA loopback is the strongest test
  available here, and it exercises this GT talking to itself — the skew a custom
  deskew buffer would be tuned against is loopback skew, not a real link's. A
  custom PCS/MAC cannot be honestly validated on this bench alone, which chains
  it to the cabled-measurement gap already recorded in README's *What is not
  done*.
- **Effort is in weeks, not days**, and most of it is bring-up and validation
  rather than the datapath.

## 6. Recommendation

1. **Do the cheap gate** (§3). One register-field widening, one bitstream, two
   runs. It costs an afternoon and it is the difference between a scoped project
   and a guess.
2. **Then decide, against a number.** If the CMAC MAC+PCS term is small, record
   it in `FINDINGS` and close this out — "close to irreducible with this IP"
   becomes "close to irreducible, and here is the proof" rather than an inference
   from a vendor datasheet.
3. **Do not start the custom PCS/MAC before there is a cable.** Its central trade
   is deskew sized to a real link, and there is no real link here yet.

The honest summary: this is a real lever on the largest single term in the path,
and it is also the highest-risk work this project has considered. The measurement
in §3 is cheap enough that not having done it is the actual gap.
