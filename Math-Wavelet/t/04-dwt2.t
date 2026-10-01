use Test;
use lib $*PROGRAM.parent.add('lib').Str;
use Vectors;
use Math::Wavelet;

my @cases = cases('dwt2.vec');
plan @cases + @cases.grep(*[0] eq 'wavedec2') + 2;

for @cases {
    when .[0] eq 'dwt2' {
        my (Any, $w, $mode, $x, $a, $h, $v, $d) = $_;
        my @x = matrix($x);
        my ($ca, ($ch, $cv, $cd)) = dwt2(@x, $w, :$mode);
        close-to [$ca, $ch, $cv, $cd], [matrix($a), matrix($h), matrix($v), matrix($d)],
            "dwt2 $w $mode, {+@x}×{+@x[0]}";
    }
    when .[0] eq 'idwt2' {
        my (Any, $w, $mode, $a, $h, $v, $d, $y) = $_;
        my @a = matrix($a);
        close-to idwt2((@a, (matrix($h), matrix($v), matrix($d))), $w, :$mode),
            matrix($y), "idwt2 $w $mode, {+@a}×{+@a[0]} bands";
    }
    default {
        my (Any, $w, $mode, $level, $x, $c, $y) = $_;
        my @flat = $c.split('|').map(&matrix);
        my @want = @flat[0], |@flat[1..*].rotor(3).map(*.Array);
        my @c = wavedec2(matrix($x), $w, :$mode, :level(+$level));
        close-to @c, @want, "wavedec2 $w $mode, level $level";
        close-to waverec2(@want, $w, :$mode), matrix($y), "waverec2 $w $mode";
    }
}

my @m = (^6).map(-> $i { (^6).map({ $i * $_ % 5 }).Array }).Array;
my ($a, ($h, $v, $d)) = dwt2(@m, 'db2', :mode<periodization>);
close-to idwt2(($a, (Nil, Nil, Nil)), 'db2', :mode<periodization>),
         idwt2(($a, ([0 xx 3] xx 3, [0 xx 3] xx 3, [0 xx 3] xx 3)), 'db2', :mode<periodization>),
         'an absent band reads as zeros';
throws-like { dwt2([[1, 2], [3]], 'haar') }, Exception, 'a ragged matrix dies';
