# Epi Implementation Wiggum Handoff

Status: Tasks 1–5 complete; Task 6 Waves 0–5 and Wave 6a.1 complete; halted cleanly before Wave 6a.2; productization remains at its approved later integration boundary

Last updated: 2026-07-23

## Current implementation run

The active objective is to implement the approved first slice under the Wiggum
loop. Work is paused at the user's explicit halt boundary. Tasks 1–5, Task 6
Waves 0–5, and Task 6 Wave 6a.1 are complete on the isolated feature
branch. The package foundation, pinned GPTel seam, canonical ledger codec,
semantic loader, private storage/append layer, tail inspector, recovery
semantics, deterministic reseal, closed recovery preparation, and private
object/ledger transfer, and transactional destination/quarantine publication
are committed
as `89a3437`, `a5b6924`, `813ea02`, `7125bfc`, `e14f9b2`, `0abdfe9`,
`a32cad6`, `bcad789`, `9caa866`, `7654e76`, and `501be5b`, respectively. The
separate Wave 2 and Wave 4 documentation checkpoints are `d49fcbd` and
`e574033`, respectively.

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

Task 4 is committed as
`7125bfc9d9e72e6295832f3029152c0c2aaa8456`
(`feat: validate Epi ledger structure and history`). It supplies the read-only
`epi-ledger-open` path, one-pass bounded cold validation, immutable checkpoint
publication, full hash/reference/lifecycle validation, precise
clean/truncated/interior-corrupt classification, and structured conditions.
The committed scope contains 72 isolated corrupt fixtures and five isolated
torn fixtures. Independent cursor, lifecycle, inertness, simplicity,
staged-plan, JSON-prefix, and post-commit reviews reported no remaining
blocker.

The implementation records two deliberate boundaries. Each retained
version-one header value has a fixed 1 MiB encoded-byte cap. Portable filename
reads use identity sandwiches and a final chain-head/identity check, but do not
claim adversarial rename-away/read/restore ABA resistance. `recovery-origin`
construction, provenance binding, and semantic admission remain a hard Task 6
prerequisite.

Task 5 is committed as
`e14f9b2d562cf0beb01aff97d4bc5bd7204da9a3`
(`feat: append Epi ledgers under an explicit lock`). It supplies private
creation, identity-bound locks and stale-lock recovery, verified single-batch
append, immutable content-addressed objects, and fail-closed publication and
cleanup races. All seven red/green waves and every additive review regression
are green. Three final reviewers approved the exact source/test snapshot; the
close gates passed 29/29 object tests, 130/130 ledger tests, 342/342 codec
tests, the full suite, warning-as-error compilation, Checkdoc, artifact and
process audits, and the Anvil unsaved-buffer check. Task 6 Waves 0–5 now supply
exact tail inspection, recovery provenance semantics, deterministic streaming
reseal, closed same-device preflight, verified bounded object inventory, and
exclusively published canonical `prepared` and `objects-transferred` manifests,
with exact private object and destination-ledger staging. Wave 5 additionally
publishes destination objects before the ledger and preserves the complete
original evidence through manifest-driven staging and quarantine. Wave 6a.1
adds the strict file-level restart converger at `84ea7d3`; Wave 6a.2, the
evidence-tree union converger, is next. All changes remain in the isolated
feature worktree; `main` remains outside the implementation path.

The user also invoked `command-productize`. Read-only reconnaissance and
current-tool research are complete. Productization integrates after Task 15
and before the final README/documentation task, so its targets cover the
complete delivered file set and the README remains the final truth check. Its
5% comparator is a separate short productization check and does not replace
Task 15's 2.0x elapsed and 1.5x RSS acceptance thresholds.

