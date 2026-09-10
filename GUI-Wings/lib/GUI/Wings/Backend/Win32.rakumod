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

# The window procedure: a Raku callback Windows itself invokes — and the one
# thing that cannot be written into WNDCLASSEXW by hand, because there is no
# way to take the ADDRESS of a Raku sub. Rakudo refuses `nativecast(Pointer,
# &sub)` ("expected return type with CPointer, CStruct, CArray, or VMArray
# representation") and Raku++ answered a null pointer for it, which would have
# registered a class with no procedure at all. A callback becomes a C function
# pointer only where the ABI expects one: as an ARGUMENT whose signature is
# declared. So the class registers with the DEFAULT procedure — a real address,
# read out of user32 — and every window is subclassed to ours the moment it
# exists, which is a plain Win32 idiom rather than a workaround.
sub SetWindowProc(Pointer, int32, &proc (Pointer, uint32, uint64, int64 --> int64) --> Pointer)
    is native(U32) is symbol('SetWindowLongPtrW') { * }
sub GetProcAddress(Pointer, Str --> Pointer) is native(K32) { * }
# LoadLibraryW, not GetModuleHandleW: the latter finds only what the process
# has ALREADY loaded, and nothing here had called a user32 function yet — a
# console program has no reason to carry user32 at all. (gdi32 does not bring
# it in; the dependency runs the other way.) Loading it is what we want anyway,
# and the reference is never given back, which is right for the process's own
# window layer.
sub LoadLibraryW(CArray[uint16] --> Pointer) is native(K32) { * }
# The arrow cursor, by its numeric resource id — a class with no cursor leaves
# whatever the last window set, which reads as a frozen app.
sub LoadCursorW(Pointer, Pointer --> Pointer) is native(U32) { * }
# A label sits on the window's own face: the parent answers WM_CTLCOLORSTATIC
# with the face brush and turns off background erasing behind the text, or the
# control paints itself a white box and keeps yesterday's glyphs when its text
# gets shorter.
sub GetSysColorBrush(int32 --> Pointer) is native(U32) { * }
# Owner-draw: a coloured push button does not exist on Win32, so :tint means
# painting the control ourselves — fill, title, pressed state and all.
sub CreateSolidBrush(uint32 --> Pointer)                is native(G32) { * }
sub FillRect(Pointer, Pointer, Pointer --> int32)       is native(U32) { * }
sub SetTextColor(Pointer, uint32 --> uint32)            is native(G32) { * }
sub SelectObject(Pointer, Pointer --> Pointer)          is native(G32) { * }
sub DrawTextW(Pointer, CArray[uint16], int32, Pointer, uint32 --> int32) is native(U32) { * }
sub InvalidateRect(Pointer, Pointer, int32 --> int32) is native(U32) { * }
sub SetBkMode(Pointer, int32 --> int32) is native(G32) { * }

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
my constant CS_VREDRAW      = 0x0001;        # repaint the whole client area on a resize
my constant CS_HREDRAW      = 0x0002;
my constant IDC_ARROW       = 32512;
my constant COLOR_BTNFACE   = 15;
my constant BTNFACE_BRUSH   = COLOR_BTNFACE + 1;   # the pseudo-handle form
my constant WM_CTLCOLORSTATIC = 0x0138;
my constant WM_DRAWITEM     = 0x002B;
my constant BS_OWNERDRAW    = 0x0000000B;
my constant ODS_SELECTED    = 0x0001;
my constant DT_CENTER       = 0x0001;
my constant DT_VCENTER      = 0x0004;
my constant DT_SINGLELINE   = 0x0020;
my constant TRANSPARENT     = 1;
my constant DEFAULT_CHARSET = 1;
my constant FIXED_PITCH     = 1;

# A plain window (title bar, close box, minimise); |WS_THICKFRAME|WS_MAXIMIZEBOX
# adds resizing, which :fixed omits.
my constant STYLE_FIXED = WS_OVERLAPPED +| WS_CAPTION +| WS_SYSMENU +| WS_MINIMIZEBOX;
my constant STYLE_SIZED = STYLE_FIXED +| WS_THICKFRAME +| WS_MAXIMIZEBOX;

sub wstr(Str $s --> CArray[uint16]) {
    my $a = CArray[uint16].new;
    my $i = 0;
    # `.Str` first: a word list yields allomorphs, so the calculator's `<7 8 9>`
    # keys arrive as IntStr. That is a Str under Rakudo and encodes fine, and it
    # is a Str under Raku++ too — but `.encode` there was gated to plain strings
    # until 3.26, and three of the four buttons in a row threw "No such method
    # 'encode' for invocant of type 'IntStr'". On a Str this costs nothing.
    $a[$i++] = $_ for $s.Str.encode('utf16').list;
    $a[$i] = 0;                                  # the NUL every …W call expects
    $a;
}

