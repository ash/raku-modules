use Math::Wavelet::Filter;

#| The one-dimensional discrete wavelet transform, single- and multilevel.
unit module Math::Wavelet::DWT;

#| The signal-extension modes, by their PyWavelets names.
our constant MODES is export(:modes) = <zero constant symmetric periodic smooth
    periodization reflect antisymmetric antireflect>;

our sub as-wavelet($w --> Math::Wavelet::Filter) {
    $w ~~ Math::Wavelet::Filter ?? $w !! Math::Wavelet::Filter.named(~$w)
}

our sub check-mode(Str $mode) {
    die "Unknown signal-extension mode '$mode'; the known ones are {MODES.join(', ')}"
        unless $mode (elem) MODES;
}

#| The value at index $k of @x extended past both ends according to $mode.
our sub extended(@x, Int $k, Str $mode) {
    my $N = +@x;
    return @x[$k] if 0 <= $k < $N;
    given $mode {
        when 'zero'     { 0e0 }
        when 'constant' { $k < 0 ?? @x[0] !! @x[$N - 1] }
        when 'periodic' | 'periodization' { @x[$k mod $N] }
        when 'symmetric' {
            my $m = $k mod (2 * $N);
            $m < $N ?? @x[$m] !! @x[2 * $N - 1 - $m]
        }
        when 'reflect' {
            return @x[0] if $N == 1;
            my $m = $k mod (2 * $N - 2);
            $m < $N ?? @x[$m] !! @x[2 * $N - 2 - $m]
        }
        when 'antisymmetric' {
            my $q = $k div $N;
            my $r = $k mod $N;
            $q %% 2 ?? @x[$r] !! -@x[$N - 1 - $r]
        }
        when 'antireflect' {
            return @x[0] if $N == 1;
            $k < 0 ?? 2 * @x[0]      - extended(@x, -$k, $mode)
                   !! 2 * @x[$N - 1] - extended(@x, 2 * ($N - 1) - $k, $mode)
        }
        when 'smooth' {
            return @x[0] if $N == 1;
            $k < 0 ?? @x[0]      + $k * (@x[1] - @x[0])
                   !! @x[$N - 1] + ($k - $N + 1) * (@x[$N - 1] - @x[$N - 2])
        }
    }
}

#| How many coefficients each half of a single-level DWT of $data-len samples
#| has, for a filter of $filter-len taps.
our sub dwt-coeff-len(Int:D $data-len, $filter, Str :$mode = 'symmetric' --> Int)
    is export
{
    check-mode($mode);
    my $F = $filter ~~ Int ?? $filter !! as-wavelet($filter).dec-len;
    die "dwt-coeff-len: the data length must be positive" if $data-len < 1;
    $mode eq 'periodization' ?? ($data-len + 1) div 2
                             !! ($data-len + $F - 1) div 2
}

#| The deepest level at which every coefficient still sees some of the
#| signal rather than only its extension.
our sub dwt-max-level(Int:D $data-len, $filter --> Int) is export {
    my $F = $filter ~~ Int ?? $filter !! as-wavelet($filter).dec-len;
    return 0 if $F < 2 || $data-len < $F - 1;
    my $l = 0;
    $l++ while $data-len >= ($F - 1) * 2 ** ($l + 1);
    $l
}

# out[o] = Σ_j f[j]·x[2o + 1 − j], x extended past its ends by the mode.
sub analyse(@x, @lo, @hi, Str $mode) {
    my $N = +@x;
    my $F = +@lo;
    my num @f-lo = @lo;
    my num @f-hi = @hi;
    my @a;
    my @d;
    if $mode eq 'periodization' {
        # An odd signal is first made even by repeating its last sample.
        my num @p = @x;
        @p.push(@x[$N - 1]) if $N % 2;
        my $P = +@p;
        my $start = $F div 2;
        loop (my $o = 0; $o < $P div 2; $o++) {
            my num $sa = 0e0;
            my num $sd = 0e0;
            my $i = $start + 2 * $o;
            loop (my $j = 0; $j < $F; $j++) {
                my num $v = @p[($i - $j) mod $P];
                $sa += @f-lo[$j] * $v;
                $sd += @f-hi[$j] * $v;
            }
            @a.push($sa);
            @d.push($sd);
        }
    }
    else {
        # The signal, padded by F − 1 samples of extension on each side.
        my $pad = $F - 1;
        my num @e = (-$pad ..^ $N + $pad).map({ extended(@x, $_, $mode).Num });
        my $L = ($N + $F - 1) div 2;
        loop (my $o = 0; $o < $L; $o++) {
            my num $sa = 0e0;
            my num $sd = 0e0;
            my $i = 2 * $o + 1 + $pad;
            loop (my $j = 0; $j < $F; $j++) {
                my num $v = @e[$i - $j];
                $sa += @f-lo[$j] * $v;
                $sd += @f-hi[$j] * $v;
            }
            @a.push($sa);
            @d.push($sd);
        }
    }
    (@a, @d)
}

