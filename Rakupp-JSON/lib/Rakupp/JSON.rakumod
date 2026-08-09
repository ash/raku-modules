=begin pod

=head1 Rakupp::JSON

A JSON parser with a native fast path on Raku++, and JSON::Fast everywhere else.

The XS pattern: the distribution ships C source, the build step compiles it
against Raku++'s extension ABI, and the module uses it when it is there. On
Rakudo — or on a Raku++ that could not build the extension — nothing breaks, it
simply calls C<JSON::Fast>. The same program runs on both.

=head2 Why it exists

Raku++ interprets an AST rather than JIT-compiling, so a tokenizer written in
Raku costs it about 12x what Rakudo pays. Parsing JSON is exactly that shape of
work. Rather than make the interpreter pretend to be faster, this moves the
parse into C:

    278 KB document      Rakudo JSON::Fast   36 ms
                         Raku++ JSON::Fast  ~440 ms
                         Rakupp::JSON       ~2.7 ms

=head2 Synopsis

    use Rakupp::JSON;

    my $data = from-json('{"a": [1, 2.5, true, null]}');
    say $data<a>[1].WHAT;        # (Rat) — Raku numerics, not doubles
    say to-json($data, :!pretty);

    say Rakupp::JSON::json-native;     # True when the compiled parser is in use

=head2 Compatibility

C<from-json> returns what C<JSON::Fast> returns, checked value by value: Int for
integer tokens (arbitrary precision), Rat for decimals, Num for exponent forms,
Bool, Any for null, Hash and Array — or Map and List under C<:immutable>.

C<to-json> is C<JSON::Fast>'s, on both engines. Serialising has to walk a hash,
and ABI v1 offers only index-based hash access; until it grows a cursor there is
nothing to gain by reimplementing it, and a serializer's exact output is a
contract worth not disturbing.

=end pod

unit module Rakupp::JSON;

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
my &ext-load = try &::('rakupp-ext-load');
my &native-parse;

sub load-native(--> Bool) {
    return False unless &ext-load;
    for libraries() -> $lib {
        next unless $lib.IO.e;
        my $ok = try ext-load($lib.Str);
        next unless $ok;
        # The loader installs the extension's subs into THIS scope.
        &native-parse = try &::('from-json-native');
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

# Which parser is in use: 'native' (the compiled extension) or 'JSON::Fast'.
our sub json-backend() is export(:MANDATORY) { $is-native ?? 'native' !! 'JSON::Fast' }

our sub from-json(Str() $text, :$immutable) is export(:MANDATORY) {
    $is-native
      ?? native-parse($text, :$immutable)
      !! jf-from-json($text, :$immutable)
}

our sub to-json(|c) is export(:MANDATORY) { jf-to-json(|c) }
