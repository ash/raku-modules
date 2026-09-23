# Times from-toml and to-toml on one file: best of three, in milliseconds.
#
#   cd TOML-Native
#   rakupp -Ilib ../benchmarks/toml/bench.raku ../benchmarks/toml/corpus-10k.toml
#   rakudo -Ilib ../benchmarks/toml/bench.raku ../benchmarks/toml/corpus-10k.toml
#   TOML_NATIVE_BACKEND=raku rakupp -Ilib ../benchmarks/toml/bench.raku ...

use TOML::Native;

my $file = @*ARGS[0].IO;
my $text = $file.slurp;
my %data;
my (@parse, @write);
for ^3 {
    my $t = now;
    %data = from-toml($text);
    @parse.push(now - $t);
    $t = now;
    my $out = to-toml(%data);
    @write.push(now - $t);
}
printf "%s %s, backend %s, %s: %d packages, parse %d ms, write %d ms\n",
    $*RAKU.compiler.name, $*RAKU.compiler.version, toml-backend(), $file.basename,
    %data<package>.elems, @parse.min * 1000, @write.min * 1000;
