# JSON::Native — design log

Why the module is shaped the way it is, and what running it on two engines has
turned up. Kept outside `JSON-Native/` on purpose: none of it is documentation
a user of the module needs, and nothing here ships in the distribution.

The module's own [README](../JSON-Native/README.md) says what it does. This
file says why.

## Dropping JSON::Fast (2026-10-12)

Up to 0.0.3 JSON::Native depended on JSON::Fast and handed it everything the
native paths did not take: every call on Rakudo, and on Raku++ every adverb or
type the extension declined. That made JSON::Fast a hard dependency of a
module whose point is not needing it — and when JSON::Fast could not be
installed on this machine, `use JSON::Native` died at its `use JSON::Fast`
line on **both** engines, including a Raku++ whose extension and built-in
codec could have answered every call the program made.

Two ways out were on the table:

1. **A Raku++-only module** (`JSON::Native::RakuPP`) with no fallback at all.
   It reaches half the goal: a program that `use`s it cannot run on Rakudo,
   which is the one thing this repository's modules are not allowed to be.
2. **A pure-Raku implementation inside the distribution**, standing where
   JSON::Fast stood. This is the shape TOML::Native, YAML::Native, CSV::Native
   and Text::Diff::Native already have; JSON::Native was the odd one out.

The second, and the implementation is a module of its own,
`JSON::Native::Raku`. "Pure" was the first name and was dropped because it
reads as the opposite of "Native" in the same name; `::Raku` matches what
`toml-backend` already calls this path. It is loaded by a runtime `require`
the first time a call needs it, not by `use`, so a Raku++ program whose calls
the native paths answer never loads it — `t/03-backends.t` checks both halves
of that in fresh processes.

## The specification is JSON::Fast's, quirks included

The contract did not change when the dependency went: `from-json` returns what
JSON::Fast 0.21.0 returns and `to-json` writes what it writes, byte for byte.
`JSON::Native::Raku` is therefore a port of JSON::Fast's behaviour, read off
its source and then checked against it by a differential harness (random
values of every kind JSON::Fast has a rule for, written by JSON::Fast, parsed
by both; the same documents with a character deleted or a structural one
inserted). Three things in it are not obvious from JSON::Fast's documentation
and each was found by that harness, not by reading:

- **Two kinds of "what is at this position".** JSON::Fast tests some positions
  with `nqp::ordat`, which answers a grapheme's *base* codepoint, and others
  with `nqp::eqat`/`nqp::index`, which compare whole graphemes. They disagree
  on a grapheme carrying a combining mark: a quote with U+0301 on it opens a
  string (ordat) but does not close one (index). The port copies which test
  sits where rather than reasoning about it.
- **Escaping runs over NFD codepoints.** So U+1D15E, which decomposes, is
  written as two surrogate pairs, and a quote with a mark on it still has its
  quote escaped.
- **JSONC at the end of the text.** A `//` comment with no newline after it,
  or an unclosed `/*`, leaves JSON::Fast's position one past the end (for
  `//`, a `??`/`!!` that binds tighter than the `=` inside it), so after a
  document it reads as additional content and dies. The port reproduces the
  outcome. Raku++'s built-in codec does not, which is why `:allow-jsonc` is
  not sent to it.

What the port deliberately does not copy: the exception class.
`X::JSON::AdditionalContent` cannot be declared by two distributions, so this
one has `X::JSON::Native::AdditionalContent`, with the same attributes. And
one input JSON::Fast accepts and the port refuses: a pair of low surrogates,
which JSON::Fast turns into codepoint 0x110000 — a string no encoder can
write.

## A native path that raises hands the call over

The native paths used to stand aside only when they *declined* a call. They
now also stand aside when they *raise*: `from-json` catches the native
parser's exception and asks the Raku implementation. That cost nothing on the
success path and closed a class of divergence at once — the extension refuses
a raw CR or any other control character inside a string, as RFC 8259 says,
while JSON::Fast refuses only raw TAB and LF. Before, a document JSON::Fast
accepted died under JSON::Native on Raku++; now it is answered as JSON::Fast
answers it, and every refusal comes from one implementation with one set of
messages.

## Text that is not NFC

Raku++ builds a Str from UTF-8 without normalising it, and every Str Rakudo
hands back is NFC. So a string assembled around a `\u` escape — `"a\u0301"`,
or U+1D15E, which NFC splits — came back from the extension and from the
engine's codec looking right and comparing unequal to JSON::Fast's. The fix is
TOML::Native's (`tmp_keep` in its `toml.c`, found 2026-09-23): a string that
had a `\u` escape and holds non-ASCII is sent through a one-line Raku helper,
`json-native-nfc`, and the normalised bytes are kept. Only a `\u` escape can
need it — the short escapes stand for characters nothing composes with, and
the text between escapes is the source's own.

