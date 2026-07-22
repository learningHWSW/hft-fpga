/* otable_sim — pick the step-4a order-table design point from real data.
 *
 * The hardware order table is a d-way set-associative hash on order_ref:
 *   set = hash(ref) & (SETS-1);  a set holds WAYS {ref, qty} slots.
 * Insert (A/F, U-new) drops into any free slot of the set; if all WAYS are
 * occupied the insert OVERFLOWS (order untracked — the real HW would drop it).
 * Delete (D, U-old) / decrement (E/C/X) scan the set's WAYS slots for the ref.
 *
 * This replays the capture through SEVERAL (SETS, WAYS, hash) configs at once
 * (one gz pass) and reports, per config, the metric that decides the design:
 * how many inserts overflow, and the worst set occupancy seen. Zero overflow
 * at the smallest capacity / fewest ways wins.
 *
 * Two hashes are compared: raw low bits of ref (order_ref is ~monotonic, so
 * low bits round-robin across sets) vs a multiply-shift mix (does mixing help
 * or is raw good enough — a real "measure, don't guess" question).
 *
 * With loc=<N> it filters inserts to one stock-locate (the symbol-filtered
 * URAM table of step 4a) and reports the URAM-scale configs — used to confirm
 * the deployed (sets,ways) never overflows for the tracked symbol.
 *
 * Usage: ./otable_sim <file[.gz]> [max_msgs] [loc=<N>]
 */
#define _DEFAULT_SOURCE
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static inline uint16_t be16(const uint8_t *p){ return (uint16_t)(p[0]<<8 | p[1]); }
static inline uint32_t be32(const uint8_t *p){ return (uint32_t)p[0]<<24|(uint32_t)p[1]<<16|(uint32_t)p[2]<<8|p[3]; }
static inline uint64_t be64(const uint8_t *p){ uint64_t v=0; for(int i=0;i<8;i++) v=v<<8|p[i]; return v; }

typedef struct {
    const char *name;
    int   sbits;        /* log2(SETS) */
    int   ways;
    int   mix;          /* 0 = raw low bits, 1 = multiply-shift */
    uint64_t sets;      /* = 1<<sbits */
    uint64_t *ref;      /* [sets*ways], 0 = empty */
    uint32_t *qty;      /* [sets*ways] */
    uint32_t *occ;      /* [sets] current occupancy */
    uint64_t overflow, inserts, deletes, decs, miss;
    uint32_t max_occ;
    uint64_t live, live_peak;
} cfg_t;

/* hash modes. The multiply-shift (1) is the best mixer but a 64x64 multiply
 * becomes a multi-DSP cascade that lands on the critical path in hardware
 * (4.6 ns, step5-board/README.md). Modes 2 and 3 are the cheap alternatives:
 * 2 is pure XOR folding (a couple of LUT levels, no DSP at all), 3 folds to
 * 32 bits first so only a 32x32 multiply is needed. Whether they mix well
 * enough for a single filtered symbol is a measurement, not an opinion. */
enum { H_RAW = 0, H_MUL64 = 1, H_XORFOLD = 2, H_MUL32 = 3 };

static inline uint64_t set_of(const cfg_t *c, uint64_t ref){
    uint64_t h;
    switch (c->mix) {
    case H_MUL64:   h = (ref * 0x9E3779B97F4A7C15ull) >> (64 - c->sbits); break;
    case H_XORFOLD: h = ref ^ (ref >> 16) ^ (ref >> 32) ^ (ref >> 48);    break;
    case H_MUL32: { uint32_t f = (uint32_t)(ref ^ (ref >> 32));
                    h = ((uint64_t)f * 0x9E3779B9u) >> (32 - c->sbits);   break; }
    default:        h = ref;                                             break;
    }
    return h & (c->sets - 1);
}

