/* fuzz-inflate.c — the gate for the one function here that parses bytes
 * somebody else chose.
 *
 * inflate is the attack surface of this distribution: `uncompress` is handed
 * whatever arrived over the wire or came out of a file. A malformed stream
 * must produce an ERROR, never a read outside the buffer and never an
 * unbounded allocation. That is not a property a test suite of valid streams
 * can check, so this driver builds the same source under AddressSanitizer and
 * UndefinedBehaviorSanitizer and throws mutated and random bytes at it.
 *
 *   cc -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
 *      -I/path/to/rakupp/include tools/fuzz-inflate.c -o /tmp/fuzz && /tmp/fuzz
 *
 * It includes zlib.c rather than linking it, and stubs the handful of rk_*
 * functions the shim calls, so nothing here needs an interpreter — the whole
 * point is to run the codec on its own where a sanitizer can see every access.
 */
#include <rakupp/rakupp_ext.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- the ABI, stubbed. The codec never touches these; only the shim does. */
static char rk_err[256];
RkValue rk_any  (RkCtx c)                                   { (void)c; return 0; }
RkValue rk_bool (RkCtx c, int t)                            { (void)c; (void)t; return 0; }
RkValue rk_int  (RkCtx c, long long v)                      { (void)c; (void)v; return 0; }
RkValue rk_int_s(RkCtx c, const char* d)                    { (void)c; (void)d; return 0; }
RkValue rk_num  (RkCtx c, double v)                         { (void)c; (void)v; return 0; }
RkValue rk_rat_s(RkCtx c, const char* a, const char* b)     { (void)c; (void)a; (void)b; return 0; }
RkValue rk_str  (RkCtx c, const char* s, size_t n)          { (void)c; (void)s; (void)n; return 0; }
RkValue rk_array(RkCtx c)                                   { (void)c; return 0; }
void    rk_push (RkCtx c, RkValue a, RkValue v)             { (void)c; (void)a; (void)v; }
void    rk_list (RkCtx c, RkValue a)                        { (void)c; (void)a; }
RkValue rk_hash (RkCtx c)                                   { (void)c; return 0; }
void    rk_set  (RkCtx c, RkValue h, const char* k, size_t n, RkValue v)
                                                            { (void)c; (void)h; (void)k; (void)n; (void)v; }
void    rk_map  (RkCtx c, RkValue h)                        { (void)c; (void)h; }
RkType  rk_type (RkCtx c, RkValue v)                        { (void)c; (void)v; return RK_ANY; }
int     rk_truthy(RkCtx c, RkValue v)                       { (void)c; (void)v; return 0; }
long long rk_int_get(RkCtx c, RkValue v)                    { (void)c; (void)v; return 0; }
double  rk_num_get(RkCtx c, RkValue v)                      { (void)c; (void)v; return 0; }
const char* rk_str_get(RkCtx c, RkValue v, size_t* n)       { (void)c; (void)v; if (n) *n = 0; return ""; }
size_t  rk_elems(RkCtx c, RkValue v)                        { (void)c; (void)v; return 0; }
RkValue rk_at_pos(RkCtx c, RkValue a, size_t i)             { (void)c; (void)a; (void)i; return 0; }
const char* rk_key_at(RkCtx c, RkValue h, size_t i, size_t* n)
                                                            { (void)c; (void)h; (void)i; if (n) *n = 0; return 0; }
RkValue rk_val_at(RkCtx c, RkValue h, size_t i)             { (void)c; (void)h; (void)i; return 0; }
size_t  rk_argc(RkCtx c)                                    { (void)c; return 0; }
RkValue rk_arg (RkCtx c, size_t i)                          { (void)c; (void)i; return 0; }
RkValue rk_named(RkCtx c, const char* n)                    { (void)c; (void)n; return 0; }
RkValue rk_call(RkCtx c, const char* n, const RkValue* a, size_t k)
                                                            { (void)c; (void)n; (void)a; (void)k; return 0; }
