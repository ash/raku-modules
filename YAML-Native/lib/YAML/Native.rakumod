=begin pod

=head1 YAML::Native

A YAML 1.2 parser and writer with a native fast path on Raku++, and a
pure-Raku implementation everywhere else. No dependencies.

The XS pattern: the distribution ships C source, the build step compiles it
against Raku++'s extension ABI, and the module uses it when it is there. On
Rakudo — or on a Raku++ without the built extension — the same parser runs as
plain Raku from this file. The same program runs on both.

=head2 Synopsis

    use YAML::Native;

    my %conf = from-yaml(q:to/YAML/);
        name: example
        ports: [80, 443]
        YAML
    say %conf<ports>[1];                 # 443

    say to-yaml({ a => 1, b => [True, Any] });
    say yaml-backend;                    # 'native' or 'raku'

=head2 Values

Plain scalars are resolved by the YAML 1.2 core schema: null → C<Any>,
C<true>/C<false> → C<Bool>, integers → C<Int>, floats → C<Num>; everything
else, and every quoted or block scalar, is a C<Str>. A mapping is a C<Hash>
whose keys are the keys' text, a sequence an C<Array>.

Every parse error is C<YAML::Native: E<lt>whatE<gt> at line N>, and the native
and the Raku implementation raise the same message for the same input.

=end pod

unit module YAML::Native;

# ---- helpers the extension calls back into -------------------------------------

# An octal or hexadecimal integer wider than int64: the C side has no
# arbitrary precision, and this is the one place it asks.
my sub yaml-native-int(Str $t) {
    $t.substr(1, 1) eq 'x' ?? :16($t.substr(2)) !! :8($t.substr(2))
}

# Text composed as the Raku parser composes it: see compose() in src/yaml.c.
my sub yaml-native-nfc(Str $s) { $s.NFC.Str }

# ---- loading the extension ----------------------------------------------------

# `&::(…)` is a RUNTIME lookup, so this line compiles on Rakudo too — where it
# simply yields Nil and the module runs its own Raku implementation.
my &ext-load = try &::('rakupp-ext-load');
my &native-load;
my &native-events;

# Where the compiled half might be. %?RESOURCES is the installed answer; the
# CWD form covers a git checkout tested with -Ilib. NOT $?FILE-relative: under
# Raku++ a module's $?FILE is the main program's.
sub libraries() {
    my $ext = $*DISTRO.is-win ?? 'dll' !! ($*KERNEL.name eq 'darwin' ?? 'dylib' !! 'so');
    my $stem = $*DISTRO.is-win ?? "yaml.$ext" !! "libyaml.$ext";
    my @c;
    with (try %?RESOURCES<libraries/yaml>) { @c.push($_) if .defined }
    @c.push($*CWD.add("resources/libraries/$stem"));
    @c
}

