# Arduino

This is a module aimed to support Raku-for-Arduino development.

Processing `use Arduino` itself is a part of the [Raku++](https://github.com/ash/rakupp) engine:
`rakupp` answers the name itself. No module installation needed. On any other Raku this module stops the program at the `use` line.

## Version

0.0.1

## Synopsis

```raku
use Arduino;

constant LED   = 9; # a PWM pin
constant @wave = (^32).map: { (127.5 + 127.5 * sin(2 * pi * $_ / 32)).Int };

pinMode(LED, OUTPUT); # the mainline before the loop: setup()
say "a wave of {@wave.elems} steps";

loop { # the top-level loop: loop()
    state uint8 $i = 0;
    analogWrite(LED, @wave[$i++ % @wave.elems]);
    delay(20);
}
```

Running the program:

```bash
rakupp fade.raku                       # on the simulated board
rakupp --target=arduino fade.raku      # the sketch for a real one
```

## Getting started

- **A walkthrough**, from a blinking LED to the Uno R4 WiFi's LED matrix,
  with a program for each step:
  [examples/arduino](https://github.com/ash/rakupp/tree/main/examples/arduino).
- **On the web:** [raku.online/arduino](https://raku.online/arduino/).
- **The full reference:**
  [docs/guide/ARDUINO.md](https://github.com/ash/rakupp/blob/main/docs/guide/ARDUINO.md),
  with every type, function and construct a board program can use.

No board is needed to start: every program runs on Raku++'s simulated board,
which prints the serial port and every pin change.

## Why a stub

First of all, to reserve the name and make sure the program is accepted by other Raku engines. This also helps to avoid any future conflicts in the module space. (Well, Raku allows tagging module versions with `auth`, so that's not a complete blocker.)

Raku++ does not rely on the ecosystem for this name. It answers `use Arduino` before
it searches any path or repository, so nothing installed under the name can
change what a Raku++ program gets.

## Scope

- **No API and no simulated board.** The board, its functions and its
  constants are part of the engine. Nothing here imitates them for another
  Raku; a program that needs them needs Raku++.
- **Nothing to configure.** The module takes no import list and reads no
  environment.

## Install

With Raku++ there is nothing to install: `use Arduino` is built in, and
`rakupp install Arduino` says so and skips it.

For other Raku implementations, install this stub with zef:

```
zef install Arduino
```

A program that says `use Arduino` then stops at that line with a message
that names rakupp and the command to run it with, instead of
`Could not find Arduino`.


## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.

## Additional notes

- Design notes:
[notes/Arduino.md](https://github.com/ash/raku-modules/blob/main/notes/Arduino.md)
