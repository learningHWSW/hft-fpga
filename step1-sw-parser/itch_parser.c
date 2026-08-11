/*
 * ITCH 5.0 reference parser + single-symbol top-of-book tracker.
 *
 * Purpose: golden model for the SystemVerilog decoder (step 2). Every field
 * extraction here maps 1:1 to a byte-lane select in RTL, so keep this file
 * boring and explicit — no clever parsing.
 *
 * Usage:
 *   ./itch_parser <file|-> [SYMBOL] [max_messages]
 *   .gz files are decompressed through "gzip -dc" automatically.
 *   ITCH_BBO_RAW=1 prints BBO records as integers for analysis (see below).
 *
 * Book model:
 *   - orders keyed by 64-bit order reference (hash table)
 *   - one aggregated price ladder per side (sorted array; index 0 = best)
 *   - BBO printed whenever best bid/ask price or quantity changes
 *   - non-target symbols filtered by stock locate from the common header,
 *     which is exactly what the RTL will do (locate match instead of an
 *     8-byte symbol compare on every message)
 */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <inttypes.h>
#include <time.h>
#include "itch5.h"

/* ---------- big-endian readers ---------- */
static inline uint16_t be16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static inline uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
static inline uint64_t be48(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 0; i < 6; i++) v = (v << 8) | p[i];
    return v;
}
static inline uint64_t be64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v = (v << 8) | p[i];
    return v;
}

/* ---------- order table: open-addressing hash, tombstone deletes ---------- */
enum { SLOT_EMPTY = 0, SLOT_USED = 1, SLOT_TOMB = 2 };

typedef struct {
    uint64_t ref;
    uint32_t shares;   /* remaining displayed shares */
    uint32_t price;
    uint8_t  side;     /* 'B' or 'S' */
    uint8_t  state;
} order_t;

static order_t *otab;
static size_t   ocap = 1u << 16, ocnt, otombs;

static size_t ohash(uint64_t ref) {
    ref ^= ref >> 33;
    ref *= 0xff51afd7ed558ccdULL;
    ref ^= ref >> 33;
    return (size_t)ref;
}

static order_t *order_find(uint64_t ref) {
    size_t mask = ocap - 1, i = ohash(ref) & mask;
    while (otab[i].state != SLOT_EMPTY) {
        if (otab[i].state == SLOT_USED && otab[i].ref == ref) return &otab[i];
        i = (i + 1) & mask;
    }
    return NULL;
}

static void order_insert(uint64_t ref, uint8_t side, uint32_t shares, uint32_t price);

static void order_grow(void) {
    order_t *old = otab;
    size_t oldcap = ocap;
    ocap <<= 1;
    ocnt = otombs = 0;
    otab = calloc(ocap, sizeof(order_t));
    if (!otab) { fprintf(stderr, "out of memory\n"); exit(1); }
    for (size_t i = 0; i < oldcap; i++)
        if (old[i].state == SLOT_USED)
            order_insert(old[i].ref, old[i].side, old[i].shares, old[i].price);
    free(old);
}

static void order_insert(uint64_t ref, uint8_t side, uint32_t shares, uint32_t price) {
    if ((ocnt + otombs) * 10 >= ocap * 7) order_grow();
    size_t mask = ocap - 1, i = ohash(ref) & mask;
    while (otab[i].state == SLOT_USED) i = (i + 1) & mask;
    if (otab[i].state == SLOT_TOMB) otombs--;
    otab[i] = (order_t){ ref, shares, price, side, SLOT_USED };
    ocnt++;
}

static void order_remove(order_t *o) {
    o->state = SLOT_TOMB;
    ocnt--;
    otombs++;
}

/* ---------- price ladder ---------- */
#define MAXLVL 65536

typedef struct { uint32_t price; uint64_t qty; } level_t;

static level_t bids[MAXLVL], asks[MAXLVL];
static int nbids, nasks;

