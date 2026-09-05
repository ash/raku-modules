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

unit module CSV::Native;

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
        return True if &native-parse && &native-write;
    }
    False
}

my Bool $is-native = load-native();

# Which implementation is answering: 'native' (the compiled extension) or
# 'raku' (this file).
our sub csv-backend() is export(:MANDATORY) {
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
                 Bool:D :$strict = False) is export(:MANDATORY) {
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
                   Bool:D :$strict = False) {
    # from-csv validates the whole dialect; these two are repeated here because
    # an empty needle is found at every position, and a split that produces
    # nothing but empty pieces is not an answer — a direct caller deserves the
    # error.
    die "CSV::Native: sep must not be empty"   unless $sep.chars;
    die "CSV::Native: quote must be exactly one character, not '$quote'" unless $quote.chars == 1;
    my $s = $text.starts-with("\x[FEFF]") ?? $text.substr(1) !! $text;

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
    my int $line = 1;
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
               :$headers, Bool:D :$always-quote = False) is export(:MANDATORY) {
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
