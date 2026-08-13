// Self-checking TB for itch_decoder.
//
// Reads a framed ITCH file (+itch=<path>, default test.itch), drives each
// message as one AXI-Stream packet with random inter-message gaps, and logs
// every decoded message to decode_rtl.log in a canonical text format. The
// Makefile diffs that log against scripts/dump_itch.py output (golden).
//
// Runs under xsim (xvlog/xelab/xsim).
`timescale 1ns/1ps

module tb_itch_decoder;
  import itch5_pkg::*;

  localparam int DATA_W = 64;
  localparam int KEEP_W = DATA_W / 8;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #1.552 clk = ~clk;  // ~322 MHz, U55C 100G-path ballpark

  logic [DATA_W-1:0] tdata;
  logic [KEEP_W-1:0] tkeep;
  logic tvalid, tlast, tready;
  itch_msg_t msg;
  logic mvalid, len_err;

  itch_decoder #(.DATA_W(DATA_W)) dut (
    .clk      (clk),
    .rst_n    (rst_n),
    .s_tdata  (tdata),
    .s_tkeep  (tkeep),
    .s_tvalid (tvalid),
    .s_tlast  (tlast),
    .s_tready (tready),
    .m_msg    (msg),
    .m_valid  (mvalid),
    .m_len_err(len_err)
  );

  // ---------- monitor: canonical decode log ----------
  int fd_log;
  int n_decoded = 0;
  int n_len_err = 0;

  initial fd_log = $fopen("decode_rtl.log", "w");

  always @(posedge clk) begin
    if (mvalid) begin
      n_decoded++;
      if (len_err) begin
        n_len_err++;
        $display("** LENGTH ERROR on message %0d type=%c", n_decoded, msg.msg_type);
      end
      log_msg();
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

  // ---------- driver ----------
  byte unsigned payload[];

  task automatic send_msg(input int n);
    int i, k;
    i = 0;
    while (i < n) begin
      k = (n - i > KEEP_W) ? KEEP_W : (n - i);
      @(negedge clk);
      tdata = '0;
      tkeep = '0;
      for (int j = 0; j < k; j++) begin
        tdata[8*j +: 8] = payload[i+j];
        tkeep[j] = 1'b1;
      end
      tvalid = 1'b1;
      tlast  = (i + k == n);
      i += k;
    end
    @(negedge clk);
    tvalid = 1'b0;
    tlast  = 1'b0;
    tkeep  = '0;
  endtask

  initial begin
    string fname;
    int fd, c1, c2, len;

    fname = "test.itch";
    void'($value$plusargs("itch=%s", fname));
    fd = $fopen(fname, "rb");
    if (fd == 0) begin
      $display("FATAL: cannot open %s", fname);
      $finish;
    end

    tvalid = 1'b0; tlast = 1'b0; tkeep = '0; tdata = '0;
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    forever begin
      c1 = $fgetc(fd);
      if (c1 == -1) break;
      c2 = $fgetc(fd);
      len = (c1 << 8) | c2;
      if (len == 0 || len > 64) begin
        $display("FATAL: bad frame length %0d", len);
        break;
      end
      payload = new[len];
      for (int i = 0; i < len; i++) payload[i] = byte'($fgetc(fd));
      send_msg(len);
      // mix back-to-back messages with idle gaps
      repeat ($urandom_range(0, 2)) @(negedge clk);
    end
    $fclose(fd);

    repeat (10) @(posedge clk);
    $fclose(fd_log);
    $display("TB done: %0d messages decoded, %0d length errors", n_decoded, n_len_err);
    $finish;
  end

endmodule
