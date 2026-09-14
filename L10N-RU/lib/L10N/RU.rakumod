# This file contains the Russian Slang of the Raku Programming Language

#- start of generated part of localization ------------------------------------
#- Generated on 2026-09-14T15:52:10+02:00 by update-localization
#- PLEASE DON'T CHANGE ANYTHING BELOW THIS LINE

role L10N::RU {
    use experimental :rakuast;
    token block-default { умолчание}
    token block-else { иначе}
    token block-elsif { иначеесли}
    token block-for { для}
    token block-given { дано}
    token block-if { если}
    token block-loop { цикл}
    token block-orwith { илипри}
    token block-repeat { повторяй}
    token block-unless { еслине}
    token block-until { покане}
    token block-when { когда}
    token block-whenever { всякийраз}
    token block-while { пока}
    token block-with { при}
    token block-without { без}
    token constraint-where { где}
    token enum-BigEndian { BigEndian}
    token enum-Broken { Нарушено}
    token enum-False { Ложь}
    token enum-FileChanged { FileChanged}
    token enum-FileRenamed { FileRenamed}
    token enum-Kept { Исполнено}
    token enum-Less { Меньше}
    token enum-LittleEndian { LittleEndian}
    token enum-More { Больше}
    token enum-NativeEndian { NativeEndian}
    token enum-Planned { Запланировано}
    token enum-Same { Равно}
    token enum-SeekFromBeginning { SeekFromBeginning}
    token enum-SeekFromCurrent { SeekFromCurrent}
    token enum-SeekFromEnd { SeekFromEnd}
    token enum-True { Истина}
    token infix-pcontp { "(содержит)"}
    token infix-pelemp { "(элемент)"}
    token infix-cff { "^ff"}
    token infix-cffc { "^ff^"}
    token infix-cfff { "^fff"}
    token infix-cfffc { "^fff^"}
    token infix-after { после}
    token infix-and { и}
    token infix-andthen { изатем}
    token infix-before { до}
    token infix-but { но}
    token infix-cmp { сравни}
    token infix-coll { coll}
    token infix-div { дели}
    token infix-does { делает}
    token infix-eq { равно}
    token infix-ff { ff}
    token infix-ffc { "ff^"}
    token infix-fff { fff}
    token infix-fffc { "fff^"}
    token infix-gcd { gcd}
    token infix-ge { большеравно}
    token infix-gt { больше}
    token infix-lcm { lcm}
    token infix-le { меньшеравно}
    token infix-leg { мрб}
    token infix-lt { меньше}
    token infix-max { макс}
    token infix-min { мин}
    token infix-minmax { минмакс}
    token infix-mod { мод}
    token infix-ne { неравно}
    token infix-notandthen { неизатем}
    token infix-o { o}
    token infix-or { или}
    token infix-orelse { илииначе}
    token infix-unicmp { unicmp}
    token infix-x { x}
    token infix-X { X}
    token infix-xx { xx}
    token infix-Z { Z}
    token meta-R { R}
    token meta-X { X}
    token meta-Z { Z}
    token modifier-for { для}
    token modifier-given { дано}
    token modifier-if { если}
    token modifier-unless { еслине}
    token modifier-until { покане}
    token modifier-when { когда}
    token modifier-while { пока}
    token modifier-with { при}
    token modifier-without { без}
    token multi-multi { мульти}
    token multi-only { только}
    token multi-proto { прото}
    token package-class { класс}
    token package-grammar { грамматика}
    token package-module { модуль}
    token package-package { пакет}
    token package-role { роль}
    token phaser-BEGIN { BEGIN}
    token phaser-CATCH { ЛОВИ}
    token phaser-CHECK { CHECK}
    token phaser-CLOSE { ЗАКРЫТИЕ}
    token phaser-CONTROL { УПРАВЛЕНИЕ}
    token phaser-DOC { DOC}
    token phaser-END { КОНЕЦ}
    token phaser-ENTER { ВХОД}
    token phaser-FIRST { ПЕРВЫЙ}
    token phaser-INIT { INIT}
    token phaser-KEEP { УСПЕХ}
    token phaser-LAST { ПОСЛЕДНИЙ}
    token phaser-LEAVE { ВЫХОД}
    token phaser-NEXT { СЛЕДУЮЩИЙ}
    token phaser-POST { ПОСЛЕ}
    token phaser-PRE { ПЕРЕД}
    token phaser-QUIT { ОБРЫВ}
    token phaser-UNDO { ОТКАТ}
    token prefix-not { не}
    token prefix-so { так}
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
    token routine-method { метод}
    token routine-regex { регекс}
    token routine-rule { правило}
    token routine-sub { функция}
    token routine-submethod { субметод}
    token routine-token { лексема}
    token scope-anon { аноним}
    token scope-augment { дополни}
    token scope-constant { константа}
    token scope-has { имеет}
    token scope-HAS { ИМЕЕТ}
    token scope-my { мой}
    token scope-our { наш}
    token scope-state { состояние}
    token scope-unit { единица}
    token stmt-prefix-also { также}
    token stmt-prefix-do { выполни}
    token stmt-prefix-eager { жадно}
    token stmt-prefix-gather { собери}
    token stmt-prefix-hyper { гипер}
    token stmt-prefix-lazy { лениво}
    token stmt-prefix-quietly { тихо}
    token stmt-prefix-race { наперегонки}
    token stmt-prefix-react { реагируй}
    token stmt-prefix-sink { вникуда}
    token stmt-prefix-start { начни}
    token stmt-prefix-supply { поставляй}
    token stmt-prefix-try { попробуй}
    token term-nano { nano}
    token term-now { сейчас}
    token term-pi { pi}
    token term-rand { случайно}
    token term-self { сам}
    token term-tau { tau}
    token term-time { время}
    token traitmod-does { делает}
    token traitmod-handles { передает}
    token traitmod-hides { скрывает}
    token traitmod-is { это}
    token traitmod-of { типа}
    token traitmod-returns { возвращает}
    token traitmod-trusts { доверяет}
    token typer-enum { перечисление}
    token typer-subset { подмножество}
    token use-import { импортируй}
    token use-need { нужен}
    token use-no { отключи}
    token use-require { требуй}
    token use-use { используй}
    method core2ast {
        my constant %mapping = "все", "all", "антипара", "antipair", "антипары", "antipairs", "любой", "any", "добавь", "append", "дождись", "await", "мешок", "bag", "сдаюсь", "bail-out", "благослови", "bless", "умеет-ок", "can-ok", "категоризируй", "categorize", "потолок", "ceiling", "символов", "chars", "смени-каталог", "chdir", "отсеки-конец", "chomp", "отсеки", "chop", "всимвол", "chr", "всимволы", "chrs", "классифицируй", "classify", "закрой", "close", "сравни-ок", "cmp-ok", "кодов", "codes", "вычеши", "comb", "сочетания", "combinations", "содержит", "contains", "перекрест", "cross", "раскодируй", "decode", "определено", "defined", "диагностика", "diag", "умри", "die", "умирает-ок", "dies-ok", "каталог", "dir", "делает-ок", "does-ok", "готово", "done", "элементов", "elems", "испусти", "emit", "закодируй", "encode", "конец", "end", "заканчивается-на", "ends-with", "eval-умирает-ок", "eval-dies-ok", "eval-живет-ок", "eval-lives-ok", "выйди", "exit", "провались", "fail", "падает-как", "fails-like", "первый", "first", "плоский", "flat", "переверни", "flip", "пол", "floor", "незачет", "flunk", "получи", "get", "получи-символ", "getc", "суть", "gist", "отбери", "grep", "хеш", "hash", "голова", "head", "отступ", "indent", "индекс", "index", "индексы", "indices", "обрати", "invert", "это", "is", "это-примерно", "is-approx", "это-точно", "is-deeply", "простое", "is-prime", "типа-ок", "isa-ok", "нето", "isnt", "элемент", "item", "соедини", "join", "ключ", "key", "ключи", "keys", "кз", "kv", "прерви", "last", "строчные", "lc", "похоже", "like", "строки", "lines", "ссылка", "link", "список", "list", "живет-ок", "lives-ok", "сделай", "make", "отобрази", "map", "совпадение", "match", "макс", "max", "мин", "min", "минмакс", "minmax", "смесь", "mix", "создай-каталог", "mkdir", "перемести", "move", "новый", "new", "дальше", "next", "неок", "nok", "никакой", "none", "не", "not", "заметь", "note", "один", "one", "открой", "open", "вкод", "ord", "вкоды", "ords", "пара", "pair", "пары", "pairs", "зачет", "pass", "перестановки", "permutations", "выбери", "pick", "план", "plan", "вытолкни", "pop", "добавь-в-начало", "prepend", "печатай", "print", "печатайф", "printf", "продолжи", "proceed", "спроси", "prompt", "втолкни", "push", "выведи", "put", "случайное", "rand", "заново", "redo", "сверни", "reduce", "повторные", "repeated", "верни", "return", "верни-чз", "return-rw", "наоборот", "reverse", "риндекс", "rindex", "удали-каталог", "rmdir", "брось", "roll", "корни", "roots", "прокрути", "rotate", "округли", "round", "покругу", "roundrobin", "запусти", "run", "скажи", "say", "множество", "set", "оболочка", "shell", "сдвинь", "shift", "знак", "sign", "пропусти", "skip", "пропусти-все", "skip-rest", "спи", "sleep", "будильник", "sleep-timer", "спи-до", "sleep-until", "прочти", "slurp", "подсмотри", "snitch", "так", "so", "сортируй", "sort", "вклей", "splice", "раздели", "split", "сформатируй", "sprintf", "запиши", "spurt", "корень", "sqrt", "сожми", "squish", "зерно", "srand", "начинается-с", "starts-with", "замени", "subst", "подстрока", "substr", "подтест", "subtest", "преуспей", "succeed", "сумма", "sum", "симссылка", "symlink", "хвост", "tail", "возьми", "take", "возьми-чз", "take-rw", "бросает-как", "throws-like", "надо", "todo", "переведи", "trans", "обрежь", "trim", "обрежь-слева", "trim-leading", "обрежь-справа", "trim-trailing", "усеки", "truncate", "прописные", "uc", "уникальные", "unique", "непохоже", "unlike", "удали", "unlink", "вдвинь", "unshift", "используй-ок", "use-ok", "значение", "value", "значения", "values", "предупреди", "warn", "слова", "words", "молния", "zip";
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
        my constant %mapping = "построено", "built", "копия", "copy", "умолчание", "default", "УСТАРЕЛО", "DEPRECATED", "эквив", "equiv", "экспорт", "export", "скрыт-из-трассировки", "hidden-from-backtrace", "скрыт-из-справки", "hidden-from-USAGE", "деталь-реализации", "implementation-detail", "слабее", "looser", "узловой", "nodal", "чистый", "pure", "сырой", "raw", "чтение-запись", "rw", "тестовое-утверждение", "test-assertion", "сильнее", "tighter";
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
        my constant %mapping = "удали", "delete", "существует", "exists", "к", "k", "кз", "kv", "п", "p", "з", "v";
        %mapping{$key} // $key
    }
    method adverb-q2str (str $key) {
        $key
    }
    method adverb-rx2str (str $key) {
        my constant %mapping = "продолжи", "continue", "исч", "ex", "исчерпывающе", "exhaustive", "й", "nd", "й", "nth", "пер", "ov", "перекрытие", "overlap", "храповик", "ratchet", "й", "rd", "й", "st", "до", "to", "раз", "x";
        %mapping{$key} // $key
    }
    method named2str (str $key) {
        my constant %mapping = "абсолютный", "absolute", "действия", "actions", "добавить", "append", "отсечь", "chomp", "закрыть", "close", "полностью", "completely", "продолжить", "continue", "количество", "count", "создать", "create", "дата", "date", "день", "day", "удалить", "delete", "элементов", "elems", "кодировка", "encoding", "конец", "end", "каждые", "every", "исключая", "exclusive", "исчерпывающе", "exhaustive", "истекает", "expires", "имя-файла", "filename", "форматер", "formatter", "глобально", "global", "хост", "host", "час", "hour", "через", "in", "во", "into", "соединитель", "joiner", "к", "k", "ключ", "key", "кз", "kv", "слушать", "listen", "совпадение", "match", "слить", "merge", "минута", "minute", "режим", "mode", "месяц", "month", "имя", "name", "й", "nd", "й", "nth", "выкл", "off", "вывод", "out", "частично", "partial", "части", "parts", "порт", "port", "й", "rd", "реальный", "real", "замена", "replacement", "чз", "rw", "секунда", "second", "секунды", "seconds", "размер", "size", "сжать", "squash", "й", "st", "статус", "status", "нижний-индекс", "subscript", "верхний-индекс", "superscript", "й", "th", "разов", "times", "часовой-пояс", "timezone", "усечь", "truncate", "з", "v", "значение", "value", "где", "where", "раз", "x", "год", "year";
        %mapping{$key} // $key
    }
    method pragma2str (str $key) {
        my constant %mapping = "фатально", "fatal", "библиотека", "lib", "строго", "strict", "трассировка", "trace";
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
          $LANG.slang_grammar('MAIN').^mixin(L10N::RU)
        );
    }

    BEGIN Map.new
}

#- PLEASE DON'T CHANGE ANYTHING ABOVE THIS LINE
#- end of generated part of localization --------------------------------------

# vim: expandtab shiftwidth=4
