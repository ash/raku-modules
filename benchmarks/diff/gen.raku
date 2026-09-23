# Writes the benchmark pairs: old-<n>.txt and new-<n>.txt for n = 1k, 10k and
# 100k lines. Source-like text — mostly distinct lines, some repeated ones
# (blank lines, closing braces) — and the new file is the old one with 1% of
# its lines edited: a third replaced, a third deleted, a third inserted.
# Seeded with our own generator, so every run writes the same bytes.

my $state = 42;
sub rnd(Int $n) { $state = ($state * 1103515245 + 12345) % 2**31; $state % $n }

my @words = <my our sub return if else for while given when die say push pop
             shift map grep join split lines chars elems keys values $x $y @a
             %h $i $n $s self .new .Str .Int True False Nil>;

sub line() {
    given rnd(10) {
        when 0 { '' }
        when 1 { '}' }
        default {
            ' ' x (4 * rnd(3)) ~ (^(2 + rnd(6))).map({ @words[rnd(@words.elems)] }).join(' ') ~ ';'
        }
    }
}

for 1_000, 10_000, 100_000 -> $n {
    my @old = (^$n).map({ line() });
    my @new = @old.clone;
    for ^($n div 100) {
        my $at = rnd(@new.elems);
        given rnd(3) {
            when 0 { @new[$at] = line() }
            when 1 { @new.splice($at, 1) }
            when 2 { @new.splice($at, 0, line()) }
        }
    }
    my $k = $n div 1000 ~ 'k';
    "old-$k.txt".IO.spurt(@old.map(* ~ "\n").join);
    "new-$k.txt".IO.spurt(@new.map(* ~ "\n").join);
    say "$k: {@old.elems} and {@new.elems} lines";
}
