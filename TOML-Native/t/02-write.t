use Test;
use TOML::Native;

# The writer is Raku only (notes/TOML-Native.md says why), so there is no
# second implementation to agree with here. What the file holds instead:
# golden text for every case — the output is deterministic, sorted keys, the
# same on both engines — and round trips, which on Raku++ with the extension
# read the text back through the native parser.

my $native = toml-backend() eq 'native';
diag "toml-backend: {toml-backend}";

my constant LDT = TOML::Native::LocalDateTime;
my constant LT  = TOML::Native::LocalTime;

class Opaque { }

my @cases = (
    # data                                              expected                                            description
    [{},                                                '',                                                 'no keys is no text'],
    [{a => 1, b => 'x'},                                "a = 1\nb = \"x\"\n",                               'plain keys'],
    [{b => 1, a => 2, c => 3},                          "a = 2\nb = 1\nc = 3\n",                            'keys are sorted'],
    [{'a b' => 1, '' => 2, 'é' => 3, 'a-b_1' => 4},     "\"\" = 2\n\"a b\" = 1\na-b_1 = 4\n\"é\" = 3\n",    'keys are quoted only when not bare'],
    [{s => "q\"b\\t\tn\nr\r\x[1]\x[7F]é😀"},             "s = \"q\\\"b\\\\t\\tn\\nr\\r\\u0001\\u007Fé😀\"\n", 'string escapes'],
    [{s => "a\r\nb"},                                   "s = \"a\\r\\nb\"\n",                               'CRLF in a string is escaped'],
    [{s => ''},                                         "s = \"\"\n",                                       'the empty string'],
    [{n => -42, z => 0},                                "n = -42\nz = 0\n",                                 'integers'],
    [{n => 9223372036854775807},                        "n = 9223372036854775807\n",                        'the largest int64'],
    [{t => True, f => False},                           "f = false\nt = true\n",                            'booleans'],
    [{f => 1e0, g => 1.5e0, h => -0e0},                 "f = 1.0\ng = 1.5\nh = -0.0\n",                     'a float always reads back as a float'],
    [{f => Inf, g => -Inf, h => NaN},                   "f = inf\ng = -inf\nh = nan\n",                     'inf and nan'],
    [{f => 1e20, g => 6.626e-34},                       "f = 1e+20\ng = 6.626e-34\n",                       'exponents'],
    [{f => 5e-324, g => 1e-310},                        "f = 5e-324\ng = 1e-310\n",                         'subnormals, in their shortest form'],
    [{r => 0.5, s => 1/3},                              "r = 0.5\ns = 0.3333333333333333\n",                'a Rat is written as a float'],
    [{d => DateTime.new(1979, 5, 27, 7, 32, 0, :timezone(-25200))}, "d = 1979-05-27T07:32:00-07:00\n",     'an offset date-time'],
    [{d => DateTime.new(1979, 5, 27, 7, 32, 0.5, :timezone(0))},    "d = 1979-05-27T07:32:00.5Z\n",        'UTC, with a fraction'],
    [{d => DateTime.new(1979, 5, 27, 7, 32, 0, :timezone(19800))},  "d = 1979-05-27T07:32:00+05:30\n",     'a half-hour offset'],
    [{d => LDT.new(1979, 5, 27, 7, 32, 0)},             "d = 1979-05-27T07:32:00\n",                        'a local date-time'],
    [{d => Date.new(1979, 5, 27)},                      "d = 1979-05-27\n",                                 'a local date'],
    [{t => LT.new(:hour(7), :minute(32), :second(1.25))}, "t = 07:32:01.25\n",                              'a local time'],
    [{a => [1, 2, 3]},                                  "a = [1, 2, 3]\n",                                  'an array'],
    [{a => []},                                         "a = []\n",                                         'an empty array'],
    [{a => [[1, 2], ['x']]},                            "a = [[1, 2], [\"x\"]]\n",                          'nested arrays'],
    [{a => (1, 'two').List},                            "a = [1, \"two\"]\n",                               'a List is an array'],
    [{a => [1, {x => 1, y => {z => 2}}]},               "a = [1, \{ x = 1, y = \{ z = 2 } }]\n",            'a hash among other values is an inline table'],
    [{a => [{}, 1]},                                    "a = [\{}, 1]\n",                                   'an empty inline table'],
    [{t => {a => 1}},                                   "[t]\na = 1\n",                                     'a table'],
    [{t => {}},                                         "[t]\n",                                            'an empty table keeps its header'],
    [{z => 1, t => {a => 1}},                           "z = 1\n\n[t]\na = 1\n",                            'plain keys come before tables'],
    [{a => {b => {c => 1}}},                            "[a.b]\nc = 1\n",                                   'a table of only tables needs no header'],
    [{'a b' => {'c.d' => {e => 1}}},                    "[\"a b\".\"c.d\"]\ne = 1\n",                       'quoted keys in a header'],
    [{p => [{x => 1}, {x => 2}]},                       "[[p]]\nx = 1\n\n[[p]]\nx = 2\n",                   'an array of tables'],
    [{p => [{}, {}]},                                   "[[p]]\n\n[[p]]\n",                                 'empty elements keep their headers'],
    [{p => [{s => {k => 1}, n => 1},]},                  "[[p]]\nn = 1\n\n[p.s]\nk = 1\n",                   'a table inside an element'],
    [{a => [{x => 1},], b => {y => 1}, c => 1},          "c = 1\n\n[b]\ny = 1\n\n[[a]]\nx = 1\n",            'plain keys, then tables, then arrays of tables'],
    [Map.new((a => 1, b => Map.new((c => 2)))),         "a = 1\n\n[b]\nc = 2\n",                            'a Map is a table'],
);

