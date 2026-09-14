package B::Raku;

# A Raku-emitting backend for perl's own compiler.
#
# perl parses the program (the only parser that knows all of Perl); B::Deparse
# reconstructs high-level structure from the optree; this subclass retargets
# the emission to Raku source. The output is meant to be fed to a Raku engine,
# not read by a human -- so it runs in fully-parenthesised mode, which makes
# Perl-vs-Raku precedence differences irrelevant.

use strict;
use warnings;

require B::Deparse;
our @ISA = ('B::Deparse');
our $VERSION = '0.0.1';

# Captured before compile() localises the glob, so new() never recurses.
my $ORIG_NEW = \&B::Deparse::new;

sub new {
    my $class = shift;
    my $self = $ORIG_NEW->($class, @_);
    $self->{'parens'} = 1;    # emit ((a + b) * c) -- precedence becomes moot
    return $self;
}

# B::Deparse::compile hardcodes "B::Deparse->new", so we borrow the whole
# driver and redirect just the constructor. Cheaper and far less version-
# fragile than copying its 75-line body.
sub compile {
    my @args = @_;
    my $inner = B::Deparse::compile(@args);
    return sub {
        no warnings 'redefine';
        local *B::Deparse::new = sub { shift; B::Raku->new(@_) };
        # Capture rather than print, so there is one place for whole-program
        # passes -- currently just dropping Perl pragmas that mean nothing in
        # Raku and would send the engine looking for modules of that name.
        my $out = '';
        {
            open my $fh, '>', \$out or die $!;
            my $old = select $fh;
            eval { $inner->(); 1 } or do { my $e = $@; select $old; die $e };
            select $old;
        }
        $out =~ s/^\s*(?:use|no)\s+(?:strict|warnings|utf8|feature|vars|integer|bytes|PerlIO)\b[^;]*;\n//gm;
        $out =~ s/^\s*BEGIN \{\$\{\^WARNING_BITS\}.*\}\n//gm;
        print "use Perl5::Runtime;\n", $out;
    };
}

# ---------------------------------------------------------------- operators

# Perl's "." is Raku's "~"; ".=" is "~=". Body mirrors B::Deparse::real_concat,
# which is a plain sub (not a method) and so cannot be overridden in place.
sub pp_concat {
    my $self = shift;
    my ($op, $cx) = @_;
    my $left  = $op->first;
    my $right = $op->last;
    my $eq   = "";
    my $prec = 18;
    if (($op->flags & B::OPf_STACKED()) and !($op->private & 64)) { # OPpCONCAT_NESTED
        $eq   = "=";
        $prec = 7;
    }
    $left  = $self->deparse_binop_left($op, $left, $prec);
    $right = $self->deparse_binop_right($op, $right, $prec);
    return $self->maybe_parens("$left ~$eq $right", $cx, $prec);
}

# ------------------------------------------------------------ sigil invariance

