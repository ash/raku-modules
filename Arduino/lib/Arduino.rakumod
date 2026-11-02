# A stub. `use Arduino` is built into Raku++: rakupp answers the name itself,
# runs the program against a simulated board, and compiles it for a real one
# with `--target=arduino`. That rakupp never loads this file. Every other Raku
# does, and is stopped here with a message saying what the program needs.
#
# `die` rather than `note` + `exit`: a program that probes with
# `try require Arduino` gets an exception it can catch, not a dead process.

unit module Arduino;

my $program = $*PROGRAM-NAME eq '-e' || $*PROGRAM-NAME eq '-'
    ?? 'PROGRAM.raku'
    !! $*PROGRAM-NAME;

die $*RAKU.compiler.name eq 'Raku++'
    ?? "This Raku++ does not have `use Arduino` built in yet: it arrives with\n"
     ~ "`--target=arduino`. Upgrade it with `rakupp upgrade`, or from\n"
     ~ "https://github.com/ash/rakupp/releases\n"
    !! "This program needs Raku++: `use Arduino` is built into rakupp\n"
     ~ "(https://github.com/ash/rakupp), which runs it against a simulated board\n"
     ~ "and compiles it for a real one:\n"
     ~ "    rakupp $program\n"
     ~ "    rakupp --target=arduino $program\n";
