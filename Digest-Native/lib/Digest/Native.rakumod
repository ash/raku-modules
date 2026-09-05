=begin pod

=head1 Digest::Native

MD5, SHA-1, SHA-224/256/384/512 and HMAC — one distribution, our C on Raku++,
and the established native modules everywhere else.

=head2 Why it exists

The Raku ecosystem has native digests, but scattered: bduggan's
C<Digest::SHA1::Native> and C<Digest::SHA256::Native> are two separate installs
covering two algorithms, and neither does MD5, SHA-512 or HMAC. C<Digest>
(grondilu) covers all six in pure Raku — which on Raku++ runs at about
0.04 MB/s, some five thousand times slower than the same algorithm in C.
C<Digest::HMAC> is pure Raku on every engine.

This is one distribution covering C<md5 sha1 sha224 sha256 sha384 sha512> and
HMAC over any of them, with the C<-hex> twins the ecosystem already spells:

=item on B<Raku++>, our own C, compiled at install against the extension ABI;
=item on B<any other Raku>, delegation — bduggan's two dists for SHA-1 and
SHA-256, C<Digest> for the rest, C<Digest::HMAC> for HMAC.

The same program runs on both. What differs is what answers.

=head2 Synopsis

    use Digest::Native;

    say sha256-hex('abc');           # ba7816bf8f01cfea…
    say md5('abc').list;             # 144 1 80 152 60 210 79 176 …
    say sha512-hex('/etc/hosts'.IO); # a file is streamed, never slurped

    say hmac-hex($key, $message, &sha256);
    say digest-backend();            # 'native' on Raku++, 'Digest' elsewhere

    use Digest::Native <sha256 sha256-hex>;   # or just the names you want

=head2 The interface is the ecosystem's

Name for name, so swapping this module in or out is a one-line edit:

=item C<md5 sha1 sha224 sha256 sha384 sha512> return C<blob8>, as
C<Digest::SHA2> types them;
=item C<md5-hex … sha512-hex> return a lowercase C<Str>, as bduggan and
C<OpenSSL::Digest> spell them;
=item C<hmac($key, $message, &hash, $blocksize?)> returns a C<Blob> and
C<hmac-hex> a C<Str>, as C<Digest::HMAC> has them.

Three places this is deliberately a B<superset>, each of which agrees with the
reference on every input the reference accepts:

=item B<Input.> C<Str> (as UTF-8), C<Blob>/C<Buf>, C<IO::Path> and
C<IO::Handle>. A C<Supply> is not taken. An C<IO::Path> is B<streamed> — a
16 GB file costs 64 KB of memory, not 16 GB.

=item B<HMAC block size.> C<Digest::HMAC> defaults C<$blocksize> to 64 for
every hash, which makes C<hmac($k, $m, &sha512)> a non-standard MAC unless the
caller remembers to pass 128. Here C<$blocksize> has B<no default>: absent, and
C<&hash> one of this module's own, the algorithm's real block length is used
(64 below SHA-384, 128 at and above), which is what RFC 2104 says. Passed, it
is honoured exactly as written — so C<hmac($k, $m, &sha512, 64)> still
reproduces C<Digest::HMAC> bit for bit.

=item B<HMAC C<Str> inputs are UTF-8>, where C<Digest::HMAC> encodes them as
ASCII. Identical bytes for every input it accepts; works where it dies.

C<&hash> may be any C<Callable> — HMAC is two calls to it, so a hash of your own
keeps working. The native path is taken only for this module's own subs,
recognised by identity; anything else composes through C<Digest::HMAC> with
C<$blocksize> defaulting to 64, because a foreign hash cannot be asked for its
block length.

B<Not supported, and they throw:> C<:initial-hash> on C<sha256>/C<sha512> (a
C<Digest::SHA2> internal that leaks through its signature), and SHA-3, RIPEMD
and the other C<Digest> sub-modules. This distribution covers C<Digest::MD5>,
C<Digest::SHA1>, C<Digest::SHA2> and C<Digest::HMAC> — the four with
dependents.

=head2 digest-backend

C<digest-backend()> answers C<'native'> when our compiled extension is in use,
C<'core'> when the names have been claimed by C<Data::Native> and this engine
answers them as built-ins, and C<'Digest'> when the ecosystem modules are doing
the work. Because that last case is B<composed> of three distributions,
C<digest-backend> also takes an algorithm and names the exact one:

    digest-backend('sha1')   # 'native', 'core', or 'Digest::SHA1::Native'
    digest-backend('sha384') # 'native', 'core', or 'Digest::SHA2'

=head2 Cooperating with Data::Native

