/* zlib.c — the native half of Compress::Zlib::Native.
 *
 * DEFLATE (RFC 1951), the zlib wrapper (RFC 1950) and the gzip wrapper
 * (RFC 1952), in plain C against <rakupp/rakupp_ext.h> and nothing else. No
 * libz: that is the point of the distribution, not an omission. The same code
 * therefore works inside an `--exe` binary and in the WASM playground, where a
 * dlopen'd system library does not exist to be found.
 *
 * WHAT THIS IS NOT. It is not faster than zlib and it is not trying to be.
 * zlib is thirty years of hand-tuned C with assembly fast paths; this is a
 * clean-room implementation of a closed, small specification. Read the README's
 * measured table before assuming otherwise. What it offers is availability and
 * self-containment.
 *
 * TWIN: the engine's own src/DataZlib.{h,cpp}, planned as DATA-PLAN P4. When
 * that exists the two are separate implementations on purpose — see
 * NATIVE-MODULES-PLAN, "The architecture: independent C" — held together by
 * t/vectors/, which both read. A fix on either side is not finished until the
 * other has been checked.
 *
 * SECURITY. inflate() is the one function here that parses bytes somebody else
 * chose, so every read of the input is bounds-checked against `inlen` and every
 * back-reference is checked against how much output already exists. A stream
 * that lies about either is an error, never a read outside the buffer. The
 * output buffer growth is also capped, so a small input claiming a huge
 * expansion fails rather than exhausting memory.
 *
 * BYTES ACROSS THE ABI. This module is the reason ABI 3 has rk_blob. rk_str is
 * a Str constructor and DECODES what it is given as UTF-8, so raw compressed
 * bytes could not cross as themselves; the workaround was to send each byte as
 * the UTF-8 encoding of the codepoint of the same number and re-read it with
 * .encode('latin-1') on the Raku side, and that cost 15.8 ms of a 34 ms
 * two-megabyte inflate — 46%, all of it transport rather than codec.
 *
 * rk_blob is one call and no copy on the Raku side. The shim below is kept for
 * an older header, because the module is compiled at INSTALL time against
 * whatever Raku++ is on the machine; it will delete itself when ABI 3 is the
 * floor.
 */
#include <rakupp/rakupp_ext.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned char      u8;
typedef unsigned int       u32;
typedef unsigned long long u64;

/* An inflate output cap. 1 GB is far past anything a Raku program wants in one
 * Buf and far short of what a decompression bomb asks for. */
#define MAX_OUT ((size_t)1 << 30)

#define FMT_ZLIB 0
#define FMT_GZIP 1
#define FMT_RAW  2

/* ===================== a growable output buffer ========================== */

typedef struct { u8* p; size_t len, cap; } Out;

static int out_need(Out* o, size_t extra) {
    size_t want = o->len + extra;
    u8* np;
    if (want <= o->cap) return 1;
    if (want > MAX_OUT) return 0;
    while (o->cap < want) o->cap = o->cap ? o->cap * 2 : 4096;
    if (o->cap > MAX_OUT) o->cap = MAX_OUT;
    np = (u8*)realloc(o->p, o->cap);
    if (!np) return 0;
    o->p = np;
    return 1;
}
static int out_byte(Out* o, u8 b) {
    if (!out_need(o, 1)) return 0;
    o->p[o->len++] = b;
    return 1;
}
static int out_mem(Out* o, const u8* s, size_t n) {
    if (!out_need(o, n)) return 0;
    memcpy(o->p + o->len, s, n);
    o->len += n;
    return 1;
}

/* ===================== CRC-32 and Adler-32 =============================== */

static u32 CRC_TABLE[256];
static int crc_ready = 0;

static void crc_init(void) {
    u32 i, j, c;
    for (i = 0; i < 256; i++) {
        c = i;
        for (j = 0; j < 8; j++) c = (c & 1) ? 0xedb88320u ^ (c >> 1) : c >> 1;
        CRC_TABLE[i] = c;
    }
    crc_ready = 1;
}
static u32 crc32_of(u32 crc, const u8* p, size_t n) {
    size_t i;
    if (!crc_ready) crc_init();
    crc = ~crc;
    for (i = 0; i < n; i++) crc = CRC_TABLE[(crc ^ p[i]) & 0xff] ^ (crc >> 8);
    return ~crc;
}

/* 65521 is the largest prime below 65536, which is the whole trick: sums are
 * reduced only when they could overflow, every 5552 bytes. */
static u32 adler32_of(u32 adler, const u8* p, size_t n) {
    u32 s1 = adler & 0xffff, s2 = (adler >> 16) & 0xffff;
    while (n) {
        size_t k = n < 5552 ? n : 5552, i;
        for (i = 0; i < k; i++) { s1 += p[i]; s2 += s1; }
        s1 %= 65521u; s2 %= 65521u;
        p += k; n -= k;
    }
    return (s2 << 16) | s1;
}

/* ===================== DEFLATE tables (RFC 1951 §3.2.5) ================== */

static const unsigned short LEN_BASE[29] = {
    3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,
    163,195,227,258
};
static const unsigned char LEN_EXTRA[29] = {
    0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0
};
static const unsigned short DIST_BASE[30] = {
    1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,
    2049,3073,4097,6145,8193,12289,16385,24577
};
static const unsigned char DIST_EXTRA[30] = {
    0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13
};
/* The order the code-length code lengths are written in, §3.2.7. */
static const unsigned char CLEN_ORDER[19] = {
    16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15
};

/* ===================== inflate =========================================== */

/* Canonical Huffman as counts-plus-symbols, decoded one bit at a time. It is
 * the shape of Mark Adler's puff.c because that is the shape the specification
 * describes, and a table-driven decoder would be the optimisation to reach for
 * only after this is known correct. */
typedef struct {
    unsigned short count[16];
    unsigned short symbol[288];
} Huff;

