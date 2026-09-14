# HTTP::Simple

A batteries-included HTTP client for Raku — redirects, timeouts, JSON,
cookies, retries and streaming bodies behind one call — and the client object
under that, for anything which has to keep state between calls.

## Version

0.1.0

## Synopsis

```raku
use HTTP::Simple;

my $r = http-get 'https://example.com';
say $r.status;          # 200
say $r.text;            # decoded per the Content-Type charset

my %user = http-get-json 'https://api.example.com/users/1';

http-post 'https://api.example.com/users', json => %payload;
http-post 'https://api.example.com/users', form => { name => 'Ada' };
```

## Install

Either installer takes it, into the same `~/.raku` store:

```bash
rakupp install HTTP::Simple
zef install HTTP::Simple
```

## Description

Module-level functions for one-shot calls, a client object for anything
stateful — the shape `requests`, `httpx`, `axios` and `faraday` each arrived
at on their own. It is not a port of Perl's `HTTP::Simple`, which is a
procedural veneer over `HTTP::Tiny`.

The distribution is seven modules behind one `use` line:

| module | what it is |
|---|---|
| `HTTP::Simple` | the one-shot subs — `http-get` and the rest |
| `HTTP::Simple::Client` | a base URI, default headers and a cookie jar |
| `HTTP::Simple::Response` | a whole answer: status, headers, body, history |
| `HTTP::Simple::Stream` | that same head, with the body still on the wire |
| `HTTP::Simple::SSE` | one `text/event-stream` event |
| `HTTP::Simple::Message` | what a response and a stream have in common |
| `HTTP::Simple::X` | the two exceptions |

**Everything below is implemented and covered by `t/`**, over HTTP and over
HTTPS. What this version deliberately leaves out is under Scope, and the one
place the two Raku engines part company is under Compatibility — nothing
between here and there mentions them.

## The one-shot layer

The subs are prefixed because `get`, `put` and `head` are Raku CORE subs and
exporting those names would shadow them. The client's *methods* keep the
natural spelling — a class has its own namespace.

| | |
|---|---|
| `http-get($url, *%opt)` | |
| `http-post($url, *%opt)` | `:form`, `:json` or `:body` |
| `http-put`, `http-patch`, `http-delete`, `http-head`, `http-options` | |
| `http-get-json($url, *%opt)` | GET and decode; a non-2xx throws |
| `http-stream($method, $url, *%opt)` | the head now, the body as it arrives |
| `http-request($method, $url, *%opt)` | anything else |

Each of them builds a client for the one call and throws it away, with the jar
off, so nothing carries from one one-shot call into the next.

Options, the same on the subs and on the client's methods but for the one the
table marks:

| option | default | |
|---|---|---|
| `:headers(%h)` | — | merged over the client's defaults |
| `:query(%q)` | — | appended and encoded |
| `:json($data)` | — | body, sets `Content-Type: application/json` |
| `:form(%f)` | — | body, `application/x-www-form-urlencoded` |
| `:body($str-or-blob)` | — | raw body; pair with `:content-type` |
| `:timeout($seconds)` | `30` | total, for the whole request |
| `:connect-timeout($seconds)` | `10` | on the subs and on `.new`, not per request |
| `:idle-timeout($seconds)` | `:timeout` | streaming only: the longest gap between body chunks |
| `:follow` | `True` | follow redirects, max 10, with RFC method rewriting |
| `:retries($n)` | `0` | opt-in, exponential backoff, idempotent methods only |
| `:auth($user, $pass)` / `:bearer($token)` | — | |
| `:fatal` | `False` | throw on a 4xx/5xx instead of returning it |
| `:ca-file($path)` / `:ca-path($dir)` | — | trust these anchors instead of the system store |
| `:insecure` | `False` | accept any certificate — for testing, and it says so |

Note the two defaults: **there is a timeout**, and **there are no retries
unless asked for**.

## The client layer

For a cookie jar, a base URI, and configuration every call then inherits:

