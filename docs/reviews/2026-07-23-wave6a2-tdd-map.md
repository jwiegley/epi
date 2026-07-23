# Wave 6a.2 first-slice TDD test map

## Boundary under test

The proposed private entry point is:

```elisp
(epi-ledger--recovery-converge-evidence-tree
 SOURCE-ROOT TARGET-ROOT DEVICE
 SOURCE-PARENT-IDENTITY TARGET-PARENT-IDENTITY
 REQUIRED-REFERENCES)
```

`REQUIRED-REFERENCES` is only the historical manifest
`reachable_objects` vector.  It never contains the current fragment object.
The caller enters this helper only for the durable
`source_object_tree_state = present` case, although a restarted physical state
may already have no source-root name.  The result should be a fresh
`epi-ledger--recovery-evidence-proof` rooted at `TARGET-ROOT`.

The five tests below deliberately do not cover manifest selection, phase
rehydration, locks, barriers, the absent-source marker, or the seven-phase
driver.  They freeze only the complete two-root tree operation promised by
Wave 6a.2.

## Exact committed test and production anchors

Line numbers are from the committed halt checkpoint and are only navigation
anchors.

- `epi-test-ledger-io--condition-code` at
  `test/epi-ledger-io-test.el:40` extracts the stable structured error code.
- `epi-test-ledger-io--literal-file-bytes` at line 1202 is the byte oracle.
- `epi-test-ledger-io--recovery-tree-snapshot` at lines 10117-10134 captures
  recursive name, kind, mode, inode/device, link count, size, stable times, and
  bytes.  Use it both before and after every inert refusal.
- `epi-test-ledger-io--recovery-call-inertly` at lines 10136-10143 is useful
  for exact before/after state, but it cannot detect a create-then-delete
  transient.  The rejection test below therefore also forbids mutation
  primitives while the real scanner runs.
- The committed Wave 6a.1 entry point is
  `epi-ledger--recovery-converge-file-move` at `epi-ledger.el:17797`.  Its ERT
  contracts begin with
  `epi-ledger-recovery-converge-file-move-completes-source-only` at
  `test/epi-ledger-io-test.el:23433`, followed by exact-dual, target-only,
  conflict, drift, closure, and error-preservation tests.
- `epi-test-wave6--file-parent-identity` at line 23416 returns the exact
  containing-directory identity required by the proposed tree API.  It works
  even when the leaf or tree root itself is absent.
- `epi-test-wave6--file-state-snapshot` at line 23421 is available for a small
  set of leaf names; prefer the recursive tree snapshot for whole-tree
  refusal assertions.
- `epi-test-wave5--tree-transfer-fixture` at lines 24163-24292 constructs a
  canonical private markerless object tree and returns `:source`, `:target`,
  `:target-parent`, `:device`, sorted `:items`, `:source-shape`,
  `:source-directories`, and `:source-files`.  Its supported topologies are
  `objects`, `empty-root`, `empty-sha`, and `empty-prefix`.
- `epi-ledger--recovery-object-path-under-root` at `epi-ledger.el:15345` and
  `epi-ledger--recovery-rebase-object-tree-path` at line 18090 derive canonical
  target paths without duplicating path rules in tests.
- `epi-ledger--recovery-evidence-directory-names` at line 18817,
  `epi-ledger--recovery-evidence-chunk-leaves` at line 18837, and
  `epi-ledger--recovery-source-object-proof-at` at line 18877 show the existing
  canonical census rules: root is empty or contains only `sha256`; prefixes
  are lower-case two-hex directories; leaves are full lower-case hashes,
  private regular files, and content-authenticated.
- `epi-ledger--recovery-require-evidence-proof-raw` at line 19048 and its
  alias `epi-ledger--recovery-require-source-object-proof-raw` at line 19238
  are the final target-proof oracle.  A successful test must invoke the latter
  on the returned proof and `DEVICE`.
- `epi-ledger--recovery-transfer-evidence-tree-no-clobber` at line 19246 is
  the Wave 5 absent-target path.  It is useful prior art, but Wave 6a.2 must not
  use its absent-target assumption as restart logic.
