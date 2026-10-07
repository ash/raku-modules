# Slang::Sigilless — plan

A slang for writing Raku without sigils, on Rakudo and on Raku++. Not started
as a distribution yet; this file is the plan to come back to. When work
begins, it becomes the design log, like the other files here, and
`Slang-Sigilless/` holds the distribution.

```raku
use Slang::Sigilless;

my @queue = 1, 2, 3;          # the sigil once, at the declaration
my %seen;
while queue && seen.elems < 2 {
    seen{queue.shift} = True;
}
say seen.keys.sort;
```

```raku
use Slang::Sigilless <infer>;

my words = <apple banana>;    # @words: a word list
words.push('cherry');
my ages = { alice => 30 };    # %ages: a Hash literal
my double = -> n { n * 2 };   # &double: a routine
```

## Decisions taken

* **Name: `Slang::Sigilless`.** It sits with the other grammar extensions
  (`Slang::Nogil`, `Slang::Tuxic`, `Slang::Lambda`, …) and was free in the
  ecosystem index as of 2026-10-07. A lowercase pragma name (`use sigilless`)
  was considered and dropped: lowercase names are conventionally the core's,
  and on Rakudo a user module cannot be switched off with `no` (it fails with
  an internal error).
* **Two modes.** Plain `use Slang::Sigilless;` is *sigil once*: a variable is
  declared with its sigil, and every later use is the bare name. Inference
  (no sigil anywhere; the kind comes from the uses) is opt-in with
  `use Slang::Sigilless <infer>`. The option is positional because Rakudo
  reads `:infer` after a module name as an export tag.
* **One name, one kind.** Wherever a bare name has to be resolved, a name
  cannot be two kinds of variable: not in one scope, and not an inner `$a`
  under an outer `@a`.
* **A real slang**, lexical on Rakudo and working inside modules. It is not
  the prototype's mechanism (re-read `$*PROGRAM`, translate, run the result in
  a second process), which covers only the main file, only on Rakudo, and only
  from the `use` line to the end of the file.

## The prototype

A working translator from sigil-free Raku to ordinary Raku. It does both
modes and runs on both engines:
- 10 sigil-free programs match hand-sigiled twins;
- 6 programs are refused with the right message;
- all 1,333 Raku files in the Raku++ repository come back byte-identical.

It lives in the Raku++ repository, on branch
`claude/raku-sigil-free-exploration-59368f` (commit `68b5fb07`, not merged):

* `docs/dev/experiments/SIGIL-FREE.md` — the findings: what a sigil does, the
  probes on both engines, the inference rules, the limits.
* `docs/dev/experiments/sigil-free/` — `lib/Acme/Sigilless.rakumod` (lexer,
  scope-aware analyzer, emitter), `bin/sigilless`, `examples/` with
  `reference/` twins, `errors/`, and `t/{examples,errors,passthrough}.raku`.

Its analyzer is the part to keep: the scope model and the evidence rules,
including the one that took a regression to find. A value from an expression
of unknown kind stays `$`, because `x[…]`, `x<…>` and `x.push` work on an
item too. Without that rule, `my m = KV.parse(…); m<pair>` copies the Match
into a Hash. Its tests carry over as this distribution's suite.

## What the slang has to do

| Piece | Rakudo | Raku++ |
|---|---|---|
| `my x` / `has x` declares a variable | `sigilless-variable` token, as `Slang::Nogil` does | the existing `sigilless-variable` hook |
| bare `x` resolves to the declared `@x`, `%x`, `&x` or `$x` | an action that compiles a lexical variable lookup (needs actions, not just a grammar; Slangify carries both frontends) | the same hook: Raku++ lexes the action's result as text, i.e. `@x` |
| `sub f(x)`, `-> a, b`, `:name`, `*rest` | override the parameter rule | **no hook yet** — one has to be added |
| inference (`<infer>`) | at `use` time, run the analyzer over the source text (through `$/.orig`, as Nogil's keyword check does), keep its decisions by position, and let the hooks apply them | same; needs a code assertion that can see the module's own lexical subs |
| scope | lexical | unit-scoped: a `use` inside a block governs the rest of the file (stated in Raku++'s SLANG-PLAN.md) |

## Prerequisites in Raku++

Raku++ bugs found during the R&D; a fix session is being started separately:

1. The sigilless-binding family. Each was checked against Rakudo:
   - `my \x = $ = 5; x = 6` dies;
   - `my \a = [1,2,3]; a = 4, 5, 6` dies;
   - `my \x := $x` and `my \x = $x` do not alias;
   - `-> \row` over itemized elements iterates per element;
   - `for @a -> \e { e *= 2 }` does not write through;
   - `my \v := %h<a>` does not alias;
   - `.VAR` of `my \x = $ = 5` is `Int`, where Rakudo says `Scalar`.
2. `Slang::Nogil` 1.3 fails its own test with *Undefined routine
   'check-keywords'*. A token's `<?{ … }>` cannot see the slang module's
   lexical subs. This blocks the `<infer>` mode on Raku++.
3. Smaller ones met on the way:
   - `.raku` of an itemized container: `[1]` instead of `$[1]`;
   - `method !regex` / `method !rule` swallows the next method;
   - `say <= a>` is a parse error;
   - `use Foo :tag` passes `:tag` to `EXPORT`;
   - `no Foo` runs `EXPORT`.

## Steps

1. Raku++ fixes for prerequisites 1 and 2.
2. Rakudo, sigil-once mode: grammar and actions, `t/` from the prototype's
   examples and error cases. Check inside a module and inside a block.
3. Raku++: run step 2's slang through the existing hooks, and add the
   parameter hook.
4. `<infer>`: the analyzer at `use` time, on both engines.
5. README, META6.json, then the usual both-engine `./test.sh Slang-Sigilless`.
   Publishing is the user's step.

## Limits that stay, whatever the implementation

* **Strings.** Only `"{x}"` interpolates; a bare word in a string is text.
* **Pairs.** `:$x` has no sigil-free spelling (write `:x(x)`), and
  `x => 1` quotes `x`.
* **Names that can't be variables:** keywords, the control routines (`fail`,
  `die`, `exit`, `done`, …), quote words (`m`, `s`, `q`, `rx`, `tr`, …),
  native types and capitalized names.
* **Calls.** A name followed by a term is a call (`fail 'boom'`).
  `x(…)` beside a declared `$x`, `@x` or `%x` calls a routine named `x`.
* **Copy or alias.** Under `<infer>`, `my b = a` copies when `b` becomes `@b`
  and aliases when it becomes `$b`. The uses show the kind, not the intent.
* **The compiler's variables keep their sigils:** `$_`, `$/`, `$0`, `$!`,
  `$*OUT`, `@*ARGS`, `$^a`.
