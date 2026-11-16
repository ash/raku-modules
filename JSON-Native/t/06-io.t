use Test;
use JSON::Native;

# from-json reads a path or a handle, rather than stringifying it. Before this,
# `from-json($path.IO)` coerced the IO::Path to its own path and parsed THAT —
# a one-token document whose error pointed at a letter of the filename. The
# sibling CSV::Native's from-csv has always taken a path or a handle, so these
# tests also pin the two distributions to the same interface.

plan 13;

diag "json-backend: {json-backend}";

my $dir  = $*TMPDIR.add("json-native-io-{$*PID}");
$dir.mkdir;
LEAVE { .unlink for $dir.dir; $dir.rmdir }

my $doc  = '{"name":"Raku","versions":[6,6.5],"ok":true,"nope":null}';
my $file = $dir.add('doc.json');
$file.spurt($doc);

my $want = from-json($doc);

# A path
is-deeply from-json($file), $want, 'an IO::Path is read, not stringified';

# A handle
my $fh = $file.open(:r);
is-deeply from-json($fh), $want, 'an IO::Handle is read';
$fh.close;

# The handle is the caller's to close — from-csv leaves it open too, so a
# caller that reads a header itself and hands the rest over still can.
my $fh2 = $file.open(:r);
from-json($fh2);
ok $fh2.opened, 'the handle is left open for its owner to close';
$fh2.close;

# The old failure mode, stated as a test: a path must never be parsed as a
# document. If it were, this would die "at 0: expected a json object".
lives-ok { from-json($file) }, 'a path is not parsed as JSON text';

# Str input is untouched
is-deeply from-json($doc), $want, 'a Str still parses as text';
is-deeply from-json('[1,2,3]'), [1,2,3], 'a Str array';

# The Str() coercion survives for everything that is not an IO
is from-json(42), 42, 'a non-Str still coerces through Str()';

# ... including the refusal, which must still name the parameter and the type
throws-like { from-json(Mu) }, X::TypeCheck::Binding::Parameter,
    'Mu is still a type-check failure, not a parse error';

# Empty and whitespace-only files fail as the same text would
my $empty = $dir.add('empty.json');
$empty.spurt('');
throws-like { from-json($empty) }, Exception,
    'an empty file fails like empty text';

# A big-ish file, to show the path is the file's contents and not a prefix
my @many = (^2000).map({ '{"i":' ~ $_ ~ '}' });
my $big  = $dir.add('big.json');
$big.spurt('[' ~ @many.join(',') ~ ']');
my $parsed = from-json($big);
is $parsed.elems, 2000, 'a 2,000-element document reads whole';
is $parsed[1999]<i>, 1999, 'the last element is there';

# Unicode: the file is read as UTF-8, so a non-ASCII string survives
my $uni = $dir.add('uni.json');
my $e-acute = "\c[LATIN SMALL LETTER E WITH ACUTE]";   # single quotes would not interpolate it
$uni.spurt('{"city":"Sevilla","note":"caf' ~ $e-acute ~ ' — ok"}');
is from-json($uni)<city>, 'Sevilla', 'a path decodes UTF-8';
is from-json($uni)<note>, "caf$e-acute — ok",
    'non-ASCII content survives the read';

done-testing;
