/* yaml.c — the native half of YAML::Native.
 *
 * Plain C against <rakupp/rakupp_ext.h> and nothing else, for the reason
 * CSV::Native's csv.c gives: an extension that never sees the interpreter's
 * value layout keeps working across compiler releases.
 *
 * THE CONTRACT. This file and the Raku parser in lib/YAML/Native.rakumod are
 * two spellings of ONE parser for YAML 1.2. The test suite runs every case
 * through both and demands the same data, the same event stream and the same
 * error message, and the conformance script in the repository's
 * benchmarks/yaml does the same over the whole yaml-test-suite. So the two are
 * written in the same shape — the same functions, the same order of checks —
 * and a change to one is a change to the other.
 *
 * Three stages, as libyaml has them, though none of libyaml's code:
 *
 *   the scanner   text -> tokens. YAML's hard part: indentation becomes
 *                 BLOCK-MAPPING-START / BLOCK-END tokens, and a key is only
 *                 known to be a key when the ':' after it is seen, so a KEY
 *                 token is inserted back into the queue at that point.
 *   the parser    tokens -> a node tree, by recursive descent, one tree per
 *                 document. Nodes keep their style, tag and anchor, and an
 *                 alias stays an alias, so the tree can be printed back as
 *                 the yaml-test-suite's event stream (the `events` entry).
 *   construction  tree -> Raku values, resolving plain scalars by the YAML
 *                 1.2 core schema, following aliases and merge keys.
 *
 * Errors are "YAML::Native: <what> at line N", raised by longjmp to the entry
 * point, which frees everything and hands the message to rk_die. Only this
 * file's own frames are unwound; nothing of the host's is on that stack.
 */
#include <rakupp/rakupp_ext.h>

#include <errno.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_DEPTH  128        /* nested collections */
#define MAX_ALIAS  1000000    /* nodes that aliases may add to one document */
#define MAX_KEYLEN 1024       /* an implicit key's length, as the spec says */

/* ---- a growable byte buffer ---------------------------------------------- */
typedef struct {
    char*  buf;
    size_t len;
    size_t cap;
} Buf;

/* ---- tokens -------------------------------------------------------------- */
enum {
    T_STREAM_START, T_STREAM_END, T_VERSION, T_TAG_DIRECTIVE,
    T_DOC_START, T_DOC_END,
    T_BSEQ_START, T_BMAP_START, T_BLOCK_END,
    T_FSEQ_START, T_FSEQ_END, T_FMAP_START, T_FMAP_END,
    T_BLOCK_ENTRY, T_FLOW_ENTRY, T_KEY, T_VALUE,
    T_ALIAS, T_ANCHOR, T_TAG, T_SCALAR
};

/* scalar styles, and the collection styles beside them */
enum { S_PLAIN, S_SINGLE, S_DOUBLE, S_LITERAL, S_FOLDED, S_BLOCK, S_FLOW };

typedef struct { size_t pos; long line, col; } Mark;

typedef struct {
    int         type;
    int         style;
    Mark        mark;
    const char* s;  size_t n;    /* scalar text, anchor or alias name, tag handle, directive */
    const char* s2; size_t n2;   /* tag suffix, %TAG prefix */
} Token;

typedef struct {
    int    possible;
    int    required;
    size_t number;               /* the token number the key would be inserted at */
    Mark   mark;
    int    kind;                 /* 0 block, '[' or '{': the context this level is */
} SimpleKey;

/* ---- nodes --------------------------------------------------------------- */
enum { N_SCALAR, N_SEQ, N_MAP, N_ALIAS };

typedef struct Node Node;
struct Node {
    unsigned char kind;
    unsigned char style;
    unsigned char building;      /* between its start and its end in the parse */
    long          line;
    const char*   anchor; size_t anchorn;
    const char*   tag;    size_t tagn;     /* resolved, or NULL for none */
    const char*   s;      size_t n;        /* scalar text, alias name */
    Node*         target;                  /* an alias's node */
    Node*         first;
    Node*         last;
    Node*         next;
    size_t        size;                    /* nodes, aliases expanded, capped */
    size_t        count;                   /* children */
    RkValue       built;                   /* an anchored node's value, once made */
};

typedef struct Doc Doc;
struct Doc {
    Node* root;
    int   explicit_start;
    int   explicit_end;
    Doc*  next;
};

typedef struct { const char* name; size_t n; Node* node; } Anchor;
typedef struct { const char* handle; size_t hn; const char* prefix; size_t pn; } TagDir;

/* An arena: tokens' text, nodes, strings — freed together. */
typedef struct Block { struct Block* next; size_t used, cap; } Block;

typedef struct {
    RkCtx         c;
    jmp_buf       jb;
    Buf           msg;
    Block*        arena;

    /* the input, normalised: no BOM, LF line endings */
    unsigned char* in;
    size_t        len;
    size_t        pos;
    long          line, col;

    /* the scanner */
    Token*        q;
    size_t        qhead, qlen, qcap;
    size_t        parsed;                  /* tokens handed to the parser */
    int           started, ended;
    long          indent;
    long*         indents;
    size_t        nindents, capindents;
    SimpleKey*    keys;                    /* one per flow level, plus the block level */
    size_t        nkeys, capkeys;
    int           flow;                    /* flow level */
    int           key_allowed;
    int           json_key;                /* the last token was a quoted scalar or a flow
                                              collection's end: in flow, a ':' after it
                                              needs no space */
    Buf           sb, lb, tb, wb;          /* a scalar: text, a line break, breaks, spaces */

    /* the parser */
    Anchor*       anchors;                 /* open addressing on the name */
    size_t        anchorcap, anchorn;
    TagDir*       tags;
    size_t        ntags, captags;
    int           depth;
    Doc*          docs;
    Doc*          lastdoc;
    size_t        ndocs;

    /* construction */
    size_t        expanded;
    int           need_nfc;                /* the text has a mark that may compose */
} P;

static void oom(P* s);

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
static void badd(P* s, Buf* b, const char* t, size_t n) {
    if (!bneed(b, n)) oom(s);
    memcpy(b->buf + b->len, t, n);
    b->len += n;
}
static void bput(P* s, Buf* b, char ch) {
    if (!bneed(b, 1)) oom(s);
    b->buf[b->len++] = ch;
}

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

static const char* keep(P* s, const char* t, size_t n) {
    char* r = (char*)alloc(s, n + 1);
    memcpy(r, t, n);
    r[n] = '\0';
    return r;
}

static void cleanup(P* s) {
    Block* b = s->arena;
    while (b) { Block* n = b->next; free(b); b = n; }
    s->arena = 0;
    free(s->in);
    free(s->q);
    free(s->indents);
    free(s->keys);
    free(s->anchors);
    free(s->tags);
    free(s->sb.buf); free(s->lb.buf); free(s->tb.buf); free(s->wb.buf);
    free(s->msg.buf);
}

/* ---- errors -------------------------------------------------------------- */
static void msg_add(P* s, const char* t, size_t n) {
    if (!bneed(&s->msg, n)) return;
    memcpy(s->msg.buf + s->msg.len, t, n);
    s->msg.len += n;
}
static void msg_str(P* s, const char* t) { msg_add(s, t, strlen(t)); }

static void fail_at(P* s, const char* what, long line) {
    char tail[64];
    s->msg.len = 0;
    msg_str(s, "YAML::Native: ");
    msg_str(s, what);
    snprintf(tail, sizeof tail, " at line %ld", line);
    msg_str(s, tail);
    longjmp(s->jb, 1);
}
static void fail(P* s, const char* what) { fail_at(s, what, s->line); }

/* A message quoting a name or key: "<pre>'<text>'<post> at line N". */
static void fail_name(P* s, const char* pre, const char* t, size_t n, const char* post, long line) {
    char tail[64];
    s->msg.len = 0;
    msg_str(s, "YAML::Native: ");
    msg_str(s, pre);
    msg_str(s, "'");
    msg_add(s, t, n);
    msg_str(s, "'");
    msg_str(s, post);
    snprintf(tail, sizeof tail, " at line %ld", line);
    msg_str(s, tail);
    longjmp(s->jb, 1);
}

static void oom(P* s) {
    s->msg.len = 0;
    msg_str(s, "YAML::Native: out of memory");
    longjmp(s->jb, 1);
}

/* ---- the input ----------------------------------------------------------- */

/* Decode one UTF-8 sequence (the host hands over valid UTF-8). */
static unsigned long u8dec(const unsigned char* p, size_t* n) {
    unsigned char b = p[0];
    if (b < 0x80) { *n = 1; return b; }
    if (b < 0xE0) { *n = 2; return ((unsigned long)(b & 0x1F) << 6) | (p[1] & 0x3F); }
    if (b < 0xF0) { *n = 3; return ((unsigned long)(b & 0x0F) << 12) | ((unsigned long)(p[1] & 0x3F) << 6) | (p[2] & 0x3F); }
    *n = 4;
    return ((unsigned long)(b & 0x07) << 18) | ((unsigned long)(p[1] & 0x3F) << 12)
         | ((unsigned long)(p[2] & 0x3F) << 6) | (p[3] & 0x3F);
}

static int printable(unsigned long c) {
    return c == 0x09 || c == 0x0A || c == 0x0D || (c >= 0x20 && c <= 0x7E) || c == 0x85
        || (c >= 0xA0 && c <= 0xD7FF) || (c >= 0xE000 && c <= 0xFFFD) || (c >= 0x10000 && c <= 0x10FFFF);
}

/* Codepoints that may compose with the one before them under NFC: the
   combining marks, the Indic and Hangul blocks whole, kana voicing marks. A
   superset on purpose — it only decides when text is worth composing. The
   Raku parser has the same table. */
