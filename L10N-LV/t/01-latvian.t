use Test;
use experimental :rakuast;

# 'no-slangification' is the module's own escape hatch: it loads the two roles
# without mixing the slang into the grammar. Without it this file would have
# to be written in Latvian to parse at all.
use L10N::LV 'no-slangification';
use RakuAST::Deparse::L10N::LV;

plan 16;

is L10N::LV.^name, 'L10N::LV',
  'the slang role is there';
is RakuAST::Deparse::L10N::LV.^name, 'RakuAST::Deparse::L10N::LV',
  'and so is the deparsing role';

# A slang IS a RakuAST grammar mixin, so an engine without RakuAST has nothing
# to mix it into. Str.AST is the narrowest thing to ask about: it is both the
# feature and the API every assertion below goes through.
unless Str.^can('AST') {
    skip 'no RakuAST on this engine, so there is no grammar to slang', 14;
    exit;
}

# Compile a fragment under the LV slang and run it. `use L10N::LV` would slang
# the rest of THIS file instead, which is not what a test wants.
sub lv($code) { $code.AST("LV").EVAL }

# One engine capability the last assertions lean on, probed with the smallest
# thing that shows it: honouring a localization when deparsing. Asked here of
# an English program, so nothing about the LV slang takes part in the answer.
# It is the engine's story rather than the module's, so what it gates is a
# `todo` and not a skip.
my $localized-deparse =
  ((try Q[my $x = 1].AST.DEPARSE("LV")) // '').contains('mans');

is lv(Q:to/KODS/), 55, 'scope declarator, range, core sub';
mans @saraksts = 1..10;
summa @saraksts;
KODS

is lv(Q:to/KODS/), [2, 4, 6], 'loop, modifier, infix word operators';
mans @rezultāts;
katram 1..6 -> $s { @rezultāts.iebīdi($s) ja $s atlikums 2 vienāds 0 }
@rezultāts;
KODS

is lv(Q:to/KODS/), 15, 'class, attribute, trait, method, self';
klase Punkts {
    satur $.nobīde ir lasīt-rakstīt;
    metode pabīdi($par) { $!nobīde += $par; pats }
}
Punkts.jauns(nobīde => 10).pabīdi(5).nobīde;
KODS

is lv(Q:to/KODS/), 'vesels', 'given/when/default';
dots 42 {
    kad Str { "virkne" }
    kad Int { "vesels" }
    noklusējums { "cits" }
}
KODS

is lv(Q:to/KODS/), [1, 4, 9, 16], 'gather/take';
savāc { ņem $_ * $_ katram 1..4 };
KODS

is lv(Q:to/KODS/), 'bums', 'try, die and a CATCH phaser';
mans $noķerts = '';
mēģini {
    mirsti "bums";
    ĶER { noklusējums { $noķerts = .message } }
}
$noķerts;
KODS

is lv(Q:to/KODS/), 3, 'ENTER phaser fires once per block entry';
mans $skaits = 0;
katram 1..3 { IEEJA { $skaits++ } }
$skaits;
KODS

is lv(Q:to/KODS/), 5, 'subset with a where constraint';
apakškopa Pozitīvs no Int kur * lielāks 0;
mans Pozitīvs $p = 5;
$p;
KODS

is lv(Q:to/KODS/), 'zaļa', 'enum declaration';
uzskaitījums Krāsa <sarkana zaļa zila>;
Krāsa::zaļa.atslēga;
KODS

is lv(Q:to/KODS/), 'aa', 'repeat block with an until modifier';
mans $teksts = '';
mans $n = 0;
atkārto { $teksts ~= 'a'; $n++ } līdz $n lielākvienāds 2;
$teksts;
KODS

is lv(Q:to/KODS/), True, 'boolean word operators and comparison';
3 mazāks 5 un 5 lielākvienāds 5 vai Aplams;
KODS

is lv(Q:to/KODS/), 42, 'sub declaration and return';
funkcija dubulto($x) { atgriez $x * 2 }
dubulto(21);
KODS

# The deparser is the same translation table read the other way, so a program
# parsed as Latvian comes back as Latvian — and, asked for no localization,
# as the English it was compiled to.
my $ast := Q:to/KODS/.AST("LV");
mans @s = 1..3;
katram @s -> $n { saki $n }
KODS

todo 'this engine ignores the localization it is handed when deparsing'
  unless $localized-deparse;
like $ast.DEPARSE("LV"), /mans .* katram .* saki/,
  'deparsing back into Latvian returns the Latvian keywords';

like $ast.DEPARSE, /'my' .* 'for' .* 'say'/,
  'deparsing without a localization returns the English ones';

# vim: expandtab shiftwidth=4
