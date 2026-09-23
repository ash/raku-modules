# Build data in Raku, write it as TOML, read it back.
#
#   raku   -Ilib examples/roundtrip.raku
#   rakupp -Ilib examples/roundtrip.raku

use TOML::Native;

my %data =
    name     => 'raku-modules',
    released => Date.new(2026, 9, 23),
    started  => DateTime.new('2026-09-23T10:00:00.25+02:00'),
    ratio    => 0.75e0,
    tags     => [<toml config native>],
    limits   => { cpu => 2, memory => '512M' },
    deps     => [ { name => 'JSON::Fast', optional => False },
                  { name => 'Test',       optional => True } ];

my $text = to-toml(%data);
print $text;

my %back = from-toml($text);
say %back eqv %data ?? 'read back the same' !! 'DIFFERENT';

# TOML has no null, so an undefined value cannot be written.
try to-toml({ missing => Any });
say $!.message;                          # TOML::Native: cannot write an undefined value for 'missing'
