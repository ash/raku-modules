use Test;

# JSON::Native is a drop-in for JSON::Fast: change `use JSON::Fast` to
# `use JSON::Native` and the program keeps working. That includes JSON::Fast's
# import options, which change the defaults of the subs `use` hands out:
#
#   use JSON::Fast <immutable !pretty sorted-keys enums-as-value>;
#
# Each case runs in a fresh process, since an import is a compile-time thing.

plan 6;

sub run-with(Str $use, Str $code) {
    my $p = run $*EXECUTABLE, '-Ilib', '-e', "$use; $code", :out, :err;
    my $out = $p.out.slurp(:close);
    my $err = $p.err.slurp(:close);
    $p.exitcode == 0 ?? $out.chomp !! "DIED: $err.lines.head()"
}

is run-with('use JSON::Native', 'print to-json({b => 1, a => [2]}, :sorted-keys)'),
   qq/\{\n  "a": [\n    2\n  ],\n  "b": 1\n}/,
   'with no options, the defaults are JSON::Fast\'s: pretty, unsorted unless asked';

is run-with('use JSON::Native <!pretty>', 'print to-json([1, [2]])'),
   '[1,[2]]', '<!pretty> makes compact output the default';

is run-with('use JSON::Native <!pretty sorted-keys>', 'print to-json({b => 1, a => 2, c => 3})'),
   '{"a":2,"b":1,"c":3}', '<sorted-keys> sorts by default';

is run-with('use JSON::Native <!pretty enums-as-value>', 'enum E <x y>; print to-json([x, y])'),
   '[0,1]', '<enums-as-value> writes an enum as its value';

is run-with('use JSON::Native <immutable>', 'print from-json(q<{"a":[1]}>).^name, " ", from-json(q<[1]>).^name'),
   'Map List', '<immutable> makes Map and List the default';

is run-with('use JSON::Native <!pretty>', 'print to-json([1], :pretty)'),
   "[\n  1\n]", 'an adverb at the call still wins over the default';
