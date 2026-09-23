/* textdiff.c — the native half of Text::Diff::Native.
 *
 * Plain C against <rakupp/rakupp_ext.h> and nothing else, as json.c and
 * csv.c are: an extension that never sees the interpreter's value layout
 * keeps working across compiler releases.
 *
 * THE CONTRACT. `script` below computes exactly what `changes-raku` in
 * lib/Text/Diff/Native.rakumod computes — not a shortest edit script, THE
 * shortest edit script that one finds, with the same tie-breaks, the same
 * split points and the same sliding — and `unified_diff_native` writes the
 * same bytes as `unified-raku`. The test suite runs every case, and a few
 * hundred random ones, through both and demands the same answer. So the
 * steps below are the Raku ones transcribed, in the same order and with the
 * same names, and a change to one is a change to both.
 *
 * Two entry points:
 *   diff-changes-native(ids-a, ids-b)  the script between two lists of line
 *       ids that Raku has numbered: [count of old changes, old indices...,
 *       new indices...]. diff() on arbitrary lists uses it.
 *   unified-diff-native(a, b, context, from, to)  the whole unified diff of
 *       two texts: lines, ids, script, hunks, text. In Raku those linear
 *       steps cost a hundred times what the search does, so the native path
 *       takes them all.
 *
 * Lines are bytes up to and including "\n", which is the Raku side's rule
 * ("\n" or "\r\n" ends a line, a lone "\r" is content) said in bytes.
 */
#include <rakupp/rakupp_ext.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- the script ------------------------------------------------------------ */

typedef struct {
    const long* a;      /* the kept elements (after discard) */
    const long* b;
    char*       ca;     /* ca[i]: a[i] is a change */
    char*       cb;
    long*       vf;     /* furthest x per diagonal, forward search */
    long*       vb;     /* the same, reverse search */
} S;

/* Myers' middle snake over a[a0,a1) and b[b0,b1), both non-empty. Stores
   the split point and returns 1, or returns 0 when the two share nothing. */
static int bisect(S* s, long a0, long a1, long b0, long b1, long* sx, long* sy) {
    long n = a1 - a0, m = b1 - b0;
    long max = (n + m + 1) / 2;
    long off = max + 1;
    long delta = n - m;
    int  front = delta % 2 != 0;   /* odd: the forward search checks for overlap */
    long kfs = 0, kfe = 0;         /* forward diagonals retired at each end */
    long kbs = 0, kbe = 0;         /* reverse diagonals retired at each end */
    long d, k;
    long* vf = s->vf;
    long* vb = s->vb;
    const long* a = s->a;
    const long* b = s->b;

    /* -1 is "not reached in this call"; each step clears the two diagonals
       it newly brings in range, as the Raku side explains */
    vf[off - 1] = -1; vf[off] = -1; vf[off + 1] = 0;
    vb[off - 1] = -1; vb[off] = -1; vb[off + 1] = 0;
    for (d = 0; d < max; d++) {
        if (d) {
            vf[off - d - 1] = -1; vf[off + d + 1] = -1;
            vb[off - d - 1] = -1; vb[off + d + 1] = -1;
        }
        for (k = kfs - d; k <= d - kfe; k += 2) {
            long ko = off + k, x, y;
            if (k == -d || (k != d && vf[ko - 1] < vf[ko + 1])) x = vf[ko + 1];
            else x = vf[ko - 1] + 1;
            y = x - k;
            while (x < n && y < m && a[a0 + x] == b[b0 + y]) { x++; y++; }
            vf[ko] = x;
            if (x > n) kfe += 2;
            else if (y > m) kfs += 2;
            else if (front) {
                long kr = off + delta - k;
                if (kr >= off - d - 1 && kr <= off + d + 1
                        && vb[kr] != -1 && x >= n - vb[kr]) {
                    *sx = a0 + x; *sy = b0 + y;
                    return 1;
                }
            }
        }
        for (k = kbs - d; k <= d - kbe; k += 2) {
            long ko = off + k, x, y;
            if (k == -d || (k != d && vb[ko - 1] < vb[ko + 1])) x = vb[ko + 1];
            else x = vb[ko - 1] + 1;
            y = x - k;
            while (x < n && y < m && a[a1 - 1 - x] == b[b1 - 1 - y]) { x++; y++; }
            vb[ko] = x;
            if (x > n) kbe += 2;
            else if (y > m) kbs += 2;
            else if (!front) {
                long kf = off + delta - k;
                if (kf >= off - d - 1 && kf <= off + d + 1 && vf[kf] != -1) {
                    long xf = vf[kf];
                    if (xf >= n - x) {
                        *sx = a0 + xf; *sy = b0 + xf - (kf - off);
                        return 1;
                    }
                }
            }
        }
    }
    return 0;
}

