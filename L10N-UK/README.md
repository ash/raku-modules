# L10N::UK

Ukrainian localization of Raku — a slang that lets a program be written with
Ukrainian keywords — `мій` for `my`, `якщо` for `if`, `кажи` for `say` — and
the deparser that prints such a program back out in Ukrainian again.

## Version

0.0.1

## Synopsis

```raku
use L10N::UK;

мій @список = 1..10;
кажи сума @список;

для @список -> $ч {
    кажи $ч якщо $ч мод 3 рівне 0
}
```

## Install

Either installer takes it, into the same `~/.raku` store:

```bash
rakupp install L10N::UK
zef install L10N::UK
```

## Description

The `use` line is the one line that cannot be Ukrainian: until it has run, the
slang is not in the grammar and there is nothing to write Ukrainian *with*.
Everything after it is Ukrainian, including the program's own names.

The distribution is two modules generated from one translation table:

| module | what it is |
|---|---|
| `L10N::UK` | the slang — `use` it and the rest of the file parses as Ukrainian |
| `RakuAST::Deparse::L10N::UK` | the reverse — an AST printed back out in Ukrainian |

Because both come from that one table they agree by construction: **anything
the slang accepts, the deparser can write back**. The round trip is the
clearest way to see what a localization is, and it needs no `use` at all,
because the localization can be named:

```raku
my $ast := Q[мій $х = 1].AST("UK");
say $ast.DEPARSE("UK");    # мій $х = 1
say $ast.DEPARSE;          # my $х = 1
```

The last line is the point: there is no Ukrainian Raku. `.AST("UK")` builds
the same AST the English would have built, and the English is what runs.

`use L10N::UK 'no-slangification'` loads the two roles without touching the
grammar — what a tool that wants to *inspect* the localization needs, and what
this distribution's own test file uses so that it can stay in English.

Both Raku engines run all of this. The handful of places where they differ
are collected under Compatibility, and nothing between here and there
mentions them.

## Running a localized program

```bash
ukrku програма.raku
```

`ukrku` is the executor this distribution installs. It re-runs the interpreter
that invoked it with `-ML10N::UK`, so the slang is in place before the file
is parsed and a program needs no `use` line of its own.

**The two ways of running a localized program are exclusive.** Under `ukrku`
the file is Ukrainian from its first character, `use` included — it is spelled
`використай` there — so a file carrying the English `use L10N::UK;` of the
synopsis above will not compile. Such a file is run directly instead:

```bash
raku програма.raku
```

At a REPL, `ukrku` with no arguments — `-M` and a prompt — opens a localized
session, which needs no `use` line for the same reason:

    $ ukrku
    > кажи 5;
    5
    > мій $х = 41; кажи $х + 1;
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
Ukrainian word for them would be a translation of nothing.

No translation in this table contains an apostrophe. Raku allows one inside an
identifier, but `з'єднай` next to a quoted string is a reading hazard nobody
needs, so words that would carry one were chosen differently — `єднай` for
`join`, `назва-файлу` for `:filename`.

## `my` cannot agree with everything

A Ukrainian possessive agrees with what it modifies — here, with whatever the
variable happens to be called — and no single form is right for all of them:
`мій лічильник`, but `моя змінна` and `мої числа`. A keyword is one word, so
the table names the citation form and that is what the slang accepts:

    scope-my   мій

Every variable in this README and under `examples/` is therefore named with a
masculine singular noun, so that the sample code reads as Ukrainian. That is a
constraint on the examples rather than on the language — a variable can be
called anything, and only the declaration in front of it reads oddly.

## Translated names are reserved

A word in the table means what the table says it means, everywhere a name of
that kind can appear — including in code you write yourself. `зсунь` is
`shift`, so a method of your own called `зсунь` is *called* as `shift` at
every call site, and is not found:

```raku
клас Точка {
    метод зсунь($на) { … }   # declares зсунь
}
$точка.зсунь(5);             # calls .shift — and dies
```

The same holds for named arguments: `з` is `named-v`, so `з => 1` arrives as
`v => 1`. Every module in the L10N family works this way — `$objekt.drehe`
reaches `.rotate` in German too — and the remedy is the same in all of them:
**do not name your own things after words in the table**. `Точка.новий(...)`
finding `.new` is the same mechanism seen from the useful side.

## Regenerating

`UK.l10n` is the source and `lib/` is output. That file lists all 645 keys,
the untranslated ones commented out, and carries the instructions at its top.
To change a word, edit it and run, from the distribution root — `L10N-UK/`
in a checkout of this repository, not the repository root:

```bash
update-localization
```

