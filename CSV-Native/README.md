# CSV::Native

CSV parsing and writing with a native fast path on **Raku++**, and pure Raku
everywhere else. No dependencies. The same program runs on both engines.

> Version 0.0.1. The interface below is implemented and tested on both
> engines; what it leaves out is under Scope.

```raku
use CSV::Native;

my @rows = from-csv("a,b\n1,\"x,y\"\n");            # [["a","b"],["1","x,y"]]
my @recs = from-csv("data.csv".IO, :headers);        # [{a => "1", b => "2"}, ...]
my @recs = from-csv($text, :headers<id name>, :sep<;>);

say to-csv([[1, "two", "3,4"]]);                     # 1,two,"3,4"
say to-csv(@recs, :headers<name id>);                # a header line, then rows

say csv-backend();                                   # 'native' or 'raku'
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

## Scope

Left out of 0.0.1 on purpose:

- **Streaming.** `from-csv` reads the whole text and returns the whole table.
  A lazy row iterator over a handle is the natural next feature.
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

| engine | version | `t/01-parse.t` | `t/02-write.t` | `t/03-mock-file.t` |
|---|---|---:|---:|---:|
| Rakudo | v2026.08 | 73/73 | 55/55 | 17/17 |
| Raku++, extension | 3.24.0 | 139/139 | 93/93 | 19/19 |
| Raku++, `CSV_NATIVE_BACKEND=raku` | 3.24.0 | 73/73 | 55/55 | 17/17 |

The Raku++ counts are higher because every case runs through both
implementations there. Neither version is an established floor; the
extension needs a Raku++ with extension ABI 2.

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
turned up, is in [notes/CSV-Native.md](../notes/CSV-Native.md).
