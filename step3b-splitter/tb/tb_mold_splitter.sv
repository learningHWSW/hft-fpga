// Self-checking TB for mold_splitter (512-bit), chained into itch_decoder.
//
// Reads a .mold file (+mold=<path>; 2B BE length-prefixed UDP payloads) and
// drives each payload as a group of 512-bit beats — 64 bytes per beat, the
// last beat partial (tkeep marks valid bytes), honoring s_tready. That beat
// packing is what forces the realignment: message boundaries land anywhere
// inside a beat and messages straddle beats. Logs decoded messages plus
// GAP/HB/EOS events to splitter_rtl.log; the Makefile diffs it against
// scripts/dump_mold.py (same golden as step 3a — format is width-agnostic).
//
// Runs unmodified under xsim and Verilator --binary --timing.
`timescale 1ns/1ps

module tb_mold_splitter;
  import itch5_pkg::*;

  localparam int DATA_W = 512;
  localparam int KEEP_W = DATA_W / 8;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #1.552 clk = ~clk;  // ~322 MHz, U55C 100G-path

  // driver -> splitter
  logic [DATA_W-1:0] s_tdata;
  logic [KEEP_W-1:0] s_tkeep;
  logic s_tvalid, s_tlast, s_tready;

  // splitter -> decoder
  logic [DATA_W-1:0] x_tdata;
  logic [KEEP_W-1:0] x_tkeep;
  logic x_tvalid, x_tlast, x_tready;

  logic        ev_gap, ev_hb, ev_eos;
  logic [63:0] ev_seq, ev_expected;
  logic [31:0] gap_total, dup_cnt, frame_err_cnt;

  itch_msg_t msg;
  logic mvalid, len_err;

  mold_splitter #(.DATA_W(DATA_W)) dut (
    .clk          (clk),
    .rst_n        (rst_n),
    .s_tdata      (s_tdata),
    .s_tkeep      (s_tkeep),
    .s_tvalid     (s_tvalid),
    .s_tlast      (s_tlast),
    .s_tready     (s_tready),
    .m_tdata      (x_tdata),
    .m_tkeep      (x_tkeep),
    .m_tvalid     (x_tvalid),
    .m_tlast      (x_tlast),
    .ev_gap       (ev_gap),
    .ev_hb        (ev_hb),
    .ev_eos       (ev_eos),
    .ev_seq       (ev_seq),
    .ev_expected  (ev_expected),
    .gap_total    (gap_total),
    .dup_cnt      (dup_cnt),
    .frame_err_cnt(frame_err_cnt)
  );

  itch_decoder #(.DATA_W(DATA_W)) dec (
    .clk      (clk),
    .rst_n    (rst_n),
    .s_tdata  (x_tdata),
    .s_tkeep  (x_tkeep),
    .s_tvalid (x_tvalid),
    .s_tlast  (x_tlast),
    .s_tready (x_tready),
    .m_msg    (msg),
    .m_valid  (mvalid),
    .m_len_err(len_err)
  );

  // ---------- monitor ----------
  int fd_log;
  int n_decoded = 0;
  int n_len_err = 0;
  bit eos_seen = 1'b0;

  initial fd_log = $fopen("splitter_rtl.log", "w");

  // The splitter co-registers message output and event pulses in one stage,
  // but a message then traverses the decoder (x_tvalid -> m_valid = 2 cycles)
  // while events reach the log directly. Delaying event logging by that same
  // decoder latency restores the single-stream order the golden expects.
  localparam int EV_DELAY = 2;
  logic        gp [1:EV_DELAY], hp [1:EV_DELAY], ep [1:EV_DELAY];
  logic [63:0] sp [1:EV_DELAY], xp [1:EV_DELAY];

  always_ff @(posedge clk) begin
    gp[1] <= ev_gap; hp[1] <= ev_hb; ep[1] <= ev_eos;
    sp[1] <= ev_seq; xp[1] <= ev_expected;
    for (int s = 2; s <= EV_DELAY; s++) begin
      gp[s] <= gp[s-1]; hp[s] <= hp[s-1]; ep[s] <= ep[s-1];
      sp[s] <= sp[s-1]; xp[s] <= xp[s-1];
    end
  end

  always @(posedge clk) begin
    // messages first, then same-cycle delayed events (matches golden order)
    if (mvalid) begin
      n_decoded++;
      if (len_err) begin
        n_len_err++;
        $display("** LENGTH ERROR on message %0d type=%c", n_decoded, msg.msg_type);
      end
      log_msg();
    end
    if (gp[EV_DELAY])
      $fdisplay(fd_log, "GAP expected=%0d got=%0d missing=%0d",
                xp[EV_DELAY], sp[EV_DELAY], sp[EV_DELAY] - xp[EV_DELAY]);
    if (hp[EV_DELAY]) $fdisplay(fd_log, "HB seq=%0d", sp[EV_DELAY]);
    if (ep[EV_DELAY]) begin
      $fdisplay(fd_log, "EOS seq=%0d", sp[EV_DELAY]);
      eos_seen <= 1'b1;
    end
  end

  task automatic log_msg();
    case (msg.msg_type)
      "S": $fdisplay(fd_log, "S locate=%0d ts=%0d event=%c",
                     msg.locate, msg.timestamp, msg.event_code);
      "R": $fdisplay(fd_log, "R locate=%0d ts=%0d stock='%s'",
                     msg.locate, msg.timestamp, msg.stock);
      "A", "F":
        $fdisplay(fd_log, "%c locate=%0d ts=%0d ref=%0d side=%c shares=%0d stock='%s' price=%0d",
                  msg.msg_type, msg.locate, msg.timestamp, msg.order_ref,
                  msg.side, msg.shares, msg.stock, msg.price);
      "E": $fdisplay(fd_log, "E locate=%0d ts=%0d ref=%0d shares=%0d match=%0d",
                     msg.locate, msg.timestamp, msg.order_ref, msg.shares, msg.match_num);
      "C": $fdisplay(fd_log, "C locate=%0d ts=%0d ref=%0d shares=%0d match=%0d printable=%c price=%0d",
                     msg.locate, msg.timestamp, msg.order_ref, msg.shares,
                     msg.match_num, msg.printable, msg.price);
      "X": $fdisplay(fd_log, "X locate=%0d ts=%0d ref=%0d shares=%0d",
                     msg.locate, msg.timestamp, msg.order_ref, msg.shares);
      "D": $fdisplay(fd_log, "D locate=%0d ts=%0d ref=%0d",
                     msg.locate, msg.timestamp, msg.order_ref);
      "U": $fdisplay(fd_log, "U locate=%0d ts=%0d ref=%0d newref=%0d shares=%0d price=%0d",
                     msg.locate, msg.timestamp, msg.order_ref,
                     msg.new_order_ref, msg.shares, msg.price);
      "P": $fdisplay(fd_log, "P locate=%0d ts=%0d side=%c shares=%0d stock='%s' price=%0d match=%0d",
                     msg.locate, msg.timestamp, msg.side, msg.shares,
                     msg.stock, msg.price, msg.match_num);
      default:
        $fdisplay(fd_log, "%c locate=%0d ts=%0d",
                  msg.msg_type, msg.locate, msg.timestamp);
    endcase
  endtask

  // ---------- driver: one packet -> ceil(len/64) beats (honors s_tready) ---
  byte unsigned payload[];

  task automatic send_packet(input int n);
    int i, k;
    i = 0;
    while (i < n) begin
      k = (n - i > KEEP_W) ? KEEP_W : (n - i);
      @(negedge clk);
      s_tdata = '0;
      s_tkeep = '0;
      for (int j = 0; j < k; j++) begin
        s_tdata[8*j +: 8] = payload[i+j];
        s_tkeep[j] = 1'b1;
      end
      s_tvalid = 1'b1;
      s_tlast  = (i + k == n);
      forever begin
        @(posedge clk);
        if (s_tready) break;
      end
      i += k;
    end
    @(negedge clk);
    s_tvalid = 1'b0;
    s_tlast  = 1'b0;
    s_tkeep  = '0;
  endtask

  // stall watchdog: trips only if the datapath makes no progress (no decode
  // and no accepted beat) for a long stretch — catches a hang without
  // capping legitimate long replays. Dumps the datapath state on trip.
  int stall = 0;
  always @(posedge clk) begin
    if (rst_n) begin
      if (mvalid || (s_tvalid && s_tready)) stall <= 0;
      else stall <= stall + 1;
      if (stall > 2000) begin
        $display("WATCHDOG @%0t stalled: state=%0d vcnt=%0d consume=%0d msglen=%0d msg_ready=%b accept=%b s_tready=%b s_tvalid=%b n_decoded=%0d win[63:0]=%h",
                 $time, dut.state, dut.vcnt, dut.consume, dut.msglen,
                 dut.msg_ready, dut.accept, s_tready, s_tvalid, n_decoded, dut.win[63:0]);
        $finish;
      end
    end
  end

  initial begin
    string fname;
    int fd, c1, c2, len;

    fname = "test.mold";
    void'($value$plusargs("mold=%s", fname));
    fd = $fopen(fname, "rb");
    if (fd == 0) begin
      $display("FATAL: cannot open %s", fname);
      $finish;
    end

    s_tvalid = 1'b0; s_tlast = 1'b0; s_tkeep = '0; s_tdata = '0;
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    forever begin
      c1 = $fgetc(fd);
      if (c1 == -1) break;
      c2 = $fgetc(fd);
      len = (c1 << 8) | c2;
      if (len == 0 || len > 4000) begin
        $display("FATAL: bad packet length %0d", len);
        break;
      end
      payload = new[len];
      for (int i = 0; i < len; i++) payload[i] = byte'($fgetc(fd));
      send_packet(len);
      // occasional idle gap between packets
      repeat ($urandom_range(0, 2)) @(negedge clk);
    end
    $fclose(fd);

    repeat (40) @(posedge clk);
    $fclose(fd_log);
    $display("TB done: %0d messages decoded, %0d length errors", n_decoded, n_len_err);
    $display("splitter: gap_total=%0d dup=%0d frame_err=%0d eos=%0d",
             gap_total, dup_cnt, frame_err_cnt, eos_seen);
    if (n_len_err != 0 || frame_err_cnt != 0 || !eos_seen)
      $display("FAIL: unexpected error counters");
    $finish;
  end

endmodule
