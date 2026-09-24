use Test;
use YAML::Native;

# Two implementations, one specification. Every case below states what YAML
# 1.2 says the document means — the golden value — and on a Raku++ with the
# extension the same input also goes through the Raku implementation, which
# must answer identically: the same data, the same event stream, the same
# error message. So on Rakudo this file tests the Raku implementation against
# the specification, and on Raku++ it tests both against it AND against each
# other.
#
# The whole yaml-test-suite is run the same way by
# benchmarks/yaml/conformance.raku in the repository, outside the
# distribution; these are the cases worth having in every install.
#
# (A list holding one hash is written with a trailing comma, `[{a => 1},]`:
# without it Raku's single-argument rule would flatten the hash into pairs.)

my $native = yaml-backend() eq 'native';
diag "yaml-backend: {yaml-backend}";

my @cases = (
    # document                                        expected                                         description
    # -- documents and streams
    [Q:b"",                                           Any,                                             'an empty stream is null'],
    [Q:b"# only a comment\n",                         Any,                                             'a comment alone'],
    [Q:b"---\n",                                      Any,                                             'an empty document'],
    [Q:b"--- 42\n",                                   42,                                              'a scalar on the start line'],
    [Q:b"a: 1",                                       {a => 1},                                        'no final line break'],
    [Q:b"a: 1\r\nb: 2\r\n",                           {a => 1, b => 2},                                'CRLF line endings'],
    [Q:b"a: 1\rb: 2\r",                               {a => 1, b => 2},                                'CR line endings'],
    ["\x[FEFF]a: 1\n",                                {a => 1},                                        'a leading byte-order mark is skipped'],
    [Q:b"%YAML 1.2\n---\na: 1\n...\n",                {a => 1},                                        'a directive and both markers'],
    [Q:b"a: 1\n...\n# trailing\n",                    {a => 1},                                        'a comment after the end marker'],
    # -- block collections
    [Q:b"a: 1\nb: two\n",                             {a => 1, b => 'two'},                            'a block mapping'],
    [Q:b"- 1\n- two\n",                               [1, 'two'],                                      'a block sequence'],
    [Q:b"a:\n  b:\n    c: 1\n",                       {a => {b => {c => 1}}},                          'nested mappings'],
    [Q:b"a:\n- 1\n- 2\nb: 3\n",                       {a => [1, 2], b => 3},                           'a sequence at its key\'s indentation'],
    [Q:b"a:\n  - 1\n  - 2\n",                         {a => [1, 2]},                                   'an indented sequence'],
    [Q:b"- a: 1\n  b: 2\n- c: 3\n",                   [{a => 1, b => 2}, {c => 3}],                    'mappings in a sequence'],
    [Q:b"- - 1\n  - 2\n- - 3\n",                      [[1, 2], [3,]],                                  'compact nested sequences'],
    [Q:b"a:\nb: ~\nc: null\n",                        {a => Any, b => Any, c => Any},                  'empty values are null'],
    [Q:b"-\n- \n-  # none\n",                         [Any, Any, Any],                                 'empty entries are null'],
    [Q:b"? a\n: 1\n? b\n",                            {a => 1, b => Any},                              'explicit keys'],
    [Q:b"a: 1 # note\n# between\nb: 2\n",             {a => 1, b => 2},                                'comments'],
    [Q:b"key:    value   \n",                         {key => 'value'},                                'spaces around a value'],
    [Q:b"a:\tb\n",                                    {a => 'b'},                                      'a tab after the colon'],
    # -- flow collections
    [Q:b"[1, two, 3.5]",                              [1, 'two', 3.5e0],                               'a flow sequence'],
    [Q:b"{a: 1, b: [x, y]}",                          {a => 1, b => ['x', 'y']},                       'a flow mapping'],
    [Q:b"[a, b, ]",                                   ['a', 'b'],                                      'a trailing comma'],
    [Q:b"[]",                                         [],                                              'an empty flow sequence'],
    [Q:b"{}",                                         {},                                              'an empty flow mapping'],
    [Q:b"[a: 1, b]",                                  [{a => 1}, 'b'],                                 'a single pair in a flow sequence'],
    [Q:b"{a, b: }",                                   {a => Any, b => Any},                            'flow keys without values'],
    [Q:b"{\"a\":1, 'b':x}",                           {a => 1, b => 'x'},                              'JSON-like keys need no space after the colon'],
    [Q:b"[\n  a,\n  b\n]\n",                          ['a', 'b'],                                      'a flow sequence over several lines'],
    [Q:b"k: [a,\n  b]\n",                             {k => ['a', 'b']},                               'a flow value continued on the next line'],
    [Q:b"[a:b, c]",                                   ['a:b', 'c'],                                    'a colon inside a flow scalar'],
    # -- plain scalars
    [Q:b"a: one\n  two\n\n  three\n",                 {a => "one two\nthree"},                         'a plain scalar folds its lines'],
    [Q:b"a: x#y\n",                                   {a => 'x#y'},                                    'a # inside a word is text'],
    [Q:b"a: x:y\n",                                   {a => 'x:y'},                                    'so is a colon'],
    [Q:b"a: -x\n",                                    {a => '-x'},                                     'a dash that starts a word'],
    [Q:b"url: http://example.com/a?b=c\n",            {url => 'http://example.com/a?b=c'},             'a URL'],
    [Q:b"a: 日本語 — ok\n",                            {a => '日本語 — ok'},                              'non-ASCII text'],
    # -- quoted scalars
    [Q:b"a: 'it''s'\n",                               {a => "it's"},                                   'a single-quoted scalar'],
    [Q:b"a: \"tab\\there \\\"q\\\" \\\\ \\u00e9 \\U0001F600\"\n", {a => "tab\there \"q\" \\ é 😀"},      'double-quoted escapes'],
    [Q:b"a: \"\\0\\a\\b\\v\\f\\e\\N\\_\\L\\P\\/\\x41\"\n", {a => "\x[0]\x[7]\b\x[B]\f\x[1B]\x[85]\x[A0]\x[2028]\x[2029]/A"}, 'the other escapes'],
    [Q:b"a: 'one\n  two\n\n  three'\n",               {a => "one two\nthree"},                         'a quoted scalar folds too'],
    [Q:b"a: \"one \\\n  two\"\n",                     {a => 'one two'},                                'an escaped line break joins'],
    [Q:b"a: \"x \\\t\"\n",                            {a => "x \t"},                                   'an escaped tab'],
    [Q:b"a: \"\"\nb: ''\n",                           {a => '', b => ''},                              'empty quoted scalars'],
    [Q:b"\"a b\": 1\n'c:d': 2\n",                     {'a b' => 1, 'c:d' => 2},                        'quoted keys'],
    # -- block scalars
    [Q:b"a: |\n  line 1\n  line 2\n",                 {a => "line 1\nline 2\n"},                       'a literal block'],
    [Q:b"a: >\n  line 1\n  line 2\n\n  line 3\n",     {a => "line 1 line 2\nline 3\n"},                'a folded block'],
    [Q:b"a: |-\n  x\n\n",                             {a => 'x'},                                      'strip chomping'],
    [Q:b"a: |+\n  x\n\n",                             {a => "x\n\n"},                                  'keep chomping'],
    [Q:b"a: |\n  x\n\n\nb: 1\n",                      {a => "x\n", b => 1},                            'clip chomping'],
    [Q:b"a: |2\n    indented\n  not\n",               {a => "  indented\nnot\n"},                      'an indentation indicator'],
    [Q:b"a: >\n  one\n    more\n  two\n",             {a => "one\n  more\ntwo\n"},                     'a more-indented line is not folded'],
    [Q:b"a: |\n  x\n  # not a comment\n",             {a => "x\n# not a comment\n"},                   'a # inside a block is text'],
    [Q:b"--- |\nat column zero\n",                    "at column zero\n",                              'a top-level block at column 0'],
    [Q:b"a: |\n  x\nb: |\n  y",                       {a => "x\n", b => "y\n"},                        'the last line counts as a line'],
    # -- the core schema
    [Q:b"[~, null, Null, NULL, ]",                    [Any, Any, Any, Any],                            'null'],
    [Q:b"[true, True, TRUE, false, False, FALSE]",    [True, True, True, False, False, False],         'booleans'],
    [Q:b"[yes, no, on, off, y, n]",                   <yes no on off y n>.Array,                       'YAML 1.1 booleans are strings'],
    [Q:b"[0, -17, +5, 010, 0o17, 0x1F, 0xff]",        [0, -17, 5, 10, 15, 31, 255],                    'integers'],
    [Q:b"12345678901234567890123",                    12345678901234567890123,                         'an integer beyond int64'],
    [Q:b"0x10000000000000000",                        18446744073709551616,                            'a hex integer beyond int64'],
    [Q:b"[1.5, -0.5, .5, 1., 1e3, 6.02E+23, -1.5e-3]", [1.5e0, -0.5e0, 0.5e0, 1e0, 1e3, 6.02e23, -1.5e-3], 'floats'],
    [Q:b"[1_000, 0b101, 0O17, 1:30, +.5.]",           ['1_000', '0b101', '0O17', '1:30', '+.5.'],      'near misses are strings'],
    [Q:b"a: \"42\"\nb: '1.5'\nc: \"true\"\n",         {a => '42', b => '1.5', c => 'true'},            'quoted scalars are strings'],
    [Q:b"a: |\n  42\n",                               {a => "42\n"},                                   'block scalars are strings'],
    [Q:b"1: a\ntrue: b\n~: c\n",                      {'1' => 'a', 'true' => 'b', '~' => 'c'},         'keys are their text'],
    # -- tags
    [Q:b"[!!str 42, !!int '42', !!float 1, !!bool 'true', !!null '']", ['42', 42, 1e0, True, Any],     'core tags override the style'],
    [Q:b"[! 42, !local 42, !<tag:x.com,1:y> z]",       ['42', 42, 'z'],                                 'the non-specific tag, and others ignored'],
    [Q:b"%TAG !e! tag:example.com,2000:\n---\n- !e!thing x\n", ['x',],                                 'a tag handle'],
    [Q:b"!!map {a: 1}",                               {a => 1},                                        'a collection tag'],
    # -- anchors, aliases, merge keys
    [Q:b"a: &x 1\nb: *x\n",                           {a => 1, b => 1},                                'an alias'],
    [Q:b"a: &x [1, 2]\nb: *x\n",                      {a => [1, 2], b => [1, 2]},                      'an alias to a collection'],
    [Q:b"a: &x 1\nb: &x 2\nc: *x\n",                  {a => 1, b => 2, c => 2},                        'an anchor redefined'],
    [Q:b"&k a: 1\nb: *k\n",                          {a => 1, b => 'a'},                              'an anchored key, aliased as a value'],
    [Q:b"base: &b {x: 1, y: 2}\nm:\n  <<: *b\n  y: 3\n", {base => {x => 1, y => 2}, m => {x => 1, y => 3}}, 'a merge key'],
    [Q:b"a: &a {x: 1}\nb: &b {x: 2, y: 2}\nm:\n  <<: [*a, *b]\n", {a => {x => 1}, b => {x => 2, y => 2}, m => {x => 1, y => 2}}, 'the earlier merged mapping wins'],
    [Q:b"m:\n  <<: {x: 1}\n", {m => {x => 1}},                                                           'a merge of an inline mapping'],
    [Q:b"'<<': 1\n",                                  {'<<' => 1},                                     'a quoted << is an ordinary key'],
    # -- composition and unicode
    [Q:b"a: \"Rene\\u0301\"\n",                        {a => "Rene\x[301]"},                            'an escaped combining mark composes'],
    ["a: e\x[301]x\n",                                {a => "e\x[301]x"},                              'a combining mark in the text'],
    [Q:b"a: \"\\x00\"\n",                             {a => "\x[0]"},                                  'an escaped NUL'],
);

