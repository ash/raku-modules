=begin pod

=head1 Prompt::Hidden::Win32

The Windows half of C<Prompt::Hidden>: one line read through C<_getch> from
C<msvcrt>, which returns a key without echoing it.

Loaded B<only> when C<$*DISTRO.is-win> — C<use NativeCall> costs about 70 ms on
Rakudo, and a Unix program should not pay it for a branch it cannot take.

Nothing here runs on Raku++/Windows either: the engine has C<prompt(:hidden)>
natively, so C<Prompt::Hidden> takes the C<'core'> backend and never reaches
this file.

=end pod

unit module Prompt::Hidden::Win32;

use NativeCall;

# _getch: one keypress, unechoed, unbuffered. Taking it means taking the line
# discipline too — there is no kernel to honour backspace for us.
sub _getch(--> int32) is native('msvcrt') is symbol('_getch') { * }

constant CTRL-C     = 3;
constant CTRL-Z     = 26;
constant BACKSPACE  = 8;
constant DELETE     = 127;
constant RETURN     = 13;
constant NEWLINE    = 10;

# 0x00 and 0xE0 introduce a two-byte function/arrow key; the second byte has to
# be swallowed or it lands in the password as a stray character.
constant PREFIX-A   = 0;
constant PREFIX-B   = 224;

#| One line, never echoed. Nil at end of input, as `prompt` gives.
sub getch-line(--> Str) is export {
    my @chars;
    loop {
        my $ch = _getch();
        return @chars.join                 if $ch == RETURN | NEWLINE;
        exit 130                           if $ch == CTRL-C;
        return @chars ?? @chars.join !! Nil if $ch == CTRL-Z || $ch < 0;
        if $ch == BACKSPACE || $ch == DELETE {
            @chars.pop if @chars;
            next;
        }
        if $ch == PREFIX-A || $ch == PREFIX-B {
            _getch();                      # discard the second byte
            next;
        }
        @chars.push: $ch.chr;
    }
}
