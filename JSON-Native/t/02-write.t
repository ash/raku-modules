use Test;
use JSON::Native;

# Same shape as 01-parse.t, and the same reasoning: the contract is not "emits
# JSON" but "emits exactly what JSON::Fast emits", because programs already
# depend on that text — a diff in a fixture file, a signature over a payload, a
# golden test somewhere downstream. So JSON::Fast is the oracle here too, run on
# whichever engine is running, which keeps the test meaningful under the
# fallback and on Rakudo.
my &oracle;
{
    use JSON::Fast;
    &oracle = &to-json;
}

my @cases =
  # numerics: Int, Rat and Num each print differently, and a Num that looks
  # like an integer still has to come out as one ("2e0", not "2")
  42, -7, 0, 2**70, -(2**70), 3.14, 1/3, 2/3, 0.5, 7/2, 1.0, 100.0, -1.0, 22/7,
  1e10, 2.0e0, -0.0e0, -2.5e-8, 1e100, 1e-300, 0.1e0+0.2e0, 3.0e0, 1234567.0e0,
  Inf, -Inf, NaN,
  # strings: the escape table, including the two JSON::Fast does NOT name
  "plain", "", "quote\"back\\slash", "tab\ttab", "nl\nnl", "cr\rcr",
  "backspace\x[8]here", "formfeed\x[c]here", "ctrl\x[1]\x[1f]",
  "unicode é ☃ 高", "sol/idus", "del\x[7f]",
  True, False, Any,
  # containers, including the empty ones, which pretty-print oddly
  [], [1, 2, 3], [[1], [2]], [Any, True, "s"], [[[[1]]]],
  {}, {a => 1}, {b => [1, {c => 2}]}, {z => 1, a => 2, m => 3},
  {"k with space" => "v", "" => "empty key", "q\"k" => 1},
  {list => [1, 2.5, "three", True, Any], nested => {deep => {deeper => [{}]}}},
  [{a => 1}, {b => 2}],
  ;

for @cases -> $c {
    for (True, False) -> $pretty {
        is to-json($c, :$pretty), oracle($c, :$pretty),
           "matches JSON::Fast (:pretty($pretty)): {$c.raku}";
    }
}

# Types the native path does not claim: it must stand aside rather than guess,
# and the result still has to be JSON::Fast's.
for Date.new(2026, 8, 10), set(1, 2), bag(1, 1, 2) -> $odd {
    is to-json($odd, :!pretty), oracle($odd, :!pretty),
       "falls back correctly for {$odd.WHAT.^name}";
}

# And where JSON::Fast REFUSES, the fast path has to refuse identically —
# a native serialiser that quietly invented an encoding for a Range would be
# a worse bug than a slow one.
{
    my $ours = (try to-json((1..3), :!pretty)) // "THREW: {$!.message}";
    my $fast = (try oracle((1..3), :!pretty)) // "THREW: {$!.message}";
    is $ours, $fast, 'a Range fails the same way it fails under JSON::Fast';
}

# Options the native path does not implement go to JSON::Fast untouched.
is to-json({b => 1, a => 2}, :!pretty, :sorted-keys),
   oracle({b => 1, a => 2}, :!pretty, :sorted-keys),
   ':sorted-keys is delegated';

# Round trip, which is the property a user actually relies on.
#
# Compared as DATA, not as text, for anything with more than one key in an
# object: Raku++ iterates a hash in key order, Rakudo in an order it randomises
# per process, so `to-json` is free to emit `b` before `a` and a text comparison
# here would fail on Rakudo roughly half the time. (It did — this test passed
# twice and then failed, which is exactly how that kind of assertion announces
# itself.) The contract is that the values survive, not that the bytes do.
for '{"a":[1,2.5,true,null],"b":{"c":"d"}}', '{"z":1,"a":2}' -> $json {
    is-deeply from-json(to-json(from-json($json), :!pretty)), from-json($json),
              "round-trips $json";
}

# Where there is no ordering to disagree about, the bytes must survive too.
for '[]', '{}', '[[[]]]', '[1,2,3]', '{"only":1}', '"str"', '42' -> $json {
    is to-json(from-json($json), :!pretty), $json, "round-trips $json byte for byte";
}

# An Array argument must not flatten on its way in — `to-json([1,2,3])` gave
# `1` under Raku++ while this sub was declared `(|c)`, because a capture
# flattens a single Positional there.
is to-json([1, 2, 3], :!pretty), '[1,2,3]', 'an Array argument is one argument';

# A hash wide enough that the old O(i)-per-key walk would have been quadratic.
my %wide;
%wide{"key-{$_.fmt('%05d')}"} = $_ for ^5000;
is to-json(%wide, :!pretty), oracle(%wide, :!pretty), 'a 5,000-key hash matches';

done-testing;
