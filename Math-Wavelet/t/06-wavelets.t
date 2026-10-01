use Test;
use lib $*PROGRAM.parent.add('lib').Str;
use Vectors;
use Math::Wavelet;
use Math::Wavelet::Filter;

my @names = wavelist;
plan 2 * @names + 16;

is +@names, 106, 'the 106 discrete wavelets PyWavelets has';
is-deeply wavelist('coif'), (1..17).map({ "coif$_" }).List, 'one family, in order';

# Every built-in filter bank reconstructs what it decomposed, to a part in
# 10¹⁰ of the signal's peak. dmey is the exception the wavelet itself makes:
# its 62 taps truncate the Meyer filter, and it comes back within half a
# percent — as it does from PyWavelets, which t/01-dwt.t checks it against.
my @x = (^64).map({ sin($_ / 3) * 10 + ($_ * 7 % 11) });
for @names -> $n {
    my $w   = wavelet($n);
    my $tol = ($n eq 'dmey' ?? 5e-3 !! 1e-10) * @x.map(*.abs).max;
    for <periodization symmetric> -> $mode {
        my $y = idwt(|dwt(@x, $w, :$mode), $w, :$mode);
        my $err = ($y[^@x] Z- @x).map(*.abs).max;
        ok $err < $tol, "$n reconstructs, $mode" or diag "error $err";
    }
}

# the table parses back to PyWavelets' exact doubles
is wavelet('db2').dec-lo[0], -0.12940952255126037e0, 'coefficients round-trip exactly';

my $s = wavelet('sym4');
is $s.family, 'Symlets', 'family';
is $s.short-family, 'sym', 'short family';
is $s.vanishing-moments-psi, 4, 'vanishing moments';
ok $s.orthogonal && $s.biorthogonal, 'orthogonal';
is $s.dec-len, 8, 'filter length';
nok wavelet('bior2.2').orthogonal, 'a biorthogonal wavelet is not orthogonal';

my $own = Math::Wavelet::Filter.from-lowpass(wavelet('db2').dec-lo, :name<mine>);
is-deeply $own.filter-bank».List, wavelet('db2').filter-bank».List,
    'from-lowpass derives the filter bank db2 has';
close-to dwt(@x, $own), dwt(@x, 'db2'), 'a custom wavelet transforms like the built-in';

my $bank = Math::Wavelet::Filter.new(
    dec-lo => [1, 1] »/» sqrt(2), dec-hi => [-1, 1] »/» sqrt(2),
    rec-lo => [1, 1] »/» sqrt(2), rec-hi => [1, -1] »/» sqrt(2));
close-to dwt(@x, $bank), dwt(@x, 'haar'), 'so does one given as four filters';
is wavelet($bank), $bank, 'wavelet() passes a Filter through';

throws-like { wavelet('db99') }, Exception, message => /'Unknown wavelet'/, 'an unknown name dies';
throws-like { dwt(@x, 'db2', :mode<mirror>) }, Exception, message => /'Unknown signal-extension mode'/,
    'an unknown mode dies';
throws-like { Math::Wavelet::Filter.new(dec-lo => [1, 1], dec-hi => [1], rec-lo => [1, 1], rec-hi => [1, 1]) },
    Exception, 'filters of different lengths die';
