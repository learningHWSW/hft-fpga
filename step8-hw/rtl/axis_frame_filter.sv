// Pass only the frames whose IPv4 protocol byte matches; drop the rest.
//
// Phase B puts the GT in near-end loopback, so EVERYTHING this design transmits
// comes back in on RX: the replayed feed, the order frames, ARP replies, IGMP
// reports. The datapath itself needs no help with that -- eth_ip_udp_rx already
// filters on MAC, IP and UDP port, so the returning TCP and ARP frames fall out
// there exactly as junk on a real network would. The capture path has no such
// filter, and it is the path the golden diff reads: if the feed came back into
// eth_capture the captured records would be thousands of feed frames with the
// seventy order frames buried in them.
//
// The decision is made once, on the first beat, and held for the frame. That is
// the only correct place for it: tkeep and tlast say nothing about protocol, and
// re-deciding per beat on a frame whose header has long since gone past would
// pass or cut frames in the middle.
//
// No tready in either direction, matching the MAC's RX port and the market-data
// policy the rest of the design follows. Dropping happens by not asserting
// tvalid, which is a frame that never existed downstream rather than a truncated
// one.
`timescale 1ns/1ps
module axis_frame_filter #(
  parameter int DATA_W    = 512,
  parameter byte unsigned PROTO = 8'd6      // 6 = TCP (orders), 17 = UDP (feed)
)(
  input  logic                clk,
  input  logic                rst_n,

  input  logic [DATA_W-1:0]   s_tdata,
  input  logic [DATA_W/8-1:0] s_tkeep,
  input  logic                s_tvalid,
  input  logic                s_tlast,

  output logic [DATA_W-1:0]   m_tdata,
  output logic [DATA_W/8-1:0] m_tkeep,
  output logic                m_tvalid,
  output logic                m_tlast,

  output logic [31:0]         passed,
  output logic [31:0]         dropped
);
  logic in_frame;      // a frame is in progress
  logic keep;          // ...and it matched

  // byte 12/13 ethertype, byte 23 IPv4 protocol -- the same offsets lat_probe
  // and scripts/pack_eth.py use, so all three agree on what an order frame is
  wire sof   = s_tvalid && !in_frame;
  wire match = (s_tdata[8*12 +: 8] == 8'h08) &&
               (s_tdata[8*13 +: 8] == 8'h00) &&
               (s_tdata[8*23 +: 8] == PROTO);

  wire pass_now = s_tvalid && (sof ? match : keep);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      in_frame <= 1'b0; keep <= 1'b0;
      passed   <= '0;   dropped <= '0;
    end else begin
      if (s_tvalid) begin
        if (sof) begin
          keep <= match;
          if (s_tlast) begin
            if (match) passed  <= passed  + 1'b1;
            else       dropped <= dropped + 1'b1;
          end
        end else if (s_tlast) begin
          if (keep) passed  <= passed  + 1'b1;
          else      dropped <= dropped + 1'b1;
        end
        in_frame <= !s_tlast;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      m_tvalid <= 1'b0; m_tlast <= 1'b0; m_tdata <= '0; m_tkeep <= '0;
    end else begin
      m_tvalid <= pass_now;
      m_tdata  <= s_tdata;
      m_tkeep  <= s_tkeep;
      // tlast is gated by the pass decision, not merely by s_tvalid. A consumer
      // that only samples on tvalid would not care, but leaving tlast asserted
      // for a frame that is being dropped is a trap for the next reader of this
      // module, and it costs one AND gate to not set it.
      m_tlast  <= pass_now && s_tlast;
    end
  end

endmodule
