use Test;

# `use Arduino::WiFi` must stop a program before any of it runs, and say
# what the program needs — on every Raku except a Raku++ that answers the name
# itself. The programs run in a child, as a user's would: `use` is compile
# time, so the only way to reach the stub in-process is `require`, which is
# checked separately because it must stay catchable.

my $on-rakupp = $*RAKU.compiler.name eq 'Raku++';
my $lib       = $?FILE.IO.parent.parent.add('lib').absolute;

sub run-raku(*@args) {
    my $p = run $*EXECUTABLE, "-I$lib", |@args, :out, :err;
    my $out = $p.out.slurp(:close);
    my $err = $p.err.slurp(:close);
    %(:exit($p.exitcode), :$out, :$err)
}

plan 6;

my %e = run-raku '-e', 'use Arduino::WiFi; say "the program ran"';

if $on-rakupp && %e<exit> == 0 {
    # A Raku++ with `use Arduino::WiFi` built in: the stub is never loaded.
    pass 'this Raku++ answers `use Arduino::WiFi` itself';
    ok %e<out>.contains('the program ran'), '…and runs the program';
    skip 'no stub on this engine', 4;
}
else {
    isnt %e<exit>, 0, '`use Arduino::WiFi` stops the program';
    nok %e<out>.contains('the program ran'), '…before any of it runs';

    if $on-rakupp {
        like %e<err>, /'does not have `use Arduino::WiFi` built in yet'/,
            'an older Raku++ is told it predates `use Arduino::WiFi`';
        like %e<err>, /'rakupp upgrade'/, '…and how to upgrade';
    }
    else {
        like %e<err>, /'This program needs Raku++'/,
            'any other Raku is told the program needs Raku++';
        like %e<err>, /'rakupp --target=arduino PROGRAM.raku'/,
            '…and, for -e, how to compile one';
    }

    my $file = $*TMPDIR.add("arduino-wifi-stub-{$*PID}.raku");
    $file.spurt: "use Arduino::WiFi;\nsay 'the program ran';\n";
    my %f = run-raku $file.absolute;
    $file.unlink;
    if $on-rakupp {
        like %f<err>, /'built in yet'/, 'a program file gets the same answer';
    }
    else {
        ok %f<err>.contains("rakupp --target=arduino {$file.absolute}"),
            'the message names the program file';
    }

    my $caught = !(try { require ::('Arduino::WiFi'); True });
    ok $caught && $!.message.contains('Raku++'),
        '`try require Arduino::WiFi` gets a catchable exception';
}
