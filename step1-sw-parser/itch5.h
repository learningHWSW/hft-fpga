/*
 * NASDAQ TotalView-ITCH 5.0 message layouts.
 *
 * All multi-byte integers are BIG-ENDIAN (network order).
 * All messages are fixed length — length is fully determined by the first
 * byte (message type). This is what makes ITCH ideal for hardware decoding:
 * the decoder FSM knows the total length after seeing byte 0.
 *
 * Common header (every message):
 *   offset 0  : 1 byte  message type (ASCII)
 *   offset 1  : 2 bytes stock locate  (per-day integer id for the symbol)
 *   offset 3  : 2 bytes tracking number
 *   offset 5  : 6 bytes timestamp, nanoseconds since midnight ET
 *
 * Prices are unsigned 32-bit fixed point with 4 decimal places:
 *   1500000 == $150.0000
 *
 * NOTE on framing: this parser reads the NASDAQ *file dump* format
 * (BinaryFILE): a stream of [2-byte big-endian length][message].
 * On the wire the same messages arrive inside MoldUDP64 UDP packets:
 *   session(10) + sequence(8) + count(2), then count x [len(2) + message].
 * The RTL front-end (step 2+) must strip the MoldUDP64 header; the
 * per-message decoding below is identical in both cases.
 */
#ifndef ITCH5_H
#define ITCH5_H

/* Total message sizes (header included), indexed by message type. 0 = unknown. */
static const int ITCH_MSG_SIZE[128] = {
    ['S'] = 12, /* System Event */
    ['R'] = 39, /* Stock Directory */
    ['H'] = 25, /* Stock Trading Action */
    ['Y'] = 20, /* Reg SHO Restriction */
    ['L'] = 26, /* Market Participant Position */
    ['V'] = 35, /* MWCB Decline Level */
    ['W'] = 12, /* MWCB Status */
    ['K'] = 28, /* IPO Quoting Period Update */
    ['J'] = 35, /* LULD Auction Collar */
    ['h'] = 21, /* Operational Halt */
    ['A'] = 36, /* Add Order (no MPID) */
    ['F'] = 40, /* Add Order with MPID */
    ['E'] = 31, /* Order Executed */
    ['C'] = 36, /* Order Executed With Price */
    ['X'] = 23, /* Order Cancel (partial) */
    ['D'] = 19, /* Order Delete */
    ['U'] = 35, /* Order Replace */
    ['P'] = 44, /* Trade (non-cross, hidden liquidity) */
    ['Q'] = 40, /* Cross Trade */
    ['B'] = 19, /* Broken Trade */
    ['I'] = 50, /* Net Order Imbalance Indicator (NOII) */
    ['N'] = 20, /* Retail Price Improvement Indicator */
    ['O'] = 48, /* Direct Listing w/ Capital Raise Price Discovery */
};

/* Common header field offsets */
#define ITCH_OFF_TYPE      0
#define ITCH_OFF_LOCATE    1
#define ITCH_OFF_TRACKING  3
#define ITCH_OFF_TS        5   /* 6 bytes */

/* 'A' / 'F' Add Order:  A = 36 bytes, F = A + 4-byte MPID attribution */
#define ADD_OFF_ORDER_REF  11  /* 8 bytes */
#define ADD_OFF_SIDE       19  /* 1 byte: 'B' or 'S' */
#define ADD_OFF_SHARES     20  /* 4 bytes */
#define ADD_OFF_STOCK      24  /* 8 bytes, space padded ASCII */
#define ADD_OFF_PRICE      32  /* 4 bytes */

/* 'E' Order Executed: 31 bytes */
#define EXEC_OFF_ORDER_REF 11  /* 8 bytes */
#define EXEC_OFF_SHARES    19  /* 4 bytes executed */
#define EXEC_OFF_MATCH     23  /* 8 bytes match number */

/* 'C' Order Executed With Price: 36 bytes  (execution at != display price) */
#define EXECP_OFF_PRINTABLE 31 /* 1 byte 'Y'/'N' */
#define EXECP_OFF_PRICE     32 /* 4 bytes execution price */

/* 'X' Order Cancel: 23 bytes */
#define CANCEL_OFF_ORDER_REF 11 /* 8 bytes */
#define CANCEL_OFF_SHARES    19 /* 4 bytes cancelled */

/* 'D' Order Delete: 19 bytes */
#define DEL_OFF_ORDER_REF  11  /* 8 bytes */

/* 'U' Order Replace: 35 bytes. New order inherits side+stock of original. */
#define REPL_OFF_ORIG_REF  11  /* 8 bytes */
#define REPL_OFF_NEW_REF   19  /* 8 bytes */
#define REPL_OFF_SHARES    27  /* 4 bytes */
#define REPL_OFF_PRICE     31  /* 4 bytes */

/* 'P' Trade (non-cross): 44 bytes. Hidden-order execution; no book impact. */
#define TRADE_OFF_ORDER_REF 11 /* 8 bytes (always 0 in ITCH 5.0) */
#define TRADE_OFF_SIDE      19 /* 1 byte */
#define TRADE_OFF_SHARES    20 /* 4 bytes */
#define TRADE_OFF_STOCK     24 /* 8 bytes */
#define TRADE_OFF_PRICE     32 /* 4 bytes */
#define TRADE_OFF_MATCH     36 /* 8 bytes */

/* 'R' Stock Directory */
#define DIR_OFF_STOCK      11  /* 8 bytes */

/* 'S' System Event: event code at offset 11.
 * 'O' start of messages, 'S' start of system hours, 'Q' start of market
 * hours, 'M' end of market hours, 'E' end of system hours, 'C' end of
 * messages. */
#define SYS_OFF_EVENT      11

#endif /* ITCH5_H */
