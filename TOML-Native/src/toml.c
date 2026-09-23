/* toml.c — the native half of TOML::Native.
 *
 * Plain C against <rakupp/rakupp_ext.h> and nothing else, for the reason
 * CSV::Native's csv.c gives: an extension that never sees the interpreter's
 * value layout keeps working across compiler releases.
 *
 * THE CONTRACT. This file and parse-raku in lib/TOML/Native.rakumod are two
 * spellings of ONE parser for TOML v1.0.0. The test suite runs every case
 * through both and demands the same data and the same error message, and the
 * conformance script in the repository's benchmarks/toml does the same over
 * the whole toml-test suite. So the two are written in the same shape —
 * the same functions, the same order of checks — and a change to one is a
 * change to the other.
 *
 * The document is parsed into a C tree first and converted to Raku values at
 * the end. Two reasons: the ABI has no lookup by key, and the rules about
 * which table may be extended where (a table defined twice, an inline table
 * extended, a dotted key reopening a table from an earlier section) need
 * flags per table that a Raku Hash has nowhere to keep. The tree lives in an
 * arena and in one hash map keyed by (parent, key), and is freed in one go.
 *
 * Dates and times cross back through rk_call: the ABI has no constructor for
 * a DateTime, so the module provides one small sub per type and both parsers
 * call the same ones — which is what makes their results identical objects.
 *
 * Errors are "TOML::Native: <what> at line N", raised by longjmp to the entry
 * point, which frees the tree and hands the message to rk_die. Only this
 * file's own frames are unwound; nothing of the host's is on that stack.
 */
#include <rakupp/rakupp_ext.h>

#include <math.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_DEPTH 128

/* ---- a growable byte buffer ---------------------------------------------- */
typedef struct {
    char*  buf;
    size_t len;
    size_t cap;
} Buf;

static int bneed(Buf* b, size_t extra) {
    size_t want = b->len + extra + 1;
    char* nb;
    if (want <= b->cap) return 1;
    while (b->cap < want) b->cap = b->cap ? b->cap * 2 : 256;
    nb = (char*)realloc(b->buf, b->cap);
    if (!nb) return 0;
    b->buf = nb;
    return 1;
}

/* ---- the tree ------------------------------------------------------------ */
enum { K_TABLE, K_ARRAY, K_STR, K_INT, K_FLOAT, K_BOOL, K_ODT, K_LDT, K_DATE, K_TIME };

typedef struct Node Node;
struct Node {
    unsigned char kind;
    unsigned char frozen;     /* an inline table or a static array: closed */
    unsigned char explicit_;  /* a table defined by a [header] */
    unsigned char aot;        /* an array created by [[header]] */
    int           depth;      /* containers from the root, which is 0 */
    long          dotted;     /* the section whose dotted keys defined it, or 0 */
    Node*         parent;
    const char*   key;
    size_t        keylen;
    Node*         first;      /* children: a table's entries, an array's items */
    Node*         last;
    Node*         next;
    union {
        struct { const char* s; size_t n; } str;
        long long i;
        double    f;
        int       b;
        struct {
            int y, mo, d, h, mi, s, off;
            const char* frac;
            size_t fracl;
        } dt;
    } v;
};

/* An arena: nodes and decoded strings, freed together. */
typedef struct Block { struct Block* next; size_t used, cap; } Block;

typedef struct {
    const char* p;
    const char* end;
    long        line;
    RkCtx       c;
    jmp_buf     jb;
    Block*      arena;
    Node**      map;        /* open addressing on (parent, key) */
    size_t      mapcap;
    size_t      mapn;
    long        section;    /* 1 for the root section, +1 per header */
    Buf         tmp;        /* decoding a string with escapes */
    Buf         msg;
    Node*       root;
} P;

static void oom(P* s);

static void* alloc(P* s, size_t n) {
    Block* b = s->arena;
    n = (n + 15) & ~(size_t)15;
    if (!b || b->used + n > b->cap) {
        size_t cap = n > 65536 ? n : 65536;
        Block* nb = (Block*)malloc(sizeof(Block) + 16 + cap);
        if (!nb) oom(s);
        nb->next = s->arena; nb->used = 0; nb->cap = cap;
        s->arena = nb;
        b = nb;
    }
    {
        char* base = (char*)(b + 1);
        base += (16 - ((uintptr_t)base & 15)) & 15;
        void* r = base + b->used;
        b->used += n;
        return r;
    }
}

static void cleanup(P* s) {
    Block* b = s->arena;
    while (b) { Block* n = b->next; free(b); b = n; }
    s->arena = 0;
    free(s->map); s->map = 0;
    free(s->tmp.buf); s->tmp.buf = 0;
    free(s->msg.buf); s->msg.buf = 0;
}

/* ---- errors -------------------------------------------------------------- */
static void msg_add(P* s, const char* t, size_t n) {
    if (!bneed(&s->msg, n)) return;
    memcpy(s->msg.buf + s->msg.len, t, n);
    s->msg.len += n;
}
static void msg_str(P* s, const char* t) { msg_add(s, t, strlen(t)); }

