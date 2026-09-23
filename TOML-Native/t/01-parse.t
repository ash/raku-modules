use Test;
use TOML::Native;

# Two implementations, one specification. Every case below states what TOML
# v1.0.0 says the document means — the golden value — and on a Raku++ with the
# extension the same input also goes through the Raku implementation, which
# must answer identically. So on Rakudo this file tests the Raku
# implementation against the specification, and on Raku++ it tests both
# against it AND against each other, error messages included.
#
# The whole toml-test suite is run the same way by
# benchmarks/toml/conformance.raku in the repository, outside the
# distribution; these are the cases worth having in every install.

my $native = toml-backend() eq 'native';
diag "toml-backend: {toml-backend}";

my constant LDT = TOML::Native::LocalDateTime;
my constant LT  = TOML::Native::LocalTime;

my @cases = (
    # document                                  expected                                  description
    # -- the document
    ['',                                        {},                                       'an empty document'],
    ["# only a comment\n",                      {},                                       'a comment alone'],
    ['a = 1',                                   {a => 1},                                 'no final line ending'],
    ["a = 1\nb = 2\n",                          {a => 1, b => 2},                         'two pairs'],
    ["a = 1\r\nb = 2\r\n",                      {a => 1, b => 2},                         'CRLF line endings'],
    ["\x[FEFF]a = 1",                           {a => 1},                                 'a leading byte-order mark is skipped'],
    ["  a\t=\t1   # note\n\n\n",                {a => 1},                                 'whitespace, a comment, blank lines'],
    # -- keys
    ['bare_key-1 = 1',                          {'bare_key-1' => 1},                      'a bare key'],
    ['"quoted key" = 1',                        {'quoted key' => 1},                      'a quoted key'],
    ["'literal \"key\"' = 1",                   {'literal "key"' => 1},                   'a literal key'],
    ['"" = 1',                                  {'' => 1},                                'the empty quoted key'],
    ['"é\u00E9" = 1',                           {'éé' => 1},                              'escapes in a quoted key'],
    ['a.b.c = 1',                               {a => {b => {c => 1}}},                   'a dotted key'],
    ['a . "b c" . d = 1',                       {a => {'b c' => {d => 1}}},               'whitespace around dots, a quoted part'],
    ['"a.b" = 1',                               {'a.b' => 1},                             'a dot inside quotes is not a separator'],
    ['3.14159 = "pi"',                          {'3' => {'14159' => 'pi'}},               'digits are bare keys, and the dot splits them'],
    ["a.b = 1\na.c = 2",                        {a => {b => 1, c => 2}},                  'dotted keys extend their own table'],
    ['true = 1',                                {'true' => 1},                            'a key may look like a value'],
    # -- strings
    ['s = "tab\there \"q\" \\\\ \u00E9 \U0001F600"', {s => "tab\there \"q\" \\ é 😀"},    'basic string escapes'],
    ['s = "\b\f\n\r"',                          {s => "\b\f\n\r"},                        'the control escapes'],
    ['s = "\u0000"',                            {s => "\x[0]"},                           'an escaped NUL'],
    ["s = 'C:\\Users\\x'",                      {s => 'C:\\Users\\x'},                    'a literal string keeps backslashes'],
    ["s = \"\"\"\nline 1\nline 2\"\"\"",        {s => "line 1\nline 2"},                  'a multi-line string drops its first newline'],
    ["s = \"\"\"\nThe quick \\\n   brown \\\n\n  fox\"\"\"", {s => 'The quick brown fox'},  'a line-ending backslash trims'],
    ["s = '''\nraw \\n text\n'''",              {s => "raw \\n text\n"},                  'a multi-line literal string'],
    ['s = """x"""""',                           {s => 'x""'},                             'two quotes before the closing three are content'],
    ["s = '''x'''''",                           {s => "x''"},                             'the same for literal strings'],
    ["s = \"\"\"\r\nx\r\ny\"\"\"",              {s => "x\ny"},                            'CRLF inside a multi-line string is LF'],
    ["s = \"\ttab\"",                           {s => "\ttab"},                           'a raw tab in a string'],
    ["s = \"\x[301]x\"",                        {s => "\x[301]x"},                        'a combining mark straight after the quote'],
    ['s = "Rene\u0301"',                        {s => "Rene\x[301]"},                     'an escaped combining mark composes'],
    ['"cafe\u0301" = 1',                        {"cafe\x[301]" => 1},                     '... in a key too'],
    ['s = "日本語 — ok"',                        {s => '日本語 — ok'},                      'non-ASCII text'],
    # -- integers
    ['n = 42',                                  {n => 42},                                'an integer'],
    ['n = +17',                                 {n => 17},                                'a plus sign'],
    ['n = -17',                                 {n => -17},                               'a minus sign'],
    ['n = 0',                                   {n => 0},                                 'zero'],
    ['n = -0',                                  {n => 0},                                 'minus zero is zero'],
    ['n = 1_000_000',                           {n => 1000000},                           'underscores between digits'],
    ['n = 0xDEAD_beef',                         {n => 0xDEADBEEF},                        'hexadecimal, either case'],
    ['n = 0o755',                               {n => 0o755},                             'octal'],
    ['n = 0b1101',                              {n => 0b1101},                            'binary'],
    ['n = 9223372036854775807',                 {n => 9223372036854775807},               'the largest int64'],
    ['n = -9223372036854775808',                {n => -9223372036854775808},              'the smallest int64'],
    ['n = 0x7FFFFFFFFFFFFFFF',                  {n => 9223372036854775807},               'the largest int64 in hex'],
    # -- floats
    ['f = 3.1415',                              {f => 3.1415e0},                          'a float'],
    ['f = -0.01',                               {f => -0.01e0},                           'a negative float'],
    ['f = 5e+22',                               {f => 5e22},                              'an exponent'],
    ['f = 1e06',                                {f => 1e6},                               'an exponent with a leading zero'],
    ['f = -2E-2',                               {f => -2e-2},                             'a capital E'],
    ['f = 6.626e-34',                           {f => 6.626e-34},                         'fraction and exponent'],
    ['f = 224_617.445_991',                     {f => 224617.445991e0},                   'underscores in a float'],
    ['f = 0e0',                                 {f => 0e0},                               'zero with an exponent'],
    ['f = -0.0',                                {f => -0e0},                              'negative zero'],
    ['f = inf',                                 {f => Inf},                               'inf'],
    ['f = +inf',                                {f => Inf},                               '+inf'],
    ['f = -inf',                                {f => -Inf},                              '-inf'],
    ['f = nan',                                 {f => NaN},                               'nan'],
    ['f = -nan',                                {f => NaN},                               '-nan is nan'],
    # -- booleans
    ["t = true\nf = false",                     {t => True, f => False},                  'booleans'],
    # -- dates and times
    ['d = 1979-05-27T07:32:00Z',                {d => DateTime.new(1979, 5, 27, 7, 32, 0, :timezone(0))},       'an offset date-time in UTC'],
    ['d = 1979-05-27T00:32:00-07:00',           {d => DateTime.new(1979, 5, 27, 0, 32, 0, :timezone(-25200))},  'a negative offset'],
    ['d = 1979-05-27T00:32:00+05:30',           {d => DateTime.new(1979, 5, 27, 0, 32, 0, :timezone(19800))},   'a half-hour offset'],
    ['d = 1979-05-27T00:32:00.999999-07:00',    {d => DateTime.new(1979, 5, 27, 0, 32, 0.999999, :timezone(-25200))}, 'fractional seconds'],
    ['d = 1979-05-27 07:32:00Z',                {d => DateTime.new(1979, 5, 27, 7, 32, 0, :timezone(0))},       'a space for the T'],
    ['d = 1979-05-27t07:32:00z',                {d => DateTime.new(1979, 5, 27, 7, 32, 0, :timezone(0))},       'lower-case t and z'],
    ['d = 1979-05-27T07:32:00',                 {d => LDT.new(1979, 5, 27, 7, 32, 0)},                          'a local date-time'],
    ['d = 1979-05-27T00:32:00.5',               {d => LDT.new(1979, 5, 27, 0, 32, 0.5)},                        'a local date-time with a fraction'],
    ['d = 1979-05-27',                          {d => Date.new(1979, 5, 27)},                                   'a local date'],
    ['d = 2000-02-29',                          {d => Date.new(2000, 2, 29)},                                   'a leap day'],
    ['d = 1979-05-27 # a date, then a comment', {d => Date.new(1979, 5, 27)},                                   'a date then a space is a date'],
    ['t = 07:32:00',                            {t => LT.new(:hour(7), :minute(32), :second(0))},               'a local time'],
    ['t = 00:32:00.999999',                     {t => LT.new(:hour(0), :minute(32), :second(0.999999))},        'a local time with a fraction'],
    ['t = 00:00:00.1234567891',                 {t => LT.new(:hour(0), :minute(0), :second(0.123456789))},      'fractions are kept to nine digits'],
    # -- arrays
    ['a = [1, 2, 3]',                           {a => [1, 2, 3]},                         'an array'],
    ['a = []',                                  {a => []},                                'an empty array'],
    ['a = ["x", 1, 1.5, true]',                 {a => ['x', 1, 1.5e0, True]},             'types may mix'],
    ['a = [[1, 2], [3]]',                       {a => [[1, 2], [3]]},                     'nested arrays'],
    ['a = [[1]]',                               {a => [[1],]},                            'one array inside another'],
    ["a = [\n  1, # one\n  2,\n]",              {a => [1, 2]},                            'newlines, comments and a trailing comma'],
    ['a = [{x = 1}, {x = 2}]',                  {a => [{x => 1}, {x => 2}]},              'inline tables in an array'],
    # -- inline tables
    ['t = { x = 1, y = "z" }',                  {t => {x => 1, y => 'z'}},                'an inline table'],
    ['t = {}',                                  {t => {}},                                'an empty inline table'],
    ['t = { b.c = 1, b.d = 2 }',                {t => {b => {c => 1, d => 2}}},           'dotted keys in an inline table'],
    ['t = { b = { c = [1] } }',                 {t => {b => {c => [1]}}},                 'nested inline tables'],
    # -- tables
    ["[t]\na = 1",                              {t => {a => 1}},                          'a table'],
    ['[t]',                                     {t => {}},                                'an empty table'],
    ["[a.b.c]\nx = 1",                          {a => {b => {c => {x => 1}}}},            'a dotted header makes its parents'],
    ["[ a . \"b c\" ]\nx = 1",                  {a => {'b c' => {x => 1}}},               'whitespace and quotes in a header'],
    ["[a.b]\nx = 1\n[a]\ny = 2",                {a => {b => {x => 1}, y => 2}},           'a parent may be defined after its child'],
    ["[fruit]\napple.color = \"red\"\n[fruit.apple.texture]\nsmooth = true",
                                                {fruit => {apple => {color => 'red', texture => {smooth => True}}}},
                                                                                          'a header may add a table under dotted keys'],
    ["a = 1\n[t]\na = 2",                       {a => 1, t => {a => 2}},                  'the same key in two tables'],
    # -- arrays of tables
    ["[[p]]\nx = 1\n[[p]]\nx = 2",              {p => [{x => 1}, {x => 2}]},              'an array of tables'],
    ["[[p]]\n[p.sub]\nk = 1\n[[p]]",            {p => [{sub => {k => 1}}, {}]},           'a sub-table of the last element'],
    ["[[a]]\n[[a.b]]\nx = 1\n[[a.b]]\nx = 2",   {a => [{b => [{x => 1}, {x => 2}]},]},    'nested arrays of tables'],
);

