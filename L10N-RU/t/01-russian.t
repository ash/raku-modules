use Test;
use experimental :rakuast;

# 'no-slangification' is the module's own escape hatch: it loads the two roles
# without mixing the slang into the grammar. Without it this file would have
# to be written in Russian to parse at all.
use L10N::RU 'no-slangification';
use RakuAST::Deparse::L10N::RU;

plan 16;

is L10N::RU.^name, 'L10N::RU',
  'the slang role is there';
is RakuAST::Deparse::L10N::RU.^name, 'RakuAST::Deparse::L10N::RU',
  'and so is the deparsing role';

# A slang IS a RakuAST grammar mixin, so an engine without RakuAST has nothing
# to mix it into. Str.AST is the narrowest thing to ask about: it is both the
# feature and the API every assertion below goes through.
unless Str.^can('AST') {
    skip 'no RakuAST on this engine, so there is no grammar to slang', 14;
    exit;
}

# Compile a fragment under the RU slang and run it. `use L10N::RU` would slang
# the rest of THIS file instead, which is not what a test wants.
sub ru($code) { $code.AST("RU").EVAL }

# Two engine capabilities the assertions below lean on, each probed with the
# smallest thing that shows it. Both are the engine's story rather than the
# module's, so what they gate is a `todo` and not a skip.

# Reaching a private attribute named outside the Latin script. Raku++ 3.28.0
# cannot, and fails the same way on that class written in plain English — the
# diacritics of, say, Latvian are fine there, Cyrillic is not.
my $non-latin-attributes = ?(try ru Q:to/КОД/);
класс Проба { имеет $.знач; метод дай() { $!знач } }
Проба.новый(знач => 1).дай;
КОД

# Honouring a localization when deparsing. Asked here of an English program,
# so nothing about the RU slang takes part in the answer.
my $localized-deparse =
  ((try Q[my $x = 1].AST.DEPARSE("RU")) // '').contains('мой');

is ru(Q:to/КОД/), 55, 'scope declarator, range, core sub';
мой @список = 1..10;
сумма @список;
КОД

is ru(Q:to/КОД/), [2, 4, 6], 'loop, statement modifier, infix word operators';
мой @отбор;
для 1..6 -> $н { @отбор.втолкни($н) если $н мод 2 равно 0 }
@отбор;
КОД

todo 'this engine cannot reach a private attribute named outside Latin script'
  unless $non-latin-attributes;
# `try`, because a `todo` assertion has to be allowed to fail: on an engine
# that cannot do this, the fragment throws rather than returning a wrong
# value.
is (try ru Q:to/КОД/), 15, 'class, attribute, trait, method, self';
класс Точка {
    имеет $.х это чтение-запись;
    метод подвинь($на) { $!х += $на; сам }
}
Точка.новый(х => 10).подвинь(5).х;
КОД

is ru(Q:to/КОД/), 'целое', 'given/when/default';
дано 42 {
    когда Str { "строка" }
    когда Int { "целое" }
    умолчание { "иное" }
}
КОД

is ru(Q:to/КОД/), [1, 4, 9, 16], 'gather/take';
собери { возьми $_ * $_ для 1..4 };
КОД

is ru(Q:to/КОД/), 'бах', 'try, die and a CATCH phaser';
мой $улов = '';
попробуй {
    умри "бах";
    ЛОВИ { умолчание { $улов = .message } }
}
$улов;
КОД

is ru(Q:to/КОД/), 3, 'ENTER phaser fires once per block entry';
мой $счет = 0;
для 1..3 { ВХОД { $счет++ } }
$счет;
КОД

is ru(Q:to/КОД/), 5, 'subset with a where constraint';
подмножество Положительное типа Int где * больше 0;
мой Положительное $п = 5;
$п;
КОД

is ru(Q:to/КОД/), 'зеленый', 'enum declaration';
перечисление Цвет <красный зеленый синий>;
Цвет::зеленый.ключ;
КОД

is ru(Q:to/КОД/), 'aa', 'repeat block with an until modifier';
мой $текст = '';
мой $н = 0;
повторяй { $текст ~= 'a'; $н++ } покане $н большеравно 2;
$текст;
КОД

is ru(Q:to/КОД/), True, 'boolean word operators and comparison';
3 меньше 5 и 5 большеравно 5 или Ложь;
КОД

is ru(Q:to/КОД/), 42, 'sub declaration and return';
функция удвой($х) { верни $х * 2 }
удвой(21);
КОД

# The deparser is the same translation table read the other way, so a program
# parsed as Russian comes back as Russian — and, asked for no localization,
# as the English it was compiled to.
my $ast := Q:to/КОД/.AST("RU");
мой @ч = 1..3;
для @ч -> $н { скажи $н }
КОД

todo 'this engine ignores the localization it is handed when deparsing'
  unless $localized-deparse;
like $ast.DEPARSE("RU"), /мой .* для .* скажи/,
  'deparsing back into Russian returns the Russian keywords';

like $ast.DEPARSE, /'my' .* 'for' .* 'say'/,
  'deparsing without a localization returns the English ones';

# vim: expandtab shiftwidth=4