static void compare(S* s, long a0, long a1, long b0, long b1) {
    const long* a = s->a;
    const long* b = s->b;
    long sx, sy, x, y;
    while (a0 < a1 && b0 < b1 && a[a0] == b[b0]) { a0++; b0++; }
    while (a0 < a1 && b0 < b1 && a[a1 - 1] == b[b1 - 1]) { a1--; b1--; }
    if (a0 == a1) { for (y = b0; y < b1; y++) s->cb[y] = 1; return; }
    if (b0 == b1) { for (x = a0; x < a1; x++) s->ca[x] = 1; return; }
    if (bisect(s, a0, a1, b0, b1, &sx, &sy)) {
        compare(s, a0, sx, b0, sy);
        compare(s, sx, a1, sy, b1);
    }
    else {
        for (x = a0; x < a1; x++) s->ca[x] = 1;
        for (y = b0; y < b1; y++) s->cb[y] = 1;
    }
}

/* The script between a[0,n) and b[0,m), ids in 0 .. k-1, into ca and cb
   (zeroed by the caller): discard, compare, slide. Returns 0 when out of
   memory. */
static int script(const long* a, long n, const long* b, long m, long k,
                  char* ca, char* cb) {
    char *ina = 0, *inb = 0;
    long *x = 0, *xi = 0, *y = 0, *yi = 0, *v = 0;
    long xn = 0, yn = 0, i, j, vlen;
    S s;
    int ok = 0;

    /* discard: an element the other side does not have at all is a change
       in every shortest script */
    ina = (char*)calloc((size_t)(k ? k : 1), 1);
    inb = (char*)calloc((size_t)(k ? k : 1), 1);
    x  = (long*)malloc((size_t)(n ? n : 1) * sizeof(long));
    xi = (long*)malloc((size_t)(n ? n : 1) * sizeof(long));
    y  = (long*)malloc((size_t)(m ? m : 1) * sizeof(long));
    yi = (long*)malloc((size_t)(m ? m : 1) * sizeof(long));
    memset(&s, 0, sizeof s);
    if (!ina || !inb || !x || !xi || !y || !yi) goto done;
    for (i = 0; i < n; i++) ina[a[i]] = 1;
    for (j = 0; j < m; j++) inb[b[j]] = 1;
    for (i = 0; i < n; i++) {
        if (inb[a[i]]) { x[xn] = a[i]; xi[xn] = i; xn++; } else ca[i] = 1;
    }
    for (j = 0; j < m; j++) {
        if (ina[b[j]]) { y[yn] = b[j]; yi[yn] = j; yn++; } else cb[j] = 1;
    }

    vlen = 2 * ((xn + yn + 1) / 2) + 2;   /* the largest any subproblem needs */
    s.a = x; s.b = y;
    s.ca = (char*)calloc((size_t)(xn ? xn : 1), 1);
    s.cb = (char*)calloc((size_t)(yn ? yn : 1), 1);
    v = (long*)malloc((size_t)vlen * 2 * sizeof(long));
    if (!s.ca || !s.cb || !v) goto done;
    s.vf = v; s.vb = v + vlen;

    compare(&s, 0, xn, 0, yn);
    for (i = 0; i < xn; i++) if (s.ca[i]) ca[xi[i]] = 1;
    for (j = 0; j < yn; j++) if (s.cb[j]) cb[yi[j]] = 1;

    /* slide: walk both sides together; unchanged elements pair up in order */
    i = 0; j = 0;
    while (i < n || j < m) {
        long st, t;
        if (i < n && j < m && !ca[i] && !cb[j]) { i++; j++; continue; }
        st = i; t = j;
        while (i < n && ca[i]) i++;
        while (j < m && cb[j]) j++;
        if (t == j) {
            /* deletions a[st, i); a[i] pairs with b[j] */
            while (i < n && j < m && !ca[i] && !cb[j] && a[st] == a[i]) {
                ca[st] = 0; ca[i] = 1;
                st++; i++; j++;
            }
        }
        else if (st == i) {
            /* insertions b[t, j); b[j] pairs with a[i] */
            while (i < n && j < m && !ca[i] && !cb[j] && b[t] == b[j]) {
                cb[t] = 0; cb[j] = 1;
                t++; i++; j++;
            }
        }
    }
    ok = 1;

done:
    free(ina); free(inb); free(x); free(xi); free(y); free(yi);
    free(s.ca); free(s.cb); free(v);
    return ok;
}

