use Test;
use lib $?FILE.IO.parent.add('lib').Str;

use HTTP::Simple;
use HTTP::Simple::TestServer;

plan 27;

#| Build a response head. The streaming routes write their own rather than going
#| through `reply`, because the whole point is that the head goes out before the
#| body exists.
sub head(Int $status = 200, Str $reason = 'OK', :%headers --> Blob) {
    ("HTTP/1.1 $status $reason\r\n"
     ~ %headers.kv.map(-> $k, $v { "$k: $v\r\n" }).join
     ~ "Connection: close\r\n\r\n").encode('utf8')
}

sub chunk(Str $s --> Blob) {
    my $b = $s.encode('utf8');
    Buf.new(|sprintf("%x\r\n", $b.elems).encode('utf8').list, |$b.list, 13, 10)
}

constant LAST-CHUNK = "0\r\n\r\n".encode('utf8');
constant GAP        = 0.15;     # long enough that arrival order is not a coin toss

#| The staggered routes below pace themselves with `sleep`, not with
#| `await Promise.in`. They are not interchangeable on every engine: Raku++
#| 3.14 returns from `await Promise.in($n)` immediately, so a server written
#| that way sends its whole response at once and the two arrival-order
#| assertions below would fail against a client that is behaving perfectly.

my $server = HTTP::Simple::TestServer.new(handler => -> %req {
    given %req<target> {
        # Three SSE events, spaced out, over a chunked body.
        when '/sse' {
            -> $conn {
                await $conn.write(head(200, 'OK', headers =>
                    { 'Content-Type' => 'text/event-stream',
                      'Transfer-Encoding' => 'chunked' }));
                await $conn.write(chunk(": keep-alive\n\n"));
                for 1 .. 3 -> $i {
                    sleep GAP;
                    await $conn.write(chunk("event: tick\ndata: \{\"n\": $i}\n\n"));
                }
                await $conn.write(chunk("data: one\ndata: two\n\n"));
                await $conn.write(LAST-CHUNK);
                $conn.close;
            }
        }
        # Never ends, so an early close is the only way out.
        when '/forever' {
            -> $conn {
                await $conn.write(head(200, 'OK', headers =>
                    { 'Content-Type' => 'text/event-stream',
                      'Transfer-Encoding' => 'chunked' }));
                loop {
                    my $ok = try await $conn.write(chunk("data: tick\n\n"));
                    last without $ok;
                    sleep 0.05;
                }
            }
        }
        # A head, then silence: what the idle clock is for.
        when '/quiet' {
            -> $conn {
                await $conn.write(head(200, 'OK', headers => { 'Transfer-Encoding' => 'chunked' }));
            }
        }
        # Promises a hundred bytes, sends five, hangs up.
        when '/truncated' {
            -> $conn {
                await $conn.write(head(200, 'OK', headers => { 'Content-Length' => '100' }));
                await $conn.write('short'.encode('utf8'));
                $conn.close;
            }
        }
        when '/counted'  { reply 200, 'hello world' }
        when '/lines'    { reply 200, "alpha\nbeta\r\ngamma" }
        when '/empty'    { reply 204 }
        when '/limited'  { reply 429, '{"error":"slow down"}',
                                headers => { 'Content-Type' => 'application/json' } }
        when '/moved'    { reply 302, '', headers => { Location => '/counted' } }
        default          { reply 404, 'no' }
    }
}).start;

LEAVE $server.stop;

my $base = $server.base;

# --- the head arrives before the body

my $sse = http-stream('GET', "$base/sse");
is $sse.status, 200, 'the head is readable before a byte of the body is';
is $sse.content-type, 'text/event-stream', 'and so are its headers';
isa-ok $sse.body, Supply, 'the body is a Supply';

my @events;
my @at;
my $t0 = now;
react whenever $sse.sse -> $e { @events.push($e); @at.push(now - $t0) }

is @events.elems, 4, 'four events, and the comment is not one of them';
is @events[0].event, 'tick', 'the event: field is carried';
is @events[0].data, '{"n": 1}', 'and the data: field, with the one space stripped';
is-deeply @events[1].json, { n => 2 }, '.json parses the data';
is @events[3].event, 'message', 'an event with no event: field is a message';
is @events[3].data, "one\ntwo", 'repeated data: fields join with a newline';

# The assertion that this streams at all: the first event landed while the
# server was still sitting on the later ones. A buffered client cannot do this.
ok @at[0] < @at[2] - GAP, 'events arrive as they are sent, not in one lump at the end';

# --- an early close

my $forever = http-stream('GET', "$base/forever");
my $seen = 0;
react whenever $forever.sse -> $e {
    $seen++;
    $forever.close if $seen == 2;
}
is $seen, 2, 'closing the stream ends the supply after the events already taken';

# --- lines, and a Content-Length body

my $lines = http-stream('GET', "$base/lines");
is-deeply $lines.lines.list, ('alpha', 'beta', 'gamma'),
    '.lines splits on either terminator and drops it';

my $counted = http-stream('GET', "$base/counted");
is $counted.text, 'hello world', 'a Content-Length body reads to exactly its length';

my $blob = http-stream('GET', "$base/counted").blob;
isa-ok $blob, Blob, '.blob hands back bytes';
is $blob.elems, 11, 'all of them';

# --- no body at all

my $empty = http-stream('GET', "$base/empty");
is $empty.status, 204, 'a 204 streams';
is $empty.blob.elems, 0, 'with an empty body, rather than waiting for one';

# --- an error answer to a streaming request

my $limited = http-stream('POST', "$base/limited", json => { hi => 1 });
nok $limited.ok, 'a 429 comes back as a stream with .ok False, not a throw';
is $limited.status, 429, 'the status is there to be checked first';
is-deeply $limited.response.json, { error => 'slow down' },
    '.response collects the short error body into an ordinary Response';

throws-like { http-stream('GET', "$base/limited", :fatal) }, X::HTTP::Simple::Status,
    ':fatal throws on the status, before any body is read';

throws-like { http-stream('GET', "$base/limited").raise-for-status },
    X::HTTP::Simple::Status, 'and .raise-for-status does the same by hand';

# --- redirects

my $moved = http-stream('GET', "$base/moved");
is $moved.status, 200, 'a redirect is followed before the body is handed over';
is $moved.text, 'hello world', "and the body is the target's";
is $moved.history.elems, 1, 'the 302 is kept in .history';

# --- failures

my $cut = http-stream('GET', "$base/truncated");
throws-like { $cut.blob }, X::HTTP::Simple::Transport,
    'a body that stops short of its Content-Length is a transport error';

my $quiet = http-stream('GET', "$base/quiet", idle-timeout => 1);
throws-like { $quiet.blob }, X::HTTP::Simple::Transport,
    'a stream that goes quiet trips the idle clock';
