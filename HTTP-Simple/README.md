# HTTP::Simple

A batteries-included HTTP client for Raku: redirects, timeouts, JSON, cookies
and retries behind one call.

> **Status: v0.0.1 — the interface below is implemented and tested on both
> engines, over plain HTTP.** See [Scope](#scope) for what the first version
> leaves out, and [TLS](#tls) for the one dependency that is loaded on demand.

```raku
use HTTP::Simple;

my $r = http-get 'https://example.com';
say $r.status;          # 200
say $r.text;            # decoded per the Content-Type charset

my %user = http-get-json 'https://api.example.com/users/1';

http-post 'https://api.example.com/users', json => %payload;
http-post 'https://api.example.com/users', form => { name => 'Ada' };
```

## Why it exists

Raku has four partial answers and no complete one. `Cro::HTTP::Client` is
capable but arrives with the whole Cro stack; `HTTP::UserAgent` is synchronous
and long unmaintained; `HTTP::Tiny` and `WWW` are deliberately minimal; the curl
bindings are native and archive-only. Nothing gives you redirects, cookies,
TLS, JSON, timeouts and retries behind a single call — which is the baseline
`requests`, `httpx`, `axios` and `faraday` all set in their own languages.

## It is not a port of Perl's HTTP::Simple

Perl's `HTTP::Simple` is a thin procedural veneer over `HTTP::Tiny` — `get`,
`getjson`, `getstore`, `postform`. Two reasons this module is shaped
differently:

- **`get`, `put` and `head` are Raku CORE subs.** Exporting those names would
  shadow the line-reading `get` and the printing `put` in every file that
  imports the module. The procedural spelling Perl uses is simply not available.
- That veneer is not the gap. Raku's own `LWP::Simple` already occupies it.

So the shape borrowed here is the one every language converged on
independently: **module-level functions for one-shot calls, a client object for
anything stateful**. Method names are safe — a class has its own namespace — so
the client gets the natural `.get`, `.put`, `.head`.

## The one-shot layer

Prefixed subs, because of the CORE collision above:

| | |
|---|---|
| `http-get($url, *%opt)` | |
| `http-post($url, *%opt)` | `:form`, `:json` or `:body` |
| `http-put`, `http-patch`, `http-delete`, `http-head`, `http-options` | |
| `http-get-json($url, *%opt)` | GET and decode, in one step |
| `http-request($method, $url, *%opt)` | anything else |

Options, identical on the subs and on the client:

| option | default | |
|---|---|---|
| `:headers(%h)` | — | merged over the client's defaults |
| `:query(%q)` | — | appended and encoded |
| `:json($data)` | — | body, sets `Content-Type: application/json` |
| `:form(%f)` | — | body, `application/x-www-form-urlencoded` |
| `:body($str-or-blob)` | — | raw body; pair with `:content-type` |
| `:timeout($seconds)` | `30` | total; `:connect-timeout` defaults to `10` |
| `:follow` | `True` | follow redirects, max 10, with RFC method rewriting |
| `:retries($n)` | `0` | opt-in, exponential backoff, idempotent methods only |
| `:auth($user, $pass)` / `:bearer($token)` | — | |
| `:fatal` | `False` | throw on a 4xx/5xx instead of returning it |

Two defaults chosen deliberately: **there is a timeout** (having none is a
famous footgun in `requests`) and **there are no retries unless asked** —
silently repeating a non-idempotent call is worse than failing once.

## The client layer

For cookies, connection reuse and shared configuration:

```raku
my $http = HTTP::Simple::Client.new(
    base-uri => 'https://api.example.com',
    headers  => { Authorization => "Bearer $token" },
    timeout  => 10,
    retries  => 2,
    cookies  => True,
);

my $r = $http.get('/users/1');
my %u = $http.get-json('/users/1');
$http.post('/users', json => %payload);
```

## The response

```raku
class HTTP::Simple::Response {
    has Int  $.status;      # 200
    has Str  $.reason;      # "OK"
    has      %.headers;     # keys lower-cased; repeated headers become a List
    has Blob $.body;        # exactly what came over the wire
    has Str  $.url;         # the final URL, after any redirects
    has      @.history;     # the responses that redirected here, in order

    method text(--> Str)    # decoded using the Content-Type charset, UTF-8 default
    method json()           # from-json(self.text)
    method ok(--> Bool)     # 2xx — and Bool overloads to this
    method raise-for-status()
}
```

## Errors

A **transport** failure — DNS, connect, TLS, timeout — throws
`X::HTTP::Simple::Transport`. An HTTP **status** does not: a 404 is an answer,
not a malfunction, so it comes back as a response with `.ok` False. Pass
`:fatal`, or call `.raise-for-status`, to invert that.

## TLS

`https` is served by `IO::Socket::Async::SSL`, which the client `require`s the
first time an `https` URL comes along. That keeps plain HTTP working on a box
where the TLS distribution will not build; when it is missing, an `https` call
throws `X::HTTP::Simple::Transport` saying exactly that rather than failing at
load time.

It is listed in `depends`, so a normal `zef install` gets it. It is **not**
installed on either engine here yet, so the `https` path is the one part of
v0.0.1 with no test behind it.

## Scope

**In v0.0.1:** the seven methods, query parameters, headers, basic and bearer
auth, string/blob/form/JSON bodies, redirects with history and RFC method
rewriting, connect and total timeouts, a cookie jar on the client, opt-in
retries with exponential backoff on transport failures for idempotent methods
only, chunked transfer decoding, and `HTTP_PROXY` / `NO_PROXY` for plain HTTP.

**Deliberately out:** HTTP/2 (Cro has it, and it is a different module),
streaming bodies and multipart uploads (v0.2 — the response type is designed to
allow it), an async API (v0.2, as `http-get-async` returning a `Promise`),
gzip/deflate (needs a compression dependency; v0.0.1 asks for `identity`),
connection reuse (every request sends `Connection: close`), `https` through a
proxy (it needs `CONNECT` tunnelling; the client says so rather than pretending),
and caching.

## Both engines

Like everything in this repository, it is released only once its tests pass
under Rakudo **and** under Raku++. All 81 assertions in `t/` pass on both.

Writing it surfaced two Raku++ bugs, which is the intended outcome rather than
an obstacle: `next without $x` read `without` as a loop label, and
`Buf.new($blob)` stored the blob's element *count* as a single byte. Both are
fixed in Raku++.

## Licence

Artistic-2.0.
