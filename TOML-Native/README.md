# TOML::Native

TOML v1.0.0 parsing and writing with a native fast path on **Raku++**, and
pure Raku everywhere else. No dependencies. The same program runs on both
engines.

> Version 0.0.1. The interface below is implemented and tested on both
> engines, and passes the whole TOML 1.0.0 part of the official `toml-test`
> suite; what it leaves out is under Scope.

```raku
use TOML::Native;

my %conf = from-toml(q:to/TOML/);
    title = "example"
    [owner]
    dob = 1979-05-27T07:32:00-08:00
    [[servers]]
    ip = "10.0.0.1"
    TOML
say %conf<owner><dob>.year;               # 1979 — a DateTime
say %conf<servers>[0]<ip>;                # 10.0.0.1

my %file = from-toml("config.toml".IO);   # a path or a handle works too

print to-toml({ a => 1, t => { b => [1.5e0, "x"] } });
# a = 1
#
# [t]
# b = [1.5, "x"]

say toml-backend();                       # 'native' or 'raku'
```

```bash
raku   -Ilib examples/config.raku
rakupp -Ilib examples/config.raku
```

## What it is

The XS pattern, as [CSV::Native](../CSV-Native) does it: the distribution
ships C source, the build step compiles it against Raku++'s extension ABI,
and the module uses the result if it is there. On Rakudo, or on a Raku++
without the headers or a compiler, the same parser runs as plain Raku from
the module file. A failed native build costs speed, never function.

There are two implementations of one specification, and the test suite holds
them to it: on Raku++ every case runs through both and must give the same
data and the same error message. The writer is Raku only, on both engines.

## Values

| TOML | Raku |
|---|---|
| string | `Str` |
| integer | `Int`, within int64 — anything outside is an error, as TOML requires |
| float | `Num`, including `inf`, `-inf` and `nan` |
| boolean | `Bool` |
| offset date-time | `DateTime`, with its `timezone` |
| local date-time | `TOML::Native::LocalDateTime` — a `DateTime` whose `Str` has no offset |
| local date | `Date` |
| local time | `TOML::Native::LocalTime` — `hour`, `minute`, `second`; `Str` gives the TOML form |
| table, inline table | `Hash` |
| array, array of tables | `Array` |

Fractional seconds survive, as an exact `Rat`, to the nanosecond; further
digits are truncated, which the specification allows. Hex, octal and binary
integers and underscores between digits are read as the numbers they are.
Key order is not kept — Rakudo randomises hash order anyway. A multi-line
string keeps its line breaks as LF, whatever line endings the file used.

## Errors

Every parse error is `TOML::Native: <what> at line N`, and the native and the
Raku implementation raise the same message for the same input. The semantic
errors name the key as written:

    TOML::Native: duplicate key 'fruit.color' at line 7
    TOML::Native: table 'fruit.apple' is defined twice at line 12
    TOML::Native: inline table 'point' cannot be extended at line 4
    TOML::Native: cannot append to static array 'fruits' at line 9
    TOML::Native: cannot reopen table 'apple' with a dotted key at line 15
    TOML::Native: integer out of range at line 3
    TOML::Native: unterminated multi-line string at line 20

A multi-line string or an array that never closes is reported at the line it
opened on. A file that is not UTF-8 is `TOML::Native: the document is not
valid UTF-8`.

## Reading

`from-toml($source)` takes a `Str`, an `IO::Path` or an `IO::Handle` and
returns a `Hash`. A leading byte-order mark is skipped; CRLF and LF line
endings are both accepted.

## Writing

`to-toml(%data)` returns a `Str`. The output is deterministic: keys are
sorted, so both engines, and every run under Rakudo, write the same text. In
each table come its plain keys, then its `[sub.tables]`, then its
`[[arrays.of.tables]]` — an array whose elements are all hashes is written
that way; any other array is written inline, a hash inside it as an inline
table. Keys are quoted only when they are not bare.

A `Num` always reads back as a float (`1.0`, `inf`, `nan`); a `Rat` is
written as a float too. Dates and times are written in TOML form, a
`LocalDateTime` without an offset. An undefined value is an error, since TOML
has no null, and so is an `Int` outside int64 or a value of any other type:

    TOML::Native: cannot write an undefined value for 'owner.email'

## Backends

| `toml-backend` | when |
|---|---|
| `native` | Raku++ with the compiled extension |
| `raku` | Rakudo, or Raku++ without the extension |

`TOML_NATIVE_BACKEND=raku` in the environment forces the Raku implementation
on a Raku++ that has the extension, to compare the two or to rule the native
path out of a suspected bug. The Raku parser is reachable as
`TOML::Native::parse-raku`; the test suite uses it.

