=begin pod

=head1 Compress::Zlib::Native

gzip and zlib without libz — our own DEFLATE on Raku++, and C<Compress::Zlib>
everywhere else.

=head2 Why it exists

C<Compress::Zlib> is NativeCall over the system C<libz>, which means it needs
that library to be present and its ABI to be the one the bindings expect. This
distribution carries the format instead of binding to a library: RFC 1951
(deflate), RFC 1950 (the zlib wrapper) and RFC 1952 (gzip), in C compiled at
install time. That works inside an C<--exe> binary and in the WASM playground,
where a dlopen'd system library is not there to be found, and it is what makes
C<gzslurp>/C<gzspurt> work on Raku++ at all — C<Compress::Zlib>'s own file
wrappers reach for C<nqp::p6definite> and fail there.

B<It is not faster than zlib.> zlib is thirty years of tuned C; this is a
clean-room implementation of a small closed specification. The claim is
availability and self-containment. The README has the measured table.

=head2 Synopsis

    use Compress::Zlib::Native;

    my $z = compress($data);                 # zlib framing, as the reference
    say uncompress($z).decode;

    my $g = compress($data, 9, :gzip);       # gzip framing — ours
    my $r = compress($data, 6, :raw);        # bare deflate, for Content-Encoding

    gzspurt('log.gz', $text);
    say gzslurp('log.gz');

    say crc32($data).fmt('%08x');
    say zlib-backend();                      # 'native' or 'Compress::Zlib'

=head2 The interface is C<Compress::Zlib>'s

    compress(Blob $data, Int $level = 6 --> Buf)
    uncompress(Blob $data --> Buf)
    gzslurp($path, :$bin)
    gzspurt($path, $stuff, :$bin)

Same names, same signatures, same defaults — so swapping this module in or out
is a one-line edit. C<$level> outside -1..9 dies, as it does there.

B<Where it is a superset,> and all of it is additive:

=item C<:gzip> and C<:raw> on C<compress> and C<uncompress>. The reference
reaches those two framings only through its C<Compress::Zlib::Stream> class,
and raw deflate plus gzip are exactly what an HTTP C<Content-Encoding> needs.
The two adverbs are mutually exclusive.
=item C<crc32> and C<adler32>, which the reference does not offer at all.
Both take a C<Str> (as UTF-8) or a C<Blob>, and an optional running value so
they can be fed a stream in pieces.

B<Not in this cut:> the C<Compress::Zlib::Stream> class and C<zwrap>.
Streaming inflate and deflate are a second phase; the one-shot subs are what
the dependents call.

=head2 Errors

A malformed stream dies with a message that says what was wrong with it —
C<zlib header check failed>, C<gzip CRC mismatch>, C<distance points before the
start of the stream> — rather than the reference's single C<uncompress data
error>. The checksums are verified, so a stream that decompresses to the wrong
bytes is an error and not a silent result.

=end pod

# ===========================================================================
# The fallback.
#
# One module, `use`d in a BLOCK so its `compress`/`uncompress` stay out of this
# file's scope. It is a hard `depends`, the JSON::Fast pattern: `require`
# inside a module breaks the whole export on Rakudo, so a plain `use` is the
# only idiom that works on both engines.
#
# Installing it does NOT require libz — Compress::Zlib::Raw declares its
# NativeCall subs lazily and only looks for the library on the first call — so
# depending on it costs a Raku++ user nothing at install time, and on Raku++
# the fallback path is not the one that runs.
# ===========================================================================

my (&fb-compress, &fb-uncompress);
my $fb-Stream;
{
    use Compress::Zlib;
    &fb-compress   = &compress;
    &fb-uncompress = &uncompress;
    # Compress::Zlib::Stream is a class rather than an exported sub, and it is
    # what gives the fallback the other two framings: window-bits 15 is zlib,
    # -15 is bare deflate and 31 is gzip, which is exactly the :gzip/:raw
    # distinction. Reaching for it beats re-framing streams by hand.
    $fb-Stream = ::('Compress::Zlib::Stream');
}

# ===========================================================================
# The compiled extension. `&::(…)` is a RUNTIME lookup, so this compiles on
# Rakudo too, where it yields Nil.
# ===========================================================================

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
my (&x-compress, &x-uncompress, &x-crc32, &x-adler32);

sub libraries() {
    my $ext  = $*DISTRO.is-win ?? 'dll' !! ($*KERNEL.name eq 'darwin' ?? 'dylib' !! 'so');
    my $stem = $*DISTRO.is-win ?? "zlib.$ext" !! "libzlib.$ext";
    my @c;
    # %?RESOURCES is the installed answer and works on both engines; the CWD
    # form covers a checkout tested with -Ilib. NOT $?FILE-relative: under
    # Raku++ a module's $?FILE is the MAIN PROGRAM's path.
    with (try %?RESOURCES<libraries/zlib>) { @c.push($_) if .defined }
    @c.push($*CWD.add("resources/libraries/$stem"));
    @c
}

