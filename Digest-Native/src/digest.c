/* digest.c — the native half of Digest::Native.
 *
 * MD5 (RFC 1321), SHA-1 and SHA-224/256/384/512 (FIPS 180-4), HMAC (RFC 2104),
 * in plain C against <rakupp/rakupp_ext.h> and nothing else. Same bargain as
 * JSON::Native's json.c and CSV::Native's csv.c: the extension never sees the
 * interpreter's value layout, so it keeps working across compiler releases and
 * the module versions on its own schedule.
 *
 * TWIN: the engine's own digest code, planned as src/Digest.{h,cpp} in
 * raku++ (DATA-PLAN P3). The two implementations are DELIBERATELY separate —
 * see NATIVE-MODULES-PLAN, "The architecture: independent C". They are held
 * together by one thing and it is not shared source: t/vectors/digest.vec in
 * this distribution is the same file the engine's regression suite reads. A
 * fix on either side is not finished until the other has been checked against
 * it. Deliberate differences, if any ever exist, are listed in both headers.
 * There are none today.
 *
 * BYTES ACROSS THE ABI. Inbound needs nothing special: rk_str_get on a Buf or
 * blob8 hands back its RAW BYTES, and on a Str the UTF-8 encoding of its text.
 * Both are exactly the bytes to hash, so one accessor covers every input this
 * module takes.
 *
 * Outbound needed rk_blob, which is why ABI 3 exists. rk_str is a Str
 * constructor and DECODES what it is given as UTF-8, so a raw digest handed to
 * it came back eleven characters long with 0xd2 0x4f collapsed into one. Built
 * against an older header this file still works, by sending each byte as the
 * UTF-8 encoding of the codepoint of the same number and letting the Raku half
 * read it back with .encode('latin-1') — see emit_bytes below. That shim costs
 * a digest nothing and will delete itself when ABI 3 is the floor.
 *
 * No secret-dependent branches and no table lookups indexed by key material:
 * these are the message-schedule algorithms, whose control flow depends only
 * on the LENGTH of the input. That is a property to keep, not to rediscover.
 */
#include <rakupp/rakupp_ext.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned char      u8;
typedef unsigned int       u32;
typedef unsigned long long u64;

#define ROTL32(x, n) (((x) << (n)) | ((x) >> (32 - (n))))
#define ROTR32(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define ROTR64(x, n) (((x) >> (n)) | ((x) << (64 - (n))))

/* Explicit byte loads and stores throughout: the specifications are written in
 * bytes, and a host that happens to share the algorithm's endianness is a
 * portability accident, not a licence to memcpy a word. */
static u32 ld32be(const u8* p) {
    return ((u32)p[0] << 24) | ((u32)p[1] << 16) | ((u32)p[2] << 8) | (u32)p[3];
}
static u32 ld32le(const u8* p) {
    return ((u32)p[3] << 24) | ((u32)p[2] << 16) | ((u32)p[1] << 8) | (u32)p[0];
}
static u64 ld64be(const u8* p) {
    return ((u64)ld32be(p) << 32) | (u64)ld32be(p + 4);
}
static void st32be(u8* p, u32 v) {
    p[0] = (u8)(v >> 24); p[1] = (u8)(v >> 16); p[2] = (u8)(v >> 8); p[3] = (u8)v;
}
static void st32le(u8* p, u32 v) {
    p[0] = (u8)v; p[1] = (u8)(v >> 8); p[2] = (u8)(v >> 16); p[3] = (u8)(v >> 24);
}
static void st64be(u8* p, u64 v) {
    st32be(p, (u32)(v >> 32)); st32be(p + 4, (u32)v);
}

/* ===================== MD5 (RFC 1321) ==================================== */

typedef struct { u32 h[4]; u64 len; u8 buf[64]; size_t n; } Md5;

static const u32 MD5_K[64] = {
    0xd76aa478u,0xe8c7b756u,0x242070dbu,0xc1bdceeeu,0xf57c0fafu,0x4787c62au,
    0xa8304613u,0xfd469501u,0x698098d8u,0x8b44f7afu,0xffff5bb1u,0x895cd7beu,
    0x6b901122u,0xfd987193u,0xa679438eu,0x49b40821u,0xf61e2562u,0xc040b340u,
    0x265e5a51u,0xe9b6c7aau,0xd62f105du,0x02441453u,0xd8a1e681u,0xe7d3fbc8u,
    0x21e1cde6u,0xc33707d6u,0xf4d50d87u,0x455a14edu,0xa9e3e905u,0xfcefa3f8u,
    0x676f02d9u,0x8d2a4c8au,0xfffa3942u,0x8771f681u,0x6d9d6122u,0xfde5380cu,
    0xa4beea44u,0x4bdecfa9u,0xf6bb4b60u,0xbebfbc70u,0x289b7ec6u,0xeaa127fau,
    0xd4ef3085u,0x04881d05u,0xd9d4d039u,0xe6db99e5u,0x1fa27cf8u,0xc4ac5665u,
    0xf4292244u,0x432aff97u,0xab9423a7u,0xfc93a039u,0x655b59c3u,0x8f0ccc92u,
    0xffeff47du,0x85845dd1u,0x6fa87e4fu,0xfe2ce6e0u,0xa3014314u,0x4e0811a1u,
    0xf7537e82u,0xbd3af235u,0x2ad7d2bbu,0xeb86d391u
};
static const unsigned MD5_S[64] = {
    7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
    5, 9,14,20, 5, 9,14,20, 5, 9,14,20, 5, 9,14,20,
    4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
    6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21
};

