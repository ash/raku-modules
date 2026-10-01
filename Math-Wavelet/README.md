# Math::Wavelet

Discrete wavelet transforms in pure Raku: the single-level and multilevel
DWT, the stationary transform, the 2-D transform, thresholding and wavelet
denoising, over the 106 discrete wavelets PyWavelets has. It has no
dependencies and no native library, and agrees with PyWavelets to ten
significant digits.

> Version 0.0.1. The interface below is implemented and tested on both
> engines; what it leaves out is under Scope.

```raku
use Math::Wavelet;

my @x = (^64).map({ sin($_ / 4) + ($_ %% 3 ?? 0.1 !! -0.05) });

my ($cA, $cD) = dwt(@x, 'db4');                 # one level
my @y         = idwt($cA, $cD, 'db4');          # and back

my @c = wavedec(@x, 'sym5', :level(3));         # [cA3, cD3, cD2, cD1]
my @r = waverec(@c, 'sym5');
my @t = threshold(@c, 0.1, :mode<hard>);

my @clean = denoise(@x, 'db4');                 # VisuShrink, soft

my @image = (^8).map(-> $r { (^8).map({ $r * $_ }).Array });
my ($a, ($h, $v, $d)) = dwt2(@image, 'haar');   # an image is an array of rows
```

```bash
raku   -Ilib examples/denoise.raku
rakupp -Ilib examples/denoise.raku
```

## Install

Either installer takes it, into the same `~/.raku` store:

```bash
rakupp install Math::Wavelet
zef install Math::Wavelet
```

## The modules

`use Math::Wavelet` exports every routine below. The modules behind it can
also be used one at a time:

| module | what it is |
|---|---|
| `Math::Wavelet` | the one `use` line |
| `Math::Wavelet::Filter` | a wavelet: its four filters and what is known about it |
| `Math::Wavelet::DWT` | `dwt`, `idwt`, `wavedec`, `waverec` and the extension modes |
| `Math::Wavelet::SWT` | `swt`, `iswt` |
| `Math::Wavelet::DWT2` | `dwt2`, `idwt2`, `wavedec2`, `waverec2` |
| `Math::Wavelet::Threshold` | `threshold`, `noise-sigma`, `denoise` |
| `Math::Wavelet::Table` | the filter coefficients, generated from PyWavelets |

## Wavelets

A wavelet is given by name, or as a `Math::Wavelet::Filter`:

| family | names |
|---|---|
| Haar | `haar` |
| Daubechies | `db1` … `db38` |
| Symlets | `sym2` … `sym20` |
| Coiflets | `coif1` … `coif17` |
| Biorthogonal | `bior1.1` `bior1.3` `bior1.5` `bior2.2` `bior2.4` `bior2.6` `bior2.8` `bior3.1` `bior3.3` `bior3.5` `bior3.7` `bior3.9` `bior4.4` `bior5.5` `bior6.8` |
| Reverse biorthogonal | `rbio` with the same numbers |
| Discrete Meyer | `dmey` |

```raku
my $w = wavelet('sym4');
say $w.family;                     # Symlets
say $w.dec-len;                    # 8
say $w.vanishing-moments-psi;      # 4
say wavelist('coif').elems;        # 17
```

| method | |
|---|---|
| `.dec-lo` `.dec-hi` `.rec-lo` `.rec-hi` | the four filters |
| `.filter-bank` | the four as a list, in that order |
| `.dec-len`, `.rec-len` | filter length |
| `.name` `.family` `.short-family` `.symmetry` | |
| `.orthogonal`, `.biorthogonal` | |
| `.vanishing-moments-psi`, `.vanishing-moments-phi` | `0` where PyWavelets has none |
| `.scaled($k)` | a copy with every filter multiplied by `$k` |

A wavelet of your own is either the orthogonal filter bank that one lowpass
filter defines, or all four filters given explicitly:

```raku
my $own  = Math::Wavelet::Filter.from-lowpass(@dec-lo, :name<mine>);
my $bank = Math::Wavelet::Filter.new(:@dec-lo, :@dec-hi, :@rec-lo, :@rec-hi);
```

The coefficients are PyWavelets' own doubles, bit for bit. `dmey` is a
62-tap truncation of the Meyer filter, so it reconstructs only to within
about half a percent. The same is true in PyWavelets.

## The one-dimensional transform

| | |
|---|---|
| `dwt(@x, $w, :$mode)` | `(cA, cD)` |
| `idwt($cA, $cD, $w, :$mode)` | either half may be `Nil`, read as zeros |
| `wavedec(@x, $w, :$mode, :$level)` | `[cA_n, cD_n, …, cD_1]`; the level defaults to the maximum |
| `waverec(@coeffs, $w, :$mode)` | |
| `dwt-max-level($n, $w)` | the deepest useful level for `$n` samples |
| `dwt-coeff-len($n, $w, :$mode)` | the length of each half |

Every routine takes a name or a `Math::Wavelet::Filter` for `$w`, and returns
`Array`s of `Num`. Outside `periodization`, a level of `n` samples produces
`⌊(n + F − 1) / 2⌋` coefficients in each half for an `F`-tap filter, and the
inverse gives back `2·len − F + 2` samples. `waverec` drops the extra
trailing approximation coefficient that an odd length leaves, the same way
PyWavelets does.

## Signal extension

What the transform assumes lies beyond each end of the signal. The default is
`symmetric`.