The engine codec got the same fix (below). For a Raku++ without it, the module
asks the codec once, at load, to decode `"a\u0301"`; where the answer is two
codepoints, a document with a `\u` in it goes to the Raku implementation.

## Making the Raku implementation fast enough on Rakudo

On Rakudo the Raku implementation is the only path, so it replaces JSON::Fast
there and its speed is the module's speed. The first working version was 4x
slower than JSON::Fast to parse and 3.6x to write; it ended 2.5x and 1.6x, on
a machine where MoarVM has no JIT (arm64). What the profiler showed, in order
of what it was worth:

- **`.substr($p, 1).ord` allocates a string per character**, where
  JSON::Fast's `nqp::ordat` allocates nothing. There is no plain-Raku spelling
  of ordat. A copy of the module using `nqp::ordat` was measured at 20% faster
  to parse and rejected: the module is plain Raku so that both engines run the
  same code.
- **`last`, and `return` from inside a loop, are control exceptions** when the
  loop body is a block of its own — one that declares anything. The hot loops
  (whitespace, digits) became `while` conditions with declarations hoisted
  out.
- **Numbers are built while they are scanned.** An integer or plain decimal of
  up to 18 ASCII digits is the Int or `Rat.new(n, 10**k)` that `.Numeric`
  would have made; everything else still goes through `.Numeric`, as
  JSON::Fast's does.
- **"Does this string need escaping" was a regex, ~5 µs a call on Rakudo**
  (0.75 µs on Raku++). The writer now remembers each string's escaped form for
  the length of one call — a document repeats its keys once per record — which
  halved the write time.
- **Strings are cut out with one `substr`**, and whether one holds a
  backslash, TAB or LF is answered from the position of the next one in the
  document, found once and reused. Strings ended up faster than JSON::Fast's.

## What Raku++ turned up

The first run of the Raku implementation on Raku++ took **108 seconds** to
parse 316 KB: `.index` from a position scanned from the start of the string
whenever the text was not ASCII, and the parser calls it once per string. That
was already fixed at HEAD (#154). Measured on 5.3.0-83 and still open, on a
300 KB non-ASCII string:

| operation | cost |
|---|---:|
| `.substr-eq('xx', $end)` | 4 ms per call — the whole string is copied |
| `.indices('x')`, 300,000 hits | 2.7 s |
| `.substr($end, 1)` | 4 µs, against 0.27 µs at the start |
| `.chars` | 3.9 µs per call |

The module avoids `.substr-eq` (a `substr` and an `eq` say the same thing) and
`.indices`; the other two are why the Raku implementation parses at 350 ms
there. Also found, both cosmetic for this module: a `Bool` pair inside a `Map`
is `.raku`'d as `:f(Bool::False)` where Rakudo writes `:!f`, and the engine's
JSON::Fast replacement writes a Capture as an array where JSON::Fast refuses
it.

## Why the extension was faster than the engine's codec

It was not, in general. Per token type, on Raku++ 5.3.0:

| 200-850 KB of only | extension | engine codec before | engine codec after |
|---|---:|---:|---:|
| strings | 3.1 ms | 2.4 ms | 2.4 ms |
| true/false/null | 0.9 ms | 0.7 ms | 0.7 ms |
| integers | 3.5 ms | 18.0 ms | 1.2 ms |
| decimals | 8.9 ms | 65.5 ms | 5.7 ms |
| exponent forms | 2.0 ms | 60.4 ms | 2.1 ms |
| the mixed 316 KB document | 4.1 ms | 13.5 ms | 5.3 ms |

The whole gap was numbers. The codec typed every number token with
`numifyStr`, which is all of `Str.Numeric` — radix forms, `1/3`, `2*10**3`,
Unicode digits, and up to four `std::regex` matches per token. The fix, on the
`json-number-fastpath` branch of rakupp, types an integer or decimal of up to
18 digits, and any exponent form, with the constructors `numifyStr` itself
uses for them, and sends every other token to it unchanged; its regression
test runs each case through both and requires the same type, value and
`.raku`. Since then the codec is as fast as the extension or faster on every
token type, and within 1.3x of it on the mixed document.

## The tests

`t/01-parse.t` and `t/02-write.t` hold JSON::Fast's answers, generated by
JSON::Fast 0.21.0 on Rakudo 2026.09 and written into the files, and run every
case through both `JSON::Native` and `JSON::Native::Raku` — on Raku++ the
second is otherwise exercised only by the calls the native paths decline.
Parse results are compared by `.raku`, which sees itemisation that `eqv` does
not, with one spelling normalised (the Bool-pair difference above). Where
JSON::Fast is installed, `t/04-json-fast.t` asks it live over 600 random
documents; it skips itself on Raku++, where JSON::Fast's subs are the engine's
codec and the comparison would be the engine against itself.