/* The four rounds are four LOOPS rather than one loop with a branch chain, and
 * that shape is worth keeping. A single loop asking `i < 16 … else if …` at
 * every one of the 64 steps gives the compiler nothing to unroll, and measured
 * against the split form it cost about half the throughput. Same reasoning
 * drives the rolling 16-word schedules in the SHA functions below. */
static void md5_block(Md5* c, const u8* p) {
    u32 m[16], a = c->h[0], b = c->h[1], d = c->h[2], e = c->h[3], f;
    unsigned i;
    for (i = 0; i < 16; i++) m[i] = ld32le(p + 4 * i);

/* do/while(0): every one of these is several statements, and a bare brace-less
 * macro as a loop body would run only its first line per iteration. */
#define MD5_STEP(F, G) do { \
    f = (F) + a + MD5_K[i] + m[(G)]; \
    a = e; e = d; d = b; b += ROTL32(f, MD5_S[i]); \
} while (0)

    for (i =  0; i < 16; i++) MD5_STEP((b & d) | (~b & e),  i);
    for (i = 16; i < 32; i++) MD5_STEP((e & b) | (~e & d),  (5 * i + 1) & 15);
    for (i = 32; i < 48; i++) MD5_STEP(b ^ d ^ e,           (3 * i + 5) & 15);
    for (i = 48; i < 64; i++) MD5_STEP(d ^ (b | (u32)~e),   (7 * i) & 15);
#undef MD5_STEP

    c->h[0] += a; c->h[1] += b; c->h[2] += d; c->h[3] += e;
}
static void md5_init(void* v) {
    Md5* c = (Md5*)v;
    c->h[0] = 0x67452301u; c->h[1] = 0xefcdab89u;
    c->h[2] = 0x98badcfeu; c->h[3] = 0x10325476u;
    c->len = 0; c->n = 0;
}
static void md5_update(void* v, const u8* p, size_t n) {
    Md5* c = (Md5*)v;
    c->len += (u64)n;
    if (c->n) {
        size_t want = 64 - c->n, take = n < want ? n : want;
        memcpy(c->buf + c->n, p, take);
        c->n += take; p += take; n -= take;
        if (c->n < 64) return;
        md5_block(c, c->buf); c->n = 0;
    }
    while (n >= 64) { md5_block(c, p); p += 64; n -= 64; }
    if (n) { memcpy(c->buf, p, n); c->n = n; }
}
static void md5_final(void* v, u8* out) {
    Md5* c = (Md5*)v;
    u64 bits = c->len * 8;
    u8 pad = 0x80;
    md5_update(c, &pad, 1);
    while (c->n != 56) { u8 z = 0; md5_update(c, &z, 1); }
    st32le(c->buf + 56, (u32)bits);
    st32le(c->buf + 60, (u32)(bits >> 32));
    md5_block(c, c->buf);
    st32le(out,      c->h[0]); st32le(out + 4,  c->h[1]);
    st32le(out + 8,  c->h[2]); st32le(out + 12, c->h[3]);
}

/* ===================== SHA-1 (FIPS 180-4) ================================ */

typedef struct { u32 h[5]; u64 len; u8 buf[64]; size_t n; } Sha1;

/* Sixteen words of schedule, not eighty. w[i] depends only on w[i-3], w[i-8],
 * w[i-14] and w[i-16], so a window of sixteen holds everything a round can ask
 * for — and it fits in registers where the full array does not. That plus the
 * four unrollable loops is the whole difference between this and the obvious
 * transcription of FIPS 180-4. */
