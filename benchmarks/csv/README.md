# CSV::Native benchmarks

The data behind the "Measured" section of
[CSV::Native's README](../../CSV-Native/README.md), so the numbers there can
be re-run rather than taken on trust. Everything here is synthetic: `gen.raku`
computes every value from the row number, so the files are reproducible byte
for byte and contain nobody's data. They live outside the distribution on
purpose — an install from the ecosystem carries none of this.

| file | rows | bytes | used for |
|---|---:|---:|---|
| `corpus-100k.csv` | 100,000 | 8,512,124 | the main table |
| `corpus-10k.csv` | 10,000 | 813,472 | the second table |
| `corpus-1k.csv`, `corpus-2k.csv`, `corpus-4k.csv` | 1,000 / 2,000 / 4,000 | 77,603 / 159,356 / 322,895 | a size ladder, to check that a backend is linear |

Rows have eight columns (`id,name,email,city,amount,note,tags,active`); every
seventh note is quoted with doubled quotes inside, every eleventh holds a line
break, every third `tags` field is quoted for its commas, and the cities are
partly non-ASCII. Line endings are LF.

## Reproducing

Run from the distribution directory, so that `-Ilib` finds the module and, on
Raku++, the compiled extension in `resources/libraries/` is found next to it
(build it first with the Build hook, as CI does: `rakupp -I. -MBuild -e
'exit(Build.new.build($*CWD.Str) ?? 0 !! 1)'`).

```sh
cd CSV-Native

# the two tables: parse, parse with :headers, write, write from hashes —
# best of three, in milliseconds
rakupp -Ilib ../benchmarks/csv/bench.raku ../benchmarks/csv/corpus-100k.csv
raku   -Ilib ../benchmarks/csv/bench.raku ../benchmarks/csv/corpus-100k.csv
rakupp -Ilib ../benchmarks/csv/bench.raku ../benchmarks/csv/corpus-10k.csv
raku   -Ilib ../benchmarks/csv/bench.raku ../benchmarks/csv/corpus-10k.csv

# the Raku implementation forced on Raku++, on the ladder — one parse and one
# write each, to see that the time grows with the input and no faster
for n in 1k 2k 4k; do
    CSV_NATIVE_BACKEND=raku rakupp -Ilib ../benchmarks/csv/ladder.raku ../benchmarks/csv/corpus-$n.csv
done

# the Text::CSV column, on Rakudo, with Text::CSV installed
raku ../benchmarks/csv/bench-textcsv.raku ../benchmarks/csv/corpus-100k.csv
```

To make a corpus of another size, `raku gen.raku N` writes `corpus.csv` with
N rows into the current directory.

`bench.raku` prints one line per run — engine, backend, row count and the
four timings — so a table is a matter of running it under each engine.
