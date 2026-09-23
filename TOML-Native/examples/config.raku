# Read a configuration document and use its values as the Raku types they
# arrive as — and show which implementation answered.
#
#   raku   -Ilib examples/config.raku
#   rakupp -Ilib examples/config.raku

use TOML::Native;

my %conf = from-toml(q:to/TOML/);
    title = "TOML example"

    [owner]
    name = "Tom Preston-Werner"
    dob = 1979-05-27T07:32:00-08:00

    [database]
    enabled = true
    ports = [ 8000, 8001, 8002 ]
    data = [ ["delta", "phi"], [3.14] ]
    temp_targets = { cpu = 79.5, case = 72.0 }

    [servers.alpha]
    ip = "10.0.0.1"
    role = "frontend"

    [servers.beta]
    ip = "10.0.0.2"
    role = "backend"

    [[backups]]
    at = 07:30:00
    on = 2026-09-23

    [[backups]]
    at = 19:30:00.5
    on = 2026-09-24
    TOML

say "parsed by the {toml-backend()} backend";
say %conf<title>;                                      # TOML example
say %conf<owner><dob>.year;                            # 1979 — a DateTime
say %conf<owner><dob>.timezone div 3600;               # -8
say %conf<database><ports>.sum;                        # 24003 — Ints
say %conf<database><temp_targets><cpu> + 0.5;          # 80 — a Num
say %conf<servers>.keys.sort.join(', ');               # alpha, beta
for %conf<backups>.list -> %b {
    say "backup on {%b<on>} ({%b<on>.day-of-week}) at {%b<at>}";   # a Date, a LocalTime
}

# Errors name the line.
try from-toml("[a]\nx = 1\n[a]\n");
say $!.message;                                        # TOML::Native: table 'a' is defined twice at line 3
