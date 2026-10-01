# Keep the largest tenth of the wavelet coefficients, drop the rest, and see
# how much of the signal survives.
use Math::Wavelet;

my @x = (^1024).map({ my $t = $_ / 1024; exp(-30 * ($t - 0.4) ** 2) * sin(60 * $t) + $t });

for <haar db2 db6 sym6 coif3 bior4.4> -> $w {
    my @c    = wavedec(@x, $w, :mode<periodization>);
    my @mags = @c.map(|*).map(*.abs).sort(-*);
    my $keep = @mags[@mags div 10];
    my @y    = waverec(threshold(@c, $keep, :mode<hard>), $w, :mode<periodization>);
    my $err  = sqrt(([+] (@x Z- @y).map(* ** 2)) / ([+] @x.map(* ** 2)));
    printf "%-8s keeps %d of %d coefficients, relative error %.2e\n",
        $w, +@c.map(|*).grep(*.abs >= $keep), +@mags, $err;
}
