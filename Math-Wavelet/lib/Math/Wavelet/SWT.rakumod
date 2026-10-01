use Math::Wavelet::Filter;
use Math::Wavelet::DWT;

#| The stationary (undecimated, à trous) wavelet transform.
unit module Math::Wavelet::SWT;

#| How many levels of SWT a signal of $data-len samples admits: every level
#| halves nothing, but needs the length divisible by 2 once more.
our sub swt-max-level(Int:D $data-len --> Int) is export {
    die "swt-max-level: the data length must be positive" if $data-len < 1;
    my $l = 0;
    my $n = $data-len;
    while $n %% 2 { $l++; $n div= 2 }
    $l
}

# out[n] = Σ_j f[j]·x[(F_e/2 + n − j·2^(l−1)) mod N], the filter upsampled by
# 2^(l−1) with zeros and wrapped periodically, which is periodization at step 1.
sub filter-at-level(@x, @f, Int $level) {
    my $N    = +@x;
    my $F    = +@f;
    my $step = 2 ** ($level - 1);
    my $half = ($F * $step) div 2;
    my num @in = @x;
    my num @k  = @f;
    my @out;
    loop (my $n = 0; $n < $N; $n++) {
        my num $s = 0e0;
        loop (my $j = 0; $j < $F; $j++) {
            $s += @k[$j] * @in[($half + $n - $j * $step) mod $N];
        }
        @out.push($s);
    }
    @out
}

#| [[cA_n, cD_n], …, [cA_1, cD_1]], or with :trim-approx [cA_n, cD_n, …, cD_1].
our sub swt(@data, $wavelet, Int :$level, Int :$start-level = 0,
            Bool :$trim-approx, Bool :$norm) is export
{
    my $w   = Math::Wavelet::DWT::as-wavelet($wavelet);
    $w      = $w.scaled(1 / sqrt 2) if $norm;
    my $max = swt-max-level(+@data);
    my $n   = $level // $max;
    die "swt: the level must be at least 1" if $n < 1;
    die "swt: the start level must not be negative" if $start-level < 0;
    die "swt: level $n from start level $start-level needs the length divisible by "
        ~ 2 ** ($n + $start-level) ~ "; {+@data} samples admit at most "
        ~ ($max - $start-level) ~ " levels"
        if $n + $start-level > $max;
    my @x = @data.map(*.Num);
    my @out;
    for $start-level + 1 .. $start-level + $n -> $l {
        my $a = filter-at-level(@x, $w.dec-lo, $l);
        my $d = filter-at-level(@x, $w.dec-hi, $l);
        @out.unshift: [$a, $d];
        @x = @$a;
    }
    $trim-approx ?? [@out[0][0], |@out.map(*[1])] !! @out
}

#| The inverse of swt, from either of its two output shapes. It assumes the
#| decomposition started at level 0.
our sub iswt(@coeffs, $wavelet, Bool :$norm) is export {
    die "iswt: no coefficients" unless @coeffs;
    my $w = Math::Wavelet::DWT::as-wavelet($wavelet);
    $w    = $w.scaled(sqrt 2) if $norm;
    my $paired = @coeffs[0][0] ~~ Positional;
    my @out    = ($paired ?? @coeffs[0][0] !! @coeffs[0]).map(*.Num);
    my @d      = $paired ?? @coeffs.map(*[1]) !! @coeffs[1..*];
    my $levels = +@d;
    for $levels ... 1 -> $j {
        my $step = 2 ** ($j - 1);
        my @cd   = @d[$levels - $j].map(*.Num);
        die "iswt: every level must have as many coefficients as the approximation"
            if @cd != @out;
        for ^$step -> $first {
            my @idx  = ($first, $first + $step ...^ * >= +@cd);
            my @even = @idx[0, 2 ... *];
            my @odd  = @idx[1, 3 ... *];
            my @x1 = idwt(@out[@even].Array, @cd[@even].Array, $w, :mode<periodization>);
            my @x2 = idwt(@out[@odd].Array,  @cd[@odd].Array,  $w, :mode<periodization>);
            @x2 = @x2.rotate(-1);
            @out[@idx] = (@x1 Z+ @x2).map(* / 2);
        }
    }
    @out
}
