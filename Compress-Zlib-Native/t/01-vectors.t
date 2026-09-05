use Test;
use Compress::Zlib::Native;

# t/vectors/zlib.vec is the SHARED conformance file: this distribution's C, its
# Compress::Zlib fallback, and (when DATA-PLAN P4 lands) the engine's own zlib
# code are separate implementations by design, and one set of inputs neither
# side can weaken is what keeps them agreeing.
#
# Every stream in it was produced by real libz or the system gzip, never by us,
# so what these assertions check is INTEROPERABILITY, not self-consistency: a
# codec that agreed only with itself would pass a round-trip suite and still be
# useless.

my $vec = $*PROGRAM.parent.add('vectors/zlib.vec');
sub unhex(Str $h) { $h eq '-' ?? Buf.new !! Buf.new($h.comb(2).map({ :16($_) })) }
sub adverbs(Str $f) { $f eq 'gzip' ?? \(:gzip) !! ($f eq 'raw' ?? \(:raw) !! \()) }

my @lines = $vec.lines.grep({ $_ && !.starts-with('#') }).map(*.words);
my @I = @lines.grep(*.[0] eq 'I');
my @X = @lines.grep(*.[0] eq 'X');
my @C = @lines.grep(*.[0] eq 'C');
my @A = @lines.grep(*.[0] eq 'A');

diag "zlib-backend: {zlib-backend()}";
plan @I + @X + @C + @A + 1;

for @I -> ($, $fmt, $comp, $plain) {
    my $want = unhex($plain);
    my $got = uncompress(unhex($comp), |adverbs($fmt));
    is-deeply $got.list, $want.list,
       "$fmt stream of {$want.elems} B, produced elsewhere, inflates to its own input";
}

for @X -> ($, $fmt, $comp) {
    # An error, not a wrong answer and not a crash. Which message is not
    # asserted: on the fallback the message is Compress::Zlib's, and pinning it
    # would be pinning somebody else's prose.
    dies-ok { uncompress(unhex($comp), |adverbs($fmt)) },
        "a malformed $fmt stream ({unhex($comp).elems} B) is refused";
}

for @C -> ($, $want, $in) {
    is crc32(unhex($in)).fmt('%08x'), $want, "crc32 of {unhex($in).elems} B";
}
for @A -> ($, $want, $in) {
    is adler32(unhex($in)).fmt('%08x'), $want, "adler32 of {unhex($in).elems} B";
}

# A running checksum has to compose, or it cannot be fed a stream in pieces —
# which is the only reason the second argument exists.
{
    my $whole = 'the quick brown fox jumps over the lazy dog'.encode;
    my $a = $whole.subbuf(0, 20);
    my $b = $whole.subbuf(20);
    is crc32($b, crc32($a)), crc32($whole),
       'crc32 fed in two pieces equals crc32 of the whole';
}

done-testing;
