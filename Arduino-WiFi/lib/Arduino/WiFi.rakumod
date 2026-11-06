# A stub. `use Arduino::WiFi` is built into Raku++: rakupp answers the name
# itself, joins the Uno R4 WiFi's network on its simulated board, and compiles
# the program for a real one with `--target=arduino`. That rakupp never loads
# this file. Every other Raku does, and is stopped here with a message saying
# what the program needs.
#
# `die` rather than `note` + `exit`: a program that probes with
# `try require Arduino::WiFi` gets an exception it can catch, not a dead
# process.

unit module Arduino::WiFi;

my $program = $*PROGRAM-NAME eq '-e' || $*PROGRAM-NAME eq '-'
    ?? 'PROGRAM.raku'
    !! $*PROGRAM-NAME;

die $*RAKU.compiler.name eq 'Raku++'
    ?? "This Raku++ does not have `use Arduino::WiFi` built in yet: it arrives\n"
     ~ "with `--target=arduino`. Upgrade it with `rakupp upgrade`, or from\n"
     ~ "https://github.com/ash/rakupp/releases\n"
    !! "This program needs Raku++: `use Arduino::WiFi` is built into rakupp\n"
     ~ "(https://github.com/ash/rakupp), which joins the Uno R4 WiFi's network\n"
     ~ "on a simulated board and compiles the program for a real one:\n"
     ~ "    rakupp $program\n"
     ~ "    rakupp --target=arduino $program\n";
