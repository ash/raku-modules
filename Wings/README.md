# Wings

Windows with wings: a native GUI framework for Raku. Declarative builders for
windows and widgets, every event a `Supply`, `react`/`whenever` as the event
loop. The Cocoa backend reaches AppKit through `objc_msgSend` over NativeCall —
no C glue, no bindings distribution to install.

> **Status: v0.0.1 — a working proof of concept.** The example below runs on
> both engines on macOS: Raku++ (arm64, with `RAKUPP_MAIN_THREAD=1`) and Rakudo
> (main thread by default; an x86-64 Rosetta build works). Widgets so far:
> `window`, `label`, `button`. See [Scope](#scope).

```raku
use Wings;

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
