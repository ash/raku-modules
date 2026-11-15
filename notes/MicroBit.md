# MicroBit — the design log

Why a distribution that does nothing but stop the program exists, and why it
is shaped this way. The README says what it does. The plan it serves is
[MICROBIT-PLAN.md](https://github.com/ash/rakupp/blob/main/docs/dev/plans/MICROBIT-PLAN.md)
in the Raku++ repository: `--target=microbit`, a Raku program on a BBC
micro:bit V2, as C++ for the board's own runtime, CODAL.

## The same shape as Arduino

Everything [notes/Arduino.md](Arduino.md) says about the `Arduino` stub holds
here, with the name changed. Raku++ answers `use MicroBit` itself, before it
looks at any path or repository: under the interpreter the module is a
simulated micro:bit, under `--target=microbit` the emitter writes CODAL's own
calls. So this distribution has no code to share with the engine, only the
name to cover on every other Raku: `die`, not `exit`, so `try require
MicroBit` stays catchable; two messages, the upgrade one for a Raku++ that
predates the name; the program's own file in the commands, `PROGRAM.raku`
for `-e`.

## The name

`MicroBit`, as rakupp's guide and examples spell it. The board's makers write
"micro:bit", which is no Raku name, and MicroPython's module is `microbit`;
a Raku module's name is capitalised, and `MicroBit` reads as the board.
raku.land listed no distribution matching `microbit` when this was added
(2026-11-15).

## The test

The Arduino one with the name changed, with its three outcomes: on Rakudo it
is told the program needs Raku++; on a Raku++ without the name (v5.8.0, the
release before the target) it is told to upgrade; on one that answers the
name, rakupp's main from 2026-11-15, the program runs and the four
assertions about the message are skipped. rakupp's `tools/install.raku`
lists `MicroBit` in `SHADOWED` beside the Arduino names.

## When to upload

With the rakupp release that ships `--target=microbit`, as for Arduino: the
two commands in the message work from the first day.
