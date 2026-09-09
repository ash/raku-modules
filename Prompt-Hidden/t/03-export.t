use Test;
use lib $?FILE.IO.parent.Str;
use Child;

plan 8;

# The exported `&prompt` must actually be THIS module's. Identity is not the
# test — Raku++ resolves a bare `prompt` call to the built-in unless the import
# really took — and neither is "did it die": core `prompt` has no named
# arguments and dies on :bogus too. Only the MESSAGE separates the two.
my ($out, $err, $rc) = child(
    'use Prompt::Hidden; try prompt("a: ", :hidden, :bogus); say $!.message.lines[0]',
    "x\n");
like $out, /'Prompt::Hidden'/, 'the imported &prompt is ours, not the built-in';
like $out, /':bogus'/, 'and it says which named argument it will not take';

($out, $err, $rc) = child(
    'use Prompt::Hidden; try prompt("a: ", "b: ", :hidden); say $!.message.lines[0]', "x\n");
like $out, /'at most one message'/, 'two messages is an error';

# There is one export, so there is nothing to select and no import list. A list
# is REFUSED rather than accepted and ignored — including `<prompt>`, which
# would otherwise be a second spelling of the default, quietly tolerating a
# typo written beside it.
($out, $err, $rc) = child('use Prompt::Hidden <prompt>; say "loaded"', "");
like $err, /'takes no import list'/, 'an import list is refused, even the valid-looking one';
isnt $out, "loaded\n", 'and the program does not run on';

($out, $err, $rc) = child('use Prompt::Hidden <prompt-backend>; say "loaded"', "");
like $err, /'Prompt::Hidden::prompt-backend'/,
     'and asking for the backend says where it actually lives';

# `prompt-backend` answers in full and does NOT land in the caller's scope.
# Raku++ publishes an `our` sub to its importer when a module is written the
# obvious way (`unit module` + `is export`), so `leaked=False` is the row that
# would catch a regression back into that shape — Rakudo would not.
($out, $err, $rc) = child(
    'use Prompt::Hidden; say Prompt::Hidden::prompt-backend(), " leaked=", (::("&prompt-backend") ~~ Callable)', "");
like $out, /^ ['core' | 'stty' | 'msvcrt'] ' leaked=False'/,
     'the backend answers in full and leaks no bare name';

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
like $out, /'[via-module-8a4d]'/, ':hidden works through a module that imports this one';

done-testing;
