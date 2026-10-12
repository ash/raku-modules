# Build hook: compile the native halves at install time.
#
# The XS bargain — the distribution carries C source rather than binaries, so
# it builds against whatever is actually installed. Two libraries, one per
# engine: src/json.c against Raku++'s extension ABI, and src/json-nc.c, plain C
# for Rakudo's NativeCall. If anything here fails it fails QUIETLY on purpose:
# the module answers through its other paths, so a missing compiler costs
# speed, never function. A build hook that aborts the install would turn an
# optimisation into a dependency.

class Build {
    method build($dist-path --> Bool) {
        my $root = $dist-path.IO;

        # Every declared resource must exist on EVERY path out of here, built
        # or not: the installer copies each META6 resource and dies on a
        # missing file, so "nothing to build" without a stub means "cannot
        # install". An empty stub is safe: neither loader takes it, and the
        # module falls back, same as after any failed build.
        my $ext = $*DISTRO.is-win ?? 'dll' !! ($*KERNEL.name eq 'darwin' ?? 'dylib' !! 'so');
        my &lib = -> $name { $root.add("resources/libraries/" ~ ($*DISTRO.is-win ?? "$name.$ext" !! "lib$name.$ext")) };
        for &lib('json'), &lib('json-nc') -> $out {
            $out.parent.mkdir;
            $out.spurt('') unless $out.e;
        }

        $*RAKU.compiler.name eq 'Raku++'
          ?? self!build-extension($root, &lib('json'))
          !! self!build-nativecall($root, &lib('json-nc'));
        True
    }

    # Rakudo (or any engine that is not Raku++): plain C, no headers to find.
    method !build-nativecall($root, $out) {
        my $src = $root.add('src/json-nc.c');
        return unless $src.e;
        my @cmd = self!compiler, '-O2', '-shared', '-fPIC', $src.Str, '-o', $out.Str;
        my $p = try run(|@cmd, :out, :err);
        unless $p && $p.exitcode == 0 {
            note "JSON::Native: no C library for NativeCall (no C compiler?); "
               ~ "using JSON::Fast if it is installed, else the Raku implementation";
            note $p.err.slurp(:close).indent(4) if $p;
            $out.spurt('');   # a half-written library must not look like one
        }
    }

    # Raku++: the extension, against the installed rakupp headers.
    method !build-extension($root, $out) {
        my $src = $root.add('src/json.c');
        return unless $src.e;
        my $inc = self!include-dir;
        unless $inc && $inc.add('rakupp/rakupp_ext.h').e {
            note "JSON::Native: no rakupp headers found; the engine's codec answers instead";
            return;
        }
        my @cmd = self!compiler, '-O2', '-shared', '-fPIC', "-I$inc",
                  |self!link-flags, $src.Str, '-o', $out.Str;
        my $p = try run(|@cmd, :out, :err);
        unless $p && $p.exitcode == 0 {
            note "JSON::Native: native build failed; the engine's codec answers instead";
            note $p.err.slurp(:close).indent(4) if $p;
            $out.spurt('');
        }
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