sub load-native(--> Bool) {
    return False unless &ext-load;
    # YAML_NATIVE_BACKEND=raku forces the Raku implementation on a Raku++ that
    # has the extension: for measuring the two against each other, and for a
    # user who suspects the native path and wants to know in one run.
    return False if (%*ENV<YAML_NATIVE_BACKEND> // '') eq 'raku';
    for libraries() -> $lib {
        next unless $lib.IO.e;
        next unless try ext-load($lib.Str);
        # The loader installs the extension's subs into THIS scope.
        &native-load   = try &::('yaml-native-load');
        &native-events = try &::('yaml-native-events');
        return True if &native-load && &native-events;
    }
    False
}

my Bool $is-native = load-native();

# Which implementation is answering: 'native' (the compiled extension) or
# 'raku' (this file).
our sub yaml-backend() is export(:MANDATORY) {
    $is-native ?? 'native' !! 'raku'
}

# ---- reading ------------------------------------------------------------------

our sub from-yaml($src, Bool :$all) is export(:MANDATORY) {
    my Str $text = $src ~~ IO::Path | IO::Handle ?? decode($src.slurp(:bin)) !! $src.Str;
    $is-native ?? native-load($text, $all) !! parse-raku($text, :$all)
}

# The parse as the yaml-test-suite's event stream: one event per line, "+MAP",
# "=VAL :text" and so on. What the conformance script compares, and a way to
# see exactly how a document was read.
our sub events(Str() $text --> Str) {
    $is-native ?? native-events($text) !! events-raku($text)
}

# Read as bytes and decode strictly: a YAML stream here must be UTF-8, and
# Raku++'s text-mode slurp substitutes for malformed bytes where Rakudo's
# throws, so decoding here is what makes a bad file an error on both.
#
# Rakudo's decoder also drops a leading byte-order mark and Raku++'s keeps it.
# The parser skips one BOM itself — so the one the decoder dropped is put
# back, and both engines hand the parser the same text.
my constant DECODER-DROPS-BOM = Blob.new(0xEF, 0xBB, 0xBF, 0x61).decode('utf8').chars == 1;

# Raku++'s IO::Handle.slurp ignores :bin on a handle opened for text and
# returns a Str; that Str is taken as it is.
multi sub decode(Str $s --> Str) { $s }
multi sub decode(Blob $b --> Str) {
    my $s = try $b.decode('utf8');
    die "YAML::Native: the document is not valid UTF-8" without $s;
    $s = "\x[FEFF]" ~ $s
        if DECODER-DROPS-BOM && $b.elems >= 3 && $b[0] == 0xEF && $b[1] == 0xBB && $b[2] == 0xBF;
    $s
}

# ---- the Raku implementation ---------------------------------------------------
#
# The reference the extension is held to, and what runs on Rakudo: src/yaml.c
# transcribed — the same functions, the same order of checks, the same
# messages — so that a change to one is visibly a change to the other. The
# comments that explain WHY live there; these say where the Raku differs.
#
# It scans an array of codepoints, not the string: the C side works on
# characters of UTF-8, and a combining mark or a CRLF, which Raku would glue
# to its neighbour as one character, must stay a character of its own for the
# two to agree on every column. Runs of text are cut from the string with
# substr where the string's characters and codepoints line up, which is
# nearly always.

constant MAX-DEPTH  = 128;
constant MAX-ALIAS  = 1_000_000;
constant MAX-KEYLEN = 1024;

# tokens
constant T-STREAM-START  = 0;
constant T-STREAM-END    = 1;
constant T-VERSION       = 2;
constant T-TAG-DIRECTIVE = 3;
constant T-DOC-START     = 4;
constant T-DOC-END       = 5;
constant T-BSEQ-START    = 6;
constant T-BMAP-START    = 7;
constant T-BLOCK-END     = 8;
constant T-FSEQ-START    = 9;
constant T-FSEQ-END      = 10;
constant T-FMAP-START    = 11;
constant T-FMAP-END      = 12;
constant T-BLOCK-ENTRY   = 13;
constant T-FLOW-ENTRY    = 14;
constant T-KEY           = 15;
constant T-VALUE         = 16;
constant T-ALIAS         = 17;
constant T-ANCHOR        = 18;
constant T-TAG           = 19;
constant T-SCALAR        = 20;

# styles
constant S-PLAIN   = 0;
constant S-SINGLE  = 1;
constant S-DOUBLE  = 2;
constant S-LITERAL = 3;
constant S-FOLDED  = 4;
constant S-BLOCK   = 5;
constant S-FLOW    = 6;

# nodes
constant N-SCALAR = 0;
constant N-SEQ    = 1;
constant N-MAP    = 2;
constant N-ALIAS  = 3;

# characters
constant C-TAB    = 9;
constant C-LF     = 10;
constant C-SP     = 32;
constant C-BANG   = 33;
constant C-DQ     = 34;
constant C-HASH   = 35;
constant C-PCT    = 37;
constant C-SQ     = 39;
constant C-PLUS   = 43;
constant C-DASH   = 45;
constant C-DOT    = 46;
constant C-COLON  = 58;
constant C-LT     = 60;
constant C-GT     = 62;
constant C-QMARK  = 63;
constant C-LBRACK = 91;
constant C-BSL    = 92;
constant C-RBRACK = 93;
constant C-PIPE   = 124;
constant C-LBRACE = 123;
constant C-RBRACE = 125;
constant C-AMP    = 38;
constant C-STAR   = 42;
constant C-COMMA  = 44;

# Character classes as tables over ASCII — whatever lies above is none of
# these. (Not strings tested with `contains`: see notes/TOML-Native.md on
# Rakudo's eight-bit strings.)
my int @FLOWIND   = 0 xx 128; @FLOWIND[$_]   = 1 for ',[]{}'.ords;
my int @INDICATOR = 0 xx 128; @INDICATOR[$_] = 1 for '-?:,[]{}#&*!|>\'"%@`'.ords;
my int @WORD      = 0 xx 128; @WORD[$_]      = 1 for (|('0'..'9'), |('a'..'z'), |('A'..'Z'), '-').map(*.ord);
my int @URI       = @WORD;    @URI[$_]       = 1 for q{#;/?:@&=+$_.~*'()}.ords;
my int @HEX       = -1 xx 128;
@HEX[.ord] = .Int for '0'..'9';
@HEX['a'.ord + $_] = 10 + $_ for ^6;
@HEX['A'.ord + $_] = 10 + $_ for ^6;

sub is-blank(int $b --> Bool) { $b == C-SP || $b == C-TAB }
sub is-bz(int $b --> Bool) { $b == 0 || $b == C-SP || $b == C-TAB || $b == C-LF }
sub is-flow-ind(int $b --> Bool) { $b < 128 && @FLOWIND[$b] == 1 }
sub is-indicator(int $b --> Bool) { $b < 128 && @INDICATOR[$b] == 1 }
sub is-word(int $b --> Bool) { $b < 128 && @WORD[$b] == 1 }
sub is-hex(int $b --> Bool) { $b < 128 && @HEX[$b] >= 0 }

sub printable(int $c --> Bool) {
    $c == 0x09 || $c == 0x0A || $c == 0x0D || (0x20 <= $c <= 0x7E) || $c == 0x85
        || (0xA0 <= $c <= 0xD7FF) || (0xE000 <= $c <= 0xFFFD) || (0x10000 <= $c <= 0x10FFFF)
}

# Codepoints that may compose with the one before them: the COMBINING table
# of src/yaml.c, which says why, as pairs of first and last.
my int @COMBINING = (
    0x0300, 0x036F, 0x0483, 0x0489, 0x0591, 0x05C7, 0x0610, 0x061A, 0x064B, 0x065F,
    0x0670, 0x0670, 0x06D6, 0x06ED, 0x0711, 0x0711, 0x0730, 0x074A, 0x07A6, 0x07B0,
    0x07EB, 0x07F3, 0x0816, 0x082D, 0x0859, 0x085B, 0x08D3, 0x08FF, 0x0900, 0x0DFF,
    0x0E31, 0x0E4E, 0x0EB1, 0x0ECD, 0x0F18, 0x0FC6, 0x1000, 0x109F, 0x1100, 0x11FF,
    0x135D, 0x135F, 0x1712, 0x1773, 0x17B4, 0x17DD, 0x180B, 0x180D, 0x18A9, 0x18A9,
    0x1920, 0x193B, 0x1A17, 0x1A7F, 0x1AB0, 0x1AFF, 0x1B00, 0x1BF3, 0x1C24, 0x1C37,
    0x1CD0, 0x1CF9, 0x1DC0, 0x1DFF, 0x20D0, 0x20F0, 0x2CEF, 0x2CF1, 0x2D7F, 0x2D7F,
    0x2DE0, 0x2DFF, 0x302A, 0x302F, 0x3099, 0x309A, 0xA66F, 0xA67D, 0xA69E, 0xA69F,
    0xA6F0, 0xA6F1, 0xA802, 0xA82C, 0xA880, 0xA8F1, 0xA926, 0xA953, 0xA980, 0xA9C0,
    0xAA29, 0xAA4D, 0xAAB0, 0xAAF6, 0xABE3, 0xABED, 0xFB1E, 0xFB1E, 0xFE20, 0xFE2F,
    0x101FD, 0x101FD, 0x102E0, 0x102E0, 0x10376, 0x1037A, 0x10A01, 0x10A3F,
    0x10AE5, 0x10AE6, 0x10D24, 0x10D27, 0x10F46, 0x10F50, 0x11000, 0x11FFF,
    0x16AF0, 0x16AF4, 0x16B30, 0x16B36, 0x16F4F, 0x16F92, 0x1BC9D, 0x1BC9E,
    0x1D165, 0x1D1AD, 0x1D242, 0x1D244, 0x1E000, 0x1E02A, 0x1E130, 0x1E136,
    0x1E2EC, 0x1E2EF, 0x1E8D0, 0x1E8D6, 0x1E944, 0x1E94A,
);
sub combining(int $c --> Bool) {
    return False if $c < 0x300 || (0x3400 <= $c <= 0x9FFF) || (0xAC00 <= $c <= 0xD7FF);
    my int $lo = 0;
    my int $hi = @COMBINING.elems div 2;
    while $lo < $hi {
        my int $mid = ($lo + $hi) div 2;
        if $c < @COMBINING[2 * $mid] { $hi = $mid }
        elsif $c > @COMBINING[2 * $mid + 1] { $lo = $mid + 1 }
        else { return True }
    }
    False
}

my %ESCAPE = (
    '0'.ord => "\x[0]", 'a'.ord => "\x[7]", 'b'.ord => "\b", 't'.ord => "\t",
    'n'.ord => "\n", 'v'.ord => "\x[B]", 'f'.ord => "\f", 'r'.ord => "\r", 'e'.ord => "\x[1B]",
    '/'.ord => '/', 'N'.ord => "\x[85]", '_'.ord => "\x[A0]", 'L'.ord => "\x[2028]", 'P'.ord => "\x[2029]",
);
# assigned, not in the list above: Raku++ (2026-09-24) quotes the name in
# `(C-TAB) => …` despite the parentheses, as if it were `C-TAB => …`
%ESCAPE{C-TAB} = "\t";
%ESCAPE{C-SP}  = ' ';
%ESCAPE{C-DQ}  = '"';
%ESCAPE{C-BSL} = '\\';
my %HEXLEN = 'x'.ord => 2, 'u'.ord => 4, 'U'.ord => 8;

my class Tok {
    has int $.type;
    has int $.pos;
    has int $.line;
    has int $.col;
    has int $.style is rw;
    has Str $.s is rw;
    has Str $.s2 is rw;
}

my class YNode {
    has int $.kind;
    has int $.style;
    has int $.line;
    has int $.building is rw;
    has int $.size is rw = 1;
    has Str $.anchor is rw;
    has Str $.tag is rw;
    has Str $.s is rw;
    has $.target is rw;
    has @.kids;
    has $.built is rw;
}

my class Doc {
    has $.root is rw;
    has Bool $.explicit-start is rw = False;
    has Bool $.explicit-end is rw = False;
}

# text -> documents: the scanner and the parser, as in src/yaml.c
sub parse-stream(Str:D $source) {
    # ---- the input: no BOM, LF line endings, every character one YAML allows
    my $text = $source;
    $text = $text.substr(1) if $text.starts-with("\x[FEFF]");
    $text = $text.split("\r\n").join("\n") if $text.contains("\r\n");
    $text = $text.split("\r").join("\n") if $text.contains("\r");
    # every character one YAML allows, and composed if it holds a mark that
    # may compose — prepare() in src/yaml.c
    {
        my int @o = $text.ords;
        my int $e = @o.elems;
        my int $ln = 1;
        my int $k = 0;
        my Bool $compose = False;
        while $k < $e {
            my int $ch = @o[$k];
            if $ch == C-LF { $ln = $ln + 1 }
            elsif ($ch < 0x20 && $ch != C-TAB) || ($ch > 0x7E && !printable($ch)) {
                die sprintf('YAML::Native: invalid character U+%04X at line %d', $ch, $ln);
            }
            elsif $ch >= 0x300 && !$compose && combining($ch) { $compose = True }
            $k = $k + 1;
        }
        $text = $text.NFC.Str if $compose;
    }
    my int @c = $text.ords;
    my int $n = @c.elems;
    my Bool $aligned = $text.chars == $n;
    if $n > 0 && @c[$n - 1] != C-LF {
        @c.push(C-LF);
        $text ~= "\n";
        $n = $n + 1;
    }
    # zeros past the end, as the C text ends in a NUL: every read below is
    # at most three past the position, and the position never passes $n
    @c.push(0) for ^4;

    my sub span(int $a, int $b --> Str) {
        $aligned ?? $text.substr($a, $b - $a) !! @c[$a ..^ $b].map(*.chr).join
    }

    my sub fail-at(Str $what, Int $at) { die "YAML::Native: $what at line $at" }
    my int $line = 1;
    my sub fail(Str $what) { fail-at($what, $line) }
    my sub fail-name(Str $pre, Str $t, Str $post, Int $at) { fail-at("$pre'$t'$post", $at) }

    my int $pos = 0;
    my int $col = 0;
    my sub skip() { $pos = $pos + 1; $col = $col + 1 }
    my sub skip-break() { $pos = $pos + 1; $line = $line + 1; $col = 0 }
    my sub doc-marker(int $ch --> Bool) {
        $col == 0 && @c[$pos + 0] == $ch && @c[$pos + 1] == $ch && @c[$pos + 2] == $ch && is-bz(@c[$pos + 3])
    }

    # ---- the token queue
    my @q;
    my int $qhead = 0;
    my int $parsed = 0;
    my int $started = 0;
    my int $ended = 0;
    my sub tok-insert(int $number, int $type, int $mpos, int $mline, int $mcol --> Tok) {
        # consumed tokens dropped now and then (memory only: nothing reads
        # behind the head)
        if $qhead > 256 {
            @q.splice(0, $qhead);
            $qhead = 0;
        }
        my $t = Tok.new(:$type, :pos($mpos), :line($mline), :col($mcol));
        my int $idx = $qhead + ($number - $parsed);
        if $idx == @q.elems { @q.push($t) } else { @q.splice($idx, 0, $t) }
        $t
    }
    my sub tok-add(int $type, int $mpos, int $mline, int $mcol --> Tok) {
        tok-insert($parsed + (@q.elems - $qhead), $type, $mpos, $mline, $mcol)
    }

    # ---- indentation and simple keys
    my int $indent = -1;
    my int @indents;
    my int @kp;       # possible
    my int @kr;       # required
    my int @kn;       # token number
    my int @kpos;
    my int @kline;
    my int @kcol;
    my int @kkind;
    my int $flow = 0;
    my int $key-allowed = 0;
    my int $json-key = 0;

    my sub unroll-indent(int $c) {
        return if $flow;
        while $indent > $c {
            tok-add(T-BLOCK-END, $pos, $line, $col);
            $indent = @indents.pop;
        }
    }
    my sub roll-indent(int $c, int $number, int $insert, int $type, int $mpos, int $mline, int $mcol) {
        return if $flow;
        if $indent < $c {
            my int $i = $mpos;
            while $i > 0 && is-blank(@c[$i - 1]) {
                fail-at('tabs cannot be used for indentation', $mline) if @c[$i - 1] == C-TAB;
                $i = $i - 1;
            }
            @indents.push($indent);
            $indent = $c;
            if $insert { tok-insert($number, $type, $mpos, $mline, $mcol) }
            else { tok-add($type, $mpos, $mline, $mcol) }
        }
    }
    my sub stale-keys() {
        my int $i = 0;
        my int $e = @kp.elems;
        while $i < $e {
            if @kp[$i] && @kkind[$i] != C-LBRACE
               && (@kline[$i] < $line || $pos > @kpos[$i] + MAX-KEYLEN) {
                fail-at("expected ':' after a mapping key", @kline[$i]) if @kr[$i];
                @kp[$i] = 0;
            }
            $i = $i + 1;
        }
    }
    my sub remove-key() {
        my int $t = @kp.end;
        fail-at("expected ':' after a mapping key", @kline[$t]) if @kp[$t] && @kr[$t];
        @kp[$t] = 0;
    }
    my sub save-key() {
        my int $required = ($flow == 0 && $indent == $col) ?? 1 !! 0;
        if $key-allowed {
            remove-key();
            my int $t = @kp.end;
            @kp[$t] = 1;
            @kr[$t] = $required;
            @kn[$t] = $parsed + (@q.elems - $qhead);
            @kpos[$t] = $pos;
            @kline[$t] = $line;
            @kcol[$t] = $col;
        }
    }
    my sub push-level(int $kind) {
        @kp.push(0); @kr.push(0); @kn.push(0); @kpos.push(0); @kline.push(0); @kcol.push(0);
        @kkind.push($kind);
    }
    my sub pop-level() {
        @kp.pop; @kr.pop; @kn.pop; @kpos.pop; @kline.pop; @kcol.pop; @kkind.pop;
    }

    # ---- whitespace, comments, and where a flow line may start
    my sub leading-spaces(--> int) {
        my int $i = $pos;
        $i = $i - 1 while $i > 0 && is-blank(@c[$i - 1]);
        return -1 if $i > 0 && @c[$i - 1] != C-LF;
        my int $k = 0;
        $k = $k + 1 while @c[$i + $k] == C-SP;
        $k
    }
    my sub flow-line() {
        my int $c = @c[$pos];
        return if !$flow || $c == C-LF || $c == 0 || $c == C-HASH;
        my int $sp = leading-spaces();
        fail("a flow collection's lines must be indented") if $sp >= 0 && $sp <= $indent;
    }
    my sub scan-to-next() {
        loop {
            while @c[$pos] == C-SP || @c[$pos] == C-TAB { $pos = $pos + 1; $col = $col + 1 }
            if @c[$pos] == C-HASH {
                fail('a comment must be separated from what precedes it by a space')
                    if $pos > 0 && !is-blank(@c[$pos - 1]) && @c[$pos - 1] != C-LF;
                while $pos < $n && @c[$pos] != C-LF { $pos = $pos + 1; $col = $col + 1 }
            }
            last if @c[$pos] != C-LF;
            skip-break();
            $key-allowed = 1 unless $flow;
        }
        flow-line();
    }

    # ---- the tokens
    my sub fetch-stream-start() {
        $indent = -1;
        push-level(0);
        $key-allowed = 1;
        $started = 1;
        tok-add(T-STREAM-START, $pos, $line, $col);
    }
    my sub fetch-stream-end() {
        fail(@kkind[@kkind.end] == C-LBRACK ?? 'unterminated flow sequence' !! 'unterminated flow mapping') if $flow;
        unroll-indent(-1);
        remove-key();
        $key-allowed = 0;
        $ended = 1;
        tok-add(T-STREAM-END, $pos, $line, $col);
    }
    my sub end-of-line(Str $what) {
        skip() while is-blank(@c[$pos]);
        if @c[$pos] == C-HASH {
            fail('a comment must be separated from what precedes it by a space') unless is-blank(@c[$pos - 1]);
            while $pos < $n && @c[$pos] != C-LF { $pos = $pos + 1; $col = $col + 1 }
        }
        fail($what) if @c[$pos] != C-LF && @c[$pos] != 0;
    }
    my sub is-digit(int $b --> Bool) { 48 <= $b <= 57 }
    my sub fetch-directive() {
        unroll-indent(-1);
        remove-key();
        $key-allowed = 0;
        my int $mp = $pos; my int $ml = $line; my int $mc = $col;
        skip();
        my int $start = $pos;
        skip() while !is-bz(@c[$pos]);
        my $name = span($start, $pos);
        if $name eq 'YAML' {
            fail('invalid %YAML directive') unless is-blank(@c[$pos]);
            skip() while is-blank(@c[$pos]);
            my int $vs = $pos;
            fail('invalid %YAML directive') unless is-digit(@c[$pos]);
            skip() while is-digit(@c[$pos]);
            fail('invalid %YAML directive') if @c[$pos] != C-DOT;
            skip();
            fail('invalid %YAML directive') unless is-digit(@c[$pos]);
            skip() while is-digit(@c[$pos]);
            my $t = tok-add(T-VERSION, $mp, $ml, $mc);
            $t.s = span($vs, $pos);
            end-of-line('invalid %YAML directive');
        }
        elsif $name eq 'TAG' {
            fail('invalid %TAG directive') unless is-blank(@c[$pos]);
            skip() while is-blank(@c[$pos]);
            my int $hs = $pos;
            fail('invalid %TAG directive') if @c[$pos] != C-BANG;
            skip();
            unless is-blank(@c[$pos]) {
                skip() while is-word(@c[$pos]);
                fail('invalid %TAG directive') if @c[$pos] != C-BANG;
                skip();
            }
            my int $he = $pos;
            fail('invalid %TAG directive') unless is-blank(@c[$pos]);
            skip() while is-blank(@c[$pos]);
            my int $ps = $pos;
            fail('invalid %TAG directive') if is-bz(@c[$pos]) || is-flow-ind(@c[$pos]);
            skip() while !is-bz(@c[$pos]);
            my $t = tok-add(T-TAG-DIRECTIVE, $mp, $ml, $mc);
            $t.s  = span($hs, $he);
            $t.s2 = span($ps, $pos);
            end-of-line('invalid %TAG directive');
        }
        else {
            while $pos < $n && @c[$pos] != C-LF { $pos = $pos + 1; $col = $col + 1 }
        }
    }
    my sub fetch-document-indicator(int $type) {
        unroll-indent(-1);
        remove-key();
        $key-allowed = 0;
        my int $mp = $pos; my int $ml = $line; my int $mc = $col;
        skip(); skip(); skip();
        tok-add($type, $mp, $ml, $mc);
        end-of-line('a document end marker must be alone on its line') if $type == T-DOC-END;
    }
    my sub fetch-flow-start(int $type, int $kind) {
        save-key();
        push-level($kind);
        $flow = $flow + 1;
        fail('nesting is limited to 128 levels') if $flow > MAX-DEPTH;
        $key-allowed = 1;
        my int $mp = $pos; my int $ml = $line; my int $mc = $col;
        skip();
        tok-add($type, $mp, $ml, $mc);
    }
    my sub fetch-flow-end(int $type) {
        my int $want = $type == T-FSEQ-END ?? C-LBRACK !! C-LBRACE;
        fail($type == T-FSEQ-END ?? "']' without a matching '['" !! "'}' without a matching '\{'")
            if !$flow || @kkind[@kkind.end] != $want;
        remove-key();
        pop-level();
        $flow = $flow - 1;
        $key-allowed = 0;
        my int $mp = $pos; my int $ml = $line; my int $mc = $col;
        skip();
        tok-add($type, $mp, $ml, $mc);
        $json-key = 1;
    }
    my sub fetch-flow-entry() {
        fail("',' outside a flow collection") unless $flow;
        remove-key();
        $key-allowed = 1;
        my int $mp = $pos; my int $ml = $line; my int $mc = $col;
        skip();
        tok-add(T-FLOW-ENTRY, $mp, $ml, $mc);
    }
    my sub fetch-block-entry() {
        my int $mp = $pos; my int $ml = $line; my int $mc = $col;
        fail('a block sequence entry cannot be inside a flow collection') if $flow;
        fail('a block sequence entry is not allowed here') unless $key-allowed;
        roll-indent($col, 0, 0, T-BSEQ-START, $mp, $ml, $mc);
        remove-key();
        $key-allowed = 1;
        skip();
        tok-add(T-BLOCK-ENTRY, $mp, $ml, $mc);
    }
    my sub fetch-key() {
        my int $mp = $pos; my int $ml = $line; my int $mc = $col;
        unless $flow {
            fail('a mapping key is not allowed here') unless $key-allowed;
            roll-indent($col, 0, 0, T-BMAP-START, $mp, $ml, $mc);
        }
        remove-key();
        $key-allowed = $flow ?? 0 !! 1;
        skip();
        tok-add(T-KEY, $mp, $ml, $mc);
    }
    my sub fetch-value() {
        my int $mp = $pos; my int $ml = $line; my int $mc = $col;
        my int $t = @kp.end;
        if @kp[$t] {
            tok-insert(@kn[$t], T-KEY, @kpos[$t], @kline[$t], @kcol[$t]);
            roll-indent(@kcol[$t], @kn[$t], 1, T-BMAP-START, @kpos[$t], @kline[$t], @kcol[$t]);
            @kp[$t] = 0;
            $key-allowed = 0;
        }
        else {
            unless $flow {
                fail('a mapping value is not allowed here') unless $key-allowed;
                roll-indent($col, 0, 0, T-BMAP-START, $mp, $ml, $mc);
            }
            $key-allowed = $flow ?? 0 !! 1;
        }
        skip();
        tok-add(T-VALUE, $mp, $ml, $mc);
    }
    my sub fetch-anchor(int $type) {
        save-key();
        $key-allowed = 0;
        my int $mp = $pos; my int $ml = $line; my int $mc = $col;
        skip();
        my int $start = $pos;
        skip() while !is-bz(@c[$pos]) && !is-flow-ind(@c[$pos]);
        fail($type == T-ALIAS ?? 'an alias needs a name' !! 'an anchor needs a name') if $pos == $start;
        my $t = tok-add($type, $mp, $ml, $mc);
        $t.s = span($start, $pos);
    }

    # a tag's suffix is gathered as bytes, since a %-escape is one
    my $tagbuf;
    my sub uri-char(int $verbatim --> Bool) {
        my int $c = @c[$pos];
        if $c == C-PCT {
            fail('invalid escape in a tag') unless is-hex(@c[$pos + 1]) && is-hex(@c[$pos + 2]);
            $tagbuf.push(@HEX[@c[$pos + 1]] * 16 + @HEX[@c[$pos + 2]]);
            skip(); skip(); skip();
            return True;
        }
        if ($c < 128 && @URI[$c] == 1)
           || ($verbatim && ($c == C-BANG || $c == C-COMMA || $c == C-LBRACK || $c == C-RBRACK)) {
            $tagbuf.push($c);
            skip();
            return True;
        }
        False
    }
    my sub fetch-tag() {
        save-key();
        $key-allowed = 0;
        my int $mp = $pos; my int $ml = $line; my int $mc = $col;
        $tagbuf = Buf.new;
        my Str $handle;
        if @c[$pos + 1] == C-LT {
            skip(); skip();
            Nil while uri-char(1);
            fail('invalid verbatim tag') if @c[$pos] != C-GT || $tagbuf.elems == 0;
            skip();
            $handle = '';
        }
        else {
            my int $hs = $pos;
            skip();
            my int $i = 0;
            $i = $i + 1 while is-word(@c[$pos + $i]);
            if @c[$pos + $i] == C-BANG {
                my int $j = 0;
                while $j <= $i { skip(); $j = $j + 1 }
                $handle = span($hs, $pos);
            }
            else {
                $handle = '!';
            }
            Nil while uri-char(0);
            fail('a tag needs a suffix') if $tagbuf.elems == 0 && $handle.chars > 1;
        }
        my $suffix = try $tagbuf.decode('utf8');
        fail('invalid escape in a tag') without $suffix;
        fail('a tag must be followed by a space') if !is-bz(@c[$pos]) && !($flow && is-flow-ind(@c[$pos]));
        my $t = tok-add(T-TAG, $mp, $ml, $mc);
        $t.s  = $handle;
        $t.s2 = $suffix;
    }

    # ---- scalars
    my Str $sb = '';
    my Str $lb = '';
    my Str $tb = '';
    my Str $wb = '';
    my sub fold-in(int $leading) {
        if $leading {
            if $lb ne '' { $sb ~= $tb eq '' ?? ' ' !! $tb }
            else { $sb ~= $tb }
            $lb = '';
            $tb = '';
        }
        else {
            $sb ~= $wb;
            $wb = '';
        }
    }
    my sub scalar-token(int $mp, int $ml, int $mc, int $style) {
        my $t = tok-add(T-SCALAR, $mp, $ml, $mc);
        $t.style = $style;
        $t.s = $sb;
    }
    my sub scan-quoted(int $single) {
        save-key();
        $key-allowed = 0;
        my int $mp = $pos; my int $ml = $line; my int $mc = $col;
        $sb = ''; $lb = ''; $tb = ''; $wb = '';
        my int $leading = 0;
        my int $quote = $single ?? C-SQ !! C-DQ;
        skip();
        loop {
            fail('a document marker inside a quoted scalar') if $col == 0 && (doc-marker(C-DASH) || doc-marker(C-DOT));
            fail-at('unterminated quoted scalar', $ml) if @c[$pos] == 0;
            fail("a quoted scalar's lines must be indented") if $leading && @c[$pos] != C-LF && leading-spaces() <= $indent;
            $leading = 0;
            while !is-bz(@c[$pos]) {
                my int $c = @c[$pos];
                last if $single && $c == C-SQ && @c[$pos + 1] != C-SQ;
                last if !$single && $c == C-DQ;
                fold-in(0);
                if $single && $c == C-SQ { $sb ~= "'"; skip(); skip(); next }
                if !$single && $c == C-BSL && @c[$pos + 1] == C-LF {
                    skip();
                    skip-break();
                    $leading = 1;
                    last;
                }
                if !$single && $c == C-BSL {
                    my int $e = @c[$pos + 1];
                    my $simple = %ESCAPE{$e};
                    my int $digits = %HEXLEN{$e} // 0;
                    fail('invalid escape in a double-quoted scalar') if !$simple.defined && !$digits;
                    skip(); skip();
                    if $digits {
                        my int $v = 0;
                        my int $k = 0;
                        while $k < $digits {
                            fail('invalid escape in a double-quoted scalar') unless is-hex(@c[$pos]);
                            $v = $v * 16 + @HEX[@c[$pos]];
                            skip();
                            $k = $k + 1;
                        }
                        fail('invalid Unicode escape in a double-quoted scalar')
                            if (0xD800 <= $v <= 0xDFFF) || $v > 0x10FFFF;
                        $sb ~= $v.chr;
                    }
                    else { $sb ~= $simple }
                    next;
                }
                # a run of ordinary characters
                my int $a = $pos;
                repeat { $pos = $pos + 1; $col = $col + 1 }
                    while $pos < $n && !is-bz(@c[$pos]) && @c[$pos] != $quote && !(!$single && @c[$pos] == C-BSL);
                $sb ~= span($a, $pos);
            }
            last if @c[$pos] == $quote;
            while is-blank(@c[$pos]) || @c[$pos] == C-LF {
                if is-blank(@c[$pos]) {
                    $wb ~= @c[$pos].chr unless $leading;
                    skip();
                }
                else {
                    if !$leading { $wb = ''; $lb = "\n"; $leading = 1 }
                    else { $tb ~= "\n" }
                    skip-break();
                }
            }
            fold-in(1) if $leading;
        }
        fold-in(0);
        skip();
        scalar-token($mp, $ml, $mc, $single ?? S-SINGLE !! S-DOUBLE);
        $json-key = 1;
    }
    my sub scan-plain() {
        save-key();
        $key-allowed = 0;
        my int $mp = $pos; my int $ml = $line; my int $mc = $col;
        my int $ind = $indent + 1;
        my int $leading = 0;
        $sb = ''; $lb = ''; $tb = ''; $wb = '';
        loop {
            last if $col == 0 && (doc-marker(C-DASH) || doc-marker(C-DOT));
            last if @c[$pos] == C-HASH;
            loop {
                my int $c = @c[$pos];
                last if $c == 0 || $c == C-SP || $c == C-TAB || $c == C-LF;
                last if $c == C-COLON && (is-bz(@c[$pos + 1]) || ($flow && is-flow-ind(@c[$pos + 1])));
                last if $flow && is-flow-ind($c);
                if $leading {
                    if $flow { flow-line() }
                    elsif leading-spaces() <= $indent { fail('tabs cannot be used for indentation') }
                    fold-in(1);
                    $leading = 0;
                }
                else { fold-in(0) }
                my int $a = $pos;
                my int $d;
                repeat { $pos = $pos + 1; $col = $col + 1; $d = @c[$pos] }
                    while $d > C-SP ?? $d != C-COLON && !($flow && ($d == C-COMMA || $d == C-LBRACK || $d == C-RBRACK || $d == C-LBRACE || $d == C-RBRACE))
                                    !! !($d == 0 || $d == C-SP || $d == C-TAB || $d == C-LF);
                $sb ~= span($a, $pos);
            }
            last unless @c[$pos] == C-SP || @c[$pos] == C-TAB || @c[$pos] == C-LF;
            while @c[$pos] == C-SP || @c[$pos] == C-TAB || @c[$pos] == C-LF {
                if @c[$pos] != C-LF {
                    $wb ~= @c[$pos].chr unless $leading;
                    skip();
                }
                else {
                    if !$leading { $wb = ''; $lb = "\n"; $leading = 1 }
                    else { $tb ~= "\n" }
                    skip-break();
                }
            }
            last if !$flow && $col < $ind;
        }
        scalar-token($mp, $ml, $mc, S-PLAIN);
        $key-allowed = 1 if $leading;
    }
    my sub block-breaks(int $ind) {
        loop {
            skip() while $col < $ind && @c[$pos] == C-SP;
            fail('tabs cannot be used for indentation') if $col < $ind && @c[$pos] == C-TAB;
            last if @c[$pos] != C-LF;
            $tb ~= "\n";
            skip-break();
        }
    }
    my sub scan-block-scalar(int $literal) {
        my int $chomp = 0;
        my int $inc = 0;
        my int $leading-blank = 0;
        remove-key();
        $key-allowed = 1;
        my int $mp = $pos; my int $ml = $line; my int $mc = $col;
        $sb = ''; $lb = ''; $tb = '';
        skip();
        if @c[$pos] == C-PLUS || @c[$pos] == C-DASH {
            $chomp = @c[$pos] == C-PLUS ?? 1 !! -1;
            skip();
            if is-digit(@c[$pos]) {
                fail("a block scalar's indentation indicator must be 1 to 9") if @c[$pos] == 48;
                $inc = @c[$pos] - 48;
                skip();
            }
        }
        elsif is-digit(@c[$pos]) {
            fail("a block scalar's indentation indicator must be 1 to 9") if @c[$pos] == 48;
            $inc = @c[$pos] - 48;
            skip();
            if @c[$pos] == C-PLUS || @c[$pos] == C-DASH { $chomp = @c[$pos] == C-PLUS ?? 1 !! -1; skip() }
        }
        fail('invalid block scalar header') unless is-bz(@c[$pos]);
        end-of-line('invalid block scalar header');
        skip-break() if @c[$pos] == C-LF;

        my int $min = $indent + 1;
        my int $ind;
        if $inc { $ind = $indent + $inc }
        else {
            my int $p = $pos;
            my int $longest = 0;
            my int $lines = 0;
            my int $cl = 0;
            loop {
                $cl = 0;
                while @c[$p] == C-SP { $p = $p + 1; $cl = $cl + 1 }
                fail-at('tabs cannot be used for indentation', $line + $lines) if @c[$p] == C-TAB && $cl < $min;
                last if @c[$p] != C-LF;
                $longest = $cl if $cl > $longest;
                $p = $p + 1;
                $lines = $lines + 1;
            }
            if $p >= $n || $cl < $min { $ind = $longest > $min ?? $longest !! $min }
            else {
                $ind = $cl;
                fail-at("a block scalar's leading empty lines are indented more than its first line", $line + $lines)
                    if $longest > $ind;
            }
        }
        block-breaks($ind);
        loop {
            last if $col != $ind || @c[$pos] == 0;
            last if $col == 0 && (doc-marker(C-DASH) || doc-marker(C-DOT));
            my int $trailing-blank = is-blank(@c[$pos]) ?? 1 !! 0;
            if !$literal && $lb ne '' && !$leading-blank && !$trailing-blank {
                $sb ~= ' ' if $tb eq '';
                $lb = '';
            }
            else {
                $sb ~= $lb;
                $lb = '';
            }
            $sb ~= $tb;
            $tb = '';
            $leading-blank = is-blank(@c[$pos]) ?? 1 !! 0;
            my int $a = $pos;
            while $pos < $n && @c[$pos] != C-LF { $pos = $pos + 1; $col = $col + 1 }
            $sb ~= span($a, $pos);
            last if @c[$pos] == 0;
            $lb ~= "\n";
            skip-break();
            block-breaks($ind);
        }
        $sb ~= $lb if $chomp != -1;
        $sb ~= $tb if $chomp == 1;
        scalar-token($mp, $ml, $mc, $literal ?? S-LITERAL !! S-FOLDED);
    }

    # ---- the dispatcher
    my sub fetch-next() {
        my int $was-json = $json-key;
        $json-key = 0;
        unless $started { fetch-stream-start(); return }
        scan-to-next();
        stale-keys();
        unroll-indent($col);
        my int $c = @c[$pos];
        if $c == 0 { fetch-stream-end(); return }
        if $col == 0 && $c == C-PCT { fetch-directive(); return }
        if doc-marker(C-DASH) { fetch-document-indicator(T-DOC-START); return }
        if doc-marker(C-DOT) { fetch-document-indicator(T-DOC-END); return }
        my int $n1 = @c[$pos + 1];
        if $c == C-LBRACK { fetch-flow-start(T-FSEQ-START, C-LBRACK); return }
        if $c == C-LBRACE { fetch-flow-start(T-FMAP-START, C-LBRACE); return }
        if $c == C-RBRACK { fetch-flow-end(T-FSEQ-END); return }
        if $c == C-RBRACE { fetch-flow-end(T-FMAP-END); return }
        if $c == C-COMMA { fetch-flow-entry(); return }
        if $c == C-DASH && is-bz($n1) { fetch-block-entry(); return }
        if $c == C-QMARK && is-bz($n1) { fetch-key(); return }
        if $c == C-COLON && (is-bz($n1) || ($flow && (is-flow-ind($n1) || $was-json))) {
            fetch-value();
            return;
        }
        if $c == C-STAR { fetch-anchor(T-ALIAS); return }
        if $c == C-AMP { fetch-anchor(T-ANCHOR); return }
        if $c == C-BANG { fetch-tag(); return }
        if $c == C-PIPE && !$flow { scan-block-scalar(1); return }
        if $c == C-GT && !$flow { scan-block-scalar(0); return }
        if $c == C-SQ { scan-quoted(1); return }
        if $c == C-DQ { scan-quoted(0); return }
        if (!is-bz($c) && !is-indicator($c))
           || (($c == C-DASH || $c == C-QMARK || $c == C-COLON) && !is-bz($n1) && !($flow && is-flow-ind($n1))) {
            scan-plain();
            return;
        }
        fail($c == C-TAB ?? 'unexpected tab' !! "unexpected '{$c.chr}'");
    }
    my sub fetch-more() {
        loop {
            my int $need = 0;
            if $qhead == @q.elems { $need = 1 }
            else {
                stale-keys();
                my int $i = 0;
                my int $e = @kp.elems;
                while $i < $e {
                    if @kp[$i] && @kn[$i] == $parsed { $need = 1; $i = $e }
                    $i = $i + 1;
                }
            }
            return if !$need || $ended;
            fetch-next();
        }
    }
    # the head of the queue, unless a simple key still pending could put a
    # KEY in front of it — as peek() in src/yaml.c
    my sub peek(--> Tok) {
        if $qhead < @q.elems {
            return @q[$qhead] if $ended;
            my int $i = 0;
            my int $e = @kp.elems;
            my int $blocked = 0;
            while $i < $e {
                $blocked = 1 if @kp[$i] && @kn[$i] == $parsed;
                $i = $i + 1;
            }
            return @q[$qhead] unless $blocked;
        }
        fetch-more();
        @q[$qhead]
    }
    my sub next-tok() { $qhead = $qhead + 1; $parsed = $parsed + 1 }

    # ---- parsing
    my %anchors;
    my %tags;
    my int $depth = 0;
    my @docs;

    my sub new-node(int $kind, int $style, int $ln --> YNode) {
        YNode.new(:$kind, :$style, :line($ln))
    }
    my sub add-child(YNode $p, YNode $c) {
        $p.kids.push($c);
        my int $size = $p.size + $c.size;
        $p.size = $size > MAX-ALIAS + 1 ?? MAX-ALIAS + 1 !! $size;
    }
    my sub empty-node(int $ln --> YNode) {
        my $node = new-node(N-SCALAR, S-PLAIN, $ln);
        $node.s = '';
        $node
    }
    my sub resolve-tag(Tok $t --> Str) {
        return $t.s2 if $t.s eq '';
        return '!' if $t.s eq '!' && $t.s2 eq '';
        my $prefix = %tags{$t.s};
        without $prefix {
            if $t.s eq '!' { $prefix = '!' }
            elsif $t.s eq '!!' { $prefix = 'tag:yaml.org,2002:' }
            else { fail-name('undefined tag handle ', $t.s, '', $t.line) }
        }
        $prefix ~ $t.s2
    }
    my sub enter() {
        $depth = $depth + 1;
        fail('nesting is limited to 128 levels') if $depth > MAX-DEPTH;
    }

    my &parse-node;

    my sub parse-block-seq(YNode $node) {
        next-tok();
        loop {
            my $t = peek();
            if $t.type == T-BLOCK-ENTRY {
                my int $ln = $t.line;
                next-tok();
                $t = peek();
                if $t.type == T-BLOCK-ENTRY || $t.type == T-BLOCK-END { add-child($node, empty-node($ln)) }
                else { add-child($node, parse-node(1, 0)) }
            }
            elsif $t.type == T-BLOCK-END { next-tok(); last }
            else { fail-at("expected a sequence entry ('-')", $t.line) }
        }
    }
    my sub parse-indentless-seq(YNode $node) {
        loop {
            my $t = peek();
            last if $t.type != T-BLOCK-ENTRY;
            my int $ln = $t.line;
            next-tok();
            $t = peek();
            if $t.type == T-BLOCK-ENTRY || $t.type == T-KEY || $t.type == T-VALUE || $t.type == T-BLOCK-END {
                add-child($node, empty-node($ln));
            }
            else { add-child($node, parse-node(1, 0)) }
        }
    }
    my sub block-value(YNode $node, int $ln) {
        my $t = peek();
        if $t.type == T-KEY || $t.type == T-VALUE || $t.type == T-BLOCK-END { add-child($node, empty-node($ln)) }
        else { add-child($node, parse-node(1, 1)) }
    }
    my sub parse-block-map(YNode $node) {
        next-tok();
        loop {
            my $t = peek();
            my int $ln = $t.line;
            if $t.type == T-KEY {
                next-tok();
                block-value($node, $ln);
                $t = peek();
                $ln = $t.line;
                if $t.type == T-VALUE {
                    next-tok();
                    block-value($node, $ln);
                }
                else { add-child($node, empty-node($ln)) }
            }
            elsif $t.type == T-VALUE {
                add-child($node, empty-node($ln));
                next-tok();
                block-value($node, $ln);
            }
            elsif $t.type == T-BLOCK-END { next-tok(); last }
            else { fail-at('expected a mapping key', $t.line) }
        }
    }
    my sub parse-flow-pair(int $end --> YNode) {
        my $t = peek();
        my $m = new-node(N-MAP, S-FLOW, $t.line);
        my int $ln = $t.line;
        if $t.type == T-KEY {
            next-tok();
            $t = peek();
            if $t.type == T-VALUE || $t.type == T-FLOW-ENTRY || $t.type == $end { add-child($m, empty-node($ln)) }
            else { add-child($m, parse-node(0, 0)) }
        }
        else { add-child($m, empty-node($ln)) }
        $t = peek();
        $ln = $t.line;
        if $t.type == T-VALUE {
            next-tok();
            $t = peek();
            if $t.type == T-FLOW-ENTRY || $t.type == $end { add-child($m, empty-node($ln)) }
            else { add-child($m, parse-node(0, 0)) }
        }
        else { add-child($m, empty-node($ln)) }
        $m
    }
    my sub parse-flow-seq(YNode $node) {
        my int $first = 1;
        next-tok();
        loop {
            my $t = peek();
            if $t.type == T-FSEQ-END { next-tok(); last }
            unless $first {
                fail-at("expected ',' or ']'", $t.line) if $t.type != T-FLOW-ENTRY;
                next-tok();
                $t = peek();
                if $t.type == T-FSEQ-END { next-tok(); last }
            }
            $first = 0;
            fail-at('an empty entry in a flow sequence', $t.line) if $t.type == T-FLOW-ENTRY;
            if $t.type == T-KEY || $t.type == T-VALUE {
                enter();
                add-child($node, parse-flow-pair(T-FSEQ-END));
                $depth = $depth - 1;
            }
            else { add-child($node, parse-node(0, 0)) }
        }
    }
    my sub parse-flow-map(YNode $node) {
        my int $first = 1;
        next-tok();
        loop {
            my $t = peek();
            if $t.type == T-FMAP-END { next-tok(); last }
            unless $first {
                fail-at("expected ',' or '\}'", $t.line) if $t.type != T-FLOW-ENTRY;
                next-tok();
                $t = peek();
                if $t.type == T-FMAP-END { next-tok(); last }
            }
            $first = 0;
            my int $ln = $t.line;
            fail-at('an empty entry in a flow mapping', $ln) if $t.type == T-FLOW-ENTRY;
            if $t.type == T-KEY {
                next-tok();
                $t = peek();
                if $t.type == T-VALUE || $t.type == T-FLOW-ENTRY || $t.type == T-FMAP-END { add-child($node, empty-node($ln)) }
                else { add-child($node, parse-node(0, 0)) }
            }
            elsif $t.type == T-VALUE { add-child($node, empty-node($ln)) }
            else { add-child($node, parse-node(0, 0)) }
            $t = peek();
            $ln = $t.line;
            if $t.type == T-VALUE {
                next-tok();
                $t = peek();
                if $t.type == T-FLOW-ENTRY || $t.type == T-FMAP-END { add-child($node, empty-node($ln)) }
                else { add-child($node, parse-node(0, 0)) }
            }
            else { add-child($node, empty-node($ln)) }
        }
    }
    my sub apply-props(YNode $node, $anchor, $tag) {
        with $anchor { $node.anchor = $anchor; %anchors{$anchor} = $node }
        with $tag { $node.tag = $tag }
    }
    &parse-node = sub (int $block, int $indentless --> YNode) {
        my $t = peek();
        my int $pline = $t.line;
        my Str $anchor;
        my Str $tag;
        loop {
            $t = peek();
            if $t.type == T-ANCHOR {
                fail-at('a node can have only one anchor', $t.line) with $anchor;
                $anchor = $t.s;
                next-tok();
            }
            elsif $t.type == T-TAG {
                fail-at('a node can have only one tag', $t.line) with $tag;
                $tag = resolve-tag($t);
                next-tok();
            }
            else { last }
        }
        $t = peek();
        my int $type = $t.type;
        if $type == T-ALIAS {
            fail-at('an alias cannot have an anchor or a tag', $t.line) if $anchor.defined || $tag.defined;
            my $node = new-node(N-ALIAS, S-PLAIN, $t.line);
            $node.s = $t.s;
            my $target = %anchors{$t.s};
            fail-name('undefined alias ', $t.s, '', $t.line) without $target;
            $node.target = $target;
            $node.size = $target.building ?? 1 !! $target.size;
            next-tok();
            return $node;
        }
        if $type == T-SCALAR {
            my $node = new-node(N-SCALAR, $t.style, $t.line);
            $node.s = $t.s;
            apply-props($node, $anchor, $tag);
            next-tok();
            return $node;
        }
        if $type == T-FSEQ-START || $type == T-FMAP-START
           || ($block && ($type == T-BSEQ-START || $type == T-BMAP-START)) {
            my $node = new-node($type == T-FSEQ-START || $type == T-BSEQ-START ?? N-SEQ !! N-MAP,
                                $type == T-FSEQ-START || $type == T-FMAP-START ?? S-FLOW !! S-BLOCK, $t.line);
            apply-props($node, $anchor, $tag);
            $node.building = 1;
            enter();
            if    $type == T-FSEQ-START { parse-flow-seq($node) }
            elsif $type == T-FMAP-START { parse-flow-map($node) }
            elsif $type == T-BSEQ-START { parse-block-seq($node) }
            else                        { parse-block-map($node) }
            $depth = $depth - 1;
            $node.building = 0;
            return $node;
        }
        if $type == T-BLOCK-ENTRY && $block && $indentless {
            my $node = new-node(N-SEQ, S-BLOCK, $t.line);
            apply-props($node, $anchor, $tag);
            $node.building = 1;
            enter();
            parse-indentless-seq($node);
            $depth = $depth - 1;
            $node.building = 0;
            return $node;
        }
        if $anchor.defined || $tag.defined {
            my $node = empty-node($pline);
            apply-props($node, $anchor, $tag);
            return $node;
        }
        fail-at('expected a node', $t.line);
    };

    # ---- the stream
    my int $open = 0;
    peek();
    next-tok();
    loop {
        my $t = peek();
        last if $t.type == T-STREAM-END;
        if $t.type == T-DOC-END { next-tok(); $open = 0; next }
        %tags = ();
        %anchors = ();
        my int $directives = 0;
        my int $version = 0;
        while $t.type == T-VERSION || $t.type == T-TAG-DIRECTIVE {
            fail-at("a directive must follow a document end marker ('...')", $t.line) if $open;
            $directives = 1;
            if $t.type == T-VERSION {
                fail-at('a document can have only one %YAML directive', $t.line) if $version;
                $version = 1;
                fail-at('unsupported YAML version', $t.line) unless $t.s.starts-with('1.');
            }
            else {
                fail-name('the tag handle ', $t.s, ' is declared twice', $t.line) if %tags{$t.s}:exists;
                %tags{$t.s} = $t.s2;
            }
            next-tok();
            $t = peek();
        }
        my $d = Doc.new;
        if $t.type == T-DOC-START {
            my int $ln = $t.line;
            $d.explicit-start = True;
            next-tok();
            $t = peek();
            if $t.type == T-VERSION || $t.type == T-TAG-DIRECTIVE || $t.type == T-DOC-START
               || $t.type == T-DOC-END || $t.type == T-STREAM-END {
                $d.root = empty-node($ln);
            }
            else { $d.root = parse-node(1, 0) }
        }
        else {
            fail-at("directives must be followed by '---'", $t.line) if $directives;
            $d.root = parse-node(1, 0);
        }
        @docs.push($d);
        $t = peek();
        if $t.type == T-DOC-END {
            $d.explicit-end = True;
            next-tok();
            $open = 0;
        }
        elsif $t.type == T-DOC-START { $open = 1 }
        elsif $t.type == T-STREAM-END { $open = 0 }
        elsif $t.type == T-VERSION || $t.type == T-TAG-DIRECTIVE {
            fail-at("a directive must follow a document end marker ('...')", $t.line);
        }
        else { fail-at('unexpected content after the document', $t.line) }
    }
    @docs
}

# ---- the event stream, in the yaml-test-suite's notation ---------------------
sub ev-text(Str $s --> Str) {
    # "\r\n" is one character in Raku, so it is escaped before "\r" and "\n"
    $s.subst('\\', '\\\\', :g).subst("\r\n", '\\r\\n', :g).subst("\r", '\\r', :g)
      .subst("\n", '\\n', :g).subst("\t", '\\t', :g).subst("\b", '\\b', :g).subst("\x[0]", '\\0', :g)
}
sub ev-props(YNode $n --> Str) {
    ($n.anchor.defined ?? " &{$n.anchor}" !! '') ~ ($n.tag.defined ?? " <{$n.tag}>" !! '')
}
sub ev-node(YNode $n, @out) {
    if $n.kind == N-ALIAS { @out.push("=ALI *{$n.s}"); return }
    if $n.kind == N-SCALAR {
        @out.push('=VAL' ~ ev-props($n) ~ ' ' ~ ':\'"|>'.substr($n.style, 1) ~ ev-text($n.s));
        return;
    }
    my $seq = $n.kind == N-SEQ;
    @out.push(($seq ?? '+SEQ' !! '+MAP') ~ ($n.style == S-FLOW ?? ($seq ?? ' []' !! ' {}') !! '') ~ ev-props($n));
    ev-node($_, @out) for $n.kids;
    @out.push($seq ?? '-SEQ' !! '-MAP');
}

our sub events-raku(Str:D $text --> Str) {
    my @docs = parse-stream($text);
    my @out = '+STR';
    for @docs -> $d {
        @out.push($d.explicit-start ?? '+DOC ---' !! '+DOC');
        ev-node($d.root, @out);
        @out.push($d.explicit-end ?? '-DOC ...' !! '-DOC');
    }
    @out.push('-STR');
    @out.join("\n") ~ "\n"
}

# ---- construction --------------------------------------------------------------
#
# Plain scalars are resolved by the YAML 1.2 core schema; quoted and block
# scalars are strings. A tag from the core schema overrides the style; any
# other tag is kept in the event stream and otherwise ignored. The forms are
# checked on codepoints, as the C side checks bytes: a regex's \d would take
# digits from any script.

constant YAML-CORE = 'tag:yaml.org,2002:';
my %NULL = ('', '~', 'null', 'Null', 'NULL').map(* => True);
my %BOOL = true => True, True => True, TRUE => True, false => False, False => False, FALSE => False;
my %INF  = ('inf', 'Inf', 'INF').map(* => True);
my %NAN  = ('.nan', '.NaN', '.NAN').map(* => True);

sub is-dig(int $c --> Bool) { 48 <= $c <= 57 }

# 1 decimal, 8 octal (0o), 16 hex (0x); 0 if not an integer
sub int-form(Str $t --> int) {
    my int @o = $t.ords;
    my int $n = @o.elems;
    my int $i = 0;
    if $n > 2 && @o[0] == 48 && (@o[1] == 'o'.ord || @o[1] == 'x'.ord) {
        my int $hex = @o[1] == 'x'.ord ?? 1 !! 0;
        $i = 2;
        while $i < $n {
            return 0 if $hex ?? !is-hex(@o[$i]) !! !(48 <= @o[$i] <= 55);
            $i = $i + 1;
        }
        return $hex ?? 16 !! 8;
    }
    $i = 1 if $i < $n && (@o[0] == C-DASH || @o[0] == C-PLUS);
    return 0 if $i == $n;
    while $i < $n {
        return 0 unless is-dig(@o[$i]);
        $i = $i + 1;
    }
    1
}

# 1 a number, 2 infinity, 3 NaN; 0 if not a float
sub float-form(Str $t --> int) {
    my int @o = $t.ords;
    my int $n = @o.elems;
    my int $i = 0;
    my int $d = 0;
    $i = 1 if $i < $n && (@o[0] == C-DASH || @o[0] == C-PLUS);
    return 2 if $n - $i == 4 && @o[$i] == C-DOT && %INF{$t.substr($i + 1)};
    return 3 if $n == 4 && %NAN{$t};
    while $i < $n && is-dig(@o[$i]) { $i = $i + 1; $d = $d + 1 }
    if $i < $n && @o[$i] == C-DOT {
        $i = $i + 1;
        while $i < $n && is-dig(@o[$i]) { $i = $i + 1; $d = $d + 1 }
    }
    return 0 unless $d;
    if $i < $n && (@o[$i] == 'e'.ord || @o[$i] == 'E'.ord) {
        my int $e = 0;
        $i = $i + 1;
        $i = $i + 1 if $i < $n && (@o[$i] == C-DASH || @o[$i] == C-PLUS);
        while $i < $n && is-dig(@o[$i]) { $i = $i + 1; $e = $e + 1 }
        return 0 unless $e;
    }
    $i == $n ?? 1 !! 0
}

sub make-int(Str $t, int $form) {
    return $t.Int if $form == 1;
    yaml-native-int($t)
}

sub make-float(Str $t, int $form) {
    return ($t.starts-with('-') ?? -Inf !! Inf) if $form == 2;
    return NaN if $form == 3;
    # the forms YAML allows and a Raku numeric literal does not: ".5", "1."
    my $s = $t.starts-with('+') ?? $t.substr(1) !! $t;
    $s = $s.subst(/^ ('-'?) '.'/, { "{$0}0." });
    $s = $s.subst(/'.' (<-[0..9]> | $)/, { ".0$0" });
    $s.Num
}

sub build-scalar(YNode $n) {
    my Str $t = $n.s;
    with $n.tag -> $tag {
        return $t if $tag eq YAML-CORE ~ 'str' || $tag eq '!';
        if $tag eq YAML-CORE ~ 'null' {
            die "YAML::Native: '$t' is not a valid !!null at line {$n.line}" unless %NULL{$t}:exists;
            return Any;
        }
        if $tag eq YAML-CORE ~ 'bool' {
            my $b = %BOOL{$t};
            die "YAML::Native: '$t' is not a valid !!bool at line {$n.line}" without $b;
            return $b;
        }
        if $tag eq YAML-CORE ~ 'int' {
            my int $form = int-form($t);
            die "YAML::Native: '$t' is not a valid !!int at line {$n.line}" unless $form;
            return make-int($t, $form);
        }
        if $tag eq YAML-CORE ~ 'float' {
            my int $form = float-form($t);
            die "YAML::Native: '$t' is not a valid !!float at line {$n.line}" unless $form;
            return make-float($t, $form);
        }
        if $tag eq YAML-CORE ~ 'map' || $tag eq YAML-CORE ~ 'seq' {
            die "YAML::Native: the tag '$tag' cannot be applied to a scalar at line {$n.line}";
        }
    }
    return $t if $n.style != S-PLAIN;
    return Any if %NULL{$t}:exists;
    with %BOOL{$t} { return $_ }
    my int $form = int-form($t);
    return make-int($t, $form) if $form;
    $form = float-form($t);
    return make-float($t, $form) if $form;
    $t
}

my %NOT-MAP = (YAML-CORE X~ <seq str int float bool null>).map(* => True);
my %NOT-SEQ = (YAML-CORE X~ <map str int float bool null>).map(* => True);

sub deref(YNode $n) { $n.kind == N-ALIAS ?? $n.target !! $n }

sub is-merge-key(YNode $k --> Bool) {
    $k.kind == N-SCALAR && $k.s eq '<<'
        && (($k.style == S-PLAIN && !$k.tag.defined) || ($k.tag // '') eq YAML-CORE ~ 'merge')
}

sub construct(YNode $root) {
    my int $expanded = 0;
    my &build;
    my sub merge-from(%h, %seen, %src) {
        for %src.kv -> $k, $v {
            next if %seen{$k}:exists;
            %seen{$k} = True;
            %h{$k} = $v;
        }
    }
    my sub build-map(YNode $n) {
        die "YAML::Native: the tag '{$n.tag}' cannot be applied to a mapping at line {$n.line}"
            if $n.tag.defined && %NOT-MAP{$n.tag};
        my %h;
        my %seen;
        my @kids := $n.kids;
        my int $merges = 0;
        my int $i = 0;
        while $i < @kids.elems {
            my $k = @kids[$i];
            my $v = @kids[$i + 1];
            $i = $i + 2;
            if is-merge-key($k) { $merges = 1; next }
            my $kk = deref($k);
            die "YAML::Native: a mapping or a sequence cannot be a mapping key at line {$k.line}"
                if $kk.kind != N-SCALAR;
            die "YAML::Native: duplicate key '{$kk.s}' at line {$k.line}" if %seen{$kk.s}:exists;
            # the key into a variable before the value is built: Raku++
            # (2026-09-24) stored `%h{$kk.s} = build($v)` under the key of
            # whichever call of build-map was OUTERMOST when build recursed
            my Str $key = $kk.s;
            %seen{$key} = True;
            %h{$key} = build($v);
        }
        if $merges {
            $i = 0;
            while $i < @kids.elems {
                my $k = @kids[$i];
                my $v = @kids[$i + 1];
                $i = $i + 2;
                next unless is-merge-key($k);
                my $vv = deref($v);
                if $vv.kind == N-MAP { merge-from(%h, %seen, build($v)) }
                elsif $vv.kind == N-SEQ {
                    for $vv.kids -> $e {
                        die "YAML::Native: a merge key ('<<') takes a mapping or a sequence of mappings at line {$e.line}"
                            if deref($e).kind != N-MAP;
                        merge-from(%h, %seen, build($e));
                    }
                }
                else {
                    die "YAML::Native: a merge key ('<<') takes a mapping or a sequence of mappings at line {$v.line}";
                }
            }
        }
        %h
    }
    &build = sub (YNode $n) {
        if $n.kind == N-ALIAS {
            my $t = $n.target;
            die "YAML::Native: recursive alias '{$n.s}' at line {$n.line}" if $t.building;
            $expanded = $expanded + $t.size;
            die "YAML::Native: aliases expand the document beyond 1000000 nodes at line {$n.line}"
                if $expanded > MAX-ALIAS;
            return $t.built if $t.built.defined;
            return build($t);
        }
        my $v;
        if $n.kind == N-SCALAR { $v = build-scalar($n) }
        else {
            $n.building = 1;
            if $n.kind == N-SEQ {
                die "YAML::Native: the tag '{$n.tag}' cannot be applied to a sequence at line {$n.line}"
                    if $n.tag.defined && %NOT-SEQ{$n.tag};
                my @a;
                @a.push(build($_)) for $n.kids;
                $v = @a;
            }
            else { $v = build-map($n) }
            $n.building = 0;
        }
        $n.built = $v if $n.anchor.defined;
        $v
    };
    build($root)
}

# The Raku parser, reachable by its full name so a test can run the same
# input through both implementations.
our sub parse-raku(Str:D $text, Bool :$all) {
    my @docs = parse-stream($text);
    return [@docs.map({ construct(.root) })] if $all;
    return Any unless @docs;
    die "YAML::Native: the stream holds {+@docs} documents; read them with :all at line {@docs[1].root.line}"
        if @docs > 1;
    construct(@docs[0].root)
}

# ---- writing ------------------------------------------------------------------
#
# Raku only, on both engines: writing a document is the rare direction, and
# the time goes on deciding what each value is — the reason TOML::Native's
# design log gives for having no C writer applies here unchanged. The output
# is deterministic: keys sorted, one layout. Block style throughout; a flow
# collection only for an empty one, `{}` or `[]`.
#
#   Hash, Map                a block mapping, keys sorted
#   Array, List, Seq         a block sequence
#   Str                      plain when it would read back as the same
#                            string, a literal block (`|`) when it has line
#                            breaks and nothing that needs escaping, and
#                            double-quoted otherwise
#   Int, Bool, undefined     the core schema's forms: 42, true, null
#   Num, Rat                 a float that reads back as a float: 1.0, .inf
#   Date, DateTime           their Str, as a string
#
# Anything else is an error, as is nesting deeper than the reader accepts.

our sub to-yaml($data --> Str) is export(:MANDATORY) {
    my @out;
    my %*YAML-KEYS;
    my int $kind = kind-of($data);
    if    $kind == 1 && $data.elems      { write-map($data, @out, 0, '', 1) }
    elsif $kind == 2 && $data.list.elems { write-seq($data, @out, 0, '', 1) }
    elsif $kind == 1 { @out.push('{}') }
    elsif $kind == 2 { @out.push('[]') }
    else {
        my @lines;
        @out.push(scalar-text($data, @lines, -1));
        @out.append(@lines);
    }
    @out.join("\n") ~ "\n"
}

sub write-fail(Str $what) { die "YAML::Native: $what" }

# 0 a scalar, 1 a mapping, 2 a sequence; the likeliest first
sub kind-of($v --> int) {
    return 0 if !$v.defined || $v ~~ Str | Blob;    # a Blob is refused as a scalar
    # a Hash or a Map, asked that way: Raku++ (2026-09-24) says an IO::Handle,
    # a Proc, a Promise, a Lock ~~ Associative and even ~~ Map, where Rakudo
    # says none of them is
    return 1 if $v ~~ Hash || $v.isa(Map);
    return 2 if $v ~~ Positional || $v ~~ Seq;
    0
}

sub float-text(Num $f --> Str) {
    return '.nan' if $f.isNaN;
    return ($f > 0 ?? '.inf' !! '-.inf') if $f == Inf || $f == -Inf;
    my $s;
    # Raku++ gives a subnormal fifteen digits, not the shortest form that
    # reads back, and Rakudo's sprintf cannot format one at all: search with
    # sprintf where it works, and take .Str where it does not
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
    $s ~= '.0' if $s ~~ /^ '-'? <[0..9]>+ $/;
    $s
}

# The common case, decided by one regex: a word that starts with a letter
# and holds nothing but letters, digits and "_./-". It cannot be a number
# (those start with a digit, a sign or a dot), so only null and the booleans
# are left to rule out.
sub simple-plain(Str $s --> Bool) {
    so $s ~~ /^ <[a..zA..Z_]> <[a..zA..Z0..9_./-]>* $/ and !(%NULL{$s}:exists) and !(%BOOL{$s}:exists)
}

# Characters no plain or block scalar written here may hold: the C0 and C1
# controls but tab and line feed, the line and paragraph separators, a BOM
# and the two non-characters. (A character class and not `contains`: see
# notes/TOML-Native.md on Rakudo's eight-bit strings. And CRLF asked about
# separately, since in Raku it is one character that no class matches.)
my regex unwritable { <[\x00..\x08\x0B..\x1F\x7F..\x9F\x2028\x2029\xFEFF\xFFFE\xFFFF]> }

# Would this text, written plain, read back as this same string?
sub plain-ok(Str $s --> Bool) {
    return False if $s eq '';
    my int $first = $s.ord;
    return False if $first == C-SP || $first == C-TAB || is-indicator($first);
    return False if $s.ends-with(' ') || $s.ends-with("\t") || $s.ends-with(':');
    return False if $s eq '<<' || $s.starts-with('...');
    return False if (%NULL{$s}:exists) || (%BOOL{$s}:exists) || int-form($s) || float-form($s);
    return False if $s.contains(': ') || $s.contains(":\t") || $s.contains(' #') || $s.contains("\t#");
    return False if $s.contains("\n") || $s.contains("\r") || $s.contains("\r\n") || $s.contains("\t");
    !($s ~~ /<unwritable>/)
}

# Can it go in a literal block scalar? Line breaks, and nothing that would
# have to be escaped — and something besides line breaks.
sub literal-ok(Str $s --> Bool) {
    $s.contains("\n") && !$s.contains("\r") && !$s.contains("\r\n")
        && !($s ~~ /<unwritable>/) && so $s ~~ /<-[\n]>/
}

my %QESC;
for "\x[0]", '\\0', "\x[7]", '\\a', "\b", '\\b', "\t", '\\t', "\n", '\\n', "\x[B]", '\\v',
    "\f", '\\f', "\r", '\\r', "\x[1B]", '\\e', '"', '\\"', '\\', '\\\\',
    "\x[85]", '\\N', "\x[2028]", '\\L', "\x[2029]", '\\P' -> $c, $e {
    %QESC{$c.ord} = $e;
}

sub quoted(Str $s --> Str) {
    '"' ~ $s.ords.map(-> $c {
        %QESC{$c} // (($c < 0x20 || $c == 0x7F || (0x80 <= $c < 0xA0))
                        ?? sprintf('\\x%02X', $c)
                        !! (!printable($c) || $c == 0xFEFF) ?? sprintf('\\u%04X', $c) !! $c.chr)
    }).join ~ '"'
}

# A scalar as it goes after "key: " or "- ", or as a line of its own; a
# literal block comes back as its header, with its lines in @lines.
sub scalar-text($v, @lines, int $indent --> Str) {
    return 'null' without $v;
    if $v ~~ Str {
        return $v if simple-plain($v);
        return str-text($v, @lines, $indent);
    }
    return $v ?? 'true' !! 'false' if $v ~~ Bool;
    return $v.Str if $v ~~ Int;
    return float-text($v.Num) if $v ~~ Num | Rat | FatRat;
    return str-text($v.Str, @lines, $indent) if $v ~~ Dateish;
    write-fail("cannot write a value of type {$v.^name}");
}

sub str-text(Str $s, @lines, int $indent --> Str) {
    return $s if plain-ok($s);
    if literal-ok($s) {
        my @l = $s.split("\n");
        my int $trailing = 0;
        while @l > 1 && @l[@l.end] eq '' { @l.pop; $trailing = $trailing + 1 }
        my $chomp = $trailing == 0 ?? '-' !! $trailing == 1 ?? '' !! '+';
        # the indentation is read from the first line with anything on it,
        # so a leading space there has to be declared
        my $ind = (@l.first(*.chars) // '').starts-with(' ') ?? '2' !! '';
        my $pad = ' ' x ($indent + 2);
        @lines.push(.chars ?? $pad ~ $_ !! '') for @l;
        @lines.push('') for 1 ..^ $trailing;
        return "|$ind$chomp";
    }
    quoted($s)
}

# keys repeat from one mapping to the next, so each call of to-yaml keeps
# the text it wrote for each
sub key-text(Str() $k --> Str) {
    %*YAML-KEYS{$k} //= simple-plain($k) || plain-ok($k) ?? $k !! quoted($k)
}

# A mapping's entries at column $col. $first, when not empty, starts the
# first line instead of spaces: the "- " of a sequence item holding it.
sub write-map($m, @out, int $col, Str $first, int $depth) {
    write-fail('nesting is limited to 128 levels') if $depth > MAX-DEPTH;
    my $pad = ' ' x $col;
    my $lead = $first eq '' ?? $pad !! $first;
    for $m.keys.sort -> $k {
        my $kt = key-text($k);
        # an implicit key is at most 1024 characters; past that it is explicit
        my $kv = $kt.chars > 1000 ?? "$lead? $kt\n$pad:" !! "$lead$kt:";
        write-value($m{$k}, @out, $col, $kv, $depth);
        $lead = $pad;
    }
}

sub write-seq($s, @out, int $col, Str $first, int $depth) {
    write-fail('nesting is limited to 128 levels') if $depth > MAX-DEPTH;
    my $pad = ' ' x $col;
    my $lead = $first eq '' ?? $pad !! $first;
    for $s.list -> $item {
        write-item($item, @out, $lead ~ '- ', $depth);
        $lead = $pad;
    }
}

# the value of a mapping key, $kv being "key:" at column $col
sub write-value($v, @out, int $col, Str $kv, int $depth) {
    my int $kind = kind-of($v);
    if $kind == 0 {
        my @lines;
        @out.push("$kv " ~ scalar-text($v, @lines, $col));
        @out.append(@lines) if @lines;
    }
    elsif $kind == 1 {
        if $v.elems { @out.push($kv); write-map($v, @out, $col + 2, '', $depth + 1) }
        else { @out.push("$kv \{\}") }
    }
    elsif $v.list.elems { @out.push($kv); write-seq($v, @out, $col + 2, '', $depth + 1) }
    else { @out.push("$kv []") }
}

# an item of a sequence, $prefix its "- " (or "- - " when compact)
sub write-item($v, @out, Str $prefix, int $depth) {
    my int $col = $prefix.chars;
    my int $kind = kind-of($v);
    if $kind == 0 {
        my @lines;
        @out.push($prefix ~ scalar-text($v, @lines, $col - 2));
        @out.append(@lines) if @lines;
    }
    elsif $kind == 1 {
        if $v.elems { write-map($v, @out, $col, $prefix, $depth + 1) }
        else { @out.push("$prefix\{\}") }
    }
    elsif $v.list.elems { write-seq($v, @out, $col, $prefix, $depth + 1) }
    else { @out.push("{$prefix}[]") }
}
