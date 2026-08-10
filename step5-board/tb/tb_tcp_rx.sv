// Self-checking testbench for tcp_rx.
//
// The module's whole value is its sequence bookkeeping, and every failure mode
// there is silent: a wrong rcv_nxt makes every transmitted segment carry a bad
// ACK, and the venue simply stops progressing. So the checks are on state, not
// on "a frame came out":
//
//   1. only the configured 4-tuple is accepted
//   2. in-order payload advances rcv_nxt by exactly its length
//   3. a gap does NOT advance rcv_nxt, and is counted
//   4. a pure duplicate does not advance it either
//   5. a PARTIALLY overlapping retransmission does -- this is the one that wedges
//      a connection if it is treated as a duplicate
//   6. a pure ACK updates peer_ack without moving rcv_nxt
//   7. FIN and RST are flagged
//   8. sequence arithmetic survives wrapping past 2^32
`timescale 1ns/1ps
module tb_tcp_rx;
  localparam int DATA_W = 512;
  localparam int BYTES  = DATA_W/8;

  logic clk = 0, rst_n = 0;
  always #2.3 clk = ~clk;

  logic [31:0] cfg_local_ip = 32'h0A00_0002, cfg_peer_ip = 32'h0A00_0009;
  logic [15:0] cfg_local_port = 16'd40001, cfg_peer_port = 16'd4001;
  logic [31:0] cfg_irs = 32'h2000_0000;
  logic        cfg_load = 0;

  logic [DATA_W-1:0]   s_tdata = '0, m_tdata;
  logic [DATA_W/8-1:0] s_tkeep = '0, m_tkeep;
  logic s_tvalid = 0, s_tlast = 0, m_tvalid, m_tlast;
  logic [15:0] o_pay_off, o_pay_len, peer_window;
  logic [31:0] rcv_nxt, peer_ack;
  logic seen_fin, seen_rst;
  logic [31:0] frames_in, frames_kept, drop_not_tcp, drop_tuple,
               drop_ooo, drop_dup, payload_bytes;

  tcp_rx #(.DATA_W(DATA_W)) dut (.*);

  int errors = 0;
  int m_beats = 0;
  always @(posedge clk) if (rst_n && m_tvalid) m_beats++;

  task automatic chk(input bit cond, input string what);
    if (!cond) begin $display("FAIL: %s", what); errors++; end
  endtask

  // ---- build one Ethernet/IPv4/TCP frame ----------------------------------
  byte unsigned fr [];

  function automatic void put16(input int off, input int unsigned v);
    fr[off] = (v >> 8) & 8'hFF; fr[off+1] = v & 8'hFF;
  endfunction
  function automatic void put32(input int off, input longint unsigned v);
    fr[off]   = (v >> 24) & 8'hFF; fr[off+1] = (v >> 16) & 8'hFF;
    fr[off+2] = (v >>  8) & 8'hFF; fr[off+3] = v & 8'hFF;
  endfunction

  // doff in 32-bit words (5 = no options); flags bit0 FIN, 1 SYN, 2 RST, 4 ACK
  function automatic void build(input longint unsigned seq, input longint unsigned ack,
                                input int paylen, input logic [7:0] flags,
                                input int doff, input bit good_tuple);
    int hdr = 34 + doff*4;
    fr = new[hdr + paylen];
    foreach (fr[i]) fr[i] = 8'h00;
    put16(12, 16'h0800);                 // EtherType IPv4
    fr[14] = 8'h45;                      // IPv4, IHL 5
    put16(16, 20 + doff*4 + paylen);     // IP total length
    fr[23] = 8'd6;                       // TCP
    put32(26, good_tuple ? 32'h0A00_0009 : 32'h0A00_00FF);  // src IP
    put32(30, 32'h0A00_0002);            // dst IP
    put16(34, good_tuple ? 4001 : 9999); // src port
    put16(36, 40001);                    // dst port
    put32(38, seq);
    put32(42, ack);
    fr[46] = {doff[3:0], 4'h0};
    fr[47] = flags;
    put16(48, 16'd4096);                 // window
    for (int i = 0; i < paylen; i++) fr[hdr+i] = 8'(8'hA0 + i[7:0]);
  endfunction

  task automatic send();
    int n = fr.size(); int i = 0; int k;
    while (i < n) begin
      k = (n - i > BYTES) ? BYTES : (n - i);
      @(negedge clk);
      s_tdata = '0; s_tkeep = '0;
      for (int j = 0; j < k; j++) begin
        s_tdata[8*j +: 8] = fr[i+j];
        s_tkeep[j] = 1'b1;
      end
      s_tvalid = 1'b1; s_tlast = (i + k >= n);
      i += k;
    end
    @(negedge clk); s_tvalid = 0; s_tlast = 0; s_tkeep = '0;
    repeat (2) @(negedge clk);
  endtask

  initial begin
    repeat (4) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);
    @(negedge clk); cfg_load = 1; @(negedge clk); cfg_load = 0;
    repeat (2) @(negedge clk);
    chk(rcv_nxt == 32'h2000_0000, "cfg_load adopts the initial receive sequence");

    // 1. wrong tuple is rejected
    build(32'h2000_0000, 32'h1000_0000, 20, 8'h10, 5, 0); send();
    chk(drop_tuple == 1,               "wrong 4-tuple counted");
    chk(rcv_nxt == 32'h2000_0000,      "wrong 4-tuple does not move rcv_nxt");
    chk(m_beats == 0,                  "wrong 4-tuple is not passed through");

    // 2. in-order payload
    build(32'h2000_0000, 32'h1000_0000, 20, 8'h10, 5, 1); send();
    chk(rcv_nxt == 32'h2000_0014,      "in-order payload advances rcv_nxt by 20");
    chk(peer_ack == 32'h1000_0000,     "peer_ack taken from the ACK field");
    chk(o_pay_len == 20,               "payload length reported");
    chk(o_pay_off == 54,               "payload offset reported (doff=5)");
    chk(m_beats > 0,                   "session frame passed through");

    // 3. a gap must NOT advance rcv_nxt
    build(32'h2000_0064, 32'h1000_0000, 10, 8'h10, 5, 1); send();
    chk(drop_ooo == 1,                 "out-of-order counted");
    chk(rcv_nxt == 32'h2000_0014,      "gap does not advance rcv_nxt");

    // 4. pure duplicate, entirely behind
    build(32'h2000_0000, 32'h1000_0000, 20, 8'h10, 5, 1); send();
    chk(drop_dup == 1,                 "duplicate counted");
    chk(rcv_nxt == 32'h2000_0014,      "duplicate does not advance rcv_nxt");

    // 5. PARTIAL overlap: starts behind, reaches past. Must be accepted, or the
    //    connection wedges on every retransmission.
    build(32'h2000_000A, 32'h1000_0000, 30, 8'h10, 5, 1); send();
    chk(rcv_nxt == 32'h2000_0028,      "overlapping retransmission accepted (seq+len)");
    chk(drop_dup == 1,                 "overlap not miscounted as duplicate");

    // 6. pure ACK, no payload
    build(32'h2000_0028, 32'h1000_00FF, 0, 8'h10, 5, 1); send();
    chk(peer_ack == 32'h1000_00FF,     "pure ACK updates peer_ack");
    chk(rcv_nxt == 32'h2000_0028,      "pure ACK does not move rcv_nxt");

    // 7. TCP options (doff=8) -> payload offset moves out to 66
    build(32'h2000_0028, 32'h1000_00FF, 16, 8'h10, 8, 1); send();
    chk(o_pay_off == 66,               "payload offset follows the data offset");
    chk(rcv_nxt == 32'h2000_0038,      "payload after options still advances rcv_nxt");

    // 8. FIN and RST
    build(32'h2000_0038, 32'h1000_00FF, 0, 8'h11, 5, 1); send();
    chk(seen_fin,                      "FIN flagged");
    build(32'h2000_0039, 32'h1000_00FF, 0, 8'h04, 5, 1); send();
    chk(seen_rst,                      "RST flagged");

    // 9. sequence wrap past 2^32
    @(negedge clk); cfg_irs = 32'hFFFF_FFF0; cfg_load = 1;
    @(negedge clk); cfg_load = 0; repeat (2) @(negedge clk);
    build(32'hFFFF_FFF0, 32'h1000_00FF, 32, 8'h10, 5, 1); send();
    chk(rcv_nxt == 32'h0000_0010,      "rcv_nxt wraps correctly past 2^32");

    if (errors == 0)
      $display("PASS: tcp_rx -- tuple filter, sequence tracking, overlap and wrap");
    else
      $display("FAIL: %0d error(s)", errors);
    $finish;
  end

  initial begin #500000; $display("FAIL: timeout"); $finish; end
endmodule
