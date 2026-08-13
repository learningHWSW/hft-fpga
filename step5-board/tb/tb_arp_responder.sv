// Self-checking TB for arp_responder. Runs under xsim.
//
// Drives ARP frames on the RX tap and checks the reply is byte-exact and only
// fires for the right thing:
//   who-has OUR ip, from a requester      -> reply (diffed against gen_arp.py)
//   who-has a DIFFERENT ip                -> no reply
//   an ARP REPLY (oper 2), not a request  -> no reply
//   a non-ARP frame (ethertype 0x0800)    -> no reply
`timescale 1ns/1ps
module tb_arp_responder;
  localparam int DATA_W = 512;
  localparam int FRAME_B = 60;
  localparam logic [47:0] OUR_MAC = 48'h001122334455;
  localparam logic [31:0] OUR_IP  = 32'h0A000002;   // 10.0.0.2
  localparam logic [47:0] REQ_MAC = 48'hAABBCCDDEEFF;
  localparam logic [31:0] REQ_IP  = 32'h0A000009;   // 10.0.0.9

  logic clk = 0, rst_n = 0;
  always #2 clk = ~clk;

  logic [DATA_W-1:0]   s_tdata;
  logic                s_tvalid = 0, s_tlast = 0;
  logic [DATA_W-1:0]   m_tdata;
  logic [DATA_W/8-1:0] m_tkeep;
  logic                m_tvalid, m_tlast, m_tready = 1;
  logic [31:0]         reply_cnt;

  arp_responder #(.DATA_W(DATA_W)) dut (
    .clk(clk), .rst_n(rst_n), .cfg_src_mac(OUR_MAC), .cfg_src_ip(OUR_IP),
    .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tlast(s_tlast),
    .m_tdata(m_tdata), .m_tkeep(m_tkeep), .m_tvalid(m_tvalid), .m_tlast(m_tlast),
    .m_tready(m_tready), .reply_cnt(reply_cnt)
  );

  logic [7:0] gold [FRAME_B];
  logic [DATA_W-1:0] cap;
  logic got;
  int errs = 0;

  byte unsigned f [64];
  task automatic clr; for (int i = 0; i < 64; i++) f[i] = 8'h00; endtask

  // build an ARP frame; oper=1 request / 2 reply, tpa=target ip
  task automatic arp_frame(input [15:0] oper, input [31:0] tpa);
    clr;
    f[0]=8'hff; f[1]=8'hff; f[2]=8'hff; f[3]=8'hff; f[4]=8'hff; f[5]=8'hff;   // bcast
    f[6]=REQ_MAC[47:40]; f[7]=REQ_MAC[39:32]; f[8]=REQ_MAC[31:24];
    f[9]=REQ_MAC[23:16]; f[10]=REQ_MAC[15:8]; f[11]=REQ_MAC[7:0];
    f[12]=8'h08; f[13]=8'h06;                                                // ethertype ARP
    f[14]=8'h00; f[15]=8'h01; f[16]=8'h08; f[17]=8'h00; f[18]=8'h06; f[19]=8'h04;
    f[20]=oper[15:8]; f[21]=oper[7:0];
    f[22]=REQ_MAC[47:40]; f[23]=REQ_MAC[39:32]; f[24]=REQ_MAC[31:24];        // sha = requester
    f[25]=REQ_MAC[23:16]; f[26]=REQ_MAC[15:8]; f[27]=REQ_MAC[7:0];
    f[28]=REQ_IP[31:24]; f[29]=REQ_IP[23:16]; f[30]=REQ_IP[15:8]; f[31]=REQ_IP[7:0]; // spa
    f[38]=tpa[31:24]; f[39]=tpa[23:16]; f[40]=tpa[15:8]; f[41]=tpa[7:0];     // tpa = target
  endtask

  task automatic drive_check(input string nm, input logic expect_r);
    got = 1'b0;
    @(negedge clk);
    for (int k = 0; k < 64; k++) s_tdata[8*k +: 8] = f[k];
    s_tvalid = 1'b1; s_tlast = 1'b1;
    @(negedge clk); s_tvalid = 1'b0; s_tlast = 1'b0;
    // sample the single-beat reply from this task only (no second driver on got)
    repeat (6) begin @(negedge clk); if (m_tvalid && m_tready) begin got = 1'b1; cap = m_tdata; end end
    if (got !== expect_r) begin
      $display("FAIL %s: reply=%0b expected %0b", nm, got, expect_r);
      errs++;
    end else if (expect_r) begin
      for (int k = 0; k < FRAME_B; k++)
        if (cap[8*k +: 8] !== gold[k]) begin
          errs++;
          if (errs <= 8) $display("FAIL %s: byte %0d got %02h exp %02h",
                                  nm, k, cap[8*k +: 8], gold[k]);
        end
    end
  endtask

  initial begin
    $readmemh("arp_gold.mem", gold);
    repeat (3) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);

    arp_frame(16'd1, OUR_IP);        drive_check("who-has us", 1'b1);
    arp_frame(16'd1, 32'h0A000063);  drive_check("who-has other (10.0.0.99)", 1'b0);
    arp_frame(16'd2, OUR_IP);        drive_check("arp reply not request", 1'b0);
    // non-ARP: overwrite ethertype to IPv4
    arp_frame(16'd1, OUR_IP); f[12]=8'h08; f[13]=8'h00;
    drive_check("non-arp (ipv4)", 1'b0);

    if (reply_cnt != 1) begin $display("FAIL: reply_cnt=%0d expected 1", reply_cnt); errs++; end
    if (errs == 0) $display("PASS: arp_responder answered who-has-us byte-exact, ignored the rest");
    else           $display("FAIL: %0d error(s)", errs);
    $finish;
  end

  initial begin repeat (100000) @(posedge clk); $display("FAIL: timeout"); $finish; end
endmodule