/* binary search; bids descending, asks ascending; returns slot index */
static int lvl_find(const level_t *arr, int n, uint32_t price, int desc, int *found) {
    int lo = 0, hi = n;
    while (lo < hi) {
        int mid = (lo + hi) / 2;
        if (arr[mid].price == price) { *found = 1; return mid; }
        int before = desc ? (arr[mid].price > price) : (arr[mid].price < price);
        if (before) lo = mid + 1; else hi = mid;
    }
    *found = 0;
    return lo;
}

static void book_add(uint8_t side, uint32_t price, uint32_t qty) {
    level_t *arr = (side == 'B') ? bids : asks;
    int *n = (side == 'B') ? &nbids : &nasks;
    int found, idx = lvl_find(arr, *n, price, side == 'B', &found);
    if (found) {
        arr[idx].qty += qty;
    } else {
        if (*n >= MAXLVL) { fprintf(stderr, "price ladder overflow\n"); exit(1); }
        memmove(&arr[idx + 1], &arr[idx], (size_t)(*n - idx) * sizeof(level_t));
        arr[idx] = (level_t){ price, qty };
        (*n)++;
    }
}

static void book_reduce(uint8_t side, uint32_t price, uint32_t qty) {
    level_t *arr = (side == 'B') ? bids : asks;
    int *n = (side == 'B') ? &nbids : &nasks;
    int found, idx = lvl_find(arr, *n, price, side == 'B', &found);
    if (!found) { fprintf(stderr, "warn: reduce on missing level %u\n", price); return; }
    if (arr[idx].qty <= qty) {
        memmove(&arr[idx], &arr[idx + 1], (size_t)(*n - idx - 1) * sizeof(level_t));
        (*n)--;
    } else {
        arr[idx].qty -= qty;
    }
}

/* ---------- output ---------- */
static uint64_t bbo_updates, trade_count;

/*
 * Two output formats, because this file has two readers.
 *
 * The default is for a person: a clock timestamp and dotted prices, which is
 * what makes it useful as the reference model it was written to be.
 *
 * ITCH_BBO_RAW=1 switches BBO lines to "ts_ns bid_px bid_qty ask_px ask_qty",
 * integers throughout, and suppresses the trade lines. That exists because the
 * forward-return studies need the whole day at nanosecond resolution: a
 * measurement over 424,657 records cannot afford to parse a formatted clock and
 * re-multiply a decimal price back into 1e-4 units, and doing so would put a
 * rounding step between the book model and the statistics drawn from it.
 * Prices stay in the wire's own 1e-4 units for the same reason.
 */
static int bbo_raw;

static void fmt_ts(uint64_t ns, char *out) {
    uint64_t s = ns / 1000000000ULL, rem = ns % 1000000000ULL;
    sprintf(out, "%02" PRIu64 ":%02" PRIu64 ":%02" PRIu64 ".%09" PRIu64,
            s / 3600, (s / 60) % 60, s % 60, rem);
}

static void fmt_px(uint32_t px, char *out) {
    sprintf(out, "%u.%04u", px / 10000, px % 10000);
}

static void print_bbo(uint64_t ts) {
    static uint32_t lbp = UINT32_MAX, lap = UINT32_MAX;
    static uint64_t lbq = UINT64_MAX, laq = UINT64_MAX;
    uint32_t bp = nbids ? bids[0].price : 0;
    uint64_t bq = nbids ? bids[0].qty : 0;
    uint32_t ap = nasks ? asks[0].price : 0;
    uint64_t aq = nasks ? asks[0].qty : 0;
    if (bp == lbp && bq == lbq && ap == lap && aq == laq) return;
    lbp = bp; lbq = bq; lap = ap; laq = aq;
    bbo_updates++;

    if (bbo_raw) {
        printf("%" PRIu64 " %u %" PRIu64 " %u %" PRIu64 "\n", ts, bp, bq, ap, aq);
        return;
    }

    char t[32], b[16], a[16];
    fmt_ts(ts, t);
    if (nbids) fmt_px(bp, b); else strcpy(b, "-");
    if (nasks) fmt_px(ap, a); else strcpy(a, "-");
    printf("%s BBO  %10s x %-6" PRIu64 " | %10s x %-6" PRIu64 "\n", t, b, bq, a, aq);
}