static void raise_msg(P* s, long line) {
    char tail[64];
    snprintf(tail, sizeof tail, " at line %ld", line);
    msg_str(s, tail);
    longjmp(s->jb, 1);
}

static void fail_at(P* s, const char* what, long line) {
    s->msg.len = 0;
    msg_str(s, "TOML::Native: ");
    msg_str(s, what);
    raise_msg(s, line);
}
static void fail(P* s, const char* what) { fail_at(s, what, s->line); }

static void oom(P* s) {
    s->msg.len = 0;
    msg_str(s, "TOML::Native: out of memory");
    longjmp(s->jb, 1);
}

static void fail_ctrl(P* s, unsigned ch, const char* where) {
    char b[80];
    snprintf(b, sizeof b, "control character U+%04X in %s", ch, where);
    fail(s, b);
}

/* A key as written, up to part `upto`: the parts joined with dots. */
typedef struct { const char* k; size_t n; } Part;
typedef struct { Part* v; size_t n, cap; } Key;

static void fail_key(P* s, const char* pre, Key* key, size_t upto, const char* post, long line) {
    size_t i;
    s->msg.len = 0;
    msg_str(s, "TOML::Native: ");
    msg_str(s, pre);
    msg_str(s, "'");
    for (i = 0; i <= upto; i++) {
        if (i) msg_str(s, ".");
        msg_add(s, key->v[i].k, key->v[i].n);
    }
    msg_str(s, "'");
    msg_str(s, post);
    raise_msg(s, line);
}

/* ---- the (parent, key) map ----------------------------------------------- */
static size_t hkey(const Node* parent, const char* k, size_t n) {
    size_t h = (size_t)1469598103934665603ULL ^ ((size_t)(uintptr_t)parent >> 4);
    size_t i;
    for (i = 0; i < n; i++) { h ^= (unsigned char)k[i]; h *= (size_t)1099511628211ULL; }
    return h;
}

static Node* lookup(P* s, Node* t, const char* k, size_t n) {
    size_t i;
    if (!s->mapcap) return 0;
    i = hkey(t, k, n) & (s->mapcap - 1);
    for (;;) {
        Node* e = s->map[i];
        if (!e) return 0;
        if (e->parent == t && e->keylen == n && memcmp(e->key, k, n) == 0) return e;
        i = (i + 1) & (s->mapcap - 1);
    }
}

static void map_put(P* s, Node* e) {
    size_t i;
    if ((s->mapn + 1) * 2 > s->mapcap) {
        size_t nc = s->mapcap ? s->mapcap * 2 : 1024, j;
        Node** nm = (Node**)calloc(nc, sizeof(Node*));
        if (!nm) oom(s);
        for (j = 0; j < s->mapcap; j++) {
            Node* o = s->map[j];
            if (o) {
                size_t k = hkey(o->parent, o->key, o->keylen) & (nc - 1);
                while (nm[k]) k = (k + 1) & (nc - 1);
                nm[k] = o;
            }
        }
        free(s->map);
        s->map = nm; s->mapcap = nc;
    }
    i = hkey(e->parent, e->key, e->keylen) & (s->mapcap - 1);
    while (s->map[i]) i = (i + 1) & (s->mapcap - 1);
    s->map[i] = e;
    s->mapn++;
}

static Node* node(P* s, int kind) {
    Node* n = (Node*)alloc(s, sizeof(Node));
    memset(n, 0, sizeof *n);
    n->kind = (unsigned char)kind;
    return n;
}

static void link_child(Node* parent, Node* child) {
    if (parent->last) parent->last->next = child;
    else parent->first = child;
    parent->last = child;
}

static void add_child(P* s, Node* t, const Part* k, Node* child) {
    child->parent = t;
    child->key = k->k;
    child->keylen = k->n;
    link_child(t, child);
    map_put(s, child);
}

static Node* container(P* s, int kind, int depth) {
    Node* n;
    if (depth > MAX_DEPTH) fail(s, "nesting deeper than 128 levels");
    n = node(s, kind);
    n->depth = depth;
    return n;
}

/* ---- the scanner --------------------------------------------------------- */
#define AT_END(s)  ((s)->p >= (s)->end)
#define PEEK(s, o) ((s)->p + (o) < (s)->end ? (s)->p[o] : '\0')

/* A line ending here? 1 for LF, 2 for CRLF, 0 otherwise — a lone CR is not
   one, and is reported by whoever finds it. */
static int nl_len(P* s) {
    if (AT_END(s)) return 0;
    if (*s->p == '\n') return 1;
    if (*s->p == '\r' && s->p + 1 < s->end && s->p[1] == '\n') return 2;
    return 0;
}

static void skip_ws(P* s) {
    while (s->p < s->end && (*s->p == ' ' || *s->p == '\t')) s->p++;
}

static int is_ctrl(unsigned char c) { return (c < 0x20 && c != '\t') || c == 0x7f; }

