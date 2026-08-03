use Test;
use App::Rakus;

plan 18;

# A tree to serve. `handle` never touches a socket, so everything about what the
# server ANSWERS can be settled here, with no port and no network.
my $root = $*TMPDIR.add("rakus-handle-{$*PID}");
$root.mkdir;
$root.add('index.html').spurt('<h1>root index</h1>');
$root.add('hello.txt').spurt('hello');
$root.add('a b.txt').spurt('spaces');
$root.add('.hidden').spurt('secret');
my $bytes = Buf.new(0, 1, 2, 254, 255);
$root.add('bytes.bin').spurt($bytes);
$root.add('sub').mkdir;
$root.add('sub/a.txt').spurt('in sub');
$root.add('nested').mkdir;
$root.add('nested/index.html').spurt('<h1>nested index</h1>');

sub nuke(IO::Path $p) {
    if $p.d { nuke($_) for dir($p).map(*.IO); rmdir $p } else { unlink $p }
}
LEAVE nuke($root);

my $R = $root.absolute;

# --- files

my ($status, $ctype, $body, $extra) = handle('GET', '/hello.txt', $R);
is $status, 200,                        'a file is served';
is $ctype,  'text/plain; charset=utf-8', 'with the type its extension implies';
is $body.decode, 'hello',               'and its contents';

is handle('GET', '/hello.txt?v=2', $R)[0], 200, 'a query string is not part of the path';
is handle('GET', '/a%20b.txt', $R)[2].decode, 'spaces', 'the target is URL-decoded';

# Byte-exactness is the whole point of reading files as Buf: an image that goes
# through a text round trip arrives corrupted and nothing says so.
is-deeply handle('GET', '/bytes.bin', $R)[2].list, $bytes.list,
   'a binary file is served byte for byte';

# --- directories

is handle('GET', '/', $R)[2].decode, '<h1>root index</h1>',
   'a directory with an index.html serves it';
is handle('GET', '/nested/', $R)[2].decode, '<h1>nested index</h1>',
   'at any depth';

my @listing = handle('GET', '/sub/', $R);
is @listing[0], 200,                             'a directory without one is still 200';
like @listing[2].decode, /'Index of /sub/'/,     'and gets a generated listing';
like @listing[2].decode, /'a.txt'/,              'naming what is in it';

# A dotfile is not secret, but listing it invites the assumption that it is not
# served either — which it is. Better not to advertise.
unlike handle('GET', '/', $R)[2].decode, /'.hidden'/,
   'dotfiles stay out of a listing';

# --- redirects, refusals and misses

my @moved = handle('GET', '/sub', $R);
is @moved[0], 301, 'a directory without a trailing slash redirects';
is @moved[3].value, '/sub/', 'to itself with the slash, so relative links resolve';

is handle('GET', '/nope.txt', $R)[0], 404, 'a missing file is 404';
is handle('GET', '/../secrets', $R)[0], 403, 'a .. segment is refused, not resolved';
is handle('POST', '/hello.txt', $R)[0], 405, 'a method other than GET/HEAD is 405';

# HEAD answers exactly as GET does, body included — the caller drops the bytes
# and keeps the length, which is what makes Content-Length honest on a HEAD.
is handle('HEAD', '/hello.txt', $R)[2].decode, 'hello',
   'HEAD is answered like a GET, so its Content-Length is the real one';