my @errors = (
    # document                                          message
    # -- redefinition
    ["a = 1\na = 2",                                    "duplicate key 'a' at line 2"],
    ["a = \{b = 1, b = 2}",                              "duplicate key 'b' at line 1"],
    ["a = 1\n[a.b]",                                    "duplicate key 'a' at line 2"],
    ["a = 1\na.b = 2",                                  "duplicate key 'a' at line 2"],
    ["[a.b]\n[a]\nb = 1",                               "duplicate key 'b' at line 3"],
    ["[a]\n[a]",                                        "table 'a' is defined twice at line 2"],
    ["a.b = 1\n[a]",                                    "table 'a' is defined twice at line 2"],
    ["[a]\nb.c = 1\n[a.b]",                             "table 'a.b' is defined twice at line 3"],
    ["[[a]]\n[a]",                                      "table 'a' is defined twice at line 2"],
    ["[a]\n[[a]]",                                      "table 'a' is defined twice at line 2"],
    # -- closed things
    ["a = \{b = 1}\n[a]",                                "inline table 'a' cannot be extended at line 2"],
    ["a = \{b = 1}\na.c = 2",                            "inline table 'a' cannot be extended at line 2"],
    ["a = \{b = 1}\n[a.c]",                              "inline table 'a' cannot be extended at line 2"],
    ["a = \{b = \{c = 1}, b.d = 2}",                      "inline table 'b' cannot be extended at line 1"],
    ["a = [1]\n[[a]]",                                  "cannot append to static array 'a' at line 2"],
    ["a = [1]\n[a.b]",                                  "static array 'a' cannot be extended at line 2"],
    ["a = [\{}]\na.b = 1",                               "static array 'a' cannot be extended at line 2"],
    # -- dotted keys reopening
    ["[a.b.c]\nz = 1\n[a]\nb.c.d = 1",                  "cannot reopen table 'b.c' with a dotted key at line 4"],
    ["[a]\nb.c = 1\n[a.x]\n[a]",                        "table 'a' is defined twice at line 4"],
    ["[[a.b]]\n[a]\nb.c = 1",                           "cannot reopen table 'b' with a dotted key at line 3"],
    # -- values
    ['a = 9223372036854775808',                         'integer out of range at line 1'],
    ['a = -9223372036854775809',                        'integer out of range at line 1'],
    ['a = 0x8000000000000000',                          'integer out of range at line 1'],
    ['a = 01',                                          'invalid number at line 1'],
    ['a = 1__0',                                        'invalid number at line 1'],
    ['a = 1_',                                          'invalid number at line 1'],
    ['a = 1.',                                          'invalid number at line 1'],
    ['a = 1.e5',                                        'invalid number at line 1'],
    ['a = 1e',                                          'invalid number at line 1'],
    ['a = +0x1',                                        'invalid number at line 1'],
    ['a = 0X1',                                         'invalid number at line 1'],
    ['a = 0xG',                                         'invalid number at line 1'],
    ['a = infinity',                                    'expected a value at line 1'],
    ['a = .5',                                          'expected a value at line 1'],
    ['a = tru',                                         'expected a value at line 1'],
    ['a = ',                                            'expected a value at line 1'],
    ["a = # nothing",                                   'expected a value at line 1'],
    ['a = 1979-02-29',                                  'invalid date at line 1'],
    ['a = 1979-13-01',                                  'invalid date at line 1'],
    ['a = 1979-04-31',                                  'invalid date at line 1'],
    ['a = 24:00:00',                                    'invalid time at line 1'],
    ['a = 07:32:60',                                    'invalid time at line 1'],
    ['a = 07:32',                                       'malformed date or time at line 1'],
    ['a = 1979-05-27T07:32',                            'malformed date or time at line 1'],
    ['a = 1979-05-27T07:32:00.',                        'malformed date or time at line 1'],
    ['a = 1979-05-27T07:32:00+24:00',                   'invalid time offset at line 1'],
    ['a = 1979-05-27T07:32:00+05',                      'malformed date or time at line 1'],
    # -- strings
    ['a = "abc',                                        'unterminated string at line 1'],
    ["a = \"abc\nb = 1",                                'unterminated string at line 1'],
    ["a = 'abc\nb = 1",                                 'unterminated string at line 1'],
    ["\n\na = \"\"\"\nabc",                             'unterminated multi-line string at line 3'],
    ['a = "\x41"',                                      'invalid escape sequence at line 1'],
    ['a = "\ "',                                        'invalid escape sequence at line 1'],
    ['a = "\uD800"',                                    'invalid Unicode escape at line 1'],
    ['a = "\u12"',                                      'invalid Unicode escape at line 1'],
    ['a = "\U00110000"',                                'invalid Unicode escape at line 1'],
    ["a = \"\x[01]\"",                                  'control character U+0001 in a string at line 1'],
    ["a = '\x[7F]'",                                    'control character U+007F in a string at line 1'],
    ["a = \"\"\"\n\x[0]\"\"\"",                         'control character U+0000 in a string at line 2'],
    ["# \x[7F]",                                        'control character U+007F in a comment at line 1'],
    ["# x\ra = 1",                                      'control character U+000D in a comment at line 1'],
    # -- structure
    ["a = 1 b = 2",                                     'expected the end of the line at line 1'],
    ["a = 1\r",                                         'expected the end of the line at line 1'],
    ["[a] x = 1",                                       'expected the end of the line at line 1'],
    ["= 1",                                             'expected a key at line 1'],
    ["a..b = 1",                                        'expected a key at line 1'],
    ["[]",                                              'expected a key at line 1'],
    ["a 1",                                             "expected '=' after a key at line 1"],
    ["[a",                                              "expected ']' to close a table header at line 1"],
    ["[a\n]",                                           "expected ']' to close a table header at line 1"],
    ["[[a]",                                            "expected ']]' to close an array-of-tables header at line 1"],
    ["[[a] ]",                                          "expected ']]' to close an array-of-tables header at line 1"],
    ["a = [1 2]",                                       "expected ',' or ']' in an array at line 1"],
    ["a = [,]",                                         'expected a value at line 1'],
    ["\na = [1,\n2",                                    'unterminated array at line 2'],
    ["a = \{ b = 1 ",                                    "expected ',' or '}' in an inline table at line 1"],
    ["a = \{ b = 1, }",                                  'trailing comma in an inline table at line 1'],
    ["a = \{ b = 1,\n c = 2 }",                          'expected a key at line 1'],
    ["a = \{ b = 1\n}",                                 "expected ',' or '}' in an inline table at line 1"],
    ["\x[FEFF]\x[FEFF]a = 1",                           'expected a key at line 1'],
    ['a = ' ~ '[' x 130 ~ ']' x 130,                    'nesting deeper than 128 levels at line 1'],
    # -- the line numbers
    ["\n\n\na = 1\na = 2",                              "duplicate key 'a' at line 5"],
    ["a = \"\"\"\n\n\"\"\"\nb = \"\x[01]\"",            'control character U+0001 in a string at line 4'],
    ["a = [\n1,\n2,\n]\na = 3",                         "duplicate key 'a' at line 5"],
    ["a = [\n1,\n2\n]\n\na = 3",                        "duplicate key 'a' at line 6"],
    ["a = 1\r\nb = 2\r\nc = \"\x[01]\"",                'control character U+0001 in a string at line 3'],
);