C<use Data::Native E<lt>digestE<gt>> gives the same fourteen names from the
engine's own built-ins. Two modules exporting one name is a compile error on
Rakudo, so these two cooperate rather than collide, and C<Data::Native> wins
for the tags it claimed whatever the C<use> order. The protocol is a
process-global claim registry; the details are in the source, beside the code
that implements them.

=end pod

# ===========================================================================
# The fallbacks.
#
# Each `use` sits in its own BLOCK, and that is not a style choice. `use` is
# lexically scoped, and two of the modules below export the SAME name —
# Digest::SHA1 and Digest::SHA1::Native both give you `&sha1` — so importing
# them side by side is a hard compile error on Rakudo:
#
#     Cannot import symbol '&sha1' from 'Digest::SHA1::Native', because it
#     already exists in this lexical scope.
#
# One block each, one captured reference each. It is also what keeps their
# names out of this file's scope, where our own `sha1` is about to be declared.
# JSON::Native learned the same lesson against JSON::Fast.
#
# These are hard `depends`, not probes. `require` inside a module breaks the
# whole export on Rakudo — measured, both engines, before this file was
# written — so the one idiom that works everywhere is a plain `use` at file
# scope. That is the JSON::Fast pattern, and it means there is exactly one
# fallback path and nothing extra to test.
# ===========================================================================

my &fb-md5;
{ use Digest::MD5;            &fb-md5 = &md5; }

my (&fb-sha1, &fb-sha1-hex);
{ use Digest::SHA1::Native;   &fb-sha1 = &sha1; &fb-sha1-hex = &sha1-hex; }

my (&fb-sha256, &fb-sha256-hex);
{ use Digest::SHA256::Native; &fb-sha256 = &sha256; &fb-sha256-hex = &sha256-hex; }

my (&fb-sha224, &fb-sha384, &fb-sha512);
{ use Digest::SHA2; &fb-sha224 = &sha224; &fb-sha384 = &sha384; &fb-sha512 = &sha512; }

my (&fb-hmac, &fb-hmac-hex);
{ use Digest::HMAC; &fb-hmac = &hmac; &fb-hmac-hex = &hmac-hex; }

# ===========================================================================
# The algorithms, and what answers for each in fallback mode.
# ===========================================================================

my constant %BLOCK = md5 => 64, sha1 => 64, sha224 => 64,
                     sha256 => 64, sha384 => 128, sha512 => 128;

my constant @ALGOS = <md5 sha1 sha224 sha256 sha384 sha512>;

# The exact distribution behind each algorithm when the C is not in play. Used
# by digest-backend($algo), and worth having written down in one place rather
# than spread through the README: "the fallback" is three dists, not one.
my constant %FALLBACK-OF =
    md5    => 'Digest::MD5',
    sha1   => 'Digest::SHA1::Native',
    sha224 => 'Digest::SHA2',
    sha256 => 'Digest::SHA256::Native',
    sha384 => 'Digest::SHA2',
    sha512 => 'Digest::SHA2';

my %FB-BYTES = md5 => &fb-md5, sha1 => &fb-sha1, sha224 => &fb-sha224,
               sha256 => &fb-sha256, sha384 => &fb-sha384, sha512 => &fb-sha512;

# ===========================================================================
# The compiled extension.
#
# `&::(…)` is a RUNTIME lookup, so these lines compile on Rakudo too, where
# they simply yield Nil. Anything spelled `use Rakupp::Ext` would have made the
# file uncompilable there.
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
my (&x-digest, &x-digest-file, &x-hmac);

sub libraries() {
    my $ext  = $*DISTRO.is-win ?? 'dll' !! ($*KERNEL.name eq 'darwin' ?? 'dylib' !! 'so');
    my $stem = $*DISTRO.is-win ?? "digest.$ext" !! "libdigest.$ext";
    my @c;
    # %?RESOURCES is the installed answer and works on both engines; the CWD
    # form covers a git checkout tested with -Ilib. NOT $?FILE-relative: under
    # Raku++ a module's $?FILE is the MAIN PROGRAM's path, so a path derived
    # from it lands somewhere unrelated.
    with (try %?RESOURCES<libraries/digest>) { @c.push($_) if .defined }
    @c.push($*CWD.add("resources/libraries/$stem"));
    @c
}

sub load-native(--> Bool) {
    return False unless &ext-load;
    for libraries() -> $lib {
        next unless $lib.IO.e;
        next unless (try ext-load($lib.Str));
        &x-digest      = try &::('digest-native');
        &x-digest-file = try &::('digest-file-native');
        &x-hmac        = try &::('hmac-native');
        return True if &x-digest && &x-hmac;
    }
    False
}

