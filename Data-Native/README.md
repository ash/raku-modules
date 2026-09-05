# Data::Native

One portable `use` line for whatever the engine does natively.

```raku
use Data::Native;

my %rec  = name => 'Ada', langs => <Raku C>, score => 9.5;
my $json = to-json(%rec);
say from-json($json)<langs>[1];      # C
say sha256-hex($json);
say json-backend();                  # what actually answered
```

**This file runs, unchanged, on every Raku.** What differs is what answers. On
an engine that supplies the primitives, every call above is that engine's own C
and nothing needs installing. Everywhere else the same calls go through the
established modules the ecosystem already agrees on.

```raku
use Data::Native;                    # everything
use Data::Native <json csv>;         # or name the tags
```

The spelling is `<json csv>`, **not** `:json` — Rakudo routes `:tag` through the
`is export(:tag)` machinery, which a `sub EXPORT` module has no part in.

## The five tags — 27 functions and 5 backend subs

| tag | names | reference interface |
|---|---|---|
| `json` | `from-json` `to-json` | `JSON::Fast` |
| `csv` | `from-csv` `to-csv` | `CSV::Native` — no usable reference existed |
| `digest` | `md5 sha1 sha224 sha256 sha384 sha512`, their `-hex` twins, `hmac` `hmac-hex` | `Digest` + `Digest::HMAC`, with bduggan's `-hex` spelling |
| `zlib` | `compress` `uncompress` `gzslurp` `gzspurt` `crc32` `adler32` | `Compress::Zlib` |
| `random` | `crypt_random_buf` `crypt_random` `crypt_random_uniform` | `Crypt::Random` |

Plus `json-backend` `csv-backend` `digest-backend` `zlib-backend`
`random-backend`, one per tag.

Every signature is the reference's, character for character. A program moves
between `use Data::Native <digest>` and `use Digest::Native` — or
`use Digest::SHA2; use Digest::HMAC;` — by editing one line, in either
direction, on either engine.

Where a tag is deliberately more than its reference, it is the same superset the
matching `**::Native` distribution documents: `:gzip` and `:raw` framings,
`crc32`/`adler32` as subs, HMAC's block size defaulting to the algorithm's real
one rather than 64, and `Str` inputs taken as UTF-8.

## What answers

Three backends, in this order, per name:

1. **the engine's own primitive** — `rakupp-<name>` and equivalents, if this
   engine supplies it. `*-backend()` reports `core`.
2. **the reference module** for that family. `*-backend()` reports its name.
3. **a stub that throws when called**, naming the tag, the missing module and
   the `zef install` line.

The third exists because a `sub EXPORT` that dies is swallowed by both engines
— Raku++ warns and continues, Rakudo says nothing at all — so failing at `use`
time is not available as a mechanism. **Every tag always exports every one of
its names**; a name with no implementation fails when it is *called*, with a
sentence that says what to do. That is better than failing at `use` anyway: it
does not punish a program that imports everything and calls only `from-json`.

A primitive is adopted only if it **answers the contract**, not merely if a
symbol of that name exists. That is not caution for its own sake:
`rakupp-sha1-hex` exists on Raku++ 3.25.0 today and returns UPPERCASE hex,
where every module in that family returns lowercase. Each name is checked once
at load against a known value — one hash of `"abc"`, one round trip, one check
string — and the return type is part of what is checked.

## Adopting the contract in another engine

`Data::Native` is a **contract**: a fixed list of names and signatures, one tag
per family, plus a probe. An engine adopts it in two steps and no more —

1. supply native subs for any subset of the names, under its own prefix,
   reachable by the runtime lookup `&::('…')` that every Raku compiles;
2. add that prefix to `@PREFIXES` in this file, one line.

Everything it does not supply keeps flowing to the reference modules. A partial
adoption is a valid adoption. The probe is by symbol and by behaviour, never by
`$*RAKU.compiler.name`, so a fork or a renamed build is not locked out by an
identity check.

## Cooperating with the ::Native distributions

`use Data::Native <digest>` and `use Digest::Native` export the same fourteen
names, and two modules exporting one name is a hard compile error on Rakudo. So
they cooperate through a process-global claim registry rather than colliding:
whichever loads second yields the contested names, and the program builds in
either order. All four cells are in `t/02-export.t`.

A claim is **per tag**, so `use Data::Native <csv>; use Digest::Native;` gives
you this module's CSV and `Digest::Native`'s digests, which is the point.

### The one rule that shapes the dependency list

**This module must not `use` anything that participates in the claim
protocol.** A `**::Native` module announces itself when its `EXPORT` puts names
into a scope; loading one from here runs that `EXPORT` into *this* file's scope,
and the announcement is then indistinguishable from one the caller made — so
this module would stand aside from its own names and export nothing at all.

There is no repair available from this side. Snapshotting the registry around
those `use`s needs `BEGIN`, and on Rakudo touching `PROCESS::` at compile time
inside a module that gets precompiled makes the precomp unserializable. Three
spellings were tried; all three fail identically.

So the dependencies here are the **reference** modules — the same ones each
`**::Native` distribution falls back to — and none of them has heard of the
registry. The cost is that the digest and zlib compositions appear twice, here
and in the distribution that owns each family; the conformance vectors in those
distributions are what keep the copies honest.

`CSV::Native` is the exception, because no reference exists for CSV. It uses
`is export` today and is therefore outside the protocol. **If it is ever
retrofitted onto the claim protocol, this file breaks for the `csv` tag** — and
the fix is to give CSV the same treatment as the others, not to add a guard
here.

## Status

0.0.1. Not published — see the repository's standing rule.

No engine implements the `rakupp-*` primitives yet, so `*-backend()` reports the
reference module everywhere today and the `core` row is untested against a real
implementation. That is the next piece of work; the plan is
`docs/dev/plans/DATA-PLAN.md` in the Raku++ repository.
