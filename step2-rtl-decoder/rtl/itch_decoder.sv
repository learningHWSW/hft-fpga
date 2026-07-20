// ITCH 5.0 message decoder.
//
// Input : AXI-Stream, one ITCH message per packet (framing — MoldUDP64 or
//         the file dump's length prefix — is stripped upstream). Byte 0 of
//         the message rides tdata[7:0] of the first beat; tkeep is
//         contiguous from bit 0 on the last beat.
// Output: decoded itch_msg_t + 1-cycle valid pulse, one cycle after the
//         beat carrying tlast (store-then-decode; the cut-through variant
//         that fires per-field before tlast is a later optimization).
//
// No backpressure: s_tready is constant 1. A market-data front end must
// never stall the wire — if a downstream consumer is slow, the fix is a
// FIFO behind this module, not backpressure into the MAC.
`timescale 1ns/1ps
module itch_decoder
  import itch5_pkg::*;
#(
  parameter int DATA_W = 64
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

  logic [7:0] mbuf [BUFB];
  int         wr_ptr;
  int         msg_len;
  logic       decode_pending;

  assign s_tready = 1'b1;

  function automatic int count_keep(input logic [KEEP_W-1:0] k);
    int c = 0;
    for (int i = 0; i < KEEP_W; i++) c += int'(k[i]);
    return c;
  endfunction

  // ---- byte collection ----
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

  // ---- big-endian field extractors (pure byte-lane selects) ----
  function automatic logic [15:0] f_be16(input int off);
    return {mbuf[off], mbuf[off+1]};
  endfunction

  function automatic logic [31:0] f_be32(input int off);
    return {mbuf[off], mbuf[off+1], mbuf[off+2], mbuf[off+3]};
  endfunction

  function automatic logic [47:0] f_be48(input int off);
    return {mbuf[off], mbuf[off+1], mbuf[off+2],
            mbuf[off+3], mbuf[off+4], mbuf[off+5]};
  endfunction

  function automatic logic [63:0] f_be64(input int off);
    return {f_be32(off), f_be32(off + 4)};
  endfunction

  function automatic itch_msg_t decode_msg();
    itch_msg_t m;
    m           = '0;
    m.msg_type  = mbuf[OFF_TYPE];
    m.locate    = f_be16(OFF_LOCATE);
    m.tracking  = f_be16(OFF_TRACKING);
    m.timestamp = f_be48(OFF_TS);
    case (mbuf[OFF_TYPE])
      "S": m.event_code = mbuf[SYS_OFF_EVENT];
      "R": m.stock = f_be64(DIR_OFF_STOCK);
      "A", "F": begin  // 'F' MPID attribution is intentionally dropped
        m.order_ref = f_be64(ADD_OFF_REF);
        m.side      = mbuf[ADD_OFF_SIDE];
        m.shares    = f_be32(ADD_OFF_SHARES);
        m.stock     = f_be64(ADD_OFF_STOCK);
        m.price     = f_be32(ADD_OFF_PRICE);
      end
      "E": begin
        m.order_ref = f_be64(EXEC_OFF_REF);
        m.shares    = f_be32(EXEC_OFF_SHARES);
        m.match_num = f_be64(EXEC_OFF_MATCH);
      end
      "C": begin
        m.order_ref = f_be64(EXEC_OFF_REF);
        m.shares    = f_be32(EXEC_OFF_SHARES);
        m.match_num = f_be64(EXEC_OFF_MATCH);
        m.printable = mbuf[EXECP_OFF_PRINTABLE];
        m.price     = f_be32(EXECP_OFF_PRICE);
      end
      "X": begin
        m.order_ref = f_be64(CXL_OFF_REF);
        m.shares    = f_be32(CXL_OFF_SHARES);
      end
      "D": m.order_ref = f_be64(DEL_OFF_REF);
      "U": begin
        m.order_ref     = f_be64(REPL_OFF_ORIG);
        m.new_order_ref = f_be64(REPL_OFF_NEW);
        m.shares        = f_be32(REPL_OFF_SHARES);
        m.price         = f_be32(REPL_OFF_PRICE);
      end
      "P": begin
        m.order_ref = f_be64(TRD_OFF_REF);
        m.side      = mbuf[TRD_OFF_SIDE];
        m.shares    = f_be32(TRD_OFF_SHARES);
        m.stock     = f_be64(TRD_OFF_STOCK);
        m.price     = f_be32(TRD_OFF_PRICE);
        m.match_num = f_be64(TRD_OFF_MATCH);
      end
      default: ;  // header-only decode for types the book doesn't consume
    endcase
    return m;
  endfunction

  // ---- decode stage ----
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      m_valid   <= 1'b0;
      m_len_err <= 1'b0;
      m_msg     <= '0;
    end else begin
      m_valid   <= 1'b0;
      m_len_err <= 1'b0;
      if (decode_pending) begin
        m_msg     <= decode_msg();
        m_valid   <= 1'b1;
        m_len_err <= (msg_size(mbuf[OFF_TYPE]) != 0)
                   && (msg_len != msg_size(mbuf[OFF_TYPE]));
      end
    end
  end

endmodule