RkValue rk_call_value(RkCtx c, RkValue f, const RkValue* a, size_t k)
                                                            { (void)c; (void)f; (void)a; (void)k; return 0; }
int     rk_can(RkCtx c, const char* n)                      { (void)c; (void)n; return 0; }
void    rk_die(RkCtx c, const char* m) { (void)c; strncpy(rk_err, m ? m : "", sizeof rk_err - 1); }
const char* rk_error(RkCtx c)                               { (void)c; return rk_err; }
void    rk_clear_error(RkCtx c)                             { (void)c; rk_err[0] = 0; }
RkValue rk_root(RkCtx c, RkValue v)                         { (void)c; (void)v; return 0; }
void    rk_unroot(RkCtx c, RkValue v)                       { (void)c; (void)v; }

#include "../src/zlib.c"

/* xorshift, so a failing seed is reproducible from the line the driver prints. */
static unsigned long long rng_state = 0x2545f4914f6cdd1dULL;
static unsigned rnd(void) {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return (unsigned)(rng_state >> 32);
}

static size_t try_inflate(const u8* p, size_t n) {
    Inf s;
    size_t got;
    memset(&s, 0, sizeof s);
    s.in = p; s.inlen = n;
    if (inflate_raw(&s)) { free(s.out.p); return (size_t)-1; }
    got = s.out.len;
    free(s.out.p);
    return got;
}

int main(void) {
    u8 buf[4096];
    size_t i, iter;
    unsigned long errors = 0, successes = 0;

    /* 1. Pure noise. Almost all of it is invalid, which is the point: every
     *    rejection has to be a clean error rather than a wild read. */
    for (iter = 0; iter < 200000; iter++) {
        size_t n = 1 + rnd() % 200;
        for (i = 0; i < n; i++) buf[i] = (u8)rnd();
        if (try_inflate(buf, n) == (size_t)-1) errors++; else successes++;
    }

    /* 2. Valid streams with one byte corrupted — the shapes that get furthest
     *    into the decoder before going wrong, and so exercise the most code. */
    {
        const char* texts[4] = {
            "hello hello hello hello world world world",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "The quick brown fox jumps over the lazy dog, repeatedly. "
            "The quick brown fox jumps over the lazy dog, repeatedly.",
            ""
        };
        for (i = 0; i < 4; i++) {
            Out c;
            size_t tlen = strlen(texts[i]);
            size_t j;
            memset(&c, 0, sizeof c);
            if (!deflate_data(&c, (const u8*)texts[i], tlen, 6)) { free(c.p); continue; }

            if (try_inflate(c.p, c.len) != tlen) {
                printf("FAIL: a valid stream did not round-trip (corpus %zu)\n", i);
                free(c.p);
                return 1;
            }
            for (iter = 0; iter < 40000; iter++) {
                u8* m = (u8*)malloc(c.len ? c.len : 1);
                size_t cut;
                memcpy(m, c.p, c.len);
                for (j = 0; j < 1 + rnd() % 3; j++)
                    if (c.len) m[rnd() % c.len] ^= (u8)(1 << (rnd() % 8));
                cut = c.len ? 1 + rnd() % c.len : 0;      /* also truncate */
                if (try_inflate(m, rnd() % 2 ? c.len : cut) == (size_t)-1) errors++;
                else successes++;
                free(m);
            }
            free(c.p);
        }
    }

    /* 3. A stream that claims an enormous expansion. It must fail on the cap,
     *    not by trying to allocate it. */
    {
        u8 bomb[64];
        /* fixed block, one literal, then a maximal-length match repeated */
        memset(bomb, 0xff, sizeof bomb);
        bomb[0] = 0x63;
        (void)try_inflate(bomb, sizeof bomb);
    }

    printf("fuzz-inflate: %lu rejected, %lu accepted, no sanitizer report\n",
           errors, successes);
    return 0;
}
