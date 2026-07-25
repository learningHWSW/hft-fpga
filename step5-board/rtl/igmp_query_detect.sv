// RX-side IGMP membership-query detector.
//
// igmp_join refreshes membership on a periodic timer, which keeps the feed
// flowing on its own. RFC 2236 also asks a host to ANSWER queries: the router
// periodically sends a Membership Query and expects a report back within the
// max-response time. Answering is what makes membership survive a router whose
// query interval is shorter than our refresh period, and it is the correct
// behaviour. This block is the missing half -- it watches the raw RX stream and
// pulses o_query when a query for our group arrives, which drives igmp_join.
//
// It taps the stream BEFORE eth_ip_udp_rx, on purpose: IGMP is IP protocol 2,
// not UDP, so the feed's UDP/group filter would drop a query before anything
// downstream could see it. This monitor never backpressures and never consumes
// the beat -- it only looks.
//
// A query is: ethertype 0x0800, IPv4, protocol 2, IGMP type 0x11, and either a
// General Query (group 0.0.0.0) or a Group-Specific Query for cfg_group_ip.
// The IGMP message sits at byte 14 + IHL*4; IGMP queries carry either no IP
// options (IHL 5) or the Router Alert option (IHL 6), so those two are decoded
// with constant offsets and anything else is ignored.
`timescale 1ns/1ps
module igmp_query_detect #(
  parameter int DATA_W = 512
)(
  input  logic                clk,
  input  logic                rst_n,

  input  logic [31:0]         cfg_group_ip,

  // raw RX stream (tap of what feeds eth_ip_udp_rx), byte 0 in bits[7:0]
  input  logic [DATA_W-1:0]   s_tdata,
  input  logic                s_tvalid,
  input  logic                s_tlast,

  output logic                o_query,        // 1-cycle pulse
  output logic [31:0]         query_cnt
);
  // start-of-frame: the first beat carries the whole header. The feed path
  // never backpressures, so every valid beat is accepted.
  logic sof;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n)          sof <= 1'b1;
    else if (s_tvalid)   sof <= s_tlast;

  wire [3:0] ihl = s_tdata[8*14 +: 4];
  wire       is_eth_ip = (s_tdata[8*12 +: 8] == 8'h08) && (s_tdata[8*13 +: 8] == 8'h00);
  wire       is_ipv4   = (s_tdata[8*14+4 +: 4] == 4'h4);
  wire       is_igmp   = (s_tdata[8*23 +: 8] == 8'd2);      // IP protocol byte

  // IGMP type + group at the offset implied by IHL (5 = no options, 6 = RA)
  logic [7:0]  igmp_type;
  logic [31:0] igmp_group;
  logic        ihl_ok;
  always_comb begin
    ihl_ok = 1'b1;
    unique case (ihl)
      4'd5: begin
        igmp_type  = s_tdata[8*34 +: 8];
        igmp_group = {s_tdata[8*38 +: 8], s_tdata[8*39 +: 8],
                      s_tdata[8*40 +: 8], s_tdata[8*41 +: 8]};
      end
      4'd6: begin
        igmp_type  = s_tdata[8*38 +: 8];
        igmp_group = {s_tdata[8*42 +: 8], s_tdata[8*43 +: 8],
                      s_tdata[8*44 +: 8], s_tdata[8*45 +: 8]};
      end
      default: begin igmp_type = 8'h00; igmp_group = 32'h0; ihl_ok = 1'b0; end
    endcase
  end

  wire is_query = is_eth_ip && is_ipv4 && is_igmp && ihl_ok
                  && (igmp_type == 8'h11)
                  && ((igmp_group == 32'h0) || (igmp_group == cfg_group_ip));

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      o_query   <= 1'b0;
      query_cnt <= 32'd0;
    end else begin
      o_query <= sof && s_tvalid && is_query;
      if (sof && s_tvalid && is_query) query_cnt <= query_cnt + 32'd1;
    end
endmodule