- `epi-ledger--recovery-reserve-publication-directory` at line 21137 and
  `epi-ledger--recovery-delete-exact-empty-directory` at line 13876 are the
  existing creation and exact-empty deletion seams.

Place the proposed Wave 6a.2 fixture helper and ERTs immediately after
`epi-test-wave5--tree-transfer-fixture` (after current line 24292), before
`epi-ledger-recovery-tree-transfer-requires-exact-linked-object-verifier-return`.
That keeps the new restart tests adjacent to the fixture they extend and after
the complete Wave 6a.1 file-level contract.

## Smallest new test-only support

Add only one small data helper initially:

```elisp
(defun epi-test-wave6--reachable-references (items) ...)
```

It maps the already hash-sorted `:items` vector returned by
`epi-test-wave5--tree-transfer-fixture` into a fresh vector of closed alists in
this exact key order:

```elisp
(("hash" . HASH)
 ("size" . SIZE)
 ("media_type" . "application/octet-stream")
 ("role" . "recovery-fragment"))
```

Do not add a production fixture builder, schema type, public API, or synthetic
persisted identity.  Build each mixed physical state directly in its test
with `make-directory`, mode 0700, `add-name-to-file`, `delete-file`, and the
existing byte writer.  A second generic case-builder would obscure which
crash shape each test actually creates; extract one only after the first five
tests are green and duplication is demonstrated.

For refusal tests, use a local `cl-letf` that replaces these mutation seams
with `ert-fail`: `make-directory`, `add-name-to-file`, `delete-file`,
`delete-directory`, `rename-file`, `copy-file`, `write-region`, and
`set-file-modes`.  This is not a mocked scanner: all stat, directory-enumeration,
and content-hash code remains real.  The replacements merely prove that a
rejected complete census never enters mutation.  Pair this with an exact
`epi-test-ledger-io--recovery-tree-snapshot` comparison.

## Ordered first-red sequence

Add and green these one at a time.  Do not add all five before observing the
first failure.

### 1. Minimal API RED: source-only tree

Suggested ERT name:

```elisp
epi-ledger-recovery-converge-evidence-tree-converges-source-only
```

Setup:

1. Enter `epi-test-with-temporary-root`.
2. Call `(epi-test-wave5--tree-transfer-fixture root)` with its default
   `objects` topology.  Leave `:target` absent.
3. Convert `:items` with `epi-test-wave6--reachable-references`.
4. Save every `(path . identity)` in `:source-files` and obtain both top-level
   parent identities with `epi-test-wave6--file-parent-identity` immediately
   before the call.

Action: call the proposed tree converger with `:source`, `:target`, `:device`,
the two parent identities, and the required-reference vector.

Assertions:

- The result satisfies `epi-ledger--recovery-evidence-proof-p`.
- `epi-ledger--recovery-evidence-proof-raw-root` is exactly `:target`, its
  device is `:device`, and its count is 2.
- `epi-ledger--recovery-require-source-object-proof-raw` returns non-nil for
  the result and device; this is the final target authentication, not merely a
  shape assertion.
- `:source` is absent.
- Each hash exists at the path returned by
  `epi-ledger--recovery-object-path-under-root`; its bytes match the original
  source bytes, its mode is 0600, its link count is 1, and
  `epi-ledger--same-file-object-p` relates its final identity to the saved
  source identity.

Expected first RED: ERT reports
`(void-function epi-ledger--recovery-converge-evidence-tree)`.  This is the
only acceptable first-red reason.  A fixture, arity, or setup error must be
fixed and rerun before production code is added.

### 2. Core restart behavior: mixed admitted union

Suggested ERT name:

```elisp
epi-ledger-recovery-converge-evidence-tree-converges-mixed-union
```

Setup from the default Wave 5 fixture:

1. Leave its first required leaf source-only.
2. Create the target root/`sha256`/needed prefix directories at mode 0700,
   hard-link the second required leaf to its canonical target path, then
   delete its source name.  It is now target-only with one link.
3. Create a third, nonempty private object whose hash has a canonical prefix,
   but do not add it to required references.  Hard-link it at the same
   canonical relative path in both roots and retain both names.  It is a valid
   unreachable exact-dual leaf with two links.
