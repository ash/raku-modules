# YAML::Native — design log

Why the module is shaped the way it is, and what running it on two engines
has turned up. Kept outside `YAML-Native/` on purpose: none of it is
documentation a user of the module needs, and nothing here ships in the
distribution.

The module's own [README](../YAML-Native/README.md) says what it does. This
file says why.

## Why it exists at all

YAML is the fourth tokenizer-shaped format here, after JSON, CSV and TOML,
and the most used of them for configuration: CI pipelines, Compose files,
Kubernetes manifests, Ansible, OpenAPI. The ecosystem's pure-Raku reader is
`YAMLish` (zef:leont, 0.1.3), a grammar. Measured on this repository's
corpus it reads 174 KB in about two seconds under Rakudo, and it refuses or
misreads things real files use: it cannot read a block scalar with an
indentation indicator (`script: |2`), so the first corpus it was given had to
lose one before YAMLish would read it at all; and it keeps a merge key as a
key named `<<` instead of merging, so a CI configuration built on anchors
comes back with its defaults missing. The other route, a NativeCall binding
to libyaml, needs a C library on the machine.

So the same pattern as TOML::Native: C source compiled against Raku++'s
extension ABI at install time, and a Raku implementation of the same parser
for every other case, with no dependencies.

## Two implementations, one specification, and an outside oracle

YAML has a specification (1.2.2) and an official test suite whose expected
output is not only data but the parse itself, as a stream of events
(`+MAP`, `=VAL :text`, `=ALI *a`, …). That decided the architecture before
anything else: both parsers build a node tree that keeps each node's style,
tag and anchor, and an alias stays an alias, so the tree can be printed back
as that event stream. `YAML::Native::events` is that printout. It makes every
case of the suite checkable — including the ninety-odd whose data JSON
cannot hold — and it gives the parity checks something finer than data to
compare. Four checks, then:

- **golden values** in `t/01-parse.t`, from the specification's rules, run
  through whichever implementation answers;
- **parity**: on Raku++ with the extension, every case also goes through
  `parse-raku` and `events-raku`, and the two must give `eqv` data, the same
  event stream, or the same error message;
- **conformance**: `benchmarks/yaml/conformance.raku` runs the 402 cases of
  the yaml-test-suite data release `data-2022-01-17` under each engine and
  backend: the events of every valid case against its `test.event`, the data
  against `in.json` where there is one, a round trip through `to-yaml` for
  every case that loads, and a refusal for every invalid one; and on Raku++
  the parity of the two implementations over all 402;
- **fuzzing**, run during development and recorded here rather than kept as
  scripts. A mutation fuzzer (the suite's documents with random insertions —
  indicators, tabs, quotes, CR, combining marks, escapes — deletions and
  duplications) ran 76,000 documents through both implementations on
  Raku++. It found the eight composition differences below; the 43,000 run
  after that fix found none, in events, data or message, and 25,000 of them
  ran against the final code. The C parser, linked against a stand-in host
  that implements the `rk_*` calls, ran 500,000 such documents under
  AddressSanitizer and UndefinedBehaviorSanitizer, through both entry
  points, without a report — the last 200,000 after the last change to the
  scanner. The writer ran 14,000 random nested documents — strings built
  from indicators, quotes, line breaks, controls, look-alikes of numbers and
  booleans — through `to-yaml` and back, on both engines and backends (6,000
  against the final code), and every one read back `eqv`.

The suite is a copy, not a submodule, for the reason toml-test is: the
numbers in the README are for those files.

## The architecture: libyaml's, not a grammar

A Raku `grammar` was ruled out for TOML because the two implementations must
fail at the same place with the same words; for YAML there is a second
reason. YAML's block structure is decided by indentation, and whether a
scalar is a mapping key is only known when the `:` after it is seen. The
libyaml design handles both in the scanner, and is known to scale to the
whole specification: an indentation stack that turns columns into
BLOCK-MAPPING-START and BLOCK-END tokens, and "simple keys" — a possible key
is remembered, and when its `:` arrives a KEY token is inserted back into the
token queue in front of it. None of libyaml's code is used; its design is,
with the YAML 1.2 changes libyaml never made (anchors named with any
non-space characters, `:` inside plain scalars in flow context, JSON-like
keys followed by an adjacent `:`, keys in flow mappings that span lines) and
fixes the suite asked for, each a few lines:

- **Tabs.** A tab may follow enough spaces of indentation but never be
  indentation, and never open a nested block collection: `-\t-` is not a
  nested sequence, `?\tkey:` not a nested mapping. The check sits where a new
  block collection is opened, which is exactly where the suite's cases
  (`Y79Y`, `DK95`) put the difference.
- **Flow and quoted continuation lines** must be indented further than the
  block they sit in, counted in spaces before any tab.
- **Block scalar indentation** is detected by looking ahead, not by
  consuming, and a leading empty line longer than the first content line is
  an error rather than a silent change of indentation.
