# Wave 6a.2 adversarial correctness review

## Scope and verdict

This is a read-only review of the frozen Wave 6a.2 boundary.  No Wave 6a.2
implementation exists in the committed files, so the items below are
commit-blocking implementation traps, not observed defects in a submitted
patch.  The committed Wave 6a.1 file converger is sound for its stated
per-file contract; the danger is composing it into a two-root tree transaction
without first establishing the stronger union authority required by the
handoff.

The controlling contract is:

- authenticate both roots completely before mutation;
- admit source-only, target-only, and exact same-inode dual leaves;
- preserve every valid present union leaf, including unreachable leaves, and
  every canonical empty directory;
- require every persisted historical reachable reference;
- produce and close a complete target proof before pruning the source;
- prune only captured exact-empty source directories, bottom-up; and
- make an already completed target-only invocation mutation-free.

This review excludes the fragment, absent-source-object transition, manifest
discovery, locks, durable phase advancement, actual process kills, exhaustive
interruption schedules, and scale/counter acceptance.  Version one also cannot
detect a valid unreachable leaf absent from both roots; adding durable census
state to make that claim would be scope expansion.

## Existing primitives and their exact limits

- `epi-ledger--recovery-converge-file-move` (`epi-ledger.el:17797`) already
  authenticates source-only, target-only, and same-inode dual file states; it
  enforces link counts 1/1/2, exact modes and devices, post-verifier closure,
  callback-free unlink, and target-only no-op behavior.  This closes leaf-level
  publication and unlink races.  It deliberately requires both immediate
  parent directories and their identities (`epi-ledger.el:17830-17867`).
- `epi-ledger--recovery-source-object-proof-at` (`epi-ledger.el:18877`) is a
  Wave 5 one-root capture.  It requires a present root and every leaf to have
  exactly one link (`epi-ledger.el:18927-18944`), so it cannot be used unchanged
  to admit a legal two-root dual state.
- `epi-ledger--recovery-require-evidence-proof-raw`
  (`epi-ledger.el:19048`) is an appropriate independent final-target closer,
  but it likewise describes the settled one-link tree.  It is not a transient
  two-root census representation.
- `epi-ledger--recovery-transfer-evidence-tree-no-clobber`
  (`epi-ledger.el:19246`) requires an absent target (`epi-ledger.el:19298-19300`)
  and linearly moves one source proof.  The design and handoff explicitly say
  this Wave 5 helper is not restart logic.
- `epi-ledger--recovery-reserve-publication-directory`
  (`epi-ledger.el:21137`) provides exclusive ownership for a missing directory.
  `epi-ledger--recovery-delete-exact-empty-directory`
  (`epi-ledger.el:13876`) provides nonrecursive, inode-bound deletion.  Both are
  suitable building blocks if the tree layer supplies correct ordering and
  receipts.

## Ranked commit blockers

### P0.1 — No mutation may precede a complete, reclosed two-root census

**Risk.**  Scanning the source, then creating target directories, then scanning
the target allows malformed target topology, a missing required reference, a
distinct-inode collision, or a late change to be discovered only after durable
state was changed.  Reusing the one-root proof is also unsound because it
rejects legal link-count-two leaves and says nothing about the other root.

**Required invariant.**  Before the first `make-directory`, hard-link, unlink,
write, or directory deletion, the implementation must have captured both
optional roots, validated their entire canonical topology/mode/device/link
matrix, hashed every unique present union object, checked all required
references, and raw-reclosed every captured root, directory entry set, and leaf
identity.  Both roots absent is invalid even when the required vector is empty.

**Smallest discriminating ERT.**  A table test with otherwise valid split roots
injects, one at a time, target debris, source debris, wrong mode, wrong device,
missing required hash, distinct same-hash inode, extra link, both roots absent,
and root replacement during the last content callback.  Wrap
`make-directory`, `add-name-to-file`, `delete-file`, `delete-directory`, and
`write-region`; assert zero calls and an identity/byte/mode-exact snapshot for
both parent trees.  A test that merely expects `epi-ledger-conflict` is
insufficient because a mutate-then-fail implementation passes it.

