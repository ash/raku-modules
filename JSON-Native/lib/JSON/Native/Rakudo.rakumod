=begin pod

=head1 JSON::Native::Rakudo

JSON::Native's writer on Rakudo: JSON::Native::Raku's C<to-json>, the same
rules in the same order, with its hot spots in C<nqp::> ops — the escape scan,
the output buffer, the type tests. JSON::Native reaches it by a runtime
C<require> only when the engine is Rakudo, so no other engine ever parses this
file. It exports nothing and is not meant to be called directly.

=end pod

use nqp;

unit module JSON::Native::Rakudo;

my sub to-surrogate-pair(int $ord --> str) {
    my int $base = $ord - 0x10000;
    Q/\u/ ~ (0xD800 + ($base +> 10)).base(16) ~ Q/\u/ ~ (0xDC00 + ($base +& 0x3FF)).base(16)
}

# JSON::Fast escapes the string's NFD codepoints: \t \n \r, the quote and the
# backslash by name; every other control as lower-case \u%04x; an astral
# codepoint as an upper-case surrogate pair; the rest as it is. Whether there
# is anything to escape is asked of the string's own characters when each is
# one codepoint (chars == codes), which is nearly always; otherwise, and when
# there is, every NFD codepoint is looked at, as JSON::Fast looks at them.
my sub str-escape(str $text --> str) {
    nqp::iseq_i(nqp::codes($text), nqp::chars($text)) && nqp::iseq_i(clean-up-to($text), nqp::chars($text))
      ?? $text
      !! escape-codes($text)
}

# How far the string runs without a character JSON::Fast would escape. Spelled
# in nqp:: ops throughout, as JSON::Fast spells its scanners: the same loop with
# `<` and `&&` cost Rakudo about 1.5 µs a short string.
my sub clean-up-to(str $text --> int) {
    my int $n = nqp::chars($text);
    my int $i = 0;
    my int $c;
    nqp::while(
      nqp::islt_i($i, $n)
        && nqp::isge_i(($c = nqp::ordat($text, $i)), 32)
        && nqp::isne_i($c, 34)
        && nqp::isne_i($c, 92)
        && nqp::islt_i($c, 0x10000),
      ($i = nqp::add_i($i, 1))
    );
    $i
}

my sub escape-codes(str $text --> str) {
    my $codes := nqp::strtocodes($text, nqp::const::NORMALIZE_NFD, nqp::create(NFD));
    my $out := nqp::create(Uni);
    my int $m = nqp::elems($codes);
    my int $j = -1;
    my int $code;
    while nqp::islt_i(++$j, $m) {
        $code = nqp::atpos_i($codes, $j);
        if $code <= 31 {
            if    $code == 10 { nqp::push_i($out, 92); nqp::push_i($out, 110) }
            elsif $code == 13 { nqp::push_i($out, 92); nqp::push_i($out, 114) }
            elsif $code ==  9 { nqp::push_i($out, 92); nqp::push_i($out, 116) }
            else  { for $code.fmt(Q/\u%04x/).ords -> int $o { nqp::push_i($out, $o) } }
        }
        elsif $code == 34 { nqp::push_i($out, 92); nqp::push_i($out, 34) }
        elsif $code == 92 { nqp::push_i($out, 92); nqp::push_i($out, 92) }
        elsif $code >= 0x10000 { for to-surrogate-pair($code).ords -> int $o { nqp::push_i($out, $o) } }
        else { nqp::push_i($out, $code) }
    }
    # rebuilt from codepoints, so composed again — as JSON::Fast's output is
    nqp::strfromcodes($out)
}

