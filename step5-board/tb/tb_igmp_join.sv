// Self-checking TB for igmp_join. Runs under xsim and Verilator --binary.
//
// Proves the membership report is correct to the byte and that each trigger
// produces the right number of them. gen_igmp.py writes the golden frame as
// one hex byte per line (igmp_gold.mem, an independent construction); this TB
// $readmemh's it and compares every emitted 60-byte frame against it.
//
// Scenario (periodic off for A/B so the counts are exact):
//   A. one i_join pulse           -> REPORTS_ON_JOIN (2) frames
//   B. one i_query pulse          -> 1 frame
//   C. enable periodic, interval 10 -> frames keep coming, all byte-correct
`timescale 1ns/1ps
module tb_igmp_join;
  localparam int DATA_W  = 512;
  localparam int FRAME_B = 60;
  localparam int ROBUST  = 2;

  logic clk = 0, rst_n = 0;
  always #2 clk = ~clk;

  logic [31:0] cfg_group_ip = 32'hE9360C01;   // 233.54.12.1
  logic [31:0] cfg_src_ip   = 32'h0A000002;   // 10.0.0.2
  logic [47:0] cfg_src_mac  = 48'h001122334455;
  logic        cfg_igmp_en  = 0;
  logic [31:0] cfg_interval = 0;
  logic        i_join = 0, i_query = 0;

  logic [DATA_W-1:0]   m_tdata;
  logic [DATA_W/8-1:0] m_tkeep;
  logic                m_tvalid, m_tlast, m_tready = 1;
  logic [31:0]         report_cnt;

  igmp_join #(.DATA_W(DATA_W), .REPORTS_ON_JOIN(ROBUST)) dut (
    .clk(clk), .rst_n(rst_n),
    .cfg_group_ip(cfg_group_ip), .cfg_src_mac(cfg_src_mac), .cfg_src_ip(cfg_src_ip),
    .cfg_igmp_en(cfg_igmp_en), .cfg_interval(cfg_interval),
    .i_join(i_join), .i_query(i_query),
    .m_tdata(m_tdata), .m_tkeep(m_tkeep), .m_tvalid(m_tvalid), .m_tlast(m_tlast),
    .m_tready(m_tready), .report_cnt(report_cnt)
  );

  logic [7:0] gold [FRAME_B];
  int frames = 0, byte_errs = 0, keep_errs = 0;

  // capture and byte-check every accepted frame
  always @(posedge clk) if (rst_n && m_tvalid && m_tready) begin
    frames++;
    if (!m_tlast) begin
      $display("FAIL: frame %0d not tlast (multi-beat?)", frames);
      byte_errs++;
    end
    // exactly 60 keep bits set
    if (m_tkeep !== ({64{1'b1}} >> (64 - FRAME_B))) keep_errs++;
    for (int k = 0; k < FRAME_B; k++)
      if (m_tdata[8*k +: 8] !== gold[k]) begin
        byte_errs++;
        if (byte_errs <= 8)
          $display("FAIL: frame %0d byte %0d got %02h exp %02h",
                   frames, k, m_tdata[8*k +: 8], gold[k]);
      end
  end

  task automatic pulse(ref logic sig);
    @(negedge clk); sig = 1; @(negedge clk); sig = 0;
  endtask

  int n;
  initial begin
    $readmemh("igmp_gold.mem", gold);
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (2) @(negedge clk);

    // A. join -> ROBUST reports
    pulse(i_join);
    repeat (8) @(negedge clk);
    if (frames != ROBUST) begin
      $display("FAIL: join produced %0d frames, expected %0d", frames, ROBUST);
      byte_errs++;
    end

    // B. query -> 1 more report
    n = frames;
    pulse(i_query);
    repeat (8) @(negedge clk);
    if (frames != n + 1) begin
      $display("FAIL: query produced %0d frames, expected 1", frames - n);
      byte_errs++;
    end

    // C. periodic refresh
    n = frames;
    cfg_interval = 32'd10;
    cfg_igmp_en  = 1'b1;
    repeat (60) @(negedge clk);
    cfg_igmp_en  = 1'b0;
    if (frames - n < 3) begin
      $display("FAIL: periodic produced only %0d frames", frames - n);
      byte_errs++;
    end

    if (byte_errs == 0 && keep_errs == 0)
      $display("PASS: igmp_join %0d reports, all byte-identical to golden (keep ok)",
               frames);
    else
      $display("FAIL: %0d byte error(s), %0d keep error(s) over %0d frames",
               byte_errs, keep_errs, frames);
    $finish;
  end

  initial begin
    repeat (100000) @(posedge clk);
    $display("FAIL: timeout");
    $finish;
  end
endmodule
