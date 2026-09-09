use Test;
use lib $?FILE.IO.parent.Str;
use Child;

# `prompt` WITHOUT :hidden must be CORE::<&prompt>, forwarded whole. Every row
# uses a fixture of its own, so a stale or leaked answer cannot satisfy two.
plan 8;

my ($out, $err, $rc) = child(
    'use Prompt::Hidden; my $x = prompt("who: "); say "[$x]"', "ada-4b1f\n");
is $rc, 0, 'plain prompt exits clean';
is $out, "who: [ada-4b1f]\n", 'message printed, line returned';

($out, $err, $rc) = child(
    'use Prompt::Hidden; say prompt("n: ").^name', "1234\n");
is $out, "n: IntStr\n", 'a numeric line still comes back an allomorph';

($out, $err, $rc) = child(
    'use Prompt::Hidden; say prompt("n: ").^name', "0x1f\n");
is $out, "n: IntStr\n", 'and a hex one too — val() is untouched';

($out, $err, $rc) = child(
    'use Prompt::Hidden; say prompt("n: ").^name', "not-a-number\n");
is $out, "n: Str\n", 'a non-numeric line is a plain Str';

($out, $err, $rc) = child('use Prompt::Hidden; say prompt("eof: ").^name', "");
is $out, "eof: Nil\n", 'end of input is Nil';

($out, $err, $rc) = child(
    'use Prompt::Hidden; my $x = prompt(); say "[$x]"', "no-message-9c2e\n");
is $out, "[no-message-9c2e]\n", 'no message prints nothing';

# `:!hidden` is an ordinary prompt, allomorph and all — it must NOT be routed
# to the hidden reader, which returns a Str.
($out, $err, $rc) = child(
    'use Prompt::Hidden; say prompt("n: ", :!hidden).^name', "1234\n");
is $out, "n: IntStr\n", ':!hidden is an ordinary prompt';

done-testing;
