use lib $?FILE.IO.parent.parent.parent.add('CSV-Native/lib').Str;
use Test;
use Data::Native;

# Every tag, every name, on whichever backend this engine resolves to. The
# point is not that the answers are novel — each family has its own
# distribution with its own conformance vectors — but that ONE `use` line
# produces the same values on every engine, which is the whole claim.

# ---- json ----------------------------------------------------------------

{
    my $data = from-json('{"a": [1, 2.5, true, null], "b": "x"}');
    is $data<a>[0], 1,        'from-json: an integer token is an Int';
    is $data<a>[1], 2.5,      'and a decimal is exact';
    is $data<a>[1].WHAT.gist, Rat.gist, 'a Rat, not a Num — the reason to use Raku';
    is $data<a>[2], True,     'true is Bool';
    nok $data<a>[3].defined,  'null is undefined';
    is to-json({ a => 1 }, :!pretty), '{"a":1}', 'to-json round-trips a hash';
    is from-json(to-json($data))<b>, 'x', 'and the two compose';
}

# ---- csv -----------------------------------------------------------------

{
    my @rows = from-csv("name,score\nAda,9.5\nGrace,10\n");
    is @rows.elems, 3,          'from-csv reads every row including the header';
    is @rows[1][0], 'Ada',      'and the fields';
    is @rows[2][1], '10',       'as text, undecided about type';
    is to-csv([[<a b>], [<1 2>]]).lines[0], 'a,b', 'to-csv writes the header row';
    # Two ROWS, not one: an `@rows` parameter flattens a single nested array,
    # so a one-row call arrives as a row of loose fields.
    like to-csv([['has,comma', 'plain'], ['x', 'y']]), /'"has,comma"'/,
         'and quotes what needs it';
}

# ---- digest --------------------------------------------------------------

# One published vector per algorithm — the family's own distribution carries
# 156 of them, so what is being checked here is that this tag reaches a correct
# implementation at all, not that the implementation is correct.
{
    is md5-hex('abc'),    '900150983cd24fb0d6963f7d28e17f72', 'md5-hex of abc';
    is sha1-hex('abc'),   'a9993e364706816aba3e25717850c26c9cd0d89d', 'sha1-hex of abc';
    is sha224-hex('abc'), '23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7',
       'sha224-hex of abc';
    is sha256-hex('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
       'sha256-hex of abc';
    is sha384-hex('abc'), 'cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed'
                        ~ '8086072ba1e7cc2358baeca134c825a7', 'sha384-hex of abc';
    is sha512-hex('abc'), 'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a'
                        ~ '2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f',
       'sha512-hex of abc';

    ok sha256('abc') ~~ Blob, 'the bare name returns a Blob';
    is sha256('abc').list».fmt('%02x').join, sha256-hex('abc'),
       'and the same bytes as its -hex twin';

    # RFC 4231 case 1. The block size matters: absent, this tag uses the
    # algorithm's real one, so hmac(…, &sha512) is the RFC 2104 MAC rather than
    # Digest::HMAC's 64-byte default.
    my $key = Buf.new(0x0b xx 20);
    is hmac-hex($key, 'Hi There', &sha256),
       'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7',
       'hmac-hex over sha256, RFC 4231 case 1';
    is hmac-hex($key, 'Hi There', &sha512),
       '87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cde'
     ~ 'daa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854',
       'and over sha512, where the block length is 128 and not 64';
    ok hmac($key, 'Hi There', &sha256) ~~ Blob, 'hmac returns a Blob';
}

# ---- zlib ----------------------------------------------------------------

{
    my $data = ('some repeated content. ' x 200).encode;
    my $z = compress($data);
    ok $z ~~ Buf, 'compress returns a Buf';
    ok $z.elems < $data.elems, 'and it is smaller';
    is-deeply uncompress($z).list, $data.list, 'uncompress round-trips';

    my $g = compress($data, 6, :gzip);
    is $g[0] +| ($g[1] +< 8), 0x8b1f, ':gzip carries the gzip magic';
    is-deeply uncompress($g, :gzip).list, $data.list, 'and round-trips too';
    is-deeply uncompress(compress($data, 6, :raw), :raw).list, $data.list,
       ':raw round-trips';

    is crc32('123456789').fmt('%08x'), 'cbf43926', 'crc32, the published check string';
    is adler32('123456789').fmt('%08x'), '091e01de', 'adler32, likewise';

    my $tmp = $*TMPDIR.add("dn-{$*PID}.gz");
    LEAVE { $tmp.unlink if $tmp.e }
    gzspurt($tmp, "a line\nanother\n");
    is gzslurp($tmp), "a line\nanother\n", 'gzspurt and gzslurp are inverses';
}

# ---- random --------------------------------------------------------------

{
    my $b = crypt_random_buf(32);
    ok $b ~~ Blob && $b.elems == 32, 'crypt_random_buf returns the length asked for';
    isnt $b.list.join(','), crypt_random_buf(32).list.join(','),
       'and not the same bytes twice — which is the entire specification';
    ok crypt_random(4) ~~ Int, 'crypt_random returns an Int';
    my @u = (^200).map({ crypt_random_uniform(10) });
    ok @u.all ~~ 0..^10, 'crypt_random_uniform stays inside its bound';
    ok @u.unique.elems > 5, 'and covers the range rather than favouring one value';
}

# ---- the backends report themselves --------------------------------------

{
    my @answers = json-backend(), csv-backend(), digest-backend(),
                  zlib-backend(), random-backend();
    ok @answers.all ~~ Str, 'every *-backend sub answers with a Str';
    diag "backends: json={json-backend()} csv={csv-backend()} "
       ~ "digest={digest-backend()} zlib={zlib-backend()} random={random-backend()}";
}

done-testing;
