# Compress::Zlib::Native — design log

Why the module is shaped the way it is, and what running it on two engines
turned up. Kept outside `Compress-Zlib-Native/` on purpose: none of it is
documentation a user of the module needs, and nothing here ships in the
distribution.

The module's own [README](../Compress-Zlib-Native/README.md) says what it does.
This file says why. The plan it implements is
`docs/dev/plans/NATIVE-MODULES-PLAN.md` in the Raku++ repository.

## The premise it was planned on has partly expired

NATIVE-MODULES-PLAN and DATA-PLAN both say `Compress::Zlib` **self-fails** on
Raku++, taking `PDF`, `Image::PNG::Portable`, `Archive::SimpleZip`, `File::Zip`,
`Avro`, `SAT`, `Sitemap` and `pack6` with it, and that this family is therefore
"the only tag where Raku++ has no capability at all". Re-probed 2026-09-05
against `build-arm64/rakupp` 3.25.0, that is now only half true:

| | Raku++ 3.25.0 |
|---|---|
| `compress` / `uncompress` | **work** — 105,000 B to 303 B and back, byte-identical |
| `gzslurp` / `gzspurt` | **fail** — `Undefined routine 'nqp::p6definite'` inside `Compress::Zlib::Wrap::lines` |

So the capability gap is narrower than the plan assumed: the one-shot subs work
through NativeCall, and it is the file wrappers — which go through a `Wrap`
class built on `nqp` — that do not. The honest case for the distribution is
what is left after that:

- `gzslurp`/`gzspurt` work on Raku++;
- no system `libz` at run time, so the format travels into an `--exe` binary
  and into the WASM playground;
- `:gzip` and `:raw` framings, and `crc32`/`adler32`, which the reference does
  not expose as subs at all.

That is a real case, but it is not "the difference between working and not",
and the README says so rather than letting the plan's older framing stand.

## Fixed Huffman was not good enough

The first working encoder emitted LZ77 tokens straight into a **fixed** Huffman
block, which is the shape the plan sketched and about 200 lines. It
interoperated perfectly in both directions and produced output 34% larger than
libz on 200 KB of `/usr/share/dict/words`, and 52% larger on repetitive prose.

That is a visible cost for the module's main use — writing `.gz` files somebody
else will read and store — so dynamic Huffman went in after all: buffer the
tokens, count the symbol frequencies, build optimal code lengths under the
15-bit ceiling, RLE the length table, and emit whichever of stored, fixed or
dynamic is smallest by an **exact** bit count rather than a guess. About 250
more lines, and it changes the picture entirely:

| 2 MB of `/usr/share/dict/words` | fixed only | dynamic | libz level 6 |
|---|---:|---:|---:|
| compressed size | (34% over libz) | 631,562 B | 608,612 B |

Within 4% of libz, and *better* than libz at level 1. Emitting straight from
the matcher is what forces the fixed code — a dynamic block has to state its
code lengths before its data, and the lengths are not known until the data has
been seen — so buffering a block's worth of tokens at eight bytes each is what
buys the choice.

## Inflate was 46% ABI, and that is why ABI 3 exists

