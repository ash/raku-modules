# TOML::Native against the TOML v1.0.0 subset of toml-test.
#
#   cd TOML-Native
#   rakupp -Ilib ../benchmarks/toml/conformance.raku
#   rakudo -Ilib ../benchmarks/toml/conformance.raku
#   TOML_NATIVE_BACKEND=raku rakupp -Ilib ../benchmarks/toml/conformance.raku
#
# Every valid case is decoded and compared with its tagged JSON (JSON::Fast
# reads that), then written with to-toml, read back, and compared again.
# Every invalid case must be refused. When the answering backend is the
# native one, every case also goes through the Raku implementation, which
# must return the same data or die with the same message.
#
# --verbose lists each failure.

use JSON::Fast;
use TOML::Native;

my Bool $verbose = so @*ARGS.grep('--verbose');
my $root = $*PROGRAM.parent.add('toml-test');
my @files = $root.add('files-toml-1.0.0').lines.grep(*.ends-with('.toml'));
my $native = toml-backend() eq 'native';

# Seconds as the parsers keep them: nine fractional digits at most.
sub secs(Str $s) {
    my ($w, $f) = $s.split('.');
    $f.defined && $f.chars ?? $w.Int + $f.substr(0, 9).Int / 10 ** $f.substr(0, 9).chars !! $w.Int
}

sub date-ok($got, Str $v) {
    my $m = $v ~~ /^ (\d**4) '-' (\d\d) '-' (\d\d) /;
    $m && $got.year == +$m[0] && $got.month == +$m[1] && $got.day == +$m[2]
}
sub time-ok($got, Str $t) {
    my $m = $t ~~ /^ (\d\d) ':' (\d\d) ':' (\d\d ['.' \d+]?) /;
    $m && $got.hour == +$m[0] && $got.minute == +$m[1] && $got.second == secs(~$m[2])
}

sub scalar-ok($got, Str $type, Str $v) {
    given $type {
        when 'string'  { $got ~~ Str && $got eq $v }
        when 'integer' { $got ~~ Int && $got !~~ Bool && $got == $v.Int }
        when 'float' {
            return False unless $got ~~ Num;
            given $v.lc {
                when 'nan' | '+nan' | '-nan' { $got.isNaN }
                when 'inf' | '+inf'          { $got == Inf }
                when '-inf'                  { $got == -Inf }
                default                      { $got == $v.Num }
            }
        }
        when 'bool' { $got ~~ Bool && ($got ?? 'true' !! 'false') eq $v }
        when 'datetime' {
            return False unless $got ~~ DateTime && $got !~~ TOML::Native::LocalDateTime;
            my $m = $v ~~ /^ (\S**10) <[Tt\ ]> (<[\d:.]>+) (<[Zz]> | <[+-]> \d\d ':' \d\d) $/;
            return False unless $m && date-ok($got, ~$m[0]) && time-ok($got, ~$m[1]);
            my $off = ~$m[2];
            my $tz = $off.uc eq 'Z' ?? 0
                  !! ($off.starts-with('-') ?? -1 !! 1) * ($off.substr(1, 2) * 3600 + $off.substr(4, 2) * 60);
            $got.timezone == $tz
        }
        when 'datetime-local' {
            my $m = $v ~~ /^ (\S**10) <[Tt\ ]> (.+) $/;
            $got ~~ TOML::Native::LocalDateTime && $m && date-ok($got, ~$m[0]) && time-ok($got, ~$m[1])
        }
        when 'date-local' { $got ~~ Date && date-ok($got, $v) }
        when 'time-local' { $got ~~ TOML::Native::LocalTime && time-ok($got, $v) }
        default { False }
    }
}

my constant TYPES = set <string integer float bool datetime datetime-local date-local time-local>;

sub same($got, $want --> Bool) {
    if $want ~~ Associative {
        if $want.keys.sort.List eqv ('type', 'value') && $want<type> ~~ Str && $want<type> (elem) TYPES
                && $want<value> ~~ Str {
            return scalar-ok($got, $want<type>, $want<value>);
        }
        return False unless $got ~~ Associative && $got.keys.sort.List eqv $want.keys.sort.List;
        return so $want.keys.map({ same($got{$_}, $want{$_}) }).all;
    }
    if $want ~~ Positional {
        return False unless $got ~~ Positional && $got.elems == $want.elems;
        return so (^$want.elems).map({ same($got[$_], $want[$_]) }).all;
    }
    False
}

my ($valid, $valid-ok, $trip-ok, $invalid, $invalid-ok) = 0 xx 5;
my ($data-same, $msg-same, $msg-cases) = 0 xx 3;
my @fail;

for @files -> $rel {
    my $file = $root.add($rel);
    if $rel.starts-with('valid/') {
        $valid++;
        my $want = from-json($file.extension('json').slurp);
        my $got = try from-toml($file);
        without $got { @fail.push("$rel: refused: {$!.message}"); next }
        if same($got, $want) { $valid-ok++ } else { @fail.push("$rel: wrong data") }
        my $back = try from-toml(to-toml($got));
        if $back.defined && same($back, $want) { $trip-ok++ }
        else { @fail.push("$rel: round trip: {$! ?? $!.message !! 'wrong data'}") }
        if $native {
            my $raku = try TOML::Native::parse-raku($file.slurp(:bin).decode);
            if $raku.defined && $raku eqv $got { $data-same++ }
            else { @fail.push("$rel: the Raku implementation disagrees") }
        }
    }
    else {
        $invalid++;
        my $got = try from-toml($file);
        if $got.defined { @fail.push("$rel: accepted"); next }
        $invalid-ok++;
        my $native-msg = $!.message;
        if $native && (my $text = try $file.slurp(:bin).decode) {
            $msg-cases++;
            my $raku-msg = (try TOML::Native::parse-raku($text)) ?? 'accepted' !! $!.message;
            if $raku-msg eq $native-msg { $msg-same++ }
            else { @fail.push("$rel: messages differ: native '$native-msg', raku '$raku-msg'") }
        }
    }
}

say "{$*RAKU.compiler.name} {$*RAKU.compiler.version}, backend {toml-backend()}";
say "  valid:      $valid-ok/$valid decoded as the JSON says";
say "  round trip: $trip-ok/$valid written by to-toml and read back the same";
say "  invalid:    $invalid-ok/$invalid refused";
if $native {
    say "  parity:     $data-same/$valid valid cases, the Raku implementation returns the same data";
    say "              $msg-same/$msg-cases invalid cases, the same error message";
}
if $verbose { say '  ' ~ $_ for @fail }
exit(@fail ?? 1 !! 0);
