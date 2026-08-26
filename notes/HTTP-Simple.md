# HTTP::Simple — design log

Why the module is shaped the way it is, and what running it on two engines has
turned up. Kept outside `HTTP-Simple/` on purpose: none of it is documentation a
user of the module needs, and nothing here ships in the distribution.

The module's own [README](../HTTP-Simple/README.md) says what it does. This file
says why.

## Why it exists at all

Raku had four partial answers and no complete one. `Cro::HTTP::Client` is
capable but arrives with the whole Cro stack; `HTTP::UserAgent` is synchronous
and long unmaintained; `HTTP::Tiny` and `WWW` are deliberately minimal; the curl
bindings are native and archive-only. None gives you redirects, cookies, TLS,
JSON, timeouts and retries behind a single call — which is the baseline
`requests`, `httpx`, `axios` and `faraday` all set in their own languages.

## It is not a port of Perl's HTTP::Simple

Perl's `HTTP::Simple` is a thin procedural veneer over `HTTP::Tiny` — `get`,
`getjson`, `getstore`, `postform`. Two reasons this module is shaped
differently:

- **`get`, `put` and `head` are Raku CORE subs.** Exporting those names would
  shadow the line-reading `get` and the printing `put` in every file that
  imports the module. The procedural spelling Perl uses is simply not available.
- That veneer is not the gap. Raku's own `LWP::Simple` already occupies it.

So the shape borrowed instead is the one every language converged on
independently: module-level functions for one-shot calls, a client object for
anything stateful. Method names are safe — a class has its own namespace — so
the client keeps the natural `.get`, `.put`, `.head`.

## Two defaults argued for explicitly

- **There is a timeout** (30 s total, 10 s to connect). Having none is a famous
  footgun in `requests`.
- **There are no retries unless asked.** Silently repeating a non-idempotent
  call is worse than failing once.

## Why the response frames itself

The client originally read every response until the peer closed the connection,
which `Connection: close` makes correct but expensive: it costs a round trip on
every request, and it makes each one depend on the server hanging up promptly.
A client is not entitled to assume that.

It now frames the response the way HTTP/1.1 says to — `Content-Length`, or the
terminal chunk, or no body at all for HEAD/204/304/1xx — and falls back to the
close only when the response carries no framing of its own. What it works out
about the framing is remembered, so each further packet costs a length
comparison rather than a rescan of everything received so far.

This started as a correctness fix and turned out to matter for a second reason:
it is what makes the suite independent of the open `Lock` deviation below.

## Why the TLS trust options exist

Verification is on by default, so testing `https` against a local server with a
private CA is impossible without a way to name your own trust anchors. Hence
`:ca-file`, `:ca-path` and `:insecure` — an interface addition the tests
required, not a workaround they took.

A rejected certificate used to surface as `could not connect within 10 s`,
because the connect promise was only ever checked for `Kept`. Looking for a
timeout that is really a certificate is a bad afternoon; it now carries the
reason OpenSSL gave.

The test certificates in `HTTP-Simple/t/tls/` are a private CA, a leaf for
`127.0.0.1`, and a leaf for a host the machine is not — the last is how the
hostname check is tested. They expire in 2046, so the suite needs no `openssl`
at run time, and the keys guard nothing.

## How the proxy is tested without a proxy

Nothing is forwarded. What separates a proxied request from a direct one is
entirely in the bytes the client sends — the connection goes to the proxy's
address, and the request line carries an absolute URL instead of a path — so the
ordinary test server plays the proxy and the assertions are about what it
received.

The target host in those tests is `example.invalid`. A reserved TLD cannot
resolve, so a request that arrives at the server at all can only have gone
through the proxy; and where the point is that a request must NOT be proxied, the
stand-in proxy is a dead address, so an exemption that failed to fire could not
succeed by accident.

Writing them turned up a module bug the suite had never covered: a name that does
not resolve escaped as a bare `X::AdHoc`, because `.connect` throws on a
resolution failure rather than breaking the promise it would have returned — and
the check for a failed connection only inspected the promise. The README had been
promising DNS failures as `X::HTTP::Simple::Transport` since the first commit.

## What two engines have found

Bugs this module surfaced in Raku++, which is the intended outcome rather than
an obstacle. All are fixed there.

| bug | what it broke |
|---|---|
| `next without $x` read `without` as a loop label | the retry loop |
| `Buf.new($blob)` stored the blob's element *count* as a single byte | every request body |
| a `constant` as a return type was reported undeclared the moment the routine returned | TLS outright — `IO::Socket::Async::SSL` builds its DH parameters in `sub get_dh2048() returns DH` |
| `orwith` after `if`/`elsif` ran even when an earlier branch had been taken | a TLS client re-ran its handshake branch after every read |
| `===` called two distinct `Promise`s identical | a TLS socket could not retire a finished write |

