#| A continuous wavelet: a function ψ(x), sampled over its effective support,
#| for the continuous transform. PyWavelets' seven families, under its names.
unit class Math::Wavelet::Continuous;

has Str  $.name is required;
has Str  $.short-family is required;
has Str  $.family is required;
has Str  $.symmetry is required;
has Bool $.complex-cwt = False;
has Num  $.lower-bound is required;
has Num  $.upper-bound is required;
has Num  $.center-frequency;      # cmor, shan and fbsp only
has Num  $.bandwidth-frequency;   # cmor, shan and fbsp only
has Int  $.fbsp-order;            # fbsp only
has Int  $.order;                 # gaus and cgau only: which derivative

method orthogonal(--> Bool)   { False }
method biorthogonal(--> Bool) { False }

method Str  { $!name }
method gist { "Math::Wavelet::Continuous($!name)" }

# ---------- the families ----------

my constant FAMILIES = (
    gaus => 'Gaussian',
    mexh => 'Mexican hat wavelet',
    morl => 'Morlet wavelet',
    cgau => 'Complex Gaussian wavelets',
    shan => 'Shannon wavelets',
    fbsp => 'Frequency B-Spline wavelets',
    cmor => 'Complex Morlet wavelets',
);

#| The short family names, in PyWavelets' order.
method families(::?CLASS:U: --> List) { FAMILIES».key.List }

#| The names PyWavelets lists for the continuous wavelets, in family order.
#| `shan`, `fbsp` and `cmor` stand for their families' default parameters;
#| any others are written into the name, as `cmor1.5-1.0`.
method list(::?CLASS:U: Str $family? --> List) {
    my @names = |(1..8).map({ "gaus$_" }), 'mexh', 'morl',
                |(1..8).map({ "cgau$_" }), 'shan', 'fbsp', 'cmor';
    @names .= grep(*.starts-with($family)) with $family;
    @names.List
}

#| Whether `$name` is a continuous wavelet's — a family name with or without
#| its parameters.
method is-continuous(::?CLASS:U: Str() $name --> Bool) {
    so $name ~~ / ^ [ 'gaus' <[1..8]> | 'cgau' <[1..8]> | 'mexh' | 'morl'
                    | 'shan' | 'fbsp' | 'cmor' ] /
}

sub number(Str $s, Str $name, Str $form) {
    my $n = try $s.Numeric;
    die "For wavelets of family {$name.substr(0, 4)}, the name should take the form $form"
        unless $n.defined && $n ~~ Real && $n > 0;
    $n.Num
}

#| The built-in wavelet of that name: gaus1–gaus8, mexh, morl, cgau1–cgau8,
#| and shanB-C, fbspM-B-C and cmorB-C, with B the bandwidth and C the centre
#| frequency.
method named(::?CLASS:U: Str:D $name --> ::?CLASS) {
    my %base = :$name, family => '', symmetry => 'asymmetric';
    with $name ~~ / ^ ('gaus' | 'cgau') (<[1..8]>) $ / {
        my $p = +$1;
        return self.new(:$name, short-family => ~$0, family => FAMILIES.Map{~$0},
            symmetry => $p %% 2 ?? 'symmetric' !! 'anti-symmetric',
            complex-cwt => $0 eq 'cgau', order => $p,
            lower-bound => -5e0, upper-bound => 5e0);
    }
    if $name eq 'mexh' | 'morl' {
        return self.new(:$name, short-family => $name, family => FAMILIES.Map{$name},
            symmetry => 'symmetric', lower-bound => -8e0, upper-bound => 8e0);
    }
    with $name ~~ / ^ ('shan' | 'cmor' | 'fbsp') (.*) $ / {
        my $fam  = ~$0;
        my @p    = (~$1).chars ?? (~$1).split('-') !! ();
        my %defaults = shan => (0.5e0, 1e0), cmor => (1e0, 0.5e0), fbsp => (2, 1e0, 0.5e0);
        my $form = $fam eq 'fbsp' ?? 'fbspM-B-C, where M is the spline order and B and C are the bandwidth and center frequencies (example: fbsp2-1.0-0.5)'
                                  !! "{$fam}B-C, where B and C are the bandwidth and center frequencies (example: {$fam}1.5-1.0)";
        my $want = $fam eq 'fbsp' ?? 3 !! 2;
        die "For wavelets of family $fam, the name should take the form $form"
            unless !@p || @p == $want;
        my @v = @p ?? @p.map({ number($_, $name, $form) }) !! %defaults{$fam}.list;
        my $order;
        if $fam eq 'fbsp' {
            $order = @v.shift;
            die 'Wavelet spline order must be an integer >= 1.'
                unless $order == $order.Int && $order >= 1;
            $order .= Int;
        }
        my $bound = $fam eq 'cmor' ?? 8e0 !! 20e0;
        return self.new(:$name, short-family => $fam, family => FAMILIES.Map{$fam},
            symmetry => 'asymmetric', :complex-cwt,
            bandwidth-frequency => @v[0].Num, center-frequency => @v[1].Num,
            |(fbsp-order => $order if $order.defined),
            lower-bound => -$bound, upper-bound => $bound);
    }
    die "Unknown wavelet '$name'; wavelist() names the known ones";
}