The user created the public GitHub destination during this run. `origin` is
`git@github.com:jwiegley/epi.git`; the 18 plan-derived issues carry the
`phase1` label, completed Tasks 1–5 are closed, Task 6 remains in progress,
and all issues are members of
the public linked project at `https://github.com/users/jwiegley/projects/7`.
The feature branch is published at `origin/codex/epi-first-slice`; subsequent
task checkpoints are pushed as they are committed so the GitHub issue and
project state can point to recoverable external artifacts.

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

Tasks 1–6 use staged parallel contract, implementation, and review lanes while
the coordinator owns integration, gates, and Git. Active Task 6 work owns only
`epi-ledger.el`, `test/epi-ledger-io-test.el`, and its recovery fixtures.
Productization remains at its later integration boundary and must not contend
for Task 6 files.

## Prior planning outcome

The approved Pi-grade Epi architecture now has a detailed, executable,
test-first implementation plan at
`docs/superpowers/plans/2026-07-21-epi-first-slice.md`. The planning unit was
documentation-only; implementation is now complete through Task 5 and Task 6
Wave 5.

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

The Task 4 implementation gate requires and has passed:

- The coordinator's final `make test` passed 477/477 tests in fresh Emacs
  processes: 79 GPTel contract, 342 ledger/JCS, 30 package, and 26 preflight;
  the post-repair run completed at 2026-07-22 04:57:48-0700.
- The complete ledger/JCS gate passed 342/342 tests, including 185
  `epi-ledger-open-*` contracts. The fixture manifest contains 72 corrupt and
  five torn artifacts, all byte-bound to deterministic builders.
- Warning-as-error `make compile` exited 0; `make checkdoc` passed all three
  production files; Anvil reported no source or test diagnostics; and the
  exact frozen-root preflight passed 26/26.
- The sealed `epi-ledger.el` SHA-256 is
  `9f9e2de56f909b03511b502e0d778a2766df4265e24900a22ef87c1de3c90f47`;
  the sealed codec-test SHA-256 is
  `0ef33d917e811dc70683cba5a4292e8c620309c7b43039ea24dbde10d1cfa500`;
  and the exact precommit staged-diff SHA-256 is
  `669adebf4ab2ab86e026017bd6bc308ff9bc92cd230015d12a118786c4cc7ddc`.
- Review found and repaired three publication-boundary defects before commit:
  yield callbacks could observe or mutate the carry buffer, multi-chunk indexed
  lookup could continue after finding its record, and impossible source-backed
  JSON prefixes could be misclassified as recoverable truncation. TDD
  regressions, the full gate, 333-prefix parity checks, large-fragment work
  probes, and an independent post-commit audit all passed afterward.
- The post-commit evidence audit also strengthened the previous-hash fixture
  to break only the fourth rolling link and gave the multi-chunk index test an
  independent exact-order oracle. The repaired fixture SHA-256 is
  `ce2e7c8ca80a799c74a020e40bb35d9bf7a4e0f1c4b2d63d1eef4c440c3fd1ac`;
  an independent re-audit approved both repairs before the amend.
- The earlier staged-plan audit returned PASS for its pre-repair candidate at
  report SHA-256
  `e9dc8b6f191f4f3e02ea5f2bece6e4b70c23ffdc7ac3df1f863c818f0c52fb2e`;
  it is retained as historical evidence, not as the final-candidate audit.
  The final post-repair audit is
  `docs/reviews/2026-07-22-task4-post-repair-audit.md`, SHA-256
  `cb0fcff2814251924d28d29b69d916657f11843bef99f3d73696ddd6163973e9`.

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

The primary checkout remains on `main`; its unrelated untracked
`pi-harness-for-emacs.md` is preserved and no feature implementation occurs
there. Feature implementation is in
`.worktrees/epi-first-slice` on `codex/epi-first-slice`, based on
`efc5ee1a6d41132e837c6c8f7c1daebf8fb35a31`. The repository now has the
public GitHub remote `origin` at `git@github.com:jwiegley/epi.git`; the feature
branch tracks `origin/codex/epi-first-slice` and is pushed at task checkpoints.

