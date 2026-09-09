use Test;
use lib $?FILE.IO.parent.Str;
use Child;

plan 10;

# The exported `&prompt` must actually be THIS module's. Identity is not the
# test — Raku++ resolves a bare `prompt` call to the built-in unless the import
# really took — and neither is "did it die": Rakudo's own prompt has no named
# arguments and dies on :bogus too. Only the MESSAGE separates the two.
my ($out, $err, $rc) = child(
    'use Prompt::Hidden; try prompt("a: ", :hidden, :bogus); say $!.message.lines[0]',
    "x\n");
like $out, /'Prompt::Hidden'/, 'the imported &prompt is ours, not the built-in';
like $out, /':bogus'/, 'and it says which named argument it will not take';

($out, $err, $rc) = child(
    'use Prompt::Hidden; try prompt("a: ", "b: ", :hidden); say $!.message.lines[0]', "x\n");
like $out, /'at most one message'/, 'two messages is an error';

# An import list, spelled <name> — not :name, which Rakudo routes through the
# `is export(:tag)` machinery a sub EXPORT module has no part in.
($out, $err, $rc) = child(
    'use Prompt::Hidden <prompt>; my $x = prompt("q: ", :hidden); say "[$x]"', "picked-2f9e\n");
is $out, "q: [picked-2f9e]\n", 'use Prompt::Hidden <prompt> exports prompt';

($out, $err, $rc) = child(
    'use Prompt::Hidden <prompt-backend>; say prompt-backend()', "");
like $out, /^ ['core' | 'stty' | 'msvcrt'] $$/,
     'use Prompt::Hidden <prompt-backend> exports it alone';

# …and only that one: asking for just prompt-backend must NOT put prompt in
# scope as ours. Whatever answers `prompt` then, it is not this module — so the
# error, if any, must not carry this module's name.
($out, $err, $rc) = child(
    'use Prompt::Hidden <prompt-backend>; try prompt("a: ", :hidden, :bogus); say ($! ?? $!.message.lines[0] !! "no error")',
    "x\n");
unlike $out, /'Prompt::Hidden'/, 'an import list of one does not export the other';

# An unknown import name is refused, and the MESSAGE is what every engine
# agrees on — so that is what is asserted here.
#
# The exit code is deliberately not: Raku++ up to 3.26.0 downgraded a failing
# `sub EXPORT` to a warning and carried on at exit 0, where Rakudo aborts
# compilation and exits 1. That is fixed in the engine (unreleased at the time
# of writing) — and it is asserted THERE, in the engine's own regression suite,
# because it is a property of the engine rather than of this module. Pinning it
# here would only turn a version floor into a test failure.
($out, $err, $rc) = child('use Prompt::Hidden <nonesuch>; say "loaded"', "");
like $err, /'nonesuch'/, 'an unknown import name is refused, by name';
like $err, /'Prompt::Hidden'/, 'and the refusal names this module';

# A MODULE importing this one must precompile. On Rakudo a module's `use` runs
# at precompilation, in another process, and the importer's serialisation walks
# the imported file's state — a module-scope `try` would leave its exception in
# `$!` and take the whole build down with a serialisation error. The engine
# probe here is inside a sub for exactly that reason, and this is what proves
# it: a plain program importing this module precompiles nothing and would never
# have noticed.
($out, $err, $rc) = child(
    'use lib "t/lib"; use Consumer; my $x = consumer-prompt("c: ", :hidden); say "[$x] {consumer-backend()}"',
    "via-module-8a4d\n");
is $rc, 0, 'a module can import this one and precompile';
like $out, /'[via-module-8a4d]'/, 'and :hidden still works through it';

done-testing;
