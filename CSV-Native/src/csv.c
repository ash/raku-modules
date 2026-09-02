/* csv.c — the native half of CSV::Native.
 *
 * Plain C against <rakupp/rakupp_ext.h> and nothing else, for the same reason
 * JSON::Native's json.c is: an extension that never sees the interpreter's
 * value layout keeps working across compiler releases, so the module versions
 * on its own schedule.
 *
 * THE CONTRACT. This file and the pure-Raku implementation in
 * lib/CSV/Native.rakumod are two spellings of ONE specification — the one the
 * README states — and the test suite runs every case through both and demands
 * the same rows, the same text and the same error message. So nothing here is
 * allowed to be "close": a field is the bytes between separators, a quoted
 * field is the bytes between quotes with a doubled quote meaning one quote,
 * and anything else is an error that names its line. There is no third
 * implementation to stand aside for, which is what makes the two-way parity
 * check the whole test.
 *
 * Bytes, not characters. The separator and the quote arrive as UTF-8 and are
 * matched by memcmp, so a multi-byte separator ("→", "::") costs nothing
 * special, and a field's bytes are handed to rk_str untouched — the host
 * treats them as the UTF-8 they are. An unquoted field is a pointer into the
 * source and is never copied here; a quoted field is too unless it holds a
 * doubled quote, in which case it is decoded into one buffer shared by the
 * whole parse (grown geometrically, never per field — json.c learned that the
 * expensive way).
 *
 * Line numbers in errors are counted the way the reader would: LF, CRLF and a
 * lone CR each end a line, inside a quoted field as well as outside it, and an
 * error names the line the offending FIELD started on — for an unterminated
 * quote that is the line to look at, not the end of the file.
 */
#include <rakupp/rakupp_ext.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- shared: a growable byte buffer ------------------------------------- */
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
static int bmem(Buf* b, const char* s, size_t n) {
    if (!bneed(b, n)) return 0;
    memcpy(b->buf + b->len, s, n);
    b->len += n;
    return 1;
}

/* ---- parsing ------------------------------------------------------------- */

typedef struct {
    const char* p;
    const char* end;
    RkCtx       c;
    const char* sep;  size_t sepl;
    const char* quo;  size_t quol;
    long        line;      /* 1-based, the line `p` is on */
    int         failed;
    Buf         dec;       /* decode buffer for quoted fields with doubled quotes */
} P;

enum { T_SEP, T_EOL, T_EOF };

static void fail(P* s, const char* msg) {
    if (!s->failed) {
        rk_die(s->c, msg);
        s->failed = 1;
    }
}

static void fail_line(P* s, const char* what, long line) {
    char buf[200];
    snprintf(buf, sizeof buf, "CSV::Native: %s at line %ld", what, line);
    fail(s, buf);
}

static int at(P* s, const char* needle, size_t n) {
    return (size_t)(s->end - s->p) >= n && memcmp(s->p, needle, n) == 0;
}

/* Consume one line ending at p (LF, CRLF or a lone CR) and count it. */
static void eol(P* s) {
    if (*s->p == '\r') {
        s->p++;
        if (s->p < s->end && *s->p == '\n') s->p++;
    }
    else s->p++;
    s->line++;
}

