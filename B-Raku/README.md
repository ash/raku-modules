# B::Raku

A Raku-emitting backend for perl's own compiler.

```sh
bin/perl-to-raku program.pl > program.raku
rakupp program.raku
rakupp --exe program.raku -o program     # a native binary
```

## Why this shape

Only `perl` parses all of Perl — parsing it correctly requires running it
(`BEGIN` blocks and prototypes change how later code parses), so PPI and any
hand-written grammar are approximations. `B::Deparse` already walks the optree
and reconstructs high-level structure (loops, conditionals, declarations) from
`pushmark`/`padrange`/`aassign`; that reconstruction is the bulk of its 7086
lines and the part worth inheriting. `B::Raku` subclasses it and retargets only
the emission.

`compile()` borrows B::Deparse's driver and localises just the constructor,
rather than copying its 75-line body, so perl upgrades are less likely to break
us.

Output runs in fully-parenthesised mode (`parens => 1`). Nobody reads it — it
feeds a Raku engine — so paying in ugliness to make Perl-vs-Raku precedence
differences irrelevant is a good trade.

## What limits the override surface

Much of B::Deparse is plain subs, not methods: `elem`, `real_concat` and
`indirop` are called directly and **cannot be overridden**. Hooks exist only at
the `pp_*` layer and at the handful of genuine methods (`loop_common`, `dq`,
`do_multiconcat`, `keyword`).

The peephole optimiser also fuses ops, so the obvious hook often never fires.
Element access alone arrives in three shapes — `pp_aelem`, `pp_multideref`, and
`pp_aelemfast_lex` — all needing the same Raku rewrite. Concat arrives as
`pp_multiconcat`, not `pp_concat`. Expect to discover more of these by testing,
not by reading.

## Status

All 6 of the `raku++/showcase/perl/examples` convert to Raku that runs under
rakupp with output byte-identical to `perl` -- and all 6 then compile to native
binaries via `rakupp --exe` that are also byte-identical. Run them with
`RAKULIB` pointing at `../Perl5-Runtime/lib`.

Implemented: `.`/`.=` to `~`/`~=`; sigil invariance across all three element-op
shapes; `foreach my $x (LIST)` to `for LIST -> $x`; C-style `for` to `loop`;
comma before sort/grep/map lists; `$a`/`$b` to `$^a`/`$^b`; list `x` to `xx`;
`"@a"` to `"@a[]"`; `"${n}"` to `"$n"`; `scalar()` to `+()`; `?:` to `?? !!`;
`=~` to `~~`; Perl pragmas and the warning-bits preamble stripped; `*@_`
slurpies so arguments flatten; flattened `return`; and split via the runtime.

### Three divergences worth knowing

**Regexes are not translated at all.** They are emitted as `m:P5/.../` and
`s:P5[...][...]`, which take Perl 5 syntax directly. This matters more than it
sounds: `:` is Raku's ratchet metacharacter, so passing `/(\w+):\s*(\d+)/`
through verbatim does not error -- it silently matches something else. `m:P5`
works on both rakupp and Rakudo.

**Perl flattens, Raku does not.** `quicksort(@less)` arrives as one Array
element unless the sub is declared `(*@_)`, and a returned list nests unless
flattened. Both are handled, but `.flat` on return is also wrong for Perl
programs that return array *references* -- see the gaps below.

**Captures renumber.** Perl's `$1` is Raku's `$0`. Perl's `$0` (program name)
becomes `$*PROGRAM-NAME` so it does not collide.

## Known gaps

- **OO.** `$self->method` still emits Perl's arrow, and `bless` has no Raku
  target. Real OO support means mapping bless-based packages onto Raku classes;
  not started.
- **`local`.** Emitted verbatim; Raku has no equivalent spelling.
- **`.flat` on return over-flattens.** Perl's array *references* are Raku
  Arrays, which `.flat` will flatten and Perl would not. The general fix is
  modelling Perl references distinctly from Raku containers.
- **`split` in some assignment shapes** is not routed through `p5split`; the
  op is fused differently there and the `pp_split` hook does not fire.
- **Runtime shim is two subs.** `wantarray`, `local`, context propagation,
  `%.15g` stringification and Perl `sort`/`sprintf` semantics are still absent.
  This remains the bulk of the work and is independent of the front end.
- Single-pass string codegen: B::Deparse concatenates text and parents inspect
  children with regexes, so anything needing a second look at the whole tree
  has to be string surgery.
- Coverage is measured on six small programs. Larger samples break quickly.

## An engine bug this surfaced

rakupp drops trailing arguments when `return` is inside parens --
`sub g { (return (1,2), 9) }` yields `(1, 2)` where Rakudo yields
`((1, 2), 9)`. The unparenthesised form agrees. Since this backend emits fully
parenthesised code it hits the shape constantly; `pp_return` works around it by
wrapping the arguments explicitly.

## Constraints inherited from using perl as the front end

The program must **compile**, so every dependency including XS must be
installed on the converting machine. XS modules have no Raku target at all.
`BEGIN`-time effects and constant folding (`1 + 2` arrives as `3`) are already
baked into the optree.
