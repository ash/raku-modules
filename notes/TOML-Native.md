# TOML::Native — design log

Why the module is shaped the way it is, and what running it on two engines has
turned up. Kept outside `TOML-Native/` on purpose: none of it is documentation
a user of the module needs, and nothing here ships in the distribution.

The module's own [README](../TOML-Native/README.md) says what it does. This
file says why.

## Why it exists at all

TOML is the third tokenizer-shaped format in this repository, after JSON and
CSV, and the reasoning is theirs: a parser whose cost is the cost of
interpreting its own scanner is exactly what the Raku++ extension ABI is for.
The pattern is CSV::Native's, not JSON::Native's — ship C source, compile it
at install time, and carry a same-specification Raku implementation for every
other case — because there is no oracle module to fall back on and hold the
extension to. The extension parses a 2 MB document in 18 ms; the Raku
implementation takes two seconds under Rakudo.

## Two implementations, one specification, and an outside oracle

Unlike CSV, TOML has a real specification (v1.0.0) and an official
conformance suite, `toml-test`. So the module has three checks instead of
two:

- **golden values** in `t/01-parse.t`, taken from the specification's own
  examples and its rules one by one, run through whichever implementation
  answers;
- **parity**: on Raku++ with the extension, every case also goes through
  `parse-raku`, and the two must return `eqv` data or die with the same
  message;
- **conformance**: `benchmarks/toml/conformance.raku` runs the 709 TOML
  1.0.0 cases of toml-test under each engine and backend, round-trips every
  valid one through `to-toml`, and on Raku++ checks parity over the whole
  suite as well — 208 valid documents, 492 invalid ones that decode.

The suite lives outside the distribution because the README measures against
it, as the CSV corpora do. It is a copy of the 1.0.0 file list at one commit,
with its MIT licence, not a submodule: the numbers in the README are for
those files, and a submodule would move under them.

Two more checks were run during development and are recorded here rather
than kept as scripts. A mutation fuzzer (the toml-test documents with random
characters inserted, deleted and duplicated — quotes, brackets, CR, DEL,
combining marks, escapes) ran 23,000 documents through both implementations
on Raku++ and found one difference in data (composing text, below); after
the fix, 30,000 more and 20,000 generated from headers and dotted keys found
none, in data or in message. And 40,000 generated documents — 20,000 built
from headers, dotted keys, inline tables and arrays over three key names,
20,000 of the mutations — were checked for acceptance against Python 3.14's
`tomllib`: the only disagreement was an integer beyond int64, which
`tomllib` accepts and this module refuses on purpose.

## The interface

`from-toml` and `to-toml`, mirroring `from-json`/`to-json` and
`from-csv`/`to-csv`, and `toml-backend` as `csv-backend`. Decisions argued
for explicitly:

- **A local date-time is a `DateTime` subclass**, `LocalDateTime`, and not a
  `DateTime` in UTC. A plain `DateTime` would be right about the fields and
  wrong about the meaning — `1979-05-27T07:32:00` is 07:32 wherever the
  reader is, not 07:32 UTC — and would write back with a `Z` it never had.
  As a subclass it still does everything a `DateTime` does, and its `Str`
  has no offset. Subclassing `DateTime` works on both engines.
- **A local time is its own small class**, `LocalTime`: Raku has no time of
  day without a date, and a `Duration` or a number of seconds would lose the
  type on a round trip.
- **Fractional seconds are an exact `Rat`**, to nine digits. The parsers
  hand the digits to one Raku constructor, which truncates past nine (the
  specification allows truncation beyond what an implementation supports)
  because a longer decimal denominator overflows a `Rat` into a `Num` and
  the value would no longer be exact.
- **A seconds field of 60 is refused.** TOML allows a leap second anywhere
  the syntax does; Raku's `DateTime` accepts one only at 23:59:60 UTC on a
  date in its leap-second table (`2016-12-31T23:59:60Z` is accepted,
  `2017-01-15T23:59:60Z` dies on both engines, each with its own message),
  and a local date-time or local time has no UTC to check against. Accepting
  some leap seconds would make a document's validity depend on the engine's
  table; refusing all of them is a rule both implementations apply
  identically. No valid toml-test case has one.
- **Integers are int64.** The specification requires lossless int64 and
  permits refusing what does not fit; a Raku `Int` could hold more, but the
  file would not be portable TOML.
- **`-nan` is `NaN`**; Raku has no signed NaN. `-0.0` stays `-0e0`.
- **Nesting is limited to 128 levels** of containers, as toml-test's notes
  suggest, in both implementations and in the writer: the C tree is
  converted recursively, and the Raku parser recurses on nested values.
- **CRLF inside a multi-line string becomes LF**, in both implementations.
  The specification allows normalising, and it makes a document mean the same
  whichever line endings it was saved with — and whichever engine decoded
  it, since Rakudo's text decoding turns CRLF into LF and Raku++'s
  `Blob.decode` does not.

