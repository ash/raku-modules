/* json.c — the native half of Rakupp::JSON.
 *
 * Plain C against <rakupp/rakupp_ext.h> and nothing else: no C++, no rakupp
 * source, no knowledge of how a Raku value is laid out. That is the point of the
 * extension ABI — this file keeps working across compiler releases that change
 * the interpreter's internals, so the module versions on its own schedule.
 *
 * Only the PARSER is here. Serialising needs to walk a hash, and ABI v1 offers
 * only index-based hash access (O(i) per key, so quadratic over a whole hash);
 * until it grows a cursor, `to-json` stays in Raku where it costs nothing to be
 * honest about. Parsing is where the time was anyway.
 *
 * Raku's numerics, not C's: an integer token becomes an Int of arbitrary
 * precision, a decimal becomes a Rat (what `.Numeric` gives, and why
 * `0.1 + 0.2 == 0.3` holds in Raku), and an exponent form becomes a Num.
 */
#include <rakupp/rakupp_ext.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const char* p;
    const char* begin;
    const char* end;
    RkCtx c;
    int failed;
    int immutable;
} P;

static RkValue thing(P* s, int depth);

static void fail(P* s, const char* msg) {
    if (!s->failed) {
        char buf[160];
        /* position, so a malformed document says WHERE */
        long at = (long)(s->p - s->begin);
        snprintf(buf, sizeof buf, "Rakupp::JSON: %s at position %ld", msg, at);
        rk_die(s->c, buf);
        s->failed = 1;
    }
}

static void ws(P* s) {
    while (s->p < s->end &&
           (*s->p == ' ' || *s->p == '\t' || *s->p == '\n' || *s->p == '\r'))
        s->p++;
}

static int hex4(P* s, unsigned* out) {
    unsigned v = 0;
    int i;
    if (s->end - s->p < 4) { fail(s, "truncated \\u escape"); return 0; }
    for (i = 0; i < 4; i++) {
        char ch = *s->p++;
        v <<= 4;
        if (ch >= '0' && ch <= '9') v |= (unsigned)(ch - '0');
        else if (ch >= 'a' && ch <= 'f') v |= (unsigned)(ch - 'a' + 10);
        else if (ch >= 'A' && ch <= 'F') v |= (unsigned)(ch - 'A' + 10);
        else { fail(s, "bad hex digit in \\u escape"); return 0; }
    }
    *out = v;
    return 1;
}

