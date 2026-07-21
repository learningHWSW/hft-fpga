// Elastic FIFO with drop-on-full accounting — the standard coupling between
// two market-data stages where the producer cannot be backpressured.
//
// Push side has no ready: a beat presented while full is DROPPED and counted.
// That is the deliberate market-data policy (never stall the wire; absorb what
// you can, count what you lose) — the counter is what tells you the depth was
// wrong. Pop side is a normal valid/ready handshake.
//
// Depth must be a power of two.
`timescale 1ns/1ps
module drop_fifo #(
  parameter int WIDTH = 32,
  parameter int DEPTH = 512
)(
  input  logic             clk,
  input  logic             rst_n,

  input  logic             push_valid,
  input  logic [WIDTH-1:0] push_data,

  output logic             pop_valid,
  output logic [WIDTH-1:0] pop_data,
  input  logic             pop_ready,

  output logic [31:0]      drop_cnt,
  output logic [$clog2(DEPTH):0] level,      // current occupancy
  output logic [$clog2(DEPTH):0] level_max   // high-water mark (sizing evidence)
);
  localparam int AW = $clog2(DEPTH);

  logic [WIDTH-1:0] mem [DEPTH];
  logic [AW:0]      wptr, rptr;

  assign level     = wptr - rptr;
  assign pop_valid = (wptr != rptr);
  assign pop_data  = mem[rptr[AW-1:0]];

  wire full = (level == DEPTH[AW:0]);
  wire do_push = push_valid && !full;
  wire do_pop  = pop_valid && pop_ready;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wptr <= '0; rptr <= '0; drop_cnt <= '0; level_max <= '0;
    end else begin
      if (do_push) begin
        mem[wptr[AW-1:0]] <= push_data;
        wptr <= wptr + 1'b1;
      end else if (push_valid) begin
        drop_cnt <= drop_cnt + 1;          // full: lost a message
      end
      if (do_pop) rptr <= rptr + 1'b1;
      if (level > level_max) level_max <= level;
    end
  end

endmodule
