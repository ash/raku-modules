# A small `diff -u`: prints the unified diff of two files and exits 1 when
# they differ, 0 when they do not — the exit codes diff uses.
#
#   raku   -Ilib examples/udiff.raku OLD NEW
#   rakupp -Ilib examples/udiff.raku -U1 OLD NEW

use Text::Diff::Native;

sub MAIN(Str $old, Str $new, Int :U(:$context) = 3) {
    my $diff = unified-diff($old.IO, $new.IO, :$context);
    print $diff;
    exit $diff ?? 1 !! 0;
}
