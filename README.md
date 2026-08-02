# raku-modules

Raku modules written here and published to the ecosystem. Each one is developed
on [Raku++](https://github.com/ash/rakupp) and tested on **both** engines —
Rakudo and `rakupp` — before it is released.

They are modules for **Raku**, not for Raku++. The aim of Raku++ is to work
everywhere Rakudo does, so anything published from here has to run on both.

## Layout

One directory per distribution, each a complete distribution root:

```
HTTP-Simple/
    META6.json
    lib/HTTP/Simple.rakumod
    t/
```

The directory name is the distribution name with `::` written `-`, which is the
convention zef uses when it unpacks one.

### Why one repository

The ecosystem overwhelmingly publishes one repository per distribution — of the
567 distributions in the [Raku Ecosystem
Archive](https://github.com/Raku/REA) that declare an upstream repository, only
nine publish more than one, and most of those are renames sitting side by side.
This repository is deliberately the exception, for as long as that stays useful:

- Every module here exists partly to be run under two engines. One repository
  means one CI that runs every distribution under both, and one place where
  "all of them pass on both" is an invariant rather than a spreadsheet.
- When a module turns up an engine bug — the expected outcome, not the
  surprising one — the fix lands in Raku++ and *everything here* gets re-run.
  That is a single-repository operation.

**A module moves to its own repository when it earns it**: an outside
contributor, a release cadence of its own, or its own issue traffic. Splitting
is cheap and lossless (`git subtree split -P <dir>`), the distribution name does
not change, and nobody installing it notices. Merging later would not be cheap,
which is why the default starts here.

## Naming

Modules ship under their **functional** name — `HTTP::Simple`, `Data::Schema`,
`Terminal::Rich`. Not under a vendor prefix.

`RakuPP::` is reserved for the narrow case where the coupling to the engine is
real and a portable module could not express the same thing: variadic C calls,
driving `--exe`, the precompiled-AST cache, the WebAssembly surface. The test is
**would this module mean anything under Rakudo?** If yes, it gets a functional
name, and any Raku++-only behaviour in it is an engine bug to go and fix.

Modules that already exist in the ecosystem are not reimplemented here. See the
[reasoning](https://github.com/ash/rakupp/blob/main/docs/dev/ecosystem/MODULE-WISHLIST.md)
— in short, the existing modules are the best test oracle Raku++ has, and
replacing them would hide the bugs they find.

## Testing a distribution on both engines

```sh
cd HTTP-Simple
zef install --deps-only .
raku   -Ilib t/            # Rakudo
rakupp -Ilib t/            # Raku++
```

Both are expected to pass before anything is released. CI does the same for
every distribution in the repository, on every push.

## Releasing

Each distribution is released independently, from its own directory:

```sh
cd HTTP-Simple
fez upload
```

`META6.json` should carry `support.source` pointing at this repository, so
[raku.land](https://raku.land) links somewhere useful.

## Licence

Artistic-2.0, the ecosystem's convention. See [LICENSE](LICENSE).
