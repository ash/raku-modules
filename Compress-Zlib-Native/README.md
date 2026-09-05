# Compress::Zlib::Native

gzip and zlib without libz — our own DEFLATE on Raku++, and `Compress::Zlib`
everywhere else.

```raku
use Compress::Zlib::Native;

my $z = compress($data);              # zlib framing, as the reference
say uncompress($z).decode;

my $g = compress($data, 9, :gzip);    # gzip framing — ours
my $r = compress($data, 6, :raw);     # bare deflate, for Content-Encoding

gzspurt('log.gz', $text);
say gzslurp('log.gz');

say crc32($data).fmt('%08x');
say zlib-backend();                   # 'native' or 'Compress::Zlib'
```

## Why it exists

`Compress::Zlib` is NativeCall over the system `libz`. That means the library
has to be there, with the ABI the bindings expect. This distribution carries
the *format* instead: RFC 1951 (deflate), RFC 1950 (the zlib wrapper) and
RFC 1952 (gzip), in C compiled at install time. It therefore works inside an
`--exe` binary and in the WASM playground, where there is no system library to
dlopen.

On Raku++ specifically it is also the difference between working and not for
the file wrappers: `Compress::Zlib`'s `gzslurp` and `gzspurt` go through a
`Wrap` class that calls `nqp::p6definite`, and die there. `compress` and
`uncompress` do work on Raku++ today, so this is a narrower gap than it once
was — but it is still a gap, and it is the one most programs hit first.

## What it exports

Seven names. Four are `Compress::Zlib`'s, with its signatures and defaults, so
swapping this module in or out is a one-line edit:

```raku
compress(Blob $data, Int $level = 6 --> Buf)     # $level outside -1..9 dies
uncompress(Blob $data --> Buf)
gzslurp($path, :$bin)
gzspurt($path, $stuff, :$bin)
```

Three are additive:

- **`:gzip` and `:raw`** on `compress` and `uncompress`. The reference reaches
  those framings only through its `Compress::Zlib::Stream` class, and raw
  deflate plus gzip are exactly what an HTTP `Content-Encoding` needs. The two
  adverbs are mutually exclusive, and a stream read with the wrong framing is
  an error rather than nonsense.
- **`crc32($data, $init = 0)`** and **`adler32($data, $init = 1)`**, which the
  reference does not offer at all. Both take a `Str` (as UTF-8) or a `Blob`,
  and the running value lets a stream be fed in pieces.
- **`zlib-backend()`** → `'core'`, `'native'` or `'Compress::Zlib'`.

**Not in this cut:** the `Compress::Zlib::Stream` class and `zwrap`. Streaming
inflate and deflate are a second phase; the one-shot subs are what the
dependents call.

## Measured

arm64 Mac (Darwin 24.6), Raku++ 3.25.0, Rakudo v2026.08, 2026-09-05. Two
megabytes of `/usr/share/dict/words`. The right-hand column is real zlib
through `Compress::Zlib`, which is what this module falls back to.

| | ours, on Raku++ | libz, on Rakudo |
|---|---:|---:|
| compressed size, level 1 | **633,171 B (31.7%)** | 727,508 B (36.4%) |
| compressed size, level 6 | 631,562 B (31.6%) | **608,612 B (30.4%)** |
| compressed size, level 9 | 631,438 B (31.6%) | **608,636 B (30.4%)** |
| compress, level 6 | 132 ms (14 MB/s) | **148 ms (12.9 MB/s)** |
| inflate | **16 ms (118 MB/s)** | 17 ms (112 MB/s) |
| crc32 | **8 ms (243 MB/s)** | 1,055 ms (2 MB/s) |

Read honestly:

- **Ratio is within about four per cent of libz** at level 6, and better than
  libz at level 1. That is closer than the plan expected, and it is what
  dynamic Huffman coding buys — the first cut of this file emitted fixed
  Huffman only and was 34% larger than libz on this same corpus.
- **Compression speed is comparable.** Levels 1, 6 and 9 barely differ in our
  output size, which says the matcher is not being pushed by the level knob;
  that is a tuning job nobody has done yet, not a claim.
- **Inflate reaches 118 MB/s**, which is level with libz. It was 65 until the
  extension ABI grew a way to hand bytes back — see the next section; nearly
  half the time was the transport, not the decoder.
- **`crc32` on the fallback is pure Raku and slow**, because `Compress::Zlib`
  has no crc32 to delegate to. Present and slow beats absent, and on Raku++ it
  is native anyway.

**None of this makes it faster than zlib**, and the point of the distribution
is not speed. It is that the format travels with the program.

## The transport, and the ABI change it prompted

