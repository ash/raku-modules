# The GTK3 backend: plain C, no ABI tricks needed — the used subset passes
# only pointers, ints and strings. GTK does not demand the process FIRST
# thread, only that every GTK call comes from ONE thread — which the GUI::Wings
# pump guarantees by construction, so no RAKUPP_MAIN_THREAD is needed on Linux.
# Coordinates arrive bottom-left (the Wings convention, Cocoa's native one);
# GTK's origin is top-left, so this backend flips y against the window height.
# On macOS the library paths point at the x86-64 Homebrew prefix, which lets a
# Rosetta Rakudo exercise this whole backend without a Linux box.
unit class GUI::Wings::Backend::Gtk;

use NativeCall;

sub gtk-lib     { $*KERNEL.name eq 'darwin' ?? '/usr/local/lib/libgtk-3.0.dylib'     !! 'libgtk-3.so.0' }
sub gobject-lib { $*KERNEL.name eq 'darwin' ?? '/usr/local/lib/libgobject-2.0.dylib' !! 'libgobject-2.0.so.0' }
sub libc-lib    { $*KERNEL.name eq 'darwin' ?? '/usr/lib/libSystem.B.dylib'          !! 'libc.so.6' }

sub gtk_init_check(Pointer, Pointer --> int32)             is native(&gtk-lib) { * }
sub gtk_window_new(int32 --> Pointer)                      is native(&gtk-lib) { * }
sub gtk_window_set_title(Pointer, Str)                     is native(&gtk-lib) { * }
sub gtk_window_set_resizable(Pointer, int32)               is native(&gtk-lib) { * }
sub gtk_window_close(Pointer)                              is native(&gtk-lib) { * }
sub gtk_widget_set_size_request(Pointer, int32, int32)     is native(&gtk-lib) { * }
sub gtk_widget_show_all(Pointer)                           is native(&gtk-lib) { * }
sub gtk_widget_destroy(Pointer)                            is native(&gtk-lib) { * }
sub gtk_widget_get_style_context(Pointer --> Pointer)      is native(&gtk-lib) { * }
sub gtk_fixed_new(--> Pointer)                             is native(&gtk-lib) { * }
sub gtk_fixed_put(Pointer, Pointer, int32, int32)          is native(&gtk-lib) { * }
sub gtk_container_add(Pointer, Pointer)                    is native(&gtk-lib) { * }
sub gtk_label_new(Str --> Pointer)                         is native(&gtk-lib) { * }
sub gtk_label_set_text(Pointer, Str)                       is native(&gtk-lib) { * }
sub gtk_label_set_xalign(Pointer, num32)                   is native(&gtk-lib) { * }
sub gtk_button_new_with_label(Str --> Pointer)             is native(&gtk-lib) { * }
sub gtk_button_clicked(Pointer)                            is native(&gtk-lib) { * }
sub gtk_events_pending(--> int32)                          is native(&gtk-lib) { * }
sub gtk_main_iteration_do(int32 --> int32)                 is native(&gtk-lib) { * }
sub gtk_css_provider_new(--> Pointer)                      is native(&gtk-lib) { * }
sub gtk_css_provider_load_from_data(Pointer, Str, int64, Pointer --> int32)
                                                           is native(&gtk-lib) { * }
sub gtk_style_context_add_provider(Pointer, Pointer, uint32)
                                                           is native(&gtk-lib) { * }
sub g_signal_connect_data(Pointer, Str, &cb (Pointer, Pointer --> int64), Pointer, Pointer, int32 --> uint64)
                                                           is native(&gobject-lib) { * }
sub c-raise(int32 --> int32) is native(&libc-lib) is symbol('raise') { * }

my %ALIVE;    # window address → True until its destroy signal fires
my @KEEP;     # root every closure handed to C (Rakudo does not)

# GTK_STYLE_PROVIDER_PRIORITY_APPLICATION
my constant CSS-APP = 600;

