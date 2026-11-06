# Arduino::WiFi

This is a module for the WiFi of the Arduino Uno R4 WiFi, in Raku-for-Arduino
programs.

Processing `use Arduino::WiFi` itself is a part of the
[Raku++](https://github.com/ash/rakupp) engine: `rakupp` answers the name
itself, as it answers `use Arduino`. No module installation needed. On any
other Raku this module stops the program at the `use` line.

## Version

0.0.1

## Synopsis

```raku
use Arduino;
use Arduino::WiFi;

constant SSID = %*ENV<WIFI_SSID> // die "set WIFI_SSID to the network's name";
constant PASS = %*ENV<WIFI_PASS> // die "set WIFI_PASS to its password";

until WiFi.begin(SSID, PASS) == WL_CONNECTED {
    say "not yet: status {WiFi.status}";
    delay(5000);
}
say "joined, address {WiFi.localIP}";
```

Running the program:

```bash
WIFI_SSID=home WIFI_PASS=secret rakupp wifi.raku                       # on the simulated board
WIFI_SSID=home WIFI_PASS=secret rakupp --target=arduino wifi.raku      # the sketch for a real one
```

The network's name and password are constants, so they are read while the
program is built, here from the environment, and the program's source holds
neither. The sketch calls the Uno R4 core's WiFiS3 library: `WiFi.begin`,
`WiFi.status`, `WiFi.localIP` and `WiFi.disconnect`. On the simulated board
the network is simulated too, and each attempt to join is a line on stderr.

## Getting started

The walkthrough in
[examples/arduino](https://github.com/ash/rakupp/tree/main/examples/arduino)
ends with joining a network; it is also at
[raku.online/arduino](https://raku.online/arduino/). The full reference is
the
[network section](https://github.com/ash/rakupp/blob/main/docs/guide/ARDUINO.md#the-network-uno-r4-wifi)
of the Raku++ Arduino guide.

## Why a stub

For the same reasons as the
[Arduino](https://github.com/ash/raku-modules/tree/main/Arduino) stub: to reserve the name,
and to make a program written for Raku++ say what it needs on other Raku
engines instead of failing to find the module.

Raku++ does not rely on the ecosystem for this name. It answers
`use Arduino::WiFi` before it searches any path or repository, so nothing
installed under the name can change what a Raku++ program gets.

## Scope

- **No API and no simulated network.** `WiFi`, the `WL_*` statuses and the
  simulation are part of the engine. Nothing here imitates them for another
  Raku; a program that needs them needs Raku++.
- **Nothing to configure.** The module takes no import list and reads no
  environment.

## Install

With Raku++ there is nothing to install: `use Arduino::WiFi` is built in, and
`rakupp install Arduino::WiFi` says so and skips it.

For other Raku implementations, install this stub with zef:

```
zef install Arduino::WiFi
```

A program that says `use Arduino::WiFi` then stops at that line with a
message that names rakupp, instead of `Could not find Arduino::WiFi`.

## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.

## Additional notes

- Design notes:
[notes/Arduino.md](https://github.com/ash/raku-modules/blob/main/notes/Arduino.md)