### P0.2 — The union must use an exact leaf-state matrix, not “first valid copy wins”

**Risk.**  Pairing by filename without comparing inode/link authority can adopt
two distinct files with identical bytes, accept an external hard link, or drop
one side of a split.  Hashing both distinct copies does not resolve the
authority ambiguity: the frozen contract accepts a dual pathname only when the
two names identify the same inode.

**Required invariant.**  For each canonical hash path, allow exactly:

| Source | Target | Required authority |
| --- | --- | --- |
| present | absent | source link count 1 |
| absent | present | target link count 1 |
| present | present | same device and inode, both link count 2 |
| absent | absent | not a union member |

Any distinct inode at both names, even with identical authenticated bytes, or
any other link count is a conflict before mutation.

**Smallest discriminating ERT.**  One success fixture contains three hashes:
one source-only, one target-only, and one exact same-inode dual.  Assert all
three end at target with link count one, original inode identity, exact bytes,
and no source names.  A paired failure fixture writes the same bytes to a
separately created target inode and asserts zero verifier/mutator calls plus an
exact unchanged snapshot.  Add a third external link to the legal dual and
assert the same inert failure.  Existing Wave 6a.1 tests prove these properties
for one file, but the new tests are necessary to prove that the tree census
does not reject or misclassify them before invoking that helper.

### P0.3 — A repeated target-only tree cannot be routed blindly through Wave 6a.1

**Risk.**  A fully completed move has no source root and therefore no source
prefix directories.  The Wave 6a.1 helper requires the immediate source parent
to exist and match caller-held authority.  Recreating source directories just
to call it mutates a completed transaction; calling it with fabricated parent
authority weakens the security boundary; rejecting the state breaks required
idempotence.

**Required invariant.**  The tree layer must authenticate a target-only leaf
directly from the complete target census when its source parent is absent (or
use a separately proven absence-aware adapter).  It must never recreate source
topology.  Where both parents exist, source-only and dual leaves should still
use the committed Wave 6a.1 converger.

**Smallest discriminating ERT.**  Start with source root absent and a valid
target tree containing one required and one unreachable leaf plus an empty
prefix.  Count complete object verifications, and make every mutation primitive
fail the test.  Assert all leaves were authenticated, the returned proof closes
with `epi-ledger--recovery-require-source-object-proof-raw`, and the complete
filesystem snapshot is identical.  Invoke it twice.  This test rejects both an
early-return stub (no content reads) and an implementation that reconstructs
source parents.

### P0.4 — Final target authority must cover the complete union before any source pruning

**Risk.**  Moving only `reachable_objects`, copying only one root per prefix, or
building a proof from intended operations can lose valid unreachable evidence
or empty topology.  Pruning source before independently closing the final
target turns such a proof bug into evidence loss.

**Required invariant.**  The settled target proof must be freshly rooted at the
target, contain every unique present union hash exactly once with link count
one, contain the union of canonical root/`sha256`/prefix directories including
empty directories, and satisfy every required hash and size.  It must be raw-
closed before the first source directory deletion and closed again after source
pruning.

**Smallest discriminating ERT.**  Build a mixed fixture with:

- one required source-only leaf;
- one required exact dual leaf;
- one unreachable source-only leaf;
- one unreachable target-only leaf;
- two different hashes sharing the same two-hex prefix but split across roots;
- one source-only empty prefix and one target-only empty prefix.

Assert the returned proof's count, ordered hashes, directory paths, bytes, and
original inodes against an independently captured expected union, then run the
committed raw proof closer.  Instrument the raw target closer and
`delete-directory`; assert a successful full-target close occurs before the
first source prune and another occurs after it.  A fixture containing only
required leaves or only distinct prefixes would let a reachable-only or
prefix-selection implementation pass vacuously.

### P0.5 — Source pruning must be exact, bottom-up, and strictly post-proof

**Risk.**  Recursive deletion, pruning from an intended rather than captured
directory list, or deleting a replaced directory can erase foreign evidence.
Deleting parent-first can also turn ordinary nonempty-directory failure into an
uncertain partially cleaned state.

