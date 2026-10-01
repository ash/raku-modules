# A two-level 2-D decomposition of a small synthetic image: where its energy
# goes, and which detail band sees which kind of edge. Periodization, because
# it is the mode in which an orthogonal wavelet preserves energy exactly.
use Math::Wavelet;

my $n = 64;
# a horizontal edge, a vertical edge, and a diagonal ramp
my @img = (^$n).map(-> $r { (^$n).map(-> $c {
    ($r >= 20 ?? 1 !! 0) + ($c >= 44 ?? 2 !! 0) + ($r + $c) / (2 * $n)
}).Array }).Array;

sub energy(@m) { [+] @m.map(|*).map(* ** 2) }
my $total = energy(@img);

my @c = wavedec2(@img, 'db2', :level(2), :mode<periodization>);
printf "cA2  %6.3f%%\n", 100 * energy(@c[0]) / $total;
for 1 .. 2 -> $i {
    my $level = 3 - $i;
    my ($h, $v, $d) = @c[$i];
    printf "cH%d  %6.3f%%   cV%d  %6.3f%%   cD%d  %6.3f%%\n",
        $level, 100 * energy($h) / $total, $level, 100 * energy($v) / $total,
        $level, 100 * energy($d) / $total;
}

my @back = waverec2(@c, 'db2', :mode<periodization>);
printf "reconstruction error %.1e\n",
    (@back.map(|*) Z- @img.map(|*)).map(*.abs).max;
