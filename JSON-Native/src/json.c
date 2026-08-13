/* json.c — the native half of JSON::Native.
 *
 * Plain C against <rakupp/rakupp_ext.h> and nothing else: no C++, no rakupp
 * source, no knowledge of how a Raku value is laid out. That is the point of the
 * extension ABI — this file keeps working across compiler releases that change
 * the interpreter's internals, so the module versions on its own schedule.
 *
 * Raku's numerics, not C's: an integer token becomes an Int of arbitrary
 * precision, a decimal becomes a Rat (what `.Numeric` gives, and why
 * `0.1 + 0.2 == 0.3` holds in Raku), and an exponent form becomes a Num.
 *
 * THE SERIALISER, and why it took until ABI 2. Walking a hash used to cost
 * O(i) per key, so a wide hash was quadratic and `to-json` stayed in Raku. The
 * The decode buffer is shared by every string in a parse (P.sbuf) and sized to
 * the string being read. Both halves of that matter: it was a fresh malloc per
 * string, sized to the rest of the DOCUMENT, so a document with K strings did
 * K allocations of O(N) bytes — linear to about half a megabyte and quadratic
 * past a megabyte (9.6 MB took 3.3 s, with the profile dominated by free and
 * madvise rather than by parsing). A shared buffer also means an object's key
 * must be copied out before its value is parsed, since that recursion reuses
 * the same bytes.
 *
 * host now remembers its position between rk_key_at calls and a sequential walk
 * is O(1) per key: 40,000 keys serialise in 9.6 ms, a flat 0.24 us per key from
 * 5,000 keys up, where the old walk would have taken ~800 million iterator
 * steps to do the same work. Documents shaped like many SMALL records never
 * felt that — their hashes are a handful of keys each — so the honest summary
 * is that the fix removed the cliff rather than the ordinary cost.
 *
 * Its contract is stricter than the parser's: JSON::Fast's exact output is
 * what programs already depend on, so this reproduces it byte for byte rather
 * than merely producing valid JSON. Two rules do most of that work, both
 * derived by measuring JSON::Fast rather than by reading it:
 *
 *   - numbers are the value's own Raku .Str (via rk_str_get, so this file
 *     never reimplements Raku's float formatting), with "e0" appended to a Num
 *     that has no exponent and ".0" to a Rat that has no decimal point;
 *   - \t \n \r are named, every other control character is \u00xx in lower
 *     case — including 0x08 and 0x0c, which JSON::Fast does NOT write as
 *     \b and \f.
 *
 * Anything this file does not understand — a type outside the ABI's
 * vocabulary — makes it return Nil rather than guess, and the Raku side falls
 * back to JSON::Fast. Being exactly right or standing aside is the whole
 * bargain; being approximately right would be worse than being slow.
 */
#include <rakupp/rakupp_ext.h>

#include <math.h>
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
    /* ONE decode buffer for the whole parse, grown geometrically and reused by
       every string. It used to be a fresh malloc per string, sized to the rest
       of the DOCUMENT — so a document with K strings did K allocations of O(N)
       bytes each and freed them again, which is O(N*K): 47 MB/s at 278 KB but
       2.8 MB/s at 9.5 MB, with the profile dominated by free/madvise rather
       than by parsing. Reused here, and sized to the string actually being
       read (see jstring). */
    char*  sbuf;
    size_t scap;
} P;

static RkValue thing(P* s, int depth);

