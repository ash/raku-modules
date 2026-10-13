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
there.

Found later, and more serious: **a variable bound to a routine's native-int
result became a native-int slot.** After `$v := f()`, with f returning a
`my int` variable, every later `$v := …` was coerced to an integer — `[7, 8]`
became 2, `"s"` became 0. The Raku parser rebinds one variable per object
pair, so on Raku++ an object's values after its first number came back as
their own `.elems`; the suite had no such object and said nothing. The module
now assigns each value straight into its container, and the engine branch
drops a returned value's native tags (`native-return-value-is-not-a-
container.raku`). The cost of not looking: two Raku++ differential runs were
written off as "the engine's codec is wrong" before the minimal case showed
the Raku port was.

Also found: `return` from inside a `try` block costs 34 µs on Raku++ 5.3 (the
module's own from-json did it on every call), a Capture does Associative and
Positional there (it does neither in Rakudo), and JSON::Fast's own nom-comment
runs to a different position there; and cosmetically, a `Bool` pair inside a
`Map` is `.raku`'d as `:f(Bool::False)` where Rakudo writes `:!f`.

## Why the extension was faster than the engine's codec

It was not, in general. Per token type, on Raku++ 5.3.0:

| 200-850 KB of only | extension | engine codec before | engine codec after |
|---|---:|---:|---:|
| strings | 3.0 ms | 2.4 ms | 2.5 ms |
| true/false/null | 0.8 ms | 0.7 ms | 0.75 ms |
| integers | 3.3 ms | 18.0 ms | 1.1 ms |
| decimals | 9.0 ms | 65.5 ms | 3.4 ms |
| exponent forms | 2.1 ms | 60.4 ms | 2.0 ms |
| the mixed 316 KB document | 3.8 ms | 13.5 ms | 2.6 ms |

The whole gap was numbers. The codec typed every number token with
`numifyStr`, which is all of `Str.Numeric` — radix forms, `1/3`, `2*10**3`,
Unicode digits, and up to four `std::regex` matches per token. The fix, on the
`json-number-fastpath` branch of rakupp, types an integer or decimal of up to
18 digits, and any exponent form, with the constructors `numifyStr` itself
uses for them, and sends every other token to it unchanged; its regression
test runs each case through both and requires the same type, value and
`.raku`. A second pass built longer decimals the same way (the mixed
document's 19-digit ones still reached the regexes), reduced a decimal's
fraction in machine words instead of through BigInt's gcd and two divisions,
and moved values into their containers instead of copying a 392-byte Value
each time. Since then the codec is faster than the extension on every shape
of document.

The same branch makes the codec exact where it answers — NFC on the way in and
out, a comment running into the end of the text fails, a Capture is not
written — found by running it and the Raku port side by side over 27,000
random calls; and adds `rakupp-json-codec`, the codec as a routine with a
fallback built in, which is how JSON::Native exports it.

## The final shape (2026-10-13)

Two requirements, stated outright, decided it. **JSON::Native is a drop-in
for JSON::Fast** — swapping the `use` line keeps a program working, import
options and all. And **an engine loads only what it uses**: on Raku++ a `use
JSON::Native` reads no module file, compiled or cached.

So the C went, all of it. The NativeCall tokenizer needed a compiler at
install time, and it turned out not to be needed for speed:
`Rakudo::Internals::JSON` — the copy of JSON::Fast that Rakudo carries for
zef — parses exactly as JSON::Fast does (6,000 documents, accepted and
refused) at JSON::Fast's speed. Its *writer* is an older one and wrong outside
plain JSON data (a Set's keys unquoted, an enum written bare, an object as
`{"0":"null"}`), and 1.6-2x slower besides, so writing on Rakudo is
`JSON::Native::Rakudo`: JSON::Native::Raku's writer with the escape scan, the
buffer and the type tests in `nqp::` ops, faster than JSON::Fast on every
document measured once the scan was written as `nqp::while` (in ordinary
`while` and `<` it cost 1.5 µs a string). Raku++'s C extension went too: the
engine's codec had overtaken it everywhere.

Rakudo only ever sees the `nqp::` file through a runtime `require` behind
`$*RAKU.compiler.name eq 'rakudo'`, and a deliberately unparseable stand-in
proved Raku++ never opens it. On Raku++ the engine answers `use JSON::Native`
itself (the Data::Native mechanism, `dataNativeUse`), handing out the codec as
routines whose fallback is JSON::Native::Raku — and rakupp now carries its own
copy of that file as a *bundled* module, found only when nothing installed or
on `-I` provides one, so the answer needs nothing installed. The engine steps
aside when an installed JSON::Native is newer than the interface it claims
(0.1.0), when `-I` names one, or when `JSON_NATIVE_BACKEND` asks for another
path — the last being how this suite tests the distribution on Raku++.

That bundled copy is a second copy of `lib/JSON/Native/Raku.rakumod`, in
rakupp's `rakulib/JSON/Native/`. **The two must be kept equal**: change one,
copy it to the other, and bump the claimed interface version when the
surface changes.

## mutsu

mutsu answers `Rakudo::Internals::JSON` with its own Rust codec — 2.5 ms for
the mixed document — and it is not exact: large negative integers come back as
rounded Nums, and 619 of 6,000 parses differ from JSON::Fast. It also ships
JSON::Fast as a bundled "battery" and runs it fast (143 ms), so mutsu parses
and writes with that. Three mutsu faults turned up, each worked around in the
module and worth reporting upstream:

- `my int @a = $str.NFD` refuses to fill a native array from a Uni (`.list`
  works), and `.chrs` and `.join` do not compose (`a` and U+0301 stay two
  codepoints); the Raku implementation now says `.NFD.list` and `.NFC.Str`.
- A `qq//` holding both `\{` and a `{…}` interpolation does not parse, and a
  nested destructuring `my (($a, $b), $c) = …` is not unpacked: the tests no
  longer write either.
