use Math::Wavelet::Filter;
use Math::Wavelet::DWT;
use Math::Wavelet::SWT;
use Math::Wavelet::DWT2;
use Math::Wavelet::Threshold;

#| The wavelet of that name, or the one given.
sub wavelet($w --> Math::Wavelet::Filter) { Math::Wavelet::DWT::as-wavelet($w) }

#| The names of the built-in wavelets, optionally of one short family.
sub wavelist(Str $family? --> List) { Math::Wavelet::Filter.list($family) }

# `sub EXPORT` at file scope with no `unit module` above it: inside a package
# declaration Rakudo never runs EXPORT.
sub EXPORT {
    Map.new: (
        '&wavelet' => &wavelet, '&wavelist' => &wavelist,
        '&dwt' => &dwt, '&idwt' => &idwt,
        '&wavedec' => &wavedec, '&waverec' => &waverec,
        '&dwt-max-level' => &dwt-max-level, '&dwt-coeff-len' => &dwt-coeff-len,
        '&swt' => &swt, '&iswt' => &iswt, '&swt-max-level' => &swt-max-level,
        '&dwt2' => &dwt2, '&idwt2' => &idwt2,
        '&wavedec2' => &wavedec2, '&waverec2' => &waverec2,
        '&threshold' => &threshold, '&denoise' => &denoise,
        '&noise-sigma' => &noise-sigma,
    )
}