- **The end of the input is a line break.** Two suite cases (`L24T/01`,
  `JEF9/02`) end without a final newline, inside a block scalar, and expect
  the last line to count as a line — a trailing break under keep chomping, a
  one-space content line under clip. Both parsers therefore read a text that
  does not end in a line break as if it did. It changes nothing else: a
  plain or quoted scalar does not see the break.

Then a recursive-descent parser over the tokens builds the tree, one per
document, and construction turns trees into Raku values. The parser's
recursion is bounded by the 128-level nesting limit, as the C scanner's flow
depth is.

The C and the Raku are one program in two spellings: the same functions in
the same order, the same messages. Where the Raku is written differently for
speed it says so and keeps the same effect — it copies runs of ordinary
characters with `substr` rather than one at a time, for instance, and the C
was changed to copy runs too so that the two stay recognisably the same
code. One structural change was made to both at once: `peek` returns the head
of the queue straight away unless a pending simple key could still insert a
KEY in front of it, instead of re-examining every simple key before every
token; whether a key has gone stale only changes as the scanner moves, and
the scanner re-examines then.

## The interface

`from-yaml`, `to-yaml` and `yaml-backend`, as the other modules name theirs,
and `from-yaml($text, :all)` for a stream of several documents. Decisions
argued for explicitly:

- **One document, or `:all`.** `from-yaml` returns the document, `Any` for
  an empty stream, and refuses a stream of several with a message that names
  `:all`. Returning the first document and dropping the rest would lose data
  without a word; returning a list always would make the common case clumsy.
- **The YAML 1.2 core schema**, not 1.1's: `yes`, `no`, `on`, `off`, `y`
  and `n` are strings, `010` is ten, `0o17` is octal, `1_000` is a string.
  This is the "Norway problem" answered the way YAML 1.2 answers it.
- **Keys are their text.** A Raku `Hash` has string keys, and a key such as
  `1`, `true` or `~` becomes `'1'`, `'true'` or `'~'` — as written, not
  resolved and stringified (`0x10` stays `'0x10'`, not `'16'`). A mapping or
  a sequence used as a key is refused: it has no text to be, and an object
  hash for the few documents that use one would make every other mapping
  harder to use. Sixteen of the suite's 308 valid cases are declined for
  this and for the next reason.
- **Duplicate keys are an error**, as the specification says they are. The
  suite does not test it — its expected output is the event stream, where a
  duplicate is not visible — and `2JQS`, two empty keys, is the one valid
  case that therefore does not load.
- **Merge keys (`<<`) are applied.** They are YAML 1.1, not 1.2, but they
  are what anchors are used for in real files, and a loader that leaves a
  `<<` key in the data is a loader those files cannot use. Explicit keys win
  over merged ones, and in a sequence of merged mappings the earlier wins, as
  the 1.1 type definition says. A quoted `'<<'` is an ordinary key.
- **An alias is the same object as its anchor**, on both backends and both
  engines: a change through one is seen through the other. That is YAML's
  meaning — one node, reached twice — and it costs nothing. Aliases may
  still add at most 1,000,000 nodes to a document, counted identically by
  both parsers, so a "billion laughs" document is refused rather than
  walked; the check is on the count, not on memory, because a consumer that
  copies or serialises the result would expand it.
- **Tags.** The core tags (`!!str`, `!!int`, `!!float`, `!!bool`,
  `!!null`, `!!map`, `!!seq`) are applied and override the style —
  `!!int "42"` is 42 — and a value that does not fit its tag is an error.
  The non-specific `!` makes a string. Any other tag is kept in the event
  stream and otherwise ignored; there is no hook for custom tags in 0.0.1.
- **Nesting is limited to 128 levels**, as in TOML::Native, in both parsers
  and in the writer.

## Errors

`YAML::Native: <what> at line N`, lines only, for TOML::Native's reason: the
C side counts characters of UTF-8 and the Raku side codepoints, and the two
agree on lines everywhere, but a column is only worth reporting if it is the
same on both. Where a message is about a key or an anchor it names it.

## Composition: why a combining mark costs a call

Raku strings are sequences of graphemes; the C side sees bytes. For almost
every document the two agree without help. They stop agreeing around a
combining mark — U+0301 after an `e` — because the engines treat
composition differently:

- Rakudo composes text when it decodes it, so the Raku parser there only
  ever sees `é` as one codepoint.
- Raku++ decodes without composing, and `rk_str` builds strings the same
  way, but a string built with `~` is composed; and two Raku++ strings with
  the same codepoints, one composed at construction and one not, are not
  `eq`.

So the Raku parser's strings, assembled with `~`, were composed where the
C's were not — whenever a scalar was assembled from pieces (an escape, an
escaped line break, a folded line) and whenever the source itself held an
uncomposed mark. The mutation fuzzer found both. The fix is in two places,
and costs nothing for text without combining marks:

