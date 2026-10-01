use Math::Wavelet::Filter;
use Math::Wavelet::DWT;

#| The two-dimensional DWT, over a matrix given as an array of rows.
unit module Math::Wavelet::DWT2;

sub columns(@m) { (^@m[0].elems).map(-> $j { @m.map(*[$j]).Array }).Array }

sub check-matrix(@m, Str $who) {
    die "$who: expected a non-empty array of rows" unless @m && @m[0] ~~ Positional;
    die "$who: every row must have the same length" unless [==] @m.map(*.elems);
}

# One level along each axis in turn, axis 0 (down the columns) first: the
# subband keys spell the filter applied along axis 0 and then axis 1.
#| (cA, (cH, cV, cD)) — the horizontal, vertical and diagonal details.
our sub dwt2(@data, $wavelet, Str :$mode = 'symmetric') is export {
    check-matrix(@data, 'dwt2');
    my $w = Math::Wavelet::DWT::as-wavelet($wavelet);
    # along axis 0: every column becomes an approximation and a detail column
    my @cols = columns(@data).map({ dwt($_, $w, :$mode) });
    my @a = columns(@cols.map(*[0]));
    my @d = columns(@cols.map(*[1]));
    # along axis 1: every row of each
    my @aa = @a.map({ dwt($_, $w, :$mode) });
    my @da = @d.map({ dwt($_, $w, :$mode) });
    (@aa.map(*[0]).Array,
     (@da.map(*[0]).Array, @aa.map(*[1]).Array, @da.map(*[1]).Array))
}

sub inverse-rows($l, $h, $w, $mode) {
    return Nil unless $l.defined || $h.defined;
    my $rows = ($l // $h).elems;
    (^$rows).map(-> $i { idwt($l.defined ?? $l[$i] !! Nil,
                              $h.defined ?? $h[$i] !! Nil, $w, :$mode) }).Array
}

#| The inverse of dwt2; any of the four bands may be Nil, which reads as zeros.
our sub idwt2(($cA, ($cH, $cV, $cD)), $wavelet, Str :$mode = 'symmetric') is export {
    my $w = Math::Wavelet::DWT::as-wavelet($wavelet);
    my @given = ($cA, $cH, $cV, $cD).grep(*.defined);
    die "idwt2: at least one band must be given" unless @given;
    die "idwt2: every band must have the same shape"
        unless [eq] @given.map({ .elems ~ 'x' ~ .[0].elems });
    # along axis 1 first, undoing the order dwt2 went in
    my $a = inverse-rows($cA, $cV, $w, $mode);
    my $d = inverse-rows($cH, $cD, $w, $mode);
    my $ac = $a.defined ?? columns(@$a) !! Nil;
    my $dc = $d.defined ?? columns(@$d) !! Nil;
    columns(inverse-rows($ac, $dc, $w, $mode))
}

#| [cA_n, (cH_n, cV_n, cD_n), …, (cH_1, cV_1, cD_1)].
our sub wavedec2(@data, $wavelet, Str :$mode = 'symmetric', Int :$level) is export {
    check-matrix(@data, 'wavedec2');
    my $w = Math::Wavelet::DWT::as-wavelet($wavelet);
    my $n = $level // min(dwt-max-level(+@data, $w), dwt-max-level(@data[0].elems, $w));
    die "wavedec2: the level must not be negative" if $n < 0;
    my $a = @data;
    my @out;
    for ^$n {
        my ($ca, $details) = dwt2(@$a, $w, :$mode);
        @out.unshift: $details;
        $a = $ca;
    }
    @out.unshift: $a.Array;
    @out
}

#| The inverse of wavedec2.
our sub waverec2(@coeffs, $wavelet, Str :$mode = 'symmetric') is export {
    die "waverec2: no coefficients" unless @coeffs;
    my $w = Math::Wavelet::DWT::as-wavelet($wavelet);
    my $a = @coeffs[0];
    for @coeffs[1..*] -> $d {
        die "waverec2: each detail level must be a (cH, cV, cD) triple"
            unless $d ~~ Positional && $d.elems == 3;
        with $d.first(*.defined) -> $shape {
            my ($r, $c) = $shape.elems, $shape[0].elems;
            if $a.defined {
                $a = $a[^($a.elems == $r + 1 ?? $r !! $a.elems)];
                $a = $a.map({ .[^(.elems == $c + 1 ?? $c !! .elems)].Array }).Array;
            }
        }
        $a = idwt2(($a, $d), $w, :$mode);
    }
    $a.Array
}
