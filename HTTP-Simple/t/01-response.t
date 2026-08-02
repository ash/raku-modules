use Test;
use HTTP::Simple::Response;
use HTTP::Simple::X;

plan 22;

sub r(|c) { HTTP::Simple::Response.new(|c) }

# --- status classification

ok  r(status => 200).ok,            '200 is ok';
ok  r(status => 204).ok,            '204 is ok';
nok r(status => 302).ok,            '302 is not ok';
ok  r(status => 302).is-redirect,   '302 is a redirect';
ok  r(status => 404).is-error,      '404 is an error';
ok  ?r(status => 201),              'Bool overloads to .ok';
nok ?r(status => 500),              'a 500 is False in boolean context';

# --- headers

my $h = r(
    status  => 200,
    headers => { 'content-type' => 'text/plain; charset=utf-8',
                 'set-cookie'   => ('a=1', 'b=2') },
);
is $h.header('Content-Type'), 'text/plain; charset=utf-8', 'header lookup is case-insensitive';
is $h.header('X-Missing'),    '',                          'a missing header is the empty string';
is $h.content-type,           'text/plain',                'content-type drops the parameters';
is $h.charset,                'utf-8',                     'charset comes from the parameters';
is $h.header('set-cookie'),   'b=2',                       'a repeated header yields the last value';
is-deeply $h.headers-all('set-cookie').List, ('a=1', 'b=2'), 'headers-all yields every value';
is-deeply $h.headers-all('nope').List,       (),            'headers-all on a missing header is empty';
is r(status => 200).charset,  'utf-8',                     'no Content-Type means UTF-8';

# --- body decoding

my $utf8 = r(status => 200, body => 'héllo'.encode('utf8'),
             headers => { 'content-type' => 'text/plain; charset=utf-8' });
is $utf8.text, 'héllo', 'a UTF-8 body decodes';
is ~$utf8,     'héllo', 'Str is the decoded text';
is r(status => 204).text, '', 'an empty body is the empty string';

is r(status => 200, body => '{"a":[1,2]}'.encode('utf8')).json<a>.List, (1, 2),
   'json parses the decoded text';

# --- raise-for-status

my $ok = r(status => 200);
ok $ok.raise-for-status === $ok, 'raise-for-status returns the response on success';

my $bad = r(status => 404, reason => 'Not Found', url => 'http://x/y');
throws-like { $bad.raise-for-status }, X::HTTP::Simple::Status,
    'raise-for-status throws on a 404';

my $ex;
try { $bad.raise-for-status; CATCH { default { $ex = $_ } } }
is $ex.response.status, 404, 'the exception carries the response';
