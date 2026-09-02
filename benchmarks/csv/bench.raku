use CSV::Native;
my $text = @*ARGS[0].IO.slurp;
sub best(&f, $n = 3) { (^$n).map({ my $t = now; f(); now - $t }).min }
my @rows;
my $parse = best({ @rows = from-csv($text) });
my @recs;
my $parse-h = best({ @recs = from-csv($text, :headers) });
my $write = best({ to-csv(@rows) });
my $write-h = best({ to-csv(@recs) });
printf "%-8s backend=%-6s rows=%d  parse %.0f ms  parse:headers %.0f ms  write %.0f ms  write:hashes %.0f ms\n",
    $*RAKU.compiler.name, csv-backend, @rows.elems, $parse*1000, $parse-h*1000, $write*1000, $write-h*1000;
