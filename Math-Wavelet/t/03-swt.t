use Test;
use lib $*PROGRAM.parent.add('lib').Str;
use Vectors;
use Math::Wavelet;

my @cases = cases('swt.vec');
my @with-inverse = @cases.grep(*[7] ne '-');
plan @cases + 2 * @with-inverse + 4;

for @cases -> (Any, $w, $level, $start, $norm, $x, $c, $y) {
    my %level = $level eq '-' ?? () !! (level => +$level);
    my @x    = nums($x);
    my @want = list-of($c);
    my $what = "swt $w, {+@x} samples, start {$start}" ~ ($norm eq 'norm' ?? ', norm' !! '');
    my @c = swt(@x, $w, :start-level(+$start), :norm($norm eq 'norm'), |%level);
    close-to @c.map({ |$_ }).Array, @want, $what;
    next if $y eq '-';
    my @pairs = @want.rotor(2).map(*.Array);
    close-to iswt(@pairs, $w, :norm($norm eq 'norm')), nums($y), "i$what";
    # the trimmed shape carries the same coefficients and inverts the same
    close-to iswt([@pairs[0][0], |@pairs.map(*[1])], $w, :norm($norm eq 'norm')),
             nums($y), "i$what, approximation trimmed";
}

my @x = (^16).map({ sin $_ });
is swt-max-level(24), 3, 'swt-max-level 24';
is swt-max-level(1), 0, 'swt-max-level 1';
my @t = swt(@x, 'db2', :level(2), :trim-approx);
is +@t, 3, ':trim-approx gives cA_n then each detail';
throws-like { swt(@x, 'db2', :level(5)) }, Exception,
    message => /'admit at most 4'/, 'a level the length cannot carry dies';
