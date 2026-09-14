use Test;
use experimental :rakuast;

# 'no-slangification' is the module's own escape hatch: it loads the two roles
# without mixing the slang into the grammar. Without it this file would have
# to be written in Ukrainian to parse at all.
use L10N::UK 'no-slangification';
use RakuAST::Deparse::L10N::UK;

plan 16;

is L10N::UK.^name, 'L10N::UK',
  'the slang role is there';
is RakuAST::Deparse::L10N::UK.^name, 'RakuAST::Deparse::L10N::UK',
  'and so is the deparsing role';

# A slang IS a RakuAST grammar mixin, so an engine without RakuAST has nothing
# to mix it into. Str.AST is the narrowest thing to ask about: it is both the
# feature and the API every assertion below goes through.
unless Str.^can('AST') {
    skip 'no RakuAST on this engine, so there is no grammar to slang', 14;
    exit;
}

# Compile a fragment under the UK slang and run it. `use L10N::UK` would slang
# the rest of THIS file instead, which is not what a test wants.
sub uk($code) { $code.AST("UK").EVAL }

# Two engine capabilities the assertions below lean on, each probed with the
# smallest thing that shows it. Both are the engine's story rather than the
# module's, so what they gate is a `todo` and not a skip.

# Reaching a private attribute named outside the Latin script. Raku++
# cannot, and fails the same way on that class written in plain English — the
# diacritics of, say, Latvian are fine there, Cyrillic is not.
my $non-latin-attributes = ?(try uk Q:to/КОД/);
клас Проба { має $.знач; метод дай() { $!знач } }
Проба.новий(знач => 1).дай;
КОД

# Honouring a localization when deparsing. Asked here of an English program,
# so nothing about the UK slang takes part in the answer.
my $localized-deparse =
  ((try Q[my $x = 1].AST.DEPARSE("UK")) // '').contains('мій');

is uk(Q:to/КОД/), 55, 'scope declarator, range, core sub';
мій @список = 1..10;
сума @список;
КОД

is uk(Q:to/КОД/), [2, 4, 6], 'loop, statement modifier, infix word operators';
мій @відбір;
для 1..6 -> $ч { @відбір.заштовхни($ч) якщо $ч мод 2 рівне 0 }
@відбір;
КОД

todo 'this engine cannot reach a private attribute named outside Latin script'
  unless $non-latin-attributes;
# `try`, because a `todo` assertion has to be allowed to fail: on an engine
# that cannot do this, the fragment throws rather than returning a wrong
# value.
is (try uk Q:to/КОД/), 15, 'class, attribute, trait, method, self';
клас Точка {
    має $.х це читання-запис;
    метод посунь($на) { $!х += $на; сам }
}
Точка.новий(х => 10).посунь(5).х;
КОД

is uk(Q:to/КОД/), 'ціле', 'given/when/default';
дано 42 {
    коли Str { "рядок" }
    коли Int { "ціле" }
    замовчування { "інше" }
}
КОД

is uk(Q:to/КОД/), [1, 4, 9, 16], 'gather/take';
збери { візьми $_ * $_ для 1..4 };
КОД

is uk(Q:to/КОД/), 'бах', 'try, die and a CATCH phaser';
мій $улов = '';
спробуй {
    помри "бах";
    ЛОВИ { замовчування { $улов = .message } }
}
$улов;
КОД

is uk(Q:to/КОД/), 3, 'ENTER phaser fires once per block entry';
мій $лічильник = 0;
для 1..3 { ВХІД { $лічильник++ } }
$лічильник;
КОД

is uk(Q:to/КОД/), 5, 'subset with a where constraint';
підмножина Додатне типу Int де * більше 0;
мій Додатне $д = 5;
$д;
КОД

is uk(Q:to/КОД/), 'зелений', 'enum declaration';
перелік Колір <червоний зелений синій>;
Колір::зелений.ключ;
КОД

is uk(Q:to/КОД/), 'aa', 'repeat block with an until modifier';
мій $рядок = '';
мій $ч = 0;
повторюй { $рядок ~= 'a'; $ч++ } покине $ч більшерівне 2;
$рядок;
КОД

is uk(Q:to/КОД/), True, 'boolean word operators and comparison';
3 менше 5 і 5 більшерівне 5 або Хиба;
КОД

is uk(Q:to/КОД/), 42, 'sub declaration and return';
функція подвій($ч) { поверни $ч * 2 }
подвій(21);
КОД

# The deparser is the same translation table read the other way, so a program
# parsed as Ukrainian comes back as Ukrainian — and, asked for no
# localization, as the English it was compiled to.
my $ast := Q:to/КОД/.AST("UK");
мій @ч = 1..3;
для @ч -> $н { кажи $н }
КОД

todo 'this engine ignores the localization it is handed when deparsing'
  unless $localized-deparse;
like $ast.DEPARSE("UK"), /мій .* для .* кажи/,
  'deparsing back into Ukrainian returns the Ukrainian keywords';

like $ast.DEPARSE, /'my' .* 'for' .* 'say'/,
  'deparsing without a localization returns the English ones';

# vim: expandtab shiftwidth=4
