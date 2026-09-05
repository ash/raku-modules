use Test;
use Digest::Native;

# What may be digested, what may not, and the one mechanism in this
# distribution that had to be invented rather than looked up.

plan 23;

my $text  = "hello, мир\n";
my $bytes = $text.encode('utf-8');
my $want  = sha256-hex($bytes);

# ---- the four input types agree ------------------------------------------

is sha256-hex($text), $want, 'a Str is digested as its UTF-8';
is sha256-hex($bytes), $want, 'a Blob is digested as itself';
is sha256-hex(Buf.new($bytes.list)), $want, 'a Buf likewise';

my $tmp = $*TMPDIR.add("digest-native-{$*PID}.tmp");
LEAVE { $tmp.unlink if $tmp.e }
$tmp.spurt($text);

is sha256-hex($tmp), $want, 'an IO::Path is digested as its contents';
is sha256-hex($tmp.open(:bin)), $want, 'and so is an open IO::Handle';
is sha256($tmp).list».fmt('%02x').join, $want, 'the blob form takes a path too';

# The file path is STREAMED by the extension rather than slurped, so a large
# file costs a fixed 64 KB. Nothing here can observe memory, but it can observe
# that a file crossing several read chunks still hashes correctly, which is the
# part a chunked loop gets wrong.
{
    my $big = $*TMPDIR.add("digest-native-big-{$*PID}.tmp");
    LEAVE { $big.unlink if $big.e }
    my $blob = ('0123456789abcdef' x 20_000).encode;      # 320 KB, five chunks
    $big.spurt($blob);
    is sha256-hex($big), sha256-hex($blob),
       'a file larger than one read chunk hashes as its bytes';
}

# ---- the byte transport, pinned over its whole range ---------------------

# The extension ABI has no Blob, and rk_str DECODES the bytes it is given as
# UTF-8 — hand it a raw digest and md5('abc') comes back eleven characters
# long. So the C sends each output byte as the codepoint of the same number and
# the Raku half reads it back with latin-1. That scheme is only worth anything
# if every one of the 256 values survives it, and a digest is the wrong place
# to find out: this checks the range directly, by digesting inputs chosen so
# that the OUTPUT covers the awkward region.
{
    my $ok = True;
    my $mismatch;
    for ^256 -> $b {
        # Every byte value, on the input side.
        my $in = Buf.new($b, ($b + 1) % 256, ($b + 128) % 256);
        unless sha256($in).list».fmt('%02x').join eq sha256-hex($in) {
            $ok = False; $mismatch //= $b; last;
        }
    }
    ok $ok, 'blob and hex forms agree for inputs covering every byte value'
        or diag "first mismatch at byte $mismatch";
}
{
    # And on the output side: 256 different digests is enough that every byte
    # value appears many times over in the results.
    my $bad = (^256).first({ md5(Buf.new($_)).list».fmt('%02x').join ne md5-hex(Buf.new($_)) });
    ok !$bad.defined, 'blob and hex agree over 256 distinct digests'
        or diag "mismatch digesting byte $bad";
}

is sha256('').list.elems, 32, 'the empty input still produces a full digest';
is md5(Buf.new).list.elems, 16, 'and so does an empty Blob';

# ---- return types --------------------------------------------------------

# .^name is NOT asserted: blob8.new(…).^name is 'Blob' on Raku++ and
# 'Blob[uint8]' on Rakudo, a cosmetic the engines differ on. What the interface
# promises is a Blob whose elements are the digest bytes.
ok sha256('abc') ~~ Blob, 'the bare name returns a Blob';
ok sha256-hex('abc') ~~ Str, 'the -hex twin returns a Str';
is sha256-hex('abc'), sha256-hex('abc').lc, 'hex is lowercase, as the ecosystem spells it';
ok hmac(Buf.new(1), 'x', &sha256) ~~ Blob, 'hmac returns a Blob';
ok hmac-hex(Buf.new(1), 'x', &sha256) ~~ Str, 'hmac-hex returns a Str';

# ---- what is refused, and by name ----------------------------------------

throws-like { sha256(42) }, Exception,
    message => /'cannot digest'.*'Int'/,
    'an Int is refused by name rather than silently stringified';

throws-like { sha256(Any) }, Exception,
    message => /'cannot digest'/,
    'and so is an undefined value';

# :initial-hash is a Digest::SHA2 internal leaking through its signature.
# Refusing it silently would be the bad outcome; it is named in the error.
throws-like { sha256('abc', :initial-hash(Nil)) }, Exception,
    message => /':initial-hash'/,
    ':initial-hash is refused, and the message says so';

throws-like { sha512-hex('abc', :whatever) }, Exception,
    message => /':whatever'/,
    'an unknown adverb names itself too';

# ---- the backend reports itself honestly ---------------------------------

ok digest-backend() eq any(<native core Digest>),
   "digest-backend is one of the three documented answers (got {digest-backend()})";
ok digest-backend('sha1').chars > 0, 'digest-backend names the module behind one algorithm';
throws-like { digest-backend('sha3') }, Exception,
    'digest-backend refuses an algorithm this distribution does not cover';

done-testing;
