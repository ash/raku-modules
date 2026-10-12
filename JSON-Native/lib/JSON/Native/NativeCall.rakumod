=begin pod

=head1 JSON::Native::NativeCall

The C half of JSON::Native on Rakudo: a JSON tokenizer compiled at install
time from C<src/json-nc.c> and reached through NativeCall. JSON::Native loads
it only on Rakudo, and only uses it where the library was built; it exports
nothing and is not meant to be called directly.

C cannot build a Raku value on Rakudo, so the work is split where it is
cheapest: one NativeCall reads the whole document into a flat tape of tagged
words and one buffer of decoded strings, and the Raku side turns those into
values in a single pass. Anything the tokenizer does not accept exactly as
JSON::Fast would — a malformed document, an odd surrogate, a document holding
a multi-codepoint grapheme — comes back as C<Decline>, and JSON::Native asks
its Raku implementation instead.

=end pod

unit module JSON::Native::NativeCall;

use NativeCall;

# Where the compiled half might be: %?RESOURCES installed, or the checkout's
# resources/ when testing with -Ilib. NOT $?FILE-relative (see JSON::Native).
sub library() {
    my $ext = $*DISTRO.is-win ?? 'dll' !! ($*KERNEL.name eq 'darwin' ?? 'dylib' !! 'so');
    my $stem = $*DISTRO.is-win ?? "json-nc.$ext" !! "libjson-nc.$ext";
    my @c;
    with (try %?RESOURCES<libraries/json-nc>) { @c.push(.IO.absolute) if .defined && .IO.s }
    @c.push($*CWD.add("resources/libraries/$stem").Str);
    @c.first(*.IO.s) // ''
}
my $LIB = library();
# a SUB, not the variable: the trait is applied when this file is compiled,
# and the path is only known when it is loaded
sub lib-path() { $LIB }

sub json_nc_abi(--> int64) is native(&lib-path) {*}
sub json_nc_parse(Blob, size_t, Blob, size_t, Blob, size_t, CArray[int64] --> int64) is native(&lib-path) {*}

# Answered in place of a value: "ask the Raku implementation".
our class Decline { }

# Whether the library is here and speaks this protocol. An install without a C
# compiler leaves an empty stub where the library would be; loading it fails,
# and that is a no, not an error.
sub probe(--> Bool) {
    return False unless $LIB;
    my $abi = try json_nc_abi();
    so $abi.defined && $abi == 1
}
my Bool $available = probe();
our sub available(--> Bool) { $available }

# The tape is a buf8 read with read-int64, which on Rakudo costs a third of
# what indexing a Buf[int64] does; one word per value, tag in the low four
# bits (see the comment at the top of src/json-nc.c).
our sub parse(Str $text, :$immutable) {
    # one grapheme per codepoint, or JSON::Fast's grapheme rules and the
    # tokenizer's codepoint ones could disagree about where a quote is
    return Decline unless $text.chars == $text.codes;
    my $bytes = $text.encode;
    my int $len = $bytes.bytes;
    my int $cap = 2 * $len + 8;
    my $tape = buf8.allocate($cap * 8);
    my $strs = buf8.allocate($cap);
    my $lens = CArray[int64].new(0);
    my int $tn = json_nc_parse($bytes, $len, $tape, $cap, $strs, $cap, $lens);
    return Decline if $tn < 0;
    # one decode for every string; it also puts them in NFC, as JSON::Fast's are
    my @s = $strs.subbuf(0, $lens[0]).decode.split("\0");

    my int $at = 0;    # byte offset into the tape
    my int $si = 1;    # past the leading separator; see json_nc_parse
    my int $imm = $immutable ?? 1 !! 0;
    my int $w;
    my int $tag;
    my int $declined = 0;   # a number token .Numeric refused (see tag 5)

    # Declarations stay outside the loops, so Rakudo flattens them rather than
    # entering a block per element; strings, small Ints and literals are made
    # in the container's own loop, and only a container costs a call.
    my sub value() {
        $w = $tape.read-int64($at);
        $at = $at + 8;
        $tag = $w +& 15;
        value-of-word()
    }
    my sub value-of-word() {
        if $tag == 8 {
            $si = $si + 1;
            @s[$si - 1]
        }
        elsif $tag == 3 { $w +> 4 }
        elsif $tag == 6 {
            my int $c = $w +> 4;
            my $k;
            if $imm {
                my @pairs;
                while $c {
                    $k = @s[$si];
                    $si = $si + 1;
                    @pairs.push: Pair.new($k, value());
                    $c = $c - 1;
                }
                Map.new(@pairs)
            }
            else {
                my %h;
                while $c {
                    $k = @s[$si];
                    $w = $tape.read-int64($at);
                    $at = $at + 8;
                    $tag = $w +& 15;
                    if $tag == 8 { %h{$k} = @s[$si + 1]; $si = $si + 2 }
                    elsif $tag == 3 { %h{$k} = $w +> 4; $si = $si + 1 }
                    else { $si = $si + 1; %h{$k} = value-of-word() }
                    $c = $c - 1;
                }
                %h
            }
        }
        elsif $tag == 7 {
            my int $c = $w +> 4;
            my @a;
            while $c {
                $w = $tape.read-int64($at);
                $at = $at + 8;
                $tag = $w +& 15;
                if $tag == 8 { @a.push: @s[$si]; $si = $si + 1 }
                elsif $tag == 3 { @a.push: $w +> 4 }
                elsif $tag == 1 { @a.push: True }
                elsif $tag == 2 { @a.push: False }
                elsif $tag == 0 { @a.push: Any }
                else { @a.push: value-of-word() }
                $c = $c - 1;
            }
            $imm ?? (@a ?? @a.List !! List.new) !! @a
        }
        elsif $tag == 4 {
            $at = $at + 8;
            Rat.new($tape.read-int64($at - 8), 10 ** ($w +> 4))
        }
        elsif $tag == 10 {
            # the double strtod made of a well-formed exponent form — the one
            # Rakudo's .Numeric makes of it too (t/01-parse.t holds them to it)
            $at = $at + 8;
            $tape.read-num64($at - 8)
        }
        elsif $tag == 1 { True }
        elsif $tag == 2 { False }
        elsif $tag == 0 { Any }
        elsif $tag == 9 {
            $at = $at + 8;
            $tape.read-int64($at - 8)
        }
        else {   # 5: a number token, typed by .Numeric as JSON::Fast types it
            my $n := @s[$si].Numeric;
            $si = $si + 1;
            if $n ~~ Failure { $n.so; $declined = 1; return Any }
            $n
        }
    }

    # a flag rather than an exception for the one refusal that can come this
    # late: a CATCH around every parse cost more than the rest of a small one
    my \result = value();
    $declined ?? Decline !! result
}
