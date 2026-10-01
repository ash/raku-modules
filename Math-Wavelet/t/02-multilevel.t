use Test;
use lib $*PROGRAM.parent.add('lib').Str;
use Vectors;
use Math::Wavelet;

my @len = cases('length.vec');
my @dec = cases('wavedec.vec');
plan @len + 2 * @dec;

for @len {
    when .[0] eq 'max-level' {
        my (Any, $w, $n, $want) = $_;
        is dwt-max-level(+$n, $w), +$want, "dwt-max-level $n, $w";
    }
    default {
        my (Any, $w, $mode, $n, $want) = $_;
        is dwt-coeff-len(+$n, $w, :$mode), +$want, "dwt-coeff-len $n, $w, $mode";
    }
}

for @dec -> (Any, $w, $mode, $level, $x, $c, $y) {
    my %level = $level eq '-' ?? () !! (level => +$level);
    my @x = nums($x);
    my @c = wavedec(@x, $w, :$mode, |%level);
    close-to @c, list-of($c), "wavedec $w $mode, {+@x} samples, level {+@c - 1}";
    # reconstructed from PyWavelets' coefficients, not from ours
    close-to waverec(list-of($c), $w, :$mode), nums($y), "waverec $w $mode";
}
