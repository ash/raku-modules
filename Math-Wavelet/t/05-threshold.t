use Test;
use lib $*PROGRAM.parent.add('lib').Str;
use Vectors;
use Math::Wavelet;

my @thr = cases('threshold.vec');
my @den = cases('denoise.vec');
plan @thr + 3 * @den + 2;

for @thr -> (Any, $mode, $value, $sub, $x, $y) {
    close-to threshold(nums($x), +$value, :$mode, :substitute(+$sub)), nums($y),
        "threshold $mode at $value, substitute $sub";
}

for @den -> (Any, $w, $level, $mode, $sigma, $t, $x, $y) {
    my %level = $level eq '-' ?? () !! (level => +$level);
    my @x = nums($x);
    my @c = wavedec(@x, $w, |%level);
    is-approx noise-sigma(@c[*-1]), +$sigma, "noise-sigma, $w";
    close-to denoise(@x, $w, :$mode, |%level), nums($y), "denoise $w $mode";
    close-to denoise(@x, $w, :$mode, :threshold(+$t), |%level), nums($y),
        "denoise $w $mode, the threshold given";
}

close-to threshold([[3, -0.5], [0.5, -3]], 1), [[2, 0], [0, -2]], 'a matrix is thresholded element-wise';
throws-like { threshold([1], 1, :mode<firm>) }, Exception, 'an unknown mode dies';
