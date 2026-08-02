use Test;
use lib $?FILE.IO.parent.add('lib').Str;

use HTTP::Simple;
use HTTP::Simple::TestServer;

plan 20;

my $slow = 0;

my $server = HTTP::Simple::TestServer.new(handler => -> %req {
    given %req<target> {
        when '/plain'   { reply 200, 'hello' }
        when '/chunked' { reply 200, "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n",
                                headers => { 'Transfer-Encoding' => 'chunked' } }
        when '/setc'    { reply 200, 'set',
                                headers => { 'Set-Cookie' => ('a=1; Path=/; HttpOnly', 'b=2') } }
        when '/showc'   { reply 200, (%req<headers><cookie> // '(none)') }
        when '/agent'   { reply 200, (%req<headers><user-agent> // '') }
        when '/auth'    { reply 200, (%req<headers><authorization> // '') }
        when '/host'    { reply 200, (%req<headers><host> // '') }
        when '/hdr'     { reply 200, (%req<headers><x-token> // '(none)') }
        when '/flaky'   { $slow++; reply($slow < 3 ?? 500 !! 200, "try $slow") }
        when '/latin'   { reply 200, Buf.new(104, 233, 108),
                                headers => { 'Content-Type' => 'text/plain; charset=iso-8859-1' } }
        default         { reply 404, 'no' }
    }
}).start;

LEAVE $server.stop;

my $base = $server.base;

# --- chunked transfer

is http-get("$base/chunked").text, 'hello world', 'a chunked body is reassembled';

# --- charset handling

is http-get("$base/latin").text, "h\c[LATIN SMALL LETTER E WITH ACUTE]l",
   'a latin-1 body decodes per its declared charset';

# --- headers

like http-get("$base/agent").text, /^ 'HTTP::Simple/'/, 'a User-Agent is sent by default';
is http-get("$base/agent", headers => { 'User-Agent' => 'mine/1' }).text, 'mine/1',
   ':headers overrides the default User-Agent';
is http-get("$base/host").text, "127.0.0.1:{$server.port}",
   'a non-default port stays in the Host header';

is http-get("$base/auth", bearer => 'tok').text, 'Bearer tok', ':bearer sets Authorization';
is http-get("$base/auth", auth => ['ada', 'l0velace']).text, 'Basic YWRhOmwwdmVsYWNl',
   ':auth base64-encodes the credentials';

# --- the client object

my $http = HTTP::Simple::Client.new(
    base-uri => $base,
    headers  => { 'X-Token' => 'shared' },
);

is $http.get('/plain').text, 'hello', 'base-uri joins a leading-slash path';
is $http.get('plain').text,  'hello', 'and a path without one';
is $http.get('/hdr').text,   'shared', 'the client headers go out on every request';
is $http.get('/hdr', headers => { 'X-Token' => 'once' }).text, 'once',
   'a per-request header wins over the client default';
is $http.get("$base/plain").text, 'hello', 'an absolute URL ignores base-uri';

is $http.post('/plain').status, 200, 'the client has .post';
is $http.head('/plain').status, 200, 'and .head, without shadowing CORE head';

# --- the cookie jar

$http.get('/setc');
is-deeply $http.cookies-for('127.0.0.1'), { a => '1', b => '2' },
    'Set-Cookie fills the jar, attributes stripped';
is $http.get('/showc').text, 'a=1; b=2', 'and the jar is sent back';

my $no-jar = HTTP::Simple::Client.new(base-uri => $base, cookies => False);
$no-jar.get('/setc');
is $no-jar.get('/showc').text, '(none)', 'cookies => False keeps the jar shut';

is http-get("$base/showc").text, '(none)', 'the sub layer is stateless between calls';

# --- retries

$slow = 0;
is http-get("$base/flaky", retries => 5).text, 'try 1',
   'a 500 is an answer, so retries do not fire';

# --- transport failures

throws-like { http-get 'http://127.0.0.1:1/nothing' }, X::HTTP::Simple::Transport,
    'a refused connection throws a transport error';
