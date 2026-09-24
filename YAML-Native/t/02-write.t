use Test;
use YAML::Native;

# The writer is Raku only (notes/YAML-Native.md says why), so there is no
# second implementation to agree with here. What the file holds instead:
# golden text for every case — the output is deterministic, sorted keys, one
# layout, the same on both engines — and round trips, which on Raku++ with the
# extension read the text back through the native parser.

my $native = yaml-backend() eq 'native';
diag "yaml-backend: {yaml-backend}";

class Opaque { }

my @cases = (
    # data                                              expected                                              description
    [{},                                                "\{}\n",                                              'an empty mapping'],
    [[],                                                "[]\n",                                               'an empty sequence'],
    [{b => 1, a => 'x'},                                "a: x\nb: 1\n",                                       'keys are sorted'],
    [[1, 'two', 3],                                     "- 1\n- two\n- 3\n",                                  'a sequence'],
    [{a => {b => {c => 1}}},                            "a:\n  b:\n    c: 1\n",                               'nested mappings'],
    [{a => [1, 2]},                                     "a:\n  - 1\n  - 2\n",                                 'a sequence in a mapping'],
    [[{a => 1, b => 2}, {c => 3}],                      "- a: 1\n  b: 2\n- c: 3\n",                           'mappings in a sequence, compact'],
    [[[1, 2], [3,]],                                    "- - 1\n  - 2\n- - 3\n",                              'sequences in a sequence, compact'],
    [{a => {}, b => [], c => [{},]},                    "a: \{}\nb: []\nc:\n  - \{}\n",                       'empty collections inside'],
    [{n => Any, t => True, f => False},                 "f: false\nn: null\nt: true\n",                       'null and booleans'],
    [{i => -42, z => 0, big => 2 ** 70},                "big: 1180591620717411303424\ni: -42\nz: 0\n",        'integers'],
    [{f => 1e0, g => 1.5e0, h => -0e0},                 "f: 1.0\ng: 1.5\nh: -0.0\n",                          'a float always reads back as a float'],
    [{f => Inf, g => -Inf, h => NaN},                   "f: .inf\ng: -.inf\nh: .nan\n",                       'infinities and NaN'],
    [{f => 1e20, g => 6.626e-34},                       "f: 1e+20\ng: 6.626e-34\n",                           'exponents'],
    [{r => 0.5, s => 1/3},                              "r: 0.5\ns: 0.3333333333333333\n",                    'a Rat is written as a float'],
    [{d => Date.new(2026, 9, 24)},                      "d: 2026-09-24\n",                                    'a Date is its text'],
    # -- strings
    [{s => 'plain words, and more'},                    "s: plain words, and more\n",                         'plain when it reads back the same'],
    [{s => ''},                                         "s: \"\"\n",                                          'the empty string'],
    [{a => 'true', b => 'null', c => '42', d => '1.5', e => '0x1F', f => '~'},
     "a: \"true\"\nb: \"null\"\nc: \"42\"\nd: \"1.5\"\ne: \"0x1F\"\nf: \"~\"\n",                                'strings that would read as other types'],
    [{a => 'yes', b => 'No', c => '1_000'},             "a: yes\nb: No\nc: 1_000\n",                          'YAML 1.1 forms are plain'],
    [{a => 'k: v', b => 'x #y', c => 'end:', d => '- x', e => '[x]', f => '&a', g => ' lead', h => 'trail '},
     "a: \"k: v\"\nb: \"x #y\"\nc: \"end:\"\nd: \"- x\"\ne: \"[x]\"\nf: \"&a\"\ng: \" lead\"\nh: \"trail \"\n",   'indicators and edge spaces are quoted'],
    [{a => 'x:y', b => 'x#y', c => 'http://a/b?c'},     "a: x:y\nb: x#y\nc: http://a/b?c\n",                  'a colon or # inside a word is plain'],
    [{s => "q\"b\\t\tc\x[0]\x[7F]\x[85]\x[2028]"},      "s: \"q\\\"b\\\\t\\tc\\0\\x7F\\N\\L\"\n",             'escapes'],
    [{s => "a\r\nb"},                                   "s: \"a\\r\\nb\"\n",                                  'CRLF in a string is escaped'],
    [{s => "é 日本 😀"},                                 "s: é 日本 😀\n",                                      'non-ASCII text stays as it is'],
    # -- block scalars
    [{s => "line 1\nline 2\n"},                         "s: |\n  line 1\n  line 2\n",                         'a string with line breaks is a literal block'],
    [{s => "no final break"~"\nx"},                     "s: |-\n  no final break\n  x\n",                     '... stripped when it has no final break'],
    [{s => "x\n\n\n"},                                  "s: |+\n  x\n\n\n",                                   '... kept when it has several'],
    [{s => "  indented\nnot\n"},                        "s: |2\n    indented\n  not\n",                       '... with its indentation given when it starts with a space'],
    [{s => "\n\n  x\n"},                                "s: |2\n\n\n    x\n",                                 '... also after empty lines'],
    [["a\nb\n"],                                        "- |\n  a\n  b\n",                                    '... in a sequence'],
    ["top\nlevel\n",                                    "|\n top\n level\n",                                  '... at the top'],
    [{s => "\n\n"},                                     "s: \"\\n\\n\"\n",                                    'only line breaks is quoted'],
    [{s => "a\x[1]\nb"},                                "s: \"a\\x01\\nb\"\n",                                'a control character is quoted, even with line breaks'],
    # -- keys
    [{'a b' => 1, '' => 2, 'é' => 3, 'k: v' => 4, '1' => 5, 'true' => 6},
     "\"\": 2\n\"1\": 5\na b: 1\n\"k: v\": 4\n\"true\": 6\né: 3\n",                                              'keys are quoted only when they must be'],
    [{'<<' => 1},                                       "\"<<\": 1\n",                                        'a key of << is quoted, or it would merge'],
    [{"a\nb" => 1},                                     "\"a\\nb\": 1\n",                                     'a key with a line break'],
    # -- scalars at the top
    [42,                                                "42\n",                                               'a top-level integer'],
    ['text',                                            "text\n",                                             'a top-level string'],
    [Any,                                               "null\n",                                             'a top-level null'],
);