static void print_trade(uint64_t ts, uint8_t side, uint32_t shares, uint32_t px, const char *tag) {
    if (bbo_raw) { trade_count++; return; }
    char t[32], p[16];
    fmt_ts(ts, t);
    fmt_px(px, p);
    trade_count++;
    printf("%s TRADE %s %c %u @ %s\n", t, tag, side, shares, p);
}

/* ---------- main ---------- */
int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <file|-> [SYMBOL] [max_messages]\n", argv[0]);
        return 1;
    }

    /* target symbol, space padded to 8 like the wire format */
    char target_stock[9] = "AAPL    ";
    if (argc >= 3) {
        memset(target_stock, ' ', 8);
        size_t n = strlen(argv[2]);
        if (n > 8) n = 8;
        memcpy(target_stock, argv[2], n);
    }
    uint64_t max_msgs = (argc >= 4) ? strtoull(argv[3], NULL, 10) : 0;
    { const char *e = getenv("ITCH_BBO_RAW"); bbo_raw = (e && *e == '1'); }

    FILE *f;
    int piped = 0;
    if (strcmp(argv[1], "-") == 0) {
        f = stdin;
    } else if (strlen(argv[1]) > 3 && strcmp(argv[1] + strlen(argv[1]) - 3, ".gz") == 0) {
        char cmd[4096];
        snprintf(cmd, sizeof cmd, "gzip -dc '%s'", argv[1]);
        f = popen(cmd, "r");
        piped = 1;
    } else {
        f = fopen(argv[1], "rb");
    }
    if (!f) { perror(argv[1]); return 1; }

    otab = calloc(ocap, sizeof(order_t));
    if (!otab) { fprintf(stderr, "out of memory\n"); return 1; }

    uint64_t counts[128] = {0}, total = 0, size_mismatch = 0;
    uint16_t target_locate = 0;
    int have_locate = 0;

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    uint8_t hdr[2], buf[64];
    while (fread(hdr, 1, 2, f) == 2) {
        uint16_t len = be16(hdr);
        if (len == 0) break;
        if (len > sizeof buf) { fprintf(stderr, "oversized message len=%u\n", len); break; }
        if (fread(buf, 1, len, f) != len) { fprintf(stderr, "truncated message\n"); break; }

        uint8_t type = buf[ITCH_OFF_TYPE];
        total++;
        if (type < 128) counts[type]++;
        if (type < 128 && ITCH_MSG_SIZE[type] && ITCH_MSG_SIZE[type] != len) size_mismatch++;
        if (max_msgs && total >= max_msgs) break;

        uint16_t locate = be16(buf + ITCH_OFF_LOCATE);
        uint64_t ts = be48(buf + ITCH_OFF_TS);
        int is_target = have_locate && locate == target_locate;

        switch (type) {
        case 'S': {
            char t[32];
            fmt_ts(ts, t);
            if (!bbo_raw) printf("%s SYSTEM EVENT '%c'\n", t, buf[SYS_OFF_EVENT]);
            break;
        }
        case 'R':
            if (memcmp(buf + DIR_OFF_STOCK, target_stock, 8) == 0) {
                target_locate = locate;
                have_locate = 1;
                if (!bbo_raw) printf("-- directory: %.8s locate=%u\n", target_stock, locate);
            }
            break;
        case 'A':
        case 'F': {
            /* fallback: learn locate from the symbol field if no 'R' seen */
            if (!have_locate && memcmp(buf + ADD_OFF_STOCK, target_stock, 8) == 0) {
                target_locate = locate;
                have_locate = 1;
                if (!bbo_raw) printf("-- learned locate=%u from add order\n", locate);
            }
            if (!(have_locate && locate == target_locate)) break;
            uint64_t ref = be64(buf + ADD_OFF_ORDER_REF);
            uint8_t side = buf[ADD_OFF_SIDE];
            uint32_t shares = be32(buf + ADD_OFF_SHARES);
            uint32_t price = be32(buf + ADD_OFF_PRICE);
            order_insert(ref, side, shares, price);
            book_add(side, price, shares);
            print_bbo(ts);
            break;
        }
        case 'E':
        case 'C': {
            if (!is_target) break;
            uint64_t ref = be64(buf + EXEC_OFF_ORDER_REF);
            uint32_t exec = be32(buf + EXEC_OFF_SHARES);
            order_t *o = order_find(ref);
            if (!o) { fprintf(stderr, "warn: exec on unknown order %" PRIu64 "\n", ref); break; }
            /* book impact is always at the order's displayed price; a 'C'
             * message trades at its own (better) price but removes displayed
             * liquidity from where the order was resting */
            uint32_t trade_px = (type == 'C') ? be32(buf + EXECP_OFF_PRICE) : o->price;
            print_trade(ts, o->side, exec, trade_px, type == 'C' ? "EXEC@PX" : "EXEC");
            book_reduce(o->side, o->price, exec);
            if (o->shares <= exec) order_remove(o); else o->shares -= exec;
            print_bbo(ts);
            break;
        }
        case 'X': {
            if (!is_target) break;
            uint64_t ref = be64(buf + CANCEL_OFF_ORDER_REF);
            uint32_t cxl = be32(buf + CANCEL_OFF_SHARES);
            order_t *o = order_find(ref);
            if (!o) { fprintf(stderr, "warn: cancel on unknown order %" PRIu64 "\n", ref); break; }
            book_reduce(o->side, o->price, cxl);
            if (o->shares <= cxl) order_remove(o); else o->shares -= cxl;
            print_bbo(ts);
            break;
        }
        case 'D': {
            if (!is_target) break;
            uint64_t ref = be64(buf + DEL_OFF_ORDER_REF);
            order_t *o = order_find(ref);
            if (!o) { fprintf(stderr, "warn: delete on unknown order %" PRIu64 "\n", ref); break; }
            book_reduce(o->side, o->price, o->shares);
            order_remove(o);
            print_bbo(ts);
            break;
        }
        case 'U': {
            if (!is_target) break;
            uint64_t orig = be64(buf + REPL_OFF_ORIG_REF);
            uint64_t nref = be64(buf + REPL_OFF_NEW_REF);
            uint32_t shares = be32(buf + REPL_OFF_SHARES);
            uint32_t price = be32(buf + REPL_OFF_PRICE);
            order_t *o = order_find(orig);
            if (!o) { fprintf(stderr, "warn: replace on unknown order %" PRIu64 "\n", orig); break; }
            uint8_t side = o->side;
            book_reduce(side, o->price, o->shares);
            order_remove(o);
            order_insert(nref, side, shares, price);
            book_add(side, price, shares);
            print_bbo(ts);
            break;
        }
        case 'P': {
            /* hidden-order execution: trade print only, no book change */
            if (memcmp(buf + TRADE_OFF_STOCK, target_stock, 8) != 0) break;
            print_trade(ts, buf[TRADE_OFF_SIDE], be32(buf + TRADE_OFF_SHARES),
                        be32(buf + TRADE_OFF_PRICE), "HIDDEN");
            break;
        }
        default:
            break; /* counted above; no book impact for this exercise */
        }
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);
    double secs = (double)(t1.tv_sec - t0.tv_sec) + (double)(t1.tv_nsec - t0.tv_nsec) / 1e9;

    fprintf(stderr, "\n==== stats ====\n");
    for (int i = 0; i < 128; i++)
        if (counts[i])
            fprintf(stderr, "  '%c' : %12" PRIu64 "\n", i, counts[i]);
    fprintf(stderr, "  total messages : %" PRIu64 "\n", total);
    fprintf(stderr, "  size mismatches: %" PRIu64 "\n", size_mismatch);
    fprintf(stderr, "  BBO updates    : %" PRIu64 "\n", bbo_updates);
    fprintf(stderr, "  trades printed : %" PRIu64 "\n", trade_count);
    fprintf(stderr, "  live orders    : %zu\n", ocnt);
    fprintf(stderr, "  elapsed        : %.3f s (%.2f M msg/s)\n",
            secs, secs > 0 ? (double)total / secs / 1e6 : 0.0);

    if (piped) pclose(f); else if (f != stdin) fclose(f);
    free(otab);
    return 0;
}
