# Step 3b — 512-bit MoldUDP64 realigning splitter

At the 100G CMAC width (512 bits = 64 bytes/beat), takes MoldUDP64 payload,
**realigns** it into per-ITCH-message units, and emits at 1 msg/cycle. A message
ends and the next begins within one beat (up to 3 boundaries per beat), and a
message straddles a beat boundary — this realignment is the technical core of
step 3b. The output follows the step-2 decoder input contract exactly, so
`itch_decoder #(.DATA_W(512))` is reused unchanged.

## Run

```sh
make test              # xsim, synthetic test.mold (with gap+dup+hb+eos)
make test-verilator    # Verilator, same
make test-real         # real data 1M msg (Verilator)
make test-real-xsim    # real data 1M msg (xsim)
```

Real data is BinaryFILE format, so it does not stimulate realignment as-is.
`step1-sw-parser/itch2mold.py` repacks the real messages into multi-message
MoldUDP64 packets (1–8 per packet, cycling + periodic heartbeats + EOS) so the
boundaries scatter across several offsets within a beat. The golden is step 3a's
`dump_mold.py` (width-independent), unchanged.

## Realignment core

A 2-beat (128-byte) byte window is held as a flat vector. **Every cycle,
concurrently**:
- `consume`: bytes removed from the front (a complete message `2+len`, the 20-B
  header, or 0 if the front is incomplete)
- `accept`: append one input beat at the tail if there is room after this cycle's
  consume (`s_tready` reflects that room)

Both are done in the same cycle via barrel shift -> even with 2–3 messages
packed into one beat, the output stays at **1 msg/cycle**. This meshes with the
input-FIFO sizing (worst 76 msgs, [data/FINDINGS.md](../data/FINDINGS.md)). If
the front is incomplete then `vcnt <= 52 < 64` automatically, so there is always
room to accept a beat and progress is guaranteed; occupancy never exceeds 128
bytes (the window invariant).

Sequence tracking (gap/hb/dup/eos) is the same receiver model as step 3a and
matches `dump_mold.py`. A duplicate data packet consumes its header+message bytes
but suppresses output (the DROP state).

## Design notes

- **Packet boundaries come from framing**: the header MsgCount + per-message
  length prefix give the boundaries, so `s_tlast` is not used in the datapath
  (the port is kept only). The byte stream is self-describing.
- **Every ITCH message is <= 50 B < 64 B** -> one message = one beat = one cycle.
  The output is left-aligned (message byte0 in `m_tdata[7:0]`), `m_tkeep` = length,
  `m_tlast` = 1 every beat.
- **Decoder reused unchanged**: instantiate with `DATA_W=512` to gather the single
  beat and decode the next cycle. Back-to-back tlast beats also work (the decode
  is the cycle after the beat, and mbuf reads only the per-type field ranges).
- **Log alignment**: the splitter registers messages and events in the same
  stage, but a message goes through the decoder (2 cycles) as well. The TB delays
  event logging by that latency to restore single-stream order (`EV_DELAY=2`).
  The RTL itself is unaffected.
- **An xsim portability trap (found by debugging)**: in a continuous assign, a
  function that reads the module signal `win` in a non-argument way
  (`assign msglen = w_be16(0)`) does not re-evaluate in xsim because `win` is not
  in its sensitivity list, so `msglen` sticks at X -> an infinite stall.
  Verilator inlines the function and happens to work. Fix: use a direct bit-select
  in the continuous assign (`{win[7:0], win[15:8]}`). **Lesson: a function used in
  a continuous assign must depend only on its arguments.** A stall watchdog is a
  permanent fixture in the TB to catch such a line immediately.

## Status

- **xsim (Vivado 2025.2)**: synthetic test.mold PASS, real data 50k msg PASS
- **Verilator**: synthetic PASS, real data 1M msg PASS (2019-12-30)
- Both flows verify gap/dup/hb/eos + 512-b realignment. len_err / frame_err 0.
