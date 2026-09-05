=begin pod

=head1 Data::Native

One portable C<use> line for whatever the engine does natively.

    use Data::Native;

    my %rec  = name => 'Ada', langs => <Raku C>, score => 9.5;
    my $json = to-json(%rec);
    say from-json($json)<langs>[1];      # C
    say sha256-hex($json);
    say json-backend();                  # 'core' where the engine answers,
                                         # else 'native' or 'JSON::Fast'

B<This file runs, unchanged, on every Raku.> What differs is what answers. On an
engine that supplies the primitives, every call above is that engine's own C and
nothing needs installing. Everywhere else the same calls go through the
C<**::Native> distributions and the established modules they stand in for.

    use Data::Native;                    # everything
    use Data::Native <json csv>;         # or name the tags

The spelling is C<E<lt>json csvE<gt>>, B<not> C<:json> — Rakudo routes C<:tag>
through the C<is export(:tag)> machinery, which a C<sub EXPORT> module has no
part in.

=head2 The five tags

=item C<json> — C<from-json> C<to-json> C<json-backend>
=item C<csv> — C<from-csv> C<to-csv> C<csv-backend>
=item C<digest> — C<md5 sha1 sha224 sha256 sha384 sha512>, their C<-hex> twins,
C<hmac> C<hmac-hex>, C<digest-backend>
=item C<zlib> — C<compress> C<uncompress> C<gzslurp> C<gzspurt> C<crc32>
C<adler32> C<zlib-backend>
=item C<random> — C<crypt_random_buf> C<crypt_random> C<crypt_random_uniform>
C<random-backend>

Twenty-seven functions and five C<*-backend> subs. Every signature is the
reference interface's, character for character, so a program moves between
C<use Data::Native E<lt>digestE<gt>> and C<use Digest::Native> — or
C<use Digest::SHA2; use Digest::HMAC;> — by editing one line, in either
direction, on either engine.

=head2 What answers, and how to ask

Three backends, in this order, per name:

=item the B<engine's own primitive>, C<rakupp-E<lt>nameE<gt>> and equivalents,
if this engine supplies it — C<*-backend()> reports C<'core'>;
=item the B<C<**::Native> distribution> for that family, which has its own
compiled extension and its own fallback — it reports C<'native'> or the name of
the module it delegated to;
=item a B<stub that throws when called>, naming the tag, the missing module and
the C<zef install> line.

The third exists because a C<sub EXPORT> that dies is swallowed by both engines
— Raku++ warns and continues, Rakudo says nothing at all — so failing at
C<use> time is not available as a mechanism. B<Every tag always exports every
one of its names>, and a name with no implementation fails when it is called,
with a sentence that says what to do. That is better than failing at C<use>
anyway: it does not punish a program that imports everything and calls
C<from-json>.

=head2 Cooperating with the ::Native modules

C<use Data::Native E<lt>digestE<gt>> and C<use Digest::Native> export the same
fourteen names, and two modules exporting one name is a hard compile error on
Rakudo — so they cooperate through a process-global claim registry rather than
colliding. Whichever loads second yields the contested names, and the program
builds in either order. Which implementation then answers is not observable:
that is what the shared conformance vectors in each distribution are for.

A claim is B<per tag>, so C<use Data::Native E<lt>csvE<gt>; use JSON::Native;>
gives you the engine's CSV and C<JSON::Native>'s JSON, as it should.

=end pod

# ===========================================================================
# The fallbacks — and the one rule that decides which modules they are.
#
# THIS MODULE MUST NOT `use` ANYTHING THAT PARTICIPATES IN THE CLAIM PROTOCOL.
#
# A **::Native module announces itself in the registry when its EXPORT puts
# names into a scope. Loading one from here runs that EXPORT — into THIS file's
# scope, not the caller's — and the announcement is then indistinguishable from
# one the caller made. This module would stand aside from its own names, and
# `use Data::Native` would export nothing at all.
#
# There is no way out from this side. The repair would be to snapshot the
# registry before these `use`s and restore it after, which needs BEGIN, and on
# Rakudo touching PROCESS:: at compile time inside a module that gets
# precompiled makes the precomp unserializable. Three spellings were tried;
# all three fail the same way.
#
# So the dependencies here are the REFERENCE modules — the same ones each
# **::Native module falls back to — and none of them has heard of the registry.
# The cost is that the digest and zlib compositions appear twice, here and in
# the distribution that owns them, and the conformance vectors in each of those
# distributions are what keep the two copies honest.
#
# CSV is the exception, because no reference exists for it — that distribution
# IS the reference. It resolves the same way anyway: CSV::Native::Core holds the
# implementation and has no export protocol, and `need` reaches it without
# running anything. That is the general pattern for a family where our own
# module is the reference.
#
# Each `use` is in its own BLOCK: several of them export the same names
# (Digest::SHA1 and Digest::SHA1::Native both give `&sha1`), and side by side
# that is a hard compile error on Rakudo.
# ===========================================================================