# The adjoint of analyse, taken with the reconstruction filters.
sub synthesise($a, $d, @lo, @hi, Str $mode) {
    my $L = ($a // $d).elems;
    my $F = +@lo;
    my num @ca = $a.defined ?? $a.map(*.Num) !! 0e0 xx $L;
    my num @cd = $d.defined ?? $d.map(*.Num) !! 0e0 xx $L;
    my num @r-lo = @lo;
    my num @r-hi = @hi;
    if $mode eq 'periodization' {
        my $P = 2 * $L;
        my num @y = 0e0 xx $P;
        my $start = $F div 2;
        loop (my $o = 0; $o < $L; $o++) {
            my num $va = @ca[$o];
            my num $vd = @cd[$o];
            loop (my $j = 0; $j < $F; $j++) {
                @y[($start + 2 * $o - $j) mod $P]
                    += $va * @r-lo[$F - 1 - $j] + $vd * @r-hi[$F - 1 - $j];
            }
        }
        @y.Array
    }
    else {
        my $N = 2 * $L - $F + 2;
        die "idwt: {$L} coefficients are too few for a {$F}-tap filter outside periodization mode"
            if $N < 1;
        my @y;
        loop (my $k = 0; $k < $N; $k++) {
            my num $s = 0e0;
            # y[k] = Σ_o a[o]·rec-lo[k + F − 2 − 2o] + d[o]·rec-hi[…]
            my $base = $k + $F - 2;
            my $o-lo = max(0, ($base - $F + 2) div 2);
            my $o-hi = min($L - 1, $base div 2);
            loop (my $o = $o-lo; $o <= $o-hi; $o++) {
                my $t = $base - 2 * $o;
                $s += @ca[$o] * @r-lo[$t] + @cd[$o] * @r-hi[$t];
            }
            @y.push($s);
        }
        @y
    }
}

#| A single level of the DWT: the approximation and the detail coefficients.
our sub dwt(@data, $wavelet, Str :$mode = 'symmetric') is export {
    check-mode($mode);
    die "dwt: the data must hold at least one sample" unless @data;
    my $w = as-wavelet($wavelet);
    analyse(@data.map(*.Num).Array, $w.dec-lo, $w.dec-hi, $mode)
}

#| The inverse of a single level. Either half may be Nil, which reads as all
#| zeros.
our sub idwt($cA, $cD, $wavelet, Str :$mode = 'symmetric') is export {
    check-mode($mode);
    die "idwt: at most one of the approximation and the detail may be Nil"
        unless $cA.defined || $cD.defined;
    die "idwt: the approximation and the detail must have the same length"
        if $cA.defined && $cD.defined && $cA.elems != $cD.elems;
    my $w = as-wavelet($wavelet);
    synthesise($cA, $cD, $w.rec-lo, $w.rec-hi, $mode)
}

#| The multilevel DWT: [cA_n, cD_n, cD_n−1, …, cD_1].
our sub wavedec(@data, $wavelet, Str :$mode = 'symmetric', Int :$level) is export {
    check-mode($mode);
    my $w = as-wavelet($wavelet);
    my $n = $level // dwt-max-level(+@data, $w);
    die "wavedec: the level must not be negative" if $n < 0;
    my @a = @data.map(*.Num);
    my @out;
    for ^$n {
        my ($ca, $cd) = analyse(@a, $w.dec-lo, $w.dec-hi, $mode);
        @out.unshift: $cd;
        @a = @$ca;
    }
    @out.unshift: @a;
    @out
}

#| The inverse of wavedec.
our sub waverec(@coeffs, $wavelet, Str :$mode = 'symmetric') is export {
    check-mode($mode);
    die "waverec: no coefficients" unless @coeffs;
    my $w = as-wavelet($wavelet);
    my $a = @coeffs[0];
    for @coeffs[1..*] -> $d {
        if $a.defined && $d.defined {
            if $a.elems == $d.elems + 1 { $a = $a[0 ..^ *-1] }
            elsif $a.elems != $d.elems {
                die "waverec: coefficient length mismatch ({$a.elems} against {$d.elems})";
            }
        }
        $a = synthesise($a, $d, $w.rec-lo, $w.rec-hi, $mode);
    }
    $a.Array
}
