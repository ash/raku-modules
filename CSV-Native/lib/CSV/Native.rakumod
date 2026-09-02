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
my &ext-load = try &::('rakupp-ext-load');
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
# The scan keeps a memo of where each of the four interesting strings (the
# separator, the quote, LF, CR) NEXT occurs, refreshed only when the cursor
# passes it. Calling `.index` afresh per field would be quadratic on a file
# where one of them is rare — a single-column file has no separator at all,
# and every field would rescan to the end of the text looking for one.
our sub parse-raku(Str:D $text, Str:D :$sep = ',', Str:D :$quote = '"', :$headers,
                   Bool:D :$strict = False) {
    # from-csv validates the whole dialect; these two are repeated here because
    # an empty needle is found at every position, and a scan that never
    # advances is a hang, not an error — a direct caller deserves the error.
    die "CSV::Native: sep must not be empty"   unless $sep.chars;
    die "CSV::Native: quote must be exactly one character, not '$quote'" unless $quote.chars == 1;
    my $s = $text.starts-with("\x[FEFF]") ?? $text.substr(1) !! $text;
    my int $len  = $s.chars;
    my int $sepl = $sep.chars;
    my int $pos  = 0;
    my int $line = 1;
    my int $nsep = $s.index($sep)   // $len;
    my int $nq   = $s.index($quote) // $len;
    # Three line-ending needles, because CRLF is ONE grapheme in Raku: a
    # search for "\n" does not find the "\n" inside a "\r\n", and a search for
    # "\r\n" does not find a lone "\r". Each is its own memo for the same
    # reason the separator is — a file that ends its lines one way would
    # otherwise rescan to the end for the other two on every field.
    my int $nlf   = $s.index("\n")   // $len;
    my int $ncr   = $s.index("\r")   // $len;
    my int $ncrlf = $s.index("\r\n") // $len;

    my @names;
    my Bool $want-header = False;
    my $expected;
    given $headers {
        when Positional { @names = .list; check-dups(@names); $expected = @names.elems }
        when Bool       { $want-header = $_ }
    }

    my @rows;
    while $pos < $len {
        my int $row-line = $line;
        my @cells;
        loop {
            my int $fline = $line;
            my $field;
            my $term;
            $nq = $s.index($quote, $pos) // $len if $nq < $pos;
            if $nq == $pos && $pos < $len {
                # quoted: the text up to the next quote, a doubled quote being
                # one quote of content, then whatever ends the field
                $pos = $pos + 1;
                $field = '';
                loop {
                    my $q = $s.index($quote, $pos);
                    die "CSV::Native: unterminated quoted field starting at line $fline"
                        without $q;
                    $field ~= $s.substr($pos, $q - $pos);
                    $pos = $q + 1;
                    if $pos < $len && $s.substr($pos, 1) eq $quote {
                        $field ~= $quote;
                        $pos = $pos + 1;
                        next;
                    }
                    last;
                }
                $line = $line + count-lines($field);
                $nq = $s.index($quote, $pos) // $len;
                if $pos >= $len                { $term = 'eof' }
                elsif $s.substr-eq($sep, $pos) { $pos = $pos + $sepl; $term = 'sep' }
                elsif $s.substr($pos, 1) eq "\r\n" | "\n" | "\r" {
                    # one grapheme, whichever line ending it is
                    $pos = $pos + 1;
                    $line = $line + 1;
                    $term = 'eol';
                }
                else { die "CSV::Native: text after a closing quote at line $fline" }
            }
            else {
                $nsep  = $s.index($sep, $pos)   // $len if $nsep  < $pos;
                $nlf   = $s.index("\n", $pos)   // $len if $nlf   < $pos;
                $ncr   = $s.index("\r", $pos)   // $len if $ncr   < $pos;
                $ncrlf = $s.index("\r\n", $pos) // $len if $ncrlf < $pos;
                my int $end = $nsep;
                $end = $nlf   if $nlf   < $end;
                $end = $ncr   if $ncr   < $end;
                $end = $ncrlf if $ncrlf < $end;
                die "CSV::Native: a quote inside an unquoted field at line $fline" if $nq < $end;
                $field = $s.substr($pos, $end - $pos);
                if    $end == $len  { $pos = $len; $term = 'eof' }
                elsif $end == $nsep { $pos = $end + $sepl; $term = 'sep' }
                else                { $pos = $end + 1; $line = $line + 1; $term = 'eol' }
            }
            @cells.push($field);
            last unless $term eq 'sep';
        }

        if $want-header && !@names {
            @names = @cells;
            check-dups(@names);
            $expected = @names.elems;
            next;
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
    @rows
}

# Line endings inside a quoted field, counted the way the reader would: CRLF
# is one, and so is a lone CR or LF — and since CRLF is one grapheme, each
# line ending is exactly one character to count. The three `contains` checks
# keep the (much more common) single-line field off the character walk.
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
