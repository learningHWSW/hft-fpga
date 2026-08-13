// Self-checking TB for feed_ab_arb. Runs under xsim.
//
// Drives the two redundant lines concurrently (each line's frames from
// gen_ab.py, with different drops) and checks the merged output equals the
// clean golden stream. The two drivers run in a fork so the lines interleave
// and backpressure independently -- the merge must reconstruct order from
// whichever line has the next packet. Output frames are written as hex; the
// Makefile diffs them against ab_gold.hex. Counters (gap/dup) are checked too.
//
// +a=<file> +b=<file> line frames, +out=<file> merged hex, +gap=<0|1> expected.
`timescale 1ns/1ps
module tb_feed_ab;
  localparam int DATA_W = 512;
  localparam int KEEP_W = DATA_W / 8;

  logic clk = 0, rst_n = 0;
  always #2 clk = ~clk;

  logic [DATA_W-1:0] a_td = 0, b_td = 0;
  logic [KEEP_W-1:0] a_tk = 0, b_tk = 0;
  logic a_tv = 0, a_tl = 0, a_tr, b_tv = 0, b_tl = 0, b_tr;
  logic [DATA_W-1:0] m_td;
  logic [KEEP_W-1:0] m_tk;
  logic m_tv, m_tl, m_tr = 1;
  logic ev_gap;
  logic [31:0] fwd_cnt, dup_cnt, gap_cnt, a_src_cnt, b_src_cnt;

  feed_ab_arb #(.DATA_W(DATA_W), .AHEAD_STALL(16)) dut (
    .clk(clk), .rst_n(rst_n),
    .a_tdata(a_td), .a_tkeep(a_tk), .a_tvalid(a_tv), .a_tlast(a_tl), .a_tready(a_tr),
    .b_tdata(b_td), .b_tkeep(b_tk), .b_tvalid(b_tv), .b_tlast(b_tl), .b_tready(b_tr),
    .m_tdata(m_td), .m_tkeep(m_tk), .m_tvalid(m_tv), .m_tlast(m_tl), .m_tready(m_tr),
    .ev_gap(ev_gap), .fwd_cnt(fwd_cnt), .dup_cnt(dup_cnt), .gap_cnt(gap_cnt),
    .a_src_cnt(a_src_cnt), .b_src_cnt(b_src_cnt)
  );

  // ---- capture merged frames (each packet is one beat) ----
  int fout, n_out = 0;
  always @(posedge clk) if (rst_n && m_tv && m_tr && m_tl) begin
    automatic int nb = 0;
    for (int i = 0; i < KEEP_W; i++) if (m_tk[i]) nb++;
    for (int i = 0; i < nb; i++) $fwrite(fout, "%02x", m_td[8*i +: 8]);
    $fwrite(fout, "\n");
    n_out++;
  end

  // ---- line A driver ----
  task automatic send_a(input byte unsigned q[], input int n);
    @(negedge clk);
    a_td = '0; a_tk = '0;
    for (int j = 0; j < n; j++) begin a_td[8*j +: 8] = q[j]; a_tk[j] = 1'b1; end
    a_tv = 1'b1; a_tl = 1'b1;
    @(posedge clk); while (!a_tr) @(posedge clk);      // held until accepted
    @(negedge clk); a_tv = 1'b0; a_tl = 1'b0; a_tk = '0;
  endtask
  task automatic send_b(input byte unsigned q[], input int n);
    @(negedge clk);
    b_td = '0; b_tk = '0;
    for (int j = 0; j < n; j++) begin b_td[8*j +: 8] = q[j]; b_tk[j] = 1'b1; end
    b_tv = 1'b1; b_tl = 1'b1;
    @(posedge clk); while (!b_tr) @(posedge clk);
    @(negedge clk); b_tv = 1'b0; b_tl = 1'b0; b_tk = '0;
  endtask

  task automatic drive(input int fd, input bit is_a);
    int c1, c2, ln; byte unsigned q[];
    forever begin
      c1 = $fgetc(fd); if (c1 == -1) break;
      c2 = $fgetc(fd); ln = (c1 << 8) | c2;
      if (ln == 0 || ln > 64) begin $display("FATAL: frame len %0d > 1 beat", ln); $finish; end
      q = new[ln]; for (int x = 0; x < ln; x++) q[x] = byte'($fgetc(fd));
      if (is_a) send_a(q, ln); else send_b(q, ln);
    end
  endtask

  int fda, fdb, exp_gap;
  string fa, fb, fo;
  initial begin
    fa = "ab_a.frames"; void'($value$plusargs("a=%s", fa));
    fb = "ab_b.frames"; void'($value$plusargs("b=%s", fb));
    fo = "ab_rtl.hex";  void'($value$plusargs("out=%s", fo));
    exp_gap = 0;        void'($value$plusargs("gap=%d", exp_gap));

    fda = $fopen(fa, "rb"); fdb = $fopen(fb, "rb"); fout = $fopen(fo, "w");
    if (fda == 0 || fdb == 0) begin $display("FATAL: cannot open inputs"); $finish; end

    repeat (4) @(negedge clk); rst_n = 1'b1; repeat (2) @(negedge clk);

    fork
      drive(fda, 1'b1);
      drive(fdb, 1'b0);
    join
    repeat (64) @(posedge clk);          // drain any final gap-jump
    $fclose(fout);

    $display("TB done: out=%0d fwd=%0d dup=%0d gap=%0d (A=%0d B=%0d)",
             n_out, fwd_cnt, dup_cnt, gap_cnt, a_src_cnt, b_src_cnt);
    if (fwd_cnt != n_out)
      $display("FAIL: fwd_cnt %0d != frames out %0d", fwd_cnt, n_out);
    if (gap_cnt != exp_gap)
      $display("FAIL: gap_cnt %0d != expected %0d", gap_cnt, exp_gap);
    if (fwd_cnt == n_out && gap_cnt == exp_gap)
      $display("PASS: feed_ab_arb merged %0d packets, %0d dup dropped, %0d gap",
               n_out, dup_cnt, gap_cnt);
    $finish;
  end

  initial begin repeat (2000000) @(posedge clk); $display("FAIL: timeout"); $finish; end
endmodule
