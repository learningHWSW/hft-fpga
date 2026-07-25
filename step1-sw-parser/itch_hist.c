/* itch_hist — one-pass measurement tool over a NASDAQ_ITCH50 BinaryFILE
 * stream (2B BE length prefix per message; .gz via "gzip -dc" like
 * itch_parser.c). Produces the numbers PLAN.md steps 3b/4a call for:
 *
 *  1. message type mix and size distribution
 *  2. msgs-per-window histograms (1us / 10us / 100us / 1ms) over the
 *     exchange timestamps
 *  3. FIFO backlog simulation for the step-3b splitter:
 *       arrival = 100G wire serialization of (len+2)-byte framed msgs,
 *                 released no earlier than the message's own timestamp
 *       drain   = single server, 1 msg per 322.265625 MHz cycle
 *     -> exact max backlog in msgs and bytes = required FIFO for zero drop.
 *     Caveat: timestamps are matching-engine time and MoldUDP64/UDP/Eth
 *     per-packet overhead is not modeled, so modeled arrivals are denser
 *     than reality -> the FIFO bound is conservative (safe side).
 *  4. live open-order tracking (A/F insert, E/C/X decrement, D delete,
 *     U delete+insert): peak concurrent orders, plus linear-probe length
 *     stats for hash(ref) = low bits — the PLAN 4a "measure, don't guess"
 *     input for table sizing and way count.
 *
 * Usage: ./itch_hist <file[.gz]> [max_msgs]
 */
#define _DEFAULT_SOURCE  /* popen/pclose */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---------- big-endian readers ---------- */
static inline uint16_t be16(const uint8_t *p){ return (uint16_t)(p[0]<<8 | p[1]); }
static inline uint32_t be32(const uint8_t *p){ return (uint32_t)p[0]<<24 | (uint32_t)p[1]<<16 | (uint32_t)p[2]<<8 | p[3]; }
static inline uint64_t be48(const uint8_t *p){ uint64_t v=0; for(int i=0;i<6;i++) v=v<<8|p[i]; return v; }
static inline uint64_t be64(const uint8_t *p){ uint64_t v=0; for(int i=0;i<8;i++) v=v<<8|p[i]; return v; }

/* ---------- type mix ---------- */
static uint64_t type_cnt[256], type_bytes[256];

/* ---------- msgs per window ---------- */
#define NWIN 4
static const uint64_t win_ns[NWIN] = {1000ull, 10000ull, 100000ull, 1000000ull};
static const char    *win_name[NWIN] = {"1us", "10us", "100us", "1ms"};
#define WCAP (1u<<20)
static uint32_t *win_hist[NWIN];          /* histogram of msgs-per-window   */
static uint64_t  win_id[NWIN];            /* current window index           */
static uint64_t  win_cur[NWIN];           /* msgs in current window         */
static uint64_t  win_active[NWIN];        /* windows with >=1 msg           */
static uint64_t  win_max[NWIN], win_max_ts[NWIN];

static void win_flush(int w){
    uint64_t c = win_cur[w];
    if (!c) return;
    win_hist[w][c < WCAP ? c : WCAP-1]++;
    win_active[w]++;
    win_cur[w] = 0;
}
static void win_feed(int w, uint64_t ts){
    uint64_t id = ts / win_ns[w];
    if (id != win_id[w]) { win_flush(w); win_id[w] = id; }
    if (++win_cur[w] > win_max[w]) { win_max[w] = win_cur[w]; win_max_ts[w] = ts; }
}

/* ---------- backlog simulation ----------
 * A single wire (100G serialization) feeds one or more single-server queues,
 * each with its own service time per message. This is how "does the design
 * keep up at line rate" is MEASURED rather than assumed: the splitter drains
 * 1 msg / 3.103 ns, the order table is slower (its FSM takes several cycles at
 * a slower clock), so both are simulated against the same real arrival trace
 * and the max backlog / overflow tells whether the input FIFO ever spills.
 */
#define WIRE_PS_B  80            /* 100G: 1 byte = 80 ps                    */
#define QCAP (1u<<23)            /* ring of in-flight msgs (8M)             */

