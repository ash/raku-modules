# Wings — windows with wings: a native GUI framework for Raku.
# Cocoa backend over NativeCall + objc_msgSend; no C glue, no bindings dist.
#
# Architecture: the process MAIN thread owns AppKit and pumps the event loop;
# the `app` body runs on a worker so `react` can park there. Builders marshal
# AppKit work to the main thread over a Channel and wait for the ack; clicks
# come back as Supply emits; each pump turn reconciles widget state (text,
# title) into Cocoa — change-driven only, inside its own autorelease pool.
#
# Works on arm64 and x86-64 macOS (including a Rosetta Rakudo): no NSRect
# ever crosses the FFI. The only by-value structs used are NSPoint/NSSize —
# two doubles, which both ABIs pass exactly like two num64 arguments. Window
# geometry goes through setStyleMask:/setContentSize:, widget geometry through
# setFrameOrigin:/setFrameSize:.
unit module Wings;

use NativeCall;

my constant OBJC = '/usr/lib/libobjc.A.dylib';
my constant APPKIT = '/System/Library/Frameworks/AppKit.framework/AppKit';

sub objc_getClass(Str --> Pointer)                           is native(OBJC) { * }
sub sel_registerName(Str --> Pointer)                        is native(OBJC) { * }
sub objc_allocateClassPair(Pointer, Str, uint64 --> Pointer) is native(OBJC) { * }
sub objc_registerClassPair(Pointer)                          is native(OBJC) { * }
sub objc_autoreleasePoolPush(--> Pointer)                    is native(OBJC) { * }
sub objc_autoreleasePoolPop(Pointer)                         is native(OBJC) { * }

# The action IMP is a Raku sub. The declared sub-signature carries the C shape;
# it returns int64 (always 0) because a `v@:@` method ignores the register
# anyway and an explicit return type keeps both engines' marshallers happy.
sub class_addMethod(Pointer, Pointer, &imp (Pointer, Pointer, Pointer --> int64), Str --> int8)
                                                             is native(OBJC) { * }

# objc_msgSend, re-declared once per call shape we need.
sub msg-p(Pointer, Pointer --> Pointer)            is native(OBJC) is symbol('objc_msgSend') { * }
sub msg-p-p(Pointer, Pointer, Pointer --> Pointer) is native(OBJC) is symbol('objc_msgSend') { * }
sub msg-p-str(Pointer, Pointer, Str --> Pointer)   is native(OBJC) is symbol('objc_msgSend') { * }
sub msg-p-i(Pointer, Pointer, int64 --> Pointer)   is native(OBJC) is symbol('objc_msgSend') { * }
sub msg-p-b(Pointer, Pointer, int8 --> Pointer)    is native(OBJC) is symbol('objc_msgSend') { * }
sub msg-p-d(Pointer, Pointer, num64 --> Pointer)   is native(OBJC) is symbol('objc_msgSend') { * }
sub msg-b(Pointer, Pointer --> int8)               is native(OBJC) is symbol('objc_msgSend') { * }
sub msg-ppp(Pointer, Pointer, Pointer, Pointer, Pointer --> Pointer)
                                                   is native(OBJC) is symbol('objc_msgSend') { * }
sub msg-p-dd(Pointer, Pointer, num64, num64 --> Pointer)
                                                   is native(OBJC) is symbol('objc_msgSend') { * }
sub msg-next-event(Pointer, Pointer, int64, Pointer, Pointer, int8 --> Pointer)
                                                   is native(OBJC) is symbol('objc_msgSend') { * }

# AppKit is loaded with an explicit dlopen: `is native` on the extension-less
# framework path works on rakupp but Rakudo rewrites it to lib<name>.dylib.
sub dlopen(Str, int32 --> Pointer) is native('/usr/lib/libSystem.B.dylib') { * }
sub pthread_main_np(--> int32)     is native('/usr/lib/libSystem.B.dylib') { * }
sub raise(int32 --> int32)         is native('/usr/lib/libSystem.B.dylib') { * }

sub cls(Str $n)    { objc_getClass($n) }
sub sel(Str $n)    { sel_registerName($n) }
sub ns-str(Str $s) { msg-p-str(cls('NSString'), sel('stringWithUTF8String:'), $s) }

my $DEBUG = ?%*ENV<WINGS_DEBUG>;
sub debug(Str $m) { note "wings: $m" if $DEBUG }

