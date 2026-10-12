# JSON::Native

JSON parsing and writing with a native fast path on **Raku++**, and pure Raku
everywhere else. No dependencies. The same program runs on both engines, and
gets JSON::Fast's answers on both.

> Version 0.0.3. The interface below is implemented and tested on both
> engines and on all three of the module's backends; what it leaves out of
> JSON::Fast's surface is under Scope.

```raku
use JSON::Native;

my $data = from-json('{"a": [1, 2.5, true, null]}');
say $data<a>[1].WHAT;      # (Rat) — Raku numerics, not doubles
say to-json($data, :!pretty);

say json-backend();        # 'native', 'engine' or 'raku'
```

## What it is

The XS pattern, for Raku++. The distribution ships **C source**; the build step
compiles it against Raku++'s extension ABI at install time; the module uses the
result if it is there. Three paths, tried in order:

| backend | where | what it answers |
|---|---|---|
| `native` | Raku++ with the extension built | `from-json` (and `:immutable`), `to-json` (and `:pretty`) |
| `engine` | Raku++ without it | the same, from the interpreter's own built-in codec, plus every `to-json` adverb but a callable `:sorted-keys` |
| `raku` | everywhere | everything — and on Rakudo, every call |

The `raku` path is `JSON::Native::Raku`, the distribution's second module: a
complete JSON parser and writer in plain Raku. It is loaded the first time a
call needs it, by `require`, so a program on Raku++ whose calls the native
paths answer never loads it at all. It can also be used on its own:
`use JSON::Native::Raku` exports the same `from-json` and `to-json`.

A native path either answers exactly or stands aside. One that declines a call
— an adverb or a type it does not take — hands it to the Raku implementation,
and so does one that **raises**: a document a native parser refuses is still
answered the way JSON::Fast answers it, including what JSON::Fast refuses and
how. A failed native build costs speed, never function, and never changes an
answer.

## The contract

JSON::Fast's, which this module used to depend on and now does not.

`from-json` returns what JSON::Fast returns — same values *and* same Raku
types, case by case:

- integer token → `Int`, arbitrary precision
- decimal → `Rat`, so `from-json('[0.1,0.2]').sum == 0.3`
- exponent form → `Num`
- `true`/`false` → `Bool`, `null` → `Any`
- objects and arrays → `Hash`/`Array`, or `Map`/`List` under `:immutable`

It takes JSON::Fast's adverbs, `:immutable` and `:allow-jsonc`, and refuses
what JSON::Fast refuses, quirks included: a raw TAB or LF inside a string is
an error, any other raw control character is not; a `//` comment that runs to
the very end of the text reads as content after the document. Content after
the document raises `X::JSON::Native::AdditionalContent`, with JSON::Fast's
`parsed`, `parsed-length` and `rest-position`.

`to-json` writes what JSON::Fast writes, **byte for byte** — a serializer's
exact output is a contract programs already depend on. The same adverbs
(`:pretty`, `:spacing`, `:sorted-keys`, `:enums-as-value`, `:level`), the same
layout down to an empty array pretty-printing as `"[\n]"`, the same escapes
down to backspace as `\u0008` rather than `\b`, astral characters as
surrogate pairs, NaN and Inf as `null` unless `$*JSON_NAN_INF_SUPPORT` says
otherwise, and the same rules for every type outside the JSON ladder — Date,
Instant, Version, Seq, Pair, sets, enums, allomorphs.

The test suite holds JSON::Fast's answers for some 120 documents and 440
value-and-adverb combinations, written down by JSON::Fast itself, and checks
every one through both `JSON::Native` and `JSON::Native::Raku`; where
JSON::Fast is installed, `t/04-json-fast.t` asks it live as well, over 600
random documents and random corruptions of them.

## Measured

A 316 KB document of 1,400 records — integers, decimals, exponent forms,
escaped and non-ASCII strings — best of several runs, measured 2026-10-12 on
arm64 macOS:

| | parse | write |
|---|---:|---:|
| Rakudo v2026.09, JSON::Fast | 47 ms | 55 ms |
| Rakudo v2026.09, `JSON::Native` (`raku`) | 118 ms | 89 ms |
| Raku++, `JSON::Native`, **extension** | **4.1 ms** | **4.0 ms** |
| Raku++, `JSON::Native`, engine codec | 5.9 ms | 3.0 ms |
| Raku++, `JSON::Native::Raku` | 350 ms | 224 ms |

The Raku++ figures are a 5.3.0 development build carrying the engine's new
number typing; on the build before it (5.3.0-83) the engine codec parses this
document in 13.7 ms, the rest unchanged. On Rakudo the module is the price of
having no dependency: JSON::Fast reaches MoarVM through `nqp::` ops, and this
module's Raku implementation is plain Raku, the same code on both engines —
2.5x slower to parse, 1.6x to write, and faster than JSON::Fast on
string-heavy documents.

## Requirements

Nothing, to work. For the fast path: Raku++, a C compiler, and Raku++'s headers
installed (`<prefix>/include/rakupp/rakupp_ext.h`, which `cmake --install`
places there). Set `RAKUPP_SRC` to a checkout's `include/` directory to build
against that instead. When none of that is present the install still succeeds —
the build step leaves a stub and the module runs on its other paths.

## Scope

- **`use JSON::Native <immutable>`** and JSON::Fast's other import-list
  defaults (`!pretty`, `sorted-keys`, `enums-as-value`) are not supported; the
  import list here is the names to import, for Data::Native's cooperation
  protocol.
- **`X::JSON::Native::AdditionalContent`** is this module's class, not
  JSON::Fast's `X::JSON::AdditionalContent`: two distributions cannot both
  declare one global class. Its type is only visible once `JSON::Native::Raku`
  is loaded — `need JSON::Native::Raku;` makes it nameable in a `CATCH`.
- **The engine codec is not asked for `:allow-jsonc`.** It closes a comment
  that runs to the end of the text, where JSON::Fast does not, so JSONC goes
  to the Raku implementation.

## Compatibility

| engine | version | 01-parse | 02-write | 03-backends | 04-json-fast |
|---|---|---:|---:|---:|---:|
| Rakudo | v2026.09 | 22/22 | 28/28 | 4/4 | 8/8 |
| Raku++, extension | 5.3.0-74 | 22/22 | 28/28 | 4/4 | skipped |
| Raku++, engine codec | 5.3.0-74 | 22/22 | 28/28 | 4/4 | skipped |

Counts are from runs with `JSON_NATIVE_REQUIRE_BACKEND` set, as CI sets it;
the same counts come from 5.3.0-83 and from a build carrying the engine's new
number typing. `t/04-json-fast.t` needs JSON::Fast installed, and skips itself
on Raku++, where JSON::Fast's subs are replaced by the engine's own codec at
load time and would only compare the engine with itself. Neither version is an
established floor; the extension needs a Raku++ with extension ABI 2 or later.

A Raku++ whose built-in codec does not hand back NFC text — every build
before the codec fix this release was measured with: `"a\u0301"` decoded
to an `a` and a separate combining mark — is detected when the module
loads, and there a document with a `\u` escape in it goes to the Raku
implementation instead.

## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.

---

Why the module is shaped this way, and what running it under two engines
turned up, is in
[notes/JSON-Native.md](https://github.com/ash/raku-modules/blob/main/notes/JSON-Native.md).
