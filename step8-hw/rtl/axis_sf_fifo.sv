// Store-and-forward AXI-Stream FIFO, optionally across two clocks, optionally
// cut-through.
//
// WHY STORE-AND-FORWARD, and why cdc_fifo could not be reused. cdc_fifo is the
// right shape for the market-data RX path: it never stalls its writer and drops
// a beat rather than backpressure the wire, because the wire cannot be
// backpressured. A CMAC transmit port is the exact opposite contract. Once
// tx_axis_tvalid rises on a frame, the MAC expects a beat every cycle until
// tlast; a gap is not a bubble, it is an underrun (tx_unfout), and the frame
// goes onto the wire corrupted. A source fed from HBM through an arbiter cannot
// promise that.
//
// So the FIFO makes the promise instead: a frame becomes visible to the reader
// only once its tlast has been written. From that moment the whole frame is
// resident, so the read side can supply a beat on every cycle the MAC asks for
// one no matter what the writer is doing. The cost is one frame of latency on
// the path that uses it -- two beats, ~6 ns at 322 MHz for an order frame --
// paid to remove a corruption mode.
//
// The write side backpressures rather than drops, because here a dropped beat
// would silently truncate a frame instead of losing a whole one, and the golden
// diff is the project's only real check: a truncated order frame would show up
// as a mismatch with no explanation. eth_replay grew an m_tready for this.
//
// HOW "COMPLETE FRAME" CROSSES THE CLOCKS, and the trap avoided. The obvious
// implementation is a second write pointer that advances to the end of each
// frame at tlast, gray-coded across like cdc_fifo's pointers. That is WRONG, and
// silently so: gray coding is only safe for a value that changes by ONE between
// sampling edges, because that is what guarantees a single bit differs and a
// mid-transition sample is either the old or the new value. A commit pointer
// jumps by the whole frame length -- twenty-odd bits changing together -- and a
// synchroniser can latch an address that was never written.
//
// What crosses instead is a frame COUNT, which does increment by one, so gray
// coding means what it is supposed to mean:
//
//   write side   wbin advances per beat; pkt_wr advances per tlast
//   read  side   pkt_rd advances per tlast POPPED; it may pop whenever the two
//                counts differ, and rbin simply walks the memory
//
// The reader therefore stops exactly on a frame boundary and never enters a
// frame that is still being written, without any multi-bit address crossing.
//
// The per-beat write pointer crosses too, as wgray. That one is safe for the
// ordinary reason -- it increments by one per beat -- and it is what gives the
// read side an occupancy, which store-and-forward never needed and cut-through
// cannot do without.
//
// "Per tlast popped" is load-bearing and was got wrong first. The payload memory
// is synchronous and the port register adds a second slot, so a beat's tlast is
// not known until two cycles after the pop that fetched it -- and gating the pop
// on a frame count that only advanced then let the reader run two beats past the
// end of the last committed frame and emit whatever the array happened to hold.
// So tlast is ALSO kept in a one-bit shadow array, read asynchronously at the
// pop address, which makes the frame count advance in the same cycle as the pop
// it belongs to. The shadow array is safe to read asynchronously for the same
// reason the payload is safe to read at all: the count handshake has already
// ordered the write against this read.
//
// A frame longer than DEPTH would fill the FIFO before it could commit and
// deadlock the writer. DEPTH must exceed the longest frame: 512 beats here
// against a 1518-byte maximum Ethernet frame, which is 24.
//
// SAME_CLOCK: WHERE THE ORDER PATH'S ~6 ns ACTUALLY WENT. Set the two clocks to
// the same net for a synchronous instance and the module still works -- which is
// why both the same-clock order path and the cross-clock feed path use this one
// module rather than two. But the synchronisers then cost SYNC_FF cycles of pure
// latency for nothing: a two-flop chain between a register and a reader in the
// SAME domain resolves a metastability that cannot occur. On the order path that
// is 2 of the 322 MHz cycles between tlast being written and m_tvalid rising --
// 6.2 ns, which is the whole of the "store-and-forward fill" line FINDINGS
// §7.6.1 attributes to this block. SAME_CLOCK=1 bypasses both chains and the
// frame is published combinationally. It gives up NOTHING: the frame is still
// complete before the reader sees it, so the underrun guarantee is untouched.
// This is the cheap half of the order path's latency, and it was never a trade.
//
// CUT_THROUGH: RELEASING A FRAME BEFORE ITS LAST BEAT, SAFELY. The expensive
// half is the fill itself, and giving it up does trade against the guarantee.
// The trade is arithmetic, not judgement. Let the reader take one beat per
// r_clk, and let the writer be able to stall for up to W_GAP_MAX reader cycles
// between consecutive beats of a frame. If the reader starts with H beats of an
// L-beat frame resident, at reader cycle k it needs beat k and has
//
//     H + floor(k / W_GAP_MAX)
//
// so it never runs dry iff k+1 <= H + floor(k/W_GAP_MAX) for every k < L. The
// binding case is the last beat, giving
//
//     CT_MIN = MAX_FRAME_BEATS - (MAX_FRAME_BEATS - 1) / W_GAP_MAX
//
// (integer division), which the module computes rather than the instantiator.
// Two consequences are worth stating because they are the whole result:
//
//   * W_GAP_MAX = 1 -- a writer that cannot stall mid-frame -- gives CT_MIN = 1,
//     true cut-through, the frame leaves as its first beat lands.
//   * W_GAP_MAX >= MAX_FRAME_BEATS gives CT_MIN = MAX_FRAME_BEATS, which IS
//     store-and-forward. For the 2-beat order frame behind a 215 MHz writer and
//     a 322 MHz reader, W_GAP_MAX is 2 and CT_MIN is 2: cut-through recovers
//     exactly nothing. That is not a disappointment, it is the answer -- a
//     2-beat frame has no interior to cut through, and FINDINGS §7.6.1's ~6 ns
//     was never the fill. SAME_CLOCK is where that 6 ns is.
//
// W_GAP_MAX is a contract with the SOURCE, and a contract nothing checks is a
// guess. `starves` counts the cycles the port went idle mid-frame with the sink
// asking -- the underrun itself, not a proxy for it -- so a wrong W_GAP_MAX is a
// non-zero counter in a testbench and in the register map, rather than a frame
// that is corrupt on the wire and fine in simulation. It is zero by construction
// when CUT_THROUGH is 0.
`timescale 1ns/1ps
module axis_sf_fifo #(
  parameter int DATA_W  = 512,
  parameter int DEPTH   = 512,          // beats, power of two
  parameter int SYNC_FF = 2,
  // w_clk and r_clk are the same net: skip the synchronisers, which in one
  // domain are SYNC_FF cycles of latency protecting against nothing.
  parameter bit SAME_CLOCK  = 0,
  // Release a frame once CT_MIN of its beats are resident instead of all of
  // them. CT_MIN is derived below from the two numbers that decide it.
  parameter bit CUT_THROUGH = 0,
  parameter int MAX_FRAME_BEATS = DEPTH,
  // Worst-case reader cycles between consecutive beats of one frame at the
  // WRITE port. 1 = the source cannot stall inside a frame.
  parameter int W_GAP_MAX = 1
)(
  // ---- write domain ----
  input  logic                w_clk,
  input  logic                w_rst_n,
  input  logic [DATA_W-1:0]   s_tdata,
  input  logic [DATA_W/8-1:0] s_tkeep,
  input  logic                s_tvalid,
  input  logic                s_tlast,
  output logic                s_tready,
  output logic [31:0]         pkts_in,    // frames committed
  output logic [31:0]         hwm,        // high-water mark, beats

  // ---- read domain ----
  input  logic                r_clk,
  input  logic                r_rst_n,
  output logic [DATA_W-1:0]   m_tdata,
  output logic [DATA_W/8-1:0] m_tkeep,
  output logic                m_tvalid,
  output logic                m_tlast,
  input  logic                m_tready,
  output logic [31:0]         starves     // port idle mid-frame with m_tready
);
  localparam int AW = $clog2(DEPTH);
  localparam int PW = AW + 1;                     // one guard bit
  localparam int EW = DATA_W + DATA_W/8 + 1;      // tdata ++ tkeep ++ tlast

  // Beats of a frame that must be resident before the reader may start it.
  // Store-and-forward is the CUT_THROUGH=0 case and also, correctly, what the
  // formula returns when the writer can stall for a whole frame.
  localparam int CT_MIN = MAX_FRAME_BEATS - (MAX_FRAME_BEATS - 1) / W_GAP_MAX;

  if (CUT_THROUGH && (W_GAP_MAX < 1))
    $error("axis_sf_fifo: W_GAP_MAX must be >= 1");
  if (CUT_THROUGH && (MAX_FRAME_BEATS > DEPTH))
    $error("axis_sf_fifo: MAX_FRAME_BEATS %0d exceeds DEPTH %0d",
           MAX_FRAME_BEATS, DEPTH);

  function automatic logic [PW-1:0] bin2gray(input logic [PW-1:0] b);
    return b ^ (b >> 1);
  endfunction

  function automatic logic [PW-1:0] gray2bin(input logic [PW-1:0] g);
    logic [PW-1:0] t;
    t = '0;
    for (int i = PW-1; i >= 0; i--) t[i] = (i == PW-1) ? g[i] : (t[i+1] ^ g[i]);
    return t;
  endfunction

  (* ram_style = "block" *) logic [EW-1:0] mem  [DEPTH];
  // one bit per slot, read combinationally at the pop address -- see the header
  (* ram_style = "distributed" *) logic    last_mem [DEPTH];

  logic [PW-1:0] wbin, wgray, rbin, rgray;
  logic [PW-1:0] pkt_wr_gray, pkt_rd;
  logic [PW-1:0] pkt_wr_gray_r;                   // frame count, in read domain
  logic [PW-1:0] wgray_r;                         // write pointer, in read domain
  logic [PW-1:0] rgray_w;                         // read pointer, in write domain

  // ---- crossings ----
  // SAME_CLOCK bypasses all three. Nothing else about the handshakes changes:
  // the gray coding is simply redundant when both ends see the same edge.
  if (SAME_CLOCK) begin : g_sync_bypass
    assign pkt_wr_gray_r = pkt_wr_gray;
    assign wgray_r       = wgray;
    assign rgray_w       = rgray;
  end else begin : g_sync_cdc
    (* ASYNC_REG = "TRUE" *) logic [PW-1:0] pw_sync_q [SYNC_FF];
    (* ASYNC_REG = "TRUE" *) logic [PW-1:0] wg_sync_q [SYNC_FF];
    (* ASYNC_REG = "TRUE" *) logic [PW-1:0] rg_sync_q [SYNC_FF];

    always_ff @(posedge r_clk) begin
      if (!r_rst_n) begin
        for (int i = 0; i < SYNC_FF; i++) begin
          pw_sync_q[i] <= '0;
          wg_sync_q[i] <= '0;
        end
      end else begin
        pw_sync_q[0] <= pkt_wr_gray;
        wg_sync_q[0] <= wgray;
        for (int i = 1; i < SYNC_FF; i++) begin
          pw_sync_q[i] <= pw_sync_q[i-1];
          wg_sync_q[i] <= wg_sync_q[i-1];
        end
      end
    end

    always_ff @(posedge w_clk) begin
      if (!w_rst_n) for (int i = 0; i < SYNC_FF; i++) rg_sync_q[i] <= '0;
      else begin
        rg_sync_q[0] <= rgray;
        for (int i = 1; i < SYNC_FF; i++) rg_sync_q[i] <= rg_sync_q[i-1];
      end
    end

    assign pkt_wr_gray_r = pw_sync_q[SYNC_FF-1];
    assign wgray_r       = wg_sync_q[SYNC_FF-1];
    assign rgray_w       = rg_sync_q[SYNC_FF-1];
  end

  // ================= write side =================
  // Fullness is measured from the SPECULATIVE pointer: an uncommitted frame
  // occupies slots even though the reader cannot see them yet. rgray_w lags the
  // real reader, so occupancy is over-stated -- the safe direction.
  wire [PW-1:0] rbin_w = gray2bin(rgray_w);
  wire [PW-1:0] occ_w  = wbin - rbin_w;           // PW-bit: wraps with the pointers
  wire          w_full = (occ_w == PW'(DEPTH));

  assign s_tready = !w_full;
  wire   w_push   = s_tvalid && s_tready;

  always_ff @(posedge w_clk) begin
    if (!w_rst_n) begin
      wbin <= '0; wgray <= '0; pkt_wr_gray <= '0; pkts_in <= '0; hwm <= '0;
    end else begin
      if (w_push) begin
        mem[wbin[AW-1:0]]      <= {s_tdata, s_tkeep, s_tlast};
        last_mem[wbin[AW-1:0]] <= s_tlast;
        wbin  <= wbin + 1'b1;
        wgray <= bin2gray(wbin + 1'b1);
        if (s_tlast) begin
          // publish the frame: a single increment, so gray code is meaningful
          pkt_wr_gray <= bin2gray(gray2bin(pkt_wr_gray) + 1'b1);
          pkts_in     <= pkts_in + 1'b1;
        end
      end
      if (32'(occ_w) > hwm) hwm <= 32'(occ_w);
    end
  end

  // ================= read side =================
  // Two storage slots between the array and the port, accounted exactly as
  // cdc_fifo accounts them: the memory's synchronous output register, then the
  // port register that gives first-word-fall-through.
  logic [PW-1:0] rbin_next, rgray_next;
  logic          r_pop, in_frame;
  logic [EW-1:0] rdata;
  logic          rvalid;
  logic          out_acc, rd_free;

  assign rbin_next  = rbin + 1'b1;
  assign rgray_next = bin2gray(rbin_next);

  // Beats actually written and not yet fetched. wgray_r lags the true writer,
  // so this UNDER-states residency -- the safe direction, and the reason it can
  // gate the pop without any risk of running past the write pointer.
  wire [PW-1:0] occ_r  = gray2bin(wgray_r) - rbin;
  wire          r_data = (occ_r != '0);

  // Whole frames waiting. Cut-through lets the reader finish a frame before its
  // commit has crossed, so pkt_rd can transiently LEAD the synchronised writer
  // count; a plain != would read that as another frame and start one that does
  // not exist. The difference is treated as signed instead -- it is bounded by
  // the synchroniser lag, far inside the guard bit.
  wire [PW-1:0] pkt_diff  = gray2bin(pkt_wr_gray_r) - pkt_rd;
  wire          frame_rdy = (pkt_diff != '0) && !pkt_diff[PW-1];

  wire ct_rdy    = CUT_THROUGH && (occ_r >= PW'(CT_MIN));
  wire can_start = frame_rdy || ct_rdy;

  assign out_acc = !m_tvalid || m_tready;
  assign rd_free = !rvalid   || out_acc;
  // Start a frame only when it is safe to; once started, run it to its tlast.
  assign r_pop   = rd_free && r_data && (in_frame || can_start);

  wire pop_is_last = last_mem[rbin[AW-1:0]];

  always_ff @(posedge r_clk) begin
    if (!r_rst_n) begin
      rbin <= '0; rgray <= '0; pkt_rd <= '0; rvalid <= 1'b0; m_tvalid <= 1'b0;
      m_tdata <= '0; m_tkeep <= '0; m_tlast <= 1'b0; in_frame <= 1'b0;
    end else begin
      if (r_pop) begin
        rdata <= mem[rbin[AW-1:0]];
        rbin  <= rbin_next;
        rgray <= rgray_next;
        // the frame is consumed the moment its last beat is FETCHED, not when
        // it reaches the port: this is the gate on r_pop, so it has to close in
        // the same cycle or the reader overruns the committed region
        if (pop_is_last) pkt_rd <= pkt_rd + 1'b1;
        in_frame <= !pop_is_last;
      end
      if (rd_free) rvalid <= r_pop;
      if (out_acc) begin
        m_tvalid <= rvalid;
        if (rvalid) {m_tdata, m_tkeep, m_tlast} <= rdata;
      end
    end
  end

  // ---- underrun, counted at the port ----
  // A frame is open from the cycle a non-last beat is accepted until its tlast
  // is accepted. Any cycle in that window where the sink asks and the port has
  // nothing is exactly the corruption store-and-forward exists to prevent.
  logic port_open;
  wire  out_beat = m_tvalid && m_tready;

  always_ff @(posedge r_clk) begin
    if (!r_rst_n) begin
      port_open <= 1'b0;
      starves   <= '0;
    end else begin
      if (out_beat) port_open <= !m_tlast;
      if (port_open && m_tready && !m_tvalid) starves <= starves + 1'b1;
    end
  end

endmodule
