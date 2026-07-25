// Self-checking TB for axis_tx_arb: two sources, one wire, no interleaving.
//
// Drives s0 (2-beat "order" frames) and s1 (1-beat "report" frames) offered at
// the same time and checks the merged stream is frame-atomic: between a beat
// with tlast=0 and the next beat, the source never changes. Also checks both
// sources drain and s0 (priority) is not starved. Runs under Verilator/xsim.
`timescale 1ns/1ps
module tb_axis_tx_arb;
  localparam int DATA_W = 512;

  logic clk = 0, rst_n = 0;
  always #2 clk = ~clk;

  logic [DATA_W-1:0]   s0_d, s1_d, m_d;
  logic [DATA_W/8-1:0] s0_k, s1_k, m_k;
  logic s0_v, s0_l, s0_r, s1_v, s1_l, s1_r, m_v, m_l, m_r;

  axis_tx_arb #(.DATA_W(DATA_W)) dut (
    .clk(clk), .rst_n(rst_n),
    .s0_tdata(s0_d), .s0_tkeep(s0_k), .s0_tvalid(s0_v), .s0_tlast(s0_l), .s0_tready(s0_r),
    .s1_tdata(s1_d), .s1_tkeep(s1_k), .s1_tvalid(s1_v), .s1_tlast(s1_l), .s1_tready(s1_r),
    .m_tdata(m_d), .m_tkeep(m_k), .m_tvalid(m_v), .m_tlast(m_l), .m_tready(m_r)
  );

  // ---- checker: track which frame is mid-flight, flag interleaving ----
  int errs = 0, s0_frames = 0, s1_frames = 0, m_frames = 0;
  logic in_frame = 0;
  logic [7:0] frame_tag = 0;   // low byte of first beat identifies the source

  always @(posedge clk) if (rst_n && m_v && m_r) begin
    if (!in_frame) begin
      frame_tag = m_d[7:0];        // 0xA0.. = s0, 0xB0.. = s1
      in_frame  = 1;
    end else begin
      if (m_d[7:0] != frame_tag) begin
        $display("FAIL: interleaved beat tag %02h != %02h", m_d[7:0], frame_tag);
        errs++;
      end
    end
    if (m_l) begin
      in_frame = 0;
      m_frames++;
    end
  end

  // ---- s0 driver: 2-beat frames, tag 0xA0 ----
  task automatic send_s0(input [7:0] id);
    for (int b = 0; b < 2; b++) begin
      s0_d = {DATA_W{1'b0}}; s0_d[7:0] = 8'hA0 | id; s0_d[15:8] = b[7:0];
      s0_k = '1; s0_v = 1; s0_l = (b == 1);
      @(posedge clk); while (!s0_r) @(posedge clk);
    end
    s0_v = 0; s0_l = 0; s0_frames++;
  endtask

  // ---- s1 driver: 1-beat frames, tag 0xB0 ----
  task automatic send_s1(input [7:0] id);
    s1_d = {DATA_W{1'b0}}; s1_d[7:0] = 8'hB0 | id;
    s1_k = '1; s1_v = 1; s1_l = 1;
    @(posedge clk); while (!s1_r) @(posedge clk);
    s1_v = 0; s1_l = 0; s1_frames++;
  endtask

  initial begin
    s0_v = 0; s1_v = 0; s0_l = 0; s1_l = 0; m_r = 1;
    repeat (3) @(posedge clk); rst_n = 1;

    // both offered together, repeatedly: the arbiter must serialise them
    fork
      begin for (int i = 0; i < 6; i++) send_s0(i[7:0]); end
      begin for (int i = 0; i < 6; i++) send_s1(i[7:0]); end
    join

    repeat (10) @(posedge clk);
    if (s0_frames != 6 || s1_frames != 6 || m_frames != 12) begin
      $display("FAIL: frames s0=%0d s1=%0d out=%0d (want 6/6/12)",
               s0_frames, s1_frames, m_frames);
      errs++;
    end
    if (errs == 0) $display("PASS: axis_tx_arb serialised %0d frames, no interleave", m_frames);
    else           $display("FAIL: %0d error(s)", errs);
    $finish;
  end

  initial begin repeat (100000) @(posedge clk); $display("FAIL: timeout"); $finish; end
endmodule
