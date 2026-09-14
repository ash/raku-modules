# L10N::RU

Russian localization of Raku — a slang that lets a program be written with
Russian keywords — `мой` for `my`, `если` for `if`, `скажи` for `say` — and
the deparser that prints such a program back out in Russian again.

## Version

0.0.1

## Synopsis

```raku
use L10N::RU;

мой @список = 1..10;
скажи сумма @список;

для @список -> $н {
    скажи $н если $н мод 3 равно 0
}
```

## Description

The `use` line is the one line that cannot be Russian: until it has run, the
slang is not in the grammar and there is nothing to write Russian *with*.
Everything after it is Russian, including the program's own names.

The distribution is two modules generated from one translation table:

| module | what it is |
|---|---|
| `L10N::RU` | the slang — `use` it and the rest of the file parses as Russian |
| `RakuAST::Deparse::L10N::RU` | the reverse — an AST printed back out in Russian |

Because both come from that one table they agree by construction: **anything
the slang accepts, the deparser can write back**. The round trip is the
clearest way to see what a localization is, and it needs no `use` at all,
because Rakudo takes the localization by name:

```raku
my $ast := Q[мой $х = 1].AST("RU");
say $ast.DEPARSE("RU");    # мой $х = 1
say $ast.DEPARSE;          # my $х = 1
```

The last line is the point: there is no Russian Raku. `.AST("RU")` builds the
same AST the English would have built, and the English is what runs.

The second line needs Rakudo. Raku++ `3.28.0` takes the localization and
ignores it, answering `my $х = 1` to both: its deparsing role loads there and
is correct, it is simply never reached. That is the second `todo` in `t/`, and
Compatibility has the rest.

`use L10N::RU 'no-slangification'` loads the two roles without touching the
grammar — what a tool that wants to *inspect* the localization needs, and what
this distribution's own test file uses so that it can stay in English.

## Running a localized program

```bash
rusku программа.raku
```

`rusku` is the executor this distribution installs. It re-runs the interpreter
that invoked it with `-ML10N::RU`, so the slang is in place before the file
is parsed and a program needs no `use` line of its own. (The family's template
passes that through `RAKUDO_OPT`, which only Rakudo reads; this one puts it on
the command line, which both engines do.)

**The two ways of running a localized program are exclusive.** Under `rusku`
the file is Russian from its first character, `use` included — it is spelled
`используй` there — so a file carrying the English `use L10N::RU;` of the
synopsis above will not compile. Such a file is run directly instead:

```bash
RAKUDO_RAKUAST=1 rakudo программа.raku
rakupp программа.raku
```

`RAKUDO_RAKUAST=1` is what a Rakudo up to `v2026.08` needs. Without it the
file goes to the legacy grammar, which has no slang to mix into, and the
synopsis above stops at `Variable '@список' is not declared`. RakuAST becomes
the default in `v2026.09`, where the switch is redundant — it is written above
because it is harmless on the newer one and required on the older. Raku++
needs it at no version.

At a REPL the engines differ, and `rusku` with no arguments — which is `-M`
and a prompt — is the one spelling that works on both. It re-runs whichever
interpreter its shebang found, so the prompt below is the one that engine
draws:

    $ rusku                 # `raku` is Rakudo here
    [0] > скажи 5;
    5
    [0] > мой $х = 41; скажи $х + 1;
    42

Under Rakudo that is the only spelling. Its slang goes into the compilation
unit the `use` ran in, and every line a prompt reads is its own unit, so a
`use L10N::RU;` typed at the prompt is forgotten by the next one — as it is
for every module in the family. Raku++ carries the language across the lines
of a session instead, so there the typed form works too:

    $ rusku                 # `raku` is Raku++ here
    > use L10N::RU;
    > скажи 5
    5

That is Raku++ after `770ebbe`; `3.28.0` as released has neither — `-M`
reaches a script file and `-e` there but not the REPL's own lines, and a
typed `use` leaves the next line in English.

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
Russian word for them would be a translation of nothing.

## `my` cannot agree with everything

A Russian possessive agrees with what it modifies — here, with whatever the
variable happens to be called — and no single form is right for all of them:
`мой счётчик`, but `моя переменная` and `мои числа`. A keyword is one word, so
the table names the citation form first and keeps the rest behind it:

    scope-my   мой|моя|мои|мое|моё
    scope-our  наш|наша|наши|наше

That is L10N's own notation — a `|`-separated translation means the slang
accepts every spelling and the deparser prints the first — and any token
translation may use it, not just these two. **What ships uses the first
spelling only**, because Raku++ `3.28.0` matches nothing for a token holding
an alternation, which would cost that engine `my` and `our` altogether while
the rest of the slang went on working: a quiet failure rather than a loud one.
`rakudo regen --synonyms` turns the rest on and gives up that engine:

