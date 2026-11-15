# A stub. `use MicroBit` is built into Raku++: rakupp answers the name itself,
# runs the program on a simulated BBC micro:bit, and compiles it for a real
# one with `--target=microbit`. That rakupp never loads this file. Every other
# Raku does, and is stopped here with a message saying what the program needs.
#
# `die` rather than `note` + `exit`: a program that probes with
# `try require MicroBit` gets an exception it can catch, not a dead process.

unit module MicroBit;

my $program = $*PROGRAM-NAME eq '-e' || $*PROGRAM-NAME eq '-'
    ?? 'PROGRAM.raku'
    !! $*PROGRAM-NAME;

die $*RAKU.compiler.name eq 'Raku++'
    ?? "This Raku++ does not have `use MicroBit` built in yet: it arrives with\n"
     ~ "`--target=microbit`. Upgrade it with `rakupp upgrade`, or from\n"
     ~ "https://github.com/ash/rakupp/releases\n"
    !! "This program needs Raku++: `use MicroBit` is built into rakupp\n"
     ~ "(https://github.com/ash/rakupp), which runs it on a simulated micro:bit\n"
     ~ "and compiles it for a real one:\n"
     ~ "    rakupp $program\n"
     ~ "    rakupp --target=microbit $program\n";
