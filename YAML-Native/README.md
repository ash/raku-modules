# YAML::Native

YAML 1.2 parsing and writing with a native fast path on **Raku++**, and pure
Raku everywhere else. No dependencies. The same program runs on both engines.

> Version 0.0.1. The interface below is implemented and tested on both
> engines, and reads every valid document of the official yaml-test-suite as
> the suite's event stream says it should; what it leaves out is under Scope.

```raku
use YAML::Native;

my %conf = from-yaml(q:to/YAML/);
    defaults: &defaults
      image: rakudo-star
      retries: 2
    jobs:
      test:
        <<: *defaults
        script: |
          prove6 -l t
    YAML
say %conf<jobs><test><image>;             # rakudo-star — merged in
say %conf<jobs><test><retries> + 1;       # 3 — an Int

my @docs = from-yaml("a: 1\n---\nb: 2\n", :all);   # a stream of documents
my %file = from-yaml("config.yaml".IO);            # a path or a handle works too

print to-yaml({ name => 'x', ports => [80, 443], on => True });
# name: x
# on: true
# ports:
#   - 80
#   - 443

say yaml-backend();                       # 'native' or 'raku'
```

```bash
raku   -Ilib examples/config.raku
rakupp -Ilib examples/config.raku
```

## What it is

The XS pattern, as [TOML::Native](../TOML-Native) does it: the distribution
ships C source, the build step compiles it against Raku++'s extension ABI,
and the module uses the result if it is there. On Rakudo, or on a Raku++
without the headers or a compiler, the same parser runs as plain Raku from
the module file. A failed native build costs speed, never function.

There are two implementations of one parser, and the test suite holds them to
each other: on Raku++ every case runs through both and must give the same
data, the same event stream and the same error message. The writer is Raku
only, on both engines.

## Values

Plain scalars are resolved by the YAML 1.2 core schema; everything else is
text.

| YAML | Raku |
|---|---|
| `null`, `Null`, `NULL`, `~`, nothing | `Any` |
| `true`, `false` (and `True`, `TRUE`, …) | `Bool` |
| `42`, `-17`, `0o17`, `0x1F` | `Int`, of any size |
| `1.5`, `.5`, `6.02e23`, `.inf`, `-.inf`, `.nan` | `Num` |
| any other plain scalar | `Str` |
| a quoted or block scalar | `Str` |
| mapping | `Hash`, keyed by each key's text |
| sequence | `Array` |

It is the 1.2 schema, not 1.1's: `yes`, `no`, `on`, `off` are strings, `010`
is ten, `1_000` is a string. A key is its text as written — `1: a` has the
key `'1'`, `0x10: b` the key `'0x10'` — and a mapping or a sequence cannot be
a key. A key may appear once in a mapping.

The core tags apply and override the style: `!!str 42` is `'42'`,
`!!int "42"` is 42, `!!float 1` is `1e0`, and a value its tag does not fit is
an error. The non-specific `!` makes a string. Any other tag is ignored.

## Anchors, aliases and merge keys

An alias is the same object as its anchor, not a copy: a change made through
one is seen through the other, as YAML means. Merge keys (`<<`) are applied:
the keys of the merged mapping, or of each mapping in a merged sequence, are
added to the mapping unless it has them already — its own keys win, and an
earlier merged mapping wins over a later one. A quoted `'<<'` is an ordinary
key.

Aliases may add at most 1,000,000 nodes to a document, so a document built to
expand exponentially is refused rather than walked.

## Documents

`from-yaml($source)` takes a `Str`, an `IO::Path` or an `IO::Handle`. It
returns the stream's one document, `Any` for an empty stream, and refuses a
stream of several. `from-yaml($source, :all)` returns an `Array` of all the
documents, any number of them.

A leading byte-order mark is skipped; LF, CRLF and CR line endings are all
read as LF, including inside block scalars. The text is read as if it ended
in a line break whether or not it does, as the yaml-test-suite reads it: it
matters only to a block scalar on the last line.

## Errors

