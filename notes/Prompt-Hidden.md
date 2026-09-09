# Prompt::Hidden — the design log

What `prompt` with a `:hidden` adverb cost, and what building it on two engines
turned up. The README says what the module does; this says why it is shaped
that way.

## The shape

`prompt` is a built-in on both engines, so extending it means shadowing it —
and a module that shadows a built-in has to be able to hand the ordinary case
back. That is the whole design:

```raku
my &core-prompt = CORE::<&prompt>;      # resolved ONCE, in the module body

sub password-prompt(|c) {
    return core-prompt(|c) unless c.hash<hidden>:exists;
    ...
}
```

`|c` rather than a written signature, so a call this module has no opinion
about is forwarded exactly as it was made and gets the CORE error rather than
ours. `sub EXPORT` at file scope with no `unit module` line, as with the other
`*::Native` modules — inside a package declaration Rakudo never runs EXPORT at
all, exports nothing, and reports no error.

Three backends, probed in order: the engine primitive, `stty`, `_getch`. The
Windows half is a separate compilation unit loaded by a conditional `require`,
because `use NativeCall` costs about 70 ms on Rakudo (measured: 0.18 s → 0.26 s
wall for `raku -e 'say 1'`) and no Unix program should pay it for a branch it
cannot take.

## Four engine bugs, three fixed here

### 1. `prompt` ignored named arguments — and printed them

`B["prompt"]` took `a[0]` as the message unconditionally. Rakudo's `prompt` has
two signatures, `()` and `($msg)`, so every named argument is a caller error
there; Raku++ accepted and discarded them. Worse, with no message at all:

```raku
prompt(:hidden)       # printed "hidden<TAB>True" as the prompt string
```

`prompt` now refuses named arguments outright, as Rakudo does.

**And that is the second half of a design decision, not just a bug fix.** The
first cut of this work put `:hidden` on the engine's own `prompt`, so
`prompt("pw: ", :hidden)` worked on Raku++ with no module loaded at all. That
is a dialect: the program runs on one Raku and dies on the next, and the
divergence surfaces on the day someone ports it. So the engine keeps the
CAPABILITY — `rakupp-prompt-hidden`, a primitive with no bearing on `prompt`'s
signature — and the ADVERB belongs to this module, which probes for the
primitive and falls back to `stty`. One spelling, one meaning, every engine.

### 2. `{ "a$_" => 1 }` was a Hash, and that silently emptied the export map

This is the one that cost the most, because nothing failed. The module's
`sub EXPORT` built its map the obvious way:

```raku
Map.new(@want.map({ "&$_" => %IMPL{$_} }))
```

On Raku++ that produced an **empty Map**. No error, no warning: the program
compiled, `use Prompt::Hidden` exported nothing, and a bare `prompt` call
resolved to the built-in — which at that point still carried `:hidden` itself
(bug 1, before the adverb moved out of the engine), so every test still passed.
It would have failed on any engine that did not, and it does fail there now.

The cause was not `Map.new`, and not the `&` sigil in the key. It was the
hash-versus-block heuristic: a `{ ... }` whose content mentions `$_` is a Block,
and the token scan in `Parser::braceLooksHash` never looked **inside a string
interpolation**. So `{ "&$_" => ... }` composed a one-key Hash, `.map` was
handed a Hash instead of a Block, and the whole map produced nothing.

Rakudo's rule, measured across nineteen cases — the engines now agree on all of
them:

| | Rakudo | Raku++ before |
|---|---|---|
| `{ "a$_" => 1 }` | Block | Hash |
| `{ "a@_[0]" => 1 }` | Block | Hash |
| `{ a => "x$_" }` | Block | Hash |
| `{ "a\$_" => 1 }` (escaped) | Hash | Hash |
| `{ "a$x" => 1 }` | Hash | Hash |
| `{ "a{ @y.map({ $_ }) }" => 1 }` | Hash | Hash |

The last row is the one that stops this being a one-line fix: an embedded
`{ ... }` code block owns its own topic, so the scan skips it whole rather than
descending. `$_b` is a variable in its own right, so the character after the
underscore must not continue the identifier.

**The lesson is the memory rule, again: a probe must be able to fail.** The
first version of the export test asked `&prompt === CORE::<&prompt>` and read
`True` on Raku++ as agreement. It was the bug. What replaced it asks for
behaviour only this module has — it refuses a named argument the built-in
ignores.

### 3. `CORE::<&name>` found the nearest lexical, not the built-in

Raku++ approximated every pseudo-package as an ordinary scope-chain lookup, and
for `CORE::` the comment in `Parser.cpp` said so outright: "`CORE::<&not>`
becomes `&not`". That is fine until something shadows the built-in — which is
exactly when anyone writes the form. This module exports its own `&prompt` and
delegates the ordinary case to `CORE::<&prompt>`, so the call reached **itself**:

```
Too many levels of recursion
  in sub password-prompt at lib/Password/Native.rakumod line 212
```

Now `CORE::<&name>` goes straight to `builtins_` and past whatever shadows it,
which is what Rakudo does. `CORE::<&abs>(-5)` in a scope with a user `abs`
answers `5` on both engines.

