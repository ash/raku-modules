use Test;

# The export protocol, and the cooperation with Data::Native that keeps
# `use Data::Native; use Compress::Zlib::Native;` compiling at all.
#
# Each case is a SEPARATE PROCESS, because what is being tested is what `use`
# does — which happens at compile time, once, and cannot be re-run inside a
# test that has already imported the module.

plan 12;

my $lib = $*PROGRAM.parent.parent.add('lib');

sub run-raku(Str $code) {
    my $p = run($*EXECUTABLE, "-I$lib", '-e', $code, :out, :err);
    ($p.exitcode, $p.out.slurp(:close).trim, $p.err.slurp(:close).trim)
}

# ---- the tag spelling ----------------------------------------------------

# `<compress uncompress>`, not `:compress`: Rakudo routes `:tag` through the
# `is export(:tag)` machinery, which a `sub EXPORT` module has no part in, so
# the angle form is the only spelling that works on both engines.
{
    my ($rc, $out, $) = run-raku(
        'use Compress::Zlib::Native; say crc32("123456789").fmt("%08x")');
    is $rc, 0, 'a bare use compiles';
    is $out, 'cbf43926', 'and imports the whole family';
}
{
    my ($rc, $out, $) = run-raku(
        'use Compress::Zlib::Native <crc32>; say crc32("123456789").fmt("%08x")');
    is $rc, 0, 'a named subset compiles';
    is $out, 'cbf43926', 'and imports what was asked for';

    # A name that was not asked for is undeclared, so this is its own process.
    #
    # It fails on Raku++, and the reason is not this module: Raku++ leaks a
    # module's own `use` imports into the scope of whatever imports THAT
    # module — from a block, from file scope, from inside a sub alike — so the
    # names withheld here arrive anyway from Compress::Zlib, which this module
    # delegates to. Rakudo confines all three. It is an engine bug with its own
    # repro; when it is fixed, delete this todo.
    todo 'Raku++ leaks a module\'s own imports into the importer'
        if $*RAKU.compiler.name eq 'Raku++';
    my ($rc2, $, $) = run-raku('use Compress::Zlib::Native <crc32>; adler32("x")');
    isnt $rc2, 0, 'and nothing else';
}

# A typo'd name must not silently import nothing. A dying EXPORT is swallowed
# by BOTH engines — Raku++ warns, Rakudo says nothing at all — so the error has
# to be worth reading when it does surface.
{
    my ($rc, $out, $err) = run-raku('use Compress::Zlib::Native <crc31>; say "reached"');
    ok ($err ~~ /'crc31'/ or $out ~~ /'crc31'/),
       'an unknown name is reported, and names itself';
}

# ---- the cooperation protocol -------------------------------------------

# Data::Native does not exist yet (DATA-PLAN P6), so its half of the protocol
# is played here by writing the claim registry directly. That is exactly what
# its `sub EXPORT` is specified to do before returning, and it is the only part
# of the contract this module can hold up on its own.
my $claimer = $*TMPDIR.add("czn-claimer-{$*PID}");
$claimer.add('lib').mkdir;
$claimer.add('lib/FakeDataNative.rakumod').spurt(q:to/MOD/);
    # Stands in for Data::Native <zlib>.
    sub EXPORT(*@tags) {
        my %c := (PROCESS::<%DATA-NATIVE-CLAIMED>  //= {});
        my %x := (PROCESS::<%DATA-NATIVE-EXPORTED> //= {});
        %c{$_} = True for (@tags || <json csv digest zlib random>);
        return Map.new unless %c<zlib>;
        # The other half of the protocol: a **::Native module has already put
        # the zlib names in this scope, so claiming the tag is the whole job
        # and exporting on top of them would be a compile error on Rakudo.
        return Map.new if %x<zlib>;
        Map.new(
            '&crc32'   => sub (|) { 'FROM-CLAIMANT' },
            '&adler32' => sub (|) { 'FROM-CLAIMANT' },
        )
    }
    MOD
LEAVE { try { .unlink for $claimer.add('lib').dir; $claimer.add('lib').rmdir; $claimer.rmdir } }

sub run-both(Str $code) {
    my $p = run($*EXECUTABLE, "-I$lib", "-I{$claimer.add('lib')}", '-e', $code, :out, :err);
    ($p.exitcode, $p.out.slurp(:close).trim, $p.err.slurp(:close).trim)
}

# The case Rakudo makes a hard compile error unless the modules cooperate:
#     Cannot import symbol '&crc32' … it already exists in this lexical scope
{
    my ($rc, $out, $) = run-both(
        'use FakeDataNative <zlib>; use Compress::Zlib::Native; say crc32("123456789")');
    is $rc, 0, 'claimant first, then Compress::Zlib::Native — compiles';

    # The same Raku++ import leak, doing real damage this time. This module
    # DOES stand aside — its EXPORT returns an empty Map when the tag is
    # already claimed — but Compress::Zlib::Raw declares a NativeCall
    # `crc32(ulong, CArray[int8], int32)` for libz, and on Raku++ that
    # declaration escapes this module and lands on top of the claimant's name,
    # so the program calls libz's crc32 with the wrong arguments and gets 0.
    # Rakudo confines it and the claimant keeps the name, which is the
    # specified behaviour. Delete this todo when the engine bug is fixed.
    todo 'Raku++ leaks Compress::Zlib::Raw\'s NativeCall crc32 over the claimant\'s'
        if $*RAKU.compiler.name eq 'Raku++';
    is $out, 'FROM-CLAIMANT', 'and the claimant keeps the name';
}
{
    my ($rc, $out, $) = run-both(
        'use Compress::Zlib::Native; use FakeDataNative <zlib>; say crc32("123456789").fmt("%08x")');
    is $rc, 0, 'Compress::Zlib::Native first, then the claimant — compiles';
    # In this direction our names were already in scope when the claimant
    # loaded, so it stands aside instead and ours answer. What the protocol
    # guarantees is that the program BUILDS in either order and that whichever
    # implementation answers gives the same value — which is what the shared
    # conformance vectors are for.
    is $out, 'cbf43926', 'and the implementation already in scope answers';
}

# A tag this module has nothing to do with must not make it stand aside.
{
    my ($rc, $out, $) = run-both(
        'use FakeDataNative <json>; use Compress::Zlib::Native; say crc32("123456789").fmt("%08x")');
    is $rc, 0, 'a claim on another tag compiles';
    is $out, 'cbf43926', 'and leaves this module exporting normally';
}

done-testing;
