# Text::Diff::Native — design log

Why the module is shaped the way it is, and what running it on two engines
turned up. Kept outside `Text-Diff-Native/` on purpose: none of it is
documentation a user of the module needs, and nothing here ships in the
distribution.

The module's own [README](../Text-Diff-Native/README.md) says what it does.
This file says why.

## Why it exists at all

The ecosystem already has two: `Algorithm::Diff` (raku-community-modules), a
port of Perl's LCS module, and `Text::Diff` (zef:rbt) on top of it, which
formats unified, context and table diffs. They work on both engines. They
are also slow in a way that decides what they can be used for: `Text::Diff`
takes 0.2 s on a 1,000-line pair and 18 s on a 10,000-line pair under
Rakudo, a growth of ninety times for ten times the input. This module's
pure-Raku path takes 128 ms on the same 10,000 lines, and its extension
takes 4 ms.

A diff is the same shape of problem as JSON and CSV were: a tight inner loop
that is slow when interpreted and cheap in C, around linear bookkeeping that
Raku does well. So it takes the same pattern: C source compiled against
Raku++'s extension ABI at install time, and a Raku implementation of the same
procedure for everywhere else.

The name sits beside `Text::Diff` rather than inside it. It is not a new
version of that module and does not share its interface.

## The reference

Eugene W. Myers, *An O(ND) Difference Algorithm and Its Variations*,
Algorithmica 1 (1986), 251–266. The linear-space variant (the paper's
section 4b): search from both corners at once, one edit at a time, until the
two furthest-reaching paths overlap on a diagonal. That point lies on a
shortest path, so the problem splits there into two smaller ones. GNU diff,
git's xdiff and Google's diff-match-patch all use this algorithm. The
bookkeeping that keeps the search inside the grid (retiring a diagonal when
it runs off an edge instead of clamping every access) follows the shape of
diff-match-patch's `bisect`. It is written here from the description, not
ported.

**GNU's code was deliberately not consulted.** Its `diffseq.h` and
`analyze.c` are GPL, and this module is Artistic-2.0, so reproducing their
tie-breaking byte for byte is exactly what could not be done. That decides
what "correct" can mean for this module, below.

## What correct means here

There is no single right diff: two texts usually have many shortest edit
scripts. So the module promises two things it can check, and a third it
cannot promise:

- **Valid**: applying the script gives the new text. `t/01-diff.t` rebuilds
  both sides from every script; `against-gnu.raku` applies every unified
  diff with the system's `patch`.
- **Minimal**: no shorter script exists. `t/01-diff.t` compares the length
  with a brute-force LCS by dynamic programming on 300 random pairs;
  `against-gnu.raku` compares it with `diff --minimal` on thousands more.
- **The same as GNU**, which is not promised. It happens 79% of the time on
  random input with few distinct lines, the hardest case for this, and the
  README says so as a measurement. The goldens in `t/02-unified.t` are all
  cases where GNU's output was checked and matched, which is the most a
  golden can honestly claim.

Where several shortest scripts exist, a pure run of deletions or insertions
is slid down while its first line equals the line after it, so inserting a
repeated block reads as an insertion at its end. That is the convention diff
tools share. The slide never changes the length, so minimality survives it.

## Two implementations, one procedure

CSV::Native's pattern, one step stricter. There, the C and Raku parsers
implement one *specification*, and any two correct implementations of it
agree. Here, two correct implementations of "a shortest diff" can disagree
wherever there is a tie. So the parity promised is **the same script**: the
C file is the Raku one transcribed step for step, with the same names, the
same order of diagonals, the same tie-break (`vf[k-1] < vf[k+1]`), the same
split point and the same slide. The parity tests (300 random pairs of id
lists, 2,000- and 5,000-element inputs, 300 random texts through the whole
unified path) are what make "same" a fact.

The seam between the two is placed by cost:

- **`diff(@a, @b)`** numbers the elements in Raku (a hash of strings, which
  C cannot do for arbitrary Raku values) and hands two lists of integers to
  `diff-changes-native`.
- **`unified-diff`** hands two strings to `unified-diff-native`, which
  splits, numbers, searches, groups hunks and writes the text. The first
  version put only the search in C. Profiling the 100,000-line pair showed
  the search took 5 ms of 680: splitting took 300 and numbering 190, linear
  steps that are simply slow as interpreted loops. A native path that
  leaves 99% of its time in Raku is not a native path.

The answer crosses the boundary as a flat list of changed indices, not as
flags or ops: a 1% diff of 200,000 lines is 2,000 integers instead of
200,000.

## Two refinements, both measured