| mode | extends `x0 x1 … xN` with |
|---|---|
| `zero` | `0 0 \| x0 … xN \| 0 0` |
| `constant` | `x0 x0 \| x0 … xN \| xN xN` |
| `symmetric` | `x1 x0 \| x0 … xN \| xN xN−1` |
| `reflect` | `x2 x1 \| x0 … xN \| xN−1 xN−2` |
| `periodic` | `xN−1 xN \| x0 … xN \| x0 x1` |
| `smooth` | the first and last slopes, continued |
| `antisymmetric` | `−x1 −x0 \| x0 … xN \| −xN −xN−1` |
| `antireflect` | `2x0 − x1 \| x0 … xN \| 2xN − xN−1` |
| `periodization` | periodic, with exactly `⌈n/2⌉` coefficients per half |

**`periodization` is the mode in which an orthogonal wavelet is an
orthogonal transform**: the coefficients carry exactly the signal's energy
and there are exactly as many of them as samples. Every other mode adds
`F − 2` coefficients per level for the boundary, or `F − 1` when the length
is odd.

## The stationary transform

The undecimated transform keeps every coefficient at every level, so it is
shift-invariant, at the cost of `n` coefficients per band per level.

| | |
|---|---|
| `swt(@x, $w, :$level, :$start-level, :$trim-approx, :$norm)` | `[[cA_n, cD_n], …, [cA_1, cD_1]]` |
| `iswt(@coeffs, $w, :$norm)` | from either output shape |
| `swt-max-level($n)` | how many times `$n` halves evenly |

`:trim-approx` returns `[cA_n, cD_n, …, cD_1]` instead. `:norm` scales the
filters by `1/√2`, which makes an orthogonal wavelet's transform preserve
energy. The length must be divisible by `2^(level + start-level)`.

## Two dimensions

An image is an array of rows. `dwt2` filters down the columns first, then
along the rows. That is PyWavelets' order, and it gives PyWavelets' band
names:

| | |
|---|---|
| `dwt2(@m, $w, :$mode)` | `(cA, (cH, cV, cD))` — horizontal, vertical, diagonal detail |
| `idwt2(($cA, ($cH, $cV, $cD)), $w, :$mode)` | any band may be `Nil` |
| `wavedec2(@m, $w, :$mode, :$level)` | `[cA_n, (cH_n, cV_n, cD_n), …, (cH_1, cV_1, cD_1)]` |
| `waverec2(@coeffs, $w, :$mode)` | |

## Thresholding and denoising

| | |
|---|---|
| `threshold(@x, $value, :$mode, :$substitute)` | element-wise, through nested arrays |
| `noise-sigma(@detail)` | `median(|d|) / 0.6745` |
| `denoise(@x, $w, :$level, :$mode, :$threshold, :$extension)` | |

The threshold modes are PyWavelets':

| mode | `x` becomes |
|---|---|
| `soft` (default) | `x·(1 − v/\|x\|)`, and `substitute` where `\|x\| < v` |
| `hard` | `x`, and `substitute` where `\|x\| < v` |
| `garrote` | `x·(1 − v²/x²)`, and `substitute` where `\|x\| < v` |
| `greater` | `x`, and `substitute` where `x < v` |
| `less` | `x`, and `substitute` where `x > v` |

`denoise` is VisuShrink. It estimates σ from the finest detail level,
thresholds every detail level at `σ·√(2 ln n)` (or at `:threshold`, if
given), leaves the approximation alone, and reconstructs `n` samples.
`:mode` is the threshold mode, and `:extension` the signal-extension mode.

## Examples

- `examples/denoise.raku` — a sine with a step, buried in noise, recovered
  with three wavelets, with σ estimated and the error before and after.
- `examples/compress.raku` — keeps the largest tenth of the coefficients and
  measures how much of the signal six wavelets keep with them.
- `examples/image.raku` — a two-level 2-D decomposition of a synthetic image
  with a horizontal and a vertical edge: where its energy goes, and which
  band sees which edge.

## Scope

Left out of 0.0.1 on purpose:

| | |
|---|---|
| the continuous transform | `cwt` and the continuous wavelets (Morlet, Mexican hat, Gaussian, …) |
| wavelet packets | the full decomposition tree, and best-basis selection |
| n-dimensional transforms | `dwtn` and `swt2`; 2-D is `dwt2` and `wavedec2` only |
| complex data | the transforms take real numbers |
| per-axis wavelets or modes | one wavelet and one mode for both axes of an image |

The stationary transform inverts only from start level 0, as in PyWavelets.

## Compatibility

| engine | version | `01-dwt` | `02-multilevel` | `03-swt` | `04-dwt2` | `05-threshold` | `06-wavelets` |
|---|---|---:|---:|---:|---:|---:|---:|
| Rakudo | v2026.09 | 1144/1144 | 534/534 | 136/136 | 74/74 | 41/41 | 228/228 |
| Raku++ | 5.1.0, a development build | 1144/1144 | 534/534 | 136/136 | 74/74 | 41/41 | 228/228 |

Neither version is an established floor; no older engine has been tried.
The expected values in `t/vectors` come from PyWavelets 1.8.0, through
`tools/gen-vectors.py`, and the filter table from the same version, through
`tools/gen-table.py`.

## Author

Andrew Shitov (`zef:ash`).

## Licence

Artistic-2.0.

---

Why the module is shaped this way, and what running it under two engines
turned up, is in [notes/Math-Wavelet.md](https://github.com/ash/raku-modules/blob/main/notes/Math-Wavelet.md).
