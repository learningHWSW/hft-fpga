// Order-frame capture: the datapath's TX stream into device memory, so the host
// can diff what the card emitted against the software golden.
//
// This is the other half of the on-card harness (eth_replay is the source). It
// records EVERY frame the datapath transmits -- order frames, IGMP reports, ARP
// replies -- and leaves the sorting to the host, which classifies by ethertype
// and IP protocol exactly as tb_t2t_axil_full.sv does. Reusing the testbench's
// classification rather than reinventing it in RTL is what makes the hardware
// log directly comparable to the simulation log.
//
// RECORD FORMAT is the same one eth_replay consumes, so one host-side parser
// serves both directions:
//
//   byte 0..1     frame length, little-endian uint16
//   byte 64..     the frame bytes
//
// FIXED STRIDE, and why it is not a waste. Each record occupies RECORD_BYTES
// (2 KB) regardless of frame size, and record N starts at base + N*2048. That
// looks profligate for a 106-byte order frame, but it buys AXI correctness for
// free: a burst may never cross a 4 KB address boundary, and a burst of at most
// 2048 bytes starting on a 2048-byte boundary provably cannot. The alternative
// -- packing records tightly and splitting bursts at 4 KB -- is more logic to
// get wrong for memory this design is not short of. Only (1 + data beats) are
// actually written, so the padding costs address space, not bandwidth.
//
// BACKPRESSURE IS ALLOWED HERE, unlike the RX side. s_tready drops while a
// frame is draining to memory, which is legitimate: this sits where the CMAC TX
// port would be, and a MAC does backpressure. The datapath already accounts for
// it -- tcp_tx stalls and st_blk_txfull counts the blocked decisions -- so a
// capture that cannot keep up shows up as a counter, not as silent corruption.
// Order frames are microseconds apart, so in practice it never stalls.
`timescale 1ns/1ps
module eth_capture #(
  parameter int DATA_W       = 512,
  parameter int ADDR_W       = 64,
  parameter int RECORD_BEATS = 32   // stride, in beats: 2 KB, covers any frame
)(
  input  logic                clk,
  input  logic                rst_n,

  // ---- control ----
  input  logic [ADDR_W-1:0]   cfg_base,      // device address of the capture area
  input  logic [31:0]         cfg_records,   // capacity, in records
  input  logic                clear,         // one-cycle pulse: rewind + zero
  output logic [31:0]         frames_out,    // frames written
  output logic [31:0]         beats_out,     // beats written, headers included
  output logic [31:0]         overflow,      // frames dropped, area full
  output logic [31:0]         stall_cnt,     // beats refused while draining

  // ---- AXI-Stream in, from the datapath's TX port ----
  input  logic [DATA_W-1:0]   s_tdata,
  input  logic [DATA_W/8-1:0] s_tkeep,
  input  logic                s_tvalid,
  input  logic                s_tlast,
  output logic                s_tready,

  // ---- AXI4 write master (this block never reads) ----
  output logic [ADDR_W-1:0]   m_axi_awaddr,
  output logic [7:0]          m_axi_awlen,
  output logic                m_axi_awvalid,
  input  logic                m_axi_awready,
  output logic [DATA_W-1:0]   m_axi_wdata,
  output logic [DATA_W/8-1:0] m_axi_wstrb,
  output logic                m_axi_wlast,
  output logic                m_axi_wvalid,
  input  logic                m_axi_wready,
  input  logic                m_axi_bvalid,
  output logic                m_axi_bready
);
  localparam int KEEP_W = DATA_W / 8;
  localparam int BW     = $clog2(RECORD_BEATS);       // beat index within a frame
  localparam int EW     = DATA_W + KEEP_W;            // data ++ keep

  // ================= frame buffer =================
  // A whole frame is assembled before any of it is written, because the record
  // header carries the length and the length is not known until tlast.
  (* ram_style = "block" *) logic [EW-1:0] fbuf [RECORD_BEATS];

  logic [BW:0]  fill;                  // beats accepted for the current frame
  logic [15:0]  bytes_acc;             // bytes accepted for the current frame

  // popcount of the byte-enable: intermediate beats are full, but trusting that
  // would make a short beat mid-frame silently mis-length the record
  function automatic logic [6:0] keep_bytes(input logic [KEEP_W-1:0] k);
    logic [6:0] n;
    n = '0;
    for (int i = 0; i < KEEP_W; i++) n += 7'(k[i]);
    return n;
  endfunction

  // ================= drain =================
  typedef enum logic [2:0] { C_ACC, C_ADDR, C_HDR, C_DATA, C_RESP } cstate_t;
  cstate_t cst;

  logic [BW:0]       nbeats;           // data beats in the frame being written
  logic [BW:0]       wcnt;             // beats already put on the w channel
  logic [15:0]       rec_len;
  logic [31:0]       rec_idx;          // next record slot
  logic [EW-1:0]     rd;               // buffer read data

  // ---- ONE read port, one address, one read expression ----
  // This must stay a single `fbuf[rd_addr]` in exactly one place. The first
  // version read the array from two states with two different index expressions
  // (`fbuf[0]` and `fbuf[wcnt+1]`), which cannot map onto a block RAM read port:
  // Vivado built a 576-bit-wide 32:1 multiplexer in LUTs instead, and the
  // resulting congestion broke the router outright --
  //   ERROR: [VPL 35-2] Design is not legally routed. There are 4797 node overlaps.
  //   ERROR: [VPL 18-1000] partially-conflicted nets: u_capture/rd[459]_i_2_n_0,
  //                        u_capture/rd[463]_i_2_n_0, u_capture/rd[441]_i_2_n_0 ...
  // Every conflicted net named in that error is a bit of this mux. With one
  // address register the array infers as simple dual-port block RAM: one write
  // port in the FSM below, this read port, and no mux at all.
  logic [BW-1:0]     rd_addr;
  logic              rd_pending;       // a read is in flight; rd not yet valid

  always_ff @(posedge clk) rd <= fbuf[rd_addr];

  wire full = (rec_idx >= cfg_records);

  // ---- input pipeline stage ----
  // The incoming beat is registered before anything is computed from it. The
  // reason is measured: without it the path runs from the TX arbiter's select,
  // through its 512-bit mux, into a 64-input popcount and a 16-bit accumulator,
  // all combinational --
  //   Source:      u_t2t/u_tx_arb/sel_reg/C
  //   Destination: u_capture/bytes_acc_reg[13]/D    setup -0.198 ns @ 300 MHz
  // Out of context that path had +0.553 ns; under real congestion in the shell's
  // pblock it goes negative. Registering here cuts it at the flop, so the
  // popcount starts from a register instead of from the far side of an arbiter.
  // The cost is one cycle before a frame's byte count settles, which is free:
  // capture is the harness, not the trading path, and the length is only needed
  // once the frame has finished.
  logic [DATA_W-1:0] q_tdata;
  logic [KEEP_W-1:0] q_tkeep;
  logic              q_valid, q_last;

  // Stop accepting as soon as a last beat is in the pipeline, so the next
  // frame's first beat cannot slip in during the extra cycle.
  assign s_tready    = (cst == C_ACC) && !full && !(q_valid && q_last);
  assign m_axi_bready = 1'b1;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cst <= C_ACC; fill <= '0; bytes_acc <= '0; nbeats <= '0; wcnt <= '0;
      rd_addr <= '0; rd_pending <= 1'b0;
      q_valid <= 1'b0; q_last <= 1'b0;
      rec_len <= '0; rec_idx <= '0;
      frames_out <= '0; beats_out <= '0; overflow <= '0; stall_cnt <= '0;
      m_axi_awvalid <= 1'b0; m_axi_awaddr <= '0; m_axi_awlen <= '0;
      m_axi_wvalid <= 1'b0; m_axi_wdata <= '0; m_axi_wstrb <= '0; m_axi_wlast <= 1'b0;
    end else if (clear) begin
      cst <= C_ACC; fill <= '0; bytes_acc <= '0; rec_idx <= '0; q_valid <= 1'b0;
      frames_out <= '0; beats_out <= '0; overflow <= '0; stall_cnt <= '0;
      m_axi_awvalid <= 1'b0; m_axi_wvalid <= 1'b0;
    end else begin
      // a frame arriving with nowhere to put it, or while the previous one is
      // still draining, is counted rather than silently lost
      if (s_tvalid && !s_tready) begin
        stall_cnt <= stall_cnt + 1'b1;
        if (full && s_tlast) overflow <= overflow + 1'b1;
      end

      // ---- stage 1: register the beat as it is accepted ----
      q_valid <= s_tvalid && s_tready;
      if (s_tvalid && s_tready) begin
        q_tdata <= s_tdata;
        q_tkeep <= s_tkeep;
        q_last  <= s_tlast;
      end

      case (cst)
        // ---- stage 2: accumulate the registered beat ----
        C_ACC: if (q_valid) begin
          fbuf[fill[BW-1:0]] <= {q_tdata, q_tkeep};
          bytes_acc <= bytes_acc + 16'(keep_bytes(q_tkeep));
          if (q_last) begin
            nbeats  <= fill + 1'b1;
            rec_len <= bytes_acc + 16'(keep_bytes(q_tkeep));
            fill    <= '0;
            bytes_acc <= '0;
            cst     <= C_ADDR;
          end else if (fill == RECORD_BEATS - 1) begin
            // longer than one record: impossible for this datapath (frames are
            // ~106 B) but drop it rather than wrap and corrupt the next slot
            fill      <= '0;
            bytes_acc <= '0;
            overflow  <= overflow + 1'b1;
          end else begin
            fill <= fill + 1'b1;
          end
        end

        // ---- one burst per frame: header beat + data beats ----
        C_ADDR: begin
          m_axi_awaddr  <= cfg_base + (ADDR_W'(rec_idx) << (BW + $clog2(KEEP_W)));
          m_axi_awlen   <= 8'(nbeats);          // (1 + nbeats) beats - 1
          m_axi_awvalid <= 1'b1;
          if (m_axi_awvalid && m_axi_awready) begin
            m_axi_awvalid <= 1'b0;
            // header beat goes out first, carrying the length
            m_axi_wdata  <= {{(DATA_W-16){1'b0}}, rec_len};
            m_axi_wstrb  <= {KEEP_W{1'b1}};
            m_axi_wlast  <= (nbeats == 0);
            m_axi_wvalid <= 1'b1;
            wcnt         <= '0;
            cst          <= C_HDR;
          end
        end

        C_HDR: if (m_axi_wvalid && m_axi_wready) begin
          beats_out <= beats_out + 1'b1;
          if (nbeats == 0) begin                // pathological: empty frame
            m_axi_wvalid <= 1'b0;
            cst <= C_RESP;
          end else begin
            rd_addr    <= '0;                   // point the read port at beat 0
            rd_pending <= 1'b1;                 // and wait for the RAM
            wcnt <= '0;
            m_axi_wvalid <= 1'b0;
            cst  <= C_DATA;
          end
        end

        // ---- stream the buffered beats, byte-enables from the frame's tkeep ----
        C_DATA: begin
          // One cycle for the block RAM to answer. Unconditional rather than
          // inferred from state duration, so it cannot go subtly wrong if the
          // preceding state is entered and left in the same cycle. Capture is the
          // harness, not the trading path -- an extra cycle per beat on a frame
          // that arrives every few microseconds costs nothing.
          if (rd_pending) begin
            rd_pending <= 1'b0;
          end else if (!m_axi_wvalid) begin
            m_axi_wdata  <= rd[EW-1 -: DATA_W];
            m_axi_wstrb  <= rd[KEEP_W-1:0];
            m_axi_wlast  <= (wcnt == nbeats - 1'b1);
            m_axi_wvalid <= 1'b1;
          end else if (m_axi_wready) begin
            beats_out <= beats_out + 1'b1;
            if (wcnt == nbeats - 1'b1) begin
              m_axi_wvalid <= 1'b0;
              cst <= C_RESP;
            end else begin
              rd_addr      <= BW'(wcnt + 1'b1);
              rd_pending   <= 1'b1;             // bubble while the RAM reads
              wcnt         <= wcnt + 1'b1;
              m_axi_wvalid <= 1'b0;
            end
          end
        end

        C_RESP: if (m_axi_bvalid) begin
          frames_out <= frames_out + 1'b1;
          rec_idx    <= rec_idx + 1'b1;
          cst        <= C_ACC;
        end

        default: cst <= C_ACC;
      endcase
    end
  end

endmodule