/* One field. Sets *term to what ended it. Returns NULL after rk_die. */
static RkValue field(P* s, int* term) {
    long fline = s->line;
    const char* start;

    if (at(s, s->quo, s->quol)) {
        /* Quoted. Zero-copy until the first doubled quote; from there on the
           field is assembled in the shared decode buffer. */
        int decoded = 0;
        const char* fp = 0;
        size_t fl = 0;
        s->p += s->quol;
        start = s->p;
        s->dec.len = 0;
        for (;;) {
            if (s->p >= s->end) {
                fail_line(s, "unterminated quoted field starting", fline);
                return 0;
            }
            if (*s->p == s->quo[0] && at(s, s->quo, s->quol)) {
                const char* q = s->p;
                s->p += s->quol;
                if (at(s, s->quo, s->quol)) {
                    /* doubled: one quote of content */
                    decoded = 1;
                    if (!bmem(&s->dec, start, (size_t)(q - start)) ||
                        !bmem(&s->dec, s->quo, s->quol)) {
                        fail(s, "CSV::Native: out of memory");
                        return 0;
                    }
                    s->p += s->quol;
                    start = s->p;
                    continue;
                }
                /* closing */
                if (decoded) {
                    if (!bmem(&s->dec, start, (size_t)(q - start))) {
                        fail(s, "CSV::Native: out of memory");
                        return 0;
                    }
                    fp = s->dec.buf; fl = s->dec.len;
                }
                else { fp = start; fl = (size_t)(q - start); }
                break;
            }
            if (*s->p == '\n' || *s->p == '\r') eol(s);
            else s->p++;
        }
        /* After a closing quote only a separator, a line ending or the end of
           the text may follow — a space there is an error, not content. */
        if (s->p >= s->end) *term = T_EOF;
        else if (at(s, s->sep, s->sepl)) { s->p += s->sepl; *term = T_SEP; }
        else if (*s->p == '\n' || *s->p == '\r') { eol(s); *term = T_EOL; }
        else { fail_line(s, "text after a closing quote", fline); return 0; }
        return rk_str(s->c, fp, fl);
    }

    /* Unquoted: everything up to the next separator or line ending, and a
       quote anywhere in it is an error (RFC 4180: a field holding a quote
       must itself be quoted). */
    start = s->p;
    for (;;) {
        char ch;
        if (s->p >= s->end) { *term = T_EOF; break; }
        ch = *s->p;
        if (ch == s->sep[0] && at(s, s->sep, s->sepl)) {
            RkValue v = rk_str(s->c, start, (size_t)(s->p - start));
            s->p += s->sepl;
            *term = T_SEP;
            return v;
        }
        if (ch == '\n' || ch == '\r') {
            RkValue v = rk_str(s->c, start, (size_t)(s->p - start));
            eol(s);
            *term = T_EOL;
            return v;
        }
        if (ch == s->quo[0] && at(s, s->quo, s->quol)) {
            fail_line(s, "a quote inside an unquoted field", fline);
            return 0;
        }
        s->p++;
    }
    return rk_str(s->c, start, (size_t)(s->p - start));
}

typedef struct { const char* k; size_t kl; } Key;

/* Header names from a row or a list: borrowed pointers, valid for the call. */
static int take_keys(P* s, RkValue list, Key** keys, size_t* nkeys) {
    size_t n = rk_elems(s->c, list), i, j;
    Key* ks = (Key*)malloc((n ? n : 1) * sizeof(Key));
    if (!ks) { fail(s, "CSV::Native: out of memory"); return 0; }
    for (i = 0; i < n; i++) {
        size_t kl = 0;
        ks[i].k = rk_str_get(s->c, rk_at_pos(s->c, list, i), &kl);
        ks[i].kl = kl;
    }
    /* A duplicate name would make one column silently overwrite another. */
    for (i = 0; i < n; i++)
        for (j = i + 1; j < n; j++)
            if (ks[i].kl == ks[j].kl && memcmp(ks[i].k, ks[j].k, ks[i].kl) == 0) {
                char msg[300];
                size_t show = ks[i].kl < 200 ? ks[i].kl : 200;
                snprintf(msg, sizeof msg, "CSV::Native: duplicate header '%.*s'", (int)show, ks[i].k);
                fail(s, msg);
                free(ks);
                return 0;
            }
    *keys = ks; *nkeys = n;
    return 1;
}