The module does **not** rely on the fix: `CORE::<&prompt>` is resolved once, in
the module body, which runs before the importer has anything in scope. That
works on a fixed engine and a broken one alike, and it is better practice
anyway — one resolution instead of one per call. It is the reason the suite is
green on Raku++ 3.25.0.

### 4. `^C` at a password prompt wrecked the shell

Not pre-existing — it arrived with the feature, and it is the reason the
feature is more than four lines. A destructor does not run when a signal's
default action kills the process, so the terminal was left with echo off and
the user's next shell showed nothing they typed.

Measured against two baselines under a pseudo-terminal:

| | ECHO restored after `^C` |
|---|---|
| `getpass(3)` (via Python) | yes |
| `sh -c 'stty -echo; read x'` | **no** |
| `prompt(:hidden)` before | **no** |
| `prompt(:hidden)` now | yes |

The saved `termios` and a flag live at file scope, where a handler — which
takes no context — can reach them; `tcsetattr` and `raise` are both
async-signal-safe. The handler restores the previous disposition and re-raises,
so it changes what a signal *means* to nothing. `SIGINT`, `SIGTERM`, `SIGHUP`,
`SIGQUIT`.

The `stty` backend still has this hole and cannot close it, which is the
sharpest argument for the engine primitive existing at all.

## The divergence this module found, and what fixing it turned up

**A `die` inside `sub EXPORT` was downgraded to a warning on Raku++.** Rakudo
aborts compilation and exits 1; Raku++ printed `===WARNING=== Module … EXPORT
failed: …` and carried on at exit 0, so this module's own import-list validation
was advisory: `use Prompt::Hidden <typo>` imported nothing, said so on stderr,
and ran the program anyway. The catch in `Interpreter.cpp` was deliberate, but
its stated reason covered exactly one distribution — the `if` dist, whose EXPORT
necessarily fails — and that one was already special-cased by name in the same
block. Everything else was collateral.

Fixed in the engine (unreleased at the time of writing): a failing EXPORT now
propagates for `use`/`need`.

**With TWO exemptions, not one, and the second is the interesting half.**
Rakudo does not run a module's `sub EXPORT` for `require` **at all** — measured
across `require Mod`, `require Mod <&sym>` and `require ::("Mod")`, it runs zero
times, where Raku++ runs it in all three. So propagating there would have made
`require` fail a load Rakudo completes, and the first cut did exactly that.
Scoping it needed a new flag rather than the obvious one: `require ::(…)` is
already the `quiet` caller, but bareword `require Mod` is parsed into a plain
`UseStmt` with no marker at all, and `quiet` could not be reused because it also
suppresses "Could not find" — a missing module would have gone silent.

The blast radius turned out to be empty: of 576 installed modules **none** has an
EXPORT that throws, and of the twelve that define a `sub EXPORT`, the only calls
whose behaviour changes are deliberately bogus import lists on `JSON::Fast` and
`Test::When` — where Rakudo exits 1 too. `Test::When` was the one to worry about,
since suites use it to skip; it signals skip with `exit 0` and reserves `die` for
genuinely invalid keywords, so its skip path never touched this.

The assertion lives in the engine's `t/regression/export-failure-fails-the-use.raku`,
not here: it is a property of the engine, and pinning it in this suite would only
turn a version floor into a test failure. `t/03-export.t` asserts the message,
which every engine agrees on.

## What a pipe cannot test

Echo suppression is invisible on a pipe: there is nothing to suppress, so a
hidden read and a plain one produce identical bytes. The whole `t/` suite runs
on pipes — that is what makes it portable — so **it cannot catch the thing the
module is for**, and it did not: all 32 assertions passed on Raku++ 3.25.0,
where a hidden read on a real terminal echoes the password and then hangs.

A pseudo-terminal is the only harness that answers. Under one, against
`getpass(3)` as the reference:

| engine | backend | what the terminal showed |
|---|---|---|
| Rakudo 2026.08 | `stty` | nothing |
| Raku++ 3.26.0 | `core` | nothing |
| Raku++ 3.25.0 | `stty` | **the password**, then stopped |

The 3.25.0 row is the `SIGTTOU` bug fixed by `8b860fd` — every child `run`
spawned was put in its own process group, so `stty -echo` writing to the
controlling terminal stopped dead. Its own memory note already said only a pty
reproduces it; this is the second time that has been true.

`xt/` carries no pty test. Driving one needs `forkpty` or `openpty` through
NativeCall — macOS's `script` mangles piped stdin, so the usual shell trick is
out — and a Python driver is not what this repo's tooling is written in. The
matrix above was produced by hand and belongs in this log rather than in a
harness nobody runs.

## Not done

- **`stty -a` is asked, but only on the `stty` path.** After `stty -echo` the
  module confirms the terminal actually obeyed and refuses to read if it did
  not, rather than accepting a password in the clear. On Raku++ 3.25.0 that
  guard never gets to run — the process is already stopped.
- **The Windows path is untested.** `Prompt::Hidden::Win32` compiles on macOS
  and its `getch-line` is present, and the dispatch to it is exercised on any
  OS through `RAKU_PROMPT_HIDDEN_FORCE_WIN`; the `_getch` call itself has never run.
  Said plainly in the README rather than implied by silence.