static void ins(cfg_t *c, uint64_t ref, uint32_t q){
    uint64_t s = set_of(c, ref);
    uint64_t base = s * c->ways;
    for (int w = 0; w < c->ways; w++)
        if (c->ref[base+w] == 0) {              /* free slot */
            c->ref[base+w] = ref; c->qty[base+w] = q;
            if (++c->occ[s] > c->max_occ) c->max_occ = c->occ[s];
            c->inserts++;
            if (++c->live > c->live_peak) c->live_peak = c->live;
            return;
        }
    c->overflow++;                              /* set full */
}
static int find(cfg_t *c, uint64_t ref, uint64_t *idx){
    uint64_t s = set_of(c, ref), base = s * c->ways;
    for (int w = 0; w < c->ways; w++)
        if (c->ref[base+w] == ref) { *idx = base+w; return (int)s; }
    return -1;
}
static int del(cfg_t *c, uint64_t ref){    /* returns 1 if the ref was present */
    uint64_t i; int s = find(c, ref, &i);
    if (s < 0) { c->miss++; return 0; }
    c->ref[i] = 0; c->occ[s]--; c->deletes++; c->live--; return 1;
}
static void dec(cfg_t *c, uint64_t ref, uint32_t q){
    uint64_t i; int s = find(c, ref, &i);
    if (s < 0) { c->miss++; return; }
    c->decs++;
    if (c->qty[i] > q) c->qty[i] -= q;
    else { c->ref[i] = 0; c->occ[s]--; c->live--; }
}

