use Test;
use Text::Diff::Native;

# diff() on lists: golden scripts for the cases where only one answer is
# right, then properties on a few hundred random pairs — the script must
# rebuild both lists and be as short as a brute-force LCS says it can be.
# On Raku++ with the extension, the Raku implementation must also return
# exactly the extension's script for every pair: not an equally short one,
# the same one. That parity is the test of the C half.
#
# Random here is our own generator, not rand: the two engines' rand differ,
# and a case that fails on one should be the same case on the other.

my $native = diff-backend() eq 'native';
diag "diff-backend: {diff-backend}";

sub script(@a, @b) { diff(@a, @b).map({ .key ~ .value }).join(' ') }

my @golden = (
    # old            new              script                     description
    [(),             (),              '',                        'two empty lists'],
    [<a b c>,        <a b c>,         ' a  b  c',                'identical'],
    [(),             <a b>,           '+a +b',                   'all inserted'],
    [<a b>,          (),              '-a -b',                   'all deleted'],
    [<a>,            <b>,             '-a +b',                   'a replacement deletes, then inserts'],
    [<a b c d>,      <a c d e>,       ' a -b  c  d +e',          'one out, one in'],
    [<a b c>,        <x b y>,         '-a +x  b -c +y',          'changes at both ends'],
    [<a b c d e>,    <a b x d e>,     ' a  b -c +x  d  e',       'a change in the middle'],
    [<a b a b>,      <a b a b a b>,   ' a  b  a  b +a +b',       'an insertion slides down past its copies'],
    [<a b a b a b>,  <a b a b>,       ' a  b  a  b -a -b',       'a deletion slides down past its copies'],
    [<x y y y z>,    <x y y z>,       ' x  y  y -y  z',          'a repeated line: the last one goes'],
    [<a b c>,        <c b a>,         '-a -b  c +b +a',          'a reversal keeps one line'],
    [<1 2 3>,        (1, 2, 3),       ' 1  2  3',                'elements compare as strings'],
);

my $rand-cases = 300;
plan @golden + 3 + 2 * $rand-cases + ($native ?? $rand-cases + 2 !! 0) + 1;

for @golden -> [$a, $b, $want, $desc] {
    is script($a.list, $b.list), $want, $desc;
}

is-deeply diff(<a b>, <a c>).map({ .^name }).unique.List, ('Pair',), 'the script is Pairs';
is-deeply diff([1, 2], [1, 3]).map(*.value).List, (1, 2, 3), 'values are the original elements';
is script('kitten'.comb, 'sitting'.comb), '-k +s  i  t  t -e +i  n +g', 'a character diff is a diff of .comb';

# The generator, and the reference: the LCS length by dynamic programming.
my $state = 7;
sub rnd(Int $n) { $state = ($state * 1103515245 + 12345) % 2**31; $state % $n }
sub lcs(@a, @b) {
    my @prev = 0 xx (@b + 1);
    for @a -> $x {
        my @cur = 0;
        for @b.kv -> $j, $y {
            @cur.push($x eq $y ?? @prev[$j] + 1 !! max(@prev[$j + 1], @cur[$j]));
        }
        @prev = @cur;
    }
    @prev[*-1]
}
sub pair() {
    my $alpha = 1 + rnd(5);
    my @a = (^rnd(25)).map({ ('a'..'e')[rnd($alpha)] });
    my @b = (^rnd(25)).map({ ('a'..'e')[rnd($alpha)] });
    (@a, @b)
}

my @pairs = (^$rand-cases).map({ pair() });
for @pairs.kv -> $i, ($a, $b) {
    my @s = diff(@$a, @$b);
    my @old = @s.grep(*.key ne '+').map(*.value);
    my @new = @s.grep(*.key ne '-').map(*.value);
    ok @old eqv @$a.Array && @new eqv @$b.Array, "random $i rebuilds both sides";
    is @s.grep(*.key ne ' ').elems, $a.elems + $b.elems - 2 * lcs(@$a, @$b),
       "random $i is minimal";
}

if $native {
    for @pairs.kv -> $i, ($a, $b) {
        my %id;
        my $next = 0;
        my @ia = $a.map({ %id{$_} //= $next++ });
        my @ib = $b.map({ %id{$_} //= $next++ });
        is-deeply Text::Diff::Native::changes-raku(@ia, @ib),
                  Text::Diff::Native::changes(@ia, @ib), "raku agrees: random $i";
    }
    # large inputs: the recursion several levels deep, and the vectors sized
    # by the whole problem rather than a piece of it
    for 2000, 5000 -> $n {
        my @ia = (^$n).map({ rnd(40) });
        my @ib = @ia.clone;
        @ib.splice(rnd(@ib.elems), 1, rnd(40)) for ^($n div 20);
        is-deeply Text::Diff::Native::changes-raku(@ia, @ib),
                  Text::Diff::Native::changes(@ia, @ib), "raku agrees: $n elements";
    }
}

with %*ENV<TEXT_DIFF_NATIVE_REQUIRE_BACKEND> -> $want {
    is diff-backend(), $want, "backend is $want (TEXT_DIFF_NATIVE_REQUIRE_BACKEND)";
}
else {
    pass 'no backend required';
}

done-testing;