my @errors = (
    # document                                        message
    # -- the stream
    [Q:b"a: 1\n--- 2\n",                              "the stream holds 2 documents; read them with :all at line 2"],
    ["a: \x[1]",                                      'invalid character U+0001 at line 1'],
    ["a: 1\nb: \x[7F]",                               'invalid character U+007F at line 2'],
    [Q:b"%YAML 1.2\na: 1\n",                          "directives must be followed by '---' at line 2"],
    [Q:b"%YAML 2.0\n---\n",                           'unsupported YAML version at line 1'],
    [Q:b"a: 1\n%YAML 1.2\n---\n",                     "a directive must follow a document end marker ('...') at line 2"],
    [Q:b"a: 1\n... x\n",                              'a document end marker must be alone on its line at line 2'],
    [Q:b"--- a: 1\n",                                 'a mapping value is not allowed here at line 1'],
    # -- structure
    [Q:b"a: 1\nb\n",                                  "expected ':' after a mapping key at line 2"],
    [Q:b"a: b: c\n",                                  'a mapping value is not allowed here at line 1'],
    [Q:b"a:\n  b: 1\n c: 2\n",                        'expected a mapping key at line 3'],
    [Q:b"- a\nb: 1\n",                                "expected a sequence entry ('-') at line 2"],
    [Q:b"a: - b\n",                                   'a block sequence entry is not allowed here at line 1'],
    [Q:b"a:\n\tb: 1\n",                               'tabs cannot be used for indentation at line 2'],
    [Q:b"-\t- x\n",                                   'tabs cannot be used for indentation at line 1'],
    [Q:b"a: 'x'#c\n",                                 'a comment must be separated from what precedes it by a space at line 1'],
    [Q:b"[a, b",                                      'unterminated flow sequence at line 2'],
    [Q:b"{a: 1",                                      'unterminated flow mapping at line 2'],
    [Q:b"[a, , b]",                                   'an empty entry in a flow sequence at line 1'],
    [Q:b"\"a\nb\": c\n",                              'a mapping value is not allowed here at line 2'],
    [Q:b"]",                                          "']' without a matching '[' at line 1"],
    [Q:b"[- a]",                                      'a block sequence entry cannot be inside a flow collection at line 1'],
    [Q:b"key: [a,\nb]\n",                             "a flow collection's lines must be indented at line 2"],
    [Q:b"a: @x\n",                                    "unexpected '@' at line 1"],
    ['x: ' ~ '[' x 129 ~ ']' x 129,                   'nesting is limited to 128 levels at line 1'],
    # -- scalars
    [Q:b"a: \"abc\n",                                 'unterminated quoted scalar at line 1'],
    [Q:b"a: \"\\q\"\n",                               'invalid escape in a double-quoted scalar at line 1'],
    [Q:b"a: \"\\uD800\"\n",                           'invalid Unicode escape in a double-quoted scalar at line 1'],
    [Q:b"a: \"x\n---\ny\"\n",                          'a document marker inside a quoted scalar at line 2'],
    [Q:b"a:\n  b: \"x\n  y\"\n",                       "a quoted scalar's lines must be indented at line 3"],
    [Q:b"a: |0\n  x\n",                               "a block scalar's indentation indicator must be 1 to 9 at line 1"],
    [Q:b"a: |x\n",                                    'invalid block scalar header at line 1'],
    [Q:b"a: |\n\n    \n  x\n",                        "a block scalar's leading empty lines are indented more than its first line at line 4"],
    # -- properties
    [Q:b"a: &x &y 1\n",                               'a node can have only one anchor at line 1'],
    [Q:b"a: !!str !!int 1\n",                         'a node can have only one tag at line 1'],
    [Q:b"a: &x *y\n",                                 'an alias cannot have an anchor or a tag at line 1'],
    [Q:b"a: *nowhere\n",                              "undefined alias 'nowhere' at line 1"],
    [Q:b"a: !x!y 1\n",                                "undefined tag handle '!x!' at line 1"],
    [Q:b"a: !!int x\n",                               "'x' is not a valid !!int at line 1"],
    [Q:b"a: !!float x\n",                             "'x' is not a valid !!float at line 1"],
    [Q:b"a: !!bool yes\n",                            "'yes' is not a valid !!bool at line 1"],
    [Q:b"a: !!null x\n",                              "'x' is not a valid !!null at line 1"],
    [Q:b"a: !!map x\n",                               "the tag 'tag:yaml.org,2002:map' cannot be applied to a scalar at line 1"],
    [Q:b"a: !!seq {b: 1}\n",                          "the tag 'tag:yaml.org,2002:seq' cannot be applied to a mapping at line 1"],
    # -- composition
    [Q:b"a: 1\nb: 2\na: 3\n",                         "duplicate key 'a' at line 3"],
    [Q:b"{a: 1, a: 2}",                               "duplicate key 'a' at line 1"],
    [Q:b"? [a]\n: 1\n",                               'a mapping or a sequence cannot be a mapping key at line 1'],
    [Q:b"&k key: v\n*k : w\n",                        "duplicate key 'key' at line 2"],
    [Q:b"&a [*a]\n",                                  "recursive alias 'a' at line 1"],
    [Q:b"m:\n  <<: 1\n",                              "a merge key ('<<') takes a mapping or a sequence of mappings at line 2"],
    [Q:b"a: &a [x, x, x, x, x, x, x, x, x, x]\nb: &b [*a, *a, *a, *a, *a, *a, *a, *a, *a, *a]\nc: &c [*b, *b, *b, *b, *b, *b, *b, *b, *b, *b]\nd: &d [*c, *c, *c, *c, *c, *c, *c, *c, *c, *c]\ne: &e [*d, *d, *d, *d, *d, *d, *d, *d, *d, *d]\nf: &f [*e, *e, *e, *e, *e, *e, *e, *e, *e, *e]\n",
                                                      'aliases expand the document beyond 1000000 nodes at line 6'],
    # -- the line numbers
    [Q:b"\n\n\na: 1\na: 2\n",                         "duplicate key 'a' at line 5"],
    [Q:b"a: |\n  x\n\n  y\nb: \"\\q\"\n",             'invalid escape in a double-quoted scalar at line 5'],
    [Q:b"a: 1\r\nb: 2\r\nc: *x\r\n",                  "undefined alias 'x' at line 3"],
);

