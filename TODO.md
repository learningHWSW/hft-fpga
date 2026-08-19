# TODO

Every step in [PLAN.md](PLAN.md) is done, so nothing here is unfinished
construction. What is left divides into three kinds: things no amount of code
closes (they need optics or a counterparty), things that are real engineering
and unblocked, and one property the repo used to get for free and now does not.

Each item says what would *close* it, not just what it is, and points at the
evidence that put it on the list. Items deliberately not being done are at the
bottom, because deciding not to do something is worth recording once rather than
re-deciding it.

## Blocked on hardware or a counterparty

Nothing on this list is closed by more simulation. Each one is waiting on a
physical thing this project does not have.

- [ ] **A cabled two-port measurement, replacing near-end PMA loopback.**
      The wire-to-wire 471.7 ns is measured with the GT in near-end PMA
      loopback — 64b/66b encoded, serialized at 25.78125 Gb/s over four lanes,
      recovered and FCS-checked, so it is the same `D + T_tx + T_rx` a wire
      gives. The honest end state is still a cable against a live feed.
      **Needs**: optics and a feed source; the QSFP cages are empty.
      **Closes**: README "Loopback is not a cable", PLAN §4 item 5.

- [ ] **Collect a real venue acknowledgement-latency distribution.**
      `ack_latency` is built, verified in both directions in the kernel
      simulation, and costs nothing to carry (220.7 MHz, 0 failing endpoints,
      URAM/BRAM/DSP unchanged). Under GT loopback it correctly reports *zero
      samples* rather than a plausible zero.
      **Needs**: something that answers the orders. **Closes**: `FINDINGS` §8.

- [ ] **Replace `cfg_rto_cycles` and `cfg_rto_retries` with measured numbers.**
      The only two values in this design chosen without evidence, and labelled
      as guesses wherever they appear. A timeout below the round trip resends
      orders the venue already has; one far above it gives back the reason for
      doing this in hardware. This is downstream of the item above — the
      instrument exists, the input does not.

- [ ] **Run the inbound path on the card against a real session.**
      Inbound is complete in simulation and has never met a venue: the ack
      number `tcp_tx` sends is live, replies merge into the same capture area
      the orders use, and `dump_session.py` reassembles and decodes them —
      verified HBM-to-HBM and through the MAC model, order frames byte-identical
      either way. What has not happened is a card run with a counterparty.

## Datapath and build

- [ ] **Make `NSYM` and `OT_SETS_BITS` fail loudly instead of silently
      under-sizing.** They move together for capacity reasons the tool cannot
      see (two symbols need 2¹⁴ sets, `FINDINGS` §4.4) but are separate knobs
      set by hand in `step5-board/Makefile` and `synth_t2t.tcl`. Raising `NSYM`
      alone is a choice to drop orders, and today nothing says so at build time.
      **The fix is an elaboration-time error, not an auto-resize** — auto-resizing
      is explicitly rejected in `synth_t2t.tcl:53`, because a build that silently
      grew the table would hide that the area answer has two halves.

- [ ] **Decide what to do about the two `NSYM = 2` builds that miss the
      out-of-context yardstick by 0.001 ns.** The structural work is done: capping
      the order table's URAM cascade and fusing `fast_bbo`'s quantity update took
      143 failing endpoints to 2, and every directive now builds between 216.5
      and 219.8 MHz (`FINDINGS` §4.4.1). What remains is the smallest violation
      the tool can report, against a constraint sitting 21 MHz above the
      195.3 MHz the wire demands. **Likely closure is to fix the yardstick**, or
      to state once that it is a reference line and not a requirement — not to
      spend cycles chasing a picosecond.

- [ ] **Price cut-through decode in fMAX, then set its default.**
      `itch_decoder` has `CUT_THROUGH`, default 0, and it is proven in
      simulation: the decode log is byte-identical to the golden and arrives one
      core cycle sooner, 2 → 1, at 512-bit width (`FINDINGS` §7.1.1a, `step3b
      make test-ct-xsim`, `step5 make test-t2t-ct`). What is unknown is the only
      thing that decides whether it ships — what a combinational twenty-way type
      dispatch ahead of the register costs the core clock, in a domain that
      closed at +0.099 ns. **Closes with a directive sweep at both settings**,
      the same shape §7.7 used for `fast_bbo`, not with more simulation.
      4.65 ns bought at the price of the core clock is not 4.65 ns bought.