- **Discarding unmatched lines.** A line the other side does not contain at
  all cannot be in any common subsequence, so it is a change in every
  shortest script. Marking those first and searching only the rest keeps
  the answer minimal and shrinks D, since most edited lines are new lines.
  GNU does something similar. On this repository's corpus it removes only
  830 of 200,000 lines, because the generator repeats lines heavily. It
  stays because on real source edits it is most of D.
- **Clearing the search vectors lazily.** Every bisect call first set its
  whole vector to "not reached", which costs the subproblem's size even
  when the snakes meet at once. Counted on the 100,000-line pair: 1.6
  million assignments, as many as all the trimming scans together. Now each
  step clears only the two diagonals it brings into reach, and the overlap
  checks ignore anything beyond them. That is equivalent, because a
  diagonal outside that band cannot have been reached in this call.

With both in, the Raku path's remaining time on the large pair is the
linear trimming scans, about 1.8 million comparisons at roughly a
microsecond each as Raku loops. That is the price of interpreting a loop,
not of the algorithm, and it is what the extension is for.

## Lines

`diff` compares lines with their endings: `"x\r\n"`, `"x\n"` and a final
`"x"` are three different lines, and the unified format marks the last one
with `\ No newline at end of file`. A lone CR is content. The module follows
all of that, because a diff that disagrees with `patch` about what a line is
produces patches that do not apply.

Files are read with `.slurp(:bin).decode`, not `.slurp`. A text slurp turns
CRLF into LF on both engines (CSV::Native's log has the details), and a diff
must see the bytes that are there.

## What two engines turned up

- **CRLF is one grapheme, again.** On Rakudo `"a\r\n".ends-with("\n")` is
  False. The first `line()` asked only that, so every CRLF line got a `\ No
  newline at end of file` marker under Rakudo and none under Raku++. It now
  asks for both endings by name. This is the lesson in CSV::Native's log,
  learned a second time. The C side works on bytes and never had the
  problem, which is why the parity tests exist.
- **`"a\r\nb".split("\n")` splits on Raku++ and not on Rakudo**, for the
  same reason: Raku++ found the `\n` inside the grapheme, Rakudo did not.
  `split-lines` therefore splits CRLF out first, as CSV::Native does. Text
  with no CR in it, which is nearly all text, takes `lines(:!chomp)`
  instead, and that agrees on both engines. It is not used for text with a
  CR because it ends a line at a lone CR, which `diff` does not.
- **Two `loop (my int $k …)` in one block** compile on Raku++ and fail on
  Rakudo with a redeclaration: in Rakudo a `loop`'s declaration belongs to
  the enclosing block. The reverse search now uses `$r`, and loop indices
  shared across several loops are declared once, up front. As with
  CSV::Native's `csv-backend eq 'native'`: Raku++ is more lenient than
  Rakudo, so a Raku++-only test run cannot catch this class.
- **`*.WHAT.^name` does not curry.** `.map(*.WHAT.^name)` dies on both
  engines ("Cannot map a Array using 'Whatever'"): a metamethod call ends
  the WhateverCode. Written as a block. Not a divergence, just a trap.
- **NFC, three ways.** A file holding a decomposed `é` (`e` + U+0301)
  exposed the difference. Rakudo normalises to NFC when it decodes, so the
  diff names `é` as `c3 a9` and `patch` rejects it against the file's
  `65 cc 81`. Raku++ keeps the bytes on decode but normalises on
  concatenation (`"-" ~ $s` is NFC), so its Raku path fails the same way,
  one step later. Only the C path, which works on bytes throughout, writes
  a diff that applies. Since a Rakudo `Str` cannot hold non-NFC text at
  all, no `Str`-returning interface can fix this there. The README states
  it as a limitation and scopes a `Blob` interface for later. It also
  means the parity promise holds for NFC text, which the parity tests use.
  Raku++'s normalise-on-concatenation, but not on decode, is filed.
- **Speed.** Native `int` array loops cost about 0.8 µs an operation on
  Raku++ and about 0.3 µs on Rakudo, measured before writing the search, so
  the Raku path is slower on Raku++ (2.7 s against 1.7 s on 100,000
  lines). With the extension, Raku++ is faster than either Raku path by more
  than thirty times.

## Scope, and what comes next

- **A cost cap** is the obvious gap. GNU gives up on minimality when the
  search grows expensive and returns a longer diff. Without one, two
  unrelated files with few distinct lines are quadratic: 16 s for 6,000
  lines on Rakudo's Raku path. A `:fast` option, with a bound on D that
  parity would still hold both implementations to, is the next feature.
- **Applying a diff** is the other half of the job and a module of its own.
- **Whitespace and case options** fit in the numbering step (the key a line
  is numbered by), so they cost nothing in the search. They wait for a
  request.
- **Streaming** does not fit a diff: both texts are needed whole before the
  first hunk is known.