sub load-native(--> Bool) {
    return False unless &ext-load;
    for libraries() -> $lib {
        next unless $lib.IO.e;
        next unless (try ext-load($lib.Str));
        &x-compress   = try &::('zlib-compress-native');
        &x-uncompress = try &::('zlib-uncompress-native');
        &x-crc32      = try &::('zlib-crc32-native');
        &x-adler32    = try &::('zlib-adler32-native');
        return True if &x-compress && &x-uncompress;
    }
    False
}

my Bool $is-native = load-native();

# ===========================================================================
# Core primitives, probed FUNCTIONALLY.
#
# DATA-PLAN spells the engine's built-ins `rakupp-<function>`. A by-name probe
# is not enough: `rakupp-sha1-hex` already exists on Raku++ 3.25.0 and returns
# UPPERCASE hex where the whole ecosystem returns lowercase, which is what a
# by-existence probe would have quietly adopted in the sister distribution. So
# a primitive counts here only if it round-trips a known value.
# ===========================================================================

my %CORE;
sub core-primitive(Str $name) {
    return %CORE{$name} if %CORE{$name}:exists;
    %CORE{$name} = do {
        my &p = try &::("rakupp-$name");
        if !&p { Nil }
        else {
            my $ok = try {
                given $name {
                    when 'compress'   { my $r = p('hello world'.encode); $r ~~ Blob && $r.elems > 0 }
                    when 'uncompress' { False }   # only meaningful paired with compress
                    when 'crc32'      { p('123456789') == 0xcbf43926 }
                    when 'adler32'    { p('123456789') == 0x091e01de }
                    default           { False }
                }
            };
            $ok ?? &p !! Nil
        }
    }
}