- [ ] **Collapse `u_tx_cdc` and `u_ord_fifo` into one cross-clock
      `axis_sf_fifo`.** An order frame crosses `t2t_top`'s core→wire `cdc_fifo`
      and then the kernel's same-clock store-and-forward FIFO: two FIFOs back to
      back, each with a pop pipeline and (now, on one of them) synchronisers,
      where one cross-clock `axis_sf_fifo` does both jobs and already has the
      underrun guarantee. Estimated ~5 ns, unmeasured, and inside the
      wire-to-wire number. **The reason it is a TODO rather than done** is that
      it moves `t2t_top`'s tx interface out of the CMAC domain, which Phase A,
      step 5 and step 6 all share — so it is a change to five testbenches'
      worth of surface for a term smaller than the one §7.6.1a already took.

- [ ] **Revisit the shared in-flight limit if a second OUCH session lands.**
      The strategy's edge detector, latched BBO and position are per name; the
      in-flight limit is shared, because it counts orders on one TCP session and
      the resource it limits is the wire, not the book. That is correct as built.
      It stops being correct the moment a second session exists — step 7 already
      runs two independent ones on the host side.

## Cut-through, in the order it closes

The rest of this file is a list of things; this is a sequence, because the two
cut-through switches are built and tested and what is left is two measurements
that have to happen in an order. Both items in *Datapath and build* above close
here. Nothing in this section needs more RTL written.

1. **DONE — swept, and it costs nothing.** 4/4 directives close at each
   setting; best-to-best the cut-through build is 1.4 MHz *faster* against a
   4.8 MHz within-configuration spread, and it is 1,161 LUTs and 361 flops
   smaller (`FINDINGS` §7.1.1b). The sweep also caught an 83 MHz regression the
   simulations could not see — a packed-vector byte collector with a variable
   part-select, which is a barrel shifter where an unpacked array is 64
   registers. Run it even when the decision is already made.

   ```sh
   cd step5-board
   mkdir -p syn/old && mv syn/sweep-f*.log syn/old/   # see below
   make sweep-t2t SWEEP_CT="0 1" SWEEP_FAST=1
   make sweep-t2t-report
   ```

   **Move the existing transcripts aside first.** `sweep-t2t-report` globs
   `syn/sweep-f*.log` and prints its best-to-best comparison only when exactly
   two configurations are present. The eight logs already in `syn/` are three
   configurations (`fast=0`, `fast=1`, `NSYM=2`), so leaving them there gives a
   table with no comparison line and nothing saying why — the same shape as the
   stale-transcript trap the script's own `!! MIXED TOOLCHAIN` guard was written
   for. The new runs tag themselves `-ct`, so they will not overwrite the old
   ones; the glob is the problem, not collision.

   Eight builds, four directives at each setting, because one build against one
   build cannot measure place & route — the lesson §7.7 paid for. **What closes
   it**: every `ct=1` directive meets timing, and the best-to-best difference is
   read against the largest spread *within* either configuration. Inside the
   spread means the cycle was free. Outside it means the shipped default costs
   core clock, which is a number to publish, not a reason to revert — unless a
   directive fails to close, which is.

2. **DONE — the default is on.** `CUT_THROUGH` is derived rather than constant:
   `(DATA_W >= 8*MAX_MSG_BYTES)`, on at the 512-bit datapath and off at the 64
   bits steps 2, 3a, 4a, 4b and 6 drive their goldens through. A flat `1` broke
   all five of those at once on the elaboration guard, which is what forced the
   derived form. Makefile `CT` and the testbench parameters follow the RTL
   rather than overriding it back. Re-verified green across every step and both
   step-8 kernels.

3. **DONE — rebuilt and measured on the card, 2026-08-19.** Wire-to-wire
   **471.7 → 459.2 ns** at the minimum, mean and max down by the same ~12 ns,
   70/70 frames byte-identical, `st_bbo_mismatch = 0`, MAC `underrun = 0`.
   Exactly 4 wire cycles, against 3.6 predicted from `SAME_CLOCK`'s two plus
   cut-through's one 200 MHz core cycle. Both changes landed.

   ```sh
   cd step8-hw && make xclbin-b        # ~1 h 15 m
   make run-card-b-real
   ```

   **What closes it**: the minimum moves 471.7 → ~465.5 ns, with `st_bbo_mismatch`,
   the MAC's `underrun` and the order FIFO's `starves` all still zero. If the
   minimum does not move, the saving was absorbed by placement — that is a
   finding to record, not a run to repeat. Do this before step 4 either way, so
   the two changes are never measured together.

4. **DONE — rebuilt and measured, 2026-08-19.** In-fabric **166.7 → 160.0 ns**
   at the minimum (236.4 → 231.8 mean), 70/70 byte-identical, `st_bbo_mismatch
   = 0`. The probe counts `ap_clk` at 300 MHz, so that is 2 probe cycles for one
   215 MHz core cycle plus quantisation. `decode->order` stayed at 14 core
   cycles, which is the control: that probe starts at the decoder's output, so
   the saving must not appear there, and it does not. The build closed with
   WNS +0.003 and no auto-scaling, unlike Phase B.

