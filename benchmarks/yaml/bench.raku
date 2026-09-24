#!/usr/bin/env raku
# Times reading and writing one corpus: from-yaml(:all) on its text, and
# to-yaml on each document it read. Best of three, in milliseconds; the
# file is slurped before the clock starts.
#
#   raku -Ilib bench.raku corpus.yaml             # YAML::Native, this engine's backend
#   raku bench.raku --yamlish corpus.yaml         # the ecosystem's YAMLish, for comparison

sub MAIN(Str $file, Bool :$yamlish) {
    my $text = $file.IO.slurp;
    my (&read, &write, $what);
    if $yamlish {
        require YAMLish <&load-yamls &save-yaml>;
        &read  = &load-yamls;
        &write = &save-yaml;
        $what  = 'YAMLish';
    }
    else {
        require ::('YAML::Native');
        &read  = -> $t { ::('YAML::Native')::('&from-yaml')($t, :all) };
        &write = ::('YAML::Native')::('&to-yaml');
        $what  = "YAML::Native {::('YAML::Native')::('&yaml-backend')()}";
    }
    my ($r, $w) = Inf, Inf;
    my @docs;
    for ^3 {
        my $t0 = now;
        @docs = read($text);
        $r = min($r, now - $t0);
        $t0 = now;
        my $out = @docs.map({ "---\n" ~ write($_) }).join;
        $w = min($w, now - $t0);
    }
    printf "%s %s, %s: %d documents, %d bytes: read %d ms, write %d ms\n",
        $*RAKU.compiler.name, $*RAKU.compiler.version, $what, +@docs, $text.encode.bytes, $r * 1000, $w * 1000;
}