## Errors

Every message is `TOML::Native: <what> at line N`, with the key as written
for the semantic ones. **Lines only, no columns.** The C scanner works on
bytes and the Raku one on characters; a column both could agree on would
have to be counted in codepoints on one side and graphemes on the other,
and they differ on exactly the inputs (combining marks, CRLF) where a column
would matter. A line is counted the same way by both. A string or an array
that never closes is reported at the line it opened on, which is the line
to look at.

The semantic rules are the ones `tomli` (Python's `tomllib`) implements,
restated on a tree instead of on key paths: each table carries whether a
header defined it, whether it is closed (an inline table or a static array),
and the number of the section whose dotted keys created it. A dotted key may
extend a table its own section's dotted keys made, or one a header only
implied, and not one a header defined or an earlier section's dotted keys
made; a header may not name a table that a header or dotted keys defined.
Checking a pair happens after its value is parsed, as in `tomli`, and a
semantic error names the line of the key, not the line the value ended on.

## Why a hand-written parser, and not a grammar

A Raku `grammar` would be the idiomatic spelling and shorter. It was not
used because the two implementations must fail at the same place with the
same words, and a grammar fails as "no match" at a position the regex engine
chose; matching the C messages would mean a hand-written error pass on top of
it. The Raku parser is instead the C parser transcribed: the same functions,
the same order of checks, so that a change to one is visibly a change to the
other. There is a second reason, specific to Raku++: matching a regex at a
position in a long string (`.match($re, :p($pos))`) is quadratic there — a
scan of 25,000 short lines that way took 0.9 s under Rakudo and 521 s under
Raku++ (measured 2026-09-23). Filed.

## What the extension ABI shaped

- **A C tree, converted at the end.** The ABI has no lookup by key, and the
  per-table flags above have nowhere to live in a Raku `Hash`. So the
  document is parsed into nodes in an arena, with one open-addressing map
  keyed by (parent, key), and converted to `Hash`es and `Array`s bottom-up
  when the parse succeeds. An error longjmps to the entry point, which frees
  the arena and calls `rk_die`: only the extension's own frames are unwound.
- **Dates and times come back through `rk_call`.** The ABI cannot construct
  a `DateTime`, so the module has one small sub per type
  (`toml-native-datetime` and its siblings), found by name from the
  extension's call site — and the Raku parser calls the same ones. That is
  what makes the two implementations' results the same objects, down to the
  type of the second.
- **Text assembled from escapes is composed in Raku** (see below).
- **The extension asks for ABI 2**, the first with `rk_call`, and nothing
  newer, so it loads on any host from 2 on.

## The writer is Raku only

Decided, not deferred. A C writer would buy little and cost a second parity
surface:

- TOML documents are configuration; writing one is rare, and the 2 MB corpus
  that takes 0.8 s to write under Raku++ is far larger than any real
  configuration file; the 202 KB one takes 76 ms.
- The writer's time is spent deciding what each value is. Half the value
  types — `DateTime`, `Date`, `LocalDateTime`, `LocalTime`, `Rat` — are
  `RK_OTHER` to the ABI, and a C writer would call back into Raku for each
  of them anyway.
- The output must be deterministic across engines, so keys are sorted, and a
  C writer would have to sort exactly as Raku's `sort` does.

So there is one writer and nothing to agree with; its tests are golden text
and round trips, which on Raku++ read the text back through the extension.

## What two engines turned up

- **Rakudo: an eight-bit string "contains" characters it does not.** MoarVM
  stores a string whose characters all fit in a byte eight bits wide, and
  searching one for a character above U+00FF matches its low byte:
  `"ABCDEFGHIJ".encode.decode.contains("Ł")` is `True` (Ł is U+0141, and 0x41
  is `A`), as is `.index`, which answers 0. Shorter strings and strings built
  with `join` are stored wide and answer correctly; text decoded from UTF-8 or
  Latin-1, and string literals in a precompiled module, are not. The first
  Raku parser tested characters with `'ABC…xyz0123456789_-'.contains($ch)` —
  the cheapest test on both engines, measured — and under Rakudo, once the
  module was precompiled, accepted `Ł` as a bare-key character and reported an
  em dash in a comment as `control character U+2014`. The character classes
  are hashes now. Filed; a program can be right in a script and wrong in a
  module, on the same engine.
- **Raku++: text is not composed when it is decoded.**
  `Buf.new(0x65, 0x65, 0xCC, 0x81).decode` is `"eé"` with three codepoints
  where Rakudo has two, and it is `ne` to the literal `"eé"`; a Str built
  with `~` is composed, and `rk_str` behaves as `decode` does. So a string
  with an escaped combining mark (`"Rene\u0301"`) came out of the extension
  uncomposed and out of the Raku parser composed, and the two compared
  unequal — found by the mutation fuzzer, a combining mark that a trimmed
  line ending had joined to the letter before it. The extension now sends
  non-ASCII text it assembled (around an escape, across a trimmed line) to
  `toml-native-nfc`, which returns `.NFC.Str`; text cut straight from the
  source is left alone, as the Raku side leaves it. Filed.
- **Rakudo: `!%h{$k}:exists` dies at run time** with "Precedence issue with
  ! and :exists, perhaps you meant :!exists?" — Rakudo reads the adverb as
  applying to the `!`. Raku++ ran it as intended. The code says `:!exists`.
  Another program that runs on Raku++ and not on Rakudo.
- **Rakudo: a sub named `array` is not called.** Inside the parser,
  `my sub array(...)` followed by `array($depth)` made Rakudo resolve the
  call to the native `array` type ("array *must* be parameterized"); Raku++
  called the sub. It is `parse-array` now. Filed as a divergence.
- **The UTF-8 decoders disagree about a byte-order mark.** Rakudo's drops a
  leading one, Raku++'s keeps it: `Blob.new(0xEF, 0xBB, 0xBF,
  0x61).decode.chars` is 1 and 2. toml-test has a document with two marks,
  which must be refused; under Rakudo the parser only ever saw one. The
  module now puts back the mark the decoder dropped, deciding at load time
  whether this engine's decoder drops one.
- **Raku++: text-mode `IO::Path.slurp` accepts malformed UTF-8**, where
  Rakudo's throws; the nine toml-test documents in bad encodings were read
  without complaint. `slurp(:bin).decode` throws on both, so files are read
  that way.
- **Raku++: `IO::Handle.slurp(:bin)` on a handle opened for text returns a
  `Str`.** Taken as it is; the strict decoding then applies to paths only.
- **Raku++: a subnormal `Num` stringifies to fifteen digits**, not the
  shortest that reads back: `1e-310.Str` is `9.99999999999997e-311`, and
  `5e-324.Str` is `4.94065645841247e-324`. **Rakudo: `sprintf` cannot format
  one** — `sprintf("%.3e", 1e-310)` dies ("Directive %e not applicable for
  value of type Num") and `%.20g` gives `NaNe-310`. The writer needs the
  same text on both, so it searches for the shortest `%e` form with
  `sprintf` where `sprintf` works and uses `.Str` where it does not — which
  on Rakudo is already the shortest. Both filed.
- **Character classes and CRLF.** `"a\r\nb" ~~ /<[\x00..\x1F]>/` does not
  match under Rakudo and matches under Raku++. The writer's "does this string
  need escaping" regex asks about `"\r\n"` separately. The parser sidesteps
  CRLF entirely: the Raku implementation turns every CRLF into LF before
  scanning (invisible in the result and in every error, see above), so the
  scanner never meets the one character that is two codepoints.
- **Raku++: `DateTime.raku` prints like a hash**, `${:day(27), :hour(7),
  …}`, where Rakudo prints `DateTime.new(1979,5,27,…)`. Cosmetic; it made a
  debugging session confusing.

## Performance of the Raku implementation

The first complete version parsed the 2 MB corpus in 9.9 s under Raku++ and
3.0 s under Rakudo, linear but slow. What moved it, measured on that file:

- the character classes as hashes rather than chains of `eq` or `.ord`
  arithmetic, and the string scans stopping only at characters that matter;
- CRLF normalised before scanning, which removed a line-ending sub call from
  every character of every string;
- a fast path for strings without escapes and for comments: the positions of
  every quote, backslash and line feed are listed once with `split` (linear
  on both engines) and walked with a pointer each, used only in text with no
  control characters but tab and line feed, so every error still comes from
  the character loop;
- no `given`/`when` on the hot paths: a Rakudo profile showed a `THROW`, a
  control exception, entered once per call of every sub that used one;
- a one-pass path for plain decimal integers.

It now takes 3.5 s under Raku++ and 2.0 s under Rakudo. That is near the floor
for a per-character scanner in Raku on these engines: a skeleton that only
walks each line's characters through three small subs costs 6.6 µs per short
line (`key_1234 = 12345`) under Rakudo and 20 µs under Raku++. The writer went
from 2.1 s to 0.8 s under Raku++ (1.2 s under Rakudo) with the same
`given`/`when` removal, one regex deciding whether a string needs escaping,
and a per-document cache of quoted keys.

## Scope, and what comes next

Left out of 0.0.1, deliberately: TOML 1.1, leap seconds, integers beyond
int64, style-preserving editing, and a C writer — all argued for above or in
the README's Scope. The natural next step is TOML 1.1 behind an option
(`:v<1.1>`), once toml-test's 1.1 list is final. Streaming, the next step for
CSV, is not worth having for a configuration format.
