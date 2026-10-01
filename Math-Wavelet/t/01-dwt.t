use Test;
use lib $*PROGRAM.parent.add('lib').Str;
use Vectors;
use Math::Wavelet;

# Every expected value in t/vectors was computed by PyWavelets — see
# tools/gen-vectors.py — over every signal-extension mode, a wavelet from each
# family, and signals from one sample up to longer than the filter.

my @cases = cases('dwt.vec');
plan +@cases;

for @cases -> ($kind, $w, $mode, $f1, $f2, $f3) {
    if $kind eq 'dwt' {
        my @x = nums($f1);
        my ($a, $d) = dwt(@x, $w, :$mode);
        close-to [$a, $d], [nums($f2), nums($f3)], "dwt $w $mode, {+@x} samples";
    }
    else {
        my ($ca, $cd) = nums($f1), nums($f2);
        close-to idwt($ca, $cd, $w, :$mode), nums($f3),
            "idwt $w $mode, {($ca // $cd).elems} coefficients"
              ~ ($ca.defined && $cd.defined ?? '' !! ', one half absent');
    }
}
