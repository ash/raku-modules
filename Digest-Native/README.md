# Digest::Native

MD5, SHA-1, SHA-224/256/384/512 and HMAC over any of them — one distribution,
our C on Raku++, and the established native modules everywhere else.

```raku
use Digest::Native;

say sha256-hex('abc');              # ba7816bf8f01cfea414140de5dae2223…
say md5('abc').list;                # 144 1 80 152 60 210 79 176 …
say sha512-hex('/etc/hosts'.IO);    # a file is streamed, never slurped

say hmac-hex($key, $message, &sha256);
say digest-backend();               # 'native' on Raku++, 'Digest' elsewhere
```

The same file runs on every Raku. What differs is what answers.

## Why it exists

The ecosystem has native digests, but scattered. bduggan's
`Digest::SHA1::Native` and `Digest::SHA256::Native` are two separate installs
covering two algorithms; neither does MD5, SHA-512 or HMAC. `Digest`
(grondilu) covers all six in pure Raku. `Digest::HMAC` is pure Raku on every
engine. Nothing covers the family in one place.

On Raku++ the pure-Raku route is not a mild slowdown. Measured below: MD5 of
one megabyte is 317 MB/s here and 0.08 MB/s through `Digest::MD5` — about four
thousand times. That is the gap a script notices.

## What it exports

Fourteen functions and `digest-backend`. The names, signatures and return types
are the ecosystem's, so moving between this module and what it stands in for is
a one-line edit in either direction.

| | |
|---|---|
| `md5 sha1 sha224 sha256 sha384 sha512` | → `blob8`, as `Digest::SHA2` types them |
| `md5-hex … sha512-hex` | → lowercase `Str`, as bduggan and `OpenSSL::Digest` spell them |
| `hmac($key, $message, &hash, $blocksize?)` | → `Blob`, as `Digest::HMAC` has it |
| `hmac-hex(…)` | → `Str` |
| `digest-backend($algo?)` | → `Str` |

`use Digest::Native <sha256 sha256-hex>` imports a subset. The spelling is
`<…>`, not `:sha256` — Rakudo routes `:tag` through machinery a `sub EXPORT`
module has no part in.

### Where it is a superset

Each of these agrees with the reference on every input the reference accepts.

**Input types.** `Str` (as UTF-8), `Blob`/`Buf`, `IO::Path` and `IO::Handle`.
A `Supply` is not taken. An `IO::Path` is **streamed**: a 16 GB file costs
64 KB of memory, not 16 GB.

**HMAC block size.** `Digest::HMAC` defaults `$blocksize` to 64 for every hash,
so `hmac($k, $m, &sha512)` there is a non-standard MAC unless the caller
remembers to pass 128. Here `$blocksize` has no default: absent, and `&hash`
one of this module's own, the algorithm's real block length is used — 64 below
SHA-384, 128 at and above, which is what RFC 2104 says. Passed, it is honoured
exactly as written, so `hmac($k, $m, &sha512, 64)` still reproduces
`Digest::HMAC` bit for bit. Both cases are in the test suite.

**HMAC `Str` inputs are UTF-8**, where `Digest::HMAC` encodes them as ASCII.
Identical bytes for every input it accepts; works where it dies.

`&hash` may be any `Callable` — HMAC is two calls to it. The native path is
taken only for this module's own subs, recognised by identity; anything else
composes through `Digest::HMAC`, with `$blocksize` defaulting to 64 because a
foreign hash cannot be asked for its block length.

**Not supported, and they throw:** `:initial-hash` on `sha256`/`sha512` (a
`Digest::SHA2` internal that leaks through its signature), and SHA-3, RIPEMD
and the other `Digest` sub-modules. This covers `Digest::MD5`, `Digest::SHA1`,
`Digest::SHA2` and `Digest::HMAC` — the four with dependents.

## The backends

Three, in this order:

| | when | `digest-backend()` |
|---|---|---|
| the engine's built-ins | `Data::Native` has claimed the `digest` tag and this engine answers | `core` |
| our compiled extension | Raku++, with the C built at install | `native` |
| the ecosystem modules | everywhere else | `Digest` |

The third row is **composed** rather than a single distribution, so
`digest-backend` also takes an algorithm and names the exact one:

```raku
digest-backend('sha1')    # 'Digest::SHA1::Native'   (bduggan, C via NativeCall)
digest-backend('sha256')  # 'Digest::SHA256::Native' (bduggan, C via NativeCall)
digest-backend('md5')     # 'Digest::MD5'            (grondilu, pure Raku)
digest-backend('sha384')  # 'Digest::SHA2'           (grondilu, pure Raku)
digest-backend('hmac')    # 'Digest::HMAC'           (jjmerelo, pure Raku)
```

All four are hard dependencies, not probes — one fallback path, nothing extra
to test. `require` inside a module breaks the whole export on Rakudo, so a
plain `use` is the only idiom that works on both engines anyway.

