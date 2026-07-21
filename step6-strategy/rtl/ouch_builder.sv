// OUCH 4.2 order builder — turns a strategy order intent into wire bytes.
//
// Per PLAN §6 the SESSION is software's job: login, sequence recovery,
// retransmission and heartbeats all live on the host, which hands this block
// nothing but static configuration. What stays in hardware is the one thing
// that has to be fast — assembling and firing the packet the moment the book
// says to. Everything here is therefore a constant concatenation of registered
// configuration and three live fields (side, shares, price), which is pure
// wiring: one cycle, no state machine, no memory.
//
// Wire format (52 bytes, byte 0 in m_tdata[7:0] like the rest of the design):
//   SoupBinTCP  0..1  Packet Length     2  big-endian, type byte + payload
//               2     Packet Type       1  'U' = unsequenced data
//   OUCH        3     Message Type      1  'O' = enter order
//               4..17 Order Token      14
//               18    Buy/Sell          1
//               19..22 Shares           4  big-endian
//               23..30 Stock            8  ASCII, space padded
//               31..34 Price            4  big-endian, 1e-4 units
//               35..38 Time in Force    4  big-endian (0 = IOC)
//               39..42 Firm             4
//               43    Display           1
//               44    Capacity          1
//               45    Sweep eligible    1
//               46..49 Minimum Quantity 4  big-endian
//               50    Cross Type        1
//               51    Customer Type     1
//
// The single-character enum fields are all configuration inputs rather than
// constants. Their offsets are structural, but their VALUES are the part of
// the spec most easily gotten wrong, and a wrong capacity code is a compliance
// problem rather than a bug — so the host owns them and they can be corrected
// without a rebuild. See scripts/dump_ouch.py, which is the golden.
//
// Price needs no conversion: ITCH and OUCH both use 1e-4 units, so the book's
// price is already the order's price.
//
// The order token is a 6-character prefix plus an order counter in 8 hex
// digits. Hex rather than decimal because binary-to-decimal needs a divider
// and buys nothing: the token has to be unique, not readable.
`timescale 1ns/1ps
module ouch_builder #(
  parameter int DATA_W = 512
)(
  input  logic         clk,
  input  logic         rst_n,

  // static configuration (host-written while the strategy is disabled)
  input  logic [47:0]  cfg_token_prefix,   // 6 ASCII bytes, [7:0] is first
  input  logic [63:0]  cfg_stock,          // 8 ASCII bytes, [7:0] is first
  input  logic [31:0]  cfg_firm,           // 4 ASCII bytes
  input  logic [31:0]  cfg_tif,            // 0 = IOC
  input  logic [31:0]  cfg_min_qty,
  input  logic [7:0]   cfg_display,
  input  logic [7:0]   cfg_capacity,
  input  logic [7:0]   cfg_sweep,
  input  logic [7:0]   cfg_cross,
  input  logic [7:0]   cfg_cust,

  // order intent from strategy
  input  logic         i_valid,
  input  logic         i_is_buy,
  input  logic [31:0]  i_qty,
  input  logic [31:0]  i_price,
  output logic         i_ready,

  // framed packet, one beat
  output logic [DATA_W-1:0]   m_tdata,
  output logic [DATA_W/8-1:0] m_tkeep,
  output logic                m_tvalid,
  output logic                m_tlast,
  input  logic                m_tready,

  output logic [31:0]  pkt_cnt,
  output logic [31:0]  token_seq     // next token counter, for host reconciliation
);
  localparam int OUCH_B = 49;
  localparam int PKT_B  = 3 + OUCH_B;          // 52

  // 4 bits -> ASCII hex. A case, not arithmetic: '0'+n breaks past 9.
  function automatic logic [7:0] hexc(input logic [3:0] n);
    return (n < 4'd10) ? (8'h30 + 8'(n)) : (8'h41 + 8'(n) - 8'd10);
  endfunction

  // big-endian byte k (0 = most significant) of a 32-bit field
  function automatic logic [7:0] be32(input logic [31:0] v, input int k);
    return v[8*(3-k) +: 8];
  endfunction

  logic [8*PKT_B-1:0] pkt;
  always_comb begin
    pkt = '0;
    // ---- SoupBinTCP ----
    pkt[8*0  +: 8] = 8'((OUCH_B + 1) >> 8);    // length, big-endian
    pkt[8*1  +: 8] = 8'((OUCH_B + 1) & 8'hFF);
    pkt[8*2  +: 8] = "U";
    // ---- OUCH Enter Order ----
    pkt[8*3  +: 8] = "O";
    for (int k = 0; k < 6; k++)                // token: prefix
      pkt[8*(4 + k) +: 8] = cfg_token_prefix[8*k +: 8];
    for (int k = 0; k < 8; k++)                // token: counter, hex, MS nibble first
      pkt[8*(10 + k) +: 8] = hexc(token_seq[4*(7-k) +: 4]);
    pkt[8*18 +: 8] = i_is_buy ? "B" : "S";
    for (int k = 0; k < 4; k++) pkt[8*(19 + k) +: 8] = be32(i_qty, k);
    for (int k = 0; k < 8; k++) pkt[8*(23 + k) +: 8] = cfg_stock[8*k +: 8];
    for (int k = 0; k < 4; k++) pkt[8*(31 + k) +: 8] = be32(i_price, k);
    for (int k = 0; k < 4; k++) pkt[8*(35 + k) +: 8] = be32(cfg_tif, k);
    for (int k = 0; k < 4; k++) pkt[8*(39 + k) +: 8] = cfg_firm[8*k +: 8];
    pkt[8*43 +: 8] = cfg_display;
    pkt[8*44 +: 8] = cfg_capacity;
    pkt[8*45 +: 8] = cfg_sweep;
    for (int k = 0; k < 4; k++) pkt[8*(46 + k) +: 8] = be32(cfg_min_qty, k);
    pkt[8*50 +: 8] = cfg_cross;
    pkt[8*51 +: 8] = cfg_cust;
  end

  // The packet fits one beat (52 <= 64), so there is no state machine: accept
  // an intent whenever the output register is free or draining.
  assign i_ready = !m_tvalid || m_tready;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      m_tvalid  <= 1'b0;
      m_tlast   <= 1'b0;
      m_tkeep   <= '0;
      m_tdata   <= '0;
      pkt_cnt   <= '0;
      token_seq <= '0;
    end else begin
      if (m_tvalid && m_tready) m_tvalid <= 1'b0;
      if (i_valid && i_ready) begin
        m_tdata   <= DATA_W'(pkt);
        m_tkeep   <= {(DATA_W/8){1'b1}} >> (DATA_W/8 - PKT_B);
        m_tvalid  <= 1'b1;
        m_tlast   <= 1'b1;
        pkt_cnt   <= pkt_cnt + 1;
        token_seq <= token_seq + 1;
      end
    end
  end

endmodule
