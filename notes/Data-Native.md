# Data::Native — design log

Why the module is shaped the way it is, and what running it on two engines
turned up. Kept outside `Data-Native/` on purpose: none of it is documentation
a user of the module needs.

The module's own [README](../Data-Native/README.md) says what it does. This file
says why. The plan it implements is `docs/dev/plans/DATA-PLAN.md` in the Raku++
repository — and this file records the two places the implementation had to
depart from it.

## Departure 1: the dependency list is the references, not our own modules

DATA-PLAN says this module's fallback is "the four `**::Native` modules, plus
`Crypt::Random`". It cannot be, and the reason is worth writing down because it
is not obvious and it took three attempts to establish.

A `**::Native` module announces itself in the process-global claim registry when
its `EXPORT` puts names into a scope. `use`ing one from here runs that `EXPORT`
**into this file's scope**, and the announcement is then indistinguishable from
one the caller made. This module reads the registry to decide whether to stand
aside — so it would stand aside from every tag, and `use Data::Native` would
export nothing at all.

Three repairs were tried and all three fail:

1. **Snapshot the registry before the `use`s and restore it after.** Needs
   `BEGIN`, and on Rakudo touching `PROCESS::` at compile time inside a module
   that gets precompiled makes the precomp unserializable:
   `Missing serialize REPR function for REPR VMException`.
2. **A guard module `use`d before and after**, setting a flag from its own
   `EXPORT`. Same failure — `sub EXPORT` also runs at compile time.
3. **Clear the tags at module-body time.** Correct on Raku++, wrong on Rakudo:
   it would also erase a genuine announcement the caller made, and the caller's
   `use` always precedes this one, so the two cannot be told apart.

The information needed — *whose scope did that announcement land in* — is not
observable from inside `sub EXPORT` on either engine.

So the dependencies are the **reference** modules, which have never heard of the
registry. The cost is that the digest and zlib compositions appear twice, here
and in the distribution that owns each family. The conformance vectors in those
distributions are what keep the copies honest, and the duplication is about
sixty lines.

**CSV was the awkward one, and the fix generalises.** No reference exists for
CSV — that distribution *is* the reference — so this has to depend on our own
module, which is now on the claim protocol like the others. The way out is that
`need` runs no `sub EXPORT` at all, on either engine: `CSV::Native` was split
into `CSV::Native::Core`, a plain `unit module` with `our` subs and no export
protocol, and a thin `CSV::Native` that does the importing and the cooperating.
This module does `need CSV::Native::Core` and calls the full names, so nothing
announces anything.

That is the general pattern for any family where our own module is the
reference: put the implementation in a package with no export protocol, and let
the importable face be a separate, thin file.

## Departure 2: `:initial-hash` is passed through, on one path

DATA-PLAN says `:initial-hash` must throw. It does, for a user. But
`Digest::SHA2`'s own `sha224` calls `sha256(…, :initial-hash(…))` internally,
and on Raku++ that call can land on **this module's** `sha256` instead of
SHA2's own, because a module's imports are visible far beyond the module. The
result was that `sha224-hex('abc')` died with *"Data::Native: sha256 takes no
named arguments"* — this module rejecting an adverb it was never handed by the
program.

The wrapper therefore passes `:initial-hash` back to `Digest::SHA2`'s own sub
when it sees it. On Rakudo the branch never runs. It goes away when the engine
stops leaking imports, or when the tag has native primitives — whichever comes
first.

## The bug this module found in all four of its siblings

`Data::Native` was the first thing to `use` `JSON::Native`, `CSV::Native`,
`Digest::Native` or `Compress::Zlib::Native` **from another module**, and all
four failed:

```
===SORRY!=== Missing serialize REPR function for REPR VMException (BOOTException)
```

Two lines reproduce it:

```raku
# lib/Data/N7.rakumod
my &ext-load = try &::('rakupp-ext-load');
sub EXPORT(*@) { Map.new('&z' => sub { 'z' }) }

# lib/Data/N8.rakumod
{ use Data::N7; }
sub EXPORT(*@) { Map.new('&y' => sub { 'y' }) }
```

`raku -Ilib -e 'use Data::N8'` fails; `raku -Ilib -e 'use Data::N7'` is fine.
A module-scope `try` leaves the caught exception in that file's `$!`, and when
another module `use`s it, precompiling the importer walks that state and dies.
A program importing it directly precompiles nothing, which is why every suite
passed and the bug sat there.

**A `do {}` block is not enough — `$!` is scoped to the routine, so the `try`
has to be inside a `sub`.** All four modules now have:

```raku
sub probe-symbol(Str $name) {
    my $c = try &::($name);
    $c ~~ Callable ?? $c !! Nil
}
my &ext-load = probe-symbol('rakupp-ext-load');
```

That is what makes them composable at all.

## What the two engines disagreed about

- **When a module's dependencies load.** On Rakudo a module's `use` runs at
  *precompilation*, in another process, so its effects are invisible at run
  time. On Raku++ it runs in this process, at compile time, before the module
  body. That asymmetry is the whole reason departure 1 was hard, and it is worth
  keeping in mind for anything that reasons about load order.
- **`use Mod :tag` is Raku++-only.** Rakudo routes it through the
  `is export(:tag)` machinery, which a `sub EXPORT` module has no part in.
  `t/02-export.t` asserts the divergence in both directions rather than
  pretending either engine is right.
- **A single-element nested list flattens through an `@rows` parameter**, so
  `to-csv([['a,b']])` arrives as a row of loose fields. Bit the test, not the
  module.

## What is not tested yet

The `core` row. No engine implements the `rakupp-*` primitives, so
`*-backend()` reports the reference module everywhere and the functional probe
has nothing to accept. The probe itself is exercised — it correctly *rejects*
`rakupp-sha1-hex`, which exists and returns uppercase hex — but the accept path
waits on DATA-PLAN P1 to P5.
