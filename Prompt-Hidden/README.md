# Prompt::Hidden

`prompt` with a `:hidden` adverb — a password typed at a terminal that the
terminal never shows.

> **0.0.3.** The interface below is implemented and tested on both engines: 31
> assertions across four files, green on Rakudo 2026.08 and Raku++ 3.26.0. The
> echo suppression itself is verified separately under a pseudo-terminal, since
> a pipe has no echo to suppress — see [Compatibility](#compatibility). What is
> deliberately left out is in [Scope](#scope).

```raku
use Prompt::Hidden;

my $user = prompt "Username: ";
my $pass = prompt "Password: ", :hidden;

say "Hello, $user ({$pass.chars} characters)";
say Prompt::Hidden::prompt-backend;   # 'core' on Raku++, 'stty' on Rakudo/Unix
```

```bash
rakupp example.raku
```

```bash
rakudo example.raku
```

Or:

```bash
rakupp -MPrompt::Hidden -e'say "[{prompt ">_", :hidden}]"'
```

```bash
raku -MPrompt::Hidden -e'say "[{prompt ">_", :hidden}]"'
```

The same file runs on every Raku. What differs is who suppresses the echo.

## Why it exists

Raku has `prompt`, and it echoes. Reading a password means reaching past it:
`Terminal::Getpass` shells out to `stty`, and everyone else writes the same
half-dozen lines again. None of that is `prompt`, so a program wanting one
visible field and one hidden one ends up with two different calls, two
signatures, and two return types.

Here the hidden read is an adverb on the call you already write. `prompt`
without `:hidden` **is** `CORE::<&prompt>` — the whole capture is forwarded, so
the message, the allomorph return and the `Nil` at end of input are the core
ones, not an imitation. Only `:hidden` is new.

**The adverb belongs to this module, not to any engine.** `prompt("pw: ",
:hidden)` without `use Prompt::Hidden` is an error everywhere, Raku++ included
— core `prompt` has two signatures, `()` and `($msg)`, and takes no named
arguments on any of them. That is deliberate: an engine that quietly accepted
the adverb would mint a dialect, and the program would run on one Raku and die
on the next. What Raku++ supplies is the *capability*, as the
`rakupp-prompt-hidden` primitive this module probes for; the spelling is the
module's, so the same source means the same thing everywhere.

## What it exports

One name, and it is the one you came for:

| export | what it does |
|---|---|
| `prompt($message?, :hidden)` | the core `prompt`, plus the adverb |

`Prompt::Hidden::prompt-backend` — `'core'`, `'stty'` or `'msvcrt'`, whichever
did the reading — is **not** exported. It is introspection, worth having and
not worth a bare name in every importer's scope, so it is spelled in full.

There is no import list. With one export there is nothing to select, and a
list that could only ever name `prompt` would be a second spelling of the
default — so one is refused rather than accepted and ignored, because the one
thing an import list must never do is swallow a typo written beside it.

## The three backends

| backend | when | how |
|---|---|---|
| `core` | Raku++ with `rakupp-prompt-hidden` | the engine's own unechoed read |
| `stty` | any other Unix Raku | `stty -g` to save, `stty -echo`, restored in a `LEAVE` |
| `msvcrt` | Windows without the primitive | `_getch`, which returns a key unechoed |

The module picks by probing, in that order. The Windows half lives in
`Prompt::Hidden::Win32` and is loaded **only** on Windows: `use NativeCall`
costs about 70 ms on Rakudo, and no Unix program should pay it for a branch it
cannot take.

Two things the `core` backend does that the shell-out cannot:

- **`^C` leaves the shell working.** A signal's default action kills the
  process without unwinding, so a `LEAVE` never runs and the terminal is left
  with echo off — the same hole `stty -echo` in a shell script has. The engine
  installs a handler for `SIGINT`, `SIGTERM`, `SIGHUP` and `SIGQUIT` that
  restores the settings and re-raises. Measured against `getpass(3)`: both
  restore, naive `stty -echo` does not.
- **No window.** Echo is off before the prompt is printed, so a fast typist
  cannot get a character in first.

The `stty` backend does not take its own success on trust. `stty -echo` exiting
0 is not proof the terminal obeyed, so the module asks `stty -a` afterwards and
**refuses to read at all** if echo is still on, rather than accepting a
password in the clear.

## A secret comes back a Str

`prompt` returns an allomorph: type `1234` and you get an `IntStr`, which is an
`Int` as much as it is a `Str`. For a secret that is a trap, and not a
theoretical one — the same on both engines:

```raku
my $pin = prompt "PIN: ";        # user types 01234
say to-json({ pin => $pin });    # {"pin": 1234}
```

The leading zero is gone and the secret has been retyped as a number. So
`prompt(:hidden)` returns a plain `Str`, always. `prompt` without `:hidden`
keeps the allomorph, because that is what `prompt` does.

## Not a terminal is not an error

A pipe, a file, a here-doc, a CI harness: there is no echo to suppress, so the
line is read plainly and returned. That is what makes `:hidden` testable, and
it is why this distribution's suite can assert the return type, the end-of-input
answer and the whole export surface without a pseudo-terminal.

## Scope

- **No `getpass` alias.** The point is the adverb; a second spelling of the same
  read would only invite the two to drift.
- **No masking.** No echoed `*` per character, and no `:show` to opt into one.
  That needs the raw line discipline — backspace, `^U` and `^W` become the
  module's job — which is a different module, not an adverb.
- **No timeout, no retry, no confirmation prompt.** `prompt` has none of those
  and this is `prompt`.
- **No `Blob` return or explicit zeroing.** Raku strings are immutable and
  garbage-collected; a module cannot honestly promise to scrub one. Claiming
  otherwise would be worse than not claiming it.

## Compatibility

| engine | version | tests | backend | hidden read on a terminal |
|---|---|---|---|---|
| Rakudo | 2026.08 | 31/31 | `stty` | verified under a pty |
| Raku++ | 3.26.0 | 31/31 | `core` | verified under a pty |

The Rakudo version is not a floor; no older one has been tried. The Raku++
figure **is** a floor, and it is the engine's story rather than the module's:

- **The engine primitive landed in 3.26.0.** Below that there is no
  `rakupp-prompt-hidden`, so the module falls back to `stty`.
- **…and on Raku++ before 3.26.0 that fallback cannot work on a terminal.**
  Every child `run` spawned was put in its own process group, so an `stty`
  writing to the controlling terminal took `SIGTTOU` and stopped: `stty -echo`
  had no effect and the program hung with the password already on screen. Fixed
  in 3.26.0, which is also the first version with the primitive — so on Raku++,
  3.26.0 is the floor either way.

The suite passes on 3.25.0 because it exercises pipes, where there is no echo
to suppress. It does not, and cannot, catch that one; a pseudo-terminal does.

## Author

Andrew Shitov (`zef:ash`)

## Licence

Artistic-2.0.

---

The design log — what running this on two engines turned up, and the four
engine bugs it found — is in [notes/Prompt-Hidden.md](https://github.com/ash/raku-modules/blob/main/notes/Prompt-Hidden.md).
