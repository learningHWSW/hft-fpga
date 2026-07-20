/* sym_conc — per-symbol peak concurrent open orders, to size the step-4a
 * URAM-resident (symbol-filtered) order table.
 *
 * The full-market table needs HBM (8M+ entries, see data/FINDINGS.md); the
 * hot path instead FILTERS to a few tracked symbols so its order table fits
 * URAM. Sizing that filtered table needs the peak simultaneous live orders of
 * the symbols we track — not the all-symbol peak. This reports peak live per
 * stock-locate (mapped to its symbol via the 'R' directory), top-N by peak,
 * so we can choose SETS/WAYS that never overflow for the chosen symbols.
 *
 * Liveness model matches the order table: A/F insert, E/C/X decrement (remove
 * at qty<=0), D delete, U delete-old + insert-new.
 *
 * Usage: ./sym_conc <file[.gz]> [max_msgs]
 */
#define _DEFAULT_SOURCE
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static inline uint16_t be16(const uint8_t *p){ return (uint16_t)(p[0]<<8|p[1]); }
static inline uint32_t be32(const uint8_t *p){ return (uint32_t)p[0]<<24|(uint32_t)p[1]<<16|(uint32_t)p[2]<<8|p[3]; }
static inline uint64_t be64(const uint8_t *p){ uint64_t v=0; for(int i=0;i<8;i++) v=v<<8|p[i]; return v; }

/* exact ref -> {locate, qty} table, linear probing */
#define OBITS 26
#define OSIZE (1ull<<OBITS)
#define OMASK (OSIZE-1)
static uint64_t *oref;
static uint16_t *oloc;
static uint32_t *oqty;

static long ofind(uint64_t ref){
    uint64_t i=ref&OMASK;
    while(oref[i]){ if(oref[i]==ref) return (long)i; i=(i+1)&OMASK; }
    return -1;
}
#define NLOC 65536
static uint32_t live[NLOC], peak[NLOC];
static char     sname[NLOC][9];

static void oins(uint64_t ref, uint16_t loc, uint32_t q){
    uint64_t i=ref&OMASK;
    while(oref[i]) i=(i+1)&OMASK;
    oref[i]=ref; oloc[i]=loc; oqty[i]=q;
    if(++live[loc]>peak[loc]) peak[loc]=live[loc];
}
/* backward-shift delete keeps probing correct. Exactly one order is removed
 * (the target); the moves only relocate survivors, so decrement the target's
 * locate once — captured up front, NOT the reassigned slot locate. */
static void odel_slot(uint64_t i){
    uint16_t dloc=oloc[i]; uint64_t j=i;
    live[dloc]--;
    for(;;){
        oref[i]=0;
        for(;;){
            j=(j+1)&OMASK;
            if(!oref[j]) return;
            uint64_t k=oref[j]&OMASK;
            if(i<=j ? (k<=i||k>j) : (k<=i&&k>j)) break;
        }
        oref[i]=oref[j]; oloc[i]=oloc[j]; oqty[i]=oqty[j]; i=j;
    }
}
static void odel(uint64_t ref){ long i=ofind(ref); if(i>=0) odel_slot((uint64_t)i); }
static void odec(uint64_t ref, uint32_t q){
    long i=ofind(ref); if(i<0) return;
    if(oqty[i]>q) oqty[i]-=q; else odel_slot((uint64_t)i);
}

int main(int argc,char**argv){
    if(argc<2){ fprintf(stderr,"usage: %s <file[.gz]> [max_msgs]\n",argv[0]); return 1; }
    uint64_t max_msgs=argc>2?strtoull(argv[2],0,10):0;
    oref=calloc(OSIZE,8); oloc=calloc(OSIZE,2); oqty=calloc(OSIZE,4);
    if(!oref||!oloc||!oqty){ fprintf(stderr,"alloc fail\n"); return 1; }

    FILE*f; int piped=0; size_t al=strlen(argv[1]);
    if(al>3&&!strcmp(argv[1]+al-3,".gz")){ char cmd[4200]; snprintf(cmd,sizeof cmd,"gzip -dc '%s'",argv[1]); f=popen(cmd,"r"); piped=1; }
    else f=fopen(argv[1],"rb");
    if(!f){ perror(argv[1]); return 1; }

    uint8_t hdr[2],buf[64]; uint64_t n=0;
    while(fread(hdr,1,2,f)==2){
        unsigned len=be16(hdr);
        if(len==0||len>sizeof buf) break;
        if(fread(buf,1,len,f)!=len) break;
        uint8_t t=buf[0]; uint16_t loc=be16(buf+1); n++;
        switch(t){
        case 'R': memcpy(sname[loc],buf+11,8); break;  /* loc is 16-bit < NLOC */
        case 'A': case 'F': oins(be64(buf+11),loc,be32(buf+20)); break;
        case 'E': case 'C': odec(be64(buf+11),be32(buf+19)); break;
        case 'X':           odec(be64(buf+11),be32(buf+19)); break;
        case 'D':           odel(be64(buf+11)); break;
        case 'U': { long i=ofind(be64(buf+11)); uint16_t nl=(i>=0)?oloc[i]:loc;
                    odel(be64(buf+11)); oins(be64(buf+19),nl,be32(buf+27)); } break;
        default: break;
        }
        if(max_msgs&&n>=max_msgs) break;
        if((n&0xFFFFFF)==0) fprintf(stderr,"... %"PRIu64"M\r",n>>20);
    }
    if(piped) pclose(f); else fclose(f);

    /* top-32 locates by peak */
    int idx[NLOC], nact=0;
    for(int i=0;i<NLOC;i++) if(peak[i]) idx[nact++]=i;
    for(int a=0;a<nact;a++) for(int b=a+1;b<nact;b++) if(peak[idx[b]]>peak[idx[a]]){int t=idx[a];idx[a]=idx[b];idx[b]=t;}

    printf("== sym_conc: %s (%"PRIu64" msgs, %d symbols with orders) ==\n",argv[1],n,nact);
    printf("top symbols by peak concurrent open orders:\n");
    printf("  %-4s %-9s %10s\n","loc","symbol","peak");
    uint64_t cum=0;
    for(int a=0;a<nact&&a<32;a++){
        int i=idx[a]; cum+=peak[i];
        printf("  %-4d %-9.8s %10u   (cum top-%d = %"PRIu64")\n",i,sname[i],peak[i],a+1,cum);
    }
    return 0;
}