## Implementation resume procedure

1. Work only in `.worktrees/epi-first-slice` on
   `codex/epi-first-slice`; never implement directly on `main`.
2. Use the already verified detached GPTel, Pi, and JCS roots listed above. Do
   not delete the compiled files from the user's existing GPTel checkout.
3. Export the five preflight inputs through the existing environment. Do not
   install a dependency, enter `nix develop`, or substitute installed Pi.
4. Resume Task 6 at Wave 6a.2 test-first in its exact file scope. The
   file-level converger is already committed at `84ea7d3`; first implement the
   complete two-root evidence-tree census, union convergence, exact-empty
   source pruning, and final target proof. Feed it only the historical
   manifest `reachable_objects`; the current fragment object belongs to the
   recovered destination store and is not original quarantine evidence. Enter
   this tree helper only for durable `source_object_state = present`; the
   absent-source marker is a separate 6a.1 file transition integrated later.
   Then implement disk-only phase rehydration and
   source/destination lock reacquisition; then the seven-phase iterative resume
   loop and cleanup; finally add representative adversarial constructed states.
   Preserve Waves 0–5 and Task 5 storage/locking behavior as the regression
   baseline. Task 6 owns production reconciliation across every durable phase
   with representative pre-action/post-action states. Task 15 owns actual
   worker-process deaths, exhaustive first/middle/last interruption
   permutations and repetitions, and census scale/counter acceptance.
5. Continue dependency-ready tasks numerically, one TDD/review/commit unit at
   a time, with architecture checkpoints after Tasks 2, 6, 12, and 15.
6. Complete the separately approved productization spec and plan before
   productization edits; integrate its implementation after Task 15 and before
   the final README task unless the approved design selects another boundary.
7. Do not implement a later-slice roadmap capability without its own reviewed
   plan and capability gate.

Task 5 completion facts:

- The implementation brief is `/var/tmp/epi-wg-task5/execution-brief.md`
  (SHA-256
  `d0780cf8dc5ac3a53dc6c3ee1fdd30145c4739096f9b6466b16af80c5af2570b`).
  Its seven ordered red/green waves are authoritative for the task.
- All seven waves are integrated, red/green proven, and independently
  approved. The final source SHA-256 is
  `8e0bbf76d5079370eaa7a7edecdc8325d5f460942425053171560091b936d3ac`;
  the final test SHA-256 is
  `21ca8d9ae6e8d97bd2b493c573df4a4908d07cbc41771ee50f7cc8794b098031`.
  Wave 5's frozen artifact is
  `/var/tmp/epi-wg-task5-wave5/wave5-tests.el` at SHA-256
  `76450ec8f71409fe3bb0dc451b623be406251c0effe9e27a03e0da1ac9ee4015`;
  Wave 6's is `/var/tmp/epi-wg-task5-wave6/wave6-tests.el` at SHA-256
  `2745503fc92255842cfeb21c3c3c724ccfb54b737dd2ce54e5977e9d4b27c0e4`.
- The exact close sequence passed: ledger 130/130, codec 342/342 with
  independent JCS goldens current, full `make test` exit 0, compile, Checkdoc,
  `git diff --check`, artifact/process audit, and Anvil buffer-state check.
  GitHub issue `jwiegley/epi#5` records this evidence and is closed.
- Creation publishes with `add-name-to-file` and `OK-IF-ALREADY-EXISTS` nil:
  a same-directory hard link is the atomic no-clobber publication point, after
  which Epi unlinks its owned source name. A postpublication unlink failure
  may leave two complete names and reports `storage-publication-failed` with
  `:published t`; filesystems without hard-link support fail before
  publication. Stale-lock archival uses the same link-then-unlink rule.
- Reuse Task 4's immutable checkpoint and private checkpoint cell only to
  publish a verified append result as one replacement. Add the smallest
  successor operations required by Task 5; do not restore the deleted
  speculative clone/advance/publish/uncertain prototype cluster.
