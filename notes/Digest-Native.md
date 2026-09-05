# Digest::Native — design log

Why the module is shaped the way it is, and what running it on two engines
turned up. Kept outside `Digest-Native/` on purpose: none of it is
documentation a user of the module needs, and nothing here ships in the
distribution.

The module's own [README](../Digest-Native/README.md) says what it does. This
file says why. The plan it implements is `docs/dev/plans/NATIVE-MODULES-PLAN.md`
in the Raku++ repository.

## Why it exists at all

The ecosystem has native digests, but no single place to get them:

| | covers | how |
|---|---|---|
| `Digest::SHA1::Native` (bduggan) | SHA-1 | C via NativeCall |
| `Digest::SHA256::Native` (bduggan) | SHA-256 | C via NativeCall |
| `Digest` (grondilu) | MD5, SHA-1, SHA-2, SHA-3, RIPEMD | pure Raku |
| `Digest::HMAC` (jjmerelo) | HMAC over any of them | pure Raku |
| `OpenSSL::Digest` | all of them | drags in system OpenSSL |

So MD5, SHA-224, SHA-384, SHA-512 and HMAC have no native option short of
OpenSSL, and the two that do are separate installs. On Raku++ the pure-Raku
route is not a mild penalty: MD5 of a megabyte runs at 0.08 MB/s there against
317 MB/s for the C in this distribution — about four thousand times.

The distribution is therefore one install covering all six plus HMAC, with the
ecosystem's own names and return types, so it can be swapped in or out by
editing one line.

## The three things that were not obvious

### 1. `rk_str` is a Str constructor, not a byte pipe

The extension ABI has no `Blob`. The obvious reading of that is "so bytes have
to be hex or an array of Ints", and the obvious reading is wrong in both
directions.

**Inbound it is already solved and undocumented:** `rk_str_get` on a `Buf` or
`blob8` hands back the raw bytes (the value reports as `RK_OTHER`), and on a
`Str` the UTF-8 encoding of its text. Both are exactly the bytes a hash wants,
so one accessor covers every input the module takes and neither common type is
converted at all.

**Outbound it bites.** `rk_str` takes a byte buffer, but the host *decodes*
those bytes as UTF-8 to build the `Str`. Handing it a raw digest does not round
trip — `md5('abc')` came back eleven characters long, with `0xd2 0x4f`
collapsed and `0xe1 0x7f 0x72` rewritten, because that is what decoding those
bytes as text means. An early probe missed this: the bytes it happened to test
(`00 01 41 ff 80`) are all invalid UTF-8 lead or continuation bytes, so they
survived by luck.

The first fix was to send each byte as the UTF-8 encoding of the **codepoint**
of the same number — latin-1 written as UTF-8 — and read it back with
`.encode('latin-1')`. All 256 values are pinned in `t/03-inputs.t`, because a
scheme like that is worth nothing if the edges are not checked.

That costs a 64-byte digest almost nothing. It cost
[Compress::Zlib::Native](Compress-Zlib-Native.md) **46% of a two-megabyte
inflate**, and that number is what moved the fix into the engine:
**extension ABI 3 adds `rk_blob`, `rk_blob_get` and `rk_is_blob`.** A Buf is
already a `Str` carrying the bytes with `hashKind` "Buf", so the whole
implementation is thirty lines in `src/ExtApi.cpp` — the only thing that was
missing was the tag.

Both distributions keep the shim under `#if RAKUPP_EXT_ABI >= 3`, because their
C is compiled at **install** time against whatever Raku++ is on the machine.
Built against the newer header, `rakupp_ext_init` refuses a host below 3, so an
older engine gets a clean fall back rather than an undefined symbol aborting at
the first call. Here the win is small and real — 9.4 µs a call against 8.3 —
and the shim deletes itself when ABI 3 is the floor.

### 2. A core primitive must be probed FUNCTIONALLY, not by name

DATA-PLAN spells the engine's built-ins `rakupp-<function>`, so the obvious
probe is `try &::("rakupp-$name")`. That is not enough, and it is not
hypothetical: **`rakupp-sha1-hex` exists on Raku++ 3.25.0 today and returns
UPPERCASE hex**, where bduggan's modules, `OpenSSL::Digest` and this one all
return lowercase. A by-existence probe would have silently changed the module's
answers the day it ran on that engine.

