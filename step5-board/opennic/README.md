# OpenNIC integration — tick-to-trade in box_322mhz

This directory drops the tick-to-trade engine (`t2t_axil`) into
[open-nic-shell](https://github.com/Xilinx/open-nic-shell)'s `box_322mhz`, in
place of the default `p2p_322mhz` forwarder. It is written and elaboration-
verified without a card; what remains (build, bitstream, bring-up) needs the
U55C.

## Why box_322mhz

`box_322mhz` already exposes everything the engine touches in one place: the
CMAC RX/TX AXI-Streams (512b + 64b tkeep), the per-user AXI-Lite slice
(`axil_p2p_*`, from the box address-map crossbar), `cmac_clk` (322.265625 MHz)
and `axil_aclk` (the register clock). `t2t_axil` handles all three clock
domains internally, so it fits inside this one box.

The only thing the box does **not** provide is a clock at the datapath rate.
`core_clk` must sit between the 100 Gb/s floor (195.3 MHz) and the datapath's
post-route Fmax (~226 MHz); `cmac_clk` (322) is above it and `axil_aclk` is
below. So the adapter adds one MMCM (`t2t_core_clk`, a clk_wiz) that makes
**core_clk = 200 MHz** from `cmac_clk`. That is the entire clocking change.

## Datapath

Bump-in-the-wire feed handler:

```
CMAC RX (exchange feed) ─▶ t2t_axil ─▶ CMAC TX (orders out)
host QDMA path (adap_tx/adap_rx) ─▶ unused (host TX dropped, host RX idle)
AXI-Lite (axil_aclk) ─▶ t2t_axil config/status
```

Orders are generated on the FPGA, not forwarded from the host, so the QDMA
datapath is left idle (documented in `t2t_user_322mhz.sv`). Configuration and
status still reach the host over AXI-Lite.

## Files

| file | role |
|---|---|
| `t2t_user_322mhz.sv`          | adapter: box interface ⇄ `t2t_axil`, MMCM, resets |
| `user_plugin_322mhz_inst.vh`  | plugin include — instantiates the adapter in box_322mhz |
| `create_t2t_core_clk.tcl`     | creates the `t2t_core_clk` MMCM IP (322.27 → 200 MHz) |
| `t2t_core_clk_stub.sv`        | MMCM stub for `make lint-opennic` (elaboration only, not built) |

## Integrate (from a clean open-nic-shell checkout)

1. **RTL sources.** Add this repo's `step5-board/rtl/*.sv`, the step2/3b/4a/4b
   and step6 RTL (the `TAXIL_SRC` list in `step5-board/Makefile`), and
   `opennic/t2t_user_322mhz.sv` to the shell's source list
   (`open-nic-shell/src/` or via `--user_plugin`). For the II=1 order table,
   define `OT_PIPE`. Nothing needs defining for the order-table memory itself
   any more — `otable_mem` instantiates the XPM macro unconditionally, which is
   the change FINDINGS §4.5 asked for and which this integration would
   otherwise have had to remember.
2. **Plugin.** Replace
   `plugin/p2p/box_322mhz/user_plugin_322mhz_inst.vh` with the one here (reuse
   the p2p address map unchanged — one 4 KB AXI-Lite slave is enough for
   `axil_regfile`'s map, CTRL at 0xA4, status at 0x100, ID at 0x1FC).
3. **Core clock IP.** After the project is created, `source
   create_t2t_core_clk.tcl` so `t2t_core_clk` exists before synthesis.
4. **Constraints.** Import `step5-board/syn/t2t_axil_cdc.xdc`, but rename the
   clock references to the shell's names: `cmac_clk` stays, `axil_clk` →
   `axil_aclk`, and `core_clk` → the generated clock on
   `t2t_core_clk/inst/clk_out1` (name it, or `create_generated_clock`). The file
   already reads periods with `get_property PERIOD`, so only the names change.
5. **build.tcl.** open-nic-shell's `build.tcl` hardcodes
   `-flow {Vivado Implementation 2020}`; on Vivado 2025.2 set it to the current
   flow (this was the one edit that made the shell build for au55c).

## What's verified vs. card-needed

- **Verified now:** `make lint-opennic` elaborates `t2t_user_322mhz` against the
  full `t2t_axil` tree (26 modules, clean) — the box wiring is structurally
  correct. `t2t_axil` itself closes post-route timing standalone and as the
  wrapper (`impl-t2t`, `impl-axil`; FINDINGS 6.1).
- **Card-needed:** the actual shell build, bitstream, and bring-up (IGMP join →
  feed in → orders out, real latency). The MMCM frequency, the QMDA-path
  decision, and the AXI-Lite base address are the knobs to revisit on real
  hardware.