4. Keep `REQUIRED-REFERENCES` equal to the original two fixture items.  Capture
   the three inode identities and bytes before invoking the converger.

Assertions:

- The source-only, target-only, and dual leaves all finish target-only with
  mode 0600 and link count 1.
- The returned, raw-verified target proof has count 3 even though required
  references has length 2.  The third leaf is therefore preserved as valid
  unreachable evidence rather than inferred from the manifest or discarded.
- All three target names retain their pre-call inode, size, and exact bytes.
- The source root is absent only after the target proof can authenticate all
  three leaves.
- Instrument `epi-ledger--recovery-converge-file-move` narrowly to record
  calls while delegating to the real function.  Require one call for the
  source-only leaf and one for the exact-dual leaf; the already target-only
  leaf may be handled by the tree-level final census because its source prefix
  can disappear.  No call may use the old
  `epi-ledger--recovery-link-move-file` directly from the new tree helper.

This test is the smallest proof of the new behavior that Wave 5 did not have:
one admitted union assembled from both roots, with all three file states and
an unreachable member.

### 3. Complete preflight before mutation

Suggested ERT name:

```elisp
epi-ledger-recovery-converge-evidence-tree-rejects-invalid-union-inertly
```

Use three fresh subcases under separate temporary roots; this is the only
small table in the first slice:

1. `missing-reachable`: remove one required source leaf while leaving it
   absent from target.  Expect `epi-ledger-conflict` with code
   `recovery-object-content-changed`.
2. `late-target-debris`: keep a valid source-only leaf that a streaming mover
   could otherwise move first, then put a foreign noncanonical entry in the
   target root.  Expect `recovery-object-content-changed`.
3. `distinct-inode-dual`: write byte-identical, hash-valid private files at
   the same canonical relative path in both roots without hard-linking them.
   Expect `recovery-path-conflict`; equal bytes and hashes do not authorize
   deleting either inode.

For every subcase:

- Capture the entire temporary root with
  `epi-test-ledger-io--recovery-tree-snapshot`.
- Install the forbidden-mutation `cl-letf` described above.
- Call the real tree converger and inspect the code with
  `epi-test-ledger-io--condition-code`.
- Require the recursive snapshot to be exactly equal afterward.

The `late-target-debris` shape is important: it proves that the implementation
does not mutate a valid early source leaf before finishing the second-root
census.  Do not satisfy this test with a rollback path.

### 4. Empty union topology and exact bottom-up pruning

Suggested ERT name:

```elisp
epi-ledger-recovery-converge-evidence-tree-preserves-empty-topology-and-prunes
```

Setup:

1. Call `(epi-test-wave5--tree-transfer-fixture root 'empty-prefix)`.  Its
   source contains the empty `sha256/ab` topology and no leaves.
2. Independently create the target root, its `sha256` directory, and a
   different empty lower-case two-hex prefix (for example `cd`), all mode
   0700.  Pass `[]` as required references.
3. Save the source directory identities and expected delete order as
   `(reverse (mapcar #'car (plist-get case :source-directories)))`.
4. Wrap `delete-directory` only to record calls and delegate to the real
   function.  At every call assert `recursive` is nil and the directory is
   empty before deletion.

Assertions:

- The returned proof is raw-valid, rooted at target, and has count 0.
- Its directory paths describe the union: target root, target `sha256`, and
  both empty prefixes `ab` and `cd`, in canonical order.
- The observed source deletion order equals the captured deepest-first order:
  prefix, `sha256`, then source root.
- The shared user-owned temporary parent remains the same directory object and
  is never passed to `delete-directory`.
- Source is absent and every target directory has mode 0700.

This keeps empty topology as evidence while proving that pruning is limited to
captured, exact, empty, recovery-owned source directories.

### 5. Completed target-only repeat is mutation-free

Suggested ERT name:

```elisp
epi-ledger-recovery-converge-evidence-tree-repeats-target-only-inertly
```

