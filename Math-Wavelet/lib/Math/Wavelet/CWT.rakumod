use Math::Wavelet::Continuous;

#| The continuous wavelet transform, and the frequencies its scales stand for.
#| PyWavelets' algorithm, step for step: ψ is integrated once, resampled for
#| each scale, convolved with the signal and differentiated.
unit module Math::Wavelet::CWT;

our sub as-continuous($w --> Math::Wavelet::Continuous) {
    return $w if $w ~~ Math::Wavelet::Continuous;
    die "'$w' is a discrete wavelet; the continuous transform takes one of "
        ~ "wavelist(:kind<continuous>)"
        unless Math::Wavelet::Continuous.is-continuous(~$w);
    Math::Wavelet::Continuous.named(~$w)
}

#| ∫ψ, as a running sum over `wavefun(:level($precision))`. Returns
#| `(integral, x)`.
our sub integrate-wavelet($wavelet, Int :$precision = 8 --> List) is export {
    my ($psi, $x) = as-continuous($wavelet).wavefun(:level($precision));
    my $step = $x[1] - $x[0];
    my $sum = 0e0;
    ($psi.map({ ($sum += $_) * $step }).Array, $x)
}

#| The frequency, in cycles per sample at scale 1, at which ψ's spectrum
#| peaks — found as PyWavelets finds it, from the largest bin of an FFT over
#| `2**$precision` samples.
our sub central-frequency($wavelet, Int :$precision = 8 --> Num) is export {
    my ($psi, $x) = as-continuous($wavelet).wavefun(:level($precision));
    my $domain = $x[*-1] - $x[0];
    my ($re, $im) = fft(|split-complex($psi));
    my $n = +$psi;
    # the largest magnitude past the zero-frequency bin; the first one wins
    my ($best, $at) = -1e0, 1;
    for 1 ..^ $n -> $k {
        my $m = sqrt($re[$k]² + $im[$k]²);
        ($best, $at) = $m, $k if $m > $best;
    }
    my $index = $at + 1;
    $index = $n - $index + 2 if $index > $n / 2;
    1 / ($domain / ($index - 1))
}

#| The frequency each scale corresponds to, in cycles per sample.
our sub scale2frequency($wavelet, $scale, Int :$precision = 8) is export {
    my $f = central-frequency($wavelet, :$precision);
    $scale ~~ Iterable ?? $scale.map({ $f / $_ }).Array !! $f / $scale
}

#| The scale each frequency corresponds to.
our sub frequency2scale($wavelet, $frequency, Int :$precision = 8) is export {
    my $f = central-frequency($wavelet, :$precision);
    $frequency ~~ Iterable ?? $frequency.map({ $f / $_ }).Array !! $f / $frequency
}

