use Test;
use JSON::Native;

# JSON Lines, read a window at a time. The oracle throughout is from-json
# itself: whatever json-each hands over must be what from-json returns for the
# same line. The window sizes go down to ONE BYTE on purpose — every framing
# bug lives at a boundary, and a 4 MiB default window hides all of them.

diag "json-backend: {json-backend}";

my $dir = $*TMPDIR.add("json-native-lines-{$*PID}");
$dir.mkdir;
LEAVE { .unlink for $dir.dir; $dir.rmdir }

my @sizes = 1, 2, 3, 7, 16, 97, 1000, 65536;

sub collect($src, *%opt) {
    my @got;
    json-each($src, |%opt, on-chunk => -> @v { @got.append(@v) });
    @got
}

# ---------------------------------------------------------------------------
# The corpus: one line per document, with the traps that matter. The \n inside
# the second string is ESCAPED — JSON forbids a raw newline in a string, which
# is exactly why a newline can be trusted as a record boundary — and a reader
# that unescaped before splitting would break the record in two.
my $nl   = "\\n";
my $acc  = "\c[LATIN SMALL LETTER E WITH ACUTE]";
my @docs = (
    '{"i":1,"s":"plain"}',
    '{"i":2,"s":"holds an escaped' ~ $nl ~ 'newline"}',
    '{"i":3,"s":"Sevilla caf' ~ $acc ~ '","deep":{"a":[1,2.5,true,null]}}',
    '{"i":4,"s":"last","n":123456789012345678901234567890}',
);
my $text = @docs.join("\n") ~ "\n";
my $file = $dir.add('docs.jsonl');
$file.spurt($text);

my @want = @docs.map({ from-json($_) });

# ---------------------------------------------------------------------------
# Every window size, every source spelling
for @sizes -> $w {
    is-deeply collect($file, :bytes($w)), @want, "a path at :bytes($w)";
}
for @sizes -> $w {
    is-deeply collect($text, :bytes($w)), @want, "a Str at :bytes($w)";
}
for @sizes -> $w {
    my $fh = $file.open(:r, :bin);
    is-deeply collect($fh, :bytes($w)), @want, "a binary handle at :bytes($w)";
    $fh.close;
}

# A multi-byte character must survive a window boundary falling inside it. The
# é is two bytes, so some small window splits it; the carry is bytes, so it
# must still decode. (The record cut itself is at a '\n' byte, which being
# ASCII can never be a continuation byte.)
ok @want[2]<s>.contains($acc), 'the corpus really does hold a non-ASCII character';
for 1 .. 24 -> $w {
    is-deeply collect($file, :bytes($w))[2]<s>, @want[2]<s>,
        "a 2-byte character survives :bytes($w)";
}

# ---------------------------------------------------------------------------
# Workers: the same records, in order
for 2, 4, 8 -> $k {
    is-deeply collect($file, :workers($k)), @want, ":workers($k) gives the same records in order";
    is-deeply collect($file, :workers($k), :bytes(3)), @want, ":workers($k) at a 3-byte window";
}

# ---------------------------------------------------------------------------
# json-stream agrees with json-each
is-deeply json-stream($file).Array, @want, 'json-stream gives the same values';
is-deeply json-stream($text).Array, @want, 'json-stream over a Str';
is-deeply json-stream($file, :bytes(2)).Array, @want, 'json-stream at a 2-byte window';
is-deeply json-stream($file).head(2).Array, @want[^2].Array, 'json-stream can be taken from the front';

# ---------------------------------------------------------------------------
# Shapes of file
my %edge =
    'a single document, no trailing newline' => '{"a":1}',
    'a trailing newline'                     => "\{\"a\":1\}\n",
    'blank lines between records'             => "\{\"a\":1\}\n\n\n\{\"a\":2\}\n",
    'whitespace-only lines'                   => "\{\"a\":1\}\n   \n\t\n\{\"a\":2\}\n",
    'CRLF line endings'                       => "\{\"a\":1\}\r\n\{\"a\":2\}\r\n",
    'a bare scalar per line'                  => "1\n2.5\ntrue\nnull\n",
    'arrays as documents'                     => "[1,2]\n[3]\n",
;
for %edge.sort -> $case {
    my $f = $dir.add('edge.jsonl');
    $f.spurt($case.value);
    my @expect = $case.value.lines.grep(*.trim).map({ from-json($_.subst(/\r$/, '')) });
    for 1, 3, 65536 -> $w {
        is-deeply collect($f, :bytes($w)), @expect, "{$case.key} at :bytes($w)";
    }
}

# An empty file, and one of only blank lines, yield nothing rather than failing
for '', "\n", "\n\n   \n" -> $empty {
    my $f = $dir.add('empty.jsonl');
    $f.spurt($empty);
    is-deeply collect($f), [], "a file of {$empty.chars} whitespace characters yields no records";
}

# ---------------------------------------------------------------------------
# Options reach the parser
my $imm = $dir.add('imm.jsonl');
$imm.spurt("\{\"a\":[1,2]\}\n");
is collect($imm, :immutable)[0].^name, 'Map', ':immutable reaches the parser';

# ---------------------------------------------------------------------------
# Failure: the message names the line the bad document was on
my $bad = $dir.add('bad.jsonl');
$bad.spurt("\{\"a\":1\}\n\{\"a\":2\}\n\{oops\}\n\{\"a\":4\}\n");
throws-like { collect($bad) }, Exception, :message(/'line 3'/),
    'a malformed document names its line number';
throws-like { collect($bad, :bytes(2)) }, Exception, :message(/'line 3'/),
    'and names it whatever the window size';

# The consumer's own exception passes through unchanged
throws-like { json-each($file, on-chunk => -> @v { die "mine" }) }, Exception,
    :message(/mine/), "a consumer's own exception is not swallowed";

# ---------------------------------------------------------------------------
# Cleanup: a path is opened here, so it must be closed here — including when
# the consumer dies. Counting open descriptors is the only way to see it.
sub fds() { "/dev/fd".IO.dir.elems }
my $before = fds();
for ^5 { collect($file) }
is fds(), $before, 'a completed read leaves no descriptor open';
for ^5 { try json-each($file, on-chunk => -> @v { die "boom" }) }
is fds(), $before, 'a read whose consumer dies still closes the file';

# A handle belongs to its caller: json-each must not close it
my $own = $file.open(:r, :bin);
collect($own);
ok $own.opened, 'a handle the caller opened is left open';
$own.close;

# ---------------------------------------------------------------------------
# Refusals
throws-like { json-each($file, :bytes(0), on-chunk => -> @v { }) }, Exception,
    :message(/':bytes'/), ':bytes(0) is refused';
throws-like { json-each($file, :workers(0), on-chunk => -> @v { }) }, Exception,
    :message(/':workers'/), ':workers(0) is refused';

done-testing;