/* ---- diff-changes-native ----------------------------------------------------- */

static long* int_list(RkCtx c, RkValue list, long* n, long* k) {
    long i, len = (long)rk_elems(c, list);
    long* v = (long*)malloc((size_t)(len ? len : 1) * sizeof(long));
    if (!v) return 0;
    for (i = 0; i < len; i++) {
        v[i] = (long)rk_int_get(c, rk_at_pos(c, list, (size_t)i));
        if (v[i] >= *k) *k = v[i] + 1;
    }
    *n = len;
    return v;
}

static RkValue flat(RkCtx c, const char* ca, long n, const char* cb, long m) {
    long i, count = 0;
    RkValue out = rk_array(c);
    for (i = 0; i < n; i++) count += ca[i];
    rk_push(c, out, rk_int(c, count));
    for (i = 0; i < n; i++) if (ca[i]) rk_push(c, out, rk_int(c, i));
    for (i = 0; i < m; i++) if (cb[i]) rk_push(c, out, rk_int(c, i));
    return out;
}

static RkValue diff_changes_native(RkCtx c) {
    long n = 0, m = 0, k = 0;
    long* a = int_list(c, rk_arg(c, 0), &n, &k);
    long* b = int_list(c, rk_arg(c, 1), &m, &k);
    char* ca = (char*)calloc((size_t)(n ? n : 1), 1);
    char* cb = (char*)calloc((size_t)(m ? m : 1), 1);
    RkValue out = 0;
    if (a && b && ca && cb && script(a, n, b, m, k, ca, cb)) out = flat(c, ca, n, cb, m);
    else rk_die(c, "Text::Diff::Native: out of memory");
    free(a); free(b); free(ca); free(cb);
    return out;
}

/* ---- unified-diff-native ----------------------------------------------------- */

typedef struct { const char* p; size_t len; } Line;

/* The lines of a text: each runs up to and including its "\n"; the last one
   has none when the text does not end with one. Returns the count, or -1
   when out of memory. */
static long split_lines(const char* t, size_t len, Line** out) {
    long n = 0, cap = 64;
    size_t i, start = 0;
    Line* v = (Line*)malloc((size_t)cap * sizeof(Line));
    if (!v) return -1;
    for (i = 0; i <= len; i++) {
        if (i == len ? i > start : t[i] == '\n') {
            if (n == cap) {
                Line* nv;
                cap *= 2;
                nv = (Line*)realloc(v, (size_t)cap * sizeof(Line));
                if (!nv) { free(v); return -1; }
                v = nv;
            }
            v[n].p = t + start;
            v[n].len = (i == len ? i : i + 1) - start;
            n++;
            start = i + 1;
        }
    }
    *out = v;
    return n;
}

