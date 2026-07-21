// Order table — step 4a. Reverse-lookup order_ref -> {locate, side, price,
// qty}, the core of an ITCH L2/L3 book. d-way set-associative on raw low bits
// of order_ref (measured best hash, data/FINDINGS.md §4). Symbol-filtered so
// it fits URAM: only A/F whose locate == track_locate enter; every other
// message that resolves to a stored order is by construction tracked.
//
// Emits one book-delta record per processed message, describing the price
// level(s) it moves: `rem` (level decremented: D/E/C/X, and U's old level),
// `add` (level incremented: A/F, and U's new level). U is the only message
// that touches two levels; everything else touches one. This is exactly the
// stream step 4b's price ladder consumes.
//
// Correctness-first FSM (not yet II=1): IDLE accepts, then 1 cycle per set
// access (2 cy/msg, 3 for U). The 2-cycle spacing plus same-cycle NBA
// writeback makes cross-message same-set accesses hazard-free without
// forwarding. At 64-bit input a message spans several beats, so the decoder
// never presents faster than this keeps up. II=1 pipelining is the follow-up.
`timescale 1ns/1ps
module order_table
  import itch5_pkg::*;
#(
  parameter int SETS_BITS = 16,
  parameter int WAYS      = 8   // 16b x8 + mix hash = 0 overflow for AAPL (full
                                // day, data/FINDINGS.md §4.2)
)(
  input  logic         clk,
  input  logic         rst_n,

  input  logic [15:0]  track_locate,   // software-set; only this symbol enters

  input  itch_msg_t    s_msg,
  input  logic         s_valid,
  output logic         s_ready,

  output logic         o_valid,
  output logic [7:0]   o_type,
  output logic [47:0]  o_ts,           // pass-through of the message timestamp
  output logic [15:0]  o_locate,
  output logic [7:0]   o_side,
  output logic         o_has_rem,
  output logic [31:0]  o_rem_price,
  output logic [31:0]  o_rem_qty,
  output logic         o_has_add,
  output logic [31:0]  o_add_price,
  output logic [31:0]  o_add_qty,

  output logic [31:0]  overflow_cnt,   // insert into a full set (order dropped)
  output logic [31:0]  miss_cnt        // op on an unknown/untracked ref
);
  localparam int SETS   = 1 << SETS_BITS;
  localparam int WAYW   = (WAYS > 1) ? $clog2(WAYS) : 1;

  typedef struct packed {
    logic        valid;
    logic [63:0] oref;
    logic [15:0] locate;
    logic [7:0]  side;
    logic [31:0] price;
    logic [31:0] qty;
  } oentry_t;

  // One memory per way (built in the generate below), NOT one array indexed by
  // a variable way. Writing `bank[way][set]` with a variable `way` blocks RAM
  // inference outright: Vivado flattens the table into flip-flops (measured:
  // 565 k FFs, 0 BRAM, 0 URAM — see step5-board/README.md). A decoded write
  // enable per way makes each way a plain single-write/single-read memory,
  // which is the pattern that maps to BRAM/URAM.
  localparam int EW = $bits(oentry_t); // entry width, for the flat storage
  oentry_t rdq [WAYS-1:0];             // registered read of the current set

  // Unified write port, driven combinationally so the write lands in the same
  // cycle the FSM decides it — that same-cycle write is what keeps
  // cross-message same-set accesses hazard-free without forwarding.
  logic                 we;
  logic [WAYW-1:0]      w_way;
  logic [SETS_BITS-1:0] w_set;
  oentry_t              w_entry;

  typedef enum logic [1:0] { IDLE, EXEC, U_EXEC } state_t;
  state_t state;

  itch_msg_t            m;             // latched message
  logic [SETS_BITS-1:0] set0, set1;
  logic                 u_same;
  logic [15:0]          old_loc;
  logic [7:0]           old_side;
  logic [31:0]          old_price, old_qty;
  logic [WAYW-1:0]      old_way;

  // XOR-fold mix. Raw low bits round-robin only across ALL symbols; a single
  // filtered symbol's refs are a correlated subset that clusters in the low
  // bits, so some mixing is required (raw at 2^16 x 8 still overflows).
  //
  // This started as a 64x64 multiply-shift, which mixed well but synthesised
  // into a multi-DSP cascade that became the critical path once the memories
  // were fixed — 4.6 ns between the input FIFO's BRAM and the table's read
  // address (step5-board/README.md). Folding instead of multiplying was then
  // measured over the full day rather than assumed: at the deployed 2^16 x 8
  // point the fold gives the SAME zero overflow as the multiply and a lower
  // worst-case set occupancy (6 vs 7), for a couple of LUT levels and no DSP
  // (data/FINDINGS.md §4.3). No pipelining needed as a result.
  function automatic logic [SETS_BITS-1:0] hash(input logic [63:0] r);
    logic [63:0] h;
    h = r ^ (r >> 16) ^ (r >> 32) ^ (r >> 48);
    return h[SETS_BITS-1:0];
  endfunction

  // ---- combinational read address (must reflect this cycle's request) ----
  logic [SETS_BITS-1:0] rd_set;
  always_comb begin
    rd_set = set0;
    if (state == IDLE && s_valid)                   rd_set = hash(s_msg.order_ref);
    else if (state == EXEC && m.msg_type == "U")    rd_set = hash(m.new_order_ref);
  end

  // ---- combinational lookup over the current set (rdq) ----
  logic            hit;
  logic [WAYW-1:0] hit_way;
  logic            have_free;
  logic [WAYW-1:0] free_way;
  logic            have_free_u;        // U: honor same-set removal of old slot
  logic [WAYW-1:0] free_way_u;
  always_comb begin
    hit = 1'b0; hit_way = '0;
    have_free = 1'b0; free_way = '0;
    have_free_u = 1'b0; free_way_u = '0;
    for (int w = WAYS-1; w >= 0; w--) begin
      if (!rdq[w].valid) begin have_free = 1'b1; free_way = w[WAYW-1:0]; end
      if (rdq[w].valid && rdq[w].oref == m.order_ref) begin hit = 1'b1; hit_way = w[WAYW-1:0]; end
      if (!rdq[w].valid || (u_same && w[WAYW-1:0] == old_way)) begin
        have_free_u = 1'b1; free_way_u = w[WAYW-1:0];
      end
    end
  end

  // ---- write port: what this cycle stores, if anything ----
  // Every case writes a whole entry (an invalidation writes all-zero) so each
  // way stays a simple one-write-port memory.
  always_comb begin
    we      = 1'b0;
    w_way   = '0;
    w_set   = set0;
    w_entry = '0;
    unique case (state)
      EXEC: begin
        unique case (m.msg_type)
          "A", "F":
            if ((m.locate == track_locate) && have_free) begin
              we = 1'b1; w_way = free_way; w_set = set0;
              w_entry = '{valid:1'b1, oref:m.order_ref, locate:m.locate,
                          side:m.side, price:m.price, qty:m.shares};
            end
          "D":
            if (hit) begin                       // remove the order
              we = 1'b1; w_way = hit_way; w_set = set0; w_entry = '0;
            end
          "E", "C", "X":
            if (hit) begin
              we = 1'b1; w_way = hit_way; w_set = set0;
              if (rdq[hit_way].qty <= m.shares) w_entry = '0;   // fully consumed
              else begin
                w_entry     = rdq[hit_way];
                w_entry.qty = rdq[hit_way].qty - m.shares;
              end
            end
          "U":
            if (hit) begin                       // remove old; new is written in U_EXEC
              we = 1'b1; w_way = hit_way; w_set = set0; w_entry = '0;
            end
          default: ;
        endcase
      end
      U_EXEC:
        if (have_free_u) begin
          we = 1'b1; w_way = free_way_u; w_set = set1;
          w_entry = '{valid:1'b1, oref:m.new_order_ref, locate:old_loc,
                      side:old_side, price:m.price, qty:m.shares};
        end
      default: ;
    endcase
  end

  // ---- the ways: one memory each, registered read, decoded write ----
  genvar gw;
  generate
    for (gw = 0; gw < WAYS; gw++) begin : g_way
      // Storage is a FLAT bit vector, not an array of oentry_t. Vivado's RAM
      // inference refuses a struct-typed memory — it reports
      //   [Synth 8-11357] ... RAM from Record/Structs ... with 626688 registers
      // and falls back to flip-flops. oentry_t is packed, so casting at the
      // boundary costs nothing.
      // No ram_style attribute: let the tool pick (BRAM at these sizes, URAM
      // when the production table lands). A `string` parameter cannot be used
      // as an attribute value — Vivado rejects it as "not a packed type".
      logic [EW-1:0] mem [SETS-1:0];
      initial for (int s = 0; s < SETS; s++) mem[s] = '0;   // valid bits clear
      always_ff @(posedge clk) begin
        rdq[gw] <= oentry_t'(mem[rd_set]);                  // read-before-write
        if (we && (w_way == gw[WAYW-1:0])) mem[w_set] <= w_entry;
      end
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state        <= IDLE;
      o_valid      <= 1'b0;
      overflow_cnt <= '0;
      miss_cnt     <= '0;
    end else begin
      o_valid <= 1'b0;

      unique case (state)
        IDLE: begin
          if (s_valid) begin
            m    <= s_msg;
            set0 <= hash(s_msg.order_ref);
            state <= EXEC;
          end
        end

        EXEC: begin
          o_type   <= m.msg_type;
          o_ts     <= m.timestamp;
          o_locate <= m.locate;
          o_side   <= m.side;
          o_has_rem <= 1'b0; o_rem_price <= '0; o_rem_qty <= '0;
          o_has_add <= 1'b0; o_add_price <= '0; o_add_qty <= '0;
          unique case (m.msg_type)
            "A", "F": begin
              if (m.locate == track_locate) begin
                if (have_free) begin
                  o_valid   <= 1'b1;
                  o_has_add <= 1'b1; o_add_price <= m.price; o_add_qty <= m.shares;
                end else overflow_cnt <= overflow_cnt + 1;
              end
              state <= IDLE;
            end
            "D": begin
              if (hit) begin
                o_valid   <= 1'b1; o_side <= rdq[hit_way].side; o_locate <= rdq[hit_way].locate;
                o_has_rem <= 1'b1; o_rem_price <= rdq[hit_way].price; o_rem_qty <= rdq[hit_way].qty;
              end else miss_cnt <= miss_cnt + 1;
              state <= IDLE;
            end
            "E", "C", "X": begin
              if (hit) begin
                automatic logic [31:0] delta =
                    (rdq[hit_way].qty < m.shares) ? rdq[hit_way].qty : m.shares;
                o_valid   <= 1'b1; o_side <= rdq[hit_way].side; o_locate <= rdq[hit_way].locate;
                o_has_rem <= 1'b1; o_rem_price <= rdq[hit_way].price; o_rem_qty <= delta;
              end else miss_cnt <= miss_cnt + 1;
              state <= IDLE;
            end
            "U": begin
              if (hit) begin
                old_loc   <= rdq[hit_way].locate;
                old_side  <= rdq[hit_way].side;
                old_price <= rdq[hit_way].price;
                old_qty   <= rdq[hit_way].qty;
                old_way   <= hit_way;
                set1   <= hash(m.new_order_ref);
                u_same <= (hash(m.new_order_ref) == set0);
                state  <= U_EXEC;
              end else begin
                miss_cnt <= miss_cnt + 1;
                state <= IDLE;
              end
            end
            default: state <= IDLE;   // non-book message: no output
          endcase
        end

        U_EXEC: begin
          if (!have_free_u) overflow_cnt <= overflow_cnt + 1;
          o_valid   <= 1'b1; o_type <= "U"; o_locate <= old_loc; o_side <= old_side;
          o_has_rem <= 1'b1; o_rem_price <= old_price; o_rem_qty <= old_qty;
          o_has_add <= 1'b1; o_add_price <= m.price;  o_add_qty <= m.shares;
          state <= IDLE;
        end

        default: state <= IDLE;
      endcase
    end
  end

  assign s_ready = (state == IDLE);

endmodule
