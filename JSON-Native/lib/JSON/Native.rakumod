=begin pod

=head1 JSON::Native

JSON parsing and writing that takes the fastest path the machine has, and
gives JSON::Fast's answers on every one of them. No dependencies.

    use JSON::Native;

    my $data = from-json('{"a": [1, 2.5, true, null]}');
    say $data<a>[1].WHAT;        # (Rat) — Raku numerics, not doubles
    say to-json($data, :!pretty);

    say json-backend;            # which path parses here
    say json-backend(:write);    # and which one writes

=head2 Backends

On B<Raku++>, the interpreter's own codec (C<engine>) — handed out as the
routines themselves where the engine offers C<rakupp-json-codec>, so a call
has nothing of this module's in front of it — then the compiled extension
(C<native>), then the Raku implementation (C<raku>).

On B<Rakudo>, a C tokenizer reached through NativeCall (C<nativecall>), where
a C compiler was there at install time; then JSON::Fast (C<json-fast>), if it
happens to be installed — it is not a dependency, and nothing here installs
it; then C<raku>. JSON::Fast also writes where it is installed, as the faster
of the two writers.

C<JSON_NATIVE_BACKEND> names one to use instead: C<engine>, C<native>,
C<nativecall>, C<json-fast> or C<raku>. One that is not available on this
machine is reported on STDERR and the usual order is used.

=head2 Compatibility

The contract is JSON::Fast's: C<from-json> returns what JSON::Fast returns,
C<to-json> writes what it writes, byte for byte, with the same adverbs. A
native path answers exactly or stands aside — one that declines or raises
hands the call to the Raku implementation, so even a refusal is JSON::Fast's.
Content after the document raises C<X::JSON::Native::AdditionalContent>,
from every path.

=end pod

# No `unit module` line, and that is load-bearing rather than an omission: `sub
# EXPORT` — which this module uses, so it can cooperate with Data::Native —
# must sit at the file's outermost scope. Inside a package declaration Rakudo
# never runs it, exports nothing, and reports no error, which is the worst
# possible shape. The subs below are file-scoped and handed out by the EXPORT
# at the bottom.
#
# Unlike CSV::Native, this file needs no implementation/face split: Data::Native
# delegates its `json` tag elsewhere, so it never `use`s this module and there
# is nothing here to poison the registry.

# `&::(…)` is a RUNTIME lookup, so this line compiles on Rakudo too — where it
# simply yields Nil and the module runs its Raku implementation. Anything
# spelled `use Rakupp::Ext` would have made the file uncompilable there.
# The probe sits in a SUB, and that is load-bearing rather than tidiness. A
# bare `my &ext-load = try &::('rakupp-ext-load');` at module scope leaves the
# caught exception in this file's `$!`, and on Rakudo that makes the whole
# module unserializable the moment ANOTHER MODULE `use`s it: precompiling the
# importer walks this one's state and dies with
#
#     Missing serialize REPR function for REPR VMException (BOOTException)
#
# It only shows up when a module imports the module — a program importing it
# directly precompiles nothing and works — which is exactly why it survived
# until Data::Native tried to depend on this. A `do {}` block is NOT enough;
# `$!` is scoped to the routine, so a sub is.
sub probe-symbol(Str $name) {
    my $c = try &::($name);
    $c ~~ Callable ?? $c !! Nil
}
my &ext-load = probe-symbol('rakupp-ext-load');
my Bool $on-rakupp = ?&ext-load;

# ---- the Raku implementation --------------------------------------------------
#
# Loaded the first time a call needs it, by a runtime `require`: on a Raku++
# whose native paths answer every call a program makes, it is never loaded.
# These two are also the FALLBACK every native path hands a call to — the
# engine codec calls them itself — so they take what the caller passed,
# untouched, Mu and all, and let the implementation refuse what JSON::Fast
# refuses.
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

