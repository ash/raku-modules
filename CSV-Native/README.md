# CSV::Native

CSV parsing and writing with a native fast path on **Raku++**, and pure Raku
everywhere else. No dependencies. The same program runs on both engines.

> Version 0.0.1. The interface below is implemented and tested on both
> engines; what it deliberately leaves out is under Scope.

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

## What it is

The XS pattern, for Raku++, as [JSON::Native](../JSON-Native) does it. The
distribution ships **C source**; the build step compiles it against Raku++'s
extension ABI at install time; the module uses the result if it is there. On
Rakudo — or on a Raku++ whose headers or compiler are missing — the same
specification runs as plain Raku from the module file. A failed native build
costs speed, never function.

The difference from JSON::Native is what the fallback is. There is no
`JSON::Fast` of CSV to stand on: the ecosystem's `Text::CSV` depends on a
slang, which depends on the compiler's grammar internals, so it neither loads
on any engine but Rakudo nor belongs as a dependency of a module meant to run
on two. So this module carries its own Raku implementation, and the two
implementations — C and Raku — are held to one specification by the test
suite, which on Raku++ runs every case through both and demands the same
rows, the same bytes and the same error message.

## The format

RFC 4180, read strictly and written minimally.

- **Fields are `Str`, always.** A CSV file carries no types; `"007"` stays
  `"007"`. Coerce what you know to be a number.
- A quoted field may hold the separator, line endings, and the quote itself
  written twice. Anything after a closing quote other than a separator or a
  line ending is an error, and so is a quote inside an unquoted field.
- LF, CRLF and a lone CR all end a record. Inside a quoted field they are
  content and kept exactly as written.
- A trailing line ending does not start an empty record; a blank line in the
  middle is one record with one empty field.
- Spaces are content. A leading UTF-8 byte-order mark is dropped.
- Records may have different lengths (`:strict` forbids it).

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
a `Hash`; a record shorter than the header simply lacks those keys, a record
longer than it is an error (a hash has nowhere to put a nameless field), and
a duplicate name in the header is an error.

## Writing

`to-csv(@rows, *%options)` returns a `Str`, one line per row, each ending in
`:eol`. A row is a list of cells or a hash; a cell is written as its `.Str`,
an undefined cell as an empty field.

| option | default | meaning |
|---|---|---|
| `:sep`, `:quote` | `,` `"` | as for reading |
| `:eol` | `"\n"` | `"\n"`, `"\r\n"` or `"\r"` |
| `:headers` | see below | the column names, written as the first line |
| `:always-quote` | `False` | quote every field |

A field is quoted when it contains the separator, the quote or a line
ending, and otherwise not; a quote inside it is doubled. Hash rows are
written in the order of `:headers` when given, else in the **sorted** key
order of the first row (Rakudo randomises hash order per process; sorted is
the one order both engines agree on), and the names become the first line
unless `:!headers` says not to. List rows get a header line only when
`:headers` names one.

## Backends

| `csv-backend` | when |
|---|---|
| `native` | Raku++ with the compiled extension |
| `raku` | Rakudo, or Raku++ without the extension |

`CSV_NATIVE_BACKEND=raku` in the environment forces the Raku implementation
on a Raku++ that has the extension — for measuring one against the other, or
for confirming in one run that a suspected native bug is not one. The raw
implementations are reachable as `CSV::Native::parse-raku` and
`CSV::Native::write-raku` with the same options `from-csv` and `to-csv` pass
on (the writer takes the resolved `:names` and `:header-line`); the test
suite uses them, and nothing else should need to.

## Measured

A generated corpus of the shapes real files have — plain fields, quoted
fields with separators and doubled quotes, a multi-line field now and then,
non-ASCII — best of three, measured 2026-09-02 on an arm64 Mac with Rakudo
v2026.08 and Raku++ 3.24.0:

| 100,000 rows, 8.5 MB | parse | parse `:headers` | write | write hashes |
|---|---:|---:|---:|---:|
| **Raku++ + CSV::Native (extension)** | **86 ms** | **133 ms** | **49 ms** | **86 ms** |
| Rakudo + CSV::Native (Raku) | 1,798 ms | 2,293 ms | 1,494 ms | 1,848 ms |
| Rakudo + `Text::CSV` 0.022 | 15,245 ms | | | |

| 10,000 rows, 813 KB | parse | parse `:headers` | write | write hashes |
|---|---:|---:|---:|---:|
| Raku++ + CSV::Native (extension) | 10 ms | 17 ms | 6 ms | 10 ms |
| Rakudo + CSV::Native (Raku) | 169 ms | 226 ms | 139 ms | 158 ms |
| Rakudo + `Text::CSV` 0.022 | 1,631 ms | | | |

The Raku implementation on **Raku++** is missing from both tables because
today it is the no-compiler fallback for correctness, not for size: Raku++'s
`Str.index` with a start position costs time proportional to that position,
so a scanner that advances with it — which is what the Raku parser is — is
quadratic there. Measured, one parse and one write each:

| rows | bytes | parse (Raku++, Raku) | write (Raku++, Raku) |
|---:|---:|---:|---:|
| 1,000 | 78 KB | 12.1 s | 34 ms |
| 2,000 | 159 KB | 48.3 s | 64 ms |
| 4,000 | 323 KB | 196 s | 133 ms |

Doubling the input quadruples the parse; the writer, which never asks for a
position, is linear. This is filed as an engine task, and the parser is
already linear in the number of `index` calls it makes (it memoises where
each needle next occurs), so the fix is entirely on the engine's side.

## Scope

Left out of 0.0.1 on purpose:

- **Streaming.** `from-csv` reads the whole text and returns the whole table.
  A lazy row iterator over a handle is the natural next feature and needs
  parser state on the C side that outlives one call; it is designed for and
  not built.
- **Loose quotes** (`5" pipe,x`), an escape character other than doubling,
  comment lines, `:skip-empty-rows`. `Text::CSV` has all of them; the RFC has
  none.
- **Typed fields.** An opt-in allomorph mode may come; a guessing parser will
  not.

## Requirements

Nothing, to work. For the fast path: Raku++, a C compiler, and Raku++'s
headers installed (`<prefix>/include/rakupp/rakupp_ext.h`, which
`cmake --install` places there). Set `RAKUPP_SRC` to a checkout's `include/`
directory to build against that instead. When none of that is present the
install still succeeds — the build step leaves a stub and the module runs the
Raku implementation.

## Compatibility

| engine | version | `t/01-parse.t` | `t/02-write.t` |
|---|---|---:|---:|
| Rakudo | v2026.08 | 73/73 | 55/55 |
| Raku++, extension | 3.24.0 | 139/139 | 93/93 |
| Raku++, `CSV_NATIVE_BACKEND=raku` | 3.24.0 | 73/73 | 55/55 |

The Raku++ counts are higher because every case is run through both
implementations there. Neither version is an established floor — no older
engine has been tried; the extension needs a Raku++ with extension ABI 2.

Two things worth knowing when a program moves between engines: CRLF is one
character in Raku (`"a\r\nb".chars` is 3, and `.index("\n")` does not find
it), which this module handles and your own string code may not; and Rakudo
applies the single-argument rule to `[[1,2]]` (it is `[1,2]`) where Raku++
today keeps it nested — write `[[1,2],]` for a one-row table on both.

## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.

---

Why the module is shaped this way, and what running it under two engines
turned up, is in [notes/CSV-Native.md](../notes/CSV-Native.md).
