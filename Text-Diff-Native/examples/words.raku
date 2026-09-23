# A word diff, the way `git diff --word-diff` shows one: diff() works on any
# list, so two sentences split into words and spaces are diffed as lists and
# the script is printed inline, [-deleted-] and {+inserted+}.
#
#   raku   -Ilib examples/words.raku
#   rakupp -Ilib examples/words.raku

use Text::Diff::Native;

my $old = 'The quick brown fox jumps over the lazy dog.';
my $new = 'The quick red fox leaps over the lazy dog!';

# words and the spaces between them, so the spacing survives the round trip
sub tokens(Str $s) { $s.comb(/\s+ | <-[\s]>+/) }

my @out;
for diff(tokens($old), tokens($new)) -> $op {
    given $op.key {
        when ' ' { @out.push($op.value) }
        when '-' { @out.push("[-{$op.value}-]") }
        when '+' { @out.push("\{+{$op.value}+}") }
    }
}
say @out.join;
say "backend: {diff-backend}";