- Keep every write behind the private no-conversion local-byte writer and the
  explicit Epi lock. Update in-memory state only after suffix readback, chain
  validation, and file identity/head verification.
- Treat nil `process-attributes` as indeterminate unless a supported local
  `list-system-processes` snapshot omits the PID. Bind both process probes to
  the canonical local ledger parent through `default-directory`.
- Preserve exact preexisting bytes. A losing writer or pre-write failure writes
  nothing; uncertain post-write failure forces cold validation before another
  append.
- Task 6 may now reuse create, lock/stale-lock recovery, batched append, and
  object put/get/presence. It must add tail recovery, quarantine, recovery
  manifests, and `recovery-origin` semantics without weakening their Task 5
  authority and cleanup contracts.
- Retain the frozen GPTel, Pi, JCS, Emacs, Transient, and Compat roots for Task
  6 and all later offline gates.

Task 6 progress facts:

- The frozen execution brief is `/var/tmp/epi-wg-task6/execution-brief.md`,
  SHA-256
  `c5987f2be636047d21b89aca1627b8706afb6679e9122d87cbe36a14cc9a04c9`.
  Its eight ordered waves and collision, manifest, quarantine, and publication
  decisions remain authoritative.
- Wave 0 is `0abdfe9` (`feat: inspect recoverable Epi ledger tails safely`).
  Wave 1 is `a32cad6` (`feat: validate Epi recovery provenance semantics`).
  Wave 2 is `bcad789` (`feat: stream deterministic Epi recovery reseals`).
  Its documentation checkpoint is
  `d49fcbd30f12df6df16dc263bb2507e241f3c262` (`docs: record Task 6 reseal
  checkpoint`). Wave 3 is
  `9caa86605b1aa19afc1af86f0900d20ce6400c85` (`feat: prepare torn-tail
  recovery manifests`).
- Wave 2 closes caller ownership before cooperative validation, preflights the
  complete copied proof chain before output, rejects malformed or cyclic
  private inspection graphs with structured conditions, preserves every
  source semantic field except the first session identity, and emits one
  presealed recovery-origin after the verified streaming prefix.
- The exact Wave 2 close sequence passed 62/62 recovery tests and 192/192 I/O
  tests. Warning-as-error compilation, Checkdoc, staged and unstaged diff
  checks, the 10,000-proof constant-stack regression, and independent final
  correctness and simplicity reviews also passed. GitHub issue
  `jwiegley/epi#6` records the wave evidence and remains in progress.
- Wave 3 adds closed same-device path and collision preflight, deterministic
  staging layout, a typed sorted historical-object inventory under the fixed
  256-entry v1 ceiling, fragment evidence, and exclusive durable publication
  of canonical `manifest.jcs` in phase `prepared` under the source lock. Its
  closing authentication pass independently replays the source proof so a
  forged non-final destination proof cannot enter durable state. No fixture
  file changed.
- The exact Wave 3 close sequence passed 153/153 recovery tests and 283/283 I/O
  tests. Warning-as-error compilation, Checkdoc, parenthesis checks, and
  `git diff --check` passed; the focused independent P1 review reported no
  blocker. The committed source SHA-256 is
  `cc3aaaed3067b0a5e29103b18b59b750868c60505b4fa760b2e9dd52301af547`;
  the committed test SHA-256 is
  `5d66c7d9d7690be2194376420cae8459a83f8402c88dabe017d73c4d2c6ab933`.
- Wave 4 is
  `7654e7603ff8d1fa6c0a1049df7435b1b9c28506`
  (`feat: transfer Epi recovery objects under lock`). It extracts only typed
  references from complete records, deduplicates and sorts the bounded object
  set, stages every verified historical object plus the exact fragment, and
  streams a cold-verified destination ledger under its hidden manifest-bound
  name. It advances only from `prepared` to `objects-transferred`, executes the
  durable phase barrier while the source lock is held, and leaves every Wave 5
  publication and quarantine name absent.
