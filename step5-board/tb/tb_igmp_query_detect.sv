// Self-checking TB for igmp_query_detect. Runs under xsim.
//
// Drives crafted first-beat frames and checks o_query fires for exactly the
// queries RFC 2236 says to answer, and for nothing else:
//   General Query (IHL 6, dst 224.0.0.1, group 0)      -> query
//   Group-Specific Query (IHL 5) for cfg_group_ip      -> query
//   Group-Specific Query for a DIFFERENT group         -> no
//   Non-IGMP (UDP, protocol 17)                        -> no
//   IGMP Membership Report (type 0x16, not a query)    -> no
`timescale 1ns/1ps
module tb_igmp_query_detect;
  localparam int DATA_W = 512;
  localparam logic [31:0] GROUP = 32'hE9360C01;   // 233.54.12.1

  logic clk = 0, rst_n = 0;
  always #2 clk = ~clk;

  logic [DATA_W-1:0] s_tdata;
  logic              s_tvalid = 0, s_tlast = 0, o_query;
  logic [31:0]       query_cnt;

  igmp_query_detect #(.DATA_W(DATA_W)) dut (
    .clk(clk), .rst_n(rst_n), .cfg_group_ip(GROUP),
    .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tlast(s_tlast),
    .o_query(o_query), .query_cnt(query_cnt)
  );

  int errs = 0;
  logic saw;

  byte unsigned f [64];

  task automatic clr; for (int i = 0; i < 64; i++) f[i] = 8'h00; endtask

  // common Ethernet + IPv4 shell; caller fills IHL, proto, addrs, IGMP
  task automatic eth_ip(input [7:0] ihl_byte, input [7:0] proto,
                        input [31:0] dst_ip);
    f[0]=8'h01; f[1]=8'h00; f[2]=8'h5e; f[3]=8'h00; f[4]=8'h00; f[5]=8'h01; // dst mac (overwritten by caller if needed)
    f[6]=8'haa; f[7]=8'hbb; f[8]=8'hcc; f[9]=8'hdd; f[10]=8'hee; f[11]=8'hff;
    f[12]=8'h08; f[13]=8'h00;                 // ethertype IPv4
    f[14]=ihl_byte; f[22]=8'h01; f[23]=proto; // ver/ihl, ttl, protocol
    f[30]=dst_ip[31:24]; f[31]=dst_ip[23:16]; f[32]=dst_ip[15:8]; f[33]=dst_ip[7:0];
  endtask

  task automatic drive_check(input string nm, input logic expect_q);
    saw = 1'b0;
    @(negedge clk);
    for (int k = 0; k < 64; k++) s_tdata[8*k +: 8] = f[k];
    s_tvalid = 1'b1; s_tlast = 1'b1;
    @(negedge clk); s_tvalid = 1'b0; s_tlast = 1'b0;
    if (o_query) saw = 1'b1;                       // pulse is present this cycle
    repeat (3) begin @(negedge clk); if (o_query) saw = 1'b1; end
    if (saw !== expect_q) begin
      $display("FAIL %s: o_query=%0b expected %0b", nm, saw, expect_q);
      errs++;
    end
  endtask

  initial begin
    repeat (3) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);

    // General Query: IHL 6 (Router Alert), dst 224.0.0.1, IGMP type 0x11, group 0
    clr; eth_ip(8'h46, 8'd2, 32'hE0000001);
    f[34]=8'h94; f[35]=8'h04;                 // router alert option
    f[38]=8'h11; f[39]=8'h64;                 // igmp query, max resp 10s
    // group (bytes 42..45) left 0 = general
    drive_check("general query", 1'b1);

    // Group-Specific Query: IHL 5, dst = group, IGMP type 0x11, group = ours
    clr; eth_ip(8'h45, 8'd2, GROUP);
    f[34]=8'h11; f[35]=8'h00;                 // igmp query at byte 34 (IHL5)
    f[38]=GROUP[31:24]; f[39]=GROUP[23:16]; f[40]=GROUP[15:8]; f[41]=GROUP[7:0];
    drive_check("group-specific (ours)", 1'b1);

    // Group-Specific Query for a DIFFERENT group -> ignore
    clr; eth_ip(8'h45, 8'd2, 32'hE9360C02);
    f[34]=8'h11; f[35]=8'h00;
    f[38]=8'hE9; f[39]=8'h36; f[40]=8'h0C; f[41]=8'h02;
    drive_check("group-specific (other)", 1'b0);

    // Non-IGMP (UDP) -> ignore
    clr; eth_ip(8'h45, 8'd17, GROUP);
    f[34]=8'h11;                              // looks like a query byte, but proto=UDP
    drive_check("udp not igmp", 1'b0);

    // IGMP Membership Report (type 0x16) -> not a query
    clr; eth_ip(8'h45, 8'd2, GROUP);
    f[34]=8'h16;                              // report, not query
    f[38]=GROUP[31:24]; f[39]=GROUP[23:16]; f[40]=GROUP[15:8]; f[41]=GROUP[7:0];
    drive_check("igmp report", 1'b0);

    if (query_cnt != 2) begin
      $display("FAIL: query_cnt=%0d expected 2", query_cnt);
      errs++;
    end
    if (errs == 0) $display("PASS: igmp_query_detect fired on 2 queries, ignored the rest");
    else           $display("FAIL: %0d error(s)", errs);
    $finish;
  end

  initial begin repeat (100000) @(posedge clk); $display("FAIL: timeout"); $finish; end
endmodule
