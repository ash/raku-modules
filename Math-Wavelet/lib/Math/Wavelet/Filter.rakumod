use Math::Wavelet::Table;

#| A discrete wavelet, as the four filters of its two-channel filter bank.
unit class Math::Wavelet::Filter;

has Str  $.name         = 'custom';
has Str  $.short-family = '';
has Str  $.family       = '';
has Str  $.symmetry     = 'unknown';
has Bool $.orthogonal   = False;
has Bool $.biorthogonal = False;
has Int  $.vanishing-moments-psi = 0;
has Int  $.vanishing-moments-phi = 0;
has @.dec-lo is required;
has @.dec-hi is required;
has @.rec-lo is required;
has @.rec-hi is required;

submethod TWEAK {
    for <dec-lo dec-hi rec-lo rec-hi> -> $f {
        my @v := self."$f"();
        die "Math::Wavelet::Filter: $f must hold at least two coefficients"
            if @v < 2;
        die "Math::Wavelet::Filter: all four filters must have the same length"
            if @v != @!dec-lo;
        my @n = @v.map(*.Num);
        @v = @n;
    }
}

#| The orthogonal filter bank that a single decomposition lowpass filter
#| defines: the rest follow by reversal and alternating sign.
method from-lowpass(::?CLASS:U: @dec-lo, Str :$name = 'custom', *%rest) {
    my @dl = @dec-lo.map(*.Num);
    my $F  = +@dl;
    my @rh = (^$F).map({ $_ %% 2 ?? @dl[$_] !! -@dl[$_] });
    self.new(:$name, :orthogonal, :biorthogonal, |%rest,
             dec-lo => @dl, dec-hi => @rh.reverse, rec-lo => @dl.reverse,
             rec-hi => @rh)
}

method dec-len(--> Int) { +@!dec-lo }
method rec-len(--> Int) { +@!rec-lo }
method filter-bank      { (@!dec-lo, @!dec-hi, @!rec-lo, @!rec-hi) }

#| A copy with every filter multiplied by $factor.
method scaled(Numeric $factor --> ::?CLASS) {
    my $f = $factor.Num;
    self.clone(dec-lo => @!dec-lo.map(* * $f), dec-hi => @!dec-hi.map(* * $f),
               rec-lo => @!rec-lo.map(* * $f), rec-hi => @!rec-hi.map(* * $f))
}

method Str  { $!name }
method gist { "Math::Wavelet::Filter($!name)" }

my %line;       # name => its line in the table, found once
my %cache;      # name => the parsed wavelet
my $lock = Lock.new;

sub lines() {
    $lock.protect: {
        unless %line {
            for Math::Wavelet::Table::TABLE.lines -> $l {
                %line{$l.substr(0, $l.index("\t"))} = $l if $l;
            }
        }
    }
    %line
}

sub nums(Str $s) { $s.words.map(*.Num).Array }

#| The built-in wavelet of that name: haar, db1–db38, sym2–sym20,
#| coif1–coif17, bior and rbio N.M, dmey.
method named(::?CLASS:U: Str:D $name --> ::?CLASS) {
    my $l = lines(){$name}
        // die "Unknown wavelet '$name'; wavelist() names the known ones";
    $lock.protect: {
        %cache{$name} //= do {
            my ($n, $short, $family, $symmetry, $psi, $phi, $kind, *@f)
                = $l.split("\t");
            my %meta = :name($n), :short-family($short), :$family, :$symmetry,
                       :vanishing-moments-psi(+$psi),
                       :vanishing-moments-phi(+$phi);
            $kind eq 'o'
                ?? self.from-lowpass(nums(@f[0]), |%meta)
                !! self.new(|%meta, :!orthogonal, :biorthogonal,
                            dec-lo => nums(@f[0]), dec-hi => nums(@f[1]),
                            rec-lo => nums(@f[2]), rec-hi => nums(@f[3]))
        }
    }
}

#| The names of the built-in wavelets, in table order, optionally of one
#| short family ('db', 'sym', 'coif', 'bior', 'rbio', 'haar', 'dmey').
method list(::?CLASS:U: Str $family? --> List) {
    my @names = Math::Wavelet::Table::TABLE.lines.grep(?*).map(*.split("\t", 3));
    @names .= grep(*[1] eq $family) with $family;
    @names.map(*[0]).List
}

#| The short family names, in table order.
method families(::?CLASS:U: --> List) {
    Math::Wavelet::Table::TABLE.lines.grep(?*).map(*.split("\t", 3)[1]).unique.List
}
