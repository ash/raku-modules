# The Cocoa backend: AppKit over NativeCall + objc_msgSend, no C glue.
# Every method runs on the pump thread (see GUI::Wings) — which on macOS must
# be the process MAIN thread, the only one AppKit accepts; init() enforces it.
# Coordinates arrive bottom-left (Cocoa's own), so no conversion happens here.
unit class GUI::Wings::Backend::Cocoa;

use NativeCall;

my constant OBJC = '/usr/lib/libobjc.A.dylib';
my constant APPKIT = '/System/Library/Frameworks/AppKit.framework/AppKit';

sub objc_getClass(Str --> Pointer)                           is native(OBJC) { * }
sub sel_registerName(Str --> Pointer)                        is native(OBJC) { * }
sub objc_allocateClassPair(Pointer, Str, uint64 --> Pointer) is native(OBJC) { * }
sub objc_registerClassPair(Pointer)                          is native(OBJC) { * }
sub objc_autoreleasePoolPush(--> Pointer)                    is native(OBJC) { * }
sub objc_autoreleasePoolPop(Pointer)                         is native(OBJC) { * }

# The action IMP is a Raku sub; the sub-signature carries the C shape. It
# returns int64 (always 0): a `v@:@` method ignores the register anyway and an
# explicit return type keeps both engines' marshallers happy.
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
sub c-raise(int32 --> int32)       is native('/usr/lib/libSystem.B.dylib') is symbol('raise') { * }

sub cls(Str $n)    { objc_getClass($n) }
sub sel(Str $n)    { sel_registerName($n) }
sub ns-str(Str $s) { msg-p-str(cls('NSString'), sel('stringWithUTF8String:'), $s) }

# NSTextAlignment: arm64 uses the unified iOS values (center 1, right 2),
# x86-64 keeps the classic AppKit ones (right 1, center 2) —
# TARGET_ABI_USES_IOS_VALUES in NSText.h. Left is 0 on both.
my %ALIGN = $*KERNEL.hardware eq 'arm64'
    ?? (left => 0, center => 1, right => 2)
    !! (left => 0, center => 2, right => 1);

my %ACTIONS;    # NSButton address → click closure
my @KEEP;       # root every closure handed to C (Rakudo does not)
my $TARGET;     # the shared target-action receiver
my $APP;

# The one Objective-C class whose action method dispatches to Raku buttons.
sub ensure-target() {
    return $TARGET if $TARGET.defined;
    my sub fire(Pointer $self, Pointer $cmd, Pointer $sender --> int64) {
        .() with %ACTIONS{+$sender};
        0;
    }
    @KEEP.push: &fire;
    my $c = objc_allocateClassPair(cls('NSObject'), 'WingsTarget', 0);
    class_addMethod($c, sel('clicked:'), &fire, 'v@:@');
    objc_registerClassPair($c);
    $TARGET = msg-p(msg-p($c, sel('alloc')), sel('init'));
    $TARGET;
}

sub place(Pointer $win, Pointer $ns, $x, $y, $w, $h) {
    msg-p-dd($ns, sel('setFrameSize:'), $w.Num, $h.Num);
    msg-p-dd($ns, sel('setFrameOrigin:'), $x.Num, $y.Num);
    msg-p-p(msg-p($win, sel('contentView')), sel('addSubview:'), $ns);
}

method init() {
    die "the Cocoa backend needs macOS" unless $*KERNEL.name eq 'darwin';
    unless pthread_main_np() {
        note 'GUI::Wings must start on the process main thread.';
        note 'Under rakupp, run with RAKUPP_MAIN_THREAD=1.';
        exit 1;
    }
    dlopen(APPKIT, 9);                           # RTLD_LAZY | RTLD_GLOBAL
    $APP = msg-p(cls('NSApplication'), sel('sharedApplication'));
    msg-p-i($APP, sel('setActivationPolicy:'), 0);
}

