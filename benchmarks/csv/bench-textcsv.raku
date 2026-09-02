use Text::CSV;
sub best(&f, $n = 3) { (^$n).map({ my $t = now; f(); now - $t }).min }
my @rows;
my $parse = best({ @rows = csv(in => @*ARGS[0]) }, 1);
printf "%-8s Text::CSV rows=%d  parse %.0f ms\n", $*RAKU.compiler.name, @rows.elems, $parse*1000;
