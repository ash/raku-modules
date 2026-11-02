# Arduino

A stub. `use Arduino` is built into [Raku++](https://github.com/ash/rakupp):
`rakupp` answers the name itself, runs the program against a simulated board,
and compiles it for a real one with `--target=arduino`. On any other Raku this
module stops the program at the `use` line and says so.

> **0.0.1, a stub with no API of its own.** 6 assertions in one file, green on
> Rakudo 2026.09 and Raku++ 5.5.0-360. The Raku++ side it points to is
> planned, not released: no rakupp answers `use Arduino` yet, so today's
> rakupp loads this stub too and is told to upgrade. See
> [Compatibility](#compatibility) and [Scope](#scope).

```raku
use Arduino;

constant LED   = 9;                                                  # a PWM pin
constant @wave = (^32).map: { (127.5 + 127.5 * sin(2 * pi * $_ / 32)).Int };

pinMode(LED, OUTPUT);                  # the mainline before the loop: setup()
say "a wave of {@wave.elems} steps";

loop {                                 # the top-level loop: loop()
    state uint8 $i = 0;
    analogWrite(LED, @wave[$i++ % @wave.elems]);
    delay(20);
}
```

On Raku++, once `use Arduino` is built in:

```bash
rakupp fade.raku                       # on the simulated board
rakupp --target=arduino fade.raku      # the sketch for a real one
```

On any other Raku:

```
$ raku fade.raku
===SORRY!=== Error while compiling fade.raku
This program needs Raku++: `use Arduino` is built into rakupp
(https://github.com/ash/rakupp), which runs it against a simulated board
and compiles it for a real one:
    rakupp fade.raku
    rakupp --target=arduino fade.raku

at fade.raku:1
------> <BOL><HERE>use Arduino;
```

## What answers `use Arduino`

| engine | what happens |
|---|---|
| Raku++ with `use Arduino` built in | the engine answers it; this module is never loaded |
| an older Raku++ | this module: "does not have `use Arduino` built in yet", and `rakupp upgrade` |
| Rakudo, or any other Raku | this module: "This program needs Raku++", with the two commands for this program |

**The module never exports anything and never lets the program run.** It
stops it with `die`, at compile time for a `use`, so not one statement of the
program runs first. Because it is an exception rather than an exit, a program
that probes with `try require Arduino` can catch it and carry on.

## Why a stub

A Raku module name cannot be reserved: a distribution is its name together
with its `auth`, and anyone may upload the same name under their own. Raku++
does not rely on the ecosystem for this name. It answers `use Arduino` before
it searches any path or repository, so nothing installed under the name can
change what a Raku++ program gets. What this distribution adds is everywhere
else: a program written for Raku++ meets a message that says what it needs,
instead of "Could not find Arduino".

## Scope

- **No API and no simulated board.** The board, its functions and its
  constants are part of the engine. Nothing here imitates them for another
  Raku; a program that needs them needs Raku++.
- **Nothing to configure.** The module takes no import list and reads no
  environment.

## Compatibility

| engine | version | 01-needs-rakupp |
|---|---|---|
| Rakudo | v2026.09 | 6/6 |
| Raku++ | 5.5.0-360 | 6/6 |

Not established floors: no older engine has been tried, and nothing in the
module depends on a recent one. On Raku++ the suite takes the "older Raku++"
branch today. On a Raku++ that answers `use Arduino`, it checks that the
program runs and skips the four assertions about the stub's message.

`zef install` on Rakudo v2026.09 tests the distribution, precompiles it and
installs it; only a program's `use Arduino` stops.

## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.

---

Why it is built this way is in the design log:
[notes/Arduino.md](https://github.com/ash/raku-modules/blob/main/notes/Arduino.md).
