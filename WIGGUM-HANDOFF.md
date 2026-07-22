# Epi Implementation Wiggum Handoff

Status: Tasks 1–3 complete; Task 4 is next; productization design awaits approval

Last updated: 2026-07-21

## Current implementation run

The active objective is to implement the approved first slice under the Wiggum
loop. Tasks 1–3 are complete on the isolated feature branch. The package
foundation, pinned GPTel seam, and canonical ledger codec are committed as
`89a3437`, `a5b6924`, and `813ea02`, respectively.

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
- Received explicit consent for the documented default isolated worktree,
  committed `.worktrees/` to `.gitignore` on `main` as
  `efc5ee1a6d41132e837c6c8f7c1daebf8fb35a31`, and created
  `.worktrees/epi-first-slice` on `codex/epi-first-slice` at that commit.
- Started Task 1 Wave A with isolated scratch agents drafting the preflight,
  runner, and package contracts while the coordinator alone owns integration,
  test gates, and Git.
- Completed the two required direct red contracts before creating the runner
  and package implementation, then passed the exact frozen dependency gate
  before creating `epi.el`.
- Hardened the validator after independent reviews: Make paths remain shell
  data, selector and gate inventories cannot be overridden, preflight's parent
  process never trusts GPTel or external package paths, the child hashes and
  evaluates one source snapshot, and unverified dependency/version shadows are
  inert.
- Completed the immutable event facade, exact options/errors/autoloads, JSON
  sentinels, canonical payload ownership, finite clocks, and injectable ID,
  wall-clock, deadline-clock, and yield seams.
- Committed Task 1 as `89a3437` (`build: establish the Epi package test
  foundation`). The branch was clean immediately after the commit.

Task 2 is committed as `a5b6924` (`test: prove the pinned GPTel adapter
contract`). Its 79 offline contract tests prove the exact pinned GPTel
delegation seam, including sequential multi-leg tools, raw attestation,
fail-stop behavior, private request ownership, exact outer-envelope
consumption, and continuation-exception terminality. An independent final
semantic review reran the complete suite and isolated adversarial probes and
reported no remaining blocker.

Task 3 is committed as `813ea02` (`feat: define the canonical Epi ledger
codec`). Its 153 codec tests prove the version-one JCS encoder, strict Org
framing, closed schema, ownership boundaries, resource caps, and physical
cooperative cadence. Two independent final reviews repeated the complete codec
suite, canonicalization oracles, golden verification, and work-slice probes on
byte-identical source and test hashes and reported no remaining finding.

Task 4, ledger loading and semantic validation, is the next implementation
frontier. All implementation changes remain in the isolated feature worktree;
`main` remains outside the implementation path.

The user also invoked `command-productize`. Read-only reconnaissance and
current-tool research are complete. The recommended integration point is after
Task 15 and before the final README/documentation task, so the productized
targets cover the complete delivered file set and the README remains the final
truth check. Productization implementation remains behind its required design
approval gate. The open choice is whether its 5% performance rule replaces
Task 15's existing matching-host elapsed/RSS thresholds or becomes a separate
short benchmark; replacing the existing thresholds with 1.05 times the frozen
five-process medians is the current recommendation.

One terminal integration decision is known but does not block intermediate
implementation: this repository has no remote or upstream. The inherited
parent instruction requires
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

Tasks 1–3 used staged parallel contract, implementation, and review lanes while
the coordinator owned integration, gates, and Git. Task 4 keeps that ownership
model and owns `epi-ledger.el`, the codec tests, and its corruption/torn-tail
fixtures. Productization remains a read-only design lane until approved and
must not contend for Task 4 files.

## Prior planning outcome

The approved Pi-grade Epi architecture now has a detailed, executable,
test-first implementation plan at
`docs/superpowers/plans/2026-07-21-epi-first-slice.md`. The planning unit was
documentation-only; implementation is now complete through Task 3.

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

The Task 3 implementation gate requires and has passed:

- The coordinator's final `make test` passed 288/288 tests in fresh Emacs
  processes: 79 GPTel contract, 153 ledger codec, 30 package, and 26 preflight.
- Warning-as-error compilation, Checkdoc over all three production files,
  source/test/generator parenthesis checks, clean loads, Pandoc parses, and
  staged/unstaged diff checks passed.
- Independent oracles passed 20,000 canonical numbers and 448,689 prefixes,
  1,000 composite objects and 41,356 prefixes, all 20 record schemas and 17,978
  frame prefixes, and 1,500 stable-sort cases, with zero failures.
- Two coordinator `make jcs-goldens` runs verified the shipped JCS vectors and
  left `independent-goldens.json` byte-identical at SHA-256
  `25edb6c8ad6d062841d3e30643149d2a61bf0709b887a06b8abecdb57a076b9d`.
