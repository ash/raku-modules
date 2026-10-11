use Test;
use lib $*PROGRAM.parent.add('lib').Str;
use Vectors;
use Math::Wavelet;
use Math::Wavelet::Continuous;

my @info  = cases('continuous.vec');
my @cases = cases('cwt.vec');
plan @info.grep(*[0] eq 'wavelet') * 9 + @info.grep(*[0] ne 'wavelet') + 4 * @cases + 17;

#| An attribute PyWavelets may leave as None, written '-'.
sub maybe($got, Str $want, Str $what) {
    $want eq '-' ?? nok($got.defined, $what) !! is($got, +$want, $what)
}

for @info -> @c {
    given @c[0] {
        when 'wavelet' {
            my (Any, $name, $family, $short, $complex, $lo, $hi, $cf, $bw, $order, $sym) = @c;
            my $w = wavelet($name);
            is $w.family, $family, "$name family";
            is $w.short-family, $short, "$name short family";
            is $w.complex-cwt, $complex eq 'True', "$name complex";
            is $w.lower-bound, +$lo, "$name lower bound";
            is $w.upper-bound, +$hi, "$name upper bound";
            maybe $w.center-frequency, $cf, "$name centre frequency";
            maybe $w.bandwidth-frequency, $bw, "$name bandwidth";
            maybe $w.fbsp-order, $order, "$name spline order";
            is $w.symmetry, $sym, "$name symmetry";
        }
        when 'wavefun' {
            my (Any, $name, $level, $length, $psi, $x) = @c;
            my %len = $length eq '-' ?? () !! (length => +$length);
            my ($p, $g) = wavelet($name).wavefun(:level(+$level), |%len);
            close-to [|$p, |$g], [|cnums($psi), |nums($x)],
                "$name wavefun, level $level" ~ ($length eq '-' ?? '' !! ", $length points");
        }
        when 'central-frequency' {
            my (Any, $name, $precision, $f) = @c;
            is central-frequency($name, :precision(+$precision)), +$f,
                "$name central frequency, precision $precision";
        }
        when 'integrate' {
            my (Any, $name, $precision, $int, $x) = @c;
            my ($i, $g) = integrate-wavelet($name, :precision(+$precision));
            close-to [|$i, |$g], [|cnums($int), |nums($x)], "$name integrated";
        }
    }
}

for @cases -> (Any, $name, $scales, $period, $x, $coef, $freqs) {
    my @scales = nums($scales);
    my @x = nums($x);
    my $what = "cwt $name, {+@x} samples, scales {@scales}";
    for <conv fft> -> $method {
        my ($c, $f) = cwt(@x, @scales, $name, :sampling-period(+$period), :$method);
        close-to $c, cmatrix($coef), "$what, $method";
        close-to $f, nums($freqs), "$what, $method, frequencies";
    }
}

is +wavelist, 127, 'every wavelet PyWavelets lists';
is-deeply wavelist(:kind<continuous>).sort.List,
    @info.grep(*[0] eq 'wavelet').map(*[1]).head(21).sort.List,
    'the continuous ones, by the same names';
is +wavelist(:kind<discrete>), 106, 'and the discrete';
is-deeply wavelist('gaus'), (1..8).map({ "gaus$_" }).List, 'one continuous family';
isa-ok wavelet('mexh'), Math::Wavelet::Continuous, 'wavelet() gives a continuous wavelet';
my ($c) = cwt((^16).map(*.sin), 2, 'cgau2');
isa-ok $c[0][0], Complex, 'a complex wavelet gives complex coefficients';
is-approx scale2frequency('morl', 4), central-frequency('morl') / 4, 'scale2frequency';
{
    my @x = (^32).map(*.sin);
    my ($a) = cwt(@x, [1, 2, 4], 'mexh');
    my ($b) = cwt(@x, (1, 2, 4).map(*.Num), 'mexh');
    my ($c) = cwt(@x, 1..2, 'mexh');
    is +$b, 3, 'cwt takes its scales as a Seq';
    close-to $b, $a, '…and transforms at each of them';
    is +$c, 2, '…or as a Range';
    is-deeply scale2frequency('morl', (2, 4).map(* + 0)), [scale2frequency('morl', 2), scale2frequency('morl', 4)],
        'scale2frequency takes a Seq';
}
is-approx frequency2scale('morl', 0.2), central-frequency('morl') / 0.2, 'frequency2scale';

throws-like { wavelet('gaus9') }, Exception, message => /'Unknown wavelet'/, 'gaus9 is unknown';
throws-like { wavelet('cmor1') }, Exception, message => /'cmorB-C'/, 'cmor without C dies';
throws-like { wavelet('fbsp1.5-1-1') }, Exception, message => /'spline order'/, 'a fractional spline order dies';
throws-like { dwt([1, 2, 3], 'mexh') }, Exception, message => /'continuous wavelet'/,
    'the discrete transform refuses a continuous wavelet';
throws-like { cwt([1, 2, 3], [1], 'db2') }, Exception, message => /'discrete wavelet'/,
    'the continuous transform refuses a discrete one';
