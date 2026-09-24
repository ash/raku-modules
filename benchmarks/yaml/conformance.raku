#!/usr/bin/env raku
# Runs the yaml-test-suite cases under yaml-test-suite/ through YAML::Native,
# under whichever engine and backend runs this script.
#
#   a valid case    passes on events when the parse, printed as the suite's
#                   event stream, is the case's test.event line for line;
#                   and on data when the case has an in.json and
#                   from-yaml(:all) gives what that JSON says;
#                   and it round-trips when to-yaml writes that data and
#                   from-yaml reads the text back the same
#   an invalid case passes when the parse refuses it
#
# On Raku++ with the extension every case also goes through the Raku
# implementation, and the two must agree: the same events, the same data,
# the same error message.
#
#   cd YAML-Native && rakupp -Ilib ../benchmarks/yaml/conformance.raku [--verbose] [ID ...]

use YAML::Native;
use JSON::Fast;

sub MAIN(Bool :$verbose, *@only) {
    my $suite = $*PROGRAM.parent.add('yaml-test-suite');
    my @cases = $suite.dir.grep(*.d).map({ .add('in.yaml').e ?? $_ !! |.dir.grep(*.d) }).flat
        .grep(*.add('in.yaml').e).sort(*.Str);
    @cases .= grep({ my $id = .Str.substr($suite.Str.chars + 1); @only.first({ $id.starts-with($_) }) }) if @only;

    my $native = yaml-backend() eq 'native' && so &YAML::Native::events-raku;
    my %n is default(0);
    my @fail;
    for @cases -> $dir {
        my $id = $dir.Str.substr($suite.Str.chars + 1);
        my $text = $dir.add('in.yaml').slurp(:bin).decode;
        my $error = $dir.add('error').e;

        my $ev = try YAML::Native::events($text);
        my $ev-err = $! ?? $!.message !! Str;
        if $native {
            my $rev = try YAML::Native::events-raku($text);
            my $rerr = $! ?? $!.message !! Str;
            my $same = $ev-err.defined ?? ($rerr // '') eq $ev-err !! ($rev.defined && $rev eq $ev);
            %n<parity-events>++ if $same;
            %n<parity-total>++;
            @fail.push("$id parity: native {$ev-err // 'ok'} / raku {$rerr // 'ok'}") unless $same;
        }
        if $error {
            %n<invalid>++;
            if $ev-err.defined { %n<refused>++ }
            else { @fail.push("$id accepted an invalid document") }
            next;
        }
        %n<valid>++;
        my $want = $dir.add('test.event').slurp;
        if $ev-err.defined { @fail.push("$id refused: $ev-err"); next }
        if $ev eq $want { %n<events>++ }
        else { @fail.push("$id events differ" ~ ($verbose ?? "\n" ~ diff-lines($want, $ev) !! '')); next }

        my $docs = try from-yaml($text, :all);
        if $! {
            # a valid stream this module declines to construct: a mapping or
            # a sequence as a key has no Str to be, and a duplicate key is
            # an error YAML's events leave to the loader
            %n<declined>++;
            %n{"declined: " ~ $!.message.subst(/^ 'YAML::Native: ' /, '').subst(/ ' at line ' \d+ $/, '').subst(/\'.*\'/, "'…'")}++;
            @fail.push("$id from-yaml: {$!.message}") if $verbose;
            next;
        }
        %n<loads>++;
        if $native {
            my $rdocs = try YAML::Native::parse-raku($text, :all);
            if !$! && same-data($rdocs, $docs) { %n<parity-data>++ }
            else { @fail.push("$id parity: data differs") }
            %n<parity-data-total>++;
        }
        if $dir.add('in.json').e {
            %n<json>++;
            my @json = json-stream($dir.add('in.json').slurp);
            if same-data($docs, @json) { %n<data>++ }
            else { @fail.push("$id data differs: got {$docs.raku.substr(0, 200)}") }
        }
        # the writer, where the data is something it can write
        my $written = try to-yaml-all($docs);
        if $written.defined {
            %n<writable>++;
            my $back = try from-yaml($written, :all);
            if !$! && same-data($back, $docs) { %n<roundtrip>++ }
            else { @fail.push("$id round trip: {$! ?? $!.message !! 'data differs'}" ~ ($verbose ?? "\n$written" !! '')) }
        }
    }
    if $verbose || @fail < 40 { .say for @fail }
    say "engine {$*RAKU.compiler.name} {$*RAKU.compiler.version}, backend {yaml-backend()}";
    say "valid:   events {%n<events>}/{%n<valid>}, loads {%n<loads>}/{%n<valid>}, data {%n<data>}/{%n<json>}, round trip {%n<roundtrip>}/{%n<writable>}";
    say "  declined — {.key.substr(10)}: {.value}" for %n.grep(*.key.starts-with('declined: ')).sort;
    say "invalid: refused {%n<refused>}/{%n<invalid>}";
    say "parity:  events {%n<parity-events>}/{%n<parity-total>}, data {%n<parity-data>}/{%n<parity-data-total>}" if $native;
}

sub to-yaml-all($docs) {
    return Str unless &YAML::Native::to-yaml;
    $docs.map({ "---\n" ~ YAML::Native::to-yaml($_) }).join
}

sub diff-lines(Str $a, Str $b) {
    my @a = $a.lines; my @b = $b.lines;
    my @o;
    for ^max(@a, @b) -> $i {
        next if (@a[$i] // '') eq (@b[$i] // '');
        @o.push("  want: {@a[$i] // '<none>'}\n  got:  {@b[$i] // '<none>'}");
        last if @o >= 3;
    }
    @o.join("\n")
}

# in.json holds one JSON text per document, one after another
sub json-stream(Str $s) {
    my @out;
    my int $i = 0;
    my int $n = $s.chars;
    while $i < $n {
        $i++ while $i < $n && $s.substr($i, 1) ~~ /\s/;
        last if $i >= $n;
        my int $start = $i;
        my int $depth = 0;
        my Bool $str = False;
        repeat {
            my $c = $s.substr($i, 1);
            if $str {
                if $c eq '\\' { $i++ }
                elsif $c eq '"' { $str = False }
            }
            elsif $c eq '"' { $str = True }
            elsif $c eq '[' | '{' { $depth++ }
            elsif $c eq ']' | '}' { $depth-- }
            $i++;
        } while $i < $n && ($str || $depth > 0 || ($s.substr($i, 1) !~~ /\s/ && $s.substr($start, 1) ne '"' && $s.substr($start, 1) ne '[' && $s.substr($start, 1) ne '{'));
        @out.push(from-json($s.substr($start, $i - $start)));
    }
    @out
}

sub same-data($a, $b --> Bool) {
    if $a ~~ Positional && $b ~~ Positional {
        return False unless $a.elems == $b.elems;
        return so (^$a.elems).map({ same-data($a[$_], $b[$_]) }).all;
    }
    if $a ~~ Associative && $b ~~ Associative {
        return False unless $a.keys.sort eqv $b.keys.sort;
        return so $a.keys.map({ same-data($a{$_}, $b{$_}) }).all;
    }
    return !$b.defined if !$a.defined;
    return False if !$b.defined;
    if $a ~~ Bool || $b ~~ Bool { return $a ~~ Bool && $b ~~ Bool && $a == $b }
    if $a ~~ Numeric && $b ~~ Numeric {
        return True if $a.isNaN && $b.isNaN;
        return $a == $b;
    }
    return False if $a ~~ Numeric || $b ~~ Numeric;
    $a eq $b
}
