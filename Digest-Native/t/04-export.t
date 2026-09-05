use Test;

# The export protocol, and the cooperation with Data::Native that keeps
# `use Data::Native; use Digest::Native;` compiling at all.
#
# Each case is a SEPARATE PROCESS, because what is being tested is what `use`
# does — which happens at compile time, once, and cannot be re-run inside a
# test that has already imported the module.

plan 12;

my $lib = $*PROGRAM.parent.parent.add('lib');

sub run-raku(Str $code) {
    my $p = run($*EXECUTABLE, "-I$lib", '-e', $code, :out, :err);
    my $out = $p.out.slurp(:close).trim;
    my $err = $p.err.slurp(:close).trim;
    ($p.exitcode, $out, $err)
}

# ---- the tag spelling ----------------------------------------------------

# `<json csv>`, not `:json`: Rakudo routes `:tag` through the `is export(:tag)`
# machinery, which a `sub EXPORT` module has no part in, so the angle form is
# the only spelling that works on both engines.
{
    # md5-hex throughout, because no fallback distribution exports that name.
    # This file is about what `use` puts in scope; using a contested name made
    # it about the Raku++ import leak and about whether a dependency's own
    # NativeCall library happens to load, neither of which is the subject.
    my ($rc, $out, $err) = run-raku('use Digest::Native; say md5-hex("abc")');
    is $rc, 0, 'a bare use compiles';
    is $out, '900150983cd24fb0d6963f7d28e17f72', 'and imports the whole family';
}
{
    my ($rc, $out, $err) = run-raku(
        'use Digest::Native <md5-hex>; say md5-hex("abc")');
    is $rc, 0, 'a named subset compiles';
    is $out, '900150983cd24fb0d6963f7d28e17f72', 'and imports what was asked for';

    # A name that was not asked for is not merely undefined, it is undeclared —
    # so this is a separate process: on Rakudo the whole program fails to
    # compile, which is the behaviour being asserted.
    #
    # It fails on Raku++, and the reason is not this module. Raku++ leaks a
    # module's own `use` imports into the scope of whatever imports THAT
    # module — from a block, from file scope, from inside a sub alike — so the
    # names withheld here are visible anyway, supplied by the very fallback
    # distributions this module delegates to. Rakudo confines all three. It is
    # an engine bug with its own repro; when it is fixed, delete this todo.
    todo 'Raku++ leaks a module\'s own imports into the importer'
        if $*RAKU.compiler.name eq 'Raku++';
    my ($rc2, $, $) = run-raku('use Digest::Native <md5-hex>; md5("abc")');
    isnt $rc2, 0, 'and nothing else';
}

# A typo'd name must not silently import nothing. A dying EXPORT is swallowed
# by BOTH engines — rakupp warns, Rakudo says nothing at all, and either way
# the program runs on to fail at the first call — so the error has to be worth
# reading when it does surface.
{
    my ($rc, $out, $err) = run-raku('use Digest::Native <sha257>; say "reached"');
    ok ($err ~~ /"sha257"/ or $out ~~ /"sha257"/),
       'an unknown name is reported, and names itself';
}

# ---- the cooperation protocol -------------------------------------------

# Data::Native does not exist yet (DATA-PLAN P6), so its half of the protocol
# is played here by writing the claim registry directly. That is exactly what
# its `sub EXPORT` is specified to do before returning, and it is the only part
# of the contract this module can hold up on its own.
my $claimer = $*TMPDIR.add("dn-claimer-{$*PID}");
$claimer.add('lib').mkdir;
$claimer.add('lib/FakeDataNative.rakumod').spurt(q:to/MOD/);
    # Stands in for Data::Native <digest>: claims the tag, then exports the
    # names itself, exactly as the real one will.
    sub EXPORT(*@tags) {
        my %c := (PROCESS::<%DATA-NATIVE-CLAIMED>  //= {});
        my %x := (PROCESS::<%DATA-NATIVE-EXPORTED> //= {});
        %c{$_} = True for (@tags || <json csv digest zlib random>);
        return Map.new unless %c<digest>;
        # The other half of the protocol: a **::Native module has already put
        # the digest names in this scope, so claiming the tag is the whole job
        # and exporting on top of them would be a compile error on Rakudo.
        return Map.new if %x<digest>;
        # md5-hex, deliberately: NO fallback distribution exports that name —
        # Digest::MD5 has only `md5` — so this cell measures the cooperation
        # protocol and nothing else. Contesting `sha256-hex` measured the
        # Raku++ import leak instead, because bduggan's dist exports it too.
        Map.new(
            '&md5-hex'    => sub (|) { 'FROM-CLAIMANT' },
            '&sha384-hex' => sub (|) { 'FROM-CLAIMANT' },
        )
    }
    MOD
LEAVE { try { .unlink for $claimer.add('lib').dir; $claimer.add('lib').rmdir; $claimer.rmdir } }

my $both = "-I$lib -I{$claimer.add('lib')}";

sub run-both(Str $code) {
    my $p = run($*EXECUTABLE, "-I$lib", "-I{$claimer.add('lib')}", '-e', $code, :out, :err);
    ($p.exitcode, $p.out.slurp(:close).trim, $p.err.slurp(:close).trim)
}

# The case Rakudo makes a hard compile error unless the modules cooperate:
#     Cannot import symbol '&sha256-hex' … it already exists in this lexical scope
{
    my ($rc, $out, $err) = run-both(
        'use FakeDataNative <digest>; use Digest::Native; say md5-hex("abc")');
    is $rc, 0, 'claimant first, then Digest::Native — compiles';
    is $out, 'FROM-CLAIMANT', 'and the claimant keeps the name';
}
{
    my ($rc, $out, $err) = run-both(
        'use Digest::Native; use FakeDataNative <digest>; say md5-hex("abc")');
    is $rc, 0, 'Digest::Native first, then the claimant — compiles';
    # In this direction our names were already in scope when the claimant
    # loaded, so it stands aside instead and ours answer. What the protocol
    # guarantees is that the program BUILDS in either order and that whichever
    # implementation answers gives the same value — which is what the shared
    # conformance vectors are for.
    is $out, '900150983cd24fb0d6963f7d28e17f72',
       'and the implementation already in scope answers';
}

# A tag this module has nothing to do with must not make it stand aside.
{
    my ($rc, $out, $err) = run-both(
        'use FakeDataNative <json>; use Digest::Native; say md5-hex("abc")');
    is $rc, 0, 'a claim on another tag compiles';
    is $out, '900150983cd24fb0d6963f7d28e17f72', 'and leaves this module exporting normally';
}

done-testing;