my Bool $is-native = load-native();

# ===========================================================================
# Core primitives — and why the probe is FUNCTIONAL.
#
# DATA-PLAN spells the engine's built-ins `rakupp-<function>`, so `sha256-hex`
# is `rakupp-sha256-hex`. Probing them by existence alone is not enough, and
# this is not hypothetical: `rakupp-sha1-hex` exists on Raku++ 3.25.0 today and
# returns UPPERCASE hex, where every module in this family — bduggan's,
# OpenSSL::Digest's, ours — returns lowercase. A by-name probe would have
# silently changed this module's answers the moment it ran on that engine.
#
# So a core primitive counts only if it ANSWERS THE CONTRACT: one known vector
# per name, checked once at load. The cost is one hash of "abc" per primitive
# that exists, which today is one.
# ===========================================================================

my constant %VECTOR-ABC =
    'md5'        => '900150983cd24fb0d6963f7d28e17f72',
    'sha1'       => 'a9993e364706816aba3e25717850c26c9cd0d89d',
    'sha224'     => '23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7',
    'sha256'     => 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    'sha384'     => 'cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed' ~
                    '8086072ba1e7cc2358baeca134c825a7',
    'sha512'     => 'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a' ~
                    '2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f';

# Memoised: EXPORT asks once per name, and digest-backend asks again.
my %CORE;
sub core-primitive(Str $name) {
    return %CORE{$name} if %CORE{$name}:exists;
    %CORE{$name} = do {
        my &p = try &::("rakupp-$name");
        my $algo = $name.subst(/'-hex'$/, '');
        my $want = %VECTOR-ABC{$algo};
        if !&p || !$want.defined { Nil }
        else {
            # The RETURN TYPE is part of the contract too: a `-hex` primitive
            # that hands back a Blob, or a bare one that hands back a Str, is
            # not the sub this module promises to export. Compared exactly —
            # lowercasing the answer here is precisely how the uppercase
            # `rakupp-sha1-hex` would have slipped through.
            my $got = try {
                my $r = p('abc');
                $name.ends-with('-hex')
                    ?? ($r ~~ Str  ?? $r                            !! Nil)
                    !! ($r ~~ Blob ?? $r.list».fmt('%02x').join     !! Nil)
            };
            ($got.defined && $got eq $want) ?? &p !! Nil
        }
    }
}

# ===========================================================================
# The cooperation protocol.
#
# `use Data::Native <digest>` exports the same fourteen names from the engine's
# built-ins, and two modules exporting one name is a COMPILE ERROR on Rakudo —
# so these two must cooperate or the program will not build. The registry is a
# pair of process-global hashes, probed identical on both engines:
#
#   %DATA-NATIVE-CLAIMED   tags Data::Native has claimed
#   %DATA-NATIVE-EXPORTED  tags a **::Native module has already put in scope
#
# Whichever loads second yields the contested names. When THIS module loads
# first it cannot know what is coming, so — per the protocol — it exports a
# dispatcher that resolves on first call: the core primitive if the tag was
# claimed by then, else our own backend.
#
# WITH ONE REFINEMENT, and it is the reason most programs pay nothing for this.
# A dispatcher is a Raku frame on every call, forever; a digest of a short
# string is a handful of microseconds, so that is not free. But a dispatcher
# only ever has something to switch TO when a core primitive for that name
# EXISTS AND ANSWERS THE CONTRACT — otherwise `Data::Native <digest>` on this
# engine would itself be falling back to this very module, and "core" and
# "ours" are the same code. So the wrapper is installed per name, only where a
# real core primitive was found. Today that is nowhere, and every exported name
# is the plain sub.
# ===========================================================================

