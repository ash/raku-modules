# Build hook: compile the native half at install time.
#
# The XS bargain — the distribution carries C source rather than a binary, so it
# builds against whatever Raku++ is actually installed. If anything here fails,
# it fails QUIETLY on purpose: the module falls back to Compress::Zlib, so a
# missing compiler or a non-Raku++ engine costs the self-contained path, never
# function. A build hook that aborts the install would turn an optimisation
# into a dependency.

class Build {
    method build($dist-path --> Bool) {
        my $root = $dist-path.IO;
        my $src  = $root.add('src/zlib.c');

        # The declared resource must exist on EVERY path out of here, built or
        # not: the installer copies each META6 resource and dies on a missing
        # file, so "nothing to build" without a stub means "cannot install" —
        # on Rakudo, which is most machines. An empty stub is safe: ext-load
        # refuses it and the module falls back, same as any failed build.
        my $ext = $*DISTRO.is-win ?? 'dll' !! ($*KERNEL.name eq 'darwin' ?? 'dylib' !! 'so');
        my $stem = $*DISTRO.is-win ?? "zlib.$ext" !! "libzlib.$ext";
        my $out = $root.add("resources/libraries/$stem");
        $out.parent.mkdir;
        $out.spurt('') unless $out.e;

        return True unless $src.e;

        # Rakudo has no extension ABI to build against; nothing to do.
        return True unless $*RAKU.compiler.name eq 'Raku++';

        my $inc = self!include-dir;
        unless $inc && $inc.add('rakupp/rakupp_ext.h').e {
            note "Compress::Zlib::Native: no rakupp headers found; using the Compress::Zlib fallback";
            return True;
        }

        # -O2 is not decoration here. This is a bit-at-a-time Huffman decoder
        # and a hash-chain match loop, and an unoptimised build of either runs
        # several times slower for no reason.
        my @cmd = self!compiler, '-shared', '-fPIC', '-O2', "-I$inc",
                  |self!link-flags, $src.Str, '-o', $out.Str;
        my $p = run(|@cmd, :out, :err);
        unless $p.exitcode == 0 {
            note "Compress::Zlib::Native: native build failed, using the Compress::Zlib fallback";
            note $p.err.slurp(:close).indent(4);
            return True;
        }
        True
    }

    # <prefix>/include, discovered from the running binary: rakupp installs as
    # <prefix>/{bin,lib,include/rakupp} and `--exe` already relies on that layout.
    method !include-dir {
        my $bin = $*EXECUTABLE.IO;
        for $bin.parent.parent, $bin.parent.parent.parent -> $p {
            my $i = $p.add('include');
            return $i if $i.add('rakupp/rakupp_ext.h').e;
        }
        # a git checkout: point RAKUPP_SRC at its include/ directory
        my $env = %*ENV<RAKUPP_SRC>;
        return $env.IO if $env && $env.IO.add('rakupp/rakupp_ext.h').e;
        Nil
    }

    method !compiler { %*ENV<CC> // 'cc' }

    # An extension resolves the rk_* symbols from the host executable at load
    # time, exactly as a Python C extension does — so undefined symbols at LINK
    # time are expected and must be permitted.
    method !link-flags {
        given $*KERNEL.name {
            when 'darwin' { '-Wl,-undefined,dynamic_lookup' }
            default       { Empty }   # ELF resolves lazily by default
        }
    }
}
