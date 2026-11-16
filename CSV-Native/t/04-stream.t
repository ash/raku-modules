use Test;
use CSV::Native;

# The streaming reader, held to ONE standard: for any source and any window
# size, `csv-each` and `csv-stream` deliver exactly the records `from-csv`
# delivers for the same source, and a malformed file fails with the same
# message naming the same line. A streamed read that is merely close is not
# worth having — the whole point is that a program can swap one for the other
# when the file outgrows memory.
#
# The window sizes are deliberately absurd. `:bytes(1)` exercises every
# boundary at once: a multi-byte character split across reads, a CRLF split
# down the middle, a record longer than the window, a quoted field spanning
# windows. Those are the bugs this reader can have, and a 4 MiB window finds
# none of them — the CRLF-split-across-reads bug passed every window of four
# million bytes and failed every window of one, three and a thousand.

my $native = csv-backend() eq 'native';
diag "csv-backend: {csv-backend}";

my $file = $*PROGRAM.parent.add('mock-customers.csv');

sub streamed($src, |c) {
    my @all;
    csv-each($src, |c, on-chunk => -> @recs { @all.append(@recs) });
    @all
}
sub err(&c) { my $m = ''; { c(); CATCH { default { $m = .message } } }; $m }

my @windows = 1, 2, 3, 7, 16, 97, 1000, 65536;
# `done-testing` rather than a plan: the count is a function of @windows and
# %edge below, and an arithmetic plan that drifts from them tests the
# arithmetic rather than the reader.

for False, True -> $headers {
    my $what = $headers ?? ':headers' !! 'rows';
    my @want = from-csv($file, :$headers);

    ok @want.elems > 999, "$what: the mock file reads as {@want.elems} records";
    is-deeply streamed($file, :$headers), @want, "$what: a default window agrees with from-csv";
    is-deeply csv-stream($file, :$headers).Array, @want, "$what: csv-stream agrees with from-csv";

    for @windows -> $bytes {
        is-deeply streamed($file, :$headers, :$bytes), @want,
            "$what: :bytes($bytes) — a split codepoint, CRLF and record all land right";
        is-deeply csv-stream($file, :$headers, :$bytes).Array, @want,
            "$what: csv-stream at :bytes($bytes)";
    }

    # Every source spelling reads the same records.
    is-deeply streamed($file.slurp, :$headers, :bytes(997)), @want, "$what: a Str source";
    is-deeply streamed($file.open(:r), :$headers, :bytes(997)), @want, "$what: a text handle";
    is-deeply streamed($file.open(:bin), :$headers, :bytes(997)), @want, "$what: a binary handle";
}

# Parallel windows change nothing but the wall clock: same records, same order.
my @want = from-csv($file, :headers);
for 2, 4, 8 -> $workers {
    is-deeply streamed($file, :headers, :$workers, :bytes(20_000)), @want,
        ":workers($workers) delivers the same records in the same order";
}
is-deeply streamed($file, :headers, :workers(4), :bytes(1)), @want,
    ':workers(4) with a one-byte window — the first window is still what names the columns';
is-deeply streamed($file, :headers(from-csv($file)[0].List), :bytes(300)),
    from-csv($file, :headers(from-csv($file)[0].List)),
    ':headers as a list of names: every record is data';
ok streamed($file, :headers, :bytes(1 +< 22)).elems == @want.elems,
    'a window larger than the file is one window';

# Errors: the same message, the same line, whatever the window or the worker
# count. The quote is planted deep enough that it cannot be in the first
# window at any of these sizes.
my $good = (1..400).map({ "a$_,b$_,c$_" }).join("\n") ~ "\n";
my %bad =
    'an unterminated quoted field' => $good.subst("a200,", "a200,\"oops,"),
    'a quote inside an unquoted field' => $good.subst("a200,", "a2\"00,"),
    'text after a closing quote'    => $good.subst("a200,", "\"a200\"x,"),
