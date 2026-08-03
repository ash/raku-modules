use Test;
use App::Rakus;

plan 10;

# The one file that does use a socket: everything above it is settled by
# `handle`, so what is left to prove is that a real request over TCP gets the
# bytes back intact.
my $root = $*TMPDIR.add("rakus-server-{$*PID}");
$root.mkdir;
$root.add('hello.txt').spurt('hello over tcp');
my $bytes = Buf.new(0, 13, 10, 200, 255, 0);   # CR and LF among the payload
$root.add('bytes.bin').spurt($bytes);

sub nuke(IO::Path $p) {
    if $p.d { nuke($_) for dir($p).map(*.IO); rmdir $p } else { unlink $p }
}
LEAVE nuke($root);

my ($listener, $port);
for 31_700 .. 31_800 -> $candidate {
    $listener = try listen-on($candidate, '127.0.0.1');
    if $listener { $port = $candidate; last }
}
die 'no free port in 31700..31800 for the test server' without $listener;

# :app_lifetime so the accept loop does not keep the process alive after the last
# test: a thread blocked in accept() never returns on its own, and every test
# here can pass while the file hangs for ever afterwards.
#
# And the listener is deliberately NOT closed on the way out. Closing one that a
# thread is blocked on wedges the exit itself — main ends up waiting on a
# condition variable inside the close, which is a far worse failure than the
# leaked descriptor it was meant to avoid. The process is about to end anyway.
Thread.start({ accept-loop($listener, $root.absolute, :!log) }, :app_lifetime);

#| One raw request, and every byte of the answer. Reading to the close is safe
#| here because the server always says `Connection: close`.
sub request(Str $line --> Buf) {
    my $c = IO::Socket::INET.new(:host<127.0.0.1>, :$port);
    $c.print("$line HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    my $buf = Buf.new;
    loop {
        my $chunk = $c.recv(2048, :bin);
        last unless $chunk.defined && $chunk.bytes;
        $buf.append($chunk);
    }
    $c.close;
    $buf
}

#| Split a raw response into its head and its body. Byte offsets: "\r\n" is a
#| single grapheme in a Raku string, so character positions do not line up.
sub split-response(Buf $raw --> List) {
    my $sep = 0;
    loop (my $i = 0; $i < $raw.bytes - 3; $i++) {
        if $raw[$i] == 13 && $raw[$i+1] == 10 && $raw[$i+2] == 13 && $raw[$i+3] == 10 {
            $sep = $i;
            last;
        }
    }
    ($raw.subbuf(0, $sep).decode('latin-1'), $raw.subbuf($sep + 4))
}

my ($head, $body) = split-response(request('GET /hello.txt'));
like $head, /^ 'HTTP/1.1 200 OK'/,          'a GET over a real socket answers 200';
like $head, /'Content-Type: text/plain'/,   'with the type its extension implies';
like $head, /'Server: rakus'/,              'and says who served it';
is $body.decode, 'hello over tcp',          'the body arrives';
like $head, /'Content-Length: ' $($body.bytes)/,
   'and Content-Length is the true byte count';

my ($bin-head, $bin-body) = split-response(request('GET /bytes.bin'));
is-deeply $bin-body.list, $bytes.list,
   'a binary body survives the socket byte for byte, CRLF and all';
like $bin-head, /'Content-Length: ' $($bytes.bytes)/,
   'its length is counted in bytes, not characters';

my ($head-head, $head-body) = split-response(request('HEAD /hello.txt'));
like $head-head, /^ 'HTTP/1.1 200 OK'/,     'a HEAD answers 200';
like $head-head, /'Content-Length: 14'/,    'with the length the body WOULD have';
is $head-body.bytes, 0,                     'and no body at all';
