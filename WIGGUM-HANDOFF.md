# Epi Implementation Wiggum Handoff

Status: stopped at required implementation-worktree consent

Last updated: 2026-07-21

## Current implementation run

The active objective is to implement the approved first slice under the Wiggum
loop. No implementation file has been created: the frozen plan requires the
exact dependency preflight to pass before `epi.el` exists.

Completed in this run:

- Read the approved design, full executable plan, applicable repository
  instructions, and Wiggum/superpowers procedures.
- Drained and verified ten partner observations, then hardened the Task 1
  bootstrap, condition, event, facade, clock, option, selector, fixture, and
  file-manifest contracts discovered by independent follow-up reviews.
- Committed the single cleanup unit as
  `48100598ac24f5baf0702ec1c6eae3a463412fdb`
  (`Address partner review observations`).
- Re-ran `git diff --check`, both Pandoc GFM parses, task/file/commit/fence
  counts, the 51-option inventory, focused consistency checks, and two
  independent final reviews. The working tree and observation queue were clean
  immediately after that commit.

The following decision is required before Task 1 may begin:

1. The `using-git-worktrees` procedure requires explicit user consent before
   creating the isolated Epi worktree. If consent is granted without another
   location preference, the skill default is a project-local
   `.worktrees/epi-first-slice` on branch `codex/epi-first-slice`. Because no
   ignore file exists yet, `.worktrees/` must first be added to `.gitignore`
   and committed before creation.

One terminal integration decision is known but does not block Task 1: this
repository has no remote or upstream. The inherited parent instruction requires
a successful push at final completion (the “Landing the Plane” directive in
`/Users/johnw/src/dot-emacs/AGENTS.md`), while the Wiggum loop prohibits
pushing during intermediate work. Before final completion, a remote must be
supplied or that terminal push requirement explicitly waived for this nested
repo.

Locally verified inputs that do not require substitution:

- `EPI_EMACS=/nix/store/1jy6wkqyckvs10q661zvpaxx52g97206-emacs-mac-macport-with-packages-30.2.50/bin/emacs`
- `GPTEL_ROOT=/var/tmp/epi-gptel-8701e2bd` is a clean, detached, source-only
  worktree at `8701e2bd80c5d2091ce2decef5d34d6fce4a3ada`. Its three frozen
  source hashes match and no sibling `.elc` or `.eln` exists.
- `PI_ROOT=/var/tmp/epi-upstreams.AwS1tp/pi` is clean at
  `dd6bea41efa8caa7a10fe5a6401676dc5699f83f`; all five frozen source-anchor
  hashes match.
- `JCS_ORACLE_ROOT=/var/tmp/epi-jcs-oracle-20260721` is clean at
  `19d51d7fe467d4706a3ff08adf8a748f29fc21e0`; both JavaScript source hashes and
  the `823c07e7e1b1bbfc903354435b508026e43d2bf3183450a8773cf6cab7668933`
  vector-manifest digest match.
- `EPI_EXTRA_LOAD_PATH` may name the Transient and Compat directories under
  `/nix/store/chhmf76w149f1zps5nh1y9nlvsnl2w1b-emacs-packages-deps/share/emacs/site-lisp/elpa/`;
  the verified subdirectories are `transient-20260617.1137` and
  `compat-31.0.0.1`.

PAL consensus tooling was not advertised in this environment. Anvil is
available through a dedicated Emacs 30.2.50 daemon; its clean-buffer checks do
not certify a separate interactive Emacs process.

Task 1 will use all four available slots in staged waves: three isolated
scratch-output agents for preflight, runner, and package contracts or
implementation candidates, while the coordinator alone integrates shared
files, witnesses red/green gates, and owns Git. Three independent read-only
reviews run in the final Task 1 wave.

## Prior planning outcome

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

The current checkout remains branch `main`. It has no configured remote or
upstream. Feature implementation has not started here. The next implementation
workspace requires the worktree consent above; the final push requirement
remains unresolved rather than silently downgraded to a local integration
boundary.

## Implementation resume procedure

1. Obtain explicit worktree consent. If granted without another preference,
   add and commit the project-local `.worktrees/` ignore rule, then create
   `.worktrees/epi-first-slice` on `codex/epi-first-slice`. If declined, treat
   that as explicit authorization to work in the current checkout and run
   `git switch -c codex/epi-first-slice` before any implementation edit or
   commit; never implement directly on `main`.
2. Use the already verified detached GPTel, Pi, and JCS roots listed above. Do
   not delete the compiled files from the user's existing GPTel checkout.
3. Export the five preflight inputs through the existing environment. Do not
   install a dependency, enter `nix develop`, or substitute installed Pi.
4. Execute Task 1's two documented direct red contracts. Implement only the
   test harness/preflight machinery, then run `direnv exec . make preflight`.
   Stop before `epi.el` on any mismatch.
5. Continue tasks numerically, one TDD/review/commit unit at a time, with
   architecture checkpoints after Tasks 2, 6, 12, and 15.
6. Do not implement a later-slice roadmap capability without its own reviewed
   plan and capability gate.

## Stop-and-escalate counters

- Repeated failing gate signature: 0/3.
- Unusable output from any one reviewer: 0/2.
- Unresolved significant-decision consensus: 0/2.
- Current stop reason: first occurrence of required worktree consent; all exact
  preflight source inputs are present and no preflight attempt has been made.
- Terminal integration issue: no remote/upstream for the inherited push rule;
  this does not block local Task 1 work.
