use CSV::Native;
my $text = @*ARGS[0].IO.slurp;
my $t = now; my @rows = from-csv($text); my $p = now - $t;
$t = now; my $out = to-csv(@rows); my $w = now - $t;
printf "%-8s backend=%-6s %7d bytes rows=%d  parse %.0f ms  write %.0f ms\n",
    $*RAKU.compiler.name, csv-backend, $text.encode.bytes, @rows.elems, $p*1000, $w*1000;
