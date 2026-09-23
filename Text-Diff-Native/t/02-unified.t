use Test;
use Text::Diff::Native;

# unified-diff() against golden output, and on Raku++ with the extension the
# Raku implementation against the native one — the same bytes for every case
# here and for a few hundred random pairs of texts.
#
# Every golden is what GNU diff 3.10 prints for the same two files with
# `diff -u --label a --label b` (and -U<n> where a context is given) —
# checked when the case was written, not assumed: these are cases where only
# one minimal diff exists, or where GNU and this module pick the same one.

sub body(*@lines) { @lines.map(* ~ "\n").join }

my @cases = (
    # old, new, options, expected, description
    ["a\nb\nc\n", "a\nb\nc\n", {}, '', 'identical texts: no output'],
    ['', '', {}, '', 'two empty texts: no output'],
    ["a\nb\nc\n", "a\nc\nd\n", {},
        body('--- a', '+++ b', '@@ -1,3 +1,3 @@', ' a', '-b', ' c', '+d'),
        'one out, one in'],
    ['', "a\nb\n", {},
        body('--- a', '+++ b', '@@ -0,0 +1,2 @@', '+a', '+b'),
        'from nothing: the empty range is 0,0'],
    ["a\nb\n", '', {},
        body('--- a', '+++ b', '@@ -1,2 +0,0 @@', '-a', '-b'),
        'to nothing'],
    ["a\n", "b\n", {},
        body('--- a', '+++ b', '@@ -1 +1 @@', '-a', '+b'),
        'a one-line range has no count'],
    ["1\n2\n3\n4\n5\n6\n7\n8\n9\n", "1\n2\n3\n4\n5\n6\n7\n8\n9\nX\n", {},
        body('--- a', '+++ b', '@@ -7,3 +7,4 @@', ' 7', ' 8', ' 9', '+X'),
        'three lines of context by default'],
    ["1\n2\n3\n4\n5\n", "1\n2\nX\n3\n4\n5\n", {:context(0)},
        body('--- a', '+++ b', '@@ -2,0 +3 @@', '+X'),
        'context 0: an insertion names the line it follows'],
    ["1\n2\n3\n4\n5\n", "1\n2\n4\n5\n", {:context(0)},
        body('--- a', '+++ b', '@@ -3 +2,0 @@', '-3'),
        'context 0: a deletion'],
    ["1\n2\n3\n4\n5\n", "1\n2\nX\n3\n4\n5\n", {:context(1)},
        body('--- a', '+++ b', '@@ -2,2 +2,3 @@', ' 2', '+X', ' 3'),
        'context 1'],
    ["x\n", "x", {},
        "--- a\n+++ b\n@@ -1 +1 @@\n-x\n+x\n\\ No newline at end of file\n",
        'a missing final newline is a change'],
    ["x", "x\n", {},
        "--- a\n+++ b\n@@ -1 +1 @@\n-x\n\\ No newline at end of file\n+x\n",
        'an added final newline'],
    ["a\nx", "b\nx", {},
        "--- a\n+++ b\n@@ -1,2 +1,2 @@\n-a\n+b\n x\n\\ No newline at end of file\n",
        'unterminated context line on both sides'],
    ["a\r\nb\r\n", "a\r\nc\r\n", {},
        "--- a\n+++ b\n@@ -1,2 +1,2 @@\n a\r\n-b\r\n+c\r\n",
        'CRLF lines keep their CR'],
    ["a\r\nb\n", "a\nb\n", {},
        body('--- a', '+++ b', '@@ -1,2 +1,2 @@', "-a\r", '+a', ' b'),
        'CRLF and LF are different lines'],
    ["a\rb\n", "a\rc\n", {},
        body('--- a', '+++ b', '@@ -1 +1 @@', "-a\rb", "+a\rc"),
        'a lone CR is content, not a line ending'],
    ["é\n日本\n", "é\n日本語\n", {},
        body('--- a', '+++ b', '@@ -1,2 +1,2 @@', ' é', '-日本', '+日本語'),
        'non-ASCII lines'],
    ["a\nb\n", "a\nc\n", {:from<old/f.txt>, :to<new/f.txt>},
        body('--- old/f.txt', '+++ new/f.txt', '@@ -1,2 +1,2 @@', ' a', '-b', '+c'),
        ':from and :to name the sides'],
);

