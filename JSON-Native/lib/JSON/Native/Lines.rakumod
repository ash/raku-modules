unit module JSON::Native::Lines;

# JSON Lines, read a window at a time.
#
# Why this can stream where from-json cannot: a JSON document is one value, so
# a parser has nothing to hand back until it has read all of it. JSONL is one
# document per LINE, and the JSON grammar forbids a raw newline inside a string
# — it has to be written \n or \u000A — so in valid JSONL a newline is ALWAYS a
# record boundary. That is the whole trick: this reader splits, it does not
# parse, and a window can be cut at any newline without understanding what is
# in it. CSV::Native's reader cannot do that, because a quoted CSV field may
# hold a real line break, so there the cut needs a quote-parity scan.
#
# The cut is made at a '\n' BYTE. '\n' is ASCII, so it is never a UTF-8
# continuation byte, and a cut there cannot split a codepoint either — which is
# why there is no partial-codepoint carry here, only a partial-line one.
#
# The reader is binary on purpose. Text-mode handle reads retain every decoded
# character for the lifetime of the handle on Raku++ 5.8.0 (rakupp #262), about
# 35 bytes a character for readchars and 6 for get, so a windowed read through
# them is bounded by the file rather than by the window. `.read` is flat.

constant \NL = 0x0A;
constant \CR = 0x0D;

# A byte source: a handle, or a Blob already in memory (a Str source is encoded
# once and windowed the same way, so there is a single path through the rest).
my sub byte-reader($src) {
    if $src ~~ Blob {
        my Int $pos = 0;
        return (sub (Int $n) {
            return Buf.new if $pos >= $src.elems;
            my $end = ($pos + $n) min $src.elems;
            my $out = $src.subbuf($pos, $end - $pos);
            $pos = $end;
            $out
        }, sub () { });
    }
    my $fh = $src ~~ IO::Path ?? $src.open(:r, :bin) !! $src;
    my Bool $close-it = $src ~~ IO::Path;
    (sub (Int $n) { $fh.read($n) }, sub () { $fh.close if $close-it })
}

# The index just past the last newline in $b, or 0 if it holds none.
my sub last-nl(Blob:D $b --> Int) {
    my Int $i = $b.elems - 1;
    while $i >= 0 {
        return $i + 1 if $b.read-uint8($i) == NL;
        $i = $i - 1;
    }
    0
}

# The split pieces paired with their line numbers, blank ones dropped.
#
# Every piece but the last was ended by a newline. The last one is a line only
# at EOF: anywhere else it is the start of a line the next window finishes, and
# the caller has already kept it as the carry, so it must not be parsed here.
#
# Blank lines are dropped rather than refused: a JSONL file ends with a newline,
# which makes the final piece empty, and an empty line is not a document.
# One pass: pick the lines out and parse them. Framing used to cost more than
# parsing did — 1.8s against 1.1s for 699,000 lines — and all of it was per-line
# work this avoids: a Pair and an intermediate array for every line, a `.trim`
# that allocates a second Str, and a CATCH installed once per line rather than
# once per window.
# Every line in here is run 700,000 times for a 100 MB file, and on Raku++ the
# obvious spellings are not the quick ones — measured over 699,000 lines:
#
#   for @pieces -> $raw { … }         0.10s     while + @pieces[$i]   0.50s
#   $raw.trim                         0.33s     $raw.ord             0.49s
#   my $raw = …                                 my $raw := …        +0.22s
#
# So: a `for` rather than an indexed `while`, `.trim` rather than reading the
# first codepoint, and no binding. The last piece is dropped with one `pop`
# instead of an index test on every line, and the line number is worked out
# only when something actually fails, which takes an add and a store off every
# line. Together these took framing from 1.83s to the figure in the README,
# where it had been costing more than the parsing it fed.
# @pieces arrives with the carry piece already removed and is not copied here:
# `is copy` on an array parameter copies every element, which for a 4 MiB
# window is the whole window again.
my sub parse-window(@pieces, Int:D $first, Bool:D $cr, &parse, %opt --> Array) {
    my @vals;
    my Bool $opts = %opt.elems > 0;
    my Int $idx = 0;

    # One handler for the window, not one per line. $idx has already been
    # stepped past the failing line, hence the -1.
    CATCH { default { die "JSON::Native: JSONL line {$first + $idx - 1}: {.message}" } }

    for @pieces -> $raw {
        $idx = $idx + 1;
        next unless $raw.trim;
        my $text = $cr && $raw.ends-with("\r") ?? $raw.chop !! $raw;
        @vals.push($opts ?? parse($text, |%opt) !! parse($text));
    }
    @vals
}

