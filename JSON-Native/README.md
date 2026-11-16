# JSON::Native

JSON::Native — read and write JSON from Raku, on whichever engine runs the
program, as fast as that engine allows.

## Version

**0.3.0** — `json-each` and `json-stream` read JSON Lines a window at a time,
in bounded memory. `from-json` reads an `IO::Path` or `IO::Handle` instead of
stringifying it (0.2.0).

The interface below is implemented and tested on Rakudo, Raku++ and mutsu.

## Synopsis

```raku
use JSON::Native;

my $data = from-json('{"name": "Raku", "versions": [6, 6.5], "ok": true}');
say $data<versions>[1].WHAT;     # (Rat) — Raku numerics, not doubles

say to-json($data);              # pretty-printed
say to-json($data, :!pretty);    # one line
say to-json($data, :sorted-keys);

say json-backend;                # which path parses on this engine

my $conf = from-json('config.json'.IO);   # a path is read, not stringified

# JSON Lines, a window at a time: memory set by the window, not the file
json-each('events.jsonl'.IO, on-chunk => -> @events {
    .<status>.say for @events;
});
```

## Description

JSON::Native converts between JSON text and Raku data. 

- `from-json` turns a
JSON document into Raku values. Integers are converted into `Int`, decimals into exact
`Rat`, exponent forms into `Num`, objects and arrays into `Hash` and `Array`;
- `to-json` writes Raku data back as JSON, pretty-printed or on one line.

It runs on any Raku engine, and on each it takes the fastest path that engine
offers, so the same program is portable and fast without changing a line:

- on **Raku++**, the engine's own built-in JSON codec answers, and a Raku++
  recent enough answers `use JSON::Native` itself — **the module does not even
  need to be installed there**;
- on **Rakudo** it parses with the JSON reader Rakudo carries internally and
  writes with a writer of its own built on `nqp::` ops;
- on **mutsu** it uses the JSON codec mutsu ships with;
- anywhere else it runs as plain Raku.


## Installation

### Raku++

```sh
rakupp install JSON::Native
```

Under Raku++ 5.4.0 and newer, there is no need to install the module, actually. The engine answers to `use JSON::Native` itself. It steps aside only for a newer module version than the one it implements.

### Rakudo or Raku++

```sh
zef install JSON::Native
```

### mutsu

```sh
mzef install JSON::Native
```

## Functions

### from-json

```raku
from-json(Str() $text,     :$immutable, :$allow-jsonc)
from-json(IO::Path $file,  :$immutable, :$allow-jsonc)   # read, not stringified
from-json(IO::Handle $fh,  :$immutable, :$allow-jsonc)   # left open for its owner
```

Parses one JSON document and returns its value. A path or a handle is read —
`from-json($file.IO)` parses the file rather than its name — which is what
CSV::Native's `from-csv` takes too. Anything else still coerces through
`Str()`, so `from-json(42)` is `42` and `from-json(Mu)` is a type-check
failure, unchanged.

| JSON | Raku |
|---|---|
| integer (`17`, `-3`, `123456789012345678901234567890`) | `Int`, arbitrary precision |
| decimal (`2.5`, `0.1`) | `Rat`, so `from-json('[0.1,0.2]').sum == 0.3` |
| exponent form (`1e3`, `2.5E-4`) | `Num` |
| `true`, `false` | `Bool` |
| `null` | `Any` |
| object, array | `Hash`, `Array` — or `Map`, `List` under `:immutable` |

`:allow-jsonc` accepts `//` and `/* */` comments. Malformed input dies;
content after the document raises `X::JSON::Native::AdditionalContent`,
whose `parsed`, `parsed-length` and `rest-position` say what was read and
where the rest begins.

### to-json

```raku
to-json($value, :$pretty = True, :$spacing = 2, :$sorted-keys,
        :$enums-as-value, :$level = 0)
```