# ---- Raku++: the engine's codec -------------------------------------------------
#
# Asked for only on Raku++ (&ext-load resolves): a name lookup that fails on
# Rakudo is a Failure whose DESTROY warns "unhandled Failure detected".
#
# rakupp-json-codec makes the codec a ROUTINE with the fallback built in, and
# that routine is what this module exports: no Raku-level frame stands between
# a call and the codec, which on a fifty-byte document is most of the cost.
# An engine without it still has the bare primitives, which raise for what
# they do not cover and are reached through from-json/to-json below.
my &codec-maker      = $on-rakupp ?? probe-symbol('rakupp-json-codec') !! Nil;
my &engine-from-json = $on-rakupp ?? probe-symbol('rakupp-from-json')  !! Nil;
my &engine-to-json   = $on-rakupp ?? probe-symbol('rakupp-to-json')    !! Nil;
my &codec-from-json  = &codec-maker ?? codec-maker('from-json', &raku-from) !! Nil;
my &codec-to-json    = &codec-maker ?? codec-maker('to-json',   &raku-to)   !! Nil;

# Whether the bare primitive hands back text in NFC, as every Str Rakudo and
# JSON::Fast produce is. One that does not (Raku++ 5.3 and before), decoding
# "a\x5Cu0301", returns an "a" and a separate combining mark — which looks like
# "á" and is not equal to it; there a document with a \u escape in it goes to
# the Raku implementation. An engine with rakupp-json-codec has the fix.
sub engine-normalises(--> Bool) {
    my $s = try engine-from-json("\"a\x5Cu0301\"");
    so $s.defined && $s.codes == 1
}
my Bool $engine-nfc = &codec-maker ?? True !! &engine-from-json ?? engine-normalises() !! False;

# ---- Raku++: the compiled extension -----------------------------------------------
my &native-parse;
my &native-write;

sub load-native(--> Bool) {
    return False unless &ext-load;
    for libraries() -> $lib {
        next unless $lib.IO.e;
        my $ok = try ext-load($lib.Str);
        next unless $ok;
        # The loader installs the extension's subs into THIS scope.
        &native-parse = try &::('from-json-native');
        # Absent on a library built against ABI 1, which is a supported state:
        # the parser is the reason the extension exists, and to-json simply
        # stays on the next path down until the extension is rebuilt.
        &native-write = try &::('to-json-native');
        return True if &native-parse;
    }
    False
}

# Where the compiled half might be. %?RESOURCES is the installed answer and
# works on both engines; the CWD form covers a git checkout tested with -Ilib.
#
# NOT $?FILE-relative, which is the obvious third candidate: under Raku++ a
# module's $?FILE is the MAIN PROGRAM's path, not the module's, so a path
# derived from it lands somewhere unrelated. Rakudo returns the module file.
sub libraries() {
    my $ext = $*DISTRO.is-win ?? 'dll' !! ($*KERNEL.name eq 'darwin' ?? 'dylib' !! 'so');
    my $stem = $*DISTRO.is-win ?? "json.$ext" !! "libjson.$ext";
    my @c;
    with (try %?RESOURCES<libraries/json>) { @c.push($_) if .defined }
    @c.push($*CWD.add("resources/libraries/$stem"));
    @c
}

# What the extension calls back for a decoded string that may not be in NFC —
# one assembled around a \u escape, which Raku++ does not normalise on its
# own. Reached by name through rk_call, so nothing here appears to use it. See
# nfc() in src/json.c.
my sub json-native-nfc(Str $s) { $s.NFC.Str }

# ---- Rakudo: NativeCall, and JSON::Fast if it is installed -----------------------------
my &nc-parse;
my $nc-decline;
# (each lookup sits in the same block as its `require`: what a runtime
# require brings in is visible in that block, and a lookup after it fails)
sub load-nativecall(--> Bool) {
    try {
        require ::('JSON::Native::NativeCall');
        if ::('&JSON::Native::NativeCall::available')() {
            &nc-parse   = ::('&JSON::Native::NativeCall::parse');
            $nc-decline = ::('JSON::Native::NativeCall::Decline');
        }
    }
    so &nc-parse
}

