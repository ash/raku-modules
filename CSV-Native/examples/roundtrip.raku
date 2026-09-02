# Read a CSV text as records, change it, write it back — and show which
# implementation answered.
#
#   raku   -Ilib examples/roundtrip.raku
#   rakupp -Ilib examples/roundtrip.raku

use CSV::Native;

my $text = q:to/CSV/;
    id,name,note
    1,Ada,"likes ""engines"", commas, and
    line breaks"
    2,Grace,
    CSV

my @recs = from-csv($text, :headers);
say "{@recs.elems} records via the {csv-backend()} backend";
say @recs[0]<note>;                      # the quoted field, decoded

.<name> = .<name>.uc for @recs;
print to-csv(@recs, :headers<id name note>);
