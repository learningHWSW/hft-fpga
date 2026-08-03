// Store-and-forward AXI-Stream FIFO, optionally across two clocks.
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
// Set the two clocks to the same net for a synchronous instance. The
// synchronisers then cost two cycles of latency and nothing else, which is why
// both the same-clock order path and the cross-clock feed path use this one
// module rather than two.
`timescale 1ns/1ps
module axis_sf_fifo #(
  parameter int DATA_W  = 512,
  parameter int DEPTH   = 512,          // beats, power of two
  parameter int SYNC_FF = 2
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
  input  logic                m_tready
);
  localparam int AW = $clog2(DEPTH);
  localparam int PW = AW + 1;                     // one guard bit
  localparam int EW = DATA_W + DATA_W/8 + 1;      // tdata ++ tkeep ++ tlast

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

  logic [PW-1:0] wbin, rbin, rgray;
  logic [PW-1:0] pkt_wr_gray, pkt_rd;
  logic [PW-1:0] pkt_wr_gray_r;                   // frame count, in read domain
  logic [PW-1:0] rgray_w;                         // read pointer, in write domain

  // ---- committed-frame count -> read domain ----
  (* ASYNC_REG = "TRUE" *) logic [PW-1:0] pw_sync_q [SYNC_FF];
  always_ff @(posedge r_clk) begin
    if (!r_rst_n) for (int i = 0; i < SYNC_FF; i++) pw_sync_q[i] <= '0;
    else begin
      pw_sync_q[0] <= pkt_wr_gray;
      for (int i = 1; i < SYNC_FF; i++) pw_sync_q[i] <= pw_sync_q[i-1];
    end
  end
  assign pkt_wr_gray_r = pw_sync_q[SYNC_FF-1];

  // ---- read pointer -> write domain ----
  (* ASYNC_REG = "TRUE" *) logic [PW-1:0] rg_sync_q [SYNC_FF];
  always_ff @(posedge w_clk) begin
    if (!w_rst_n) for (int i = 0; i < SYNC_FF; i++) rg_sync_q[i] <= '0;
    else begin
      rg_sync_q[0] <= rgray;
      for (int i = 1; i < SYNC_FF; i++) rg_sync_q[i] <= rg_sync_q[i-1];
    end
  end
  assign rgray_w = rg_sync_q[SYNC_FF-1];

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
      wbin <= '0; pkt_wr_gray <= '0; pkts_in <= '0; hwm <= '0;
    end else begin
      if (w_push) begin
        mem[wbin[AW-1:0]]      <= {s_tdata, s_tkeep, s_tlast};
        last_mem[wbin[AW-1:0]] <= s_tlast;
        wbin <= wbin + 1'b1;
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
  logic          r_avail, r_pop;
  logic [EW-1:0] rdata;
  logic          rvalid;
  logic          out_acc, rd_free;

  assign rbin_next  = rbin + 1'b1;
  assign rgray_next = bin2gray(rbin_next);
  // whole frames are waiting whenever the reader's frame count trails the
  // writer's; mid-frame the counts still differ, so a started frame runs on
  assign r_avail    = (gray2bin(pkt_wr_gray_r) != pkt_rd);
  assign out_acc    = !m_tvalid || m_tready;
  assign rd_free    = !rvalid   || out_acc;
  assign r_pop      = r_avail   && rd_free;

  wire pop_is_last = last_mem[rbin[AW-1:0]];

  always_ff @(posedge r_clk) begin
    if (!r_rst_n) begin
      rbin <= '0; rgray <= '0; pkt_rd <= '0; rvalid <= 1'b0; m_tvalid <= 1'b0;
      m_tdata <= '0; m_tkeep <= '0; m_tlast <= 1'b0;
    end else begin
      if (r_pop) begin
        rdata <= mem[rbin[AW-1:0]];
        rbin  <= rbin_next;
        rgray <= rgray_next;
        // the frame is consumed the moment its last beat is FETCHED, not when
        // it reaches the port: this is the gate on r_pop, so it has to close in
        // the same cycle or the reader overruns the committed region
        if (pop_is_last) pkt_rd <= pkt_rd + 1'b1;
      end
      if (rd_free) rvalid <= r_pop;
      if (out_acc) begin
        m_tvalid <= rvalid;
        if (rvalid) {m_tdata, m_tkeep, m_tlast} <= rdata;
      end
    end
  end

endmodule