our sub to-json(
  \obj,
  Bool :$pretty         = True,
  Int  :$level          = 0,
  Int  :$spacing        = 2,
       :$sorted-keys    = False,
  Bool :$enums-as-value = False,
) {
    my $out := nqp::list_s;
    my str $spaces = ' ' x $spacing;
    my str $comma  = ",\n" ~ $spaces x $level;

    # the escaped form of every key and every SHORT value, for the length of
    # this call: a document repeats its keys once per record, and its short
    # values (tags, names, enum-like words) often; a long value seldom repeats,
    # and hashing it costs more than escaping it
    my $escaped := nqp::hash;
    my sub escape(str $s --> str) {
        nqp::existskey($escaped, $s)
          ?? nqp::atkey($escaped, $s)
          !! nqp::bindkey($escaped, $s, str-escape($s))
    }

    my sub pairs-of(\associative) {
        $sorted-keys
          ?? associative.sort($sorted-keys<> =:= True ?? *.key !! $sorted-keys)
          !! associative.list
    }

    # JSON::Fast's pretty layout: the separator carries the next line's
    # indentation, a container pushes one and pops the trailing one, so an
    # EMPTY container comes out as "[\n]".
    my sub pretty-positional(\positional --> Nil) {
        $comma = nqp::concat($comma, $spaces);
        nqp::push_s($out, '[');
        nqp::push_s($out, nqp::substr($comma, 1));
        for positional.list {
            jsonify($_);
            nqp::push_s($out, $comma);
        }
        nqp::pop_s($out);
        $comma = nqp::substr($comma, 0, nqp::chars($comma) - $spacing);
        nqp::push_s($out, nqp::substr($comma, 1));
        nqp::push_s($out, ']');
    }

    my sub pretty-associative(\associative --> Nil) {
        $comma = nqp::concat($comma, $spaces);
        nqp::push_s($out, '{');
        nqp::push_s($out, nqp::substr($comma, 1));
        for pairs-of(associative) {
            nqp::push_s($out, '"');
            nqp::push_s($out, escape(.key.Str));
            nqp::push_s($out, '": ');
            jsonify(.value);
            nqp::push_s($out, $comma);
        }
        nqp::pop_s($out);
        $comma = nqp::substr($comma, 0, nqp::chars($comma) - $spacing);
        nqp::push_s($out, nqp::substr($comma, 1));
        nqp::push_s($out, '}');
    }

    my sub unpretty-positional(\positional --> Nil) {
        nqp::push_s($out, '[');
        my int $before = nqp::elems($out);
        for positional.list {
            jsonify($_);
            nqp::push_s($out, ',');
        }
        nqp::pop_s($out) if nqp::elems($out) > $before;
        nqp::push_s($out, ']');
    }

    my sub unpretty-associative(\associative --> Nil) {
        nqp::push_s($out, '{');
        my int $before = nqp::elems($out);
        for pairs-of(associative) {
            nqp::push_s($out, '"');
            nqp::push_s($out, escape(.key.Str));
            nqp::push_s($out, '":');
            jsonify(.value);
            nqp::push_s($out, ',');
        }
        nqp::pop_s($out) if nqp::elems($out) > $before;
        nqp::push_s($out, '}');
    }

    # The order of the tests is JSON::Fast's, and it matters: Bool and the
    # allomorphs before Str, enums before Str and Int, Seq before Positional,
    # Associative before Positional.
    my sub jsonify(\obj --> Nil) {
        if !obj.defined {
            nqp::push_s($out, 'null');
        }
        elsif nqp::istype(obj, Bool)   { nqp::push_s($out, obj ?? 'true' !! 'false') }
        elsif nqp::istype(obj, IntStr) { jsonify(obj.Int) }
        elsif nqp::istype(obj, RatStr) { jsonify(obj.Rat) }
        elsif nqp::istype(obj, NumStr) { jsonify(obj.Num) }
        elsif nqp::istype(obj, Enumeration) {
            if $enums-as-value { jsonify(obj.value) }
            else {
                nqp::push_s($out, '"');
                nqp::push_s($out, escape(obj.key));
                nqp::push_s($out, '"');
            }
        }
        elsif nqp::istype(obj, Str) {
            nqp::push_s($out, '"');
            nqp::push_s($out, nqp::chars(obj) <= 24 ?? escape(obj) !! str-escape(obj));
            nqp::push_s($out, '"');
        }
        elsif nqp::istype(obj, Int) { nqp::push_s($out, obj.Str) }
        elsif nqp::istype(obj, Rational) {
            my str $s = obj.Str;
            nqp::push_s($out, nqp::index($s, '.') >= 0 ?? $s !! nqp::concat($s, '.0'));
        }
        elsif nqp::istype(obj, Num) {
            if nqp::isnanorinf(obj) {
                nqp::push_s($out, $*JSON_NAN_INF_SUPPORT ?? obj.Str !! 'null');
            }
            else {
                my str $s = obj.Str;
                nqp::push_s($out, nqp::index($s, 'e') >= 0 ?? $s !! nqp::concat($s, 'e0'));
            }
        }
        elsif nqp::istype(obj, Seq)         { jsonify(obj.cache) }
        elsif nqp::istype(obj, Associative) { $pretty ?? pretty-associative(obj) !! unpretty-associative(obj) }
        elsif nqp::istype(obj, Positional)  { $pretty ?? pretty-positional(obj)  !! unpretty-positional(obj) }
        elsif nqp::istype(obj, Dateish)     { nqp::push_s($out, qq/"{obj}"/) }   # not escaped: nothing to escape
        elsif nqp::istype(obj, Instant)     { nqp::push_s($out, qq/"{obj.DateTime}"/) }
        elsif nqp::istype(obj, Real)        { jsonify(obj.Bridge) }
        elsif nqp::istype(obj, Version)     { jsonify(obj.Str) }
        else { die "Don't know how to jsonify {obj.^name}" }
    }

    jsonify(obj);
    nqp::join('', $out)
}