# Two changes are one hunk while no more than 2 × context unchanged lines lie
# between them, and two hunks from one line more.
my $six  = (1..6).map(* ~ "\n").join;
my $seven = (1..7).map(* ~ "\n").join;
@cases.push: ["A\n{$six}B\n", "X\n{$six}Y\n", {},
    body('--- a', '+++ b', '@@ -1,8 +1,8 @@', '-A', '+X', |(1..6).map(' ' ~ *), '-B', '+Y'),
    'six lines between two changes: one hunk at context 3'];
@cases.push: ["A\n{$seven}B\n", "X\n{$seven}Y\n", {},
    body('--- a', '+++ b', '@@ -1,4 +1,4 @@', '-A', '+X', ' 1', ' 2', ' 3',
         '@@ -6,4 +6,4 @@', ' 5', ' 6', ' 7', '-B', '+Y'),
    'seven lines between: two hunks'];

my $native = diff-backend() eq 'native';
diag "diff-backend: {diff-backend}";

# Random texts for the parity check: short lines from a small alphabet, so
# there is much to match and many ways to match it, some ending without a
# newline and some with CRLF or a lone CR.
my $state = 11;
sub rnd(Int $n) { $state = ($state * 1103515245 + 12345) % 2**31; $state % $n }
sub text() {
    my @ends = "\n", "\n", "\n", "\r\n";
    my $t = (^rnd(30)).map({ <a b c d e>[rnd(3)] ~ (rnd(9) == 0 ?? "\r" !! '') ~ @ends[rnd(4)] }).join;
    rnd(4) == 0 ?? $t ~ <x y>[rnd(2)] !! $t
}
my $rand-cases = 300;
my @random = (^$rand-cases).map({ (text(), text(), rnd(4)) });

plan @cases + 6 + ($native ?? @cases + $rand-cases !! 0);

for @cases -> [$old, $new, %opt, $want, $desc] {
    is unified-diff($old, $new, |%opt), $want, $desc;
}

# Paths: read with their bytes intact, and naming their sides.
my $dir = $*TMPDIR.add("text-diff-native-{$*PID}");
$dir.mkdir;
my $p = $dir.add('old.txt');
my $q = $dir.add('new.txt');
$p.spurt("a\r\nb\r\n");
$q.spurt("a\r\nc\r\n");
is unified-diff($p, $q),
   "--- $p\n+++ $q\n@@ -1,2 +1,2 @@\n a\r\n-b\r\n+c\r\n",
   'paths are read with CRLF intact and name the sides';
is unified-diff($p, $q, :from<a>, :to<b>).lines[0, 1].join('|'), '--- a|+++ b',
   ':from and :to override a path';
is unified-diff($p, $p), '', 'a file against itself';
$dir.dir».unlink;
$dir.rmdir;

throws-like { unified-diff('a', 'b', :context(-1)) }, Exception,
    message => 'Text::Diff::Native: context must not be negative',
    'a negative context is refused';

# The lines as the module sees them.
is-deeply Text::Diff::Native::split-lines("a\nb\r\nc"), ["a\n", "b\r\n", "c"],
    'split-lines keeps each terminator, and the last line without one';
is-deeply Text::Diff::Native::split-lines("a\n\n"), ["a\n", "\n"],
    'a blank line is a line';

if $native {
    for @cases -> [$old, $new, %opt, $want, $desc] {
        is Text::Diff::Native::unified-raku($old, $new, %opt<context> // 3,
                                            %opt<from> // 'a', %opt<to> // 'b'),
           unified-diff($old, $new, |%opt), "raku agrees: $desc";
    }
    for @random.kv -> $i, ($old, $new, $c) {
        is Text::Diff::Native::unified-raku($old, $new, $c, 'a', 'b'),
           unified-diff($old, $new, :context($c)), "raku agrees: random $i";
    }
}

done-testing;
