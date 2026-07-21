// Asynchronous (dual-clock) FIFO — the CMAC-to-core clock crossing.
//
// Why this exists at all. The obvious reading of "100G feed handler" is that
// fh_core must run at the CMAC's 322.265625 MHz. It does not, and chasing that
// number was the wrong frame: 512 bits at 322.265625 MHz is 165 Gb/s of
// interface bandwidth against a 100 Gb/s wire, so beats arrive only ~60% of
// cycles on average. What the core actually has to sustain is
//   12.5 GB/s / 64 B = 195.3 MHz
// (see step5-board/README.md). Anything at or above that drains the wire in
// the long run; this FIFO absorbs the short-term difference between the CMAC's
// bursty 322 MHz delivery and the core's steady, slower consumption.
//
// Write side never stalls. s_tready does not exist on purpose — the same
// market-data policy the rest of the design follows (PLAN §1): the wire cannot
// be backpressured, so an overflowing FIFO drops the beat and counts it rather
// than corrupting timing upstream. drop_cnt and hwm are the evidence that the
// depth chosen here is right, and they are read out over AXI-Lite like every
// other counter.
//
// Sizing. The measured worst case is 76 messages / 2356 bytes inside one
// window (data/FINDINGS.md §2), i.e. 37 beats of back-to-back arrival, and the
// core drains one beat per cycle at a ~1.6x slower clock. DEPTH=256 covers
// that with ~6x margin for four BRAMs; hwm reports how much of it real data
// ever touches, so the number can be cut later on evidence rather than nerve.
//
// CDC structure — the part that is easy to get subtly wrong, so it is written
// the textbook way and not improvised:
//   * pointers are one bit wider than the address, so full and empty are
//     distinguishable rather than aliasing at the wrap;
//   * pointers cross as GRAY code, so a value sampled mid-transition differs
//     from a true pointer by at most one increment, never by an arbitrary
//     multi-bit garbage value;
//   * each crossing goes through two flops (SYNC_FF), and those flops are
//     marked ASYNC_REG so the placer keeps them adjacent;
//   * the payload memory is written and read on different clocks but is NEVER
//     synchronised — it is safe only because the pointer handshake guarantees
//     a location is read no earlier than one full synchroniser latency after
//     it was written.
// The conservatism costs latency: full/empty are pessimistic by the two-flop
// delay, which shows up as unused depth, not as lost data.
`timescale 1ns/1ps
module cdc_fifo #(
  parameter int DATA_W  = 512,
  parameter int DEPTH   = 256,          // must be a power of two
  parameter int SYNC_FF = 2
)(
  // ---- write domain (CMAC, 322.265625 MHz) ----
  input  logic                w_clk,
  input  logic                w_rst_n,
  input  logic [DATA_W-1:0]   s_tdata,
  input  logic [DATA_W/8-1:0] s_tkeep,
  input  logic                s_tvalid,
  input  logic                s_tlast,
  output logic [31:0]         drop_cnt,   // beats lost to a full FIFO
  output logic [31:0]         hwm,        // high-water mark, in beats

  // ---- read domain (fh_core) ----
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

  // ---- payload memory: written on w_clk, read on r_clk, never synchronised ----
  (* ram_style = "block" *) logic [EW-1:0] mem [DEPTH];

  logic [PW-1:0] wbin, wgray, rbin, rgray;
  logic [PW-1:0] wgray_r, rgray_w;                // pointers after crossing

  // ---- write pointer -> read domain ----
  (* ASYNC_REG = "TRUE" *) logic [PW-1:0] wg_sync_q [SYNC_FF];
  always_ff @(posedge r_clk) begin
    if (!r_rst_n) for (int i = 0; i < SYNC_FF; i++) wg_sync_q[i] <= '0;
    else begin
      wg_sync_q[0] <= wgray;
      for (int i = 1; i < SYNC_FF; i++) wg_sync_q[i] <= wg_sync_q[i-1];
    end
  end
  assign wgray_r = wg_sync_q[SYNC_FF-1];

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

  // ---- write side ----
  // full when the next write would land on the read pointer's slot: in gray
  // code that is the read pointer with its top two bits inverted.
  logic [PW-1:0] wbin_next, wgray_next;
  logic          w_full, w_push;
  assign wbin_next  = wbin + 1'b1;
  assign wgray_next = bin2gray(wbin_next);
  assign w_full     = (wgray_next == {~rgray_w[PW-1:PW-2], rgray_w[PW-3:0]});
  assign w_push     = s_tvalid && !w_full;

  // occupancy in the write domain, for hwm. rgray_w is a lagging view of the
  // reader, so this over-states occupancy — the safe direction for a watermark.
  logic [PW-1:0] rbin_w, occ_w;
  always_comb begin                                // gray -> binary
    automatic logic [PW-1:0] t;
    t = '0;
    for (int i = PW-1; i >= 0; i--)
      t[i] = (i == PW-1) ? rgray_w[i] : (t[i+1] ^ rgray_w[i]);
    rbin_w = t;
  end
  // Occupancy MUST be a PW-bit subtraction so it wraps with the pointers.
  // Writing 32'(wbin - rbin_w) is wrong and was: the cast sets the context
  // width, so both operands widen to 32 bits before subtracting and a wrapped
  // pointer pair yields a huge value (-257 showed up as 4294967039) instead of
  // a real occupancy.
  assign occ_w = wbin - rbin_w;

  always_ff @(posedge w_clk) begin
    if (!w_rst_n) begin
      wbin <= '0; wgray <= '0; drop_cnt <= '0; hwm <= '0;
    end else begin
      if (w_push) begin
        mem[wbin[AW-1:0]] <= {s_tdata, s_tkeep, s_tlast};
        wbin  <= wbin_next;
        wgray <= wgray_next;
      end else if (s_tvalid) begin
        drop_cnt <= drop_cnt + 1;                  // never stall the wire
      end
      if (32'(occ_w) > hwm) hwm <= 32'(occ_w);
    end
  end

  // ---- read side ----
  // The memory read is SYNCHRONOUS (that is what keeps it in block RAM rather
  // than LUTRAM — the same lesson as drop_fifo and the ladder), so a popped
  // word is not available until the cycle after the pop. That puts two storage
  // slots between the array and the port, and both need explicit accounting or
  // a stalled m_tready silently overwrites a word that was never accepted:
  //   rdata/rvalid  the memory's output register
  //   m_*/m_tvalid  the output port register (gives first-word-fall-through,
  //                 matching the handshake drop_fifo presents elsewhere)
  // A slot may be refilled only when it is empty or is being drained this
  // cycle, and a pop is issued only when the slot it will land in is free.
  logic [PW-1:0] rbin_next, rgray_next;
  logic          r_empty, r_pop;
  logic [EW-1:0] rdata;
  logic          rvalid;
  logic          out_acc, rd_free;

  assign rbin_next  = rbin + 1'b1;
  assign rgray_next = bin2gray(rbin_next);
  assign r_empty    = (rgray == wgray_r);
  assign out_acc    = !m_tvalid || m_tready;   // port register can take a word
  assign rd_free    = !rvalid   || out_acc;    // memory output register will be free
  assign r_pop      = !r_empty  && rd_free;

  always_ff @(posedge r_clk) begin
    if (!r_rst_n) begin
      rbin <= '0; rgray <= '0; rvalid <= 1'b0; m_tvalid <= 1'b0;
      m_tdata <= '0; m_tkeep <= '0; m_tlast <= 1'b0;
    end else begin
      if (r_pop) begin
        rdata <= mem[rbin[AW-1:0]];
        rbin  <= rbin_next;
        rgray <= rgray_next;
      end
      if (rd_free) rvalid <= r_pop;             // else hold: no new read issued
      if (out_acc) begin
        m_tvalid <= rvalid;
        if (rvalid) {m_tdata, m_tkeep, m_tlast} <= rdata;
      end
    end
  end

endmodule