static void utf8(unsigned cp, char** o) {
    char* q = *o;
    if (cp < 0x80) *q++ = (char)cp;
    else if (cp < 0x800) {
        *q++ = (char)(0xC0 | (cp >> 6));
        *q++ = (char)(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
        *q++ = (char)(0xE0 | (cp >> 12));
        *q++ = (char)(0x80 | ((cp >> 6) & 0x3F));
        *q++ = (char)(0x80 | (cp & 0x3F));
    } else {
        *q++ = (char)(0xF0 | (cp >> 18));
        *q++ = (char)(0x80 | ((cp >> 12) & 0x3F));
        *q++ = (char)(0x80 | ((cp >> 6) & 0x3F));
        *q++ = (char)(0x80 | (cp & 0x3F));
    }
    *o = q;
}

/* Decodes into `buf`, growing it as needed. Returns length, or -1 on failure. */
static long jstring(P* s, char** buf, size_t* cap) {
    char* o;
    if (s->p >= s->end || *s->p != '"') { fail(s, "expected a string"); return -1; }
    s->p++;
    /* The decoded form is never longer than the source, plus room for one
       4-byte sequence per escape; the raw span is a safe upper bound. */
    {
        size_t need = (size_t)(s->end - s->p) + 8;
        if (need > *cap) {
            char* nb = (char*)realloc(*buf, need);
            if (!nb) { fail(s, "out of memory"); return -1; }
            *buf = nb; *cap = need;
        }
    }
    o = *buf;
    for (;;) {
        unsigned char ch;
        if (s->p >= s->end) { fail(s, "unterminated string"); return -1; }
        ch = (unsigned char)*s->p;
        if (ch == '"') { s->p++; break; }
        if (ch == '\\') {
            char e;
            s->p++;
            if (s->p >= s->end) { fail(s, "unterminated escape"); return -1; }
            e = *s->p++;
            switch (e) {
                case '"':  *o++ = '"';  break;
                case '\\': *o++ = '\\'; break;
                case '/':  *o++ = '/';  break;
                case 'b':  *o++ = '\b'; break;
                case 'f':  *o++ = '\f'; break;
                case 'n':  *o++ = '\n'; break;
                case 'r':  *o++ = '\r'; break;
                case 't':  *o++ = '\t'; break;
                case 'u': {
                    unsigned cp;
                    if (!hex4(s, &cp)) return -1;
                    if (cp >= 0xD800 && cp < 0xDC00) { /* high surrogate */
                        unsigned lo;
                        if (s->end - s->p >= 2 && s->p[0] == '\\' && s->p[1] == 'u') {
                            s->p += 2;
                            if (!hex4(s, &lo)) return -1;
                            if (lo >= 0xDC00 && lo < 0xE000)
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            else { fail(s, "high surrogate not followed by a low one"); return -1; }
                        } else { fail(s, "high surrogate not followed by a low one"); return -1; }
                    } else if (cp >= 0xDC00 && cp < 0xE000) {
                        fail(s, "stray low surrogate"); return -1;
                    }
                    utf8(cp, &o);
                    break;
                }
                default: fail(s, "unknown escape"); return -1;
            }
        } else if (ch < 0x20) {
            /* RFC 8259: a raw control character is not allowed inside a string */
            fail(s, "unescaped control character in string");
            return -1;
        } else *o++ = (char)*s->p++;
    }
    return (long)(o - *buf);
}

static RkValue number(P* s) {
    const char* start = s->p;
    int any = 0, frac = 0, expo = 0;
    size_t len, dot;
    if (s->p < s->end && (*s->p == '-' || *s->p == '+')) s->p++;
    while (s->p < s->end && *s->p >= '0' && *s->p <= '9') { s->p++; any = 1; }
    if (s->p < s->end && *s->p == '.') {
        int d = 0;
        s->p++; frac = 1;
        while (s->p < s->end && *s->p >= '0' && *s->p <= '9') { s->p++; d = 1; }
        if (!d) { fail(s, "digits expected after the decimal point"); return 0; }
    }
    if (s->p < s->end && (*s->p == 'e' || *s->p == 'E')) {
        int d = 0;
        s->p++; expo = 1;
        if (s->p < s->end && (*s->p == '-' || *s->p == '+')) s->p++;
        while (s->p < s->end && *s->p >= '0' && *s->p <= '9') { s->p++; d = 1; }
        if (!d) { fail(s, "digits expected in the exponent"); return 0; }
    }
    if (!any) { fail(s, "expected a number"); return 0; }
    len = (size_t)(s->p - start);
    {
        char tok[512];
        if (len >= sizeof tok - 1) { fail(s, "number token too long"); return 0; }
        memcpy(tok, start, len);
        tok[len] = 0;
        if (expo) return rk_num(s->c, strtod(tok, NULL));
        if (!frac) return rk_int_s(s->c, tok);
        /* Rat: digits with the point removed, over 10^(digits after the point) */
        {
            char num[512], den[512];
            size_t i, j = 0, scale;
            const char* d = strchr(tok, '.');
            dot = (size_t)(d - tok);
            for (i = 0; i < len; i++) if (i != dot) num[j++] = tok[i];
            num[j] = 0;
            scale = len - dot - 1;
            den[0] = '1';
            for (i = 0; i < scale; i++) den[i + 1] = '0';
            den[scale + 1] = 0;
            return rk_rat_s(s->c, num, den);
        }
    }
}

static RkValue thing(P* s, int depth) {
    if (s->failed) return 0;
    /* A bound on nesting, so a hostile document raises instead of exhausting
       the C stack. No legitimate JSON comes close. */
    if (depth > 512) { fail(s, "nesting too deep"); return 0; }
    ws(s);
    if (s->p >= s->end) { fail(s, "unexpected end of input"); return 0; }
    switch (*s->p) {
        case '{': {
            RkValue h = rk_hash(s->c);
            if (s->immutable) rk_map(s->c, h);
            s->p++;
            ws(s);
            if (s->p < s->end && *s->p == '}') { s->p++; return h; }
            for (;;) {
                char* kb = NULL; size_t kc = 0; long kl;
                RkValue v;
                ws(s);
                kl = jstring(s, &kb, &kc);
                if (kl < 0) { free(kb); return 0; }
                ws(s);
                if (s->p >= s->end || *s->p != ':') { free(kb); fail(s, "expected ':'"); return 0; }
                s->p++;
                v = thing(s, depth + 1);
                if (!v) { free(kb); return 0; }
                rk_set(s->c, h, kb, (size_t)kl, v);
                free(kb);
                ws(s);
                if (s->p < s->end && *s->p == ',') { s->p++; continue; }
                if (s->p < s->end && *s->p == '}') { s->p++; return h; }
                fail(s, "expected ',' or '}'");
                return 0;
            }
        }
        case '[': {
            RkValue a = rk_array(s->c);
            if (s->immutable) rk_list(s->c, a);
            s->p++;
            ws(s);
            if (s->p < s->end && *s->p == ']') { s->p++; return a; }
            for (;;) {
                RkValue v = thing(s, depth + 1);
                if (!v) return 0;
                rk_push(s->c, a, v);
                ws(s);
                if (s->p < s->end && *s->p == ',') { s->p++; continue; }
                if (s->p < s->end && *s->p == ']') { s->p++; return a; }
                fail(s, "expected ',' or ']'");
                return 0;
            }
        }
        case '"': {
            char* b = NULL; size_t c = 0;
            long n = jstring(s, &b, &c);
            RkValue v;
            if (n < 0) { free(b); return 0; }
            v = rk_str(s->c, b, (size_t)n);
            free(b);
            return v;
        }
        case 't':
            if (s->end - s->p >= 4 && !memcmp(s->p, "true", 4)) { s->p += 4; return rk_bool(s->c, 1); }
            fail(s, "expected 'true'"); return 0;
        case 'f':
            if (s->end - s->p >= 5 && !memcmp(s->p, "false", 5)) { s->p += 5; return rk_bool(s->c, 0); }
            fail(s, "expected 'false'"); return 0;
        case 'n':
            if (s->end - s->p >= 4 && !memcmp(s->p, "null", 4)) { s->p += 4; return rk_any(s->c); }
            fail(s, "expected 'null'"); return 0;
        default:
            return number(s);
    }
}

static RkValue from_json_native(RkCtx c) {
    size_t len = 0;
    const char* text = rk_str_get(c, rk_arg(c, 0), &len);
    RkValue imm = rk_named(c, "immutable");
    P s;
    RkValue out;
    s.p = text; s.begin = text; s.end = text + len; s.c = c; s.failed = 0;
    s.immutable = imm ? rk_truthy(c, imm) : 0;
    out = thing(&s, 0);
    if (!out) return 0;
    ws(&s);
    if (s.p != s.end) { fail(&s, "trailing content after the document"); return 0; }
    return out;
}

static const RkSubDef subs[] = {
    {"from-json-native", from_json_native},
    {0, 0}
};
static const RkModule mod = { RAKUPP_EXT_ABI, "Rakupp::JSON", subs };

RAKUPP_EXT_EXPORT const RkModule* rakupp_ext_init(unsigned host_abi) {
    return host_abi == RAKUPP_EXT_ABI ? &mod : 0;
}