typedef struct {
    const u8* in;
    size_t    inlen, pos;
    u32       bitbuf;
    int       bitcnt;
    Out       out;
    const char* err;
} Inf;

static int inf_bits(Inf* s, int need) {
    long val = (long)s->bitbuf;
    while (s->bitcnt < need) {
        if (s->pos >= s->inlen) { s->err = "truncated deflate stream"; return -1; }
        val |= (long)s->in[s->pos++] << s->bitcnt;
        s->bitcnt += 8;
    }
    s->bitbuf = (u32)(val >> need);
    s->bitcnt -= need;
    return (int)(val & ((1L << need) - 1));
}

static int inf_decode(Inf* s, const Huff* h) {
    int code = 0, first = 0, index = 0, len, b;
    for (len = 1; len <= 15; len++) {
        b = inf_bits(s, 1);
        if (b < 0) return -1;
        code |= b;
        {
            int count = h->count[len];
            if (code - count < first) return h->symbol[index + (code - first)];
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
    }
    s->err = "invalid Huffman code";
    return -1;
}

/* Build a canonical Huffman table from code lengths. Returns 0 on success; an
 * incomplete set is an error EXCEPT for the single-code case the specification
 * explicitly permits in the distance tree. */
static int inf_construct(Huff* h, const unsigned char* lengths, int n) {
    int symbol, len, left;
    unsigned short offs[16];

    for (len = 0; len < 16; len++) h->count[len] = 0;
    for (symbol = 0; symbol < n; symbol++) h->count[lengths[symbol]]++;
    if (h->count[0] == n) return 0;                 /* no codes at all */

    left = 1;
    for (len = 1; len < 16; len++) {
        left <<= 1;
        left -= h->count[len];
        if (left < 0) return -1;                    /* over-subscribed */
    }

    offs[1] = 0;
    for (len = 1; len < 15; len++) offs[len + 1] = (unsigned short)(offs[len] + h->count[len]);
    for (symbol = 0; symbol < n; symbol++)
        if (lengths[symbol]) h->symbol[offs[lengths[symbol]]++] = (unsigned short)symbol;

    return left;                                    /* >0 means incomplete */
}

static int inf_stored(Inf* s) {
    unsigned len, nlen;
    s->bitbuf = 0; s->bitcnt = 0;                   /* discard to a byte boundary */
    if (s->pos + 4 > s->inlen) { s->err = "truncated stored block"; return -1; }
    len  = s->in[s->pos] | ((unsigned)s->in[s->pos + 1] << 8);
    nlen = s->in[s->pos + 2] | ((unsigned)s->in[s->pos + 3] << 8);
    s->pos += 4;
    if (len != (~nlen & 0xffff)) { s->err = "stored block length check failed"; return -1; }
    if (s->pos + len > s->inlen) { s->err = "truncated stored block"; return -1; }
    if (!out_mem(&s->out, s->in + s->pos, len)) { s->err = "output too large"; return -1; }
    s->pos += len;
    return 0;
}

static int inf_codes(Inf* s, const Huff* lit, const Huff* dist) {
    for (;;) {
        int sym = inf_decode(s, lit);
        if (sym < 0) return -1;
        if (sym < 256) {
            if (!out_byte(&s->out, (u8)sym)) { s->err = "output too large"; return -1; }
        }
        else if (sym == 256) return 0;
        else {
            int len, dsym, e;
            size_t d, i;
            sym -= 257;
            if (sym >= 29) { s->err = "invalid length code"; return -1; }
            e = inf_bits(s, LEN_EXTRA[sym]);
            if (e < 0) return -1;
            len = LEN_BASE[sym] + e;

            dsym = inf_decode(s, dist);
            if (dsym < 0) return -1;
            if (dsym >= 30) { s->err = "invalid distance code"; return -1; }
            e = inf_bits(s, DIST_EXTRA[dsym]);
            if (e < 0) return -1;
            d = (size_t)DIST_BASE[dsym] + (size_t)e;

            /* The bound that matters: a distance larger than the output so far
             * would read before the start of the buffer. */
            if (d > s->out.len) { s->err = "distance points before the start of the stream"; return -1; }
            if (!out_need(&s->out, (size_t)len)) { s->err = "output too large"; return -1; }
            /* Byte at a time on purpose: overlapping copies are legal and are
             * how a run is encoded (distance 1, length 100 = 100 equal bytes). */
            for (i = 0; i < (size_t)len; i++) {
                s->out.p[s->out.len] = s->out.p[s->out.len - d];
                s->out.len++;
            }
        }
    }
}

static void inf_fixed(Huff* lit, Huff* dist) {
    unsigned char lengths[288];
    int i;
    for (i = 0;   i < 144; i++) lengths[i] = 8;
    for (i = 144; i < 256; i++) lengths[i] = 9;
    for (i = 256; i < 280; i++) lengths[i] = 7;
    for (i = 280; i < 288; i++) lengths[i] = 8;
    inf_construct(lit, lengths, 288);
    for (i = 0; i < 30; i++) lengths[i] = 5;
    inf_construct(dist, lengths, 30);
}

static int inf_dynamic(Inf* s) {
    int nlen, ndist, ncode, index, err;
    unsigned char lengths[288 + 30];
    Huff lit, dist, clen;

    nlen  = inf_bits(s, 5); if (nlen  < 0) return -1; nlen  += 257;
    ndist = inf_bits(s, 5); if (ndist < 0) return -1; ndist += 1;
    ncode = inf_bits(s, 4); if (ncode < 0) return -1; ncode += 4;
    if (nlen > 286 || ndist > 30) { s->err = "too many codes in dynamic block"; return -1; }

    for (index = 0; index < ncode; index++) {
        int v = inf_bits(s, 3);
        if (v < 0) return -1;
        lengths[CLEN_ORDER[index]] = (unsigned char)v;
    }
    for (; index < 19; index++) lengths[CLEN_ORDER[index]] = 0;

    if (inf_construct(&clen, lengths, 19) != 0) {
        s->err = "invalid code-length code"; return -1;
    }

    index = 0;
    while (index < nlen + ndist) {
        int sym = inf_decode(s, &clen), len, count;
        if (sym < 0) return -1;
        if (sym < 16) { lengths[index++] = (unsigned char)sym; continue; }
        if (sym == 16) {
            if (index == 0) { s->err = "repeat with no previous length"; return -1; }
            len = lengths[index - 1];
            count = inf_bits(s, 2); if (count < 0) return -1;
            count += 3;
        }
        else if (sym == 17) {
            len = 0;
            count = inf_bits(s, 3); if (count < 0) return -1;
            count += 3;
        }
        else {
            len = 0;
            count = inf_bits(s, 7); if (count < 0) return -1;
            count += 11;
        }
        if (index + count > nlen + ndist) { s->err = "too many code lengths"; return -1; }
        while (count--) lengths[index++] = (unsigned char)len;
    }
    if (lengths[256] == 0) { s->err = "no end-of-block code"; return -1; }

    err = inf_construct(&lit, lengths, nlen);
    if (err && (err < 0 || nlen != lit.count[0] + lit.count[1])) {
        s->err = "invalid literal/length code"; return -1;
    }
    err = inf_construct(&dist, lengths + nlen, ndist);
    /* An incomplete distance tree with exactly one code is legal — it is what a
     * block of literals only looks like. */
    if (err && (err < 0 || ndist != dist.count[0] + dist.count[1])) {
        s->err = "invalid distance code"; return -1;
    }
    return inf_codes(s, &lit, &dist);
}

/* Raw DEFLATE. On success out.p/out.len hold the result and the caller owns
 * them; on failure s->err names what went wrong and out.p is freed. */
static int inflate_raw(Inf* s) {
    int last, type;
    Huff lit, dist;
    do {
        last = inf_bits(s, 1); if (last < 0) return -1;
        type = inf_bits(s, 2); if (type < 0) return -1;
        switch (type) {
            case 0: if (inf_stored(s)) return -1; break;
            case 1: inf_fixed(&lit, &dist);
                    if (inf_codes(s, &lit, &dist)) return -1; break;
            case 2: if (inf_dynamic(s)) return -1; break;
            default: s->err = "invalid block type"; return -1;
        }
    } while (!last);
    return 0;
}

/* ===================== deflate =========================================== */

/* LZ77 with a hash of three-byte prefixes, then FIXED Huffman. Dynamic Huffman
 * would buy roughly another five to ten per cent on text and costs the whole
 * code-length-code machinery on the encoding side; it is the obvious next step
 * and deliberately not in the first cut. The README states the ratio this
 * produces rather than implying zlib's. */

#define WBITS   15
#define WSIZE   (1 << WBITS)              /* 32 KB, the format's maximum */
#define HBITS   15
#define HSIZE   (1 << HBITS)
#define MINMATCH 3
#define MAXMATCH 258

typedef struct {
    Out  out;
    u32  bitbuf;
    int  bitcnt;
} BitW;

static int bw_bits(BitW* w, u32 value, int n) {
    w->bitbuf |= value << w->bitcnt;
    w->bitcnt += n;
    while (w->bitcnt >= 8) {
        if (!out_byte(&w->out, (u8)(w->bitbuf & 0xff))) return 0;
        w->bitbuf >>= 8;
        w->bitcnt -= 8;
    }
    return 1;
}
/* Huffman codes are written most significant bit first into a stream that is
 * otherwise least-significant-bit first (RFC 1951 §3.1.1). Reversing here is
 * the whole of that rule. */
static int bw_huff(BitW* w, u32 code, int len) {
    u32 rev = 0;
    int i;
    for (i = 0; i < len; i++) { rev = (rev << 1) | (code & 1); code >>= 1; }
    return bw_bits(w, rev, len);
}
static int bw_flush(BitW* w) {
    if (w->bitcnt > 0) {
        if (!out_byte(&w->out, (u8)(w->bitbuf & 0xff))) return 0;
        w->bitbuf = 0; w->bitcnt = 0;
    }
    return 1;
}

static int len_code(int len, int* extra, int* nextra) {
    int i;
    for (i = 28; i >= 0; i--) {
        if (len >= LEN_BASE[i]) { *extra = len - LEN_BASE[i]; *nextra = LEN_EXTRA[i]; return 257 + i; }
    }
    *extra = 0; *nextra = 0; return 257;
}
static int dist_code(int d, int* extra, int* nextra) {
    int i;
    for (i = 29; i >= 0; i--) {
        if (d >= DIST_BASE[i]) { *extra = d - DIST_BASE[i]; *nextra = DIST_EXTRA[i]; return i; }
    }
    *extra = 0; *nextra = 0; return 0;
}

/* A stored block costs five bytes of overhead per 65535 and never expands by
 * more than that, so incompressible input has a floor. */
static int deflate_stored(Out* o, const u8* in, size_t n) {
    size_t off = 0;
    do {
        size_t chunk = n - off > 65535 ? 65535 : n - off;
        int last = (off + chunk == n);
        u8 hdr[5];
        hdr[0] = (u8)(last ? 1 : 0);           /* BFINAL, BTYPE=00, byte-aligned */
        hdr[1] = (u8)(chunk & 0xff);
        hdr[2] = (u8)(chunk >> 8);
        hdr[3] = (u8)(~chunk & 0xff);
        hdr[4] = (u8)((~chunk >> 8) & 0xff);
        if (!out_mem(o, hdr, 5)) return 0;
        if (chunk && !out_mem(o, in + off, chunk)) return 0;
        off += chunk;
    } while (off < n);
    return 1;
}
/* ---- the token buffer ---------------------------------------------------
 *
 * LZ77 first, encoding second. Emitting Huffman codes straight out of the
 * matcher — which the first cut of this file did — forces the FIXED code,
 * because a dynamic block has to state its code lengths before its data and
 * the lengths are not known until the data has been seen. Buffering one
 * block's worth of tokens costs eight bytes each and buys the choice.
 *
 * `dist` is 0 for a literal, in which case `val` is the byte; otherwise `val`
 * is the match length. */
typedef struct {
    unsigned* val;
    unsigned* dist;
    size_t    n, cap;
} Toks;

#define TOK_BLOCK 32768         /* tokens per block: bounded memory, and long
                                 * enough that the ~40-byte tree description is
                                 * noise against the data it describes */

static int tok_push(Toks* t, unsigned val, unsigned dist) {
    if (t->n == t->cap) {
        size_t nc = t->cap ? t->cap * 2 : 4096;
        unsigned* a = (unsigned*)realloc(t->val,  nc * sizeof(unsigned));
        unsigned* b;
        if (!a) return 0;
        t->val = a;
        b = (unsigned*)realloc(t->dist, nc * sizeof(unsigned));
        if (!b) return 0;
        t->dist = b;
        t->cap = nc;
    }
    t->val[t->n]  = val;
    t->dist[t->n] = dist;
    t->n++;
    return 1;
}

/* ---- Huffman code construction for the ENCODER --------------------------
 *
 * Optimal code lengths under DEFLATE's 15-bit ceiling. The tree is built with
 * an O(n^2) two-smallest search rather than a heap: n is at most 286 and this
 * runs once per 32,768 tokens, so the constant factor is invisible and the
 * simpler code is worth more than the asymptote.
 *
 * When the tree comes out deeper than the ceiling — which needs a
 * Fibonacci-like frequency distribution and effectively never happens on real
 * data, but must still be correct when it does — every non-zero frequency is
 * halved and the tree rebuilt. Flattening the distribution shortens the
 * deepest path, the loop terminates because the frequencies fall to 1, and the
 * result is a valid, very slightly sub-optimal code. */

#define MAXSYMS 288

static void huff_lengths(const unsigned* freq_in, int n, int maxbits, unsigned char* lens) {
    unsigned freq[MAXSYMS];
    int parent[2 * MAXSYMS], left[2 * MAXSYMS], right[2 * MAXSYMS];
    unsigned nodefreq[2 * MAXSYMS];
    int alive[2 * MAXSYMS];
    int i, nn, used;

    for (i = 0; i < n; i++) freq[i] = freq_in[i];

    for (;;) {
        int a, b, k, deepest = 0;
        used = 0;
        for (i = 0; i < n; i++) lens[i] = 0;
        for (i = 0; i < n; i++) {
            if (!freq[i]) continue;
            nodefreq[used] = freq[i]; left[used] = -1; right[used] = -1;
            parent[used] = -1; alive[used] = 1;
            used++;
        }
        nn = used;
        if (nn == 0) return;                    /* nothing to code */
        if (nn == 1) {                          /* one symbol still needs a bit */
            for (i = 0; i < n; i++) if (freq[i]) { lens[i] = 1; return; }
        }

        while (1) {
            a = -1; b = -1;
            for (k = 0; k < used; k++) {
                if (!alive[k]) continue;
                if (a < 0 || nodefreq[k] < nodefreq[a]) { b = a; a = k; }
                else if (b < 0 || nodefreq[k] < nodefreq[b]) b = k;
            }
            if (b < 0) break;                   /* one node left: the root */
            nodefreq[used] = nodefreq[a] + nodefreq[b];
            left[used] = a; right[used] = b; parent[used] = -1; alive[used] = 1;
            parent[a] = used; parent[b] = used;
            alive[a] = 0; alive[b] = 0;
            used++;
        }

        /* Depth of every leaf, walking up to the root. */
        {
            int leaf = 0;
            for (i = 0; i < n; i++) {
                int d, node;
                if (!freq[i]) continue;
                node = leaf++;
                d = 0;
                while (parent[node] >= 0) { d++; node = parent[node]; }
                lens[i] = (unsigned char)d;
                if (d > deepest) deepest = d;
            }
        }

        if (deepest <= maxbits) return;
        for (i = 0; i < n; i++) if (freq[i]) freq[i] = (freq[i] + 1) / 2;
    }
}

/* Canonical codes from lengths: RFC 1951 §3.2.2, verbatim. */
static void huff_codes(const unsigned char* lens, int n, unsigned short* codes) {
    unsigned short bl_count[16], next_code[16];
    int i, bits;
    unsigned short code = 0;
    for (i = 0; i < 16; i++) bl_count[i] = 0;
    for (i = 0; i < n; i++) bl_count[lens[i]]++;
    bl_count[0] = 0;
    for (bits = 1; bits < 16; bits++) {
        code = (unsigned short)((code + bl_count[bits - 1]) << 1);
        next_code[bits] = code;
    }
    for (i = 0; i < n; i++) codes[i] = lens[i] ? next_code[lens[i]]++ : 0;
}

/* ---- turning one block of tokens into bits ------------------------------ */

typedef struct {
    unsigned char llen[MAXSYMS];  unsigned short lcode[MAXSYMS];
    unsigned char dlen[30];       unsigned short dcode[30];
    unsigned char cllen[19];      unsigned short clcode[19];
    unsigned char rle[MAXSYMS + 30];      /* the RLE'd length sequence */
    unsigned char rlex[MAXSYMS + 30];     /* its extra-bit payloads */
    int           rlen;
    int           nlit, ndist, ncl;
} Trees;

/* Run-length encode the concatenated literal and distance code lengths, as
 * §3.2.7 requires: 16 repeats the previous length 3-6 times, 17 runs 3-10
 * zeros, 18 runs 11-138. */
static void build_rle(Trees* t) {
    unsigned char all[MAXSYMS + 30];
    int i, total = 0, prev = -1;
    for (i = 0; i < t->nlit; i++)  all[total++] = t->llen[i];
    for (i = 0; i < t->ndist; i++) all[total++] = t->dlen[i];

    t->rlen = 0;
    i = 0;
    while (i < total) {
        int len = all[i], run = 1;
        while (i + run < total && all[i + run] == len) run++;
        if (len == 0) {
            while (run >= 11) {
                int k = run > 138 ? 138 : run;
                t->rle[t->rlen] = 18; t->rlex[t->rlen++] = (unsigned char)(k - 11);
                run -= k; i += k;
            }
            while (run >= 3) {
                int k = run > 10 ? 10 : run;
                t->rle[t->rlen] = 17; t->rlex[t->rlen++] = (unsigned char)(k - 3);
                run -= k; i += k;
            }
            while (run--) { t->rle[t->rlen] = 0; t->rlex[t->rlen++] = 0; i++; }
        }
        else {
            /* The first of a run is always written literally; only repeats of
             * an already-emitted length may use code 16. */
            t->rle[t->rlen] = (unsigned char)len; t->rlex[t->rlen++] = 0;
            run--; i++;
            while (run >= 3) {
                int k = run > 6 ? 6 : run;
                t->rle[t->rlen] = 16; t->rlex[t->rlen++] = (unsigned char)(k - 3);
                run -= k; i += k;
            }
            while (run--) { t->rle[t->rlen] = (unsigned char)len; t->rlex[t->rlen++] = 0; i++; }
        }
        (void)prev;
    }
}

static void build_trees(Trees* t, const Toks* k) {
    unsigned lfreq[MAXSYMS], dfreq[30], clfreq[19];
    size_t i;
    int j, extra, nextra;

    for (j = 0; j < MAXSYMS; j++) lfreq[j] = 0;
    for (j = 0; j < 30; j++) dfreq[j] = 0;
    for (j = 0; j < 19; j++) clfreq[j] = 0;

    for (i = 0; i < k->n; i++) {
        if (k->dist[i] == 0) lfreq[k->val[i]]++;
        else {
            lfreq[len_code((int)k->val[i], &extra, &nextra)]++;
            dfreq[dist_code((int)k->dist[i], &extra, &nextra)]++;
        }
    }
    lfreq[256]++;                                   /* end of block */

    huff_lengths(lfreq, MAXSYMS, 15, t->llen);
    huff_lengths(dfreq, 30, 15, t->dlen);

    /* At least one distance code must exist even when the block is all
     * literals; a tree of one code of one bit is the conventional spelling. */
    {
        int any = 0;
        for (j = 0; j < 30; j++) if (t->dlen[j]) any = 1;
        if (!any) t->dlen[0] = 1;
    }

    t->nlit = MAXSYMS - 2;                          /* 286 */
    while (t->nlit > 257 && !t->llen[t->nlit - 1]) t->nlit--;
    t->ndist = 30;
    while (t->ndist > 1 && !t->dlen[t->ndist - 1]) t->ndist--;

    huff_codes(t->llen, MAXSYMS, t->lcode);
    huff_codes(t->dlen, 30, t->dcode);

    build_rle(t);
    for (j = 0; j < t->rlen; j++) clfreq[t->rle[j]]++;
    huff_lengths(clfreq, 19, 7, t->cllen);
    huff_codes(t->cllen, 19, t->clcode);

    t->ncl = 19;
    while (t->ncl > 4 && !t->cllen[CLEN_ORDER[t->ncl - 1]]) t->ncl--;
}

/* Exact bit cost of a block under each encoding, so the choice is a comparison
 * rather than a guess. */
static size_t cost_fixed(const Toks* k) {
    size_t bits = 3 + 7;                            /* header + end-of-block */
    size_t i;
    int extra, nextra;
    for (i = 0; i < k->n; i++) {
        if (k->dist[i] == 0) bits += k->val[i] < 144 ? 8 : 9;
        else {
            int lc = len_code((int)k->val[i], &extra, &nextra);
            bits += (lc < 280 ? 7 : 8) + nextra;
            dist_code((int)k->dist[i], &extra, &nextra);
            bits += 5 + nextra;
        }
    }
    return bits;
}
static size_t cost_dynamic(const Trees* t, const Toks* k) {
    size_t bits = 3 + 5 + 5 + 4 + (size_t)t->ncl * 3;
    size_t i;
    int j, extra, nextra;
    for (j = 0; j < t->rlen; j++) {
        bits += t->cllen[t->rle[j]];
        if (t->rle[j] == 16) bits += 2;
        else if (t->rle[j] == 17) bits += 3;
        else if (t->rle[j] == 18) bits += 7;
    }
    for (i = 0; i < k->n; i++) {
        if (k->dist[i] == 0) bits += t->llen[k->val[i]];
        else {
            int lc = len_code((int)k->val[i], &extra, &nextra);
            int dc = dist_code((int)k->dist[i], &extra, &nextra);
            bits += t->llen[lc] + LEN_EXTRA[lc - 257] + t->dlen[dc] + DIST_EXTRA[dc];
        }
    }
    bits += t->llen[256];
    return bits;
}

static int emit_tokens(BitW* w, const Toks* k,
                       const unsigned char* llen, const unsigned short* lcode,
                       const unsigned char* dlen, const unsigned short* dcode) {
    size_t i;
    int extra, nextra;
    for (i = 0; i < k->n; i++) {
        if (k->dist[i] == 0) {
            if (!bw_huff(w, lcode[k->val[i]], llen[k->val[i]])) return 0;
        }
        else {
            int lc = len_code((int)k->val[i], &extra, &nextra);
            if (!bw_huff(w, lcode[lc], llen[lc])) return 0;
            if (nextra && !bw_bits(w, (u32)extra, nextra)) return 0;
            {
                int dc = dist_code((int)k->dist[i], &extra, &nextra);
                if (!bw_huff(w, dcode[dc], dlen[dc])) return 0;
                if (nextra && !bw_bits(w, (u32)extra, nextra)) return 0;
            }
        }
    }
    return bw_huff(w, lcode[256], llen[256]);
}

/* The fixed code as lengths and codes, so one emit path serves both trees. */
static void fixed_trees(unsigned char* llen, unsigned short* lcode,
                        unsigned char* dlen, unsigned short* dcode) {
    int i;
    for (i = 0;   i < 144; i++) llen[i] = 8;
    for (i = 144; i < 256; i++) llen[i] = 9;
    for (i = 256; i < 280; i++) llen[i] = 7;
    for (i = 280; i < 288; i++) llen[i] = 8;
    huff_codes(llen, 288, lcode);
    for (i = 0; i < 30; i++) dlen[i] = 5;
    huff_codes(dlen, 30, dcode);
}

/* One block: stored, fixed or dynamic, whichever is smallest. `last` sets
 * BFINAL. `raw`/`rawlen` are the bytes this block covers, needed only for the
 * stored form. */
static int emit_block(BitW* w, const Toks* k, const u8* raw, size_t rawlen, int last) {
    Trees t;
    size_t cf, cd, cs;
    unsigned char flen[288], fdlen[30];
    unsigned short fcode[288], fdcode[30];
    int j;

    build_trees(&t, k);
    cf = cost_fixed(k);
    cd = cost_dynamic(&t, k);
    /* A stored block restarts on a byte boundary, so it also pays for the bits
     * already in the writer plus the five bytes of header. */
    cs = 3 + 7 + (size_t)rawlen * 8 + 32;

    if (cs <= cf && cs <= cd) {
        if (!bw_bits(w, (u32)(last ? 1 : 0), 1)) return 0;
        if (!bw_bits(w, 0, 2)) return 0;
        if (!bw_flush(w)) return 0;
        {
            u8 hdr[4];
            hdr[0] = (u8)(rawlen & 0xff);        hdr[1] = (u8)((rawlen >> 8) & 0xff);
            hdr[2] = (u8)(~rawlen & 0xff);       hdr[3] = (u8)((~rawlen >> 8) & 0xff);
            if (!out_mem(&w->out, hdr, 4)) return 0;
            if (rawlen && !out_mem(&w->out, raw, rawlen)) return 0;
        }
        return 1;
    }

    if (!bw_bits(w, (u32)(last ? 1 : 0), 1)) return 0;

    if (cf <= cd) {
        if (!bw_bits(w, 1, 2)) return 0;
        fixed_trees(flen, fcode, fdlen, fdcode);
        return emit_tokens(w, k, flen, fcode, fdlen, fdcode);
    }

    if (!bw_bits(w, 2, 2)) return 0;
    if (!bw_bits(w, (u32)(t.nlit - 257), 5)) return 0;
    if (!bw_bits(w, (u32)(t.ndist - 1), 5)) return 0;
    if (!bw_bits(w, (u32)(t.ncl - 4), 4)) return 0;
    for (j = 0; j < t.ncl; j++)
        if (!bw_bits(w, t.cllen[CLEN_ORDER[j]], 3)) return 0;
    for (j = 0; j < t.rlen; j++) {
        int s = t.rle[j];
        if (!bw_huff(w, t.clcode[s], t.cllen[s])) return 0;
        if      (s == 16) { if (!bw_bits(w, t.rlex[j], 2)) return 0; }
        else if (s == 17) { if (!bw_bits(w, t.rlex[j], 3)) return 0; }
        else if (s == 18) { if (!bw_bits(w, t.rlex[j], 7)) return 0; }
    }
    return emit_tokens(w, k, t.llen, t.lcode, t.dlen, t.dcode);
}

/* level: 0 stores, 1-9 pick how hard the matcher looks. */
static int deflate_data(Out* o, const u8* in, size_t n, int level) {
    BitW w;
    Toks k;
    int* head = 0;
    int* prev = 0;
    size_t i, block_start = 0;
    int max_chain = level <= 0 ? 0 : (level < 4 ? 16 : (level < 7 ? 128 : 1024));
    int good_enough = level < 7 ? 32 : MAXMATCH;
    int ok = 1;

    memset(&w, 0, sizeof w);
    memset(&k, 0, sizeof k);
    w.out = *o;

    head = (int*)malloc(sizeof(int) * HSIZE);
    prev = (int*)malloc(sizeof(int) * (n ? n : 1));
    if (!head || !prev) { ok = 0; goto done; }
    for (i = 0; i < HSIZE; i++) head[i] = -1;

    i = 0;
    while (i < n) {
        int best_len = 0;
        size_t best_dist = 0;

        if (max_chain && i + MINMATCH <= n) {
            u32 h = ((u32)in[i] << 10) ^ ((u32)in[i+1] << 5) ^ (u32)in[i+2];
            int chain = max_chain;
            int cand;
            h &= HSIZE - 1;
            cand = head[h];
            while (cand >= 0 && chain--) {
                size_t d = i - (size_t)cand;
                size_t kk = 0, maxk;
                if (d == 0 || d > WSIZE) break;
                maxk = n - i;
                if (maxk > MAXMATCH) maxk = MAXMATCH;
                while (kk < maxk && in[cand + kk] == in[i + kk]) kk++;
                if ((int)kk > best_len) { best_len = (int)kk; best_dist = d; }
                if (best_len >= good_enough) break;
                cand = prev[cand];
            }
            prev[i] = head[h];
            head[h] = (int)i;
        }

        if (best_len >= MINMATCH) {
            size_t j;
            if (!tok_push(&k, (unsigned)best_len, (unsigned)best_dist)) { ok = 0; goto done; }
            /* Every position inside a match still has to enter the hash chain,
             * or the next search misses everything the match covered. */
            for (j = 1; j < (size_t)best_len; j++) {
                size_t q = i + j;
                if (max_chain && q + MINMATCH <= n) {
                    u32 h2 = ((u32)in[q] << 10) ^ ((u32)in[q+1] << 5) ^ (u32)in[q+2];
                    h2 &= HSIZE - 1;
                    prev[q] = head[h2];
                    head[h2] = (int)q;
                }
            }
            i += (size_t)best_len;
        }
        else {
            if (!tok_push(&k, in[i], 0)) { ok = 0; goto done; }
            i++;
        }

        if (k.n >= TOK_BLOCK && i < n) {
            if (!emit_block(&w, &k, in + block_start, i - block_start, 0)) { ok = 0; goto done; }
            block_start = i;
            k.n = 0;
        }
    }

    if (!emit_block(&w, &k, in + block_start, n - block_start, 1)) { ok = 0; goto done; }
    if (!bw_flush(&w)) { ok = 0; goto done; }

done:
    free(head); free(prev); free(k.val); free(k.dist);
    *o = w.out;
    return ok;
}

/* ===================== the wrappers ====================================== */

static int put_zlib_header(Out* o, int level) {
    unsigned cmf = 0x78;                    /* CM=8 deflate, CINFO=7 (32 KB) */
    unsigned flevel = level <= 1 ? 0 : (level < 6 ? 1 : (level == 6 ? 2 : 3));
    unsigned flg = flevel << 6;
    flg |= 31 - ((cmf * 256 + flg) % 31);   /* FCHECK, §2.2 */
    return out_byte(o, (u8)cmf) && out_byte(o, (u8)flg);
}
static int put_be32(Out* o, u32 v) {
    return out_byte(o, (u8)(v >> 24)) && out_byte(o, (u8)(v >> 16))
        && out_byte(o, (u8)(v >> 8))  && out_byte(o, (u8)v);
}
static int put_le32(Out* o, u32 v) {
    return out_byte(o, (u8)v) && out_byte(o, (u8)(v >> 8))
        && out_byte(o, (u8)(v >> 16)) && out_byte(o, (u8)(v >> 24));
}
static int put_gzip_header(Out* o, int level) {
    static const u8 h[10] = { 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff };
    u8 hdr[10];
    memcpy(hdr, h, 10);
    hdr[8] = (u8)(level >= 9 ? 2 : (level <= 1 ? 4 : 0));   /* XFL */
    /* MTIME stays zero: a compressor that stamped the clock would make its own
     * output unreproducible, which is a worse default than an absent date. */
    return out_mem(o, hdr, 10);
}

/* Skip a gzip header, returning the offset of the deflate data or 0 on error. */
static size_t gzip_header_len(const u8* p, size_t n, const char** err) {
    size_t i = 10;
    u8 flg;
    if (n < 18) { *err = "truncated gzip stream"; return 0; }
    if (p[0] != 0x1f || p[1] != 0x8b) { *err = "not a gzip stream"; return 0; }
    if (p[2] != 8) { *err = "unsupported gzip compression method"; return 0; }
    flg = p[3];
    if (flg & 0xe0) { *err = "reserved gzip flags set"; return 0; }
    if (flg & 4) {                                  /* FEXTRA */
        size_t xlen;
        if (i + 2 > n) { *err = "truncated gzip extra field"; return 0; }
        xlen = p[i] | ((size_t)p[i + 1] << 8);
        i += 2 + xlen;
        if (i > n) { *err = "truncated gzip extra field"; return 0; }
    }
    if (flg & 8)  { while (i < n && p[i]) i++; if (i >= n) { *err = "truncated gzip name"; return 0; } i++; }
    if (flg & 16) { while (i < n && p[i]) i++; if (i >= n) { *err = "truncated gzip comment"; return 0; } i++; }
    if (flg & 2)  { i += 2; if (i > n) { *err = "truncated gzip header CRC"; return 0; } }
    if (i >= n) { *err = "truncated gzip stream"; return 0; }
    return i;
}

/* ===================== the ABI shim ====================================== */

/* See the note at the top. On ABI 3 this is the whole function; below it is the
 * shim for an older header, which doubles the bytes on this side and costs a
 * full encode on the other. */
#if RAKUPP_EXT_ABI >= 3
static RkValue emit_bytes(RkCtx c, const u8* d, size_t n) {
    return rk_blob(c, d, n);
}
#else
static RkValue emit_bytes(RkCtx c, const u8* d, size_t n) {
    size_t i, j = 0;
    char* buf = (char*)malloc(n * 2 + 1);
    RkValue v;
    if (!buf) { rk_die(c, "Compress::Zlib::Native: out of memory"); return 0; }
    for (i = 0; i < n; i++) {
        if (d[i] < 0x80) buf[j++] = (char)d[i];
        else { buf[j++] = (char)(0xc0 | (d[i] >> 6)); buf[j++] = (char)(0x80 | (d[i] & 0x3f)); }
    }
    v = rk_str(c, buf, j);
    free(buf);
    return v;
}
#endif

/* (data, level, format) */
static RkValue ext_compress(RkCtx c) {
    size_t n = 0;
    const u8* in = (const u8*)rk_str_get(c, rk_arg(c, 0), &n);
    int level = (int)rk_int_get(c, rk_arg(c, 1));
    int fmt   = (int)rk_int_get(c, rk_arg(c, 2));
    Out o;
    size_t body_start;
    RkValue r;

    memset(&o, 0, sizeof o);
    if (level < 0) level = 6;
    if (level > 9) level = 9;

    if (fmt == FMT_ZLIB && !put_zlib_header(&o, level)) goto oom;
    if (fmt == FMT_GZIP && !put_gzip_header(&o, level)) goto oom;
    body_start = o.len;

    if (level == 0) { if (!deflate_stored(&o, in, n)) goto oom; }
    else {
        if (!deflate_data(&o, in, n, level)) goto oom;
        /* If the Huffman pass came out larger than storing it — which happens
         * on already-compressed input — throw it away and store instead. The
         * format allows both and the smaller one is the right answer. */
        if (o.len - body_start > n + 5 + (n / 65535) * 5) {
            o.len = body_start;
            if (!deflate_stored(&o, in, n)) goto oom;
        }
    }

    if (fmt == FMT_ZLIB && !put_be32(&o, adler32_of(1, in, n))) goto oom;
    if (fmt == FMT_GZIP) {
        if (!put_le32(&o, crc32_of(0, in, n))) goto oom;
        if (!put_le32(&o, (u32)(n & 0xffffffffu))) goto oom;
    }

    r = emit_bytes(c, o.p, o.len);
    free(o.p);
    return r;
oom:
    free(o.p);
    rk_die(c, "Compress::Zlib::Native: out of memory while compressing");
    return 0;
}

/* (data, format) */
static RkValue ext_uncompress(RkCtx c) {
    size_t n = 0;
    const u8* in = (const u8*)rk_str_get(c, rk_arg(c, 0), &n);
    int fmt = (int)rk_int_get(c, rk_arg(c, 1));
    Inf s;
    size_t start = 0, tail = 0;
    const char* err = 0;
    RkValue r;
    char msg[128];

    memset(&s, 0, sizeof s);

    if (fmt == FMT_ZLIB) {
        if (n < 6) { err = "truncated zlib stream"; goto fail; }
        if ((in[0] & 0x0f) != 8) { err = "unsupported zlib compression method"; goto fail; }
        if (((unsigned)in[0] * 256 + in[1]) % 31) { err = "zlib header check failed"; goto fail; }
        if (in[1] & 0x20) { err = "a preset dictionary is not supported"; goto fail; }
        start = 2; tail = 4;
    }
    else if (fmt == FMT_GZIP) {
        start = gzip_header_len(in, n, &err);
        if (!start) goto fail;
        tail = 8;
    }
    if (n < start + tail) { err = "truncated stream"; goto fail; }

    s.in = in + start;
    s.inlen = n - start - tail;
    if (inflate_raw(&s)) { err = s.err ? s.err : "invalid deflate stream"; free(s.out.p); goto fail; }

    /* The checksums are the reason a wrapper exists; skipping them would make
     * this a decompressor that cannot tell you it produced the wrong bytes. */
    if (fmt == FMT_ZLIB) {
        const u8* t = in + n - 4;
        u32 want = ((u32)t[0] << 24) | ((u32)t[1] << 16) | ((u32)t[2] << 8) | t[3];
        if (adler32_of(1, s.out.p, s.out.len) != want) {
            free(s.out.p); err = "zlib checksum mismatch"; goto fail;
        }
    }
    else if (fmt == FMT_GZIP) {
        const u8* t = in + n - 8;
        u32 want = (u32)t[0] | ((u32)t[1] << 8) | ((u32)t[2] << 16) | ((u32)t[3] << 24);
        u32 isize = (u32)t[4] | ((u32)t[5] << 8) | ((u32)t[6] << 16) | ((u32)t[7] << 24);
        if (crc32_of(0, s.out.p, s.out.len) != want) {
            free(s.out.p); err = "gzip CRC mismatch"; goto fail;
        }
        if ((u32)(s.out.len & 0xffffffffu) != isize) {
            free(s.out.p); err = "gzip length mismatch"; goto fail;
        }
    }

    r = emit_bytes(c, s.out.p, s.out.len);
    free(s.out.p);
    return r;
fail:
    snprintf(msg, sizeof msg, "Compress::Zlib::Native: %s", err ? err : "invalid stream");
    rk_die(c, msg);
    return 0;
}

/* (data, init) */
static RkValue ext_crc32(RkCtx c) {
    size_t n = 0;
    const u8* p = (const u8*)rk_str_get(c, rk_arg(c, 0), &n);
    u32 init = (u32)rk_int_get(c, rk_arg(c, 1));
    return rk_int(c, (long long)crc32_of(init, p, n));
}
static RkValue ext_adler32(RkCtx c) {
    size_t n = 0;
    const u8* p = (const u8*)rk_str_get(c, rk_arg(c, 0), &n);
    u32 init = (u32)rk_int_get(c, rk_arg(c, 1));
    if (!init) init = 1;                      /* Adler-32 starts at 1, not 0 */
    return rk_int(c, (long long)adler32_of(init, p, n));
}

static const RkSubDef subs[] = {
    {"zlib-compress-native",   ext_compress},
    {"zlib-uncompress-native", ext_uncompress},
    {"zlib-crc32-native",      ext_crc32},
    {"zlib-adler32-native",    ext_adler32},
    {0, 0}
};
static const RkModule mod = { RAKUPP_EXT_ABI, "Compress::Zlib::Native", subs };

RAKUPP_EXT_EXPORT const RkModule* rakupp_ext_init(unsigned host_abi) {
#if RAKUPP_EXT_ABI >= 3
    /* Compiled against a header that has rk_blob, so this object CALLS it. A
     * host without it would resolve nothing and abort at the first call under
     * lazy binding — the exact failure the handshake exists to turn into a
     * sentence. Refusing here makes the module fall back instead, which is a
     * supported state and merely slower. */
    return host_abi >= 3u ? &mod : 0;
#else
    /* ABI 1 is enough for this build: nothing in it builds a container or
     * re-enters Raku, and the bytes go back through the latin-1 shim. */
    return host_abi >= 1u ? &mod : 0;
#endif
}