my (&f-from-json, &f-to-json);
{ use JSON::Fast; &f-from-json = &from-json; &f-to-json = &to-json; }

# `need`, not `use`: CSV::Native is on the claim protocol, and `use` would run
# its EXPORT into THIS file's scope, leaving an announcement in the registry
# that this module would then read as the caller's and stand aside for. `need`
# runs no EXPORT at all — probed on both engines — and CSV::Native::Core is the
# half that holds the implementation and announces nothing.
need CSV::Native::Core;
my &f-from-csv    = &CSV::Native::Core::from-csv;
my &f-to-csv      = &CSV::Native::Core::to-csv;
my &f-csv-backend = &CSV::Native::Core::csv-backend;

my %f-hash;                      # algorithm -> Blob-returning sub
my (&f-sha1-hex, &f-sha256-hex); # the two the ecosystem produces in C directly
my (&f-hmac, &f-hmac-hex);
{ use Digest::MD5;            %f-hash<md5> = &md5; }
{ use Digest::SHA1::Native;   %f-hash<sha1> = &sha1; &f-sha1-hex = &sha1-hex; }
{ use Digest::SHA256::Native; %f-hash<sha256> = &sha256; &f-sha256-hex = &sha256-hex; }
my %f-sha2;   # Digest::SHA2's own sha256/sha512, kept for the note below
{ use Digest::SHA2; %f-hash<sha224> = &sha224; %f-hash<sha384> = &sha384;
                    %f-hash<sha512> = &sha512;
                    %f-sha2<sha256> = &sha256; %f-sha2<sha512> = &sha512; }
{ use Digest::HMAC; &f-hmac = &hmac; &f-hmac-hex = &hmac-hex; }

my (&f-z-compress, &f-z-uncompress);
my $f-z-Stream;
{
    use Compress::Zlib;
    &f-z-compress   = &compress;
    &f-z-uncompress = &uncompress;
    # Its Stream class is where the other two framings live: window-bits 15 is
    # zlib, -15 bare deflate, 31 gzip — exactly the :gzip/:raw distinction.
    $f-z-Stream = ::('Compress::Zlib::Stream');
}

my %f-random;
{
    use Crypt::Random;
    %f-random = crypt_random_buf     => &crypt_random_buf,
                crypt_random         => &crypt_random,
                crypt_random_uniform => &crypt_random_uniform;
}

# ---- composing the digest tag from those five ----------------------------

sub d-bytes($in) {
    given $in {
        when Blob       { $_ }
        when Str        { .encode('utf-8') }
        when IO::Path   { .slurp(:bin) }
        when IO::Handle { .slurp(:bin) }
        default { die "Data::Native: cannot digest a {$in.^name}; "
                    ~ "pass a Str, a Blob, an IO::Path or an IO::Handle" }
    }
}

my constant %BLOCK = md5 => 64, sha1 => 64, sha224 => 64,
                     sha256 => 64, sha384 => 128, sha512 => 128;