static void sha1_block(Sha1* c, const u8* p) {
    u32 w[16], a, b, d, e, f;
    unsigned i;
    for (i = 0; i < 16; i++) w[i] = ld32be(p + 4 * i);
    a = c->h[0]; b = c->h[1]; d = c->h[2]; e = c->h[3]; f = c->h[4];

    /* i-3 ≡ i+13, i-8 ≡ i+8, i-14 ≡ i+2, i-16 ≡ i  (mod 16) */
#define SHA1_W(i) (w[(i)&15] = ROTL32(w[((i)+13)&15] ^ w[((i)+8)&15] \
                                    ^ w[((i)+ 2)&15] ^ w[(i)    &15], 1))

    /* Five rounds at a time, with the working variables PERMUTED through the
     * macro arguments rather than shuffled at the end of each round.
     *
     * One SHA-1 round is `e += rol(a,5) + F(b,c,d) + K + W; b = rol(b,30)`
     * followed by renaming (a,b,c,d,e) to (e,a,b,c,d). Written as a loop that
     * rename costs five register-to-register moves per round. Unrolled by the
     * length of the rotation it costs nothing at all: five is exactly the cycle
     * length, so after a group of five the names are back where they started
     * and there is nothing left to shuffle. The variables here are spelled
     * a b d e f, because c is not available in C.
     *
     * do/while(0) again — these are multi-statement macros standing as loop
     * bodies, and without it only the first round of each group would run. */
#define SHA1_R(FN, K, S, v, w_, x, y, z) \
    z += FN(w_, x, y) + (K) + (S) + ROTL32(v, 5); w_ = ROTL32(w_, 30);

#define SHA1_F0(w_, x, y) (((w_) & ((x) ^ (y))) ^ (y))          /* choose */
#define SHA1_F1(w_, x, y) ((w_) ^ (x) ^ (y))                    /* parity */
#define SHA1_F2(w_, x, y) ((((w_) | (x)) & (y)) | ((w_) & (x))) /* majority */

#define SHA1_5(FN, K, SRC) do { \
    SHA1_R(FN, K, SRC(i + 0), a, b, d, e, f) \
    SHA1_R(FN, K, SRC(i + 1), f, a, b, d, e) \
    SHA1_R(FN, K, SRC(i + 2), e, f, a, b, d) \
    SHA1_R(FN, K, SRC(i + 3), d, e, f, a, b) \
    SHA1_R(FN, K, SRC(i + 4), b, d, e, f, a) \
} while (0)

#define SHA1_LOAD(i) w[(i) & 15]

    for (i = 0; i < 15; i += 5) SHA1_5(SHA1_F0, 0x5a827999u, SHA1_LOAD);

    /* Rounds 15-19 straddle the boundary: 15 still reads a loaded word, 16
     * onwards expand. One group, spelled out. */
    SHA1_R(SHA1_F0, 0x5a827999u, w[15],      a, b, d, e, f)
    SHA1_R(SHA1_F0, 0x5a827999u, SHA1_W(16), f, a, b, d, e)
    SHA1_R(SHA1_F0, 0x5a827999u, SHA1_W(17), e, f, a, b, d)
    SHA1_R(SHA1_F0, 0x5a827999u, SHA1_W(18), d, e, f, a, b)
    SHA1_R(SHA1_F0, 0x5a827999u, SHA1_W(19), b, d, e, f, a)

    for (i = 20; i < 40; i += 5) SHA1_5(SHA1_F1, 0x6ed9eba1u, SHA1_W);
    for (i = 40; i < 60; i += 5) SHA1_5(SHA1_F2, 0x8f1bbcdcu, SHA1_W);
    for (i = 60; i < 80; i += 5) SHA1_5(SHA1_F1, 0xca62c1d6u, SHA1_W);

#undef SHA1_LOAD
#undef SHA1_5
#undef SHA1_F2
#undef SHA1_F1
#undef SHA1_F0
#undef SHA1_R
#undef SHA1_W

    c->h[0] += a; c->h[1] += b; c->h[2] += d; c->h[3] += e; c->h[4] += f;
}
static void sha1_init(void* v) {
    Sha1* c = (Sha1*)v;
    c->h[0] = 0x67452301u; c->h[1] = 0xefcdab89u; c->h[2] = 0x98badcfeu;
    c->h[3] = 0x10325476u; c->h[4] = 0xc3d2e1f0u;
    c->len = 0; c->n = 0;
}
static void sha1_update(void* v, const u8* p, size_t n) {
    Sha1* c = (Sha1*)v;
    c->len += (u64)n;
    if (c->n) {
        size_t want = 64 - c->n, take = n < want ? n : want;
        memcpy(c->buf + c->n, p, take);
        c->n += take; p += take; n -= take;
        if (c->n < 64) return;
        sha1_block(c, c->buf); c->n = 0;
    }
    while (n >= 64) { sha1_block(c, p); p += 64; n -= 64; }
    if (n) { memcpy(c->buf, p, n); c->n = n; }
}
static void sha1_final(void* v, u8* out) {
    Sha1* c = (Sha1*)v;
    u64 bits = c->len * 8;
    u8 pad = 0x80;
    unsigned i;
    sha1_update(c, &pad, 1);
    while (c->n != 56) { u8 z = 0; sha1_update(c, &z, 1); }
    st64be(c->buf + 56, bits);
    sha1_block(c, c->buf);
    for (i = 0; i < 5; i++) st32be(out + 4 * i, c->h[i]);
}