static const unsigned long COMBINING[][2] = {
    {0x0300, 0x036F}, {0x0483, 0x0489}, {0x0591, 0x05C7}, {0x0610, 0x061A}, {0x064B, 0x065F},
    {0x0670, 0x0670}, {0x06D6, 0x06ED}, {0x0711, 0x0711}, {0x0730, 0x074A}, {0x07A6, 0x07B0},
    {0x07EB, 0x07F3}, {0x0816, 0x082D}, {0x0859, 0x085B}, {0x08D3, 0x08FF}, {0x0900, 0x0DFF},
    {0x0E31, 0x0E4E}, {0x0EB1, 0x0ECD}, {0x0F18, 0x0FC6}, {0x1000, 0x109F}, {0x1100, 0x11FF},
    {0x135D, 0x135F}, {0x1712, 0x1773}, {0x17B4, 0x17DD}, {0x180B, 0x180D}, {0x18A9, 0x18A9},
    {0x1920, 0x193B}, {0x1A17, 0x1A7F}, {0x1AB0, 0x1AFF}, {0x1B00, 0x1BF3}, {0x1C24, 0x1C37},
    {0x1CD0, 0x1CF9}, {0x1DC0, 0x1DFF}, {0x20D0, 0x20F0}, {0x2CEF, 0x2CF1}, {0x2D7F, 0x2D7F},
    {0x2DE0, 0x2DFF}, {0x302A, 0x302F}, {0x3099, 0x309A}, {0xA66F, 0xA67D}, {0xA69E, 0xA69F},
    {0xA6F0, 0xA6F1}, {0xA802, 0xA82C}, {0xA880, 0xA8F1}, {0xA926, 0xA953}, {0xA980, 0xA9C0},
    {0xAA29, 0xAA4D}, {0xAAB0, 0xAAF6}, {0xABE3, 0xABED}, {0xFB1E, 0xFB1E}, {0xFE20, 0xFE2F},
    {0x101FD, 0x101FD}, {0x102E0, 0x102E0}, {0x10376, 0x1037A}, {0x10A01, 0x10A3F},
    {0x10AE5, 0x10AE6}, {0x10D24, 0x10D27}, {0x10F46, 0x10F50}, {0x11000, 0x11FFF},
    {0x16AF0, 0x16AF4}, {0x16B30, 0x16B36}, {0x16F4F, 0x16F92}, {0x1BC9D, 0x1BC9E},
    {0x1D165, 0x1D1AD}, {0x1D242, 0x1D244}, {0x1E000, 0x1E02A}, {0x1E130, 0x1E136},
    {0x1E2EC, 0x1E2EF}, {0x1E8D0, 0x1E8D6}, {0x1E944, 0x1E94A}
};

static int combining(unsigned long c) {
    size_t lo = 0, hi = sizeof COMBINING / sizeof COMBINING[0];
    if (c < 0x300 || (c >= 0x3400 && c <= 0x9FFF) || (c >= 0xAC00 && c <= 0xD7FF)) return 0;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (c < COMBINING[mid][0]) hi = mid;
        else if (c > COMBINING[mid][1]) lo = mid + 1;
        else return 1;
    }
    return 0;
}

static int has_combining(const char* t, size_t n) {
    size_t i = 0;
    const unsigned char* p = (const unsigned char*)t;
    while (i < n) {
        size_t k;
        if (p[i] < 0x80) { i++; continue; }
        if (combining(u8dec(p + i, &k))) return 1;
        i += k;
    }
    return 0;
}

/* Text composed by the Raku side's own rules. Raku++'s decoder and rk_str
   keep text uncomposed where Rakudo composes it, and the Raku parser, which
   builds strings with `~`, composes wherever it joins two pieces; this is
   what makes the two parsers' strings equal. NULL if the call failed. */
static const char* compose(P* s, const char* t, size_t n, size_t* outn) {
    RkValue arg = rk_str(s->c, t, n);
    RkValue got = rk_call(s->c, "yaml-native-nfc", &arg, 1);
    if (!got) { rk_clear_error(s->c); return 0; }
    return rk_str_get(s->c, got, outn);
}

/* Copy the text into s->in: a leading byte-order mark dropped, CRLF and CR
   made LF, and every character checked to be one YAML allows in a stream. A
   line break is then always one byte, and every scanner rule about breaks is
   about '\n'. The Raku parser prepares its text the same way. */
static void prepare(P* s, const char* text, size_t len) {
    const unsigned char* p = (const unsigned char*)text;
    size_t i = 0, o = 0;
    long line = 1;
    s->in = (unsigned char*)malloc(len + 2);
    if (!s->in) oom(s);
    if (len >= 3 && p[0] == 0xEF && p[1] == 0xBB && p[2] == 0xBF) i = 3;
    while (i < len) {
        unsigned char b = p[i];
        if (b == '\r') {
            s->in[o++] = '\n';
            i += (i + 1 < len && p[i + 1] == '\n') ? 2 : 1;
            line++;
        }
        else if (b < 0x80) {
            if (!printable(b)) {
                char m[64];
                snprintf(m, sizeof m, "invalid character U+%04X", (unsigned)b);
                fail_at(s, m, line);
            }
            if (b == '\n') line++;
            s->in[o++] = b;
            i++;
        }
        else {
            size_t n;
            unsigned long c = u8dec(p + i, &n);
            if (!printable(c)) {
                char m[64];
                snprintf(m, sizeof m, "invalid character U+%04lX", c);
                fail_at(s, m, line);
            }
            if (combining(c)) s->need_nfc = 1;
            memcpy(s->in + o, p + i, n);
            o += n;
            i += n;
        }
    }
    /* the text is read as if its last line ended in a line break, as the
       yaml-test-suite reads it: a block scalar's last line counts as a line
       whether or not the file ends in a newline */
    if (o > 0 && s->in[o - 1] != '\n') s->in[o++] = '\n';
    s->in[o] = '\0';
    s->len = o;
    s->pos = 0;
    s->line = 1;
    s->col = 0;
}

/* The byte k places on; 0 at the end (a NUL cannot be in the text). */
static int at(P* s, size_t k) {
    size_t i = s->pos + k;
    return i < s->len ? s->in[i] : 0;
}
#define CH at(s, 0)

