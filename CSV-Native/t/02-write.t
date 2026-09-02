use Test;
use CSV::Native;

# Same shape as 01-parse.t: golden text for every case, and on a Raku++ with
# the extension the Raku implementation must produce the same bytes.

my $native = csv-backend() eq 'native';
diag "csv-backend: {csv-backend}";

my @cases = (
    # rows                                   options                   expected                       description
    [[],                                     {},                       '',                            'no rows is no text'],
    [[[1, 2], [3, 4]],                       {},                       "1,2\n3,4\n",                  'plain rows, LF, trailing line ending'],
    [[["a", "b"],],                          {},                       "a,b\n",                       'one row'],
    [[["",],],                               {},                       "\n",                          'one empty field is an empty line'],
    [[["", ""],],                            {},                       ",\n",                         'two empty fields'],
    [[["a,b", "c"],],                        {},                       "\"a,b\",c\n",                 'the separator forces quotes'],
    [[['a"b'],],                             {},                       "\"a\"\"b\"\n",                'a quote is doubled and forces quotes'],
    [[["a\nb", "a\rb"],],                    {},                       "\"a\nb\",\"a\rb\"\n",         'line endings force quotes'],
    [[[" a ", "b "],],                       {},                       " a ,b \n",                    'spaces do not force quotes'],
    [[["é", "日本語", "😀"],],                 {},                       "é,日本語,😀\n",                'non-ASCII passes through'],
    [[[Any, "x", Str],],                     {},                       ",x,\n",                       'an undefined cell is an empty field'],
    [[[1, 2.5, 1e3, 1/3, True],],            {},                       "1,2.5,1000,0.333333,True\n",  'cells are their .Str'],
    [[[1, 2], [3, 4]],                       {eol => "\r\n"},          "1,2\r\n3,4\r\n",              ':eol CRLF'],
    [[[1, 2],],                              {eol => "\r"},            "1,2\r",                       ':eol CR'],
    [[["a", "b;c"],],                        {sep => ';'},             "a;\"b;c\"\n",                 ':sep quotes on the new separator'],
    [[["a,b"],],                             {sep => ';'},             "a,b\n",                       'a comma is content under :sep<;>'],
    [[["a", "b::c"],],                       {sep => '::'},            "a::\"b::c\"\n",               'a two-character sep'],
    [[["a:b"],],                             {sep => '::'},            "a:b\n",                       'half of a two-character sep does not quote'],
    [[["it's", 'a"b'],],                     {quote => "'"},           "'it''s',a\"b\n",              ':quote changes what is doubled'],
    [[["a", "b"], [1, 2]],                   {always-quote => True},   "\"a\",\"b\"\n\"1\",\"2\"\n",  ':always-quote'],
    [[[Any],],                               {always-quote => True},   "\"\"\n",                      ':always-quote quotes an empty field'],
    [[["x"],],                               {headers => <a b>},       "a,b\nx\n",                    'list rows with :headers get a header line'],
    [[{a => 1, b => 2}, {b => 3}],           {},                       "a,b\n1,2\n,3\n",              'hash rows: sorted keys, header line, absent is empty'],
    [[{b => 1, a => 2},],                    {},                       "a,b\n2,1\n",                  'the first row\'s keys, sorted'],
    [[{a => 1, b => 2},],                    {headers => <b a>},       "b,a\n2,1\n",                  ':headers orders the columns'],
    [[{a => 1, b => 2},],                    {headers => <a>},         "a\n1\n",                      ':headers selects columns'],
    [[{a => 1, b => 2},],                    {headers => False},       "1,2\n",                       ':!headers omits the header line'],
    [[{a => 1, b => 2},],                    {headers => True},        "a,b\n1,2\n",                  ':headers with hash rows is the default'],
    [[{a => 1}, {a => 2, c => 3}],           {},                       "a\n1\n2\n",                   'keys outside the header are not columns'],
    [[["a"], {a => 1}],                      {headers => <a>},         "a\na\n1\n",                   'list and hash rows may mix under :headers'],
    [[{"k,ey" => 'v"'},],                    {},                       "\"k,ey\"\n\"v\"\"\"\n",       'header names are quoted like cells'],
);