my %f-digest;
for %BLOCK.keys -> $algo {
    %f-digest{$algo} = sub ($in, *%o) {
        # `:initial-hash` is a Digest::SHA2 internal, and a user passing it gets
        # an error — but SHA2's OWN sha224 and sha384 call sha256 and sha512
        # with it, and on Raku++ that call can land HERE instead of on SHA2's
        # own sub, because a module's imports are visible far beyond the module.
        # Passing it back to SHA2 is what keeps sha224 and sha384 working there.
        # On Rakudo this branch never runs. It goes away when the engine stops
        # leaking imports, or when the tag has native primitives — whichever
        # comes first.
        return %f-sha2{$algo}($in, |%o)
            if %o<initial-hash>:exists && (%f-sha2{$algo}:exists);
        die "Data::Native: $algo takes no named arguments" if %o;
        blob8.new(%f-hash{$algo}(d-bytes($in)))
    };
    %f-digest{"{$algo}-hex"} = sub ($in, *%o) {
        die "Data::Native: {$algo}-hex takes no named arguments" if %o;
        my $b = d-bytes($in);
        return f-sha1-hex($b)   if $algo eq 'sha1';
        return f-sha256-hex($b) if $algo eq 'sha256';
        %f-hash{$algo}($b).list».fmt('%02x').join
    };
}
# Digest::HMAC is the padding, and it is right; what it gets wrong is defaulting
# every hash to a 64-byte block, which makes hmac(…, &sha512) a non-standard
# MAC. Absent, the algorithm's real block length is used, as RFC 2104 says;
# given, it is honoured exactly. Both inputs are Blobs by then, so its own
# .encode('ascii') never fires and UTF-8 text works where it would have died.
sub d-algo-of(&hash) {
    for %BLOCK.keys -> $a { return $a if %f-digest{$a} === &hash }
    Nil
}
sub d-block(&hash, $blocksize) {
    return $blocksize if $blocksize.defined;
    my $a = d-algo-of(&hash);
    # 64 for a hash that is not one of ours: a foreign Callable cannot be asked
    # for its block length, and 64 is Digest::HMAC's own default.
    $a.defined ?? %BLOCK{$a} !! 64
}
%f-digest<hmac> = sub ($key, $message, &hash, $blocksize?) {
    blob8.new(f-hmac(d-bytes($key), d-bytes($message), &hash, d-block(&hash, $blocksize)))
};
%f-digest<hmac-hex> = sub ($key, $message, &hash, $blocksize?) {
    f-hmac-hex(d-bytes($key), d-bytes($message), &hash, d-block(&hash, $blocksize))
};

# ---- composing the zlib tag ----------------------------------------------

sub z-framing(%o, Str $where) {
    my $g = ?%o<gzip>;
    my $r = ?%o<raw>;
    die "Data::Native: $where takes :gzip or :raw, not both" if $g && $r;
    my @extra = %o.keys.grep({ $_ ne 'gzip' && $_ ne 'raw' });
    die "Data::Native: $where does not take " ~ @extra.sort.map({ ":$_" }).join(', ')
        if @extra;
    $g ?? \(:gzip) !! ($r ?? \(:deflate) !! Nil)
}

my %f-zlib;
%f-zlib<compress> = sub (Blob $data, Int $level = 6, *%o) {
    die "compression level must be between -1 and 9" if $level < -1 || $level > 9;
    my $args = z-framing(%o, 'compress');
    return Buf.new(f-z-compress(Buf.new($data), $level)) unless $args;
    my $s = $f-z-Stream.new(|$args);
    my $out = Buf.new($s.deflate(Buf.new($data)));
    $out ~= Buf.new($_) with $s.finish;
    $out
};
%f-zlib<uncompress> = sub (Blob $data, *%o) {
    my $args = z-framing(%o, 'uncompress');
    return Buf.new(f-z-uncompress(Buf.new($data))) unless $args;
    my $s = $f-z-Stream.new(|$args);
    my $out = Buf.new($s.inflate(Buf.new($data)));
    $out ~= Buf.new($_) with $s.finish;
    $out
};
%f-zlib<gzslurp> = sub ($path, :$bin) {
    my $out = %f-zlib<uncompress>($path.IO.slurp(:bin), :gzip);
    $bin ?? $out !! $out.decode('utf-8')
};
%f-zlib<gzspurt> = sub ($path, $stuff, :$bin) {
    my $blob = $stuff ~~ Blob ?? $stuff !! $stuff.Str.encode('utf-8');
    $path.IO.spurt(%f-zlib<compress>($blob, 6, :gzip));
    True
};
# Neither checksum is in Compress::Zlib at all, so these are ours on every
# engine. Slow — about a megabyte a second — and present, which beats absent.
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
sub z-in($d) { $d ~~ Blob ?? $d !! ($d ~~ Str ?? $d.encode('utf-8')
              !! die "Data::Native: expected a Blob or a Str, got a {$d.^name}") }
%f-zlib<crc32> = sub ($data, Int $init = 0) {
    my @t := crc-table();
    my int $c = (+^$init) +& 0xffffffff;
    for z-in($data).list -> int $b { $c = @t[($c +^ $b) +& 0xff] +^ ($c +> 8) }
    (+^$c) +& 0xffffffff
};
%f-zlib<adler32> = sub ($data, Int $init = 1) {
    my int $s1 = $init +& 0xffff;
    my int $s2 = ($init +> 16) +& 0xffff;
    for z-in($data).list -> int $b { $s1 = ($s1 + $b) % 65521; $s2 = ($s2 + $s1) % 65521 }
    ($s2 +< 16) +| $s1
};

