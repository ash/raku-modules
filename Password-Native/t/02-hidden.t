use Test;
use lib $?FILE.IO.parent.Str;
use Child;

# `:hidden` where there is no terminal. A pipe has no echo to suppress, so the
# line is read plainly — which is what makes any of this assertable without a
# pseudo-terminal. What echo suppression itself does is xt/01-tty.t.
plan 9;

my ($out, $err, $rc) = child(
    'use Password::Native; my $x = prompt("pw: ", :hidden); say "[$x]"', "hunter2-a91c\n");
is $rc, 0, 'hidden prompt exits clean';
is $out, "pw: [hunter2-a91c]\n", 'message printed, secret returned';
is $err, '', 'nothing on stderr';

# The secret is a Str, NOT the allomorph an ordinary prompt returns. An IntStr
# serialises through JSON as a NUMBER, so a PIN would lose its leading zero and
# stop being a string at all.
($out, $err, $rc) = child(
    'use Password::Native; say prompt("pin: ", :hidden).^name', "01234\n");
is $out, "pin: Str\n", 'an all-digit secret is a Str, not an IntStr';

($out, $err, $rc) = child(
    'use Password::Native; my $x = prompt("pin: ", :hidden); say $x eq "01234"', "01234\n");
is $out, "pin: True\n", 'and it keeps its leading zero';

($out, $err, $rc) = child(
    'use Password::Native; say prompt("pw: ", :hidden).^name', "");
is $out, "pw: Nil\n", 'end of input is Nil';

($out, $err, $rc) = child(
    'use Password::Native; my $x = prompt(:hidden); say "[$x]"', "bare-6d20\n");
is $out, "[bare-6d20]\n",
   'no message prints nothing — not the :hidden pair itself';

# Spaces and punctuation survive: `.get`, not a shell round trip.
($out, $err, $rc) = child(
    'use Password::Native; my $x = prompt(:hidden); say "[$x]"',
    "a b\tc\"d\$e'f-3e77\n");
is $out, "[a b\tc\"d\$e'f-3e77]\n", 'whitespace and shell metacharacters survive';

($out, $err, $rc) = child(
    'use Password::Native; my $x = prompt("pw: ", :hidden); say "[$x]"',
    "unicode-Ω-π-4c8b\n");
is $out, "pw: [unicode-Ω-π-4c8b]\n", 'non-ASCII survives';

done-testing;
