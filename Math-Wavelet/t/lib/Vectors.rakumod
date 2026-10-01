use Test;

#| The cases of t/vectors/$name, one list of tab-separated fields each.
sub cases(Str $name) is export {
    $*PROGRAM.parent.add("vectors/$name").lines
        .grep({ $_ && !.starts-with('#') }).map(*.split("\t").List).List
}

#| A numeric field: doubles, '|'-separated arrays of them, or '-' for none.
sub nums(Str $f) is export { $f eq '-' ?? Nil !! $f.words.map(*.Num).Array }
sub list-of(Str $f) is export { $f.split('|').map(&nums).Array }
sub matrix(Str $f) is export { $f.split(';').map(&nums).Array }

#| Agreement to a part in 10¹⁰ of the largest value: the sums run in a
#| different order than PyWavelets' C, so the last bits may differ. Nested
#| arrays are compared flattened, after their shapes.
sub close-to($got, $want, Str $what) is export {
    sub shape($x) { $x ~~ Positional ?? '[' ~ $x.map(&shape).join(',') ~ ']' !! '.' }
    sub flat($x)  { $x ~~ Positional ?? $x.map(&flat).flat !! ($x,) }
    return flunk("$what — shape {shape($got).substr(0, 60)}, expected {shape($want).substr(0, 60)}")
        if shape($got) ne shape($want);
    my @g = flat($got);
    my @w = flat($want);
    my $scale = 1 + (@w.map(*.abs).max max 0);
    my $err = (@g Z- @w).map(*.abs).max max 0;
    ok $err <= 1e-10 * $scale, $what
        or diag "largest difference $err";
}
