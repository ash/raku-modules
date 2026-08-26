# The Win32 backend: user32/gdi32 over NativeCall, no C glue.
#
# UNTESTED — written against the Win32 API but never run on Windows; there is
# no Windows machine in this project. It parses on both engines and follows the
# same ten-method contract as the Cocoa and Gtk backends. Treat every claim
# below as intent until someone runs `WINGS_AUTODRIVE=2 rakupp examples\counter.raku`
# on a real desktop. See the module README's Requirements section.
#
# Everything goes through the WIDE (…W) entry points with UTF-16 strings: the
# ANSI ones would mangle the calculator's ÷ × − keys. Strings are marshalled as
# CArray[uint16] rather than Str, which both engines agree on.
#
# Coordinates arrive bottom-left (the Wings convention, Cocoa's native one);
# Windows' origin is top-left, so this backend flips y against the client height.
#
# Threading: Win32 is thread-affine like Cocoa — a window belongs to the thread
# that created it, and only that thread may pump its messages. The GUI::Wings
# pump thread does both, which satisfies the rule; under rakupp on Windows the
# 1 GiB spawn is that thread throughout, so no RAKUPP_MAIN_THREAD is needed
# (nothing here demands the process FIRST thread the way AppKit does).
unit class GUI::Wings::Backend::Win32;

use NativeCall;

my constant U32 = 'user32';
my constant K32 = 'kernel32';
my constant G32 = 'gdi32';

# --- window classes and windows ---
sub GetModuleHandleW(Pointer --> Pointer) is native(K32) { * }
sub DefWindowProcW(Pointer, uint32, uint64, int64 --> int64) is native(U32) { * }
sub RegisterClassExW(Pointer --> uint16) is native(U32) { * }
sub CreateWindowExW(uint32, CArray[uint16], CArray[uint16], uint32,
                    int32, int32, int32, int32,
                    Pointer, Pointer, Pointer, Pointer --> Pointer) is native(U32) { * }
sub DestroyWindow(Pointer --> int32)                is native(U32) { * }
sub ShowWindow(Pointer, int32 --> int32)            is native(U32) { * }
sub UpdateWindow(Pointer --> int32)                 is native(U32) { * }
sub SetWindowTextW(Pointer, CArray[uint16] --> int32) is native(U32) { * }
sub SetWindowPos(Pointer, Pointer, int32, int32, int32, int32, uint32 --> int32)
                                                    is native(U32) { * }
sub IsWindow(Pointer --> int32)                     is native(U32) { * }
sub SetForegroundWindow(Pointer --> int32)          is native(U32) { * }
sub SendMessageW(Pointer, uint32, uint64, int64 --> int64) is native(U32) { * }
sub PostMessageW(Pointer, uint32, uint64, int64 --> int32) is native(U32) { * }
sub GetSystemMetrics(int32 --> int32)               is native(U32) { * }
sub AdjustWindowRect(Pointer, uint32, int32 --> int32) is native(U32) { * }

# --- the message pump ---
sub PeekMessageW(Pointer, Pointer, uint32, uint32, uint32 --> int32) is native(U32) { * }
sub TranslateMessage(Pointer --> int32)             is native(U32) { * }
sub DispatchMessageW(Pointer --> int64)             is native(U32) { * }

# --- fonts ---
sub CreateFontW(int32, int32, int32, int32, int32, uint32, uint32, uint32,
                uint32, uint32, uint32, uint32, uint32, CArray[uint16] --> Pointer)
                                                    is native(G32) { * }
sub DeleteObject(Pointer --> int32)                 is native(G32) { * }

# The window procedure: a Raku callback Windows itself invokes.
sub SetWindowLongPtrW(Pointer, int32, Pointer --> Pointer) is native(U32) { * }

my constant WS_OVERLAPPED   = 0x00000000;
my constant WS_CAPTION      = 0x00C00000;
my constant WS_SYSMENU      = 0x00080000;
my constant WS_MINIMIZEBOX  = 0x00020000;
my constant WS_THICKFRAME   = 0x00040000;
my constant WS_MAXIMIZEBOX  = 0x00010000;
my constant WS_CHILD        = 0x40000000;
my constant WS_VISIBLE      = 0x10000000;
my constant BS_PUSHBUTTON   = 0x00000000;
my constant SS_CENTER       = 0x00000001;
my constant SS_RIGHT        = 0x00000002;
my constant SS_LEFT         = 0x00000000;
my constant WM_DESTROY      = 0x0002;
my constant WM_CLOSE        = 0x0010;
my constant WM_COMMAND      = 0x0111;
my constant WM_SETFONT      = 0x0030;
my constant BM_CLICK        = 0x00F5;
my constant SW_SHOW         = 5;
my constant PM_REMOVE       = 1;
my constant GWLP_WNDPROC    = -4;
my constant DEFAULT_CHARSET = 1;
my constant FIXED_PITCH     = 1;

