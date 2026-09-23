# Text::Diff::Native against GNU diff, on random pairs of files.
#
#   cd Text-Diff-Native
#   raku   -Ilib ../benchmarks/diff/against-gnu.raku [cases] [seed]
#   rakupp -Ilib ../benchmarks/diff/against-gnu.raku [cases] [seed]
#
# For every pair it checks that
#   1. `patch` turns the old file into the new one with our diff;
#   2. our diff changes exactly as many lines as `diff --minimal` does — so
#      it is minimal, since GNU's is;
# and it counts how often our output is byte for byte `diff -u --minimal`'s,
# and plain `diff -u`'s. The first two must hold for every case; the counts
# are only information: where several minimal diffs exist, two programs may
# rightly choose different ones.

use Text::Diff::Native;

sub MAIN(Int $cases = 300, Int $seed = 1) {
    # our own generator, so both engines see the same files
    my $state = $seed;
    sub rnd(Int $n) { $state = ($state * 1103515245 + 12345) % 2**31; $state % $n }

    my $dir = $*TMPDIR.add("tdn-gnu-{$*PID}");
    $dir.mkdir;
    my ($a, $b, $d, $o) = <a b d o>.map({ $dir.add($_) });
    my ($applied, $minimal, $same-min, $same-plain) = 0 xx 4;

    for ^$cases -> $case {
        my $alpha = 2 + rnd(6);                # few distinct lines: many matches
        my @old = (^rnd(40)).map({ ('a'..'z')[rnd($alpha)] });
        my @new = @old.clone;
        for ^(1 + rnd(8)) {
            my $at = rnd(@new.elems + 1);
            given rnd(3) {
                when 0 { @new.splice($at, 0, ('a'..'z')[rnd($alpha)]) }
                when 1 { @new.splice($at, 1) if @new }
                when 2 { @new[$at] = ('a'..'z')[rnd($alpha)] if $at < @new }
            }
        }
        my $ot = @old.map(* ~ "\n").join ~ (rnd(5) == 0 ?? 'tail' !! '');
        my $nt = @new.map(* ~ "\n").join ~ (rnd(5) == 0 ?? 'tail' !! '');
        $a.spurt($ot);
        $b.spurt($nt);

        my $ours = unified-diff($ot, $nt, :from<a>, :to<b>, :context(rnd(4)));
        $d.spurt($ours);
        if $ours eq '' {
            $applied++ if $ot eq $nt;
        }
        else {
            run 'patch', '-s', '-o', $o.Str, $a.Str, $d.Str, :out, :err;
            $applied++ if $o.e && $o.slurp(:bin).decode eq $nt;
            $o.unlink;
        }

        my sub count(Str $u) { $u.lines.grep(/^ <[+-]> <![+-]>/).elems }
        my sub gnu(*@opt) {
            my $p = run 'diff', |@opt, '--label', 'a', '--label', 'b', $a.Str, $b.Str, :out;
            $p.out.slurp(:bin, :close).decode
        }
        # patch was given a random context; GNU is compared at its default
        my $ours3 = unified-diff($ot, $nt, :from<a>, :to<b>);
        my $gmin = gnu('-u', '--minimal');
        $minimal++    if count($ours3) == count($gmin);
        $same-min++   if $ours3 eq $gmin;
        $same-plain++ if $ours3 eq gnu('-u');
        note "case $case: not minimal\n$ours3\nGNU:\n$gmin" if count($ours3) != count($gmin);
    }
    $dir.dir».unlink;
    $dir.rmdir;

    say "backend: {diff-backend}, $cases cases, seed $seed";
    say "patch applies:            $applied / $cases";
    say "as short as --minimal:    $minimal / $cases";
    say "identical to -u --minimal: $same-min / $cases";
    say "identical to -u:           $same-plain / $cases";
    exit($applied == $cases && $minimal == $cases ?? 0 !! 1);
}
