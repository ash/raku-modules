use Test;
use Rakupp::JSON;

# JSON::Fast's `from-json` is the oracle, but importing it at file scope would
# collide with the one under test. `use` is lexically scoped, so a block keeps
# it to itself and hands out a reference.
my &oracle;
{
    use JSON::Fast;
    &oracle = &from-json;
}

# The contract is not "parses JSON" but "parses JSON exactly as JSON::Fast
# does" — same values AND same Raku types — because the module is a drop-in
# whose fast path must be invisible. Every case is checked against JSON::Fast
# in the same run, on whichever engine is running, so the test is meaningful
# under the fallback too.
my @cases =
    '{}', '[]', '{"a":1}', '[1,2,3]', '"plain"', '0', '-0', '17', '-17',
    '1.5', '-1.5', '0.1', '1e3', '1E-3', '-2.5e+4',
    '123456789012345678901234567890',
    '1.000', '[{"a":[{"b":{}}]}]',
    '{"k":"v","j":null,"t":true,"f":false}',
    '"éA"', '"😀"',
    '"tab:\t nl:\n quote:\" back:\\\\ slash:\/"',
    '  {  "a"  :  [ 1 , 2 ]  }  ',
    '"日本語"', '[[[[[1]]]]]',
    '{"big":12345678901234567890,"neg":-0.0001}',
    '[0.1, 0.2, 0.3]';

plan @cases + 8;

for @cases -> $json {
    my $ours = from-json($json);
    my $fast = oracle($json);
    is-deeply $ours.raku, $fast.raku, "matches JSON::Fast: $json";
}

# Raku numerics rather than doubles — the property that makes a Raku JSON
# parser worth having.
is from-json('1.5')<>.WHAT.gist,  '(Rat)', 'a decimal is a Rat';
is from-json('17')<>.WHAT.gist,   '(Int)', 'an integer is an Int';
is from-json('1e3')<>.WHAT.gist,  '(Num)', 'an exponent form is a Num';
ok from-json('[0.1,0.2]').sum == 0.3, 'Rat arithmetic is exact';

# :immutable gives the immutable shapes
ok from-json('{"a":1}', :immutable) ~~ Map,  ':immutable gives a Map';
ok from-json('[1,2]',  :immutable) ~~ List,  ':immutable gives a List';

# Malformed input raises rather than returning junk
dies-ok { from-json('{"a":}') },   'a malformed object dies';
dies-ok { from-json('[1,2] junk') }, 'trailing content dies';

done-testing;
