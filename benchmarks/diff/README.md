# Text::Diff::Native benchmarks

The data behind the "Measured" section and the GNU comparison in
[Text::Diff::Native's README](../../Text-Diff-Native/README.md), so the
numbers there can be re-run rather than taken on trust. Everything here is
synthetic: `gen.raku` draws every line from a seeded generator of its own, so
the files are reproducible byte for byte on either engine. They live outside
the distribution on purpose: an install from the ecosystem carries none of
this.

| files | lines | used for |
|---|---:|---|
| `old-1k.txt`, `new-1k.txt` | 1,000 | the Measured table |
| `old-10k.txt`, `new-10k.txt` | 10,000 | the Measured table |
| `old-100k.txt`, `new-100k.txt` | 100,000 | the Measured table, and GNU's time |

The text is source-like: indented statements drawn from a few dozen words,
with blank lines and closing braces repeating throughout. Each new file is its
old one with 1% of the lines edited: a third replaced, a third deleted and a
third inserted.

## Reproducing

Run from the distribution directory, so that `-Ilib` finds the module and, on
Raku++, the compiled extension in `resources/libraries/` is found next to it.
Build the extension first with the Build hook, as CI does: `rakupp -I. -MBuild
-e 'exit(Build.new.build($*CWD.Str) ?? 0 !! 1)'`.

```sh
cd Text-Diff-Native
rakupp -Ilib ../benchmarks/diff/bench.raku
raku   -Ilib ../benchmarks/diff/bench.raku
TEXT_DIFF_NATIVE_BACKEND=raku rakupp -Ilib ../benchmarks/diff/bench.raku
time diff -u ../benchmarks/diff/old-100k.txt ../benchmarks/diff/new-100k.txt > /dev/null
```

`raku` here means Rakudo. On a machine where `raku` is a link to `rakupp`,
call Rakudo by its own name, `rakudo`.

## Against GNU diff

`against-gnu.raku` writes random pairs of small files, with few distinct
lines so that there are many equally short diffs to choose between, and
diffs each pair with this module and with GNU diff. It fails unless, for
every pair, `patch` turns the old file into the new one with our diff, and
our diff deletes and inserts exactly as many lines as `diff --minimal`'s. It
also counts how often the two outputs are byte for byte the same, which is
information, not a requirement.

```sh
cd Text-Diff-Native
raku   -Ilib ../benchmarks/diff/against-gnu.raku 1000 1
rakupp -Ilib ../benchmarks/diff/against-gnu.raku 1000 2
```

The arguments are the number of cases and the seed. It needs GNU diff (3.10
was used) and `patch` on the `PATH`.

## Against Text::Diff

`bench-textdiff.raku` times the ecosystem's `Text::Diff` on the same pairs.
It is not a dependency of anything here, so install it wherever you like and
point `-I` at it; the script's header shows how.

`gen.raku` rewrites the corpus: `raku gen.raku` in this directory.
