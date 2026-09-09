=begin pod

=head1 Prompt::Hidden

C<prompt> with a C<:hidden> adverb — a password typed at a terminal that the
terminal never shows.

=head2 Why it exists

Raku has C<prompt>, and it echoes. Reading a password means reaching past it:
C<Terminal::Getpass> shells out to C<stty>, and everyone else writes the same
half-dozen lines again. None of that is C<prompt>, so a program that wants one
visible field and one hidden one uses two different calls with two different
signatures.

This module makes the hidden read an B<adverb on the call you already write>:

    use Prompt::Hidden;

    my $user = prompt "Username: ";
    my $pass = prompt "Password: ", :hidden;

C<prompt> without C<:hidden> is C<CORE::<&prompt>>, forwarded capture and all —
same message, same allomorph return, same C<Nil> at end of input. Only
C<:hidden> is new.

=head2 What it runs on

The same program runs everywhere. What differs is who suppresses the echo.

=item On B<Raku++>, the engine can read a line without echoing it and the
module finds that by probing for the C<rakupp-prompt-hidden> primitive. The
B<adverb> is still this module's element. Core C<prompt> takes no named arguments
on any engine, so C<prompt("pw: ", :hidden)> without this module is an error
everywhere, which is what keeps the spelling portable. The terminal is put back
by a C<SIGINT> handler as well as by scope exit, so B<^C at the password prompt
leaves the shell working>.
=item On B<any other Raku>, the module does it itself: C<stty -g> to save,
C<stty -echo> for the duration, and the saved settings restored in a C<LEAVE>.
=item On B<Windows> without the engine primitive, C<_getch> from C<msvcrt>,
which reads a key without echoing it. That half lives in
C<Prompt::Hidden::Win32> and is loaded B<only on Windows>; C<use NativeCall>
costs about 70 ms on Rakudo, and no Unix program should pay it for a branch it
cannot take.

=head2 A secret comes back a Str, and that is deliberate

C<prompt> returns an allomorph: type C<1234> and you get an C<IntStr>, which is
an C<Int> as much as it is a C<Str>. For a PIN that is a trap, and not a
theoretical one — measured on Rakudo v2026.08 and Raku++ 3.26.0 alike:

    my $pin = prompt "PIN: ";        # user types 01234
    say to-json({ pin => $pin });    # {"pin": 1234}

The leading zero is gone and the secret has been retyped as a number. So
C<prompt(:hidden)> returns a plain C<Str>, always. C<prompt> without
C<:hidden> keeps the allomorph, because that is what C<prompt> does.

=head2 Not a terminal is not an error

A pipe, a file, a here-doc, a CI harness: there is no echo to suppress, so the
line is read plainly and returned. That is what makes C<:hidden> testable, and
it is why this distribution's own suite can assert the return type without a
pseudo-terminal.

=head2 Prompt::Hidden::prompt-backend

Says which of the three is live — C<'core'>, C<'stty'> or C<'msvcrt'> — so a
program (or a bug report) can tell them apart:

    say Prompt::Hidden::prompt-backend;   # 'core' on Raku++, 'stty' elsewhere

=head2 Exports

C<&prompt>, and only that. C<Prompt::Hidden::prompt-backend> is spelled in
full rather than exported. The import list is accepted for the one name:

    use Prompt::Hidden <prompt>;

Spelled C<< <prompt> >>, not C<:prompt> — Rakudo routes C<:tag> through the
C<is export(:tag)> machinery, which a C<sub EXPORT> module has no part in.

=head1 AUTHOR

Andrew Shitov

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Andrew Shitov

This library is free software; you can redistribute it and/or modify it under
the Artistic License 2.0.

=end pod

# ===========================================================================
# The engine probe.
#
# `try &::($name)` must be inside a SUB, not a bare block: a module-scope `try`
# leaves the caught exception in that file's `$!`, and precompiling an importer
# of this module then walks that state and dies with a serialisation error. A
# `do {}` block is not enough — `$!` is scoped to the routine. This is the same
# shape Data::Native, Digest::Native and CSV::Native all arrived at, and for
# the same reason.
# ===========================================================================

sub probe-symbol(Str $name) {
    my $c = try &::($name);
    $c ~~ Callable ?? $c !! Nil
}

my &core-hidden = probe-symbol('rakupp-prompt-hidden');

