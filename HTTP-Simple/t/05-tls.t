use Test;
use lib $?FILE.IO.parent.add('lib').Str;

use HTTP::Simple;
use HTTP::Simple::TestServer;

# Raku++ cannot run this file yet: it deadlocks rather than fails. The
# connection tap's `await` parks its thread on the promise while that thread
# still holds the interpreter's recursive mutex, and the spawned thread that
# would keep the promise blocks on the same mutex before it can start. The
# plain-HTTP files await shallowly enough to survive; the TLS handshake does
# not. The bare repro and the thread stacks are in notes/HTTP-Simple.md —
# drop this gate when the engine fix lands.
if $*RAKU.compiler.name eq 'Raku++' {
    plan :skip-all('await inside a socket tap deadlocks under Raku++ — see notes/HTTP-Simple.md');
    exit;
}

# The whole file needs the one optional dependency. Where it is missing, plain
# HTTP still works, so skipping is the honest outcome rather than a failure.
my $ssl = try { require ::('IO::Socket::Async::SSL'); ::('IO::Socket::Async::SSL') };
if $ssl.^name eq 'Any' {
    plan :skip-all('IO::Socket::Async::SSL is not installed');
    exit;
}

plan 14;

# Test certificates, generated once and committed: a private CA, a leaf for
# 127.0.0.1 signed by it, and a leaf for a name this host does not answer to.
# They expire in 2046. The keys are test keys and guard nothing.
my $tls    = $?FILE.IO.parent.add('tls');
my $ca     = $tls.add('ca.crt').Str;
my $cert   = $tls.add('server.crt').Str;
my $key    = $tls.add('server.key').Str;
my $wrong  = $tls.add('other.crt').Str;
my $wrong-key = $tls.add('other.key').Str;

my $server = HTTP::Simple::TestServer.new(
    tls              => True,
    certificate-file => $cert,
    private-key-file => $key,
    handler => -> %req {
        given %req<target> {
            when '/hello' { reply 200, 'hello over TLS' }
            when '/json'  { reply 200, '{"secure":true}',
                            headers => { 'Content-Type' => 'application/json' } }
            when '/echo'  { reply 200, %req<body> }
            when '/moved' { reply 302, '', headers => { Location => '/hello' } }
            when '/set'   { reply 200, 'ok',
                            headers => { 'Set-Cookie' => 'sid=tls-42; Path=/' } }
            when '/saw'   { reply 200, (%req<headers><cookie> // '(none)') }
            default       { reply 404, 'no' }
        }
    }).start;

LEAVE $server.stop;

my $base = $server.base;
like $base, /^ 'https://'/, 'the test server is speaking https';

# --- the happy path: a certificate the caller has decided to trust

my $r = http-get "$base/hello", ca-file => $ca;
is $r.status, 200,               'https GET reaches the server';
is $r.text,   'hello over TLS',  'and the body comes back intact';
is $r.url,    "$base/hello",     'the response records the https URL';

is http-get-json("$base/json", ca-file => $ca)<secure>, True,
   'JSON decodes over TLS just as it does over plain HTTP';

is http-post("$base/echo", body => 'sent under TLS', ca-file => $ca).text,
   'sent under TLS', 'a request body survives the round trip';

# --- verification is on unless the caller turns it off

throws-like { http-get "$base/hello" }, X::HTTP::Simple::Transport,
    'without :ca-file the private CA is not trusted, so the call fails';

my $why = '';
try { http-get "$base/hello"; CATCH { default { $why = .message } } }
like $why, /:i verif | certificate/,
    'and the message says it was the certificate, not a timeout';

is http-get("$base/hello", insecure => True).text, 'hello over TLS',
   ':insecure accepts the certificate anyway';

# --- the name on the certificate has to be the name that was asked for

my $liar = HTTP::Simple::TestServer.new(
    tls              => True,
    certificate-file => $wrong,
    private-key-file => $wrong-key,
    handler          => -> %req { reply 200, 'should never be read' },
).start;
LEAVE $liar.stop;

throws-like { http-get $liar.base ~ '/hello', ca-file => $ca },
    X::HTTP::Simple::Transport,
    'a certificate signed by the trusted CA but for another host is rejected';

# --- the client layer over TLS

my $http = HTTP::Simple::Client.new(base-uri => $base, ca-file => $ca);
is $http.get('/hello').text, 'hello over TLS',
   'the client takes ca-file once, for every request it makes';

my $redirected = $http.get('/moved');
is $redirected.status, 200,     'a redirect is followed over TLS';
is $redirected.history.elems, 1, 'and the 302 is kept in the history';

$http.get('/set');
is $http.get('/saw').text, 'sid=tls-42',
   'the cookie jar works over TLS as well';
