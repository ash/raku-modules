# Times unified-diff on the pairs gen.raku writes, best of three runs.
#
#   cd Text-Diff-Native
#   raku   -Ilib ../benchmarks/diff/bench.raku
#   rakupp -Ilib ../benchmarks/diff/bench.raku
#   TEXT_DIFF_NATIVE_BACKEND=raku rakupp -Ilib ../benchmarks/diff/bench.raku
#
# From the distribution directory, because that is where a git checkout's
# built extension is found (resources/libraries/, relative to the CWD).

use Text::Diff::Native;

say "{$*RAKU.compiler.name} {$*RAKU.compiler.version}, backend {diff-backend}";
for <1k 10k 100k> -> $k {
    my ($a, $b) = $*PROGRAM.parent.add("old-$k.txt"), $*PROGRAM.parent.add("new-$k.txt");
    next unless $a.e;
    my @t;
    my $out;
    for ^3 {
        my $t0 = now;
        $out = unified-diff($a, $b);
        @t.push(now - $t0);
    }
    printf "%5s lines: %8.3f s, %d lines of diff\n", $k, @t.min, $out.lines.elems;
}
