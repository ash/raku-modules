# JSON::Native

JSON::Native — read and write JSON from Raku, on whichever engine runs the
program, as fast as that engine allows.

> Version 0.1.0. The interface below is implemented and tested on Rakudo,
> Raku++ and mutsu.

## Synopsis

```raku
use JSON::Native;

my $data = from-json('{"name": "Raku", "versions": [6, 6.5], "ok": true}');
say $data<versions>[1].WHAT;     # (Rat) — Raku numerics, not doubles

say to-json($data);              # pretty-printed
say to-json($data, :!pretty);    # one line
say to-json($data, :sorted-keys);

say json-backend;                # which path parses on this engine
```

## Description

JSON::Native converts between JSON text and Raku data. `from-json` turns a
JSON document into Raku values — integers into `Int`, decimals into exact
`Rat`, exponent forms into `Num`, objects and arrays into `Hash` and `Array` —
and `to-json` writes Raku data back as JSON, pretty-printed or on one line.

It runs on any Raku engine, and on each it takes the fastest path that engine
offers, so the same program is portable and fast without changing a line:

- on **Raku++** the engine's own built-in JSON codec answers, and a Raku++
  recent enough answers `use JSON::Native` itself — **the module does not even
  need to be installed there**;
- on **Rakudo** it parses with the JSON reader Rakudo carries internally and
  writes with a writer of its own built on `nqp::` ops;
- on **mutsu** it uses the JSON codec mutsu ships with;
- anywhere else it runs as plain Raku.

None of that shows in the results: every path gives the same values and the
same text. It has no dependencies and nothing to compile.

## Installation

```sh
zef install JSON::Native
```

On Raku++ there is nothing to install: a Raku++ built from rakupp's sources
of 2026-10-13 onwards answers `use JSON::Native` from the engine, without
reading any module file. Installing it there anyway does no harm; the engine
steps aside only for a newer version than the one it implements.

## Functions

### from-json

```raku
from-json(Str() $text, :$immutable, :$allow-jsonc)
```

Parses one JSON document and returns its value:

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

## Backends

Each engine loads only what its own path needs. The distribution's other
modules are reached by a runtime `require` behind a test of the engine, so
none of them is even parsed on an engine that does not use it:

| engine | parses | writes | reads at `use` |
|---|---|---|---|
| Raku++ | the engine's codec | the engine's codec | nothing — the engine answers `use` |
| Rakudo | `Rakudo::Internals::JSON` | `JSON::Native::Rakudo`, an `nqp::` writer | `JSON::Native` |
| mutsu | the JSON::Fast mutsu ships | the same | `JSON::Native` and that JSON::Fast |
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
use JSON::Fast;      # before
use JSON::Native;    # after
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
- **Raku++** answers both directions with its own codec, the same one it
  already runs JSON::Fast's calls on.

Where a forwarded call does not match JSON::Fast exactly, JSON::Native does
not forward it: those calls go to `JSON::Native::Raku`, which reproduces
JSON::Fast's behaviour in plain Raku. The one difference a program can see
is the exception class for content after the document — see Limitations.

The test suite holds JSON::Fast's answers for some 125 documents and 440
value-and-adverb combinations, written down by JSON::Fast itself, and checks
every one on every engine and path; where JSON::Fast is installed,
`t/04-json-fast.t` also asks it live over 600 random documents and random
corruptions of them.

## Performance

A 316 KB document of 1,400 records — integers, decimals, exponent forms,
escaped and non-ASCII strings — and a 50-byte one, best of several runs,
measured 2026-10-13 on arm64 macOS:

| | 316 KB parse | 316 KB write | 50 B parse | 50 B write |
|---|---:|---:|---:|---:|
| Rakudo v2026.09, JSON::Fast | 45.0 ms | 54.3 ms | 5.4 µs | 10.0 µs |
| Rakudo, **JSON::Native** | **46.5 ms** | **41.6 ms** | 7.1 µs | 10.6 µs |
| Raku++, JSON::Fast | 2.6 ms | 3.0 ms | 0.48 µs | 0.62 µs |
| Raku++, **JSON::Native** | **2.6 ms** | **3.0 ms** | **0.49 µs** | **0.63 µs** |
| mutsu 2026.07, JSON::Fast | 143 ms | 876 ms | 23 µs | 230 µs |
| mutsu, **JSON::Native** | **149 ms** | **888 ms** | 34 µs | 243 µs |
| Rakudo, pure Raku (`raku`) | 136 ms | 96 ms | 23 µs | 49 µs |
| Raku++, pure Raku (`raku`) | 357 ms | 235 ms | 94 µs | 83 µs |
| mutsu, pure Raku (`raku`) | 1,046 ms | 733 ms | 264 µs | 310 µs |

On Raku++ JSON::Fast's calls run on the engine's codec too, which is why
those two rows match: there is nothing faster to reach. The Raku++ rows are a
5.3.0 development build from 2026-10-13; an older Raku++ answers through the
same codec from the module's own file, at 14 ms to parse this document. The
`raku` rows are the plain-Raku implementation, for comparison: it is what
answers on an engine none of the above covers.

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

## Compatibility

| engine | version | backend | 01-parse | 02-write | 03-backends | 04-json-fast | 05-drop-in |
|---|---|---|---:|---:|---:|---:|---:|
| Rakudo | v2026.09 | `rakudo` | 24/24 | 28/28 | 7/7 | 8/8 | 6/6 |
| Rakudo | v2026.09 | `raku` | 24/24 | 28/28 | 7/7 | 8/8 | 6/6 |
| Raku++ | 5.3.0-83 | `engine` | 24/24 | 28/28 | 7/7 | skipped | 6/6 |
| Raku++ | 5.3.0-83 | `raku` | 24/24 | 28/28 | 7/7 | skipped | 6/6 |
| mutsu | 2026.07 | `json-fast` | 24/24 | 28/28 | 7/7 | 8/8 | 6/6 |
| mutsu | 2026.07 | `raku` | 24/24 | 28/28 | 7/7 | 8/8 | 6/6 |

Counts are from runs with `JSON_NATIVE_BACKEND` and
`JSON_NATIVE_REQUIRE_BACKEND` set to the backend; a Raku++ build from
2026-10-13 gives the same counts, and passes 01 and 02 with the engine itself
answering `use JSON::Native`. `t/04-json-fast.t` needs JSON::Fast, and skips
itself on Raku++, where JSON::Fast's subs are the engine's own codec and would
only compare the engine with itself. No version is an established floor.

Three engine faults the module steps around: Raku++ 5.3's codec handed back
text that is not in NFC (`"a\u0301"` decoded to an `a` and a
separate combining mark), so there a document with a `\u` escape goes to the
Raku implementation; Raku++ 5.3 made a variable bound to a routine's
native-int result an int slot, which the Raku implementation sidesteps by
never rebinding one; and mutsu 2026.07's runtime `require` imports what it
loads into the program, which is why mutsu loads its JSON::Fast at `use` time
and `JSON::Native::Raku` exports nothing.

## See also

- [JSON::Fast](https://github.com/timo/json_fast) — the module whose
  interface this one implements.
- [Raku++](https://github.com/ash/rakupp) and
  [mutsu](https://github.com/tokuhirom/mutsu) — the other engines it is
  tested on.

## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.

---

Why the module is shaped this way, and what running it under three engines
turned up, is in
[notes/JSON-Native.md](https://github.com/ash/raku-modules/blob/main/notes/JSON-Native.md).