/* ===================== SHA-224 / SHA-256 (FIPS 180-4) ==================== */

typedef struct { u32 h[8]; u64 len; u8 buf[64]; size_t n; size_t outlen; } Sha256;

static const u32 K256[64] = {
    0x428a2f98u,0x71374491u,0xb5c0fbcfu,0xe9b5dba5u,0x3956c25bu,0x59f111f1u,
    0x923f82a4u,0xab1c5ed5u,0xd807aa98u,0x12835b01u,0x243185beu,0x550c7dc3u,
    0x72be5d74u,0x80deb1feu,0x9bdc06a7u,0xc19bf174u,0xe49b69c1u,0xefbe4786u,
    0x0fc19dc6u,0x240ca1ccu,0x2de92c6fu,0x4a7484aau,0x5cb0a9dcu,0x76f988dau,
    0x983e5152u,0xa831c66du,0xb00327c8u,0xbf597fc7u,0xc6e00bf3u,0xd5a79147u,
    0x06ca6351u,0x14292967u,0x27b70a85u,0x2e1b2138u,0x4d2c6dfcu,0x53380d13u,
    0x650a7354u,0x766a0abbu,0x81c2c92eu,0x92722c85u,0xa2bfe8a1u,0xa81a664bu,
    0xc24b8b70u,0xc76c51a3u,0xd192e819u,0xd6990624u,0xf40e3585u,0x106aa070u,
    0x19a4c116u,0x1e376c08u,0x2748774cu,0x34b0bcb5u,0x391c0cb3u,0x4ed8aa4au,
    0x5b9cca4fu,0x682e6ff3u,0x748f82eeu,0x78a5636fu,0x84c87814u,0x8cc70208u,
    0x90befffau,0xa4506cebu,0xbef9a3f7u,0xc67178f2u
};

/* Same rolling-window trick as SHA-1: i-16 ≡ i, i-15 ≡ i+1, i-7 ≡ i+9 and
 * i-2 ≡ i+14 (mod 16), so the schedule is sixteen words updated in place. */
static void sha256_block(Sha256* c, const u8* p) {
    u32 w[16], a, b, d, e, f, g, h, i2, t1, t2;
    unsigned i;
    for (i = 0; i < 16; i++) w[i] = ld32be(p + 4 * i);
    a = c->h[0]; b = c->h[1]; d = c->h[2]; e = c->h[3];
    f = c->h[4]; g = c->h[5]; h = c->h[6]; i2 = c->h[7];

#define S256_0(x) (ROTR32(x,  7) ^ ROTR32(x, 18) ^ ((x) >>  3))
#define S256_1(x) (ROTR32(x, 17) ^ ROTR32(x, 19) ^ ((x) >> 10))
#define S256_W(i) (w[(i)&15] += S256_0(w[((i)+1)&15]) + w[((i)+9)&15] \
                              + S256_1(w[((i)+14)&15]))
#define S256_STEP(S) do { \
    t1 = i2 + (ROTR32(f, 6) ^ ROTR32(f, 11) ^ ROTR32(f, 25)) \
       + ((f & g) ^ (~f & h)) + K256[i] + (S); \
    t2 = (ROTR32(a, 2) ^ ROTR32(a, 13) ^ ROTR32(a, 22)) \
       + ((a & b) ^ (a & d) ^ (b & d)); \
    i2 = h; h = g; g = f; f = e + t1; \
    e = d; d = b; b = a; a = t1 + t2; \
} while (0)

    for (i =  0; i < 16; i++) S256_STEP(w[i]);
    for (i = 16; i < 64; i++) S256_STEP(S256_W(i));
