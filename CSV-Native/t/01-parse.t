use Test;
use CSV::Native;

# Two implementations, one specification. Every case below states what the
# README promises — the golden value — and on a Raku++ with the extension the
# same input also goes through the Raku implementation, which must answer
# identically. So on Rakudo this file tests the Raku implementation against
# the specification, and on Raku++ it tests both against it AND against each
# other, error messages included.
#
# Array literals here carry a trailing comma on purpose: `[["a","b"]]` is
# `["a","b"]` under Raku's single-argument rule, and `[["a","b"],]` is the
# one-row table it looks like.

my $native = csv-backend() eq 'native';
diag "csv-backend: {csv-backend}";

my @cases = (
    # text                    expected                          description
    ['',                      [],                               'empty text is no rows'],
    ["a,b,c",                 [["a","b","c"],],                 'one record, no line ending'],
    ["a,b,c\n",               [["a","b","c"],],                 'a trailing LF does not add a record'],
    ["a,b\nc,d\n",            [["a","b"],["c","d"]],            'LF'],
    ["a,b\r\nc,d\r\n",        [["a","b"],["c","d"]],            'CRLF'],
    ["a,b\rc,d",              [["a","b"],["c","d"]],            'a lone CR ends a record'],
    ["a,,c",                  [["a","","c"],],                  'an empty field'],
    ["a,b,",                  [["a","b",""],],                  'a trailing separator is an empty last field'],
    [",",                     [["",""],],                       'a lone separator is two empty fields'],
    ["\n",                    [[""],],                          'a blank line is one empty field'],
    ["a\n\nb",                [["a"],[""],["b"]],               'a blank line in the middle is a record'],
    ['"a","b"',               [["a","b"],],                     'quoted fields'],
    ['"a,b",c',               [["a,b","c"],],                   'the separator inside quotes'],
    ['"a""b",c',              [['a"b',"c"],],                   'a doubled quote is one quote'],
    ['""',                    [[""],],                          'a quoted empty field'],
    ['"""",x',                [['"',"x"],],                     'a field holding one quote'],
    ['"""a"""',               [['"a"'],],                       'quotes at both ends'],
    ["\"a\nb\",c",            [["a\nb","c"],],                  'LF inside quotes is content'],
    ["\"a\r\nb\",c\r\n",      [["a\r\nb","c"],],                'CRLF inside quotes is kept as is'],
    ["é,日本語,😀",            [["é","日本語","😀"],],            'non-ASCII fields'],
    ["\x[FEFF]a,b",           [["a","b"],],                     'a leading BOM is dropped'],
    [" a , b ",               [[" a "," b "],],                 'spaces are content'],
    ["1,2.5,1e3",             [["1","2.5","1e3"],],             'numbers stay Str'],
    ["a,b\n1",                [["a","b"],["1"]],                'ragged records are allowed'],
    ["a\nb\nc",               [["a"],["b"],["c"]],              'a single column'],
    ["\"a\"\n\"b\"",          [["a"],["b"]],                    'quoted single column'],
    ["x,\"\"\n",              [["x",""],],                      'a quoted empty last field'],
);

my @dialects = (
    # text                    options            expected                  description
    ["a;b;c",                 {sep => ';'},      [["a","b","c"],],         'sep ;'],
    ["a\tb\tc",               {sep => "\t"},     [["a","b","c"],],         'sep TAB'],
    ["a::b::c",               {sep => '::'},     [["a","b","c"],],         'a two-character sep'],
    ["a:b::c",                {sep => '::'},     [["a:b","c"],],           'half of a two-character sep is content'],
    ["a→b→c",                 {sep => '→'},      [["a","b","c"],],         'a non-ASCII sep'],
    ["'a,b',c",               {quote => "'"},    [["a,b","c"],],           'quote \''],
    ["'a''b',c",              {quote => "'"},    [["a'b","c"],],           'a doubled \' is one \''],
    ["a,\"b\"",               {quote => "'"},    [["a",'"b"'],],           'the default quote is content under another'],
    ["«a;b«;c",               {sep => ';', quote => '«'}, [["a;b","c"],],  'a non-ASCII quote'],
    ["«a««b«;c",              {sep => ';', quote => '«'}, [["a«b","c"],],  'a doubled non-ASCII quote is one'],
);

my @headers = (
    # text               options                       expected                                description
    ["a,b\n1,2\n3,4",    {headers => True},            [{a => "1", b => "2"}, {a => "3", b => "4"}], ':headers takes the first record'],
    ["a,b\n",            {headers => True},            [],                                     'a header with no records is no rows'],
    ["1,2\n3,4",         {headers => <x y>},           [{x => "1", y => "2"}, {x => "3", y => "4"}], ':headers<x y> names the columns'],
    ["1\n2",             {headers => 'only'},          [{only => "1"}, {only => "2"}],         'a lone name is one column'],
    ["a,b\n1\n",         {headers => True},            [{a => "1"},],                          'a short record leaves keys absent'],
    ["a,b\n,\n",         {headers => True},            [{a => "", b => ""},],                  'empty fields are empty strings, present'],
    ["a,b\n1,2",         {headers => False},           [["a","b"],["1","2"]],                  ':!headers is plain rows'],
    ["a,b\n1,2\n3,4",    {strict => True},             [["a","b"],["1","2"],["3","4"]],        ':strict passes consistent records'],
    ["a,b\n1,2",         {headers => True, strict => True}, [{a => "1", b => "2"},],           ':strict with :headers'],
);