static void fail(P* s, const char* msg) {
    if (!s->failed) {
        char buf[160];
        /* position, so a malformed document says WHERE */
        long at = (long)(s->p - s->begin);
        snprintf(buf, sizeof buf, "JSON::Native: %s at position %ld", msg, at);
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
    /* The decoded form is never longer than the source span, plus room for one
       4-byte sequence per escape. Bound it by THIS STRING's extent, not by the
       rest of the document: scanning to the closing quote costs the same bytes
       the decode loop is about to walk anyway, so the parse stays linear, while
       the old whole-document bound made every string allocate megabytes. */
    {
        const char* q = s->p;
        size_t need;
        while (q < s->end) {
            if (*q == '\\') { q += 2; continue; }  /* skip the escaped byte too */
            if (*q == '"') break;
            q++;
        }
        if (q > s->end) q = s->end;               /* a trailing backslash ran past the end */
        need = (size_t)(q - s->p) + 8;
        if (need > *cap) {
            size_t want = *cap ? *cap * 2 : 256;  /* geometric: a long string must not realloc per call */
            char* nb;
            if (want < need) want = need;
            nb = (char*)realloc(*buf, want);
            if (!nb) { fail(s, "out of memory"); return -1; }
            *buf = nb; *cap = want;
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
                long kl;
                RkValue v;
                ws(s);
                kl = jstring(s, &s->sbuf, &s->scap);
                if (kl < 0) return 0;
                ws(s);
                if (s->p >= s->end || *s->p != ':') { fail(s, "expected ':'"); return 0; }
                s->p++;
                /* the key must be copied out BEFORE parsing the value: that
                   recursion reuses the same shared buffer for its own strings */
                {
                    char kstack[128];
                    char* kcopy = (size_t)kl < sizeof kstack ? kstack : (char*)malloc((size_t)kl + 1);
                    if (!kcopy) { fail(s, "out of memory"); return 0; }
                    memcpy(kcopy, s->sbuf, (size_t)kl);
                    v = thing(s, depth + 1);
                    if (v) rk_set(s->c, h, kcopy, (size_t)kl, v);
                    if (kcopy != kstack) free(kcopy);
                    if (!v) return 0;
                }
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
            long n = jstring(s, &s->sbuf, &s->scap);
            if (n < 0) return 0;
            /* rk_str copies into the arena, so the shared buffer is free to be
               reused by the next string the moment this returns */
            return rk_str(s->c, s->sbuf, (size_t)n);
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
    s.sbuf = NULL; s.scap = 0;
    out = thing(&s, 0);
    if (out) {
        ws(&s);
        if (s.p != s.end) { fail(&s, "trailing content after the document"); out = 0; }
    }
    free(s.sbuf); /* one buffer for the whole parse — freed once, on every path */
    return out;
}

/* ---- serialising ---------------------------------------------------------
 *
 * One growable buffer for the whole document. Doubling, because a serializer
 * appends a few bytes at a time and reallocating per append is most of what a
 * naive one spends its life doing.
 */
typedef struct {
    char*  buf;
    size_t len;
    size_t cap;
    RkCtx  c;
    int    pretty;
    int    unsupported;   /* hit a type outside the ABI's vocabulary: stand aside */
} W;

static int wneed(W* w, size_t extra) {
    size_t want = w->len + extra + 1;
    if (want <= w->cap) return 1;
    while (w->cap < want) w->cap = w->cap ? w->cap * 2 : 256;
    w->buf = (char*)realloc(w->buf, w->cap);
    return w->buf != 0;
}
static void wmem(W* w, const char* s, size_t n) {
    if (!wneed(w, n)) return;
    memcpy(w->buf + w->len, s, n);
    w->len += n;
}
static void wstr(W* w, const char* s) { wmem(w, s, strlen(s)); }
static void wch(W* w, char ch) { if (wneed(w, 1)) w->buf[w->len++] = ch; }
static void windent(W* w, int depth) {
    int i;
    for (i = 0; i < depth * 2; i++) wch(w, ' ');
}

/* JSON::Fast's escaping, measured: \t \n \r by name; everything else below
 * 0x20 as lower-case \u00xx — 0x08 and 0x0c included, which is why there is no
 * \b or \f here. DEL, the solidus and every non-ASCII byte go through raw. */
static void wjson_str(W* w, const char* s, size_t n) {
    size_t i;
    wch(w, '"');
    for (i = 0; i < n; i++) {
        unsigned char ch = (unsigned char)s[i];
        switch (ch) {
            case '"':  wstr(w, "\\\""); break;
            case '\\': wstr(w, "\\\\"); break;
            case '\t': wstr(w, "\\t");  break;
            case '\n': wstr(w, "\\n");  break;
            case '\r': wstr(w, "\\r");  break;
            default:
                if (ch < 0x20) {
                    char esc[7];
                    snprintf(esc, sizeof esc, "\\u%04x", ch);
                    wstr(w, esc);
                }
                else wch(w, (char)ch);
        }
    }
    wch(w, '"');
}

/* The value's own Raku .Str, plus the suffix that keeps a float looking like
 * one. Never a printf of a double: reproducing Raku's shortest-round-trip
 * formatting in C is exactly the kind of near-enough this file must not do. */
static void wnumber(W* w, RkValue v, RkType t) {
    size_t n = 0;
    const char* s;
    if (t == RK_NUM) {
        double d = rk_num_get(w->c, v);
        if (isnan(d) || isinf(d)) { wstr(w, "null"); return; }
    }
    s = rk_str_get(w->c, v, &n);
    wmem(w, s, n);
    if (t == RK_NUM) {
        if (!memchr(s, 'e', n) && !memchr(s, 'E', n)) wstr(w, "e0");
    }
    else if (t == RK_RAT) {
        if (!memchr(s, '.', n)) wstr(w, ".0");
    }
}

static void wvalue(W* w, RkValue v, int depth) {
    RkType t = rk_type(w->c, v);
    if (w->unsupported) return;
    switch (t) {
        case RK_ANY:  wstr(w, "null"); return;
        case RK_BOOL: wstr(w, rk_truthy(w->c, v) ? "true" : "false"); return;
        case RK_INT: case RK_NUM: case RK_RAT: wnumber(w, v, t); return;
        case RK_STR: {
            size_t n = 0;
            const char* s = rk_str_get(w->c, v, &n);
            wjson_str(w, s, n);
            return;
        }
        case RK_ARRAY: {
            size_t n = rk_elems(w->c, v), i;
            wch(w, '[');
            for (i = 0; i < n; i++) {
                if (i) wch(w, ',');
                if (w->pretty) { wch(w, '\n'); windent(w, depth + 1); }
                wvalue(w, rk_at_pos(w->c, v, i), depth + 1);
                if (w->unsupported) return;
            }
            /* An empty array still gets the newline: JSON::Fast prints "[\n]". */
            if (w->pretty) { wch(w, '\n'); windent(w, depth); }
            wch(w, ']');
            return;
        }
        case RK_HASH: {
            size_t n = rk_elems(w->c, v), i;
            wch(w, '{');
            for (i = 0; i < n; i++) {
                size_t klen = 0;
                const char* k = rk_key_at(w->c, v, i, &klen);
                RkValue val;
                if (i) wch(w, ',');
                if (w->pretty) { wch(w, '\n'); windent(w, depth + 1); }
                wjson_str(w, k ? k : "", klen);
                wch(w, ':');
                if (w->pretty) wch(w, ' ');
                /* Read the value AFTER the key: both use the host's remembered
                 * iterator, and asking for the same index twice in a row is
                 * what keeps that memo on its fast path. */
                val = rk_val_at(w->c, v, i);
                wvalue(w, val, depth + 1);
                if (w->unsupported) return;
            }
            if (w->pretty) { wch(w, '\n'); windent(w, depth); }
            wch(w, '}');
            return;
        }
        default:
            /* RK_OTHER: a Date, an object, a Set — things JSON::Fast has its
             * own opinions about. Stand aside rather than invent one. */
            w->unsupported = 1;
            return;
    }
}

static RkValue to_json_native(RkCtx c) {
    RkValue pretty = rk_named(c, "pretty");
    RkValue out;
    W w;
    w.buf = 0; w.len = 0; w.cap = 0; w.c = c;
    w.pretty = pretty ? rk_truthy(c, pretty) : 1;   /* JSON::Fast's default */
    w.unsupported = 0;

    wvalue(&w, rk_arg(c, 0), 0);
    if (w.unsupported || !w.buf) {
        free(w.buf);
        /* Nil, which the Raku side reads as "use JSON::Fast for this one". */
        return rk_any(c);
    }
    out = rk_str(c, w.buf, w.len);
    free(w.buf);
    return out;
}

static const RkSubDef subs[] = {
    {"from-json-native", from_json_native},
    {"to-json-native",   to_json_native},
    {0, 0}
};
static const RkModule mod = { RAKUPP_EXT_ABI, "JSON::Native", subs };

RAKUPP_EXT_EXPORT const RkModule* rakupp_ext_init(unsigned host_abi) {
    /* `>=`: the serialiser needs ABI 2's amortised hash walk, so it needs a
     * host at least that new — and says so, rather than also refusing every
     * host newer than the one it was built against. */
    return host_abi >= RAKUPP_EXT_ABI ? &mod : 0;
}
