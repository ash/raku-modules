# CSV::Native

**N.B.! Status of this module: WIP (work in progress).**

CSV parsing and writing with a native fast path on **Raku++**, and pure Raku
everywhere else. No dependencies. The same program runs on both engines.

> Version 0.1.0. The interface below is implemented and tested on both
> engines; what it leaves out is under Scope.

```raku
use CSV::Native;

my @rows = from-csv("a,b\n1,\"x,y\"\n");            # [["a","b"],["1","x,y"]]
my @recs = from-csv("data.csv".IO, :headers);        # [{a => "1", b => "2"}, ...]
my @recs = from-csv($text, :headers<id name>, :sep<;>);

say to-csv([[1, "two", "3,4"]]);                     # 1,two,"3,4"
say to-csv(@recs, :headers<name id>);                # a header line, then rows

say csv-backend();                                   # 'native' or 'raku'

# a file too big to hold: one window at a time, bounded memory
csv-each("huge.csv".IO, :headers, on-chunk => -> @recs { ... });
for csv-stream("huge.csv".IO, :headers) -> %rec { ... }
```

```bash
raku   -Ilib examples/roundtrip.raku
rakupp -Ilib examples/roundtrip.raku
```

## Walkthrough

`t/mock-customers.csv` ships with the distribution: 1,000 invented customer
records with quoted company names, non-ASCII cities, a few multi-line notes
and CRLF line endings. `examples/customers.raku` runs every flow below on
both engines and prints what is shown.

**Rows.** Without `:headers`, every line is a list of `Str`, the header
line included:

```raku
use CSV::Native;

my @rows = from-csv("t/mock-customers.csv".IO);
say @rows.elems;     # 1001
say @rows[0];        # [Index Customer Id First Name Last Name Company City …]
say @rows[1][2..5];  # (Ada Easley Wonka Labs Sevilla)
```

**Records.** With `:headers`, the first line names the columns and each
record is a hash. Quoted fields arrive decoded:

```raku
my @customers = from-csv("t/mock-customers.csv".IO, :headers);
say @customers.elems;                       # 1000
say @customers[0]<Company City>;            # (Wonka Labs Sevilla)
say @customers[0]{'First Name'};            # Ada — a key with a space is a string
say @customers[16]<Notes>;                  # said "call me", then left
say @customers.grep(*<Company>.contains(',')).elems;   # 302
```

**Which implementation answered.** `native` on Raku++ with the extension
built, `raku` everywhere else; the results are the same either way:

```raku
say csv-backend();   # native
```

**Writing.** `to-csv` returns text, so a file is one `spurt` away. A slice
of the rows is a valid file, header line included:

```raku
"three.csv".IO.spurt(to-csv(@rows[^3]));
print "three.csv".IO.slurp;
# Index,Customer Id,First Name,Last Name,Company,City,Country,Phone,Email,…
# 1,40e938d90c5a9fc,Ada,Easley,Wonka Labs,Sevilla,Spain,202-646-1155,…
# 2,14d96cb14241a7a,Rasmus,Stroustrup,Sirius & Wonka,Paris,France,…
```

Records write in sorted key order unless `:headers` picks the columns. Names
with spaces need a real list — `<Index First Name>` would be three words:

```raku
my @vips = @customers.grep(*<Notes> eq 'VIP');
"vips.csv".IO.spurt(to-csv(@vips, :headers('Index', 'First Name', 'Company')));
print "vips.csv".IO.slurp;
# Index,First Name,Company
# 97,Frances,"Pied, Tyrell and Acme"
# 194,Audrey,Tyrell & Massive
# …
say from-csv("vips.csv".IO, :headers).elems;   # 10
```

**Round trip.** What `to-csv` writes, `from-csv` reads back as the same
data, and a minimally quoted file comes back byte for byte:

```raku
say to-csv(@rows) eq "t/mock-customers.csv".IO.slurp;   # True
```

(In LF form: reading a file through `IO::Path` or `IO::Handle` goes through
the engine's text decoding, which turns CRLF into LF on both engines. The
parser keeps whatever line endings it is given — a `Str` with CRLF in it
keeps them, inside quoted fields too.)

## What it is

The XS pattern, as [JSON::Native](../JSON-Native) does it: the distribution
ships C source, the build step compiles it against Raku++'s extension ABI,
and the module uses the result if it is there. On Rakudo, or on a Raku++
without the headers or a compiler, the same specification runs as plain Raku
from the module file. A failed native build costs speed, never function.

Unlike JSON::Native there is no ecosystem module to fall back on. The
ecosystem's `Text::CSV` depends on a slang, which depends on Rakudo's
grammar internals, so it neither loads on another engine nor belongs as a
dependency here. So this module carries its own Raku implementation, and the
test suite holds the two implementations to one specification: on Raku++
every case runs through both and must give the same rows, the same bytes and
the same error message.

