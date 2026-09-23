=begin pod

=head1 TOML::Native

A TOML v1.0.0 parser and writer with a native fast path on Raku++, and a
pure-Raku implementation everywhere else. No dependencies.

The XS pattern: the distribution ships C source, the build step compiles it
against Raku++'s extension ABI, and the module uses it when it is there. On
Rakudo — or on a Raku++ without the built extension — the same parser runs as
plain Raku from this file. The same program runs on both.

=head2 Synopsis

    use TOML::Native;

    my %conf = from-toml(q:to/TOML/);
        title = "example"
        [owner]
        dob = 1979-05-27T07:32:00-08:00
        TOML
    say %conf<owner><dob>.year;          # 1979

    say to-toml({ a => 1, t => { b => [1.5e0, "x"] } });
    say toml-backend;                    # 'native' or 'raku'

=head2 Values

String → C<Str>, integer → C<Int> (int64, as TOML requires), float → C<Num>,
boolean → C<Bool>, offset date-time → C<DateTime>, local date-time →
C<TOML::Native::LocalDateTime> (a C<DateTime> whose C<Str> has no offset),
local date → C<Date>, local time → C<TOML::Native::LocalTime>, table →
C<Hash>, array → C<Array>.

Every parse error is C<TOML::Native: E<lt>whatE<gt> at line N>, and the
native and the Raku implementation raise the same message for the same input.

=end pod

unit module TOML::Native;

# ---- the date and time types ------------------------------------------------

# "HH:MM:SS" and the fraction, if any, in as many digits as it has (up to nine:
# the parsers keep fractional seconds to the nanosecond and truncate beyond,
# which the specification allows).
sub time-str(Int() $h, Int() $m, $s) {
    my $whole = $s.floor;
    my $frac = $s - $whole;
    my $digits = '';
    if $frac {
        $frac = $frac.Rat if $frac ~~ Num;
        while $frac && $digits.chars < 9 {
            $frac = $frac * 10;
            my $d = $frac.floor;
            $digits ~= $d;
            $frac = $frac - $d;
        }
    }
    sprintf('%02d:%02d:%02d', $h, $m, $whole) ~ ($digits ?? ".$digits" !! '')
}

sub date-str(Int() $y, Int() $m, Int() $d) { sprintf('%04d-%02d-%02d', $y, $m, $d) }

# A TOML local date-time: a DateTime with no offset. It is a DateTime so that
# everything a DateTime can do, it can; it stringifies without the "Z" a UTC
# DateTime would show, because it is not in UTC — it is in no zone at all.
class LocalDateTime is DateTime {
    method Str  { date-str(self.year, self.month, self.day) ~ 'T' ~ time-str(self.hour, self.minute, self.second) }
    method gist { self.Str }
}

# A TOML local time: a time of day, in no zone, on no date.
class LocalTime {
    has Int  $.hour   is required;
    has Int  $.minute is required;
    has Real $.second is required;
    method Str  { time-str($!hour, $!minute, $!second) }
    method gist { self.Str }
}

# The constructors BOTH parsers use — the extension reaches them by name
# through rk_call, the ABI having no way to build a DateTime itself. One set of
# constructors is what makes the two implementations' results the same
# objects, down to the type of the second.
sub seconds(Int $s, Str $frac) {
    return $s unless $frac;
    my $f = $frac.chars > 9 ?? $frac.substr(0, 9) !! $frac;
    $s + $f.Int / 10 ** $f.chars
}
my sub toml-native-datetime($y, $mo, $d, $h, $mi, $s, $frac, $off) {
    DateTime.new(:year($y), :month($mo), :day($d), :hour($h), :minute($mi),
                 :second(seconds($s, $frac)), :timezone($off * 60))
}
my sub toml-native-local-datetime($y, $mo, $d, $h, $mi, $s, $frac) {
    LocalDateTime.new(:year($y), :month($mo), :day($d), :hour($h), :minute($mi),
                      :second(seconds($s, $frac)))
}
# ... and one for text: see tmp_keep in src/toml.c.
my sub toml-native-nfc(Str $s) { $s.NFC.Str }
my sub toml-native-date($y, $mo, $d) { Date.new($y, $mo, $d) }
my sub toml-native-time($h, $mi, $s, $frac) {
    LocalTime.new(:hour($h), :minute($mi), :second(seconds($s, $frac)))
}

# ---- loading the extension ----------------------------------------------------

# `&::(…)` is a RUNTIME lookup, so this line compiles on Rakudo too — where it
# simply yields Nil and the module runs its own Raku implementation.
my &ext-load = try &::('rakupp-ext-load');
my &native-parse;

# Where the compiled half might be. %?RESOURCES is the installed answer; the
# CWD form covers a git checkout tested with -Ilib. NOT $?FILE-relative: under
# Raku++ a module's $?FILE is the main program's.
sub libraries() {
    my $ext = $*DISTRO.is-win ?? 'dll' !! ($*KERNEL.name eq 'darwin' ?? 'dylib' !! 'so');
    my $stem = $*DISTRO.is-win ?? "toml.$ext" !! "libtoml.$ext";
    my @c;
    with (try %?RESOURCES<libraries/toml>) { @c.push($_) if .defined }
    @c.push($*CWD.add("resources/libraries/$stem"));
    @c
}

