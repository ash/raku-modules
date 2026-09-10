# Shared by the suite: run a program in a CHILD interpreter with stdin we
# control. A `.t` file's own stdin belongs to the harness, so the only way to
# assert what `prompt` reads is to be the thing feeding it.
unit module Child;

# The distribution's own lib, as an ABSOLUTE path derived from the test file
# rather than a bare `lib` relative to the current directory: an installer runs
# these from wherever it unpacked the distribution, which is not necessarily
# where it starts the child.
my $LIB = $*PROGRAM.absolute.IO.parent.parent.add('lib').Str;

sub child(Str $code, Str $input = "", *%env --> List) is export {
    # `:env` ONLY when an override was asked for — one caller in the whole
    # suite does. Copying %*ENV and handing it back otherwise buys nothing and
    # costs something on Windows, where the environment carries the hidden
    # per-drive variables (`=C:`, `=ExitCode`); re-serialising names that begin
    # with `=` is how a rebuilt environment block stops being well formed.
    my @cmd = $*EXECUTABLE, '-I', $LIB, '-e', $code;
    my $p = do if %env {
        my %e = %*ENV;
        %e{.key} = .value for %env;
        run(@cmd, :in, :out, :err, :env(%e));
    }
    else {
        run(@cmd, :in, :out, :err);
    }
    # A child that dies is half of what this suite asserts, and on Rakudo a
    # Proc whose child exited non-zero throws WHEN IT IS SUNK. `.in.close`
    # hands the Proc back, so a bare `try { … }` here threw from the sinking of
    # its own result, outside the try. Ending the block on a plain value is
    # what keeps the Proc from ever reaching sink context.
    try { $p.in.print($input); $p.in.close; True }
    my $out = (try $p.out.slurp(:close)) // '';
    my $err = (try $p.err.slurp(:close)) // '';
    ($out, $err, (try $p.exitcode) // -1)
}