static RkValue from_csv_native(RkCtx c) {
    size_t len = 0;
    const char* text = rk_str_get(c, rk_arg(c, 0), &len);
    RkValue vsep = rk_named(c, "sep");
    RkValue vquo = rk_named(c, "quote");
    RkValue vhdr = rk_named(c, "headers");
    RkValue vstr = rk_named(c, "strict");
    P s;
    RkValue rows;
    RkValue* cells = 0;      /* the current record's fields */
    size_t ncells = 0, capcells = 0;
    Key* keys = 0;           /* header names, once known */
    size_t nkeys = 0;
    int want_header = 0;     /* the first record IS the header */
    int strict, have_expected = 0;
    size_t expected = 0;
    RkType ht;

    memset(&s, 0, sizeof s);
    s.c = c;
    s.sep = rk_str_get(c, vsep, &s.sepl);
    s.quo = rk_str_get(c, vquo, &s.quol);
    s.line = 1;
    strict = vstr ? rk_truthy(c, vstr) : 0;
    /* The Raku side validates the dialect before calling; these two are
       repeated because an empty needle matches everywhere and a scan that
       never advances would hang rather than fail. */
    if (s.sepl == 0) { rk_die(c, "CSV::Native: sep must not be empty"); return 0; }
    if (s.quol == 0) { rk_die(c, "CSV::Native: quote must be exactly one character, not ''"); return 0; }

    /* :headers — True: the first record names the columns; a list: these
       names do, and every record is data; anything else: plain rows. The
       Raku side has already normalised the option, so this is a dispatch,
       not a validation. */
    ht = vhdr ? rk_type(c, vhdr) : RK_ANY;
    if (ht == RK_ARRAY) {
        if (!take_keys(&s, vhdr, &keys, &nkeys)) return 0;
        have_expected = 1; expected = nkeys;
    }
    else if (ht == RK_BOOL && rk_truthy(c, vhdr)) want_header = 1;

    /* A UTF-8 byte-order mark is Excel's signature, not a field. */
    if (len >= 3 && (unsigned char)text[0] == 0xEF && (unsigned char)text[1] == 0xBB &&
        (unsigned char)text[2] == 0xBF) { text += 3; len -= 3; }
    s.p = text; s.end = text + len;

    rows = rk_array(c);
    while (s.p < s.end) {
        long row_line = s.line;
        int term;
        ncells = 0;
        for (;;) {
            RkValue f = field(&s, &term);
            if (!f) goto fail;
            if (ncells == capcells) {
                size_t want = capcells ? capcells * 2 : 16;
                RkValue* nc = (RkValue*)realloc(cells, want * sizeof(RkValue));
                if (!nc) { fail(&s, "CSV::Native: out of memory"); goto fail; }
                cells = nc; capcells = want;
            }
            cells[ncells++] = f;
            if (term != T_SEP) break;
        }

        if (want_header && !keys) {
            RkValue hrow = rk_array(c);
            size_t i;
            for (i = 0; i < ncells; i++) rk_push(c, hrow, cells[i]);
            if (!take_keys(&s, hrow, &keys, &nkeys)) goto fail;
            have_expected = 1; expected = nkeys;
            continue;
        }
        if (strict) {
            if (!have_expected) { have_expected = 1; expected = ncells; }
            else if (ncells != expected) {
                char msg[200];
                snprintf(msg, sizeof msg, "CSV::Native: line %ld has %zu fields, expected %zu",
                         row_line, ncells, expected);
                fail(&s, msg);
                goto fail;
            }
        }
        if (keys) {
            RkValue h;
            size_t i;
            if (ncells > nkeys) {
                char msg[200];
                snprintf(msg, sizeof msg, "CSV::Native: line %ld has %zu fields but the header has %zu",
                         row_line, ncells, nkeys);
                fail(&s, msg);
                goto fail;
            }
            h = rk_hash(c);
            for (i = 0; i < ncells; i++) rk_set(c, h, keys[i].k, keys[i].kl, cells[i]);
            rk_push(c, rows, h);
        }
        else {
            RkValue a = rk_array(c);
            size_t i;
            for (i = 0; i < ncells; i++) rk_push(c, a, cells[i]);
            rk_push(c, rows, a);
        }
    }
    free(cells); free(keys); free(s.dec.buf);
    return rows;

fail:
    free(cells); free(keys); free(s.dec.buf);
    return 0;
}