# ===========================================================================
# The tag table.
#
# One tag, one reference interface, one family of engine primitives. The order
# of the names is the order they are documented in, so the two lists can be
# read against each other.
# ===========================================================================

my constant @DIGEST-NAMES =
    <md5 sha1 sha224 sha256 sha384 sha512
     md5-hex sha1-hex sha224-hex sha256-hex sha384-hex sha512-hex
     hmac hmac-hex>;

my %TAGS =
    json => {
        names => <from-json to-json>,
        needs => 'JSON::Fast',
        via   => { 'from-json' => &f-from-json, 'to-json' => &f-to-json },
        back  => sub () { 'JSON::Fast' },
    },
    csv => {
        names => <from-csv to-csv>,
        needs => 'CSV::Native',
        via   => { 'from-csv' => &f-from-csv, 'to-csv' => &f-to-csv },
        back  => &f-csv-backend,
    },
    digest => {
        names => @DIGEST-NAMES,
        needs => 'Digest',
        via   => %f-digest,
        back  => sub () { 'Digest' },
    },
    zlib => {
        names => <compress uncompress gzslurp gzspurt crc32 adler32>,
        needs => 'Compress::Zlib',
        via   => %f-zlib,
        back  => sub () { 'Compress::Zlib' },
    },
    random => {
        names => <crypt_random_buf crypt_random crypt_random_uniform>,
        needs => 'Crypt::Random',
        via   => %f-random,
        back  => Nil,       # the OS call is the implementation; see below
    };

my @TAG-ORDER = <json csv digest zlib random>;

# ===========================================================================
# Engine primitives.
#
# One prefix per engine that answers natively; adopting this contract is
# supplying subs under your own prefix and adding one line here. The lookup is
# `&::(…)`, a RUNTIME resolution every Raku compiles, so nothing in this file
# is compiler-visible and nothing here fails to parse anywhere.
#
# The probe is FUNCTIONAL, not by name, and that is not caution for its own
# sake: `rakupp-sha1-hex` exists on Raku++ 3.25.0 today and returns UPPERCASE
# hex, where every module in that family returns lowercase. A by-existence
# probe would have silently changed what this module answers the moment it ran
# on that engine. So a primitive counts only if it reproduces a known value —
# one hash of "abc", one round trip, one check string — and the return TYPE is
# part of what is checked.
# ===========================================================================

my constant @PREFIXES = <rakupp>;

my constant %ABC =
    md5    => '900150983cd24fb0d6963f7d28e17f72',
    sha1   => 'a9993e364706816aba3e25717850c26c9cd0d89d',
    sha224 => '23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7',
    sha256 => 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    sha384 => 'cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed'
            ~ '8086072ba1e7cc2358baeca134c825a7',
    sha512 => 'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a'
            ~ '2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f';

sub answers-contract(Str $name, &p --> Bool) {
    my $algo = $name.subst(/'-hex'$/, '');
    if %ABC{$algo}:exists {
        my $got = try {
            my $r = p('abc');
            $name.ends-with('-hex')
                ?? ($r ~~ Str  ?? $r                        !! Nil)
                !! ($r ~~ Blob ?? $r.list».fmt('%02x').join !! Nil)
        };
        return $got.defined && $got eq %ABC{$algo};
    }
    my $ok = try {
        given $name {
            when 'from-json'  { p('{"a":[1,2.5,true,null]}')<a>[1] == 2.5 }
            when 'to-json'    { my $s = p({ a => 1 }); $s ~~ Str && $s.contains('"a"') }
            when 'from-csv'   { my @r = p("a,b\n1,2\n"); @r.elems == 2 && @r[1][1] eq '2' }
            when 'to-csv'     { my $s = p([[<a b>],]); $s ~~ Str && $s.starts-with('a,b') }
            when 'crc32'      { p('123456789') == 0xcbf43926 }
            when 'adler32'    { p('123456789') == 0x091e01de }
            when 'hmac-hex'   { p(Buf.new(0x0b xx 20), 'Hi There', &::('rakupp-sha256'))
                                eq 'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7' }
            # compress/uncompress are a pair: neither is checkable alone, and a
            # round trip through both is the only honest question to ask.
            when 'compress' | 'uncompress' {
                my &c = &::('rakupp-compress');
                my &u = &::('rakupp-uncompress');
                so &c && &u && u(c('hello world'.encode)).decode eq 'hello world'
            }
            # Bytes that must differ, and a length that must be right. A CSPRNG
            # cannot be checked against a fixed value, which is the point of it.
            when 'crypt_random_buf' { my $a = p(32); my $b = p(32);
                                      $a ~~ Blob && $a.elems == 32 && $a.list !eqv $b.list }
            when 'crypt_random'     { my $v = p(4); $v ~~ Int && $v >= 0 }
            when 'crypt_random_uniform' { my $v = p(10); $v ~~ Int && 0 <= $v < 10 }
            # A name with no cheap check earns no trust; it is not adopted.
            default { False }
        }
    };
    ?$ok
}

