# Rakupp::JSON

JSON parsing with a native fast path on **Raku++**, and `JSON::Fast` everywhere
else. The same program runs on both.

```raku
use Rakupp::JSON;

my $data = from-json('{"a": [1, 2.5, true, null]}');
say $data<a>[1].WHAT;      # (Rat) — Raku numerics, not doubles
say to-json($data, :!pretty);

say json-backend();        # 'native', 'engine' or 'JSON::Fast'
```

Three backends, tried in order: the compiled C extension (`native`), then —
on Raku++ without one — the interpreter's own built-in codec (`engine`, no C
compiler needed; 308 KB parsed in ~30 ms whole-process against ~1.1 s through
interpreted `JSON::Fast`), then `JSON::Fast` itself. The engine backend takes
`from-json` only: `to-json` and `:immutable` keep their exact-output paths.

## What it is

The XS pattern, for Raku++. The distribution ships **C source**; the build step
compiles it against Raku++'s extension ABI at install time; the module uses the
result if it is there. On Rakudo — or on a Raku++ whose headers or compiler are
missing — nothing breaks, it calls `JSON::Fast` instead. A failed native build
costs speed, never function.

## Why

Raku++ walks an AST rather than JIT-compiling, so a tokenizer written in Raku
costs it roughly 12× what Rakudo pays, and parsing JSON is exactly that shape of
work. Rather than teach the interpreter to special-case somebody's module, the
parse moves into C behind a module that says what it is.

278 KB document, same machine:

| | |
|---|---:|
| Rakudo + `JSON::Fast` | 37.5 ms |
| Raku++ + `JSON::Fast` | ~440 ms |
| **Raku++ + `Rakupp::JSON`** | **5.7 ms** |

## Compatibility

`from-json` returns what `JSON::Fast` returns — same values *and* same Raku
types, which the test suite checks case by case against `JSON::Fast` itself, on
whichever engine is running:

- integer token → `Int`, arbitrary precision
- decimal → `Rat`, so `from-json('[0.1,0.2]').sum == 0.3`
- exponent form → `Num`
- `true`/`false` → `Bool`, `null` → `Any`
- objects and arrays → `Hash`/`Array`, or `Map`/`List` under `:immutable`

`to-json` is `JSON::Fast`'s on both engines. Serialising has to walk a hash and
extension ABI v1 offers only index-based hash access, so there is nothing to win
yet — and a serializer's exact output is a contract worth not disturbing.

## Requirements

Nothing, to work. For the fast path: Raku++, a C compiler, and Raku++'s headers
installed (`<prefix>/include/rakupp/rakupp_ext.h`, which `cmake --install`
places there). Set `RAKUPP_SRC` to a checkout's `src/` to build against that
instead.

## Known costs

The extension pays an ABI tax the in-tree prototype did not: every value crosses
as an opaque handle allocated in a per-call arena, then is copied into its
container — about one extra `Value` copy per node, which is the difference
between 2.7 ms and 5.7 ms on the document above. That is the price of the module
being able to outlive the compiler release it was built against, and it is the
right trade; a future ABI with move semantics would close most of it.
