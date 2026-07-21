// Elastic FIFO with drop-on-full accounting — the standard coupling between
// two market-data stages where the producer cannot be backpressured.
//
// Push side has no ready: a beat presented while full is DROPPED and counted.
// That is the deliberate market-data policy (never stall the wire; absorb what
// you can, count what you lose) — the counter is what tells you the depth was
// wrong. Pop side is a normal valid/ready handshake.
//
// The storage is read SYNCHRONOUSLY into a one-deep output register. An
// asynchronous `mem[rptr]` read is what forces distributed RAM: measured, the
// delta FIFO alone cost 22 k LUTs and put a RAMD64E on the critical path
// (step5-board/README.md). With a registered read the array maps to block RAM
// and the head is presented from a flop instead of a LUT mux. The output
// register keeps first-word-fall-through behaviour, so consumers are unchanged
// apart from one extra cycle of fill latency.
//
// Depth must be a power of two; total capacity is DEPTH + 1 (memory + head).
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
  output logic [$clog2(DEPTH):0] level,      // occupancy incl. the head register
  output logic [$clog2(DEPTH):0] level_max   // high-water mark (sizing evidence)
);
  localparam int AW = $clog2(DEPTH);

  logic [WIDTH-1:0] mem [DEPTH];
  logic [AW:0]      wptr, rptr;              // rptr = next address to fetch

  logic [WIDTH-1:0] head;                    // output register
  logic             head_valid;

  wire [AW:0] mem_count = wptr - rptr;
  wire        mem_avail = (mem_count != '0);
  wire        full      = (mem_count == DEPTH[AW:0]);

  wire do_push = push_valid && !full;
  // refill the head whenever it is empty or is being consumed this cycle
  wire fetch   = mem_avail && (!head_valid || pop_ready);

  assign pop_valid = head_valid;
  assign pop_data  = head;
  assign level     = mem_count + (head_valid ? 1'b1 : 1'b0);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wptr <= '0; rptr <= '0; drop_cnt <= '0; level_max <= '0;
      head_valid <= 1'b0;
    end else begin
      if (do_push) begin
        mem[wptr[AW-1:0]] <= push_data;
        wptr <= wptr + 1'b1;
      end else if (push_valid) begin
        drop_cnt <= drop_cnt + 1;            // full: lost a message
      end

      // synchronous read of the storage into the head register.
      // fetch is gated by mem_avail, so the address being read is never the
      // address written this cycle (that word is only fetchable next cycle).
      if (fetch) begin
        head       <= mem[rptr[AW-1:0]];
        head_valid <= 1'b1;
        rptr       <= rptr + 1'b1;
      end else if (head_valid && pop_ready) begin
        head_valid <= 1'b0;
      end

      if (level > level_max) level_max <= level;
    end
  end

endmodule