my %CORE;
sub native(Str $name) {
    return %CORE{$name} if %CORE{$name}:exists;
    %CORE{$name} = do {
        my $found = Nil;
        for @PREFIXES -> $p {
            my &c = try &::("$p-$name");
            next unless &c;
            next unless answers-contract($name, &c);
            $found = &c;
            last;
        }
        $found
    }
}

sub stub(Str $tag, Str $name, Str $needs) {
    sub (|) {
        die "Data::Native: <$tag> needs a native `$name` that this engine does "
          ~ "not supply, and $needs is not installed here — `zef install $needs`"
    }
}

# ===========================================================================
# The *-backend subs.
#
# 'core' when the engine answered for this tag, otherwise whatever the
# distribution behind it reports for itself — 'native' for its own compiled
# extension, or the name of the ecosystem module it stood aside for. The
# distinction is the whole diagnostic value: `say json-backend()` should
# distinguish three things, not two.
# ===========================================================================

sub tag-answered(Str $tag --> Bool) {
    ?%TAGS{$tag}<names>.list.grep({ native($_).defined })
}

sub backend-for(Str $tag) {
    # A plain scalar, not `my &delegate`: the `random` tag has no module to
    # delegate to and stores Nil there, which a Callable-constrained container
    # refuses.
    my $delegate = %TAGS{$tag}<back>;
    sub () {
        return 'core' if tag-answered($tag);
        return $delegate() if $delegate.defined;
        # `random` has no **::Native module to ask: Crypt::Random is already a
        # thin native binding, so there is no third state to report.
        %TAGS{$tag}<names>.list.grep({ %TAGS{$tag}<via>{$_}.defined })
            ?? %TAGS{$tag}<needs> !! 'none'
    }
}

# ===========================================================================
# Export.
#
# `sub EXPORT` at FILE scope with no `unit module` line above it: inside a
# package declaration Rakudo never runs EXPORT, exports nothing, and reports no
# error — the worst possible shape, and the reason this file has no `unit`.
# ===========================================================================

sub claimed()  { PROCESS::<%DATA-NATIVE-CLAIMED>  //= {} }
sub exported() { PROCESS::<%DATA-NATIVE-EXPORTED> //= {} }

sub EXPORT(*@tags) {
    my @want = @tags.map(*.Str);
    @want = @TAG-ORDER if !@want || @want.any eq 'all';

    my @unknown = @want.grep({ !(%TAGS{$_}:exists) });
    die "Data::Native: no such tag" ~ (@unknown > 1 ?? 's' !! '') ~ " "
      ~ @unknown.map({ "<$_>" }).join(', ')
      ~ "; the tags are " ~ @TAG-ORDER.map({ "<$_>" }).join(' ')
        if @unknown;

    my %e;
    for @want -> $tag {
        my %t := %TAGS{$tag};

        # Claim FIRST, and unconditionally. A **::Native module loading after
        # this one reads the claim and stands aside; that is what makes
        # `use Data::Native; use Digest::Native;` compile on Rakudo, where two
        # modules exporting one name is an error rather than a shrug.
        claimed(){$tag} = True;

        # And yield if one of them got here first: its names are already in the
        # caller's scope, and putting ours on top is that same error.
        next if exported(){$tag};

        for %t<names>.list -> $n {
            %e{"&$n"} = native($n) // %t<via>{$n} // stub($tag, $n, %t<needs>);
        }
        %e{"&{$tag}-backend"} = backend-for($tag);
    }
    Map.new(%e)
}
