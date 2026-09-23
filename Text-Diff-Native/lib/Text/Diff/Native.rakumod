=begin pod

=head1 Text::Diff::Native

Line diffs and unified diffs, with a native fast path on Raku++ and a
pure-Raku implementation everywhere else. No dependencies.

The XS pattern, as in CSV::Native: the distribution ships C source, the build
step compiles it against Raku++'s extension ABI, and the module uses it when
it is there. The C half is only the part whose cost is not linear — finding
the shortest edit script — and it has a Raku twin that computes the same
script, change for change, which the test suite checks.

=head2 Synopsis

    use Text::Diff::Native;

    print unified-diff("a\nb\nc\n", "a\nc\nd\n");
    print unified-diff('old.txt'.IO, 'new.txt'.IO);

    for diff(<a b c d>, <a c d e>) {
        say .key, .value;           # " a", "-b", " c", " d", "+e"
    }

    say diff-backend;               # 'native' or 'raku'

=head2 The algorithm

Myers' O(ND) difference algorithm in its linear-space form (E. W. Myers,
"An O(ND) Difference Algorithm and Its Variations", Algorithmica 1, 1986),
after trimming the common head and tail of every subproblem. The script is
minimal: no shorter sequence of deletions and insertions turns the old text
into the new. Where several minimal scripts exist, a pure deletion or pure
insertion is slid down as far as equal lines allow, the conventional choice.

=end pod

unit module Text::Diff::Native;

# `&::(…)` is a RUNTIME lookup, so this line compiles on Rakudo too — where it
# simply yields Nil and the module runs its own Raku implementation.
my &ext-load = try &::('rakupp-ext-load');
my &native-changes;
my &native-unified;

# Where the compiled half might be. %?RESOURCES is the installed answer; the
# CWD form covers a git checkout tested with -Ilib. NOT $?FILE-relative: under
# Raku++ a module's $?FILE is the main program's.
sub libraries() {
    my $ext = $*DISTRO.is-win ?? 'dll' !! ($*KERNEL.name eq 'darwin' ?? 'dylib' !! 'so');
    my $stem = $*DISTRO.is-win ?? "textdiff.$ext" !! "libtextdiff.$ext";
    my @c;
    with (try %?RESOURCES<libraries/textdiff>) { @c.push($_) if .defined }
    @c.push($*CWD.add("resources/libraries/$stem"));
    @c
}