;
for %bad.sort -> (:key($what), :value($text)) {
    my $want = err { from-csv($text) };
    ok $want.starts-with('CSV::Native:'), "from-csv rejects $what: $want";
    is err({ streamed($text, :bytes(97)) }), $want, "  streamed, same message and line";
    is err({ streamed($text, :bytes(97), :workers(4)) }), $want, "  and with four workers";
}

# `:strict` measures every record against the FIRST record of the FILE, not of
# the window it happens to fall in — the one thing a window cannot work out
# for itself.
my $ragged = $good.subst("a200,b200,c200", "a200,b200");
is err({ streamed($ragged, :strict, :bytes(97)) }), err({ from-csv($ragged, :strict) }),
    ':strict names the same line as from-csv';
is err({ streamed($ragged, :strict, :bytes(97), :workers(4)) }), err({ from-csv($ragged, :strict) }),
    ':strict holds across workers';
ok err({ streamed($good, :strict, :bytes(97)) }) eq '', ':strict passes a file of one width';
is err({ streamed("a,b\n1,2\n", :headers, :bytes(3)) }), '', 'a short file with headers is fine';

# The edges, at three window sizes each.
my %edge =
    'an empty source'               => '',
    'a header and no records'       => "a,b,c\n",
    'a header with no line ending'  => "a,b,c",
    'no trailing line ending'       => "a,b\n1,2",
    'a blank line in the middle'    => "a,b\n\n1,2\n",
    'a byte-order mark'             => "\x[FEFF]a,b\n1,2\n",
    'CRLF and a multi-line field'   => "a,b\r\n1,\"x\r\ny\"\r\n2,z\r\n",
    'a lone CR as the terminator'   => "a,b\r1,2\r",
    'a quoted field holding only a line ending' => "a\n\"x\ny\"\n",
;
for %edge.sort -> (:key($what), :value($text)) {
    my $file-of-it = $*TMPDIR.add("csv-native-stream-{$*PID}.csv");
    $file-of-it.spurt($text);
    LEAVE { $file-of-it.unlink }
    for False, True -> $headers {
        my @w = from-csv($file-of-it, :$headers);
        ok (1, 3, 1 +< 22).map({ streamed($file-of-it, :$headers, :bytes($_)) eqv @w }).all,
            "$what (:headers $headers) reads the same at every window size";
    }
}

# A handle the caller opened stays the caller's: the reader closes only the
# file it opened itself, so a program can go on reading from where it left off.
{
    my $h = $file.open(:bin);
    streamed($h, :headers, :bytes(1000));
    ok $h.opened, 'a handle passed in is left open';
    $h.close;
}
ok csv-each($file, :headers, on-chunk => -> @r { }), 'csv-each answers True';

# A consumer that dies gets ITS OWN error, and the reader still closes the
# file it opened. Counting descriptors is the only way to SEE that: nothing
# in the language reports a handle left open, and with the cleanup removed
# this test goes from 5 descriptors to 10 while every other test still passes.
{
    my $msg = 'the consumer said no';
    my $got = '';
    {
        csv-each($file, :headers, :bytes(2000), :workers(4), on-chunk => -> @r {
            state $n = 0;
            die $msg if ++$n == 2;
        });
        CATCH { default { $got = .message } }
    }
    is $got, $msg, "a consumer's own exception comes through unchanged";

    if "/dev/fd".IO.d {
        my sub fds() { +"/dev/fd".IO.dir }
        my $base = fds();
        for ^5 {
            { csv-each($file, :headers, :bytes(2000), on-chunk => -> @r { die 'stop' });
              CATCH { default { } } }
        }
        is fds(), $base, 'a read abandoned by a dying consumer closes its file';

        $base = fds();
        for ^5 {
            { csv-each($file, :headers, :bytes(2000), :workers(4),
                       on-chunk => -> @r { die 'stop' });
              CATCH { default { } } }
        }
        is fds(), $base, 'and so does one with workers outstanding';
    }
    else {
        skip 'no /dev/fd to count descriptors with', 2;
    }
}

done-testing;
