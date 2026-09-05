use Test;
use Digest::Native;

# RFC 2202 (MD5, SHA-1) and RFC 4231 (SHA-224/256/384/512), read from the same
# shared vector file as the hashes, plus the two places this module is
# deliberately a superset of Digest::HMAC.

my $vec = $*PROGRAM.parent.add('vectors/digest.vec');

sub unspec(Str $spec) {
    return Buf.new if $spec eq '-';
    my ($h, $n) = $spec.split('*');
    my $once = Buf.new($h.comb(2).map({ :16($_) }));
    $n ?? ($once.decode('latin-1') x +$n).encode('latin-1') !! $once
}

my @M = $vec.lines.grep(*.starts-with('M ')).map(*.words[1..*]);
my %HASH = md5 => &md5, sha1 => &sha1, sha224 => &sha224,
           sha256 => &sha256, sha384 => &sha384, sha512 => &sha512;

plan 2 * @M + 8;

for @M -> ($algo, $bs, $kspec, $mspec, $want) {
    my $key = unspec($kspec);
    my $msg = unspec($mspec);
    my &h   = %HASH{$algo};
    my $label = "hmac-$algo, key {$key.elems}B, message {$msg.elems}B";

    # `$bs eq '-'` is the whole point of the file's third column: absent, this
    # module uses the algorithm's real block length, which is what RFC 2104
    # says and what openssl computed. Digest::HMAC would have used 64 here and
    # produced a different MAC for SHA-384 and SHA-512.
    if $bs eq '-' {
        is hmac-hex($key, $msg, &h), $want, "$label — hex";
        is hmac($key, $msg, &h).list».fmt('%02x').join, $want, "$label — blob";
    }
    else {
        is hmac-hex($key, $msg, &h, +$bs), $want, "$label, B=$bs — hex";
        is hmac($key, $msg, &h, +$bs).list».fmt('%02x').join, $want, "$label, B=$bs — blob";
    }
}

# ---- the superset, and the compatibility it does not break ----------------

# An explicit block size is honoured exactly as written. Digest::HMAC defaults
# every hash to 64, so `hmac($k, $m, &sha512, 64)` is how a caller reproduces
# it bit for bit — and Digest::HMAC itself is the oracle for that, which is why
# this case is here rather than in the openssl-generated file (openssl always
# uses the algorithm's own block size and cannot compute it).
{
    my (&ref-hmac, &ref-hmac-hex);
    { use Digest::HMAC; &ref-hmac = &hmac; &ref-hmac-hex = &hmac-hex; }

    my $key = Buf.new(0x0b xx 20);
    my $msg = 'Hi There'.encode;

    is hmac-hex($key, $msg, &sha512, 64), ref-hmac-hex($key, $msg, &sha512, 64),
       'an explicit block size reproduces Digest::HMAC exactly';
    isnt hmac-hex($key, $msg, &sha512), hmac-hex($key, $msg, &sha512, 64),
       'and it differs from the default, which is the RFC 2104 value';
    is hmac-hex($key, $msg, &sha256), ref-hmac-hex($key, $msg, &sha256),
       'where Digest::HMAC is already right, the two agree with no adverb at all';
}

# A Str key or message is UTF-8 here, where Digest::HMAC encodes ASCII and dies.
{
    my $k = 'ключ';
    my $m = 'сообщение';
    is hmac-hex($k, $m, &sha256),
       hmac-hex($k.encode('utf-8'), $m.encode('utf-8'), &sha256),
       'a Str key and message are their UTF-8, identical to passing the Blobs';
    ok hmac-hex($k, $m, &sha256).chars == 64, 'and it produces a digest rather than dying';
}

# HMAC is two calls to &hash, so a hash of your own keeps working — the native
# path is only ever taken for this module's own subs, recognised by identity.
{
    my $calls = 0;
    my &counted = sub ($in) { $calls++; sha256($in) };
    is hmac-hex('k', 'm', &counted, 64), hmac-hex('k', 'm', &sha256, 64),
       'a user-supplied &hash composes to the same MAC';
    is $calls, 2, 'and it was called exactly twice, which is all HMAC is';
}

# The key longer than the block is hashed first; the key shorter is zero-padded.
# Both are in the vector file above, but the boundary itself is worth naming.
{
    is hmac-hex(Buf.new(0xaa xx 64), 'x', &sha256),
       hmac-hex(Buf.new(0xaa xx 64), 'x', &sha256, 64),
       'a key exactly one block long is used as-is';
}

done-testing;