Every parse error is `YAML::Native: <what> at line N`, and the native and the
Raku implementation raise the same message for the same input:

    YAML::Native: duplicate key 'name' at line 7
    YAML::Native: expected ':' after a mapping key at line 3
    YAML::Native: tabs cannot be used for indentation at line 12
    YAML::Native: undefined alias 'defaults' at line 9
    YAML::Native: a mapping value is not allowed here at line 4
    YAML::Native: unterminated quoted scalar at line 20
    YAML::Native: 'abc' is not a valid !!int at line 2
    YAML::Native: the stream holds 3 documents; read them with :all at line 5

A file that is not UTF-8 is `YAML::Native: the document is not valid UTF-8`.

## Writing

`to-yaml($data)` returns a `Str`. The output is deterministic: keys sorted,
block style, two spaces of indentation, `{}` and `[]` only for empty
collections — the same text on both engines. A string is written plain when
it would read back as the same string, as a literal block (`|`) when it has
line breaks and nothing that needs escaping, and double-quoted otherwise, so
`'true'`, `'42'` and `'~'` come back as strings.

| Raku | written as |
|---|---|
| `Hash`, `Map` | a block mapping |
| `Array`, `List`, `Seq`, anything `Positional` | a block sequence |
| `Str` | plain, literal or double-quoted |
| `Int`, `Bool`, undefined | `42`, `true`, `null` |
| `Num`, `Rat` | a float that reads back as one: `1.0`, `.inf`, `.nan` |
| `Date`, `DateTime` | their text |

Anything else is an error, and so is nesting deeper than 128 levels, which
the reader would refuse:

    YAML::Native: cannot write a value of type IO::Handle

Several documents are written by joining them: `@docs.map({ "---\n" ~
to-yaml($_) }).join` reads back with `:all`.

## Backends

| `yaml-backend` | when |
|---|---|
| `native` | Raku++ with the compiled extension |
| `raku` | Rakudo, or Raku++ without the extension |

`YAML_NATIVE_BACKEND=raku` in the environment forces the Raku implementation
on a Raku++ that has the extension, to compare the two or to rule the native
path out of a suspected bug. The Raku parser is reachable as
`YAML::Native::parse-raku`; the test suite uses it.

`YAML::Native::events($text)` returns the parse in the yaml-test-suite's
event notation, one event per line — `+MAP`, `=VAL :text`, `=ALI *name` —
which shows exactly how a document was read.

## Conformance

