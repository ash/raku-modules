# JSON::Native

A drop-in for JSON::Fast — change `use JSON::Fast` to `use JSON::Native` and
the program keeps working — that takes each engine's fastest exact path:
**Raku++**'s built-in codec, **Rakudo**'s own copy of JSON::Fast and an
`nqp::` writer, **mutsu**'s bundled JSON::Fast, and pure Raku everywhere else.
No dependencies, nothing to compile.

> Version 0.1.0. The interface below is implemented and tested on Rakudo,
> Raku++ and mutsu; what it leaves out of JSON::Fast's surface is under Scope.

```raku
use JSON::Native;                # or: use JSON::Native <!pretty sorted-keys>;

my $data = from-json('{"a": [1, 2.5, true, null]}');
say $data<a>[1].WHAT;            # (Rat) — Raku numerics, not doubles
say to-json($data, :!pretty);

say json-backend;                # which path parses: 'engine', 'rakudo', …
say json-backend(:write);        # and which one writes
```

## What runs where

Each engine loads only what its own row needs. The other modules of the
distribution are reached by a runtime `require` behind a test of the engine,
so none of them is even parsed elsewhere:

| engine | parses | writes | reads at `use` |
|---|---|---|---|
| Raku++ | the engine's codec | the engine's codec | nothing — the engine answers `use JSON::Native` itself |
| Rakudo | `Rakudo::Internals::JSON`, Rakudo's own copy of JSON::Fast | `JSON::Native::Rakudo`, an `nqp::` writer | `JSON::Native` |
| mutsu | the JSON::Fast mutsu ships | the same | `JSON::Native` and that JSON::Fast |
| any other | `JSON::Native::Raku` | `JSON::Native::Raku` | `JSON::Native` |

Anything a fast path does not answer exactly as JSON::Fast does — an adverb it
does not take, a type outside the JSON ladder, a document it refuses — goes to
**`JSON::Native::Raku`**, JSON::Fast's behaviour in plain Raku, which is
loaded by the first call that needs it and by no other. On Raku++ even that
needs nothing installed: the engine carries its own copy of it.

`JSON_NATIVE_BACKEND` names one path to use instead — `engine`, `rakudo`,
`json-fast` or `raku`. One that is not there is reported on STDERR, and the
usual choice is used. On Raku++, naming any path but `engine` leaves `use
JSON::Native` to the installed distribution.

```sh
JSON_NATIVE_BACKEND=raku raku my-program.raku
```

## The contract

JSON::Fast's, which this module used to depend on and now does not.

`from-json` returns what JSON::Fast returns — same values *and* same Raku
types:

- integer token → `Int`, arbitrary precision
- decimal → `Rat`, so `from-json('[0.1,0.2]').sum == 0.3`
- exponent form → `Num`
- `true`/`false` → `Bool`, `null` → `Any`
- objects and arrays → `Hash`/`Array`, or `Map`/`List` under `:immutable`

It takes JSON::Fast's adverbs, `:immutable` and `:allow-jsonc`, and refuses
what JSON::Fast refuses, quirks included: a raw TAB or LF inside a string is
an error, any other raw control character is not; a `//` comment that runs to
the very end of the text reads as content after the document.

`to-json` writes what JSON::Fast writes, **byte for byte**. The same adverbs
(`:pretty`, `:spacing`, `:sorted-keys`, `:enums-as-value`, `:level`), the same
layout down to an empty array pretty-printing as `"[\n]"`, the same escapes
down to backspace as `\u0008` rather than `\b`, astral characters as
surrogate pairs, NaN and Inf as `null` unless `$*JSON_NAN_INF_SUPPORT` says
otherwise, and the same rules for every type outside the JSON ladder — Date,
Instant, Version, Seq, Pair, sets, enums, allomorphs.

