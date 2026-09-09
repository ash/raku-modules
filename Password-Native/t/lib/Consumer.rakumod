# A MODULE that imports Password::Native — not a program. Precompiling an
# importer is what walks the imported module's saved state, and a module-scope
# `try` (this one probes for an engine primitive) leaves its exception in that
# file's `$!`, which Rakudo then fails to serialise. That is why probe-symbol
# is a sub. This fixture is the regression guard for it.
unit module Consumer;
use Password::Native;

sub consumer-backend(--> Str) is export { password-backend() }
sub consumer-prompt(|c) is export { prompt(|c) }
