# A stub. `use Arduino::LEDMatrix` is built into Raku++: rakupp answers the
# name itself, draws the Uno R4 WiFi's LED matrix on its simulated board, and
# compiles the program for a real one with `--target=arduino`. That rakupp
# never loads this file. Every other Raku does, and is stopped here with a
# message saying what the program needs.
#
# `die` rather than `note` + `exit`: a program that probes with
# `try require Arduino::LEDMatrix` gets an exception it can catch, not a dead
# process.

unit module Arduino::LEDMatrix;

my $program = $*PROGRAM-NAME eq '-e' || $*PROGRAM-NAME eq '-'
    ?? 'PROGRAM.raku'
    !! $*PROGRAM-NAME;

die $*RAKU.compiler.name eq 'Raku++'
    ?? "This Raku++ does not have `use Arduino::LEDMatrix` built in yet: it arrives\n"
     ~ "with `--target=arduino`. Upgrade it with `rakupp upgrade`, or from\n"
     ~ "https://github.com/ash/rakupp/releases\n"
    !! "This program needs Raku++: `use Arduino::LEDMatrix` is built into rakupp\n"
     ~ "(https://github.com/ash/rakupp), which draws the Uno R4 WiFi's LED matrix\n"
     ~ "on a simulated board and compiles the program for a real one:\n"
     ~ "    rakupp $program\n"
     ~ "    rakupp --target=arduino $program\n";
