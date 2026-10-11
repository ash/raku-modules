use Math::Wavelet::Filter;
use Math::Wavelet::DWT;
use Math::Wavelet::SWT;
use Math::Wavelet::DWT2;
use Math::Wavelet::Threshold;
use Math::Wavelet::Continuous;
use Math::Wavelet::CWT;

#| The wavelet of that name, or the one given: a Math::Wavelet::Filter for a
#| discrete wavelet, a Math::Wavelet::Continuous for a continuous one.
sub wavelet($w) {
    return $w if $w ~~ Math::Wavelet::Filter | Math::Wavelet::Continuous;
    Math::Wavelet::Continuous.is-continuous(~$w)
        ?? Math::Wavelet::Continuous.named(~$w)
        !! Math::Wavelet::DWT::as-wavelet($w)
}

#| The names of the built-in wavelets, optionally of one short family.
#| `:kind` is PyWavelets': 'all' (the default), 'discrete' or 'continuous'.
sub wavelist(Str $family?, Str :$kind = 'all' --> List) {
    die "kind must be 'all', 'discrete' or 'continuous'"
        unless $kind eq 'all' | 'discrete' | 'continuous';
    (|($kind ne 'continuous' ?? Math::Wavelet::Filter.list($family) !! ()),
     |($kind ne 'discrete' && (!$family.defined || $family (elem) Math::Wavelet::Continuous.families)
         ?? Math::Wavelet::Continuous.list($family) !! ())).List
}

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
        '&cwt' => &cwt, '&integrate-wavelet' => &integrate-wavelet,
        '&central-frequency' => &central-frequency,
        '&scale2frequency' => &scale2frequency, '&frequency2scale' => &frequency2scale,
    )
}
