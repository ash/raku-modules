# App::Rakus — design log

Why the tool is shaped the way it is, and what running it on two engines turned
up. Kept outside `App-Rakus/` on purpose: none of it is documentation a user of
`rakus` needs, and nothing here ships in the distribution.

## Where it came from

It began as [`showcase/rakus`](https://github.com/ash/rakupp/tree/main/showcase/rakus)
in the Raku++ repository — a demonstration that raw `IO::Socket::INET` is enough
to build a real server. **That copy stays**: it is a self-contained example
someone can run straight from an engine checkout, and it is linked from the
showcase index. This one exists to be *installed*.

The two will drift. That is acceptable as long as each says the other exists,
which both READMEs now do.

## Is a command-line tool a normal thing to publish?

Yes, and there are two established shapes for it:

- **Tool-first distributions**, where the CLI *is* the product: `zef` and `fez`
  are named plainly; `App::Mi6` installs `mi6`, `App::Rak` installs `rak`,
  `App::Prove6` installs `prove6`. The `App::` namespace is the convention, and
  the one used here.
- **Module distributions that also ship a tool**: `HTTP::Tiny` ships
  `bin/rakurl`, `LWP::Simple` ships `bin/lwp-get.p6`, `Sparrow6` ships `bin/s6`.

Mechanically there is nothing to declare: a script in `bin/` is discovered and
installed by zef on its own, which writes the wrapper that puts `rakus` on
`PATH`. None of the four source distributions checked above has a `files` key in
its `META6.json`.

`App::Rakus` rather than plain `Rakus` because the namespace says "this is a
command", and it leaves the bare name free if a library ever wants it.

## A thin command over a library

The showcase is one script: routing, sockets and `MAIN` together, with the
document root in a file-scoped variable. Installed, it is split — `bin/rakus`
parses arguments and calls `run`, and everything else lives in `App::Rakus`
where the root is a parameter.

That is not tidiness for its own sake. `handle` became a pure function of
(method, target, root) returning the whole response, which means **the
behaviour that matters is testable without a socket at all**: 18 of the 37
assertions are ordinary function calls. Only one file opens a port, and what it
checks is what could not be checked any other way — that the bytes survive TCP.

The default root changed too: the showcase serves its bundled `public/`, an
installed tool serves the current directory, like `python3 -m http.server`.

## Two things about testing a server in-process

Both cost an afternoon each, and neither is obvious from the failure:

- **A thread blocked in `accept()` never returns.** Every assertion passed and
  the file then hung for ever, waiting for a connection nobody would make. The
  fix is `Thread.start(…, :app_lifetime)`, which lets the process exit with the
  thread still blocked.
- **Closing a listener that a thread is blocked on wedges the exit.** The
  obvious tidy-up — `LEAVE $listener.close` — put the main thread into a
  condition wait *inside the close*. The descriptor it was trying not to leak
  was about to be released by process exit anyway.

## What two engines have found

| bug | what it broke |
|---|---|
| a synchronous socket reported its type as `Socket`, not `IO::Socket::INET` | `sub accept-loop(IO::Socket::INET $listener)` rejected its own listener — the one signature a server naturally writes |
| `$( … )` interpolated nothing in a regex | `/ 'Content-Length: ' $($body.bytes) /` silently matched nothing; the async socket already had the type mapping the sync one lacked, one line away in the same switch |

Both are fixed in Raku++. A third, not fixed and blocking nothing here:
`IO::Handle.flush` does not exist under Raku++, so a test that flushes its own
trace file dies rather than flushing.