## The format

RFC 4180, read strictly and written minimally.

- **Fields are `Str`, always.** A CSV file carries no types; `"007"` stays
  `"007"`.
- A quoted field may hold the separator, line endings, and the quote itself
  written twice. Anything else after a closing quote is an error, and so is
  a quote inside an unquoted field.
- LF, CRLF and a lone CR all end a record. Inside a quoted field they are
  content, kept as written.
- A trailing line ending does not add an empty record; a blank line in the
  middle is one record with one empty field.
- Spaces are content. A leading UTF-8 byte-order mark is dropped.
- Records may differ in length unless `:strict` says otherwise.

Every error names its line:

    CSV::Native: unterminated quoted field starting at line 12
    CSV::Native: a quote inside an unquoted field at line 3
    CSV::Native: text after a closing quote at line 3
    CSV::Native: line 7 has 5 fields but the header has 4
    CSV::Native: line 7 has 3 fields, expected 4        # under :strict
    CSV::Native: duplicate header 'id'

## Reading

`from-csv($source, *%options)` takes a `Str`, an `IO::Path` or an
`IO::Handle` and returns an `Array` of records.

| option | default | meaning |
|---|---|---|
| `:sep` | `,` | the separator; any non-empty string (`;`, `"\t"`, `::`, `→`) |
| `:quote` | `"` | the quote; exactly one character |
| `:headers` | off | `True`: the first record names the columns; a list: these names do, and every record is data |
| `:strict` | `False` | every record must have as many fields as the first (or as the header) |

Without `:headers` each record is an `Array` of `Str`. With it each record is
a `Hash`: a record shorter than the header lacks those keys, a longer one is
an error, and a duplicate header name is an error.

## Writing

`to-csv(@rows, *%options)` returns a `Str`, one line per row. A row is a
list of cells or a hash; a cell is written as its `.Str`, an undefined cell
as an empty field.

| option | default | meaning |
|---|---|---|
| `:sep`, `:quote` | `,` `"` | as for reading |
| `:eol` | `"\n"` | `"\n"`, `"\r\n"` or `"\r"` |
| `:headers` | see below | the column names, written as the first line |
| `:always-quote` | `False` | quote every field |

A field is quoted when it contains the separator, the quote or a line
ending; a quote inside it is doubled. Hash rows follow `:headers` when
given, else the sorted keys of the first row (the one order both engines
agree on), and get a header line unless `:!headers`. List rows get a header
line only when `:headers` names one.

## Backends

| `csv-backend` | when |
|---|---|
| `native` | Raku++ with the compiled extension |
| `raku` | Rakudo, or Raku++ without the extension |

`CSV_NATIVE_BACKEND=raku` in the environment forces the Raku implementation
on a Raku++ that has the extension, to compare the two or to rule the native
path out of a suspected bug. The raw implementations are reachable as
`CSV::Native::parse-raku` and `CSV::Native::write-raku`; the test suite uses
them.

## Measured

