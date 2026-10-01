use Math::Wavelet::DWT;

#| Thresholding, and wavelet denoising built on it.
unit module Math::Wavelet::Threshold;

our constant THRESHOLD-MODES = <soft hard garrote greater less>;

sub one(Num $x, Num $v, Str $mode, Num $sub --> Num) {
    my $m = $x.abs;
    given $mode {
        when 'soft'    { $m < $v ?? $sub !! $m == 0e0 ?? 0e0 !! $x * max(0e0, 1e0 - $v / $m) }
        when 'garrote' { $m < $v ?? $sub !! $m == 0e0 ?? 0e0 !! $x * max(0e0, 1e0 - ($v * $v) / ($m * $m)) }
        when 'hard'    { $m < $v ?? $sub !! $x }
        when 'greater' { $x < $v ?? $sub !! $x }
        when 'less'    { $x > $v ?? $sub !! $x }
    }
}

#| Each value of @data thresholded at $value; nested arrays are followed, so
#| a matrix or a whole coefficient list can be given.
our sub threshold(@data, Numeric:D $value, Str :$mode = 'soft',
                  Numeric :$substitute = 0 --> Array) is export
{
    die "Unknown threshold mode '$mode'; the known ones are {THRESHOLD-MODES.join(', ')}"
        unless $mode (elem) THRESHOLD-MODES;
    my ($v, $s) = $value.Num, $substitute.Num;
    @data.map({ $_ ~~ Positional ?? threshold($_, $v, :$mode, :substitute($s))
                                 !! one(.Num, $v, $mode, $s) }).Array
}

sub median(@x) {
    my @s = @x.sort;
    @s %% 2 ?? (@s[@s/2 - 1] + @s[@s/2]) / 2 !! @s[@s div 2]
}

#| The noise level a detail band suggests: its median absolute value over
#| 0.6745, the Gaussian's median absolute deviation.
our sub noise-sigma(@detail --> Num) is export {
    (median(@detail.map(*.abs)) / 0.6745e0).Num
}

#| VisuShrink: decompose, threshold every detail level at the universal
#| threshold σ·√(2 ln N), and reconstruct to the original length.
our sub denoise(@data, $wavelet, Int :$level, Str :$mode = 'soft',
                Numeric :$threshold, Str :$extension = 'symmetric') is export
{
    my @c = wavedec(@data, $wavelet, :$level, :mode($extension));
    my $t = $threshold // noise-sigma(@c[*-1]) * sqrt(2 * log(+@data));
    @c[1..*] = @c[1..*].map({ threshold($_, $t, :$mode) });
    waverec(@c, $wavelet, :mode($extension))[^@data].Array
}