- **A runtime `require` imports what it loads into the program.** JSON::Native
  loading JSON::Fast at its first call put JSON::Fast's `from-json` over the
  one `use JSON::Native` had handed out, so every later call bypassed the
  module — which a benchmark caught only because the "raku" row ran at
  JSON::Fast's speed. mutsu now loads its JSON::Fast at `use` time, before
  JSON::Native's EXPORT runs, and JSON::Native::Raku exports nothing at all;
  `t/03-backends.t` checks the imported routine survives a fallback load.

The one interface gap left: a `CATCH` naming JSON::Fast's
`X::JSON::AdditionalContent`. Declaring that class globally would collide with
JSON::Fast whenever both are loaded (which on mutsu this module does itself),
and Rakudo and mutsu refuse a qualified name in a lexical export — Raku++
alone accepts it.

## The NativeCall backend on Rakudo (built, measured, removed)

Rakudo has no API for C to build a Raku value, which looked like the end of
it. Measured, it was not: building a 316 KB document's values in Raku, with no
parsing at all, costs 11 ms; the Raku parser's 118 ms was nearly all reading
characters. So C reads (one call, 0.5 ms) and writes two buffers — a tape of
tagged 64-bit words, one per value, and every decoded string NUL-separated —
and Raku decodes the strings with one `.decode.split` and walks the tape.

Things that mattered, in order:

- **The first benchmark measured JSON::Fast against itself.** `use JSON::Fast
  ()` still imports `from-json`; its EXPORT ignores an empty list. The numbers
  matched to the tenth of a millisecond, which is what gave it away.
- **`buf8.read-int64` is a third of what indexing a `Buf[int64]` costs** (61
  ns against 156), and a tag in the low four bits makes most values one word.
- **Strings, small integers and literals are made in the container's own
  loop**, not by a call per value: Rakudo's no-JIT arm64 build pays ~0.2 µs a
  call.
- **`Buf.decode` drops a leading U+FEFF** as a byte order mark, so a first
  string starting with one lost it: the buffer starts with a separator.
- **Exponent forms are `strtod`'s double.** That is right only while
  Rakudo's `.Numeric` gives the same double; it did on 60,015 forms, edge
  cases included, and `t/01-parse.t` keeps asking over 2,010 of them.

The result parsed the mixed document in 35.5 ms against JSON::Fast's 44.3,
decimals at a third of its time — and a 50-byte document in 12 µs against its
5, the per-call buffers and decode being most of a small call. It was removed
a day later, for the reasons in the next section; the `strtod` finding and
the tape design are kept here because a C tokenizer may be wanted again.

## Per-call cost

Large-document benchmarks hid the cost of a call entirely. On a 50-byte
document JSON::Native's from-json took 46 µs on Raku++ (JSON::Fast: 0.39) and
18 µs on Rakudo (4.6): a `return` out of a `try` block, 34 µs on Raku++, and a
`(-)` set difference to check the adverbs, 4.7 µs on Rakudo. Both are gone.
What was left on Raku++ was the Raku sub itself, 2 µs in front of a 0.4 µs
codec — hence `rakupp-json-codec`, and exporting the codec's routine.

## The tests

`t/01-parse.t` and `t/02-write.t` hold JSON::Fast's answers, generated by
JSON::Fast 0.21.0 on Rakudo 2026.09 and written into the files, and run every
case through both `JSON::Native` and `JSON::Native::Raku` — on Raku++ the
second is otherwise exercised only by the calls the native paths decline.
Parse results are compared by `.raku`, which sees itemisation that `eqv` does
not, with one spelling normalised (the Bool-pair difference above). Where
JSON::Fast is installed, `t/04-json-fast.t` asks it live over 600 random
documents; it skips itself on Raku++, where JSON::Fast's subs are the engine's
codec and the comparison would be the engine against itself. The suite runs
once per backend, chosen by `JSON_NATIVE_BACKEND` and confirmed by
`JSON_NATIVE_REQUIRE_BACKEND` — six runs on the two engines, nine with a
Raku++ build from before the engine changes beside one from after.
