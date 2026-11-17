# Read and write one JSON Lines file with whichever module -M loaded, best of
# N runs, and the same work done a line at a time with from-json and to-json,
# the loop a program would write without from-jsonl. Only JSON::Native has
# from-jsonl and to-jsonl; under another module the jsonl columns show "-".
# Run from JSON-Native/ so -Ilib finds the module:
#
#   cd JSON-Native
#   rakupp -Ilib -MJSON::Native ../benchmarks/sample-data/bench-jsonl.raku ../benchmarks/sample-data/large.jsonl
#   raku   -Ilib -MJSON::Fast   ../benchmarks/sample-data/bench-jsonl.raku ../benchmarks/sample-data/medium.jsonl 5
my $file  = @*ARGS[0];
my $runs  = (@*ARGS[1] // 3).Int;
my $text  = $file.IO.slurp;
my $bytes = $text.encode.bytes;
sub best(&f) { (^$runs).map({ my $t = now; f(); now - $t }).min }

my &from-lines = (try ::('&from-jsonl')) // Nil;
my &to-lines   = (try ::('&to-jsonl'))   // Nil;
my @data;
my $loop-read  = best({ @data = $text.lines.grep(*.trim).map({ from-json($_) }) });
my $loop-write = best({ @data.map({ to-json($_, :!pretty) ~ "\n" }).join });
my $read  = &from-lines ?? best({ @data = from-lines($text) }) !! Nil;
my $write = &to-lines   ?? best({ to-lines(@data) })           !! Nil;

sub show($s) {
    !$s.defined ?? sprintf('%11s', '-')
                !! $s < 1e-3 ?? sprintf('%8.2f µs', $s * 1e6) !! sprintf('%8.1f ms', $s * 1e3)
}
# json-backend exists only under JSON::Native
my &jb = (try ::('&json-backend')) // Nil;
my $backend = &jb ?? jb() ~ '/' ~ jb(:write) !! '-';
printf "%-8s %-19s %-12s %7d lines %10d B  from-jsonl %s  loop %s  to-jsonl %s  loop %s\n",
    $*RAKU.compiler.name, $backend, $file.IO.basename, +@data, $bytes,
    show($read), show($loop-read), show($write), show($loop-write);