Optional, and only if a card run comes out ambiguous: **publish `starves` in the
register map.** `axis_sf_fifo` counts port-idle-mid-frame cycles per instance,
but today only a testbench can read them; the MAC's own `underrun` flag says
that *something* starved, not which of the two sources did. It is a status
register, a row in `step7-host/host/regmap.py`, and a line in
`step7-host/tests/test_regmap.py` — not worth doing before it is needed.

## Verification

- [ ] **Restore, mechanically, the cross-check that a second simulator gave.**
      Everything runs under xsim; the Verilator paths are gone, and with them a
      cross-check that had already earned its keep once. A testbench driving
      stimulus on the edge the DUT samples is a race the two tools resolve in
      opposite directions, and exactly that bug was caught because both were run —
      Verilator passed it, xsim failed, and neither was reporting a design fault
      (`step6-strategy/README.md`). The negedge-stimulus convention every
      testbench follows is now the only thing standing in for that check, which
      makes it a rule rather than a style. **A rule can be enforced**: a lint pass
      that fails any testbench driving DUT inputs on `posedge` costs nothing to
      run and does not need a second toolchain.

- [ ] **Check whether anything else depended on the behavioural array coming up
      X.** Collapsing `otable_mem` to one implementation fixed a real bug — the
      `` `ifdef `` reached exactly one of three flows, and the URAM count could not
      tell the branches apart (`FINDINGS` §4.5) — but it cost a property. The
      behavioural array came up X, which is what would have caught the order
      table's post-reset clear sweep being deleted; XPM's model comes up zeroed.
      `step4a make test-clear` replaces that accident with a test **for the order
      table**. Nothing has audited whether another memory was relying on the same
      accident.

## Repo state

- [ ] **Restore the "One simulator, so no second opinion" limitation, or earn
      its deletion.** The *What is not done* section is now commented out of
      `README.md` wholesale (`957f70b`), which removed that bullet along with
      everything else in it — but Verilator is still gone (`3be6d14`), so the
      limitation still holds. Commenting a section out is not the same as
      answering what it said. **Either land the lint pass in the Verification
      item above and then rewrite the bullet to describe it, or restore the
      section.**

## Deliberately not doing

- **Flattening `price_ladder`'s group select, as the default.** Measured, not
  assumed: the one-hot mask-and-OR form is **+4.5 MHz** best-to-best with the
  critical path leaving the ladder, and **+13.3 % LUTs** (+18.8 % on the ladder,
  which is the block replicated per symbol). fMAX is not the binding constraint
  — 223.6 MHz against the 195.3 the wire demands — and LUTs are, so this buys
  headroom that is not needed with the resource that is. `FLAT_SCAN` stays as a
  parameter, default 0, and becomes correct the day the core clock is what
  limits the design (`FINDINGS` §7.1.2).

Recorded so they are not re-opened. Each was decided on a measurement.

- **Cycle-shaving the fabric datapath, as a priority.** The MAC is ~300 ns of a
  ~471.7 ns path and the fabric is ~166.7 ns, so shaving cycles attacks the
  smaller term. ~285 ns sits inside `cmac_usplus` and the GT — already generated
  with RS-FEC and flow control off — and only ~9–12 ns of the term is ours
  (`FINDINGS` §7.6.1). PLAN §4 item 1.
- **A thin custom PCS/MAC.** The one real lever on that 300 ns, and a project
  rather than an optimisation pass. Listed here as the known lever, not as work.
- **Trading the imbalance signal as a taker.** It predicts and does not pay:
  75 % continuation against a 62 % population (~7.7σ), mean move +22.7 against a
  half-spread cost of 50, so −27.3 net and 23 % of events clear it. Tightening
  the ratio destroys it rather than concentrating it (`FINDINGS` §5.3).
- **Wiring `mold_stripper` and `gt_gate`.** The only two RTL modules in no
  hierarchy, both on purpose: `mold_stripper` is step 3a's 64-bit reference, kept
  because it and `mold_splitter` are diffed against the same golden, and
  `gt_gate` is the Phase B feasibility kernel, packaged as its own `.xo` with its
  GT pins undriven.
- **HBM for the hot path.** Deferred by measurement — hundreds of ns is unsuited
  to market data, and filtering to tracked symbols keeps the order table on-chip
  (PLAN §0 item 6, `FINDINGS` §4.1). It comes back only if all-symbol tracking
  becomes necessary.