#| The continuous wavelet transform of `@data` at each of `@scales`. Returns
#| `(coefficients, frequencies)`: a row of `+@data` coefficients per scale —
#| Num, or Complex for a complex wavelet — and the frequency each scale stands
#| for, in cycles per `$sampling-period`.
#|
#| `:method<conv>` convolves directly and costs `n·m` per scale for a kernel
#| of `m` taps, which grows with the scale; `:method<fft>` convolves through
#| the FFT and costs `N log N`. They agree to rounding.
our sub cwt(@data, $scales, $wavelet, Real :$sampling-period = 1,
            Str :$method = 'conv' --> List) is export {
    my $w = as-continuous($wavelet);
    die "method must be 'conv' or 'fft'" unless $method eq 'conv' | 'fft';
    # a list of scales is anything iterable: an Array, a Range, or the Seq that
    # `@f.map({ $cf / $_ })` makes — not only a Positional, which a Seq is not
    my @scales = ($scales ~~ Iterable ?? $scales.list !! ($scales,)).map(*.Num);
    die '`scales` must only include positive values' if @scales.first(* <= 0).defined;
    my @x = @data.map(*.Num);
    my $n = +@x;
    die 'cwt needs at least one sample' unless $n;

    # PyWavelets fixes the integration at 2¹⁰ samples of ψ.
    my $precision = 10;
    my ($int, $grid) = integrate-wavelet($w, :$precision);
    my ($int-re, $int-im) = split-complex($int);
    # the transform correlates with ψ, so a complex ψ is conjugated
    $int-im = $int-im.map(-*).Array if $w.complex-cwt;
    my $size  = +$int;
    my $step  = $grid[1] - $grid[0];
    my $range = $grid[*-1] - $grid[0];

    my @rows;
    my %spectra;      # FFT size => the signal's spectrum at that size
    for @scales -> $s {
        # ψ stretched by the scale: every sample of the integral that the
        # stretched grid lands on, back to front.
        my $taps = ($s * $range + 1).ceiling;
        my @j = (^$taps).map({ ($_ / ($s * $step)).floor }).grep(* < $size);
        my @k-re = @j.reverse.map({ $int-re[$_] });
        my @k-im = $w.complex-cwt ?? @j.reverse.map({ $int-im[$_] }) !! ();

        my ($conv-re, $conv-im) = $method eq 'fft'
            ?? fft-convolve(@x, @k-re, @k-im, %spectra)
            !! (direct-convolve(@x, @k-re),
                $w.complex-cwt ?? direct-convolve(@x, @k-im) !! Nil);

        my $len = $conv-re.elems - 1;            # after the difference
        my $d = ($len - $n) / 2;
        die "Selected scale of $s too small." if $d < 0;
        my $from = $d.floor;
        my $to   = $len - $d.ceiling;            # one past the last
        my $k = -sqrt($s);
        @rows.push: $w.complex-cwt
            ?? ($from ..^ $to).map(-> $i {
                   Complex.new($k * ($conv-re[$i + 1] - $conv-re[$i]),
                               $k * ($conv-im[$i + 1] - $conv-im[$i]))
               }).Array
            !! ($from ..^ $to).map(-> $i { $k * ($conv-re[$i + 1] - $conv-re[$i]) }).Array;
    }

    my $f = central-frequency($w, :$precision);
    (@rows, @scales.map({ $f / $_ / $sampling-period }).Array)
}

# ---------- the arithmetic ----------

#| The real and imaginary parts of a list, as two lists of Num.
sub split-complex(@v --> List) {
    @v[0] ~~ Complex
        ?? (@v.map(*.re.Num).Array, @v.map(*.im.Num).Array)
        !! (@v.map(*.Num).Array, (0e0 xx @v).Array)
}

#| The full linear convolution of two real sequences: `@a + @b − 1` values.
sub direct-convolve(@a, @b) {
    my int $na = +@a;
    my int $nb = +@b;
    my num @out = 0e0 xx ($na + $nb - 1);
    my num @A = @a;
    my num @B = @b;
    my int $i; my int $j;
    my num $v;
    $i = 0;
    while $i < $na {
        $v = @A[$i];
        $j = 0;
        while $j < $nb {
            @out[$i + $j] = @out[$i + $j] + $v * @B[$j];
            $j = $j + 1;
        }
        $i = $i + 1;
    }
    @out
}

#| The full linear convolution of the real signal `@x` with a kernel whose
#| real parts are `@kr` and imaginary parts `@ki` (empty for a real kernel),
#| through the FFT. Returns the real and imaginary parts of the result.
#|
#| Because `@x` is real, a complex kernel needs no more work than a real one:
#| one forward transform of the kernel, one product, one inverse — and the
#| real and imaginary parts of what comes back are the two convolutions.
#| The signal's own spectrum depends only on the size, and is kept in
#| `%spectra` from one scale to the next.
sub fft-convolve(@x, @kr, @ki, %spectra --> List) {
    my int $nx   = +@x;
    my int $nk   = +@kr;
    my int $want = $nx + $nk - 1;
    my int $size = 1;
    $size = $size +< 1 while $size < $want;

    my int $t;
    my ($xr, $xi) = (%spectra{$size} //= do {
        my num @r = 0e0 xx $size;
        my num @i = 0e0 xx $size;
        loop ($t = 0; $t < $nx; $t = $t + 1) { @r[$t] = @x[$t] }
        fft(@r, @i).List
    }).list;

    my num @r = 0e0 xx $size;
    my num @i = 0e0 xx $size;
    loop ($t = 0; $t < $nk; $t = $t + 1) { @r[$t] = @kr[$t] }
    if @ki {
        loop ($t = 0; $t < $nk; $t = $t + 1) { @i[$t] = @ki[$t] }
    }
    my ($kr, $ki) = fft(@r, @i);

    my num @pr = 0e0 xx $size;
    my num @pi = 0e0 xx $size;
    my num @XR := $xr;
    my num @XI := $xi;
    my num @KR := $kr;
    my num @KI := $ki;
    loop ($t = 0; $t < $size; $t = $t + 1) {
        @pr[$t] = @XR[$t] * @KR[$t] - @XI[$t] * @KI[$t];
        @pi[$t] = @XR[$t] * @KI[$t] + @XI[$t] * @KR[$t];
    }
    my ($cr, $ci) = fft(@pr, @pi, :inverse);
    ($cr.head($want).Array, @ki ?? $ci.head($want).Array !! Nil)
}