Setup and first action: use the source-only case from test 1 and converge it
once.  Capture the returned proof and an exact recursive snapshot after source
pruning.  Because this models a fresh process-local epoch, capture fresh
top-level parent identities before the second invocation.

Second action: install the forbidden-mutation `cl-letf`, then call the same
tree converger with the now-absent source root, complete target root, same
device, same durable required references, and fresh parent identities.

Assertions:

- The second result is a raw-valid target proof with the same root, count,
  ordered hashes, directory topology, and exact identities as the first.
  `equal` should hold for the two proof values if the implementation performs
  no mutation.
- The complete recursive snapshot is unchanged.
- No directory creation, link, unlink, directory deletion, rename, copy,
  write, chmod, marker, or phase effect occurs.
- Source remains absent and each target leaf remains one-link mode 0600.

This is a true target-only re-entry.  It must not require now-absent source
prefix-directory identities and must not try to replay the Wave 5 transfer.

## Suggested selectors and TDD cadence

Run only after the coordinator has added the corresponding test; this report
did not run any command.

First RED only:

```sh
direnv exec . make test-one TEST=test/epi-ledger-io-test.el \
  SELECTOR='^epi-ledger-recovery-converge-evidence-tree-converges-source-only$'
```

Growing Wave 6a.2 slice:

```sh
direnv exec . make test-one TEST=test/epi-ledger-io-test.el \
  SELECTOR='^epi-ledger-recovery-converge-evidence-tree-'
```

Adjacent regression selectors after every green step:

```sh
direnv exec . make test-one TEST=test/epi-ledger-io-test.el \
  SELECTOR='^epi-ledger-recovery-converge-file-move-'
direnv exec . make test-one TEST=test/epi-ledger-io-test.el \
  SELECTOR='^epi-ledger-recovery-evidence-'
```

At the completed Wave 6a.2 checkpoint, run the frozen Task 6 selector from the
execution brief:

```sh
direnv exec . make test-one TEST=test/epi-ledger-io-test.el \
  SELECTOR='^epi-ledger-recovery-'
```

For each test: observe its precise RED, add only the minimum production logic
needed for GREEN, rerun the new selector plus the two adjacent selectors, and
only then add the next test.

## Later must-have Wave 6a.2 hardening, not part of the first five REDs

The first five tests establish the architecture.  Before Wave 6a.2 is called
complete, add focused regressions for every remaining frozen refusal and race:

- leaf mode other than 0600 and internal/root directory mode other than 0700;
- target-only, source-only, or dual leaf with an extra external hard link;
- wrong or changed device (`quarantine-cross-device` at the bound-directory
  boundary), replaced root/parent (`recovery-path-conflict`), noncanonical or
  overlapping roots, and root identity drift after a cooperative yield;
- malformed prefix/hash names, symlink/FIFO/foreign entries, duplicate or
  inconsistent union hashes, and size/hash changes
  (`recovery-object-content-changed`);
- verifier-time target/root drift after full hashing but before the first
  mutation;
- source-only link completion and exact-dual unlink races delegated through
  Wave 6a.1, including preservation of
  `storage-publication-failed :published t` when final unlink certainty is
  lost;
- a foreign entry injected before exact-empty pruning: no recursive delete,
  the foreign entry survives, and the existing deletion seam's
  `storage-write-failed` classification is retained;
- normal GC and cooperative yields during complete object walks, with only
  `post-gc-hook` suppressed where the closing epoch requires it;
- separate `empty-root` and `empty-sha` convergence, and split empty prefixes
  on both evidence hops.

These remain Wave 6a.2 correctness work; they should be added after the small
first slice exposes a stable implementation shape.  The two evidence hops use
the same private converger and need integration coverage later in Wave 6, not
duplicate tree algorithms.

## Explicit Task 15 boundary

Do not add actual killed workers, exhaustive first/middle/last leaf positions,
repeated interruption schedules, competing-process campaigns, 257-plus-leaf
scale sweeps, census counters, RSS/elapsed thresholds, or heartbeat/yield
performance acceptance here.  Those are Task 15.  Wave 6a.2 needs bounded
representative deterministic states and correct chunked proof use, but no new
durable census schema and no persisted unreachable-object list.
