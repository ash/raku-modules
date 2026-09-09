use Test;
use lib $?FILE.IO.parent.Str;
use Child;

plan 5;

my ($out, $err, $rc) = child('use Prompt::Hidden; say Prompt::Hidden::prompt-backend()', "");
my $backend = $out.chomp;
ok $backend ∈ <core stty msvcrt>, "prompt-backend is one of the three (got '$backend')";

# Which one is not a free choice: the engine primitive decides it. On a box
# that is not Windows, no primitive means stty.
my $has-primitive =
    child('say (try &::("rakupp-prompt-hidden")) ~~ Callable', "")[0].chomp eq 'True';
is $backend, ($has-primitive ?? 'core' !! 'stty'),
   'the engine primitive decides between core and stty';

# Forcing the Windows branch loads Prompt::Hidden::Win32 and routes to it —
# on any OS, which is the only way to exercise the dispatch off Windows. The
# branch is asserted, not the syscall.
($out, $err, $rc) = child('use Prompt::Hidden; say Prompt::Hidden::prompt-backend()', "",
                          RAKU_PROMPT_HIDDEN_FORCE_WIN => '1');
is $out.chomp, ($has-primitive ?? 'core' !! 'msvcrt'),
   'the Windows branch routes to msvcrt — unless the engine has its own';

# …and the unforced load must NOT have taken it. Same probe, no force: an
# msvcrt answer here would mean the Windows half loads everywhere, which is
# precisely what putting it in its own file is meant to prevent.
isnt $backend, 'msvcrt', 'the Windows half is not loaded when it is not needed';

# The Windows half is a real compilation unit on every platform, even though
# only Windows ever calls into it — a syntax error there would otherwise reach
# nobody until a Windows user hit it.
($out, $err, $rc) = child(
    'use Prompt::Hidden::Win32; say &getch-line.defined', "");
is $out.chomp, 'True', 'Prompt::Hidden::Win32 compiles and defines getch-line';

done-testing;
