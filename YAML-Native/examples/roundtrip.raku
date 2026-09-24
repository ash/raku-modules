# Build data in Raku, write it as YAML, read it back.
#
#   raku   -Ilib examples/roundtrip.raku
#   rakupp -Ilib examples/roundtrip.raku

use YAML::Native;

my %data =
    name     => 'raku-modules',
    version  => '1.0',                   # a string that looks like a number
    enabled  => True,
    ratio    => 0.75e0,
    missing  => Any,
    tags     => [<yaml config native>],
    limits   => { cpu => 2, memory => '512M' },
    motd     => "Welcome.\nMind the gap.\n",
    deps     => [ { name => 'JSON::Fast', optional => False },
                  { name => 'Test',       optional => True } ];

my $text = to-yaml(%data);
print $text;

my %back = from-yaml($text);
say %back eqv %data ?? 'read back the same' !! 'DIFFERENT';

# Only what YAML can hold is written.
try to-yaml({ handle => $*OUT });
say $!.message;                          # YAML::Native: cannot write a value of type IO::Handle