```raku
мой $счётчик = 0;         # what ships accepts
моя $переменная = 1;      # these two need --synonyms
мои @остатки = 1, 2, 3;
```

Every variable in this README and under `examples/` is therefore named with a
masculine singular noun, so that the sample code reads as Russian under what
ships. That is a constraint on the examples rather than on the language: with
the synonyms switched on, a variable can be called anything and the
declaration still agrees with it.

## Translated names are reserved

A word in the table means what the table says it means, everywhere a name of
that kind can appear — including in code you write yourself. `сдвинь` is
`shift`, so a method of your own called `сдвинь` is *called* as `shift` at
every call site, and is not found:

```raku
класс Точка {
    метод сдвинь($на) { … }   # declares сдвинь
}
$точка.сдвинь(5);             # calls .shift — and dies
```

The same holds for named arguments: `з` is `named-v`, so `з => 1` arrives as
`v => 1`. Every module in the L10N family works this way — `$objekt.drehe`
reaches `.rotate` in German too — and the remedy is the same in all of them:
**do not name your own things after words in the table**. `Точка.новый(...)`
finding `.new` is the same mechanism seen from the useful side.

## Regenerating

`RU.l10n` is the source and `lib/` is output. That file lists all 645 keys,
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

- `examples/fizzbuzz.raku` — control flow: `для`, `дано`/`когда`/`умолчание`,
  and how little of a program is left in English once the `use` line is past.
  Runs on both engines.
- `examples/wordcount.raku` — a class with an attribute and methods, a hash, a
  regex and a named argument, which is where a localization stops being a
  novelty and starts being ordinary code. Rakudo only: its attribute is named
  in Cyrillic, which Raku++ cannot reach (see Compatibility).

Both carry their own `use` line, so they are run directly rather than
through `rusku` — see Running a localized program:

```bash
RAKUDO_RAKUAST=1 rakudo -I lib examples/fizzbuzz.raku
rakupp -I lib examples/fizzbuzz.raku
```

## Scope

The 240 untranslated names are the ones where a Russian word would be worse
than the English: the quote languages (`q`, `qq`, `rx`, `m`, `s`), the regex
adverbs that are single letters (`:i`, `:g`, `:s`), the pragmas that name
themselves (`nqp`, `isms`, `precompilation`), the system methods (`BUILD`,
`TWEAK`, `ACCEPTS`), the meta-operators, and the mathematical terms `pi`,
`tau` and `nano`. They are listed, commented out, in `RU.l10n`; uncommenting
one and regenerating is all it takes to change that judgement.

Not attempted in this version: **registration upstream**. `L10N` keeps its own
table of which executor names and file extensions belong to which
localization, so `rusku` is unknown to `L10N.binaries-for-localization` and
there is no `.rus` extension that Rakudo would pick a localization from. Both
are one-line additions to the upstream distribution, not to this one.

Not attempted either: Russian **error messages** or a Russian **`.gist`**. The
slang is the input side only. `скажи Истина` prints `True`, and a program that
dies says so in English. Localizing the output is a different project with a
different table.

## Compatibility

| engine | version | `t/01-russian.t` |
|---|---|---|
| Rakudo | `v2026.08` | 16/16 |
| Raku++ | `3.28.0` | 14/16, 2 `todo` |

Neither version is an established floor — no older engine has been tried. On
Rakudo the real floor is whatever version `Str.AST` and `RAKUDO_RAKUAST`
landed in, which is well before `v2026.08`.

**Raku++ `3.28.0` runs the slang**, which is the surprise here: `Str.AST`, the
grammar mixin and a plain `use L10N::RU;` at the top of a file all work, with
no environment switch, and `examples/fizzbuzz.raku` produces the same output
under both engines. Four differences remain, all of them the engine's, and
none of them about this module:

- **A private attribute named outside the Latin script is unreachable.**
  `класс Точка { имеет $.х; метод м() { $!х } }` fails with `Undefined
  routine 'х'`, and `$!х += 1` with `Target is not assignable`. The same class
  written in plain English with the same Cyrillic name fails identically, with
  no slang anywhere in it — and a Latin-script language's diacritics are fine,
  so `$!vērt` works where `$!знач` does not. This is the one that hurts: in a
  Russian program the attribute names are Russian. It is what the first `todo`
  in `t/` marks, and why `examples/wordcount.raku` is Rakudo-only.
- **`DEPARSE($localization)` ignores its argument**, returning the AST in
  English. The deparsing role loads there and is correct; it is not reached.
  That is the second `todo`.
- **`subst` checks its adverbs against the engine's own regex-adverb names**
  before any localization is applied, so `"a.b.c".замени(".", "-",
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
