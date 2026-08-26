# JSON::Native

JSON parsing with a native fast path on **Raku++**, and `JSON::Fast` everywhere
else. The same program runs on both.

```raku
use JSON::Native;

my $data = from-json('{"a": [1, 2.5, true, null]}');
say $data<a>[1].WHAT;      # (Rat) — Raku numerics, not doubles
say to-json($data, :!pretty);

say json-backend();        # 'native', 'engine' or 'JSON::Fast'
```

Three backends, tried in order: the compiled C extension (`native`), then —
on Raku++ without one — the interpreter's own built-in codec (`engine`, no C
compiler needed), then `JSON::Fast` itself. The engine backend takes
`from-json` only: `to-json` and `:immutable` keep their exact-output paths.
The tables below have the measured cost of each.

## What it is

The XS pattern, for Raku++. The distribution ships **C source**; the build step
compiles it against Raku++'s extension ABI at install time; the module uses the
result if it is there. On Rakudo — or on a Raku++ whose headers or compiler are
missing — nothing breaks, it calls `JSON::Fast` instead. A failed native build
costs speed, never function.

## Why

Raku++ walks an AST rather than JIT-compiling, so a tokenizer written in Raku
costs it roughly an order of magnitude more than it costs Rakudo, and JSON is
exactly that shape of work. The engine itself fast-paths the `JSON::Fast`
calls it can cover — both directions, since 2026-08-23 including non-ASCII
strings — so the extension's remaining edge is the parse column, plus a
module name that *says* the code leans on native speed rather than getting it
by engine courtesy.

278 KB document (the diagnose corpus: escaped and non-ASCII strings included),
best of N, measured 2026-08-23:

| | parse | serialise |
|---|---:|---:|
| Rakudo + `JSON::Fast` | 42.0 ms | 41.3 ms |
| Raku++ + `JSON::Fast` (engine fast path) | ~6 ms | 6.1 ms |
| Raku++ + `JSON::Native`, engine backend | 7.7 ms | 2.5 ms† |
| **Raku++ + `JSON::Native`, extension** | **5.0 ms** | **3.5 ms** |

† the engine backend's `to-json` delegates to `JSON::Fast` — that cell is the
engine fast path writing this module's parsed data.

Parse time is linear in document size — worth stating, because for a while it
was not, and a table at a single size is exactly the shape of benchmark that
cannot tell you. Measured 2026-08-23, ~50-55 MB/s parse and ~72 MB/s write at
every rung (extension backend):

| document | parse | serialise |
|---|---:|---:|
| 278 KB | 5.0 ms | 3.5 ms |
| 1.1 MB | 21.3 ms | 14.7 ms |
| 2.2 MB | 40.8 ms | 29.5 ms |
| 4.5 MB | 77.9 ms | 59.2 ms |

## Compatibility

`from-json` returns what `JSON::Fast` returns — same values *and* same Raku
types, which the test suite checks case by case against `JSON::Fast` itself, on
whichever engine is running:

- integer token → `Int`, arbitrary precision
- decimal → `Rat`, so `from-json('[0.1,0.2]').sum == 0.3`
- exponent form → `Num`
- `true`/`false` → `Bool`, `null` → `Any`
- objects and arrays → `Hash`/`Array`, or `Map`/`List` under `:immutable`

`to-json` is native too (extension ABI 2 made a sequential hash walk O(1) per
key), and its output is `JSON::Fast`'s **byte for byte** — a serializer's
exact output is a contract programs already depend on, so the test suite
checks it value by value against `JSON::Fast` itself. Anything the native
path does not claim stands aside and the module answers: `:sorted-keys`,
`:spacing`, NaN/Inf (whose rendering follows `$*JSON_NAN_INF_SUPPORT`), and
every type outside the JSON ladder (Date, Version, sets, objects). The same
rule covers adverbs: an option this module does not know — `from-json`'s
`:allow-jsonc`, or whatever `JSON::Fast` grows next — is delegated, never
refused. Being exactly right or standing aside is the whole bargain.

## Requirements

Nothing, to work. For the fast path: Raku++, a C compiler, and Raku++'s headers
installed (`<prefix>/include/rakupp/rakupp_ext.h`, which `cmake --install`
places there). Set `RAKUPP_SRC` to a checkout's `include/` directory to build
against that instead. When none of that is present the install still succeeds —
the build step leaves a stub and the module runs on its fallbacks.

## Known costs

The extension pays an ABI tax: every value crosses as an opaque handle
allocated in a per-call arena, then is copied into its container — about one
extra `Value` copy per node. That is the price of the module outliving the
compiler release it was built against, and it is the right trade; a future ABI
with move semantics would close most of it. It is also no longer the deciding
number: with the shared decode buffer and ABI 2's O(1) hash walk, the
extension outruns the engine's own in-tree codec (5.0 ms against 7.7 ms on
the 278 KB parse above) despite the copies.