int main(int argc, char **argv){
    if (argc < 2){ fprintf(stderr,"usage: %s <file[.gz]> [max_msgs] [loc=<N>]\n",argv[0]); return 1; }
    uint64_t max_msgs = 0; int filt_loc = -1;
    for (int a = 2; a < argc; a++){
        if (!strncmp(argv[a],"loc=",4)) filt_loc = atoi(argv[a]+4);
        else max_msgs = strtoull(argv[a],0,10);
    }

    /* all-symbol configs (HBM scale): two capacity tiers, ways sweep, x2 hash */
    static cfg_t big[] = {
        {"20b x4  raw ",20,4,0},{"21b x2  raw ",21,2,0},{"19b x8  raw ",19,8,0},
        {"21b x4  raw ",21,4,0},{"22b x2  raw ",22,2,0},{"20b x8  raw ",20,8,0},
        {"20b x4  mix ",20,4,1},{"21b x2  mix ",21,2,1},
        {"21b x4  raw ",21,4,0},{"22b x2  raw ",22,2,0},
    };
    /* symbol-filtered configs (URAM scale) for the step-4a table.
     * raw low bits cluster for a single symbol (its refs are a subset of the
     * global monotonic sequence), so compare against the multiply-shift mix. */
    /* The hash question is settled (4.3: xorfold ties multiply at zero
     * overflow), so this sweep asks the remaining one: how SMALL can the table
     * be and still never overflow? It matters because the synthesized design
     * has been running at 2^9 x 8 while simulation runs at 2^16 x 8, and the
     * real answer has to be instantiated as URAM rather than inferred.
     * Capacity is what counts, so sets and ways are traded against each other
     * at equal and lower totals. */
    static cfg_t small[] = {
        {"16b x8  xorfld",16,8,H_XORFOLD},   /* current default: known 0 */
        {"15b x8  xorfld",15,8,H_XORFOLD},   /* 262K slots */
        {"14b x8  xorfld",14,8,H_XORFOLD},   /* 131K */
        {"13b x8  xorfld",13,8,H_XORFOLD},   /*  65K -- my first guess */
        {"12b x8  xorfld",12,8,H_XORFOLD},   /*  33K */
        {"14b x16 xorfld",14,16,H_XORFOLD},  /* 262K, deeper sets */
        {"13b x16 xorfld",13,16,H_XORFOLD},  /* 131K */
        {"12b x16 xorfld",12,16,H_XORFOLD},  /*  65K, same as 13bx8 */
    };
    cfg_t *cfgs = (filt_loc >= 0) ? small : big;
    int NC = (filt_loc >= 0) ? (int)(sizeof small/sizeof small[0])
                             : (int)(sizeof big/sizeof big[0]);
    for (int i=0;i<NC;i++){
        cfg_t *c=&cfgs[i]; c->sets=1ull<<c->sbits;
        c->ref=calloc(c->sets*c->ways,sizeof(uint64_t));
        c->qty=calloc(c->sets*c->ways,sizeof(uint32_t));
        c->occ=calloc(c->sets,sizeof(uint32_t));
        if(!c->ref||!c->qty||!c->occ){ fprintf(stderr,"alloc fail %s\n",c->name); return 1; }
    }

    FILE *f; int piped=0; size_t al=strlen(argv[1]);
    if (al>3 && !strcmp(argv[1]+al-3,".gz")){ char cmd[4200]; snprintf(cmd,sizeof cmd,"gzip -dc '%s'",argv[1]); f=popen(cmd,"r"); piped=1; }
    else f=fopen(argv[1],"rb");
    if(!f){ perror(argv[1]); return 1; }

    uint8_t hdr[2], buf[64];
    uint64_t n=0;
    while (fread(hdr,1,2,f)==2){
        unsigned len=be16(hdr);
        if(len==0||len>sizeof buf) break;
        if(fread(buf,1,len,f)!=len) break;
        uint8_t t=buf[0]; uint16_t loc=(uint16_t)(buf[1]<<8|buf[2]); n++;
        uint64_t ref; uint32_t q;
        switch(t){
        case 'A': case 'F': if(filt_loc>=0 && loc!=filt_loc) break;
                            ref=be64(buf+11); q=be32(buf+20); for(int i=0;i<NC;i++) ins(&cfgs[i],ref,q); break;
        case 'E': case 'C': ref=be64(buf+11); q=be32(buf+19); for(int i=0;i<NC;i++) dec(&cfgs[i],ref,q); break;
        case 'X':           ref=be64(buf+11); q=be32(buf+19); for(int i=0;i<NC;i++) dec(&cfgs[i],ref,q); break;
        case 'D':           ref=be64(buf+11);                 for(int i=0;i<NC;i++) del(&cfgs[i],ref);   break;
        case 'U':           ref=be64(buf+11); { uint64_t nr=be64(buf+19); uint32_t nq=be32(buf+27);
                            /* insert new only if old was tracked (matches HW) */
                            for(int i=0;i<NC;i++){ if(del(&cfgs[i],ref)) ins(&cfgs[i],nr,nq); } } break;
        default: break;
        }
        if(max_msgs&&n>=max_msgs) break;
        if((n&0xFFFFFF)==0) fprintf(stderr,"... %"PRIu64"M msgs\r",n>>20);
    }
    if(piped) pclose(f); else fclose(f);

    printf("== otable_sim: %s  (%"PRIu64" msgs) ==\n", argv[1], n);
    printf("peak live orders (all symbols): %"PRIu64"\n\n", cfgs[0].live_peak);
    printf("%-14s %8s %6s %8s %10s %8s %9s %7s\n",
           "config","cap","load%","maxset","overflow","ovf-ppm","live_pk","miss");
    for(int i=0;i<NC;i++){
        cfg_t *c=&cfgs[i];
        uint64_t cap=c->sets*c->ways;
        double load=100.0*(double)c->live_peak/(double)cap;
        double ppm=1e6*(double)c->overflow/(double)(c->inserts+c->overflow);
        printf("%-14s %8"PRIu64" %6.1f %8"PRIu32" %10"PRIu64" %8.2f %9"PRIu64" %7"PRIu64"\n",
               c->name, cap, load, c->max_occ, c->overflow, ppm, c->live_peak, c->miss);
    }
    printf("\nnote: overflow=0 means that (sets,ways,hash) never exceeds WAYS in any set.\n");
    return 0;
}
