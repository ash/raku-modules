# MicroBit

This is a module aimed to support Raku-for-micro:bit development: Raku
programs for the BBC micro:bit V2.

Processing `use MicroBit` itself is a part of the [Raku++](https://github.com/ash/rakupp) engine:
`rakupp` answers the name itself. No module installation needed. On any other Raku this module stops the program at the `use` line.

## Version

0.0.1

## Synopsis

```raku
use MicroBit;

loop {
    my int16 $acc = accelerometer.x;   # the tilt, left or right
    say $acc;                          # to the serial port
    display.show: $acc > 0 ?? Image.ARROW-E !! Image.ARROW-W;
    pause 100;
}
```

The names are MicroPython's, spelt as Raku: `display.scroll`,
`button-a.is-pressed`, `accelerometer.x`, `Image.HEART`.

Running the program:

```bash
rakupp tilt.raku                                            # on the simulated micro:bit
rakupp --target=microbit tilt.raku -o source/main.cpp       # C++ for the board's runtime, CODAL
```

CODAL's own build turns the C++ into the `MICROBIT.hex` that is copied onto
the board.

## Getting started

- **A walkthrough**, from a scrolled greeting to a die you shake, with a
  program for each step:
  [examples/microbit](https://github.com/ash/rakupp/tree/main/examples/microbit).
- **The full reference:**
  [docs/guide/MICROBIT.md](https://github.com/ash/rakupp/blob/main/docs/guide/MICROBIT.md),
  with every name of `use MicroBit`, its CODAL call and its MicroPython one,
  and the steps from the C++ to the board.
- **For MicroPython and MakeCode users:**
  [the FAQ](https://github.com/ash/rakupp/blob/main/docs/guide/faq/microbit.md).

No board is needed to start: every program runs on Raku++'s simulated
micro:bit, which prints the serial port and every picture on the LEDs.

## Why a stub

First of all, to reserve the name and make sure the program is accepted by other Raku engines. This also helps to avoid any future conflicts in the module space. (Well, Raku allows tagging module versions with `auth`, so that's not a complete blocker.)

Raku++ does not rely on the ecosystem for this name. It answers `use MicroBit` before
it searches any path or repository, so nothing installed under the name can
change what a Raku++ program gets.

## Scope

- **No API and no simulated board.** The board, its objects and its
  pictures are part of the engine. Nothing here imitates them for another
  Raku; a program that needs them needs Raku++.
- **Nothing to configure.** The module takes no import list and reads no
  environment.

## Install

With Raku++ there is nothing to install: `use MicroBit` is built in, and
`rakupp install MicroBit` says so and skips it.

For other Raku implementations, install this stub with zef:

```
zef install MicroBit
```

A program that says `use MicroBit` then stops at that line with a message
that names rakupp and the command to run it with, instead of
`Could not find MicroBit`.

## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.

## Additional notes

- Design notes:
[notes/MicroBit.md](https://github.com/ash/raku-modules/blob/main/notes/MicroBit.md)
