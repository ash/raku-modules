# TOML::Native benchmarks and conformance

The data behind the "Conformance" and "Measured" sections of
[TOML::Native's README](../../TOML-Native/README.md), so the numbers there can
be re-run rather than taken on trust. It lives outside the distribution on
purpose — an install from the ecosystem carries none of this.

| path | what | used for |
|---|---|---|
| `toml-test/` | the TOML 1.0.0 cases of [toml-test](https://github.com/toml-lang/toml-test) at commit `ff49d10` (2026-09-15): 208 valid, 501 invalid | the conformance table |
| `conformance.raku` | runs every case, and on Raku++ checks the two implementations against each other | the conformance table |
| `corpus-10k.toml` | 10,000 packages, 2,038,318 bytes | the main timing table |
| `corpus-1k.toml` | 1,000 packages, 202,144 bytes | the second timing table |
| `gen.raku` | writes a corpus of any size | making the corpora |
| `bench.raku` | times `from-toml` and `to-toml` on one file | the timing tables |

`toml-test/` is a copy, not a submodule: the files that
`tests/files-toml-1.0.0` lists, laid out as upstream lays them out, with that
list and toml-test's `LICENSE` (MIT) beside them. A valid case is a `.toml`
with a `.json` in toml-test's tagged form (`{"type": "integer", "value":
"42"}`); an invalid case is a `.toml` alone.

The corpora are synthetic: `gen.raku` computes every value from the entry
number, so they are reproducible byte for byte and contain nobody's data. Each
`[[package]]` has a name, a version, a source and a 64-digit checksum; every
third has a `dependencies` array spanning lines; every hundredth has a
`[package.details]` table with a literal string, a float, a hex integer, an
inline table, a date and a multi-line string with escapes.

## Reproducing

Run from the distribution directory, so that `-Ilib` finds the module and, on
Raku++, the compiled extension in `resources/libraries/` is found next to it
(build it first with the Build hook, as CI does: `rakupp -I. -MBuild -e
'exit(Build.new.build($*CWD.Str) ?? 0 !! 1)'`). The conformance script needs
`JSON::Fast`, to read the tagged JSON.

```sh
cd TOML-Native

# conformance: pass counts, and on Raku++ with the extension the parity of
# the two implementations; --verbose lists every failure
rakupp -Ilib ../benchmarks/toml/conformance.raku
TOML_NATIVE_BACKEND=raku rakupp -Ilib ../benchmarks/toml/conformance.raku
raku   -Ilib ../benchmarks/toml/conformance.raku

# the timing tables: best of three, in milliseconds
rakupp -Ilib ../benchmarks/toml/bench.raku ../benchmarks/toml/corpus-10k.toml
TOML_NATIVE_BACKEND=raku rakupp -Ilib ../benchmarks/toml/bench.raku ../benchmarks/toml/corpus-10k.toml
raku   -Ilib ../benchmarks/toml/bench.raku ../benchmarks/toml/corpus-10k.toml
```

(and the same three with `corpus-1k.toml`). To make a corpus of another
size, `raku gen.raku N` writes `corpus.toml` with N packages into the current
directory.

`bench.raku` prints one line per run — engine, backend, package count and the
two timings — so a table is a matter of running it under each engine.