JSON::Fast's import options work as they do there: `use JSON::Native
<immutable !pretty sorted-keys enums-as-value>` changes the defaults of the
subs it hands out, and an adverb at the call still wins.

The test suite holds JSON::Fast's answers for some 125 documents and 440
value-and-adverb combinations, written down by JSON::Fast itself, and checks
every one through both `JSON::Native` and `JSON::Native::Raku` on every
backend of every engine; where JSON::Fast is installed, `t/04-json-fast.t`
asks it live as well, over 600 random documents and random corruptions of
them.

## Measured

A 316 KB document of 1,400 records — integers, decimals, exponent forms,
escaped and non-ASCII strings — and a 50-byte one, best of several runs,
measured 2026-10-13 on arm64 macOS:

| | 316 KB parse | 316 KB write | 50 B parse | 50 B write |
|---|---:|---:|---:|---:|
| Rakudo v2026.09, JSON::Fast | 45.0 ms | 54.3 ms | 5.4 µs | 10.0 µs |
| Rakudo, **`rakudo`** | **46.5 ms** | **41.6 ms** | 7.1 µs | 10.6 µs |
| Rakudo, `raku` | 136 ms | 96 ms | 23 µs | 49 µs |
| Raku++, JSON::Fast | 2.6 ms | 3.0 ms | 0.48 µs | 0.62 µs |
| Raku++, **`engine`** | **2.6 ms** | **3.0 ms** | **0.49 µs** | **0.63 µs** |
| Raku++, `raku` | 357 ms | 235 ms | 94 µs | 83 µs |
| mutsu 2026.07, JSON::Fast | 143 ms | 876 ms | 23 µs | 230 µs |
| mutsu, **`json-fast`** | **149 ms** | **888 ms** | 34 µs | 243 µs |
| mutsu, `raku` | 1,046 ms | 733 ms | 264 µs | 310 µs |

On Rakudo the module parses with JSON::Fast's own code, so the two tie, and
writes faster than it. On Raku++ JSON::Fast's calls run on the engine's codec
too, which is why those rows match: there is nothing faster to reach. The
Raku++ rows are a 5.3.0 development build carrying rakupp's
`json-native-builtin` changes; an older Raku++ answers through the same codec
from this module's file, at 14 ms to parse this document.

## Requirements

Nothing. No dependency, no build step, no C compiler.

## Scope

- **`X::JSON::Native::AdditionalContent`** is this module's class for content
  after the document, with JSON::Fast's `parsed`, `parsed-length` and
  `rest-position`; JSON::Fast's is `X::JSON::AdditionalContent`. A `CATCH`
  naming JSON::Fast's class needs this name instead: two distributions cannot
  both declare one global class, and Rakudo and mutsu do not export a class
  under another name lexically. Its type is visible once `JSON::Native::Raku`
  is loaded — `need JSON::Native::Raku;` makes it nameable.
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
`JSON_NATIVE_REQUIRE_BACKEND` set to the backend; the same counts come from a
Raku++ build carrying the `json-native-builtin` engine changes, which also
passes 01 and 02 with the engine itself answering `use JSON::Native`.
`t/04-json-fast.t` needs JSON::Fast, and skips itself on Raku++, where
JSON::Fast's subs are the engine's own codec and would only compare the engine
with itself. No version is an established floor.

Three engine faults the module steps around, each fixed or reported where it
lives: Raku++ 5.3's codec handed back text that is not in NFC (`"a\u0301"`
decoded to an `a` and a separate combining mark), so a document with a `\u`
escape goes to the Raku implementation there; Raku++ 5.3 made a variable bound
to a routine's native-int result an int slot, which the Raku implementation
sidesteps by never rebinding one; and mutsu 2026.07's runtime `require`
imports what it loads into the program, which is why mutsu loads its
JSON::Fast at `use` time and `JSON::Native::Raku` exports nothing.

## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.

---

Why the module is shaped this way, and what running it under three engines
turned up, is in
[notes/JSON-Native.md](https://github.com/ash/raku-modules/blob/main/notes/JSON-Native.md).
