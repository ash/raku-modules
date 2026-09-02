# CSV::Native — design log

Why the module is shaped the way it is, and what running it on two engines has
turned up. Kept outside `CSV-Native/` on purpose: none of it is documentation a
user of the module needs, and nothing here ships in the distribution.

The module's own [README](../CSV-Native/README.md) says what it does. This file
says why.

## Why it exists at all

The ecosystem's CSV module is `Text::CSV`, a port of Perl's `Text::CSV_XS` by
its own author. It is complete, and it is the wrong shape for the job in two
ways that matter here:

- **It depends on a slang.** `Text::CSV` requires `Slang::Tuxic`, which
  requires `Slangify`, which reaches into the compiler's grammar to let the
  module's source be written in its author's style (a space before an opening
  parenthesis). A CSV parser therefore pulls in a compiler extension as a
  runtime dependency, and cannot load on any engine that does not expose
  Rakudo's grammar internals — which is every engine that is not Rakudo.
  Raku++ parses the module (that took an engine fix of its own, see the
  project memory) and then cannot run it.
- **It is slow, and its speed is the tokenizer's.** On an 8.5 MB, 100,000-row
  corpus, `csv(in => $file)` takes 15 s under Rakudo v2026.08. Its per-field
  state machine is written in Raku, so that number is the cost of interpreting
  the tokenizer, not of anything CSV-specific.

CSV is a tokenizer-shaped problem, exactly as JSON is, and
[JSON::Native](JSON-Native.md) already established the pattern: ship C source,
compile it against Raku++'s extension ABI at install time, and keep a
same-specification Raku implementation for every other case. The one
difference from JSON::Native is what the fallback is.

## Two implementations, one specification — and no oracle

JSON::Native's fallback is `JSON::Fast`, and its tests use `JSON::Fast` as the
oracle: the contract is "returns what JSON::Fast returns". CSV::Native has no
such oracle. `Text::CSV` cannot be a test dependency (it would carry the slang
in), and its behaviour is not what this module promises anyway.

So the module states its own specification (the README's "The format"
section) and carries **two implementations of it**: `src/csv.c` and the
`parse-raku`/`write-raku` subs in the module file. The test suite is golden
values against the specification, run through whichever implementation is
answering — and on a Raku++ with the extension, every case is additionally run
through the Raku implementation and the two are required to agree, on rows,
on bytes and on error messages. That parity check is the test of the
extension: the Raku implementation is the readable one, the C one is the fast
one, and each keeps the other honest.

The corollary is that neither implementation ever "stands aside". JSON::Native's
C writer returns Nil for a type it does not know and lets `JSON::Fast` decide;
here there is nothing to defer to, so both implementations cover the whole
specification and an input outside it is an error in both, with the same
message.

## The interface

`from-csv` and `to-csv`, mirroring `from-json` and `to-json`. Not `Text::CSV`'s
`csv(in => ..., out => ...)` with its forty named options, and not an object
with `getline` — the Perl API's surface is its author's accumulated answer to
twenty years of requests, and a new module is not entitled to it. The option
names that are shared (`sep`, `quote`, `eol`, `headers`, `strict`) are spelled
the same on purpose, so someone switching does not have to relearn them.

Decisions argued for explicitly:

- **Fields are `Str`, always.** A CSV file carries no types. A parser that
  turned `007` into `7` or `1e3` into `1000e0` would be right often enough to
  be dangerous, and Raku's allomorphs (`<42>`) are a coercion away for anyone
  who wants them. Parked in Scope rather than refused forever.
- **Strict about quotes.** A quote inside an unquoted field is an error;
  anything after a closing quote other than a separator or a line ending is an
  error. RFC 4180 says so, `Text::CSV_XS` says so by default
  (`allow_loose_quotes` is off), and a parser that guessed would produce
  fields that look right and are not. Python's `csv` is lenient here; that is
  the one place this module chose the stricter reading, and every such error
  names its line.
- **Ragged records are allowed** unless `:strict` says otherwise — real files
  have them — but under `:headers` a record LONGER than the header is an
  error, because a hash has nowhere to put a nameless field, and dropping it
  silently is the worst option. A shorter record simply lacks those keys.
- **Duplicate header names are an error.** Two columns called `id` would
  make one silently overwrite the other in every record.
- **Line endings**: LF, CRLF and a lone CR all end a record, since files from
  every platform arrive; inside a quoted field they are content and kept as
  is. The writer's default is `"\n"`, not the RFC's CRLF — it is what `.lines`
  and every other Raku tool expect, and `:eol("\r\n")` is there for Excel.
- **Quoting on output is minimal**: a field is quoted when it holds the
  separator, the quote or a line ending, and otherwise not. `Text::CSV_XS`
  also quotes fields containing spaces (`quote_space`, on by default) — an
  inheritance from a time when readers were less careful, not something RFC
  4180 asks for. `:always-quote` exists for readers that want everything
  quoted.
- **Hash rows write their columns in sorted key order** unless `:headers`
  names them, because Rakudo randomises hash iteration per process and
  Raku++ does not, and a writer whose column order differed between engines
  would fail the whole premise of this repository. The order is decided in
  Raku before either writer runs, so both writers only ever see a list of
  names.
- **Options are validated once, in Raku, before either implementation is
  called.** A separator that contains the quote or a line ending has no
  reading; a quote of more than one character has no doubling rule. Both raw
  implementations additionally refuse an empty separator or quote themselves,
  because an empty needle matches at every position and a scan that never
  advances is a hang, not an error — found the hard way, when a parity test
  handed the raw Raku parser the empty separator that `from-csv` would have
  refused, and the suite sat for ten minutes.

