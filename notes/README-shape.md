# The shape of a README

How a distribution's README in this repository is put together, written down
once so the next module reuses it instead of rediscovering it. The sections are
the classic CPAN set — name, synopsis, description, author, licence — worn the
way this repo wears them: sentence-case Markdown headings, not POD capitals,
and nothing included empty just because the tradition names it.

A README says what the module does and how to use it; **why** it is shaped
that way, and what running it on two engines turned up, goes to
`notes/<Dist>.md`, outside the distribution. Keep the two apart: a user reads
the first, a maintainer the second.

## The order

1. **`# Module::Name`**, then a short paragraph saying what it is. It agrees
   with the `description` in `META6.json` — same claim, allowed more room.

2. **A status blockquote**: the version, how much of what follows is real
   ("the interface below is implemented and tested on both engines"), and a
   pointer to Scope for what is not. The reader learns in one line how much to
   trust the rest.

3. **The synopsis**: one complete, runnable example, immediately and with no
   heading — the code is the synopsis. Follow it with the command lines that
   run it under both engines whenever that is not obvious (`raku -I lib ...`,
   any environment knobs).

4. **Topic sections**, `##`-level, named for their subject — "The model",
   "Errors", "TLS", "Portability" — in whatever order the module's own logic
   suggests. Tables for enumerable facts (options, methods, defaults);
   explanation stays in the prose around them, not in the cells.

5. **Further examples are listed, not inlined**: the path under `examples/`
   and a sentence or two on what each shows. One synopsis is the code budget;
   the rest of the code lives in the files.

6. **`## Scope`**: what this version deliberately leaves out, so an absence
   reads as a decision rather than an oversight. Name what would carry a new
   dependency, and what is parked for a later version.

7. **`## Compatibility`**: a table of engine, version, and assertion counts
   from `t/` — counts from a run that actually happened, versions from the
   binaries that ran it. Say plainly whether a version is a **floor** ("the
   engine fixes this needs landed after X, and against that binary the suite
   fails") or merely the one tried ("not established floors — no older engine
   has been tried"). Engine quirks worth a warning go here, marked as the
   engine's story, not the module's.

8. **`## Author`**: name and fez authority — Andrew Shitov (`zef:ash`).

9. **`## Licence`** — spelled that way — with the identifier as the body:
   `Artistic-2.0.` It matches the `license` field in `META6.json` and the
   `LICENSE` file the distribution ships.

10. **A footer after `---`**, only when `notes/<Dist>.md` exists: one sentence
    saying the design log lives there, with the link.

## The habits

- Prose wraps at 78 columns, including around inline code; a paragraph pasted
  from elsewhere gets rewrapped.
- Every measurable claim is measured: test counts, versions, timings come from
  runs performed against the tree being described, and are updated in the same
  commit that changes what they measure.
- Bold carries the load-bearing sentence of a section — one per section at
  most.
- British "Licence" for the heading; the SPDX identifier for the body.
