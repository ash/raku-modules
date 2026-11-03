# Arduino — the design log

Why a distribution that does nothing but stop the program exists, and why it
is shaped this way. The README says what it does. The plan it serves is
[ARDUINO-PLAN.md](https://github.com/ash/rakupp/blob/main/docs/dev/plans/ARDUINO-PLAN.md)
in the Raku++ repository: `--target=arduino`, a Raku program as firmware.

## The name belongs to the engine

`use Arduino` is answered by Raku++ itself, as `use JS` and `use Data::Native`
already are. Its functions are engine builtins: a simulated board under the
interpreter, direct calls into the Arduino core under `--target=arduino`. The
emitter knows them by identity, so a module file standing in for them would
be wrong even if it had the same surface.

The ecosystem cannot hold the name for anyone. A distribution is its name
together with its `auth`, and fez accepts the same name from a second
account: in the fez index of 2026-10-15, 269 of 9,701 module names come from
two or more auths (`App::MoarVM::Debug` from `zef:raku-community-modules` and
from `zef:slid1amo2n3e4`), and in REA 4,876 of 13,763. Nothing was named
Arduino, or mentioned Firmata, in either. So Raku++ answers the name before it
looks at any path or repository, and this distribution only covers the engines
that do not.

## The naming rule, and why this is the exception

[README.md](../README.md#naming) reserves `RakuPP::` for modules coupled to
the engine, and its test is "would this module mean anything under Rakudo?"
This one would not, and it still ships as `Arduino`. The rule is about a
module's code; this distribution has none. The name is what an Arduino
program in Raku writes on its first line, and it is the engine's to answer.
A `RakuPP::Arduino` stub would cover a name nobody writes and leave `Arduino`
itself open.

## Shape

- **`die`, not `note` and `exit`.** For a `use` it happens at the program's
  compile time either way, so no statement runs first. An exception also
  leaves `try require Arduino` working for a program that probes; an `exit`
  would kill it. The cost is Raku++'s backtrace under the message, which
  Rakudo does not print for a compile-time `die`.
- **Two messages.** A Raku++ that loads this file predates the built-in
  `use Arduino`. Telling it the program needs Raku++ would be wrong, so it is
  told to upgrade. `$*RAKU.compiler.name eq 'Raku++'` tells the two apart.
- **The program's own name in the commands.** The message is read by someone
  holding the program, so it names the file. `-e` and `-` become
  `PROGRAM.raku`, as rakupp's own `use JS` message does.

## The test

The programs run in a child, as a user's would: `use` is compile time, so
in-process the stub is reachable only through `require`, which is checked
on its own for being catchable. The suite has two outcomes on Raku++. Today it
loads the stub and checks the upgrade message. A Raku++ that answers
`use Arduino` runs the program, and the suite checks that and skips the four
assertions about the message. The same file therefore stays green across the
release that adds the target.

## Installing

`zef install ./Arduino` on Rakudo v2026.09: the tests pass, the module
precompiles and installs, and a program's `use Arduino` then stops with the
message. Precompiling does not run the module's mainline; loading it does.

`rakupp install` should skip the distribution, as it skips the
`NativeHelpers::*` dists rakupp shadows. That needs `Arduino` added to
`SHADOWED` in rakupp's `tools/install.raku`, next to the engine's own answer,
in the same release.

## When to upload

Not decided. Uploading now claims the raku.land page before anyone else's
`Arduino`, but the two commands in the message do not work until a rakupp
ships `--target=arduino`. Uploading with that release keeps the message true
from the first day.

## Arduino::LEDMatrix

The second stub, added 2026-11-03, the same shape for the same reasons. Raku++
answers `use Arduino::LEDMatrix` with the Uno R4 WiFi's 12×8 LED matrix: a
`frame` sub that packs a picture into the core library's three 32-bit words
while building, and a `LEDMatrix` with `begin`, `show` and `clear` that the
emitter turns into Arduino_LED_Matrix calls. A board-specific part gets a
module of its own, rather than more names in `Arduino`, so that a program
says what it needs and a sketch includes the library only when asked.

Its test is the Arduino one with the name changed, and has the same three
outcomes: on Rakudo v2026.09 it is told the program needs Raku++; on a Raku++
from before the name it is told to upgrade (checked against a build of
2026-11-02); and on one that answers the name the program runs (checked
against rakupp's `claude/arduino-ledmatrix` branch). rakupp's
`tools/install.raku` lists it in `SHADOWED` beside `Arduino`.
