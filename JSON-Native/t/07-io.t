use Test;
use JSON::Native;
need JSON::Native::Raku;   # loaded, not imported: called by its full names

# from-json and from-jsonl READ an IO::Path, and read an IO::Handle to its end
# and leave it open for its owner — as CSV::Native's from-csv does. They used to
# take a path through Str() and parse its NAME, pointing the error at a letter
# of it (rakupp issue 267). Anything that is not IO still binds through Str().
# Each check runs through JSON::Native, on this engine's backend, and through
# JSON::Native::Raku directly.

my $dir = $*TMPDIR.add("json-native-io-{$*PID}");
$dir.mkdir;
my $doc   = $dir.add('doc.json');   $doc.spurt: '{"ok":true,"n":[1,2.5]}';
my $lines = $dir.add('doc.jsonl');  $lines.spurt: qq<1\r\n\n\{"a":[2]}\n>;
my $bad   = $dir.add('bad.json');   $bad.spurt: '[1,';
my $badl  = $dir.add('bad.jsonl');  $badl.spurt: "1\n[2,\n";
LEAVE { try .unlink for $doc, $lines, $bad, $badl; try $dir.rmdir }

my @impls =
    'JSON::Native'       => (&from-json, &from-jsonl),
    'JSON::Native::Raku' => (&JSON::Native::Raku::from-json, &JSON::Native::Raku::from-jsonl);

plan +@impls;

for @impls -> (:key($name), :value(($fj, $fl))) {
    subtest $name, {
        plan 13;
        is-deeply $fj($doc), {ok => True, n => [1, 2.5]}, 'from-json reads an IO::Path';
        my $h = $doc.open;
        is-deeply $fj($h), {ok => True, n => [1, 2.5]}, 'and an IO::Handle';
        ok $h.opened, 'leaving the handle open';
        $h.close;
        is-deeply $fj($doc, :immutable), Map.new((ok => True, n => (1, 2.5))), 'with :immutable';
        my $e = do { try $fj($bad); $! };
        ok $e.defined && !$e.message.contains('bad.json'), 'a bad file is refused for its contents, not its name';
        $h = $bad.open;
        ok (try $fj($h)) === Nil && $!.defined, 'and from a handle too';
        $h.close;

        is-deeply $fl($lines), [1, {a => [2]}], 'from-jsonl reads an IO::Path';
        $h = $lines.open;
        is-deeply $fl($h), [1, {a => [2]}], 'and an IO::Handle';
        ok $h.opened, 'leaving it open';
        $h.close;
        $h = $badl.open;
        $e = do { try $fl($h); $! };
        isa-ok $e, X::JSON::Native::Line, 'a refused line read from a handle is numbered';
        is $e.line, 2, 'on what the handle gave, not on an emptied handle';
        $h.close;

        is $fj(42), 42, 'anything else still binds through Str()';
        # mutsu's Str() binds Mu, as an empty text: so it was before this, too
        if $*RAKU.compiler.name eq 'mutsu' { skip 'mutsu binds Mu to Str()' }
        else { throws-like { $fj(Mu) }, Exception, message => /'$text'/, 'and Mu is still refused naming $text' }
    }
}