#undef S256_STEP
#undef S256_W
#undef S256_1
#undef S256_0

    c->h[0] += a; c->h[1] += b; c->h[2] += d; c->h[3] += e;
    c->h[4] += f; c->h[5] += g; c->h[6] += h; c->h[7] += i2;
}
static void sha256_start(Sha256* c, const u32 iv[8], size_t outlen) {
    memcpy(c->h, iv, sizeof c->h);
    c->len = 0; c->n = 0; c->outlen = outlen;
}
static void sha256_init(void* v) {
    static const u32 iv[8] = {
        0x6a09e667u,0xbb67ae85u,0x3c6ef372u,0xa54ff53au,
        0x510e527fu,0x9b05688cu,0x1f83d9abu,0x5be0cd19u
    };
    sha256_start((Sha256*)v, iv, 32);
}
static void sha224_init(void* v) {
    static const u32 iv[8] = {
        0xc1059ed8u,0x367cd507u,0x3070dd17u,0xf70e5939u,
        0xffc00b31u,0x68581511u,0x64f98fa7u,0xbefa4fa4u
    };
    sha256_start((Sha256*)v, iv, 28);
}
static void sha256_update(void* v, const u8* p, size_t n) {
    Sha256* c = (Sha256*)v;
    c->len += (u64)n;
    if (c->n) {
        size_t want = 64 - c->n, take = n < want ? n : want;
        memcpy(c->buf + c->n, p, take);
        c->n += take; p += take; n -= take;
        if (c->n < 64) return;
        sha256_block(c, c->buf); c->n = 0;
    }
    while (n >= 64) { sha256_block(c, p); p += 64; n -= 64; }
    if (n) { memcpy(c->buf, p, n); c->n = n; }
}
static void sha256_final(void* v, u8* out) {
    Sha256* c = (Sha256*)v;
    u64 bits = c->len * 8;
    u8 pad = 0x80, full[32];
    unsigned i;
    sha256_update(c, &pad, 1);
    while (c->n != 56) { u8 z = 0; sha256_update(c, &z, 1); }
    st64be(c->buf + 56, bits);
    sha256_block(c, c->buf);
    for (i = 0; i < 8; i++) st32be(full + 4 * i, c->h[i]);
    memcpy(out, full, c->outlen);   /* SHA-224 is SHA-256 truncated */
}

/* ===================== SHA-384 / SHA-512 (FIPS 180-4) ==================== */

typedef struct { u64 h[8]; u64 lenlo, lenhi; u8 buf[128]; size_t n; size_t outlen; } Sha512;

static const u64 K512[80] = {
    0x428a2f98d728ae22ULL,0x7137449123ef65cdULL,0xb5c0fbcfec4d3b2fULL,0xe9b5dba58189dbbcULL,
    0x3956c25bf348b538ULL,0x59f111f1b605d019ULL,0x923f82a4af194f9bULL,0xab1c5ed5da6d8118ULL,
    0xd807aa98a3030242ULL,0x12835b0145706fbeULL,0x243185be4ee4b28cULL,0x550c7dc3d5ffb4e2ULL,
    0x72be5d74f27b896fULL,0x80deb1fe3b1696b1ULL,0x9bdc06a725c71235ULL,0xc19bf174cf692694ULL,
    0xe49b69c19ef14ad2ULL,0xefbe4786384f25e3ULL,0x0fc19dc68b8cd5b5ULL,0x240ca1cc77ac9c65ULL,
    0x2de92c6f592b0275ULL,0x4a7484aa6ea6e483ULL,0x5cb0a9dcbd41fbd4ULL,0x76f988da831153b5ULL,
    0x983e5152ee66dfabULL,0xa831c66d2db43210ULL,0xb00327c898fb213fULL,0xbf597fc7beef0ee4ULL,
    0xc6e00bf33da88fc2ULL,0xd5a79147930aa725ULL,0x06ca6351e003826fULL,0x142929670a0e6e70ULL,
    0x27b70a8546d22ffcULL,0x2e1b21385c26c926ULL,0x4d2c6dfc5ac42aedULL,0x53380d139d95b3dfULL,
    0x650a73548baf63deULL,0x766a0abb3c77b2a8ULL,0x81c2c92e47edaee6ULL,0x92722c851482353bULL,
    0xa2bfe8a14cf10364ULL,0xa81a664bbc423001ULL,0xc24b8b70d0f89791ULL,0xc76c51a30654be30ULL,
    0xd192e819d6ef5218ULL,0xd69906245565a910ULL,0xf40e35855771202aULL,0x106aa07032bbd1b8ULL,
    0x19a4c116b8d2d0c8ULL,0x1e376c085141ab53ULL,0x2748774cdf8eeb99ULL,0x34b0bcb5e19b48a8ULL,
    0x391c0cb3c5c95a63ULL,0x4ed8aa4ae3418acbULL,0x5b9cca4f7763e373ULL,0x682e6ff3d6b2b8a3ULL,
    0x748f82ee5defb2fcULL,0x78a5636f43172f60ULL,0x84c87814a1f0ab72ULL,0x8cc702081a6439ecULL,
    0x90befffa23631e28ULL,0xa4506cebde82bde9ULL,0xbef9a3f7b2c67915ULL,0xc67178f2e372532bULL,
    0xca273eceea26619cULL,0xd186b8c721c0c207ULL,0xeada7dd6cde0eb1eULL,0xf57d4f7fee6ed178ULL,
    0x06f067aa72176fbaULL,0x0a637dc5a2c898a6ULL,0x113f9804bef90daeULL,0x1b710b35131c471bULL,
    0x28db77f523047d84ULL,0x32caab7b40c72493ULL,0x3c9ebe0a15c9bebcULL,0x431d67c49c100d4cULL,
    0x4cc5d4becb3e42b6ULL,0x597f299cfc657e2aULL,0x5fcb6fab3ad6faecULL,0x6c44198c4a475817ULL
};

