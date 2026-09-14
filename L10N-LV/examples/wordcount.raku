# Vārdu biežuma vārdnīca: klase ar atribūtu un metodēm, jaucējtabula,
# regulārā izteiksme, kārtošana un nosaukts arguments — viss latviski.
#
#     RAKUDO_RAKUAST=1 rakudo -I lib examples/wordcount.raku   # Rakudo
#     rakupp -I lib examples/wordcount.raku                    # Raku++
#
# Ar `latku` šis fails nedarbosies: izpildītājs ieslēdz slengu pirms
# parsēšanas, un tad `use` pirmajā rindā būtu jāraksta kā `lieto`.

use L10N::LV;

mans $teksts = q:to/TEKSTS/;
Raku ir valoda ar daudzām sejām. Viena un tā pati valoda
lasās dažādi, un tā nav metafora: slengs maina gramatiku,
nevis tikai vārdnīcu. Valoda paliek tā pati.
TEKSTS

klase Skaitītājs {
    satur %.biežums;

    metode ieskaiti(Str:D $vārds) {
        %!biežums{$vārds}++ ja $vārds;
        pats
    }

    metode virsotne(Int:D :$cik = 5) {
        %!biežums.pāri.kārto({ -.vērtība, .atslēga }).galva($cik)
    }
}

mans $skaitītājs = Skaitītājs.jauns;
katram $teksts.mazie.izķemmē(/<[\w\-]>+/) -> $vārds {
    $skaitītājs.ieskaiti($vārds);
}

katram $skaitītājs.virsotne(cik => 5) -> $pāris {
    saki $pāris.vērtība ~ "  " ~ $pāris.atslēga;
}
