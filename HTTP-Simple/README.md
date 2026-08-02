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
| `:ca-file($path)` / `:ca-path($dir)` | — | trust these anchors instead of the system store |
| `:insecure` | `False` | accept any certificate — for testing, and it says so |

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

**Certificates are verified**, against the system trust store by default.
`:ca-file` / `:ca-path` name your own trust anchors; `:insecure` turns
verification off, which is spelled that way on purpose. A rejected certificate
throws `X::HTTP::Simple::Transport` carrying the reason OpenSSL gave — it used
to be reported as a connection timeout, which sent you looking in the wrong
place entirely.

`t/05-tls.t` runs all of this against a TLS server the suite starts in-process,
using the throwaway CA in [`t/tls/`](t/tls) — so the `https` path is tested on
both engines, with no network and no public certificate authority involved.

## Scope

**In v0.0.1:** the seven methods, query parameters, headers, basic and bearer
auth, string/blob/form/JSON bodies, redirects with history and RFC method
rewriting, connect and total timeouts, TLS with certificate verification, a
cookie jar on the client, opt-in retries with exponential backoff on transport
failures for idempotent methods only, chunked transfer decoding, and
`HTTP_PROXY` / `NO_PROXY` for plain HTTP.

A response is framed by `Content-Length` or by its terminal chunk — the
connection closing is only the delimiter when the response carries no framing of
its own. Reading to the close in every case costs a round trip, and makes every
request depend on the peer hanging up promptly, which is not a client's to
assume.

**Deliberately out:** HTTP/2 (Cro has it, and it is a different module),
streaming bodies and multipart uploads (v0.2 — the response type is designed to
allow it), an async API (v0.2, as `http-get-async` returning a `Promise`),
gzip/deflate (needs a compression dependency; v0.0.1 asks for `identity`),
connection reuse (every request sends `Connection: close`), `https` through a
proxy (it needs `CONNECT` tunnelling; the client says so rather than pretending),
and caching.

## Both engines

Like everything in this repository, it is released only once its tests pass
under Rakudo **and** under Raku++. All 95 assertions in `t/` pass on both.

Writing it has surfaced four Raku++ bugs so far, which is the intended outcome
rather than an obstacle. All four are fixed in Raku++:

- `next without $x` read `without` as a loop label.
- `Buf.new($blob)` stored the blob's element *count* as a single byte.
- A `constant` used as a return type (`sub f() returns DH`) was reported
  undeclared the moment the routine returned. This one blocked TLS outright:
  `IO::Socket::Async::SSL` builds its DH parameters in exactly such a routine.
- `orwith` after an `if`/`elsif` ran even when an earlier branch had already been
  taken, so the chain was not a chain. That made a TLS client re-run its
  handshake branch after every read.

One deviation is still open, and the tests do not depend on it: under Raku++'s
GIL a `Lock` is a no-op, so a `start` block taking a lock can run *inside* the
holder's critical section where Rakudo makes it wait. `IO::Socket::Async::SSL`
relies on that ordering to retire finished writes, and without it a TLS server
never closes a connection. A client is not entitled to assume the peer closes
anyway — hence the framing above, which is why this does not show up in `t/`.

## Licence

Artistic-2.0.
