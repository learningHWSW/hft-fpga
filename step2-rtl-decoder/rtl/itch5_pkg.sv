// ITCH 5.0 protocol constants — SystemVerilog mirror of step1's itch5.h.
// All fields are big-endian and byte aligned; message length is fully
// determined by the type byte (offset 0).
`timescale 1ns/1ps
package itch5_pkg;

  localparam int MAX_MSG_BYTES = 50;  // largest ITCH 5.0 message ('I' NOII)

  // Common header
  localparam int OFF_TYPE     = 0;
  localparam int OFF_LOCATE   = 1;  // 2 bytes
  localparam int OFF_TRACKING = 3;  // 2 bytes
  localparam int OFF_TS       = 5;  // 6 bytes, ns since midnight ET

  // 'S' System Event
  localparam int SYS_OFF_EVENT = 11;

  // 'R' Stock Directory
  localparam int DIR_OFF_STOCK = 11;  // 8 bytes ASCII, space padded

  // 'A' / 'F' Add Order ('F' adds a 4-byte MPID attribution at 36..39)
  localparam int ADD_OFF_REF    = 11;  // 8 bytes
  localparam int ADD_OFF_SIDE   = 19;  // 'B' / 'S'
  localparam int ADD_OFF_SHARES = 20;  // 4 bytes
  localparam int ADD_OFF_STOCK  = 24;  // 8 bytes
  localparam int ADD_OFF_PRICE  = 32;  // 4 bytes, fixed point 1e-4

  // 'E' Order Executed / 'C' Order Executed With Price
  localparam int EXEC_OFF_REF        = 11;
  localparam int EXEC_OFF_SHARES     = 19;
  localparam int EXEC_OFF_MATCH      = 23;
  localparam int EXECP_OFF_PRINTABLE = 31;  // 'C' only
  localparam int EXECP_OFF_PRICE     = 32;  // 'C' only

  // 'X' Order Cancel (partial)
  localparam int CXL_OFF_REF    = 11;
  localparam int CXL_OFF_SHARES = 19;

  // 'D' Order Delete
  localparam int DEL_OFF_REF = 11;

  // 'U' Order Replace — new order inherits side/stock of original
  localparam int REPL_OFF_ORIG   = 11;
  localparam int REPL_OFF_NEW    = 19;
  localparam int REPL_OFF_SHARES = 27;
  localparam int REPL_OFF_PRICE  = 31;

  // 'P' Trade, non-cross (hidden liquidity; no book impact)
  localparam int TRD_OFF_REF    = 11;
  localparam int TRD_OFF_SIDE   = 19;
  localparam int TRD_OFF_SHARES = 20;
  localparam int TRD_OFF_STOCK  = 24;
  localparam int TRD_OFF_PRICE  = 32;
  localparam int TRD_OFF_MATCH  = 36;

  // Total message size (header included) by type byte; 0 = unknown type.
  function automatic int msg_size(input logic [7:0] t);
    case (t)
      "S": return 12;
      "R": return 39;
      "H": return 25;
      "Y": return 20;
      "L": return 26;
      "V": return 35;
      "W": return 12;
      "K": return 28;
      "J": return 35;
      "h": return 21;
      "A": return 36;
      "F": return 40;
      "E": return 31;
      "C": return 36;
      "X": return 23;
      "D": return 19;
      "U": return 35;
      "P": return 44;
      "Q": return 40;
      "B": return 19;
      "I": return 50;
      "N": return 20;
      "O": return 48;
      default: return 0;
    endcase
  endfunction

  // Decoded-message superset struct: unused fields are zero for a given
  // type. One wide bus keeps downstream consumers (order table, book
  // engine) on a single interface.
  typedef struct packed {
    logic [7:0]  msg_type;
    logic [15:0] locate;
    logic [15:0] tracking;
    logic [47:0] timestamp;
    logic [63:0] order_ref;
    logic [63:0] new_order_ref;  // 'U' only
    logic [7:0]  side;           // 'B' / 'S'
    logic [31:0] shares;
    logic [63:0] stock;          // 8 ASCII chars, first char in MSB
    logic [31:0] price;
    logic [63:0] match_num;
    logic [7:0]  event_code;     // 'S' only
    logic [7:0]  printable;      // 'C' only
  } itch_msg_t;

endpackage