```raku
my $http = HTTP::Simple::Client.new(
    base-uri => 'https://api.example.com',
    headers  => { Authorization => "Bearer $token" },
    timeout  => 10,
    retries  => 2,
);

my $r = $http.get('/users/1');
my %u = $http.get-json('/users/1');
$http.post('/users', json => %payload);
```

It takes every option from the table above as the default for each call, and
these besides, which belong to a client rather than to a request:

| setting | default | |
|---|---|---|
| `base-uri` | — | a relative target is resolved against it |
| `cookies` | `True` | one jar per client; `.cookies-for($host)` reads it |
| `max-redirects` | `10` | |
| `proxy` | `True` | honour `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` |
| `user-agent` | `HTTP::Simple/0.1.0 Raku` | |

What a client is *not* is a connection pool: every request still sends
`Connection: close`, and reuse is under Scope.

## The response

```raku
class HTTP::Simple::Response {
    has Int  $.status;      # 200
    has Str  $.reason;      # "OK"
    has      %.headers;     # keys lower-cased; a repeated header is a List
    has Blob $.body;        # exactly what came over the wire
    has Str  $.url;         # the final URL, after any redirects
    has      @.history;     # the responses that redirected here, in order

    method text(--> Str)                    # per the charset; UTF-8 default
    method json()                           # from-json(self.text)
    method ok(--> Bool)                     # 2xx — and Bool overloads to this
    method is-redirect(--> Bool)
    method is-error(--> Bool)
    method header(Str $name --> Str)        # case-insensitive; '' when absent
    method headers-all(Str $name --> List)  # every value of a repeated header
    method content-type(--> Str)            # without the parameters
    method charset(--> Str)
    method raise-for-status()
}
```

Everything from `.ok` down is the `HTTP::Simple::Message` role, so a stream
answers all of it from its head while the body is still arriving.

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

An `HTTP::Simple::SSE` event has `.event`, `.data`, `.id`, `.retry` and
`.json`. Repeated `data:` fields join with newlines and comment lines are
dropped, per the `text/event-stream` grammar.

The body is meant for **one** consumer: chunks arriving between the head
coming back and your `tap` are held, but a second tap divides the bytes with
the first rather than repeating them. Reading only part of it and calling
`.close` ends the supply normally — an early close is a decision, not a
truncation. A body that stops short of its `Content-Length`, or a chunked one
with no terminal chunk, quits the supply with `X::HTTP::Simple::Transport`,
because a truncated body should not be mistaken for a short one.

Two clocks, because a stream has two failure modes: `:timeout` bounds the wait
for the head, and `:idle-timeout` the gap between body chunks. A total timeout
on the body would be wrong — staying open for minutes is what a stream is for.

Redirects are followed. Retries are not offered here: a response being
consumed as it arrives cannot be replayed once the caller has seen part of it.

## Errors

A **transport** failure — DNS, connect, TLS, timeout — throws
`X::HTTP::Simple::Transport`. An HTTP **status** does not: a 404 is an answer,
not a malfunction, so it comes back as a response with `.ok` False. Pass
`:fatal`, or call `.raise-for-status`, to invert that.

## TLS

`https` is served by `IO::Socket::Async::SSL`. An installer brings it along —
it is a declared dependency — but the client `require`s it only when an
`https` URL first turns up, and that is what makes a TLS distribution which is
present and **will not load** cost you `https` rather than the module: plain
HTTP goes on working, and the `https` call throws
`X::HTTP::Simple::Transport` carrying the loader's own reason rather than
failing at load time. A store shared by two toolchains of different
architectures is the usual way to arrive at that state.

**Certificates are verified**, against the system trust store by default.
`:ca-file` / `:ca-path` name your own trust anchors; `:insecure` turns
verification off. A rejected certificate throws `X::HTTP::Simple::Transport`
carrying the reason OpenSSL gave.

`t/05-tls.t` covers this against a TLS server the suite starts in-process,
using the throwaway CA in [`t/tls/`](t/tls): no network, no public certificate
authority. Where the TLS distribution cannot be loaded the file skips itself,
which is the same judgement the client makes at run time.

## Scope