my @errors = (
    # data                                              message
    [{a => Any},                                        "cannot write an undefined value for 'a'"],
    [{a => {b => Str}},                                 "cannot write an undefined value for 'a.b'"],
    [{a => [1, Any]},                                   "cannot write an undefined value for 'a'"],
    [{a => 2**63},                                      "integer out of range for 'a'"],
    [{a => -2**63 - 1},                                 "integer out of range for 'a'"],
    [{a => Opaque.new},                                 "cannot write a value of type Opaque for 'a'"],
    [{a => Buf.new(1, 2)},                              "cannot write a value of type Buf for 'a'"],
    [{d => Date.new(10000, 1, 1)},                      "year 10000 cannot be written for 'd'"],
);

# Round trips: what to-toml writes, from-toml reads back as the same data —
# every value type, nested every way the format allows.
my %everything =
    str => "multi\nline \"quoted\" é \x[1]",
    int => -9223372036854775808,
    hex => 255,
    flt => 3.141592653589793e0,
    exp => 6.02214076e23,
    tiny => 5e-324,
    inf => -Inf,
    bool => True,
    odt => DateTime.new(1979, 5, 27, 0, 32, 0.999999, :timezone(-25200)),
    ldt => LDT.new(1979, 5, 27, 7, 32, 0.5),
    ld => Date.new(2000, 2, 29),
    lt => LT.new(:hour(23), :minute(59), :second(59.123456789)),
    arr => [1, 'a', [2.5e0, [True]], {k => 'v', n => {m => []}}],
    tbl => {'quoted key' => 1, sub => {deeper => {deepest => 'x'}}, empty => {}},
    aot => [{a => 1, s => {t => 2}}, {}, {b => [{c => 3},]}],
    'dotted.key' => {x => 1};

plan @cases + @errors + 7 + ($native ?? 1 !! 0) + (%*ENV<TOML_NATIVE_REQUIRE_BACKEND> ?? 1 !! 0);

for @cases -> [$data, $want, $desc] {
    is to-toml($data), $want, $desc;
}
for @errors -> [$data, $msg] {
    my $got = (try to-toml($data)) // "THREW: {$!.message}";
    is $got, "THREW: TOML::Native: $msg", $msg;
}

is-deeply from-toml(to-toml(%everything)), %everything, 'every type round-trips';
is to-toml(from-toml(to-toml(%everything))), to-toml(%everything), 'and the text is a fixed point';
{
    my %h;
    my $cur = %h;
    $cur = $cur<a> = {} for ^130;
    my $got = (try to-toml(%h)) // $!.message;
    ok $got.starts-with('TOML::Native: nesting deeper than 128 levels'), 'nesting deeper than 128 levels is refused';
}
{
    my %big = (^2000).map({ "k$_" => %(n => $_, list => [$_, "$_"], when => Date.new(2000, 1, 1) + $_) });
    my %doc = packages => [(^1000).map({ %(name => "p$_", deps => [(^3).map({ "d$_" })]) })], tables => %big;
    is-deeply from-toml(to-toml(%doc)), %doc, 'a large document round-trips';
}
{
    # the order is the sorted one whatever the hash's own order: Rakudo
    # randomises it per process, so this is the check that output is stable
    my %a = (^50).map({ "k$_" => $_ });
    my %b = (^50).reverse.map({ "k$_" => $_ });
    is to-toml(%a), to-toml(%b), 'output does not depend on insertion order';
}
is to-toml({s => "e\x[301]"}), "s = \"é\"\n", 'text is written as Raku holds it, composed';
is-deeply from-toml(to-toml({"k\x[0]" => "v\x[0]"})), {"k\x[0]" => "v\x[0]"}, 'a NUL in a key and a value';

# On Raku++ with the extension, the round trip above went through the native
# parser; the Raku one must read the same text the same way.
if $native {
    is-deeply TOML::Native::parse-raku(to-toml(%everything)), from-toml(to-toml(%everything)),
              'raku agrees on the round trip';
}

# CI pins which backend a run exercised: a green suite on the wrong backend is
# the failure mode where the native path is never tested at all.
with %*ENV<TOML_NATIVE_REQUIRE_BACKEND> -> $want {
    is toml-backend, $want, "backend is $want (TOML_NATIVE_REQUIRE_BACKEND)";
}

done-testing;