Writes a value as JSON text. `:!pretty` writes one line; `:spacing` sets the
indent; `:sorted-keys` sorts object keys (or pass it a sort key or
comparator, as `.sort` takes); `:enums-as-value` writes an enum as its value
rather than its name. Strings are escaped as `\n`, `\t`, `\r`, `\"`, `\\` and
`\u0008`-style escapes for other controls, astral characters as
surrogate pairs; NaN and Inf are `null` unless `$*JSON_NAN_INF_SUPPORT` is
set. Date, Instant, Version, Seq, Pair, sets and allomorphs have their own
renderings; a value that has none dies.

### json-backend

```raku
json-backend(:$write)
```

Names the path that parses on this engine — `engine`, `rakudo`, `json-fast`
or `raku` — or with `:write`, the one that writes. It is there for
diagnostics; nothing else depends on it.

### Import options

`use JSON::Native <immutable !pretty sorted-keys enums-as-value>` changes the
defaults of the subs it hands out (`!` turns an option off); an adverb at the
call still wins.

## Streaming JSON Lines

`from-json` has to hold a whole document, because a JSON document is one
value. [JSON Lines](https://jsonlines.org) — one document per line — is the
shape that *can* be read a piece at a time, and `json-each` reads it a window
at a time, so memory is set by the window rather than by the file:

```raku
# a file too big to hold: one window at a time, bounded memory
json-each("events.jsonl".IO, on-chunk => -> @events {
    for @events -> %e { %count{%e<status>}++ }
});

# or as a lazy sequence of values
for json-stream("events.jsonl".IO) -> %e { ... }
my $first = json-stream("events.jsonl".IO).first(*<status> == 500);
```

Both take a `Str`, an `IO::Path` or an `IO::Handle`, pass `:immutable` and
`:allow-jsonc` through to the parser, and add two options of their own:

| option | default | meaning |
|---|---|---|
| `:bytes` | 64Ki | bytes read at a time: the window |
| `:workers` | 1 | windows parsed in parallel |

Each value is what `from-json` returns for that line, parsed by whichever
backend this engine chose. A malformed line fails with a message naming its
line number. Blank and whitespace-only lines are skipped, CRLF endings are
accepted, and a file need not end with a newline.

### Measured

200 MB of JSONL, 1,398,000 records, counting one field per record. Raku++
5.8.0, arm64 macOS.

| | time | peak |
|---|---:|---:|
| whole file (`slurp`, wrap in an array, `from-json`) | 3.5s | 2743 MiB |
| `json-each` | 4.8s | **30 MiB** |
| `json-each :workers(2)` | **2.4s** | 57 MiB |
| `json-each :workers(4)` | 2.2s | 67 MiB |
| `json-stream` | 6.4s | 1913 MiB |

`json-each` is flat in the file: 29 MiB at 100 MB against 30 MiB at 200 MB,
where the whole-file read doubles. From two workers up it is also faster in
wall time than reading the whole file, on **one fiftieth** of the memory.

Two things paid for most of that, and neither is what it looks like from the
code:

- **The window wants to be small.** 64 KiB is both quicker and lighter than
  4 MiB — 4.8s/30 MiB against 5.0s/284 MiB on one thread — because a window's
  decoded text and the lines split out of it are walked several times, and once
  they stop fitting in cache every pass pays. Below about 32 KiB per-window
  overhead takes over instead. A bigger window does parallelise better, though,
  so **raise `:bytes` if you raise `:workers` a long way**; at these sizes two
  workers is already most of the gain.
- **Framing cost more than parsing.** Splitting a window and picking the
  documents out of it took 1.8s against 1.1s to parse them, for 699,000 lines.
  `parse-window` in `JSON::Native::Lines` carries the measurements; the short
  version is that on Raku++ a `for` loop beats an indexed `while`, `.trim`
  beats reading the first codepoint with `.ord`, and `:=` costs more than `=`.

**`json-stream` is not bounded on Raku++ 5.8.0.** It reads in windows, but
hands the values back as a `Seq`, and a `Seq` there retains every value it
yields ([rakupp #263](https://github.com/ash/rakupp/issues/263)) — which is
why the table above shows it tracking the file. It is flat on Rakudo. For a
file you cannot hold on Raku++, use `json-each`.

### What it does not do

A document whose top level is a single array (`[{…},{…},…]`, all one value,
newlines or not) is **not** JSONL and is not streamed — `json-each` would see
one malformed line. Splitting such a file needs an incremental parser that
can yield at each element, which this does not have; `from-json` holds it
whole. The distinction is whether a newline ends a document, and in JSONL it
always does, because JSON forbids a raw newline inside a string.

## Backends

Each engine loads only what its own path needs. The distribution's other
modules are reached by a runtime `require` behind a test of the engine, so
none of them is even parsed on an engine that does not use it:

| engine | parses | writes | reads at `use` |
|---|---|---|---|
| Raku++ | the engine's codec | the engine's codec | nothing — the engine answers `use` |
| Rakudo | `Rakudo::Internals::JSON` | `JSON::Native::Rakudo`, an `nqp::` writer | `JSON::Native` |
| mutsu | the JSON::Fast mutsu ships | the same | `JSON::Native` (or JSON::Fast) |
| any other | `JSON::Native::Raku` | `JSON::Native::Raku` | `JSON::Native` |

`JSON::Native::Raku` is the module's pure-Raku implementation. Besides being
the whole of it on other engines, it answers whatever a faster path does not
take — an adverb it lacks, a type outside the JSON ladder, a document it
refuses — and is loaded by the first call that needs it and by no other. On
Raku++ the engine carries its own copy of it.

## JSON::Fast compatibility

JSON::Fast is Raku's established JSON module, and JSON::Native implements its
interface exactly: the same two functions, the same adverbs, the same import
options, and the same answers — the same values and types
from `from-json`, the same text from `to-json` byte for byte, down to its
quirks (an empty array pretty-printed as `"[\n]"`, a raw TAB refused inside a
string while other raw control characters pass, a `//` comment running into
the end of the text read as content after the document). So a program written
for JSON::Fast switches by changing one line:

```raku
- use JSON::Fast;      # before
+ use JSON::Native;    # after
```

What runs underneath is not JSON::Fast, and on most engines nothing of it
needs to be installed:

- **Rakudo** carries a copy of JSON::Fast inside itself, as
  `Rakudo::Internals::JSON` — it is what zef reads `META6.json` with — and
  JSON::Native parses with it, at JSON::Fast's own speed. Its *writer* is an
  older one that is wrong outside plain JSON data, so writing is
  JSON::Native's own `nqp::` writer, which is faster than JSON::Fast's.
- **mutsu** ships JSON::Fast as part of its standard batteries and runs it
  quickly, so there JSON::Native forwards both directions to that copy,
  loaded when the module is.
- **Raku++** answers both directions with its own codec — see below.

### On Raku++, JSON::Fast runs on the same codec

Raku++ speeds up JSON::Fast too. When a program
says `use JSON::Fast`, Raku++ loads the installed JSON::Fast as usual, then
replaces its `from-json` and `to-json` with the engine's built-in codec;
a call the codec does not cover goes back to JSON::Fast's own code. When a
program says `use JSON::Native`, the engine hands out the same codec
directly.

So on Raku++ the two modules parse and write at the same speed.

| on Raku++ | `use JSON::Fast` | `use JSON::Native` |
|---|---|---|
| speed of `from-json` / `to-json` | the engine's codec | the engine's codec |
| must be installed | yes | no (optionally) |
| read at `use` | JSON::Fast's source | nothing |
| startup cost of the `use` | about 5 ms | about 0.1 ms |
| calls the codec does not cover | JSON::Fast's own code | `JSON::Native::Raku`, built into the engine |

The test suite holds JSON::Fast's answers for some 125 documents and 440
value-and-adverb combinations, written down by JSON::Fast itself, and checks
every one on every engine and path; where JSON::Fast is installed,
`t/04-json-fast.t` also asks it live over 600 random documents and random
corruptions of them.

## Performance

Measured 2026-10-13 on a MacBook Air (Apple M4: 4 performance and 6
efficiency cores, 16 GB of memory) under macOS 26.6.2, with Raku++ 5.3.0-85,
Rakudo v2026.09 and mutsu 0.25.0, on the CSV/JSON sample data in
[benchmarks/sample-data](https://github.com/ash/raku-modules/tree/main/benchmarks/sample-data)
of the [ash/raku-modules](https://github.com/ash/raku-modules) repository on
GitHub, where this module is developed. The script that took the numbers is
there too, so they can be re-run. The records hold integers, decimals,
exponent forms, nested objects, arrays, nulls, `\u` escapes and non-ASCII
text.

| file | records | size |
|---|---:|---:|
| `tiny.json` | 1 | 49 B |
| `small.json` | 100 | 35 KB |
| `medium.json` | 10,000 | 3.6 MB |
| `large.json` | 100,000 | 36 MB |

Each cell is a range: the fastest and the slowest of five separate runs, with
the two modules taking turns. A single number means every run gave the same
result at the precision shown. Where the two modules' ranges overlap, the
difference between them is noise.

What one call costs, on the small file and on the single-record one. A run
repeats the call until it has covered a megabyte, and reports one call's time,
best of five passes:

| | 100 records parse | 100 records write | 1 record parse | 1 record write |
|---|---:|---:|---:|---:|
| Raku++, JSON::Fast | 188–195 µs | 223–231 µs | 0.61–0.63 µs | 0.67–0.69 µs |
| Raku++, **JSON::Native** | 187–199 µs | 223–228 µs | 0.63–0.64 µs | 0.67–0.69 µs |
| Rakudo, JSON::Fast | 4.0 ms | 4.5 ms | 5.39–5.54 µs | 9.72–10.0 µs |
| Rakudo, **JSON::Native** | 4.0 ms | 3.1–3.2 ms | 6.63–6.84 µs | 8.46–8.80 µs |
| mutsu, JSON::Fast | 14.3–14.5 ms | 103–106 ms | 26.9–28.1 µs | 237–240 µs |
| mutsu, **JSON::Native** | 15.1–15.4 ms | 107–109 ms | 43.1–43.6 µs | 259–261 µs |

How fast a large document goes, on the medium and large files. A run reports
the best of three passes; mutsu ran the large file three times, one pass
each:

| | 10,000 records parse | 10,000 records write | 100,000 records parse | 100,000 records write |
|---|---:|---:|---:|---:|
| Raku++, JSON::Fast | 19.3–19.7 ms | 23.4–23.8 ms | 196–206 ms | 245–260 ms |
| Raku++, **JSON::Native** | 19.2–19.8 ms | 23.5–24.5 ms | 199–211 ms | 244–253 ms |
| Rakudo, JSON::Fast | 441–446 ms | 482–488 ms | 4.65–4.85 s | 5.86–6.10 s |
| Rakudo, **JSON::Native** | 433–437 ms | 337–346 ms | 4.58–4.65 s | 4.76–5.18 s |
| mutsu, JSON::Fast | 1.45–1.48 s | 10.5–10.7 s | 14.7–14.8 s | 105–106 s |
| mutsu, **JSON::Native** | 1.53–1.56 s | 10.9–11.1 s | 15.5 s | 109–110 s |

The two Raku++ rows match because both modules' calls run on the engine's
built-in codec (see [On Raku++, JSON::Fast runs on the same
codec](#on-raku-jsonfast-runs-on-the-same-codec)). On Rakudo and mutsu,
JSON::Native parses with JSON::Fast's own code: Rakudo's built-in copy of it,
and the JSON::Fast that mutsu ships. On large documents that parses at
JSON::Fast's speed, within a few percent either way. On a one-record document
the extra call in front of it shows: about 1.3 µs a call on Rakudo and 16 µs
on mutsu. Writing on Rakudo is JSON::Native's own, and is faster.

## Environment

`JSON_NATIVE_BACKEND` names one path to use instead of the engine's usual
one: `engine`, `rakudo`, `json-fast` or `raku`. One that is not available is
reported on STDERR, and the usual path is used. On Raku++, naming any path
but `engine` leaves `use JSON::Native` to the installed distribution. It is
meant for testing and diagnosis:

```sh
JSON_NATIVE_BACKEND=raku raku my-program.raku
```

## Limitations

- **The exception class differs from JSON::Fast's.** Content after the
  document raises `X::JSON::Native::AdditionalContent`, with the same
  attributes as JSON::Fast's `X::JSON::AdditionalContent`; a `CATCH` naming
  JSON::Fast's class needs this name instead. Two distributions cannot both
  declare one global class, and Rakudo and mutsu do not export a class under
  another name. The class is visible once `JSON::Native::Raku` is loaded —
  `need JSON::Native::Raku;` makes it nameable.
- **`JSON::Native::Raku` exports nothing.** It can be used on its own by full
  name (`JSON::Native::Raku::from-json`); exporting would let a runtime load
  of it put its subs over a program's own on an engine whose `require`
  imports.
- **`from-json` holds the whole document.** A JSON document is one value, so
  it cannot be handed back a piece at a time; `from-json` returns the complete
  structure or nothing. For JSON **Lines** — one document per line — there is
  `json-each`, which is bounded; see [Streaming JSON Lines](#streaming-json-lines).
  A single huge document, including one whose top level is an array, still has
  to be held, and peak memory is a multiple of the file:

  | file | Raku++ (`engine`) | Rakudo (`rakudo`) |
  |---|---:|---:|
  | 100 MB | 1120 MiB (~11×) | 2060 MiB (~20×) |
  | 200 MB | 2179 MiB (~11×) | 3966 MiB (~20×) |

  Reading alone accounts for part of it — `.slurp` of the 200 MB file is
  780 MiB on Raku++ and 1492 MiB on Rakudo — and the parsed structure is the
  rest. So budget roughly ten to twenty times the file. (Measured on arm64
  macOS, Raku++ 5.8.0 and Rakudo v2026.05, on an array of 1.2 million small
  objects.)

## Compatibility

| engine | version | backend | 01-parse | 02-write | 03-backends | 04-json-fast | 05-drop-in | 06-io | 07-lines |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| Rakudo | v2026.05 | `rakudo` | 24/24 | 28/28 | 7/7 | 8/8 | 6/6 | 13/13 | 92/92 |
| Rakudo | v2026.05 | `raku` | 24/24 | 28/28 | 7/7 | 8/8 | 6/6 | 13/13 | 92/92 |
| Raku++ | 5.8.0 | `engine` | 24/24 | 28/28 | 7/7 | skipped | 6/6 | 13/13 | 92/92 |
| Raku++ | 5.8.0 | `raku` | 24/24 | 28/28 | 7/7 | skipped | 6/6 | 13/13 | 92/92 |
| mutsu | 2026.07 | `json-fast` | 24/24 | 28/28 | 7/7 | 8/8 | 6/6 | — | — |
| mutsu | 2026.07 | `raku` | 24/24 | 28/28 | 7/7 | 8/8 | 6/6 | — | — |

The Rakudo and Raku++ rows are from the versions named, on arm64 macOS. The
mutsu rows are from an earlier run on 2026.07 and predate `t/06-io.t` and
`t/07-lines.t`.

## See also

- [JSON::Fast](https://github.com/timo/json_fast) — the module whose
  interface this one implements.

Why the module is shaped this way, and what running it under three engines
turned up, is in
[notes/JSON-Native.md](https://github.com/ash/raku-modules/blob/main/notes/JSON-Native.md).


## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.