## What the extension ABI shaped

- **Headers are resolved in Raku, projected in C.** The ABI walks a hash by
  index (`rk_key_at`, `rk_val_at`) and has no lookup by key, so writing hash
  rows in header order means placing each key by searching the header names.
  The writer tries the same index first — records of one file almost always
  carry their keys in one order — and falls back to a linear search, so a row
  costs O(columns) rather than O(columns²).
- **Parsing with `:headers` builds the hashes in C.** Converting arrays of
  fields into hashes in Raku afterwards would have put a per-record Raku loop
  back on the hot path, which is the thing the extension exists to remove.
- **Unquoted fields are never copied in C**: `rk_str` is handed a pointer into
  the source text and copies once into the arena. A quoted field is copied
  only when it holds a doubled quote, into one buffer shared by the whole
  parse — the lesson from json.c's per-string allocations, applied from the
  start.
- **Separators and quotes are byte sequences.** A multi-byte or multi-
  character separator (`→`, `::`) is a `memcmp`, and the parser's first-byte
  check keeps the common one-byte case to a single comparison per byte.

## What two engines turned up

- **CRLF is one grapheme.** In Raku `"a\r\nb".chars` is 3 and
  `"a\r\nb".index("\n")` is `Nil`, on both engines. The first draft of the
  Raku parser searched for `"\n"` and `"\r"` and could not see a Windows line
  ending at all; the Raku writer likewise did not quote a field containing
  one, and its output re-parsed as two records. The fix is a third needle,
  `"\r\n"`, in both the parser and the writer. The C implementation works on
  bytes and never had the problem — which is why the parity test caught it.
- **`csv-backend eq 'native'` is a listop call on Rakudo** (`csv-backend(eq
  'native')`, an undeclared routine); Raku++ parsed it as the comparison
  intended. The tests now spell it `csv-backend() eq 'native'`. Raku++ being
  lenient where Rakudo is not is worth knowing about: a program can run on
  Raku++ and fail to compile on Rakudo.
- **The single-argument rule.** Rakudo reads `[["a","b"]]` as `["a","b"]`
  and `[%h]` as a list of pairs; Raku++ keeps both nested. The tests carry a
  trailing comma in every one-row literal so they mean the same thing on both.
  This is an engine divergence and is filed as one.
- **`Str.index` with a start position is O(position) on Raku++.** Each call
  walks from the start of the string to the offset before it begins searching
  (about 1.3 ns per character), and `substr-eq` pays the same walk, while
  `substr` has an O(1) path. A scanner that advances with `index` — which is
  what the Raku parser is — is therefore quadratic under Raku++: 1,000 rows
  (78 KB) parse in 12 s, 2,000 in 48 s, 4,000 in 196 s, and the 8.5 MB corpus
  ran for more than eleven minutes before being stopped, against 1.8 s under
  Rakudo. The per-call cost is worse than the offset walk alone predicts, so
  more than one string primitive is paying it. The
  parser already keeps a memo of the next occurrence of each needle so that
  it never rescans for one it has already found; that makes it linear in
  `index` calls, and the remaining cost is the engine's. Filed as an engine
  task; until it lands, the Raku implementation on Raku++ is the correctness
  fallback the README says it is and not something to run on a large file.
- **`Str.indices` is not grapheme-aware on Raku++** while `Str.index` is: it
  finds a `"\n"` inside a `"\r\n"`. The parser counts line endings inside
  quoted fields with `comb` for that reason. Filed.
- **Text decoding turns CRLF into LF before the parser sees it** — on both
  engines for `IO::Path.slurp`, which is what `from-csv($path)` uses. So a
  CRLF file reads as LF text, a CRLF inside a quoted field arrives as LF,
  and the byte-for-byte round trip the README shows is in LF form. The
  parser itself preserves whatever it is given, and a `Str` built in memory
  with CRLF keeps it. Raku++ translates only in `IO::Path.slurp`:
  `IO::Handle.slurp` and `Blob.decode` keep the CR where Rakudo's translate
  in all three, so `from-csv($file.open)` differs between engines on the one
  record with a CRLF inside a field. Filed.
- **The mock file** (`t/mock-customers.csv`, 1,000 invented records) exists
  so that a whole file — CRLF, quoted commas, non-ASCII, multi-line fields
  together — is under test and in the README, not only hand-written cases.
  It was generated once with a seeded script and is pinned by t/03-mock-file.t;
  it is not a real dataset, which is the point.

## Measured

The numbers live in the README's tables and are re-measured when either
implementation changes. The shape of them, in one sentence: the extension
parses the 100,000-row corpus in about a tenth of a second, Rakudo's Raku
implementation in about two, and `Text::CSV` under Rakudo in fifteen.

## Scope, and what comes next

Left out of 0.0.1, deliberately:

- **Streaming.** `from-csv` reads a whole text into memory and returns the
  whole table. A lazy row iterator over a handle is the natural next feature
  for CSV — files are line-oriented and often large — and it needs a C-side
  parser state that outlives one call (a handle held as an Int, since the ABI's
  values do not survive a call). Designed for, not built.
- **Loose quotes** (`5" pipe,x`), an escape character other than doubling, and
  comment lines. All `Text::CSV_XS` options, all with real users, none in the
  RFC.
- **Typed fields.** See above; an opt-in allomorph mode is the likely shape.
- **A header-line switch when writing list rows** without names, and
  `:skip-empty-rows`. Small, and waiting for a request.
