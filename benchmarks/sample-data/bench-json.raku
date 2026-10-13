# Parse and write one JSON file with whichever module -M loaded, best of N
# runs, in milliseconds. Run from JSON-Native/ so -Ilib finds the module:
#
#   cd JSON-Native
#   rakupp -Ilib -MJSON::Native ../benchmarks/sample-data/bench-json.raku ../benchmarks/sample-data/large.json
#   raku   -Ilib -MJSON::Fast   ../benchmarks/sample-data/bench-json.raku ../benchmarks/sample-data/medium.json 5
my $file = @*ARGS[0];
my $runs = (@*ARGS[1] // 3).Int;
my $text = $file.IO.slurp;
sub best(&f) { (^$runs).map({ my $t = now; f(); now - $t }).min }
my $data;
my $parse = best({ $data = from-json($text) });
my $write = best({ to-json($data) });
# json-backend exists only under JSON::Native
my &jb = (try ::('&json-backend')) // Nil;
my $backend = &jb ?? jb() ~ '/' ~ jb(:write) !! '-';
printf "%-8s %-13s %-10s %8.1f MB  parse %9.1f ms  write %9.1f ms\n",
    $*RAKU.compiler.name, $backend, $file.IO.basename, $text.encode.bytes / 1e6, $parse*1000, $write*1000;
