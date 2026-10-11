# A chirp, whose frequency rises from 0.02 to 0.2 cycles per sample, followed
# along the ridge of its scalogram: at each moment, the scale where |W| is
# largest, turned back into a frequency. A complex Morlet wavelet, because its
# |W| is a smooth envelope where a real wavelet's ripples with the phase.
use Math::Wavelet;

my $N  = 512;
my ($f0, $f1) = 0.02, 0.2;
sub freq($t) { $f0 + ($f1 - $f0) * $t / $N }                  # instantaneous
my @x = (^$N).map(-> $t { sin(2 * π * ($f0 * $t + ($f1 - $f0) * $t² / (2 * $N))) });

my $w  = 'cmor1.5-1.0';
my @f  = (^48).map({ 0.3 * (0.01 / 0.3) ** ($_ / 47) });    # 0.3 … 0.01
my @scales = frequency2scale($w, @f);
my ($W, $freq) = cwt(@x, @scales, $w, :method<fft>);

say "  t   true f   ridge f";
for 64, 128 ... 448 -> $t {
    my $best = (^@scales).max(:by({ $W[$_][$t].abs }));
    printf "%3d   %.4f   %.4f\n", $t, freq($t), $freq[$best];
}
