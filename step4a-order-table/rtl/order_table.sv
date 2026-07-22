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
  // URAM read latency. A 2^16-deep memory is 16 URAM primitives cascaded, and
  // the cascade chain is what sets this: latency 1 asks the data to traverse
  // all 16 in one cycle. Xilinx recommends >= 3 for a cascade this long, so
  // that is the default; the FSM waits RD_LAT-1 extra cycles rather than
  // assuming a number.
  parameter int RD_LAT    = 3,
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

  // Low until the post-reset clear sweep finishes. The feed must not be
  // enabled before this rises: s_ready is low throughout, and anything that
  // ignores s_ready (the no-backpressure market-data path does exactly that)
  // silently loses its first SETS messages.
  output logic         init_done,

  output logic [31:0]  overflow_cnt,   // insert into a full set (order dropped)
  output logic [31:0]  miss_cnt        // op on an unknown/untracked ref
);
  localparam int SETS   = 1 << SETS_BITS;
  localparam int WAYW   = (WAYS > 1) ? $clog2(WAYS) : 1;

  // 130 bits, and the two fields that are NOT here are the point.
  //
  // `locate` was stored per entry, 16 bits x 524,288 entries = 8.4 Mbit of a
  // constant: inserts are filtered by (m.locate == track_locate), so every
  // stored entry carries the same value. It is reproduced on output from
  // track_locate instead.
  //
  // `side` was the raw ITCH ASCII byte; only 'B' and 'S' ever occur, so one
  // bit stores it and the byte is reconstructed on output. (This assumes the
  // decoder never emits another value, which is true of valid ITCH.)
  //
  // Together that is 153 -> 130 bits, which is what makes an entry fit TWO
  // URAM columns (144 b) instead of three (216 b) -- a third of the memory,
  // for fields that carried no information.
  typedef struct packed {
    logic        valid;
    logic [63:0] oref;
    logic        is_buy;
    logic [31:0] price;
    logic [31:0] qty;
  } oentry_t;

  function automatic logic [7:0] side_of(input logic is_buy);
    return is_buy ? "B" : "S";
  endfunction

  // One memory per way (built in the generate below), NOT one array indexed by
  // a variable way. Writing `bank[way][set]` with a variable `way` blocks RAM
  // inference outright: Vivado flattens the table into flip-flops (measured:
  // 565 k FFs, 0 BRAM, 0 URAM — see step5-board/README.md). A decoded write
  // enable per way makes each way a plain single-write/single-read memory,
  // which is the pattern that maps to BRAM/URAM.
  localparam int EW = $bits(oentry_t); // entry width, for the flat storage
  oentry_t rdq [WAYS-1:0];             // XPM read port output, RD_LAT cycles on

  // Unified write port, driven combinationally so the write lands in the same
  // cycle the FSM decides it — that same-cycle write is what keeps
  // cross-message same-set accesses hazard-free without forwarding.
  logic                 we;
  logic [WAYW-1:0]      w_way;
  logic [SETS_BITS-1:0] w_set;
  oentry_t              w_entry;

  typedef enum logic [2:0] { IDLE, LOOK, EXEC, U_LOOK, U_EXEC } state_t;
  state_t state;

  itch_msg_t            m;             // latched message
  logic [SETS_BITS-1:0] set0, set1;
  logic                 u_same;
  logic                 old_is_buy;
  logic [3:0]           rd_wait;         // memory read-latency countdown
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

  // ---- combinational read address ----
  // The address must be HELD for the whole of the memory's read latency, not
  // just the cycle the read is issued. With a one-cycle memory this was invisible
  // -- EXEC drove set1 for the single cycle U_LOOK needed -- but once RD_LAT
  // grew, U_LOOK fell back to the `set0` default while the read was still in
  // flight and the pipeline delivered the wrong set. The golden caught it.
  logic [SETS_BITS-1:0] rd_set;
  always_comb begin
    rd_set = set0;
    if (state == IDLE && s_valid)                   rd_set = hash(s_msg.order_ref);
    else if (state == EXEC && m.msg_type == "U")    rd_set = hash(m.new_order_ref);
    else if (state == U_LOOK)                       rd_set = set1;
  end

  // Selection registers. The read-modify-write used to be one cycle:
  // BRAM out -> 8-way ref compare -> priority encode -> entry mux -> qty
  // arithmetic -> BRAM write data, which was the critical path once the ladder
  // was fixed. LOOK now ends at the entry mux and registers the result; EXEC
  // does the arithmetic and the write from registers.
  oentry_t         sel_ent;
  logic            sel_hit, sel_free_ok, selu_free_ok;
  logic [WAYW-1:0] sel_way, sel_free_way, selu_free_way;

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
            if ((m.locate == track_locate) && sel_free_ok) begin
              we = 1'b1; w_way = sel_free_way; w_set = set0;
              w_entry = '{valid:1'b1, oref:m.order_ref,
                          is_buy:(m.side == "B"), price:m.price, qty:m.shares};
            end
          "D":
            if (sel_hit) begin                   // remove the order
              we = 1'b1; w_way = sel_way; w_set = set0; w_entry = '0;
            end
          "E", "C", "X":
            if (sel_hit) begin
              we = 1'b1; w_way = sel_way; w_set = set0;
              if (sel_ent.qty <= m.shares) w_entry = '0;        // fully consumed
              else begin
                w_entry     = sel_ent;
                w_entry.qty = sel_ent.qty - m.shares;
              end
            end
          "U":
            if (sel_hit) begin                   // remove old; new is written in U_EXEC
              we = 1'b1; w_way = sel_way; w_set = set0; w_entry = '0;
            end
          default: ;
        endcase
      end
      U_EXEC:
        if (selu_free_ok) begin
          we = 1'b1; w_way = selu_free_way; w_set = set1;
          w_entry = '{valid:1'b1, oref:m.new_order_ref,
                      is_buy:old_is_buy, price:m.price, qty:m.shares};
        end
      default: ;
    endcase
  end

  // ---- clear-on-reset ----
  // UltraRAM CANNOT BE INITIALIZED. There is no INIT for a URAM primitive, so
  // the `initial mem[s] = '0` that made every entry start invalid works in
  // simulation and in BRAM, and is a lie on the real device: URAM contents come
  // up indeterminate, every `valid` bit is whatever the silicon felt like, and
  // the first lookup hits garbage that looks like live orders.
  //
  // Simulation will NOT catch this — XPM models URAM as starting at zero — so
  // the sweep below is written because the datasheet says it is needed, not
  // because a test failed. After reset it walks every set writing an all-zero
  // entry to all ways, holding s_ready low until done: SETS cycles, 65,536 at
  // 2^16, about 0.3 ms at 216 MHz. That is startup time, once, before the feed
  // is enabled.
  logic                 clr_busy;
  logic [SETS_BITS:0]   clr_addr;          // one extra bit to detect the end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      clr_busy <= 1'b1;
      clr_addr <= '0;
    end else if (clr_busy) begin
      clr_addr <= clr_addr + 1'b1;
      if (clr_addr[SETS_BITS]) clr_busy <= 1'b0;
    end
  end

  // ---- the ways: one memory each, registered read, decoded write ----
  // XPM rather than inference. An inferred array cannot reach this size —
  // Vivado caps a single variable at 1 Mbit ([Synth 8-4556]) and the table is
  // 8 x 65,536 x 130 b = 68 Mbit — so the memory is instantiated, which is the
  // right way to build a table this large in any case.
  wire [SETS_BITS-1:0] mem_waddr = clr_busy ? clr_addr[SETS_BITS-1:0] : w_set;
  wire [EW-1:0]        mem_wdata = clr_busy ? {EW{1'b0}} : EW'(w_entry);

  genvar gw;
  generate
    for (gw = 0; gw < WAYS; gw++) begin : g_way
      // Every way is written during the clear sweep; afterwards only the way
      // the decoded enable selects. A variable way index into one array is what
      // blocked RAM inference in the first place ([Synth 8-11357], 626 k
      // registers); a decoded enable keeps each memory single-write/single-read.
      wire [EW-1:0] rdata;
      otable_mem #(
        .WIDTH(EW), .DEPTH(SETS), .AW(SETS_BITS), .RD_LAT(RD_LAT)
      ) u_mem (
        .clk(clk),
        .we(clr_busy || (we && (w_way == gw[WAYW-1:0]))),
        .waddr(mem_waddr), .wdata(mem_wdata),
        .raddr(rd_set),    .rdata(rdata)
      );
      assign rdq[gw] = oentry_t'(rdata);
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state        <= IDLE;
      o_valid      <= 1'b0;
      overflow_cnt <= '0;
      miss_cnt     <= '0;
      rd_wait      <= '0;
    end else begin
      o_valid <= 1'b0;

      unique case (state)
        IDLE: begin
          if (s_valid) begin
            m    <= s_msg;
            set0 <= hash(s_msg.order_ref);
            rd_wait <= RD_LAT[3:0] - 4'd1;
            state <= LOOK;
          end
        end

        // Wait out the memory's read latency, then resolve which way and
        // register the selected entry. Nothing downstream of the mux happens
        // in the cycle the mux resolves.
        LOOK: if (rd_wait != 0) rd_wait <= rd_wait - 4'd1;
              else begin
          sel_hit      <= hit;
          sel_way      <= hit_way;
          sel_ent      <= rdq[hit_way];
          sel_free_ok  <= have_free;
          sel_free_way <= free_way;
          state        <= EXEC;
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
                if (sel_free_ok) begin
                  o_valid   <= 1'b1;
                  o_has_add <= 1'b1; o_add_price <= m.price; o_add_qty <= m.shares;
                end else overflow_cnt <= overflow_cnt + 1;
              end
              state <= IDLE;
            end
            "D": begin
              if (sel_hit) begin
                o_valid   <= 1'b1;
                o_side    <= side_of(sel_ent.is_buy); o_locate <= track_locate;
                o_has_rem <= 1'b1; o_rem_price <= sel_ent.price; o_rem_qty <= sel_ent.qty;
              end else miss_cnt <= miss_cnt + 1;
              state <= IDLE;
            end
            "E", "C", "X": begin
              if (sel_hit) begin
                automatic logic [31:0] delta =
                    (sel_ent.qty < m.shares) ? sel_ent.qty : m.shares;
                o_valid   <= 1'b1;
                o_side    <= side_of(sel_ent.is_buy); o_locate <= track_locate;
                o_has_rem <= 1'b1; o_rem_price <= sel_ent.price; o_rem_qty <= delta;
              end else miss_cnt <= miss_cnt + 1;
              state <= IDLE;
            end
            "U": begin
              if (sel_hit) begin
                old_is_buy <= sel_ent.is_buy;
                old_price <= sel_ent.price;
                old_qty   <= sel_ent.qty;
                old_way   <= sel_way;
                set1    <= hash(m.new_order_ref);
                u_same  <= (hash(m.new_order_ref) == set0);
                rd_wait <= RD_LAT[3:0] - 4'd1;
                state   <= U_LOOK;
              end else begin
                miss_cnt <= miss_cnt + 1;
                state <= IDLE;
              end
            end
            default: state <= IDLE;   // non-book message: no output
          endcase
        end

        // new set's rdq is valid: pick the slot, register it
        U_LOOK: if (rd_wait != 0) rd_wait <= rd_wait - 4'd1;
                else begin
          selu_free_ok  <= have_free_u;
          selu_free_way <= free_way_u;
          state         <= U_EXEC;
        end

        U_EXEC: begin
          if (!selu_free_ok) overflow_cnt <= overflow_cnt + 1;
          o_valid   <= 1'b1; o_type <= "U";
          o_locate  <= track_locate; o_side <= side_of(old_is_buy);
          o_has_rem <= 1'b1; o_rem_price <= old_price; o_rem_qty <= old_qty;
          o_has_add <= 1'b1; o_add_price <= m.price;  o_add_qty <= m.shares;
          state <= IDLE;
        end

        default: state <= IDLE;
      endcase
    end
  end

  assign s_ready   = (state == IDLE) && !clr_busy;
  assign init_done = !clr_busy;

endmodule