method make-window(Str() :$title!, :$w!, :$h!, :$fixed = False --> Pointer) {
    my $ns = msg-p(msg-p(cls('NSWindow'), sel('alloc')), sel('init'));
    # titled|closable|mini (11), plus resizable (|4) unless :fixed
    msg-p-i($ns, sel('setStyleMask:'), $fixed ?? 11 !! 15);
    msg-p-dd($ns, sel('setContentSize:'), $w.Num, $h.Num);
    msg-p-p($ns, sel('setTitle:'), ns-str($title));
    msg-p($ns, sel('center'));
    msg-p-p($ns, sel('makeKeyAndOrderFront:'), Pointer);
    msg-p-b($APP, sel('activateIgnoringOtherApps:'), 1);
    $ns;
}

method set-window-title(Pointer $win, Str() $t) {
    msg-p-p($win, sel('setTitle:'), ns-str($t));
}

method make-label(Pointer :$win!, Str() :$text!, :$font = 13, :$mono = False,
                  Str :$align = 'center', :$x!, :$y!, :$w!, :$h! --> Pointer) {
    my $ns = msg-p-p(cls('NSTextField'), sel('labelWithString:'), ns-str($text));
    # :mono — fixed-width digits, so a changing readout does not jitter
    my $f = $mono
        ?? msg-p-dd(cls('NSFont'), sel('monospacedDigitSystemFontOfSize:weight:'), $font.Num, 0e0)
        !! msg-p-d(cls('NSFont'), sel('systemFontOfSize:'), $font.Num);
    msg-p-p($ns, sel('setFont:'), $f);
    msg-p-i($ns, sel('setAlignment:'), %ALIGN{$align} // %ALIGN<center>);
    place($win, $ns, $x, $y, $w, $h);
    $ns;
}

method set-label-text(Pointer $l, Str() $t) {
    msg-p-p($l, sel('setStringValue:'), ns-str($t));
}

method make-button(Pointer :$win!, Str() :$title!, :$font, Str :$tint = '',
                   :$x!, :$y!, :$w!, :$h!, :&clicked! --> Pointer) {
    my $t = ensure-target();
    my $ns = msg-ppp(cls('NSButton'), sel('buttonWithTitle:target:action:'),
                     ns-str($title), $t, sel('clicked:'));
    # the default rounded bezel has a fixed height — a taller button needs the
    # flexible regular-square bezel to actually draw at its size
    msg-p-i($ns, sel('setBezelStyle:'), 2) if $h > 32;
    msg-p-p($ns, sel('setFont:'), msg-p-d(cls('NSFont'), sel('systemFontOfSize:'), $font.Num))
        if $font;
    # :tint<orange> etc — any NSColor system color name
    msg-p-p($ns, sel('setBezelColor:'), msg-p(cls('NSColor'), sel('system' ~ $tint.tc ~ 'Color')))
        if $tint;
    place($win, $ns, $x, $y, $w, $h);
    %ACTIONS{+$ns} = &clicked;
    @KEEP.push: &clicked;
    $ns;
}

my $MODE;
method pump() {
    # retained: this method runs inside the per-turn autorelease pool, and an
    # autoreleased mode string would be freed at frame-end while we cache it
    $MODE //= msg-p(ns-str('kCFRunLoopDefaultMode'), sel('retain'));
    my $until = msg-p-d(cls('NSDate'), sel('dateWithTimeIntervalSinceNow:'), 0.03e0);
    my $ev = msg-next-event($APP, sel('nextEventMatchingMask:untilDate:inMode:dequeue:'),
                            -1, $until, $MODE, 1);
    msg-p-p($APP, sel('sendEvent:'), $ev) if $ev;
}

method frame-begin(--> Pointer)  { objc_autoreleasePoolPush() }
method frame-end(Pointer $pool)  { objc_autoreleasePoolPop($pool) }

method click(Pointer $b)         { msg-p-p($b, sel('performClick:'), Pointer) }
method press-close(Pointer $win) { msg-p-p($win, sel('performClose:'), Pointer) }
method visible(Pointer $win --> Bool) { ?msg-b($win, sel('isVisible')) }
method close(Pointer $win)       { msg-p($win, sel('close')) }
method raise-sigint()            { c-raise(2) }
