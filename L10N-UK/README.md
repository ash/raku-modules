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
because Rakudo takes the localization by name:

```raku
my $ast := Q[мій $х = 1].AST("UK");
say $ast.DEPARSE("UK");    # мій $х = 1
say $ast.DEPARSE;          # my $х = 1
```

The last line is the point: there is no Ukrainian Raku. `.AST("UK")` builds
the same AST the English would have built, and the English is what runs.

The second line needs Rakudo. Raku++ takes the localization and
ignores it, answering `my $х = 1` to both: its deparsing role loads there and
is correct, it is simply never reached. That is the second `todo` in `t/`, and
Compatibility has the rest.

`use L10N::UK 'no-slangification'` loads the two roles without touching the
grammar — what a tool that wants to *inspect* the localization needs, and what
this distribution's own test file uses so that it can stay in English.

## Running a localized program

```bash
ukrku програма.raku
```

`ukrku` is the executor this distribution installs. It re-runs the interpreter
that invoked it with `-ML10N::UK`, so the slang is in place before the file
is parsed and a program needs no `use` line of its own. (The family's template
passes that through `RAKUDO_OPT`, which only Rakudo reads; this one puts it on
the command line, which both engines do.)

**The two ways of running a localized program are exclusive.** Under `ukrku`
the file is Ukrainian from its first character, `use` included — it is spelled
`використай` there — so a file carrying the English `use L10N::UK;` of the
synopsis above will not compile. Such a file is run directly instead:

```bash
RAKUDO_RAKUAST=1 rakudo програма.raku
rakupp програма.raku
```

`RAKUDO_RAKUAST=1` is what a Rakudo up to `v2026.08` needs. Without it the
file goes to the legacy grammar, which has no slang to mix into, and the
synopsis above stops at `Variable '@список' is not declared`. RakuAST becomes
the default in `v2026.09`, where the switch is redundant — it is written above
because it is harmless on the newer one and required on the older. Raku++
needs it at no version.

At a REPL, `ukrku` with no arguments — `-M` and a prompt — opens a localized
session under either engine. It needs no `use` line, having supplied one; the
prompt it draws is whichever engine its shebang found, Rakudo's here:

    $ ukrku
    [0] > кажи 5;
    5
    [0] > мій $х = 41; кажи $х + 1;
    42

Typing the `use` yourself at a plain prompt is the other way in, and only
Raku++ can do it. Rakudo puts the slang into the compilation unit the `use`
ran in, and every line a prompt reads is its own unit, so the line after it is
English again — as it is for every module in the family. Raku++ carries the
language across a session instead:

    $ rakupp
    > use L10N::UK;
    > кажи 5
    5

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
the table names the citation form first and keeps the rest behind it:

    scope-my   мій|моя|мої|моє
    scope-our  наш|наша|наші|наше

That is L10N's own notation — a `|`-separated translation means the slang
accepts every spelling and the deparser prints the first — and any token
translation may use it, not just these two. **What ships uses the first
spelling only**, because Raku++ matches nothing for a token holding
an alternation, which would cost that engine `my` and `our` altogether while
the rest of the slang went on working: a quiet failure rather than a loud one.
`rakudo regen --synonyms` turns the rest on and gives up that engine:

```raku
мій $лічильник = 0;       # what ships accepts
моя $змінна = 1;          # needs `rakudo regen --synonyms`
мої @залишки = 1, 2, 3;   # likewise
```

Every variable in this README and under `examples/` is therefore named with a
masculine singular noun, so that the sample code reads as Ukrainian under what
ships. That is a constraint on the examples rather than on the language: with
the synonyms switched on, a variable can be called anything and the
declaration still agrees with it.

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
To change a word, edit it and run, from this directory:

```bash
rakudo regen
```

`regen` is `update-localization` — the script the
[L10N](https://raku.land/zef:l10n/L10N) distribution installs — plus the
`|`-handling described above, and like that script it precompiles the slang
afterwards to check that what it wrote works. It is named
with `rakudo` above because it has to be: Raku++ runs the modules it
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

- `examples/fizzbuzz.raku` — control flow: `для`,
  `дано`/`коли`/`замовчування`, and how little of a program is left in English
  once the `use` line is past. Runs on both engines.
- `examples/wordcount.raku` — a class with an attribute and methods, a hash, a
  regex and a named argument, which is where a localization stops being a
  novelty and starts being ordinary code. Rakudo only: its attribute is named
  in Cyrillic, which Raku++ cannot reach (see Compatibility).

Both carry their own `use` line, so they are run directly rather than
through `ukrku` — see Running a localized program:

```bash
RAKUDO_RAKUAST=1 rakudo -I lib examples/fizzbuzz.raku
rakupp -I lib examples/fizzbuzz.raku
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
there is no `.ukr` extension that Rakudo would pick a localization from. Both
are one-line additions to the upstream distribution, not to this one.

Not attempted either: Ukrainian **error messages** or a Ukrainian **`.gist`**.
The slang is the input side only. `кажи Істина` prints `True`, and a program
that dies says so in English. Localizing the output is a different project
with a different table.

## Compatibility

| engine | version | `t/01-ukrainian.t` |
|---|---|---|
| Rakudo | `v2026.08` | 16/16 |
| Raku++ | `3.28.0` | 14/16, 2 `todo` |

Neither version is an established floor — no older engine has been tried. On
Rakudo the real floor is whatever version `Str.AST` and `RAKUDO_RAKUAST`
landed in, which is well before `v2026.08`.

**Raku++ runs the slang**, which is the surprise here: `Str.AST`, the
grammar mixin and a plain `use L10N::UK;` at the top of a file all work, with
no environment switch, and `examples/fizzbuzz.raku` produces the same output
under both engines. Four differences remain, all of them the engine's, and
none of them about this module:

- **A private attribute named outside the Latin script is unreachable.**
  `клас Точка { має $.х; метод м() { $!х } }` fails with `Undefined routine
  'х'`, and `$!х += 1` with `Target is not assignable`. The same class written
  in plain English with the same Cyrillic name fails identically, with no
  slang anywhere in it — and a Latin-script language's diacritics are fine, so
  `$!vērt` works where `$!знач` does not. This is the one that hurts: in a
  Ukrainian program the attribute names are Ukrainian. It is what the first
  `todo` in `t/` marks, and why `examples/wordcount.raku` is Rakudo-only.
- **`DEPARSE($localization)` ignores its argument**, returning the AST in
  English. The deparsing role loads there and is correct; it is not reached.
  That is the second `todo`.
- **`subst` checks its adverbs against the engine's own regex-adverb names**
  before any localization is applied, so `"a.b.c".заміни(".", "-",
  :глобально)` is rejected with `Unrecognized regex adverb`. So is `:globāli`,
  and so is a nonsense `:щщщ` — an English `:global` is what it wants.
- **An alternation inside a slang token matches nothing.** A token built from
  several spellings, which is what `rakudo regen --synonyms` writes, silently
  matches none of them — not even the first — while the rest of the slang goes
  on working. See One keyword, several spellings.

One more, recorded because it is easy to trip over even though nothing in `t/`
depends on it: under Raku++, a method call on a `Range` inside code compiled
through `.AST` returns a `Range` instead of dispatching —
`Q[('a'..'z').elems].AST.EVAL` is `0..1` rather than `26`. There is no
localization in that line at all.

## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.