typedef struct {
    const char *name;
    uint64_t srv_done_ps;                       /* server busy-until        */
    struct { uint64_t done_ps; uint16_t len; } *q;
    uint32_t head, tail;
    uint64_t bytes, max_msgs, max_bytes, max_ts, overflow, hist[64];
    uint32_t fifo_depth;                         /* FIFO size to test (msgs) */
    uint64_t fifo_drops;                         /* msgs that would spill it */
    uint64_t max_wait_ps, max_wait_ts;           /* worst queuing delay (tail) */
} server_t;

static uint64_t wire_ps;                        /* shared wire cursor       */

static void srv_feed(server_t *s, uint64_t avail, uint64_t ts,
                     unsigned len, uint64_t srv_ps){
    while (s->head != s->tail && s->q[s->head & (QCAP-1)].done_ps <= avail) {
        s->bytes -= s->q[s->head & (QCAP-1)].len;
        s->head++;
    }
    /* queuing delay of this message = how far the server was already busy past
     * its arrival. This is the burst tail latency the message actually sees. */
    uint64_t start = s->srv_done_ps > avail ? s->srv_done_ps : avail;
    uint64_t wait  = start - avail;
    if (wait > s->max_wait_ps) { s->max_wait_ps = wait; s->max_wait_ts = ts; }
    s->srv_done_ps = start + srv_ps;
    if (s->tail - s->head < QCAP) {
        s->q[s->tail & (QCAP-1)].done_ps = s->srv_done_ps;
        s->q[s->tail & (QCAP-1)].len = (uint16_t)len;
        s->tail++;
        s->bytes += len;
    } else s->overflow++;
    uint64_t depth = s->tail - s->head;
    if (depth > s->max_msgs)  { s->max_msgs = depth; s->max_ts = ts; }
    if (s->bytes > s->max_bytes) s->max_bytes = s->bytes;
    if (depth > s->fifo_depth) s->fifo_drops++;  /* would a real FIFO spill? */
    int b = 0; while ((depth >> b) > 1) b++;
    s->hist[b]++;
}

/* splitter: 1 msg / cycle @ 322.265625 MHz. order table, two designs at the
 * core clock (~220 MHz): the iterative FSM (RD_LAT=2: non-'U' = 5 cy, 'U' = 9
 * cy) and the II=1 pipe (1 cy / msg for every type, FINDINGS 6.1). Feeding both
 * the same arrival trace measures exactly what II=1 buys under burst. */
#define SPLIT_PS   3103
#define CORE_PS    4545          /* 1/220 MHz in ps                          */
static server_t sv_split = { .name = "splitter (1 msg/cy @322MHz)",    .fifo_depth = 512 };
static server_t sv_otab  = { .name = "order table iterative (@220MHz)", .fifo_depth = 512 };
static server_t sv_pipe  = { .name = "order table II=1 pipe (@220MHz)", .fifo_depth = 512 };

static void backlog_feed(uint64_t ts, unsigned len, uint8_t type){
    uint64_t ts_ps = ts * 1000ull;
    wire_ps = (wire_ps > ts_ps ? wire_ps : ts_ps) + (len + 2) * WIRE_PS_B;
    uint64_t avail = wire_ps;
    srv_feed(&sv_split, avail, ts, len, SPLIT_PS);
    uint64_t ot_ps = (type == 'U' ? 9 : 5) * CORE_PS;  // RD_LAT=2: LOOK is 3 cy
    srv_feed(&sv_otab, avail, ts, len, ot_ps);
    srv_feed(&sv_pipe, avail, ts, len, CORE_PS);       // II=1: 1 cy / msg
}

/* ---------- live order table (linear probing, backward-shift delete) --- */
#define OBITS 26
#define OSIZE (1ull<<OBITS)
#define OMASK (OSIZE-1)
static struct { uint64_t ref; uint32_t shares; } *otab;
static uint64_t live, live_peak, live_peak_ts;
static uint64_t probe_hist[64];                 /* insert probe distance    */
static uint64_t o_miss;                         /* op on unknown ref        */

static inline uint64_t oh(uint64_t ref){ return ref & OMASK; }

