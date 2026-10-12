/* json-nc.c — the native half of JSON::Native on Rakudo, reached through
 * NativeCall (lib/JSON/Native/NativeCall.rakumod). Plain C, no Raku headers:
 * the build step compiles it on any machine with a C compiler, and without one
 * the module answers through its other paths.
 *
 * C cannot build a Raku value on Rakudo, so it does the part C is good at —
 * reading the text — and hands back two flat buffers the Raku side turns into
 * values in one pass:
 *
 *   tape:    int64 words in document order, one per value except where
 *            noted. A word is (payload << 4) | tag:
 *              0 null   1 true   2 false
 *              3 n      Int n, |n| < 2**59
 *              4 k, n   Rat n / 10**k — two words, the second n itself
 *              5        a number token for .Numeric (text is the next string)
 *              6 c      object of c pairs: key (next string), then the value
 *              7 c      array of c values
 *              8        string (the next string)
 *              9, n     Int n — two words, for 2**59 <= |n| < 10**18
 *             10, d     Num d — two words, the second the double's bits
 *   strings: every decoded string and number token, in order, each ended by NUL
 *
 * Anything this does not accept EXACTLY as JSON::Fast does — malformed input,
 * a surrogate that is not a proper pair, a NUL inside a string, a non-ASCII
 * digit — returns -1, and the Raku side asks the Raku implementation, which
 * answers (or refuses) as JSON::Fast does. So this file only ever has to be
 * right about documents it accepts.
 */
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>

typedef struct {
    const unsigned char* p;
    const unsigned char* end;
    int64_t* tape; size_t tn, tcap;
    unsigned char* s; size_t sn, scap;
    int depth;
} P;

#define FAIL return -1

static void ws(P* x) {
    while (x->p < x->end && (*x->p == ' ' || *x->p == '\n' || *x->p == '\t' || *x->p == '\r')) x->p++;
}
static int put(P* x, int64_t w);
static int word(P* x, int64_t payload, int tag) { return put(x, (int64_t)((uint64_t)payload << 4) | tag); }
static int put(P* x, int64_t w) {
    if (x->tn >= x->tcap) return -1;
    x->tape[x->tn++] = w;
    return 0;
}
static int sbyte(P* x, unsigned char c) {
    if (x->sn >= x->scap) return -1;
    x->s[x->sn++] = c;
    return 0;
}
static int hex4(P* x, unsigned* out) {
    unsigned v = 0; int i;
    if (x->end - x->p < 4) return -1;
    for (i = 0; i < 4; i++) {
        unsigned char c = *x->p++;
        v <<= 4;
        if (c >= '0' && c <= '9') v |= c - '0';
        else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
        else return -1;
    }
    *out = v;
    return 0;
}
static int utf8(P* x, unsigned cp) {
    if (cp == 0) return -1;   /* NUL ends a string in the buffer: let Raku do it */
    if (cp < 0x80) return sbyte(x, (unsigned char)cp);
    if (cp < 0x800) return sbyte(x, 0xC0 | (cp >> 6)) | sbyte(x, 0x80 | (cp & 0x3F));
    if (cp < 0x10000) return sbyte(x, 0xE0 | (cp >> 12)) | sbyte(x, 0x80 | ((cp >> 6) & 0x3F)) | sbyte(x, 0x80 | (cp & 0x3F));
    return sbyte(x, 0xF0 | (cp >> 18)) | sbyte(x, 0x80 | ((cp >> 12) & 0x3F))
         | sbyte(x, 0x80 | ((cp >> 6) & 0x3F)) | sbyte(x, 0x80 | (cp & 0x3F));
}

/* at the opening quote */
static int string(P* x) {
    x->p++;
    for (;;) {
        unsigned char c;
        if (x->p >= x->end) FAIL;
        c = *x->p++;
        if (c == '"') return sbyte(x, 0);
        if (c == '\t' || c == '\n' || c == 0) FAIL;   /* JSON::Fast refuses raw TAB/LF; NUL is the separator */
        if (c != '\\') { if (sbyte(x, c)) FAIL; continue; }
        if (x->p >= x->end) FAIL;
        c = *x->p++;
        switch (c) {
            case '"': case '\\': case '/': if (sbyte(x, c)) FAIL; break;
            case 'b': if (sbyte(x, 8))  FAIL; break;
            case 'f': if (sbyte(x, 12)) FAIL; break;
            case 'n': if (sbyte(x, 10)) FAIL; break;
            case 'r': if (sbyte(x, 13)) FAIL; break;
            case 't': if (sbyte(x, 9))  FAIL; break;
            case 'u': {
                unsigned cp, lo;
                if (hex4(x, &cp)) FAIL;
                if (cp >= 0xD800 && cp < 0xE000) {
                    if (cp >= 0xDC00) FAIL;
                    if (x->end - x->p < 6 || x->p[0] != '\\' || x->p[1] != 'u') FAIL;
                    x->p += 2;
                    if (hex4(x, &lo) || lo < 0xDC00 || lo >= 0xE000) FAIL;
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                }
                if (utf8(x, cp)) FAIL;
                break;
            }
            default: FAIL;
        }
    }
}

static int isdig(const unsigned char* p, const unsigned char* end) { return p < end && *p >= '0' && *p <= '9'; }

/* JSON::Fast's scan: a sign or digit, digits, an optional fraction, an
   optional exponent. An integer or plain decimal of at most 18 digits is typed
   here; any other token goes to .Numeric as text. */