That is the script the [L10N](https://raku.land/zef:l10n/L10N) distribution
installs. It rewrites both modules from the table and then precompiles the
slang to check that what it wrote works. Compatibility says which engine it
needs.

## Examples

- `examples/fizzbuzz.raku` — control flow: `для`,
  `дано`/`коли`/`замовчування`, and how little of a program is left in English
  once the `use` line is past. Runs on both engines.
- `examples/wordcount.raku` — a class with an attribute and methods, a hash, a
  regex and a named argument, which is where a localization stops being a
  novelty and starts being ordinary code.

Both carry their own `use` line, so they are run directly rather than through
`ukrku` — see Running a localized program:

```bash
raku -I lib examples/fizzbuzz.raku
```

## Scope

The 240 untranslated names are the ones where a Ukrainian word would be worse
than the English: the quote languages (`q`, `qq`, `rx`, `m`, `s`), the regex
adverbs that are single letters (`:i`, `:g`, `:s`), the pragmas that name
themselves (`nqp`, `isms`, `precompilation`), the system methods (`BUILD`,
`TWEAK`, `ACCEPTS`), the meta-operators, and the mathematical terms `pi`,
`tau` and `nano`. They are listed, commented out, in `UK.l10n`; uncommenting
one and regenerating is all it takes to change that judgement.

Not attempted in this version: **registration upstream**. `L10N` keeps its own
table of which executor names and file extensions belong to which
localization, so `ukrku` is unknown to `L10N.binaries-for-localization` and
there is no `.ukr` extension a localization would be picked from. Both
are one-line additions to the upstream distribution, not to this one.

Not attempted either: Ukrainian **error messages** or a Ukrainian **`.gist`**.
The slang is the input side only. `кажи Істина` prints `True`, and a program
that dies says so in English. Localizing the output is a different project
with a different table.

Parked, and worth doing: **the other forms of `my`**. L10N's tables already
have the notation for it — a `|`-separated translation means the slang accepts
every spelling and the deparser prints the first, so `мій|моя|мої|моє` is how
it would be written, and a variable of any gender would then read correctly.
One engine blocks each half of that. BUILDING such a table is Rakudo's job,
since it is the only engine that can run the generator, and L10N dies there on
the first `|` it meets: it hands a `Seq` to `RakuAST::Regex::Alternation.new`,
which takes slurpy positionals, and generation fails with `You cannot deparse
a Seq instance`. RUNNING what it would have built is both engines' job, and
Raku++ matches nothing for a token holding an alternation, not even its first
spelling — so a table built despite the first problem would cost that engine
`my` altogether. No localization in the family uses the notation, which is why
neither has been run into before.

## Compatibility

| engine | version | `t/01-ukrainian.t` |
|---|---|---|
| Rakudo | `v2026.08` | 16/16 |
| Raku++ | `3.28.0` | 14/16, 2 `todo` |

Neither version is an established floor — no older engine has been tried.

Both engines run the slang: `Str.AST`, the grammar mixin, a plain
`use L10N::UK;` at the top of a file, the executor, and the examples. What
follows is every place the two part company, keyed to the section above that
runs into it.

**Synopsis, Running a localized program, Examples.** A Rakudo up to `v2026.08`
needs `RAKUDO_RAKUAST=1` in the environment. Without it the file goes to the
legacy grammar, which has no slang to mix into, and the synopsis stops at
`Variable '@список' is not declared`. RakuAST is the default from `v2026.09`,
and Raku++ needs no such switch at any version. `ukrku` sets it either way,
which is why the sections above never mention it.

**Description — the round trip.** `DEPARSE($localization)` is Rakudo's.
Raku++ takes the localization and ignores it, answering `my $х = 1` to both
lines: its deparsing role loads there and is correct, it is simply never
reached.

**Running a localized program — the REPL.** Raku++ carries a session's
language across its lines, so `use L10N::UK;` typed at a prompt works there
and goes on working. Rakudo puts the slang into the compilation unit the `use`
ran in, and every line a prompt reads is its own unit, so there the typed form
is forgotten by the next prompt — as it is for every module in the family, and
why the section above reaches for the executor instead.

**Regenerating.** `update-localization` needs Rakudo. Raku++ runs the
modules it generates but cannot load `L10N` itself, stopping at `use L10N`
with `the module registered no slang`.

**A private attribute named outside the Latin script is unreachable under
Raku++.** `клас Точка { має $.х; метод м() { $!х } }` fails with `Undefined
routine 'х'`, and `$!х += 1` with `Target is not assignable`. The same class
written in plain English with the same Cyrillic name fails identically, so it
is about script rather than about slangs — a Latin-script language's
diacritics are fine, `$!vērt` works where `$!знач` does not. It is why
`examples/wordcount.raku` runs only under Rakudo.

Two more that nothing above runs into. Under Raku++, `subst` checks its
adverbs against the engine's own regex-adverb names before any localization is
applied, so `"a.b.c".заміни(".", "-", :глобально)` is rejected with
`Unrecognized regex adverb` — an English `:global` is what it wants, and why
`examples/wordcount.raku` reaches for `вичеши` (`comb`) instead. And a method
call on a `Range` inside code compiled through `.AST` returns a `Range`
instead of dispatching: `Q[('a'..'z').elems].AST.EVAL` is `0..1` rather than
`26`.

## Links

- [`L10N::UK` on raku.land](https://raku.land/zef:ash/L10N::UK) — the
  distribution page.
- [`L10N-UK` on GitHub](https://github.com/ash/raku-modules/tree/main/L10N-UK)
  — the source, in the repository this README ships from.

## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.
