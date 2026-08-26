# GUI::Wings — windows with wings: a native GUI framework for Raku.
#
# This file is the toolkit-free front: widgets, builders, the reconcile loop
# and the threading model. Everything that touches a native toolkit lives in a
# backend — GUI::Wings::Backend::Cocoa (AppKit) or ::Gtk (GTK3) — behind ten
# methods: init, make-window/label/button, set-window-title/set-label-text,
# pump, frame-begin/end, click, press-close, visible, close, raise-sigint.
# The backend is picked from $*KERNEL.name, WINGS_BACKEND overrides.
#
# Architecture: ONE thread (the pump thread — on macOS necessarily the process
# main thread) owns the toolkit: it drains a Channel of marshalled UI closures,
# reconciles widget state (text, title) into the toolkit when it changed, and
# pumps events. The `app` body runs on a worker, so a `react` in it parks
# without freezing the GUI; builders send their toolkit work over and wait for
# the ack; clicks come back as Supply emits.
#
# Coordinates are bottom-left, Cocoa-style; backends convert where needed.
unit module GUI::Wings;

use GUI::Wings::Backend::Cocoa;
use GUI::Wings::Backend::Gtk;
use GUI::Wings::Backend::Win32;

my $DEBUG = ?%*ENV<WINGS_DEBUG>;
sub debug(Str $m) { note "wings: $m" if $DEBUG }

# ---------- widgets ----------

class Label is export {
    has Str $.text is rw;
    has $.font;
    has $.ns is rw;
    has Str $.applied is rw;
}

class Button is export {
    has Str $.title;
    has $.ns is rw;
    has Supplier $.tap = Supplier.new;
    method clicks { $!tap.Supply }
}

class Window is export {
    has Str $.title is rw;
    has @.size;
    has $.ns is rw;
    has Str $.applied-title is rw;
    has @.widgets;
    has $.y-cursor is rw;
}

# ---------- module state ----------

my $UI       = Channel.new;     # closures the pump thread must run
my @WINDOWS;
my $CURRENT-WINDOW;
my $B;                          # the active backend

