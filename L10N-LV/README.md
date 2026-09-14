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
because Rakudo takes the localization by name:

```raku
my $ast := Q[mans $x = 1].AST("LV");
say $ast.DEPARSE("LV");    # mans $x = 1
say $ast.DEPARSE;          # my $x = 1
```

The last line is the point: there is no Latvian Raku. `.AST("LV")` builds the
same AST the English would have built, and the English is what runs.

The second line needs Rakudo. Raku++ `3.28.0` takes the localization and
ignores it, answering `my $x = 1` to both: its deparsing role loads there and
is correct, it is simply never reached. That is the second `todo` in `t/`, and
Compatibility has the rest.

`use L10N::LV 'no-slangification'` loads the two roles without touching the
grammar — what a tool that wants to *inspect* the localization needs, and what
this distribution's own test file uses so that it can stay in English.

## Running a localized program

```bash
latku programma.raku
```

`latku` is the executor this distribution installs. It re-runs the interpreter
that invoked it with `-ML10N::LV`, so the slang is in place before the file
is parsed and a program needs no `use` line of its own. (The family's template
passes that through `RAKUDO_OPT`, which only Rakudo reads; this one puts it on
the command line, which both engines do.)

**The two ways of running a localized program are exclusive.** Under `latku`
the file is Latvian from its first character, `use` included — it is spelled
`lieto` there — so a file carrying the English `use L10N::LV;` of the
synopsis above will not compile. Such a file is run directly instead:

```bash
RAKUDO_RAKUAST=1 rakudo programma.raku
rakupp programma.raku
```

`RAKUDO_RAKUAST=1` is not optional on Rakudo: without it the file goes to the
legacy grammar, which has no slang to mix into, and the synopsis above stops
at `Variable '@saraksts' is not declared`. Raku++ needs no such switch.

A REPL is the one place a `use` line cannot put the slang in place. Every line
a REPL reads is its own compilation unit, and the slang was installed into the
unit that `use` ran in, so it is gone by the next prompt. That holds on both
engines and for every module in the family:

    > use L10N::LV;
    (Any)
    > saki 5;
    Undefined routine 'saki'

Start the REPL with the slang already loaded instead:

    $ rakudo -ML10N::LV
    [0] > saki 5;
    5
    [0] > mans $x = 41; saki $x + 1;
    42

`latku` with no arguments does the same thing, but it re-runs whichever
interpreter its `#!/usr/bin/env raku` shebang found, so it gives a localized
REPL only where `raku` is Rakudo. Under Raku++ `3.28.0` it does not: there
`-M` reaches a script file and `-e`, but not the REPL's own lines.

    $ latku                 # where `raku` is Raku++
    > saki 5
    Undefined routine 'saki'

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
may use it, not just this one. **What ships uses the first spelling only**,
because Raku++ `3.28.0` matches nothing for a token holding an alternation,
which would cost that engine `my` altogether while the rest of the slang went
on working: a quiet failure rather than a loud one. `rakudo regen --synonyms`
turns the rest on and gives up that engine:

```raku
mans $skaitītājs = 0;     # what ships accepts
mana $virkne = "x";       # these two need --synonyms
mani @atlikumi = 1, 2, 3;
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
To change a word, edit it and run, from this directory:

```bash
rakudo regen
```

`regen` is `update-localization` — the script the
[L10N](https://raku.land/zef:l10n/L10N) distribution installs — plus the
`|`-handling described above, and like that script it precompiles the slang
afterwards to check that what it wrote works. It is named
with `rakudo` above because it has to be: Raku++ `3.28.0` runs the modules it
generates but cannot load `L10N` itself, stopping at `use L10N` with `the
module registered no slang`.

Stock `update-localization` would do everything `regen` does, but dies on a
`|` translation: it hands a `Seq` to `RakuAST::Regex::Alternation.new`, which
takes slurpy positionals, so the `Seq` lands as one malformed alternative and
generation fails with `You cannot deparse a Seq instance`. `regen` flattens
the table before the generator sees it and puts it back afterwards — that
one-character upstream fix, `|@parts.map(...)`, is all that stands between
this and the stock script.

## Examples

- `examples/fizzbuzz.raku` — control flow: `katram`,
  `dots`/`kad`/`noklusējums`, and how little of a program is left in English
  once the `use` line is past.
- `examples/wordcount.raku` — a class with an attribute and methods, a hash, a
  regex and a named argument, which is where a localization stops being a
  novelty and starts being ordinary code.

Both run under either engine. They carry their own `use` line, so they are
run directly rather than through `latku` — see Running a localized program:

```bash
RAKUDO_RAKUAST=1 rakudo -I lib examples/fizzbuzz.raku
rakupp -I lib examples/fizzbuzz.raku
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
there is no `.lat` extension that Rakudo would pick a localization from. Both
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

Neither version is an established floor — no older engine has been tried. On
Rakudo the real floor is whatever version `Str.AST` and `RAKUDO_RAKUAST`
landed in, which is well before `v2026.08`.

**Raku++ `3.28.0` runs the slang**, which is the surprise here: `Str.AST`, the
grammar mixin and a plain `use L10N::LV;` at the top of a file all work, with
no environment switch, and both examples produce the same output under both
engines. Latvian gets off lighter than its Cyrillic siblings, because the one
Raku++ gap that bites them is about script rather than about slangs: a private
attribute named outside the Latin script is unreachable there, so `$!знач`
fails where `$!vērt` — diacritics and all — is fine. Four differences do
remain, all of them the engine's, none about this module:

- **`DEPARSE($localization)` ignores its argument**, returning the AST in
  English. The deparsing role loads there and is correct; it is not reached.
  That is the one `todo` in `t/`.
- **`subst` checks its adverbs against the engine's own regex-adverb names**
  before any localization is applied, so `"a.b.c".aizvieto(".", "-",
  :globāli)` is rejected with `Unrecognized regex adverb`. An English
  `:global` is what it wants. This is why `examples/wordcount.raku` reaches
  for `izķemmē` (`comb`) rather than a global `aizvieto`.

- **An alternation inside a slang token matches nothing.** A token built from
  several spellings, which is what `rakudo regen --synonyms` writes, silently
  matches none of them — not even the first — while the rest of the slang goes
  on working. See One keyword, several spellings.

- **`-M` does not reach the REPL's own lines.** `rakupp -ML10N::LV -e '…'`
  works, and so does a script run the same way, but at the REPL prompt the
  slang is not there — so a localized REPL is Rakudo's. (Typing `use
  L10N::LV;` at a prompt works on neither engine, but that one is the
  family's design rather than the engine's; see Running a localized program.)

One more, recorded because it is easy to trip over even though nothing in `t/`
depends on it: under Raku++, a method call on a `Range` inside code compiled
through `.AST` returns a `Range` instead of dispatching —
`Q[('a'..'z').elems].AST.EVAL` is `0..1` rather than `26`. There is no
localization in that line at all.

## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.