sub claimed()  { PROCESS::<%DATA-NATIVE-CLAIMED>  //= {} }
sub exported() { PROCESS::<%DATA-NATIVE-EXPORTED> //= {} }

# ===========================================================================
# Input.
#
# One rule, and the C half relies on it: whatever arrives here leaves as bytes.
# A Str is its UTF-8; a Blob or Buf is itself; an IO::Path or IO::Handle is its
# contents. Everything else is refused BY NAME rather than silently stringified
# — inventing a digest of "Foo.new(...)" would be worse than any error.
# ===========================================================================

sub bytes-of($in) {
    given $in {
        when Blob       { $_ }
        when Str        { .encode('utf-8') }
        when IO::Path   { .slurp(:bin) }
        when IO::Handle { .slurp(:bin) }
        default {
            die "Digest::Native: cannot digest a {$in.^name}; "
              ~ "pass a Str, a Blob, an IO::Path or an IO::Handle"
        }
    }
}

# The extension takes a Str or a Blob straight — rk_str_get hands back a Str's
# UTF-8 and a Blob's raw bytes, which are the same bytes bytes-of() would
# produce — so the common two types cross with no conversion at all.
sub native-ready($in) { $in ~~ Str || $in ~~ Blob }

# What the C hands back, and it depends on which ABI it was compiled against —
# the module's C is built at INSTALL time, so both are live states.
#
#   ABI 3 and later: a real Buf, from rk_blob. Nothing to undo.
#   older:           a Str whose codepoints ARE the bytes, because rk_str
#                    decodes what it is given as UTF-8 and a raw digest does not
#                    survive that. latin-1 maps codepoints 0..255 back to bytes.
#
# One smartmatch to tell them apart, which for a 16-to-64-byte digest is the
# entire cost. Both paths are checked over all 256 values in t/03-inputs.t.
sub to-blob($raw) {
    blob8.new($raw ~~ Blob ?? $raw !! $raw.encode('latin-1'))
}

# ===========================================================================
# The fourteen functions.
# ===========================================================================

sub digest-bytes(Str $algo, $in) {
    if $is-native {
        return to-blob(x-digest-file($algo, $in.absolute, 0)) if $in ~~ IO::Path;
        return to-blob(x-digest($algo, $in, 0))               if native-ready($in);
        return to-blob(x-digest($algo, bytes-of($in), 0));
    }
    blob8.new(%FB-BYTES{$algo}(bytes-of($in)).list)
}

sub digest-hex(Str $algo, $in) {
    if $is-native {
        return x-digest-file($algo, $in.absolute, 1) if $in ~~ IO::Path;
        return x-digest($algo, $in, 1)               if native-ready($in);
        return x-digest($algo, bytes-of($in), 1);
    }
    # bduggan's two dists produce hex in C and skip a round trip through a Blob;
    # for the rest there is nothing to skip.
    my $bytes = bytes-of($in);
    return fb-sha1-hex($bytes)   if $algo eq 'sha1';
    return fb-sha256-hex($bytes) if $algo eq 'sha256';
    %FB-BYTES{$algo}($bytes).list».fmt('%02x').join
}

# `:initial-hash` is Digest::SHA2's own internal state leaking through its
# signature. Accepting it would mean carrying a second entry point into every
# implementation here for the sake of an argument nothing in the ecosystem
# passes; refusing it silently would be worse. It is named in the error.
sub reject-adverbs(Str $name, %opt) {
    return unless %opt;
    die "Digest::Native: $name takes no named arguments (got "
      ~ %opt.keys.sort.map({ ":$_" }).join(', ')
      ~ "); :initial-hash and the other Digest::SHA2 internals are not supported";
}

# The exported subs carry the common case INLINE, and that shape is a
# measurement rather than a preference. On this box (arm64, Raku++ 3.25.0) one
# raw extension call costs 1.6 us, each Raku frame around it adds 0.9, and each
# `~~` smartmatch adds 1.7. Digesting a short string is a couple of microseconds
# of C, so a polite chain of four small subs — an adverb check, a dispatcher, a
# type predicate — cost more than the hash it was wrapping: 10.2 us a call,
# against 4.1 for the version below. Everything unusual still goes to the
# helpers and pays a frame there, where nothing is counting.
my %IMPL;
for @ALGOS -> $algo {
    my $hexname = "{$algo}-hex";
    %IMPL{$algo} = $is-native
        ?? sub ($in, *%opt) {
               return to-blob(x-digest($algo, $in, 0)) if !%opt && ($in ~~ Str || $in ~~ Blob);
               reject-adverbs($algo, %opt);
               digest-bytes($algo, $in)
           }
        !! sub ($in, *%opt) { reject-adverbs($algo, %opt) if %opt; digest-bytes($algo, $in) };

    %IMPL{$hexname} = $is-native
        ?? sub ($in, *%opt) {
               return x-digest($algo, $in, 1) if !%opt && ($in ~~ Str || $in ~~ Blob);
               reject-adverbs($hexname, %opt);
               digest-hex($algo, $in)
           }
        !! sub ($in, *%opt) { reject-adverbs($hexname, %opt) if %opt; digest-hex($algo, $in) };
}

# Recognising "one of ours" by identity is what lets hmac take the native path
# and pick the right block length. The subs are built ONCE above, not per
# import, so `use Digest::Native; use Digest::Native <sha256>;` in one program
# still hands out the same &sha256 and the identity check still fires. Six
# `===` comparisons rather than a .WHICH table: identity of a Callable is the
# thing being asked about, so ask it directly.
sub algo-of(&hash) {
    for @ALGOS -> $a { return $a if %IMPL{$a} === &hash }
    Nil
}

sub hmac-impl(Str $name, $key, $message, &hash, $blocksize?) {
    my $algo = algo-of(&hash);
    my $hex  = $name.ends-with('-hex');

    if $algo && $is-native {
        # A Str and a Blob cross the ABI as the bytes they already are, so only
        # the unusual input types are converted at all.
        my $k = ($key     ~~ Str || $key     ~~ Blob) ?? $key     !! bytes-of($key);
        my $m = ($message ~~ Str || $message ~~ Blob) ?? $message !! bytes-of($message);
        return x-hmac($algo, $k, $m, $blocksize // 0, 1) if $hex;
        return to-blob(x-hmac($algo, $k, $m, $blocksize // 0, 0));
    }

    my $kb = bytes-of($key);
    my $mb = bytes-of($message);

    # Digest::HMAC is the padding, and it is correct; what it gets wrong is the
    # default block size. Ours is the algorithm's real one when we know the
    # hash, and 64 — its own default, the only defensible guess — when we do
    # not. Both key and message are already Blobs by here, so its `.encode
    # ('ascii')` never fires and UTF-8 text works where it would have died.
    my $B = $blocksize // ($algo ?? %BLOCK{$algo} !! 64);
    $hex ?? fb-hmac-hex($kb, $mb, &hash, $B) !! blob8.new(fb-hmac($kb, $mb, &hash, $B).list)
}

%IMPL<hmac>     = sub ($key, $message, &hash, $blocksize?) { hmac-impl('hmac',     $key, $message, &hash, $blocksize) };
%IMPL<hmac-hex> = sub ($key, $message, &hash, $blocksize?) { hmac-impl('hmac-hex', $key, $message, &hash, $blocksize) };

sub digest-backend($algo?) {
    my $claimed = claimed()<digest>:exists;
    if $algo.defined {
        my $a = $algo.Str;
        die "Digest::Native: digest-backend does not know '$a'"
            unless %FALLBACK-OF{$a}:exists || $a eq 'hmac';
        return 'core' if $claimed && core-primitive($a).defined;
        return 'native' if $is-native;
        return $a eq 'hmac' ?? 'Digest::HMAC' !! %FALLBACK-OF{$a};
    }
    return 'core'   if $claimed && @ALGOS.first({ core-primitive($_).defined }).defined;
    return 'native' if $is-native;
    'Digest'
}
%IMPL<digest-backend> = &digest-backend;

my @NAMES = |@ALGOS, |@ALGOS.map({ "{$_}-hex" }), 'hmac', 'hmac-hex', 'digest-backend';
my $KNOWN = @NAMES.Set;

# ===========================================================================
# Export.
#
# `sub EXPORT` at FILE scope, with no `unit module` line above it, and that is
# load-bearing: inside a package declaration Rakudo never runs EXPORT at all,
# exports nothing, and reports no error. Measured on both engines before this
# file was written.
#
# The tag spelling is `use Digest::Native <sha256>`, not `:sha256` — Rakudo
# routes `:tag` through the `is export(:tag)` machinery, which a `sub EXPORT`
# module has no part in.
# ===========================================================================

sub dispatcher(Str $name) {
    # Resolved on first call, when every `use` in the program has run and the
    # registry is final. Memoised from then on.
    my $target;
    sub (|c) {
        $target //= (claimed()<digest> ?? core-primitive($name) !! Nil) // %IMPL{$name};
        $target(|c)
    }
}

sub EXPORT(*@names) {
    # Data::Native got here first and claimed <digest>. Its names are already
    # in the caller's scope and putting ours on top is a compile error on
    # Rakudo, so we stand aside — which is the whole protocol, and the reason
    # `use Data::Native; use Digest::Native;` builds at all.
    my $stand-aside = ?claimed()<digest>;
    exported()<digest> = 'Digest::Native' unless $stand-aside;

    my @want = @names ?? @names.map(*.Str) !! @NAMES;
    my @unknown = @want.grep({ !$KNOWN{$_} });
    die "Digest::Native: no such name" ~ (@unknown > 1 ?? 's' !! '') ~ " "
      ~ @unknown.map({ "'$_'" }).join(', ')
        if @unknown;

    return Map.new() if $stand-aside;

    my %e;
    for @want -> $n {
        # A wrapper only where there is something to switch to; see the
        # cooperation protocol above.
        %e{"&$n"} = ($n ne 'digest-backend' && core-primitive($n).defined)
            ?? dispatcher($n)
            !! %IMPL{$n};
    }
    Map.new(%e)
}
