// Feed injector: Ethernet frames out of device memory onto the 512-bit RX
// stream, at the card's own clock.
//
// WHY THIS EXISTS. The QSFP cages are empty, so the first thing to prove on
// real silicon is the datapath, not the optics. This block replaces the CMAC as
// the source of RX beats: the host uploads the SAME `.eth` stimulus file the
// simulations replay, this reads it out of HBM and drives it into t2t_axil
// exactly as the MAC would. The order frames that come back can then be diffed
// against the very same golden the testbenches use, which is the whole point --
// a hardware run that is checkable, not just a run that does not crash.
// Phase B swaps this block for a real cmac_usplus; nothing downstream changes.
//
// BUFFER FORMAT, and why the host does the alignment. A `.eth` file is a
// stream of {2-byte big-endian length, frame bytes} with no alignment at all,
// so consuming it directly would need a barrel shifter to find each frame's
// first byte inside a 512-bit beat -- i.e. a second copy of mold_splitter, the
// hardest block in the project, rebuilt here for no design reason. Instead the
// host pre-pads (scripts/pack_eth.py) into 64-byte-aligned records:
//
//   beat 0        header: bytes[1:0] = frame length, little-endian; rest zero
//   beats 1..N    the frame, N = ceil(len/64), last beat partially filled
//   ...           repeated, terminated by a header whose length is 0
//
// so this block only ever reads whole beats and the byte-lane work collapses to
// one tkeep mask on the final beat. The cost is ~1.5x more HBM traffic than the
// raw file; HBM has bandwidth to spare and the alternative was fabric.
//
// TREADY IS OPTIONAL, and Phase A does not use it. The market-data policy (PLAN
// 1) is that a real wire cannot be backpressured, so the datapath's RX port has
// no tready and the consumer must absorb or drop-and-count. Phase A wires this
// block straight to that port and ties m_tready high, so the contract the design
// saw in simulation is the contract it sees on the card, and the stall logic
// below folds away to nothing under constant propagation.
//
// Phase B needs the port anyway, because there the injector feeds a real
// cmac_usplus rather than the datapath: the MAC's tx_axis_tready genuinely does
// deassert (inter-frame gap, PCS alignment markers), and a source that ignored
// it would drop beats out of the middle of frames instead of merely bubbling.
// One module with a port that Phase A constants away beats two copies.
//
// FLOW CONTROL. Read bursts are issued against credit -- free buffer space minus
// beats already requested -- so the read data channel can never overflow the
// buffer and m_axi_rready is tied high. That is worth stating because the
// obvious alternative (rready as backpressure) throttles badly against HBM's
// latency: with one burst in flight the injector stalls for a round trip per
// kilobyte, well under line rate. MAX_OUT bursts of BURST beats keep enough
// requests standing to cover that latency.
//
// RESTART. `start` is only honoured when the block is idle -- `done` waits for
// the AXI side to quiesce (no outstanding bursts, no pending address) as well as
// for the terminator, so a second run cannot have beats from the first landing
// in its buffer. The register file gates start on !busy for the same reason.
`timescale 1ns/1ps
module eth_replay #(
  parameter int DATA_W  = 512,
  parameter int ADDR_W  = 64,
  parameter int DEPTH   = 128,      // read-data buffer, beats (power of two)
  parameter int BURST   = 16,       // beats per read burst: 1 KB at 512 bits
  parameter int MAX_OUT = 4         // read bursts allowed in flight
)(
  input  logic                clk,
  input  logic                rst_n,

  // ---- control (quasi-static, except start) ----
  input  logic [ADDR_W-1:0]   cfg_base,     // device address of the image
  input  logic [31:0]         cfg_beats,    // total 64-byte beats in the image
  input  logic [15:0]         cfg_gap,      // idle cycles between frames
  input  logic                start,        // one-cycle pulse, honoured when idle
  output logic                busy,
  output logic                done,
  output logic [31:0]         frames_out,   // frames injected
  output logic [31:0]         beats_out,    // data beats injected (no headers)

  // ---- AXI4 read master (address/data only; this block never writes) ----
  output logic [ADDR_W-1:0]   m_axi_araddr,
  output logic [7:0]          m_axi_arlen,
  output logic                m_axi_arvalid,
  input  logic                m_axi_arready,
  input  logic [DATA_W-1:0]   m_axi_rdata,
  input  logic                m_axi_rlast,
  input  logic                m_axi_rvalid,
  output logic                m_axi_rready,

  // ---- AXI-Stream out, to the datapath's RX port ----
  output logic [DATA_W-1:0]   m_tdata,
  output logic [DATA_W/8-1:0] m_tkeep,
  output logic                m_tvalid,
  output logic                m_tlast,
  input  logic                m_tready      // tie high for a non-backpressured sink
);
  localparam int KEEP_W = DATA_W / 8;
  localparam int AW     = $clog2(DEPTH);

  typedef enum logic [2:0] { E_IDLE, E_HDR, E_DATA, E_GAP, E_DONE } estate_t;
  estate_t est;

  // ================= read-data buffer =================
  // Registered read into a head register, the same discipline as drop_fifo: an
  // asynchronous mem[rptr] read is what forces distributed RAM, and this array
  // is DEPTH x 512 bits -- it belongs in block RAM.
  (* ram_style = "block" *) logic [DATA_W-1:0] mem [DEPTH];
  logic [AW:0]       wptr, rptr;
  logic [DATA_W-1:0] head;
  logic              head_valid;

  wire [AW:0] mem_count = wptr - rptr;
  wire        mem_avail = (mem_count != '0);

  logic pop;                                   // emitter consumes head this cycle
  wire  fetch = mem_avail && (!head_valid || pop);

  // ================= AXI read issue =================
  // FIXED-LENGTH BURSTS, and an INCREMENTAL credit. Both are timing fixes, and
  // both were measured rather than guessed: the first version computed the burst
  // length from the beats remaining and the credit from the pointers, and
  // out-of-context synthesis put the resulting chain
  //   rptr -> (wptr-rptr) -> occ -> space -> signed compare -> 64-bit address add
  // on the critical path at 18 logic levels and 10 CARRY8s, missing 300 MHz by
  // 0.196 ns. Neither computation needed to be combinational:
  //
  //  * The burst is always BURST beats. The host pads the image to a whole
  //    number of bursts (scripts/pack_eth.py), so there is no short final burst
  //    to special-case -- the zero-length terminator inside the image is what
  //    ends the run, not the beat count.
  //  * Credit counts buffer slots that are free AND not already promised to a
  //    read in flight, maintained by events instead of recomputed:
  //        issue a burst           -> BURST slots promised  -> credit -= BURST
  //        a beat returns          -> promised becomes held -> credit unchanged
  //        the emitter pops a beat -> a slot frees          -> credit += 1
  //    so the comparison is a register against a constant.
  localparam int BURST_BYTES = BURST * KEEP_W;

  logic [31:0] beats_req;                      // beats requested so far
  logic [7:0]  outstanding;                    // bursts not yet fully returned
  logic [31:0] off_q;                          // byte offset into the image
  logic [15:0] credit;                         // free, unpromised buffer slots

  wire run = (est != E_IDLE) && (est != E_DONE);

  wire can_issue = run && (beats_req < cfg_beats) && (outstanding < MAX_OUT) &&
                   (credit >= 16'(BURST)) && !m_axi_arvalid;

  assign m_axi_rready = 1'b1;                  // credit guarantees room
  assign busy         = run;
  // quiesced: terminator reached AND the AXI side has nothing left in flight,
  // so a restart cannot be polluted by the previous run's read data
  assign done         = (est == E_DONE) && (outstanding == '0) && !m_axi_arvalid;

  wire start_ok = start && (est == E_IDLE || est == E_DONE) &&
                  (outstanding == '0) && !m_axi_arvalid;

  assign m_axi_arlen = 8'(BURST - 1);          // constant: see above

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      m_axi_arvalid <= 1'b0; m_axi_araddr <= '0;
      beats_req <= '0; outstanding <= '0; off_q <= '0;
      credit <= 16'(DEPTH); wptr <= '0;
    end else begin
      // one next-value per counter: the issue and the return/pop arms can fire
      // in the same cycle, and two procedural assignments would silently drop
      // whichever came first
      automatic logic [7:0]  out_n = outstanding;
      automatic logic [15:0] cred_n = credit;

      if (start_ok) begin
        beats_req <= '0;
        off_q     <= '0;
        cred_n     = 16'(DEPTH);
        wptr      <= '0;
      end

      // ---- address channel ----
      if (m_axi_arvalid && m_axi_arready) m_axi_arvalid <= 1'b0;
      if (can_issue) begin
        // one 64-bit add off two registers, not a chain ending in one
        m_axi_araddr  <= cfg_base + ADDR_W'(off_q);
        m_axi_arvalid <= 1'b1;
        off_q         <= off_q + BURST_BYTES;
        beats_req     <= beats_req + BURST;
        out_n          = out_n + 8'd1;
        cred_n         = cred_n - 16'(BURST);
      end

      // ---- data channel: rready is tied high, so rvalid alone is a transfer ----
      // A returning beat turns a promised slot into an occupied one, so credit
      // does not move here.
      if (m_axi_rvalid) begin
        mem[wptr[AW-1:0]] <= m_axi_rdata;
        wptr <= wptr + 1'b1;
        if (m_axi_rlast) out_n = out_n - 8'd1;
      end

      // ---- the emitter freeing a slot is the only thing that returns credit ----
      if (pop) cred_n = cred_n + 16'd1;

      outstanding <= out_n;
      credit      <= cred_n;
    end
  end

  // ================= emitter =================
  logic [15:0] frm_len;
  logic [9:0]  nbeats, bcnt;
  logic [6:0]  rem;                            // bytes in the final beat, 1..64
  logic [15:0] gap_cnt;

  // header beat: the length is a little-endian uint16 in bytes 0-1, so it lands
  // directly in the low half-word of the beat
  wire [15:0] hdr_len = head[15:0];

  // A beat that has been presented but not accepted must stay presented, so the
  // emitter freezes whole -- output register, buffer pop and gap counter alike.
  // Freezing only the output would let the FSM walk on and overwrite the beat
  // the sink has not taken yet, which is the exact failure a missing tready
  // causes: not a bubble, a hole in the middle of a frame.
  wire out_stall = m_tvalid && !m_tready;

  always_comb begin
    case (est)
      E_HDR:   pop = head_valid && !out_stall;
      E_DATA:  pop = head_valid && !out_stall;
      default: pop = 1'b0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      est <= E_IDLE; rptr <= '0; head_valid <= 1'b0;
      m_tvalid <= 1'b0; m_tlast <= 1'b0; m_tdata <= '0; m_tkeep <= '0;
      frames_out <= '0; beats_out <= '0;
      frm_len <= '0; nbeats <= '0; bcnt <= '0; rem <= '0; gap_cnt <= '0;
    end else begin
      // buffer head maintenance
      if (fetch) begin
        head       <= mem[rptr[AW-1:0]];
        head_valid <= 1'b1;
        rptr       <= rptr + 1'b1;
      end else if (head_valid && pop) begin
        head_valid <= 1'b0;
      end

      if (!out_stall) begin
        m_tvalid <= 1'b0;                      // default: no beat this cycle
        m_tlast  <= 1'b0;
      end

      if (start_ok) begin
        est <= E_HDR; rptr <= '0; head_valid <= 1'b0;
        frames_out <= '0; beats_out <= '0;
      end else if (!out_stall) begin
        case (est)
          E_IDLE: ;                            // wait for start

          // ---- header beat: pick up the frame length ----
          E_HDR: if (head_valid) begin
            if (hdr_len == 16'd0) begin        // terminator: image consumed
              est <= E_DONE;
            end else begin
              frm_len <= hdr_len;
              nbeats  <= 10'((hdr_len + KEEP_W - 1) / KEEP_W);
              // bytes in the final beat: a length that divides evenly fills it
              rem     <= (hdr_len[5:0] == 6'd0) ? 7'd64 : 7'(hdr_len[5:0]);
              bcnt    <= '0;
              est     <= E_DATA;
            end
          end

          // ---- frame body: one beat per cycle the buffer can supply ----
          E_DATA: if (head_valid) begin
            automatic logic last = (bcnt == nbeats - 1'b1);
            m_tdata   <= head;
            m_tkeep   <= last ? ({KEEP_W{1'b1}} >> (KEEP_W - rem)) : {KEEP_W{1'b1}};
            m_tvalid  <= 1'b1;
            m_tlast   <= last;
            beats_out <= beats_out + 1'b1;
            bcnt      <= bcnt + 1'b1;
            if (last) begin
              frames_out <= frames_out + 1'b1;
              gap_cnt    <= cfg_gap;
              est        <= (cfg_gap == 0) ? E_HDR : E_GAP;
            end
          end

          // ---- inter-frame gap: the knob that sets offered load ----
          E_GAP: if (gap_cnt <= 16'd1) est <= E_HDR;
                 else                  gap_cnt <= gap_cnt - 1'b1;

          E_DONE: ;                            // hold until the next start

          default: est <= E_IDLE;
        endcase
      end
    end
  end

endmodule