static int is_blank(int b)    { return b == ' ' || b == '\t'; }
static int is_bz(int b)       { return b == 0 || b == ' ' || b == '\t' || b == '\n'; }
static int is_flow_ind(int b) { return b == ',' || b == '[' || b == ']' || b == '{' || b == '}'; }
static int is_indicator(int b) {
    return b == '-' || b == '?' || b == ':' || b == ',' || b == '[' || b == ']' || b == '{'
        || b == '}' || b == '#' || b == '&' || b == '*' || b == '!' || b == '|' || b == '>'
        || b == '\'' || b == '"' || b == '%' || b == '@' || b == '`';
}
static int is_word(int b) {
    return (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b == '-';
}
static int is_hex(int b) {
    return (b >= '0' && b <= '9') || (b >= 'a' && b <= 'f') || (b >= 'A' && b <= 'F');
}
static int hexval(int b) { return b <= '9' ? b - '0' : (b | 0x20) - 'a' + 10; }

/* One character forward: a column is a character, not a byte. */
static void skip(P* s) {
    unsigned char b = s->in[s->pos];
    s->pos += b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4;
    s->col++;
}
static void skip_break(P* s) { s->pos++; s->line++; s->col = 0; }

/* Append the text from `start` to the current position: the scanners step
   over a run of ordinary characters, then copy it in one go. */
static void take_run(P* s, Buf* b, size_t start) {
    badd(s, b, (const char*)s->in + start, s->pos - start);
}

static Mark mark(P* s) { Mark m; m.pos = s->pos; m.line = s->line; m.col = s->col; return m; }

/* "---" or "..." at the start of a line, followed by a space or the end. */
static int doc_marker(P* s, int ch) {
    return s->col == 0 && at(s, 0) == ch && at(s, 1) == ch && at(s, 2) == ch && is_bz(at(s, 3));
}

/* ---- the token queue ----------------------------------------------------- */
static Token* tok_insert(P* s, size_t number, int type, Mark m) {
    size_t idx;
    Token* t;
    if (s->qhead > 0 && s->qhead * 2 >= s->qlen) {
        memmove(s->q, s->q + s->qhead, (s->qlen - s->qhead) * sizeof(Token));
        s->qlen -= s->qhead;
        s->qhead = 0;
    }
    if (s->qlen == s->qcap) {
        size_t cap = s->qcap ? s->qcap * 2 : 64;
        Token* nq = (Token*)realloc(s->q, cap * sizeof(Token));
        if (!nq) oom(s);
        s->q = nq;
        s->qcap = cap;
    }
    idx = s->qhead + (number - s->parsed);
    if (idx < s->qlen) memmove(s->q + idx + 1, s->q + idx, (s->qlen - idx) * sizeof(Token));
    s->qlen++;
    t = s->q + idx;
    memset(t, 0, sizeof *t);
    t->type = type;
    t->mark = m;
    return t;
}
static Token* tok_add(P* s, int type, Mark m) {
    return tok_insert(s, s->parsed + (s->qlen - s->qhead), type, m);
}

/* ---- indentation and simple keys ----------------------------------------- */
static void unroll_indent(P* s, long col) {
    if (s->flow) return;
    while (s->indent > col) {
        tok_add(s, T_BLOCK_END, mark(s));
        s->indent = s->indents[--s->nindents];
    }
}

static void roll_indent(P* s, long col, size_t number, int insert, int type, Mark m) {
    if (s->flow) return;
    if (s->indent < col) {
        size_t i = m.pos;
        /* a new block collection's indentation is spaces: "-\t-" is not a
           nested sequence, nor "?\tkey:" a nested mapping */
        while (i > 0 && is_blank(s->in[i - 1])) {
            if (s->in[i - 1] == '\t') fail_at(s, "tabs cannot be used for indentation", m.line);
            i--;
        }
        if (s->nindents == s->capindents) {
            size_t cap = s->capindents ? s->capindents * 2 : 16;
            long* ni = (long*)realloc(s->indents, cap * sizeof(long));
            if (!ni) oom(s);
            s->indents = ni;
            s->capindents = cap;
        }
        s->indents[s->nindents++] = s->indent;
        s->indent = col;
        if (insert) tok_insert(s, number, type, m);
        else tok_add(s, type, m);
    }
}

/* A simple key — one with no '?' — is only recognised when its ':' arrives.
   Until then it is "possible", and it stops being so at the end of its line
   or 1024 characters on: YAML's implicit keys are one line long. In a flow
   mapping a key may span lines, so those keys never go stale. */
static void stale_keys(P* s) {
    size_t i;
    for (i = 0; i < s->nkeys; i++) {
        SimpleKey* k = &s->keys[i];
        if (!k->possible || k->kind == '{') continue;
        if (k->mark.line < s->line || s->pos > k->mark.pos + MAX_KEYLEN) {
            if (k->required) fail_at(s, "expected ':' after a mapping key", k->mark.line);
            k->possible = 0;
        }
    }
}

static void remove_key(P* s) {
    SimpleKey* k = &s->keys[s->nkeys - 1];
    if (k->possible && k->required) fail_at(s, "expected ':' after a mapping key", k->mark.line);
    k->possible = 0;
}

static void save_key(P* s) {
    int required = !s->flow && s->indent == s->col;
    if (s->key_allowed) {
        SimpleKey* k;
        remove_key(s);
        k = &s->keys[s->nkeys - 1];
        k->possible = 1;
        k->required = required;
        k->number = s->parsed + (s->qlen - s->qhead);
        k->mark = mark(s);
    }
}

static void push_level(P* s, int kind) {
    if (s->nkeys == s->capkeys) {
        size_t cap = s->capkeys ? s->capkeys * 2 : 16;
        SimpleKey* nk = (SimpleKey*)realloc(s->keys, cap * sizeof(SimpleKey));
        if (!nk) oom(s);
        s->keys = nk;
        s->capkeys = cap;
    }
    memset(&s->keys[s->nkeys], 0, sizeof(SimpleKey));
    s->keys[s->nkeys].kind = kind;
    s->nkeys++;
}

/* ---- scanning: whitespace, comments, and where a flow line may start ----- */

/* At the first non-blank of a line: how many spaces open the line before
   any tab. -1 when something other than blanks precedes the position on its
   line. Indentation is spaces; a tab may follow enough of them. */
static long leading_spaces(P* s) {
    size_t i = s->pos, n = 0;
    while (i > 0 && is_blank(s->in[i - 1])) i--;
    if (i > 0 && s->in[i - 1] != '\n') return -1;
    while (s->in[i + n] == ' ') n++;
    return (long)n;
}

/* Inside a flow collection nested in block context, every line must be
   indented further than the block it sits in. */
static void flow_line(P* s) {
    long sp;
    if (!s->flow || CH == '\n' || CH == 0 || CH == '#') return;
    sp = leading_spaces(s);
    if (sp >= 0 && sp <= s->indent) fail(s, "a flow collection's lines must be indented");
}

static void scan_to_next(P* s) {
    for (;;) {
        while (is_blank(CH)) skip(s);
        if (CH == '#') {
            if (s->pos > 0 && !is_blank(s->in[s->pos - 1]) && s->in[s->pos - 1] != '\n')
                fail(s, "a comment must be separated from what precedes it by a space");
            while (CH != '\n' && CH != 0) skip(s);
        }
        if (CH != '\n') break;
        skip_break(s);
        if (!s->flow) s->key_allowed = 1;
    }
    flow_line(s);
}

/* ---- scanning: the tokens ------------------------------------------------- */
static void fetch_stream_start(P* s) {
    s->indent = -1;
    push_level(s, 0);
    s->key_allowed = 1;
    s->started = 1;
    tok_add(s, T_STREAM_START, mark(s));
}

static void fetch_stream_end(P* s) {
    if (s->flow) {
        fail(s, s->keys[s->nkeys - 1].kind == '[' ? "unterminated flow sequence" : "unterminated flow mapping");
    }
    unroll_indent(s, -1);
    remove_key(s);
    s->key_allowed = 0;
    s->ended = 1;
    tok_add(s, T_STREAM_END, mark(s));
}

static void end_of_line(P* s, const char* what) {
    while (is_blank(CH)) skip(s);
    if (CH == '#') {
        if (!is_blank(s->in[s->pos - 1])) fail(s, "a comment must be separated from what precedes it by a space");
        while (CH != '\n' && CH != 0) skip(s);
    }
    if (CH != '\n' && CH != 0) fail(s, what);
}

static void fetch_directive(P* s) {
    Mark m;
    size_t start;
    unroll_indent(s, -1);
    remove_key(s);
    s->key_allowed = 0;
    m = mark(s);
    skip(s);
    start = s->pos;
    while (!is_bz(CH)) skip(s);
    if (s->pos - start == 4 && memcmp(s->in + start, "YAML", 4) == 0) {
        size_t vs;
        Token* t;
        if (!is_blank(CH)) fail(s, "invalid %YAML directive");
        while (is_blank(CH)) skip(s);
        vs = s->pos;
        if (!(CH >= '0' && CH <= '9')) fail(s, "invalid %YAML directive");
        while (CH >= '0' && CH <= '9') skip(s);
        if (CH != '.') fail(s, "invalid %YAML directive");
        skip(s);
        if (!(CH >= '0' && CH <= '9')) fail(s, "invalid %YAML directive");
        while (CH >= '0' && CH <= '9') skip(s);
        t = tok_add(s, T_VERSION, m);
        t->s = (const char*)s->in + vs;
        t->n = s->pos - vs;
        end_of_line(s, "invalid %YAML directive");
    }
    else if (s->pos - start == 3 && memcmp(s->in + start, "TAG", 3) == 0) {
        size_t hs, hn, ps;
        Token* t;
        if (!is_blank(CH)) fail(s, "invalid %TAG directive");
        while (is_blank(CH)) skip(s);
        hs = s->pos;
        if (CH != '!') fail(s, "invalid %TAG directive");
        skip(s);
        if (!is_blank(CH)) {
            while (is_word(CH)) skip(s);
            if (CH != '!') fail(s, "invalid %TAG directive");
            skip(s);
        }
        hn = s->pos - hs;
        if (!is_blank(CH)) fail(s, "invalid %TAG directive");
        while (is_blank(CH)) skip(s);
        ps = s->pos;
        if (is_bz(CH) || is_flow_ind(CH)) fail(s, "invalid %TAG directive");
        while (!is_bz(CH)) skip(s);
        t = tok_add(s, T_TAG_DIRECTIVE, m);
        t->s = (const char*)s->in + hs;  t->n = hn;
        t->s2 = (const char*)s->in + ps; t->n2 = s->pos - ps;
        end_of_line(s, "invalid %TAG directive");
    }
    else {
        /* a reserved directive: ignored, as the specification asks */
        while (CH != '\n' && CH != 0) skip(s);
    }
}

static void fetch_document_indicator(P* s, int type) {
    Mark m;
    unroll_indent(s, -1);
    remove_key(s);
    s->key_allowed = 0;
    m = mark(s);
    skip(s); skip(s); skip(s);
    tok_add(s, type, m);
    if (type == T_DOC_END) end_of_line(s, "a document end marker must be alone on its line");
}

static void fetch_flow_start(P* s, int type, int kind) {
    Mark m;
    save_key(s);
    push_level(s, kind);
    s->flow++;
    if (s->flow > MAX_DEPTH) fail(s, "nesting is limited to 128 levels");
    s->key_allowed = 1;
    m = mark(s);
    skip(s);
    tok_add(s, type, m);
}

static void fetch_flow_end(P* s, int type) {
    Mark m;
    int want = type == T_FSEQ_END ? '[' : '{';
    if (!s->flow || s->keys[s->nkeys - 1].kind != want)
        fail(s, type == T_FSEQ_END ? "']' without a matching '['" : "'}' without a matching '{'");
    remove_key(s);
    s->nkeys--;
    s->flow--;
    s->key_allowed = 0;
    m = mark(s);
    skip(s);
    tok_add(s, type, m);
    s->json_key = 1;
}

static void fetch_flow_entry(P* s) {
    Mark m;
    if (!s->flow) fail(s, "',' outside a flow collection");
    remove_key(s);
    s->key_allowed = 1;
    m = mark(s);
    skip(s);
    tok_add(s, T_FLOW_ENTRY, m);
}

static void fetch_block_entry(P* s) {
    Mark m = mark(s);
    if (s->flow) fail(s, "a block sequence entry cannot be inside a flow collection");
    if (!s->key_allowed) fail(s, "a block sequence entry is not allowed here");
    roll_indent(s, s->col, 0, 0, T_BSEQ_START, m);
    remove_key(s);
    s->key_allowed = 1;
    skip(s);
    tok_add(s, T_BLOCK_ENTRY, m);
}

static void fetch_key(P* s) {
    Mark m = mark(s);
    if (!s->flow) {
        if (!s->key_allowed) fail(s, "a mapping key is not allowed here");
        roll_indent(s, s->col, 0, 0, T_BMAP_START, m);
    }
    remove_key(s);
    s->key_allowed = !s->flow;
    skip(s);
    tok_add(s, T_KEY, m);
}

static void fetch_value(P* s) {
    Mark m = mark(s);
    SimpleKey* k = &s->keys[s->nkeys - 1];
    if (k->possible) {
        tok_insert(s, k->number, T_KEY, k->mark);
        roll_indent(s, k->mark.col, k->number, 1, T_BMAP_START, k->mark);
        k->possible = 0;
        s->key_allowed = 0;
    }
    else {
        if (!s->flow) {
            if (!s->key_allowed) fail(s, "a mapping value is not allowed here");
            roll_indent(s, s->col, 0, 0, T_BMAP_START, m);
        }
        s->key_allowed = !s->flow;
    }
    skip(s);
    tok_add(s, T_VALUE, m);
}

/* &anchor and *alias: the name runs to a space or a flow indicator, so
   "&a:" names "a:", as YAML 1.2 has it. */
static void fetch_anchor(P* s, int type) {
    Mark m;
    size_t start;
    Token* t;
    save_key(s);
    s->key_allowed = 0;
    m = mark(s);
    skip(s);
    start = s->pos;
    while (!is_bz(CH) && !is_flow_ind(CH)) skip(s);
    if (s->pos == start) fail(s, type == T_ALIAS ? "an alias needs a name" : "an anchor needs a name");
    t = tok_add(s, type, m);
    t->s = (const char*)s->in + start;
    t->n = s->pos - start;
}

/* A URI character; %XX escapes are decoded into the buffer. */
static int uri_char(P* s, int verbatim) {
    int c = CH;
    if (c == '%') {
        char b;
        if (!is_hex(at(s, 1)) || !is_hex(at(s, 2))) fail(s, "invalid escape in a tag");
        b = (char)(hexval(at(s, 1)) * 16 + hexval(at(s, 2)));
        bput(s, &s->sb, b);
        skip(s); skip(s); skip(s);
        return 1;
    }
    if (is_word(c) || (c && strchr("#;/?:@&=+$_.~*'()", c))
        || (verbatim && (c == '!' || c == ',' || c == '[' || c == ']'))) {
        bput(s, &s->sb, (char)c);
        skip(s);
        return 1;
    }
    return 0;
}

/* %-escapes in a tag spell UTF-8, and must spell it validly. */
static int valid_utf8(const unsigned char* p, size_t n) {
    size_t i = 0;
    while (i < n) {
        unsigned char b = p[i];
        size_t k, len;
        unsigned long c;
        if (b < 0x80) { i++; continue; }
        if (b >= 0xC2 && b < 0xE0) { len = 2; c = b & 0x1F; }
        else if (b >= 0xE0 && b < 0xF0) { len = 3; c = b & 0x0F; }
        else if (b >= 0xF0 && b < 0xF5) { len = 4; c = b & 0x07; }
        else return 0;
        if (i + len > n) return 0;
        for (k = 1; k < len; k++) {
            if ((p[i + k] & 0xC0) != 0x80) return 0;
            c = (c << 6) | (p[i + k] & 0x3F);
        }
        if ((len == 3 && c < 0x800) || (len == 4 && (c < 0x10000 || c > 0x10FFFF)) || (c >= 0xD800 && c <= 0xDFFF))
            return 0;
        i += len;
    }
    return 1;
}

static void fetch_tag(P* s) {
    Mark m;
    Token* t;
    const char* handle;
    size_t hn;
    save_key(s);
    s->key_allowed = 0;
    m = mark(s);
    s->sb.len = 0;
    if (at(s, 1) == '<') {
        skip(s); skip(s);
        while (uri_char(s, 1)) ;
        if (CH != '>' || s->sb.len == 0) fail(s, "invalid verbatim tag");
        skip(s);
        handle = ""; hn = 0;
    }
    else {
        size_t hs = s->pos, i;
        skip(s);
        /* is this "!word!..."? look ahead without consuming */
        i = 0;
        while (is_word(at(s, i))) i++;
        if (at(s, i) == '!') {
            size_t j;
            for (j = 0; j <= i; j++) skip(s);
            handle = (const char*)s->in + hs;
            hn = s->pos - hs;
        }
        else {
            handle = "!"; hn = 1;
        }
        while (uri_char(s, 0)) ;
        if (s->sb.len == 0 && hn > 1) fail(s, "a tag needs a suffix");
    }
    if (!valid_utf8((const unsigned char*)s->sb.buf, s->sb.len)) fail(s, "invalid escape in a tag");
    if (!is_bz(CH) && !(s->flow && is_flow_ind(CH)))
        fail(s, "a tag must be followed by a space");
    t = tok_add(s, T_TAG, m);
    t->s = handle; t->n = hn;
    t->s2 = keep(s, s->sb.buf ? s->sb.buf : "", s->sb.len);
    t->n2 = s->sb.len;
}

/* ---- scanning: scalars ---------------------------------------------------- */
static void put_utf8(P* s, Buf* b, unsigned long c) {
    char u[4];
    size_t n;
    if (c < 0x80) { u[0] = (char)c; n = 1; }
    else if (c < 0x800) { u[0] = (char)(0xC0 | (c >> 6)); u[1] = (char)(0x80 | (c & 0x3F)); n = 2; }
    else if (c < 0x10000) {
        u[0] = (char)(0xE0 | (c >> 12)); u[1] = (char)(0x80 | ((c >> 6) & 0x3F));
        u[2] = (char)(0x80 | (c & 0x3F)); n = 3;
    }
    else {
        u[0] = (char)(0xF0 | (c >> 18)); u[1] = (char)(0x80 | ((c >> 12) & 0x3F));
        u[2] = (char)(0x80 | ((c >> 6) & 0x3F)); u[3] = (char)(0x80 | (c & 0x3F)); n = 4;
    }
    badd(s, b, u, n);
}

/* Joining lines, the rule every multi-line scalar but a literal one shares:
   one line break folds to a space, and n breaks keep n-1 of them. */
static void fold_in(P* s, int leading) {
    if (leading) {
        if (s->lb.len) {
            if (s->tb.len == 0) bput(s, &s->sb, ' ');
            else badd(s, &s->sb, s->tb.buf, s->tb.len);
        }
        else badd(s, &s->sb, s->tb.buf ? s->tb.buf : "", s->tb.len);
        s->lb.len = 0;
        s->tb.len = 0;
    }
    else {
        badd(s, &s->sb, s->wb.buf ? s->wb.buf : "", s->wb.len);
        s->wb.len = 0;
    }
}

static Token* scalar_token(P* s, Mark m, int style) {
    Token* t = tok_add(s, T_SCALAR, m);
    t->style = style;
    t->s = keep(s, s->sb.buf ? s->sb.buf : "", s->sb.len);
    t->n = s->sb.len;
    return t;
}

static void scan_quoted(P* s, int single) {
    Mark m;
    int leading = 0, escaped = 0;
    save_key(s);
    s->key_allowed = 0;
    m = mark(s);
    s->sb.len = s->lb.len = s->tb.len = s->wb.len = 0;
    skip(s);
    for (;;) {
        if (doc_marker(s, '-') || doc_marker(s, '.'))
            fail(s, "a document marker inside a quoted scalar");
        if (CH == 0) fail_at(s, "unterminated quoted scalar", m.line);
        if (leading && CH != '\n' && leading_spaces(s) <= s->indent)
            fail(s, "a quoted scalar's lines must be indented");
        leading = 0;
        while (!is_bz(CH)) {
            int c = CH;
            if (single && c == '\'' && at(s, 1) != '\'') break;
            if (!single && c == '"') break;
            fold_in(s, 0);
            if (single && c == '\'') { bput(s, &s->sb, '\''); skip(s); skip(s); continue; }
            if (!single && c == '\\' && at(s, 1) == '\n') {
                escaped = 1;
                skip(s);
                skip_break(s);
                leading = 1;
                break;
            }
            if (!single && c == '\\') {
                int e = at(s, 1);
                escaped = 1;
                unsigned long cp = 0;
                int digits = 0;
                switch (e) {
                    case '0':  bput(s, &s->sb, '\0'); break;
                    case 'a':  bput(s, &s->sb, '\a'); break;
                    case 'b':  bput(s, &s->sb, '\b'); break;
                    case 't': case '\t': bput(s, &s->sb, '\t'); break;
                    case 'n':  bput(s, &s->sb, '\n'); break;
                    case 'v':  bput(s, &s->sb, '\v'); break;
                    case 'f':  bput(s, &s->sb, '\f'); break;
                    case 'r':  bput(s, &s->sb, '\r'); break;
                    case 'e':  bput(s, &s->sb, 0x1B); break;
                    case ' ':  bput(s, &s->sb, ' '); break;
                    case '"':  bput(s, &s->sb, '"'); break;
                    case '/':  bput(s, &s->sb, '/'); break;
                    case '\\': bput(s, &s->sb, '\\'); break;
                    case 'N':  put_utf8(s, &s->sb, 0x85); break;
                    case '_':  put_utf8(s, &s->sb, 0xA0); break;
                    case 'L':  put_utf8(s, &s->sb, 0x2028); break;
                    case 'P':  put_utf8(s, &s->sb, 0x2029); break;
                    case 'x':  digits = 2; break;
                    case 'u':  digits = 4; break;
                    case 'U':  digits = 8; break;
                    default:   fail(s, "invalid escape in a double-quoted scalar");
                }
                skip(s); skip(s);
                if (digits) {
                    int i;
                    for (i = 0; i < digits; i++) {
                        if (!is_hex(CH)) fail(s, "invalid escape in a double-quoted scalar");
                        cp = cp * 16 + (unsigned long)hexval(CH);
                        skip(s);
                    }
                    if ((cp >= 0xD800 && cp <= 0xDFFF) || cp > 0x10FFFF)
                        fail(s, "invalid Unicode escape in a double-quoted scalar");
                    put_utf8(s, &s->sb, cp);
                }
                continue;
            }
            {
                /* a run of ordinary characters */
                size_t start = s->pos;
                int q = single ? '\'' : '"', d;
                do {
                    skip(s);
                    d = CH;
                } while (!is_bz(d) && d != q && !(!single && d == '\\'));
                take_run(s, &s->sb, start);
            }
        }
        if (CH == (single ? '\'' : '"')) break;
        /* whitespace and line breaks */
        while (is_blank(CH) || CH == '\n') {
            if (is_blank(CH)) {
                if (!leading) bput(s, &s->wb, (char)CH);
                skip(s);
            }
            else {
                if (!leading) { s->wb.len = 0; s->lb.len = 0; bput(s, &s->lb, '\n'); leading = 1; }
                else bput(s, &s->tb, '\n');
                skip_break(s);
            }
        }
        if (leading) {
            fold_in(s, 1);
        }
    }
    fold_in(s, 0);
    skip(s);
    /* an escape can put a mark beside a letter it composes with */
    if (escaped && has_combining(s->sb.buf, s->sb.len)) {
        size_t n;
        const char* t = compose(s, s->sb.buf, s->sb.len, &n);
        if (t) {
            char* copy = (char*)alloc(s, n + 1);
            memcpy(copy, t, n);
            s->sb.len = 0;
            badd(s, &s->sb, copy, n);
        }
    }
    scalar_token(s, m, single ? S_SINGLE : S_DOUBLE);
    s->json_key = 1;
}

static void scan_plain(P* s) {
    Mark m;
    long indent = s->indent + 1;
    int leading = 0;
    save_key(s);
    s->key_allowed = 0;
    m = mark(s);
    s->sb.len = s->lb.len = s->tb.len = s->wb.len = 0;
    for (;;) {
        if (doc_marker(s, '-') || doc_marker(s, '.')) break;
        if (CH == '#') break;
        while (!is_bz(CH)) {
            int c = CH;
            if (c == ':' && (is_bz(at(s, 1)) || (s->flow && is_flow_ind(at(s, 1))))) break;
            if (s->flow && is_flow_ind(c)) break;
            if (leading) {
                if (s->flow) flow_line(s);
                else if (leading_spaces(s) <= s->indent) fail(s, "tabs cannot be used for indentation");
                fold_in(s, 1);
                leading = 0;
            }
            else fold_in(s, 0);
            {
                /* a run of characters none of which can end the scalar */
                size_t start = s->pos;
                int d;
                do {
                    skip(s);
                    d = CH;
                } while (d > ' ' ? d != ':' && !(s->flow && is_flow_ind(d)) : !is_bz(d));
                take_run(s, &s->sb, start);
            }
        }
        if (!(is_blank(CH) || CH == '\n')) break;
        while (is_blank(CH) || CH == '\n') {
            if (is_blank(CH)) {
                if (!leading) bput(s, &s->wb, (char)CH);
                skip(s);
            }
            else {
                if (!leading) { s->wb.len = 0; s->lb.len = 0; bput(s, &s->lb, '\n'); leading = 1; }
                else bput(s, &s->tb, '\n');
                skip_break(s);
            }
        }
        if (!s->flow && s->col < indent) break;
    }
    scalar_token(s, m, S_PLAIN);
    if (leading) s->key_allowed = 1;
}

/* The spaces a block scalar's line may begin with before it ends the
   scalar: a tab among them is an error, as libyaml has it. */
static void block_breaks(P* s, long indent) {
    for (;;) {
        while (s->col < indent && CH == ' ') skip(s);
        if (s->col < indent && CH == '\t') fail(s, "tabs cannot be used for indentation");
        if (CH != '\n') break;
        bput(s, &s->tb, '\n');
        skip_break(s);
    }
}

static void scan_block_scalar(P* s, int literal) {
    Mark m;
    int chomp = 0, inc = 0, leading_blank = 0, trailing_blank;
    long indent, min;
    remove_key(s);
    s->key_allowed = 1;
    m = mark(s);
    s->sb.len = s->lb.len = s->tb.len = 0;
    skip(s);
    if (CH == '+' || CH == '-') {
        chomp = CH == '+' ? 1 : -1;
        skip(s);
        if (CH >= '0' && CH <= '9') {
            if (CH == '0') fail(s, "a block scalar's indentation indicator must be 1 to 9");
            inc = CH - '0';
            skip(s);
        }
    }
    else if (CH >= '0' && CH <= '9') {
        if (CH == '0') fail(s, "a block scalar's indentation indicator must be 1 to 9");
        inc = CH - '0';
        skip(s);
        if (CH == '+' || CH == '-') { chomp = CH == '+' ? 1 : -1; skip(s); }
    }
    if (!is_bz(CH)) fail(s, "invalid block scalar header");
    end_of_line(s, "invalid block scalar header");
    if (CH == '\n') skip_break(s);

    min = s->indent + 1;
    if (inc) indent = s->indent + inc;
    else {
        /* Looked ahead, not consumed: the indentation is the first non-empty
           line's, no leading empty line may be longer than it, and with no
           content at all it is the longest of those lines. */
        size_t p = s->pos;
        long longest = 0, col, lines = 0;
        for (;;) {
            col = 0;
            while (s->in[p] == ' ') { p++; col++; }
            if (s->in[p] == '\t' && col < min) fail_at(s, "tabs cannot be used for indentation", s->line + lines);
            if (s->in[p] != '\n') break;
            if (col > longest) longest = col;
            p++;
            lines++;
        }
        if (p >= s->len || col < min) indent = longest > min ? longest : min;
        else {
            indent = col;
            if (longest > indent)
                fail_at(s, "a block scalar's leading empty lines are indented more than its first line", s->line + lines);
        }
    }
    block_breaks(s, indent);
    for (;;) {
        if (s->col != indent || CH == 0) break;
        if (doc_marker(s, '-') || doc_marker(s, '.')) break;
        trailing_blank = is_blank(CH);
        if (!literal && s->lb.len && !leading_blank && !trailing_blank) {
            if (s->tb.len == 0) bput(s, &s->sb, ' ');
            s->lb.len = 0;
        }
        else {
            badd(s, &s->sb, s->lb.buf ? s->lb.buf : "", s->lb.len);
            s->lb.len = 0;
        }
        badd(s, &s->sb, s->tb.buf ? s->tb.buf : "", s->tb.len);
        s->tb.len = 0;
        leading_blank = is_blank(CH);
        {
            size_t start = s->pos;
            while (CH != '\n' && CH != 0) skip(s);
            take_run(s, &s->sb, start);
        }
        if (CH == 0) break;
        bput(s, &s->lb, '\n');
        skip_break(s);
        block_breaks(s, indent);
    }
    if (chomp != -1) badd(s, &s->sb, s->lb.buf ? s->lb.buf : "", s->lb.len);
    if (chomp == 1) badd(s, &s->sb, s->tb.buf ? s->tb.buf : "", s->tb.len);
    scalar_token(s, m, literal ? S_LITERAL : S_FOLDED);
}

/* ---- scanning: the dispatcher -------------------------------------------- */
static void fetch_next(P* s) {
    int c, n1, json_key = s->json_key;
    s->json_key = 0;
    if (!s->started) { fetch_stream_start(s); return; }
    scan_to_next(s);
    stale_keys(s);
    unroll_indent(s, s->col);
    c = CH;
    if (c == 0) { fetch_stream_end(s); return; }
    if (s->col == 0 && c == '%') { fetch_directive(s); return; }
    if (doc_marker(s, '-')) { fetch_document_indicator(s, T_DOC_START); return; }
    if (doc_marker(s, '.')) { fetch_document_indicator(s, T_DOC_END); return; }
    n1 = at(s, 1);
    switch (c) {
        case '[': fetch_flow_start(s, T_FSEQ_START, '['); return;
        case '{': fetch_flow_start(s, T_FMAP_START, '{'); return;
        case ']': fetch_flow_end(s, T_FSEQ_END); return;
        case '}': fetch_flow_end(s, T_FMAP_END); return;
        case ',': fetch_flow_entry(s); return;
    }
    if (c == '-' && is_bz(n1)) { fetch_block_entry(s); return; }
    if (c == '?' && is_bz(n1)) { fetch_key(s); return; }
    if (c == ':' && (is_bz(n1) || (s->flow && (is_flow_ind(n1) || json_key)))) {
        fetch_value(s);
        return;
    }
    if (c == '*') { fetch_anchor(s, T_ALIAS); return; }
    if (c == '&') { fetch_anchor(s, T_ANCHOR); return; }
    if (c == '!') { fetch_tag(s); return; }
    if (c == '|' && !s->flow) { scan_block_scalar(s, 1); return; }
    if (c == '>' && !s->flow) { scan_block_scalar(s, 0); return; }
    if (c == '\'') { scan_quoted(s, 1); return; }
    if (c == '"') { scan_quoted(s, 0); return; }
    if ((!is_bz(c) && !is_indicator(c))
        || ((c == '-' || c == '?' || c == ':') && !is_bz(n1) && !(s->flow && is_flow_ind(n1)))) {
        scan_plain(s);
        return;
    }
    {
        char m[64];
        if (c == '\t') snprintf(m, sizeof m, "unexpected tab");
        else snprintf(m, sizeof m, "unexpected '%c'", c);
        fail(s, m);
    }
}

/* Are there enough tokens to hand one over? Not while a simple key that
   would insert a KEY in front of the queue's head is still possible. */
static void fetch_more(P* s) {
    for (;;) {
        int need = 0;
        if (s->qhead == s->qlen) need = 1;
        else {
            size_t i;
            stale_keys(s);
            for (i = 0; i < s->nkeys; i++)
                if (s->keys[i].possible && s->keys[i].number == s->parsed) { need = 1; break; }
        }
        if (!need || s->ended) return;
        fetch_next(s);
    }
}

/* The head of the queue — unless a simple key still pending could put a KEY
   in front of it, when the scanner must read on until it knows. Whether a
   key has gone stale only changes as the scanner moves, and fetch_more
   checks it then. */
static Token* peek(P* s) {
    if (s->qhead < s->qlen) {
        size_t i;
        int blocked = 0;
        if (s->ended) return &s->q[s->qhead];
        for (i = 0; i < s->nkeys; i++)
            if (s->keys[i].possible && s->keys[i].number == s->parsed) blocked = 1;
        if (!blocked) return &s->q[s->qhead];
    }
    fetch_more(s);
    return &s->q[s->qhead];
}
static void next(P* s) { s->qhead++; s->parsed++; }

/* ---- parsing -------------------------------------------------------------- */
static Node* new_node(P* s, int kind, int style, long line) {
    Node* n = (Node*)alloc(s, sizeof(Node));
    memset(n, 0, sizeof *n);
    n->kind = (unsigned char)kind;
    n->style = (unsigned char)style;
    n->line = line;
    n->size = 1;
    return n;
}

static void add_child(Node* p, Node* c) {
    if (p->last) p->last->next = c; else p->first = c;
    p->last = c;
    p->count++;
    p->size += c->size;
    if (p->size > MAX_ALIAS + 1) p->size = MAX_ALIAS + 1;
}

static size_t hname(const char* t, size_t n) {
    size_t h = (size_t)1469598103934665603ULL, i;
    for (i = 0; i < n; i++) { h ^= (unsigned char)t[i]; h *= (size_t)1099511628211ULL; }
    return h;
}

static void anchor_set(P* s, const char* name, size_t n, Node* node) {
    size_t i, mask;
    if ((s->anchorn + 1) * 2 > s->anchorcap) {
        size_t cap = s->anchorcap ? s->anchorcap * 2 : 64, j;
        Anchor* na = (Anchor*)calloc(cap, sizeof(Anchor));
        if (!na) oom(s);
        for (j = 0; j < s->anchorcap; j++) {
            Anchor* a = &s->anchors[j];
            if (!a->name) continue;
            i = hname(a->name, a->n) & (cap - 1);
            while (na[i].name) i = (i + 1) & (cap - 1);
            na[i] = *a;
        }
        free(s->anchors);
        s->anchors = na;
        s->anchorcap = cap;
    }
    mask = s->anchorcap - 1;
    i = hname(name, n) & mask;
    while (s->anchors[i].name) {
        if (s->anchors[i].n == n && memcmp(s->anchors[i].name, name, n) == 0) {
            s->anchors[i].node = node;
            return;
        }
        i = (i + 1) & mask;
    }
    s->anchors[i].name = name;
    s->anchors[i].n = n;
    s->anchors[i].node = node;
    s->anchorn++;
}

static Node* anchor_get(P* s, const char* name, size_t n) {
    size_t i, mask;
    if (!s->anchorcap) return 0;
    mask = s->anchorcap - 1;
    i = hname(name, n) & mask;
    while (s->anchors[i].name) {
        if (s->anchors[i].n == n && memcmp(s->anchors[i].name, name, n) == 0) return s->anchors[i].node;
        i = (i + 1) & mask;
    }
    return 0;
}

/* A tag as written, resolved to its full form through the document's %TAG
   directives and the two default handles. */
static void resolve_tag(P* s, Token* t, const char** out, size_t* outn) {
    size_t i;
    const char* prefix = 0;
    size_t pn = 0;
    char* r;
    if (t->n == 0) { *out = t->s2; *outn = t->n2; return; }          /* verbatim */
    if (t->n == 1 && t->n2 == 0) { *out = "!"; *outn = 1; return; }  /* non-specific */
    for (i = 0; i < s->ntags; i++)
        if (s->tags[i].hn == t->n && memcmp(s->tags[i].handle, t->s, t->n) == 0) {
            prefix = s->tags[i].prefix; pn = s->tags[i].pn;
            break;
        }
    if (!prefix) {
        if (t->n == 1) { prefix = "!"; pn = 1; }
        else if (t->n == 2 && t->s[0] == '!' && t->s[1] == '!') { prefix = "tag:yaml.org,2002:"; pn = 18; }
        else fail_name(s, "undefined tag handle ", t->s, t->n, "", t->mark.line);
    }
    r = (char*)alloc(s, pn + t->n2 + 1);
    memcpy(r, prefix, pn);
    memcpy(r + pn, t->s2, t->n2);
    r[pn + t->n2] = '\0';
    *out = r;
    *outn = pn + t->n2;
}

typedef struct {
    int   has_anchor, has_tag;
    const char* anchor; size_t anchorn;
    const char* tag; size_t tagn;
    long  line;
} Props;

static void apply_props(P* s, Node* n, Props* p) {
    if (p->has_anchor) {
        n->anchor = p->anchor; n->anchorn = p->anchorn;
        anchor_set(s, p->anchor, p->anchorn, n);
    }
    if (p->has_tag) { n->tag = p->tag; n->tagn = p->tagn; }
}

static Node* empty_node(P* s, long line) {
    Node* n = new_node(s, N_SCALAR, S_PLAIN, line);
    n->s = "";
    n->n = 0;
    return n;
}

static Node* parse_node(P* s, int block, int indentless);

static void enter(P* s) {
    if (++s->depth > MAX_DEPTH) fail(s, "nesting is limited to 128 levels");
}

static Node* parse_block_seq(P* s, Node* n) {
    next(s);
    for (;;) {
        Token* t = peek(s);
        if (t->type == T_BLOCK_ENTRY) {
            long line = t->mark.line;
            next(s);
            t = peek(s);
            if (t->type == T_BLOCK_ENTRY || t->type == T_BLOCK_END) add_child(n, empty_node(s, line));
            else add_child(n, parse_node(s, 1, 0));
        }
        else if (t->type == T_BLOCK_END) { next(s); break; }
        else fail_at(s, "expected a sequence entry ('-')", t->mark.line);
    }
    return n;
}

static Node* parse_indentless_seq(P* s, Node* n) {
    for (;;) {
        Token* t = peek(s);
        long line;
        if (t->type != T_BLOCK_ENTRY) break;
        line = t->mark.line;
        next(s);
        t = peek(s);
        if (t->type == T_BLOCK_ENTRY || t->type == T_KEY || t->type == T_VALUE || t->type == T_BLOCK_END)
            add_child(n, empty_node(s, line));
        else add_child(n, parse_node(s, 1, 0));
    }
    return n;
}

static Node* parse_block_map(P* s, Node* n) {
    next(s);
    for (;;) {
        Token* t = peek(s);
        long line = t->mark.line;
        if (t->type == T_KEY) {
            next(s);
            t = peek(s);
            if (t->type == T_KEY || t->type == T_VALUE || t->type == T_BLOCK_END) add_child(n, empty_node(s, line));
            else add_child(n, parse_node(s, 1, 1));
            t = peek(s);
            line = t->mark.line;
            if (t->type == T_VALUE) {
                next(s);
                t = peek(s);
                if (t->type == T_KEY || t->type == T_VALUE || t->type == T_BLOCK_END) add_child(n, empty_node(s, line));
                else add_child(n, parse_node(s, 1, 1));
            }
            else add_child(n, empty_node(s, line));
        }
        else if (t->type == T_VALUE) {
            add_child(n, empty_node(s, line));
            next(s);
            t = peek(s);
            if (t->type == T_KEY || t->type == T_VALUE || t->type == T_BLOCK_END) add_child(n, empty_node(s, line));
            else add_child(n, parse_node(s, 1, 1));
        }
        else if (t->type == T_BLOCK_END) { next(s); break; }
        else fail_at(s, "expected a mapping key", t->mark.line);
    }
    return n;
}

/* One key: value pair inside a flow sequence, "[a: b]", is a mapping. */
static Node* parse_flow_pair(P* s, int end) {
    Token* t = peek(s);
    Node* m = new_node(s, N_MAP, S_FLOW, t->mark.line);
    long line = t->mark.line;
    if (t->type == T_KEY) {
        next(s);
        t = peek(s);
        if (t->type == T_VALUE || t->type == T_FLOW_ENTRY || t->type == end) add_child(m, empty_node(s, line));
        else add_child(m, parse_node(s, 0, 0));
    }
    else add_child(m, empty_node(s, line));
    t = peek(s);
    line = t->mark.line;
    if (t->type == T_VALUE) {
        next(s);
        t = peek(s);
        if (t->type == T_FLOW_ENTRY || t->type == end) add_child(m, empty_node(s, line));
        else add_child(m, parse_node(s, 0, 0));
    }
    else add_child(m, empty_node(s, line));
    return m;
}

static Node* parse_flow_seq(P* s, Node* n) {
    int first = 1;
    next(s);
    for (;;) {
        Token* t = peek(s);
        if (t->type == T_FSEQ_END) { next(s); break; }
        if (!first) {
            if (t->type != T_FLOW_ENTRY) fail_at(s, "expected ',' or ']'", t->mark.line);
            next(s);
            t = peek(s);
            if (t->type == T_FSEQ_END) { next(s); break; }
        }
        first = 0;
        if (t->type == T_FLOW_ENTRY) fail_at(s, "an empty entry in a flow sequence", t->mark.line);
        if (t->type == T_KEY || t->type == T_VALUE) {
            enter(s);
            add_child(n, parse_flow_pair(s, T_FSEQ_END));
            s->depth--;
        }
        else add_child(n, parse_node(s, 0, 0));
    }
    return n;
}

static Node* parse_flow_map(P* s, Node* n) {
    int first = 1;
    next(s);
    for (;;) {
        Token* t = peek(s);
        long line;
        if (t->type == T_FMAP_END) { next(s); break; }
        if (!first) {
            if (t->type != T_FLOW_ENTRY) fail_at(s, "expected ',' or '}'", t->mark.line);
            next(s);
            t = peek(s);
            if (t->type == T_FMAP_END) { next(s); break; }
        }
        first = 0;
        line = t->mark.line;
        if (t->type == T_FLOW_ENTRY) fail_at(s, "an empty entry in a flow mapping", line);
        if (t->type == T_KEY) {
            next(s);
            t = peek(s);
            if (t->type == T_VALUE || t->type == T_FLOW_ENTRY || t->type == T_FMAP_END) add_child(n, empty_node(s, line));
            else add_child(n, parse_node(s, 0, 0));
        }
        else if (t->type == T_VALUE) add_child(n, empty_node(s, line));
        else add_child(n, parse_node(s, 0, 0));
        t = peek(s);
        line = t->mark.line;
        if (t->type == T_VALUE) {
            next(s);
            t = peek(s);
            if (t->type == T_FLOW_ENTRY || t->type == T_FMAP_END) add_child(n, empty_node(s, line));
            else add_child(n, parse_node(s, 0, 0));
        }
        else add_child(n, empty_node(s, line));
    }
    return n;
}

static Node* parse_node(P* s, int block, int indentless) {
    Props p;
    Token* t = peek(s);
    Node* n;
    memset(&p, 0, sizeof p);
    p.line = t->mark.line;
    for (;;) {
        t = peek(s);
        if (t->type == T_ANCHOR) {
            if (p.has_anchor) fail_at(s, "a node can have only one anchor", t->mark.line);
            p.has_anchor = 1; p.anchor = t->s; p.anchorn = t->n;
            next(s);
        }
        else if (t->type == T_TAG) {
            if (p.has_tag) fail_at(s, "a node can have only one tag", t->mark.line);
            p.has_tag = 1;
            resolve_tag(s, t, &p.tag, &p.tagn);
            next(s);
        }
        else break;
    }
    t = peek(s);
    switch (t->type) {
        case T_ALIAS: {
            Node* target;
            if (p.has_anchor || p.has_tag) fail_at(s, "an alias cannot have an anchor or a tag", t->mark.line);
            n = new_node(s, N_ALIAS, S_PLAIN, t->mark.line);
            n->s = t->s; n->n = t->n;
            target = anchor_get(s, t->s, t->n);
            if (!target) fail_name(s, "undefined alias ", t->s, t->n, "", t->mark.line);
            n->target = target;
            n->size = target->building ? 1 : target->size;
            next(s);
            return n;
        }
        case T_SCALAR:
            n = new_node(s, N_SCALAR, t->style, t->mark.line);
            n->s = t->s; n->n = t->n;
            apply_props(s, n, &p);
            next(s);
            return n;
        case T_FSEQ_START: case T_FMAP_START: case T_BSEQ_START: case T_BMAP_START:
            if (!block && (t->type == T_BSEQ_START || t->type == T_BMAP_START)) break;
            n = new_node(s, t->type == T_FSEQ_START || t->type == T_BSEQ_START ? N_SEQ : N_MAP,
                         t->type == T_FSEQ_START || t->type == T_FMAP_START ? S_FLOW : S_BLOCK, t->mark.line);
            apply_props(s, n, &p);
            n->building = 1;
            enter(s);
            if (t->type == T_FSEQ_START) parse_flow_seq(s, n);
            else if (t->type == T_FMAP_START) parse_flow_map(s, n);
            else if (t->type == T_BSEQ_START) parse_block_seq(s, n);
            else parse_block_map(s, n);
            s->depth--;
            n->building = 0;
            return n;
        case T_BLOCK_ENTRY:
            if (!block || !indentless) break;
            n = new_node(s, N_SEQ, S_BLOCK, t->mark.line);
            apply_props(s, n, &p);
            n->building = 1;
            enter(s);
            parse_indentless_seq(s, n);
            s->depth--;
            n->building = 0;
            return n;
    }
    if (p.has_anchor || p.has_tag) {
        n = empty_node(s, p.line);
        apply_props(s, n, &p);
        return n;
    }
    fail_at(s, "expected a node", t->mark.line);
    return 0;
}

static void add_doc(P* s, Doc* d) {
    if (s->lastdoc) s->lastdoc->next = d; else s->docs = d;
    s->lastdoc = d;
    s->ndocs++;
}

static void parse_stream(P* s) {
    int open = 0;      /* the last document ended without "...": only "---" may follow */
    Token* t = peek(s);
    next(s);           /* STREAM-START */
    for (;;) {
        Doc* d;
        int directives = 0, version = 0;
        t = peek(s);
        if (t->type == T_STREAM_END) break;
        if (t->type == T_DOC_END) { next(s); open = 0; continue; }
        s->ntags = 0;
        if (s->anchorcap) { memset(s->anchors, 0, s->anchorcap * sizeof(Anchor)); s->anchorn = 0; }
        while (t->type == T_VERSION || t->type == T_TAG_DIRECTIVE) {
            if (open) fail_at(s, "a directive must follow a document end marker ('...')", t->mark.line);
            directives = 1;
            if (t->type == T_VERSION) {
                if (version) fail_at(s, "a document can have only one %YAML directive", t->mark.line);
                version = 1;
                if (t->n < 2 || t->s[0] != '1' || t->s[1] != '.')
                    fail_at(s, "unsupported YAML version", t->mark.line);
            }
            else {
                size_t i;
                for (i = 0; i < s->ntags; i++)
                    if (s->tags[i].hn == t->n && memcmp(s->tags[i].handle, t->s, t->n) == 0)
                        fail_name(s, "the tag handle ", t->s, t->n, " is declared twice", t->mark.line);
                if (s->ntags == s->captags) {
                    size_t cap = s->captags ? s->captags * 2 : 8;
                    TagDir* nt = (TagDir*)realloc(s->tags, cap * sizeof(TagDir));
                    if (!nt) oom(s);
                    s->tags = nt;
                    s->captags = cap;
                }
                s->tags[s->ntags].handle = t->s; s->tags[s->ntags].hn = t->n;
                s->tags[s->ntags].prefix = t->s2; s->tags[s->ntags].pn = t->n2;
                s->ntags++;
            }
            next(s);
            t = peek(s);
        }
        d = (Doc*)alloc(s, sizeof(Doc));
        memset(d, 0, sizeof *d);
        if (t->type == T_DOC_START) {
            long line = t->mark.line;
            d->explicit_start = 1;
            next(s);
            t = peek(s);
            if (t->type == T_VERSION || t->type == T_TAG_DIRECTIVE || t->type == T_DOC_START
                || t->type == T_DOC_END || t->type == T_STREAM_END)
                d->root = empty_node(s, line);
            else d->root = parse_node(s, 1, 0);
        }
        else {
            if (directives) fail_at(s, "directives must be followed by '---'", t->mark.line);
            d->root = parse_node(s, 1, 0);
        }
        add_doc(s, d);
        t = peek(s);
        if (t->type == T_DOC_END) {
            d->explicit_end = 1;
            next(s);
            open = 0;
        }
        else if (t->type == T_DOC_START) open = 1;
        else if (t->type == T_STREAM_END) open = 0;
        else if (t->type == T_VERSION || t->type == T_TAG_DIRECTIVE)
            fail_at(s, "a directive must follow a document end marker ('...')", t->mark.line);
        else fail_at(s, "unexpected content after the document", t->mark.line);
    }
}

/* ---- the event stream, in the yaml-test-suite's notation ----------------- */
static void ev_text(P* s, Buf* o, const char* t, size_t n) {
    size_t i;
    for (i = 0; i < n; i++) {
        char ch = t[i];
        switch (ch) {
            case '\\': badd(s, o, "\\\\", 2); break;
            case '\0': badd(s, o, "\\0", 2); break;
            case '\b': badd(s, o, "\\b", 2); break;
            case '\n': badd(s, o, "\\n", 2); break;
            case '\r': badd(s, o, "\\r", 2); break;
            case '\t': badd(s, o, "\\t", 2); break;
            default:   bput(s, o, ch);
        }
    }
}

static void ev_props(P* s, Buf* o, Node* n) {
    if (n->anchor) { badd(s, o, " &", 2); badd(s, o, n->anchor, n->anchorn); }
    if (n->tag) { badd(s, o, " <", 2); badd(s, o, n->tag, n->tagn); bput(s, o, '>'); }
}

static void ev_node(P* s, Buf* o, Node* n) {
    Node* c;
    switch (n->kind) {
        case N_ALIAS:
            badd(s, o, "=ALI *", 6); badd(s, o, n->s, n->n); bput(s, o, '\n');
            return;
        case N_SCALAR: {
            static const char sty[] = ":'\"|>";
            badd(s, o, "=VAL", 4);
            ev_props(s, o, n);
            bput(s, o, ' ');
            bput(s, o, sty[n->style]);
            ev_text(s, o, n->s, n->n);
            bput(s, o, '\n');
            return;
        }
        default:
            badd(s, o, n->kind == N_SEQ ? "+SEQ" : "+MAP", 4);
            if (n->style == S_FLOW) badd(s, o, n->kind == N_SEQ ? " []" : " {}", 3);
            ev_props(s, o, n);
            bput(s, o, '\n');
            for (c = n->first; c; c = c->next) ev_node(s, o, c);
            badd(s, o, n->kind == N_SEQ ? "-SEQ\n" : "-MAP\n", 5);
    }
}

static RkValue events(P* s) {
    Buf o;
    Doc* d;
    RkValue r;
    memset(&o, 0, sizeof o);
    /* the output buffer is s->sb, so an error frees it with everything else */
    s->sb.len = 0;
    badd(s, &s->sb, "+STR\n", 5);
    for (d = s->docs; d; d = d->next) {
        badd(s, &s->sb, d->explicit_start ? "+DOC ---\n" : "+DOC\n", d->explicit_start ? 9 : 5);
        ev_node(s, &s->sb, d->root);
        badd(s, &s->sb, d->explicit_end ? "-DOC ...\n" : "-DOC\n", d->explicit_end ? 9 : 5);
    }
    badd(s, &s->sb, "-STR\n", 5);
    (void)o;
    /* an escape such as "\n" before a combining mark composes with it in
       the Raku side's text ("\\n" and U+0301 are "\\ń") */
    if (has_combining(s->sb.buf, s->sb.len)) {
        size_t n;
        const char* t = compose(s, s->sb.buf, s->sb.len, &n);
        if (t) return rk_str(s->c, t, n);
    }
    r = rk_str(s->c, s->sb.buf, s->sb.len);
    return r;
}

/* ---- construction ----------------------------------------------------------
 * Plain scalars are resolved by the YAML 1.2 core schema; quoted and block
 * scalars are strings. A tag from the core schema overrides the style; any
 * other tag is kept in the event stream and otherwise ignored. */

static int teq(const Node* n, const char* t) {
    size_t l = strlen(t);
    return n->tag && n->tagn == l && memcmp(n->tag, t, l) == 0;
}
#define CORE "tag:yaml.org,2002:"

static int word_is(const char* t, size_t n, const char* w) {
    return strlen(w) == n && memcmp(t, w, n) == 0;
}

static int is_null(const char* t, size_t n) {
    return n == 0 || word_is(t, n, "~") || word_is(t, n, "null") || word_is(t, n, "Null") || word_is(t, n, "NULL");
}
static int is_bool(const char* t, size_t n, int* v) {
    if (word_is(t, n, "true") || word_is(t, n, "True") || word_is(t, n, "TRUE")) { *v = 1; return 1; }
    if (word_is(t, n, "false") || word_is(t, n, "False") || word_is(t, n, "FALSE")) { *v = 0; return 1; }
    return 0;
}
/* 1 decimal, 8 octal (0o), 16 hex (0x); 0 if not an integer */
static int int_form(const char* t, size_t n) {
    size_t i = 0;
    if (n > 2 && t[0] == '0' && (t[1] == 'o' || t[1] == 'x')) {
        int hex = t[1] == 'x';
        for (i = 2; i < n; i++)
            if (hex ? !is_hex((unsigned char)t[i]) : !(t[i] >= '0' && t[i] <= '7')) return 0;
        return hex ? 16 : 8;
    }
    if (i < n && (t[i] == '-' || t[i] == '+')) i++;
    if (i == n) return 0;
    for (; i < n; i++) if (!(t[i] >= '0' && t[i] <= '9')) return 0;
    return 1;
}
/* 1 a number, 2 infinity, 3 NaN; 0 if not a float */
static int float_form(const char* t, size_t n) {
    size_t i = 0, d = 0;
    if (i < n && (t[i] == '-' || t[i] == '+')) i++;
    if (n - i == 4 && t[i] == '.' && (word_is(t + i + 1, 3, "inf") || word_is(t + i + 1, 3, "Inf") || word_is(t + i + 1, 3, "INF")))
        return 2;
    if (n == 4 && (word_is(t, n, ".nan") || word_is(t, n, ".NaN") || word_is(t, n, ".NAN"))) return 3;
    while (i < n && t[i] >= '0' && t[i] <= '9') { i++; d++; }
    if (i < n && t[i] == '.') {
        i++;
        while (i < n && t[i] >= '0' && t[i] <= '9') { i++; d++; }
    }
    if (!d) return 0;
    if (i < n && (t[i] == 'e' || t[i] == 'E')) {
        size_t e = 0;
        i++;
        if (i < n && (t[i] == '-' || t[i] == '+')) i++;
        while (i < n && t[i] >= '0' && t[i] <= '9') { i++; e++; }
        if (!e) return 0;
    }
    return i == n ? 1 : 0;
}

static RkValue make_int(P* s, const char* t, size_t n, int base) {
    if (base == 1) {
        size_t i = 0, digits;
        int neg = 0;
        if (t[0] == '-' || t[0] == '+') { neg = t[0] == '-'; i = 1; }
        while (i + 1 < n && t[i] == '0') i++;
        digits = n - i;
        if (digits <= 18) {
            long long v = 0;
            for (; i < n; i++) v = v * 10 + (t[i] - '0');
            return rk_int(s->c, neg ? -v : v);
        }
        else {
            char* b = (char*)alloc(s, digits + 2);
            size_t o = 0;
            if (neg) b[o++] = '-';
            memcpy(b + o, t + i, digits);
            b[o + digits] = '\0';
            return rk_int_s(s->c, b);
        }
    }
    else {
        size_t i = 2;
        unsigned long long v = 0;
        while (i < n && t[i] == '0') i++;
        if ((n - i) * (base == 16 ? 4 : 3) <= 62) {
            for (; i < n; i++) v = v * (unsigned)base + (unsigned)hexval((unsigned char)t[i]);
            return rk_int(s->c, (long long)v);
        }
        else {
            /* wider than int64: the Raku side has the arbitrary precision */
            RkValue arg = rk_str(s->c, t, n);
            RkValue r = rk_call(s->c, "yaml-native-int", &arg, 1);
            if (!r) { rk_clear_error(s->c); fail(s, "out of memory"); }
            return r;
        }
    }
}

static RkValue make_float(P* s, const char* t, size_t n, int form) {
    if (form == 2) return rk_num(s->c, t[0] == '-' ? -1.0 / 0.0 : 1.0 / 0.0);
    if (form == 3) return rk_num(s->c, 0.0 / 0.0);
    {
        char small[64];
        char* b = n < sizeof small ? small : (char*)alloc(s, n + 1);
        memcpy(b, t, n);
        b[n] = '\0';
        return rk_num(s->c, strtod(b, 0));
    }
}

static RkValue text_value(P* s, const char* t, size_t n) {
    return rk_str(s->c, t, n);
}

static RkValue build(P* s, Node* n);

static RkValue build_scalar(P* s, Node* n) {
    const char* t = n->s;
    size_t len = n->n;
    int b, form;
    if (n->tag) {
        if (teq(n, CORE "str") || teq(n, "!")) return text_value(s, t, len);
        if (teq(n, CORE "null")) {
            if (!is_null(t, len)) fail_name(s, "", t, len, " is not a valid !!null", n->line);
            return rk_any(s->c);
        }
        if (teq(n, CORE "bool")) {
            if (!is_bool(t, len, &b)) fail_name(s, "", t, len, " is not a valid !!bool", n->line);
            return rk_bool(s->c, b);
        }
        if (teq(n, CORE "int")) {
            form = int_form(t, len);
            if (!form) fail_name(s, "", t, len, " is not a valid !!int", n->line);
            return make_int(s, t, len, form);
        }
        if (teq(n, CORE "float")) {
            form = float_form(t, len);
            if (!form) fail_name(s, "", t, len, " is not a valid !!float", n->line);
            return make_float(s, t, len, form);
        }
        if (teq(n, CORE "map") || teq(n, CORE "seq"))
            fail_name(s, "the tag ", n->tag, n->tagn, " cannot be applied to a scalar", n->line);
    }
    if (n->style != S_PLAIN) return text_value(s, t, len);
    if (is_null(t, len)) return rk_any(s->c);
    if (is_bool(t, len, &b)) return rk_bool(s->c, b);
    if ((form = int_form(t, len))) return make_int(s, t, len, form);
    if ((form = float_form(t, len))) return make_float(s, t, len, form);
    return text_value(s, t, len);
}

/* The keys a mapping has so far, to refuse a duplicate. */
typedef struct { const char* k; size_t n; } Key;
typedef struct { Key* v; size_t cap, n; } KeySet;

static int keyset_add(P* s, KeySet* ks, const char* k, size_t n) {
    size_t i, mask;
    if ((ks->n + 1) * 2 > ks->cap) {
        size_t cap = ks->cap ? ks->cap * 2 : 16, j;
        Key* nv = (Key*)alloc(s, cap * sizeof(Key));
        memset(nv, 0, cap * sizeof(Key));
        for (j = 0; j < ks->cap; j++) {
            if (!ks->v[j].k) continue;
            i = hname(ks->v[j].k, ks->v[j].n) & (cap - 1);
            while (nv[i].k) i = (i + 1) & (cap - 1);
            nv[i] = ks->v[j];
        }
        ks->v = nv;
        ks->cap = cap;
    }
    mask = ks->cap - 1;
    i = hname(k, n) & mask;
    while (ks->v[i].k) {
        if (ks->v[i].n == n && memcmp(ks->v[i].k, k, n) == 0) return 0;
        i = (i + 1) & mask;
    }
    ks->v[i].k = k ? k : "";
    ks->v[i].n = n;
    ks->n++;
    return 1;
}

static Node* deref(Node* n) { return n->kind == N_ALIAS ? n->target : n; }

static int is_merge_key(Node* k) {
    return k->kind == N_SCALAR && k->n == 2 && k->s[0] == '<' && k->s[1] == '<'
        && ((k->style == S_PLAIN && !k->tag) || teq(k, CORE "merge"));
}

static void merge_from(P* s, RkValue h, KeySet* ks, RkValue src) {
    size_t i, count = rk_elems(s->c, src);
    for (i = 0; i < count; i++) {
        size_t kn;
        const char* k = rk_key_at(s->c, src, i, &kn);
        if (keyset_add(s, ks, keep(s, k, kn), kn)) rk_set(s->c, h, k, kn, rk_val_at(s->c, src, i));
    }
}

static RkValue build_map(P* s, Node* n) {
    RkValue h = rk_hash(s->c);
    KeySet ks;
    Node *k, *v;
    int merges = 0;
    memset(&ks, 0, sizeof ks);
    if (n->tag && (teq(n, CORE "seq") || teq(n, CORE "str") || teq(n, CORE "int") || teq(n, CORE "float")
                   || teq(n, CORE "bool") || teq(n, CORE "null")))
        fail_name(s, "the tag ", n->tag, n->tagn, " cannot be applied to a mapping", n->line);
    for (k = n->first; k; k = v->next) {
        Node* kk;
        v = k->next;
        if (is_merge_key(k)) { merges = 1; continue; }
        kk = deref(k);
        if (kk->kind != N_SCALAR)
            fail_at(s, "a mapping or a sequence cannot be a mapping key", k->line);
        if (!keyset_add(s, &ks, kk->s, kk->n)) fail_name(s, "duplicate key ", kk->s, kk->n, "", k->line);
        rk_set(s->c, h, kk->s, kk->n, build(s, v));
    }
    if (merges) {
        for (k = n->first; k; k = v->next) {
            Node* vv;
            v = k->next;
            if (!is_merge_key(k)) continue;
            vv = deref(v);
            if (vv->kind == N_MAP) merge_from(s, h, &ks, build(s, v));
            else if (vv->kind == N_SEQ) {
                Node* e;
                for (e = vv->first; e; e = e->next) {
                    if (deref(e)->kind != N_MAP)
                        fail_at(s, "a merge key ('<<') takes a mapping or a sequence of mappings", e->line);
                    merge_from(s, h, &ks, build(s, e));
                }
            }
            else fail_at(s, "a merge key ('<<') takes a mapping or a sequence of mappings", v->line);
        }
    }
    return h;
}

static RkValue build(P* s, Node* n) {
    RkValue v;
    Node* c;
    if (n->kind == N_ALIAS) {
        Node* t = n->target;
        if (t->building) fail_name(s, "recursive alias ", n->s, n->n, "", n->line);
        s->expanded += t->size;
        if (s->expanded > MAX_ALIAS) fail_at(s, "aliases expand the document beyond 1000000 nodes", n->line);
        if (t->built) return t->built;
        return build(s, t);
    }
    if (n->kind == N_SCALAR) v = build_scalar(s, n);
    else {
        n->building = 1;
        if (n->kind == N_SEQ) {
            if (n->tag && (teq(n, CORE "map") || teq(n, CORE "str") || teq(n, CORE "int") || teq(n, CORE "float")
                           || teq(n, CORE "bool") || teq(n, CORE "null")))
                fail_name(s, "the tag ", n->tag, n->tagn, " cannot be applied to a sequence", n->line);
            v = rk_array(s->c);
            for (c = n->first; c; c = c->next) rk_push(s->c, v, build(s, c));
        }
        else v = build_map(s, n);
        n->building = 0;
    }
    if (n->anchor) n->built = v;
    return v;
}

/* ---- the entry points ----------------------------------------------------- */
static P* start(RkCtx c) {
    P* s = (P*)calloc(1, sizeof(P));
    if (!s) { rk_die(c, "YAML::Native: out of memory"); return 0; }
    s->c = c;
    return s;
}

static RkValue finish_error(P* s) {
    RkCtx c = s->c;
    if (!bneed(&s->msg, 0)) rk_die(c, "YAML::Native: out of memory");
    else { s->msg.buf[s->msg.len] = '\0'; rk_die(c, s->msg.buf); }
    cleanup(s);
    free(s);
    return 0;
}

/* The text as both parsers read it: prepared, and composed first when it
   holds a combining mark, as the Raku parser composes it. */
static void read_text(P* s, const char* text, size_t len) {
    prepare(s, text, len);
    if (s->need_nfc) {
        size_t n;
        const char* t = compose(s, text, len, &n);
        if (t) {
            free(s->in);
            s->in = 0;
            prepare(s, t, n);
        }
    }
}

/* yaml-native-load($text, $all): the documents as values — the one document,
   or with $all a list of them. */
static RkValue yaml_load(RkCtx c) {
    size_t len = 0;
    const char* text = rk_str_get(c, rk_arg(c, 0), &len);
    int all = rk_argc(c) > 1 && rk_truthy(c, rk_arg(c, 1));
    P* s = start(c);
    RkValue out;
    if (!s) return 0;
    if (setjmp(s->jb)) return finish_error(s);
    read_text(s, text, len);
    parse_stream(s);
    if (all) {
        Doc* d;
        out = rk_array(c);
        for (d = s->docs; d; d = d->next) {
            s->expanded = 0;
            rk_push(c, out, build(s, d->root));
        }
    }
    else if (s->ndocs == 0) out = rk_any(c);
    else if (s->ndocs > 1) {
        char m[128];
        snprintf(m, sizeof m, "the stream holds %lu documents; read them with :all", (unsigned long)s->ndocs);
        fail_at(s, m, s->docs->next->root->line);
        out = 0;
    }
    else out = build(s, s->docs->root);
    cleanup(s);
    free(s);
    return out;
}

/* yaml-native-events($text): the parse as the yaml-test-suite's event
   stream, one event per line. */
static RkValue yaml_events(RkCtx c) {
    size_t len = 0;
    const char* text = rk_str_get(c, rk_arg(c, 0), &len);
    P* s = start(c);
    RkValue out;
    if (!s) return 0;
    if (setjmp(s->jb)) return finish_error(s);
    read_text(s, text, len);
    parse_stream(s);
    out = events(s);
    cleanup(s);
    free(s);
    return out;
}

static const RkSubDef subs[] = {
    {"yaml-native-load",   yaml_load},
    {"yaml-native-events", yaml_events},
    {0, 0}
};
/* ABI 2 is what this file needs — rk_call, for integers wider than int64 —
   and nothing of ABI 3's, so it says 2 and loads on any host from 2 on. */
#define YAML_NATIVE_ABI 2u
static const RkModule mod = { YAML_NATIVE_ABI, "YAML::Native", subs };

RAKUPP_EXT_EXPORT const RkModule* rakupp_ext_init(unsigned host_abi) {
    return host_abi >= YAML_NATIVE_ABI ? &mod : 0;
}
