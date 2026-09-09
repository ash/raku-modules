# Shared by the suite: run a program in a CHILD interpreter with stdin we
# control. A `.t` file's own stdin belongs to the harness, so the only way to
# assert what `prompt` reads is to be the thing feeding it.
unit module Child;

sub child(Str $code, Str $input = "", *%env --> List) is export {
    my %e = %*ENV;
    %e{.key} = .value for %env;
    my $p = run($*EXECUTABLE, '-I', 'lib', '-e', $code, :in, :out, :err, :env(%e));
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
