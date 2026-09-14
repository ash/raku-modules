# L10N::LV

Latvian localization of Raku — a slang that lets a program be written with
Latvian keywords — `mans` for `my`, `ja` for `if`, `saki` for `say` — and the
deparser that prints such a program back out in Latvian again.

## Version

0.0.1

## Synopsis

```raku
use L10N::LV;

mans @saraksts = 1..10;
saki summa @saraksts;

katram @saraksts -> $s {
    saki $s ja $s atlikums 3 vienāds 0
}
```

## Description

The `use` line is the one line that cannot be Latvian: until it has run, the
slang is not in the grammar and there is nothing to write Latvian *with*.
Everything after it is Latvian, including the program's own names.

The distribution is two modules generated from one translation table:

| module | what it is |
|---|---|
| `L10N::LV` | the slang — `use` it and the rest of the file parses as Latvian |
| `RakuAST::Deparse::L10N::LV` | the reverse — an AST printed back out in Latvian |

Because both come from that one table they agree by construction: **anything
the slang accepts, the deparser can write back**. The round trip is the
clearest way to see what a localization is, and it needs no `use` at all,
because the localization can be named:

```raku
my $ast := Q[mans $x = 1].AST("LV");
say $ast.DEPARSE("LV");    # mans $x = 1
say $ast.DEPARSE;          # my $x = 1
```

The last line is the point: there is no Latvian Raku. `.AST("LV")` builds the
same AST the English would have built, and the English is what runs.

`use L10N::LV 'no-slangification'` loads the two roles without touching the
grammar — what a tool that wants to *inspect* the localization needs, and what
this distribution's own test file uses so that it can stay in English.

Both Raku engines run all of this. The handful of places where they differ
are collected under Compatibility, and nothing between here and there
mentions them.

## Running a localized program

```bash
latku programma.raku
```

`latku` is the executor this distribution installs. It re-runs the interpreter
that invoked it with `-ML10N::LV`, so the slang is in place before the file
is parsed and a program needs no `use` line of its own.

**The two ways of running a localized program are exclusive.** Under `latku`
the file is Latvian from its first character, `use` included — it is spelled
`lieto` there — so a file carrying the English `use L10N::LV;` of the
synopsis above will not compile. Such a file is run directly instead:

```bash
raku programma.raku
```

At a REPL, `latku` with no arguments — `-M` and a prompt — opens a localized
session, which needs no `use` line for the same reason:

    $ latku
    > saki 5;
    5
    > mans $x = 41; saki $x + 1;
    42

## What is translated

| group | | what it holds |
|---|---|---|
| `block` | 16 of 16 | `if`, `for`, `given`, `while`, `repeat`, … |
| `modifier` | 9 of 9 | those same words as statement modifiers |
| `scope` | 9 of 9 | `my`, `our`, `state`, `has`, `constant`, … |
| `package` | 5 of 5 | `class`, `role`, `grammar`, `module`, `package` |
| `routine` | 6 of 6 | `sub`, `method`, `submethod`, `token`, `rule`, `regex` |
| `trait-is` | 16 of 16 | `is rw`, `is copy`, `is pure`, … |
| `traitmod` | 7 of 7 | `is`, `does`, `handles`, `of`, `trusts`, … |
| `stmt-prefix` | 13 of 13 | `do`, `try`, `gather`, `lazy`, `start`, … |
| `phaser` | 14 of 18 | `ENTER`, `LEAVE`, `CATCH`, `END`, … |
| `infix` | 24 of 41 | the word operators: `and`, `or`, `cmp`, `eq`, `mod`, … |
| `core` | 174 of 234 | sub and method names: `say`, `map`, `sort`, `elems`, … |
| `named` | 65 of 135 | named arguments: `:key`, `:delete`, `:global`, … |
| everything else | 47 of 136 | enums, adverbs, pragmas, terms, quote languages |
| | **405 of 645** | |

A name with no translation keeps its English spelling and goes on working, so
the table is a floor rather than a boundary: `pi`, `BEGIN`, `gcd`, `unicmp`
and the `q`/`qq`/`rx` quote languages are left alone deliberately, because a
Latvian word for them would be a translation of nothing.

The long vowels and soft consonants are kept — `ņem`, `ĶER`, `izsmeļoši`,
`lasīt-rakstīt` — rather than folded to ASCII. They are word characters as far
as Raku is concerned, so they are legal in an identifier, and both engines
parse them; the phasers are upper-cased as phasers are, diacritics and all.

## `my` cannot agree with everything

A Latvian possessive agrees with what it modifies — here, with whatever the
variable happens to be called — and no single form is right for all of them:
`mans skaitītājs`, but `mana virkne` and `mani skaitļi`. A keyword is one
word, so the table names the citation form first and keeps the rest behind it:

    scope-my   mans|mana|mani|manas

(`our` needs no such list: `mūsu` is a genitive and does not decline.) That is
L10N's own notation — a `|`-separated translation means the slang accepts
every spelling and the deparser prints the first — and any token translation
may use it, not just this one. **What ships uses the first spelling only.**
`./regen --synonyms` turns the rest on, at a cost Compatibility sets out:

```raku
mans $skaitītājs = 0;      # what ships accepts
mana $virkne = "x";        # needs `./regen --synonyms`
mani @atlikumi = 1, 2, 3;  # likewise
```

Every variable in this README and under `examples/` is therefore named with a
masculine singular noun, so that the sample code reads as Latvian under what
ships. That is a constraint on the examples rather than on the language: with
the synonyms switched on, a variable can be called anything and the
declaration still agrees with it.

## Translated names are reserved

A word in the table means what the table says it means, everywhere a name of
that kind can appear — including in code you write yourself. `nobīdi` is
`shift`, so a method of your own called `nobīdi` is *called* as `shift` at
every call site, and is not found:

```raku
klase Punkts {
    metode nobīdi($par) { … }   # declares nobīdi
}
$punkts.nobīdi(5);              # calls .shift — and dies
```

The same holds for named arguments: `a` is `named-k`, so `a => 1` arrives as
`k => 1`. Every module in the L10N family works this way — `$objekt.drehe`
reaches `.rotate` in German too — and the remedy is the same in all of them:
**do not name your own things after words in the table**. `Punkts.jauns(...)`
finding `.new` is the same mechanism seen from the useful side.

## Regenerating

`LV.l10n` is the source and `lib/` is output. That file lists all 645 keys,
the untranslated ones commented out, and carries the instructions at its top.
To change a word, edit it and run `regen`, which sits beside it in the
distribution root — `L10N-LV/` in a checkout of this repository, not the
repository root:

```bash
./regen
```

`regen` is `update-localization` — the script the
[L10N](https://raku.land/zef:l10n/L10N) distribution installs — plus the
`|`-handling described above, and like that script it precompiles the slang
afterwards to check that what it wrote works. Compatibility says which engine
it needs, and why the `|`-handling is not stock.

## Examples

- `examples/fizzbuzz.raku` — control flow: `katram`,
  `dots`/`kad`/`noklusējums`, and how little of a program is left in English
  once the `use` line is past.
- `examples/wordcount.raku` — a class with an attribute and methods, a hash, a
  regex and a named argument, which is where a localization stops being a
  novelty and starts being ordinary code.

Both carry their own `use` line, so they are run directly rather than through
`latku` — see Running a localized program:

```bash
raku -I lib examples/fizzbuzz.raku
```

## Scope

The 240 untranslated names are the ones where a Latvian word would be worse
than the English: the quote languages (`q`, `qq`, `rx`, `m`, `s`), the regex
adverbs that are single letters (`:i`, `:g`, `:s`), the pragmas that name
themselves (`nqp`, `isms`, `precompilation`), the system methods (`BUILD`,
`TWEAK`, `ACCEPTS`), the meta-operators, and the mathematical terms `pi`,
`tau` and `nano`. They are listed, commented out, in `LV.l10n`; uncommenting
one and regenerating is all it takes to change that judgement.

Not attempted in this version: **registration upstream**. `L10N` keeps its own
table of which executor names and file extensions belong to which
localization, so `latku` is unknown to `L10N.binaries-for-localization` and
there is no `.lat` extension a localization would be picked from. Both
are one-line additions to the upstream distribution, not to this one.

Not attempted either: Latvian **error messages** or a Latvian **`.gist`**. The
slang is the input side only. `saki Patiess` prints `True`, and a program that
dies says so in English. Localizing the output is a different project with a
different table.

## Compatibility

| engine | version | `t/01-latvian.t` |
|---|---|---|
| Rakudo | `v2026.08` | 16/16 |
| Raku++ | `3.28.0` | 15/16, 1 `todo` |

Neither version is an established floor — no older engine has been tried.

Both engines run the slang: `Str.AST`, the grammar mixin, a plain
`use L10N::LV;` at the top of a file, the executor, and the examples. What
follows is every place the two part company, keyed to the section above that
runs into it.

**Synopsis, Running a localized program, Examples.** A Rakudo up to `v2026.08`
needs `RAKUDO_RAKUAST=1` in the environment. Without it the file goes to the
legacy grammar, which has no slang to mix into, and the synopsis stops at
`Variable '@saraksts' is not declared`. RakuAST is the default from
`v2026.09`, and Raku++ needs no such switch at any version. `latku` sets it
either way, which is why the sections above never mention it.

**Description — the round trip.** `DEPARSE($localization)` is Rakudo's.
Raku++ takes the localization and ignores it, answering `my $x = 1` to both
lines: its deparsing role loads there and is correct, it is simply never
reached.

**Running a localized program — the REPL.** Raku++ carries a session's
language across its lines, so `use L10N::LV;` typed at a prompt works there
and goes on working. Rakudo puts the slang into the compilation unit the `use`
ran in, and every line a prompt reads is its own unit, so there the typed form
is forgotten by the next prompt — as it is for every module in the family, and
why the section above reaches for the executor instead.

**`my` cannot agree — the synonyms.** `./regen --synonyms` is Rakudo's. A
token holding an alternation matches nothing under Raku++, not even its first
spelling, so turning the synonyms on there costs `my` altogether while the
rest of the slang goes on working: a quiet failure rather than a loud one.
That is why one spelling is what ships.

**Regenerating.** `./regen` needs Rakudo. Raku++ runs the modules it generates
but cannot load `L10N` itself, stopping at `use L10N` with `the module
registered no slang`. Stock `update-localization` would do everything `regen`
does but dies on a `|` translation: it hands a `Seq` to
`RakuAST::Regex::Alternation.new`, which takes slurpy positionals, so the
`Seq` lands as one malformed alternative and generation fails with `You cannot
deparse a Seq instance`. `regen` flattens the table before the generator sees
it and puts it back afterwards — that one-character upstream fix,
`|@parts.map(...)`, is all that stands between this and the stock script.

Two more that nothing above runs into. Under Raku++, `subst` checks its
adverbs against the engine's own regex-adverb names before any localization is
applied, so `"a.b.c".aizvieto(".", "-", :globāli)` is rejected with
`Unrecognized regex adverb` — an English `:global` is what it wants, and why
`examples/wordcount.raku` reaches for `izķemmē` (`comb`) instead. And a method
call on a `Range` inside code compiled through `.AST` returns a `Range`
instead of dispatching: `Q[('a'..'z').elems].AST.EVAL` is `0..1` rather than
`26`.

## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.