- Wave 4's callback authority is lexical: documented storage/lock callbacks
  see no cleanup receipt capability, every received lock/directory/file proof
  is copied and raw-revalidated before adoption, decoded lock-token bytes must
  agree with both the source proof and receipt slots, and helper return graphs
  are consistency checks rather than cleanup authority. Exact-old manifest
  classification, rollback, and immediate prepared-state reclosure share one
  automatic-GC-free, callback-free epoch.
- The exact Wave 4 close sequence passed 240/240 recovery tests in 937.725
  seconds, 370/370 ledger-I/O tests in 940.861 seconds, and 342/342 codec/JCS
  tests in 410.452 seconds. The fresh-process `make test` matrix passed GPTel
  79/79, codec/JCS 342/342 with independent goldens current, ledger-I/O
  370/370, package 30/30, and preflight 26/26. Warning-as-error compilation,
  Checkdoc, explicit preflight 26/26, Anvil parenthesis and buffer-state checks,
  `git diff --check`, and the stray artifact/process audit also passed.
- The committed Wave 4 source SHA-256 is
  `d9f48b5ab4faf2181c403a3fb2562e70dad8807f303656afd624a080833bb436`;
  the committed test SHA-256 is
  `c778d7697caca91795655eb92d282e707c9e8a3be592900c7ca5667cc361f751`.
  Independent production-correctness, mutation-sensitive test, and frozen
  scope reviews are recorded under `/var/tmp/wg-epi-wave4-candidate-*`; all
  reported ready after their findings were fixed and rerun.
- The post-commit fess audit found no Wave 4 behavioral blocker. It identified
  post-create/pre-receipt process-death convergence as explicit Wave 6
  verification debt; that crash window is not represented as solved here. Its
  two P3 test-truth findings were fixed, and both exact selectors passed 1/1.
- Wave 5 is
  `501be5b77d414a7dc0ae8f0edbd8d7e8947ff704`
  (`feat: publish recovered Epi evidence safely`). It publishes the verified
  destination object tree before the destination ledger, preserves the
  complete original ledger and object tree through two same-device
  no-clobber hard-link hops, publishes `complete.jcs` last, and advances the
  durable manifest through `quarantine-published`. Source and destination lock
  generations remain authenticated in the frozen order through final closure.
- The reachable-object ceiling remains 256, independently of the complete
  quarantine-evidence census. The live census uses a process-local handle and
  ordered proof vectors of at most 256 leaves. That chunk bound is not a claim
  of bounded total enumeration memory: Phase 1 may materialize and
  comparison-sort one complete prefix directory, while Task 15 owns scale
  instrumentation and optimization. Ordinary GC remains enabled during full
  content walks; only `post-gc-hook` is suppressed around authority epochs.
- The exact Wave 5 close sequence passed 496/496 ledger tests in three parallel
  shards (798.648048, 739.519616, and 660.760743 seconds), 342/342 codec/JCS
  tests in 440.644335 seconds, GPTel 79/79, package 30/30, and preflight 26/26.
  Warning-as-error compilation, Checkdoc over three production files,
  parenthesis, diff, and Pandoc gates also passed. Independent correctness,
  test, resource, and frozen-scope reviews reported no remaining blocker after
  the automatic-GC wrapper regression was fixed and the unsupported strict
  linear-census claim was withdrawn.
- The committed Wave 5 source SHA-256 is
  `481a04c6dd9307e721ed9f73a329bb26ef392299143f80d6f8608590b5b93fa0`;
  the committed test SHA-256 is
  `94bd4ad0e4a5e69b42b26e5c97d6b31ac1a1bff2ed214089d61c20beb040868b`.
  The commit is published at `origin/codex/epi-first-slice`.