sub load-native(--> Bool) {
    return False unless &ext-load;
    # TEXT_DIFF_NATIVE_BACKEND=raku forces the Raku implementation on a Raku++
    # that has the extension, to measure the two against each other.
    return False if (%*ENV<TEXT_DIFF_NATIVE_BACKEND> // '') eq 'raku';
    for libraries() -> $lib {
        next unless $lib.IO.e;
        next unless try ext-load($lib.Str);
        &native-changes = try &::('diff-changes-native');
        &native-unified = try &::('unified-diff-native');
        return True if &native-changes && &native-unified;
    }
    False
}

my Bool $is-native = load-native();

# Which implementation is answering: 'native' (the compiled extension) or
# 'raku' (this file).
our sub diff-backend() is export(:MANDATORY) {
    $is-native ?? 'native' !! 'raku'
}

# ---- the public interface ----------------------------------------------------

# The edit script between two lists, one Pair per element: ' ' => an element
# both share, '-' => one only the old list has, '+' => one only the new list
# has. Elements are compared as strings. Within a change, deletions come
# before insertions.
our sub diff(@old, @new) is export(:MANDATORY) {
    my ($ids-a, $ids-b) = ids(@old.map(*.Str), @new.map(*.Str));
    my ($ca, $cb) = flags(changes($ids-a, $ids-b), @old.elems, @new.elems);
    my @ops;
    my int $n = @old.elems;
    my int $m = @new.elems;
    my int $i = 0;
    my int $j = 0;
    while $i < $n || $j < $m {
        if $i < $n && $j < $m && !$ca[$i] && !$cb[$j] {
            @ops.push(' ' => @old[$i]);
            $i = $i + 1;
            $j = $j + 1;
        }
        else {
            while $i < $n && $ca[$i] { @ops.push('-' => @old[$i]); $i = $i + 1 }
            while $j < $m && $cb[$j] { @ops.push('+' => @new[$j]); $j = $j + 1 }
        }
    }
    @ops
}

# A unified diff, as `diff -u` writes it: '' when the texts are the same.
# Each side is a Str or an IO::Path; a path is read as UTF-8 with its line
# endings untouched, and names its side unless :from or :to does.
our sub unified-diff($old, $new, Int:D :$context = 3, Str :$from, Str :$to)
        is export(:MANDATORY) {
    die "Text::Diff::Native: context must not be negative" if $context < 0;
    my $from-name = $from // ($old ~~ IO::Path ?? $old.Str !! 'a');
    my $to-name   = $to   // ($new ~~ IO::Path ?? $new.Str !! 'b');
    my $ta = text-of($old);
    my $tb = text-of($new);
    $is-native
        ?? native-unified($ta, $tb, $context, $from-name, $to-name)
        !! unified-raku($ta, $tb, $context, $from-name, $to-name)
}

# The Raku implementation of the whole of unified-diff past its options: the
# lines, their ids, the script, the hunks and the text. The extension does
# all of it in C — here only the script is not linear, but in Raku the linear
# parts are most of the time — and the two must produce the same bytes.
our sub unified-raku(Str:D $ta, Str:D $tb, Int:D $context, Str:D $from, Str:D $to) {
    my @a = split-lines($ta);
    my @b = split-lines($tb);
    my ($ids-a, $ids-b) = ids(@a, @b);
    my ($ca, $cb) = flags(changes-raku($ids-a, $ids-b), @a.elems, @b.elems);
    my @hunks = hunks($ca, $cb, @a.elems, @b.elems, $context);
    return '' unless @hunks;

    my @out = "--- $from\n", "+++ $to\n";
    for @hunks -> [$as, $ae, $bs, $be] {
        @out.push("@@ -{range($as, $ae)} +{range($bs, $be)} @@\n");
        my int $i = $as;
        my int $j = $bs;
        while $i < $ae || $j < $be {
            if $i < $ae && $j < $be && !$ca[$i] && !$cb[$j] {
                @out.push(line(' ', @a[$i]));
                $i = $i + 1;
                $j = $j + 1;
            }
            else {
                while $i < $ae && $ca[$i] { @out.push(line('-', @a[$i])); $i = $i + 1 }
                while $j < $be && $cb[$j] { @out.push(line('+', @b[$j])); $j = $j + 1 }
            }
        }
    }
    @out.join
}

# ---- lines, ids and hunks ----------------------------------------------------

sub text-of($src) {
    given $src {
        # :bin and decode, not .slurp: a text slurp turns CRLF into LF, and a
        # diff must see the bytes that are there
        when IO::Path   { .slurp(:bin).decode }
        when IO::Handle { .slurp(:bin).decode }
        default         { .Str }
    }
}

# The lines of a text, each with its terminator ("\n" or "\r\n"); the last
# one has none when the text does not end with one, and so is a different
# line from the same text with an ending — as it is to `diff`. A lone "\r" is
# content.
#
# Text with no CR in it — nearly all text — is `lines(:!chomp)`, which is
# fast on both engines but also ends a line at a lone CR, so anything with a
# CR takes the long way: CRLF split out first (it is one grapheme, and
# Rakudo will not find the "\n" inside it where Raku++ will), then LF.
our sub split-lines(Str:D $s) {
    return $s.lines(:!chomp).Array
        unless $s.contains("\r") || $s.contains("\r\n");
    my @out;
    my @crlf = $s.split("\r\n");
    my int $cend = @crlf.end;
    for @crlf.kv -> $ci, $chunk {
        my @l = $chunk.split("\n");
        my int $lend = @l.end;
        for @l.kv -> $li, $l {
            if $li < $lend       { @out.push($l ~ "\n") }
            elsif $ci < $cend    { @out.push($l ~ "\r\n") }
            elsif $l ne ''       { @out.push($l) }
        }
    }
    @out
}

# Every distinct string gets a small integer, in order of first appearance,
# so the algorithm compares numbers and never strings.
sub ids(@a, @b) {
    my %id;
    my int $next = 0;
    my int @ia;
    my int @ib;
    for @a -> $s { @ia.push(%id{$s} //= $next++) }
    for @b -> $s { @ib.push(%id{$s} //= $next++) }
    (@ia, @ib)
}

# The edit script between two lists of ids, from whichever implementation is
# answering. Reachable by its full name, beside changes-raku, so a test can
# hold the two against each other.
our sub changes(@ia, @ib) {
    $is-native ?? native-changes(@ia, @ib) !! changes-raku(@ia, @ib)
}

# The flat answer of either implementation — the number of changed old
# elements, their indices, then the new side's — as two arrays of flags.
sub flags(@flat, Int:D $n, Int:D $m) {
    my int @ca = 0 xx $n;
    my int @cb = 0 xx $m;
    my int $k = @flat[0];
    my int $total = @flat.elems;
    loop (my int $x = 1; $x <= $k; $x = $x + 1) { @ca[@flat[$x]] = 1 }
    loop (my int $y = $k + 1; $y < $total; $y = $y + 1) { @cb[@flat[$y]] = 1 }
    (@ca, @cb)
}

# The hunks of a unified diff with $c lines of context: [old-start, old-end,
# new-start, new-end], half-open and 0-based. Two changes share a hunk when
# no more than 2 × $c unchanged lines lie between them, as in `diff -u`.
sub hunks($ca, $cb, Int:D $n, Int:D $m, Int:D $c) {
    # the change blocks first: maximal runs of changes on either side,
    # between two unchanged pairs
    my @blocks;
    my int $i = 0;
    my int $j = 0;
    while $i < $n || $j < $m {
        if $i < $n && $j < $m && !$ca[$i] && !$cb[$j] {
            $i = $i + 1;
            $j = $j + 1;
            next;
        }
        my int $ai = $i;
        my int $bj = $j;
        while $i < $n && $ca[$i] { $i = $i + 1 }
        while $j < $m && $cb[$j] { $j = $j + 1 }
        @blocks.push([$ai, $i, $bj, $j]);
    }
    my @hunks;
    my $cur;
    for @blocks -> [$as, $ae, $bs, $be] {
        if $cur && $as - $cur[1] <= 2 * $c {
            $cur[1] = $ae;
            $cur[3] = $be;
        }
        else {
            @hunks.push($cur) if $cur;
            $cur = [$as, $ae, $bs, $be];
        }
    }
    @hunks.push($cur) if $cur;
    # widen by the context, which is the same number of lines on both sides:
    # outside a change, old and new advance together
    for @hunks -> $h {
        my $before = min($c, $h[0]);
        my $after  = min($c, $n - $h[1]);
        $h[0] -= $before;  $h[2] -= $before;
        $h[1] += $after;   $h[3] += $after;
    }
    @hunks
}

# A hunk header's range: "l" for one line, "l,n" for several, and for none
# the line BEFORE the empty range ("4,0"; "0,0" at the very top).
sub range(Int:D $s, Int:D $e) {
    my $len = $e - $s;
    $len == 1 ?? ($s + 1).Str
              !! $len == 0 ?? "$s,0" !! "{$s + 1},$len"
}

# One line of a hunk. Both endings are asked for by name: on Rakudo "\r\n" is
# one grapheme, and a Str ending in it does not end with "\n".
sub line(Str:D $mark, Str:D $l) {
    $l.ends-with("\n") || $l.ends-with("\r\n")
        ?? "$mark$l"
        !! "$mark$l\n\\ No newline at end of file\n"
}

# ---- the Raku implementation ------------------------------------------------

# The shortest edit script between two lists of ids, as the flat list the
# extension also returns. The reference the extension is held to, and what
# runs on Rakudo; reachable by its full name so a test can run the same input
# through both.
#
# Four steps, each mirrored line for line in src/textdiff.c:
#   0. discard: an element the other side does not have at all is a change in
#      every shortest script, so it is marked here and the search below runs
#      on what is left — the same length of script, found with far less
#      searching, since most edited lines are new lines.
#   1. compare: trim the common head and tail; a range with one side empty is
#      all deletions or all insertions; otherwise bisect it and recurse.
#   2. bisect: Myers' middle snake. A forward and a reverse search advance one
#      edit at a time until their furthest-reaching paths meet on a diagonal;
#      that point lies on a shortest path, and splits the problem in two
#      smaller ones. Diagonals that run off the grid are retired, so no index
#      ever leaves it. If the searches never meet, the two sides share nothing
#      and every element is a change.
#   3. slide: a pure deletion (or insertion) whose first line equals the line
#      after it can move down one line without changing its length; each one
#      moves as far down as that allows.
our sub changes-raku(@a, @b) {
    my int $n = @a.elems;
    my int $m = @b.elems;
    my int @ca = 0 xx $n;
    my int @cb = 0 xx $m;

    # discard: @x and @y are the elements the other side also has, @xi and
    # @yi where each came from
    my int $k = 0;
    my int $i;
    my int $j;
    loop ($i = 0; $i < $n; $i = $i + 1) { $k = @a[$i] + 1 if @a[$i] >= $k }
    loop ($j = 0; $j < $m; $j = $j + 1) { $k = @b[$j] + 1 if @b[$j] >= $k }
    my int @ina = 0 xx $k;
    my int @inb = 0 xx $k;
    loop ($i = 0; $i < $n; $i = $i + 1) { @ina[@a[$i]] = 1 }
    loop ($j = 0; $j < $m; $j = $j + 1) { @inb[@b[$j]] = 1 }
    my int @x;
    my int @xi;
    my int @y;
    my int @yi;
    loop ($i = 0; $i < $n; $i = $i + 1) {
        if @inb[@a[$i]] { @x.push(@a[$i]); @xi.push($i) } else { @ca[$i] = 1 }
    }
    loop ($j = 0; $j < $m; $j = $j + 1) {
        if @ina[@b[$j]] { @y.push(@b[$j]); @yi.push($j) } else { @cb[$j] = 1 }
    }
    my int $xn = @x.elems;
    my int $yn = @y.elems;
    my int @cx = 0 xx $xn;
    my int @cy = 0 xx $yn;
    my int @vf;
    my int @vb;

    my sub bisect(int $a0, int $a1, int $b0, int $b1) {
        my int $n = $a1 - $a0;
        my int $m = $b1 - $b0;
        my int $max = ($n + $m + 1) div 2;
        my int $off = $max + 1;
        # -1 is "not reached in this call". Only diagonals -(d+1) .. d+1 can
        # be read at step d, so each step clears the two it newly brings in
        # range, and the overlap checks below ignore anything beyond them —
        # clearing the whole vector per call would cost the subproblem's size
        # on every call, even one that finds its middle snake at once.
        @vf[$off - 1] = -1; @vf[$off] = -1; @vf[$off + 1] = 0;
        @vb[$off - 1] = -1; @vb[$off] = -1; @vb[$off + 1] = 0;
        my int $delta = $n - $m;
        my int $front = $delta % 2 == 0 ?? 0 !! 1;   # odd: the forward search checks for overlap
        my int $kfs = 0; my int $kfe = 0;   # forward diagonals retired at each end
        my int $kbs = 0; my int $kbe = 0;   # reverse diagonals retired at each end
        loop (my int $d = 0; $d < $max; $d = $d + 1) {
            if $d {
                @vf[$off - $d - 1] = -1; @vf[$off + $d + 1] = -1;
                @vb[$off - $d - 1] = -1; @vb[$off + $d + 1] = -1;
            }
            loop (my int $k = $kfs - $d; $k <= $d - $kfe; $k = $k + 2) {
                my int $ko = $off + $k;
                my int $x;
                if $k == -$d || ($k != $d && @vf[$ko - 1] < @vf[$ko + 1]) { $x = @vf[$ko + 1] }
                else { $x = @vf[$ko - 1] + 1 }
                my int $y = $x - $k;
                while $x < $n && $y < $m && @x[$a0 + $x] == @y[$b0 + $y] {
                    $x = $x + 1;
                    $y = $y + 1;
                }
                @vf[$ko] = $x;
                if $x > $n { $kfe = $kfe + 2 }
                elsif $y > $m { $kfs = $kfs + 2 }
                elsif $front {
                    my int $kr = $off + $delta - $k;
                    if $kr >= $off - $d - 1 && $kr <= $off + $d + 1
                            && @vb[$kr] != -1 && $x >= $n - @vb[$kr] {
                        return ($a0 + $x, $b0 + $y);
                    }
                }
            }
            loop (my int $r = $kbs - $d; $r <= $d - $kbe; $r = $r + 2) {
                my int $ko = $off + $r;
                my int $x;
                if $r == -$d || ($r != $d && @vb[$ko - 1] < @vb[$ko + 1]) { $x = @vb[$ko + 1] }
                else { $x = @vb[$ko - 1] + 1 }
                my int $y = $x - $r;
                while $x < $n && $y < $m && @x[$a1 - 1 - $x] == @y[$b1 - 1 - $y] {
                    $x = $x + 1;
                    $y = $y + 1;
                }
                @vb[$ko] = $x;
                if $x > $n { $kbe = $kbe + 2 }
                elsif $y > $m { $kbs = $kbs + 2 }
                elsif !$front {
                    my int $kf = $off + $delta - $r;
                    if $kf >= $off - $d - 1 && $kf <= $off + $d + 1 && @vf[$kf] != -1 {
                        my int $xf = @vf[$kf];
                        if $xf >= $n - $x {
                            return ($a0 + $xf, $b0 + $xf - ($kf - $off));
                        }
                    }
                }
            }
        }
        Nil
    }

    my sub compare(int $a0 is copy, int $a1 is copy, int $b0 is copy, int $b1 is copy) {
        while $a0 < $a1 && $b0 < $b1 && @x[$a0] == @y[$b0] {
            $a0 = $a0 + 1;
            $b0 = $b0 + 1;
        }
        while $a0 < $a1 && $b0 < $b1 && @x[$a1 - 1] == @y[$b1 - 1] {
            $a1 = $a1 - 1;
            $b1 = $b1 - 1;
        }
        if $a0 == $a1 {
            loop (my int $y = $b0; $y < $b1; $y = $y + 1) { @cy[$y] = 1 }
            return;
        }
        if $b0 == $b1 {
            loop (my int $x = $a0; $x < $a1; $x = $x + 1) { @cx[$x] = 1 }
            return;
        }
        my $split = bisect($a0, $a1, $b0, $b1);
        if $split.defined {
            my int $x = $split[0];
            my int $y = $split[1];
            compare($a0, $x, $b0, $y);
            compare($x, $a1, $y, $b1);
        }
        else {
            loop (my int $x = $a0; $x < $a1; $x = $x + 1) { @cx[$x] = 1 }
            loop (my int $y = $b0; $y < $b1; $y = $y + 1) { @cy[$y] = 1 }
        }
    }

    compare(0, $xn, 0, $yn);
    loop ($i = 0; $i < $xn; $i = $i + 1) { @ca[@xi[$i]] = 1 if @cx[$i] }
    loop ($j = 0; $j < $yn; $j = $j + 1) { @cb[@yi[$j]] = 1 if @cy[$j] }

    # slide: walk both sides together; unchanged elements pair up in order
    $i = 0;
    $j = 0;
    while $i < $n || $j < $m {
        if $i < $n && $j < $m && !@ca[$i] && !@cb[$j] {
            $i = $i + 1;
            $j = $j + 1;
            next;
        }
        my int $s = $i;
        my int $t = $j;
        while $i < $n && @ca[$i] { $i = $i + 1 }
        while $j < $m && @cb[$j] { $j = $j + 1 }
        if $t == $j {
            # deletions @a[$s ..^ $i]; @a[$i] pairs with @b[$j]
            while $i < $n && $j < $m && !@ca[$i] && !@cb[$j] && @a[$s] == @a[$i] {
                @ca[$s] = 0;
                @ca[$i] = 1;
                $s = $s + 1;
                $i = $i + 1;
                $j = $j + 1;
            }
        }
        elsif $s == $i {
            # insertions @b[$t ..^ $j]; @b[$j] pairs with @a[$i]
            while $i < $n && $j < $m && !@ca[$i] && !@cb[$j] && @b[$t] == @b[$j] {
                @cb[$t] = 0;
                @cb[$j] = 1;
                $t = $t + 1;
                $i = $i + 1;
                $j = $j + 1;
            }
        }
    }

    my @flat = 0;
    loop (my int $x = 0; $x < $n; $x = $x + 1) { @flat.push($x) if @ca[$x] }
    @flat[0] = @flat.elems - 1;
    loop (my int $y = 0; $y < $m; $y = $y + 1) { @flat.push($y) if @cb[$y] }
    @flat
}
