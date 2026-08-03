# App::Rakus

`rakus` — a static HTTP file server for the command line. Point it at a
directory and it serves what is inside over HTTP/1.1, on nothing but
`IO::Socket::INET`.

> **Status: v0.0.1 — implemented and tested on both engines.** 37 assertions in
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

The routing is a pure function — it returns the whole response and touches no
socket — so it can be used, and tested, without a server:

```raku
use App::Rakus;

my ($status, $type, $body, $extra) = handle('GET', '/index.html', '/var/www');

say mime-for('logo.svg');            # image/svg+xml

my $listener = listen-on(8080);      # bind, and keep the socket
accept-loop($listener, '/var/www');  # serve on it until it closes

run(:port(8080), :root('/var/www')); # or all three at once
```

## Scope

**In v0.0.1:** the above, and nothing else. No configuration file, no TLS, no
range requests, no compression, no caching headers, no keep-alive — every
response says `Connection: close`. It is a development and local-network
server, in the same spirit as `python3 -m http.server`, and it says so rather
than implying otherwise.

## Both engines

Like everything in this repository, it is released only once its tests pass
under Rakudo **and** under Raku++. All 37 assertions in `t/` pass on both.

## Licence

Artistic-2.0.

---

Design notes — why it is shaped this way, and what running it on two engines
turned up — are kept out of the distribution, in
[notes/App-Rakus.md](https://github.com/ash/raku-modules/blob/main/notes/App-Rakus.md).
