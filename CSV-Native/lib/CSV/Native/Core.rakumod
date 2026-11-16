=begin pod

=head1 CSV::Native

A CSV parser and writer with a native fast path on Raku++, and a pure-Raku
implementation everywhere else. No dependencies.

The XS pattern: the distribution ships C source, the build step compiles it
against Raku++'s extension ABI, and the module uses it when it is there. On
Rakudo — or on a Raku++ without the built extension — the same specification
runs as plain Raku from this file. The same program runs on both.

=head2 Synopsis

    use CSV::Native;

    my @rows = from-csv("a,b\n1,\"x,y\"\n");   # [["a","b"],["1","x,y"]]
    my @recs = from-csv("a,b\n1,2\n", :headers);   # [{a => "1", b => "2"}]
    my @recs = from-csv("data.csv".IO, :headers, :sep<;>);

    say to-csv([[1, "two", "3,4"]]);             # 1,two,"3,4"\n
    say to-csv(@recs, :headers<b a>);            # a header line, then rows

    say csv-backend;                             # 'native' or 'raku'

=head2 The format

RFC 4180, read strictly and written minimally. Fields are C<Str>, always — a
CSV file carries no types, and inventing them would be the one thing a
drop-in parser must not do. A quoted field may hold the separator, the quote
(doubled) and line endings; anything after a closing quote other than a
separator or a line ending is an error, and so is a quote inside an unquoted
field. LF, CRLF and a lone CR all end a record; a trailing line ending does
not start an empty record, but a blank line in the middle is one record with
one empty field. A leading UTF-8 byte-order mark is dropped.

Every error names its line. The native and the Raku implementation raise the
same message for the same input, which the test suite checks.

=end pod

unit module CSV::Native::Core;

# THE IMPLEMENTATION LIVES HERE, and the thin CSV/Native.rakumod beside it is
# the importable face. The split exists for one reason: Data::Native has to
# delegate its `csv` tag to this distribution — CSV is the one family with no
# ecosystem reference to stand in for it — and a module that `use`s a
# claim-protocol participant runs that participant's EXPORT into its OWN scope,
# leaving an announcement in the registry that cannot be told apart from one the
# caller made. Data::Native would then stand aside from its own names.
#
# A package with `our` subs and no export protocol has no such hazard: `need
# CSV::Native::Core` loads it and runs no EXPORT at all (probed, both engines).
# So this half is reachable by full name and announces nothing, and CSV::Native
# next door does the importing and the cooperating.

# `&::(…)` is a RUNTIME lookup, so this line compiles on Rakudo too — where it
# simply yields Nil and the module runs its own Raku implementation. Anything
# spelled `use Rakupp::Ext` would have made the file uncompilable there.
# The probe sits in a SUB, and that is load-bearing rather than tidiness. A
# bare `my &ext-load = try &::('rakupp-ext-load');` at module scope leaves the
# caught exception in this file's `$!`, and on Rakudo that makes the whole
# module unserializable the moment ANOTHER MODULE `use`s it: precompiling the
# importer walks this one's state and dies with
#
#     Missing serialize REPR function for REPR VMException (BOOTException)
#
# It only shows up when a module imports the module — a program importing it
# directly precompiles nothing and works — which is exactly why it survived
# until Data::Native tried to depend on this. A `do {}` block is NOT enough;
# `$!` is scoped to the routine, so a sub is.
sub probe-symbol(Str $name) {
    my $c = try &::($name);
    $c ~~ Callable ?? $c !! Nil
}
my &ext-load = probe-symbol('rakupp-ext-load');
my &native-parse;
my &native-write;
my &native-cut;
my &native-read;

# Where the compiled half might be. %?RESOURCES is the installed answer and
# works on both engines; the CWD form covers a git checkout tested with -Ilib.
# NOT $?FILE-relative: under Raku++ a module's $?FILE is the main program's.
sub libraries() {
    my $ext = $*DISTRO.is-win ?? 'dll' !! ($*KERNEL.name eq 'darwin' ?? 'dylib' !! 'so');
    my $stem = $*DISTRO.is-win ?? "csv.$ext" !! "libcsv.$ext";
    my @c;
    with (try %?RESOURCES<libraries/csv>) { @c.push($_) if .defined }
    @c.push($*CWD.add("resources/libraries/$stem"));
    @c
}

