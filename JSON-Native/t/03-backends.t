use Test;
use JSON::Native;

# Which path answers is not observable in the results — that is what 01, 02
# and 04 check, on whichever backend this run has. What IS observable is
# which one was chosen, what JSON_NATIVE_BACKEND does to that, and whether the
# Raku implementation got loaded at all: on any other backend it should not
# be until a call needs it, which is why it is a module of its own, loaded by
# `require`.

diag "json-backend: {json-backend} (writes: {json-backend(:write)})";

plan 6;

my @names = <engine native nativecall json-fast raku>;
ok json-backend() eq any(@names) && json-backend(:write) eq any(@names),
   'json-backend names one of the paths, for parsing and for writing';

# Each probe runs in a fresh process, so nothing this file loaded counts. It
# asks the repository chain which compilation units are loaded, and failing
# that (an engine that does not list them) for the implementation's sub. A
# lookup of the PACKAGE name is no test: on Rakudo `::('JSON::Native::Raku')`
# finds the core class Raku once a JSON::Native package exists.
my $loaded-check = q[$*REPO.repo-chain.map({ (try .loaded) // () }).flat.map({ (try .short-name) // '' }).grep('JSON::Native::Raku').so || so try ::('&JSON::Native::Raku::from-json')];
sub probe(Str $calls, *%env) {
    my $code = "use JSON::Native; $calls; print json-backend, ' ', ($loaded-check)";
    my $p = run $*EXECUTABLE, '-Ilib', '-e', $code, :out, :err, :env(%(%*ENV, %env));
    ($p.out.slurp(:close).words, $p.err.slurp(:close))
}

{
    my (($backend, $loaded), $) = probe q[my $d = from-json('{"a":[1,2.5,"s",true,null]}')];
    if $backend eq 'raku' {
        is $loaded, 'True', 'on the raku backend, the first parse loads JSON::Native::Raku';
    }
    else {
        is $loaded, 'False', "on the $backend backend, a plain parse never loads JSON::Native::Raku";
    }
}

{
    my (($backend, $loaded), $) = probe q[my $d = try from-json('[1] trailing')];
    is $loaded, 'True', "a document the $backend backend refuses is answered by JSON::Native::Raku";
}

{
    my (($backend, $), $) = probe q[my $d = from-json('[1]')], JSON_NATIVE_BACKEND => 'raku';
    is $backend, 'raku', 'JSON_NATIVE_BACKEND chooses the backend';
}

{
    my (($backend, $), $err) = probe q[my $d = from-json('[1]')], JSON_NATIVE_BACKEND => 'no-such';
    ok $err.contains('JSON_NATIVE_BACKEND=no-such is not available') && $backend eq any(@names),
       'one that is not available is reported, and the usual order used';
}

# CI pins which backend a run exercised: a green suite on the wrong backend is
# the failure mode where the native path is never tested at all.
with %*ENV<JSON_NATIVE_REQUIRE_BACKEND> -> $want {
    is json-backend, $want, "backend is $want (JSON_NATIVE_REQUIRE_BACKEND)";
}
else {
    skip 'JSON_NATIVE_REQUIRE_BACKEND is not set', 1;
}
