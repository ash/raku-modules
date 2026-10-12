use Test;
use JSON::Native;
need JSON::Native::Raku;

# JSON::Fast is the specification of this module, and no longer a dependency
# of it. 01 and 02 hold its answers written down; this file asks it live, over
# documents and values nobody wrote down — random ones, and random damage to
# them — wherever it happens to be installed.
#
# Only on Rakudo. Under Raku++, JSON::Fast's from-json and to-json are replaced
# at load time by the engine's own codec, so asking "JSON::Fast" there would
# compare the engine with itself, not with JSON::Fast.

my (&jf-from-json, &jf-to-json);
my $have = try {
    require ::('JSON::Fast');
    &jf-from-json = ::('&JSON::Fast::from-json');
    &jf-to-json   = ::('&JSON::Fast::to-json');
    True
};
plan skip-all => 'JSON::Fast is not installed' unless $have;
plan skip-all => "on Raku++ JSON::Fast's subs are the engine's codec, not an independent oracle"
    if $*RAKU.compiler.name eq 'Raku++';

diag "json-backend: {json-backend}";

my @impls = 'JSON::Native'       => (&from-json, &to-json),
            'JSON::Native::Raku' => (&JSON::Native::Raku::from-json, &JSON::Native::Raku::to-json);

sub outcome(&f) { my $r = try f(); $! ?? 'DIES' !! $r.raku }

# Random values, of every kind JSON::Fast has a rule for, and strings built
# from the characters that need one.
srand 20261012;
my @chars = flat 'a'..'z', ' ', '"', '\\', "\n", "\t", "\r", "\x[1]", "\x[7f]", '/', 'é',
                 '日', "\x[1F600]", "\x[301]", "\x[1D15E]", "\x[FEFF]";
sub rand-str { (^(0..8).pick).map({ @chars.pick }).join }
sub rand-val($d = 0) {
    given (^($d > 3 ?? 7 !! 10)).pick {
        when 0 { (-1000..1000).pick }
        when 1 { (2 ** (60..130).pick) * (1, -1).pick }
        when 2 { (-10000..10000).pick / (1, 2, 3, 4, 7, 8, 10, 100, 1000).pick }
        when 3 { rand * 10 ** (-10..10).pick * (1, -1).pick }
        when 4 { rand-str() }
        when 5 { (True, False, Any).pick }
        when 6 { (0e0, -0e0, 1e300, 5e-324, 1.0e0, 100.0, 1/3, 2/3).pick }
        when 7 { [ (^(0..4).pick).map({ rand-val($d + 1) }) ] }
        when 8 { %( (^(0..4).pick).map(-> $ { Pair.new(rand-str(), rand-val($d + 1)) }) ) }
        when 9 { (^(0..3).pick).map({ rand-val($d + 1) }).List }
    }
}

my @values = (^250).map({ rand-val() });
my @docs = @values.map({ jf-to-json($_, :!pretty) });
@docs.append: @values.head(50).map({ jf-to-json($_) });
# random damage: a character deleted, or one of the structural ones inserted
for @docs.head(150) -> $j {
    for ^2 {
        my $m = $j;
        if $m.chars && (True, False).pick { $m = $m.substr(0, my $p = (^$m.chars).pick) ~ $m.substr($p + 1) }
        else { my $p = (0..$m.chars).pick; $m = $m.substr(0, $p) ~ <[ ] { } , : " \\ 1 - . e / a>.pick ~ $m.substr($p) }
        @docs.push: $m;
    }
}

plan @impls * 4;

for @impls -> (:key($name), :value((&parse, &write))) {
    for (%(), %(:immutable), %(:allow-jsonc)) -> %opt {
        my @bad = @docs.grep(-> $j { outcome({ parse($j, |%opt) }) ne outcome({ jf-from-json($j, |%opt) }) });
        diag "  differs: {.raku}" for @bad.head(5);
        is +@bad, 0, "$name parses {+@docs} documents as JSON::Fast does{%opt ?? ", :{%opt.keys}" !! ''}";
    }
    my @wrote = @values.grep(-> $v {
        (%(:!pretty), %(:sorted-keys), %(:sorted-keys, :spacing(3), :level(1)))
          .first(-> %opt { outcome({ write($v, |%opt) }) ne outcome({ jf-to-json($v, |%opt) }) })
    });
    diag "  differs: {.raku}" for @wrote.head(5);
    is +@wrote, 0, "$name writes {+@values} values as JSON::Fast does";
}