plan @cases + @errors + 10 + ($native ?? 2 * @cases + @errors !! 0);

for @cases -> [$text, $want, $desc] {
    is-deeply from-yaml($text), $want, $desc;
}
for @errors -> [$text, $msg] {
    my $got = (try from-yaml($text)) // "THREW: {$!.message}";
    is $got, "THREW: YAML::Native: $msg", $msg;
}

# :all, and aliases that are the same value
{
    is-deeply from-yaml(Q:b"a: 1\n--- [2]\n...\n--- x\n", :all), [{a => 1}, [2,], 'x'], ':all reads every document';
    is-deeply from-yaml('', :all), [], ':all of an empty stream is an empty list';
    my $d = from-yaml(Q:b"a: &x {k: 1}\nb: *x\n");
    is-deeply $d<b>, {k => 1}, 'an aliased mapping';
    is $d<a><k>, 1, '... and its anchor';
}

# a file, a handle, bytes that are not UTF-8
{
    my $file = $*TMPDIR.add("yaml-native-{$*PID}.yaml");
    LEAVE $file.unlink if $file.e;
    $file.spurt("t:\n  a: x\n");
    is-deeply from-yaml($file), {t => {a => 'x'}}, 'an IO::Path is read';
    is-deeply from-yaml($file.open), {t => {a => 'x'}}, 'an IO::Handle is read';
    $file.spurt(Blob.new(0xEF, 0xBB, 0xBF) ~ "a: 1\n".encode);
    is-deeply from-yaml($file), {a => 1}, 'a file with a byte-order mark';
    $file.spurt(Blob.new(0x61, 0x3A, 0x20, 0xFF, 0x0A));
    throws-like { from-yaml($file) }, Exception, message => 'YAML::Native: the document is not valid UTF-8',
        'a file that is not UTF-8';
}

# the event stream, which the conformance script compares
is YAML::Native::events(Q:b"--- &a !!str x\n...\n"),
    "+STR\n+DOC ---\n=VAL &a <tag:yaml.org,2002:str> :x\n-DOC ...\n-STR\n", 'the event stream';
is YAML::Native::events(Q:b"[a, {b: 'c'}]").lines[2..4].join('|'),
    '+SEQ []|=VAL :a|+MAP {}', 'flow collections in the event stream';

# On Raku++ with the extension, the Raku implementation must agree with it on
# every case: the data, the event stream, and every error message.
if $native {
    for @cases -> [$text, $, $desc] {
        is-deeply YAML::Native::parse-raku($text), from-yaml($text), "raku agrees: $desc";
        is YAML::Native::events-raku($text), YAML::Native::events($text), "raku events agree: $desc";
    }
    for @errors -> [$text, $msg] {
        my $got = (try YAML::Native::parse-raku($text)) // "THREW: {$!.message}";
        is $got, "THREW: YAML::Native: $msg", "raku agrees: $msg";
    }
}