static long ofind(uint64_t ref){
    uint64_t i = oh(ref);
    while (otab[i].ref) {
        if (otab[i].ref == ref) return (long)i;
        i = (i+1) & OMASK;
    }
    return -1;
}
static void oins(uint64_t ref, uint32_t sh, uint64_t ts){
    uint64_t i = oh(ref), d = 0;
    while (otab[i].ref) { i = (i+1) & OMASK; d++; }
    otab[i].ref = ref; otab[i].shares = sh;
    probe_hist[d < 63 ? d : 63]++;
    if (++live > live_peak) { live_peak = live; live_peak_ts = ts; }
}
static void odel_slot(uint64_t i){
    uint64_t j = i;
    for (;;) {
        otab[i].ref = 0;
        for (;;) {
            j = (j+1) & OMASK;
            if (!otab[j].ref) { live--; return; }
            uint64_t k = oh(otab[j].ref);
            if (i <= j ? (k <= i || k > j) : (k <= i && k > j)) break;
        }
        otab[i] = otab[j]; i = j;
    }
}
static void odel(uint64_t ref){
    long i = ofind(ref);
    if (i < 0) { o_miss++; return; }
    odel_slot((uint64_t)i);
}
static void odec(uint64_t ref, uint32_t sh){
    long i = ofind(ref);
    if (i < 0) { o_miss++; return; }
    if (otab[i].shares > sh) otab[i].shares -= sh;
    else odel_slot((uint64_t)i);
}

/* ---------- percentile over a histogram ---------- */
static uint64_t hist_pct(const uint32_t *h, uint64_t n, size_t cap, double p){
    uint64_t need = (uint64_t)(p * (double)n), acc = 0;
    for (size_t i = 0; i < cap; i++) { acc += h[i]; if (acc >= need && h[i]) return i; }
    return 0;
}

static void fmt_ts(uint64_t ns, char *buf){
    uint64_t s = ns / 1000000000ull;
    sprintf(buf, "%02" PRIu64 ":%02" PRIu64 ":%02" PRIu64 ".%09" PRIu64,
            s/3600, s/60%60, s%60, (uint64_t)(ns%1000000000ull));
}