Our C accelerates Raku++ and nothing else: the extension ABI is Raku++'s own.
That is a deliberate choice with a measurement behind it, recorded in
`NATIVE-MODULES-PLAN.md`.

## Measured

arm64 Mac (Darwin 24.6), Raku++ 3.25.0, Rakudo v2026.08, 2026-09-05. Throughput
over a 16 MB message; the per-call figures are a 43-byte message, which is where
the wrapper rather than the hash is what you are paying for.

| | Raku++, this module | Rakudo, the fallback | what the fallback is |
|---|---:|---:|---|
| md5 | **317 MB/s** | 0.05 MB/s | `Digest::MD5`, pure Raku |
| sha1 | **425 MB/s** | 394 MB/s | `Digest::SHA1::Native`, C |
| sha224 | **223 MB/s** | 0.04 MB/s | `Digest::SHA2`, pure Raku |
| sha256 | **237 MB/s** | 172 MB/s | `Digest::SHA256::Native`, C |
| sha384 | **348 MB/s** | 0.02 MB/s | `Digest::SHA2`, pure Raku |
| sha512 | **282 MB/s** | 0.02 MB/s | `Digest::SHA2`, pure Raku |

Two things that table is not allowed to imply:

- **SHA-1 is not a win over `Digest::SHA1::Native`.** bduggan's is Steve Reid's
  hand-unrolled implementation and reaches 452 MB/s on this box; ours reaches
  425. What this distribution offers for SHA-1 is that it is in the same
  install as the other five and as HMAC, not that it is faster.
- **The pure-Raku rows are the point, and they are not a fair fight.** MD5,
  SHA-224/384/512 and HMAC have no native ecosystem module at all short of
  `OpenSSL::Digest`, which drags in system OpenSSL. Those five rows are where
  a program stops waiting.

Per call, 43-byte message, Raku++: `sha256-hex` 5.3 µs, `hmac-hex` 18.0 µs. Of
the 5.3, about 1.6 is the extension call and the rest is Raku — one frame costs
0.9 µs and one `~~` smartmatch 1.7, which is why the hot path in the module is
written flat rather than as a chain of small subs.

## Correctness

`t/vectors/digest.vec` holds 156 vectors — RFC 1321, FIPS 180-4, RFC 2202 and
RFC 4231, plus block-boundary sizes at 63/64/65 and 127/128/129 bytes, a NUL
byte, non-UTF-8 bytes, and the million-byte message. Every one is run through
**both** the bare name and its `-hex` twin, on **both** engines, against the
expected bytes rather than against each other.

The file was generated from the system `openssl` and never from our own code
(`tools/gen-vectors.raku`), so it is an oracle this project did not compute.

It is also **shared on purpose**. The engine's own digest code, planned as
`src/Digest.{h,cpp}` in Raku++, is a separate implementation by design — see
`NATIVE-MODULES-PLAN.md`, "The architecture: independent C" — and one set of
inputs that neither side can weaken is the thing that keeps the two agreeing.
A fix on either side is not finished until the other has been checked against
this file.

## Building

The distribution ships C source, not a binary. `Build.rakumod` compiles it at
install time against Raku++'s extension ABI, and **fails quietly** if it
cannot: no compiler, no headers, or a different engine costs speed, never
function. A build hook that aborted the install would turn an optimisation into
a dependency.

From a checkout:

```bash
RAKUPP_SRC=/path/to/rakupp/include rakupp -e 'use Build:file<Build.rakumod>; Build.new.build($*CWD)'
rakupp -Ilib -e 'use Digest::Native; say digest-backend()'   # native
```

## The one thing worth reading the source for

`rk_str` is a `Str` constructor, not a byte pipe: it **decodes** the bytes it is
given as UTF-8, so handing it a raw digest does not round-trip — `md5('abc')`
came back eleven characters long, with `0xd2 0x4f` collapsed into one. The
extension ABI had no `Blob` to use instead.

**Extension ABI 3 adds `rk_blob`**, and the bare names now cross as a real
`Buf`. `src/digest.c` keeps the old path under `#if RAKUPP_EXT_ABI >= 3` —
each byte sent as the UTF-8 encoding of the codepoint of the same number, read
back with `.encode('latin-1')` — because the C is compiled at **install** time
against whatever Raku++ is on the machine, and an older one is a supported
state. Built against the newer header the module refuses a host that lacks
`rk_blob`, so the failure is a clean fall back rather than an undefined symbol
at the first call.

Both paths are pinned over all 256 byte values in `t/03-inputs.t`, because a
scheme like that is worth nothing if the edges are not checked. The cost here
was never the point — a 64-byte digest barely notices either way, and the
measured difference is 9.4 µs a call against 8.3. For
`Compress::Zlib::Native`, where the payload is the whole file, it was 46% of an
inflate.

## Status

0.0.1. Not published — see the repository's standing rule.