/* ---- writing ------------------------------------------------------------- */

typedef struct {
    Buf         out;
    RkCtx       c;
    const char* sep;  size_t sepl;
    const char* quo;  size_t quol;
    const char* eol;  size_t eoll;
    int         always;
    int         failed;
} W;

static void wfail(W* w, const char* msg) {
    if (!w->failed) { rk_die(w->c, msg); w->failed = 1; }
}

/* Does `s` contain `needle`? A byte scan keyed on the first byte, so a
   one-byte separator (the usual case) costs one pass with no memcmp. */
static int has(const char* s, size_t n, const char* needle, size_t nl) {
    size_t i;
    if (nl == 0 || n < nl) return 0;
    for (i = 0; i + nl <= n; i++)
        if (s[i] == needle[0] && (nl == 1 || memcmp(s + i, needle, nl) == 0)) return 1;
    return 0;
}

/* One cell: its Str, quoted when the separator, the quote or a line ending
   is in it (or always, when asked); an undefined value is an empty field. */
static void wcell(W* w, RkValue v) {
    const char* s = "";
    size_t n = 0;
    int quote;
    if (w->failed) return;
    if (v && rk_type(w->c, v) != RK_ANY) s = rk_str_get(w->c, v, &n);
    quote = w->always || has(s, n, w->sep, w->sepl) || has(s, n, w->quo, w->quol) ||
            memchr(s, '\n', n) != 0 || memchr(s, '\r', n) != 0;
    if (!quote) { if (!bmem(&w->out, s, n)) wfail(w, "CSV::Native: out of memory"); return; }
    if (!bmem(&w->out, w->quo, w->quol)) { wfail(w, "CSV::Native: out of memory"); return; }
    {
        size_t i, from = 0;
        for (i = 0; i + w->quol <= n; ) {
            if (s[i] == w->quo[0] && (w->quol == 1 || memcmp(s + i, w->quo, w->quol) == 0)) {
                /* the quote itself, then again: a doubled quote */
                if (!bmem(&w->out, s + from, i + w->quol - from) ||
                    !bmem(&w->out, w->quo, w->quol)) { wfail(w, "CSV::Native: out of memory"); return; }
                i += w->quol; from = i;
            }
            else i++;
        }
        if (!bmem(&w->out, s + from, n - from)) { wfail(w, "CSV::Native: out of memory"); return; }
    }
    if (!bmem(&w->out, w->quo, w->quol)) wfail(w, "CSV::Native: out of memory");
}

static void wrow_cells(W* w, RkValue* cells, size_t n) {
    size_t i;
    for (i = 0; i < n && !w->failed; i++) {
        if (i && !bmem(&w->out, w->sep, w->sepl)) { wfail(w, "CSV::Native: out of memory"); return; }
        wcell(w, cells[i]);
    }
    if (!w->failed && !bmem(&w->out, w->eol, w->eoll)) wfail(w, "CSV::Native: out of memory");
}