/* At '#': the comment, up to (not including) the line ending. */
static void comment(P* s) {
    s->p++;
    while (s->p < s->end) {
        unsigned char c = (unsigned char)*s->p;
        if (c == '\n' || nl_len(s)) return;
        if (is_ctrl(c)) fail_ctrl(s, c, "a comment");
        s->p++;
    }
}

/* After a key/value pair or a header: nothing but a comment may follow. */
static void end_of_line(P* s) {
    int n;
    skip_ws(s);
    if (!AT_END(s) && *s->p == '#') comment(s);
    if (AT_END(s)) return;
    n = nl_len(s);
    if (!n) fail(s, "expected the end of the line");
    s->p += n;
    s->line++;
}

/* Spaces, tabs, line endings and comments: between array elements. */
static void skip_ws_nl(P* s) {
    for (;;) {
        int n;
        skip_ws(s);
        if (AT_END(s)) return;
        if (*s->p == '#') { comment(s); continue; }
        n = nl_len(s);
        if (!n) return;
        s->p += n;
        s->line++;
    }
}

/* ---- strings ------------------------------------------------------------- */
static void tmp_add(P* s, const char* t, size_t n) {
    if (!bneed(&s->tmp, n)) oom(s);
    memcpy(s->tmp.buf + s->tmp.len, t, n);
    s->tmp.len += n;
}