- Wave 6a.1 is
  `84ea7d37d8bb2034e2e448b5187ff213534ad788`
  (`feat: reconcile interrupted Epi file moves`). It handles source-only,
  exact same-inode dual-name, and target-only file states; rejects conflicting
  inodes, extra links, wrong mode/device, both-absent state, and verifier or
  closure drift; and preserves a mutation-free repeated target-only call. Its
  focused 8/8 selector, adjacent 7/7 legacy mover selector, linked-verifier
  selector, warning-as-error compilation, Checkdoc, parenthesis, diff, and
  independent final review passed. The commit is pushed and the worktree is
  clean.
- Wave 6a.2 is the next boundary. No Wave 6a.2 test or production edit exists
  at this halt. Read-only design work froze the following contract: preflight
  and authenticate both roots before mutation; admit source-only, target-only,
  and exact same-inode dual leaves; preserve the complete valid union including
  unreachable leaves and empty topology; require every persisted historical
  reachable object; converge leaves through the 6a.1 helper; prove the final
  target; prune only captured exact-empty source directories bottom-up; and
  make a repeated target-only invocation mutation-free. Debris, distinct
  inodes for one canonical hash, missing required reachable objects, replaced
  roots, or closure drift must fail without mutation.
- Task 6 must implement production restart
  reconciliation for every durable phase and prove representative constructed
  pre-action/post-action states, including split roots and the
  post-link/pre-unlink case. Task 15 retains actual worker-process deaths,
  exhaustive first/middle/last interruption permutations and repetitions, and
  census scale/counter acceptance.
- Version one persists the required reachable-object set but not the complete
  unreachable-evidence census. Fresh re-entry must find every persisted
  reachable leaf, authenticate every present union leaf, and preserve valid
  unreachable union members; it cannot prove that an unreachable leaf is
  missing from both roots. Persisting that stronger proof would be a later
  schema capability, not Task 6 work.

## Halt checkpoint — 2026-07-23 15:51 PDT

- The user requested `command-halt`; all Wave 6a.2 parallel workers were
  interrupted immediately. They made no shared-worktree edits.
- The exact implementation tip at halt is
  `84ea7d37d8bb2034e2e448b5187ff213534ad788`, identical to
  `origin/codex/epi-first-slice` before this documentation checkpoint.
- No implementation test was running and no untracked implementation artifact
  remained. The only new work after `84ea7d3` is this durable halt
  documentation and the external remaining-scope report named below.
- Resume in
  `/Users/johnw/src/dot-emacs/lisp/epi/.worktrees/epi-first-slice` on
  `codex/epi-first-slice`. Do not implement on `main`.
- The comprehensive remaining-scope and requirements report is
  `/Users/johnw/dl/20260723T1551-EPI-PHASE1-HALT-REMAINING-SCOPE.md`.
- At the end of every resumed subtask, run the `fess` skill and record or fix
  every finding before claiming that subtask complete.

## Stop-and-escalate counters

- Repeated failing gate signature: 0/3.
- Maximum unusable outputs from any one reviewer: 1/2; each affected reviewer
  recovered after one neutral local-quality prompt.
- Unresolved significant-decision consensus: 0/2.
- Current stop reason: explicit user-requested halt. Tasks 1–5, Task 6 Waves
  0–5, and Wave 6a.1 are committed and pushed; Wave 6a.2 is next and all exact
  source inputs remain present and validated.
- Terminal integration issue: none. The public remote, 20 `phase1` issues,
  and linked Phase 1 project now exist; the feature branch is published at its
  exact checkpoint.

## Halt checkpoint refresh — 2026-07-23 16:01 PDT

- Work resumed briefly from documentation checkpoint `973f3be` to revalidate
  the frozen roots and baseline before Wave 6a.2. No production, test, plan,
  design, or fixture edit was made.
