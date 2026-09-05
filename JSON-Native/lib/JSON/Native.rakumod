=begin pod

=head1 JSON::Native

A JSON parser with a native fast path on Raku++, and JSON::Fast everywhere else.

The XS pattern: the distribution ships C source, the build step compiles it
against Raku++'s extension ABI, and the module uses it when it is there. On a
Raku++ without the built extension, C<from-json> still runs native through the
interpreter's own built-in codec. On Rakudo — or wherever neither is present —
nothing breaks, it simply calls C<JSON::Fast>. The same program runs on both.

=head2 Why it exists

Raku++ interprets an AST rather than JIT-compiling, so a tokenizer written in
Raku costs it roughly an order of magnitude more than it costs Rakudo, and
JSON is exactly that shape of work. The engine fast-paths the C<JSON::Fast>
calls it can cover — both directions — so what this module adds is the parse
column below, and a name that says at the point of C<use> that the code leans
on native speed. 278 KB document, measured 2026-08-23:

    278 KB document                  parse       serialise
    Rakudo JSON::Fast                42 ms        41 ms
    Raku++ JSON::Fast (fast path)    ~6 ms        6.1 ms
    JSON::Native (extension)          5.0 ms       3.5 ms

=head2 Synopsis

    use JSON::Native;

    my $data = from-json('{"a": [1, 2.5, true, null]}');
    say $data<a>[1].WHAT;        # (Rat) — Raku numerics, not doubles
    say to-json($data, :!pretty);

    say json-backend;                  # 'native', 'engine' or 'JSON::Fast'

=head2 Compatibility

C<from-json> returns what C<JSON::Fast> returns, checked value by value: Int for
integer tokens (arbitrary precision), Rat for decimals, Num for exponent forms,
Bool, Any for null, Hash and Array — or Map and List under C<:immutable>.

C<to-json> is native too as of extension ABI 2, which made a hash walk cost
O(1) per key instead of O(i). Its output is C<JSON::Fast>'s, byte for byte —
that is a contract programs already depend on, so it is checked value by value
rather than merely being valid JSON, down to backspace being written as a
six-character \u escape rather than as \b.

The native serialiser takes one value and an optional C<:pretty>. Anything
else — C<:sorted-keys>, C<:spacing>, NaN/Inf (whose rendering follows
C<$*JSON_NAN_INF_SUPPORT>), or a value outside the extension ABI's
vocabulary — falls through to C<JSON::Fast> unchanged. C<from-json> follows
the same rule for adverbs: C<:immutable> is native, anything else
(C<:allow-jsonc>, or whatever C<JSON::Fast> grows next) is delegated, never
refused. Being exactly right or standing aside is the whole bargain; being
approximately right would be worse than being slow.

=end pod

unit module JSON::Native;

# JSON::Fast is imported inside a BLOCK on purpose. `use` is lexically scoped,
# so its `from-json`/`to-json` stay in here and do not collide with the ones this
# module declares — importing it at module scope is a redeclaration error, which
# is the whole reason for the two captured references.
my &jf-from-json;
my &jf-to-json;
{
    use JSON::Fast;
    &jf-from-json = &from-json;
    &jf-to-json   = &to-json;
}

# `&::(…)` is a RUNTIME lookup, so this line compiles on Rakudo too — where it
# simply yields Nil and the module falls through to JSON::Fast. Anything
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
        # the parser is the reason this module exists, and to-json simply stays
        # on JSON::Fast until the extension is rebuilt.
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

my Bool $is-native = load-native();

# The middle path: on Raku++ WITHOUT a compiled extension, from-json still
# runs native — the interpreter's own C++ parser, reached through the
# Rakudo::Internals::JSON compatibility class it answers to. It types values
# exactly as JSON::Fast does (Int/Rat/Num per Str.Numeric, strict escapes,
# surrogate pairs), so the compatibility contract holds. Gated on &ext-load
# resolving, which only Raku++ answers: under Rakudo the same class name
# exists but is the slow vendored copy, and JSON::Fast is the right choice
# there. Two things deliberately stay OFF this path: :immutable (the engine
# class does not take it) and to-json (the engine's is compact-only where
# JSON::Fast pretty-prints by default, and byte-identical output is the
# contract — approximately right would be worse than slow).
my Bool $engine-codec = ?(!$is-native && &ext-load);

# The codec's first-party name, when this Raku++ has it; older builds answer
# only the Rakudo-compatibility spelling. Probed FUNCTIONALLY — a type object
# is undefined, so `(try ::(…)) // fallback` would always take the fallback.
# Same reason as probe-symbol above: the `try` has to live inside a routine, or
# the exception it catches stays in this file's `$!` and makes the module
# unserializable for any module that `use`s it.
sub engine-json-class() {
    my $ok = try { ::('Rakupp::Internals::JSON').from-json('1') === 1 };
    $ok ?? ::('Rakupp::Internals::JSON') !! Rakudo::Internals::JSON
}
my $engine-json = engine-json-class();

# Which parser is in use: 'native' (the compiled extension), 'engine'
# (Raku++'s built-in codec, no extension present) or 'JSON::Fast'.
our sub json-backend() is export(:MANDATORY) {
    $is-native      ?? 'native'
    !! $engine-codec ?? 'engine'
    !!                  'JSON::Fast'
}

# Same bargain as to-json below: the native parser claims the text plus an
# optional :immutable, and every OTHER adverb — :allow-jsonc today, whatever
# JSON::Fast grows tomorrow — goes to JSON::Fast untouched. Refusing an adverb
# the module it stands in for accepts would make `use JSON::Native` a
# downgrade, and this used to do exactly that ("Unexpected named argument").
our sub from-json(Str() $text, *%opt) is export(:MANDATORY) {
    if %opt.keys (-) <immutable> {
        return jf-from-json($text, |%opt);
    }
    my $immutable = %opt<immutable>;
    return native-parse($text, :$immutable) if $is-native;
    return $engine-json.from-json($text) if $engine-codec && !$immutable;
    jf-from-json($text, |%opt)
}

# The native serialiser handles one value and an optional :pretty, and hands
# back Nil for anything outside the ABI's vocabulary. Everything else —
# :sorted-keys, :spacing, a Date, an object with its own .Str — goes to
# JSON::Fast, whose exact output is the contract both paths have to honour.
#
# `($obj, *%opt)` rather than the `(|c)` this used to be: under Raku++ a single
# Array argument FLATTENS into a capture, so `to-json([1,2,3])` reached
# JSON::Fast as three arguments and serialised `1`. That is an interpreter bug
# and it is being fixed, but an explicit signature is the more honest spelling
# anyway — it says what this sub accepts — and it does not wait for the fix.
# A bare `$obj` is Any-constrained, which is deliberate: JSON::Fast's own
# parameter is too, so `to-json(Mu)` must be refused here exactly as it is
# there. Declaring `Mu $obj` would have been the more permissive-looking
# choice and would have made the native path answer "null" where JSON::Fast
# raises — a divergence invented by the fast path, which is the one thing it
# must never do.
our sub to-json($obj, *%opt) is export(:MANDATORY) {
    if &native-write && !(%opt.keys (-) <pretty>) {
        my $s = native-write($obj, |%opt);
        return $s if $s.defined;
    }
    jf-to-json($obj, |%opt)
}
