# HTTP::Simple

A batteries-included HTTP client for Raku: redirects, timeouts, JSON, cookies
and retries behind one call.

> **Status: v0.0.1 — the interface below is implemented and tested on both
> engines, over HTTP and HTTPS.** See [Scope](#scope) for what the first version
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

Module-level functions for one-shot calls, a client object for anything
stateful. It is not a port of Perl's `HTTP::Simple`, which is a procedural
veneer over `HTTP::Tiny`.

## The one-shot layer

The subs are prefixed because `get`, `put` and `head` are Raku CORE subs and
exporting those names would shadow them. The client's *methods* keep the natural
spelling — a class has its own namespace.

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

Note the two defaults: **there is a timeout**, and **there are no retries unless
asked for**.

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
verification off. A rejected certificate throws
`X::HTTP::Simple::Transport` carrying the reason OpenSSL gave.

`t/05-tls.t` covers this against a TLS server the suite starts in-process, using
the throwaway CA in [`t/tls/`](t/tls): no network, no public certificate
authority.

## Scope

**In v0.0.1:** the seven methods, query parameters, headers, basic and bearer
auth, string/blob/form/JSON bodies, redirects with history and RFC method
rewriting, connect and total timeouts, TLS with certificate verification, a
cookie jar on the client, opt-in retries with exponential backoff on transport
failures for idempotent methods only, chunked transfer decoding, and
`HTTP_PROXY` / `NO_PROXY` for plain HTTP.

A response is framed by `Content-Length` or by its terminal chunk; the
connection closing is the delimiter only when the response carries no framing of
its own.

**Deliberately out:** HTTP/2 (Cro has it, and it is a different module),
streaming bodies and multipart uploads (v0.2 — the response type is designed to
allow it), an async API (v0.2, as `http-get-async` returning a `Promise`),
gzip/deflate (needs a compression dependency; v0.0.1 asks for `identity`),
connection reuse (every request sends `Connection: close`), `https` through a
proxy (it needs `CONNECT` tunnelling; the client says so rather than pretending),
and caching.

## Compatibility

Like everything in this repository, it is released only once its tests pass
under Rakudo **and** under Raku++.

| engine | version | `t/` |
|---|---|---|
| Rakudo | `v2026.07` (MoarVM `2026.07`, Raku `v6.d`) | 107/107 |
| Raku++ | `v1.8.0` | 107/107 |

**`v1.8.0` is the minimum Raku++**, not merely the one it was tried on: the
engine fixes this distribution needs landed after `v1.7.0`, and against that
binary the suite fails rather than degrading. It was tested on the build that
became `v1.8.0` (`v1.7.0-63-gd3bdea5`). Rakudo has no such floor — nothing here
depends on a recent Rakudo.

## Licence

Artistic-2.0.

---

Design notes — why it is shaped this way, and what running it on two engines has
turned up — are kept out of the distribution, in
[notes/HTTP-Simple.md](https://github.com/ash/raku-modules/blob/main/notes/HTTP-Simple.md).