**Required invariant.**  Use only captured source directory identities; after
all leaf names have converged and the final target proof has closed, verify each
source directory is the captured inode and empty, then delete nonrecursively in
strict deepest-first order.  Finally prove the source root absent.  A late
foreign entry or directory replacement must survive and cause a conflict; no
recursive fallback is permissible.

**Smallest discriminating ERT.**  Record every `delete-directory` call and
assert the exact reverse-depth sequence and `recursive=nil`.  In a second case,
inject a foreign file into the first prefix immediately before pruning; assert
the function errors, the foreign file remains byte-identical, the source root
remains, and the already converged target proof still closes.  In a third case,
rename a captured empty prefix and replace it with another empty directory;
assert the replacement is not deleted.  The committed deletion helper closes
the final inode/delete step, but only the tree integration can prove correct
ordering and captured-set selection.

### P1.1 — Existing target directories and newly created target directories need different authority paths

**Risk.**  Exclusively creating every union directory rejects legitimate split
and repeat states; blindly adopting existing directories accepts foreign
topology; check-then-create permits clobber/adoption races.

**Required invariant.**  Existing target directories must come from the fully
authenticated target census and remain bound to captured identities.  Missing
target directories must be created top-down only through the exclusive
reservation helper, with each receipt reclosed before leaf action.  The
implementation must never overwrite or silently adopt a collision that appears
between preflight and reservation.

**Smallest discriminating ERT.**  Use a target with an existing root, `sha256`,
and one prefix while a second prefix is source-only.  Assert existing directory
inodes are unchanged and only the missing prefix is created.  Then intercept
the reservation of that missing prefix, install a foreign directory first, and
assert no leaf is linked/unlinked and the foreign directory is retained.  This
proves actual use of exclusive ownership rather than a pre-check.

### P1.2 — Content callbacks require a final whole-census closure, not only per-leaf closure

**Risk.**  Complete object verification may yield.  A callback while hashing
leaf N can replace a root, directory, or already verified sibling.  Wave 6a.1
recloses the leaf it moves, but it cannot validate unrelated census members or
the root topology.

**Required invariant.**  Freeze both metadata censuses before cooperative
content verification, authenticate all unique objects, and then raw-reclose the
entire two-root snapshot without yielding before mutation.  During object reads
normal automatic GC remains enabled, while `post-gc-hook` is nil.  After each
leaf convergence, the helper's exact post-verifier closure remains authoritative.

**Smallest discriminating ERT.**  While verifying the last union leaf, replace
an already verified sibling with a same-size new inode (and separately replace
one root directory).  Assert conflict and zero mutation.  Record
`gc-cons-threshold` and `post-gc-hook` inside every object read; assert the
caller's finite threshold is unchanged and the hook is nil for source-only,
target-only, dual, reachable, and unreachable objects.  Wave 5 already tests
this policy for its one-root proof; the new path must prove it independently.

### P1.3 — Interruption must leave a valid restart state and preserve structured exits

**Risk.**  A tree wrapper that catches `quit` or an arbitrary nonlocal exit and
continues pruning can lose source authority.  A wrapper that tries speculative
rollback after a hard link may delete the only valid name.

**Required invariant.**  A quit during preflight propagates with no mutation.
A quit after target link creation but before source unlink leaves the exact
same-inode two-link state created by the file helper.  No source pruning begins
after an incomplete leaf convergence.  A subsequent invocation must converge
that deterministic state.

**Smallest discriminating ERT.**  Inject `quit` from the post-link verifier for
the second of two source-only leaves.  Assert the first leaf is settled at
target, the second has exact source/target dual names with link count two, all
bytes/inodes remain valid, and no source directory was deleted.  Reinvoke with
the normal verifier and assert the complete final proof.  This is one
representative deterministic nonlocal-exit case, not Task 15's exhaustive kill
matrix.

### P1.4 — Every present union leaf must be content-authenticated, not only required leaves

**Risk.**  Treating path syntax and metadata as sufficient for unreachable
leaves allows corrupt or substituted evidence into quarantine.  Conversely,
silently dropping an invalid unreachable leaf violates preservation and hides
corruption.

**Required invariant.**  Every canonical leaf in either root is completely
hashed against its basename and measured size before mutation, regardless of
reachability.  Required references add a presence-and-size constraint; they do
not define the census.