plan @cases + @errors + 16 + ($native ?? @cases + @errors !! 0);

for @cases -> [$text, $want, $desc] {
    is-deeply from-toml($text), $want, $desc;
}
for @errors -> [$text, $msg] {
    my $got = (try from-toml($text)) // "THREW: {$!.message}";
    is $got, "THREW: TOML::Native: $msg", $msg;
}

# The types, one by one: a local date-time IS a DateTime, stringifying
# without an offset; a local time is its own small class.
{
    my %d = from-toml(q:to/T/);
        odt = 1979-05-27T00:32:00.25-07:00
        ldt = 1979-05-27T07:32:00.25
        ld  = 1979-05-27
        lt  = 07:32:00.25
        T
    isa-ok %d<odt>, DateTime, 'an offset date-time is a DateTime';
    nok %d<odt> ~~ LDT, '... and not a local one';
    isa-ok %d<ldt>, DateTime, 'a local date-time is a DateTime too';
    isa-ok %d<ldt>, LDT, '... of the LocalDateTime kind';
    is ~%d<ldt>, '1979-05-27T07:32:00.25', 'a local date-time stringifies without an offset';
    isa-ok %d<ld>, Date, 'a local date is a Date';
    is ~%d<lt>, '07:32:00.25', 'a local time stringifies as TOML writes it';
    is %d<odt>.second, 0.25, 'the fraction of a second survives';
}

