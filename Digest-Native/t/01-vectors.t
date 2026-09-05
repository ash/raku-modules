use Test;
use Digest::Native;

# t/vectors/digest.vec is the SHARED conformance file: this module's C, its
# ecosystem fallback and (when DATA-PLAN P3 lands) the engine's own digest code
# are separate implementations by design, and one set of inputs neither side
# can weaken is what keeps them agreeing. It was generated from the system
# openssl, never from our own code — see tools/gen-vectors.raku.

my $vec = $*PROGRAM.parent.add('vectors/digest.vec');

# Repeated inputs are written <hex>*<count>; latin-1 is byte-for-byte both
# ways, so building a million-byte message costs a C-level string repeat.
sub unspec(Str $spec) {
    return Buf.new if $spec eq '-';
    my ($h, $n) = $spec.split('*');
    my $once = Buf.new($h.comb(2).map({ :16($_) }));
    $n ?? ($once.decode('latin-1') x +$n).encode('latin-1') !! $once
}

my @H = $vec.lines.grep(*.starts-with('H ')).map(*.words[1..*]);

# The million-byte vectors go through the pure-Raku Digest::SHA2 in fallback
# mode, which runs at about 0.04 MB/s on Raku++ — half a minute for one line.
# They are the multi-block-plus-length case, and the 127/128/129-byte vectors
# cover that too, so they are skipped where they would only measure a
# dependency's speed. Nothing is skipped on the backend this module ships.
my $native = digest-backend() eq 'native';
my $LIMIT  = $native ?? Inf !! 100_000;

diag "digest-backend: {digest-backend()}";

my @run = @H.grep({ .[1].contains('*') ?? +(.[1].split('*')[1]) <= $LIMIT !! True });
diag "vectors: {+@run} of {+@H}" if @run != @H;

plan 2 * @run;

for @run -> ($algo, $spec, $want) {
    my $in = unspec($spec);
    my $label = "$algo of " ~ ($spec.chars > 24 ?? $spec.substr(0, 21) ~ '…' !! $spec);

    is ::("\&{$algo}-hex")($in), $want, "$label — hex";

    # The bare name is the same digest as a blob8, so it is checked against the
    # same expected bytes rather than against its own hex twin: two spellings
    # agreeing with each other proves nothing if both are wrong.
    is ::("\&$algo")($in).list».fmt('%02x').join, $want, "$label — blob";
}

done-testing;
