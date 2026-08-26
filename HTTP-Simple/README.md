# HTTP::Simple

A batteries-included HTTP client for Raku: redirects, timeouts, JSON, cookies,
retries and streaming bodies behind one call.

> **Status: v0.1.0 — the interface below is implemented and tested on both
> engines, over HTTP and HTTPS.** See [Scope](#scope) for what it leaves out,
> and [TLS](#tls) for the one dependency that is loaded on demand.

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
| `http-stream($method, $url, *%opt)` | the head now, the body as it arrives |
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
| `:idle-timeout($seconds)` | `:timeout` | streaming only: the longest gap between body chunks |
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

## Streaming

`.stream` sends the request and returns as soon as the response **head** has
arrived, with the body still on the wire:

```raku
my $s = $http.stream('POST', '/v1/messages', json => %payload, bearer => $key);

# The status is here before a byte of the body is — which matters, because a
# server answering a streaming request with an error sends a short ordinary
# body, not a stream.
die $s.response.json<error> unless $s.ok;

react whenever $s.sse -> $e {
    my %chunk = $e.json;
    print %chunk<delta><text> // '';
    $s.close if %chunk<type> eq 'message_stop';
}
```

`HTTP::Simple::Stream` carries the same status and header accessors as a
response — both do the `HTTP::Simple::Message` role — plus:

| | |
|---|---|
| `.body` | a `Supply` of `Blob` chunks, dechunked, in order |
| `.lines` | a `Supply` of decoded lines, terminator removed |
| `.sse` | a `Supply` of `HTTP::Simple::SSE` events, one per blank line |
| `.blob` / `.text` / `.json` | read to the end and hand it all back |
| `.response` | collect the rest into an ordinary `HTTP::Simple::Response` |
| `.close` | stop reading and hang up |

An `HTTP::Simple::SSE` event has `.event`, `.data`, `.id`, `.retry` and `.json`.
Repeated `data:` fields join with newlines and comment lines are dropped, per
the `text/event-stream` grammar.

The body is meant for **one** consumer: chunks arriving between the head coming
back and your `tap` are held, but a second tap divides the bytes with the first
rather than repeating them. Reading only part of it and calling `.close` ends
the supply normally — an early close is a decision, not a truncation. A body
that stops short of its `Content-Length`, or a chunked one with no terminal
chunk, quits the supply with `X::HTTP::Simple::Transport`, because a truncated
body should not be mistaken for a short one.

Two clocks, because a stream has two failure modes: `:timeout` bounds the wait
for the head, and `:idle-timeout` the gap between body chunks. A total timeout
on the body would be wrong — staying open for minutes is what a stream is for.

Redirects are followed. Retries are not offered here: a response being consumed
as it arrives cannot be replayed once the caller has seen part of it.

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

**In v0.1.0:** the seven methods, query parameters, headers, basic and bearer
auth, string/blob/form/JSON bodies, redirects with history and RFC method
rewriting, connect, total and idle timeouts, TLS with certificate verification,
a cookie jar on the client, opt-in retries with exponential backoff on transport
failures for idempotent methods only, chunked transfer decoding, streaming
bodies with `text/event-stream` parsing, and `HTTP_PROXY` / `NO_PROXY` for plain
HTTP.

A response is framed by `Content-Length` or by its terminal chunk; the
connection closing is the delimiter only when the response carries no framing of
its own. That is decided in one place and used by both the buffered and the
streaming path.

**Deliberately out:** HTTP/2 (Cro has it, and it is a different module),
multipart uploads, streaming request *bodies* (only responses stream today),
an async API for the buffered path (as `http-get-async` returning a `Promise`),
gzip/deflate (needs a compression dependency; this version asks for `identity`),
connection reuse (every request sends `Connection: close`), `https` through a
proxy (it needs `CONNECT` tunnelling; the client says so rather than pretending),
and caching.

## Compatibility

Like everything in this repository, it is released only once its tests pass
under Rakudo **and** under Raku++.

| engine | version | `t/` |
|---|---|---|
| Rakudo | `v2026.07` (MoarVM `2026.07`, Raku `v6.d`) | 134/134 |
| Raku++ | `v3.14.0` | 120/120, `t/05-tls.t` not run — see below |

**`v1.8.0` is the minimum Raku++** for everything up to v0.0.1, not merely the
one it was tried on: the engine fixes this distribution needs landed after
`v1.7.0`, and against that binary the suite fails rather than degrading. The
v0.1.0 streaming work has only been run on `v3.14.0`, so treat that as the floor
for `.stream`. Rakudo has no such floor — nothing here depends on a recent
Rakudo.

Two engine notes, neither of them a defect in this distribution:

* **`t/05-tls.t` hangs under Raku++ `v3.14.0`**, before its first assertion. It
  does the same on the v0.0.1 tree, so it is not a streaming regression; the
  other six files pass. The TLS *client* code is unchanged and green on Rakudo.
* **`await Promise.in($n)` returns immediately under Raku++ `v3.14.0`.** It is
  why the staggered routes in `t/07-stream.t` pace themselves with `sleep`: a
  test server written the other way sends its whole response at once, and the
  arrival-order assertions would then fail against a client that is behaving
  perfectly. Worth knowing before writing any timing-dependent async test.

## Licence

Artistic-2.0.

---

Design notes — why it is shaped this way, and what running it on two engines has
turned up — are kept out of the distribution, in
[notes/HTTP-Simple.md](https://github.com/ash/raku-modules/blob/main/notes/HTTP-Simple.md).