# ---------- ψ ----------

# The Gaussian family is the p-th derivative of e^(−x²), which is a Hermite
# polynomial times the Gaussian, normalised to unit energy:
# ∫ (Hₚ e^(−x²))² dx = (2p−1)!! √(π/2). PyWavelets' signs follow the
# pattern below, which is not (−1)ᵖ; t/07-cwt.t holds it to them.
my constant GAUS-SIGN = (Nil, -1, -1, 1, 1, -1, -1, 1, 1);

sub double-factorial(Int $n --> Int) { $n < 1 ?? 1 !! [*] (1, 3 ... $n) }

sub hermite(Int $p, Num $x --> Num) {
    my ($a, $b) = 1e0, 2 * $x;
    return $a if $p == 0;
    for 1 ..^ $p -> $n { ($a, $b) = $b, 2 * $x * $b - 2 * $n * $a }
    $b
}

# The complex Gaussian family is the n-th derivative of e^(−ix−x²): a
# polynomial Pₙ(x) times that function, with P₀ = 1 and
# Pₙ₊₁ = Pₙ′ + (−i − 2x)·Pₙ. Its energy, through Parseval, is
# (√(2π)/2) Σₘ C(2n, 2m) (2m−1)!!.
my %CGAU;     # order => (coefficients, norm), computed once
my $lock = Lock.new;
sub cgau-poly(Int $n) {
    $lock.protect: {
        %CGAU{$n} //= do {
            my @c = (1+0i,);
            for ^$n {
                my @d = (1 ..^ @c).map({ $_ * @c[$_] });     # Pₙ′
                my @next = (0+0i) xx (@c + 1);
                @next[$_] += @d[$_] for ^@d;
                for ^@c -> $k {
                    @next[$k]     += -1i * @c[$k];
                    @next[$k + 1] += -2 * @c[$k];
                }
                @c = @next;
            }
            my $energy = sqrt(2 * π) / 2
                * [+] (0..$n).map(-> $m { binomial(2 * $n, 2 * $m) * double-factorial(2 * $m - 1) });
            (@c.List, sqrt($energy))
        }
    }
}
sub binomial(Int $n, Int $k --> Int) { ([*] ($n - $k + 1) .. $n) div ([*] 1 .. $k) }

sub sinc(Num $x --> Num) { $x == 0 ?? 1e0 !! sin(π * $x) / (π * $x) }

#| ψ at one point: a Num, or a Complex for a complex wavelet.
method psi(Real $x is copy) {
    $x .= Num;
    given $!short-family {
        when 'gaus' {
            GAUS-SIGN[$!order] * hermite($!order, $x) * exp(-$x * $x)
                / sqrt(double-factorial(2 * $!order - 1) * sqrt(π / 2))
        }
        when 'mexh' { 2 / (sqrt(3) * π ** .25) * (1 - $x * $x) * exp(-$x * $x / 2) }
        when 'morl' { cos(5 * $x) * exp(-$x * $x / 2) }
        when 'cgau' {
            my ($c, $norm) = cgau-poly($!order);
            my $p = 0+0i;
            $p = $p * $x + $_ for $c.reverse;
            $p * exp(-$x * $x) * (cos($x) - 1i * sin($x)) / $norm
        }
        default {
            my $B = $!bandwidth-frequency;
            my $carrier = cis(2 * π * $!center-frequency * $x);
            given $!short-family {
                when 'cmor' { exp(-$x * $x / $B) / sqrt(π * $B) * $carrier }
                when 'shan' { sqrt($B) * sinc($B * $x) * $carrier }
                when 'fbsp' { sqrt($B) * sinc($B * $x / $!fbsp-order) ** $!fbsp-order * $carrier }
            }
        }
    }
}

#| ψ sampled at `2**$level` points (or `$length`, if given) spread evenly over
#| [lower-bound, upper-bound], ends included. Returns `(psi, x)`, as
#| PyWavelets' `wavefun` does.
method wavefun(Int :$level = 8, Int :$length --> List) {
    my $n = $length // 2 ** $level;
    die 'wavefun needs at least one point' if $n < 1;
    # numpy.linspace, step for step: i·Δ + lower, and the upper bound exact.
    # Agreeing to the last bit matters: `cwt` indexes by these steps.
    my @x = $n == 1 ?? ($!lower-bound,) !! do {
        my $d = ($!upper-bound - $!lower-bound) / ($n - 1);
        |(^($n - 1)).map({ $_ * $d + $!lower-bound }), $!upper-bound
    };
    (@x.map({ self.psi($_) }).Array, @x.Array)
}