static uint64_t fnv(const char* p, size_t n) {
    uint64_t h = 1469598103934665603ULL;
    size_t i;
    for (i = 0; i < n; i++) { h ^= (unsigned char)p[i]; h *= 1099511628211ULL; }
    return h;
}

/* Every distinct line gets a small integer: an open-addressed table of line
   indices into the combined list (old lines, then new). Returns the number
   of distinct lines, or -1 when out of memory. */
static long number_lines(const Line* all, long total, long* ids) {
    size_t cap = 16, mask, i;
    long* slot;
    long* sid;
    long next = 0, t;
    while (cap < (size_t)total * 2) cap *= 2;
    mask = cap - 1;
    slot = (long*)malloc(cap * sizeof(long));
    sid  = (long*)malloc(cap * sizeof(long));
    if (!slot || !sid) { free(slot); free(sid); return -1; }
    for (i = 0; i < cap; i++) slot[i] = -1;
    for (t = 0; t < total; t++) {
        const Line* l = &all[t];
        i = (size_t)fnv(l->p, l->len) & mask;
        for (;;) {
            long o = slot[i];
            if (o == -1) { slot[i] = t; sid[i] = next; ids[t] = next++; break; }
            if (all[o].len == l->len && memcmp(all[o].p, l->p, l->len) == 0) {
                ids[t] = sid[i];
                break;
            }
            i = (i + 1) & mask;
        }
    }
    free(slot); free(sid);
    return next;
}

typedef struct { char* buf; size_t len, cap; int oom; } Buf;

static void bmem(Buf* b, const char* s, size_t n) {
    if (b->oom) return;
    if (b->len + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 4096;
        char* nb;
        while (cap < b->len + n + 1) cap *= 2;
        nb = (char*)realloc(b->buf, cap);
        if (!nb) { b->oom = 1; return; }
        b->buf = nb; b->cap = cap;
    }
    memcpy(b->buf + b->len, s, n);
    b->len += n;
}
static void bstr(Buf* b, const char* s) { bmem(b, s, strlen(s)); }

/* A hunk header's range, as the Raku side's `range`. */
static void brange(Buf* b, long s, long e) {
    char tmp[64];
    long len = e - s;
    if (len == 1) snprintf(tmp, sizeof tmp, "%ld", s + 1);
    else if (len == 0) snprintf(tmp, sizeof tmp, "%ld,0", s);
    else snprintf(tmp, sizeof tmp, "%ld,%ld", s + 1, len);
    bstr(b, tmp);
}

static void bline(Buf* b, char mark, const Line* l) {
    bmem(b, &mark, 1);
    bmem(b, l->p, l->len);
    if (l->len == 0 || l->p[l->len - 1] != '\n') bstr(b, "\n\\ No newline at end of file\n");
}

typedef struct { long as, ae, bs, be; } Hunk;

