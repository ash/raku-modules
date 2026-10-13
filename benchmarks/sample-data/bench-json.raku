# Parse and write one JSON file with whichever module -M loaded, best of N
# runs. A small file is parsed and written many times in a run, enough to
# make a megabyte, and the time of one call is reported. Run from
# JSON-Native/ so -Ilib finds the module:
#
#   cd JSON-Native
#   rakupp -Ilib -MJSON::Native ../benchmarks/sample-data/bench-json.raku ../benchmarks/sample-data/large.json
#   raku   -Ilib -MJSON::Fast   ../benchmarks/sample-data/bench-json.raku ../benchmarks/sample-data/tiny.json 5
my $file  = @*ARGS[0];
my $runs  = (@*ARGS[1] // 3).Int;
my $text  = $file.IO.slurp;
my $bytes = $text.encode.bytes;
my $calls = max 1, 1_000_000 div $bytes;
sub best(&f) { (^$runs).map({ my $t = now; f() for ^$calls; (now - $t) / $calls }).min }
my $data;
my $parse = best({ $data = from-json($text) });
my $write = best({ to-json($data) });
sub show($s) { $s < 1e-3 ?? sprintf('%8.2f µs', $s * 1e6) !! sprintf('%8.1f ms', $s * 1e3) }
# json-backend exists only under JSON::Native
my &jb = (try ::('&json-backend')) // Nil;
my $backend = &jb ?? jb() ~ '/' ~ jb(:write) !! '-';
printf "%-8s %-13s %-11s %9d B  parse %s  write %s\n",
    $*RAKU.compiler.name, $backend, $file.IO.basename, $bytes, show($parse), show($write);
