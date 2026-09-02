use Test;
use CSV::Native;

# A whole file rather than a hand-written case: t/mock-customers.csv is 1,000
# invented customer records in the shape of a real export — quoted company
# names holding commas, non-ASCII cities, three multi-line notes, CRLF line
# endings. Every number below was established once and is pinned; the file
# does not change.

my $native = csv-backend() eq 'native';
diag "csv-backend: {csv-backend}";

my $file = $*PROGRAM.parent.add('mock-customers.csv');
plan 17 + ($native ?? 2 !! 0);

ok $file.e, 'the mock file ships with the distribution';

my @rows = from-csv($file);
is @rows.elems, 1001, '1,001 rows: the header line and 1,000 records';
is-deeply @rows.map(*.elems).unique.List, (12,), 'every row has 12 fields';
is-deeply @rows[0],
    ['Index', 'Customer Id', 'First Name', 'Last Name', 'Company', 'City', 'Country',
     'Phone', 'Email', 'Subscription Date', 'Website', 'Notes'],
    'the header row';
is-deeply @rows[1][^7], ('1', '40e938d90c5a9fc', 'Ada', 'Easley', 'Wonka Labs', 'Sevilla', 'Spain'),
    'the first record';
is @rows[*-1][0], '1000', 'the last record is number 1000';

my @customers = from-csv($file, :headers);
is @customers.elems, 1000, ':headers gives 1,000 records';
is-deeply @customers[0]{'Index', 'First Name', 'City', 'Notes'}, ('1', 'Ada', 'Sevilla', ''),
    'a record is keyed by the header, an empty field is an empty Str';
is @customers[16]<Notes>, 'said "call me", then left', 'a doubled quote is decoded';
is @customers[249]<Notes>, "prefers post\nsecond line of the note",
    'a line ending inside a quoted field is content';
is @customers.grep(*<Company>.contains(',')).elems, 302, '302 quoted company names';
is @customers.grep(*<Notes> eq 'VIP').elems, 10, 'ten VIPs';
is @customers.map(*<Country>).unique.elems, 18, '18 countries, non-ASCII cities among them';

# A handle reads the same records as a path
is from-csv($file.open).elems, 1001, 'an IO::Handle reads the same file';

# Round trips. The file was written minimally quoted, so it comes back byte
# for byte in LF form — .slurp turns CRLF into LF on both engines, and so
# does from-csv's own reading of an IO::Path, which is what makes the two
# sides equal.
is to-csv(@rows), $file.slurp, 'writing the rows back reproduces the file';
is-deeply from-csv(to-csv(@customers, :headers(@rows[0])), :headers), @customers,
    'records survive a write and a read';

# :strict holds on a regular file
lives-ok { from-csv($file, :strict) }, ':strict passes a file whose records are all one width';

# On Raku++ with the extension, the Raku implementation must agree on the
# whole file too — not only on the small cases. Kept to the first 200 records
# because Raku++'s positional Str operations make the Raku parser quadratic
# today (README, "Measured"); the parity of the full file is the same test at
# a cost nobody should pay on every run.
if $native {
    my $head = $file.slurp.lines[^201].join("\n") ~ "\n";
    is-deeply CSV::Native::parse-raku($head), from-csv($head), 'raku agrees on 200 records';
    is CSV::Native::write-raku(from-csv($head)), to-csv(from-csv($head)), 'and writes them the same';
}

done-testing;
