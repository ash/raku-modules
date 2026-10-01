# A sine with a step in it, buried in noise, recovered by VisuShrink.
use Math::Wavelet;

my $N = 512;
my @clean = (^$N).map({ sin(2 * π * 4 * $_ / $N) + ($_ > $N / 2 ?? 1 !! 0) });

# a fixed linear-congruential source, so both engines draw the same noise
my $seed = 42;
sub uniform { $seed = ($seed * 1103515245 + 12345) % 2 ** 31; $seed / 2 ** 31 }
sub gaussian { sqrt(-2 * log(1 - uniform())) * cos(2 * π * uniform()) }
my @noisy = @clean.map({ $_ + 0.3 * gaussian() });

sub rms(@a, @b) { sqrt(([+] (@a Z- @b).map(* ** 2)) / @a) }

for <haar db4 sym8> -> $w {
    my @c = wavedec(@noisy, $w);
    printf "%-5s σ estimated %.3f (true 0.300)   rms error %.4f → %.4f\n",
        $w, noise-sigma(@c[*-1]), rms(@noisy, @clean),
        rms(denoise(@noisy, $w), @clean);
}
