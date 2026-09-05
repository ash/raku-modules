use Test;
use Compress::Zlib::Native;

# The interface, and every place this module is deliberately more than the one
# it stands in for.

my @corpus =
    ''                                                        => 'empty',
    'x'                                                       => 'one byte',
    'hello world'                                             => 'short',
    ('ab' x 20000)                                            => 'a long two-byte run',
    ("\c[0]" x 50000)                                         => 'fifty thousand NULs',
    ('The quick brown fox jumps over the lazy dog. ' x 1000)  => 'repeated prose',
    (^30000).map({ (($_ * 2654435761) % 251).chr }).join      => 'near-incompressible',
    'héllo wörld — ünïcode ✓'                                 => 'multi-byte UTF-8',
    ;

my @framings = 'zlib' => \(), 'gzip' => \(:gzip), 'raw' => \(:raw);

diag "zlib-backend: {zlib-backend()}";

# ---- round trips ---------------------------------------------------------

for @corpus -> $c {
    my $blob = $c.key.encode('utf-8');
    for @framings -> $f {
        my $z = compress($blob, 6, |$f.value);
        ok $z ~~ Buf, "compress returns a Buf — {$f.key}, {$c.value}";
        is-deeply uncompress($z, |$f.value).list, $blob.list,
            "round trip — {$f.key}, {$c.value} ({$blob.elems} B)";
    }
}

# Every level is accepted and every level round-trips. -1 is zlib's "default",
# 0 is "store it", and 9 is "try hardest"; all three are real code paths here.
for @corpus -> $c {
    my $blob = $c.key.encode('utf-8');
    my $all-ok = True;
    for -1, 0, 1, 5, 9 -> $level {
        $all-ok &&= uncompress(compress($blob, $level)).list eqv $blob.list;
    }
    ok $all-ok, "every level from -1 to 9 round-trips — {$c.value}";
}

# ---- the reference's contract --------------------------------------------

{
    my $blob = ('data ' x 100).encode;
    is compress($blob).WHAT.gist, Buf.gist, 'compress defaults to the zlib framing and a Buf';
    ok compress($blob).elems < $blob.elems, 'and it actually compresses';
    throws-like { compress($blob, 10) }, Exception,
        message => /'between -1 and 9'/, 'a level above 9 dies, as the reference does';
    throws-like { compress($blob, -2) }, Exception,
        message => /'between -1 and 9'/, 'and so does a level below -1';
    # Through a reference, so the binding failure happens at RUN time on both
    # engines. Called directly, Rakudo refuses to compile the file at all —
    # which is the better outcome and not one a test can assert from inside.
    my $c = &compress;
    dies-ok { $c('a plain Str') },
        'compress wants a Blob, exactly as the reference declares it';
}

# ---- the superset --------------------------------------------------------

{
    my $blob = ('mixed content, some of it repeated. ' x 50).encode;

    # Different framings are different bytes but the same payload, and a stream
    # read with the wrong framing must fail rather than return nonsense.
    my $z = compress($blob);
    my $g = compress($blob, 6, :gzip);
    my $r = compress($blob, 6, :raw);
    isnt $z.list.join(','), $g.list.join(','), ':gzip produces a different stream from :zlib';
    is $g[0], 0x1f, 'a gzip stream starts with 1f';
    is $g[1], 0x8b, 'and 8b';
    is $z[0], 0x78, 'a zlib stream starts with a 0x78 CMF';
    ok ($z[0] * 256 + $z[1]) %% 31, 'and its header check word is a multiple of 31';
    # Against gzip rather than against zlib. On the fallback the default zlib
    # path goes through libz's one-shot compress2 while the two adverbs go
    # through its Stream class, which flushes as it goes and can therefore come
    # out larger; :raw against :gzip compares two streams made the same way and
    # differing only by the eighteen bytes of wrapper.
    ok $r.elems < $g.elems, 'the raw framing is smaller than gzip, having no wrapper';

    dies-ok { uncompress($g) }, 'a gzip stream read as zlib is refused';
    dies-ok { uncompress($z, :gzip) }, 'a zlib stream read as gzip is refused';

    throws-like { compress($blob, 6, :gzip, :raw) }, Exception,
        message => /':gzip or :raw'/, ':gzip and :raw together are refused';
    throws-like { compress($blob, 6, :zlib) }, Exception,
        message => /':zlib'/, 'an adverb this module does not have names itself';
}

# ---- the file wrappers ---------------------------------------------------

{
    my $tmp = $*TMPDIR.add("czn-{$*PID}.gz");
    LEAVE { $tmp.unlink if $tmp.e }
    my $text = "a line\nanother line\nunicode: ✓\n" x 200;

    gzspurt($tmp, $text);
    ok $tmp.e && $tmp.s > 0, 'gzspurt writes a file';
    ok $tmp.s < $text.encode.elems, 'and it is smaller than the text';
    is gzslurp($tmp), $text, 'gzslurp reads it back as text';
    is-deeply gzslurp($tmp, :bin).list, $text.encode('utf-8').list,
        'and :bin reads it back as bytes';

    # The file must be a real gzip file, not merely one we can read.
    my $raw = $tmp.slurp(:bin);
    is $raw[0] +| ($raw[1] +< 8), 0x8b1f, 'the file on disk carries the gzip magic';
}

done-testing;
