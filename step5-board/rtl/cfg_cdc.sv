// Clock-domain crossing for the AXI-Lite register file <-> core.
//
// The register file (axil_regfile) runs on the QDMA/AXI-Lite clock; t2t_top
// consumes its config on the core clock. Two kinds of signal cross:
//
//   * config data (group IP, strategy params, connection state): QUASI-STATIC.
//     Software writes every word, then pulses a commit; nothing changes again
//     until the next reconfiguration. So this does NOT need a per-bit
//     synchroniser -- it needs the textbook "data with a synchronised enable"
//     crossing (cfg_cdc): snapshot the bus in the source domain on commit, and
//     in the destination domain sample that snapshot only when the commit pulse
//     arrives, by which time the bus has been stable for several cycles.
//
//   * commit / order-ack: single-cycle PULSES. These cross with a toggle
//     synchroniser (pulse_sync). Correct only if pulses are spaced further
//     apart than the synchroniser latency -- true here (config commit and order
//     acks are software events milliseconds apart, never back-to-back).
`timescale 1ns/1ps

// ---- single-pulse crossing (src -> dst), toggle + 2FF + edge detect ----
module pulse_sync #(
  parameter int SYNC_FF = 2
)(
  input  logic src_clk,
  input  logic src_rst_n,
  input  logic src_pulse,
  input  logic dst_clk,
  input  logic dst_rst_n,
  output logic dst_pulse
);
  logic tog;
  always_ff @(posedge src_clk or negedge src_rst_n)
    if (!src_rst_n)      tog <= 1'b0;
    else if (src_pulse)  tog <= ~tog;

  // one extra stage past the SYNC_FF resync so the edge detector compares two
  // fully-synchronised samples
  (* ASYNC_REG = "TRUE" *) logic [SYNC_FF:0] sync;
  always_ff @(posedge dst_clk or negedge dst_rst_n)
    if (!dst_rst_n) sync <= '0;
    else            sync <= {sync[SYNC_FF-1:0], tog};

  assign dst_pulse = sync[SYNC_FF] ^ sync[SYNC_FF-1];
endmodule


// ---- quasi-static config bus crossing: snapshot + synchronised enable ----
module cfg_cdc #(
  parameter int W       = 32,
  parameter int SYNC_FF = 2
)(
  input  logic         src_clk,
  input  logic         src_rst_n,
  input  logic [W-1:0] src_data,     // stable around src_load (quasi-static)
  input  logic         src_load,     // 1-cycle commit pulse
  input  logic         dst_clk,
  input  logic         dst_rst_n,
  output logic [W-1:0] dst_data,     // updated only on a committed crossing
  output logic         dst_load      // 1-cycle pulse in dst domain
);
  // hold the committed value in the source domain
  logic [W-1:0] snap;
  always_ff @(posedge src_clk or negedge src_rst_n)
    if (!src_rst_n)     snap <= '0;
    else if (src_load)  snap <= src_data;

  // cross the commit pulse; snap is guaranteed stable by the time it fires
  logic load_x;
  pulse_sync #(.SYNC_FF(SYNC_FF)) u_ps (
    .src_clk(src_clk), .src_rst_n(src_rst_n), .src_pulse(src_load),
    .dst_clk(dst_clk), .dst_rst_n(dst_rst_n), .dst_pulse(load_x)
  );

  always_ff @(posedge dst_clk or negedge dst_rst_n)
    if (!dst_rst_n) begin
      dst_data <= '0;
      dst_load <= 1'b0;
    end else begin
      dst_load <= load_x;
      if (load_x) dst_data <= snap;   // MCP: sample the settled snapshot
    end
endmodule