my &jf-from-json;
my &jf-to-json;
sub load-json-fast(--> Bool) {
    try {
        require ::('JSON::Fast');
        &jf-from-json = ::('&JSON::Fast::from-json');
        &jf-to-json   = ::('&JSON::Fast::to-json');
    }
    so &jf-from-json
}

# ---- choosing --------------------------------------------------------------------
#
# Once per process: at load on Raku++, where every probe is a name lookup; at
# the first call on Rakudo, so a program that never parses never loads
# NativeCall or JSON::Fast. JSON_NATIVE_BACKEND overrides the order; a backend
# that is not here is reported, not fatal.
my Str $PARSE;
my Str $WRITE;
sub choose() {
    my $want = %*ENV<JSON_NATIVE_BACKEND> // '';
    my %have;
    if $on-rakupp {
        %have<engine> = so (&codec-maker || &engine-from-json);
        %have<native> = load-native() if !&codec-maker || $want eq 'native';
    }
    else {
        %have<nativecall> = load-nativecall() unless $want eq 'json-fast' | 'raku';
        %have<json-fast>  = load-json-fast()  unless $want eq 'raku';
    }
    %have<raku> = True;
    if $want && !%have{$want} {
        note "JSON::Native: JSON_NATIVE_BACKEND=$want is not available here; using the usual order";
        $want = '';
    }
    if $want {
        $PARSE = $want;
        $WRITE = $want eq 'nativecall' ?? (%have<json-fast> ?? 'json-fast' !! 'raku')
              !! $want eq 'native' && !&native-write ?? 'raku'
              !! $want;
    }
    elsif $on-rakupp {
        # the codec routine is the fastest parser and writer there is; without
        # it, the extension parses faster than the bare primitive, and the
        # primitive writes faster than the extension
        $PARSE = &codec-maker ?? 'engine' !! %have<native> ?? 'native' !! %have<engine> ?? 'engine' !! 'raku';
        $WRITE = %have<engine> ?? 'engine' !! &native-write ?? 'native' !! 'raku';
    }
    else {
        $PARSE = %have<nativecall> ?? 'nativecall' !! %have<json-fast> ?? 'json-fast' !! 'raku';
        $WRITE = %have<json-fast> ?? 'json-fast' !! 'raku';
    }
}
choose() if $on-rakupp;

# Which path answers a plain call: 'engine', 'native', 'nativecall',
# 'json-fast' or 'raku' — the parser, or with :write the writer.
sub json-backend(Bool :$write) {
    choose() unless $PARSE;
    $write ?? $WRITE !! $PARSE
}

# The adverbs are checked with `!%opt` and a lookup rather than a set
# difference (4.7 µs a call on Rakudo, most of a small parse), and no `try`
# here `return`s from inside itself (34 µs on Raku++ 5.3, where returning out
# of a `try` block is slow).
sub from-json(Str() $text, *%opt) {
    choose() unless $PARSE;
    my $parsed;
    my $ok = False;
    my $immutable = %opt<immutable>;
    if !%opt || %opt.elems == 1 && $immutable.defined {
        if $PARSE eq 'nativecall' {
            $parsed := nc-parse($text, :immutable(?$immutable));
            $ok = !($parsed === $nc-decline);
        }
        elsif $PARSE eq 'json-fast' {
            # JSON::Fast's errors are answered by the Raku implementation, so
            # the exception — X::JSON::Native::AdditionalContent among them —
            # is the same from every path
            try { $parsed := jf-from-json($text, :immutable(?$immutable)); $ok = True }
        }
        elsif $PARSE eq 'native' {
            try { $parsed := native-parse($text, :immutable(?$immutable)); $ok = True }
        }
        elsif $PARSE eq 'engine' && ($engine-nfc || !$text.contains("\x5Cu")) {
            try { $parsed := engine-from-json($text, |%opt); $ok = True }
        }
        return $parsed if $ok;
    }
    elsif $PARSE eq 'json-fast' && %opt.elems <= 2 && !%opt.keys.first({ $_ ne 'immutable' && $_ ne 'allow-jsonc' }).defined {
        try { $parsed := jf-from-json($text, |%opt); $ok = True }
        return $parsed if $ok;
    }
    raku-from($text, |%opt)
}