One trap was ours, and both engines agree on it: `"\r\n"` is a single grapheme
in a Raku string, so splitting an HTTP response has to be done in bytes.

### Open: a Lock is a no-op under the GIL

A `start` block taking a lock runs *inside* the holder's critical section, where
Rakudo makes it wait — the GIL serialises execution but is released at every
blocking point, so a protected block that does I/O is interleaved.
`IO::Socket::Async::SSL` relies on that ordering to retire finished writes, and
without it a TLS **server** under Raku++ never closes a connection.

Giving `Lock` a real recursive mutex fixes the ordering and then deadlocks: the
module holds one process-wide lock across socket I/O, and the GIL and the mutex
end up taken in opposite orders. Fixing it properly means making an `await`
inside a lock release the GIL the way Rakudo's thread-pool await does.

Nothing in `t/` depends on it, because of the framing change above.

### Open: `await` inside a socket tap deadlocks (found 2026-08-25)

`t/05-tls.t` under Raku++ does not fail — it hangs before its first line of
output, and it took the CI bill to notice: with no job timeout, every push
from 2026-08-13 on burned GitHub's six-hour ceiling in the "Test under
Raku++" step (runs 31737793146, 32771085733, 32772086542). It never hung
locally, because `IO::Socket::Async::SSL` was never installed here and the
file's own guard skipped it; CI installs it — META lists it as a hard
dependency — so CI was the only place the TLS code ever ran under Raku++.

The thread stacks (macOS `sample` of the hung process; the same signature
every run) close the cycle:

| thread | stuck in |
|---|---|
| connection tap, running the handler | `awaitPromise` → `condition_variable::wait`, **holding the interpreter's `recursive_mutex`** (taken in `methodCallPart2`) |
| `spawnPromise` runner that would keep that promise | `recursive_mutex::lock()`, same offset |
| main test flow | `recursive_mutex::lock()` |
| listener and second reader | blocking `__accept` / `__recvfrom` |

An `await` on a tap thread parks it with the interpreter lock still held —
the mutex is recursive and was acquired at depth, so whatever single release
the await path performs is not enough — and the thread that would keep the
promise needs that same lock to run any Raku at all. This is the shape the
Lock section above ends on: an `await` has to release the GIL — every
acquisition of it, not one — before parking a thread. Rakudo has no such
lock; the file passes there, 14/14 in ~5 s.

What does *not* reproduce it, which is why it went unseen: `await start { }`
inside a `Supply.interval` tap is fine under Raku++, so is one inside a tap
inside a tap, and so are the plain-HTTP files, whose TestServer `await`s a
socket write inside a connection tap on every request. The smallest known
reproduction is the real TLS shape — run from `HTTP-Simple/` with
`IO::Socket::Async::SSL` installed; Rakudo prints two lines and exits,
Raku++ (released `v3.7.0` and the 2026-08-25 dev build alike) prints
nothing, forever, at 0% CPU:

```raku
use IO::Socket::Async::SSL;

my $tls  = 't/tls'.IO;
my $port = 31557;

my $tap = IO::Socket::Async::SSL.listen('127.0.0.1', $port,
    certificate-file => $tls.add('server.crt').Str,
    private-key-file => $tls.add('server.key').Str,
).tap(-> $conn {
    $conn.Supply(:bin).tap(-> $chunk {
        await $conn.write("hello over TLS\n".encode);
        $conn.close;
    });
});

my $c = await IO::Socket::Async::SSL.connect('127.0.0.1', $port,
    ca-file => $tls.add('ca.crt').Str);
await $c.print("ping");
say "got: ", (await $c.Supply.head).trim;
say "completed without deadlock";
```

Until the engine fix lands, `t/05-tls.t` gates itself under Raku++ — in the
test file rather than in CI, because a Raku++ user running `zef install`
with the TLS module present would hang their install the same way. Drop the
gate when the fix lands.

## CI: red on purpose, then red by accident

When this file first said "CI is red on purpose", the released Raku++ was
`v1.7.0`, the engine fixes in the table were local only, and red meant
"waiting for the next engine release" — with the footnote that released and
local builds both reported `1.7.0`. That release came: under `v3.7.0`
(released 2026-08-24) the plain-HTTP files `t/01`–`t/04` pass in CI, and
`t/06` passes locally (CI never reached it — the job always died at
`t/05`). What kept the workflow red was no longer principle but the TLS
deadlock above: a hang, not a failure, at six runner-hours per push. With
`t/05-tls.t` gated under Raku++ and `timeout-minutes` on the jobs, the
workflow is green again, and a future hang costs fifteen minutes instead of
an afternoon.
