use v6.d;

unit module Perl5::Runtime;

#| Perl's split LIMIT: 0 (the value B::Deparse always emits when the program
#| gave none) means "no limit", and trailing empty fields are stripped.
#| Raku reads a 0 limit as "produce zero pieces", so the two disagree on the
#| most common call in all of Perl.
our sub p5split($pattern, Str() $string, Int() $limit = 0) is export {
    my @parts = $limit > 0
        ?? $string.split($pattern, $limit)
        !! $string.split($pattern);
    @parts.pop while $limit <= 0 && @parts && @parts[*-1] eq '';
    return @parts;
}

#| Perl's scalar(@a) in the numeric sense; kept as a named sub so generated
#| code never has to guess at Raku's coercion spelling.
our sub p5scalar(+@items) is export { @items.elems }