sub style(Pointer $widget, Str $css) {
    my $prov = gtk_css_provider_new();
    gtk_css_provider_load_from_data($prov, $css, -1, Pointer);
    gtk_style_context_add_provider(gtk_widget_get_style_context($widget), $prov, CSS-APP);
}

has %!fixed;    # window address → its GtkFixed content container
has %!height;   # window address → content height, for the y flip

method init() {
    die "GTK could not open a display (is one running?)"
        unless gtk_init_check(Pointer, Pointer);
}

method make-window(:$title!, :$w!, :$h!, :$fixed = False --> Pointer) {
    my $win = gtk_window_new(0);                 # GTK_WINDOW_TOPLEVEL
    gtk_window_set_title($win, $title);
    gtk_window_set_resizable($win, $fixed ?? 0 !! 1);
    my $box = gtk_fixed_new();
    gtk_widget_set_size_request($box, $w.Int, $h.Int);
    gtk_container_add($win, $box);
    %!fixed{+$win}  = $box;
    %!height{+$win} = $h;
    my $addr = +$win;
    my &gone = sub (Pointer $wdg, Pointer $data --> int64) { %ALIVE{$addr}:delete; 0 };
    @KEEP.push: &gone;
    g_signal_connect_data($win, 'destroy', &gone, Pointer, Pointer, 0);
    %ALIVE{$addr} = True;
    gtk_widget_show_all($win);
    $win;
}

method set-window-title(Pointer $win, Str() $t) {
    gtk_window_set_title($win, $t);
}

method !put(Pointer $win, Pointer $widget, $x, $y, $w, $h) {
    gtk_widget_set_size_request($widget, $w.Int, $h.Int);
    gtk_fixed_put(%!fixed{+$win}, $widget, $x.Int, (%!height{+$win} - $y - $h).Int);
    gtk_widget_show_all($widget);
}

method make-label(Pointer :$win!, Str() :$text!, :$font = 13, :$mono = False,
                  Str :$align = 'center', :$x!, :$y!, :$w!, :$h! --> Pointer) {
    my $l = gtk_label_new($text);
    gtk_label_set_xalign($l, ($align eq 'left' ?? 0e0 !! $align eq 'right' ?? 1e0 !! 0.5e0));
    style($l, "label \{ font-size: {$font.Int}px;"
              ~ ($mono ?? ' font-family: monospace;' !! '') ~ ' }');
    self!put($win, $l, $x, $y, $w, $h);
    $l;
}

method set-label-text(Pointer $l, Str() $t) {
    gtk_label_set_text($l, $t);
}

method make-button(Pointer :$win!, Str() :$title!, :$font, Str :$tint = '',
                   :$x!, :$y!, :$w!, :$h!, :&clicked! --> Pointer) {
    my $b = gtk_button_new_with_label($title);
    my $css = 'button {';
    $css ~= " font-size: {$font.Int}px;" if $font;
    $css ~= " background-image: none; background-color: $tint; color: white;" if $tint;
    $css ~= ' }';
    style($b, $css) if $font || $tint;
    my &fire = sub (Pointer $wdg, Pointer $data --> int64) { clicked(); 0 };
    @KEEP.push: &fire;
    g_signal_connect_data($b, 'clicked', &fire, Pointer, Pointer, 0);
    self!put($win, $b, $x, $y, $w, $h);
    $b;
}

method pump() {
    my $n = 0;
    while gtk_events_pending() {
        gtk_main_iteration_do(0);
        last if ++$n > 100;                      # never let a flood starve the pump loop
    }
    sleep 0.02;
}

method frame-begin(--> Pointer) { Pointer }      # no autorelease pools in GTK
method frame-end(Pointer $)     { }

method click(Pointer $b)         { gtk_button_clicked($b) }
method press-close(Pointer $win) { gtk_widget_destroy($win) if %ALIVE{+$win} }   # gtk_window_close is inert on the Quartz build; destroy is what delete-event does anyway
method visible(Pointer $win --> Bool) { so %ALIVE{+$win} }
method close(Pointer $win)       { gtk_widget_destroy($win) if %ALIVE{+$win}:delete }
method raise-sigint()            { c-raise(2) }