Generated corpora with the shapes real files have (quoted fields with
separators and doubled quotes, multi-line fields, non-ASCII), best of three,
2026-09-02, arm64 Mac, Rakudo v2026.08 and Raku++ 3.24.0. The corpora, the
generator and the scripts are in the repository under
[benchmarks/csv](https://github.com/ash/raku-modules/tree/main/benchmarks/csv),
outside the distribution; its README says how to re-run every number.

| 100,000 rows, 8.5 MB | parse | parse `:headers` | write | write hashes |
|---|---:|---:|---:|---:|
| **Raku++, extension** | **107 ms** | **150 ms** | **48 ms** | **137 ms** |
| Raku++, Raku implementation | 1,075 ms | 1,778 ms | 3,551 ms | 3,984 ms |
| Rakudo, Raku implementation | 1,617 ms | 3,566 ms | 1,475 ms | 2,097 ms |
| Rakudo, `Text::CSV` 0.022 | 15,245 ms | | | |

| 10,000 rows, 813 KB | parse | parse `:headers` | write | write hashes |
|---|---:|---:|---:|---:|
| **Raku++, extension** | **6 ms** | **10 ms** | **4 ms** | **8 ms** |
| Raku++, Raku implementation | 98 ms | 151 ms | 308 ms | 371 ms |
| Rakudo, Raku implementation | 130 ms | 171 ms | 143 ms | 174 ms |
| Rakudo, `Text::CSV` 0.022 | 1,631 ms | | | |

The Raku implementation is built on `split` and `lines`, never on scanning
with `index`, because on Raku++ an `index` costs the whole string on every
call; the first version scanned that way and took 12 s for a thousand rows
there. Both implementations are linear in the input.

## Streaming

`from-csv` reads the whole text and returns the whole table, which is the
right shape for a file you can hold and the wrong one for a file you cannot.
The ceiling is not the disk, it is the multiple between a file and its parsed
form:

| peak memory ÷ file size | rows | `:headers` |
|---|---:|---:|
| Raku++, extension | ~12x | ~15–20x |
| Rakudo | ~24x | ~30x |

The multiple depends on the shape of a row — many narrow columns cost more per
byte of file than few wide ones — so treat these as the order of the thing and
not a constant. So a 2 GB export read as records wants tens of GB on Raku++
and half again as much on Rakudo, and a 10 GB one is out of reach on any
machine you have.

`csv-each` reads a window at a time and parses it on its own. What is alive at
once is one window of text and one window of records, whatever the file's
size — the file's size stops being the question.

```raku
my %by-country;
csv-each("huge.csv".IO, :headers, on-chunk => -> @recs {
    %by-country{.<Country>}++ for @recs;     # totals accumulate, records do not
});
```

`csv-stream` is the same reading as a lazy sequence of records, for when a
loop over records reads better than a loop over windows. On Raku++ 5.8.0 it is
*not* bounded — a `Seq` there retains every record it yields ([#263][i263]), so
use `csv-each` for a file you cannot hold:

```raku
for csv-stream("huge.csv".IO, :headers) -> %rec { ... }
my $first = csv-stream("huge.csv".IO, :headers).first(*<Notes> eq 'VIP');
```

Both take `from-csv`'s options — `:sep`, `:quote`, `:headers`, `:strict` — and
two of their own:

| option | default | meaning |
|---|---|---|
| `:bytes` | 64Ki | bytes read at a time: the window |
| `:workers` | 1 | windows parsed in parallel (Raku++) |

The records are the ones `from-csv` returns for the same source, and a
malformed file fails with the same message naming the same line. `t/04-stream.t`
holds both to that for every window size from one byte up, which is where the
reader's real bugs live: a multi-byte character split across two reads, a CRLF
split down the middle, a record longer than the window, a quoted field
spanning windows. The default window finds none of them.

`:strict` measures every record against the first record of the **file**, not
of the window it falls in, and `:headers` names the columns from the first
window even when the header line itself spans lines — neither is something a
window can work out for itself, so both are passed down.

A source may be a `Str`, an `IO::Path` or an `IO::Handle`. A handle the caller
opened stays the caller's; only a path the reader opened is closed by it, and
`csv-each` closes it on every way out, including through an exception the
consumer itself raised. A `csv-stream` sequence abandoned part way — `.first`,
or `last` in a loop over it — cannot know it was abandoned, so its file waits
for the collector; `csv-each` is the one to reach for when that matters.

One input defeats the window: an unterminated quoted field near the start of a
huge file. Everything after it is inside a quoted field as far as any reader
can tell, so no record boundary is ever found, the leftover grows to the whole
file and each window rescans it from the beginning. The error, when it comes,
is the right error at the right line — but a file malformed that way is read
quadratically rather than linearly.

### Measured

arm64 Mac, Raku++ 5.8.0. `t/mock-customers.csv` repeated to 851 MB —
5,550,000 records of twelve columns, quoted fields and multi-line notes among
them — every record read with `:headers` and one field of it read:

| 851 MB, 5.55M records | time | peak memory |
|---|---:|---:|
| `from-csv`, whole table | 16.3 s | **12.33 GiB** |
| `csv-each` | **12.4 s** | **31 MiB** |
| `csv-stream` | 18.1 s | 8.79 GiB |

**Memory is flat in the file's size** — 31 MiB on 85 MB of CSV and 31 MiB on
851 MB — and that is the point: four hundred times less memory than the whole
table, and quicker as well, because nothing is kept that has to be allocated,
grown and collected.

#### The window and the workers pull against each other

With a cheap consumer, so that the figures are the reader's and not the
caller's:

| `:bytes` | `:workers(1)` | `:workers(2)` | `:workers(4)` |
|---|---:|---:|---:|
| 64Ki (the default) | **9.9 s** / 33 MiB | 9.3 s / 52 MiB | 10.2 s / 57 MiB |
| 1Mi | 11.2 s / 147 MiB | 9.1 s / 194 MiB | 9.3 s / 245 MiB |
| 4Mi | 11.7 s / 450 MiB | 8.8 s / 573 MiB | **8.2 s** / 736 MiB |

A small window is quickest on one thread — its text and records stay in cache,
and every pass over them is cheaper — but it gives each worker too little to
do to pay for handing the work over. A large window is the other way round.
The default is chosen for the single-threaded case and for memory, which is
what a streaming reader is for; **if you raise `:workers`, raise `:bytes` with
it**, or the extra threads will not earn their keep. The best time here, 4Mi
across four workers, costs twenty-two times the memory of the default to save
a sixth of the time.

Note also that workers divide the *parsing* only. The consumer's own work runs
on one thread, and in the first table above it is most of the cost — which is
why `:workers` is absent from it: at two and four workers that read takes
13.0 s and 12.6 s, no better than one.

### Two engine findings the reader is built around

Both were measured on Raku++ 5.8.0 and both change what a streaming reader can
be made of:

- **Text-mode handle reads are O(the file)** ([rakupp #262][i262]). Reading an
  851 MB file in windows and discarding every one peaks at 29.6 GB, whatever
  the window size — about 35 bytes per character read, held for the lifetime of
  the handle; `.read` on the same loop peaks at 83 MB. `get` has the same shape
  at about 6 B/char. So the reader is binary and decodes each window itself.
  (On Rakudo, `get` is flat and `readchars` plateaus.) Decoding a window is
  only safe where the encoding agrees, and a record terminator is ASCII — so
  cutting at one can never split a codepoint,
  and the leftover is carried as bytes. On Raku++ the read, the decode, the
  CRLF normalisation and the cut are one C pass; doing them in Raku cost more
  than the parsing they feed, which left `:workers` nothing to divide.
- **A `Seq` retains every value it yields**, for as long as the `Seq` is alive
  ([rakupp #263][i263]) — about 280 bytes a value. It is the `Seq`, not the
  consumer: `gather`/`take`, `Seq.new`, and `.map` all do it, and so do both
  `for` and draining `.iterator` by hand, while the same `Iterator` drained
  directly with no `Seq` around it is flat (13 MiB against 1082 MiB for four
  million one-key hashes). That is why `csv-stream` is a hand-rolled iterator
  rather than a `gather`; but `csv-stream` still hands the records back as a
  `Seq`, so on Raku++ 5.8.0 it is bounded only by the file, and **for a file
  you cannot hold, use `csv-each` there**. `csv-stream` is flat on Rakudo
  (466 MB at both 85 MB and 851 MB).

[i262]: https://github.com/ash/rakupp/issues/262
[i263]: https://github.com/ash/rakupp/issues/263

CRLF: a file read whole goes through the engine's text decoding, which turns
CRLF into LF — inside quoted fields too — while a byte read does not. The
reader normalises CRLF to LF to match, and leaves a lone CR alone, which is
also what the engine does. That is why a streamed read of a CRLF file agrees
with `from-csv` line ending for line ending.

## Scope

Left out of 0.0.1 on purpose:

- **Loose quotes** (`5" pipe,x`), an escape character other than doubling,
  comment lines, `:skip-empty-rows`.
- **Typed fields.** An opt-in allomorph mode may come; a guessing parser will
  not.

## Requirements

Nothing, to work. For the fast path: Raku++, a C compiler, and Raku++'s
headers (`<prefix>/include/rakupp/rakupp_ext.h`, installed by
`cmake --install`; or `RAKUPP_SRC` pointing at a checkout's `include/`).
Without them the install still succeeds and the module runs its Raku
implementation.

## Compatibility

| engine | version | `t/01-parse.t` | `t/02-write.t` | `t/03-mock-file.t` | `t/04-stream.t` |
|---|---|---:|---:|---:|---:|
| Rakudo | v2026.05 | 73/73 | 55/55 | 17/17 | 86/86 |
| Raku++, extension | 5.8.0 | 139/139 | 93/93 | 19/19 | 86/86 |
| Raku++, `CSV_NATIVE_BACKEND=raku` | 5.8.0 | 73/73 | 55/55 | 17/17 | 86/86 |

The Raku++ counts are higher because every case runs through both
implementations there. Neither version is an established floor; the
extension needs a Raku++ with extension ABI 2 for parsing and writing, and
ABI 3 for the one-pass streaming reader, which hands raw bytes across the
boundary — ABI 3's addition. Against an ABI-2 header the reader compiles out
and streaming reads through Raku; parsing keeps its fast path either way.

Two engine differences worth knowing: CRLF is one character in Raku
(`"a\r\nb".chars` is 3, and `.index("\n")` does not find it); and Rakudo
applies the single-argument rule to `[[1,2]]` (it is `[1,2]`) where Raku++
keeps it nested — write `[[1,2],]` for a one-row table on both.

## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.

---

Why the module is shaped this way, and what running it under two engines
turned up, is in [notes/CSV-Native.md](https://github.com/ash/raku-modules/blob/main/notes/CSV-Native.md).
