# FizBuz. Pirmā rinda ir vienīgā, ko nevar uzrakstīt latviski:
# slengs vēl nav ieslēgts, kamēr `use` nav izpildīts.
#
#     RAKUDO_RAKUAST=1 rakudo -I lib examples/fizzbuzz.raku   # Rakudo
#     rakupp -I lib examples/fizzbuzz.raku                    # Raku++
#
# Ar `latku` šis fails nedarbosies: izpildītājs ieslēdz slengu pirms
# parsēšanas, un tad `use` pirmajā rindā būtu jāraksta kā `lieto`.

use L10N::LV;

katram 1..20 -> $s {
    dots $s {
        kad $_ %% 15 { saki "FizBuz" }
        kad $_ %% 3  { saki "Fiz"    }
        kad $_ %% 5  { saki "Buz"    }
        noklusējums  { saki $s       }
    }
}