# The ordinary `prompt`, resolved ONCE, HERE — in the module body, which runs
# before the importer has `&prompt` in scope.
#
# Not at call time, and that is not a micro-optimisation. Raku++ 3.26.0 and
# earlier approximate `CORE::<&name>` as a plain lexical lookup, so a call-time
# `CORE::<&prompt>` inside this module found the `&prompt` THIS MODULE HAD JUST
# EXPORTED into the caller and recursed until the stack gave out. Resolving in
# the module body predates the export, so it answers the builtin on every
# engine — fixed or not.
my &core-prompt = CORE::<&prompt>;

# ===========================================================================
# The Windows half, loaded only on Windows.
#
# `require Mod <&sym>` declares the symbol at COMPILE time and loads at RUN
# time, so wrapping it in a runtime `if` means NativeCall is never loaded on a
# platform that cannot use it. The import list has to sit in the scope that
# uses the name — a `require` inside a `try {}` block declares the symbol in
# that block and Rakudo reports it undeclared outside. Verified on both
# engines.
#
# RAKU_PROMPT_HIDDEN_FORCE_WIN exists so the dispatch can be exercised where the
# platform cannot be: it takes this branch on any OS. Off Windows the module
# still LOADS and the symbol still binds — `is native` resolves the library
# lazily, on the first call — so `prompt-backend` answers 'msvcrt' and the
# test asserts the routing without ever making the call that would fail.
# ===========================================================================

my &win-hidden;
if $*DISTRO.is-win || %*ENV<RAKU_PROMPT_HIDDEN_FORCE_WIN> {
    require Prompt::Hidden::Win32 <&getch-line>;
    &win-hidden = &getch-line;
    CATCH { default { &win-hidden = Nil } }
}

# ===========================================================================
# The portable half: `stty`.
#
# stty acts on ITS OWN stdin, and `run` hands the child ours, so this reaches
# the same terminal the read will. A non-zero exit means stdin is not a
# terminal — a pipe, a file, a test harness — which is not an error here.
# ===========================================================================

sub stty-state() {
    my $p = run('stty', '-g', :out, :err);
    my $out = $p.out.slurp(:close);
    $p.err.slurp(:close);              # "stdin isn't a terminal" is an answer, not a failure
    $p.exitcode == 0 ?? $out.chomp !! Nil
}

sub stty-set(*@args) {
    my $p = run('stty', |@args, :out, :err);
    $p.out.slurp(:close);
    $p.err.slurp(:close);
    $p.exitcode == 0
}

# Ask the TERMINAL whether echo is off, rather than assuming `stty -echo`
# worked because it exited 0.
#
# It is not a hypothetical. On Raku++ before 3.26.0 every child `run` spawned
# was put in its own process group, so an `stty` writing to the controlling
# terminal took SIGTTOU and stopped — `stty -echo` had NO EFFECT and the
# program hung. A module whose one promise is that the terminal shows nothing
# must not take that on trust: the failure is a password typed in the clear.
#
# `stty -a` spells the flag `-echo` when off and `echo` when on, as a token of
# its own, on macOS and on GNU coreutils alike.
sub stty-echo-is-off(--> Bool) {
    my $p = run('stty', '-a', :out, :err);
    my $a = $p.out.slurp(:close);
    $p.err.slurp(:close);
    return False unless $p.exitcode == 0;
    so $a.split(/<[\s;,]>+/).first(* eq '-echo')
}

# ===========================================================================
# The read.
#
# One rule for all three backends: print the message, take one line, give back
# a plain Str — or Nil at end of input, which is what `prompt` does.
# ===========================================================================

sub read-hidden($message) {
    # The engine's own, when there is one. It prints the message itself.
    with &core-hidden {
        my $line = $message.defined ?? .($message) !! .();
        return $line.defined ?? $line.Str !! Nil;
    }

    print $message if $message.defined;
    $*OUT.flush;

    with &win-hidden {
        my $line = .();
        return Nil unless $line.defined;
        $*OUT.print("\n");             # _getch never echoed the Return
        return $line.Str;
    }

    my $saved = stty-state();
    # Not a terminal: nothing echoes, so nothing has to be suppressed.
    return $*IN.get // Nil without $saved;

    stty-line($saved)
}