End to end, a two-megabyte inflate was 65 MB/s against libz's 112. Measured
separately, of the 34 ms that took, **15.8 ms was turning the result back into
a `Buf`** — the latin-1-over-UTF-8 transport described in
[the Digest::Native log](Digest-Native.md#1-rk_str-is-a-str-constructor-not-a-byte-pipe),
forced by the extension ABI having no `Blob`. The decoder itself was doing
about 107 MB/s, within 5% of libz.

That number is what settled it: the fix belonged in the ABI, not in the module.
**Extension ABI 3 adds `rk_blob`, `rk_blob_get` and `rk_is_blob`** — thirty
lines in `src/ExtApi.cpp`, because a Buf is already a `Str` carrying the bytes
with `hashKind` "Buf", so the only thing missing was the tag. Same input, same
codec, same `-O2`:

| | before | after |
|---|---:|---:|
| inflate, 2 MB | 65 MB/s | **118 MB/s** |
| compress, level 6 | 140 ms | 132 ms |

`rk_type` deliberately still reports `RK_OTHER` for a Buf. Changing what an
existing value answers would rewrite the behaviour of every extension already
written — JSON::Native's serializer reads `RK_OTHER` as "stringify it" and
would start seeing a type it has no branch for — so the new capability is a
predicate beside the enum, not a change to it.

The module keeps the old path under `#if RAKUPP_EXT_ABI >= 3` because its C is
compiled at **install** time against whatever Raku++ is on the machine. Built
against the newer header, `rakupp_ext_init` refuses a host below 3, so the
failure mode is a clean fall back to `Compress::Zlib` rather than an undefined
symbol aborting at the first call — verified in both directions.

## The fallback did not need re-framing by hand

`Compress::Zlib` only exports zlib-framed `compress`/`uncompress`, so the first
version of the fallback swapped wrappers by hand: strip the two-byte header and
four-byte Adler-32, wrap the deflate data in a gzip header, append CRC-32 and
ISIZE. Going the other way that does not work — libz's `uncompress` verifies
the Adler-32, and the Adler-32 of the *decompressed* data is not knowable
before decompressing it.

`Compress::Zlib::Stream` already has all three framings, as window-bits 15,
-15 and 31, which is exactly the `:gzip`/`:raw` distinction. Reaching for the
class the reference already ships beat re-deriving the wrappers, and it is
correct by construction. The default zlib path still goes through the
reference's own one-shot subs, so `compress($data)` on the fallback is
byte-for-byte what `Compress::Zlib::compress($data)` would have produced.

One visible consequence: the Stream class flushes with `Z_SYNC_FLUSH`, so on
the fallback a `:raw` stream can be *larger* than the default zlib one. A test
that asserted "raw is the smallest" failed on Rakudo for exactly that reason
and now compares `:raw` against `:gzip`, two streams made the same way.

## Fuzzing was not optional

Inflate is the only function in either of these distributions that parses bytes
somebody else chose. `tools/fuzz-inflate.c` includes `src/zlib.c` directly,
stubs the handful of `rk_*` functions the shim calls so nothing needs an
interpreter, and runs under AddressSanitizer and UndefinedBehaviorSanitizer:
200,000 random streams plus 160,000 bit-flipped and truncated valid ones.
Current run: 320,661 rejected, 39,339 accepted, no sanitizer report.

Output growth is capped at 1 GB, so a stream that claims an enormous expansion
fails on the cap rather than by trying to allocate it.

## What the two engines disagreed about

- **A module's `use` leaks into its importer on Raku++**, and here it does real
  damage rather than merely being untidy. `Compress::Zlib::Raw` declares a
  NativeCall `crc32(ulong, CArray[int8], int32)` binding for libz; on Raku++
  that declaration escapes this module and can land on top of a `crc32` the
  program imported from somewhere else, which then returns 0. Two assertions in
  `t/03-export.t` are `todo` for it. Ordinary use is unaffected — this module's
  own exports win — but it is the sharpest instance of the bug found so far.
- **Rakudo refuses to compile `compress('a Str')`** against a `Blob $data`
  signature, where Raku++ fails at run time. The test calls through a reference
  so the failure is a run-time one on both.
- **Error messages differ by backend, deliberately.** The native path names
  what was wrong (`zlib header check failed`, `gzip CRC mismatch`); the
  fallback reports `Compress::Zlib`'s own `uncompress data error`, because the
  fallback *is* `Compress::Zlib`. The suite asserts that a malformed stream
  raises, never which words it raises with — pinning somebody else's prose
  would be pinning the wrong thing.

## Decisions worth not re-litigating

- **No `libz`, and no dlopen.** That is the distribution, not an omission.
  `Compress::Zlib` is a hard `depends` for the fallback, but installing it does
  not require libz — its NativeCall subs resolve lazily — so a Raku++ user pays
  nothing for the dependency and never takes that path.
- **Checksums are verified on both backends.** A decompressor that cannot tell
  you it produced the wrong bytes is not one.
- **The vectors are somebody else's streams.** Compression is not a function —
  two correct deflaters differ — so what can be pinned is that a stream *libz
  or the system gzip produced* inflates to exactly what they compressed. A
  round-trip suite alone would pass for a codec that agreed only with itself.
- **`Compress::Zlib::Stream` and `zwrap` are not in this cut.** Streaming is a
  second phase; the one-shot subs are what the dependents call.

## Where it could still go faster

The decoder is bit-at-a-time canonical Huffman, in the shape of Mark Adler's
`puff.c`, because that is the shape RFC 1951 describes and correctness came
first. A table-driven decoder is the standard next step and would close most of
the remaining gap to libz — but the transport above is the larger number today,
so the ABI is the thing to fix first.

On the encoder side, levels 1, 6 and 9 barely differ in output size (633,171 /
631,562 / 631,438 B), which says the level knob is not reaching the matcher.
Lazy matching — the trick that gives zlib most of its remaining edge — is not
implemented at all. Neither is a claim anywhere; both are tuning nobody has
done.