- Preflight passed 26/26, GPTel passed 79/79, package passed 30/30,
  warning-as-error compilation exited zero, and Checkdoc passed over the three
  production files. The codec/JCS run was interrupted after 177/342 passing
  tests and the ledger-I/O run after 196/504 passing tests when the user
  requested `command-halt`; neither run had reported a failure.
- All three read-only Wave 6a.2 mapping/review workers were interrupted before
  producing a canonical artifact or touching the shared worktree. All four
  test/compile processes were stopped, and a process audit found none left.
- The implementation tip remains `84ea7d3`; the clean documentation parent is
  `973f3be`, already pushed before this refreshed halt record. Wave 6a.2 still
  begins with the first red evidence-tree test and no partial implementation
  needs to be recovered or discarded.
- The comprehensive remaining-scope report at
  `/Users/johnw/dl/20260723T1551-EPI-PHASE1-HALT-REMAINING-SCOPE.md` was
  refreshed for this stop. Its 13–23 focused-day estimate and scope boundaries
  are unchanged.
- On resume, restart the codec/JCS and ledger-I/O baselines from zero; the
  interrupted prefixes are diagnostic evidence only, not completion evidence.
  Run `fess` at the end of every completed resumed subtask.

## Halt checkpoint refresh — 2026-07-23 16:12 PDT

- The continuation loop briefly restarted the frozen baseline from the clean
  documentation checkpoint `4bf1c73`; the user repeated `command-halt` before
  any Wave 6a.2 edit. No production, test, plan, design, or fixture file
  changed.
- Preflight passed 26/26, GPTel passed 79/79, package passed 30/30,
  warning-as-error compilation exited zero, and Checkdoc passed over all three
  production files. Codec/JCS was interrupted after 177/342 passing tests and
  ledger-I/O after 189/504 passing tests, with no reported failure. These are
  diagnostic prefixes only; restart both suites from zero on resume.
- All three read-only Wave 6a.2 workers were interrupted before producing a
  canonical report or touching the shared worktree. The two long test sessions
  exited on interrupt, the completed sessions exited zero, and `make clean`
  removed `.build`.
- GitHub issue #20 records this exact evidence and is back in Todo. Issue #6
  remains the In Progress parent. The next implementation action is still the
  first Wave 6a.2 red evidence-tree test.
- The comprehensive report remains
  `/Users/johnw/dl/20260723T1551-EPI-PHASE1-HALT-REMAINING-SCOPE.md` and was
  refreshed for this stop. Run `fess` at the end of every completed resumed
  subtask.

## Halt checkpoint refresh — 2026-07-23 16:21 PDT

- The continuation loop restarted once more from clean documentation commit
  `0a3130d3f48744ddcfb9c70f9a4fec64d47148dd`; the user then invoked
  `command-halt` before the first Wave 6a.2 test or production edit. The
  implementation tip remains `84ea7d37d8bb2034e2e448b5187ff213534ad788`.
- Preflight passed 26/26, GPTel passed 79/79, package passed 30/30,
  warning-as-error compilation exited zero, and Checkdoc passed over all three
  production files. Codec/JCS was interrupted after 177/342 passing tests and
  ledger-I/O after 193/504 passing tests, with no reported failure. These are
  diagnostic prefixes only; restart both suites from zero on resume.
- The two long test sessions exited with the expected interrupt status,
  `make clean` removed the build directory, and the worktree buffer audit found
  no modified Emacs buffer visiting this linked worktree. No Epi test or batch
  process remains active.
- The Wave 6a.2 implementation-map worker was interrupted and produced no
  report. Two read-only workers completed before the halt, and their exact
  outputs are now durable at
  `docs/reviews/2026-07-23-wave6a2-tdd-map.md` (SHA-256
  `1805e8810d8ff2f7810693f32464803ffe781ee690087d6517128617631381c9`) and
  `docs/reviews/2026-07-23-wave6a2-adversarial-review.md` (SHA-256
  `49de2dc816321eb8d4256e9565f97472c638432039f82d4a55b1c45ce17eee0f`).
  They are implementation guidance; the frozen handoff and Task 6 execution
  brief remain authoritative where wording differs.