sub claimed()  { PROCESS::<%DATA-NATIVE-CLAIMED>  //= {} }
sub exported() { PROCESS::<%DATA-NATIVE-EXPORTED> //= {} }

# ===========================================================================
# Bytes.
# ===========================================================================

my constant FMT-ZLIB = 0;
my constant FMT-GZIP = 1;
my constant FMT-RAW  = 2;

sub framing(%opt, Str $where) {
    my $g = ?%opt<gzip>;
    my $r = ?%opt<raw>;
    die "Compress::Zlib::Native: $where takes :gzip or :raw, not both" if $g && $r;
    my @extra = %opt.keys.grep({ $_ ne 'gzip' && $_ ne 'raw' });
    die "Compress::Zlib::Native: $where does not take "
      ~ @extra.sort.map({ ":$_" }).join(', ') if @extra;
    $g ?? FMT-GZIP !! ($r ?? FMT-RAW !! FMT-ZLIB)
}

# What the C hands back, and which it is depends on the ABI it was compiled
# against — the module's C is built at INSTALL time, so both are live states.
#
#   ABI 3 and later: a real Buf, from rk_blob. Returned AS IS, no copy at all.
#   older:           a Str whose codepoints are the bytes, because rk_str
#                    decodes what it is given as UTF-8 and compressed bytes do
#                    not survive that. latin-1 maps them back — and that encode
#                    is what cost 46% of a two-megabyte inflate.
sub to-buf($raw) {
    return $raw if $raw ~~ Buf;
    Buf.new($raw ~~ Blob ?? $raw !! $raw.encode('latin-1'))
}

sub as-bytes($d, Str $what) {
    return $d      if $d ~~ Blob;
    return $d.encode('utf-8') if $d ~~ Str;
    die "Compress::Zlib::Native: $what expects a Blob or a Str, got a {$d.^name}"
}

# ===========================================================================
# The fallback's framings.
#
# `compress`/`uncompress` with no adverb go through Compress::Zlib's own
# one-shot subs, so the default case is byte-for-byte what the module being
# stood in for would have produced. The two adverbs go through its Stream
# class, which is where it keeps the other window-bits settings.
# ===========================================================================

sub fb-stream-args(Int $fmt) {
    $fmt == FMT-GZIP ?? \(:gzip) !! ($fmt == FMT-RAW ?? \(:deflate) !! \(:zlib))
}

sub fb-deflate(Blob $data, Int $fmt) {
    my $s = $fb-Stream.new(|fb-stream-args($fmt));
    my $out = Buf.new($s.deflate(Buf.new($data)));
    $out ~= Buf.new($_) with $s.finish;
    $out
}

sub fb-inflate(Blob $data, Int $fmt) {
    my $s = $fb-Stream.new(|fb-stream-args($fmt));
    my $out = Buf.new($s.inflate(Buf.new($data)));
    $out ~= Buf.new($_) with $s.finish;
    $out
}

# ===========================================================================
# CRC-32 and Adler-32 in Raku, for the fallback.
#
# The reference offers neither, so "present but slow" is strictly better than
# absent — but it IS slow, roughly a megabyte a second on Rakudo and far less
# on Raku++, where the native path answers anyway. Documented rather than
# hidden; if the fallback ever needs to be fast, Compress::Zlib::Raw could bind
# libz's own crc32 in a line.
# ===========================================================================

my @CRC-TABLE;
sub crc-table() {
    return @CRC-TABLE if @CRC-TABLE;
    for ^256 -> $i {
        my $c = $i;
        $c = $c +& 1 ?? 0xedb88320 +^ ($c +> 1) !! $c +> 1 for ^8;
        @CRC-TABLE[$i] = $c;
    }
    @CRC-TABLE
}
sub raku-crc32(Blob $b, Int $init) {
    my @t := crc-table();
    my int $c = (+^$init) +& 0xffffffff;
    for $b.list -> int $byte { $c = @t[($c +^ $byte) +& 0xff] +^ ($c +> 8) }
    (+^$c) +& 0xffffffff
}
sub raku-adler32(Blob $b, Int $init) {
    my int $s1 = $init +& 0xffff;
    my int $s2 = ($init +> 16) +& 0xffff;
    for $b.list -> int $byte { $s1 = ($s1 + $byte) % 65521; $s2 = ($s2 + $s1) % 65521 }
    ($s2 +< 16) +| $s1
}

# ===========================================================================
# The seven functions.
# ===========================================================================

sub do-compress(Blob $data, Int $level, Int $fmt) {
    return to-buf(x-compress($data, $level, $fmt)) if $is-native;
    return Buf.new(fb-compress(Buf.new($data), $level)) if $fmt == FMT-ZLIB;
    fb-deflate($data, $fmt)
}

sub do-uncompress(Blob $data, Int $fmt) {
    return to-buf(x-uncompress($data, $fmt)) if $is-native;
    return Buf.new(fb-uncompress(Buf.new($data))) if $fmt == FMT-ZLIB;
    fb-inflate($data, $fmt)
}

my %IMPL;

%IMPL<compress> = sub (Blob $data, Int $level = 6, *%opt) {
    die "compression level must be between -1 and 9" if $level < -1 || $level > 9;
    do-compress($data, $level, framing(%opt, 'compress'))
};

%IMPL<uncompress> = sub (Blob $data, *%opt) {
    do-uncompress($data, framing(%opt, 'uncompress'))
};

%IMPL<gzslurp> = sub ($path, :$bin) {
    my $out = do-uncompress($path.IO.slurp(:bin), FMT-GZIP);
    $bin ?? $out !! $out.decode('utf-8')
};

%IMPL<gzspurt> = sub ($path, $stuff, :$bin) {
    my $blob = $stuff ~~ Blob ?? $stuff !! $stuff.Str.encode('utf-8');
    die "Compress::Zlib::Native: gzspurt(:bin) wants a Blob, got a {$stuff.^name}"
        if $bin && $stuff !~~ Blob;
    $path.IO.spurt(do-compress($blob, 6, FMT-GZIP));
    True
};

%IMPL<crc32> = sub ($data, Int $init = 0) {
    my $b = as-bytes($data, 'crc32');
    $is-native ?? x-crc32($b, $init) !! raku-crc32($b, $init)
};

%IMPL<adler32> = sub ($data, Int $init = 1) {
    my $b = as-bytes($data, 'adler32');
    $is-native ?? x-adler32($b, $init) !! raku-adler32($b, $init)
};

sub zlib-backend() {
    return 'core'   if claimed()<zlib> && core-primitive('compress').defined;
    return 'native' if $is-native;
    'Compress::Zlib'
}
%IMPL<zlib-backend> = &zlib-backend;

my @NAMES = <compress uncompress gzslurp gzspurt crc32 adler32 zlib-backend>;
my $KNOWN = @NAMES.Set;

# ===========================================================================
# Export.
#
# `sub EXPORT` at FILE scope with no `unit module` above it: inside a package
# declaration Rakudo never runs EXPORT, exports nothing, and reports no error.
# The tag spelling is `<compress uncompress>`, not `:compress`.
#
# The cooperation protocol with Data::Native is the same as Digest::Native's,
# for the `zlib` tag: whichever module loads second yields the contested names,
# because two modules exporting one name is a compile error on Rakudo. A
# dispatcher is installed only for a name whose core primitive exists AND
# answers the contract — otherwise `Data::Native <zlib>` on this engine would
# itself be falling back to this module, and there is nothing to switch to.
# ===========================================================================

sub dispatcher(Str $name) {
    my $target;
    sub (|c) {
        $target //= (claimed()<zlib> ?? core-primitive($name) !! Nil) // %IMPL{$name};
        $target(|c)
    }
}

sub EXPORT(*@names) {
    my $stand-aside = ?claimed()<zlib>;
    exported()<zlib> = 'Compress::Zlib::Native' unless $stand-aside;

    my @want = @names ?? @names.map(*.Str) !! @NAMES;
    my @unknown = @want.grep({ !$KNOWN{$_} });
    die "Compress::Zlib::Native: no such name" ~ (@unknown > 1 ?? 's' !! '') ~ " "
      ~ @unknown.map({ "'$_'" }).join(', ')
        if @unknown;

    return Map.new() if $stand-aside;

    my %e;
    for @want -> $n {
        %e{"&$n"} = ($n ne 'zlib-backend' && core-primitive($n).defined)
            ?? dispatcher($n)
            !! %IMPL{$n};
    }
    Map.new(%e)
}
