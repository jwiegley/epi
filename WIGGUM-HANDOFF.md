# Epi Implementation-Plan Wiggum Handoff

Status: complete

Last updated: 2026-07-21

## Outcome

The approved Pi-grade Epi architecture now has a detailed, executable,
test-first implementation plan at
`docs/superpowers/plans/2026-07-21-epi-first-slice.md`. This work unit changes
documentation only; it does not implement Epi.

The plan covers the bounded first slice in Section 16 of
`docs/superpowers/specs/2026-07-21-epi-design.md` and the applicable Section
18, 20, and 21 gates. Section 17 remains a non-executable roadmap whose later
slices require separately reviewed plans. The original design commit is
`7a54b7ee69af74745423485d56a817b7308335e3`; partner-review cleanup is
`525aae291f19c1b3b23dc974eab376d17cd4e604`; the commit containing this handoff
also contains the review-driven design amendments and executable plan.

## Delivered artifacts

- `docs/superpowers/plans/2026-07-21-epi-first-slice.md`: 16 ordered tasks,
  each with an explicit file set, red test, implementation contract,
  verification command, and atomic commit boundary.
- `docs/superpowers/specs/2026-07-21-epi-design.md`: approved architecture plus
  the contract clarifications required by plan review.
- `WIGGUM-HANDOFF.md`: durable completion and implementation-resume boundary.

The plan freezes the record schema, append-only Org framing, canonical bytes,
structural and memory limits, lock and recovery identity, live-session
registry, runtime lifecycle, tool equality and terminality, callback contract,
GPTel capability seam, source-only pin verification, offline fixtures,
portable benchmark protocol, UI projections, exclusions, and Definition of
Done.

## Source baseline

- GPTel: commit `8701e2bd80c5d2091ce2decef5d34d6fce4a3ada`, package
  version `0.9.9.5`.
- Pi: commit `dd6bea41efa8caa7a10fe5a6401676dc5699f83f`.
- Official JCS oracle: commit
  `19d51d7fe467d4706a3ff08adf8a748f29fc21e0`, with the exact source and
  vector-manifest hashes recorded in the plan.

These sources were downloaded and inspected. Pi remains a behavioral oracle;
GPTel owns provider communication and semantic response handling; JCS is a
development-only canonicalization oracle.

## Review closure

The initial plan review and the requested deep-review pass were both completed.
All findings were repaired before this handoff, including:

- GPTel WAIT-handler preservation, raw safety attestation versus callback-time
  normalization, per-leg/request limits, and source-artifact pinning.
- Exact tool proposal/lifecycle/result equality, conservative terminal order,
  settlement callback semantics, and recovery registry exclusion.
- Bounded decoder/hash units, FIFO terminal reserve, rendering/reducer bounds,
  and cooperative work cursors.
- A benchmark protocol whose production source changes remain gated, fixture
  generation is outside measurement, adapter identity is pinned, and
  same-host versus cross-host outcomes fail closed correctly.
- Complete task dependencies, file/target inventories, recovery crash phases,
  and final verification ordering.

Final independent architecture/closure, performance, and consistency reviewers
all reported clean with no remaining actionable finding. No partner observation
file remains under `doc/observations/`.

## Verification evidence

The final documentation gate requires and has passed:

- Pandoc 3.7.0.2 parses both the design and plan as GitHub-flavored Markdown.
- `git diff --check` passes for tracked edits, and the staged diff check covers
  the newly added plan and handoff as well.
- The plan has exactly 16 task headings, 16 `Files` sections, 16 task commit
  commands, and balanced code fences.
- Placeholder scans find no unfinished plan marker.
- The Anvil-visible root Emacs session has no modified buffer visiting this
  repository before the final edit/commit checkpoints. This does not certify
  a separate interactive Emacs process.

No implementation ERT, compile, or GPTel compatibility test was run: there is
no implementation yet, the shell environment has no `emacs` executable, and
the dedicated Anvil daemon does not have GPTel on its load path. The plan makes
that an explicit fail-closed Task 1 preflight instead of installing or
substituting dependencies.

## Repository boundary

The branch is `main`. This repository has no configured remote or upstream, so
there is no honest fetch, rebase, push, or PR step. The final local commit is
the integration boundary for this work unit.

## Implementation resume procedure

1. Read the approved design, the executable plan, and this handoff.
2. Supply `EPI_EMACS`, `GPTEL_ROOT`, `PI_ROOT`, `JCS_ORACLE_ROOT`, and the
   declared Transient/Compat load paths through the existing environment.
3. Run `direnv exec . make preflight`; stop on any source, artifact, version,
   or path mismatch.
4. Execute Task 1, then continue numerically with
   `superpowers:subagent-driven-development` or
   `superpowers:executing-plans`, honoring the architecture checkpoints at
   Tasks 2, 6, 12, and 15.
5. Do not implement a later-slice capability from the roadmap without its own
   reviewed plan and capability gate.

## Stop-and-escalate counters

- Repeated failing gate signature: 0/3.
- Unusable output from any one reviewer: 0/2.
- Unresolved significant-decision consensus: 0/2.