int main(int argc, char **argv){
    if (argc < 2) { fprintf(stderr, "usage: %s <file[.gz]> [max_msgs]\n", argv[0]); return 1; }
    uint64_t max_msgs = argc > 2 ? strtoull(argv[2], 0, 10) : 0;

    FILE *f; int piped = 0;
    size_t alen = strlen(argv[1]);
    if (alen > 3 && !strcmp(argv[1]+alen-3, ".gz")) {
        char cmd[4200]; snprintf(cmd, sizeof cmd, "gzip -dc '%s'", argv[1]);
        f = popen(cmd, "r"); piped = 1;
    } else f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }

    for (int w = 0; w < NWIN; w++) win_hist[w] = calloc(WCAP, sizeof(uint32_t));
    otab = calloc(OSIZE, sizeof *otab);
    sv_split.q = malloc((size_t)QCAP * sizeof *sv_split.q);
    sv_otab.q  = malloc((size_t)QCAP * sizeof *sv_otab.q);
    sv_pipe.q  = malloc((size_t)QCAP * sizeof *sv_pipe.q);
    if (!otab) { fprintf(stderr, "otab alloc failed\n"); return 1; }

    uint8_t hdr[2], buf[64];
    uint64_t n = 0, total_bytes = 0, ts_min = ~0ull, ts_max = 0;
    uint64_t ooo_cnt = 0, ooo_max = 0, prev_ts = 0;

    while (fread(hdr, 1, 2, f) == 2) {
        unsigned len = be16(hdr);
        if (len == 0 || len > sizeof buf) { fprintf(stderr, "bad len %u @msg %" PRIu64 "\n", len, n); break; }
        if (fread(buf, 1, len, f) != len) { fprintf(stderr, "truncated @msg %" PRIu64 "\n", n); break; }
        uint8_t t = buf[0];
        uint64_t ts = be48(buf+5);
        n++; total_bytes += len;
        type_cnt[t]++; type_bytes[t] += len;
        if (ts < ts_min) ts_min = ts;
        if (ts > ts_max) ts_max = ts;
        if (ts < prev_ts) { ooo_cnt++; if (prev_ts-ts > ooo_max) ooo_max = prev_ts-ts; }
        prev_ts = ts;

        for (int w = 0; w < NWIN; w++) win_feed(w, ts);
        backlog_feed(ts, len, t);

        switch (t) {
        case 'A': case 'F': oins(be64(buf+11), be32(buf+20), ts); break;
        case 'E': case 'C': odec(be64(buf+11), be32(buf+19)); break;
        case 'X':           odec(be64(buf+11), be32(buf+19)); break;
        case 'D':           odel(be64(buf+11)); break;
        case 'U':           odel(be64(buf+11)); oins(be64(buf+19), be32(buf+27), ts); break;
        default: break;
        }
        if (max_msgs && n >= max_msgs) break;
        if ((n & 0xFFFFFF) == 0) fprintf(stderr, "... %" PRIu64 "M msgs\r", n>>20);
    }
    if (piped) pclose(f); else fclose(f);
    for (int w = 0; w < NWIN; w++) win_flush(w);

    char b1[40], b2[40];
    fmt_ts(ts_min, b1); fmt_ts(ts_max, b2);
    printf("== itch_hist: %s ==\n", argv[1]);
    printf("msgs %" PRIu64 "  bytes %" PRIu64 "  ts %s .. %s\n", n, total_bytes, b1, b2);
    printf("out-of-order ts: %" PRIu64 " (max regression %" PRIu64 " ns)\n\n", ooo_cnt, ooo_max);

    printf("-- type mix --\n");
    for (int t = 0; t < 256; t++) if (type_cnt[t])
        printf("  %c  cnt %12" PRIu64 "  (%6.3f%%)  len %2" PRIu64 "\n",
               t, type_cnt[t], 100.0*(double)type_cnt[t]/(double)n, type_bytes[t]/type_cnt[t]);
    printf("  avg msg len %.1f B\n\n", (double)total_bytes/(double)n);

    printf("-- msgs per window (active windows only) --\n");
    printf("  %-6s %12s %8s %8s %8s %8s %8s  peak@\n",
           "win", "active", "p50", "p99", "p99.9", "p99.99", "max");
    for (int w = 0; w < NWIN; w++) {
        char bt[40]; fmt_ts(win_max_ts[w], bt);
        printf("  %-6s %12" PRIu64 " %8" PRIu64 " %8" PRIu64 " %8" PRIu64 " %8" PRIu64 " %8" PRIu64 "  %s\n",
               win_name[w], win_active[w],
               hist_pct(win_hist[w], win_active[w], WCAP, 0.50),
               hist_pct(win_hist[w], win_active[w], WCAP, 0.99),
               hist_pct(win_hist[w], win_active[w], WCAP, 0.999),
               hist_pct(win_hist[w], win_active[w], WCAP, 0.9999),
               win_max[w], bt);
    }

    printf("\n-- FIFO backlog vs a real 100G arrival trace (drain = server rate) --\n");
    server_t *svs[3] = { &sv_split, &sv_otab, &sv_pipe };
    for (int k = 0; k < 3; k++) {
        server_t *s = svs[k];
        char bt[40], wt[40]; fmt_ts(s->max_ts, bt); fmt_ts(s->max_wait_ts, wt);
        printf("  %s:\n", s->name);
        printf("    max backlog: %" PRIu64 " msgs / %" PRIu64 " bytes  @ %s%s\n",
               s->max_msgs, s->max_bytes, bt,
               s->overflow ? "  (RING OVERFLOW: bigger QCAP)" : "");
        printf("    max queuing delay (burst tail): %.2f us  @ %s\n",
               s->max_wait_ps / 1e6, wt);
        printf("    would-spill a %u-msg FIFO: %" PRIu64 " msgs dropped\n",
               s->fifo_depth, s->fifo_drops);
    }

    fmt_ts(live_peak_ts, b1);
    printf("\n-- live orders (table 2^%d, hash = low bits of ref) --\n", OBITS);
    printf("  peak live %" PRIu64 "  @ %s   end-of-file live %" PRIu64 "   miss-ops %" PRIu64 "\n",
           live_peak, b1, live, o_miss);
    printf("  insert probe distance:\n");
    for (int d = 0; d < 64; d++) if (probe_hist[d])
        printf("    %2d%s %12" PRIu64 "\n", d, d==63?"+":" ", probe_hist[d]);
    return 0;
}