# A plain window (title bar, close box, minimise); |WS_THICKFRAME|WS_MAXIMIZEBOX
# adds resizing, which :fixed omits.
my constant STYLE_FIXED = WS_OVERLAPPED +| WS_CAPTION +| WS_SYSMENU +| WS_MINIMIZEBOX;
my constant STYLE_SIZED = STYLE_FIXED +| WS_THICKFRAME +| WS_MAXIMIZEBOX;

sub wstr(Str $s --> CArray[uint16]) {
    my $a = CArray[uint16].new;
    my $i = 0;
    $a[$i++] = $_ for $s.encode('utf16').list;
    $a[$i] = 0;                                  # the NUL every …W call expects
    $a;
}

my %ACTIONS;    # control id → click closure
my %ALIVE;      # HWND address → True until WM_DESTROY
my @KEEP;       # root every closure handed to C (Rakudo does not)
my @FONTS;      # HFONTs live as long as the controls that use them
my $NEXT-ID = 100;

has %!height;   # window address → client height, for the y flip

# Our window procedure: turn a button's WM_COMMAND into the Raku closure, and
# treat WM_DESTROY as "this window is gone" for the liveness map. Everything
# else goes to the default handler, exactly as a C program would do it.
sub wndproc(Pointer $hwnd, uint32 $msg, uint64 $wp, int64 $lp --> int64) {
    if $msg == WM_COMMAND {
        my $id = $wp +& 0xFFFF;                  # LOWORD(wParam) is the control id
        .() with %ACTIONS{$id};
        return 0;
    }
    if $msg == WM_DESTROY {
        %ALIVE{+$hwnd}:delete;
        return 0;
    }
    DefWindowProcW($hwnd, $msg, $wp, $lp);
}

my $CLASS;
my $HINST;

method init() {
    die "the Win32 backend needs Windows" unless $*DISTRO.is-win;
    $HINST = GetModuleHandleW(Pointer);
    # WNDCLASSEXW, laid out by hand: cbSize, style, lpfnWndProc, cbClsExtra,
    # cbWndExtra, hInstance, hIcon, hCursor, hbrBackground, lpszMenuName,
    # lpszClassName, hIconSm. 80 bytes on x64.
    my $wc = CArray[uint64].new;
    $wc[$_] = 0 for ^10;
    $wc[0] = 80;                                 # cbSize (low half) — style is the high half
    @KEEP.push: &wndproc;
    my $name = wstr('WingsWindow');
    @KEEP.push: $name;
    # The struct is written through a byte view so the 32-bit and pointer
    # fields land at their real offsets rather than uint64 slots.
    my $blob = Buf[uint8].allocate(80, 0);
    my sub put-u32($off, $v) { $blob.write-uint32($off, $v, LittleEndian) }
    my sub put-ptr($off, $p) { $blob.write-uint64($off, $p ?? +nativecast(Pointer, $p) !! 0, LittleEndian) }
    put-u32(0, 80);                              # cbSize
    put-u32(4, 0);                               # style
    put-ptr(8, &wndproc);                        # lpfnWndProc
    put-ptr(24, $HINST);                         # hInstance
    put-ptr(64, $name);                          # lpszClassName
    my $ptr = nativecast(Pointer, $blob);
    @KEEP.push: $blob;
    $CLASS = RegisterClassExW($ptr);
    die "RegisterClassExW failed" unless $CLASS;
}

method make-window(Str() :$title!, :$w!, :$h!, :$fixed = False --> Pointer) {
    my $style = ($fixed ?? STYLE_FIXED !! STYLE_SIZED) +| WS_VISIBLE;
    # CreateWindowEx sizes the WHOLE window; ask for a client area of w × h by
    # padding with the frame's own metrics (SM_CXFRAME/SM_CYFRAME/SM_CYCAPTION).
    my $fw = GetSystemMetrics(32) * 2;           # SM_CXFRAME
    my $fh = GetSystemMetrics(33) * 2 + GetSystemMetrics(4);   # SM_CYFRAME, SM_CYCAPTION
    my $cls = wstr('WingsWindow');
    my $ttl = wstr($title);
    @KEEP.push: $cls, $ttl;
    my $hwnd = CreateWindowExW(0, $cls, $ttl, $style,
                               0x80000000, 0x80000000,        # CW_USEDEFAULT ×2
                               ($w + $fw).Int, ($h + $fh).Int,
                               Pointer, Pointer, $HINST, Pointer);
    die "CreateWindowExW failed" unless $hwnd;
    %!height{+$hwnd} = $h;
    %ALIVE{+$hwnd} = True;
    ShowWindow($hwnd, SW_SHOW);
    UpdateWindow($hwnd);
    SetForegroundWindow($hwnd);
    $hwnd;
}