/* SHA-512 is SHA-256 with 64-bit words, other constants and eighty rounds; the
 * schedule window is the same sixteen and the index congruences are identical. */
static void sha512_block(Sha512* c, const u8* p) {
    u64 w[16], a, b, d, e, f, g, h, i2, t1, t2;
    unsigned i;
    for (i = 0; i < 16; i++) w[i] = ld64be(p + 8 * i);
    a = c->h[0]; b = c->h[1]; d = c->h[2]; e = c->h[3];
    f = c->h[4]; g = c->h[5]; h = c->h[6]; i2 = c->h[7];

#define S512_0(x) (ROTR64(x,  1) ^ ROTR64(x,  8) ^ ((x) >> 7))
#define S512_1(x) (ROTR64(x, 19) ^ ROTR64(x, 61) ^ ((x) >> 6))
#define S512_W(i) (w[(i)&15] += S512_0(w[((i)+1)&15]) + w[((i)+9)&15] \
                              + S512_1(w[((i)+14)&15]))
#define S512_STEP(S) do { \
    t1 = i2 + (ROTR64(f, 14) ^ ROTR64(f, 18) ^ ROTR64(f, 41)) \
       + ((f & g) ^ (~f & h)) + K512[i] + (S); \
    t2 = (ROTR64(a, 28) ^ ROTR64(a, 34) ^ ROTR64(a, 39)) \
       + ((a & b) ^ (a & d) ^ (b & d)); \
    i2 = h; h = g; g = f; f = e + t1; \
    e = d; d = b; b = a; a = t1 + t2; \
} while (0)

    for (i =  0; i < 16; i++) S512_STEP(w[i]);
    for (i = 16; i < 80; i++) S512_STEP(S512_W(i));
#undef S512_STEP
#undef S512_W
#undef S512_1
#undef S512_0

    c->h[0] += a; c->h[1] += b; c->h[2] += d; c->h[3] += e;
    c->h[4] += f; c->h[5] += g; c->h[6] += h; c->h[7] += i2;
}
static void sha512_start(Sha512* c, const u64 iv[8], size_t outlen) {
    memcpy(c->h, iv, sizeof c->h);
    c->lenlo = c->lenhi = 0; c->n = 0; c->outlen = outlen;
}
static void sha512_init(void* v) {
    static const u64 iv[8] = {
        0x6a09e667f3bcc908ULL,0xbb67ae8584caa73bULL,0x3c6ef372fe94f82bULL,0xa54ff53a5f1d36f1ULL,
        0x510e527fade682d1ULL,0x9b05688c2b3e6c1fULL,0x1f83d9abfb41bd6bULL,0x5be0cd19137e2179ULL
    };
    sha512_start((Sha512*)v, iv, 64);
}
static void sha384_init(void* v) {
    static const u64 iv[8] = {
        0xcbbb9d5dc1059ed8ULL,0x629a292a367cd507ULL,0x9159015a3070dd17ULL,0x152fecd8f70e5939ULL,
        0x67332667ffc00b31ULL,0x8eb44a8768581511ULL,0xdb0c2e0d64f98fa7ULL,0x47b5481dbefa4fa4ULL
    };
    sha512_start((Sha512*)v, iv, 48);
}
static void sha512_update(void* v, const u8* p, size_t n) {
    Sha512* c = (Sha512*)v;
    u64 before = c->lenlo;
    c->lenlo += (u64)n;
    if (c->lenlo < before) c->lenhi++;      /* 128-bit length, as the spec says */
    if (c->n) {
        size_t want = 128 - c->n, take = n < want ? n : want;
        memcpy(c->buf + c->n, p, take);
        c->n += take; p += take; n -= take;
        if (c->n < 128) return;
        sha512_block(c, c->buf); c->n = 0;
    }
    while (n >= 128) { sha512_block(c, p); p += 128; n -= 128; }
    if (n) { memcpy(c->buf, p, n); c->n = n; }
}
static void sha512_final(void* v, u8* out) {
    Sha512* c = (Sha512*)v;
    u64 lo = c->lenlo << 3, hi = (c->lenhi << 3) | (c->lenlo >> 61);
    u8 pad = 0x80, full[64];
    unsigned i;
    sha512_update(c, &pad, 1);
    while (c->n != 112) { u8 z = 0; sha512_update(c, &z, 1); }
    st64be(c->buf + 112, hi);
    st64be(c->buf + 120, lo);
    sha512_block(c, c->buf);
    for (i = 0; i < 8; i++) st64be(full + 8 * i, c->h[i]);
    memcpy(out, full, c->outlen);   /* SHA-384 is SHA-512 truncated */
}