The Raku++ extension ABI used to have no `Blob`, and `rk_str` **decodes** the
bytes it is handed as UTF-8 — so raw compressed bytes could not cross as
themselves. The workaround was to send each byte as the UTF-8 encoding of the
codepoint of the same number and read it back with `.encode('latin-1')`.

For the sister distribution, `Digest::Native`, that cost nothing: a digest is
at most 64 bytes. Here the payload is the whole file, and it was **15.8 ms of a
34 ms two-megabyte inflate — 46%, all of it transport rather than codec.**

**Extension ABI 3 adds `rk_blob`, `rk_blob_get` and `rk_is_blob`**, and the
workaround is gone: the C hands back a `Buf` and the Raku half returns it
untouched. Inflate went from 65 MB/s to 118 on the same input and the same
codec.

`src/zlib.c` still carries the old path under `#if RAKUPP_EXT_ABI >= 3`,
because the C is compiled at **install** time against whatever Raku++ is on the
machine and an older one is a supported state. Built against an older header
the module refuses to load into a host that lacks `rk_blob` — the handshake
turns what would be an undefined symbol at the first call into a clean fall
back to `Compress::Zlib`. The shim deletes itself when ABI 3 is the floor.

## Correctness

`t/vectors/zlib.vec` holds 67 vectors, every one of them produced by **real
libz or the system gzip**, never by us — because a codec that agreed only with
itself would pass a round-trip suite and still be useless. They cover:

- zlib, gzip and raw streams at three levels over eight corpora, each of which
  must inflate to exactly the bytes the other implementation compressed;
- a stream from the system `gzip -9`, which writes an `FNAME` field that libz's
  own stream never produces, so the header parser is exercised;
- eight **malformed** streams — bad magic, a corrupted header check, a flipped
  checksum, a truncated tail, an invalid block type, a stored block whose
  length and complement disagree — each of which must be refused;
- the published CRC-32 and Adler-32 check values.

Interoperability was checked in both directions over seven corpora: every
stream we produce is read by libz, and every stream libz produces is read by
us, byte for byte. The system `gunzip` reads our `.gz` files.

**Inflate is fuzzed.** It is the one component here that parses bytes somebody
else chose. `tools/fuzz-inflate.c` builds the same source under
AddressSanitizer and UndefinedBehaviorSanitizer and throws 360,000 random and
bit-flipped streams at it; the current run rejects 320,661, accepts 39,339, and
produces no sanitizer report.

```bash
cc -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -I$RAKUPP_SRC tools/fuzz-inflate.c -o /tmp/fuzz && /tmp/fuzz
```

Output growth is capped at 1 GB, so a small stream claiming an enormous
expansion fails rather than exhausting memory.

The vector file is **shared on purpose**. The engine's own zlib code, planned
as `src/DataZlib.{h,cpp}` (DATA-PLAN P4), will be a separate implementation by
design — see `NATIVE-MODULES-PLAN.md`, "The architecture: independent C" — and
one set of inputs neither side can weaken is what keeps them agreeing.

## Errors

On the native path a malformed stream names what was wrong with it: `zlib
header check failed`, `gzip CRC mismatch`, `distance points before the start of
the stream`. On the fallback the message is `Compress::Zlib`'s own `uncompress
data error`, because the fallback *is* `Compress::Zlib`. Both raise; only the
wording differs, and the test suite asserts the raising rather than the prose.

Checksums are verified in both directions, so a stream that decompresses to the
wrong bytes is an error and not a silent result.

## Known issue on Raku++

Raku++ leaks a module's own `use` imports into whatever imports that module.
Because this distribution depends on `Compress::Zlib`, that means
`Compress::Zlib::Raw`'s NativeCall declarations — including a `crc32(ulong,
CArray[int8], int32)` binding for libz — become visible in your program too,
and can shadow a `crc32` you imported from elsewhere. Ordinary use is
unaffected: this module's own exports win. Two assertions in `t/03-export.t`
are marked `todo` on Raku++ and point at it; Rakudo confines all of it
correctly.

## Building

The distribution ships C source, not a binary. `Build.rakumod` compiles it at
install time against Raku++'s extension ABI and **fails quietly** if it cannot:
no compiler, no headers, or a different engine costs the self-contained path,
never function.

Installing does **not** require libz. `Compress::Zlib::Raw` declares its
NativeCall subs lazily and only looks for the library on the first call, so
depending on it costs a Raku++ user nothing at install time — and on Raku++ the
fallback is not the path that runs.

From a checkout:

```bash
RAKUPP_SRC=/path/to/rakupp/include rakupp -e 'use Build:file<Build.rakumod>; Build.new.build($*CWD)'
rakupp -Ilib -e 'use Compress::Zlib::Native; say zlib-backend()'   # native
```

## Status

0.0.1. Not published — see the repository's standing rule.