method set-window-title(Pointer $win, Str() $t) {
    my $w = wstr($t);
    SetWindowTextW($win, $w);
}

method !child(Pointer $win, Str $class, Str $text, $style, $x, $y, $w, $h, $id --> Pointer) {
    my $c = wstr($class);
    my $t = wstr($text);
    @KEEP.push: $c, $t;
    my $hwnd = CreateWindowExW(0, $c, $t, WS_CHILD +| WS_VISIBLE +| $style,
                               $x.Int, (%!height{+$win} - $y - $h).Int, $w.Int, $h.Int,
                               $win, Pointer.new($id), $HINST, Pointer);
    die "CreateWindowExW (child) failed" unless $hwnd;
    $hwnd;
}

# CreateFontW's height is in logical units: negative means "character height",
# which is what a point-ish size means to everyone else.
sub font-for($size, $mono) {
    my $face = wstr($mono ?? 'Consolas' !! 'Segoe UI');
    @KEEP.push: $face;
    my $f = CreateFontW((-$size).Int, 0, 0, 0, 400, 0, 0, 0,
                        DEFAULT_CHARSET, 0, 0, 0, ($mono ?? FIXED_PITCH !! 0), $face);
    @FONTS.push: $f;
    $f;
}

method make-label(Pointer :$win!, Str() :$text!, :$font = 13, :$mono = False,
                  Str :$align = 'center', :$x!, :$y!, :$w!, :$h! --> Pointer) {
    my $st = $align eq 'left' ?? SS_LEFT !! $align eq 'right' ?? SS_RIGHT !! SS_CENTER;
    my $l = self!child($win, 'STATIC', $text, $st, $x, $y, $w, $h, $NEXT-ID++);
    SendMessageW($l, WM_SETFONT, +nativecast(Pointer, font-for($font, $mono)), 1);
    $l;
}

method set-label-text(Pointer $l, Str() $t) {
    my $w = wstr($t);
    SetWindowTextW($l, $w);
}

method make-button(Pointer :$win!, Str() :$title!, :$font, Str :$tint = '',
                   :$x!, :$y!, :$w!, :$h!, :&clicked! --> Pointer) {
    my $id = $NEXT-ID++;
    my $b = self!child($win, 'BUTTON', $title, BS_PUSHBUTTON, $x, $y, $w, $h, $id);
    SendMessageW($b, WM_SETFONT, +nativecast(Pointer, font-for($font // 13, False)), 1)
        if $font;
    # :tint is deliberately ignored: a coloured push button means owner-draw on
    # Win32, which is a lot of machinery for decoration. The option stays legal
    # so the same program runs everywhere — it simply looks native here.
    %ACTIONS{$id} = &clicked;
    @KEEP.push: &clicked;
    $b;
}

method pump() {
    # MSG is 48 bytes on x64: hwnd, message, wParam, lParam, time, pt.
    my $msg = Buf[uint8].allocate(48, 0);
    my $p = nativecast(Pointer, $msg);
    my $n = 0;
    while PeekMessageW($p, Pointer, 0, 0, PM_REMOVE) {
        TranslateMessage($p);
        DispatchMessageW($p);
        last if ++$n > 100;                      # never let a flood starve the pump loop
    }
    sleep 0.02;
}

method frame-begin(--> Pointer) { Pointer }      # no per-frame pool on Win32
method frame-end(Pointer $)     { }

method click(Pointer $b)         { SendMessageW($b, BM_CLICK, 0, 0) }
method press-close(Pointer $win) { PostMessageW($win, WM_CLOSE, 0, 0) if %ALIVE{+$win} }
method visible(Pointer $win --> Bool) { so %ALIVE{+$win} && IsWindow($win) }
method close(Pointer $win)       { DestroyWindow($win) if %ALIVE{+$win}:delete }

# Windows has no SIGINT to raise into a console-less GUI process, and rakupp's
# `signal` is a non-emitting stub there anyway. Closing every window ends the
# app through the pump's own all-windows-closed path instead.
method raise-sigint() {
    self.press-close($_) for %ALIVE.keys.map({ Pointer.new(+$_) });
}
