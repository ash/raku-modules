# App::Rakus

`rakus` — a static HTTP file server for the command line. Point it at a
directory and it serves what is inside over HTTP/1.1, on nothing but
`IO::Socket::INET`.

> **Status: v0.0.2 — implemented and tested on both engines.** 37 assertions in
> `t/`, no dependencies.

```sh
rakus                      # serve . on http://127.0.0.1:8080/
rakus 9000                 # choose the port
rakus 9000 ~/site          # choose the port and the directory
rakus --quiet 9000 ~/site  # without the request log
```

## What it does

- **Correct `Content-Type` by extension** — text *and* binary. Files are read
  and written as bytes, so images arrive intact and `Content-Length` is always
  the true byte count. An unknown extension is `application/octet-stream`
  rather than a guess.
- **`index.html`** when a directory has one, otherwise a generated **directory
  listing** with sizes and links. Dotfiles are left out of it.
- **`GET` and `HEAD`**; anything else gets `405`.
- **`301`** to add a missing trailing slash on a directory, so relative links
  inside it resolve; **`403`** for a `..` segment, which is refused rather than
  resolved; **`404`** for anything missing.
- **One thread per connection**, and a request log on stderr: `  200 GET  /style.css`.

## As a library

The routing — `handle` — is a pure function of (method, target, root): it
returns the whole response and touches no socket, so what the server *answers*
can be used, and tested, with no port and no network:

```raku
use App::Rakus;

my ($status, $type, $body, $extra) = handle('GET', '/index.html', '/var/www');

say mime-for('logo.svg');            # image/svg+xml
```

The rest of the module is the server around that function — these do open
sockets, in stages, so a caller can choose where to take over:

```raku
my $listener = listen-on(8080);      # bind, and keep the socket
accept-loop($listener, '/var/www');  # serve on it until it closes

run(:port(8080), :root('/var/www')); # bind, announce, serve — the whole thing
```

## Scope

**In v0.0.2:** the above, and nothing else. No configuration file, no TLS, no
range requests, no compression, no caching headers, no keep-alive — every
response says `Connection: close`. It is a development and local-network
server, in the same spirit as `python3 -m http.server`, and it says so rather
than implying otherwise.

## Compatibility

It is released only once its tests pass under Rakudo **and** under Raku++.

| engine | version | `t/` |
|---|---|---|
| Rakudo | `v2026.08` (MoarVM `2026.08`, Raku `v6.d`) | 37/37 |
| Raku++ | `v3.7.0` (the released binary, which is what CI installs) | 37/37 |

`v1.8.0` is the minimum Raku++ version.

## Licence

Artistic-2.0.

---

Design notes — why it is shaped this way, and what running it on two engines
turned up — are kept out of the distribution, in
[notes/App-Rakus.md](https://github.com/ash/raku-modules/blob/main/notes/App-Rakus.md).