my @errors = (
    # rows                      options            message
    [["a", "b"],                {},                'CSV::Native: row 0 is not a list or a hash'],
    [[["a"], "b"],              {},                'CSV::Native: row 1 is not a list or a hash'],
    [[["a"], {a => 1}],         {},                'CSV::Native: row 1 is a hash but no headers are known'],
    [[[1],],                    {eol => "|"},      'CSV::Native: eol must be \n, \r\n or \r'],
    [[[1],],                    {sep => ''},       'CSV::Native: sep must not be empty'],
    [[[1],],                    {quote => 'ab'},   "CSV::Native: quote must be exactly one character, not 'ab'"],
);

# Round trips: what to-csv writes, from-csv reads back as the same data, on
# every dialect and with every kind of cell the format can hold.
my @trips = (
    [[["a", "b"], ["1", "2"]],                 {}],
    [[["a,b", 'c"d', "e\nf", "g\r\nh", ""],],  {}],
    [[["", "", ""], ["", "", ""]],             {}],
    [[["x;y", "z"],],                          {sep => ';'}],
    [[["it's", "x"],],                         {quote => "'"}],
    [[["a", "b"], ["1", "2"]],                 {eol => "\r\n"}],
    [[["a", "b"], ["1", "2"]],                 {always-quote => True}],
    [[["é 日本語 😀", "→"],],                   {sep => '→'}],
);

plan @cases + @errors + @trips * 2 + 2
     + ($native ?? @cases + @errors + 1 !! 0);

for @cases -> [$rows, %opt, $want, $desc] {
    is to-csv($rows, |%opt), $want, $desc;
}
for @errors -> [$rows, %opt, $msg] {
    my $got = (try to-csv($rows, |%opt)) // "THREW: {$!.message}";
    is $got, "THREW: $msg", $msg;
}
for @trips -> [$rows, %opt] {
    my %read = %opt.grep({ .key eq 'sep' | 'quote' });
    is-deeply from-csv(to-csv($rows, |%opt), |%read), $rows, "round-trips {$rows.raku}";
    # and with a header line, as records
    my @names = (^$rows[0].elems).map({ "c$_" });
    my @recs = $rows.map(-> @r { %( @names Z=> @r ) });
    is-deeply from-csv(to-csv(@recs, :headers(@names), |%opt), :headers, |%read),
              @recs.Array, "round-trips {$rows.raku} as records";
}

# A wide table: the writer's per-row work must stay flat in the number of
# columns, and a 500-column header must come out in the order given.
{
    my @names = (^500).map({ "col$_" });
    my %row = @names Z=> ^500;
    my $text = to-csv([%row,], :headers(@names));
    is $text.lines[0], @names.join(','), 'a 500-column header in the given order';
    is $text.lines[1], (^500).join(','), 'and its values in the same order';
}

# On Raku++ with the extension, the Raku implementation writes the same bytes.
if $native {
    for @cases -> [$rows, %opt, $want, $desc] {
        my $names = %opt<headers>;
        my %raw = %opt.grep({ .key ne 'headers' });
        # resolve :headers the way to-csv does before it reaches either writer
        my @names;
        my $line;
        if $names ~~ Positional { @names = @$names; $line = True }
        elsif $names ~~ Str { @names = ($names,); $line = True }
        elsif $rows && $rows[0] ~~ Associative { @names = $rows[0].keys.sort; $line = $names ~~ Bool ?? $names !! True }
        else { $line = False }
        is CSV::Native::write-raku($rows, |%raw, :@names, :header-line($line)),
           to-csv($rows, |%opt), "raku agrees: $desc";
    }
    for @errors -> [$rows, %opt, $msg] {
        if $msg.contains('must') {
            pass "raku agrees (option check is shared): $msg";
        }
        else {
            my $native-msg = (try to-csv($rows, |%opt)) // $!.message;
            my $raku-msg   = (try CSV::Native::write-raku($rows, |%opt)) // $!.message;
            is $raku-msg, $native-msg, "raku agrees on the error: $msg";
        }
    }
    my @names = (^500).map({ "col$_" });
    my %row = @names Z=> ^500;
    is CSV::Native::write-raku([%row,], :@names, :header-line), to-csv([%row,], :headers(@names)),
       'raku agrees on the 500-column table';
}

# CI pins which backend a run exercised: a green suite on the wrong backend is
# the failure mode where the native path is never tested at all.
with %*ENV<CSV_NATIVE_REQUIRE_BACKEND> -> $want {
    is csv-backend, $want, "backend is $want (CSV_NATIVE_REQUIRE_BACKEND)";
}

done-testing;