## Conformance

The TOML 1.0.0 cases of [toml-test](https://github.com/toml-lang/toml-test)
(208 valid documents, 501 invalid ones), run by
[benchmarks/toml/conformance.raku](https://github.com/ash/raku-modules/tree/main/benchmarks/toml)
in the repository. A valid case passes when it decodes to what its JSON says;
it round-trips when `to-toml` writes it and `from-toml` reads the text back
the same. An invalid case passes when it is refused.

| engine, backend | valid | round trip | invalid |
|---|---:|---:|---:|
| Raku++, extension | 208/208 | 208/208 | 501/501 |
| Raku++, Raku implementation | 208/208 | 208/208 | 501/501 |
| Rakudo, Raku implementation | 208/208 | 208/208 | 501/501 |

On Raku++ with the extension the script also runs every case through the
Raku implementation: the same data for all 208 valid cases, the same error
message for all 492 invalid ones that are UTF-8 (the other nine never reach
a parser).

## Measured

Generated documents in the shape of a `Cargo.lock` — `[[package]]` entries
with strings, arrays spanning lines, and every hundredth one carrying a table
of dates, hex integers, inline tables and a multi-line string. Best of three,
2026-09-23, arm64 Mac, Rakudo v2026.08 and Raku++ 4.0.1. The corpora and the
scripts are under
[benchmarks/toml](https://github.com/ash/raku-modules/tree/main/benchmarks/toml),
outside the distribution.

| 10,000 packages, 2.0 MB | `from-toml` | `to-toml` |
|---|---:|---:|
| **Raku++, extension** | **18 ms** | 751 ms |
| Raku++, Raku implementation | 3,452 ms | 782 ms |
| Rakudo, Raku implementation | 1,973 ms | 1,155 ms |

| 1,000 packages, 202 KB | `from-toml` | `to-toml` |
|---|---:|---:|
| **Raku++, extension** | **1 ms** | 76 ms |
| Raku++, Raku implementation | 311 ms | 78 ms |
| Rakudo, Raku implementation | 163 ms | 117 ms |

Both parsers are linear in the input. The writer is the same Raku code in
every row.

## Examples

- `examples/config.raku` — a configuration document read into typed values:
  a `DateTime`, `Int`s, a `Num`, dates and local times in an array of tables,
  and an error message.
- `examples/roundtrip.raku` — data built in Raku, written as TOML, read back
  unchanged; and the error for an undefined value.

## Scope

Left out of 0.0.1 on purpose:

- **TOML 1.1.** Version 1.0.0 only: 1.1's newlines in inline tables,
  optional seconds and `\e` escape are errors here.
- **Leap seconds.** TOML allows a seconds field of 60; this module refuses
  it (`invalid time`), because `DateTime` accepts one only at a leap second
  in its own table, and a local time has no UTC to check. No toml-test case
  uses one.
- **Integers beyond int64.** TOML says a parser must refuse a value it cannot
  hold losslessly, and names int64; a Raku `Int` could hold more, but a file
  that relied on it would not be portable TOML.
- **Nesting deeper than 128 levels** of tables and arrays is an error, as
  toml-test's notes suggest, so a hostile document cannot exhaust the stack.
- **Keeping the document's shape.** Comments, key order and the choice
  between inline and standard tables are not kept; `to-toml` writes its own
  layout. A style-preserving editor is a different module.
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
| Rakudo | v2026.08 | 197/197 | 53/53 |
| Raku++, extension | 4.0.1 | 378/378 | 54/54 |
| Raku++, `TOML_NATIVE_BACKEND=raku` | 4.0.1 | 197/197 | 53/53 |

Counts are from runs with `TOML_NATIVE_REQUIRE_BACKEND` set, as CI sets it.
The Raku++ counts are higher because every case runs through both
implementations there. Neither version is an established floor; the
extension needs a Raku++ with extension ABI 2 or later.

Engine differences worth knowing, all worked around here: Rakudo's UTF-8
decoder drops a leading byte-order mark and Raku++'s keeps it; Raku++'s
`IO::Handle.slurp(:bin)` on a text-mode handle returns a `Str`; and on Rakudo
a string held eight bits wide — text decoded from UTF-8 or Latin-1, or a
literal in a precompiled module, once it is a few characters long — wrongly
`contains` a character above U+00FF whose low byte it holds:
`"ABCDEFGHIJ".encode.decode.contains("Ł")` is `True`.

## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.

---

Why the module is shaped this way, and what running it under two engines
turned up, is in [notes/TOML-Native.md](../notes/TOML-Native.md).
