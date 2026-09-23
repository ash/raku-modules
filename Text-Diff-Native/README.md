# Text::Diff::Native

Line diffs and unified diffs with a native fast path on **Raku++**, and pure
Raku everywhere else. Myers' O(ND) algorithm, always a shortest diff. No
dependencies. The same program runs on both engines.

> Version 0.0.1. The interface below is implemented and tested on both
> engines; what it leaves out is under Scope.

```raku
use Text::Diff::Native;

print unified-diff("a\nb\nc\n", "a\nc\nd\n");
# --- a
# +++ b
# @@ -1,3 +1,3 @@
#  a
# -b
#  c
# +d

print unified-diff('old.txt'.IO, 'new.txt'.IO, :context(1));

for diff(<a b c d>, <a c d e>) {
    say .key, .value;          #  a / -b /  c /  d / +e
}

say diff-backend();            # 'native' or 'raku'
```

```bash
raku   -Ilib examples/udiff.raku old.txt new.txt
rakupp -Ilib examples/udiff.raku old.txt new.txt
```

## The interface

| routine | returns |
|---|---|
| `unified-diff($old, $new, :$context = 3, :$from, :$to)` | the unified diff as a `Str`, `''` when the two are the same |
| `diff(@old, @new)` | the edit script, one `Pair` per element |
| `diff-backend()` | `'native'` or `'raku'` |

**`unified-diff`** takes two texts, each a `Str` or an `IO::Path`, and writes
what `diff -u` writes: `---`/`+++` header lines, then `@@ -l,n +l,n @@`
hunks with `:context` unchanged lines around each change. Two changes share
a hunk when no more than twice the context lies between them. A path is read
as UTF-8 with its bytes untouched and names its side in the header; `:from`
and `:to` name the sides of anything else (`a` and `b` by default), or
override a path.

**`diff`** takes any two lists and compares their elements as strings. Each
`Pair` in the result is `' ' => $element` (in both), `'-' => $element` (only
in the old list) or `'+' => $element` (only in the new one); within a
change, deletions come first. The keys are the unified format's own markers,
so `print .key ~ .value for diff(@a, @b)` prints a context-free diff of
lines. A word or character diff is `diff` of `.words` or `.comb`.

## Lines

A line ends with `"\n"` or `"\r\n"`, and the ending is part of the line: a
CRLF line and an LF line with the same text are different lines, as they are
to `diff`. A lone `"\r"` is content, not an ending. A last line with no
ending differs from the same line with one, and the hunk marks it with
`\ No newline at end of file`.

Text is compared as Raku strings, and a Raku string is in Unicode NFC. A
file written in another normal form, such as the decomposed `e` + `◌́` that
some macOS tools produce, is diffed as its NFC equivalent. The Raku
implementation also writes that equivalent, so its diff of such a file does
not apply to the file's bytes. The native path works on bytes and keeps
them. NFC is what nearly all text is in already.

## The algorithm

Eugene W. Myers, *An O(ND) Difference Algorithm and Its Variations*,
Algorithmica 1 (1986): the linear-space version, which finds the middle of a
shortest edit path by searching forward from the start and backward from
the end at once, then recurses on the two halves. Before the search, the
common head and tail of each piece are trimmed, and a line that the other
side does not have at all is set aside as a change, since it is one in every
shortest diff.

**The diff is always a shortest one**: no diff with fewer deleted and
inserted lines exists. Where several shortest ones exist, a run of
deletions or insertions is slid down as far as equal lines allow, the
conventional choice. Against GNU diff 3.10 on 2,000 random pairs of files,
every diff applied with `patch`, every one was as short as `diff --minimal`'s,
and 79% were byte for byte what `diff -u` prints; the rest are other choices
among equally short diffs.

The cost is O((N+M)·D) for N and M lines and D changes: linear for files
that differ in a few places, which is most of what gets diffed.

## Two implementations

On Raku++ with the extension built, the whole of `unified-diff`, from
splitting the lines to writing the hunks, runs in C (`src/textdiff.c`), and
so does the search inside `diff`. Everywhere else the same steps run in Raku.
They are two spellings of one procedure, and they give the same answer
**change for change**, not merely an equally short diff (for text in NFC;
see Lines). The test suite runs
every case, and 600 random ones, through both and compares them.
`TEXT_DIFF_NATIVE_BACKEND=raku` forces the Raku implementation.

## Measured

`unified-diff` on two versions of a source-like file with 1% of its lines
edited. The files, the generator and the timing script are in
[benchmarks/diff](../benchmarks/diff); best of three runs, on an Apple
Silicon Mac, 2026-09-23.

| lines | Raku++ native | Rakudo, Raku | Raku++, Raku | GNU `diff -u` |
|---:|---:|---:|---:|---:|
| 1,000 | < 1 ms | 11 ms | 11 ms | — |
| 10,000 | 4 ms | 128 ms | 166 ms | — |
| 100,000 | 47 ms | 1.7 s | 2.7 s | 17 ms |

For comparison, the ecosystem's `Text::Diff` (zef:rbt, 1.0.5), which is
built on `Algorithm::Diff`, takes 0.2 s for the 1,000-line pair and 18 s
for the 10,000-line pair under Rakudo.

The worst case is two unrelated files with few distinct lines, where D is
close to N: the native path diffs two 20,000-line ones in half a second, and
Rakudo's Raku path takes 2.1 s for 2,000 lines and 16 s for 6,000.

## Examples

- `examples/udiff.raku` — a small `diff -u`: the diff of two files, and
  diff's exit codes (1 when they differ, 0 when they do not).
- `examples/words.raku` — a word diff printed inline, `[-old-]{+new+}`, the
  way `git diff --word-diff` shows one: `diff` on two lists of words.

## Scope

Left out of 0.0.1, deliberately:

- **A cost cap.** GNU diff gives up on a perfect answer when the search
  grows too expensive and settles for a longer diff; this module always
  finds a shortest one, which is quadratic for two unrelated files (see
  Measured). A `:fast` option in that spirit is the likely next feature.
- **Applying a diff**, i.e. `patch`. The other half of the job, and a
  module of its own size.
- **Ignoring whitespace or case**, and the other GNU context formats (`-c`,
  normal, side by side). Each is small, and each waits for a request.
- **Binary files, and text that is not NFC byte for byte** (see Lines).
  Paths are read as UTF-8 text. A diff of bytes would need a `Blob` result,
  since a Rakudo `Str` cannot hold text that is not NFC.

## Compatibility

| engine | version | assertions in `t/` |
|---|---|---:|
| Rakudo | v2026.08 | 643 |
| Raku++ (native) | 4.0.1-134-gf8296182 | 1,265 |

Raku++ runs more assertions than Rakudo: every case also goes through the
Raku implementation, which must give the extension's answer exactly. These
are the versions tried, not established floors: no older engine has been
tried. The extension asks for ABI 1 of Raku++'s extension interface, the
first there was.

## Author

Andrew Shitov (`zef:ash`)

## Licence

Artistic-2.0.

---

The design log — why it is shaped this way, and what the two engines turned
up — is in [notes/Text-Diff-Native.md](../notes/Text-Diff-Native.md).