static RkValue to_csv_native(RkCtx c) {
    RkValue rows = rk_arg(c, 0);
    RkValue vsep = rk_named(c, "sep");
    RkValue vquo = rk_named(c, "quote");
    RkValue veol = rk_named(c, "eol");
    RkValue vhdr = rk_named(c, "headers");
    RkValue vline = rk_named(c, "header-line");
    RkValue valw = rk_named(c, "always-quote");
    W w;
    Key* keys = 0;
    size_t nkeys = 0, nrows, r;
    RkValue* cells = 0;
    size_t capcells = 0;
    RkValue out;

    memset(&w, 0, sizeof w);
    w.c = c;
    w.sep = rk_str_get(c, vsep, &w.sepl);
    w.quo = rk_str_get(c, vquo, &w.quol);
    w.eol = rk_str_get(c, veol, &w.eoll);
    w.always = valw ? rk_truthy(c, valw) : 0;

    /* The Raku side resolved :headers into a list of names (possibly empty)
       and a flag saying whether to write them as the first line. */
    if (vhdr && rk_type(c, vhdr) == RK_ARRAY) {
        size_t i;
        nkeys = rk_elems(c, vhdr);
        keys = (Key*)malloc((nkeys ? nkeys : 1) * sizeof(Key));
        cells = (RkValue*)malloc((nkeys ? nkeys : 1) * sizeof(RkValue));
        if (!keys || !cells) { free(keys); free(cells); rk_die(c, "CSV::Native: out of memory"); return 0; }
        capcells = nkeys;
        for (i = 0; i < nkeys; i++) {
            size_t kl = 0;
            cells[i] = rk_at_pos(c, vhdr, i);
            keys[i].k = rk_str_get(c, cells[i], &kl);
            keys[i].kl = kl;
        }
        if (vline && rk_truthy(c, vline)) wrow_cells(&w, cells, nkeys);
    }

    nrows = rk_elems(c, rows);
    for (r = 0; r < nrows && !w.failed; r++) {
        RkValue row = rk_at_pos(c, rows, r);
        RkType t = rk_type(c, row);
        if (t == RK_ARRAY) {
            size_t n = rk_elems(c, row), i;
            if (n > capcells) {
                RkValue* nc = (RkValue*)realloc(cells, n * sizeof(RkValue));
                if (!nc) { wfail(&w, "CSV::Native: out of memory"); break; }
                cells = nc; capcells = n;
            }
            for (i = 0; i < n; i++) cells[i] = rk_at_pos(c, row, i);
            wrow_cells(&w, cells, n);
        }
        else if (t == RK_HASH) {
            /* Project the hash onto the header order. The ABI walks a hash by
               index, not by key, so each key is placed by searching the
               header names — trying the same index first, since rows of one
               file usually carry their keys in one order. */
            size_t n, m, i;
            if (!nkeys) {
                char msg[120];
                snprintf(msg, sizeof msg, "CSV::Native: row %zu is a hash but no headers are known", r);
                wfail(&w, msg);
                break;
            }
            for (i = 0; i < nkeys; i++) cells[i] = 0;
            n = rk_elems(c, row);
            for (m = 0; m < n; m++) {
                size_t kl = 0, idx = (size_t)-1;
                const char* k = rk_key_at(c, row, m, &kl);
                if (!k) break;
                if (m < nkeys && keys[m].kl == kl && memcmp(keys[m].k, k, kl) == 0) idx = m;
                else
                    for (i = 0; i < nkeys; i++)
                        if (keys[i].kl == kl && memcmp(keys[i].k, k, kl) == 0) { idx = i; break; }
                /* a key outside the header is simply not a column */
                if (idx != (size_t)-1) cells[idx] = rk_val_at(c, row, m);
                else (void)rk_val_at(c, row, m);   /* keep the walk sequential */
            }
            wrow_cells(&w, cells, nkeys);
        }
        else {
            char msg[120];
            snprintf(msg, sizeof msg, "CSV::Native: row %zu is not a list or a hash", r);
            wfail(&w, msg);
            break;
        }
    }

    free(keys); free(cells);
    if (w.failed) { free(w.out.buf); return 0; }
    out = rk_str(c, w.out.buf ? w.out.buf : "", w.out.len);
    free(w.out.buf);
    return out;
}

static const RkSubDef subs[] = {
    {"from-csv-native", from_csv_native},
    {"to-csv-native",   to_csv_native},
    {0, 0}
};
static const RkModule mod = { RAKUPP_EXT_ABI, "CSV::Native", subs };

RAKUPP_EXT_EXPORT const RkModule* rakupp_ext_init(unsigned host_abi) {
    /* ABI 2 for the O(1) sequential hash walk the writer leans on. */
    return host_abi >= RAKUPP_EXT_ABI ? &mod : 0;
}