# Run a closure on the pump thread, wait for its result. A Channel ack, not a
# Promise: Channel.receive parks reliably on every thread.
sub on-main(&code) {
    my $ack = Channel.new;
    $UI.send: { $ack.send(code() // True) };
    $ack.receive;
}

# ---------- builders (called from the worker; toolkit work marshalled) ----------

multi sub window(&body, *%opts) is export {
    my ($w, $h) = %opts<size> // (480, 240);
    my $win = Window.new(title => %opts<title> // 'Wings',
                         size  => ($w, $h), y-cursor => $h - 100);
    on-main {
        $win.ns = $B.make-window(title => $win.title, :w($w.Int), :h($h.Int),
                                 fixed => ?%opts<fixed>);
        $win.applied-title = $win.title;
    }
    @WINDOWS.push: $win;
    $CURRENT-WINDOW = $win;
    debug "window '$win.title()' up";
    body();
    $win;
}

multi sub window() is export { $CURRENT-WINDOW }

# With :$at the widget sits at that exact origin; otherwise it stacks
# top-down, centered, the way the counter example lays out.
sub spot(Window $win, %opts, $dw, $dh) {
    my ($w, $h) = %opts<size> // ($dw, $dh);
    my ($x, $y);
    if %opts<at> {
        ($x, $y) = %opts<at>[0], %opts<at>[1];
    }
    else {
        $x = ($win.size[0] - $w) / 2;
        $y = $win.y-cursor;
        $win.y-cursor -= $h + 24;
    }
    ($x.Int, $y.Int, $w.Int, $h.Int);
}

sub label(Str $text, *%opts) is export {
    my $win = $CURRENT-WINDOW // die 'label used outside a window block';
    my $l = Label.new(:$text, font => %opts<font> // 13, applied => $text);
    my ($x, $y, $w, $h) = spot($win, %opts, $win.size[0] - 80, $l.font * 1.6);
    on-main {
        $l.ns = $B.make-label(win => $win.ns, :$text, font => $l.font,
                              mono => ?%opts<mono>, align => (%opts<align> // 'center'),
                              :$x, :$y, :$w, :$h);
    }
    $win.widgets.push: $l;
    $l;
}

sub button(Str $title, *%opts) is export {
    my $win = $CURRENT-WINDOW // die 'button used outside a window block';
    my $b = Button.new(:$title);
    my ($x, $y, $w, $h) = spot($win, %opts, 150, 36);
    my &fire = { debug "click on '$b.title()'"; $b.tap.emit(True) };
    on-main {
        $b.ns = $B.make-button(win => $win.ns, :$title, font => %opts<font>,
                               tint => (%opts<tint> // ''), :$x, :$y, :$w, :$h,
                               clicked => &fire);
    }
    $win.widgets.push: $b;
    $b;
}

# ---------- the pump (one thread owns the toolkit) ----------

sub reconcile() {
    for @WINDOWS -> $win {
        next without $win.ns;
        if $win.title ne $win.applied-title {
            $B.set-window-title($win.ns, $win.title);
            $win.applied-title = $win.title;
            debug "title -> '$win.title()'";
        }
        for $win.widgets.grep(Label) -> $l {
            next without $l.ns;
            if $l.text ne $l.applied {
                $B.set-label-text($l.ns, $l.text);
                $l.applied = $l.text;
                debug "label -> '$l.text()'";
            }
        }
    }
}

sub app(Str $name, &body) is export {
    my $bn = %*ENV<WINGS_BACKEND>
             // ($*KERNEL.name eq 'darwin' ?? 'Cocoa'
                 !! $*DISTRO.is-win    ?? 'Win32'
                 !!                       'Gtk');
    $B = $bn eq 'Cocoa' ?? GUI::Wings::Backend::Cocoa.new
      !! $bn eq 'Gtk'   ?? GUI::Wings::Backend::Gtk.new
      !! $bn eq 'Win32' ?? GUI::Wings::Backend::Win32.new
      !! die "unknown WINGS_BACKEND '$bn' (Cocoa, Gtk or Win32)";
    debug "backend: $bn";
    $B.init();

    my $done = start body();

    # Autodrive: WINGS_AUTODRIVE=n clicks every button once a second, n times,
    # then raises SIGINT — the app ends through its own `whenever signal` path.
    my $auto = (%*ENV<WINGS_AUTODRIVE> // 0).Int;
    my @auto-at = $auto ?? (1 .. $auto).map(now + *) !! ();
    my $sigint-at = $auto ?? now + $auto + 1 !! Nil;   # a beat after the last click
    # WINGS_AUTOCLOSE=secs presses the close button after that many seconds —
    # the same code path as the window's own close control.
    my $close-after = (%*ENV<WINGS_AUTOCLOSE> // 0).Num;
    my $close-at = $close-after ?? now + $close-after !! Nil;

    while $done.status ~~ Planned {
        my $frame = $B.frame-begin();
        while $UI.poll -> $job { $job() }
        reconcile();
        $B.pump();
        if @auto-at && now > @auto-at[0] {
            @auto-at.shift;
            for @WINDOWS -> $win {
                $B.click(.ns) for $win.widgets.grep(Button).grep(*.ns.defined);
            }
        }
        if $sigint-at && now > $sigint-at {
            $sigint-at = Nil;
            $B.raise-sigint();                   # SIGINT, the app's own exit path
        }
        if $close-at && now > $close-at {
            $close-at = Nil;
            $B.press-close(.ns) for @WINDOWS.grep(*.ns.defined);
        }
        if @WINDOWS && !@WINDOWS.grep({ .ns.defined && $B.visible(.ns) }) {
            debug 'all windows closed';
            exit 0;
        }
        $B.frame-end($frame);
    }
    note $done.cause if $done.status ~~ Broken;
    reconcile();
    for @WINDOWS.grep(*.ns.defined) -> $win {
        $B.close($win.ns);
    }
    debug "app '$name' finished";
}