# Perl varies the sigil with the access ($h{k} from %h); Raku keeps it (%h{k}).
# elem() is a plain sub in B::Deparse, so we post-process its text.
sub _resigil {
    my ($text, $sigil) = @_;
    return $text if $text =~ /^\$\{/;          # ${$ref}{k} -- leave for now
    $text =~ s/^\$(\w+(?:::\w+)*)->/\$$1/     # $r->{k}  => $r{k}   (deref)
        or $text =~ s/^\$(\w+(?:::\w+)*)([\[\{])/$sigil$1$2/;  # $h{k} => %h{k}
    return $text;
}

sub pp_helem { my $self = shift; _resigil($self->SUPER::pp_helem(@_), '%') }
sub pp_aelem { my $self = shift; _resigil($self->SUPER::pp_aelem(@_), '@') }

# ------------------------------------------------------------------ keywords

# keyword() is a genuine method with 59 call sites -- the cheapest central hook
# for renaming builtins that survive into Raku under another name.
my %KEYWORD = (
    'foreach' => 'for',
    'elsif'   => 'elsif',
    'undef'   => 'Nil',
);

sub keyword {
    my $self = shift;
    my $name = $_[0];
    my $out  = $self->SUPER::keyword(@_);
    return exists $KEYWORD{$out} ? $KEYWORD{$out} : $out;
}

# --------------------------------------------------------------------- loops

# loop_common is a real method, but its 120-line body reconstructs the whole
# loop; we let it run and rewrite only the head, which is always on one line.
sub loop_common {
    my $self = shift;
    my $text = $self->SUPER::loop_common(@_);

    # C-style "for (init; cond; step)" is Raku's "loop (init; cond; step)".
    return $text =~ s/\Afor \(/loop (/r if $text =~ /\Afor \([^;]*;/;

    # "for my $x (LIST)" is Raku's "for LIST -> $x".
    $text =~ s{
        \A (?:for|foreach) \s+ my \s+ (\$\w+) \s+
        (?<paren> \( (?: [^()]++ | (?&paren) )* \) ) \s*
    }{for $+{paren} -> $1 }x;

    return $text;
}

# ------------------------------------------------- block-taking list builtins

# Perl's sort/grep/map take a block with no comma; Raku wants one.
sub _comma_after_block {
    my ($text) = @_;
    $text =~ s{
        \A (sort|grep|map) (\s*\(\s*|\s+)
        (?<blk> \{ (?: [^{}]++ | (?&blk) )* \} ) [ ]+
    }{$1$2$+{blk}, }x;
    return $text;
}

sub pp_grepwhile { my $self = shift; _comma_after_block($self->SUPER::pp_grepwhile(@_)) }
sub pp_mapwhile  { my $self = shift; _comma_after_block($self->SUPER::pp_mapwhile(@_))  }

# Perl's sort block compares the globals $a/$b; Raku uses the placeholders
# $^a/$^b, which also give the block its two-parameter signature.
sub pp_sort {
    my $self = shift;
    my $text = _comma_after_block($self->SUPER::pp_sort(@_));
    $text =~ s{\A(sort\s*\(?\s*)(?<blk>\{(?:[^{}]++|(?&blk))*\})}
              { my ($h,$b) = ($1,$+{blk}); $b =~ s/\$([ab])\b/\$^$1/g; "$h$b" }xe;
    return $text;
}

# ------------------------------------------------- optimiser-fused op shapes

# The peephole optimiser fuses element access into multideref and concat
# chains into multiconcat, so the plain pp_helem/pp_concat hooks never fire
# for most real code. These two are where the work actually lands.

sub pp_multideref {
    my $self = shift;
    my $text = $self->SUPER::pp_multideref(@_);
    return _resigil($text, $text =~ /\[/ ? '@' : '%');
}

# Rewrite Perl's "." / ".=" outside string literals.
sub _concat_to_tilde {
    my ($text) = @_;
    my $out = '';
    while ($text =~ /\G( '(?:[^'\\]|\\.)*' | "(?:[^"\\]|\\.)*" | .[^'"]* )/gsx) {
        my $chunk = $1;
        $chunk =~ s/ \.= / ~= /g unless $chunk =~ /\A['"]/;
        $chunk =~ s/ \. / ~ /g   unless $chunk =~ /\A['"]/;
        $out .= $chunk;
    }
    return $out;
}

sub do_multiconcat {
    my $self = shift;
    return _raku_interp(_concat_to_tilde($self->SUPER::do_multiconcat(@_)));
}

# Perl overloads "x" for both string and list repetition; Raku splits them
# into "x" and "xx". OPpREPEAT_DOLIST tells us which one this is.
sub pp_repeat {
    my $self = shift;
    my ($op) = @_;
    my $text = $self->SUPER::pp_repeat(@_);
    $text =~ s/\) x / ) xx /
        if ($op->private & 64) and $text =~ /\A\(/;   # OPpREPEAT_DOLIST
    return $text;
}

# Raku does not interpolate a bare "@a" in a string; it needs "@a[]".
sub dq {
    my $self = shift;
    my $text = $self->SUPER::dq(@_);
    $text =~ s/\$\{(\w+)\}/\$$1/g;   # Raku reads "${n}" as a call to n()
    $text =~ s/(?<!\\)(\@\w+)(?![\[\{\w])/$1\[\]/g;
    return $text;
}

# A constant-index lexical array element is fused again, into aelemfast_lex.
# Three separate fused shapes reach the same Raku rewrite.
sub pp_aelemfast_lex { my $self = shift; _resigil($self->SUPER::pp_aelemfast_lex(@_), '@') }
sub pp_aelemfast     { my $self = shift; _resigil($self->SUPER::pp_aelemfast(@_),     '@') }

# multiconcat assembles the interpolated string itself, after dq() has run, and
# brace-protects variables: "${n}" -- which Raku reads as a call to n().
sub _raku_interp {
    my ($text) = @_;
    $text =~ s/\$\{(\w+)\}/\$$1/g;
    return $text;
}

# Raku has no scalar(); the numeric coercion "+(...)" is the direct equivalent.
sub pp_scalar {
    my $self = shift;
    my $text = $self->SUPER::pp_scalar(@_);
    $text =~ s/\Ascalar\s*(\(.*\))\z/+$1/s or $text =~ s/\Ascalar\s+(.*)\z/+($1)/s;
    return $text;
}

# ------------------------------------------------------ sub calls and returns

# Perl flattens every argument into @_; Raku does not, unless the slurpy is
# declared "*@". Without this, quicksort(@less) arrives as one Array element.
sub deparse_sub {
    my $self = shift;
    my $text = $self->SUPER::deparse_sub(@_);
    $text =~ s/\A(\s*)\{/$1(*\@_) \{/;
    return $text;
}

# In fully-parenthesised output "return" constantly gets the shape
# "return (X), Y" -- and in Raku a paren directly after a listop IS the whole
# argument list, so Y is silently dropped. Wrap the arguments explicitly.
sub pp_return {
    my $self = shift;
    my $text = $self->SUPER::pp_return(@_);
    # maybe_parens has already wrapped us in parens mode, so match both shapes.
    $text =~ s/\A\(return\s+(.*)\)\z/(return(($1).flat))/s
        or $text =~ s/\Areturn\s+(\S.*)\z/return(($1).flat)/s;
    return $text;
}

# ------------------------------------------------------------ runtime library

# Constructs whose Perl semantics have no direct Raku spelling are emitted as
# calls into Perl5::Runtime rather than open-coded, so there is one place to
# fix them. See that module for what each one is compensating for.

# Perl's split LIMIT of 0 means "unlimited"; Raku's means "zero pieces".
sub pp_split {
    my $self = shift;
    my $text = $self->SUPER::pp_split(@_);
    $text =~ s/\Asplit\(/p5split(/;
    return $text;
}

# -------------------------------------------------------------------- regexes

# Perl numbers captures from $1; Raku from $0. Perl's $0 (the program name) is
# a different variable entirely, so it has to move out of the way first.
sub pp_gvsv {
    my $self = shift;
    my $text = $self->SUPER::pp_gvsv(@_);
    return '$*PROGRAM-NAME' if $text eq '$0';
    $text =~ s/\A\$([1-9])\z/'$' . ($1 - 1)/e;
    return $text;
}

sub _raku_bind {
    my ($text) = @_;

    # Do not translate the pattern at all -- Raku's m:P5 adverb takes Perl 5
    # regex syntax directly. Without it every ":" in a pattern is read as
    # Raku's ratchet metacharacter and the match silently changes meaning.
    $text =~ s{ =~ (m?)/(.*)/([a-z]*)(\)*)\z}{ " ~~ m:P5" . _p5_adverbs($3) . "/$2/$4" }se;
    $text =~ s{ =~ s([\[\{(])}{ ~~ s:P5$1}g;

    $text =~ s{ =~ }{ ~~ }g;
    $text =~ s{ !~ }{ !~~ }g;
    return $text;
}

# Perl's trailing regex flags become Raku adverbs.
sub _p5_adverbs {
    my ($flags) = @_;
    my $out = '';
    $out .= ':g' if $flags =~ /g/;
    $out .= ':i' if $flags =~ /i/;
    $out .= ':m' if $flags =~ /m/;
    $out .= ':s' if $flags =~ /s/;
    return $out;
}

sub pp_match { my $self = shift; _raku_bind($self->SUPER::pp_match(@_)) }

sub pp_subst {
    my $self = shift;
    # No capture renumbering here: pp_gvsv already shifts $1..$9 as they are
    # emitted, including inside the replacement. Doing it again double-shifts.
    return _raku_bind($self->SUPER::pp_subst(@_));
}

# --------------------------------------------------------------------- ternary

# Raku spells the conditional operator "?? !!". Nested ternaries are already
# converted by their own pp_cond_expr call, so the first remaining " ? " and
# the " : " after it are always this level's.
sub pp_cond_expr {
    my $self = shift;
    my $text = $self->SUPER::pp_cond_expr(@_);
    if ($text =~ / \? /) {
        $text =~ s/ \? / ?? /;
        substr($text, $+[0]) =~ s/ : / !! /;
    }
    return $text;
}

1;