# Split out so the LEAVE lives ONLY where there is something to restore. A
# LEAVE is registered for its whole BLOCK, not from the line it is written on:
# both engines run it even when an earlier `return` never reached it, so
# leaving this inline restored a terminal state that had never been saved —
# `run('stty', Any)` on every piped read, which Rakudo warns about and Raku++
# performs in silence.
sub stty-line(Str $saved) {
    # LEAVE, not a plain trailing call: an exception out of the read must not
    # be the thing that leaves a shell with echo off.
    #
    # It does NOT cover ^C. A signal's default action kills the process without
    # unwinding, so this backend has the same hole `stty -echo` in a shell
    # script has — measured, and the reason the Raku++ backend installs a
    # handler instead of relying on scope exit.
    LEAVE stty-set($saved);
    stty-set('-echo');
    # Refuse rather than read a visible password. Restoring is the LEAVE's job.
    die "Prompt::Hidden: could not turn the terminal's echo off "
      ~ "(`stty -echo` reported success but the terminal still echoes); "
      ~ "refusing to read a password in the clear"
        unless stty-echo-is-off();

    my $line = $*IN.get;
    $*OUT.print("\n");                 # the Return that ended the line was not echoed either
    $line.defined ?? $line.Str !! Nil
}

# ===========================================================================
# prompt.
#
# `|c` rather than a written signature, so the ordinary call is forwarded to
# CORE::<&prompt> EXACTLY as it was made — including a call this module has no
# opinion about, whose error should then be the core one rather than ours.
# CORE::<&prompt> resolves on both engines; that was the first thing checked.
# ===========================================================================

sub password-prompt(|c) {
    my %named = c.hash;

    # No :hidden anywhere — not ours. Forward the whole capture untouched.
    return core-prompt(|c) unless %named<hidden>:exists;

    my @extra = %named.keys.grep(* ne 'hidden').sort;
    die "Prompt::Hidden: prompt takes no named argument"
      ~ (@extra > 1 ?? 's' !! '') ~ " " ~ @extra.map({ ":$_" }).join(', ')
      ~ " beside :hidden"
        if @extra;

    my @pos = c.list;
    die "Prompt::Hidden: prompt takes at most one message, got {@pos.elems}"
        if @pos > 1;

    my $message = @pos ?? @pos[0] !! Str;

    # `:!hidden` is an ordinary prompt, allomorph and all.
    return $message.defined ?? core-prompt($message) !! core-prompt()
        unless %named<hidden>;

    read-hidden($message)
}

# ===========================================================================
# The one name that is NOT exported.
#
# `prompt-backend` answers which of the three did the reading, and that is
# introspection — worth having, not worth a name in every importer's scope. So
# it lives in a package of its own and is spelled in full:
#
#     say Prompt::Hidden::prompt-backend;   # 'core' | 'stty' | 'msvcrt'
#
# A PACKAGE BLOCK, not `unit module`, because the two cannot be swapped here:
# `sub EXPORT` has to stay at file scope (inside a package declaration Rakudo
# never runs it at all), and this block is the only way to have both.
#
# And the block is not decoration. The obvious spelling — `unit module` with
# `sub prompt(|c) is export` and a plain `our sub prompt-backend` — leaves
# Raku++ publishing that `our` sub to its importer anyway: measured, a bare
# `prompt-backend()` answers there after a mere `use`, where Rakudo refuses to
# compile it. Only this shape keeps the name out of the caller on BOTH engines,
# which is the whole point of not exporting it.
# ===========================================================================

module Prompt::Hidden {
    our sub prompt-backend(--> Str) {
        return 'core'   if &core-hidden.defined;
        return 'msvcrt' if &win-hidden.defined;
        'stty'
    }
}

# ===========================================================================
# Export: one name.
#
# `sub EXPORT` at FILE scope with no `unit module` line above it, and that is
# load-bearing: inside a package declaration Rakudo never runs EXPORT at all,
# exports nothing, and reports no error.
# ===========================================================================

my %IMPL = 'prompt' => &password-prompt;
my $KNOWN = %IMPL.keys.Set;

sub EXPORT(*@names) {
    my @want = @names ?? @names.map(*.Str) !! %IMPL.keys;
    my @unknown = @want.grep({ !$KNOWN{$_} });
    die "Prompt::Hidden: no such name" ~ (@unknown > 1 ?? 's' !! '') ~ " "
      ~ @unknown.map({ "'$_'" }).join(', ')
      ~ " (this module exports only 'prompt';"
      ~ " prompt-backend is Prompt::Hidden::prompt-backend)"
        if @unknown;

    # Built through a hash, not `Map.new(@pairs)`: on Raku++ 3.26.0 a Map
    # constructed from a LIST of pairs came back EMPTY, and an empty export map
    # is silent — the program compiles and `prompt` resolves to the built-in.
    # It went unnoticed because the engine briefly carried `:hidden` on its own
    # `prompt` too, so the calls kept working; both halves are fixed now, and a
    # bare `prompt(:hidden)` is an error again. This spelling is the one both
    # engines have always agreed on.
    my %e;
    %e{"&$_"} = %IMPL{$_} for @want;
    Map.new(%e)
}
