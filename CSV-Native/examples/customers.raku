# The README's walkthrough, runnable: every flow there is this file, and the
# comments are what it prints. Written files go to $*TMPDIR.
#
#   raku   -Ilib examples/customers.raku
#   rakupp -Ilib examples/customers.raku

use CSV::Native;

my $file = "t/mock-customers.csv".IO;

# rows
my @rows = from-csv($file);
say @rows.elems;                                     # 1001
say @rows[0];
say @rows[1][2..5];                                  # (Ada Easley Wonka Labs Sevilla)

# records
my @customers = from-csv($file, :headers);
say @customers.elems;                                # 1000
say @customers[0]<Company City>;                     # (Wonka Labs Sevilla)
say @customers[0]{'First Name'};                     # Ada
say @customers[16]<Notes>;                           # said "call me", then left
say @customers.grep(*<Company>.contains(',')).elems; # 302

# which implementation answered
say csv-backend();

# writing: a slice of the rows is a valid file, header line included
my $three = $*TMPDIR.add("csv-native-three-{$*PID}.csv");
$three.spurt(to-csv(@rows[^3]));
print $three.slurp;

# records, with the columns chosen and ordered — names with spaces need a
# real list, `<Index First Name>` would be three words
my $vips = $*TMPDIR.add("csv-native-vips-{$*PID}.csv");
my @vips = @customers.grep(*<Notes> eq 'VIP');
$vips.spurt(to-csv(@vips, :headers('Index', 'First Name', 'Company')));
print $vips.slurp;
say from-csv($vips, :headers).elems;                 # 10

# round trip: the file was written minimally quoted, so it comes back byte
# for byte — in LF form, because .slurp turns CRLF into LF on the way in
say to-csv(@rows) eq $file.slurp;                    # True

.unlink for $three, $vips;