# NSTextAlignment center: arm64 uses the unified iOS values (1), x86-64 keeps
# the classic AppKit ones (2) — TARGET_ABI_USES_IOS_VALUES in NSText.h.
my $CENTER = $*KERNEL.hardware eq 'arm64' ?? 1 !! 2;

# ---------- widgets ----------

class Label is export {
    has Str $.text is rw;
    has $.font;
    has Pointer $.ns is rw;
    has Str $.applied is rw;
}

class Button is export {
    has Str $.title;
    has Pointer $.ns is rw;
    has Supplier $.tap = Supplier.new;
    method clicks { $!tap.Supply }
}

class Window is export {
    has Str $.title is rw;
    has @.size;
    has Pointer $.ns is rw;
    has Str $.applied-title is rw;
    has @.widgets;
    has $.y-cursor is rw;
}

# ---------- module state ----------

my $UI       = Channel.new;     # closures the main thread must run
my @WINDOWS;
my %BUTTONS;                    # NSButton address → Button
my $CURRENT-WINDOW;
my $TARGET;                     # shared target-action receiver
my $APP;

# Run a closure on the main thread, wait for its result. A Channel ack, not a
# Promise: Channel.receive parks reliably on every thread.
sub on-main(&code) {
    my $ack = Channel.new;
    $UI.send: { $ack.send(code() // True) };
    $ack.receive;
}

# The one Objective-C class whose action method dispatches to Raku buttons.
sub ensure-target() {
    return $TARGET if $TARGET.defined;
    my sub fire(Pointer $self, Pointer $cmd, Pointer $sender --> int64) {
        with %BUTTONS{+$sender} -> $b {
            debug "click on '$b.title()'";
            $b.tap.emit(True);
        }
        0;
    }
    my $c = objc_allocateClassPair(cls('NSObject'), 'WingsTarget', 0);
    class_addMethod($c, sel('clicked:'), &fire, 'v@:@');
    objc_registerClassPair($c);
    $TARGET = msg-p(msg-p($c, sel('alloc')), sel('init'));
    $TARGET;
}

# ---------- builders (called from the worker; AppKit work marshalled) ----------

multi sub window(&body, *%opts) is export {
    my ($w, $h) = %opts<size> // (480, 240);
    my $win = Window.new(title => %opts<title> // 'Wings',
                         size  => ($w, $h), y-cursor => $h - 100);
    on-main {
        my $ns = msg-p(msg-p(cls('NSWindow'), sel('alloc')), sel('init'));
        msg-p-i($ns, sel('setStyleMask:'), 15);      # titled|closable|mini|resizable
        msg-p-dd($ns, sel('setContentSize:'), $w.Num, $h.Num);
        msg-p-p($ns, sel('setTitle:'), ns-str($win.title));
        msg-p($ns, sel('center'));
        msg-p-p($ns, sel('makeKeyAndOrderFront:'), Pointer);
        msg-p-b($APP, sel('activateIgnoringOtherApps:'), 1);
        $win.ns = $ns;
        $win.applied-title = $win.title;
    }
    @WINDOWS.push: $win;
    $CURRENT-WINDOW = $win;
    debug "window '$win.title()' up";
    body();
    $win;
}

multi sub window() is export { $CURRENT-WINDOW }

sub place(Window $win, Pointer $ns, $w, $h) {
    my $x = ($win.size[0] - $w) / 2;
    msg-p-dd($ns, sel('setFrameSize:'), $w.Num, $h.Num);
    msg-p-dd($ns, sel('setFrameOrigin:'), $x.Num, $win.y-cursor.Num);
    msg-p-p(msg-p($win.ns, sel('contentView')), sel('addSubview:'), $ns);
    $win.y-cursor -= $h + 24;
}

sub label(Str $text, *%opts) is export {
    my $win = $CURRENT-WINDOW // die 'label used outside a window block';
    my $l = Label.new(:$text, font => %opts<font> // 13, applied => $text);
    on-main {
        my $ns = msg-p-p(cls('NSTextField'), sel('labelWithString:'), ns-str($text));
        msg-p-p($ns, sel('setFont:'),
                msg-p-d(cls('NSFont'), sel('systemFontOfSize:'), $l.font.Num));
        msg-p-i($ns, sel('setAlignment:'), $CENTER);
        place($win, $ns, $win.size[0] - 80, $l.font * 1.6);
        $l.ns = $ns;
    }
    $win.widgets.push: $l;
    $l;
}

sub button(Str $title, *%opts) is export {
    my $win = $CURRENT-WINDOW // die 'button used outside a window block';
    my $b = Button.new(:$title);
    on-main {
        my $t = ensure-target();
        my $ns = msg-ppp(cls('NSButton'), sel('buttonWithTitle:target:action:'),
                         ns-str($title), $t, sel('clicked:'));
        place($win, $ns, 150, 36);
        $b.ns = $ns;
        %BUTTONS{+$ns} = $b;
    }
    $win.widgets.push: $b;
    $b;
}

# ---------- the pump (main thread) ----------

sub reconcile() {
    for @WINDOWS -> $win {
        next without $win.ns;
        if $win.title ne $win.applied-title {
            msg-p-p($win.ns, sel('setTitle:'), ns-str($win.title));
            $win.applied-title = $win.title;
            debug "title -> '$win.title()'";
        }
        for $win.widgets.grep(Label) -> $l {
            next without $l.ns;
            if $l.text ne $l.applied {
                msg-p-p($l.ns, sel('setStringValue:'), ns-str($l.text));
                $l.applied = $l.text;
                debug "label -> '$l.text()'";
            }
        }
    }
}

sub app(Str $name, &body) is export {
    # No file-existence check: system dylibs live only in the dyld shared
    # cache on modern macOS, so the path never exists on disk.
    die "Wings' Cocoa backend needs macOS" unless $*KERNEL.name eq 'darwin';
    unless pthread_main_np() {
        note 'Wings must start on the process main thread.';
        note 'Under rakupp, run with RAKUPP_MAIN_THREAD=1.';
        exit 1;
    }
    dlopen(APPKIT, 9);                           # RTLD_LAZY | RTLD_GLOBAL
    $APP = msg-p(cls('NSApplication'), sel('sharedApplication'));
    msg-p-i($APP, sel('setActivationPolicy:'), 0);

    my $done = start body();

    # Autodrive: WINGS_AUTODRIVE=n clicks every button n times, once a second,
    # then raises SIGINT — the app ends through its own `whenever signal` path.
    my $auto = (%*ENV<WINGS_AUTODRIVE> // 0).Int;
    my @auto-at = $auto ?? (1 .. $auto).map(now + *) !! ();
    my $sigint-at = $auto ?? now + $auto + 1 !! Nil;   # a beat after the last click
    # WINGS_AUTOCLOSE=secs presses the close button after that many seconds —
    # performClose: is exactly the red button, so this times the close path.
    my $close-after = (%*ENV<WINGS_AUTOCLOSE> // 0).Num;
    my $close-at = $close-after ?? now + $close-after !! Nil;

    my $mode = ns-str('kCFRunLoopDefaultMode');
    while $done.status ~~ Planned {
        my $pool = objc_autoreleasePoolPush();
        while $UI.poll -> $job { $job() }
        reconcile();
        my $until = msg-p-d(cls('NSDate'), sel('dateWithTimeIntervalSinceNow:'), 0.03e0);
        my $ev = msg-next-event($APP, sel('nextEventMatchingMask:untilDate:inMode:dequeue:'),
                                -1, $until, $mode, 1);
        msg-p-p($APP, sel('sendEvent:'), $ev) if $ev;
        if @auto-at && now > @auto-at[0] {
            @auto-at.shift;
            for @WINDOWS -> $win {
                msg-p-p(.ns, sel('performClick:'), Pointer) for $win.widgets.grep(Button);
            }
        }
        if $sigint-at && now > $sigint-at {
            $sigint-at = Nil;
            raise(2);                            # SIGINT, the app's own exit path
        }
        if $close-at && now > $close-at {
            $close-at = Nil;
            msg-p-p(.ns, sel('performClose:'), Pointer) for @WINDOWS.grep(*.ns.defined);
        }
        if @WINDOWS && !@WINDOWS.grep({ .ns.defined && msg-b(.ns, sel('isVisible')) }) {
            debug 'all windows closed';
            exit 0;
        }
        objc_autoreleasePoolPop($pool);
    }
    note $done.cause if $done.status ~~ Broken;
    reconcile();
    for @WINDOWS.grep(*.ns.defined) -> $win {
        msg-p($win.ns, sel('close'));
    }
    debug "app '$name' finished";
}
