use Test;
use lib $?FILE.IO.parent.add('lib').Str;

use HTTP::Simple;
use HTTP::Simple::TestServer;

plan 7;

my $gets  = 0;
my $posts = 0;

my $server = HTTP::Simple::TestServer.new(handler => -> %req {
    given %req<target> {
        # Answers nothing at all, so the client has to give up on its own.
        when '/hang'  { Nil }
        # Closes without a response the first two times it is asked.
        when '/flaky' {
            $gets++;
            $gets < 3 ?? Blob.new !! reply(200, "got it on try $gets");
        }
        when '/flaky-post' {
            $posts++;
            $posts < 3 ?? Blob.new !! reply(200, "post try $posts");
        }
        default { reply 404, 'no' }
    }
}).start;

LEAVE $server.stop;

my $base = $server.base;

# --- timeouts

my $t0 = now;
throws-like { http-get "$base/hang", timeout => 1 }, X::HTTP::Simple::Transport,
    'a server that never answers times out';
my $spent = now - $t0;
ok $spent >= 0.8, "the timeout waited its second (waited {$spent.round(0.01)} s)";
ok $spent <  6,   'and did not wait much longer';

# --- retries

$gets = 0;
throws-like { http-get "$base/flaky" }, X::HTTP::Simple::Transport,
    'without :retries a transport failure is fatal';

$gets = 0;
is http-get("$base/flaky", retries => 3).text, 'got it on try 3',
   ':retries repeats a failed GET until it works';

$posts = 0;
throws-like { http-post "$base/flaky-post", retries => 3 }, X::HTTP::Simple::Transport,
    'a POST is never retried, however many are asked for';
is $posts, 1, 'and it really was sent only once';