- Both parsers look for a codepoint that might compose while they check the
  text's characters — a table of the combining ranges, the Indic and Hangul
  blocks, kana voicing marks; a superset on purpose — and if they find one,
  compose the whole text first (`.NFC` in Raku; in C, a call back to the
  module's `yaml-native-nfc`). On Rakudo this is a no-op, since its text is
  composed already.
- In C, a double-quoted scalar that used an escape and holds such a
  codepoint is composed again by the same call, since an escape can put a
  mark beside a letter; and the event text, where the escape `\n` before a
  mark composes into `\ń` on the Raku side, likewise.

The first attempt composed every text on the way in; on Raku++ that cost
1.2 s for 2.3 MB, twenty times the parse. Testing `chars == codes` first
cost 59 ms. The table costs nothing: the C side decodes every non-ASCII
character to check it anyway.

## The writer is Raku only

Decided, for TOML::Native's reasons: writing is the rare direction, and the
writer's time goes on deciding what each value is — which the ABI would send
back to Raku for half the types anyway. It writes block style throughout,
keys sorted, two spaces of indentation, a sequence under a key indented, a
mapping in a sequence compact (`- a: 1`); `{}` and `[]` only for empty
collections. A string is plain when it would read back as the same string —
not a core-schema null, boolean or number, no indicator first, no `: ` or
` #`, no edge spaces, nothing that needs escaping — a literal block when it
has line breaks and nothing to escape, with its chomping and, when its first
non-empty line starts with a space, its indentation indicator; double-quoted
otherwise. A key over 1,000 characters is written explicit (`? key`), since
an implicit key may be at most 1,024.

It was slow at first — 8.6 s for the 2,000-document corpus under Raku++ —
and the profile was all per-character work: a character loop deciding
whether a string could be plain, and `printable` per character. One regex for
the common identifier-like string, whole-string `contains` and a character
class for the rest, one classification per value instead of three type
checks, and a per-call cache of written keys brought it to 2.4 s on Raku++
and on Rakudo.

## What two engines turned up

- **Raku++: `%h{$n.s} = f(...)`, with `f` re-entering the same code, stores
  under the outer call's key.** Construction built a nested mapping and the
  inner mapping's keys came out as the outer's (`{top1 => {top1 => …}}`).
  A key computed into a variable first is stored right. Filed; the
  construction code carries the workaround and a comment.
- **Raku++: `(C-TAB) => "\t"` is the pair `"C-TAB" => "\t"`.** The
  parentheses that stop the fat arrow quoting its left side under Rakudo do
  not under Raku++, so the escape table was missing four escapes on the
  Raku side only — the parity check caught it on its first run. Filed; the
  table is assigned element by element.
- **Raku++: hash-backed objects smartmatch `Associative`, even `Map`.** An
  `IO::Handle`, a `Proc`, a `Promise`, a `Lock` — `to-yaml({ h => $*OUT })`
  wrote the handle's innards as a mapping. The writer asks `~~ Hash ||
  .isa(Map)`, which is right on both. Filed.
- **Rakudo: `constant CORE` is the `CORE` pseudo-package.** A constant of
  that name, for the core schema's tag prefix, compiled on both engines and
  on Rakudo meant the package, so every tag comparison failed. Raku++ let the
  constant shadow it. It is `YAML-CORE` now.
- **Rakudo: `%h{$s}:exists || …` does not parse** ("You can't adverb
  &infix:<||>"); Raku++ accepts it. Parenthesised.
- **Neither engine's regex sees what the other's does in a grapheme.** On
  Rakudo `"e\x[301]" ~~ /<[\x300..\x36F]>/` is false — the mark is part of
  the grapheme `é`; on Raku++ text decoded uncomposed matches. The design
  above leans on this: the combining check only has to be right where
  composition differs, which is Raku++.
- **The speeds are not the same shape.** On Raku++ a simple operation on a
  native integer costs 0.3–0.6 µs and a sub call about 1 µs; Rakudo is ten
  times faster at both, and slower than Raku++ at a regex scan of a whole
  text (0.33 s against 0.015 s for 1.6 MB). A validation loop over the
  characters was tried as a regex, which made Raku++ faster and Rakudo
  slower by more; the loop stayed, since Rakudo is where the Raku
  implementation is the main path.

## Performance of the Raku implementation

It reads the 1.7 MB corpus in 8.4 s under Rakudo, two and a half times the
speed of YAMLish there, and in 31 s under Raku++, where the extension takes
51 ms. Measured under Raku++, scanning is 50 µs a token — about a hundred
interpreted operations each — and parsing another 20; the profile has no
single hot spot left to take. The cheap wins were taken: codepoints padded
with zeros so a read needs no bounds check, inlined predicates in the plain
scalar's loop, `peek` without the key re-examination, rare compaction of the
token queue. The faster tools for this on other engines — a regex anchored at
a position, `index` from a position — are quadratic on Raku++ (see
notes/TOML-Native.md), so a faster Raku scanner there waits on the engine.

## Scope, and what comes next

Left out of 0.0.1, deliberately: complex keys, custom tag handlers, YAML 1.1
types beyond merge keys (`!!timestamp`, `!!binary`, `!!set`, `!!omap`),
style-preserving editing, a streaming or event API, and a C writer. The
natural next step is a `:tags` option taking handlers for local tags — the
event tree already carries them — and after it `!!binary` as a `Blob`,
which ABI 3's `rk_blob` makes possible without a call back into Raku.