static int number(P* x) {
    const unsigned char* st = x->p;
    const unsigned char* q = x->p + 1;
    int neg = *st == '-', digits = neg ? 0 : 1, fdigits = 0, frac = 0, expo = 0, edigits = 0;
    int64_t acc = neg ? 0 : *st - '0';
    if (q < x->end && *q >= 0x80) FAIL;   /* a non-ASCII digit, perhaps: Raku's business */
    while (isdig(q, x->end)) { if (digits < 18) acc = acc * 10 + (*q - '0'); digits++; q++; }
    if (q < x->end && *q == '.') {
        frac = 1; q++;
        while (isdig(q, x->end)) { if (digits + fdigits < 18) acc = acc * 10 + (*q - '0'); fdigits++; q++; }
    }
    if (q < x->end && (*q == 'e' || *q == 'E')) {
        expo = 1; q++;
        if (q < x->end && (*q == '+' || *q == '-')) q++;
        while (isdig(q, x->end)) { q++; edigits++; }
    }
    if (q < x->end && *q >= 0x80) FAIL;
    x->p = q;
    if (!expo && digits && digits + fdigits <= 18 && (!frac || fdigits)) {
        if (neg) acc = -acc;
        if (!frac) {
            if (acc < ((int64_t)1 << 59) && acc > -((int64_t)1 << 59)) return word(x, acc, 3);
            return word(x, 0, 9) | put(x, acc);
        }
        return word(x, fdigits, 4) | put(x, acc);
    }
    /* A well-formed exponent form is the double strtod makes of it — which is
       what Rakudo's .Numeric makes of it too, checked over 60,000 of them */
    if (expo && digits && edigits && (!frac || fdigits) && q - st < 64) {
        char buf[64];
        double d;
        int64_t bits;
        memcpy(buf, st, (size_t)(q - st));
        buf[q - st] = 0;
        d = strtod(buf, NULL);
        memcpy(&bits, &d, sizeof bits);
        return word(x, 0, 10) | put(x, bits);
    }
    /* the token as text; .Numeric decides, and refuses what JSON::Fast refuses */
    while (st < q) if (sbyte(x, *st++)) FAIL;
    return word(x, 0, 5) | sbyte(x, 0);
}

static int value(P* x) {
    ws(x);
    if (x->p >= x->end) FAIL;
    if (++x->depth > 10000) FAIL;
    switch (*x->p) {
        case '"':
            if (word(x, 0, 8)) FAIL;
            if (string(x)) FAIL;
            break;
        case '{': {
            size_t at; int64_t n = 0;
            x->p++;
            if (word(x, 0, 6)) FAIL;
            at = x->tn - 1;
            ws(x);
            if (x->p < x->end && *x->p == '}') { x->p++; break; }
            for (;;) {
                ws(x);
                if (x->p >= x->end || *x->p != '"') FAIL;
                if (string(x)) FAIL;
                ws(x);
                if (x->p >= x->end || *x->p != ':') FAIL;
                x->p++;
                if (value(x)) FAIL;
                n++;
                ws(x);
                if (x->p < x->end && *x->p == ',') { x->p++; continue; }
                if (x->p < x->end && *x->p == '}') { x->p++; break; }
                FAIL;
            }
            x->tape[at] = (int64_t)((uint64_t)n << 4) | 6;
            break;
        }
        case '[': {
            size_t at; int64_t n = 0;
            x->p++;
            if (word(x, 0, 7)) FAIL;
            at = x->tn - 1;
            ws(x);
            if (x->p < x->end && *x->p == ']') { x->p++; break; }
            for (;;) {
                if (value(x)) FAIL;
                n++;
                ws(x);
                if (x->p < x->end && *x->p == ',') { x->p++; continue; }
                if (x->p < x->end && *x->p == ']') { x->p++; break; }
                FAIL;
            }
            x->tape[at] = (int64_t)((uint64_t)n << 4) | 7;
            break;
        }
        case 't':
            if (x->end - x->p < 4 || memcmp(x->p, "true", 4)) FAIL;
            x->p += 4; if (word(x, 0, 1)) FAIL; break;
        case 'f':
            if (x->end - x->p < 5 || memcmp(x->p, "false", 5)) FAIL;
            x->p += 5; if (word(x, 0, 2)) FAIL; break;
        case 'n':
            if (x->end - x->p < 4 || memcmp(x->p, "null", 4)) FAIL;
            x->p += 4; if (word(x, 0, 0)) FAIL; break;
        default:
            if (*x->p == '-' || (*x->p >= '0' && *x->p <= '9')) { if (number(x)) FAIL; }
            else FAIL;
    }
    x->depth--;
    return 0;
}

/* Returns the number of tape words, or -1 for "ask the Raku implementation".
   lens[0] receives the bytes of the strings buffer used. */
/* The protocol version of the tape and strings described above; the Raku
   side refuses a library that answers anything else. */
int64_t json_nc_abi(void) { return 1; }

int64_t json_nc_parse(const unsigned char* text, size_t len,
                 int64_t* tape, size_t tcap,
                 unsigned char* strs, size_t scap, int64_t* lens) {
    P x;
    x.p = text; x.end = text + len;
    x.tape = tape; x.tn = 0; x.tcap = tcap;
    x.s = strs; x.sn = 0; x.scap = scap;
    x.depth = 0;
    /* the buffer starts with a separator, so no string is ever at offset 0 —
       where Buf.decode would take a leading U+FEFF for a byte order mark and
       drop it */
    if (sbyte(&x, 0)) return -1;
    if (value(&x)) return -1;
    ws(&x);
    if (x.p != x.end) return -1;
    lens[0] = (int64_t)x.sn;
    return (int64_t)x.tn;
}