The [yaml-test-suite](https://github.com/yaml/yaml-test-suite), data release
`data-2022-01-17`: 308 valid cases and 94 invalid ones, run by
[benchmarks/yaml/conformance.raku](https://github.com/ash/raku-modules/tree/main/benchmarks/yaml)
in the repository. A valid case passes on events when its parse, printed as
events, is the suite's; it loads when `from-yaml(:all)` constructs it; its
data passes, where the case has JSON, when it is what the JSON says; and it
round-trips when `to-yaml` writes it and `from-yaml` reads the text back
the same. An invalid case passes when it is refused.

| engine, backend | events | loads | data | round trip | invalid |
|---|---:|---:|---:|---:|---:|
| Raku++, extension | 308/308 | 292/308 | 279/279 | 292/292 | 94/94 |
| Raku++, Raku implementation | 308/308 | 292/308 | 279/279 | 292/292 | 94/94 |
| Rakudo, Raku implementation | 308/308 | 292/308 | 279/279 | 292/292 | 94/94 |

The sixteen valid cases that do not load are the ones this module declines
by design: fifteen use a mapping or a sequence as a key, and one has a
duplicate key. On Raku++ with the extension the script also runs every case
through the Raku implementation: the same events or the same error message
for all 402, and the same data for all 292 that load.

## Measured

Generated documents in the shape of Kubernetes manifests — Deployments with
nested mappings, sequences of mappings, flow collections, all three quoting
styles and a folded block, and every tenth a ConfigMap with a literal block,
anchors and a merge key. Best of three, 2026-09-24, arm64 Mac, Rakudo
v2026.08 and Raku++ 4.0.1-160. The corpora and the scripts are under
[benchmarks/yaml](https://github.com/ash/raku-modules/tree/main/benchmarks/yaml),
outside the distribution.

| 2,000 documents, 1.7 MB | `from-yaml(:all)` | `to-yaml` |
|---|---:|---:|
| **Raku++, extension** | **51 ms** | 2,387 ms |
| Raku++, Raku implementation | 31,398 ms | 2,503 ms |
| Rakudo, Raku implementation | 8,415 ms | 2,402 ms |
| Rakudo, YAMLish 0.1.3 | 21,211 ms | 5,179 ms |

| 200 documents, 174 KB | `from-yaml(:all)` | `to-yaml` |
|---|---:|---:|
| **Raku++, extension** | **3 ms** | 237 ms |
| Raku++, Raku implementation | 3,021 ms | 242 ms |
| Rakudo, Raku implementation | 759 ms | 228 ms |
| Rakudo, YAMLish 0.1.3 | 1,955 ms | 500 ms |

Both parsers are linear in the input. The writer is the same Raku code in
every row but the last. YAMLish reads the corpus's merge keys as keys named
`<<` rather than merging them; the timings are for the same text all the
same.

## Examples

- `examples/config.raku` — a CI-style configuration: anchors and merge keys,
  a literal and a folded block, typed values, a stream of two documents read
  with `:all`, and an error message.
- `examples/roundtrip.raku` — data built in Raku, written as YAML, read back
  unchanged; and the error for a value YAML cannot hold.

## Scope

Left out of 0.0.1 on purpose:

- **Complex keys.** A mapping or a sequence used as a key is refused: a Raku
  `Hash` has string keys, and an object hash for the rare document that needs
  one would make every other mapping harder to use.
- **Custom tags.** Tags other than the core ones are read and ignored; there
  is no way yet to hand a tagged node to your own constructor.
- **YAML 1.1 types** beyond merge keys: `!!timestamp`, `!!binary`, `!!set`,
  `!!omap` are ignored like any other tag, and 1.1's booleans (`yes`, `on`)
  are strings, as in 1.2.
- **Nesting deeper than 128 levels** of collections is an error, so a hostile
  document cannot exhaust the stack.
- **Keeping the document's shape.** Comments, key order, quoting styles and
  flow or block layout are not kept; `to-yaml` writes its own layout. A
  style-preserving editor is a different module.
- **A streaming or event API.** Documents are read whole; `events` is for
  inspection, not for consuming a stream as it arrives.
- **A native writer.** Measured above: the writer's time is Raku's, spent
  deciding what each value is. See the design log.

## Requirements

Nothing, to work. For the fast path: Raku++, a C compiler, and Raku++'s
headers (`<prefix>/include/rakupp/rakupp_ext.h`; or `RAKUPP_SRC` pointing at
a checkout's `include/`). Without them the install still succeeds and the
module runs its Raku implementation.

## Compatibility

| engine | version | `t/01-parse.t` | `t/02-write.t` |
|---|---|---:|---:|
| Rakudo | v2026.08 | 148/148 | 89/89 |
| Raku++, extension | 4.0.1-160 | 370/370 | 91/91 |
| Raku++, `YAML_NATIVE_BACKEND=raku` | 4.0.1-160 | 148/148 | 89/89 |

Counts are from runs with `YAML_NATIVE_REQUIRE_BACKEND` set, as CI sets it.
The Raku++ counts are higher because every case runs through both
implementations there. Neither version is an established floor; the
extension needs a Raku++ with extension ABI 2 or later.

Engine differences worth knowing, all worked around here: on Raku++ an
`IO::Handle`, a `Proc` or a `Promise` smartmatches `Associative`, so a
serializer that asks `~~ Associative` would walk one as a mapping; and
Raku++ keeps decoded text uncomposed where Rakudo composes it, so two Raku++
strings with the same letters may not be `eq` — this module composes text
that holds a combining mark before reading it, on both paths.

## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.

---

Why the module is shaped this way, and what running it under two engines
turned up, is in [notes/YAML-Native.md](../notes/YAML-Native.md).