my @errors = (
    # data                                              message
    [{a => Opaque.new},                                 'cannot write a value of type Opaque'],
    [{a => Blob.new(1, 2)},                             'cannot write a value of type Blob'],
);

plan @cases + @cases + @errors + 6 + ($native ?? 2 !! 0) + (%*ENV<YAML_NATIVE_REQUIRE_BACKEND> ?? 1 !! 0);

for @cases -> [$data, $want, $desc] {
    is to-yaml($data), $want, $desc;
}
for @cases -> [$data, $, $desc] {
    my $back = from-yaml(to-yaml($data));
    is-deeply-num $back, $data, "reads back: $desc";
}
for @errors -> [$data, $msg] {
    my $got = (try to-yaml($data)) // "THREW: {$!.message}";
    is $got, "THREW: YAML::Native: $msg", $msg;
}

# NaN is not eqv to itself on every engine, and -0e0 is a float whose sign
# must survive: compared by their text
sub is-deeply-num($got, $want, $desc) {
    is-deeply canon($got), canon($want), $desc;
}
sub canon($v) {
    return $v.map(&canon).Array if $v ~~ Positional;
    return $v.map({ .key => canon(.value) }).Hash if $v ~~ Associative;
    return "Num:{$v.Str}" if $v ~~ Num;
    return "Num:{$v.Num.Str}" if $v ~~ Rat;
    return $v.Str if $v ~~ Dateish;
    $v
}

# every type at once, and a document large enough to be real
my %everything = (
    str => 'x', int => 7, num => 2.5e0, bool => True, null => Any, date => '2026-09-24',
    list => [1, [2, [3, {deep => 'yes'}]]], text => "two\nlines\n", 'odd key: yes' => '# not a comment',
    tbl => {'quoted key' => 1, sub => {deeper => {deepest => 'x'}}, empty => {}},
);
is-deeply from-yaml(to-yaml(%everything)), %everything, 'every type round-trips';
{
    my %doc = services => (^300).map({ %(name => "svc-$_", port => 8000 + $_, tags => ['a', 'b c', "d: $_"], on => $_ %% 2) }).Array;
    is-deeply from-yaml(to-yaml(%doc)), %doc, 'a large document round-trips';
}
is-deeply from-yaml(to-yaml({"k\x[0]" => "v\x[0]"})), {"k\x[0]" => "v\x[0]"}, 'a NUL in a key and a value';
{
    my @docs = {a => 1}, [2, 3], 'four';
    is-deeply from-yaml(@docs.map({ "---\n" ~ to-yaml($_) }).join, :all), @docs, 'documents joined with --- read back with :all';
}
{
    my $deep = 1;
    $deep = [$deep] for ^129;
    throws-like { to-yaml($deep) }, Exception, message => 'YAML::Native: nesting is limited to 128 levels',
        'nesting deeper than the reader accepts';
    my $ok = 1;
    $ok = [$ok] for ^128;
    is-deeply from-yaml(to-yaml($ok)), $ok, '128 levels are written and read back';
}

# On Raku++ with the extension, the text reads back the same through both
# implementations
if $native {
    is-deeply YAML::Native::parse-raku(to-yaml(%everything)), from-yaml(to-yaml(%everything)),
        'raku reads the written text as the extension does';
    my $big = to-yaml({ list => (^500).map({ "item $_: \x[301]é\n" }).Array });
    is-deeply YAML::Native::parse-raku($big), from-yaml($big), '... and a larger one';
}

with %*ENV<YAML_NATIVE_REQUIRE_BACKEND> -> $want {
    is yaml-backend, $want, "backend is $want (YAML_NATIVE_REQUIRE_BACKEND)";
}