static RkValue unified_diff_native(RkCtx c) {
    size_t la = 0, lb = 0, lfrom = 0, lto = 0;
    const char* ta   = rk_str_get(c, rk_arg(c, 0), &la);
    const char* tb   = rk_str_get(c, rk_arg(c, 1), &lb);
    long ctx         = (long)rk_int_get(c, rk_arg(c, 2));
    const char* from = rk_str_get(c, rk_arg(c, 3), &lfrom);
    const char* to   = rk_str_get(c, rk_arg(c, 4), &lto);
    Line *A = 0, *B = 0, *all = 0;
    long n, m, k, i, j, nh = 0, caph = 16;
    long *ids = 0;
    char *ca = 0, *cb = 0;
    Hunk* h = 0;
    Buf out;
    RkValue r = 0;

    memset(&out, 0, sizeof out);
    n = split_lines(ta, la, &A);
    m = split_lines(tb, lb, &B);
    if (n < 0 || m < 0) goto oom;
    all = (Line*)malloc((size_t)(n + m ? n + m : 1) * sizeof(Line));
    ids = (long*)malloc((size_t)(n + m ? n + m : 1) * sizeof(long));
    ca  = (char*)calloc((size_t)(n ? n : 1), 1);
    cb  = (char*)calloc((size_t)(m ? m : 1), 1);
    h   = (Hunk*)malloc((size_t)caph * sizeof(Hunk));
    if (!all || !ids || !ca || !cb || !h) goto oom;
    if (n) memcpy(all, A, (size_t)n * sizeof(Line));
    if (m) memcpy(all + n, B, (size_t)m * sizeof(Line));
    k = number_lines(all, n + m, ids);
    if (k < 0 || !script(ids, n, ids + n, m, k, ca, cb)) goto oom;

    /* hunks: the change blocks, merged while no more than 2 × context
       unchanged lines lie between them, then widened by the context */
    i = 0; j = 0;
    while (i < n || j < m) {
        long ai, bj;
        if (i < n && j < m && !ca[i] && !cb[j]) { i++; j++; continue; }
        ai = i; bj = j;
        while (i < n && ca[i]) i++;
        while (j < m && cb[j]) j++;
        if (nh && ai - h[nh - 1].ae <= 2 * ctx) {
            h[nh - 1].ae = i;
            h[nh - 1].be = j;
        }
        else {
            if (nh == caph) {
                Hunk* nhk;
                caph *= 2;
                nhk = (Hunk*)realloc(h, (size_t)caph * sizeof(Hunk));
                if (!nhk) goto oom;
                h = nhk;
            }
            h[nh].as = ai; h[nh].ae = i; h[nh].bs = bj; h[nh].be = j;
            nh++;
        }
    }
    if (nh == 0) { r = rk_str(c, "", 0); goto done; }

    bstr(&out, "--- "); bmem(&out, from, lfrom); bstr(&out, "\n");
    bstr(&out, "+++ "); bmem(&out, to, lto); bstr(&out, "\n");
    for (k = 0; k < nh; k++) {
        Hunk* x = &h[k];
        long before = ctx < x->as ? ctx : x->as;
        long after  = ctx < n - x->ae ? ctx : n - x->ae;
        x->as -= before; x->bs -= before;
        x->ae += after;  x->be += after;
        bstr(&out, "@@ -"); brange(&out, x->as, x->ae);
        bstr(&out, " +");   brange(&out, x->bs, x->be);
        bstr(&out, " @@\n");
        i = x->as; j = x->bs;
        while (i < x->ae || j < x->be) {
            if (i < x->ae && j < x->be && !ca[i] && !cb[j]) {
                bline(&out, ' ', &A[i]);
                i++; j++;
            }
            else {
                while (i < x->ae && ca[i]) { bline(&out, '-', &A[i]); i++; }
                while (j < x->be && cb[j]) { bline(&out, '+', &B[j]); j++; }
            }
        }
    }
    if (out.oom) goto oom;
    r = rk_str(c, out.buf, out.len);
    goto done;

oom:
    rk_die(c, "Text::Diff::Native: out of memory");
    r = 0;
done:
    free(A); free(B); free(all); free(ids); free(ca); free(cb); free(h); free(out.buf);
    return r;
}

static const RkSubDef subs[] = {
    {"diff-changes-native", diff_changes_native},
    {"unified-diff-native", unified_diff_native},
    {0, 0}
};
/* ABI 1 is all this file uses — construct, inspect, rk_die — so it asks for
   no more, and loads on any Raku++ that has an extension ABI at all. */
static const RkModule mod = { 1u, "Text::Diff::Native", subs };

RAKUPP_EXT_EXPORT const RkModule* rakupp_ext_init(unsigned host_abi) {
    return host_abi >= 1u ? &mod : 0;
}