sub load-native(--> Bool) {
    return False unless &ext-load;
    # TOML_NATIVE_BACKEND=raku forces the Raku implementation on a Raku++ that
    # has the extension: for measuring the two against each other, and for a
    # user who suspects the native path and wants to know in one run.
    return False if (%*ENV<TOML_NATIVE_BACKEND> // '') eq 'raku';
    for libraries() -> $lib {
        next unless $lib.IO.e;
        next unless try ext-load($lib.Str);
        # The loader installs the extension's subs into THIS scope.
        &native-parse = try &::('from-toml-native');
        return True if &native-parse;
    }
    False
}

my Bool $is-native = load-native();

# Which implementation is answering: 'native' (the compiled extension) or
# 'raku' (this file).
our sub toml-backend() is export(:MANDATORY) {
    $is-native ?? 'native' !! 'raku'
}

# ---- parsing ------------------------------------------------------------------

our sub from-toml($src) is export(:MANDATORY) {
    my Str $text = $src ~~ IO::Path | IO::Handle ?? decode($src.slurp(:bin)) !! $src.Str;
    $is-native ?? native-parse($text) !! parse-raku($text)
}

# Read as bytes and decode strictly: a TOML document must be UTF-8, and
# Raku++'s text-mode slurp substitutes for malformed bytes where Rakudo's
# throws (measured 2026-09-23), so decoding here is what makes a bad file
# an error on both.
#
# Rakudo's decoder also drops a leading byte-order mark and Raku++'s keeps it.
# The parser skips one BOM itself, and a second is an error — so the one the
# decoder dropped is put back, and both engines hand the parser the same text.
my constant DECODER-DROPS-BOM = Blob.new(0xEF, 0xBB, 0xBF, 0x61).decode('utf8').chars == 1;

#
# Raku++'s IO::Handle.slurp ignores :bin on a handle opened for text and
# returns a Str (2026-09-23); that Str is taken as it is.
multi sub decode(Str $s --> Str) { $s }
multi sub decode(Blob $b --> Str) {
    my $s = try $b.decode('utf8');
    die "TOML::Native: the document is not valid UTF-8" without $s;
    $s = "\x[FEFF]" ~ $s
        if DECODER-DROPS-BOM && $b.elems >= 3 && $b[0] == 0xEF && $b[1] == 0xBB && $b[2] == 0xBF;
    $s
}

# The parse tree. Tables and arrays are nodes while the document is read,
# because the rules about what may be extended (a table defined twice, an
# inline table reopened, a dotted key reaching into a table from an earlier
# section) need flags that a Hash has nowhere to keep; they become Hash and
# Array at the end. Scalars are stored as their final values.
my class TNode {
    has %.kids;
    has Int  $.depth;
    has Bool $.frozen   is rw = False;   # an inline table: closed
    has Bool $.explicit is rw = False;   # defined by a [header]
    has Int  $.dotted   is rw = 0;       # the section whose dotted keys defined it
}
my class ANode {
    has @.items;
    has Int  $.depth;
    has Bool $.aot = False;              # made by [[header]]; otherwise static
}

constant MAX-DEPTH = 128;

# Character classes, as hashes. Not strings tested with `contains`, though
# that was measured cheaper on Rakudo: on Rakudo (MoarVM 2026.08) a string
# stored eight bits wide — a literal in a precompiled module, or any text
# decoded from UTF-8 or Latin-1 — "contains" a character above U+00FF whose
# low byte it holds, so a 'Ł' was a bare-key character and an em dash a
# control character. notes/TOML-Native.md has the repro. A hash lookup
# compares whole characters, and is as fast as `contains` on Raku++.
my %BARE    = (|('A'..'Z'), |('a'..'z'), |('0'..'9'), '_', '-').map(* => True);
my %NUMCHAR = |%BARE, '.' => True, '+' => True;
my %DIGIT   = ('0'..'9').map(* => True);
# the characters a scan has to stop at: control characters other than tab
# (the line feed among them), and the quote and backslash of each string kind
my %CTRL    = (|(0..8), |(10..31), 127).map({ .chr => True });
my %BASIC   = |%CTRL, '"' => True, '\\' => True;
my %LITERAL = |%CTRL, "'" => True;

my %ESCAPE = b => "\b", t => "\t", n => "\n", f => "\f", r => "\r", '"' => '"', '\\' => '\\';
my %HEXVAL = |(('0'..'9') Z=> 0..9), |(('a'..'f') Z=> 10..15), |(('A'..'F') Z=> 10..15);
sub hexval(Str $ch --> Int) { %HEXVAL{$ch} // -1 }

# The Raku implementation of the parser — the reference the extension is held
# to, and what runs on Rakudo. Reachable by its full name so a test can run
# the same input through both.
#
# A hand-written scanner over the text's characters, in the same shape as
# src/toml.c: the same functions, the same order of checks, so that the two
# fail at the same place with the same words. Not a Raku grammar — a grammar
# would be shorter, but its failures come out as "no match" at a position the
# regex engine chose, and matching the C messages from that would mean a
# second, hand-written error pass anyway.
#
# The text is combed into an array once and indexed; runs of plain text are
# cut out with substr at the same indices. Never `.index($x, $pos)` and never
# `.match(:p($pos))` on the whole text: on Raku++ both cost the whole string
# on every call (notes/TOML-Native.md has the measurements), which turns a
# scanner quadratic.
our sub parse-raku(Str:D $source --> Hash) {
    # CRLF becomes LF before anything else. The two mean the same everywhere
    # in TOML — a line ending, or inside a multi-line string a newline, which
    # both implementations keep as LF — and a lone CR is an error either way,
    # so the change is invisible in the result and in every error. What it
    # buys is that "\r\n", one character in Raku, never reaches the scanner.
    my $text = $source.contains("\r\n") ?? $source.split("\r\n").join("\n") !! $source;

    # One element per character. Where a character is more than one codepoint
    # — a combining mark straight after a quote would glue to it and hide it —
    # work on codepoints instead, as the C side does.
    my @c = $text.comb;
    my Bool $aligned = True;
    if $text.codes != @c.elems {
        @c = $text.ords.map(&chr);
        $aligned = False;
    }
    my int $n = @c.elems;
    my int $i = 0;
    my int $line = 1;
    my int $section = 1;
    my $root = TNode.new(:depth(0));

    # The fast path. In a text with no control characters but tab and line
    # feed — nearly every real document — a string without escapes or a
    # comment is decided by where the next quote, backslash and line feed
    # are, so those positions are listed once, with `split` (linear on both
    # engines), and walked with a pointer each as the scan moves forward.
    # Anything the lists cannot decide goes through the character loop,
    # which is the reference; a text with other control characters in it
    # uses nothing else, so every error comes from the same code.
    my Bool $fast = $aligned && !$text.contains(any(%CTRL.keys.grep(* ne "\n")));
    my int @dq; my int @sq; my int @bs; my int @nl;
    my int ($dqp, $sqp, $bsp, $nlp) = 0, 0, 0, 0;
    if $fast {
        for (@dq, '"'), (@sq, "'"), (@bs, '\\'), (@nl, "\n") -> ($list, $needle) {
            my int $pos = -1;
            my @pieces = $text.split($needle);
            @pieces.pop;
            for @pieces -> $piece { $pos = $pos + $piece.chars + 1; $list.push($pos) }
        }
    }
    # the first position in @list at or after $from, or $n if none
    my sub next-at(@list, Int $p is rw, int $from --> int) {
        my int $e = @list.elems;
        $p = $p + 1 while $p < $e && @list[$p] < $from;
        $p < $e ?? @list[$p] !! $n
    }

    my sub span(int $a, int $b) {
        $aligned ?? $text.substr($a, $b - $a) !! @c[$a ..^ $b].join
    }
    my sub peek(int $o) { $i + $o < $n ?? @c[$i + $o] !! '' }

    my sub fail-at(Str $what, Int $at) { die "TOML::Native: $what at line $at" }
    my sub fail(Str $what) { fail-at($what, $line) }
    my sub fail-ctrl(Str $ch, Str $where) {
        fail(sprintf('control character U+%04X in %s', $ch.ord, $where))
    }
    my sub fail-key(Str $pre, @key, Int $upto, Str $post, Int $at) {
        fail-at("$pre'{@key[0 .. $upto].join('.')}'$post", $at)
    }
    my sub new-table(Int $depth, Int $dotted = 0) {
        fail('nesting deeper than 128 levels') if $depth > MAX-DEPTH;
        TNode.new(:$depth, :$dotted)
    }
    my sub new-array(Int $depth, Bool $aot = False) {
        fail('nesting deeper than 128 levels') if $depth > MAX-DEPTH;
        ANode.new(:$depth, :$aot)
    }

    # ---- the scanner
    # The hot loops test each character once, against a hash of the ones that
    # matter (cheaper than a chain of `eq`, or `.ord` and integer comparisons,
    # on both engines), and cut plain runs out with substr.
    # (no `last` and no `given`/`when` in the hot paths: on Rakudo both are
    # control exceptions in places the optimizer does not reach, and a
    # profile put this sub at the top when it had one)
    my sub skip-ws() {
        $i = $i + 1 while $i < $n && (@c[$i] eq ' ' || @c[$i] eq "\t");
    }
    my sub comment() {
        $i = $i + 1;
        if $fast { $i = next-at(@nl, $nlp, $i); return }
        while $i < $n {
            my $ch = @c[$i];
            if %CTRL{$ch} {
                return if $ch eq "\n";
                fail-ctrl($ch, 'a comment');
            }
            $i = $i + 1;
        }
    }
    my sub end-of-line() {
        skip-ws();
        comment() if $i < $n && @c[$i] eq '#';
        return if $i >= $n;
        fail('expected the end of the line') unless @c[$i] eq "\n";
        $i = $i + 1;
        $line = $line + 1;
    }
    my sub skip-ws-nl() {
        loop {
            skip-ws();
            return if $i >= $n;
            if @c[$i] eq '#' { comment(); next }
            return unless @c[$i] eq "\n";
            $i = $i + 1;
            $line = $line + 1;
        }
    }

    # ---- strings
    # At the backslash of an escape in a basic string: what it means.
    my sub escape(--> Str) {
        my $e = peek(1);
        with %ESCAPE{$e} -> $meant { $i = $i + 2; return $meant }
        my int $k = $e eq 'u' ?? 4 !! $e eq 'U' ?? 8 !! 0;
        fail('invalid escape sequence') unless $k;
        my $cp = 0;
        loop (my int $j = 0; $j < $k; $j = $j + 1) {
            my $h = hexval(peek(2 + $j));
            fail('invalid Unicode escape') if $h < 0;
            $cp = $cp * 16 + $h;
        }
        fail('invalid Unicode escape') if $cp > 0x10FFFF || 0xD800 <= $cp <= 0xDFFF;
        $i = $i + 2 + $k;
        chr($cp)
    }
    my sub basic-string(--> Str) {
        $i = $i + 1;
        if $fast {
            my int $q = next-at(@dq, $dqp, $i);
            if $q < next-at(@bs, $bsp, $i) && $q < next-at(@nl, $nlp, $i) {
                my $s = span($i, $q);
                $i = $q + 1;
                return $s;
            }
        }
        my int $run = $i;
        my $buf;
        loop {
            fail('unterminated string') if $i >= $n;
            my $ch = @c[$i];
            if %BASIC{$ch} {
                last if $ch eq '"';
                if $ch eq '\\' {
                    $buf = ($buf // '') ~ span($run, $i);
                    $buf ~= escape();
                    $run = $i;
                    next;
                }
                fail('unterminated string') if $ch eq "\n";
                fail-ctrl($ch, 'a string');
            }
            $i = $i + 1;
        }
        my $s = $buf.defined ?? $buf ~ span($run, $i) !! span($run, $i);
        $i = $i + 1;
        $s
    }
    my sub literal-string(--> Str) {
        $i = $i + 1;
        if $fast {
            my int $q = next-at(@sq, $sqp, $i);
            if $q < next-at(@nl, $nlp, $i) {
                my $s = span($i, $q);
                $i = $q + 1;
                return $s;
            }
        }
        my int $start = $i;
        loop {
            fail('unterminated string') if $i >= $n;
            my $ch = @c[$i];
            if %LITERAL{$ch} {
                last if $ch eq "'";
                fail('unterminated string') if $ch eq "\n";
                fail-ctrl($ch, 'a string');
            }
            $i = $i + 1;
        }
        my $s = span($start, $i);
        $i = $i + 1;
        $s
    }
    # """...""" and ''''...'''': a line ending straight after the opening
    # quotes is dropped, and one or two quotes may sit just before the closing
    # three.
    my sub ml-string(Str $q --> Str) {
        my $open-line = $line;
        my %special := $q eq '"' ?? %BASIC !! %LITERAL;
        $i = $i + 3;
        if $i < $n && @c[$i] eq "\n" { $i = $i + 1; $line = $line + 1 }
        my $buf = '';
        my int $run = $i;
        loop {
            fail-at('unterminated multi-line string', $open-line) if $i >= $n;
            my $ch = @c[$i];
            unless %special{$ch} { $i = $i + 1; next }
            if $ch eq $q {
                if peek(1) eq $q && peek(2) eq $q {
                    $buf ~= span($run, $i);
                    $i = $i + 3;
                    if $i < $n && @c[$i] eq $q {
                        $buf ~= $q; $i = $i + 1;
                        if $i < $n && @c[$i] eq $q { $buf ~= $q; $i = $i + 1 }
                    }
                    return $buf;
                }
                $i = $i + 1;
                next;
            }
            if $ch eq '\\' {
                # a backslash at the end of a line eats the line ending and all
                # the whitespace after it
                $buf ~= span($run, $i);
                my int $save = $i;
                $i = $i + 1;
                skip-ws();
                if $i < $n && @c[$i] eq "\n" {
                    loop {
                        skip-ws();
                        last unless $i < $n && @c[$i] eq "\n";
                        $i = $i + 1;
                        $line = $line + 1;
                    }
                    $run = $i;
                    next;
                }
                $i = $save;
                $buf ~= escape();
                $run = $i;
                next;
            }
            if $ch eq "\n" {
                $i = $i + 1;
                $line = $line + 1;
                next;
            }
            fail-ctrl($ch, 'a string');
        }
    }

    # ---- keys
    my sub parse-key(--> Array) {
        my @key;
        loop {
            skip-ws();
            fail('expected a key') if $i >= $n;
            my $ch = @c[$i];
            if $ch eq '"' { @key.push(basic-string()) }
            elsif $ch eq "'" { @key.push(literal-string()) }
            elsif %BARE{$ch} {
                my int $start = $i;
                $i = $i + 1 while $i < $n && %BARE{@c[$i]};
                @key.push(span($start, $i));
            }
            else { fail('expected a key') }
            skip-ws();
            if $i < $n && @c[$i] eq '.' { $i = $i + 1; next }
            return @key;
        }
    }

    # ---- numbers
    # Digits of a base with single underscores between them, from position
    # $p up to $end; appends the digits to $out. The count of digits, or -1
    # for a misplaced underscore.
    my sub digits(Int $p is rw, int $end, int $base, Str $out is rw --> Int) {
        my int $count = 0;
        loop {
            my $ch = $p < $end ?? @c[$p] !! '';
            my $v = %HEXVAL{$ch} // -1;
            if 0 <= $v < $base { $out ~= $ch; $count = $count + 1; $p = $p + 1; next }
            if $ch eq '_' {
                my $w = $p + 1 < $end ?? hexval(@c[$p + 1]) !! -1;
                return -1 if !$count || $w < 0 || $w >= $base;
                $p = $p + 1;
                next;
            }
            last;
        }
        $count
    }
    my sub number() {
        my int $start = $i;
        $i = $i + 1 while $i < $n && %NUMCHAR{@c[$i]};
        my int $end = $i;
        my Int $p = $start;
        my Bool $neg = False;
        my Bool $sign = False;
        if @c[$p] eq '+' || @c[$p] eq '-' { $neg = @c[$p] eq '-'; $sign = True; $p = $p + 1 }
        my $rest = span($p, $end);
        return NaN if $rest eq 'nan';
        return ($neg ?? -Inf !! Inf) if $rest eq 'inf';
        fail($sign ?? 'invalid number' !! 'expected a value') if $p == $end || !%DIGIT{@c[$p]};
        # the common case, a plain decimal that cannot overflow: one pass
        {
            my int $k = $p;
            $k = $k + 1 while $k < $end && %DIGIT{@c[$k]};
            if $k == $end && $end - $p <= 18 && ($end - $p == 1 || @c[$p] ne '0') {
                my $v = span($p, $end).Int;
                return $neg ?? -$v !! $v;
            }
        }
        my Str $tmp = '';
        if $p + 1 < $end && @c[$p] eq '0' && (@c[$p + 1] eq 'x' || @c[$p + 1] eq 'o' || @c[$p + 1] eq 'b') {
            my int $base = @c[$p + 1] eq 'x' ?? 16 !! @c[$p + 1] eq 'o' ?? 8 !! 2;
            fail('invalid number') if $sign;
            $p = $p + 2;
            fail('invalid number') if digits($p, $end, $base, $tmp) <= 0 || $p != $end;
            my $v = $tmp.parse-base($base);
            fail('integer out of range') if $v > 0x7FFFFFFFFFFFFFFF;
            return $v;
        }
        $tmp = '-' if $neg;
        my $ints = digits($p, $end, 10, $tmp);
        fail('invalid number') if $ints <= 0;
        fail('invalid number') if $ints > 1 && $tmp.substr(+$neg, 1) eq '0';
        my Bool $float = False;
        if $p < $end && @c[$p] eq '.' {
            $tmp ~= '.';
            $p = $p + 1;
            fail('invalid number') if digits($p, $end, 10, $tmp) <= 0;
            $float = True;
        }
        if $p < $end && (@c[$p] eq 'e' || @c[$p] eq 'E') {
            $tmp ~= 'e';
            $p = $p + 1;
            if $p < $end && (@c[$p] eq '+' || @c[$p] eq '-') { $tmp ~= @c[$p]; $p = $p + 1 }
            fail('invalid number') if digits($p, $end, 10, $tmp) <= 0;
            $float = True;
        }
        fail('invalid number') if $p != $end;
        return $tmp.Num if $float;
        my $v = $tmp.Int;
        fail('integer out of range') unless -0x8000000000000000 <= $v <= 0x7FFFFFFFFFFFFFFF;
        $v
    }

    # ---- dates and times
    my sub fixed(int $count --> Int) {
        my $v = 0;
        loop (my int $j = 0; $j < $count; $j = $j + 1) {
            my $ch = peek($j);
            fail('malformed date or time') unless %DIGIT{$ch};
            $v = $v * 10 + $ch.Int;
        }
        $i = $i + $count;
        $v
    }
    my sub expect-char(Str $ch) {
        fail('malformed date or time') if $i >= $n || @c[$i] ne $ch;
        $i = $i + 1;
    }
    my sub time-part() {
        my $h = fixed(2);
        expect-char(':');
        my $mi = fixed(2);
        expect-char(':');
        my $s = fixed(2);
        my $frac = '';
        if $i < $n && @c[$i] eq '.' {
            $i = $i + 1;
            my int $f = $i;
            $i = $i + 1 while $i < $n && %DIGIT{@c[$i]};
            fail('malformed date or time') if $i == $f;
            $frac = span($f, $i);
        }
        # seconds stop at 59: see src/toml.c
        fail('invalid time') if $h > 23 || $mi > 59 || $s > 59;
        ($h, $mi, $s, $frac)
    }
    my sub datetime() {
        my $y = fixed(4);
        expect-char('-');
        my $mo = fixed(2);
        expect-char('-');
        my $d = fixed(2);
        fail('invalid date') if $mo < 1 || $mo > 12;
        my $max = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)[$mo - 1];
        $max = 29 if $mo == 2 && $y %% 4 && ($y % 100 != 0 || $y %% 400);
        fail('invalid date') if $d < 1 || $d > $max;
        if $i < $n && (@c[$i] eq 'T' || @c[$i] eq 't' || (@c[$i] eq ' ' && %DIGIT{peek(1)})) {
            $i = $i + 1;
            my ($h, $mi, $s, $frac) = time-part();
            if $i < $n && (@c[$i] eq 'Z' || @c[$i] eq 'z') {
                $i = $i + 1;
                return toml-native-datetime($y, $mo, $d, $h, $mi, $s, $frac, 0);
            }
            if $i < $n && (@c[$i] eq '+' || @c[$i] eq '-') {
                my $sgn = @c[$i] eq '-' ?? -1 !! 1;
                $i = $i + 1;
                my $oh = fixed(2);
                expect-char(':');
                my $om = fixed(2);
                fail('invalid time offset') if $oh > 23 || $om > 59;
                return toml-native-datetime($y, $mo, $d, $h, $mi, $s, $frac, $sgn * ($oh * 60 + $om));
            }
            return toml-native-local-datetime($y, $mo, $d, $h, $mi, $s, $frac);
        }
        toml-native-date($y, $mo, $d)
    }

    # ---- values
    my &value;
    my sub parse-array(Int $depth) {
        my $open-line = $line;
        my $a = new-array($depth);
        $i = $i + 1;
        loop {
            skip-ws-nl();
            fail-at('unterminated array', $open-line) if $i >= $n;
            if @c[$i] eq ']' { $i = $i + 1; return $a }
            $a.items.push(value($depth + 1));
            skip-ws-nl();
            fail-at('unterminated array', $open-line) if $i >= $n;
            if @c[$i] eq ',' { $i = $i + 1; next }
            if @c[$i] eq ']' { $i = $i + 1; return $a }
            fail("expected ',' or ']' in an array");
        }
    }
    my sub inline-table(Int $depth) {
        my $t = new-table($depth);
        $i = $i + 1;
        skip-ws();
        if $i < $n && @c[$i] eq '}' { $i = $i + 1; $t.frozen = True; return $t }
        loop {
            my $cur = $t;
            my @key = parse-key();
            fail("expected '=' after a key") if $i >= $n || @c[$i] ne '=';
            $i = $i + 1;
            skip-ws();
            my $kline = $line;
            my $v = value($depth + @key.elems);
            # within an inline table: dotted keys may build its sub-tables,
            # but nothing already closed may be reopened
            loop (my int $j = 0; $j < @key.elems - 1; $j = $j + 1) {
                my $child = $cur.kids{@key[$j]};
                if $cur.kids{@key[$j]}:!exists {
                    $child = new-table($cur.depth + 1);
                    $cur.kids{@key[$j]} = $child;
                }
                elsif $child ~~ TNode {
                    fail-key('inline table ', @key, $j, ' cannot be extended', $kline) if $child.frozen;
                }
                elsif $child ~~ ANode { fail-key('static array ', @key, $j, ' cannot be extended', $kline) }
                else { fail-key('duplicate key ', @key, $j, '', $kline) }
                $cur = $child;
            }
            fail-key('duplicate key ', @key, @key.end, '', $kline) if $cur.kids{@key[*-1]}:exists;
            $cur.kids{@key[*-1]} = $v;
            skip-ws();
            if $i < $n && @c[$i] eq ',' {
                $i = $i + 1;
                skip-ws();
                fail('trailing comma in an inline table') if $i < $n && @c[$i] eq '}';
                next;
            }
            if $i < $n && @c[$i] eq '}' { $i = $i + 1; last }
            fail("expected ',' or '}' in an inline table");
        }
        $t.frozen = True;
        $t
    }
    &value = sub (Int $depth) {
        fail('expected a value') if $i >= $n;
        my $ch = @c[$i];
        if $ch eq '"' {
            return ml-string('"') if peek(1) eq '"' && peek(2) eq '"';
            return basic-string();
        }
        if $ch eq "'" {
            return ml-string("'") if peek(1) eq "'" && peek(2) eq "'";
            return literal-string();
        }
        if $ch eq 't' && peek(1) eq 'r' && peek(2) eq 'u' && peek(3) eq 'e' {
            $i = $i + 4;
            return True;
        }
        if $ch eq 'f' && peek(1) eq 'a' && peek(2) eq 'l' && peek(3) eq 's' && peek(4) eq 'e' {
            $i = $i + 5;
            return False;
        }
        return parse-array($depth) if $ch eq '[';
        return inline-table($depth) if $ch eq '{';
        if %DIGIT{$ch} {
            my $p1 = peek(1);
            return datetime() if %DIGIT{$p1} && %DIGIT{peek(2)} && %DIGIT{peek(3)} && peek(4) eq '-';
            if %DIGIT{$p1} && peek(2) eq ':' {
                my ($h, $mi, $s, $frac) = time-part();
                return toml-native-time($h, $mi, $s, $frac);
            }
            return number();
        }
        return number() if $ch eq '+' || $ch eq '-' || $ch eq 'i' || $ch eq 'n';
        fail('expected a value');
    };

    # ---- the document
    # [key] or [[key]]: at the first bracket. Returns the table that the
    # following key/value pairs go into.
    my sub header() {
        my Bool $aot = peek(1) eq '[';
        my $hline = $line;
        my $t = $root;
        my $child;
        $i = $i + ($aot ?? 2 !! 1);
        $section = $section + 1;
        my @key = parse-key();
        if $aot {
            fail("expected ']]' to close an array-of-tables header") if peek(0) ne ']' || peek(1) ne ']';
            $i = $i + 2;
        }
        else {
            fail("expected ']' to close a table header") if $i >= $n || @c[$i] ne ']';
            $i = $i + 1;
        }
        my int $last = @key.end;
        loop (my int $j = 0; $j < $last; $j = $j + 1) {
            $child = $t.kids{@key[$j]};
            if $t.kids{@key[$j]}:!exists {
                $child = new-table($t.depth + 1);
                $t.kids{@key[$j]} = $child;
            }
            elsif $child ~~ TNode {
                fail-key('inline table ', @key, $j, ' cannot be extended', $hline) if $child.frozen;
            }
            elsif $child ~~ ANode {
                fail-key('static array ', @key, $j, ' cannot be extended', $hline) unless $child.aot;
                $child = $child.items[*-1];
            }
            else { fail-key('duplicate key ', @key, $j, '', $hline) }
            $t = $child;
        }
        my $exists = $t.kids{@key[$last]}:exists;
        $child = $t.kids{@key[$last]};
        unless $aot {
            if !$exists {
                $child = new-table($t.depth + 1);
                $t.kids{@key[$last]} = $child;
            }
            elsif $child ~~ TNode {
                fail-key('inline table ', @key, $last, ' cannot be extended', $hline) if $child.frozen;
                fail-key('table ', @key, $last, ' is defined twice', $hline) if $child.explicit || $child.dotted;
            }
            elsif $child ~~ ANode {
                fail-key('table ', @key, $last, ' is defined twice', $hline) if $child.aot;
                fail-key('static array ', @key, $last, ' cannot be extended', $hline);
            }
            else { fail-key('duplicate key ', @key, $last, '', $hline) }
            $child.explicit = True;
            return $child;
        }
        if !$exists {
            $child = new-array($t.depth + 1, True);
            $t.kids{@key[$last]} = $child;
        }
        elsif $child ~~ ANode {
            fail-key('cannot append to static array ', @key, $last, '', $hline) unless $child.aot;
        }
        elsif $child ~~ TNode {
            fail-key('inline table ', @key, $last, ' cannot be extended', $hline) if $child.frozen;
            fail-key('table ', @key, $last, ' is defined twice', $hline);
        }
        else { fail-key('duplicate key ', @key, $last, '', $hline) }
        my $elem = new-table($child.depth + 1);
        $child.items.push($elem);
        $elem
    }

    # key = value, into the current section's table.
    my sub keyval($table) {
        my $t = $table;
        my $kline = $line;
        my @key = parse-key();
        fail("expected '=' after a key") if $i >= $n || @c[$i] ne '=';
        $i = $i + 1;
        skip-ws();
        my $v = value($t.depth + @key.elems);
        my int $last = @key.end;
        loop (my int $j = 0; $j < $last; $j = $j + 1) {
            my $child = $t.kids{@key[$j]};
            if $t.kids{@key[$j]}:!exists {
                $child = new-table($t.depth + 1, $section);
                $t.kids{@key[$j]} = $child;
            }
            elsif $child ~~ TNode {
                fail-key('inline table ', @key, $j, ' cannot be extended', $kline) if $child.frozen;
                fail-key('cannot reopen table ', @key, $j, ' with a dotted key', $kline)
                    if $child.explicit || ($child.dotted && $child.dotted != $section);
                $child.dotted = $section;
            }
            elsif $child ~~ ANode {
                fail-key('cannot reopen table ', @key, $j, ' with a dotted key', $kline) if $child.aot;
                fail-key('static array ', @key, $j, ' cannot be extended', $kline);
            }
            else { fail-key('duplicate key ', @key, $j, '', $kline) }
            $t = $child;
        }
        fail-key('duplicate key ', @key, $last, '', $kline) if $t.kids{@key[$last]}:exists;
        $t.kids{@key[$last]} = $v;
    }

    # a byte-order mark is an encoding's signature, not content
    $i = 1 if $n && @c[0] eq "\x[FEFF]";
    my $cur = $root;
    loop {
        skip-ws();
        last if $i >= $n;
        if @c[$i] eq "\n" { $i = $i + 1; $line = $line + 1; next }
        if @c[$i] eq '#' { comment(); end-of-line(); next }
        if @c[$i] eq '[' { $cur = header() }
        else { keyval($cur) }
        end-of-line();
    }
    to-value($root)
}

# The tree, as Raku values: bottom-up, so every Hash and Array is complete
# before it is stored.
sub to-value($node) {
    if $node ~~ TNode {
        my %h;
        for $node.kids.kv -> $k, $v { %h{$k} = to-value($v) }
        return %h;
    }
    if $node ~~ ANode {
        my @a;
        @a.push(to-value($_)) for $node.items;
        return @a;
    }
    $node
}

# ---- writing ------------------------------------------------------------------

# The writer is Raku only: see notes/TOML-Native.md for why a C writer would
# buy nothing here. Output is deterministic — keys sorted, so both engines
# (and every run on Rakudo, which randomises hash order) write the same text.
# In each table: the plain keys, then its [sub.tables], then its
# [[arrays.of.tables]].
our sub to-toml(%data --> Str) is export(:MANDATORY) {
    my @out;
    my %*TOML-KEY-STR;
    write-table(%data, (), @out, 0, False);
    @out.join
}

sub path-str(@path) { @path.map(&key-str).join('.') }
sub where(@path) { @path ?? " for '{@path.join('.')}'" !! '' }

# Keys repeat — every element of an array of tables has the same ones — so
# each is decided once per document.
sub key-str(Str() $k) {
    %*TOML-KEY-STR{$k} //= ($k ne '' && !$k.comb.first({ !%BARE{$_} }).defined) ?? $k !! quote-str($k)
}

# A basic string. Escaping goes by codepoint, not by character: "\r\n" is one
# character in Raku, and a search for "\r" does not find it. Most strings
# need none, and a regex says so fastest — except that Rakudo's character
# class does not match the "\r\n" grapheme at all (Raku++'s does), so CRLF is
# asked about separately.
my %ESCAPED = 0x22 => '\\"', 0x5C => '\\\\', 0x08 => '\\b', 0x09 => '\\t', 0x0A => '\\n',
              0x0C => '\\f', 0x0D => '\\r';
sub quote-str(Str $s) {
    return '"' ~ $s ~ '"' unless $s ~~ /<[\x00..\x1F\x7F"\\]>/ || $s.contains("\r\n");
    '"' ~ $s.ords.map({
        %ESCAPED{$_} // ($_ < 0x20 || $_ == 0x7F ?? sprintf('\\u%04X', $_) !! chr($_))
    }).join ~ '"'
}

# A float that reads back as a float: "1" becomes "1.0", Inf "inf".
#
# Subnormals need care, differently on each engine: Raku++ stringifies them
# to fifteen digits rather than the shortest that reads back (1e-310 as
# 9.99999999999997e-311), and Rakudo's sprintf dies on them with %e. So the
# shortest form is searched for with sprintf where sprintf works, and
# Rakudo's own .Str — which is the shortest — is used where it does not; the
# text is the same on both.
sub float-str(Num $f) {
    return 'nan' if $f.isNaN;
    return ($f > 0 ?? 'inf' !! '-inf') if $f == Inf || $f == -Inf;
    my $s;
    if $f != 0 && $f.abs < 2.2250738585072014e-308 {
        $s = try {
            my $r;
            for 0 .. 16 -> $p {
                $r = sprintf("%.{$p}e", $f);
                last if $r.Num == $f;
            }
            $r
        } // $f.Str;
    }
    else {
        $s = $f.Str;
    }
    $s ~= '.0' if $s ~~ /^ '-'? \d+ $/;
    $s
}

sub offset-str(Int $tz) {
    return 'Z' unless $tz;
    my $m = $tz.abs div 60;
    ($tz < 0 ?? '-' !! '+') ~ sprintf('%02d:%02d', $m div 60, $m % 60)
}

sub value-str($v, @path, Int $depth) {
    die "TOML::Native: nesting deeper than 128 levels{where(@path)}" if $depth > MAX-DEPTH;
    die "TOML::Native: cannot write an undefined value{where(@path)}" without $v;
    return quote-str($v) if $v ~~ Str;
    return $v ?? 'true' !! 'false' if $v ~~ Bool;
    if $v ~~ Int {
        die "TOML::Native: integer out of range{where(@path)}"
            unless -0x8000000000000000 <= $v <= 0x7FFFFFFFFFFFFFFF;
        return $v.Str;
    }
    return float-str($v) if $v ~~ Num;
    return float-str($v.Num) if $v ~~ Real;
    if $v ~~ DateTime | Date {
        die "TOML::Native: year {$v.year} cannot be written{where(@path)}" unless 0 <= $v.year <= 9999;
        my $date = date-str($v.year, $v.month, $v.day);
        return $date if $v ~~ Date;
        my $time = $date ~ 'T' ~ time-str($v.hour, $v.minute, $v.second);
        return $v ~~ LocalDateTime ?? $time !! $time ~ offset-str($v.timezone);
    }
    return $v.Str if $v ~~ LocalTime;
    if $v ~~ Associative {
        my @kv = $v.keys.sort.map(-> $k {
            key-str($k) ~ ' = ' ~ value-str($v{$k}, (|@path, $k), $depth + 1)
        });
        return @kv ?? '{ ' ~ @kv.join(', ') ~ ' }' !! '{}';
    }
    if $v ~~ Positional && $v !~~ Blob {
        return '[' ~ $v.list.map({ value-str($_, @path, $depth + 1) }).join(', ') ~ ']';
    }
    die "TOML::Native: cannot write a value of type {$v.^name}{where(@path)}";
}

sub is-aot($v) {
    $v ~~ Positional && $v !~~ Blob && $v.elems && so $v.list.all ~~ Associative
}

sub write-table(%t, @path, @out, Int $depth, Bool $header, Bool :$aot = False) {
    die "TOML::Native: nesting deeper than 128 levels{where(@path)}" if $depth > MAX-DEPTH;
    my (@plain, @tables, @aots);
    for %t.keys.sort -> $k {
        my $v = %t{$k};
        if    $v.defined && $v ~~ Associative { @tables.push($k) }
        elsif $v.defined && is-aot($v)        { @aots.push($k) }
        else                                  { @plain.push($k) }
    }
    # a table holding only tables needs no header of its own — theirs create
    # it — but an empty one does, and every element of an array of tables does
    if $header && ($aot || @plain || !(@tables || @aots)) {
        @out.push("\n") if @out;
        @out.push($aot ?? "[[{path-str(@path)}]]\n" !! "[{path-str(@path)}]\n");
    }
    for @plain -> $k {
        @out.push(key-str($k) ~ ' = ' ~ value-str(%t{$k}, (|@path, $k), $depth + 1) ~ "\n");
    }
    for @tables -> $k {
        write-table(%t{$k}, (|@path, $k), @out, $depth + 1, True);
    }
    for @aots -> $k {
        for %t{$k}.list -> %elem {
            write-table(%elem, (|@path, $k), @out, $depth + 2, True, :aot);
        }
    }
}