- GitHub issue #20 is returned to Todo; issue #6 remains the In Progress parent.
  The next shared-worktree action is unchanged: add only the first source-only
  evidence-tree ERT, demonstrate the intended missing-function red result, and
  then implement the smallest Wave 6a.2 production surface. Run `fess` after
  every completed resumed subtask.

## Halt checkpoint refresh — 2026-07-23 16:47 PDT

- Work resumed from clean pushed checkpoint
  `890ce2b7c42d5d7d26b2218795f136959064de47`. The user invoked
  `command-halt` while the first Wave 6a.2 production draft was being written;
  no further behavioral work was performed after that request.
- The first TDD gate is now durable. One test helper and one ERT were added,
  selecting exactly
  `epi-ledger-recovery-converge-evidence-tree-converges-source-only`. Its first
  and only observed failure was the required
  `(void-function epi-ledger--recovery-converge-evidence-tree)` result. The
  fixture, selector, setup, and provisional six-argument call shape all loaded
  correctly.
- `epi-ledger.el` contains an in-flight private
  `epi-ledger--recovery-converge-evidence-tree` draft. It uses a local two-root
  census, the Wave 6a.1 leaf converger, exclusive target-directory receipts, a
  fresh settled-target census, and exact-empty bottom-up pruning. This draft is
  **not green, not compiled, not reviewed, and not complete**. Do not treat its
  presence as a completed Wave 6a.2 implementation. Halt hygiene established
  only that both edited Lisp files have balanced delimiters and that
  `git diff --check` passes; an extra closing delimiter found by that audit was
  corrected without running the feature test.
- A read-only closure review corrected the earlier guidance: the settled
  evidence-proof raw closer is metadata closure, not a content read. The draft
  therefore performs a fresh complete target content census before building
  and raw-closing the returned proof. It also brackets absent roots with stable
  parent authority and calls Wave 6a.1 for target-only leaves when their source
  prefix still exists; a truly missing source prefix remains a mutation-free
  tree-level target-only case.
- Fresh preflight passed 26/26. GPTel passed 79/79, package passed 30/30,
  warning-as-error compilation and Checkdoc passed before the Wave 6a.2 edits.
  The long ledger-I/O baseline was explicitly interrupted at 362/504 passing
  tests with no reported failure after the halt request. The earlier codec/JCS
  session's terminal result was not retained and must not be credited. These
  long-suite prefixes are diagnostic only; rerun both complete suites from zero
  after the focused Wave 6a.2 test first reaches green.
- The remaining test process exited with interrupt status 130, and a process
  audit found no Epi batch test left running. Anvil again failed its readiness
  probe before dispatch. The fallback found no default live Emacs server and no
  worktree lockfile; no editor buffer was modified through this run.
- Read-only resume artifacts remain at
  `/var/tmp/wg-epi-wave6a2-resume3/impl-map/report.md`,
  `/var/tmp/wg-epi-wave6a2-resume3/closure-review/report.md`,
  `/var/tmp/wg-epi-wave6a2-resume3/test-draft/report.md`, and
  `/var/tmp/wg-epi-wave6a2-resume3/followup-tests/report.md`. They made no
  shared-worktree edits. The frozen handoff and Task 6 execution brief remain
  authoritative where any advisory report differs.
- Resume in this linked worktree, never on `main`. The first action is to run
  only the source-only selector against the parseable WIP, record its actual
  post-definition RED, and make the minimum production correction to green it.
  Do not add the mixed-union ERT until that source-only selector is green. Then
  continue the committed order: mixed union, inert refusal table, empty topology
  and pruning, target-only repeat, followed by the remaining Wave 6a.2
  hardening. Run `fess` only after a genuinely completed subtask.
