use Test;
use JSON::Native;

# Which path answers is not observable in the results — that is what 01, 02
# and 04 check, on whichever backend this run has. What IS observable is
# which one was chosen, what JSON_NATIVE_BACKEND does to that, and whether the
# Raku implementation got loaded at all: on any other backend it should not
# be until a call needs it, which is why it is a module of its own, loaded by
# `require`.

diag "json-backend: {json-backend} (writes: {json-backend(:write)})";

plan 7;

my @names = <engine rakudo json-fast raku>;
ok json-backend() eq any(@names) && json-backend(:write) eq any(@names),
   'json-backend names one of the paths, for parsing and for writing';

# Each probe runs in a fresh process, so nothing this file loaded counts. It
# asks the repository chain which compilation units are loaded, and failing
# that (an engine that does not list them) for the implementation's sub. A
# lookup of the PACKAGE name is no test: on Rakudo `::('JSON::Native::Raku')`
# finds the core class Raku once a JSON::Native package exists.
my $loaded-check = q[$*REPO.repo-chain.map({ (try .loaded) // () }).flat.map({ (try .short-name) // '' }).grep('JSON::Native::Raku').so || so try ::('&JSON::Native::Raku::from-json')];
# Answers backend, loaded and stderr as one flat list, read by index: a
# nested destructuring `my (($a, $b), $c) = …` is not unpacked on mutsu.
sub probe(Str $calls, *%env) {
    my $code = "use JSON::Native; $calls; print json-backend, ' ', ($loaded-check)";
    my $p = run $*EXECUTABLE, '-Ilib', '-e', $code, :out, :err, :env(%(%*ENV, %env));
    my @w = $p.out.slurp(:close).words;
    (@w[0] // '', @w[1] // '', $p.err.slurp(:close))
}

{
    my @r = probe q[my $d = from-json('{"a":[1,2.5,"s",true,null]}')];
    my ($backend, $loaded) = @r[0], @r[1];
    if $backend eq 'raku' {
        is $loaded, 'True', 'on the raku backend, the first parse loads JSON::Native::Raku';
    }
    else {
        is $loaded, 'False', "on the $backend backend, a plain parse never loads JSON::Native::Raku";
    }
}

{
    my @r = probe q[my $d = try from-json('[1] trailing')];
    my ($backend, $loaded) = @r[0], @r[1];
    is $loaded, 'True', "a document the $backend backend refuses is answered by JSON::Native::Raku";
}

{
    my $backend = (probe q[my $d = from-json('[1]')], JSON_NATIVE_BACKEND => 'raku')[0];
    is $backend, 'raku', 'JSON_NATIVE_BACKEND chooses the backend';
}

{
    my @r = probe q[my $d = from-json('[1]')], JSON_NATIVE_BACKEND => 'no-such';
    my ($backend, $err) = @r[0], @r[2];
    ok $err.contains('JSON_NATIVE_BACKEND=no-such is not available') && $backend eq any(@names),
       'one that is not available is reported, and the usual order used';
}

# Loading a module at run time must not touch what `use` handed out: mutsu's
# `require` imports what it loads into the program (2026.07), and once put
# JSON::Fast's from-json over this module's after the first call that loaded it.
{
    my $p = run $*EXECUTABLE, '-Ilib', '-e', q:to/CODE/, :out, :err;
        use JSON::Native;
        my &mine = &from-json;
        my $a = try from-json('[1] trailing');   # loads the Raku implementation
        my $b = to-json(Date.new(2026, 10, 13));  # and whatever writes a Date
        print &from-json === &mine ?? 'same' !! 'replaced';
        CODE
    is $p.out.slurp(:close), 'same', 'loading a fallback leaves the imported from-json in place';
}

# CI pins which backend a run exercised: a green suite on the wrong backend is
# the failure mode where the native path is never tested at all.
with %*ENV<JSON_NATIVE_REQUIRE_BACKEND> -> $want {
    is json-backend, $want, "backend is $want (JSON_NATIVE_REQUIRE_BACKEND)";
}
else {
    skip 'JSON_NATIVE_REQUIRE_BACKEND is not set', 1;
}
