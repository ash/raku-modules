use Test;

# The export protocol, and the cooperation with the **::Native distributions
# that keeps `use Data::Native; use Digest::Native;` compiling on Rakudo, where
# two modules exporting one name is a hard error rather than a shrug.
#
# Each case is a SEPARATE PROCESS, because what is being tested is what `use`
# does — at compile time, once, and not re-runnable inside a test that has
# already imported the module.

my $repo = $?FILE.IO.parent.parent.parent;
my @I = <Data-Native CSV-Native Digest-Native Compress-Zlib-Native JSON-Native>
        .map({ "-I" ~ $repo.add("$_/lib") });

sub run-raku(Str $code) {
    my $p = run($*EXECUTABLE, |@I, '-e', $code, :out, :err);
    ($p.exitcode, $p.out.slurp(:close).trim, $p.err.slurp(:close).trim)
}

# ---- the tag spelling ----------------------------------------------------

{
    my ($rc, $out, $) = run-raku('use Data::Native; say md5-hex("abc")');
    is $rc, 0, 'a bare use compiles';
    is $out, '900150983cd24fb0d6963f7d28e17f72', 'and imports every tag';
}
{
    my ($rc, $out, $) = run-raku(
        'use Data::Native <json digest>; say from-json("[1]")[0]; say md5-hex("abc")');
    is $rc, 0, 'two named tags compile';
    is $out.lines[0], '1', 'and the first is imported';
    is $out.lines[1], '900150983cd24fb0d6963f7d28e17f72', 'and so is the second';
}
{
    # A tag NOT asked for must not arrive. On Raku++ it does anyway, because a
    # module's own `use` of its dependencies is visible to whatever imports that
    # module — `compress` here comes from Compress::Zlib, which this module
    # delegates to. Rakudo confines it. Engine bug, filed, with its own repro.
    todo 'Raku++ leaks a module\'s own imports into the importer'
        if $*RAKU.compiler.name eq 'Raku++';
    my ($rc, $, $) = run-raku('use Data::Native <json>; compress("x".encode)');
    isnt $rc, 0, 'a tag that was not asked for is not imported';
}
{
    my ($rc, $out, $err) = run-raku('use Data::Native <crytpo>; say "reached"');
    ok ($err ~~ /'crytpo'/ or $out ~~ /'crytpo'/),
       'an unknown tag is reported, and names itself';
    ok ($err ~~ /'<json>'/ or $out ~~ /'<json>'/),
       'and the message lists the tags that do exist';
}
{
    # `:json` is Raku++-only: Rakudo routes `:tag` through the `is export(:tag)`
    # machinery, which a `sub EXPORT` module has no part in. The documented
    # spelling is `<json>`, and this pins that the docs are right rather than
    # that either engine is.
    my ($rc, $, $) = run-raku('use Data::Native :json; say from-json("[1]")[0]');
    if $*RAKU.compiler.name eq 'Raku++' {
        is $rc, 0, ':json happens to work on Raku++ — a divergence, not a promise';
    }
    else {
        isnt $rc, 0, ':json is refused on Rakudo, which is why the docs say <json>';
    }
}

# ---- every name arrives, or fails by name --------------------------------

{
    my @names = <
        from-json to-json from-csv to-csv
        md5 sha1 sha224 sha256 sha384 sha512
        md5-hex sha1-hex sha224-hex sha256-hex sha384-hex sha512-hex
        hmac hmac-hex
        compress uncompress gzslurp gzspurt crc32 adler32
        crypt_random_buf crypt_random crypt_random_uniform
        json-backend csv-backend digest-backend zlib-backend random-backend
    >;
    is @names.elems, 32, 'the tag table is twenty-seven functions and five backends';

    my $prog = 'use Data::Native; my @m = <' ~ @names.join(' ') ~ q[>.grep({ !::('&' ~ $_).defined }); say @m ?? 'MISSING ' ~ @m.join(' ') !! 'all present'];
    my ($rc, $out, $err) = run-raku($prog);
    is $rc, 0, 'a program can ask for all thirty-two names' or diag $err;
    is $out, 'all present', 'and every one of them is exported';
}

# ---- the cooperation protocol, all four cells ---------------------------

# All four distributions are on the protocol now, so all four families get the
# full table rather than only the two that were written with it.
my %CELLS =
    json   => ('JSON::Native',           'from-json("[7]")[0]',            '7'),
    csv    => ('CSV::Native',            'from-csv("a,b\n").elems',        '1'),
    digest => ('Digest::Native',         'md5-hex("abc")',
               '900150983cd24fb0d6963f7d28e17f72'),
    zlib   => ('Compress::Zlib::Native', 'crc32("123456789").fmt("%08x")', 'cbf43926');

for %CELLS.keys.sort -> $tag {
    my ($mod, $call, $want) = %CELLS{$tag};

    {
        my ($rc, $out, $err) = run-raku("use Data::Native; use $mod; say $call");
        is $rc, 0, "<$tag>: Data::Native then $mod — compiles" or diag $err;
        is $out, $want, "  and the value is the agreed one";
    }
    {
        my ($rc, $out, $err) = run-raku("use $mod; use Data::Native; say $call");
        is $rc, 0, "<$tag>: $mod then Data::Native — compiles" or diag $err;
        is $out, $want, "  and the value is the agreed one";
    }
}

# A claim is per TAG, so claiming one leaves the others alone. This is the case
# the plan singles out: `use Data::Native <csv>; use JSON::Native;` must give
# you the engine's CSV and JSON::Native's JSON.
{
    my ($rc, $out, $err) = run-raku(
        'use Data::Native <csv>; use JSON::Native; say from-json("[7]")[0]');
    is $rc, 0, 'claiming <csv> leaves JSON::Native free to export' or diag $err;
    is $out, '7', 'and it answers — the case the plan singles out';
}

done-testing;