So the module carries one known vector per name and checks it once at load,
comparing the digest **and** the return type exactly — lowercasing the answer
before comparing is precisely how the uppercase primitive would have slipped
through. Today one primitive exists and it fails the check, which is the right
outcome.

### 3. The Raku wrapper cost more than the hash

First working version: `sha256-hex` of a 43-byte string took **10.2 µs**, of
which about 1.6 was the extension call. Measured on this box, Raku++ 3.25.0:

| | cost |
|---|---:|
| raw extension call | 1.59 µs |
| + one Raku frame | 2.45 µs |
| + a `*%opt` slurpy | 2.76 µs |
| + two `~~` smartmatches | 6.21 µs |

A frame is 0.9 µs and a smartmatch is 1.7. The polite version — an adverb
check, a dispatcher, a type predicate, each its own small sub — was four frames
and three smartmatches around two microseconds of C. Inlining the common case
(a `Str` or `Blob`, no adverbs) into the exported sub took it to **5.3 µs**;
everything unusual still goes to the helpers and pays a frame there, where
nothing is counting.

The general lesson for this family of modules: the wrapper is the cost, and it
is worth measuring before it is worth writing prettily.

## What the two engines disagreed about

- **A module's `use` leaks into its importer on Raku++.** From a block, from
  file scope, from inside a sub alike; Rakudo confines all three. So
  `use Digest::Native <sha256-hex>` on Raku++ also gives you `md5`, `sha1` and
  the rest, supplied by the fallback distributions this module delegates to.
  One assertion in `t/04-export.t` is `todo` on Raku++ for it. Filed as an
  engine bug with a three-case repro.
- **`blob8.new(…).^name`** is `Blob` on Raku++ and `Blob[uint8]` on Rakudo, so
  nothing asserts `.^name`; the tests compare `.list`.
- **Two modules exporting one name** is a hard compile error on Rakudo and
  silently last-wins on Raku++, which is why the cooperation protocol with
  `Data::Native` exists at all rather than being a nicety.

## Decisions worth not re-litigating

- **The fallbacks are hard `depends`, not probes.** `require` inside a module
  breaks the whole export on Rakudo, so a plain `use` at file scope is the only
  idiom that works on both engines. One fallback path, nothing extra to test.
  This is the `JSON::Fast` pattern from `JSON::Native`.
- **Each fallback is `use`d in its own block.** `Digest::SHA1` and
  `Digest::SHA1::Native` both export `&sha1`; importing them side by side is a
  compile error on Rakudo.
- **HMAC's `$blocksize` has no default.** `Digest::HMAC` defaults every hash to
  64, which makes `hmac($k, $m, &sha512)` a non-standard MAC. Absent, this
  module uses the algorithm's real block length (RFC 2104); passed, it is
  honoured as written, so `hmac($k, $m, &sha512, 64)` still reproduces
  `Digest::HMAC` bit for bit. Both are asserted.
- **The vectors come from `openssl`, never from us.** An oracle this project
  computed would not be one. `tools/gen-vectors.raku` regenerates the file.
- **The vector file is shared on purpose.** The engine's own digest code
  (DATA-PLAN P3) will be a separate implementation by design; one set of inputs
  neither side can weaken is what keeps them agreeing.

## Where the C could still go faster

SHA-1 reaches 425 MB/s here against 452 for bduggan's `Digest::SHA1::Native`,
which is Steve Reid's fully unrolled implementation. Closing that last 6% would
mean unrolling all eighty rounds rather than five at a time, and the module's
claim for SHA-1 is that it is in the same install as the other five, not that
it is faster. The three shapes that did matter, and their measured effect at
16 MB:

| | before | after |
|---|---:|---:|
| four unrollable loops instead of one branch chain (MD5) | 170 MB/s | 268 |
| a rolling 16-word schedule instead of `w[80]` (SHA-1) | 166 | 314 |
| five-round unrolling so the variable rotation disappears (SHA-1) | 314 | 425 |

Getting there cost one classic C mistake worth recording: a multi-statement
macro used as a brace-less loop body runs only its first line per iteration.
MD5 reported a very convincing 965 MB/s that way, and every vector failed.