- The final cadence reviewer reran 153/153 tests and 16 physical probes without
  observing work above a configured slice. The distinct correctness reviewer
  repeated the complete 288-test matrix, both golden checks, and all oracles.
- The sealed source SHA-256 is
  `57f6b44b82e5ce57956145f41f6f66d57728c5c973a2f432a796c5ab32788c88`;
  the sealed codec-test SHA-256 is
  `7595d5f38e2a6a3cc69f646a296d673d1402e8c4b7b16dfaef48cec8efa2d1a1`.

The Task 2 implementation gate requires and has passed:

- The complete offline adapter contract passes 79/79 tests against the pinned
  source-only GPTel checkout.
- Exact-EOF, exact choice-index, deep snapshot/dry-run ownership, two-leg
  mutation isolation, and throwing-continuation regressions pass both together
  and as five isolated adversarial tests.
- Direct probes observed zero stock parser or TOOL calls for rejected outer
  envelopes, unchanged `Hello` prompts in both transport legs after caller
  mutation, and exactly one redacted abort after a continuation exception.
- Warning-as-error compilation, Checkdoc over all three production files, and
  the 26/26 frozen-root preflight passed before final review.
- The final independent semantic reviewer reported clean at source SHA-256
  `987a69e8ddab5e9ecc871e929c498641048ab0edb39b64d406f484b928183f90`.

The Task 1 implementation gate requires and has passed:

- `make test`: 30/30 package tests and 26/26 preflight tests, each test file in
  a fresh Emacs process.
- A hostile command-line `TESTS`/`SELECTOR` override still ran all 26 preflight
  tests and printed `Validated frozen Epi dependencies`.
- `make compile`: warning-as-error byte compilation into `.build/elc` only.
- `make checkdoc`: Checkdoc passed for the sole production file.
- No source-tree `.elc`, injection sentinel, modified Anvil-visible buffer, or
  parse error remained.
- Two final focused trust-boundary re-reviews and one integrated Task 1 review
  reported clean after their findings were fixed and regression-tested.

The earlier documentation gate also passed:

- Pandoc 3.7.0.2 parses both the design and plan as GitHub-flavored Markdown.
- `git diff --check` passes for tracked edits, and the staged diff check covers
  the newly added plan and handoff as well.
- The plan has exactly 16 task headings, 16 `Files` sections, 16 task commit
  commands, and balanced code fences.
- Placeholder scans find no unfinished plan marker.
- The Anvil-visible root Emacs session has no modified buffer visiting this
  repository before the final edit/commit checkpoints. This does not certify
  a separate interactive Emacs process.

The pinned GPTel semantic adapter contract is implemented and committed. Its
source/runtime identity checks, WAIT/TOOL/post delegation, guarded Curl filter
and parser, abort/watchdog behavior, dry-run ownership, typed history, and
form-hash boundaries all pass the frozen offline contract.

## Repository boundary

The primary checkout remains clean on `main`. Feature implementation is in
`.worktrees/epi-first-slice` on `codex/epi-first-slice`, based on
`efc5ee1a6d41132e837c6c8f7c1daebf8fb35a31`. The repository has no configured
remote or upstream; the final push requirement remains unresolved rather than
silently downgraded to a local integration boundary.

## Implementation resume procedure

1. Work only in `.worktrees/epi-first-slice` on
   `codex/epi-first-slice`; never implement directly on `main`.
2. Use the already verified detached GPTel, Pi, and JCS roots listed above. Do
   not delete the compiled files from the user's existing GPTel checkout.
3. Export the five preflight inputs through the existing environment. Do not
   install a dependency, enter `nix develop`, or substitute installed Pi.
4. Start Task 4 test-first: add isolated corrupt/torn fixtures and red
   `epi-ledger-open` semantic-validation tests before extending the committed
   Task 3 codec.
5. Continue dependency-ready tasks numerically, one TDD/review/commit unit at
   a time, with architecture checkpoints after Tasks 2, 6, 12, and 15.
6. Complete the separately approved productization spec and plan before
   productization edits; integrate its implementation after Task 15 and before
   the final README task unless the approved design selects another boundary.
7. Do not implement a later-slice roadmap capability without its own reviewed
   plan and capability gate.

## Stop-and-escalate counters

- Repeated failing gate signature: 0/3.
- Maximum unusable outputs from any one reviewer: 1/2; each affected reviewer
  recovered after one neutral local-quality prompt.
- Unresolved significant-decision consensus: 0/2.
- Current stop reason: none. Tasks 1–3 are committed and Task 4 is next; all
  exact preflight source inputs remain present and validated.
- Terminal integration issue: no remote/upstream for the inherited push rule;
  this does not block local implementation work.
