# Arduino::LEDMatrix

This is a module for the 12×8 LED matrix of the Arduino Uno R4 WiFi, in
Raku-for-Arduino programs.

Processing `use Arduino::LEDMatrix` itself is a part of the
[Raku++](https://github.com/ash/rakupp) engine: `rakupp` answers the name
itself, as it answers `use Arduino`. No module installation needed. On any
other Raku this module stops the program at the `use` line.

## Version

0.0.1

## Synopsis

```raku
use Arduino;
use Arduino::LEDMatrix;

constant @HEART = frame q:to/END/;
    ..##...##...
    .#..#.#..#..
    .#...#...#..
    .#.......#..
    ..#.....#...
    ...#...#....
    ....#.#.....
    .....#......
    END

LEDMatrix.begin;
loop {
    LEDMatrix.show(@HEART);  delay(500);
    LEDMatrix.clear;         delay(500);
}
```

Running the program:

```bash
rakupp heart.raku                       # on the simulated board
rakupp --target=arduino heart.raku      # the sketch for a real one
```

`frame` runs while the program is built: it packs the picture into the three
32-bit words the Uno R4 core's Arduino_LED_Matrix library takes, and the board
gets only those twelve bytes. On the simulated board, each new picture is
drawn on stderr with `#` and `.`.

## Why a stub

For the same reasons as the
[Arduino](https://github.com/ash/raku-modules/tree/main/Arduino) stub: to reserve the name,
and to make a program written for Raku++ say what it needs on other Raku
engines instead of failing to find the module.

Raku++ does not rely on the ecosystem for this name. It answers
`use Arduino::LEDMatrix` before it searches any path or repository, so
nothing installed under the name can change what a Raku++ program gets.

## Scope

- **No API and no simulated matrix.** `frame`, `LEDMatrix` and the drawing
  are part of the engine. Nothing here imitates them for another Raku; a
  program that needs them needs Raku++.
- **Nothing to configure.** The module takes no import list and reads no
  environment.

## Install

```
rakupp install Arduino::LEDMatrix
```

Alternatively:

```
zef install Arduino::LEDMatrix
```

## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.

## Additional notes

- Design notes:
[notes/Arduino.md](https://github.com/ash/raku-modules/blob/main/notes/Arduino.md)
