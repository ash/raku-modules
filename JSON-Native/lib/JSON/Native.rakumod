=begin pod

=head1 JSON::Native

A drop-in for JSON::Fast — replace C<use JSON::Fast> with C<use JSON::Native>
and the program keeps working — that takes each engine's fastest exact path.
No dependencies.

    use JSON::Native;

    my $data = from-json('{"a": [1, 2.5, true, null]}');
    say $data<a>[1].WHAT;        # (Rat) — Raku numerics, not doubles
    say to-json($data, :!pretty);

    say json-backend;            # which path parses here
    say json-backend(:write);    # and which one writes

=head2 Backends

=item B<Raku++> answers with its own codec (C<engine>). An engine that knows
this module answers C<use JSON::Native> itself and never reads this file.

=item B<Rakudo> parses with its own built-in copy of JSON::Fast,
C<Rakudo::Internals::JSON>, and writes with C<JSON::Native::Rakudo>, an
C<nqp::> writer that only Rakudo ever loads (C<rakudo>).

=item B<mutsu> uses the JSON::Fast it ships with (C<json-fast>).

=item Everywhere, C<JSON::Native::Raku> — JSON::Fast's behaviour in plain
Raku (C<raku>) — answers what the others decline or refuse, and is the whole
of the module on any other engine. It is loaded the first time a call needs
it.

C<JSON_NATIVE_BACKEND> names one to use instead. One that is not available is
reported on STDERR, and the usual choice is used.

=end pod

# No `unit module` line, and that is load-bearing rather than an omission: `sub
# EXPORT` — which this module uses, so it can cooperate with Data::Native —
# must sit at the file's outermost scope. Inside a package declaration Rakudo
# never runs it, exports nothing, and reports no error, which is the worst
# possible shape. The subs below are file-scoped and handed out by the EXPORT
# at the bottom.
#
# Nothing here is loaded that the engine running it does not use: every other
# module of the distribution is reached by a runtime `require` behind a test of
# the engine, so on Raku++ and mutsu the nqp:: writer is never even parsed, and
# the Raku implementation is parsed only by a call that needs it.

my Str $ENGINE = $*RAKU.compiler.name;   # 'rakudo', 'Raku++', 'mutsu', …

# A runtime lookup of a routine by name, in a SUB: a bare module-scope `try`
# leaves the caught exception in this file's `$!`, and on Rakudo that makes the
# module unserializable once another module `use`s it ("Missing serialize REPR
# function for REPR VMException"). `$!` is scoped to the routine.
sub probe-symbol(Str $name) {
    my $c = try &::($name);
    $c ~~ Callable ?? $c !! Nil
}

# ---- the Raku implementation: the fallback of every path ---------------------
#
# These two take what the caller passed, untouched — Mu and all — so the
# implementation refuses what JSON::Fast refuses, with its own messages.
my &raku-from-json;
my &raku-to-json;
sub load-raku() {
    require ::('JSON::Native::Raku');
    &raku-to-json   = ::('&JSON::Native::Raku::to-json');
    &raku-from-json = ::('&JSON::Native::Raku::from-json');
}
sub raku-from(Mu \text, *%opt) {
    load-raku() unless &raku-from-json;
    raku-from-json(text, |%opt)
}
sub raku-to(Mu \obj, *%opt) {
    load-raku() unless &raku-to-json;
    raku-to-json(obj, |%opt)
}

# ---- Raku++: the engine's codec ------------------------------------------------
#
# rakupp-json-codec makes the codec a ROUTINE with the fallback built in, and
# that routine is what this module exports: no Raku frame stands between a call
# and the codec. An older engine has only the bare primitives, which raise for
# what they do not cover and are reached through from-json/to-json below — and
# whose text is not NFC where a \u escape assembled it, so there a document
# holding one goes to the Raku implementation.
my &codec-maker      = $ENGINE eq 'Raku++' ?? probe-symbol('rakupp-json-codec') !! Nil;
my &engine-from-json = $ENGINE eq 'Raku++' ?? probe-symbol('rakupp-from-json')  !! Nil;
my &engine-to-json   = $ENGINE eq 'Raku++' ?? probe-symbol('rakupp-to-json')    !! Nil;
my &codec-from-json  = &codec-maker ?? codec-maker('from-json', &raku-from) !! Nil;
my &codec-to-json    = &codec-maker ?? codec-maker('to-json',   &raku-to)   !! Nil;