static void tmp_utf8(P* s, unsigned long cp) {
    char b[4];
    size_t n;
    if (cp < 0x80) { b[0] = (char)cp; n = 1; }
    else if (cp < 0x800) { b[0] = (char)(0xC0 | (cp >> 6)); b[1] = (char)(0x80 | (cp & 0x3F)); n = 2; }
    else if (cp < 0x10000) {
        b[0] = (char)(0xE0 | (cp >> 12)); b[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        b[2] = (char)(0x80 | (cp & 0x3F)); n = 3;
    }
    else {
        b[0] = (char)(0xF0 | (cp >> 18)); b[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        b[2] = (char)(0x80 | ((cp >> 6) & 0x3F)); b[3] = (char)(0x80 | (cp & 0x3F)); n = 4;
    }
    tmp_add(s, b, n);
}

/* The decoded text so far, copied into the arena so it outlives tmp.
 *
 * Text assembled here — around an escape, or across a trimmed line ending —
 * can put a combining mark after a character it did not follow in the source
 * ("e\u0301"). Raku++ builds a Str from UTF-8 without composing such a pair
 * (2026-09-23), and a Str built in Raku with ~ composes it, so the two
 * implementations' strings would look the same and compare unequal. So
 * non-ASCII text from here is sent through the module's toml-native-nfc and
 * the composed form is kept; ASCII cannot need it and is not sent. */
static Part tmp_keep(P* s) {
    Part r;
    const char* src = s->tmp.buf;
    size_t n = s->tmp.len, i;
    char* d;
    for (i = 0; i < n; i++) {
        if ((unsigned char)src[i] >= 0x80) {
            RkValue arg = rk_str(s->c, src, n);
            RkValue got = rk_call(s->c, "toml-native-nfc", &arg, 1);
            if (got) src = rk_str_get(s->c, got, &n);
            else rk_clear_error(s->c);
            break;
        }
    }
    d = (char*)alloc(s, n ? n : 1);
    memcpy(d, src, n);
    r.k = d; r.n = n;
    return r;
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* At the backslash of an escape in a basic string; appends what it means. */
static void escape(P* s) {
    char e = PEEK(s, 1);
    int n = 0, i;
    unsigned long cp = 0;
    switch (e) {
        case 'b':  tmp_add(s, "\b", 1); s->p += 2; return;
        case 't':  tmp_add(s, "\t", 1); s->p += 2; return;
        case 'n':  tmp_add(s, "\n", 1); s->p += 2; return;
        case 'f':  tmp_add(s, "\f", 1); s->p += 2; return;
        case 'r':  tmp_add(s, "\r", 1); s->p += 2; return;
        case '"':  tmp_add(s, "\"", 1); s->p += 2; return;
        case '\\': tmp_add(s, "\\", 1); s->p += 2; return;
        case 'u':  n = 4; break;
        case 'U':  n = 8; break;
        default:   fail(s, "invalid escape sequence");
    }
    for (i = 0; i < n; i++) {
        int h = hexval(PEEK(s, 2 + i));
        if (h < 0) fail(s, "invalid Unicode escape");
        cp = cp * 16 + (unsigned long)h;
    }
    if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) fail(s, "invalid Unicode escape");
    tmp_utf8(s, cp);
    s->p += 2 + n;
}

/* "...": at the opening quote. */
static Part basic_string(P* s) {
    const char* start;
    Part r;
    int escaped = 0;
    s->p++;
    start = s->p;
    s->tmp.len = 0;
    for (;;) {
        unsigned char c;
        if (AT_END(s)) fail(s, "unterminated string");
        c = (unsigned char)*s->p;
        if (c == '"') break;
        if (c == '\\') {
            if (!escaped) { tmp_add(s, start, (size_t)(s->p - start)); escaped = 1; }
            escape(s);
            continue;
        }
        if (c == '\n' || nl_len(s)) fail(s, "unterminated string");
        if (is_ctrl(c)) fail_ctrl(s, c, "a string");
        if (escaped) tmp_add(s, (const char*)s->p, 1);
        s->p++;
    }
    if (escaped) r = tmp_keep(s);
    else { r.k = start; r.n = (size_t)(s->p - start); }
    s->p++;
    return r;
}

/* '...': at the opening quote. */
static Part literal_string(P* s) {
    Part r;
    s->p++;
    r.k = s->p;
    for (;;) {
        unsigned char c;
        if (AT_END(s)) fail(s, "unterminated string");
        c = (unsigned char)*s->p;
        if (c == '\'') break;
        if (c == '\n' || nl_len(s)) fail(s, "unterminated string");
        if (is_ctrl(c)) fail_ctrl(s, c, "a string");
        s->p++;
    }
    r.n = (size_t)(s->p - r.k);
    s->p++;
    return r;
}

/* """...""" and '''...''': at the first of the three quotes. A line ending
   straight after the opening quotes is dropped; CRLF inside is kept as LF,
   so a document means the same whichever line endings it was saved with;
   one or two quotes may sit just before the closing three. */
static Part ml_string(P* s, char q) {
    long open_line = s->line;
    int n;
    s->p += 3;
    s->tmp.len = 0;
    n = nl_len(s);
    if (n) { s->p += n; s->line++; }
    for (;;) {
        unsigned char c;
        if (AT_END(s)) fail_at(s, "unterminated multi-line string", open_line);
        c = (unsigned char)*s->p;
        if (c == (unsigned char)q && PEEK(s, 1) == q && PEEK(s, 2) == q) {
            s->p += 3;
            if (!AT_END(s) && *s->p == q) {
                tmp_add(s, &q, 1); s->p++;
                if (!AT_END(s) && *s->p == q) { tmp_add(s, &q, 1); s->p++; }
            }
            return tmp_keep(s);
        }
        if (c == '\\' && q == '"') {
            /* a backslash at the end of a line eats the line ending and all
               the whitespace after it */
            const char* save = s->p;
            s->p++;
            skip_ws(s);
            if (nl_len(s)) {
                for (;;) {
                    skip_ws(s);
                    n = nl_len(s);
                    if (!n) break;
                    s->p += n; s->line++;
                }
                continue;
            }
            s->p = save;
            escape(s);
            continue;
        }
        n = nl_len(s);
        if (n) { tmp_add(s, "\n", 1); s->p += n; s->line++; continue; }
        if (is_ctrl(c)) fail_ctrl(s, c, "a string");
        tmp_add(s, (const char*)s->p, 1);
        s->p++;
    }
}

/* ---- keys ---------------------------------------------------------------- */
static int is_bare(unsigned char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
           c == '_' || c == '-';
}

static void key_push(P* s, Key* key, Part p) {
    /* grown in the arena, not with realloc: an error longjmps past every
       caller, and the arena is the one thing that is always freed */
    if (key->n == key->cap) {
        size_t nc = key->cap ? key->cap * 2 : 8;
        Part* nv = (Part*)alloc(s, nc * sizeof(Part));
        if (key->n) memcpy(nv, key->v, key->n * sizeof(Part));
        key->v = nv; key->cap = nc;
    }
    key->v[key->n++] = p;
}

/* A dotted key, parts decoded. Leading whitespace is skipped; trailing is
   too, so the caller sees the '=' or ']' next. */
static void parse_key(P* s, Key* key) {
    key->n = 0;
    for (;;) {
        Part part = {0, 0};
        skip_ws(s);
        if (AT_END(s)) fail(s, "expected a key");
        if (*s->p == '"') part = basic_string(s);
        else if (*s->p == '\'') part = literal_string(s);
        else if (is_bare((unsigned char)*s->p)) {
            part.k = s->p;
            while (s->p < s->end && is_bare((unsigned char)*s->p)) s->p++;
            part.n = (size_t)(s->p - part.k);
        }
        else fail(s, "expected a key");
        key_push(s, key, part);
        skip_ws(s);
        if (!AT_END(s) && *s->p == '.') { s->p++; continue; }
        return;
    }
}

/* ---- numbers ------------------------------------------------------------- */
static int is_numchar(unsigned char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           c == '_' || c == '.' || c == '+' || c == '-';
}
static int is_dig(char c) { return c >= '0' && c <= '9'; }

/* Digits of a base with single underscores between them; appends the digits
   to tmp. Returns the count of digits, or -1 on a misplaced underscore. */
static int digits(P* s, const char** pp, const char* end, int base) {
    const char* p = *pp;
    int count = 0;
    for (;;) {
        char c = p < end ? *p : '\0';
        int v = hexval(c);
        if (v >= 0 && v < base) { tmp_add(s, p, 1); count++; p++; continue; }
        if (c == '_') {
            char d = p + 1 < end ? p[1] : '\0';
            int w = hexval(d);
            if (!count || w < 0 || w >= base) return -1;
            p++;
            continue;
        }
        break;
    }
    *pp = p;
    return count;
}

static Node* number(P* s) {
    const char* start = s->p;
    const char* p;
    const char* end;
    Node* n;
    int neg = 0, sign = 0;
    while (s->p < s->end && is_numchar((unsigned char)*s->p)) s->p++;
    end = s->p;
    p = start;
    if (*p == '+' || *p == '-') { neg = *p == '-'; sign = 1; p++; }
    {
        size_t rest = (size_t)(end - p);
        if ((rest == 3 && memcmp(p, "inf", 3) == 0) || (rest == 3 && memcmp(p, "nan", 3) == 0)) {
            n = node(s, K_FLOAT);
            n->v.f = p[0] == 'n' ? NAN : (neg ? -INFINITY : INFINITY);
            return n;
        }
    }
    if (p == end || !is_dig(*p)) fail(s, sign ? "invalid number" : "expected a value");
    s->tmp.len = 0;
    if (p + 1 < end && p[0] == '0' && (p[1] == 'x' || p[1] == 'o' || p[1] == 'b')) {
        int base = p[1] == 'x' ? 16 : p[1] == 'o' ? 8 : 2;
        unsigned long long v = 0;
        size_t i;
        if (sign) fail(s, "invalid number");
        p += 2;
        if (digits(s, &p, end, base) <= 0 || p != end) fail(s, "invalid number");
        for (i = 0; i < s->tmp.len; i++) {
            unsigned long long d = (unsigned long long)hexval(s->tmp.buf[i]);
            if (v > (0x7FFFFFFFFFFFFFFFULL - d) / (unsigned long long)base)
                fail(s, "integer out of range");
            v = v * (unsigned long long)base + d;
        }
        n = node(s, K_INT);
        n->v.i = (long long)v;
        return n;
    }
    {
        int ints, is_float = 0;
        if (neg) tmp_add(s, "-", 1);
        ints = digits(s, &p, end, 10);
        if (ints <= 0) fail(s, "invalid number");
        if (ints > 1 && s->tmp.buf[neg] == '0') fail(s, "invalid number");
        if (p < end && *p == '.') {
            tmp_add(s, ".", 1);
            p++;
            if (digits(s, &p, end, 10) <= 0) fail(s, "invalid number");
            is_float = 1;
        }
        if (p < end && (*p == 'e' || *p == 'E')) {
            tmp_add(s, "e", 1);
            p++;
            if (p < end && (*p == '+' || *p == '-')) { tmp_add(s, p, 1); p++; }
            if (digits(s, &p, end, 10) <= 0) fail(s, "invalid number");
            is_float = 1;
        }
        if (p != end) fail(s, "invalid number");
        tmp_add(s, "", 1);   /* NUL, for strtod */
        if (is_float) {
            n = node(s, K_FLOAT);
            n->v.f = strtod(s->tmp.buf, 0);
            return n;
        }
        {
            unsigned long long v = 0, lim = neg ? 0x8000000000000000ULL : 0x7FFFFFFFFFFFFFFFULL;
            const char* d = s->tmp.buf + neg;
            while (*d) {
                unsigned long long x = (unsigned long long)(*d - '0');
                if (v > (lim - x) / 10) fail(s, "integer out of range");
                v = v * 10 + x;
                d++;
            }
            n = node(s, K_INT);
            n->v.i = neg ? (long long)(0 - v) : (long long)v;
            return n;
        }
    }
}

/* ---- dates and times ----------------------------------------------------- */
static int fixed(P* s, int count) {
    int v = 0, i;
    for (i = 0; i < count; i++) {
        char c = PEEK(s, i);
        if (!is_dig(c)) fail(s, "malformed date or time");
        v = v * 10 + (c - '0');
    }
    s->p += count;
    return v;
}
static void expect_char(P* s, char c) {
    if (AT_END(s) || *s->p != c) fail(s, "malformed date or time");
    s->p++;
}

static void time_part(P* s, Node* n) {
    n->v.dt.h = fixed(s, 2);
    expect_char(s, ':');
    n->v.dt.mi = fixed(s, 2);
    expect_char(s, ':');
    n->v.dt.s = fixed(s, 2);
    n->v.dt.frac = "";
    n->v.dt.fracl = 0;
    if (!AT_END(s) && *s->p == '.') {
        const char* f;
        s->p++;
        f = s->p;
        while (s->p < s->end && is_dig(*s->p)) s->p++;
        if (s->p == f) fail(s, "malformed date or time");
        n->v.dt.frac = f;
        n->v.dt.fracl = (size_t)(s->p - f);
    }
    /* seconds stop at 59: a leap second is valid TOML, but DateTime refuses
       one outside the leap-second table, and differently on each engine */
    if (n->v.dt.h > 23 || n->v.dt.mi > 59 || n->v.dt.s > 59) fail(s, "invalid time");
}

static Node* datetime(P* s) {
    static const int dim[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    Node* n = node(s, K_DATE);
    int y, mo, d, max;
    y = fixed(s, 4);
    expect_char(s, '-');
    mo = fixed(s, 2);
    expect_char(s, '-');
    d = fixed(s, 2);
    if (mo < 1 || mo > 12) fail(s, "invalid date");
    max = dim[mo - 1];
    if (mo == 2 && y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) max = 29;
    if (d < 1 || d > max) fail(s, "invalid date");
    n->v.dt.y = y; n->v.dt.mo = mo; n->v.dt.d = d;
    if (!AT_END(s) && (*s->p == 'T' || *s->p == 't' || (*s->p == ' ' && is_dig(PEEK(s, 1))))) {
        s->p++;
        time_part(s, n);
        if (!AT_END(s) && (*s->p == 'Z' || *s->p == 'z')) {
            s->p++;
            n->kind = K_ODT;
            n->v.dt.off = 0;
        }
        else if (!AT_END(s) && (*s->p == '+' || *s->p == '-')) {
            int neg = *s->p == '-', oh, om;
            s->p++;
            oh = fixed(s, 2);
            expect_char(s, ':');
            om = fixed(s, 2);
            if (oh > 23 || om > 59) fail(s, "invalid time offset");
            n->kind = K_ODT;
            n->v.dt.off = (neg ? -1 : 1) * (oh * 60 + om);
        }
        else n->kind = K_LDT;
    }
    return n;
}

/* ---- values -------------------------------------------------------------- */
static Node* value(P* s, int depth);

static Node* str_node(P* s, Part p) {
    Node* n = node(s, K_STR);
    n->v.str.s = p.k;
    n->v.str.n = p.n;
    return n;
}

static Node* array(P* s, int depth) {
    long open_line = s->line;
    Node* a = container(s, K_ARRAY, depth);
    a->frozen = 1;
    s->p++;
    for (;;) {
        skip_ws_nl(s);
        if (AT_END(s)) fail_at(s, "unterminated array", open_line);
        if (*s->p == ']') { s->p++; return a; }
        link_child(a, value(s, depth + 1));
        skip_ws_nl(s);
        if (AT_END(s)) fail_at(s, "unterminated array", open_line);
        if (*s->p == ',') { s->p++; continue; }
        if (*s->p == ']') { s->p++; return a; }
        fail(s, "expected ',' or ']' in an array");
    }
}

static Node* inline_table(P* s, int depth) {
    Node* t = container(s, K_TABLE, depth);
    Key key = {0, 0, 0};
    s->p++;
    skip_ws(s);
    if (!AT_END(s) && *s->p == '}') { s->p++; t->frozen = 1; return t; }
    for (;;) {
        Node* cur = t;
        Node* v;
        size_t i;
        long kline;
        parse_key(s, &key);
        if (AT_END(s) || *s->p != '=') fail(s, "expected '=' after a key");
        s->p++;
        skip_ws(s);
        kline = s->line;
        v = value(s, depth + (int)key.n);
        /* within an inline table: dotted keys may build its sub-tables, but
           nothing already closed may be reopened */
        for (i = 0; i + 1 < key.n; i++) {
            Node* child = lookup(s, cur, key.v[i].k, key.v[i].n);
            if (!child) {
                child = container(s, K_TABLE, cur->depth + 1);
                add_child(s, cur, &key.v[i], child);
            }
            else if (child->kind == K_TABLE) {
                if (child->frozen) fail_key(s, "inline table ", &key, i, " cannot be extended", kline);
            }
            else if (child->kind == K_ARRAY) fail_key(s, "static array ", &key, i, " cannot be extended", kline);
            else fail_key(s, "duplicate key ", &key, i, "", kline);
            cur = child;
        }
        if (lookup(s, cur, key.v[key.n - 1].k, key.v[key.n - 1].n))
            fail_key(s, "duplicate key ", &key, key.n - 1, "", kline);
        add_child(s, cur, &key.v[key.n - 1], v);
        skip_ws(s);
        if (!AT_END(s) && *s->p == ',') {
            s->p++;
            skip_ws(s);
            if (!AT_END(s) && *s->p == '}') fail(s, "trailing comma in an inline table");
            continue;
        }
        if (!AT_END(s) && *s->p == '}') { s->p++; break; }
        fail(s, "expected ',' or '}' in an inline table");
    }
    t->frozen = 1;
    return t;
}

static Node* value(P* s, int depth) {
    char c;
    if (AT_END(s)) fail(s, "expected a value");
    c = *s->p;
    if (c == '"') {
        if (PEEK(s, 1) == '"' && PEEK(s, 2) == '"') return str_node(s, ml_string(s, '"'));
        return str_node(s, basic_string(s));
    }
    if (c == '\'') {
        if (PEEK(s, 1) == '\'' && PEEK(s, 2) == '\'') return str_node(s, ml_string(s, '\''));
        return str_node(s, literal_string(s));
    }
    if (c == 't' && s->end - s->p >= 4 && memcmp(s->p, "true", 4) == 0) {
        Node* n = node(s, K_BOOL);
        n->v.b = 1; s->p += 4;
        return n;
    }
    if (c == 'f' && s->end - s->p >= 5 && memcmp(s->p, "false", 5) == 0) {
        Node* n = node(s, K_BOOL);
        n->v.b = 0; s->p += 5;
        return n;
    }
    if (c == '[') return array(s, depth);
    if (c == '{') return inline_table(s, depth);
    if (is_dig(c)) {
        if (is_dig(PEEK(s, 1)) && is_dig(PEEK(s, 2)) && is_dig(PEEK(s, 3)) && PEEK(s, 4) == '-')
            return datetime(s);
        if (is_dig(PEEK(s, 1)) && PEEK(s, 2) == ':') {
            Node* n = node(s, K_TIME);
            time_part(s, n);
            return n;
        }
        return number(s);
    }
    if (c == '+' || c == '-' || c == 'i' || c == 'n') return number(s);
    fail(s, "expected a value");
    return 0;
}

/* ---- the document -------------------------------------------------------- */

/* [key] or [[key]]: at the first bracket. Returns the table that the
   following key/value pairs go into. */
static Node* header(P* s, Key* key) {
    int aot = PEEK(s, 1) == '[';
    long hline = s->line;
    Node* t = s->root;
    Node* child;
    size_t i, last;
    s->p += aot ? 2 : 1;
    s->section++;
    parse_key(s, key);
    if (aot) {
        if (PEEK(s, 0) != ']' || PEEK(s, 1) != ']') fail(s, "expected ']]' to close an array-of-tables header");
        s->p += 2;
    }
    else {
        if (AT_END(s) || *s->p != ']') fail(s, "expected ']' to close a table header");
        s->p++;
    }
    last = key->n - 1;
    for (i = 0; i < last; i++) {
        child = lookup(s, t, key->v[i].k, key->v[i].n);
        if (!child) {
            child = container(s, K_TABLE, t->depth + 1);
            add_child(s, t, &key->v[i], child);
        }
        else if (child->kind == K_TABLE) {
            if (child->frozen) fail_key(s, "inline table ", key, i, " cannot be extended", hline);
        }
        else if (child->kind == K_ARRAY) {
            if (!child->aot) fail_key(s, "static array ", key, i, " cannot be extended", hline);
            child = child->last;
        }
        else fail_key(s, "duplicate key ", key, i, "", hline);
        t = child;
    }
    child = lookup(s, t, key->v[last].k, key->v[last].n);
    if (!aot) {
        if (!child) {
            child = container(s, K_TABLE, t->depth + 1);
            add_child(s, t, &key->v[last], child);
        }
        else if (child->kind == K_TABLE) {
            if (child->frozen) fail_key(s, "inline table ", key, last, " cannot be extended", hline);
            if (child->explicit_ || child->dotted) fail_key(s, "table ", key, last, " is defined twice", hline);
        }
        else if (child->kind == K_ARRAY) {
            if (child->aot) fail_key(s, "table ", key, last, " is defined twice", hline);
            fail_key(s, "static array ", key, last, " cannot be extended", hline);
        }
        else fail_key(s, "duplicate key ", key, last, "", hline);
        child->explicit_ = 1;
        return child;
    }
    {
        Node* elem;
        if (!child) {
            child = container(s, K_ARRAY, t->depth + 1);
            child->aot = 1;
            add_child(s, t, &key->v[last], child);
        }
        else if (child->kind == K_ARRAY) {
            if (!child->aot) fail_key(s, "cannot append to static array ", key, last, "", hline);
        }
        else if (child->kind == K_TABLE) {
            if (child->frozen) fail_key(s, "inline table ", key, last, " cannot be extended", hline);
            fail_key(s, "table ", key, last, " is defined twice", hline);
        }
        else fail_key(s, "duplicate key ", key, last, "", hline);
        elem = container(s, K_TABLE, child->depth + 1);
        link_child(child, elem);
        return elem;
    }
}

/* key = value, into the current section's table. */
static void keyval(P* s, Node* t, Key* key) {
    long kline = s->line;
    Node* v;
    size_t i, last;
    parse_key(s, key);
    if (AT_END(s) || *s->p != '=') fail(s, "expected '=' after a key");
    s->p++;
    skip_ws(s);
    v = value(s, t->depth + (int)key->n);
    last = key->n - 1;
    for (i = 0; i < last; i++) {
        Node* child = lookup(s, t, key->v[i].k, key->v[i].n);
        if (!child) {
            child = container(s, K_TABLE, t->depth + 1);
            child->dotted = s->section;
            add_child(s, t, &key->v[i], child);
        }
        else if (child->kind == K_TABLE) {
            if (child->frozen) fail_key(s, "inline table ", key, i, " cannot be extended", kline);
            if (child->explicit_ || (child->dotted && child->dotted != s->section))
                fail_key(s, "cannot reopen table ", key, i, " with a dotted key", kline);
            child->dotted = s->section;
        }
        else if (child->kind == K_ARRAY) {
            if (child->aot) fail_key(s, "cannot reopen table ", key, i, " with a dotted key", kline);
            fail_key(s, "static array ", key, i, " cannot be extended", kline);
        }
        else fail_key(s, "duplicate key ", key, i, "", kline);
        t = child;
    }
    if (lookup(s, t, key->v[last].k, key->v[last].n))
        fail_key(s, "duplicate key ", key, last, "", kline);
    add_child(s, t, &key->v[last], v);
}

static void document(P* s) {
    Node* cur = s->root;
    Key key = {0, 0, 0};
    /* a byte-order mark is an encoding's signature, not content */
    if (s->end - s->p >= 3 && (unsigned char)s->p[0] == 0xEF && (unsigned char)s->p[1] == 0xBB &&
        (unsigned char)s->p[2] == 0xBF) s->p += 3;
    for (;;) {
        int n;
        skip_ws(s);
        if (AT_END(s)) break;
        n = nl_len(s);
        if (n) { s->p += n; s->line++; continue; }
        if (*s->p == '#') { comment(s); end_of_line(s); continue; }
        if (*s->p == '[') cur = header(s, &key);
        else keyval(s, cur, &key);
        end_of_line(s);
    }
}

/* ---- to Raku values ------------------------------------------------------ */
static RkValue convert(P* s, Node* n) {
    RkCtx c = s->c;
    switch (n->kind) {
        case K_TABLE: {
            RkValue h = rk_hash(c);
            Node* k;
            for (k = n->first; k; k = k->next) {
                RkValue v = convert(s, k);
                if (!v) return 0;
                rk_set(c, h, k->key, k->keylen, v);
            }
            return h;
        }
        case K_ARRAY: {
            RkValue a = rk_array(c);
            Node* k;
            for (k = n->first; k; k = k->next) {
                RkValue v = convert(s, k);
                if (!v) return 0;
                rk_push(c, a, v);
            }
            return a;
        }
        case K_STR:   return rk_str(c, n->v.str.s, n->v.str.n);
        case K_INT:   return rk_int(c, n->v.i);
        case K_FLOAT: return rk_num(c, n->v.f);
        case K_BOOL:  return rk_bool(c, n->v.b);
        case K_DATE: {
            RkValue a[3];
            a[0] = rk_int(c, n->v.dt.y); a[1] = rk_int(c, n->v.dt.mo); a[2] = rk_int(c, n->v.dt.d);
            return rk_call(c, "toml-native-date", a, 3);
        }
        case K_TIME: {
            RkValue a[4];
            a[0] = rk_int(c, n->v.dt.h); a[1] = rk_int(c, n->v.dt.mi); a[2] = rk_int(c, n->v.dt.s);
            a[3] = rk_str(c, n->v.dt.frac, n->v.dt.fracl);
            return rk_call(c, "toml-native-time", a, 4);
        }
        default: {   /* K_ODT, K_LDT */
            RkValue a[8];
            a[0] = rk_int(c, n->v.dt.y); a[1] = rk_int(c, n->v.dt.mo); a[2] = rk_int(c, n->v.dt.d);
            a[3] = rk_int(c, n->v.dt.h); a[4] = rk_int(c, n->v.dt.mi); a[5] = rk_int(c, n->v.dt.s);
            a[6] = rk_str(c, n->v.dt.frac, n->v.dt.fracl);
            if (n->kind == K_LDT) return rk_call(c, "toml-native-local-datetime", a, 7);
            a[7] = rk_int(c, n->v.dt.off);
            return rk_call(c, "toml-native-datetime", a, 8);
        }
    }
}

static RkValue from_toml_native(RkCtx c) {
    size_t len = 0;
    const char* text = rk_str_get(c, rk_arg(c, 0), &len);
    /* on the heap, not the stack: the state changes between setjmp and a
       longjmp, and only memory that is not a local of this frame is certain
       to hold its latest values afterwards */
    P* s = (P*)calloc(1, sizeof(P));
    RkValue out;
    if (!s) { rk_die(c, "TOML::Native: out of memory"); return 0; }
    s->c = c;
    s->p = text;
    s->end = text + len;
    s->line = 1;
    s->section = 1;
    if (setjmp(s->jb)) {
        if (!bneed(&s->msg, 0)) rk_die(c, "TOML::Native: out of memory");
        else { s->msg.buf[s->msg.len] = '\0'; rk_die(c, s->msg.buf); }
        cleanup(s);
        free(s);
        return 0;
    }
    s->root = container(s, K_TABLE, 0);
    document(s);
    out = convert(s, s->root);
    cleanup(s);
    free(s);
    return out;
}

static const RkSubDef subs[] = {
    {"from-toml-native", from_toml_native},
    {0, 0}
};
/* ABI 2 is what this file needs — rk_call, for the dates and times and the
   composing of text — and nothing of ABI 3's, so it says 2 and loads on any
   host from 2 on. */
#define TOML_NATIVE_ABI 2u
static const RkModule mod = { TOML_NATIVE_ABI, "TOML::Native", subs };

RAKUPP_EXT_EXPORT const RkModule* rakupp_ext_init(unsigned host_abi) {
    return host_abi >= TOML_NATIVE_ABI ? &mod : 0;
}