my %ACTIONS;    # control id → click closure
# WINGS_DEBUG=1 narrates here too: the frontend's `debug` is not visible from a
# backend, and the one thing worth watching from inside is whether a click
# reaches Raku at all. That is the difference between Windows losing a message
# and the Supply losing an emit, and it cannot be told apart from outside.
my $DEBUG = ?%*ENV<WINGS_DEBUG>;
sub note-debug(Str $m) { note "wings/win32: $m" if $DEBUG }

my %ALIVE;      # HWND address → True until WM_DESTROY
my %DRAW;       # control id → what an owner-drawn button needs to paint itself
my @KEEP;       # root every closure handed to C (Rakudo does not)
my @FONTS;      # HFONTs live as long as the controls that use them
my $NEXT-ID = 100;

has %!height;   # window address → client height, for the y flip

# Our window procedure: turn a button's WM_COMMAND into the Raku closure, and
# treat WM_DESTROY as "this window is gone" for the liveness map. Everything
# else goes to the default handler, exactly as a C program would do it.
# The names are NSColor's, because that is what :tint takes on Cocoa and the
# same program has to run here. COLORREF is 0x00BBGGRR, not RGB.
sub tint-colour(Str $name) {
    my %rgb =
        orange => (255, 149,   0), gray   => (142, 142, 147),
        grey   => (142, 142, 147), blue   => (  0, 122, 255),
        green  => ( 52, 199,  89), red    => (255,  59,  48),
        yellow => (255, 204,   0), purple => (175,  82, 222),
        teal   => ( 90, 200, 250), pink   => (255,  45,  85),
        indigo => ( 88,  86, 214), brown  => (162, 132,  94);
    my $c = %rgb{$name.lc} // return Nil;
    my ($r, $g, $b) = @$c;
    ($r + ($g +< 8) + ($b +< 16), ($r * 299 + $g * 587 + $b * 114) / 1000);
}

# DRAWITEMSTRUCT on x64: CtlType 0, CtlID 4, itemID 8, itemAction 12,
# itemState 16, hwndItem 24, hDC 32, rcItem 40 (four LONGs), itemData 56.
sub draw-button(int64 $lp) {
    my $u32 = nativecast(CArray[uint32], Pointer.new($lp));
    my $u64 = nativecast(CArray[uint64], Pointer.new($lp));
    my $id  = $u32[1];
    my %d = %DRAW{$id} // return;
    my $state = $u32[4];
    my $hdc   = Pointer.new($u64[4]);
    my $rect  = Pointer.new($lp + 40);          # rcItem, in place

    # A pressed button is the same colour, darker — no second colour to name.
    my ($col, $lum) = %d<colour>, %d<lum>;
    if $state +& ODS_SELECTED {
        my ($r, $g, $b) = $col +& 0xFF, ($col +> 8) +& 0xFF, ($col +> 16) +& 0xFF;
        $col = ($r * 4 div 5) + (($g * 4 div 5) +< 8) + (($b * 4 div 5) +< 16);
    }
    my $brush = CreateSolidBrush($col);
    FillRect($hdc, $rect, $brush);
    DeleteObject($brush);

    SelectObject($hdc, %d<font>) if %d<font>;
    SetBkMode($hdc, TRANSPARENT);
    # Dark text on a light fill, light text on a dark one — one rule, so a new
    # colour never needs a second decision.
    SetTextColor($hdc, $lum > 140 ?? 0x000000 !! 0xFFFFFF);
    my $t = wstr(%d<title>);
    DrawTextW($hdc, $t, -1, $rect, DT_CENTER +| DT_VCENTER +| DT_SINGLELINE);
}

sub wndproc(Pointer $hwnd, uint32 $msg, uint64 $wp, int64 $lp --> int64) {
    if $msg == WM_DRAWITEM {
        draw-button($lp);
        return 1;                                # TRUE: it is drawn
    }
    if $msg == WM_COMMAND {
        my $id = $wp +& 0xFFFF;                  # LOWORD(wParam) is the control id
        note-debug("WM_COMMAND id=$id" ~ (%ACTIONS{$id}:exists ?? '' !! ' (NO HANDLER)'));
        .() with %ACTIONS{$id};
        return 0;
    }
    if $msg == WM_CTLCOLORSTATIC {
        # wParam is the control's HDC. Transparent background mode leaves our
        # own face showing through the text; the brush we return is what
        # Windows erases the control's rectangle with.
        SetBkMode(Pointer.new($wp), TRANSPARENT);
        return +GetSysColorBrush(COLOR_BTNFACE);
    }
    if $msg == WM_DESTROY {
        %ALIVE{+$hwnd}:delete;
        return 0;
    }
    DefWindowProcW($hwnd, $msg, $wp, $lp);
}

my $CLASS;
my $HINST;

