# GUI::Wings

Windows with wings: a native GUI framework for Raku. Declarative builders for
windows and widgets, every event a `Supply`, `react`/`whenever` as the event
loop. The Cocoa backend reaches AppKit through `objc_msgSend` over NativeCall —
no C glue, no bindings distribution to install.

> **Status: v0.0.2 — a working proof of concept with two backends.** The same
> examples run unchanged on the Cocoa backend (macOS: Raku++ arm64 with
> `RAKUPP_MAIN_THREAD=1`, Rakudo as-is) and on the Gtk backend (GTK3 — for
> Linux, so far exercised through a Rosetta Rakudo against Homebrew GTK).
> `WINGS_BACKEND=Cocoa|Gtk` overrides the default choice by OS. Widgets so
> far: `window`, `label`, `button`. See [Scope](#scope).

```raku
use GUI::Wings;

app 'Counter', {
    my $n = 0;
    window :title('Camelia counts'), :size(480, 220), {
        my $l = label 'clicked 0 times', :font(28);
        my $b = button 'Click me';

        react {
            whenever $b.clicks        { $l.text = "clicked {++$n} times" }
            whenever Supply.interval(1) { window.title = DateTime.now.hh-mm-ss }
            whenever signal(SIGINT)   { done }
        }
    }
}
```

```sh
RAKUPP_MAIN_THREAD=1 rakupp -I lib examples/counter.raku   # Raku++
raku -I lib examples/counter.raku                          # Rakudo
```

The module splits into a toolkit-free front (`GUI::Wings`) and backends behind
ten methods (`GUI::Wings::Backend::Cocoa`, `::Gtk`); `WINGS_BACKEND` picks one
explicitly.

`examples/calculator.raku` is the second example: a calculator — seventeen keys
(digits, a decimal comma, four operators, C, a full-width =) feeding one
`react`, a big right-aligned monospaced readout, orange operator keys — whose
arithmetic is exact `Rat`s behind a rounded display, so `1 ÷ 3 × 3` is exactly
`1`, which is more than most desk calculators manage.

Close the window or Ctrl+C to quit. Two environment knobs:

- `WINGS_AUTODRIVE=n` — the app clicks every button once a second, n times,
  then raises SIGINT and ends through its own `whenever signal` path. The
  whole GUI self-verifies in about n+1 seconds, no hands needed.
- `WINGS_DEBUG=1` — narrates window creation, clicks and reconciliations on
  stderr.

## The model

- `app NAME, { ... }` starts Cocoa on the **process main thread** and pumps
  its event loop there; the block runs on a worker, so a `react` in it parks
  without freezing the GUI.
- Builders — `window :title(...), :size(w, h), { ... }`, `label`, `button` —
  are plain subs. They marshal their AppKit work to the main thread over a
  Channel and return live Raku objects. Inside a window block, `window` with
  no arguments is the current window.
- Events flow out as Supplies (`$button.clicks`); state flows in as plain
  attribute assignment (`$label.text = ...`, `window.title = ...`). Each pump
  turn *reconciles* changed state into Cocoa — widgets never mutate AppKit
  from worker threads.
- A click crosses AppKit → a runtime-minted Objective-C class
  (`objc_allocateClassPair` + `class_addMethod`) whose action method IS a Raku
  sub → `Supplier.emit` → your `whenever`.

## Requirements

- **macOS 10.12.2 or newer** (10.12 if you drop `:tint`). The floor comes from
  Apple's availability annotations — `labelWithString:` and
  `buttonWithTitle:target:action:` are 10.12, the monospaced-digit font 10.11,
  `setBezelColor:` and the `system*Color` family 10.12.2 — and everything else
  Wings touches is decades older. Tested on macOS 15.7.
- **Intel and Apple Silicon** both, same module file; the alignment enum is the
  one arch difference and is picked at runtime.
- **Backends**: `GUI::Wings::Backend::Cocoa` (AppKit) is the macOS default;
  `GUI::Wings::Backend::Gtk` (GTK3, `libgtk-3.so.0` on Linux) is the default
  elsewhere and needs no main-thread env var — GTK only requires that one
  thread makes all its calls, which the pump guarantees. The Gtk backend is
  verified against GTK 3.24 via Rosetta on this Mac; a genuine Linux run is
  still pending.
- **Raku++**: a build from current `main` — the main-thread hook and the
  declared-Str/word-list marshalling fixes are newer than the v3.6.x release
  binaries. **Rakudo**: any recent release works as-is (2026.08 tested; the
  framework-dlopen and signed-mask workarounds are already inside the module).
- Verified matrix: arm64 rakupp natively and x86-64 Rakudo under Rosetta, both
  on macOS 15.7. A native arm64 Rakudo is untested but each of its halves —
  the arm64 path (via rakupp) and Rakudo itself (via Rosetta) — is.

## Portability

macOS only — the one backend is Cocoa. Both Mac ABIs are served by the same
module: **no NSRect ever crosses the FFI.** An NSPoint/NSSize is two doubles,
which arm64 (as an HFA) and x86-64 (as two SSE words) both pass exactly like
two `num64` arguments, so window geometry goes through `setStyleMask:` +
`setContentSize:` and widget geometry through `setFrameOrigin:` +
`setFrameSize:`. `objc_msgSend` is declared once per call shape via
`is symbol`; the runtime is loaded by absolute path, AppKit by explicit
`dlopen` (Rakudo rewrites extension-less framework paths).

Under Raku++ the interpreter runs programs on a big-stack worker thread, and
AppKit refuses windows off the main thread; `RAKUPP_MAIN_THREAD=1` runs the
program inline on the main thread instead. Under Rakudo the mainline already
is the main thread. `app` checks with `pthread_main_np` and says so if the
requirement is not met.

## Scope

What v0.0.1 deliberately leaves out: any widget beyond label and button, real
layout (children stack top-down, centered), menus, dialogs, images, multiple
apps per process, and non-macOS backends. The architecture has room for GTK
and terminal backends behind the same builder API, but none exists yet.

## Compatibility

The `t/` suite is deliberately headless — the native declarations dlopen on
first call, so loading the module opens no window and the tests run on any OS.
The GUI itself is tested by the examples, which `WINGS_AUTODRIVE` drives to a
clean exit with no hands on the mouse.

| engine | version | `t/` | examples |
|---|---|---|---|
| Rakudo | `v2026.08` (MoarVM `2026.08`, Raku `v6.d`) | 8/8 | both self-drive to exit 0 |
| Raku++ | `v3.7.0` (with `RAKUPP_MAIN_THREAD=1`) | 8/8 | both self-drive to exit 0 |

These are the versions it was run on, not established floors — no older engine
has been tried.

## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.