/* ===================== the algorithm table =============================== */

typedef union { Md5 md5; Sha1 sha1; Sha256 s256; Sha512 s512; } AnyCtx;

typedef struct {
    const char* name;
    size_t      digest_len;
    size_t      block_len;      /* HMAC's B — 64 below SHA-384, 128 at and above */
    void      (*init)  (void*);
    void      (*update)(void*, const u8*, size_t);
    void      (*final) (void*, u8*);
} Algo;

static const Algo ALGOS[] = {
    { "md5",    16,  64, md5_init,    md5_update,    md5_final    },
    { "sha1",   20,  64, sha1_init,   sha1_update,   sha1_final   },
    { "sha224", 28,  64, sha224_init, sha256_update, sha256_final },
    { "sha256", 32,  64, sha256_init, sha256_update, sha256_final },
    { "sha384", 48, 128, sha384_init, sha512_update, sha512_final },
    { "sha512", 64, 128, sha512_init, sha512_update, sha512_final }
};
#define NALGOS (sizeof ALGOS / sizeof ALGOS[0])
#define MAXDIGEST 64
#define MAXBLOCK  128

static const Algo* find_algo(const char* name, size_t len) {
    size_t i;
    for (i = 0; i < NALGOS; i++)
        if (strlen(ALGOS[i].name) == len && memcmp(ALGOS[i].name, name, len) == 0)
            return &ALGOS[i];
    return 0;
}

static void hash_all(const Algo* a, const u8* p, size_t n, u8* out) {
    AnyCtx ctx;
    a->init(&ctx);
    a->update(&ctx, p, n);
    a->final(&ctx, out);
}

/* ===================== HMAC (RFC 2104) =================================== */

/* $blocksize is honoured as given, so a caller reproducing Digest::HMAC's
 * behaviour bit for bit can still ask for B = 64 with SHA-512. Absent, the
 * algorithm's real block length is used — which is what RFC 2104 wants and
 * what Digest::HMAC gets wrong by defaulting every hash to 64. */
static void hmac_raw(const Algo* a, size_t B,
                     const u8* key, size_t keylen,
                     const u8* msg, size_t msglen, u8* out) {
    u8 k[MAXBLOCK], ipad[MAXBLOCK], opad[MAXBLOCK], inner[MAXDIGEST];
    AnyCtx ctx;
    size_t i;

    if (B > MAXBLOCK) B = MAXBLOCK;
    memset(k, 0, B);
    if (keylen > B) hash_all(a, key, keylen, k);
    else            memcpy(k, key, keylen);

    for (i = 0; i < B; i++) { ipad[i] = (u8)(k[i] ^ 0x36); opad[i] = (u8)(k[i] ^ 0x5c); }

    a->init(&ctx);
    a->update(&ctx, ipad, B);
    a->update(&ctx, msg, msglen);
    a->final(&ctx, inner);

    a->init(&ctx);
    a->update(&ctx, opad, B);
    a->update(&ctx, inner, a->digest_len);
    a->final(&ctx, out);
}

/* ===================== the ABI shim ====================================== */

static const char HEX[] = "0123456789abcdef";

/* GETTING BYTES BACK OUT.
 *
 * ABI 3 has rk_blob and this is one line. Below it is the shim for older
 * headers, kept because the module is compiled at INSTALL time against
 * whatever Raku++ is on the machine, and an older one is a supported state.
 *
 * The trap it works around, since the shim looks arbitrary without it: rk_str
 * takes a byte buffer, but what the host builds from it is a Raku Str, and it
 * DECODES those bytes as UTF-8 to do so. Handing it a raw digest does not
 * round-trip — md5("abc") came back eleven characters long, with 0xd2 0x4f
 * collapsed and 0xe1 0x7f 0x72 rewritten. So each byte is sent as the UTF-8
 * encoding of the CODEPOINT of the same number, decoding yields a Str of
 * exactly n characters with ordinals 0..255, and .encode('latin-1') on the
 * Raku side hands back the original bytes. Both paths are checked over all 256
 * values in t/03-inputs.t.
 *
 * Hex output needs neither: hex is ASCII, and ASCII is its own UTF-8. */