# The twiddle factors e^(−2πik/N) for k < N/2, one table per size, shared by
# every stage through a stride. Filled under a lock: the transform may run on
# several threads at once.
my %TWIDDLES;
my $twiddle-lock = Lock.new;
sub twiddles(Int $n --> List) {
    $twiddle-lock.protect: {
        %TWIDDLES{$n} //= do {
            my num @c = (^($n div 2)).map({ cos(2 * π * $_ / $n) });
            my num @s = (^($n div 2)).map({ sin(2 * π * $_ / $n) });
            (@c, @s)
        }
    }
}

#| A radix-2 FFT of a power-of-two length, on copies of its input.
#| `:inverse` includes the 1/N.
sub fft(@re-in, @im-in, Bool :$inverse = False --> List) {
    my int $n = +@re-in;
    die "fft needs a power-of-two length, not $n" unless $n +& ($n - 1) == 0;
    my num @re = @re-in;
    my num @im = @im-in;
    my ($c, $s) = twiddles($n);
    my num @wc := $c;
    my num @ws := $s;
    # e^(+2πik/N) for the inverse: the same table, sine negated
    my num $sign = $inverse ?? 1e0 !! -1e0;
    # Every local is declared once, out here: under Raku++ a `my` inside the
    # innermost loop costs more than the butterfly does.
    my int $i; my int $j; my int $bit; my int $len; my int $half; my int $stride; my int $start; my int $k; my int $w; my int $p; my int $q;
    my num $t; my num $wr; my num $wi; my num $tr; my num $ti;

    # bit reversal
    $j = 0;
    $i = 1;
    while $i < $n {
        $bit = $n +> 1;
        while $j +& $bit { $j = $j +^ $bit; $bit = $bit +> 1 }
        $j = $j +^ $bit;
        if $i < $j {
            $t = @re[$i]; @re[$i] = @re[$j]; @re[$j] = $t;
            $t = @im[$i]; @im[$i] = @im[$j]; @im[$j] = $t;
        }
        $i = $i + 1;
    }

    $len = 2;
    while $len <= $n {
        $half   = $len +> 1;
        $stride = $n div $len;
        $start  = 0;
        while $start < $n {
            $k = 0;
            $w = 0;
            while $k < $half {
                $p  = $start + $k;
                $q  = $p + $half;
                $wr = @wc[$w];
                $wi = $sign * @ws[$w];
                $tr = $wr * @re[$q] - $wi * @im[$q];
                $ti = $wr * @im[$q] + $wi * @re[$q];
                @re[$q] = @re[$p] - $tr;
                @im[$q] = @im[$p] - $ti;
                @re[$p] = @re[$p] + $tr;
                @im[$p] = @im[$p] + $ti;
                $k = $k + 1;
                $w = $w + $stride;
            }
            $start = $start + $len;
        }
        $len = $len +< 1;
    }
    if $inverse {
        $t = 1e0 / $n;
        $i = 0;
        while $i < $n {
            @re[$i] = @re[$i] * $t;
            @im[$i] = @im[$i] * $t;
            $i = $i + 1;
        }
    }
    (@re, @im)
}
