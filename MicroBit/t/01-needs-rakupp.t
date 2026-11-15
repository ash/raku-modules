use Test;

# `use MicroBit` must stop a program before any of it runs, and say what the
# program needs — on every Raku except a Raku++ that answers the name itself.
# The programs run in a child, as a user's would: `use` is compile time, so
# the only way to reach the stub in-process is `require`, which is checked
# separately because it must stay catchable.

my $on-rakupp = $*RAKU.compiler.name eq 'Raku++';
my $lib       = $?FILE.IO.parent.parent.add('lib').absolute;

sub run-raku(*@args) {
    my $p = run $*EXECUTABLE, "-I$lib", |@args, :out, :err;
    my $out = $p.out.slurp(:close);
    my $err = $p.err.slurp(:close);
    %(:exit($p.exitcode), :$out, :$err)
}

plan 6;

my %e = run-raku '-e', 'use MicroBit; say "the program ran"';

if $on-rakupp && %e<exit> == 0 {
    # A Raku++ with `use MicroBit` built in: the stub is never loaded.
    pass 'this Raku++ answers `use MicroBit` itself';
    ok %e<out>.contains('the program ran'), '…and runs the program';
    skip 'no stub on this engine', 4;
}
else {
    isnt %e<exit>, 0, '`use MicroBit` stops the program';
    nok %e<out>.contains('the program ran'), '…before any of it runs';

    if $on-rakupp {
        like %e<err>, /'does not have `use MicroBit` built in yet'/,
            'an older Raku++ is told it predates `use MicroBit`';
        like %e<err>, /'rakupp upgrade'/, '…and how to upgrade';
    }
    else {
        like %e<err>, /'This program needs Raku++'/,
            'any other Raku is told the program needs Raku++';
        like %e<err>, /'rakupp --target=microbit PROGRAM.raku'/,
            '…and, for -e, how to compile one';
    }

    my $file = $*TMPDIR.add("microbit-stub-{$*PID}.raku");
    $file.spurt: "use MicroBit;\nsay 'the program ran';\n";
    my %f = run-raku $file.absolute;
    $file.unlink;
    if $on-rakupp {
        like %f<err>, /'built in yet'/, 'a program file gets the same answer';
    }
    else {
        ok %f<err>.contains("rakupp --target=microbit {$file.absolute}"),
            'the message names the program file';
    }

    my $caught = !(try { require ::('MicroBit'); True });
    ok $caught && $!.message.contains('Raku++'),
        '`try require MicroBit` gets a catchable exception';
}