#if RAKUPP_EXT_ABI >= 3
static RkValue emit_bytes(RkCtx c, const u8* d, size_t n) {
    return rk_blob(c, d, n);
}
#else
static RkValue emit_bytes(RkCtx c, const u8* d, size_t n) {
    char buf[MAXDIGEST * 2];
    size_t i, j = 0;
    for (i = 0; i < n; i++) {
        if (d[i] < 0x80) buf[j++] = (char)d[i];
        else { buf[j++] = (char)(0xc0 | (d[i] >> 6)); buf[j++] = (char)(0x80 | (d[i] & 0x3f)); }
    }
    return rk_str(c, buf, j);
}
#endif

static RkValue emit(RkCtx c, const u8* d, size_t n, int hex) {
    char buf[MAXDIGEST * 2];
    size_t i;
    if (!hex) return emit_bytes(c, d, n);
    for (i = 0; i < n; i++) { buf[2*i] = HEX[d[i] >> 4]; buf[2*i+1] = HEX[d[i] & 15]; }
    return rk_str(c, buf, n * 2);
}

/* Every input arrives here: a Str gives its UTF-8 bytes, a Buf or blob8 its
 * raw ones. The Raku half has already refused anything that is neither, so a
 * value reaching this point is bytes by construction. */
static const u8* bytes_of(RkCtx c, RkValue v, size_t* len) {
    return (const u8*)rk_str_get(c, v, len);
}

static const Algo* algo_arg(RkCtx c, size_t i) {
    size_t n = 0;
    const char* s = rk_str_get(c, rk_arg(c, i), &n);
    const Algo* a = find_algo(s, n);
    if (!a) rk_die(c, "Digest::Native: unknown algorithm");
    return a;
}

/* (algo, data, hex) */
static RkValue ext_digest(RkCtx c) {
    const Algo* a = algo_arg(c, 0);
    size_t n = 0;
    const u8* p;
    u8 out[MAXDIGEST];
    if (!a) return 0;
    p = bytes_of(c, rk_arg(c, 1), &n);
    hash_all(a, p, n, out);
    return emit(c, out, a->digest_len, rk_truthy(c, rk_arg(c, 2)));
}

/* (algo, path, hex) — streamed, so hashing a file never costs its size in
 * memory. This is the one entry point that touches the filesystem; the Raku
 * half opens nothing when the extension is present. */
static RkValue ext_digest_file(RkCtx c) {
    const Algo* a = algo_arg(c, 0);
    size_t n = 0;
    const char* path;
    char pathz[4096];
    FILE* f;
    AnyCtx ctx;
    u8 out[MAXDIGEST];
    u8* chunk;
    size_t got;

    if (!a) return 0;
    path = rk_str_get(c, rk_arg(c, 1), &n);
    if (n >= sizeof pathz) { rk_die(c, "Digest::Native: path too long"); return 0; }
    memcpy(pathz, path, n); pathz[n] = 0;

    f = fopen(pathz, "rb");
    if (!f) { rk_die(c, "Digest::Native: cannot open file"); return 0; }
    /* Heap, not a file-scope static: since v3.0.0 several rakupp threads can be
     * inside extension calls at once, and a shared scratch buffer would be the
     * one piece of state here that they could tread on. */
    chunk = (u8*)malloc(65536);
    if (!chunk) { fclose(f); rk_die(c, "Digest::Native: out of memory"); return 0; }
    a->init(&ctx);
    while ((got = fread(chunk, 1, 65536, f)) > 0) a->update(&ctx, chunk, got);
    free(chunk);
    if (ferror(f)) { fclose(f); rk_die(c, "Digest::Native: read error"); return 0; }
    fclose(f);
    a->final(&ctx, out);
    return emit(c, out, a->digest_len, rk_truthy(c, rk_arg(c, 2)));
}

/* (algo, key, message, blocksize, hex) — blocksize 0 means "the algorithm's". */
static RkValue ext_hmac(RkCtx c) {
    const Algo* a = algo_arg(c, 0);
    size_t klen = 0, mlen = 0;
    const u8 *k, *m;
    long long B;
    u8 out[MAXDIGEST];
    if (!a) return 0;
    k = bytes_of(c, rk_arg(c, 1), &klen);
    m = bytes_of(c, rk_arg(c, 2), &mlen);
    B = rk_int_get(c, rk_arg(c, 3));
    if (B <= 0) B = (long long)a->block_len;
    if (B > MAXBLOCK) { rk_die(c, "Digest::Native: block size above 128 is not supported"); return 0; }
    hmac_raw(a, (size_t)B, k, klen, m, mlen, out);
    return emit(c, out, a->digest_len, rk_truthy(c, rk_arg(c, 4)));
}

static const RkSubDef subs[] = {
    {"digest-native",      ext_digest},
    {"digest-file-native", ext_digest_file},
    {"hmac-native",        ext_hmac},
    {0, 0}
};
static const RkModule mod = { RAKUPP_EXT_ABI, "Digest::Native", subs };

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