**Smallest discriminating ERT.**  Use an empty required vector and a target-only
tree with one valid unreachable leaf and one leaf whose basename is the SHA-256
of different bytes.  Assert conflict, at least the corrupt path reached the
content verifier, no mutation, and an unchanged snapshot.  A required-only
implementation otherwise passes all missing-required tests when the vector is
empty.

### P2.1 — Canonical ordering and chunk construction must be derived from the union, not concatenated proofs

**Risk.**  Concatenating source and target proof chunks can duplicate a dual
leaf, violate strict global hash order at a chunk boundary, or produce a
noncanonical directory order.  The raw settled-proof verifier rejects these,
but a test that checks only `count` may miss the construction error until a
different topology appears.

**Required invariant.**  Deduplicate by canonical hash only after the identity
matrix is validated, globally sort unique leaves, then form nonempty chunks of
at most the committed limit; sort canonical directory paths as required by the
settled proof representation.

**Smallest discriminating ERT.**  Arrange source and target hashes so their
lexical orders interleave and include one dual leaf spanning the two roots.
Assert the flattened returned hashes equal the independently sorted unique set,
the dual appears once, every nonfinal chunk has the exact chunk limit, and the
raw proof closer accepts the result.  No scale or performance counter is needed.

## Minimum first-commit test gate

The first Wave 6a.2 commit should be blocked unless deterministic tests prove
all of the following:

1. Whole-root source-only success preserves inode/bytes and yields a closed
   target proof.
2. Whole-root target-only success authenticates all content and performs zero
   mutation on two invocations.
3. One mixed split covers source-only, target-only, exact dual, required,
   unreachable, shared-prefix, and empty-directory union behavior.
4. Distinct same-hash inodes and third-link ambiguity fail before callbacks or
   mutation.
5. Both roots absent, debris, wrong mode/device, and missing/size-mismatched
   required references fail with exact snapshots unchanged.
6. A late preflight sibling/root replacement fails before mutation.
7. The full final target proof closes before prune and again after prune.
8. Source directories are deleted only exact-empty, nonrecursively, and
   bottom-up; injected debris and replacement directories survive.
9. Existing target directories retain identity; missing ones are exclusively
   reserved and a racing collision is never adopted.
10. Normal GC remains enabled, `post-gc-hook` is suppressed during complete
    reads, and one representative post-link quit resumes safely.

Tests that assert only a returned proof, only target existence, only a signaled
condition, or only required-object preservation are vacuous for this contract.
They can all pass under an early-return stub, a reachable-only mover, a
mutate-then-fail implementation, or a proof assembled from intended rather than
observed state.  Independent filesystem snapshots, inode/link assertions,
mutation counters, content-read counters, and the committed raw proof closer
are the minimum useful oracles.

## Scope-creep temptations to reject

- Do not add a durable unreachable-census field or claim detection of an
  unreachable leaf missing from both roots.
- Do not include `fragment_object` in this converger; Wave 6a.2 receives only
  historical `reachable_objects` for the present-source-object transition.
- Do not build manifest scanning, lock acquisition, phase advancement, marker
  publication, or the seven-phase resume driver here.
- Do not add process-kill harnesses, exhaustive first/middle/last schedules,
  repetitions, census benchmarks, or operation counters; those are Task 15.
- Do not generalize Wave 6a.1 or introduce a new storage abstraction merely to
  handle target-only missing source parents.  A narrow absence-aware tree-layer
  closure is sufficient.
- Do not optimize away the complete union census or final proof in the name of
  scale.  Task 15 owns scale optimization; Wave 6a.2 owns correctness.

## Final assessment

No defect was found in the committed Wave 6a.1 helper within its stated scope.
The highest-risk composition errors are (1) mutating before a fully reclosed
two-root census, (2) treating same bytes as equivalent to same inode, (3)
blindly routing target-only leaves through a helper whose source parent must
exist, and (4) pruning before an independent complete target-union proof.  The
test matrix above is the smallest one that distinguishes the required
authority transfer from a superficially idempotent but evidence-losing
implementation.