# The source may be a path or a handle, not only text.
{
    my $file = $*TMPDIR.add("toml-native-{$*PID}.toml");
    $file.spurt("[t]\na = \"x\"\n");
    is-deeply from-toml($file), {t => {a => 'x'}}, 'an IO::Path is read';
    is-deeply from-toml($file.open), {t => {a => 'x'}}, 'an IO::Handle is read';
    $file.spurt(Blob.new(0xEF, 0xBB, 0xBF, |"a = 1\n".encode));
    is-deeply from-toml($file), {a => 1}, 'a file with a byte-order mark';
    $file.spurt(Blob.new(0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, |"a = 1\n".encode));
    is ((try from-toml($file)) // $!.message), 'TOML::Native: expected a key at line 1',
       'a second byte-order mark is an error, whichever engine decoded the file';
    $file.spurt(Blob.new(|"a = \"".encode, 0xC3, 0x28, |"\"\n".encode));
    is ((try from-toml($file)) // $!.message), 'TOML::Native: the document is not valid UTF-8',
       'a file that is not UTF-8';
    $file.unlink;
}

# Size: the paths a small case never exercises — the key map growing, strings
# long enough to leave the fast path's lists behind.
{
    my $many = (^3000).map({ "[[p]]\nn = $_\ns = \"v $_\"\nt.u = [$_, '$_']" }).join("\n");
    my %d = from-toml($many);
    is-deeply (%d<p>.elems, %d<p>[2999]), (3000, {n => 2999, s => 'v 2999', t => {u => [2999, '2999']}}),
              '3,000 elements of an array of tables';
    my $long = 'x"' x 20_000;
    is from-toml('s = "' ~ $long.subst('"', '\"', :g) ~ '"')<s>, $long, 'a 40,000-character string with 20,000 escapes';
    is from-toml((^5000).map({ "k$_ = $_" }).join("\n"))<k4999>, 4999, '5,000 keys in one table';
}

# On Raku++ with the extension, the Raku implementation must agree with it on
# every case above — values and error messages alike. That parity IS the test
# of the extension: there is no third party to compare it with.
if $native {
    for @cases -> [$text, $want, $desc] {
        is-deeply TOML::Native::parse-raku($text), from-toml($text), "raku agrees: $desc";
    }
    for @errors -> [$text, $msg] {
        my $native-msg = (try from-toml($text)) // $!.message;
        my $raku-msg   = (try TOML::Native::parse-raku($text)) // $!.message;
        is $raku-msg, $native-msg, "raku agrees on the error: $msg";
    }
}

done-testing;