sub load-native(--> Bool) {
    return False unless &ext-load;
    # CSV_NATIVE_BACKEND=raku forces the Raku implementation on a Raku++ that
    # has the extension: for measuring the two against each other, and for a
    # user who suspects the native path and wants to know in one run.
    return False if (%*ENV<CSV_NATIVE_BACKEND> // '') eq 'raku';
    for libraries() -> $lib {
        next unless $lib.IO.e;
        next unless try ext-load($lib.Str);
        # The loader installs the extension's subs into THIS scope.
        &native-parse = try &::('from-csv-native');
        &native-write = try &::('to-csv-native');
        # The cutter arrived with streaming. An extension built from older C
        # source will not have it, so it is probed separately and the streaming
        # reader falls back to the Raku cutter rather than to no streaming.
        &native-cut  = try &::('csv-cut-native');
        &native-read = try &::('csv-read-native');
        return True if &native-parse && &native-write;
    }
    False
}

my Bool $is-native = load-native();

# Which implementation is answering: 'native' (the compiled extension) or
# 'raku' (this file).
our sub csv-backend() {
    $is-native ?? 'native' !! 'raku'
}

# The dialect is validated ONCE, here, so both implementations receive options
# they can trust: a separator that contains the quote or a line ending has no
# reading, and a quote of more than one character has no doubling rule.
sub check-dialect(Str:D $sep, Str:D $quote) {
    die "CSV::Native: sep must not be empty" unless $sep.chars;
    die "CSV::Native: quote must be exactly one character, not '$quote'"
        unless $quote.chars == 1;
    die "CSV::Native: quote must not be a line ending" if $quote eq "\n" | "\r";
    die "CSV::Native: sep must not contain the quote character" if $sep.contains($quote);
    die "CSV::Native: sep must not contain a line ending"
        if $sep.contains("\n") || $sep.contains("\r");
}

# :headers, normalised: True (the first record names the columns), a List of
# names (every record is data), or False. `<a>` is a Str, not a one-element
# list, so a lone name is accepted as one.
sub header-names($headers) {
    given $headers {
        when Bool       { $_ }
        when Str        { ($_,) }
        when Positional { .map(*.Str).List }
        when .defined   { die "CSV::Native: headers must be a Bool or a list of names" }
        default         { False }
    }
}

sub check-dups(@names) {
    my %seen;
    for @names -> $n {
        die "CSV::Native: duplicate header '$n'" if %seen{$n}++;
    }
}

# ---- parsing ----------------------------------------------------------------

our sub from-csv($src, Str:D :$sep = ',', Str:D :$quote = '"', :$headers,
                 Bool:D :$strict = False) {
    check-dialect($sep, $quote);
    my $names = header-names($headers);
    my Str $text = $src ~~ IO::Path   ?? $src.slurp
                !! $src ~~ IO::Handle ?? $src.slurp
                !!                       $src.Str;
    $is-native
        ?? native-parse($text, :$sep, :$quote, :headers($names), :$strict)
        !! parse-raku($text, :$sep, :$quote, :headers($names), :$strict)
}

# The Raku implementation of the parser — the reference the extension is held
# to, and what runs on Rakudo. Reachable by its full name so a test can run
# the same input through both.
#
# Line-oriented, and built on `split` rather than on a character scanner. The
# text is split into lines with their terminators kept; a line without a
# quote in it is one `split` on the separator; a line that holds a quote is
# gathered with the lines that follow it while its quotes are unbalanced (a
# quoted field may span lines) and then split on the QUOTE: the pieces at
# even positions are outside quotes, those at odd positions inside, and an
# empty outside piece between two inside ones is a doubled quote. Every rule
# of the format is then a check on a piece: the outside text before an
# opening quote must end at a separator, the outside text after a closing
# one must start at a separator or end the record.
#
# Why not scan the whole text with `.index($needle, $pos)`, the obvious
# shape? Because on Raku++ every `index` costs the whole string wherever the
# match is (13 ms per call on 800 KB, measured 2026-09-02), so that scanner
# was quadratic there — a thousand rows took twelve seconds — and on Rakudo a
# per-record scanner was slower than this by three times. `lines`, `split`
# and `contains` are linear on both engines, and this never asks either for a
# position except to name the line of an error.
our sub parse-raku(Str:D $text, Str:D :$sep = ',', Str:D :$quote = '"', :$headers,
                   Bool:D :$strict = False,
                   # Streaming. A chunk is a slice of a bigger file, so three
                   # things the whole-file call assumes stop holding: its first
                   # line is not line 1, its record width was fixed by a record
                   # in an earlier chunk, and only the chunk at offset 0 may
                   # carry a BOM. A chunk cannot infer any of the three.
                   Int:D :$first-line = 1, Int :$expect, Bool:D :$bom = True) {
    # from-csv validates the whole dialect; these two are repeated here because
    # an empty needle is found at every position, and a split that produces
    # nothing but empty pieces is not an answer — a direct caller deserves the
    # error.
    die "CSV::Native: sep must not be empty"   unless $sep.chars;
    die "CSV::Native: quote must be exactly one character, not '$quote'" unless $quote.chars == 1;
    my $s = ($bom && $text.starts-with("\x[FEFF]")) ?? $text.substr(1) !! $text;

    # The lines. A text with no CR in it — every file read through .slurp,
    # which turns CRLF into LF — is one plain `split`, and the terminator
    # between any two lines is "\n". Otherwise the three terminators are
    # split out in turn, CRLF first (it is one grapheme on both engines, and
    # the lone "\n" and "\r" that remain cannot be halves of one), and the
    # lines are listed alternating with the terminator that followed each,
    # so that a field spanning lines is put back together exactly.
    #
    # Plain splits, never `split(..., :v)`: on Rakudo the :v form is
    # quadratic (18 ms for 10,000 lines, 2 s for 100,000 — measured
    # 2026-09-02), and it was most of this parser's time until it went.
    my @pieces;
    my Bool $terms = $s.contains("\r") || $s.contains("\r\n");
    if $terms {
        for $s.split("\r\n").kv -> $oi, $o {
            @pieces.push("\r\n") if $oi;
            for $o.split("\n").kv -> $pi, $p {
                @pieces.push("\n") if $pi;
                for $p.split("\r").kv -> $li, $l {
                    @pieces.push("\r") if $li;
                    @pieces.push($l);
                }
            }
        }
    }
    else {
        @pieces = $s.split("\n");
    }
    my int $step = $terms ?? 2 !! 1;   # from one line to the next in @pieces

    my @names;
    my Bool $want-header = False;
    my $expected;
    given $headers {
        when Positional { @names = .list; check-dups(@names); $expected = @names.elems }
        when Bool       { $want-header = $_ }
    }
    $expected = $expect if !$expected.defined && $expect.defined;

    my @rows;
    my sub emit(Int $row-line, @cells) {
        if $want-header && !@names {
            @names = @cells;
            check-dups(@names);
            $expected = @names.elems;
            return;
        }
        if $strict {
            $expected //= @cells.elems;
            die "CSV::Native: line $row-line has {@cells.elems} fields, expected $expected"
                if @cells.elems != $expected;
        }
        if @names {
            die "CSV::Native: line $row-line has {@cells.elems} fields but the header has {@names.elems}"
                if @cells.elems > @names.elems;
            my %h;
            %h{@names[$_]} = @cells[$_] for ^@cells.elems;
            @rows.push(%h);
        }
        else {
            @rows.push(@cells);
        }
    }

    my int $n = @pieces.elems;
    my int $i = 0;
    my int $line = $first-line;
    while $i < $n {
        my $text = @pieces[$i];
        # the text after the last terminator is a record only if there is one
        last if $i == $n - 1 && $text eq '';
        if !$text.contains($quote) {
            emit($line, $text.split($sep).Array);
            $i = $i + $step;
            $line = $line + 1;
        }
        else {
            # gather the lines that follow while the quotes stay unbalanced:
            # the field runs on, or the record is malformed and the check
            # below will say so at the line the field started on, exactly as
            # the extension does. A line with an odd number of quotes flips
            # the balance; the record is split on the quote once, at the end.
            my $rec = $text;
            my @p = $text.split($quote);
            my Bool $open = @p.elems %% 2;      # an even piece count is an odd quote count
            my int $j = $i + $step;             # the next line
            if $open {
                while $open && $j < $n {
                    my $next = @pieces[$j];
                    $rec ~= ($terms ?? @pieces[$j - 1] !! "\n") ~ $next;
                    $open = !$open if $next.split($quote).elems %% 2;
                    $j = $j + $step;
                }
                @p = $rec.split($quote);
            }
            emit($line, quoted-record($rec, @p, $line, $sep, $quote));
            $line = $line + ($j - $i) div $step;
            $i = $j;
        }
    }
    @rows
}

# One record whose text holds a quote, already split on the quote into @p.
# Returns its fields; dies, naming the line a field started on, exactly where
# the extension would. $start is the line the record starts on.
sub quoted-record(Str:D $rec, @p, Int:D $start, Str:D $sep, Str:D $quote) {
    my int $last = @p.elems - 1;
    my @cells;
    # the outside text before the first quote: whole fields, then an empty
    # fragment — a quoted field opens only at the start or after a separator
    my @f = @p[0].split($sep);
    my $lastf = @f.pop;
    @cells.append(@f);
    die "CSV::Native: a quote inside an unquoted field at line {line-of-piece($rec, @p, $start, 1, 1 + $lastf.chars)}"
        if $lastf ne '';
    my int $k = 1;
    loop {
        # @p[$k] is inside a quoted field; the piece after it is outside —
        # unless that piece is empty and another inside piece follows, which
        # is a doubled quote: one quote of content
        my int $opened = $k;
        my $field = @p[$k];
        $k = $k + 1;
        die "CSV::Native: unterminated quoted field starting at line {line-of-piece($rec, @p, $start, $opened, 1)}"
            if $k > $last;
        while @p[$k] eq '' && $k < $last {
            $k = $k + 1;
            $field ~= $quote ~ @p[$k];
            $k = $k + 1;
            die "CSV::Native: unterminated quoted field starting at line {line-of-piece($rec, @p, $start, $opened, 1)}"
                if $k > $last;
        }
        @cells.push($field);
        # the outside text after the closing quote: nothing, or a separator
        # and whole fields — and, when another quote follows, an empty last
        # fragment again
        my $out = @p[$k];
        last if $k == $last && $out eq '';
        my @g = $out.split($sep);
        die "CSV::Native: text after a closing quote at line {line-of-piece($rec, @p, $start, $opened, 1)}"
            if @g.shift ne '';
        if $k == $last {
            @cells.append(@g);
            last;
        }
        my $lastg = @g.pop;
        @cells.append(@g);
        die "CSV::Native: a quote inside an unquoted field at line {line-of-piece($rec, @p, $start, $k + 1, 1 + $lastg.chars)}"
            if $lastg ne '';
        $k = $k + 1;
    }
    @cells
}

# The line on which piece $k of a record split on the quote begins, $back
# characters earlier. Only an error needs it, so offsets are computed here
# and not carried: piece $k starts after the pieces before it and the $k
# quotes between them.
sub line-of-piece(Str:D $rec, @p, Int:D $start, Int:D $k, Int:D $back) {
    my $off = [+](@p[^$k].map(*.chars)) + $k - $back;
    $start + count-lines($rec.substr(0, $off))
}

# Line endings in a stretch of text, counted the way the reader would: CRLF
# is one, and so is a lone CR or LF — and since CRLF is one grapheme, each
# line ending is exactly one character to count. The three `contains` checks
# keep the (much more common) single-line text off the character walk.
sub count-lines(Str:D $s) {
    return 0 unless $s.contains("\n") || $s.contains("\r") || $s.contains("\r\n");
    $s.comb.grep({ $_ eq "\r\n" | "\n" | "\r" }).elems
}

# ---- writing ----------------------------------------------------------------

# :headers, resolved for the writer into the column names (possibly none) and
# whether to write them as the first line:
#   - a list of names: those columns, header line written;
#   - hash rows with no :headers: the first row's keys, sorted (Rakudo
#     randomises hash order per process, so the sorted order is the only one
#     both engines can agree on), header line written;
#   - :!headers with hash rows: the same columns, no header line;
#   - list rows with no :headers: no names, no header line.
our sub to-csv(@rows, Str:D :$sep = ',', Str:D :$quote = '"', Str:D :$eol = "\n",
               :$headers, Bool:D :$always-quote = False) {
    check-dialect($sep, $quote);
    die "CSV::Native: eol must be \\n, \\r\\n or \\r" unless $eol eq "\n" | "\r\n" | "\r";
    my $names = header-names($headers);
    my @names;
    my Bool $line;
    if $names ~~ Positional {
        @names = @$names;
        $line = True;
    }
    elsif @rows && @rows[0] ~~ Associative {
        @names = @rows[0].keys.sort;
        $line = $headers ~~ Bool ?? $headers !! True;   # only :!headers says no
    }
    else {
        $line = False;
    }
    $is-native
        ?? native-write(@rows.item, :$sep, :$quote, :$eol, :headers(@names.List),
                        :header-line($line), :$always-quote)
        !! write-raku(@rows, :$sep, :$quote, :$eol, :@names, :header-line($line), :$always-quote)
}

# The Raku implementation of the writer; the same contract as the extension's.
our sub write-raku(@rows, Str:D :$sep = ',', Str:D :$quote = '"', Str:D :$eol = "\n",
                   :@names, Bool:D :$header-line = False, Bool:D :$always-quote = False) {
    my $doubled = $quote x 2;
    my sub cell($v) {
        my $s = $v.defined ?? $v.Str !! '';
        # all three line endings, since CRLF is one grapheme and a search for
        # either half does not find it
        if $always-quote || $s.contains($sep) || $s.contains($quote)
                         || $s.contains("\n") || $s.contains("\r") || $s.contains("\r\n") {
            $quote ~ $s.subst($quote, $doubled, :g) ~ $quote
        }
        else {
            $s
        }
    }
    my @out;
    @out.push(@names.map(&cell).join($sep) ~ $eol) if $header-line;
    for @rows.kv -> $i, $row {
        my @cells = do given $row {
            when Associative {
                die "CSV::Native: row $i is a hash but no headers are known" unless @names;
                @names.map({ $row{$_} })
            }
            when Positional { $row.list }
            default { die "CSV::Native: row $i is not a list or a hash" }
        };
        @out.push(@cells.map(&cell).join($sep) ~ $eol);
    }
    @out.join
}

# ---- streaming --------------------------------------------------------------
#
# `from-csv` reads the whole text and builds the whole table. That is the right
# shape for a file you can hold, and the wrong one for a file you cannot: 85 MB
# of CSV becomes about 1.6 GB of Raku values, so the ceiling is not the disk but
# the multiple — roughly 15x — between a file and its parsed form.
#
# `csv-each` reads a window at a time and parses it on its own, so what is alive
# at once is one window of text and one window of records, whatever the file's
# size. Reading is `readchars`, never `lines`: a byte-or-character read of an
# 851 MB file peaks at 8 MB, while walking it with `lines` or `get` peaks at
# 332 MB, because every line becomes a Str the parser then has to be handed
# again. One `readchars` of four million characters costs one Str.
#
# The hard part is not the reading, it is WHERE TO CUT. A fixed-size read ends
# wherever it ends — mid-record, and worse, possibly inside a quoted field,
# where a line ending is content and not a record end. Cutting on a line is
# wrong for the same reason, and wrong silently: splitting `t/mock-customers.csv`
# every 1,000 lines fails with `unterminated quoted field starting at line
# 1000`, and splitting it every 20,000 lines happened to work, which is worse.
# So `cut-chunk` finds the last line ending that sits OUTSIDE a quoted field,
# and that is always a record boundary.

# Line endings in a stretch of text, counted the way the reader counts them:
# CRLF is one, and so is a lone CR or LF. Three splits rather than the
# character walk `count-lines` does, because a chunk is megabytes: CRLF is one
# grapheme, so `split("\n")` does not see it and `split("\r")` does not either,
# which makes the three counts disjoint and their sum the answer.
sub count-terms(Str:D $s) {
    return 0 unless $s.contains("\n") || $s.contains("\r");
    my $n = $s.split("\n").elems - 1;
    $n += ($s.split("\r\n").elems - 1) + ($s.split("\r").elems - 1) if $s.contains("\r");
    $n
}

# Where the buffer's last complete record ends: ($ready, $rest, $terminators).
# `:first` asks for the FIRST boundary instead, which is how the header line
# comes off the front of a file whose header may itself span lines.
#
# The pure-Raku half splits ONCE on the quote. The pieces at even indices are
# the text outside quoted fields — a doubled quote toggles the state twice and
# so leaves it alone, which makes parity the whole rule — so a line ending in
# an even piece ends a record, and one in an odd piece is field content. Only
# the pieces actually examined have their offsets computed, from whichever end
# the search runs: the answer is usually in the first or last piece, and a
# chunk of 50,000 quoted rows has 200,000 pieces whose offsets nobody needs.
sub cut-raku(Str:D $buf, Str:D $quote, Bool :$first = False) {
    my @q = $buf.split($quote);
    my $cut;
    if $first {
        my int $off = 0;
        for @q.kv -> $i, $p {
            if $i %% 2 {
                with first-eol($p) { $cut = $off + $_ + 1; last }
            }
            $off = $off + $p.chars + 1;      # the piece, and the quote after it
        }
    }
    else {
        my int $tail = 0;                    # characters after this piece ends
        for (^@q.elems).reverse -> $i {
            my $p = @q[$i];
            if $i %% 2 {
                with last-eol($p) { $cut = $buf.chars - $tail - $p.chars + $_ + 1; last }
            }
            $tail = $tail + $p.chars + 1;    # the piece, and the quote before it
        }
    }
    return ('', $buf, 0) without $cut;
    my $ready = $buf.substr(0, $cut);
    ($ready, $buf.substr($cut), count-terms($ready))
}

# The first and last line ending in a piece. "\r\n" is one grapheme, so a
# search for "\n" does not find it and a search for "\r" does not either —
# all three spellings have to be asked for, and the index that comes back is
# the whole ending's, which is why `+ 1` past it is right for CRLF too.
sub first-eol(Str:D $p) {
    my @i = ($p.index("\n"), $p.index("\r"), $p.index("\r\n")).grep(*.defined);
    @i ?? @i.min !! Nil
}
sub last-eol(Str:D $p) {
    my @i = ($p.rindex("\n"), $p.rindex("\r"), $p.rindex("\r\n")).grep(*.defined);
    @i ?? @i.max !! Nil
}

sub cut-chunk(Str:D $buf, Str:D $quote, Bool :$first = False) {
    &native-cut
        ?? native-cut($buf, :$quote, :$first).List
        !! cut-raku($buf, $quote, :$first)
}

# One chunk, through whichever implementation is in play. The three streaming
# options are what make a slice of a file parse as that slice: its errors name
# file-global lines, its record width is the one the file's first record set,
# and only the chunk at offset 0 is allowed to drop a byte-order mark.
sub parse-chunk(Str:D $text, Str:D :$sep!, Str:D :$quote!, :$headers!,
                Bool:D :$strict!, Int:D :$first-line!, Int :$expect,
                Bool:D :$bom!) {
    $is-native
        ?? native-parse($text, :$sep, :$quote, :$headers, :$strict,
                        :$first-line, :$expect, :$bom)
        !! parse-raku($text, :$sep, :$quote, :$headers, :$strict,
                      :$first-line, :$expect, :$bom)
}

# Bytes in, text out. The reader is binary and NOT `readchars`, and that is the
# single most consequential line in this file: on Raku++ 5.8.0, reading an
# 85 MB file with `readchars` and discarding every window peaks at 2.9 GB, and
# the same loop over 851 MB peaks at 29.6 GB — O(the file), whatever the window
# size, which is exactly the thing streaming exists to avoid. The same loop on
# `.read` peaks at 83 MB for 851 MB. (Rakudo's `readchars` is better behaved but
# still six times the file.) So this reads bytes and decodes each window itself.
#
# Decoding a window is only safe at a boundary the encoding agrees with, and
# there are two:
#
#  * A multi-byte UTF-8 sequence must not be split, or the window ends in a
#    replacement character and the next one begins with another.
#  * A CRLF must not be split, because the two halves would decode as two
#    separate line endings — and a record boundary where there is none is a
#    wrong answer rather than a slow one.
#
# `utf8-cut` answers where the window may end, and whatever it holds back is
# carried into the next read.
# Plain `Int`, not `int`: a native integer used to index a Buf is "This
# container does not reference a native integer" on Rakudo, and this runs once
# per window — four million bytes apart — so the declaration buys nothing.
sub utf8-cut(Buf:D $b --> Int) {
    my Int $n = $b.elems;
    return 0 if $n == 0;
    my Int $cut = $n;
    # A trailing CR is held back: its LF may be the next read's first byte.
    $cut = $cut - 1 if $b.read-uint8($cut - 1) == 0x0D;
    return 0 if $cut == 0;
    # Walk back over continuation bytes (10xxxxxx) to the sequence's lead byte.
    my Int $i = $cut - 1;
    while $i >= 0 && ($b.read-uint8($i) +& 0xC0) == 0x80 { $i = $i - 1 }
    return $cut if $i < 0;
    my Int $lead = $b.read-uint8($i);
    return $cut if $lead < 0x80;          # the window ends on an ASCII byte
    my Int $need = $lead >= 0xF0 ?? 4 !! ($lead >= 0xE0 ?? 3 !! ($lead >= 0xC0 ?? 2 !! 1));
    $i + $need <= $cut ?? $cut !! $i      # an incomplete sequence waits
}

# A window of bytes as the text `from-csv` would have seen. Reading a file
# through `slurp` or `readchars` goes through the engine's line-ending
# handling, which turns CRLF into LF — inside quoted fields too — while
# `decode` does not; a lone CR is left alone by both. So the normalisation is
# exactly CRLF to LF, and with it a streamed read of a CRLF file gives the
# same records, byte for byte, as reading the whole of it.
sub decode-window(Buf:D $b --> Str) {
    my $t = $b.decode('utf-8');
    $t.contains("\r\n") ?? $t.subst("\r\n", "\n", :g) !! $t
}
# The reader, as a source that is PULLED rather than one that pushes. Both
# public spellings are this one generator: `csv-each` calls it in a loop, and
# `csv-stream` wraps it in an iterator. It answers the next Array of records,
# or Nil when the input is spent.
#
# Pulled rather than push-only because `csv-stream` cannot be built on `gather`
# and `take`. Taking is lazy on both engines, but on Raku++ 5.8.0 what has been
# taken is never released: five million takes of a one-key hash peak at 2.0 GB,
# and the same loop without the gather peaks at 3.7 MB. A lazy sequence built
# that way would stream the file and still hold all of it, which is the bug
# this module is meant to fix rather than relocate.
sub chunk-source($src, Str:D :$sep!, Str:D :$quote!, :$headers!, Bool:D :$strict!,
                 Int:D :$bytes!, Int:D :$workers!) {
    my $names-opt = header-names($headers);

    # A Str source has nothing to stream: it is already whole in memory, and
    # the window machinery below takes it as one buffer that never refills.
    # Accepted so a program can hand over either without branching.
    my $fh = do given $src {
        when IO::Path   { .open(:bin) }
        when IO::Handle { $_ }       # `.read` answers on a text handle too
        default         { Nil }
    };
    my Bool $close-it = $src ~~ IO::Path;
    my Str  $buf      = $fh ?? '' !! $src.Str;
    my Bool $drained  = !$fh.defined;
    my Buf  $carry    = Buf.new;     # bytes held back from the last window

    my @names = $names-opt ~~ Positional ?? $names-opt.list !! ();
    check-dups(@names) if @names;
    my Int  $expect;
    my Int  $line     = 1;
    my Bool $at-start = True;        # only the first window may carry a BOM
    my Bool $primed   = False;
    my Bool $spent    = False;
    my Bool $closed   = False;
    my @pending;

    my sub close-input() {
        return if $closed;
        $closed = True;
        $fh.close if $close-it && $fh;
    }

    # The next window of whole records, as ($text, $terminators), or () when
    # the input is spent. A window holding no complete record is not an
    # answer — it is a record longer than the window, so the loop reads more
    # rather than cutting where there is no boundary.
    # Raku++ with the extension: the window of bytes goes straight to C, which
    # decodes it, collapses CRLF and cuts it at the last record boundary in ONE
    # pass. Nothing becomes a Raku string until it is the text of whole
    # records, and the leftover stays bytes. That matters more than it sounds:
    # with the reading done in Raku it cost MORE than the parsing it feeds, so
    # `:workers` had almost nothing to divide.
    my sub next-text-native() {
        loop {
            my $got = $drained ?? Nil !! $fh.read($bytes);
            if $got.defined && $got.elems {
                my $b = $carry.elems ?? ($carry ~ $got) !! $got;
                my ($ready, $rest, $terms) = native-read($b, :$quote).List;
                $carry = $rest;
                next unless $ready.chars;      # no whole record in hand yet
                return ($ready, $terms);
            }
            unless $drained { $drained = True; close-input() }
            return () unless $carry.elems;
            # The tail: everything left is text, terminated or not.
            my ($ready, $rest, $terms) = native-read($carry, :$quote, :eof).List;
            $carry = Buf.new;
            return $ready.chars ?? ($ready, $terms) !! ();
        }
    }

    my sub next-text-raku() {
        loop {
            if !$drained {
                my $got = $fh.read($bytes);
                if $got.defined && $got.elems {
                    my $b   = $carry.elems ?? ($carry ~ $got) !! $got;
                    my $cut = utf8-cut($b);
                    $carry  = $cut < $b.elems ?? Buf.new($b[$cut ..^ $b.elems]) !! Buf.new;
                    $buf ~= decode-window($b.subbuf(0, $cut)) if $cut;
                }
                else {
                    # End of the file. What was held back can only be a
                    # trailing CR or a truncated sequence, and both are text.
                    if $carry.elems { $buf ~= decode-window($carry); $carry = Buf.new }
                    $drained = True;
                    close-input();
                }
            }
            if $drained {
                return () unless $buf.chars;
                my $all = $buf;
                $buf = '';
                return ($all, count-terms($all));   # the tail, newline or not
            }
            my ($ready, $rest, $terms) = cut-chunk($buf, $quote);
            next unless $ready.chars;
            $buf = $rest;
            return ($ready, $terms);
        }
    }

    # A Str source has no handle to read, so it always takes the Raku path,
    # which hands the whole buffer over as one window.
    my &next-text = ($fh && &native-read) ?? &next-text-native !! &next-text-raku;

    my sub parse-at(Str $text, Int $first-line, Bool $bom) {
        parse-chunk($text, :$sep, :$quote, :$strict, :$expect, :$bom,
                    :first-line($first-line),
                    :headers(@names ?? @names.List !! False))
    }

    # A broken promise nobody awaits is an unhandled exception at exit, and by
    # then the error that matters has already been raised.
    my sub drain-unawaited() {
        for @pending { try await $_ }
        @pending = ();
    }

    sub next-records() {
        return Nil if $spent;
        # On the way out through an exception: no worker is left holding a
        # broken promise nobody awaited, and the handle does not wait for the
        # collector. A normal return leaves the source open for the next pull.
        CATCH { default { $spent = True; drain-unawaited(); close-input(); .rethrow } }

        loop {
            my ($text, $terms) = next-text();
            unless $text.defined {
                # Input spent: hand back whatever the workers still hold,
                # oldest first, so a malformed window reports in file order.
                return await @pending.shift if @pending;
                $spent = True;
                close-input();
                return Nil;
            }

            # The header line comes off the first window before anything is
            # read as data: every later window, and every worker, needs the
            # names. It may itself span lines, so it is cut at the first
            # boundary and not at the first newline.
            if !$primed && $names-opt ~~ Bool && $names-opt {
                my ($hrec, $hrest, $ht) = cut-chunk($text, $quote, :first);
                # A header with no line ending after it is the whole window,
                # which is also the whole file: a header-only file has no
                # data records.
                ($hrec, $hrest, $ht) = ($text, '', $terms) unless $hrec.chars;
                @names = parse-chunk($hrec, :$sep, :$quote, :headers(False),
                                     :strict(False), :first-line($line),
                                     :bom($at-start))[0].List;
                check-dups(@names);
                $at-start = False;
                $line    += $ht;
                $text     = $hrest;
                $terms   -= $ht;
            }

            my $first-line = $line;
            $line += $terms;
            unless $text.chars { $primed = True; next }

            # The first data window is parsed HERE, in this thread, whatever
            # `:workers` says: under `:strict` it is what fixes the record
            # width for the file, and a worker cannot be handed a width that
            # has not been established yet.
            if !$primed || $workers == 1 {
                my @recs = parse-at($text, $first-line, $at-start);
                $expect   = @recs[0].elems if $strict && !@names && !$primed && @recs;
                $at-start = False;
                $primed   = True;
                return @recs;
            }

            @pending.push(start { parse-at($text, $first-line, False) });
            # At most two windows per worker are ever outstanding. Starting
            # every window up front would put the whole file back in memory,
            # which is the thing this avoids.
            next if @pending.elems < 2 * $workers;
            return await @pending.shift;
        }
    }

    # Handed back beside the generator, because the generator only learns
    # about ITS own failures. A consumer that dies — or stops pulling, which
    # `last` in a loop over the records does — would otherwise leave the
    # handle for the collector and leave a worker holding a promise nobody
    # awaits, which surfaces as an unhandled exception at exit. Idempotent, so
    # the LEAVE that normally runs after the input is spent costs nothing.
    my sub close-all() {
        $spent = True;
        drain-unawaited();
        close-input();
    }

    (&next-records, &close-all)
}

#| Read a CSV source a window at a time, calling `&on-chunk` with an Array of
#| records per window, in file order. What is alive at once is one window of
#| text and one window of records, whatever the file's size: 851 MB of CSV and
#| ten million records go through in 150 MB, where `from-csv` on the same file
#| would need about 16 GB.
#|
#| Options are `from-csv`'s — `:sep`, `:quote`, `:headers`, `:strict` — plus:
#|
#|   :bytes    bytes read at a time (default 4Mi) — the window
#|   :workers  windows parsed in parallel (default 1, serial)
#|
#| The records are the ones `from-csv` returns for the same source, and an
#| error carries the same message and the same line number, which is what the
#| test suite holds this to.
# 64 KiB rather than something bigger, because bigger is slower AS WELL AS
# heavier: a window's decoded text and its parsed records are walked several
# times over, and once the window stops fitting in cache every pass pays for
# it. On a 204 MB file with :headers this default reads in 1.70s and 31 MiB
# where a 4 MiB window took 1.97s and 385 MiB — a tenth of the memory and
# faster with it. Below about 32 KiB the per-window overhead starts to show
# instead (2.13s at 8 KiB), so this sits just past that.
our sub csv-each($src, :&on-chunk!, Str:D :$sep = ',', Str:D :$quote = '"',
                 :$headers, Bool:D :$strict = False,
                 Int:D :$bytes = 1 +< 16, Int:D :$workers = 1) {
    check-dialect($sep, $quote);
    die "CSV::Native: bytes must be at least 1"   if $bytes   < 1;
    die "CSV::Native: workers must be at least 1" if $workers < 1;
    my (&next-records, &close-all) = chunk-source($src, :$sep, :$quote,
                                                  :$headers, :$strict,
                                                  :$bytes, :$workers);
    # On every way out, including one through `&on-chunk`'s own exception.
    LEAVE close-all();
    loop {
        my $recs = next-records();
        last without $recs;
        on-chunk($recs);
    }
    True
}

#| The same reading, as a lazy sequence of records:
#|
#|     for csv-stream("huge.csv".IO, :headers) -> %rec { ... }
#|
#| Bounded the same way as `csv-each` as long as the caller does not keep the
#| records — `.Array` on the result is `from-csv` with extra steps. A hand-rolled
#| iterator and not `gather`/`take`: see `chunk-source` for why that matters.
#|
#| A sequence ABANDONED part way — `.first`, or `last` in a loop over it —
#| cannot know it was abandoned, so the file it opened is closed by the
#| collector rather than there and then. `csv-each` closes deterministically;
#| prefer it when that matters.
our sub csv-stream($src, Str:D :$sep = ',', Str:D :$quote = '"', :$headers,
                   Bool:D :$strict = False,
                   Int:D :$bytes = 1 +< 16, Int:D :$workers = 1) {
    check-dialect($sep, $quote);
    die "CSV::Native: bytes must be at least 1"   if $bytes   < 1;
    die "CSV::Native: workers must be at least 1" if $workers < 1;
    my (&next-records, &close-all) = chunk-source($src, :$sep, :$quote,
                                                  :$headers, :$strict,
                                                  :$bytes, :$workers);
    Seq.new(class :: does Iterator {
        has @!recs;
        has Int $!i = 0;
        method pull-one() {
            loop {
                return @!recs[$!i++] if $!i < @!recs.elems;
                my $next = next-records();
                return IterationEnd without $next;
                @!recs := @$next;
                $!i = 0;
            }
        }
    }.new)
}
