# Times the ecosystem's Text::Diff (zef:rbt, built on Algorithm::Diff) on the
# same pairs bench.raku uses, for the comparison in Text::Diff::Native's
# README. It is not a dependency of anything here; install it wherever you
# like and point -I at it:
#
#   zef install --/test --install-to="inst#/tmp/td" Text::Diff
#   raku -I"inst#/tmp/td" bench-textdiff.raku 1k 10k
#
# 100k is left out of the defaults: at the rate the smaller two grow it would
# run for about half an hour.

use Text::Diff;

sub MAIN(*@sizes) {
    for (@sizes || <1k 10k>) -> $k {
        my $old = $*PROGRAM.parent.add("old-$k.txt").slurp;
        my $new = $*PROGRAM.parent.add("new-$k.txt").slurp;
        my $t = now;
        my $u = diff($old, $new);
        printf "Text::Diff %5s lines: %8.3f s, %d lines of diff\n", $k, now - $t, $u.lines.elems;
    }
}