# The pull side: hands back one parsed batch at a time, and never holds more
# than the window (times the worker count) in bytes.
my sub line-source($src, :&parse!, Int:D :$bytes!, Int:D :$workers!, *%opt) {
    # Checked here rather than in each caller, so json-stream refuses the same
    # arguments json-each does, and before anything is opened.
    die "JSON::Native: :bytes must be at least 1" if $bytes < 1;
    die "JSON::Native: :workers must be at least 1" if $workers < 1;
    my ($read, $close) = byte-reader($src ~~ Str ?? $src.encode('utf-8') !! $src);
    my Buf $carry = Buf.new;
    my Int $line = 1;
    my Bool $eof = False;
    my Bool $spent = False;
    my @pending;

    my sub drain-unawaited() {
        for @pending { try await $_ }
        @pending = ();
    }
    my sub close-all() {
        return if $spent;
        $spent = True;
        drain-unawaited();
        try $close();
    }

    # The next window as (@pieces, first-line, at-eof); () once the input is
    # done. The pieces are handed over unexamined — picking the lines out and
    # parsing them is one pass in parse-window, and on the worker path that
    # pass happens off this thread.
    my sub next-window(--> List) {
        loop {
            return () if $eof && !$carry.elems;
            my $chunk = $eof ?? Buf.new !! $read($bytes);
            $eof = True unless $chunk.defined && $chunk.elems;
            # .append rather than building a Buf from .list: a 4 MiB window as a
            # list of Ints is millions of boxed values per read.
            my $got = $chunk // Buf.new;
            $carry.append($got) if $got.elems;
            my Int $cut = $eof ?? $carry.elems !! last-nl($carry);
            next if !$cut && !$eof;          # no newline yet: read more
            return () unless $cut;
            my $ready = $carry.subbuf(0, $cut);
            $carry = $cut < $carry.elems ?? $carry.subbuf($cut) !! Buf.new;

            # Decoded and split once. Every piece but the last is a line the
            # window ended, so the counter advances by that many; at EOF the
            # last piece is a line too, and there is nothing after it.
            #
            # CRLF is normalised BEFORE the split, because "\r\n" is a single
            # grapheme in Raku — `"a\r\nb".chars` is 3 — so split("\n") does
            # not see it and a CRLF file would come back as one long line.
            my $t = $ready.decode('utf-8');
            $t = $t.subst("\r\n", "\n", :g) if $t.contains("\r\n");
            my @pieces = $t.split("\n");
            my $first = $line;
            $line = $line + @pieces.elems - 1;

            # The carry piece comes off here, where the array is owned, so the
            # parsing pass needs neither a copy nor a test on every line.
            @pieces.pop unless $eof;

            # Whether any '\r' is left after the normalisation above — only a
            # file whose endings are neither LF nor CRLF has one. Checked once
            # per window so the per-line chop can be skipped entirely.
            return (@pieces, $first, $t.contains("\r"));
        }
    }

    my sub next-batch() {
        return Nil if $spent;
        CATCH { default { close-all(); .rethrow } }
        loop {
            if $workers <= 1 {
                my ($pieces, $first, $cr) = next-window();
                unless $pieces {
                    close-all();
                    return Nil;
                }
                my $vals = parse-window($pieces, $first, $cr, &parse, %opt);
                # A window of nothing but blank lines yields no values; read on
                # rather than handing the consumer an empty batch.
                next unless $vals.elems;
                return $vals;
            }
            # Keep up to $workers windows in flight, deliver oldest first.
            while @pending.elems < $workers {
                my ($pieces, $first, $cr) = next-window();
                last unless $pieces;
                @pending.push(start { parse-window($pieces, $first, $cr, &parse, %opt) });
            }
            unless @pending {
                close-all();
                return Nil;
            }
            my $vals = await @pending.shift;
            next unless $vals.elems;
            return $vals;
        }
    }

    (&next-batch, &close-all)
}

#| Read a JSONL source a window at a time, handing each window's parsed values
#| to :on-chunk. Memory is set by :bytes (times :workers), not by the file.
#
# 64 KiB, because a bigger window is slower as well as heavier — its decoded
# text and the lines split out of it stop fitting in cache, and every pass over
# them pays. 100 MB of JSONL reads in 1.86s and 31 MiB here against 2.04s and
# 249 MiB at 4 MiB; with :workers the times level out but the memory gap stays.
# Below about 32 KiB the per-window overhead takes over instead.
our sub json-each($src, :&on-chunk!, :&parse!, Int:D :$bytes = 1 +< 16,
                  Int:D :$workers = 1, *%opt) {
    my (&next-batch, &close-all) = line-source($src, :&parse, :$bytes, :$workers, |%opt);
    # Guarded: the LEAVE also runs when line-source itself threw, and calling
    # an unassigned &close-all would replace that exception with a method error.
    LEAVE { close-all() if &close-all.defined }
    loop {
        my $batch = next-batch();
        last without $batch;
        on-chunk($batch);
    }
    Nil
}

#| The same reading as a lazy sequence of values. NOT bounded on Raku++ 5.8.0:
#| a Seq there retains every value it yields (rakupp #263). Use json-each for a
#| file you cannot hold.
our sub json-stream($src, :&parse!, Int:D :$bytes = 1 +< 16,
                    Int:D :$workers = 1, *%opt) {
    my (&next-batch, &close-all) = line-source($src, :&parse, :$bytes, :$workers, |%opt);
    Seq.new(class :: does Iterator {
        has @!vals;
        has Int $!i = 0;
        has Bool $!done = False;
        method pull-one() {
            loop {
                return IterationEnd if $!done;
                if $!i < @!vals.elems {
                    return @!vals[$!i++];
                }
                my $batch = next-batch();
                without $batch {
                    $!done = True;
                    return IterationEnd;
                }
                @!vals = @$batch;
                $!i = 0;
            }
        }
    }.new)
}