sub engine-normalises(--> Bool) {
    my $s = try engine-from-json("\"a\x5Cu0301\"");
    so $s.defined && $s.codes == 1
}
my Bool $engine-nfc = &codec-maker ?? True !! &engine-from-json ?? engine-normalises() !! False;

# ---- Rakudo: its own JSON::Fast, and an nqp:: writer -------------------------------
#
# Rakudo::Internals::JSON is the copy of JSON::Fast that Rakudo carries for its
# own use (zef parses META6 with it). It parses exactly as JSON::Fast does —
# checked over 6,000 documents, accepted and refused — at JSON::Fast's speed, so
# a plain from-json is its. Its WRITER is older and wrong outside plain JSON
# data (a Set's keys unquoted, an enum bare), so writing is the nqp:: writer's.
# looked up by name, at run time and only on Rakudo: an engine without the
# class must still be able to compile this file
my $RAKUDO-JSON = $ENGINE eq 'rakudo' ?? ::('Rakudo::Internals::JSON') !! Nil;
my &rakudo-to-json;
sub load-rakudo-writer() {
    require ::('JSON::Native::Rakudo');
    &rakudo-to-json = ::('&JSON::Native::Rakudo::to-json');
}

# ---- mutsu, or wherever it is asked for: JSON::Fast -------------------------------
#
# mutsu ships JSON::Fast and runs it fast; nothing is installed for it. It is
# looked for with a runtime `require` and never declared, so on an engine
# without it nothing installs it.
my &jf-from-json;
my &jf-to-json;
sub load-json-fast(--> Bool) {
    # each lookup in the block of its `require`: what a runtime require brings
    # in is visible there, and a lookup after the block fails
    try {
        require ::('JSON::Fast');
        &jf-from-json = ::('&JSON::Fast::from-json');
        &jf-to-json   = ::('&JSON::Fast::to-json');
    }
    so &jf-from-json
}

# ---- choosing ------------------------------------------------------------------
#
# Once per process, at the first call (on Raku++ at load: there every probe is a
# name lookup and the answer decides what EXPORT hands out).
my Str $PARSE;
my Str $WRITE;
sub choose() {
    my $want = %*ENV<JSON_NATIVE_BACKEND> // '';
    my %have = :raku;
    %have<engine>    = so (&codec-maker || &engine-from-json) if $ENGINE eq 'Raku++';
    %have<rakudo>    = True                                   if $ENGINE eq 'rakudo';
    %have<json-fast> = load-json-fast()                       if $want eq 'json-fast' || $ENGINE eq 'mutsu';
    if $want && !%have{$want} {
        note "JSON::Native: JSON_NATIVE_BACKEND=$want is not available here; using the usual choice";
        $want = '';
    }
    $PARSE = $want || (%have<engine> ?? 'engine' !! %have<rakudo> ?? 'rakudo'
                    !! %have<json-fast> ?? 'json-fast' !! 'raku');
    $WRITE = $PARSE;
}
# …and on mutsu at load too, which LOADS JSON::Fast now rather than at the
# first call: mutsu's runtime `require` imports what it loads into the
# program's scope (2026.07), so JSON::Fast loaded by a call would put its
# from-json over the one `use JSON::Native` handed out. Loaded here, before
# this module's EXPORT runs, ours lands last.
choose() if $ENGINE eq 'Raku++' | 'mutsu';

# Which path answers a plain call: 'engine', 'rakudo', 'json-fast' or 'raku' —
# the parser, or with :write the writer.
sub json-backend(Bool :$write) {
    choose() unless $PARSE;
    $write ?? $WRITE !! $PARSE
}

# The adverbs are checked with `!%opt` and a lookup rather than a set
# difference (4.7 µs a call on Rakudo, most of a small parse), and no `try`
# here `return`s from inside itself (34 µs on Raku++ 5.3).
sub from-json(Str() $text, *%opt) {
    choose() unless $PARSE;
    my $parsed;
    my $ok = False;
    if $PARSE eq 'rakudo' {
        if !%opt {
            try { $parsed := $RAKUDO-JSON.from-json($text); $ok = True }
        }
    }
    elsif $PARSE eq 'json-fast' {
        # JSON::Fast's refusals are re-asked of the Raku implementation, so the
        # exception is the same from every path. Not :allow-jsonc: JSON::Fast's
        # end-of-text quirk (a `//` comment running into the end is content
        # after the document) depends on how the engine runs its nqp:: code,
        # and mutsu runs it to a different answer.
        if !%opt || %opt.elems == 1 && %opt<immutable>.defined {
            try { $parsed := jf-from-json($text, |%opt); $ok = True }
        }
    }
    elsif $PARSE eq 'engine' {
        if (!%opt || %opt.elems == 1 && %opt<immutable>.defined)
           && ($engine-nfc || !$text.contains("\x5Cu")) {
            try { $parsed := engine-from-json($text, |%opt); $ok = True }
        }
    }
    return $parsed if $ok;
    raku-from($text, |%opt)
}

