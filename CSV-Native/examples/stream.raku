# Read a file too big to hold: one window at a time, with a bounded footprint.
#
#   raku   -Ilib examples/stream.raku t/mock-customers.csv
#   rakupp -Ilib examples/stream.raku t/mock-customers.csv
#
# The same program reads a file of any size. `from-csv` on the same input
# would build every record first: with `:headers`, 851 MB of CSV becomes about
# 17 GB of Raku values, while this stays under 92 MB — the file's size stops
# being the question.

use CSV::Native;

my $file = (@*ARGS[0] // 't/mock-customers.csv').IO;
die "no such file: $file" unless $file.e;

# `csv-each` hands over an Array of records per window. Totals accumulate, the
# records do not: a window is dropped before the next is read, which is what
# keeps the footprint flat.
my %by-country;
my $records = 0;
csv-each($file, :headers, on-chunk => -> @recs {
    $records += @recs.elems;
    %by-country{.<Country>}++ for @recs;
});

say "$records records, {%by-country.elems} countries, via the {csv-backend()} backend";
say "  $_: %by-country{$_}" for %by-country.keys.sort.head(5);

# `csv-stream` is the same reading as a lazy sequence, for when a loop over
# records reads better than a loop over windows. On Raku++ 5.8.0 prefer
# `csv-each` for a file you cannot hold: see the README's Streaming section.
my $first-vip = csv-stream($file, :headers).first(*<Notes> eq 'VIP');
# A key with a space needs a real string — `<First Name>` is two words.
say "first VIP: {$first-vip{'First Name'}} {$first-vip{'Last Name'}}" with $first-vip;

# `:workers` parses windows in parallel on Raku++. Two is the whole gain;
# past that the reader, not the parser, is the limit.
my $rows = 0;
csv-each($file, :workers(2), on-chunk => -> @recs { $rows += @recs.elems });
say "$rows rows again, with two workers";
