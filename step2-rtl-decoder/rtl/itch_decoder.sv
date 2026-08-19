// ITCH 5.0 message decoder.
//
// Input : AXI-Stream, one ITCH message per packet (framing — MoldUDP64 or
//         the file dump's length prefix — is stripped upstream). Byte 0 of
//         the message rides tdata[7:0] of the first beat; tkeep is
//         contiguous from bit 0 on the last beat.
// Output: decoded itch_msg_t + 1-cycle valid pulse.
//
// No backpressure: s_tready is constant 1. A market-data front end must
// never stall the wire — if a downstream consumer is slow, the fix is a
// FIFO behind this module, not backpressure into the MAC.
//
// TWO ARRIVAL PATHS, ONE DECODE. The store-then-decode path collects bytes
// into a register vector and decodes it the cycle after tlast: two cycles from
// the last beat to m_valid. It is the only path that can work when a message
// spans beats, which is the 64-bit datapath of steps 2 and 3a.
//
// CUT_THROUGH adds a second arrival path for the case where a message lands
// COMPLETE in one beat — which at DATA_W=512 is every message, because
// MAX_MSG_BYTES is 50 and mold_splitter emits one message per beat with tlast
// set on all of them. That beat is decoded combinationally and registered once,
// so m_valid rises one cycle earlier. One cycle, 4.65 ns at 215 MHz.
//
// The two paths share `decode_msg` rather than each having their own copy. That
// is not tidiness: FINDINGS §4.5 records what it cost when otable_mem had two
// implementations behind an `ifdef` and only one flow ever compiled each. A
// decoder with two field-extraction bodies is the same bug waiting to be
// written, and here the goldens could not tell them apart either — each path
// fires on different traffic. So there is one `decode_msg`, taking the message
// as a packed byte vector, and the paths differ only in where that vector comes
// from: a register file, or the incoming beat's wires.
//
// THE DEFAULT IS THE WIDTH'S ANSWER, not a constant. Cut-through can only fire
// where a message lands complete in one beat, so the default is
//
//     CUT_THROUGH = (DATA_W >= 8*MAX_MSG_BYTES)
//
// — on at the 512-bit datapath that ships, off at the 64 bits steps 2, 3a, 4a,
// 4b and 6 drive their goldens through, where it could never fire anyway. A
// flat default of 1 was tried first and is wrong in the loudest possible way:
// every one of those testbenches instantiates this module without naming the
// parameter, so all five stopped elaborating at once, on the guard below. That
// is the guard working. It is also the reason the default has to be a function
// of the width rather than a preference.
//
// An EXPLICIT CUT_THROUGH=1 at a width that cannot carry it is still an
// elaboration error, and that distinction is the point: defaulting off at 64
// bits is the width answering, while asking for it at 64 bits is a mistake, and
// quietly getting the slow path when you asked for the fast one is the failure
// mode this project keeps writing guards against.
//
// THE TWO PATHS ARE GENERATED, NOT MULTIPLEXED. Under CUT_THROUGH there is no
// collector, no wr_ptr, no second decode: the unreachable path is ABSENT rather
// than merely unreached, which is the only form of "unreachable" a synthesiser
// can act on. The cost is that this branch no longer tolerates a multi-beat
// message, which is checked in simulation below rather than assumed.
//
// An earlier version of this comment claimed that restructuring was worth
// 62 MHz, and that the first attempt was slow because synthesis could not prove
// the runtime fallback dead and kept two decoders. **That was wrong**, and it is
// left recorded rather than deleted because the way it was wrong is the useful
// part. The real cause was one line in the collector -- see the packed-vs-
// unpacked note in g_store_then_decode below -- which was present in BOTH
// configurations. Deleting the collector "fixed" the fast path by removing the
// code containing the bug, that looked like confirmation, and the broken
// baseline went unnoticed until a post-route build of the configuration nobody
// was testing came back at 191.6 MHz with 230 failing endpoints.
//
// A fix that works by deleting the code containing the bug is not evidence for
// the theory that motivated it.
//
// MEASURED, and it costs nothing (FINDINGS §7.1.1b). Four implementation
// directives per setting, out of context, one toolchain:
//
//   CUT_THROUGH=0   4/4 close, best 222.2 MHz, spread 2.2
//   CUT_THROUGH=1   4/4 close, best 223.6 MHz, spread 4.8
//
// Best-to-best the cut-through build is 1.4 MHz FASTER, inside the spread
// within a single configuration -- no measurable difference -- and it is 1,161
// LUTs and 361 flops smaller, because deleting the collector removes more than
// the combinational decode adds. §7.1.1 predicted this would cost core clock,
// on the reasoning that every timing fix in this project has gone the other way.
// It does not.
`timescale 1ns/1ps
module itch_decoder
  import itch5_pkg::*;
#(
  parameter int DATA_W      = 64,
  // on wherever a whole message fits in one beat; see the header
  parameter bit CUT_THROUGH = (DATA_W >= 8*MAX_MSG_BYTES)
)(
  input  logic                clk,
  input  logic                rst_n,

  input  logic [DATA_W-1:0]   s_tdata,
  input  logic [DATA_W/8-1:0] s_tkeep,
  input  logic                s_tvalid,
  input  logic                s_tlast,
  output logic                s_tready,

  output itch_msg_t           m_msg,
  output logic                m_valid,
  output logic                m_len_err  // received length != spec length
);
  localparam int KEEP_W = DATA_W / 8;
  localparam int BUFB   = 64;  // > MAX_MSG_BYTES, power of two
  localparam int VEC_W  = BUFB * 8;

  // A message as a flat byte vector: byte i occupies [8*i +: 8]. Packed rather
  // than an unpacked array so the same type can be a register file on one path
  // and a slice of the input beat on the other.
  typedef logic [VEC_W-1:0] msgvec_t;

  // Elaboration-time, and worded without format arguments because xsim does not
  // substitute them in an elaboration $error -- a guard whose message is half
  // printed is a guard someone has to go and read the source for.
  if (CUT_THROUGH && (DATA_W < 8*MAX_MSG_BYTES))
    $error("itch_decoder: CUT_THROUGH needs DATA_W >= 8*MAX_MSG_BYTES (400 bits). Below that a message spans beats, the cut-through path can never fire, and the build would quietly be the store-then-decode one you did not ask for.");

  assign s_tready = 1'b1;

  function automatic int count_keep(input logic [KEEP_W-1:0] k);
    int c = 0;
    for (int i = 0; i < KEEP_W; i++) c += int'(k[i]);
    return c;
  endfunction

  // ---- big-endian field extractors (pure byte-lane selects) ----
  function automatic logic [15:0] f_be16(input msgvec_t v, input int off);
    return {v[8*off +: 8], v[8*(off+1) +: 8]};
  endfunction

  function automatic logic [31:0] f_be32(input msgvec_t v, input int off);
    return {v[8*off +: 8], v[8*(off+1) +: 8], v[8*(off+2) +: 8], v[8*(off+3) +: 8]};
  endfunction

  function automatic logic [47:0] f_be48(input msgvec_t v, input int off);
    return {v[8*off +: 8], v[8*(off+1) +: 8], v[8*(off+2) +: 8],
            v[8*(off+3) +: 8], v[8*(off+4) +: 8], v[8*(off+5) +: 8]};
  endfunction

  function automatic logic [63:0] f_be64(input msgvec_t v, input int off);
    return {f_be32(v, off), f_be32(v, off + 4)};
  endfunction

  function automatic itch_msg_t decode_msg(input msgvec_t v);
    itch_msg_t m;
    logic [7:0] t;
    m           = '0;
    t           = v[8*OFF_TYPE +: 8];
    m.msg_type  = t;
    m.locate    = f_be16(v, OFF_LOCATE);
    m.tracking  = f_be16(v, OFF_TRACKING);
    m.timestamp = f_be48(v, OFF_TS);
    case (t)
      "S": m.event_code = v[8*SYS_OFF_EVENT +: 8];
      "R": m.stock = f_be64(v, DIR_OFF_STOCK);
      "A", "F": begin  // 'F' MPID attribution is intentionally dropped
        m.order_ref = f_be64(v, ADD_OFF_REF);
        m.side      = v[8*ADD_OFF_SIDE +: 8];
        m.shares    = f_be32(v, ADD_OFF_SHARES);
        m.stock     = f_be64(v, ADD_OFF_STOCK);
        m.price     = f_be32(v, ADD_OFF_PRICE);
      end
      "E": begin
        m.order_ref = f_be64(v, EXEC_OFF_REF);
        m.shares    = f_be32(v, EXEC_OFF_SHARES);
        m.match_num = f_be64(v, EXEC_OFF_MATCH);
      end
      "C": begin
        m.order_ref = f_be64(v, EXEC_OFF_REF);
        m.shares    = f_be32(v, EXEC_OFF_SHARES);
        m.match_num = f_be64(v, EXEC_OFF_MATCH);
        m.printable = v[8*EXECP_OFF_PRINTABLE +: 8];
        m.price     = f_be32(v, EXECP_OFF_PRICE);
      end
      "X": begin
        m.order_ref = f_be64(v, CXL_OFF_REF);
        m.shares    = f_be32(v, CXL_OFF_SHARES);
      end
      "D": m.order_ref = f_be64(v, DEL_OFF_REF);
      "U": begin
        m.order_ref     = f_be64(v, REPL_OFF_ORIG);
        m.new_order_ref = f_be64(v, REPL_OFF_NEW);
        m.shares        = f_be32(v, REPL_OFF_SHARES);
        m.price         = f_be32(v, REPL_OFF_PRICE);
      end
      "P": begin
        m.order_ref = f_be64(v, TRD_OFF_REF);
        m.side      = v[8*TRD_OFF_SIDE +: 8];
        m.shares    = f_be32(v, TRD_OFF_SHARES);
        m.stock     = f_be64(v, TRD_OFF_STOCK);
        m.price     = f_be32(v, TRD_OFF_PRICE);
        m.match_num = f_be64(v, TRD_OFF_MATCH);
      end
      default: ;  // header-only decode for types the book doesn't consume
    endcase
    return m;
  endfunction

  function automatic logic len_bad(input msgvec_t v, input int len);
    logic [7:0] t;
    t = v[8*OFF_TYPE +: 8];
    return (msg_size(t) != 0) && (len != msg_size(t));
  endfunction

  // The incoming beat, seen as a message vector. Equal widths on the path that
  // reads it -- CUT_THROUGH is refused below one beat per message.
  msgvec_t mvec_ct;
  assign mvec_ct = msgvec_t'(s_tdata);

  // ---- the two arrival paths, generated rather than multiplexed ----
  if (CUT_THROUGH) begin : g_cut_through
    // No collector exists here at all. A message is the beat.
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        m_valid   <= 1'b0;
        m_len_err <= 1'b0;
        m_msg     <= '0;
      end else begin
        m_valid   <= 1'b0;
        m_len_err <= 1'b0;
        if (s_tvalid && s_tlast) begin
          m_msg     <= decode_msg(mvec_ct);
          m_valid   <= 1'b1;
          m_len_err <= len_bad(mvec_ct, count_keep(s_tkeep));
        end
      end
    end

    // The contract this branch is built on, checked rather than assumed. There
    // is no collector to catch a message that spans beats, so an upstream that
    // sends one would have its message silently dropped -- and mold_splitter at
    // 512 bits sets tlast on every beat, which is exactly the sort of guarantee
    // that stops being true when someone changes the block that makes it.
    // synthesis translate_off
    always_ff @(posedge clk)
      if (rst_n && s_tvalid && !s_tlast)
        $fatal(1, "itch_decoder: CUT_THROUGH saw a beat without tlast -- the \
upstream is sending messages that span beats, which this branch cannot hold.");
    // synthesis translate_on

  end else begin : g_store_then_decode
    // UNPACKED, and that is not a style choice -- it is 83 MHz.
    // This was briefly a packed msgvec_t written with a variable part-select,
    // mvec_q[8*(wr_ptr+i) +: 8] <= ..., which reads as the same thing and is
    // not: an unpacked array of bytes is 64 eight-bit registers with an enable
    // apiece, while a packed vector indexed by a register is a barrel shifter
    // in front of 512 flops. Measured, same directive, everything else equal:
    // post-synth core_clk 222.4 MHz unpacked against 139.6 MHz packed, and the
    // build went from 0 failing endpoints to 230. The cut-through branch never
    // saw it because that branch has no collector -- which is exactly how a
    // regression hides in the path you are not looking at.
    logic [7:0] mbuf [BUFB];
    int         wr_ptr;
    int         msg_len;
    logic       decode_pending;

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        wr_ptr         <= 0;
        msg_len        <= 0;
        decode_pending <= 1'b0;
      end else begin
        decode_pending <= 1'b0;
        if (s_tvalid) begin
          for (int i = 0; i < KEEP_W; i++)
            if (s_tkeep[i] && (wr_ptr + i) < BUFB)
              mbuf[wr_ptr + i] <= s_tdata[8*i +: 8];
          if (s_tlast) begin
            msg_len        <= wr_ptr + count_keep(s_tkeep);
            wr_ptr         <= 0;
            decode_pending <= 1'b1;
          end else begin
            wr_ptr <= wr_ptr + KEEP_W;
          end
        end
      end
    end

    // Flatten for the shared decoder. Pure wiring, and it sits AFTER the
    // register: the byte lanes are fixed here, so there is no shifter.
    msgvec_t mvec_q;
    always_comb
      for (int b = 0; b < BUFB; b++) mvec_q[8*b +: 8] = mbuf[b];

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        m_valid   <= 1'b0;
        m_len_err <= 1'b0;
        m_msg     <= '0;
      end else begin
        m_valid   <= 1'b0;
        m_len_err <= 1'b0;
        if (decode_pending) begin
          m_msg     <= decode_msg(mvec_q);
          m_valid   <= 1'b1;
          m_len_err <= len_bad(mvec_q, msg_len);
        end
      end
    end
  end

endmodule
