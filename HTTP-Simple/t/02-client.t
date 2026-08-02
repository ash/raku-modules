use Test;
use lib $?FILE.IO.parent.add('lib').Str;

use JSON::Fast;
use HTTP::Simple;
use HTTP::Simple::TestServer;

plan 32;

# Everything below talks to a server running in this very process, so the suite
# needs no network and no fixtures.

my $server = HTTP::Simple::TestServer.new(handler => -> %req {
    given %req<target> {
        when '/plain'    { reply 200, 'hello' }
        when '/json'     { reply 200, '{"name":"Ada","ids":[1,2,3]}',
                                 headers => { 'Content-Type' => 'application/json' } }
        when '/utf8'     { reply 200, 'héllo',
                                 headers => { 'Content-Type' => 'text/plain; charset=utf-8' } }
        when '/missing'  { reply 404, 'nope' }
        when '/boom'     { reply 500, 'sorry' }
        when '/echo'     { reply 200, %req<body>,
                                 headers => { 'X-Method' => %req<method>,
                                              'X-Sent-Type' => (%req<headers><content-type> // '') } }
        when /^ '/query' / { reply 200, %req<target> }
        when '/hop1'     { reply 302, '', headers => { Location => '/hop2' } }
        when '/hop2'     { reply 302, '', headers => { Location => '/plain' } }
        when '/see'      { reply 303, '', headers => { Location => '/echo' } }
        when '/keep'     { reply 307, '', headers => { Location => '/echo' } }
        when '/loop'     { reply 302, '', headers => { Location => '/loop' } }
        when '/setc'     { reply 200, 'set',
                                 headers => { 'Set-Cookie' => ('a=1; Path=/', 'b=2') } }
        when '/showc'    { reply 200, (%req<headers><cookie> // '(none)') }
        when '/chunked'  { reply 200, "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n",
                                 headers => { 'Transfer-Encoding' => 'chunked' } }
        when '/head'     { reply 200, 'body-should-not-arrive' }
        when '/agent'    { reply 200, (%req<headers><user-agent> // '') }
        when '/auth'     { reply 200, (%req<headers><authorization> // '') }
        when '/hosthdr'  { reply 200, (%req<headers><host> // '') }
        default          { reply 404, "no route for $_" }
    }
}).start;

LEAVE $server.stop;

my $base = $server.base;

# --- the one-shot layer

my $r = http-get "$base/plain";
ok  $r.ok,               'a 200 is ok';
is  $r.status, 200,      'status is parsed';
is  $r.reason, 'OK',     'reason is parsed';
is  $r.text,   'hello',  'the body arrives';
is  $r.url,    "$base/plain", 'the response knows its URL';

is http-get("$base/utf8").text, 'héllo', 'a UTF-8 body decodes per the charset';

is-deeply http-get-json("$base/json")<ids>.List, (1, 2, 3), 'http-get-json decodes';

my $missing = http-get "$base/missing";
nok $missing.ok,          'a 404 comes back rather than throwing';
is  $missing.status, 404, 'and carries its status';
is  $missing.text, 'nope','and its body';

throws-like { http-get "$base/boom", :fatal }, X::HTTP::Simple::Status,
    ':fatal turns a 500 into a throw';

# --- bodies and methods

my $posted = http-post "$base/echo", body => 'raw bytes', content-type => 'text/plain';
is $posted.text, 'raw bytes',           'a raw body round-trips';
is $posted.header('x-method'), 'POST',  'the method reaches the server';
is $posted.header('x-sent-type'), 'text/plain', ':content-type is honoured';

my $j = http-post "$base/echo", json => { a => 1 };
is $j.header('x-sent-type'), 'application/json', ':json sets the content type';
is-deeply from-json($j.text), { a => 1 }, ':json encodes the body';

my $f = http-post "$base/echo", form => { name => 'Ada L', n => 2 };
is $f.header('x-sent-type'), 'application/x-www-form-urlencoded',
   ':form sets the content type';
is $f.text, 'n=2&name=Ada%20L', ':form encodes and escapes';

is http-put("$base/echo", body => 'p').header('x-method'),    'PUT',    'http-put';
is http-delete("$base/echo").header('x-method'),              'DELETE', 'http-delete';
is http-options("$base/echo").header('x-method'),             'OPTIONS','http-options';

my $h = http-head "$base/head";
is $h.status, 200, 'http-head gets a status';
is $h.text,   '',  'and no body';

# --- query parameters

is http-get("$base/query", query => { b => 2, a => 'x y' }).text,
   '/query?a=x%20y&b=2', ':query is appended and escaped';
is http-get("$base/query?z=1", query => { a => 2 }).text,
   '/query?z=1&a=2', ':query merges with a query already in the URL';

# --- redirects

my $red = http-get "$base/hop1";
is $red.status, 200,               'redirects are followed';
is $red.url, "$base/plain",        'the response reports the final URL';
is $red.history.elems, 2,          'and keeps the hops in .history';

is http-get("$base/hop1", :!follow).status, 302, ':!follow returns the redirect itself';

is http-post("$base/see", body => 'x').header('x-method'), 'GET',
   'a 303 rewrites POST to GET';
is http-post("$base/keep", body => 'x').header('x-method'), 'POST',
   'a 307 keeps the method';

throws-like { http-get "$base/loop" }, X::HTTP::Simple::Transport,
    'an endless redirect gives up';