# `($obj, *%opt)` rather than `(|c)`: under Raku++ a single Array argument
# FLATTENS into a capture, so `to-json([1,2,3])` once serialised `1`. A bare
# `$obj` is Any-constrained, which is deliberate: JSON::Fast's own parameter is
# too, so `to-json(Mu)` must be refused here exactly as it is there.
my %WRITES = :pretty, :spacing, :sorted-keys, :enums-as-value, :level;
sub to-json($obj, *%opt) {
    choose() unless $PARSE;
    if $WRITE eq 'rakudo' {
        load-rakudo-writer() unless &rakudo-to-json;
        my $s = rakudo-to-json($obj, |%opt);
        return $s if $s.defined;
    }
    elsif $WRITE eq 'json-fast' {
        my $s = try jf-to-json($obj, |%opt);
        return $s if $s.defined;
    }
    elsif $WRITE eq 'engine' {
        if (!%opt || !%opt.keys.first({ !%WRITES{$_} }).defined) && %opt<sorted-keys> !~~ Callable {
            my $s = try engine-to-json($obj, |%opt);
            return $s if $s.defined;
        }
    }
    raku-to($obj, |%opt)
}

# ===========================================================================
# What `use` hands out.
#
# JSON::Fast's import options come first: `use JSON::Fast <immutable !pretty
# sorted-keys enums-as-value>` changes the defaults of the subs it exports, and
# so must `use JSON::Native <…>` — the same words, the same effect.
#
# Then the cooperation protocol: `use Data::Native <json>` exports the same
# names, and two modules exporting one name is a hard compile error on Rakudo —
# so these two cooperate rather than collide. Whichever loads second yields the
# contested names; the program builds in either order.
# ===========================================================================

sub claimed()  { PROCESS::<%DATA-NATIVE-CLAIMED>  //= {} }
sub exported() { PROCESS::<%DATA-NATIVE-EXPORTED> //= {} }

# Where the engine's codec routine parses (or writes), IT is what is handed out
# — not from-json/to-json above, which would put a Raku frame in front.
my %IMPL = 'from-json'    => ($PARSE && $PARSE eq 'engine' && &codec-from-json ?? &codec-from-json !! &from-json),
           'to-json'      => ($WRITE && $WRITE eq 'engine' && &codec-to-json   ?? &codec-to-json   !! &to-json),
           'json-backend' => &json-backend;

my @NAMES = %IMPL.keys.sort;
my $KNOWN = @NAMES.Set;
my %OPTIONS = 'immutable' => 'immutable', 'pretty' => 'pretty',
              'sorted-keys' => 'sorted-keys', 'enums-as-value' => 'enums-as-value';

sub EXPORT(*@args) {
    # JSON::Fast's import options, '!'-negated or not
    my %default;
    my @names;
    for @args.map(*.Str) -> $a {
        my $neg = $a.starts-with('!');
        with %OPTIONS{$neg ?? $a.substr(1) !! $a} { %default{$_} = !$neg }
        else { @names.push: $a }
    }

    my $stand-aside = ?claimed()<json>;
    exported()<json> = 'JSON::Native' unless $stand-aside;

    my @want = @names || @NAMES;
    my @unknown = @want.grep({ !$KNOWN{$_} });
    die "JSON::Native: no such name" ~ (@unknown > 1 ?? 's' !! '') ~ " "
      ~ @unknown.map({ "'$_'" }).join(', ')
        if @unknown;

    return Map.new() if $stand-aside;

    my %subs = %IMPL;
    if %default<immutable>:exists {
        my $immutable = %default<immutable>;
        my &f = %IMPL<from-json>;
        %subs<from-json> = sub from-json(Str() $text, *%opt) { f($text, :$immutable, |%opt) };
    }
    if (%default<pretty>:exists) || (%default<sorted-keys>:exists) || (%default<enums-as-value>:exists) {
        my %d = %default<pretty sorted-keys enums-as-value>:p;
        my &t = %IMPL<to-json>;
        %subs<to-json> = sub to-json($obj, *%opt) { t($obj, |%d, |%opt) };
    }
    Map.new(@want.map({ "&$_" => %subs{$_} }))
}