**In v0.1.0:** the seven methods, query parameters, headers, basic and bearer
auth, string/blob/form/JSON bodies, redirects with history and RFC method
rewriting, connect, total and idle timeouts, TLS with certificate
verification, a cookie jar on the client, opt-in retries with exponential
backoff on transport failures for idempotent methods only, chunked transfer
decoding, streaming bodies with `text/event-stream` parsing, and `HTTP_PROXY`
/ `NO_PROXY` for plain HTTP.

A response is framed by `Content-Length` or by its terminal chunk; the
connection closing is the delimiter only when the response carries no framing
of its own. That is decided in one place and used by both the buffered and the
streaming path.

Not attempted in this version:

| | why not |
|---|---|
| HTTP/2 | Cro has it, and it is a different module |
| multipart uploads | |
| streaming request *bodies* | only responses stream today |
| an async buffered call — `http-get-async` returning a `Promise` | |
| gzip/deflate | it needs a compression dependency; this version asks for `identity` |
| connection reuse | every request sends `Connection: close` |
| `https` through a proxy | it needs `CONNECT` tunnelling |
| caching | |

Two of those are worth saying more about. **`https` through a proxy** is the
one a reader can walk into: `HTTPS_PROXY` is read, and a request that would
have to be tunnelled is refused with `X::HTTP::Simple::Transport` saying so,
rather than quietly going direct. And **gzip** is parked rather than rejected:
what it wants is a decompressor that every engine can load, and the obvious
candidate now sits in this repository as `Compress::Zlib::Native`.

## Compatibility

Like everything in this repository, it is released only once its tests pass
under Rakudo **and** under Raku++.

| engine | version | `t/` |
|---|---|---|
| Rakudo | `v2026.07` | 134/134 |
| Raku++ | `3.28.0` | 120/134, `t/05-tls.t` skipped |

**`v1.8.0` is the minimum Raku++** for everything up to v0.0.1, not merely the
one it was tried on: the engine fixes this distribution needs landed after
`v1.7.0`, and against that binary the suite fails rather than degrading.
`.stream` has only ever been run from `3.14.0` up, so treat that as its floor
until something older is tried. Rakudo has no such floor — nothing here
depends on a recent Rakudo.

Both engines run the plain-HTTP files, the proxy file and the streaming file
identically, and they agree on every count above but one. The exception is
TLS, and it is the engine's story rather than this distribution's:

**TLS — `t/05-tls.t` does not run under Raku++.** A TLS server and a TLS
client in one process deadlock there: one thread parks in `await`, and the
worker which would settle the promise it waits on blocks acquiring a lock the
parked side still holds. It hangs rather than fails, which is why the gate is
in the test file and not in CI — a Raku++ user running `zef install` with the
TLS distribution present would hang the install the same way.

The client is not what is implicated, and neither is `https`. That same file
passes 14/14 under Raku++'s cooperative-GIL mode (`RAKUPP_GIL=1`), an ordinary
outbound `https` request returns normally under the default parallel mode, and
the whole file is green on Rakudo. What the gate costs is the coverage, not
the feature. The thread stacks are in the design notes; the minimal
reproduction recorded beside them no longer deadlocks on `3.28.0`, so the file
itself is what reproduces this today.

One difference that used to belong here has gone: `await Promise.in($n)`
returned immediately under Raku++ `3.14.0`, which is why the staggered routes
in `t/07-stream.t` pace themselves with `sleep`. It waits properly as of
`3.28.0`, and that workaround is now belt and braces.

## Links

- [`HTTP::Simple` on raku.land](https://raku.land/zef:ash/HTTP::Simple) — the
  distribution page.
- [`HTTP-Simple` on GitHub](https://github.com/ash/raku-modules/tree/main/HTTP-Simple)
  — the source, in the repository this README ships from.

## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.

---

Design notes — why it is shaped this way, and what running it on two engines
has turned up — are kept out of the distribution, in
[notes/HTTP-Simple.md](https://github.com/ash/raku-modules/blob/main/notes/HTTP-Simple.md).
