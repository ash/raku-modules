# This file contains the Latvian Slang of the Raku Programming Language

#- start of generated part of localization ------------------------------------
#- Generated on 2026-09-14T12:58:07+02:00 by regen
#- PLEASE DON'T CHANGE ANYTHING BELOW THIS LINE

role L10N::LV {
    use experimental :rakuast;
    token block-default { noklusējums}
    token block-else { citādi}
    token block-elsif { citādija}
    token block-for { katram}
    token block-given { dots}
    token block-if { ja}
    token block-loop { cikls}
    token block-orwith { vaiar}
    token block-repeat { atkārto}
    token block-unless { izņemot}
    token block-until { līdz}
    token block-when { kad}
    token block-whenever { ikreiz}
    token block-while { kamēr}
    token block-with { ar}
    token block-without { bez}
    token constraint-where { kur}
    token enum-BigEndian { BigEndian}
    token enum-Broken { Lauzts}
    token enum-False { Aplams}
    token enum-FileChanged { FileChanged}
    token enum-FileRenamed { FileRenamed}
    token enum-Kept { Izpildīts}
    token enum-Less { Mazāk}
    token enum-LittleEndian { LittleEndian}
    token enum-More { Vairāk}
    token enum-NativeEndian { NativeEndian}
    token enum-Planned { Plānots}
    token enum-Same { Tāpat}
    token enum-SeekFromBeginning { SeekFromBeginning}
    token enum-SeekFromCurrent { SeekFromCurrent}
    token enum-SeekFromEnd { SeekFromEnd}
    token enum-True { Patiess}
    token infix-pcontp { "(satur)"}
    token infix-pelemp { "(elements)"}
    token infix-cff { "^ff"}
    token infix-cffc { "^ff^"}
    token infix-cfff { "^fff"}
    token infix-cfffc { "^fff^"}
    token infix-after { pēc}
    token infix-and { un}
    token infix-andthen { untad}
    token infix-before { pirms}
    token infix-but { bet}
    token infix-cmp { salīdzini}
    token infix-coll { coll}
    token infix-div { dali}
    token infix-does { dara}
    token infix-eq { vienāds}
    token infix-ff { ff}
    token infix-ffc { "ff^"}
    token infix-fff { fff}
    token infix-fffc { "fff^"}
    token infix-gcd { gcd}
    token infix-ge { lielākvienāds}
    token infix-gt { lielāks}
    token infix-lcm { lcm}
    token infix-le { mazākvienāds}
    token infix-leg { mlv}
    token infix-lt { mazāks}
    token infix-max { maks}
    token infix-min { min}
    token infix-minmax { minmaks}
    token infix-mod { atlikums}
    token infix-ne { nevienāds}
    token infix-notandthen { nevistad}
    token infix-o { o}
    token infix-or { vai}
    token infix-orelse { vaicitādi}
    token infix-unicmp { unicmp}
    token infix-x { x}
    token infix-X { X}
    token infix-xx { xx}
    token infix-Z { Z}
    token meta-R { R}
    token meta-X { X}
    token meta-Z { Z}
    token modifier-for { katram}
    token modifier-given { dots}
    token modifier-if { ja}
    token modifier-unless { izņemot}
    token modifier-until { līdz}
    token modifier-when { kad}
    token modifier-while { kamēr}
    token modifier-with { ar}
    token modifier-without { bez}
    token multi-multi { multi}
    token multi-only { vienīgā}
    token multi-proto { proto}
    token package-class { klase}
    token package-grammar { gramatika}
    token package-module { modulis}
    token package-package { pakotne}
    token package-role { loma}
    token phaser-BEGIN { BEGIN}
    token phaser-CATCH { ĶER}
    token phaser-CHECK { CHECK}
    token phaser-CLOSE { AIZVĒRŠANA}
    token phaser-CONTROL { VADĪBA}
    token phaser-DOC { DOC}
    token phaser-END { BEIGAS}
    token phaser-ENTER { IEEJA}
    token phaser-FIRST { PIRMAIS}
    token phaser-INIT { INIT}
    token phaser-KEEP { IZDEVĀS}
    token phaser-LAST { PĒDĒJAIS}
    token phaser-LEAVE { IZEJA}
    token phaser-NEXT { NĀKAMAIS}
    token phaser-POST { PĒC}
    token phaser-PRE { PIRMS}
    token phaser-QUIT { PĀRTRAUKUMS}
    token phaser-UNDO { ATSAUKŠANA}
    token prefix-not { nav}
    token prefix-so { tā}
    token quote-lang-m { m}
    token quote-lang-ms { ms}
    token quote-lang-q { q}
    token quote-lang-Q { Q}
    token quote-lang-qq { qq}
    token quote-lang-rx { rx}
    token quote-lang-s { s}
    token quote-lang-S { S}
    token quote-lang-ss { ss}
    token quote-lang-Ss { Ss}
    token routine-method { metode}
    token routine-regex { regekss}
    token routine-rule { likums}
    token routine-sub { funkcija}
    token routine-submethod { apakšmetode}
    token routine-token { marķieris}
    token scope-anon { anonīms}
    token scope-augment { papildini}
    token scope-constant { konstante}
    token scope-has { satur}
    token scope-HAS { SATUR}
    token scope-my { mans}
    token scope-our { mūsu}
    token scope-state { stāvoklis}
    token scope-unit { vienība}
    token stmt-prefix-also { arī}
    token stmt-prefix-do { dari}
    token stmt-prefix-eager { dedzīgi}
    token stmt-prefix-gather { savāc}
    token stmt-prefix-hyper { hiper}
    token stmt-prefix-lazy { slinki}
    token stmt-prefix-quietly { klusi}
    token stmt-prefix-race { sacīkstē}
    token stmt-prefix-react { reaģē}
    token stmt-prefix-sink { iztukšo}
    token stmt-prefix-start { sāc}
    token stmt-prefix-supply { piegādā}
    token stmt-prefix-try { mēģini}
    token term-nano { nano}
    token term-now { tagad}
    token term-pi { pi}
    token term-rand { nejauši}
    token term-self { pats}
    token term-tau { tau}
    token term-time { laiks}
    token traitmod-does { dara}
    token traitmod-handles { nodod}
    token traitmod-hides { slēpj}
    token traitmod-is { ir}
    token traitmod-of { no}
    token traitmod-returns { atgriež}
    token traitmod-trusts { uztic}
    token typer-enum { uzskaitījums}
    token typer-subset { apakškopa}
    token use-import { importē}
    token use-need { vajag}
    token use-no { izslēdz}
    token use-require { pieprasi}
    token use-use { lieto}
    method core2ast {
        my constant %mapping = "visi", "all", "antipāris", "antipair", "antipāri", "antipairs", "jebkurš", "any", "pievieno", "append", "gaidi", "await", "maiss", "bag", "padodos", "bail-out", "svētī", "bless", "var-ok", "can-ok", "kategorizē", "categorize", "griesti", "ceiling", "rakstzīmes", "chars", "maini-direktoriju", "chdir", "nocērt-galu", "chomp", "nocērt", "chop", "par-rakstzīmi", "chr", "par-rakstzīmēm", "chrs", "klasificē", "classify", "aizver", "close", "salidzini-ok", "cmp-ok", "kodi", "codes", "izķemmē", "comb", "kombinācijas", "combinations", "satur", "contains", "krustojums", "cross", "atkodē", "decode", "definēts", "defined", "diagnostika", "diag", "mirsti", "die", "mirst-ok", "dies-ok", "direktorija", "dir", "dara-ok", "does-ok", "pabeigts", "done", "elementi", "elems", "izstaro", "emit", "kodē", "encode", "beigas", "end", "beidzas-ar", "ends-with", "eval-mirst-ok", "eval-dies-ok", "eval-dzivo-ok", "eval-lives-ok", "iziet", "exit", "neizdodies", "fail", "krit-lidzigi", "fails-like", "pirmais", "first", "plakans", "flat", "otrādi", "flip", "grīda", "floor", "neizturēts", "flunk", "saņem", "get", "saņem-rakstzīmi", "getc", "būtība", "gist", "atlasi", "grep", "hešs", "hash", "galva", "head", "atkāpe", "indent", "indekss", "index", "indeksi", "indices", "invertē", "invert", "ir", "is", "ir-aptuveni", "is-approx", "ir-dzili", "is-deeply", "pirmskaitlis", "is-prime", "tips-ok", "isa-ok", "navir", "isnt", "vienums", "item", "savieno", "join", "atslēga", "key", "atslēgas", "keys", "av", "kv", "pārtrauc", "last", "mazie", "lc", "līdzīgs", "like", "rindas", "lines", "saite", "link", "saraksts", "list", "dzivo-ok", "lives-ok", "izveido", "make", "attēlo", "map", "sakritība", "match", "maks", "max", "minmaks", "minmax", "maisījums", "mix", "izveido-direktoriju", "mkdir", "pārvieto", "move", "jauns", "new", "tālāk", "next", "neok", "nok", "neviens", "none", "nav", "not", "piezīmē", "note", "viens", "one", "atver", "open", "par-kodu", "ord", "par-kodiem", "ords", "pāris", "pair", "pāri", "pairs", "izturēts", "pass", "permutācijas", "permutations", "izvēlies", "pick", "plāns", "plan", "izbīdi", "pop", "pievieno-sākumā", "prepend", "drukā", "print", "drukāf", "printf", "turpini", "proceed", "jautā", "prompt", "iebīdi", "push", "izvadi", "put", "nejaušs", "rand", "pārdari", "redo", "reducē", "reduce", "atkārtoti", "repeated", "atgriez", "return", "atgriez-lr", "return-rw", "apvērs", "reverse", "rindekss", "rindex", "dzēs-direktoriju", "rmdir", "met", "roll", "saknes", "roots", "pagriez", "rotate", "noapaļo", "round", "peckartas", "roundrobin", "palaid", "run", "saki", "say", "kopa", "set", "čaula", "shell", "nobīdi", "shift", "zīme", "sign", "izlaid", "skip", "izlaid-parejo", "skip-rest", "guli", "sleep", "modinātājs", "sleep-timer", "guli-līdz", "sleep-until", "ielasi", "slurp", "paskaties", "snitch", "tā", "so", "kārto", "sort", "ielīmē", "splice", "sadali", "split", "sformatē", "sprintf", "ieraksti", "spurt", "sakne", "sqrt", "saspied", "squish", "sēkla", "srand", "sākas-ar", "starts-with", "aizvieto", "subst", "apakšvirkne", "substr", "apakštests", "subtest", "izdodies", "succeed", "summa", "sum", "simsaite", "symlink", "aste", "tail", "ņem", "take", "ņem-lr", "take-rw", "met-lidzigi", "throws-like", "jādara", "todo", "tulko", "trans", "apgriez", "trim", "apgriez-sākumu", "trim-leading", "apgriez-beigas", "trim-trailing", "nogriez", "truncate", "lielie", "uc", "unikāli", "unique", "nelīdzīgs", "unlike", "dzēs", "unlink", "atbīdi", "unshift", "lieto-ok", "use-ok", "vērtība", "value", "vērtības", "values", "brīdini", "warn", "vārdi", "words", "savij", "zip";
        my $ast := self.ast;
        my $name := $ast ?? $ast.simple-identifier !! self.Str;
        if %mapping{$name} -> $original {
            RakuAST::Name.from-identifier($original)
        }
        else {
            $ast // RakuAST::Name.from-identifier($name)
        }
    }
    method trait-is2ast {
        my constant %mapping = "būvēts", "built", "kopija", "copy", "noklusējums", "default", "NOVECOJIS", "DEPRECATED", "ekviv", "equiv", "eksports", "export", "slēpts-no-izsekojuma", "hidden-from-backtrace", "slēpts-no-pamācības", "hidden-from-USAGE", "realizācijas-detaļa", "implementation-detail", "vaļīgāks", "looser", "mezglains", "nodal", "tīrs", "pure", "jēls", "raw", "lasīt-rakstīt", "rw", "testa-apgalvojums", "test-assertion", "ciešāks", "tighter";
        my $ast := self.ast;
        my $name := $ast ?? $ast.simple-identifier !! self.Str;
        if %mapping{$name} -> $original {
            RakuAST::Name.from-identifier($original)
        }
        else {
            $ast // RakuAST::Name.from-identifier($name)
        }
    }
    method adverb-pc2str (str $key) {
        my constant %mapping = "dzēs", "delete", "eksistē", "exists", "a", "k", "av", "kv", "pr", "p";
        %mapping{$key} // $key
    }
    method adverb-q2str (str $key) {
        $key
    }
    method adverb-rx2str (str $key) {
        my constant %mapping = "turpini", "continue", "izsm", "ex", "izsmeļoši", "exhaustive", "ais", "nd", "ais", "nth", "pār", "ov", "pārklāšanās", "overlap", "sprūds", "ratchet", "ais", "rd", "ais", "st", "līdz", "to", "reiz", "x";
        %mapping{$key} // $key
    }
    method named2str (str $key) {
        my constant %mapping = "absolūts", "absolute", "darbības", "actions", "pievienot", "append", "nokost", "chomp", "aizvērt", "close", "pilnībā", "completely", "turpināt", "continue", "skaits", "count", "izveidot", "create", "datums", "date", "diena", "day", "dzēst", "delete", "elementi", "elems", "kodējums", "encoding", "beigas", "end", "ik", "every", "izslēdzoši", "exclusive", "izsmeļoši", "exhaustive", "beidzas", "expires", "faila-vārds", "filename", "formatētājs", "formatter", "globāli", "global", "resursdators", "host", "stunda", "hour", "pēc", "in", "iekš", "into", "savienotājs", "joiner", "a", "k", "atslēga", "key", "av", "kv", "klausīties", "listen", "sakritība", "match", "sapludināt", "merge", "minūte", "minute", "režīms", "mode", "mēnesis", "month", "vārds", "name", "ais", "nd", "ais", "nth", "izsl", "off", "izvade", "out", "daļēji", "partial", "daļas", "parts", "ports", "port", "ais", "rd", "reāls", "real", "aizvietojums", "replacement", "lr", "rw", "sekunde", "second", "sekundes", "seconds", "izmērs", "size", "saspiest", "squash", "ais", "st", "statuss", "status", "apakšindekss", "subscript", "augšindekss", "superscript", "ais", "th", "reizes", "times", "laika-josla", "timezone", "nogriezt", "truncate", "vērtība", "value", "kur", "where", "reiz", "x", "gads", "year";
        %mapping{$key} // $key
    }
    method pragma2str (str $key) {
        my constant %mapping = "fatāli", "fatal", "bibliotēka", "lib", "stingri", "strict", "izsekošana", "trace";
        %mapping{$key} // $key
    }
    method system2str (str $key) {
        $key
    }
}

# The EXPORT sub that actually does the slanging
my sub EXPORT($dontslang?) {
    unless $dontslang {
        my $LANG := $*LANG;
        $LANG.define_slang('MAIN',
          $LANG.slang_grammar('MAIN').^mixin(L10N::LV)
        );
    }

    BEGIN Map.new
}

#- PLEASE DON'T CHANGE ANYTHING ABOVE THIS LINE
#- end of generated part of localization --------------------------------------

# vim: expandtab shiftwidth=4
