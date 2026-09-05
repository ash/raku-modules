=begin pod

=head1 CSV::Native

CSV parsing and writing, native on Raku++ and pure Raku everywhere else.

This file is the importable face of the distribution; the implementation is in
C<CSV::Native::Core> beside it, and the README documents both. Everything a
program calls — C<from-csv>, C<to-csv>, C<csv-backend> — is exported from here
exactly as before the split, and the pure-Raku halves keep the spellings the
test suite and the README use, C<CSV::Native::parse-raku> and
C<CSV::Native::write-raku>.

=head2 Why the file is split

C<Data::Native> delegates its C<csv> tag here, because CSV is the one family
with no ecosystem reference to stand in for it — this distribution B<is> the
reference. But a module that C<use>s a claim-protocol participant runs that
participant's C<EXPORT> into its B<own> scope, and the announcement that leaves
in the registry cannot be told apart from one the caller made. C<Data::Native>
would stand aside from its own names and export nothing for the tag.

C<need CSV::Native::Core> runs no C<EXPORT> at all, on either engine, so the
implementation half is reachable without touching the registry. This half does
the importing and the cooperating.

=end pod

need CSV::Native::Core;

# The documented full-name spellings, unchanged by the split. A `module` BLOCK,
# not `unit module`: `sub EXPORT` has to sit at the file's outermost scope or
# Rakudo never runs it — silently, exporting nothing, with no error.
module CSV::Native {
    our sub parse-raku(|c) { CSV::Native::Core::parse-raku(|c) }
    our sub write-raku(|c) { CSV::Native::Core::write-raku(|c) }
}

# ===========================================================================
# The cooperation protocol.
#
# `use Data::Native <csv>` exports the same names from the engine's built-ins,
# and two modules exporting one name is a hard compile error on Rakudo — so
# these two cooperate rather than collide. Whichever loads second yields the
# contested names; the program builds in either order, and which implementation
# answers is not observable, which is what the conformance suites are for.
# ===========================================================================

sub claimed()  { PROCESS::<%DATA-NATIVE-CLAIMED>  //= {} }
sub exported() { PROCESS::<%DATA-NATIVE-EXPORTED> //= {} }

# Named explicitly rather than looked up symbolically: `::("&…::$_")` is a
# malformed lookup on Rakudo, and a literal table is checked at compile time.
my %IMPL = 'from-csv'    => &CSV::Native::Core::from-csv,
           'to-csv'      => &CSV::Native::Core::to-csv,
           'csv-backend' => &CSV::Native::Core::csv-backend;

my @NAMES = %IMPL.keys.sort;
my $KNOWN = @NAMES.Set;

sub EXPORT(*@names) {
    my $stand-aside = ?claimed()<csv>;
    exported()<csv> = 'CSV::Native' unless $stand-aside;

    my @want = @names ?? @names.map(*.Str) !! @NAMES;
    my @unknown = @want.grep({ !$KNOWN{$_} });
    die "CSV::Native: no such name" ~ (@unknown > 1 ?? 's' !! '') ~ " "
      ~ @unknown.map({ "'$_'" }).join(', ')
        if @unknown;

    return Map.new() if $stand-aside;

    Map.new(@want.map({ "&$_" => %IMPL{$_} }))
}
