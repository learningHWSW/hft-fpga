// Order table, II=1 — a pipelined drop-in for order_table (step 4a).
//
// Same ports, same book-delta semantics, verified against the SAME golden. The
// iterative order_table spends ~5 cycles per message (accept, read latency,
// resolve, write); this accepts a new message EVERY cycle for the common
// operations, so several messages are in flight across the read-latency
// pipeline at once.
//
// Why this is safe without write-forwarding: HAZARD STALL. The only
// correctness risk in a pipelined table is two in-flight messages touching the
// same SET — the second would read the URAM before the first's write lands.
// So a message is issued only when its set collides with NO in-flight op; on a
// collision it waits (s_ready drops) until the conflicting write has retired.
// The set is hash(ref), spread over 2^13 sets, and the pipeline is ~5 deep, so
// a random message collides ~0.06% of the time — II is 1 in the overwhelming
// common case, and the collision stall keeps it exactly correct in the rest.
// This also subsumes the free-way hazard (two inserts to one set can never be
// in flight together, so the second sees the first's occupied way).
//
// U (replace) is the exception. It touches TWO sets and its insert inherits the
// removed order's side, a cross-set data dependency the pipeline would need
// forwarding for. U is 8% of messages, so rather than risk that, a U DRAINS the
// pipeline and runs the exact sequential remove-then-insert the iterative table
// uses — provably identical to the golden — then the pipeline resumes. That
// makes the effective II ~1.7 on real data (measured), still ~3x the iterative
// table, and the common path is a true II=1.
`timescale 1ns/1ps
module order_table_pipe
  import itch5_pkg::*;
#(
  parameter int SETS_BITS = 13,
  parameter int RD_LAT    = 2,
  parameter int WAYS      = 16
)(
  input  logic         clk,
  input  logic         rst_n,

  input  logic [15:0]  track_locate,

  input  itch_msg_t    s_msg,
  input  logic         s_valid,
  output logic         s_ready,

  output logic         o_valid,
  output logic [7:0]   o_type,
  output logic [47:0]  o_ts,
  output logic [15:0]  o_locate,
  output logic [7:0]   o_side,
  output logic         o_has_rem,
  output logic [31:0]  o_rem_price,
  output logic [31:0]  o_rem_qty,
  output logic         o_has_add,
  output logic [31:0]  o_add_price,
  output logic [31:0]  o_add_qty,

  output logic         init_done,
  output logic [31:0]  overflow_cnt,
  output logic [31:0]  miss_cnt
);
  localparam int SETS = 1 << SETS_BITS;
  localparam int WAYW = (WAYS > 1) ? $clog2(WAYS) : 1;
  localparam int PDEPTH = RD_LAT + 2;   // read-latency stages + resolve + write
  // hazard window, in accept-cycles. The read issues when the op is in pipe[0]
  // (one cycle after accept), so an op is in flight PDEPTH+1 cycles from accept;
  // +1 more covers the cycle its write commits. Over-covering only adds a rare
  // extra stall, never incorrectness.
  localparam int HAZ    = PDEPTH + 2;

  typedef struct packed {
    logic        valid;
    logic [63:0] oref;
    logic        is_buy;
    logic [31:0] price;
    logic [31:0] qty;
  } oentry_t;
  localparam int EW = $bits(oentry_t);

  function automatic logic [7:0] side_of(input logic is_buy);
    return is_buy ? "B" : "S";
  endfunction
  function automatic logic [SETS_BITS-1:0] hash(input logic [63:0] r);
    logic [63:0] h;
    h = r ^ (r >> 16) ^ (r >> 32) ^ (r >> 48);
    return h[SETS_BITS-1:0];
  endfunction

  // ---- clear-on-reset sweep (URAM has no init) ----
  logic               clr_busy;
  logic [SETS_BITS:0] clr_addr;
  always_ff @(posedge clk) begin
    if (!rst_n) begin clr_busy <= 1'b1; clr_addr <= '0; end
    else if (clr_busy) begin
      clr_addr <= clr_addr + 1'b1;
      if (clr_addr[SETS_BITS]) clr_busy <= 1'b0;
    end
  end

  // ---- shared memory ports (driven by the pipe or the U sub-FSM) ----
  logic [SETS_BITS-1:0] rd_set;
  logic                 we;
  logic [WAYW-1:0]      w_way;
  logic [SETS_BITS-1:0] w_set;
  oentry_t              w_entry;
  oentry_t rdq [WAYS-1:0];

  wire [SETS_BITS-1:0] mem_waddr = clr_busy ? clr_addr[SETS_BITS-1:0] : w_set;
  wire [EW-1:0]        mem_wdata = clr_busy ? {EW{1'b0}} : EW'(w_entry);

  genvar gw;
  generate
    for (gw = 0; gw < WAYS; gw++) begin : g_way
      wire [EW-1:0] rdata;
      otable_mem #(.WIDTH(EW), .DEPTH(SETS), .AW(SETS_BITS), .RD_LAT(RD_LAT)) u_mem (
        .clk(clk),
        .we(clr_busy || (we && (w_way == gw[WAYW-1:0]))),
        .waddr(mem_waddr), .wdata(mem_wdata),
        .raddr(rd_set),    .rdata(rdata)
      );
      assign rdq[gw] = oentry_t'(rdata);
    end
  endgenerate

  // ---- combinational lookup over the current set (rdq), for a given ref ----
  logic            hit;
  logic [WAYW-1:0] hit_way;
  logic            have_free;
  logic [WAYW-1:0] free_way;
  logic [63:0]     look_ref;            // ref being resolved this cycle
  always_comb begin
    hit = 1'b0; hit_way = '0; have_free = 1'b0; free_way = '0;
    for (int w = WAYS-1; w >= 0; w--) begin
      if (!rdq[w].valid) begin have_free = 1'b1; free_way = w[WAYW-1:0]; end
      if (rdq[w].valid && rdq[w].oref == look_ref) begin hit = 1'b1; hit_way = w[WAYW-1:0]; end
    end
  end

  // ---- pipeline op ----
  typedef struct packed {
    logic         valid;
    logic [7:0]   mtype;
    logic [63:0]  oref;
    logic [SETS_BITS-1:0] set;
    logic         is_buy;               // insert side (A/F: m.side=='B')
    logic [31:0]  price;                // A/F: m.price
    logic [31:0]  qty;                  // A/F: m.shares; E/C/X: m.shares
    logic [47:0]  ts;
    logic [15:0]  locate;               // m.locate
    logic [7:0]   side_raw;             // m.side (A/F output)
  } uop_t;

  // read-latency + resolve stages: op flows one stage per cycle
  uop_t pipe [PDEPTH];                  // pipe[0]=just-issued .. pipe[PDEPTH-1]=at write

  // ---- U sub-FSM (drains the pipe, runs remove-then-insert sequentially) ----
  typedef enum logic [2:0] { P_RUN, U_DRAIN, U_LK0, U_EX0, U_LK1, U_EX1 } mode_t;
  mode_t mode;
  itch_msg_t   um;
  logic [SETS_BITS-1:0] uset0, uset1;
  logic        u_same, u_old_is_buy;
  logic [31:0] u_old_price, u_old_qty;
  logic [WAYW-1:0] u_old_way;
  logic [3:0]  u_wait;

  // is any pipe stage still busy? (for U drain)
  logic pipe_busy;
  always_comb begin
    pipe_busy = 1'b0;
    for (int i = 0; i < PDEPTH; i++) if (pipe[i].valid) pipe_busy = 1'b1;
  end

  // ---- hazard: sets of in-flight ops (issued but not yet write-committed) ----
  logic [SETS_BITS-1:0] haz_set [HAZ];
  logic                 haz_val [HAZ];
  wire [SETS_BITS-1:0]  in_set = hash(s_msg.order_ref);
  logic                 collide;
  always_comb begin
    collide = 1'b0;
    for (int i = 0; i < HAZ; i++)
      if (haz_val[i] && haz_set[i] == in_set) collide = 1'b1;
  end

  wire msg_is_u = (s_msg.msg_type == "U");
  // accept a normal (non-U) op into the pipe this cycle?
  wire pipe_take = (mode == P_RUN) && s_valid && !clr_busy && !msg_is_u && !collide;
  // a U at the head switches to drain mode (accepted only when the pipe empties)
  wire u_start   = (mode == P_RUN) && s_valid && !clr_busy && msg_is_u;
  // the U is CONSUMED (popped) the cycle the drained pipe latches it into `um`
  wire u_consume = (mode == U_DRAIN) && s_valid && !pipe_busy && !wop.valid;

  // s_ready pops a normal op when the pipe takes it, and pops the U exactly
  // once, when U_DRAIN latches it -- otherwise the U sits at the FIFO head and
  // would be re-processed forever, since s_ready is low all through U mode.
  assign s_ready = pipe_take || u_consume;

  // read address. CRITICAL alignment: the read must be issued the cycle the op
  // is in pipe[0], NOT the cycle it is accepted. Driving rd_set from the
  // combinational in_set (the op being accepted) issues the read one cycle
  // before the op enters pipe[0], so at pipe[RD_LAT] the op's rdata is a read
  // from one cycle later -- a wrong address. The bug hid because a following
  // op often re-drove the same set, so only an op with no successor (the last
  // in a burst) read stale and missed. Driving from the REGISTERED pipe[0].set
  // puts the read in lockstep with the op's position.
  always_comb begin
    rd_set = pipe[0].set;               // the op now in pipe[0]
    if (mode == U_LK0) rd_set = uset0;
    else if (mode == U_LK1) rd_set = uset1;
  end

  // resolve stage sees pipe[RD_LAT] (data has been read); its ref feeds lookup
  wire [63:0] rs_ref = pipe[RD_LAT].oref;
  always_comb look_ref = (mode == U_LK0) ? um.order_ref
                       : (mode == U_LK1) ? um.new_order_ref
                       : rs_ref;

  // resolve registers (RS -> WR)
  logic            sel_hit, sel_free_ok;
  logic [WAYW-1:0] sel_way, sel_free_way;
  oentry_t         sel_ent;
  uop_t            wop;                  // op at the write stage

  // ---- write port + output, from the write stage (wop) or the U-FSM ----
  always_comb begin
    we = 1'b0; w_way = '0; w_set = wop.set; w_entry = '0;
    if (mode == U_EX0) begin
      // remove old (if found), like the iterative EXEC 'U' branch
      if (u_hit0) begin we = 1'b1; w_way = u_way0; w_set = uset0; w_entry = '0; end
    end else if (mode == U_EX1) begin
      if (u_free_ok1) begin
        we = 1'b1; w_way = u_free_way1; w_set = uset1;
        w_entry = '{valid:1'b1, oref:um.new_order_ref,
                    is_buy:u_old_is_buy, price:um.price, qty:um.shares};
      end
    end else if (wop.valid) begin
      unique case (wop.mtype)
        "A", "F":
          if ((wop.locate == track_locate) && sel_free_ok) begin
            we = 1'b1; w_way = sel_free_way; w_set = wop.set;
            w_entry = '{valid:1'b1, oref:wop.oref, is_buy:wop.is_buy,
                        price:wop.price, qty:wop.qty};
          end
        "D":
          if (sel_hit) begin we = 1'b1; w_way = sel_way; w_set = wop.set; w_entry = '0; end
        "E", "C", "X":
          if (sel_hit) begin
            we = 1'b1; w_way = sel_way; w_set = wop.set;
            if (sel_ent.qty <= wop.qty) w_entry = '0;
            else begin w_entry = sel_ent; w_entry.qty = sel_ent.qty - wop.qty; end
          end
        default: ;
      endcase
    end
  end

  // U sub-FSM lookup captures (combinational lookup reused via look_ref/mode)
  logic            u_hit0;
  logic [WAYW-1:0] u_way0;
  logic            u_free_ok1;
  logic [WAYW-1:0] u_free_way1;

  // free-way for the U insert, honoring the same-set removal of the old slot
  logic            have_free_u;
  logic [WAYW-1:0] free_way_u;
  always_comb begin
    have_free_u = 1'b0; free_way_u = '0;
    for (int w = WAYS-1; w >= 0; w--)
      if (!rdq[w].valid || (u_same && w[WAYW-1:0] == u_old_way)) begin
        have_free_u = 1'b1; free_way_u = w[WAYW-1:0];
      end
  end

  // ---- main sequential ----
  integer k;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mode <= P_RUN;
      o_valid <= 1'b0; overflow_cnt <= '0; miss_cnt <= '0;
      for (k = 0; k < PDEPTH; k++) pipe[k].valid <= 1'b0;
      for (k = 0; k < HAZ; k++) haz_val[k] <= 1'b0;
      u_wait <= '0; u_hit0 <= 1'b0; wop.valid <= 1'b0;
    end else begin
      o_valid <= 1'b0;

      // ---- advance the pipeline (non-U ops) ----
      // shift; stage 0 gets the newly accepted op (or a bubble)
      for (k = PDEPTH-1; k > 0; k--) pipe[k] <= pipe[k-1];
      if (pipe_take)
        pipe[0] <= '{valid:1'b1, mtype:s_msg.msg_type, oref:s_msg.order_ref,
                     set:in_set, is_buy:(s_msg.side == "B"),
                     price:s_msg.price, qty:s_msg.shares, ts:s_msg.timestamp,
                     locate:s_msg.locate, side_raw:s_msg.side};
      else
        pipe[0].valid <= 1'b0;

      // hazard shift register
      for (k = HAZ-1; k > 0; k--) begin haz_set[k] <= haz_set[k-1]; haz_val[k] <= haz_val[k-1]; end
      haz_val[0] <= pipe_take;
      haz_set[0] <= in_set;

      // ---- RESOLVE (op at pipe[RD_LAT]) -> register selection for the write ----
      sel_hit      <= hit;
      sel_way      <= hit_way;
      sel_ent      <= rdq[hit_way];
      sel_free_ok  <= have_free;
      sel_free_way <= free_way;
      wop          <= pipe[RD_LAT];

      // ---- WRITE + emit (from wop / sel_*), for a normal op ----
      if (wop.valid) begin
        o_type <= wop.mtype; o_ts <= wop.ts;
        o_locate <= wop.locate; o_side <= wop.side_raw;
        o_has_rem <= 1'b0; o_rem_price <= '0; o_rem_qty <= '0;
        o_has_add <= 1'b0; o_add_price <= '0; o_add_qty <= '0;
        unique case (wop.mtype)
          "A", "F":
            if (wop.locate == track_locate) begin
              if (sel_free_ok) begin
                o_valid <= 1'b1; o_has_add <= 1'b1;
                o_add_price <= wop.price; o_add_qty <= wop.qty;
              end else overflow_cnt <= overflow_cnt + 1;
            end
          "D":
            if (sel_hit) begin
              o_valid <= 1'b1; o_side <= side_of(sel_ent.is_buy); o_locate <= track_locate;
              o_has_rem <= 1'b1; o_rem_price <= sel_ent.price; o_rem_qty <= sel_ent.qty;
            end else miss_cnt <= miss_cnt + 1;
          "E", "C", "X": begin
            if (sel_hit) begin
              automatic logic [31:0] d = (sel_ent.qty < wop.qty) ? sel_ent.qty : wop.qty;
              o_valid <= 1'b1; o_side <= side_of(sel_ent.is_buy); o_locate <= track_locate;
              o_has_rem <= 1'b1; o_rem_price <= sel_ent.price; o_rem_qty <= d;
            end else miss_cnt <= miss_cnt + 1;
          end
          default: ;
        endcase
      end

      // ---- U sub-FSM ----
      unique case (mode)
        P_RUN: if (u_start) mode <= U_DRAIN;
        U_DRAIN: if (u_consume) begin
          um     <= s_msg;
          uset0  <= hash(s_msg.order_ref);
          u_wait <= RD_LAT[3:0];
          mode   <= U_LK0;
        end
        U_LK0: if (u_wait != 0) u_wait <= u_wait - 4'd1;
               else begin
          u_hit0 <= hit; u_way0 <= hit_way;
          u_old_is_buy <= rdq[hit_way].is_buy;
          u_old_price  <= rdq[hit_way].price;
          u_old_qty    <= rdq[hit_way].qty;
          mode <= U_EX0;
        end
        U_EX0: begin
          if (u_hit0) begin
            uset1  <= hash(um.new_order_ref);
            u_same <= (hash(um.new_order_ref) == uset0);
            u_old_way <= u_way0;
            u_wait <= RD_LAT[3:0];
            mode   <= U_LK1;
          end else begin
            miss_cnt <= miss_cnt + 1;
            mode <= P_RUN;              // no output, like the iterative !hit case
          end
        end
        U_LK1: if (u_wait != 0) u_wait <= u_wait - 4'd1;
               else begin
          u_free_ok1  <= have_free_u;
          u_free_way1 <= free_way_u;
          mode <= U_EX1;
        end
        U_EX1: begin
          if (!u_free_ok1) overflow_cnt <= overflow_cnt + 1;
          o_valid <= 1'b1; o_type <= "U";
          o_locate <= track_locate; o_side <= side_of(u_old_is_buy);
          o_ts <= um.timestamp;
          o_has_rem <= 1'b1; o_rem_price <= u_old_price; o_rem_qty <= u_old_qty;
          o_has_add <= 1'b1; o_add_price <= um.price; o_add_qty <= um.shares;
          mode <= P_RUN;
        end
        default: mode <= P_RUN;
      endcase
    end
  end

  assign init_done = !clr_busy;

endmodule
