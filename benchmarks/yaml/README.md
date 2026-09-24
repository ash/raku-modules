# YAML::Native benchmarks and conformance

The data behind the "Conformance" and "Measured" sections of
[YAML::Native's README](../../YAML-Native/README.md), so the numbers there can
be re-run rather than taken on trust. It lives outside the distribution on
purpose — an install from the ecosystem carries none of this.

| path | what | used for |
|---|---|---|
| `yaml-test-suite/` | the [yaml-test-suite](https://github.com/yaml/yaml-test-suite) data release `data-2022-01-17`: 402 cases, 94 of them invalid | the conformance table |
| `conformance.raku` | runs every case, and on Raku++ checks the two implementations against each other | the conformance table |
| `corpus-2000.yaml` | 2,000 documents, 1,743,998 bytes | the main timing table |
| `corpus-200.yaml` | 200 documents, 174,211 bytes | the second timing table |
| `gen.raku` | writes a corpus of any size | making the corpora |
| `bench.raku` | times reading and writing one corpus, with YAML::Native or YAMLish | the timing tables |

`yaml-test-suite/` is a copy, not a submodule: the release laid out as
upstream lays it out — one directory per case (some with numbered
sub-cases), holding `in.yaml`, the expected `test.event` stream, an `in.json`
where the data can be written as JSON, and an `error` file where the document
must be refused — with the suite's `License` (MIT) beside them. The `name/`
and `tags/` link directories of the release are left out.

The corpora are synthetic: `gen.raku` computes every value from the document
number, so they are reproducible byte for byte and contain nobody's data. Each
document is shaped like a Kubernetes manifest — a Deployment with nested block
mappings, sequences of mappings, flow collections, all three quoting styles, a
folded block scalar, integers, a float, booleans and a null; every tenth is a
ConfigMap with a literal block scalar, anchors, aliases and a merge key.

## Reproducing

Run from the distribution directory, so that `-Ilib` finds the module and, on
Raku++, the compiled extension in `resources/libraries/` is found next to it
(build it first with the Build hook, as CI does: `rakupp -I. -MBuild -e
'exit(Build.new.build($*CWD.Str) ?? 0 !! 1)'`). The conformance script needs
`JSON::Fast`, to read the suite's JSON.

```sh
cd YAML-Native

# conformance: pass counts, and on Raku++ with the extension the parity of
# the two implementations; --verbose lists every failure, and case ids
# after the options run just those cases
rakupp -Ilib ../benchmarks/yaml/conformance.raku
YAML_NATIVE_BACKEND=raku rakupp -Ilib ../benchmarks/yaml/conformance.raku
raku   -Ilib ../benchmarks/yaml/conformance.raku

# the timing tables: best of three, in milliseconds
rakupp -Ilib ../benchmarks/yaml/bench.raku ../benchmarks/yaml/corpus-2000.yaml
YAML_NATIVE_BACKEND=raku rakupp -Ilib ../benchmarks/yaml/bench.raku ../benchmarks/yaml/corpus-2000.yaml
raku   -Ilib ../benchmarks/yaml/bench.raku ../benchmarks/yaml/corpus-2000.yaml
raku   ../benchmarks/yaml/bench.raku --yamlish ../benchmarks/yaml/corpus-2000.yaml
```

(and the same with `corpus-200.yaml`). The `--yamlish` row needs
[YAMLish](https://raku.land/zef:leont/YAMLish) installed. To make a corpus of
another size, `raku gen.raku N` writes `corpus.yaml` with N documents into the
current directory.

`bench.raku` prints one line per run — engine, what answered, the document
count and the two timings — so a table is a matter of running it under each
engine.