my @errors = (
    # text                 options              message
    ["a,\"b\nc",           {},                  'CSV::Native: unterminated quoted field starting at line 1'],
    ["x\ny,\"b",           {},                  'CSV::Native: unterminated quoted field starting at line 2'],
    ["a,b\"c",             {},                  'CSV::Native: a quote inside an unquoted field at line 1'],
    ["1\n2\n3\"",          {},                  'CSV::Native: a quote inside an unquoted field at line 3'],
    ["\"a\" ,b",           {},                  'CSV::Native: text after a closing quote at line 1'],
    ["\"a\"b",             {},                  'CSV::Native: text after a closing quote at line 1'],
    ["\"l1\nl2\"x",        {},                  'CSV::Native: text after a closing quote at line 1'],
    ["\"l1\r\nl2\"\n\"3\"x", {},                'CSV::Native: text after a closing quote at line 3'],
    ["a,b\n1,2,3",         {headers => True},   'CSV::Native: line 2 has 3 fields but the header has 2'],
    ["1,2,3",              {headers => <x y>},  'CSV::Native: line 1 has 3 fields but the header has 2'],
    ["a,b\n1",             {strict => True},    'CSV::Native: line 2 has 1 fields, expected 2'],
    ["a,b\n1,2\n1,2,3",    {strict => True},    'CSV::Native: line 3 has 3 fields, expected 2'],
    ["a,b\n1",             {headers => True, strict => True}, 'CSV::Native: line 2 has 1 fields, expected 2'],
    ["a,a\n1,2",           {headers => True},   "CSV::Native: duplicate header 'a'"],
    ["1,2",                {headers => <x x>},  "CSV::Native: duplicate header 'x'"],
    ["a,b",                {sep => ''},         'CSV::Native: sep must not be empty'],
    ["a,b",                {quote => '""'},     "CSV::Native: quote must be exactly one character, not '\"\"'"],
    ["a,b",                {sep => ',"'},       'CSV::Native: sep must not contain the quote character'],
    ["a,b",                {sep => ",\n"},      'CSV::Native: sep must not contain a line ending'],
    ["a,b",                {headers => 42},     'CSV::Native: headers must be a Bool or a list of names'],
);

plan @cases + @dialects + @headers + @errors + 7
     + ($native ?? @cases + @dialects + @headers + @errors !! 0);

for @cases -> [$text, $want, $desc] {
    is-deeply from-csv($text), $want, $desc;
}
for @dialects -> [$text, %opt, $want, $desc] {
    is-deeply from-csv($text, |%opt), $want, $desc;
}
for @headers -> [$text, %opt, $want, $desc] {
    is-deeply from-csv($text, |%opt), $want, $desc;
}
for @errors -> [$text, %opt, $msg] {
    my $got = (try from-csv($text, |%opt)) // "THREW: {$!.message}";
    is $got, "THREW: $msg", $msg;
}

# Fields are Str: a CSV file carries no types, and a parser that guessed them
# would be right often enough to be dangerous.
isa-ok from-csv("1,2.5")[0][0], Str, 'a field that looks like a number is a Str';
isa-ok from-csv("1,2.5")[0][1], Str, 'a decimal is a Str too';

# The source may be a path or a handle, not only text.
my $file = $*TMPDIR.add("csv-native-{$*PID}.csv");
$file.spurt("a,b\n1,2\n");
is-deeply from-csv($file), [["a","b"],["1","2"]], 'an IO::Path is read';
is-deeply from-csv($file.open), [["a","b"],["1","2"]], 'an IO::Handle is read';
is-deeply from-csv($file, :headers), [{a => "1", b => "2"},], 'with options';
$file.unlink;

# A large field and many records: the paths a small case never exercises —
# the decode buffer growing, the memo of next occurrences being refreshed
# across thousands of fields.
{
    my $big = '"' ~ ('x""' x 20_000) ~ '"';
    is from-csv($big)[0][0], 'x"' x 20_000, 'a 40,000-character field with 20,000 doubled quotes';
    my $many = (^2000).map({ "$_,\"v $_\",z" }).join("\n");
    my @rows = from-csv($many);
    is-deeply (@rows.elems, @rows[1999]), (2000, ["1999", "v 1999", "z"]), '2,000 records';
}

# On Raku++ with the extension, the Raku implementation must agree with it on
# every case above — values and error messages alike. That parity IS the test
# of the extension: there is no third party to compare it with.
if $native {
    for @cases -> [$text, $want, $desc] {
        is-deeply CSV::Native::parse-raku($text), from-csv($text), "raku agrees: $desc";
    }
    for @dialects -> [$text, %opt, $want, $desc] {
        is-deeply CSV::Native::parse-raku($text, |%opt), from-csv($text, |%opt), "raku agrees: $desc";
    }
    for @headers -> [$text, %opt, $want, $desc] {
        my $names = %opt<headers>;
        $names = ($names,) if $names ~~ Str;
        my %raw = %opt;
        %raw<headers> = $names.List if $names ~~ Positional;
        is-deeply CSV::Native::parse-raku($text, |%raw), from-csv($text, |%opt), "raku agrees: $desc";
    }
    for @errors -> [$text, %opt, $msg] {
        # The dialect and option checks live in from-csv, above both
        # implementations, so they do not need agreeing on — and the raw
        # implementations are not handed those inputs, which they refuse on
        # their own terms rather than being specified for.
        if $msg.contains('must') {
            pass "raku agrees (option check is shared): $msg";
            next;
        }
        my $native-msg = (try from-csv($text, |%opt)) // $!.message;
        my %raw = %opt;
        %raw<headers> = %raw<headers>.List if %raw<headers> ~~ Positional;
        my $raku-msg   = (try CSV::Native::parse-raku($text, |%raw)) // $!.message;
        is $raku-msg, $native-msg, "raku agrees on the error: $msg";
    }
}

done-testing;