# The host test, in the spelling that also works under an engine whose
# `$*DISTRO.is-win` is hard-coded False — see the note in GUI::Wings.
sub win-host(--> Bool) {
    return True if ($*KERNEL.name // '').lc eq 'win32';
    my $d = ($*DISTRO.name // '').lc;
    return True if $d eq 'mswin32' | 'mingw' | 'msys' | 'cygwin';
    so (try $*DISTRO.is-win);
}

method init() {
    die "the Win32 backend needs Windows" unless win-host();
    # A Win32 GUI needs an FFI that can place a wide argument list:
    # CreateWindowExW takes twelve arguments, CreateFontW fourteen. Rakudo
    # always can. Raku++ without libffi calls through a fixed prototype that
    # held eight until 3.26, and one clear sentence here beats the exception
    # that lands in the middle of building a window.
    {
        CATCH {
            when X::NYI {
                die "GUI::Wings: this engine's FFI cannot place the Win32 API's wider calls\n"
                  ~ "  ({.message})\n"
                  ~ "  Point it at a libffi (libffi-8.dll ships with GTK, MSYS2 and Python):\n"
                  ~ "    set RAKUPP_FFI=C:\\path\\to\\libffi-8.dll\n"
                  ~ "  or use a Raku++ newer than 3.26, whose fallback path is wide enough.";
            }
        }
        my $probe = CreateFontW(-12, 0, 0, 0, 400, 0, 0, 0,
                                DEFAULT_CHARSET, 0, 0, 0, 0, wstr('Segoe UI'));
        DeleteObject($probe) if $probe;
    }
    $HINST = GetModuleHandleW(Pointer);
    # WNDCLASSEXW, laid out by hand: cbSize, style, lpfnWndProc, cbClsExtra,
    # cbWndExtra, hInstance, hIcon, hCursor, hbrBackground, lpszMenuName,
    # lpszClassName, hIconSm. 80 bytes on x64.
    my $wc = CArray[uint64].new;
    $wc[$_] = 0 for ^10;
    $wc[0] = 80;                                 # cbSize (low half) — style is the high half
    my $name = wstr('WingsWindow');
    @KEEP.push: $name;
    # The struct is written through a byte view so the 32-bit and pointer
    # fields land at their real offsets rather than uint64 slots.
    my $blob = Buf[uint8].allocate(80, 0);
    my sub put-u32($off, $v) { $blob.write-uint32($off, $v, LittleEndian) }
    my sub put-ptr($off, $p) { $blob.write-uint64($off, $p ?? +nativecast(Pointer, $p) !! 0, LittleEndian) }
    put-u32(0, 80);                              # cbSize
    put-u32(4, CS_HREDRAW +| CS_VREDRAW);        # style
    # lpfnWndProc — DefWindowProcW's own address, out of the DLL that defines
    # it. Every window then gets ours (see SetWindowProc above). The two steps
    # fail for different reasons, so they say which.
    my $user32 = LoadLibraryW(wstr('user32.dll'));
    die "user32.dll would not load" unless $user32 && +$user32;
    my $def = GetProcAddress($user32, 'DefWindowProcW');
    die "user32 is loaded at {+$user32}, but GetProcAddress found no DefWindowProcW in it"
        unless $def && +$def;
    put-ptr(8, $def);                            # lpfnWndProc
    put-ptr(24, $HINST);                         # hInstance
    # hCursor and hbrBackground were left null, which is legal and looks
    # broken: no cursor of its own, and a client area nothing ever erases.
    put-ptr(40, LoadCursorW(Pointer, Pointer.new(IDC_ARROW)));   # hCursor
    $blob.write-uint64(48, BTNFACE_BRUSH, LittleEndian);         # hbrBackground
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
    # From here the messages are ours: WM_COMMAND for the buttons, WM_DESTROY
    # for liveness, everything else back to the default.
    SetWindowProc($hwnd, GWLP_WNDPROC, &wndproc);
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
    # With a transparent background the control does not erase what was there,
    # so a shorter string leaves the tail of the longer one behind. Ask for the
    # rectangle to be erased and repainted.
    InvalidateRect($l, Pointer, 1);
}

method make-button(Pointer :$win!, Str() :$title!, :$font, Str :$tint = '',
                   :$x!, :$y!, :$w!, :$h!, :&clicked! --> Pointer) {
    my $id = $NEXT-ID++;
    # A tinted button is drawn by us (BS_OWNERDRAW); an untinted one stays a
    # native push button, so a program that asks for no colour still looks like
    # every other Windows program. An unknown colour name is no tint rather
    # than an error — the same program runs on a toolkit that knows the name.
    my ($col, $lum) = $tint ?? tint-colour($tint) !! (Nil, Nil);
    my $b = self!child($win, 'BUTTON', $title, $col.defined ?? BS_OWNERDRAW !! BS_PUSHBUTTON,
                       $x, $y, $w, $h, $id);
    my $hfont = $font ?? font-for($font, False) !! Pointer;
    SendMessageW($b, WM_SETFONT, +nativecast(Pointer, $hfont), 1) if $font;
    # `%( )`, not `{ }`: a statement whose last line ends in a closing curly is
    # terminated there under Rakudo, so a trailing `if` became a second
    # statement and the parse died wanting a block. (Raku++ accepted it — a
    # divergence worth knowing about, and not one to lean on.)
    %DRAW{$id} = %( colour => $col, lum => $lum, title => $title.Str, font => $hfont )
        if $col.defined;
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