# The extension's writer takes one value and an optional :pretty, and hands
# back Nil for anything outside its ABI's vocabulary; the engine's takes every
# adverb but a Callable :sorted-keys and raises for what it does not cover;
# JSON::Fast takes everything, and its refusals are re-asked of the Raku
# implementation so the message is the same from every path.
#
# `($obj, *%opt)` rather than `(|c)`: under Raku++ a single Array argument
# FLATTENS into a capture, so `to-json([1,2,3])` once serialised `1`. A bare
# `$obj` is Any-constrained, which is deliberate: JSON::Fast's own parameter is
# too, so `to-json(Mu)` must be refused here exactly as it is there.
my %ENGINE-WRITES = :pretty, :spacing, :sorted-keys, :enums-as-value, :level;
sub to-json($obj, *%opt) {
    choose() unless $PARSE;
    if $WRITE eq 'json-fast' {
        my $s = try jf-to-json($obj, |%opt);
        return $s if $s.defined;
    }
    elsif $WRITE eq 'engine' {
        if (!%opt || !%opt.keys.first({ !%ENGINE-WRITES{$_} }).defined) && %opt<sorted-keys> !~~ Callable {
            my $s = try engine-to-json($obj, |%opt);
            return $s if $s.defined;
        }
    }
    elsif $WRITE eq 'native' && (!%opt || %opt.elems == 1 && (%opt<pretty>:exists)) {
        my $s = native-write($obj, |%opt);
        return $s if $s.defined;
    }
    raku-to($obj, |%opt)
}

# ===========================================================================
# The cooperation protocol.
#
# `use Data::Native <json>` exports the same names, and two modules exporting
# one name is a hard compile error on Rakudo — so these two cooperate rather
# than collide. Whichever loads second yields the contested names; the program
# builds in either order, and which implementation answers is not observable,
# which is what the conformance suites are for.
# ===========================================================================

sub claimed()  { PROCESS::<%DATA-NATIVE-CLAIMED>  //= {} }
sub exported() { PROCESS::<%DATA-NATIVE-EXPORTED> //= {} }

# Where the engine's codec routine parses (or writes), IT is what is handed
# out — not from-json/to-json above, which would put a Raku frame in front.
# ($PARSE is only chosen at load on Raku++; on Rakudo it waits for a call.)
my %IMPL = 'from-json'    => ($on-rakupp && $PARSE eq 'engine' && &codec-from-json ?? &codec-from-json !! &from-json),
           'to-json'      => ($on-rakupp && $WRITE eq 'engine' && &codec-to-json   ?? &codec-to-json   !! &to-json),
           'json-backend' => &json-backend;

my @NAMES = %IMPL.keys.sort;
my $KNOWN = @NAMES.Set;

sub EXPORT(*@names) {
    my $stand-aside = ?claimed()<json>;
    exported()<json> = 'JSON::Native' unless $stand-aside;

    my @want = @names ?? @names.map(*.Str) !! @NAMES;
    my @unknown = @want.grep({ !$KNOWN{$_} });
    die "JSON::Native: no such name" ~ (@unknown > 1 ?? 's' !! '') ~ " "
      ~ @unknown.map({ "'$_'" }).join(', ')
        if @unknown;

    return Map.new() if $stand-aside;

    Map.new(@want.map({ "&$_" => %IMPL{$_} }))
}
