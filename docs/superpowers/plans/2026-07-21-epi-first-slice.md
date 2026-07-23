# Epi First Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the approved Epi first slice: an Emacs-native agent harness whose append-only Org ledger is authoritative, whose disposable runtime delegates provider communication to GPTel, and whose text and sequential-tool sessions survive close, reopen, branch selection, and continuation.

**Architecture:** Seven Emacs Lisp modules form a one-way dependency graph. `epi-ledger.el` owns canonical records and pure reduction; `epi-resources.el` and `epi-tools.el` own provider-neutral inputs and effects; `epi-gptel.el` is the only GPTel compatibility boundary; `epi-runtime.el` owns lifecycle and commit barriers; `epi-ui.el` builds disposable Emacs views; `epi.el` is the lazy public facade. One frozen turn snapshot governs the entire GPTel request loop. GPTel continuations remain opaque and are released only after Epi has durably committed the corresponding tool result.

**Tech Stack:** Emacs 30 and lexical-binding Emacs Lisp; Org 9.7 or later for presentation only; GPTel 0.9.9.5 at commit `8701e2bd80c5d2091ce2decef5d34d6fce4a3ada`; ERT; `cl-lib`, `json`, `map`, `seq`, `subr-x`, and other built-in libraries; Curl through GPTel; GNU Make as a thin batch-command facade. No TypeScript or second extension language is introduced.

## Global Constraints

1. The approved design, [`2026-07-21-epi-design.md`](../specs/2026-07-21-epi-design.md), is authoritative. This plan implements Section 16 only. Section 17 remains a gated, non-executable roadmap.
2. The Org ledger and immutable content-addressed objects are the only durable session authority. GPTel buffers, UI buffers, in-memory indexes, callbacks, and continuations are disposable.
3. A ledger is append-only Epi data. Users may view it through `epi-ledger-mode` but must not edit it. Epi commands express every state change by appending a record.
4. `epi-gptel.el` is the only production file allowed to name `gptel--*`, `gptel-fsm-*`, provider parsers, GPTel text properties, or GPTel's active-request registry. It may install the pinned request-local pre-parse safety auditor and raw-transport byte guard specified in Task 2; those guards inspect and reject input but never publish/cache a provider-neutral response object or replace GPTel's request/parser/FSM loop. The argument auditor may transiently decode bounded scalar tokens solely to validate schema and duplicates, then retains only raw bytes plus a nonsemantic safety attestation. Canonical Epi arguments are constructed later, during normalization of GPTel's accepted tool callback.
5. The sole first-slice provider capability is `openai-chat-completions/sequential-tools-v1`: classic OpenAI-compatible Chat Completions, text, streaming, reasoning observation, and exactly one tool call per provider leg. Responses API, additional provider families, parallel calls, mixed text-and-tool legs, media, replayed reasoning, steering, and in-run configuration changes fail closed.
6. The immutable snapshot captured at `turn-started` governs every provider leg in that turn. There is no first-slice pause/resume or save-point refresh.
7. Provider-leg completion is not settlement. An admitted agent operation ends with exactly one committed terminal turn record, one committed terminal operation record, and one committed `agent-settled` event. A turnless structural operation ends with one terminal operation record and one committed `agent-settled` event.
8. No provider continuation may run until all policy, tool-terminal, and model-facing tool-result records that precede it are committed and read-verified.
9. Project instructions are untrusted model context. They never add tool authority, alter policy, or load project Elisp.
10. No test uses the network. The GPTel contract suite replaces only the transport and continues to exercise real GPTel request construction, provider parsing, FSM transitions, callbacks, and tool continuations.
11. Work is test-first. Every task below begins red, ends green, runs all preceding tests, and is committed independently. Do not combine tasks or continue after a named fail-closed gate.
12. Do not install dependencies or enter an ad-hoc development environment. The executor supplies Emacs, GPTel, Transient, and Compat through the existing `direnv` environment.

## Execution Preflight

The planning host currently has no `emacs` command in its shell environment, and the dedicated Anvil Emacs does not have GPTel on its `load-path`. That does not invalidate this documentation plan, but implementation must stop at the preflight until the repository's existing environment supplies the pinned dependencies.

The bootstrap order is explicit because a fresh checkout has no Makefile yet.
Before Task 1, use only read-only shell checks to locate the already-provided
`EPI_EMACS`, `GPTEL_ROOT`, `PI_ROOT`, `JCS_ORACLE_ROOT`, and
`EPI_EXTRA_LOAD_PATH` inputs; these availability checks are not a substitute
for preflight. In Task 1, create the test helper and write the package test
and dedicated preflight/runner regression test first, then run both initial red
contracts directly with `EPI_EMACS`. Next implement the validator utilities in
the helper plus the test runner and Makefile, run the isolated preflight tests
directly, run `direnv exec . make preflight`, and stop on any mismatch before
implementing `epi.el`. Every later task starts only after that exact preflight
has passed. Do not invoke a nonexistent `make preflight`, and do not weaken or
bypass it to bootstrap the target that defines it.

Use these inputs:

```sh
export EPI_EMACS=/absolute/path/to/emacs
export GPTEL_ROOT=/absolute/path/to/gptel
export PI_ROOT=/absolute/path/to/pi
export JCS_ORACLE_ROOT=/absolute/path/to/json-canonicalization
export EPI_EXTRA_LOAD_PATH=/path/to/transient:/path/to/compat
direnv exec . make preflight
```

`make preflight` must verify, without fetching:

- Emacs version 30.1 or later.
- Org version 9.7 or later.
- GPTel reports version 0.9.9.5.
- `GPTEL_ROOT` is Git commit `8701e2bd80c5d2091ce2decef5d34d6fce4a3ada`.
- `gptel.el`, `gptel-request.el`, and `gptel-openai.el` have SHA-256 values `2a1a7aba6bb4d7af7bf302ebed75ad74c598ccb7383fc5f5318b15295c42bbe5`, `f4a42353208dc52ac14cd90e77e06d6b656d00c6bc5ee5a72cb9d517e088d66b`, and `8467b1693a768230d6fa7f57f636756282c613626b94b0ff05f656b212d69677`.
- In the clean `--batch -Q` helper, `locate-library` resolves all three GPTel libraries to those exact truenamed `.el` files under `GPTEL_ROOT`; no same-library path precedes them, no sibling `.elc` exists, and `comp-el-to-eln-filename` finds no loadable native artifact for them. The helper disables native JIT, loads the three absolute source files in dependency order under source-only resolution, and requires representative pinned functions' `symbol-file` values to remain those `.el` files. A compiled or shadowing artifact is incompatible even if its adjacent source hash matches.
- `PI_ROOT` is Git commit `dd6bea41efa8caa7a10fe5a6401676dc5699f83f`; its `session-manager.ts`, `agent-session.ts`, `resource-loader.ts`, `tools/read.ts`, and `tools/edit.ts` source anchors have SHA-256 values `5ca662efec88c135559630deda469fcf022035ddfb61b4610de8d74cee5c8b39`, `7fe22be86e251af9f820c816f0c847e6db390682e33882f8fce388715fea4dc5`, `e2b999d280fcf640a995fadca84cfc9ddfd83aef1d3748f29dd71edae0c408a8`, `1acc6fcb88a29317d4f800fa1e9e1ff3d13d32527dd8c6f1cdbeeab5107ae06d`, and `a42f745488ab89553173479986efc222544eeac26e1820692954031c63c27fdd`.
- `JCS_ORACLE_ROOT` is the official `cyberphone/json-canonicalization` repository at commit `19d51d7fe467d4706a3ff08adf8a748f29fc21e0`; `node-es6/canonicalize.js` and `node-es6/verify-canonicalization.js` have SHA-256 values `f9f498b55c99eefe348c99018ddcfe08efa6f7ff96b9ba9dce4b7090b33c4438` and `314898c8f08ed5b14a3f5903b27ec4789ac5dc7fd59a168e72a6d876f192be6f`. For `testdata/input/*.json` plus `testdata/output/*.json`, bytewise-sort relative paths, form UTF-8 lines `<file-sha256><two spaces><relative-path><LF>`, and hash their concatenation; the required digest is `823c07e7e1b1bbfc903354435b508026e43d2bf3183450a8773cf6cab7668933`.
- `make preflight` validates the JCS source without executing it. Node is checked and used only by the deliberate Task 3 `make jcs-goldens` regeneration target. Ordinary ERT, `make test`, and consumption of checked-in JCS goldens do not execute JavaScript or require Node.
- `gptel`, `gptel-request`, `gptel-openai`, `transient` 0.7.8 or later, and `compat` 30.1.0.0 or later can be loaded under `--batch -Q` with only the declared load paths.

Any mismatch prints the observed value, the required value, and exits nonzero. It must not silently use an installed GPTel from another path.

## Frozen Source Baseline

The implementation worker must retain local, read-only source checkouts while executing the plan:

| Oracle | Pinned revision | What is borrowed |
|---|---|---|
| Pi | `dd6bea41efa8caa7a10fe5a6401676dc5699f83f` | Tree traversal, context construction, lifecycle settlement, resource precedence, and file-operation behavior |
| GPTel | `8701e2bd80c5d2091ce2decef5d34d6fce4a3ada` | Provider request construction, typed history, streaming parser, callback forms, FSM, abort, and tool continuation |
| JCS reference | `19d51d7fe467d4706a3ff08adf8a748f29fc21e0` | Development-only canonical-byte oracle and official input/output vectors used to generate checked-in fixtures |

Pi is a behavioral oracle, not a code port. GPTel is a runtime dependency behind one pinned adapter. The JCS repository is a fixture-generation oracle, not a shipped extension or runtime dependency; Epi remains Emacs Lisp-only. Re-study the cited source when a test exposes a mismatch; do not reproduce provider machinery in Epi.

## Production File Map

| File | Responsibility | May depend on |
|---|---|---|
| `epi.el` | Customization, conditions, semantic events, lazy public facade | Built-ins only |
| `epi-ledger.el` | JCS, Org framing, validation, append, objects, recovery, reduction | `epi.el` |
| `epi-resources.el` | Instruction discovery, exact-byte snapshots, provenance | `epi.el` |
| `epi-tools.el` | Tool values, registry, policy, read and mutation transactions | `epi.el` |
| `epi-gptel.el` | GPTel compatibility and provider-semantic replay | `epi.el`, `epi-ledger.el`, `epi-tools.el`, GPTel |
| `epi-runtime.el` | Session FSM, snapshots, FIFO, commit barriers, settlement | All provider-neutral modules and `epi-gptel.el` |
| `epi-ui.el` | Conversation, composer, ledger, tree, approval views | Public facade and runtime |

`epi.el` must not eagerly require GPTel. Lower modules may require `epi.el`.
The facade installs autoload declarations for public functions and commands
owned by `epi-runtime.el` and `epi-ui.el`; those modules later define the
declared public names directly. `epi.el` does not define wrapper functions that
require an owner and delegate to a second internal public seam.

## Test File Map

```text
test/
  checkdoc.el
  run-tests.el
  epi-test-helper.el
  epi-preflight-test.el
  epi-package-test.el
  epi-gptel-contract-test.el
  epi-gptel-fixture-transport.el
  epi-ledger-codec-test.el
  epi-ledger-io-test.el
  epi-ledger-worker.el
  epi-ledger-process-test.el
  epi-reducer-test.el
  epi-runtime-test.el
  epi-resources-test.el
  epi-tools-test.el
  epi-mutation-test.el
  epi-ui-test.el
  epi-acceptance-test.el
  epi-scale-test.el
  epi-scale-runner.el
  epi-architecture-test.el
  epi-documentation-test.el
  generate-jcs-goldens.el
  fixtures/
    gptel/
    ledger/
    jcs/
      appendix-b.el
      independent-goldens.json
    performance/
      time-darwin.txt
      time-gnu.txt
      reference.json
```

`test/run-tests.el` accepts `TESTS` and `SELECTOR` from the Makefile, loads only the requested test files when supplied, treats `SELECTOR` as a raw ERT regular-expression string (not an Elisp symbol read from the environment), and calls `ert-run-tests-batch-and-exit`. When a selector is supplied, the runner must preselect against the loaded ERT tests and exit nonzero if it matches zero tests; an empty selection can never satisfy an expected-red or expected-green step. `test/checkdoc.el` opens each named production file in a temporary Emacs Lisp buffer and calls `checkdoc-current-buffer`. Do not use a nonexistent `checkdoc-batch` entry point.

All preflight validator and probe utilities live in
`test/epi-test-helper.el`, use the `epi-test-*` namespace, and are exercised by
`test/epi-preflight-test.el`. Loading the helper never loads GPTel and never
defines, advises, aliases, or substitutes a production Epi symbol.

The Makefile exposes these stable commands:

```sh
direnv exec . make preflight
direnv exec . make jcs-goldens
direnv exec . make test-one TEST=test/epi-ledger-codec-test.el SELECTOR='^epi-jcs-'
direnv exec . make test
direnv exec . make process-test
direnv exec . make scale
direnv exec . env EPI_SCALE_RECORDS=100000 EPI_UPDATE_SCALE_REFERENCE=1 make scale-reference-record
direnv exec . env EPI_SCALE_RECORDS=100000 make scale-reference
direnv exec . make compile
direnv exec . make checkdoc
direnv exec . make architecture
direnv exec . make verify
direnv exec . make clean
```

`make test` runs every in-process offline ERT file in the map. `make process-test` runs the isolated competing-process/crash suite, and `make scale` runs the hardware-independent scale gates. `make verify` runs preflight, test, process-test, scale, byte-compilation with `byte-compile-error-on-warn`, checkdoc, architecture checks, and Markdown/documentation checks. It leaves no `.elc` files or worker processes in the source tree.

## Frozen Storage and Wire Format

Given ledger path `FILE`:

```text
FILE
FILE.objects/sha256/ab/<64-lowercase-hex>
FILE.epi-lock
<epi-session-directory>/quarantine/<session-id>-<timestamp>/
<custom-ledger-parent>/.epi-quarantine/<session-id>-<timestamp>/
<quarantine-directory>/.epi-recovery/<recovery-id>/manifest.jcs
<quarantine-directory>/.epi-recovery/<recovery-id>/source-stage/
<quarantine-directory>/<session-id>-<timestamp>/complete.jcs
```

Default ledgers are `<epi-session-directory>/<session-id>.org`. Their default quarantine is `<epi-session-directory>/quarantine`; a custom ledger defaults to a sibling `<custom-ledger-parent>/.epi-quarantine`. An explicitly supplied quarantine directory must have the same filesystem device as the source ledger parent, and recovery refuses before creating, publishing, or moving anything if this cannot be proved. Thus every source-to-quarantine move is same-filesystem; the destination may live elsewhere because it is built and published independently on its own filesystem. Final directories are exclusively reserved and become complete only when their canonical `complete.jcs` marker is published. Epi-created session/object/quarantine directories are mode 0700; Epi never chmods an existing caller-owned parent directory for a custom path. Ledger, object, token, fragment, manifest, and completion-marker files are mode 0600. Temporary files are siblings of their destination so file replacement stays on one filesystem. Payloads store object hash, byte size, media type, and role, never a derived path.

All canonical writes go through one private local-byte writer. It rejects remote paths, accepts unibyte data, binds `coding-system-for-write` to `no-conversion`, disables `write-region-annotate-functions` and `write-region-post-annotation-function`, bypasses file-name handlers only after proving the path local, and exposes explicit exclusive-create/append/replace modes. Header, record batch, lock token, temporary object, fragment, and recovery manifest writes use this primitive; no ambient coding or annotation hook may touch already-hashed bytes.

The immutable header is:

```org
#+title: Epi session
#+EPI_FORMAT: 1
#+EPI_SESSION_ID: <uuid>
#+EPI_CREATED_AT: <Epi-RFC3339-profile>
#+EPI_PROJECT_ROOT: <canonical-absolute-directory>
#+EPI_CODING_SYSTEM: utf-8-unix
#+EPI_HEADER_SHA256: <hash>
```

The Epi RFC 3339 profile is deliberately narrower than the complete RFC
grammar: it requires uppercase `T` and `Z`, a four-digit year from `0000`
through `9999`, seconds from `00` through `59`, and an explicit `Z` or
`±HH:MM` offset from `00:00` through `23:59`. Optional fractional seconds
contain one or more decimal digits. Leap-second spellings are rejected because
the first slice has neither a maintained occurrence table nor a wall clock that
generates them.

The header hash is SHA-256 over UTF-8 bytes of a JCS object with the string keys `title`, `format`, `session_id`, `created_at`, `project_root`, and `coding_system`. Each level-one record then has one exact property drawer and one `epi-json` special block. The JSON block is one JCS envelope line terminated by LF. Its self hash is not inside that envelope; `EPI_RECORD_SHA256` holds SHA-256 of the exact stored UTF-8 JCS bytes between the block delimiters, excluding the single framing LF. `previous_hash` inside the envelope and `EPI_PREV_SHA256` in the drawer agree and point to the header hash or previous record hash.

Envelope keys are `id`, `type`, `schema`, `at`, `previous_hash`, optional `parent`, `target`, `turn`, and `operation`, then `payload`. Absent optional keys are omitted, not encoded as null. JSON null is represented only by `epi-json-null`. JSON false is represented only by `epi-json-false`.

Canonical data is restricted to string-keyed alists, vectors, strings, safe integers, finite floats, `t`, `epi-json-false`, and `epi-json-null`. Every key and string must contain Unicode scalar values only: reject surrogate code points, characters above U+10FFFF, malformed multibyte strings, and any unibyte string containing a byte above ASCII 0x7F unless the caller first decodes it with an explicit strict coding system. Also reject duplicate object keys, symbols other than the two sentinels and `t`, improper lists, non-finite floats, and integers outside ±9007199254740991.

`epi-ledger--jcs-encode` must conform to [RFC 8785](https://www.rfc-editor.org/info/rfc8785/):

- Sort object keys by their UTF-16BE code-unit bytes.
- Use JSON escaping without insignificant whitespace.
- Treat negative zero as `0`.
- Use fixed notation for normalized decimal exponents from -6 through 20 and scientific notation otherwise.
- Use lowercase `e`, include `+` for positive scientific exponents, and remove exponent leading zeros.
- Prove the complete Appendix B number corpus, rather than assuming `json-serialize` is canonical.

The implementation may use `json-serialize` only to obtain the runtime's shortest round-tripping primitive number digits. It must parse that token into sign, coefficient digits, and decimal position, remove redundant zeroes, and reformat it under the rules above. If the official corpus cannot be reproduced byte-for-byte, stop Task 3; do not change the format.

## Frozen First-Slice Record Schema

Every record uses schema 1. Envelope IDs duplicated in payload must agree.

| Type | Required envelope | Required payload |
|---|---|---|
| `session-info` | none | `session_id`, `working_directory`, `base_system_prompt`, `backend`, `model`, `request_params`, `tools`, `capability` |
| `operation-started` | `operation` | `operation_id`, `kind` |
| `turn-started` | `turn`, `operation` | `turn_id`, `operation_id`, `attempt_id`, `message_id`, `working_directory`, `base_system_prompt`, `resources`, `system_prompt`, `backend`, `model`, `request_params`, `tools`, `snapshot_hash` |
| `message` | `parent` when not a root, `turn` | `role`, `content` |
| `reasoning` | `turn` | `text`, zero-based provider `leg`, `replay` (false) |
| `leaf` | `target`, `operation` | empty object |
| `tool-planned` | `target`, `turn`, `operation` | `call_id`, `name`, `arguments`, `authority`, `order` |
| `tool-approved` | `target`, `turn`, `operation` | `call_id`, `policy`; `approved_diff_sha256` for mutation |
| `tool-denied` | `target`, `turn`, `operation` | `call_id`, `reason`, `model_result` |
| `tool-started` | `target`, `turn`, `operation` | `call_id`, `tool_version` |
| `tool-finished` | `target`, `turn`, `operation` | `call_id`, `status`, `details`; `model_result` required unless status is `uncertain` |
| `turn-finished` | `turn`, `operation` | `turn_id`, `status` |
| `turn-failed` | `turn`, `operation` | `turn_id`, `code`, redacted `details` |
| `turn-cancelled` | `turn`, `operation` | `turn_id`, `reason` |
| `turn-interrupted` | `turn`, `operation` | `turn_id`, `reason` |
| `operation-finished` | `operation` | `operation_id`, `status` (`success`) |
| `operation-failed` | `operation` | `operation_id`, `code`, redacted `details` |
| `operation-cancelled` | `operation` | `operation_id`, `reason` |
| `operation-interrupted` | `operation` | `operation_id`, `reason` |
| `recovery-origin` | none | source path/session/head, valid-prefix head, fragment object reference |

`turn-started.payload.message_id` is a typed forward-intent identifier, not an envelope `parent` or `target`. It names the user message that the same acceptance batch intends to append next and may be absent after a crash. This is the only first-slice forward reference. Every envelope `parent` and `target` remains backward-only. All tool lifecycle records target the assistant tool-call message and correlate their own `call_id` through payload.

`session-info` is the first record and is written atomically with the header before `epi-session-create` returns. It makes creation defaults durable even before the first prompt. Defaults are immutable in this slice. On open, built-in tools are rebound by exact name/version/schema; any non-built-in descriptor requires a caller-supplied matching `epi-tool` object before prompting. Runtime backend/model bindings must match the durable names.

Recognized message content objects are:

```json
{"type":"text","text":"..."}
{"type":"tool-call","call_id":"...","name":"...","arguments":{},"order":0,"group_id":null}
{"type":"tool-result","call_id":"...","name":"...","result":"...","status":"success"}
```

Reasoning is durable audit data but is omitted from first-slice replay. Operational tool records never enter provider context; the assistant tool-call message and tool-result message do.

`tool-planned.order` and tool-call content `order` are the same zero-based, turn-global counter allocated by Epi when the proposal is committed. GPTel does not supply it. The first-slice `group_id` is always `epi-json-null`. One call per leg means committed orders are `0, 1, 2, ...` across provider legs.

Cross-record tool equality is part of ledger validity, not merely a runtime convention. The assistant tool-call message and its immediately following `tool-planned` record have byte-identical `call_id` and `name`, JCS-identical `arguments`, and equal `order`; the message's `group_id` is null, `tool-planned.target` is that message's record ID, their turns are equal, and `tool-planned.operation` is the operation bound by that turn. Every later approved/denied/started/finished record for the call has the identical target, turn, operation, and call ID. A model-facing tool-result message immediately follows its terminal operational record, has parent equal to the targeted assistant tool-call message, has the same turn and call ID, repeats the proposal's name, and has `result` byte-equal to the terminal record's `model_result`. `tool-denied` maps only to result status `denied`; `tool-finished(success)` maps to `success`; `tool-finished(error|timeout|cancelled)` maps to `error`; and `tool-finished(uncertain)` forbids a result message. The lifecycle's turn must map to its operation through `turn-started`, including denial, approval timeout, execution timeout, cancellation, failure, and reopen synthesis. Any mismatch is corruption even when every individual record is well-formed and hash-valid.

Allowed `tool-finished.status` values are `success`, `error`, `cancelled`, `timeout`, and `uncertain`. `tool-denied` is terminal without a `tool-finished`. Provider-facing tool-result message statuses are `success`, `error`, or `denied`: timeout projects as `error`; cancellation and uncertainty terminate the operation without provider continuation. A call has exactly one of `tool-denied` or `tool-finished`, and `tool-finished` requires an earlier `tool-started`. `epi-tool-outcome.details` and every durable details payload are canonical string-keyed data, never symbol-keyed plists.

Terminal rules are exact:

- Success: `turn-finished(status=success)` then `operation-finished(status=success)`.
- Provider or runtime failure with no open call: `turn-failed` then `operation-failed`.
- Provider or runtime failure with an open call first terminalizes that call: planned -> `tool-denied(reason=operation-failed)` plus a truthful denied result; started and provably side-effect-free -> `tool-finished(status=error, details.code=<failure-code>)` plus a truthful error result; started with a possible unprovable side effect -> `tool-finished(status=uncertain)` and no result. Then append `turn-failed` and `operation-failed`.
- User abort with no open tool call: `turn-cancelled` then `operation-cancelled`.
- Abort while a call is planned but not started: `tool-denied(reason=operation-cancelled)`, its truthful denied tool-result message, `turn-cancelled`, then `operation-cancelled`; do not release the obsolete continuation.
- Abort while a started read or other provably side-effect-free call is running: `tool-finished(status=cancelled)`, its truthful error tool-result message, `turn-cancelled`, then `operation-cancelled`; do not continue the provider request.
- Reopen after a planned but unstarted call: `tool-denied(reason=interrupted)`, its truthful denied tool-result message, `turn-interrupted`, then `operation-interrupted`.
- Reopen after a started ordinary read: `tool-finished(status=error, details.code=interrupted)`, its truthful error tool-result message, `turn-interrupted`, then `operation-interrupted`.
- Normal execution, runtime failure, or user abort after a started mutation whose side effect cannot be disproved: `tool-finished(status=uncertain)`, `turn-failed(code=tool-uncertain)`, then `operation-failed(code=tool-uncertain)`. Reopen of the same evidence uses `tool-finished(status=uncertain)`, `turn-interrupted(reason=tool-uncertain)`, then `operation-interrupted(reason=tool-uncertain)`. Both append no guessed tool-result message, settle to phase `idle`, retain a reduced `blocked-reason`/uncertain-tool state, and never continue the provider request or admit another operation.

For every open call the exact durable order is call terminal, optional model-facing result message, turn terminal, operation terminal, then one committed `agent-settled` event keyed to the operation terminal's durable sequence. A planned/started suffix is accepted only until abort or conservative reopen terminalizes it. An uncertain terminal is valid audit history even though it deliberately leaves no provider-replayable tool result; the reducer blocks continuation rather than misclassifying that state as ledger corruption.

At most one terminal record is legal for a started turn or operation. An unfinished final suffix is valid only long enough for conservative reopen handling; duplicate or contradictory terminals are corruption.

## Frozen Public and Internal Interfaces

The public first-slice API in `epi.el` is:

```elisp
(cl-defun epi-session-create
    (project-root &key file working-directory backend model system-prompt tools))
(cl-defun epi-session-open (file &key backend model tools))
(defun epi-session-close (session))
(cl-defgeneric epi-session-p (object))
(defun epi-session-id (session))
(defun epi-session-file (session))
(defun epi-session-phase (session))
(defun epi-session-state (session))
(defun epi-session-prompt (session text &optional settled-callback))
(defun epi-session-abort (session))
(defun epi-session-wait (session &optional timeout))
(defun epi-session-select-leaf (session record-id))
(defun epi-session-subscribe (session function))
(defun epi-session-unsubscribe (session token))
(defun epi-tool-approve (session call-id))
(defun epi-tool-deny (session call-id &optional reason))
(cl-defun epi-session-recover-tail (file &key destination))
(defun epi-display-session (session))
(defun epi-display-tree (session))
(defun epi-display-ledger (session))
```

These forms freeze signatures, not facade-wrapper implementations.
`epi-session-p` is the one generic defined in `epi.el`, with a default method
that returns nil for every object; Task 8 adds the `epi--session` method.
`epi.el` installs autoload declarations for every other runtime- or UI-owned
name above and for the interactive names below. The owning module defines that
same public symbol when autoloaded; no parallel `epi-runtime-*` public API is
introduced.

One live-session registry is authoritative inside an Emacs process. It indexes both canonical file identity `(truename device inode)` and durable session ID; creation reserves canonical parent/name until publication supplies file identity. `epi-session-open` returns the exact existing session object only when file/session identity and supplied backend/model/tool bindings match. A conflicting binding, copied session ID, replaced path, or hard-link alias signals before constructing another runtime; an in-progress reservation signals `epi-busy`. `epi-session-close` signals `epi-busy` while an operation is active (the caller must abort/wait first), otherwise closes handles/buffers and unregisters only entries whose value is `eq` to that session, then becomes idempotent. Failed create/open removes only its own reservation token.

The public `epi-session-recover-tail` operation also participates in this registry. It atomically reserves the source canonical path, existing file identity, and durable session ID plus the destination canonical parent/name, any existing destination identity, and a newly allocated destination session ID before invoking the low-level closed-ledger recovery primitive. Acquisition uses one deterministic key order and rolls back only the caller's exact composite token. Any live session or create/open/recovery reservation reachable through a source or destination symlink, hard link, copied session ID, or path alias signals `epi-busy`, even when that live session is idle or failed; callers must close it first. Every success or failure releases the exact reservations in `unwind-protect`, publishes no live session object, and returns the canonical recovered-ledger path; a later explicit open performs normal validation. The low-level `epi-ledger-recover-tail` has no registry awareness and is used only after the runtime operation owns these reservations or in isolated closed-ledger tests. Symlink and hard-link aliases, duplicate/concurrent opens, failed-open cleanup, busy-close refusal, close/reopen, path replacement, and live/aliased/reserved recovery endpoints are contract tests.

`epi-event` is constructed only through one private validating constructor and
has raw read-only slots `kind`, `durability`, `session-id`, `generation`,
`operation-id`, `turn-id`, `attempt-id`, `call-id`, `record-id`, `sequence`,
`live-sequence`, and `payload`. The struct uses a private raw-accessor prefix
and generates no public copier. Durability is exactly `committed` or
`volatile`. A committed kind requires its positive durable `sequence` and
forbids `live-sequence`; a volatile kind requires its positive
`live-sequence` and forbids `sequence`. The constructor validates that kind and
durability agree. First-slice committed event kinds are the frozen record-type
symbols plus derived `tool-approval-needed` and `agent-settled`; each carries
the applicable durable record sequence, and `agent-settled` uses its operation
terminal's sequence. First-slice volatile kinds are `text-delta`,
`reasoning-delta`, `tool-progress`, and `diagnostic`; they are never replayed.

Construction copies every incoming string-valued slot and custom-deep-copies
the admitted canonical payload data: strings, conses, and vectors are rebuilt
recursively, while immutable atoms pass through. It does not rely on
`copy-tree`, and noncanonical mutable payload types are rejected. Public
`epi-event-*` accessors are ordinary functions over the private raw accessors:
each read returns a fresh copy of any string and performs the same custom deep
copy for `payload`. Mutating values returned by those supported accessors
cannot alter runtime/ledger state or a later accessor result. The underlying
`cl-defstruct` record is not a security boundary: direct sequence mutation such
as `aset`, or use of private raw accessors, is unsupported and may corrupt the
notification seen by a later observer. Runtime and ledger state never read
authority back from a dispatched event, so even unsupported representation
mutation cannot change the committed outcome. Dispatch itself does not make a
new event per subscriber: settlement subscribers and the one-shot callback
still receive the same `eq` `agent-settled` event object.
“Replayable” means a committed event can be reconstructed from ledger
reduction; first-slice subscription starts with the next event and does not
synthesize a backlog.

`epi-session-subscribe` calls `FUNCTION` as `(FUNCTION SESSION EVENT)` in registration order from the bounded drain and returns an opaque token owned by that session. Dispatch snapshots the current subscriber vector for one event. `epi-session-unsubscribe` returns non-nil exactly once for the matching session/token, returns nil thereafter or for another session, and affects only later events. Subscriber mutation, failure, and overrun cannot change an already committed outcome.

`epi-session-prompt` accepts `SETTLED-CALLBACK` only as nil or a function called once as `(FUNCTION SESSION EVENT)`, where `EVENT` is the same read-only committed `agent-settled` event object dispatched for that admitted operation. Validate the callback before admission; a rejected prompt never calls it. Prompt returns the durable operation ID before any settlement subscriber or callback can run, even if the adapter completes synchronously. At settlement the drain first dispatches the `agent-settled` event to the snapshotted subscribers in registration order, including any rescheduled remainder, and then invokes the one-shot callback exactly once. Its return value is ignored. An exception or budget overrun emits a diagnostic after the committed outcome, is not retried, cannot alter waiters or state, and does not prevent later drain work.

The stable module seams are:

```elisp
;; Ledger
(cl-defun epi-ledger-create
    (path &key session-id created-at project-root initial-drafts))
(defun epi-ledger-open (path))
(defun epi-ledger-refresh (ledger))
(defun epi-ledger--append (ledger drafts))
(cl-defun epi-ledger-recover-tail
    (path &key destination quarantine-directory destination-session-id))
(cl-defun epi-ledger-recover-stale-lock
    (path &key expected-token-sha256))
(cl-defun epi-ledger-object-put (ledger bytes &key media-type role))
(defun epi-ledger-object-get (ledger object-ref))
(defun epi-ledger-reduce (ledger))
(defun epi-ledger-branch (state &optional leaf-id))
(defun epi-ledger-context (state &optional leaf-id))

;; Resources
(cl-defun epi-resources-discover-instructions
    (project-root working-directory &key global-file))
(defun epi-resources-system-prompt (base-system resources))
(defun epi-resources-descriptors (resources))

;; Tools
(defun epi-tools-registry-create (&optional tools))
(defun epi-tools-register (registry tool))
(defun epi-tools-find (registry name))
(defun epi-tools-snapshot (registry names))
(defun epi-tools-policy (context tool call))
(defun epi-tools-preview (context call))
(defun epi-tools-execute (context call done))
(defun epi-tools-read-file ())
(defun epi-tools-replace-text ())

;; GPTel adapter
(defun epi-gptel-check-compatibility ())
(defun epi-gptel-start (snapshot enqueue))
(defun epi-gptel-submit-tool-result (request call-id result))
(defun epi-gptel-abort (request))
(defun epi-gptel-close (request))
```

Constructors containing `--` and all GPTel continuation values are private. Public callers receive opaque sessions and subscription tokens, copied summary plists, stable Epi events, and structured Epi errors.

Every Epi condition is signaled with data containing exactly one plist. That
plist is proper and even-length, and always has a non-nil symbolic `:code`;
any further keys are condition-specific. No condition adds a leading message
string, a second plist, or positional data. One private signaling helper first
requires `plistp` (or an equivalent proper/even-length check), then uses
`plist-member` to distinguish a missing `:code` before validating its value,
and finally calls `(signal condition (list plist))`; production call sites do
not assemble condition data independently. The complete inheritance tree is frozen as
follows:

```text
epi-error
├── epi-busy
├── epi-invalid-state
│   └── epi-stale-generation
├── epi-limit-exceeded
├── epi-ledger-error
│   ├── epi-ledger-format-error
│   ├── epi-ledger-corrupt
│   │   └── epi-ledger-truncated-tail
│   ├── epi-ledger-conflict
│   └── epi-missing-object
├── epi-gptel-error
│   ├── epi-gptel-incompatible
│   └── epi-provider-error
├── epi-tool-error
│   ├── epi-tool-denied
│   └── epi-tool-uncertain
├── epi-interaction-required
└── epi-cancelled
```

The interactive facade is `epi` (create and display), `epi-open-session`, `epi-send`, `epi-abort`, `epi-show-tree`, and `epi-show-ledger`. Display functions return a live buffer, reuse the buffer owned by the same session when present, and rebuild it from the ledger when killed.

The normalized adapter event kinds are closed:

```text
text-delta reasoning-delta reasoning-finished leg-finished
tool-proposed tool-result-observed transport-error
request-finished request-failed request-aborted
```

Ordinary adapter callbacks only copy data, append to a per-session FIFO, and schedule a zero-delay drain timer. They do not write ledgers, execute tools, render, invoke user subscribers, or settle operations in the Curl filter/sentinel stack. The synchronous exceptions are fail-stop controls inside `epi-gptel.el`: a request-local raw-transport guard counts the complete leg before GPTel inserts it, a pinned pre-parse safety auditor inspects complete SSE outer envelopes before GPTel decodes inner tool-argument JSON, the TOOL-state guard checks the result again before GPTel's stock handler, and abort may invalidate continuations/terminalize a handle. None constructs model semantics, executes a tool, releases a continuation, or advances a provider leg.

The first-slice tool-schema subset is a root object with `additionalProperties` false, a deterministic `properties` object, a `required` vector, and flat primitive properties of type string, integer, number, or boolean with optional description and same-type enum. A tool has at most 64 properties and required entries, 64 enum entries on one property, 256 enum entries total, and 256 KiB of canonical schema JSON. A proposal has at most 64 top-level argument members. Reject arrays, nested objects, null unions, combinators, references, defaults, pattern properties, and every keyword not proven byte-equivalent in the pinned GPTel dry-run payload.

## Frozen First-Slice Limits

Every configurable option named here is a public `defcustom`; the Type column
freezes its Customize `:type` contract, and tests bind and assert its default
and validated range. The one row marked as a fixed v1 invariant is deliberately
not customizable. “Positive integer” requires an integer greater than zero.
“Nonnegative seconds” requires a number greater than or equal to zero and is
stored in seconds even when the displayed default is in milliseconds.

| Limit | Public option or invariant | Default | Type | Failure behavior |
|---|---|---:|---|---|
| Ledger/recovery records per work slice | `epi-ledger-work-record-limit` | 256 | positive integer | Yield with private cursor |
| Historical reachable objects in one prepared recovery | fixed v1 `epi-ledger--recovery-atomic-object-limit` | 256 | fixed compatibility ceiling | Derived set rejects with `epi-limit-exceeded(code=recovery-atomic-object-limit)`; decoded one-over manifest is `recovery-manifest-invalid`; preserve source |
| Ledger/recovery I/O or lexical bytes per work slice | `epi-ledger-work-byte-limit` | 1 MiB | positive integer | Yield with private cursor |
| Ledger/recovery wall time per work slice | `epi-ledger-work-time-budget` | 8 ms | nonnegative seconds | Yield after current bounded unit |
| Canonical JSON bytes per record | `epi-record-json-byte-limit` | 15 MiB | positive integer | Reject before append; corrupt if stored input exceeds |
| Complete rendered record frame | `epi-record-frame-byte-limit` | 16 MiB | positive integer | Reject before append; corrupt if stored frame exceeds |
| Whole-record JSON materialization | `epi-record-decode-byte-limit` | 15 MiB | positive integer | One measured nonpreemptible decode unit between yields |
| One record/object/fragment SHA-256 input | `epi-hash-input-byte-limit` | 16 MiB | positive integer | One measured nonpreemptible hash unit between yields |
| JSON container nesting per record | `epi-json-depth-limit` | 32 | positive integer | Reject during encode or pre-decode lexical validation |
| JSON object members plus array elements per record | `epi-json-item-limit` | 131,072 | positive integer | Reject during encode or pre-decode lexical validation |
| First-slice immutable object | `epi-object-byte-limit` | 16 MiB | positive integer | Refuse object creation; preserve source |
| Torn final frame/fragment | `epi-recovery-fragment-byte-limit` | 16 MiB | positive integer | Refuse recovery; preserve source |
| Drain items per timer | `epi-drain-item-limit` | 128 | positive integer | Reschedule remaining FIFO |
| Drain bytes per timer | `epi-drain-byte-limit` | 512 KiB | positive integer | Reschedule remaining FIFO |
| Drain wall time per timer | `epi-drain-time-budget` | 8 ms | nonnegative seconds | Reschedule remaining FIFO |
| Queued callback items | `epi-callback-queue-item-limit` | 4,096 | positive integer | Invalidate generation and abort |
| Queued callback bytes | `epi-callback-queue-byte-limit` | 16 MiB | positive integer | Invalidate generation and abort |
| Queue overflow terminal reserve items | `epi-callback-queue-reserve-items` | 1 | positive integer | Unavailable to ordinary callbacks; carries one fixed failure |
| Queue overflow terminal reserve bytes | `epi-callback-queue-reserve-bytes` | 4 KiB | positive integer | Unavailable to ordinary callbacks; carries one fixed failure |
| One normalized callback event | `epi-callback-event-byte-limit` | 512 KiB | positive integer | Invalidate generation and abort |
| Raw tool-argument JSON | `epi-tool-argument-byte-limit` | 256 KiB | positive integer | Reject before GPTel's inner object materialization |
| Canonical tool-schema JSON | `epi-tool-schema-byte-limit` | 256 KiB | positive integer | Reject snapshot before GPTel dry-run |
| Properties per tool | `epi-tool-schema-property-limit` | 64 | positive integer | Reject snapshot |
| Required entries per tool | `epi-tool-schema-required-limit` | 64 | positive integer | Reject snapshot |
| Enum entries per property | `epi-tool-schema-enum-per-property-limit` | 64 | positive integer | Reject snapshot |
| Enum entries per tool | `epi-tool-schema-enum-total-limit` | 256 | positive integer | Reject snapshot |
| Top-level argument members | `epi-tool-argument-member-limit` | 64 | positive integer | Reject in pre-parse argument scanner |
| Provider call ID | `epi-provider-call-id-byte-limit` | 4 KiB | positive integer | Reject in pre-parse safety audit |
| Provider tool name | `epi-provider-tool-name-byte-limit` | 128 bytes | positive integer | Reject in pre-parse safety audit |
| Raw provider response per leg | `epi-provider-leg-raw-byte-limit` | 4 MiB | positive integer | Reject crossing chunk before GPTel buffer insertion |
| Raw provider response per turn | `epi-provider-turn-raw-byte-limit` | 32 MiB | positive integer | Fail turn; never start another leg |
| Provider text plus reasoning per leg | `epi-provider-leg-output-byte-limit` | 2 MiB | positive integer | Invalidate generation and abort |
| Provider text plus reasoning per turn | `epi-provider-turn-output-byte-limit` | 16 MiB | positive integer | Fail turn; never start another leg |
| Sequential tool calls per turn | `epi-provider-tool-call-limit` | 32 | positive integer | Fail before accepting call 33 |
| GPTel no-progress leg timeout | `epi-gptel-no-progress-timeout` | 120 seconds | nonnegative seconds | Diagnose, invalidate, abort |
| Human approval timeout | `epi-tool-approval-timeout` | disabled (`nil`) | nil or nonnegative seconds | Wait for decision; optional timer may durably deny |
| Accepted user prompt | `epi-user-prompt-byte-limit` | 2 MiB | positive integer | Reject before operation/turn acceptance |
| Base system prompt | `epi-system-prompt-byte-limit` | 256 KiB | positive integer | Reject session creation |
| One instruction resource | `epi-instruction-resource-byte-limit` | 256 KiB | positive integer | Fail preflight before snapshot |
| Aggregate instruction resources | `epi-instruction-total-byte-limit` | 1 MiB | positive integer | Fail preflight before prompt acceptance |
| Projected provider context | `epi-provider-context-byte-limit` | 16 MiB | positive integer | Fail preflight before GPTel dry-run |
| `read_file` result | `epi-read-file-result-byte-limit` | 1 MiB | positive integer | Return ordinary limit error without content |
| `replace_text` input file | `epi-replace-text-input-byte-limit` | 4 MiB | positive integer | Deny before preview |
| `replace_text` rendered diff | `epi-replace-text-diff-byte-limit` | 1 MiB | positive integer | Deny before approval |
| Initial rendered messages | `epi-ui-initial-message-limit` | 200 | positive integer | Offer explicit load-earlier action |
| Conversation content per render action | `epi-ui-conversation-action-byte-limit` | 1 MiB | positive integer | Insert bounded preview and continuation button |
| Tree nodes per render action | `epi-ui-tree-node-limit` | 1,000 | positive integer | Insert collapsed continuation nodes |
| Tree label bytes per node | `epi-ui-tree-label-byte-limit` | 384 bytes | positive integer | Truncate display label; preserve ID on button |
| Tree content per render action | `epi-ui-tree-action-byte-limit` | 512 KiB | positive integer | Insert continuation node |
| Subscriber/settled callback budget | `epi-callback-time-budget` | 4 ms | nonnegative seconds | Diagnose; disable repeating subscriber |

The fixed recovery ceiling counts only historical entries in
`reachable_objects`; the current torn fragment's separate `fragment_object`
does not count against it. Preparation verifies those objects cooperatively
once under the source lock, freezes their exact identities, then raw-restats
each identity after callback boundaries. That closing proof cannot yield
without reopening the mutation race, so v1 bounds it independently of every
user-tunable work-slice option.

The remaining Task 1 public customization is also frozen:

| Setting | Public option | Default | Type |
|---|---|---|---|
| Session ledger directory | `epi-session-directory` | `(expand-file-name "epi/sessions/" user-emacs-directory)` | directory |
| Optional global instruction file | `epi-global-instructions-file` | `nil` | nil or file |

Time has two separate private, dynamically bindable sources. The wall-clock
source supplies time values only for durable timestamps in the Epi RFC 3339
profile defined above. The deadline
source supplies numeric seconds for budgets and timeouts. Its production
default samples `float-time`'s epoch wall time and returns the maximum of that
sample and a process-local high-water mark. It is therefore monotonicized wall
time, not an operating-system monotonic primitive: a backward wall-clock jump
can stall the reported value and delay a budget until wall time catches up,
while a forward jump may expire work early and fail closed. The high-water value
is never persisted or treated as cross-process time. Hard item/byte limits and
Emacs relative timers remain the authoritative safety bounds; the deadline
clock measures elapsed work between them. Tests
bind the wall clock and the deadline clock independently and reset/bind the
deadline high-water state; no test advises `current-time`, `float-time`, or
global random state.

Tests use small dynamically bound values; production code never waits 120 seconds in ERT. A normalized event's charged size is 4 KiB base plus copied text/ID/name bytes, the raw argument byte count retained as a cost (not as a second string), and 256 bytes per canonical argument member. Flat arguments contain at most 64 members and their decoded string bytes are bounded by the charged raw JSON bytes, so the 512 KiB event ceiling is conservative; FIFO byte accounting sums this charge. One item and 4 KiB of each FIFO maximum are reserved and cannot admit ordinary callbacks. An ordinary enqueue that would cross either reduced admission ceiling is discarded, latches overflow, invalidates/aborts, and appends exactly one fixed-charge `request-failed(code=queue-overflow)` control event into that reserve; all later callbacks are dropped. Thus total item/byte counters never cross their published maxima and prior accepted events drain before the failure. Byte limits are measured over UTF-8 model-visible or canonical bytes as applicable, not `length` alone. A wall-time budget is checked between bounded units and cannot preempt one Elisp primitive. I/O and lexical scanning obey every 1 MiB/8 ms slice boundary; before decoding, the lexical state machine counts maximum live object/array depth and the cumulative number of object members plus array elements, rejecting either structural limit one unit over. Each whole-record JSON decode and each bounded `secure-hash` over a record, object, or recovery fragment is a separately measured nonpreemptible unit; inputs are capped at 15 MiB for record JSON and 16 MiB otherwise, and the cursor yields before and after each such primitive. Cooperative work pumps retain partial scan/reduce/recovery state only in a private cursor, call an injectable yield function between slices and nonpreemptible units, and revalidate session generation plus source identity/head before publication.

## Dependency DAG

```text
T1 package/test foundation
 ├── T2 GPTel seam proof
 └── T3 canonical codec ── T4 validation ── T5 store ─┬─ T6 recovery ─┐
                                                      └─ T7 reducer ──┴─ T8 fake runtime
                                                                        ├── T9 resources
                                                                        └── T10 tools
T2 + T7 + T10 ─────────────────────────────────────── T11 GPTel driver
T2 + T6 + T8 + T9 + T10 + T11 ───────────────────── T12 integration
T12 ── T13 UI ── T14 acceptance ── T15 hardening ── T16 documentation
```

## Task 1: Establish the Package and Deterministic Test Foundation

**Files:**

- Create: `Makefile`
- Create: `epi.el`
- Create: `test/epi-test-helper.el`
- Create: `test/run-tests.el`
- Create: `test/checkdoc.el`
- Create: `test/epi-preflight-test.el`
- Create: `test/epi-package-test.el`

**Interfaces produced:** `epi-error` hierarchy, JSON sentinels, `epi-event`,
frozen customization, deterministic ID/wall-clock/deadline-clock indirections,
autoloaded public facade, and batch commands.

- [x] Create the initial `test/epi-test-helper.el` with only test loading,
  temporary-root, deterministic-ID, and independently bindable wall/deadline
  clock helpers. Every helper-owned symbol is prefixed `epi-test-`; this file
  never defines, advises, or substitutes a production Epi symbol and does not
  load GPTel merely by being loaded. Before implementing the preflight
  validator, runner, Makefile, or `epi.el`, write both
  `test/epi-preflight-test.el` and `test/epi-package-test.el`.

- [x] In `test/epi-preflight-test.el`, specify the validator behavior for an
  exact source-only resolution and its injected stale sibling `.elc`, earlier
  shadow directory, and native-artifact failures, using
  `epi-test-preflight-validate` as the explicit validator entry point. Also
  specify that loading `epi-test-helper` leaves GPTel unloaded, that all
  validator utilities are named `epi-test-*`, and that a child invocation of
  `test/run-tests.el` with a selector matching zero loaded tests exits nonzero
  with the exact `SELECTOR matched zero loaded ERT tests` diagnostic. The
  assertion must distinguish that diagnostic from a missing runner or
  unrelated child-process failure.

- [x] In `test/epi-package-test.el`, require `epi-test-helper` but register all
  ERT tests without a top-level `require` of `epi`. Every test enters one shared
  `epi-test-with-epi-loaded` fixture that calls `(require 'epi)` only when the
  selected test executes. This lets the runner load and count the tests before
  the intentional missing-package failure. Cover feature loading; the exact
  condition inheritance tree; condition data as exactly one proper,
  even-length plist with a present, non-nil symbolic `:code` through the private
  signaling helper; rejection of improper, odd, missing, nil, and nonsymbol
  data; direct and transitive condition parents; every frozen option name,
  default, and type; all private raw read-only event slots; absence of a public
  event copier; constructor rejection of kind/durability or positive-sequence
  mismatches; construction-time and per-access deep-copy isolation for strings,
  conses, and vectors; rejection of noncanonical mutable payload data;
  independently injected IDs, wall timestamps, and deadline samples; the
  default-false `epi-session-p` generic; runtime/UI autoload declarations; and
  the fact that loading `epi` does not load GPTel.

```elisp
(ert-deftest epi-package-load-is-gptel-lazy ()
  (epi-test-with-epi-loaded
    (should (featurep 'epi))
    (should-not (featurep 'gptel))))

(ert-deftest epi-package-errors-have-stable-code ()
  (epi-test-with-epi-loaded
    (let ((condition
           (should-error
            (epi--signal 'epi-invalid-state
                         (list :code 'not-idle :session-id "s-1"))
            :type 'epi-invalid-state)))
      (should (= 1 (length (cdr condition))))
      (should (eq (plist-get (cadr condition) :code) 'not-idle)))))
```

- [x] Run the new infrastructure contract directly, before the runner and
  Makefile exist:

```sh
direnv exec . "$EPI_EMACS" --batch -Q -L test \
  -l ert -l test/epi-test-helper.el -l test/epi-preflight-test.el \
  --eval "(ert-run-tests-batch-and-exit \"^epi-preflight-\")"
```

Expected red: the behavioral validator cases fail with
`void-function epi-test-preflight-validate`, and the zero-selector case fails
because it does not observe the exact
`SELECTOR matched zero loaded ERT tests` runner diagnostic. A missing test,
zero selected tests, or an unrelated load error is not the intended red.

- [x] Run the package contract directly, still before the Makefile exists:

```sh
direnv exec . "$EPI_EMACS" --batch -Q -L . -L test \
  -l ert -l test/epi-package-test.el \
  --eval "(ert-run-tests-batch-and-exit \"^epi-package-\")"
```

Expected red: the file loads and registers at least one `epi-package-*` test,
then the selected tests fail when their fixture reports
`Cannot open load file ... epi`. A top-level load failure or zero selected tests
is not the intended red.

- [x] Now implement all preflight validator and probe utilities in
  `test/epi-test-helper.el`, each under the `epi-test-*` namespace; create
  `test/run-tests.el` and the Makefile infrastructure.
  `epi-test-preflight-validate` is the validator entry point used by the tests
  and `make preflight`.
  Loading the helper alone still must not load GPTel. Only an explicit
  validator call may start its clean `--batch -Q` source-resolution probe.
  Before that probe loads GPTel, require `locate-library` for `gptel`,
  `gptel-request`, and `gptel-openai` to resolve the exact truenamed `.el`
  paths in `GPTEL_ROOT`; reject an earlier shadow, sibling `.elc`, or
  corresponding native `.eln`. Disable native JIT, force source-only
  resolution, load those absolute source files in dependency order, and verify
  representative pinned functions' `symbol-file` paths plus source hashes.
  The validator also checks the exact Pi and JCS commits/files/hashes listed
  above from `PI_ROOT` and `JCS_ORACLE_ROOT`, reports every observed mismatch,
  and performs no clone, fetch, install, checkout, or source rewrite.

- [x] Run the infrastructure tests directly once more, before asking the
  Makefile to trust them:

```sh
direnv exec . "$EPI_EMACS" --batch -Q -L test \
  -l ert -l test/epi-test-helper.el -l test/epi-preflight-test.el \
  --eval "(ert-run-tests-batch-and-exit \"^epi-preflight-\")"
```

Expected green: the three injected artifact probes fail closed for their exact
reasons, the clean injected probe passes, helper loading leaves GPTel unloaded,
and the runner's zero-match regression observes the dedicated nonzero exit.

- [x] Run `direnv exec . make preflight`. The target first runs those isolated
  probes, then validates the real declared inputs exactly. Any probe or input
  mismatch stops implementation before `epi.el` is created.

- [x] Re-run the still-red package contract through the stable runner:

```sh
direnv exec . make test-one TEST=test/epi-package-test.el SELECTOR='^epi-package-'
```

Expected red: nonzero ERT exit with `Cannot open load file ... epi`; the runner
must report that it selected at least one `epi-package-*` test.

- [x] Implement `epi.el` with `lexical-binding: t`, Package-Requires for Emacs
  30.1, Org 9.7, GPTel 0.9.9.5, Transient 0.7.8, and Compat 30.1.0.0;
  `defgroup`; every exact public `defcustom` name/default/type frozen above;
  the complete condition hierarchy and one-plist signal contract;
  `epi-json-false` and `epi-json-null`; and the privately constructed
  `epi-event`. Give its struct a private raw-accessor prefix, suppress its
  public copier, and make every raw slot read-only. The private constructor
  validates event kind/durability compatibility and the positive
  sequence/live-sequence inverse, copies input strings, and custom-deep-copies
  only canonical string/cons/vector payloads. Public accessors copy strings and
  custom-deep-copy payload on every read; do not use `copy-tree`.

- [x] Define these conditions with the exact frozen parent relationships:
  `epi-error`; direct children `epi-busy`, `epi-invalid-state`,
  `epi-limit-exceeded`, `epi-ledger-error`, `epi-gptel-error`,
  `epi-tool-error`, `epi-interaction-required`, and `epi-cancelled`;
  `epi-stale-generation` under `epi-invalid-state`;
  `epi-ledger-format-error`, `epi-ledger-corrupt`, `epi-ledger-conflict`, and
  `epi-missing-object` under `epi-ledger-error`;
  `epi-ledger-truncated-tail` under `epi-ledger-corrupt`;
  `epi-gptel-incompatible` and `epi-provider-error` under `epi-gptel-error`;
  and `epi-tool-denied` and `epi-tool-uncertain` under `epi-tool-error`.
  Route every production signal through one private helper that rejects
  non-plists, improper or odd-length plists, and a missing, nil, or nonsymbol
  `:code`, using `plist-member` before calling
  `(signal condition (list plist))`.

- [x] Add dynamically bindable private functions/variables for UUID generation,
  Epi-profile RFC 3339 wall time, the process-local nondecreasing deadline clock, its
  high-water state, and cooperative yield. Implement the deadline default as
  the frozen process-local, nonpersisted high-water mark over `float-time` epoch
  wall time; do not describe or test it as an OS monotonic clock. Keep hard
  item/byte bounds and relative timers authoritative. Tests bind both clocks
  independently and never advise `current-time`, `float-time`, or global
  random state.

- [x] Define `epi-session-p` as a `cl-defgeneric` whose default method returns
  nil. Install autoload declarations for the public runtime/UI functions and
  interactive commands and public UI mode functions; mark command autoloads
  interactive. Tasks 8 and 13 define those exact symbols in their owning
  modules. Do not add facade wrappers, fallback semantics, or parallel
  `epi-runtime-*` public functions.

- [x] Implement `test/checkdoc.el` with `checkdoc-current-buffer`, not `checkdoc-batch`. Add isolated build directories for `.elc` output and cleanup.

- [x] Run the focused test again. Expected green: all `epi-package-*` tests pass and zero unexpected results.

- [x] Run:

```sh
direnv exec . make compile
direnv exec . make checkdoc
```

Expected: no warnings, errors, or source-tree `.elc` files.

- [x] Commit:

```sh
git add Makefile epi.el test/epi-test-helper.el test/run-tests.el test/checkdoc.el test/epi-preflight-test.el test/epi-package-test.el
git commit -m "build: establish the Epi package test foundation"
```

## Task 2: Prove the Pinned GPTel Seam Before Depending on It

**Files:**

- Create: `epi-gptel.el`
- Create: `test/epi-gptel-contract-test.el`
- Create: `test/epi-gptel-fixture-transport.el`
- Create: `test/fixtures/gptel/text.sse`
- Create: `test/fixtures/gptel/reasoning.sse`
- Create: `test/fixtures/gptel/read-tool.sse`
- Create: `test/fixtures/gptel/write-tool.sse`
- Create: `test/fixtures/gptel/final.sse`
- Create: `test/fixtures/gptel/malformed.sse`
- Create: `test/fixtures/gptel/error.json`

**Interfaces produced:** `epi-gptel-snapshot`, `epi-gptel-event`, `epi-gptel-request`, capability diagnostic, dry-run/start seam, fixture transport driver, and opaque continuation table.

**Source contract:** Re-read `gptel-request.el` around callback dispatch, dry-run realization, FSM transitions, terminal `:post` actions, effective request materialization, model sanitization, tool continuations, `gptel-curl--stream-filter`, stream completion, and abort; re-read `gptel-openai.el` around `gptel-curl--parse-stream`, streaming/nonstreaming call IDs, and typed history. At the pinned revision the streaming parser decodes inner function arguments before the TOOL handler, inspects only `tool_calls[0]`, and skips the tool branch when the same delta contains nonempty content. Record those source line anchors and expected function hashes in test comments because GPTel declares its FSM unstable; the seam is incompatible if any anchor contract changes.

**Task boundary:** `epi-tools.el`, `epi-ledger.el`, and runtime message structs do not exist yet. This seam task consumes copied provider-neutral descriptor/history alists owned by `epi-gptel-snapshot` and fixture helpers; it must not require or stub later production modules. Tasks 11–12 connect the proven seam to the real Epi structs without changing the contract.

- [x] Write contract tests for exact backend/model selection, effective Curl streaming, text/reasoning/nil/t/tool-call/tool-result callback forms, per-leg versus request completion, terminal post actions, abort both during transport and while paused in TOOL, redacted errors, two- and three-leg sequential tools, exact raw call IDs, and typed replay.

```elisp
(ert-deftest epi-gptel-contract-leg-finish-is-not-terminal ()
  (epi-test-with-gptel-fixtures '("text.sse" "final.sse")
    (let ((events (epi-test-run-gptel-contract
                   (epi-test-text-snapshot))))
      (should (= 1 (epi-test-count-kind events 'leg-finished)))
      (should (= 1 (epi-test-count-kind events 'request-finished)))
      (should (< (epi-test-event-index events 'leg-finished)
                 (epi-test-event-index events 'request-finished))))))

(ert-deftest epi-gptel-contract-sequential-call-id-survives-replay ()
  (let* ((first (epi-test-run-tool-contract "call_read_17"))
         (history (epi-test-reopen-history first))
         (data (epi-test-gptel-dry-run-data history)))
    (should (equal "call_read_17"
                   (epi-test-openai-tool-call-id data)))))
```

- [x] Run:

```sh
direnv exec . make test-one TEST=test/epi-gptel-contract-test.el SELECTOR='^epi-gptel-contract-'
```

Expected red: missing `epi-gptel` types and driver functions.

- [x] Define the adapter structs and constant `epi-gptel-capability` with value `openai-chat-completions/sequential-tools-v1`. The capability report includes GPTel version, commit, backend family, streaming mode, typed-history mode, sequential-tool limit, and every disabled feature.

- [x] Build the request with `gptel-request :dry-run t`. Resolve the exact named backend, require classic `gptel-openai` rather than `gptel-openai-responses`, require the exact model before GPTel can sanitize it, require Curl, and inspect the realized FSM info before starting it.

- [x] Force all request-sensitive settings buffer-locally. Translate Epi's false sentinel to GPTel's request sentinel `:json-false`; effective dry-run data must contain `parallel_tool_calls` as JSON false whenever tools exist. If GPTel overwrites or omits that setting, fail compatibility rather than accepting possible parallel calls.

- [x] Compile Epi tools to unregistered GPTel tools with a fail-closed stub function, `:async t`, and `:confirm t`. Reject schemas outside the frozen subset, copy before GPTel preprocesses it, and compare effective dry-run `tools[].function.parameters` with an independently normalized expected object. Force `gptel-confirm-tool-calls` so GPTel only returns proposals.

- [x] Attach Epi's terminal closure to the FSM `:post` list before explicitly transitioning `INIT -> WAIT` in the hidden buffer. Treat callback `t` as `leg-finished` only. Terminal settlement comes only from the post action.

- [x] Install two narrowly scoped safety guards without replacing GPTel's transport, response semantics, callback, or FSM. Replace the pinned FSM WAIT action only with `epi-gptel--handle-wait`, which calls a captured, hash-verified function object for stock `gptel--handle-wait` exactly once. During that stock call, temporarily intercept `set-process-filter`; when stock Curl setup installs `gptel-curl--stream-filter`, install instead a request-local closure over that exact stock filter and capture the process/FSM. Refuse zero, multiple, or unexpected filter installations. Delegating the complete stock WAIT handler must preserve its per-leg clearing of `:tool-result`, `:tool-use`, `:error`, `:http-status`, `:reasoning`, and `:tokens`, its Curl dispatch, and its buffer-local post-request-hook call; never call `gptel-curl-get-response` directly from the replacement. The closure maintains a request-wide raw-byte total from request start to terminal and a leg total reset only after a documented `leg-finished` and immediately before the guarded continuation starts the next leg. It checks both totals before delegating an unchanged safe chunk; a crossing chunk terminalizes without insertion. Restore `set-process-filter` before returning, and leave a non-Epi request's WAIT action/filter untouched.

- [x] Add an around method for the pinned `gptel-curl--parse-stream` that acts only when its `info` belongs to an Epi request. Before calling the stock method, scan every newly complete `data:` outer envelope from a private audit marker, parse that outer JSON with duplicate detection while retaining each `function.arguments` fragment as raw text, and inspect every element/index in `delta.tool_calls`. At a completed call, feed the concatenated raw argument string to a bounded single-pass Epi safety scanner before GPTel's `gptel--json-read-string`: require one flat root object, at most 64 members, unique decoded string keys present in the frozen schema, primitive values of the declared type, safe finite numbers, and same-type enum membership; reject nested values, null, trailing data, or malformed escapes. Discard transient decoded scalars. Cache by raw call ID only the exact bounded raw string and a nonsemantic attestation containing byte length/SHA-256, member count, tool-schema fingerprint, and validation generation; do not construct or cache the canonical argument alist and emit no text, reasoning, call, history, result, or other provider-semantic event.

- [x] On parallel indices, more than one distinct call, mixed nonempty text and tool content, duplicate outer keys, malformed outer JSON, oversized ID/name/raw arguments, argument member/schema violation, or another capability violation, the pre-parse auditor invalidates the generation and invokes the adapter's exactly-once fail-stop path without calling the stock parser for that envelope. In the safe case it calls the stock parser exactly once on the original buffered bytes. “Before GPTel argument parsing” means the Epi bounded argument scanner completes before GPTel calls `gptel--json-read-string`; parsing the containing SSE JSON and validating the frozen flat argument object are safety duties, not an alternate provider response loop.

- [x] Replace the pinned FSM's TOOL handler with an adapter-owned guard that runs before the stock handler. It requires exactly one call, no text/tool mixture, a declared frozen tool name, and a valid raw argument object. On failure it sets a redacted adapter error and transitions directly to `ERRS`; it never invokes GPTel's stock tool handler or starts another leg. On success it delegates to the stock handler so GPTel still owns execution sequencing.

- [x] On the resulting declared-tool callback, require one pending continuation and one raw attestation. Copy the GPTel-accepted ID and name, correlate them with the complete raw OpenAI `function.arguments` JSON retained for that call, and require byte equality with the scanner-cached raw string plus equality of length/SHA-256/schema fingerprint/generation. Only now run a separate bounded callback normalizer over those exact bytes to construct the duplicate-free canonical flat Epi alist, rechecking the attestation before enqueue. Then erase both raw bytes and attestation. Never derive durable arguments from GPTel's lossy keyword plist, and never normalize a call that GPTel did not semantically accept.

- [x] On replay, convert a fresh copy of Epi's flat canonical argument object to GPTel's keyword-plist/sentinel representation before typed-history construction. Prove nested object/array/null schemas are rejected, while empty root object, false, strings, safe numbers, duplicate-key rejection, and reopen round trips preserve the enabled subset.

- [x] Keep the transport fixture support internal to `epi-gptel.el`. `test/epi-gptel-fixture-transport.el` supplies byte fixtures, but tests call an Epi-owned driver and never call provider parsers or FSM accessors directly. Dynamically replace only `gptel-curl-get-response` for the full asynchronous request lifetime.

- [x] Add negative tests: missing model, compiled/shadowed GPTel artifacts, non-Curl transport, ineffective streaming, Responses API, other provider, missing raw call ID, two calls in one vector, a later nonzero tool index, calls split across deltas, same-delta mixed text/tool, later-delta mixed text/tool, undeclared-only tool proposal, mixed declared/undeclared proposals, unsupported schema/argument shapes, duplicate inner argument keys, duplicate outer envelope keys, call ID/name/raw argument JSON exactly at and one byte above each limit, single- and multi-leg raw totals exactly at and one byte above their leg/turn limits, media, replayed reasoning, steering, configuration refresh, malformed SSE, transport error, duplicate continuation, callback exception, a request stuck in GPTel's TOOL state without a delivered proposal, a valid proposal held past the leg timeout for human approval, concurrent Epi requests, and an unrelated non-Epi GPTel request. Seed every cleared WAIT-info key with a distinct non-nil sentinel before leg two and prove the captured stock handler clears all six before Curl setup, invokes the buffer-local hook exactly once, and still reaches the real pinned filter/parser/FSM. Rejected fixtures never reach its inner-argument parse, TOOL handler, tool function, continuation, or second transport leg; valid approval waits do not fire the leg watchdog, and non-Epi requests remain untouched.

- [x] Exercise the WAIT interception failure contract directly: make the captured stock handler install no process filter, install twice, and install one function other than the exact pinned `gptel-curl--stream-filter`. Each case must take one redacted incompatible/fail-stop terminal path, restore the original `set-process-filter`, leave no process/continuation registered, and never invoke an unexpected filter. The one-install control must wrap and delegate to the exact stock filter once.

- [x] Start a resettable leg watchdog only while a network leg awaits provider progress. A valid tool-proposal callback plus captured continuation is documented completion of that network leg: cancel its watchdog before enqueuing the proposal, and do not arm the next leg until the guarded continuation actually starts it. Human `tool-policy` wait and tool execution are owned by separate runtime policy/executor timers and can outlast the leg timeout. On expiry without a valid callback, invalidate continuations and attempt public `gptel-abort`. If no transport is registered because GPTel reached TOOL without delivering a valid proposal, the adapter owns terminalization: atomically mark the request terminal, enqueue one `request-failed`, and close the handle without advancing the FSM. `epi-gptel-abort` uses the same exactly-once fallback but emits `request-aborted`. Do not synthesize or release an unproven continuation.

- [x] Set `gptel-post-request-hook` buffer-locally to nil. Add a hostile global-hook contract proving it never runs from Epi's hidden buffer.

- [x] Run focused tests. Expected green: every contract event sequence and exact request-data assertion passes offline.

- [x] Run all Task 1 and Task 2 tests, compile, and checkdoc.

- [x] **Fail-closed gate:** If the pinned GPTel cannot preserve typed two- and three-leg sequential calls, raw IDs, exactly-once continuation, or terminal observation, stop implementation and report the failing fixture and source anchor. Do not build a provider loop outside GPTel.

- [x] Commit:

```sh
git add epi-gptel.el test/epi-gptel-contract-test.el test/epi-gptel-fixture-transport.el test/fixtures/gptel
git commit -m "test: prove the pinned GPTel adapter contract"
```

## Task 3: Implement the Version-One Canonical Record Codec

**Files:**

- Modify: `Makefile`
- Create: `epi-ledger.el`
- Create: `test/epi-ledger-codec-test.el`
- Create: `test/generate-jcs-goldens.el`
- Create: `test/fixtures/jcs/appendix-b.el`
- Create: `test/fixtures/jcs/independent-goldens.json`
- Create: `test/fixtures/ledger/header.org`
- Create: `test/fixtures/ledger/one-message.org`
- Create: `test/fixtures/ledger/adversarial-text.org`

**Interfaces produced:** header, draft, record, ledger, object-ref, message structs; JCS encoder; header and record sealing; strict framing parser and renderer.

- [x] Transcribe the complete RFC 8785 Appendix B number inputs and expected strings into a data-only fixture. Generate the independent canonical byte strings and SHA-256 digests with `node "$JCS_ORACLE_ROOT/node-es6/verify-canonicalization.js"` plus `test/generate-jcs-goldens.el`, an Emacs Lisp driver that invokes the pinned `canonicalize.js` in a separate Node process without adding JavaScript to the Epi tree. Record repository URL, commit, source hashes, exact command, Node version, and input hash in fixture metadata. `make jcs-goldens` first runs `make preflight`, checks Node, and compares the oracle's shipped input/output vectors; it rewrites the fixture only under an explicit `EPI_UPDATE_GOLDENS=1`. Tests consume only fixed goldens and never require JavaScript at runtime. Add Unicode key-order, escaping, negative-zero, safe-integer-boundary, non-finite, duplicate-key, lone-surrogate, U+10FFFF, U+110000, unibyte ASCII, unibyte non-ASCII, malformed multibyte, and unsupported-value cases.

- [x] Generate and review the independent fixture explicitly:

```sh
direnv exec . env EPI_UPDATE_GOLDENS=1 make jcs-goldens
git diff --check -- test/fixtures/jcs
```

Expected: the pinned oracle's own vectors pass before the Epi fixture changes; metadata names the exact oracle commit, hashes, Node version, and command. A second run is byte-identical.

```elisp
(ert-deftest epi-jcs-rfc-boundaries ()
  (dolist (case '((-0.0 . "0")
                  (0.000001 . "0.000001")
                  (0.0000001 . "1e-7")
                  (1e20 . "100000000000000000000")
                  (1e21 . "1e+21")))
    (should (equal (cdr case)
                   (epi-ledger--jcs-encode (car case))))))

(ert-deftest epi-jcs-sorts-keys-by-utf16 ()
  (should
   (equal (epi-test-jcs-unicode-order-golden)
          (epi-ledger--jcs-encode
           (epi-test-jcs-unicode-order-object)))))
```

- [x] Run:

```sh
direnv exec . make test-one TEST=test/epi-ledger-codec-test.el SELECTOR='^epi-jcs-'
```

Expected red: `void-function epi-ledger--jcs-encode`.

- [x] Implement a recursive, type-checking JCS encoder. Encode key sort values as BOM-free UTF-16BE bytes. Normalize `json-serialize` number tokens with the explicit coefficient/decimal-position algorithm. Never canonicalize an alist after converting it through a hash table. Count live container nesting and cumulative object members plus array elements while encoding; reject depth 33 and entry 131,073 before retaining unbounded output.

- [x] Make record sealing count canonical output bytes while encoding and stop before retaining output beyond the 15 MiB canonical-JSON limit; render framing only when the complete frame remains within 16 MiB. The cold framing parser checks both stored frame size and JSON byte-range size before lexical validation or JSON parsing. Its incremental lexical validator tracks string/escape state, live object/array depth, and cumulative object members plus array elements without allocating decoded values; only size- and structure-compliant bytes reach `json-parse-string`. Treat the whole-record JSON decode as one measured nonpreemptible unit between cooperative yields, never as part of the 1 MiB I/O/lexical slice counter. Add exact-limit and one-over fixtures for nesting and container entries, plus exact-limit and one-byte-over fixtures for highly escaped strings and maximum framing overhead, not only ordinary ASCII.

- [x] Run the JCS group. Expected green: every official vector and negative input passes.

- [x] Write exact golden tests for the header, root hash, one record, property order, block delimiters, LF normalization, omitted optionals, and record hash. The expected strings and hashes are literal fixtures, not generated by the code under test.

```elisp
(ert-deftest epi-ledger-codec-round-trips-org-looking-text ()
  (let* ((text "* forged headline\n:END:\n#+end_epi-json\nNUL? no")
         (record (epi-test-seal-user-message text))
         (bytes (epi-ledger-render-record record))
         (parsed (epi-test-parse-single-record bytes)))
    (should (equal text (epi-test-record-text parsed)))
    (should (equal (epi-record-hash record)
                   (epi-record-hash parsed)))))
```

- [x] Implement strict header and level-one record framing without invoking Org Babel, property evaluation, or general Org interpretation. Hash the exact stored JSON byte range before decoding. A single-pass JCS lexical validator checks whitespace, minimal escapes, canonical number syntax, duplicate/sorted keys, and UTF-16 key order without rebuilding a second serialized copy; then parse the JSON as data and verify semantic drawer agreement.

- [x] Define the complete first-slice payload validators from the schema table. Verify the frozen Epi RFC 3339 timestamp profile, including year `0000`, uppercase `T`/`Z`, explicit offset, and rejection of leap-second spellings; also verify UUID/ID, lowercase hash, role, content type, call ordering, and sentinel types. Redacted details remain canonical data.

- [x] Add delimiter-injection, control-character, CRLF input, malformed UTF-8, drawer/JSON disagreement, self-hash-in-envelope, unknown schema, unknown record type, and noncanonical-but-semantically-equivalent JSON failures.

- [x] Run all codec tests, then all prior tests, compile, and checkdoc.

- [x] **Fail-closed gate:** If exact RFC number bytes, UTF-16 ordering, or the independent canonical-byte/digest goldens cannot be reproduced, stop. Do not substitute ordinary `json-serialize` output or a locale sort.

- [x] Commit:

```sh
git add Makefile epi-ledger.el test/epi-ledger-codec-test.el test/generate-jcs-goldens.el test/fixtures/jcs test/fixtures/ledger
git commit -m "feat: define the canonical Epi ledger codec"
```

## Task 4: Implement Ledger Loading and Semantic Validation

**Files:**

- Modify: `epi-ledger.el`
- Modify: `test/epi-ledger-codec-test.el`
- Create: `test/fixtures/ledger/corrupt-*.org`
- Create: `test/fixtures/ledger/torn-*.org`

**Interfaces produced:** read-only `epi-ledger-open`, full-chain validation, clean/torn/interior classification, and structured ledger conditions.

**Completion:** Implemented in
`7125bfc9d9e72e6295832f3029152c0c2aaa8456`
(`feat: validate Epi ledger structure and history`). The final candidate
passed 477/477 offline tests, warning-as-error compilation, Checkdoc for all
three production files, exact preflight, and independent staged and
post-repair reviews. The sealed implementation and test hashes are recorded
in `WIGGUM-HANDOFF.md`.

- [x] Add tests whose fixtures each isolate one violation: bad header, missing/duplicate/non-first `session-info`, a hash-valid mismatch between header `EPI_SESSION_ID` and `session-info.payload.session_id`, unsupported format/schema, duplicate ID, forward parent/target, impossible record target, previous-hash mismatch, payload hash mismatch, property mismatch, orphan tool result, invalid tool status/pairing, duplicate call ID, duplicate terminal, contradictory terminal, clean EOF, truncated final headline/drawer/block/JSON, and valid unfinished suffix.

```elisp
(ert-deftest epi-ledger-open-identifies-corrupt-record ()
  (let ((error
         (should-error
          (epi-ledger-open
           (epi-test-fixture "ledger/corrupt-previous-hash.org"))
          :type 'epi-ledger-corrupt)))
    (should (eq 'previous-hash-mismatch
                (plist-get (car (cdr error)) :code)))
    (should (= 4 (plist-get (car (cdr error)) :sequence)))))

(ert-deftest epi-ledger-open-does-not-repair-torn-tail ()
  (let* ((file (epi-test-copy-fixture "ledger/torn-final-json.org"))
         (before (epi-test-file-bytes file)))
    (should-error (epi-ledger-open file)
                  :type 'epi-ledger-truncated-tail)
    (should (equal before (epi-test-file-bytes file)))))
```

- [x] Run:

```sh
direnv exec . make test-one TEST=test/epi-ledger-codec-test.el SELECTOR='^epi-ledger-open-'
```

Expected red: open either accepts corruption or lacks structured conditions.

- [x] Implement one forward scan as an iterative cursor that records byte offsets, sequence numbers, ID-to-record mappings, file identity, validated end offset, and tail hash. Process I/O and lexical work at no more than the frozen records/bytes/time budget per slice, cooperatively yield, and resume without exposing partial state. Treat each exact stored-JSON `secure-hash` as one separately timed nonpreemptible unit after its 15-MiB size check; yield immediately before and after it and report exceptional duration. Revalidate file identity before returning the completed ledger. Keep payload bodies only in record objects; indexes refer to those objects and do not copy content.

- [x] Validate that every envelope parent/target refers backward to an allowed record family, every lifecycle ID agrees between envelope and payload, and no entity has more than one terminal. Enforce the frozen cross-record tool equality byte-for-byte/JCS-for-JCS: proposal message versus `tool-planned`; every lifecycle target/turn/operation/call ID; result parent/turn/call/name/model-result; and the exact denied/success/error/timeout/cancelled/uncertain status mapping. Add individually hash-valid negative fixtures for every unequal duplicated field, wrong timeout/cancellation mapping, result after uncertainty, missing required result, and result attached to a different call or operation. Permit only the typed `turn-started.payload.message_id` forward intent and require the later user message to match it when present.

- [x] Classify a suffix as truncated only when the valid prefix ends exactly before one incomplete final frame. Any complete malformed frame, hash failure, bytes after a fragment, or impossible reference is interior corruption.

- [x] Signal one plist as condition data, beginning with `:code` and including path, sequence, record ID, byte offset, and a redacted nested `:cause` where available. Tests assert codes and identifiers, never prose.

- [x] Confirm `epi-ledger-open` performs no writes, lock takeover, recovery, quarantine, object creation, or UI activity.

- [x] Run all ledger codec/validation tests and all prior tests.

Cold open reads adjacent bounded pathname ranges into an unibyte buffer,
parses exact buffer source regions, and retains no second frame-sized JSON
copy. Every requested read, delimiter scan, and buffer transfer is charged.
Finalization produces a bounded private record index before a final
chain-head check, deliberate yield, and identity restat; publication below
that restat performs constructors and field stores only. The portable-Elisp
pathname ABA boundary and the fixed header-value limit are normative design
constraints, not unrecorded implementation exceptions. That boundary also
governs identity-checked rollback deletion because portable Emacs has no
inode-conditional remove primitive. Impossible final JSON prefixes are
interior corruption; only lexically completable prefixes qualify as a
truncated tail.

- [x] Commit:

```sh
git add epi-ledger.el test/epi-ledger-codec-test.el test/fixtures/ledger
git commit -m "feat: validate Epi ledger structure and history"
```

## Task 5: Implement Private Storage, Locking, Append, and Objects

**Files:**

- Modify: `epi-ledger.el`
- Create: `test/epi-ledger-io-test.el`

**Interfaces produced:** `epi-ledger-create`, private batched `epi-ledger--append`, object put/get/presence, explicit stale-lock recovery.

- [x] Write temporary-file tests for 0700 directories, 0600 files, staged no-clobber create, a crash before/after creation publication, one-flush batched append, distinct linked hashes within a batch, exact preservation of existing bytes, file-identity/head races, lock ownership, and immutable objects.

```elisp
(ert-deftest epi-ledger-append-rejects-a-stale-head-without-writing ()
  (epi-test-with-ledger (file first)
    (let ((stale (epi-ledger-open file)))
      (epi-ledger--append first
                          (vector (epi-test-message-draft "winner")))
      (let ((before (epi-test-file-bytes file)))
        (should-error
         (epi-ledger--append stale
                             (vector (epi-test-message-draft "loser")))
         :type 'epi-ledger-conflict)
        (should (equal before (epi-test-file-bytes file)))))))

(ert-deftest epi-ledger-object-put-is-content-addressed ()
  (epi-test-with-ledger (_file ledger)
    (let ((one (epi-ledger-object-put
                ledger (string-make-unibyte "abc")
                :media-type "text/plain" :role "test"))
          (two (epi-ledger-object-put
                ledger (string-make-unibyte "abc")
                :media-type "text/plain" :role "test")))
      (should (equal (epi-object-ref-hash one)
                     (epi-object-ref-hash two)))
      (should (equal "abc" (epi-ledger-object-get ledger one))))))
```

- [x] Run:

```sh
direnv exec . make test-one TEST=test/epi-ledger-io-test.el SELECTOR='^epi-ledger-'
```

Expected red: append/create/object functions are absent.

- [x] Implement `epi-ledger-create` with canonical local-path checks, private directory creation, and one precomputed byte string containing the complete header plus `initial-drafts`, whose first and only session-default record must be a valid `session-info`. Acquire an exclusive create lock whose expected file identity is `absent`, write/flush/read-verify the complete mode-0600 bytes at a hidden temporary sibling, revalidate that the destination is absent, and publish while the lock is held by atomically creating a same-directory hard link with `add-name-to-file` and overwrite disabled. Treat removal of the temporary source name as postpublication cleanup; a cleanup failure may leave both complete names for the same inode and must report `storage-publication-failed` with `:published t`. Refuse an existing path. A crash may expose only a recognized hidden temporary, a complete normal ledger, or both complete names, never a header-only normal session. A filesystem without hard-link support fails closed before publication.

- [x] Define a canonical lock token containing host, PID, process-start identity from `(alist-get 'start (process-attributes pid))`, nonce, canonical ledger path, expected file identifier, expected validated offset, and expected head hash. Create `FILE.epi-lock` through the private byte writer's exclusive-create mode, independent of `create-lockfiles`. Bind `default-directory` to the proven-local ledger parent while obtaining the current process identity; missing, malformed, or signaling self attributes fail with a structured conflict before lock creation or any other write.

- [x] Permit automatic takeover only for a same-host token when either a present process has a different normalized start identity, proving PID reuse, or `process-attributes` is nil and a supported local `list-system-processes` snapshot omits the PID. Nil attributes alone are indeterminate, as are an unavailable process list, a listed PID whose start identity cannot be read, and a remote owner. Bind `default-directory` to the proven-local ledger parent for both probes and signal `epi-ledger-conflict` for every indeterminate case.

- [x] Add module-level `epi-ledger-recover-stale-lock`. It accepts the expected token SHA-256, archives that exact token, obtains a fresh exclusive lock, and revalidates the complete file identity/head before doing anything. It never treats token age alone as proof.

- [x] Implement the private no-conversion local-byte writer specified above and use it for create, lock tokens, append, object temporaries, recovery artifacts, and manifests. Bind `write-region-inhibit-fsync` to nil at durability barriers. Hostile coding-system, format, file-name-handler, annotation, and post-annotation tests must leave exact bytes unchanged.

- [x] Implement append as one critical section: lock; restat and validate identity/head; fill draft IDs/times from deterministic indirections; pre-seal all records in order; render one UTF-8/LF unibyte string; append once through the byte writer; parse and hash the realized suffix; update the in-memory ledger only after verification; release only the token this process owns.

- [x] Add injected operation seams for lock creation, append, flush boundary, stat, read-back, and unlock. Tests simulate every failure without advising built-ins globally. Any failure before the append leaves bytes unchanged; any uncertain post-write failure forces a fresh full validation before another append.

- [x] Implement object storage at `FILE.objects/sha256/<prefix>/<hash>`. Enforce the first-slice object-byte limit before hashing or writing, and reject any ledger object reference whose declared size exceeds it during validation. Treat each at-most-16-MiB object SHA-256 as a measured nonpreemptible primitive with a cooperative yield immediately before and after; chunked copy/write I/O still obeys the ordinary slice budget. Write and flush a mode-0600 temporary sibling, then atomically publish with same-directory `add-name-to-file` and overwrite disabled before unlinking the temporary source name as postpublication cleanup. If a concurrent writer won, accept the existing object only after byte length and SHA-256 verification. A mismatched pre-existing path is corruption, and a filesystem without hard-link support fails closed before publication.

- [x] Make object reads unibyte, size/hash verified, and fail with `epi-missing-object` for absence or mismatch. Before reading, stat the path and reject a file larger than either the declared bounded size or 16 MiB; read at most declared-size-plus-one bytes, require exact length, then hash. Add exact-cap, declared-size mismatch, replaced-oversize, and one-byte-over tests. Never infer reachability or semantic order from directory contents.

- [x] Test disabled ordinary Emacs lockfiles, malformed/remote/indeterminate tokens, nil or signaling current-process attributes, nil process attributes with a listed PID, signaling or unavailable process lists, same-host death proven by a supported process list, PID reuse with a different start identity, canonical-local `default-directory` for current-process identity and both stale-owner probes even under a remote ambient value, failure before write or takeover when those probes are inconclusive, a one-shot takeover race, token replacement during unlock, a competing head update, mismatched pre-existing object, and missing referenced object.

- [x] Run all ledger tests and all prior tests.

- [x] Commit:

```sh
git add epi-ledger.el test/epi-ledger-io-test.el
git commit -m "feat: append Epi ledgers under an explicit lock"
```

## Task 6: Implement Explicit Torn-Tail Recovery

**Files:**

- Modify: `epi-ledger.el`
- Modify: `test/epi-ledger-io-test.el`
- Modify/extend: `test/fixtures/ledger/recovery/torn-*.org` (keep the five
  Task 4 root `torn-*.org` fixtures unchanged)

**Interfaces produced:** the closed-ledger `epi-ledger-recover-tail` primitive, fragment object evidence, quarantine layout, recovery-origin records. The registry-aware public facade is added in Task 8 after the runtime registry exists.

**Implementation progress (2026-07-23):** Waves 0–5 of the frozen eight-wave
execution brief are committed. `0abdfe9` adds exact torn-tail inspection,
`a32cad6` adds recovery-origin admission and evidence semantics, `bcad789` adds
deterministic frame-free planning plus streaming reseal, `9caa866` adds closed
same-device preflight and exclusive durable publication of the canonical
`prepared` manifest, and `7654e76` stages the exact sorted object set plus the
verified hidden destination ledger before advancing only to
`objects-transferred` under the source lock. `501be5b` publishes the verified
destination objects and ledger, moves the complete original evidence through
two verified hard-link hops, and advances the manifest through
`quarantine-published` while preserving the frozen lock order. Wave 4 also
closes receipt authority around documented callbacks, binds live lock-token bytes to their
decoded source epoch, and keeps exact-old classification, rollback, and
prepared-state reclosure in one automatic-GC-free, callback-free epoch. Its close gate passed 240/240
recovery tests, 370/370 ledger-I/O tests, 342/342 codec/JCS tests, the complete
fresh-process offline matrix, warning-as-error byte compilation, Checkdoc,
preflight, parenthesis, diff, and artifact checks, plus independent production,
test, and frozen-scope reviews. Wave 5's close gate passed 496/496 ledger tests
across three parallel shards, 342/342 codec/JCS tests, 79/79 GPTel tests, 30/30
package tests, 26/26 preflight tests, warning-as-error byte compilation,
Checkdoc, parenthesis, diff, and Pandoc gates, plus independent production,
test, resource, and frozen-scope reviews. Wave 6a.1 is committed as `84ea7d3`:
the strict file-level restart helper converges source-only, exact same-inode
dual-name, and target-only states while failing closed on conflicting or
drifting authority. Wave 6a.2, the complete two-root evidence-tree union
converger, is the next implementation boundary. The remaining Task 6
checkboxes deliberately stay open until their resume and refusal behavior
exists.

**Wave 5 committed checkpoint (2026-07-23):** commit
`501be5b77d414a7dc0ae8f0edbd8d7e8947ff704` advances through
`quarantine-published`, holds source
and destination locks in the frozen order, publishes destination objects before
the ledger, and preserves the complete original object directory through both
verified hard-link hops. The manifest's 256-entry `reachable_objects` ceiling
remains independent of the quarantine census: the latter uses a private
complete proof stored as ordered vectors of at most 256 leaves and an opaque
process-local projection handle, so generic projection budgets do not scale
with unreachable evidence. The proof format is chunk-bounded, but Phase 1 may
materialize and comparison-sort one complete prefix directory while building
or validating it; Task 15 owns census scale instrumentation and optimization.
Normal GC remains enabled during full-object and final-authority walks while
`post-gc-hook` is suppressed. Focused regressions cover 257 total
source leaves with one reachable object, empty object-directory topologies,
malformed proof fields, foreign handles, exact quarantine identity/bytes, and
the independent reachable-object limit. The committed source SHA-256 is
`481a04c6dd9307e721ed9f73a329bb26ef392299143f80d6f8608590b5b93fa0`;
the committed test SHA-256 is
`94bd4ad0e4a5e69b42b26e5c97d6b31ac1a1bff2ed214089d61c20beb040868b`.
The branch is published at `origin/codex/epi-first-slice`.

Wave 6 must reconstruct and reconcile a partially moved evidence tree after
process death. Its restart matrix includes both source-to-stage and
stage-to-quarantine hops, death after target link creation but before source
unlink, and death after any proper prefix of leaves has moved. Re-entry proves
the union of both roots and the same-inode two-link case before deciding which
names to retain; the Wave 5 transfer helper itself is deliberately not treated
as idempotent restart logic. Task 6 proves production reconciliation with
representative deterministically constructed states for every durable phase
and pre-action/post-action class. Task 15 owns actual worker-process deaths,
exhaustive first/middle/last interruption permutations and repetitions, and
census scale/counter acceptance. Version one persists the exact required
reachable-object set but not its complete unreachable-evidence census. Fresh
re-entry therefore requires every persisted reachable leaf, authenticates
every present union leaf, and preserves valid unreachable union members; it
does not claim to detect an unreachable leaf missing from both roots. Extending
the durable schema to make that stronger claim is outside Task 6.

- [ ] Write tests for truncation after every byte class in a final record, unchanged source bytes, new session identity, semantic preservation of the valid prefix, fragment hash/object, reachable-object transfer, recovery provenance, destination collision, and refusal of interior corruption.

```elisp
(ert-deftest epi-ledger-recovery-preserves-evidence-and-changes-session ()
  (let* ((source (epi-test-copy-fixture "ledger/torn-final-json.org"))
         (source-bytes (epi-test-file-bytes source))
         (source-id (epi-test-header-session-id source))
         (recovered (epi-ledger-recover-tail source))
         (origin (epi-test-last-record recovered)))
    (should-not (equal source-id
                       (epi-header-session-id
                        (epi-ledger-header recovered))))
    (should (equal source-bytes
                   (epi-test-quarantined-source-bytes recovered)))
    (should (equal 'recovery-origin (epi-record-type origin)))
    (should (epi-test-recovery-fragment-verifies-p recovered origin))))
```

- [ ] Run:

```sh
direnv exec . make test-one TEST=test/epi-ledger-io-test.el SELECTOR='^epi-ledger-recovery-'
```

Expected red: `epi-ledger-recover-tail` is missing.

- [ ] Treat `epi-ledger-recover-tail` as a low-level closed-ledger primitive: its caller must already own the runtime registry reservations when a runtime exists, and direct use is limited to isolated closed-ledger tests. Scan matching manifests before allocating anything. Accept an optional pre-reserved destination session ID; otherwise allocate one for those tests. When `destination` is nil, use `<canonical-source-parent>/<destination-session-id>.org`; an unfinished matching manifest freezes both values on retry. Acquire and revalidate the source filesystem lock, then classify the tail again. Recovery is legal only for one incomplete final frame after a fully valid prefix. Refuse a multiply linked source ledger because moving one name cannot prove the original evidence was quarantined.

- [x] Because the recovered ledger has a new header and root hash, re-seal the logical valid-prefix records under the new hash chain through the same records/bytes/time-budgeted work cursor. Preserve record IDs, types, timestamps, parents, targets, lifecycle IDs, and payloads except that the first `session-info.payload.session_id` must change to the destination session ID so header and record remain consistent; change chain-dependent hashes and physical offsets. Test semantic equality explicitly with this named identity substitution rather than claiming byte identity for the destination prefix.

- [ ] Store the exact trailing fragment bytes in the destination object store with media type `application/octet-stream` and role `recovery-fragment`. The `recovery-origin` payload records original canonical path, source session ID, source file byte size, source header hash, source valid-prefix head, fragment offset/hash/size/object reference, and destination's corresponding valid-prefix head. `source_evidence_sha256` is SHA-256 over the no-LF UTF-8 JCS bytes of a closed object containing `kind = epi-recovery-source-evidence`, `version = 1`, and every payload field except the digest itself. The at-most-16-MiB fragment hash is one measured nonpreemptible unit bracketed by cursor yields; reading/copying its bytes remains sliced. Do not compute a redundant ordinary digest over the complete ledger: the validated record chain authenticates the prefix and the fragment digest authenticates every remaining byte.

- [x] Add the semantic `recovery-origin` transition before treating any
  recovered destination as openable. Append exactly one new origin per
  transaction; allow payload-identical historical origins only after their
  prior recovery barrier was reconciled, require unique evidence hashes, and
  bind the newest origin's destination valid-prefix head to its actual
  predecessor. Recompute every origin's source evidence digest; admit the new
  origin after every otherwise valid recoverable
  suffix without erasing the suffix state; and suspend ordinary adjacency
  only for the prescribed recovery terminalization. Ordinary message,
  provider, or tool continuation remains forbidden until Task 8 terminalizes
  the preserved suffix. Add Task 6 fixtures for every proposal, planned,
  approved, started, result-pending, select-leaf, intended-message, and
  uncertainty suffix class, together with explicit Task 8 reopen fixtures.

- [ ] Copy or hard-link every reachable source object admitted by the fixed
  256-entry v1 historical-object ceiling into the new object's store, then
  verify its length and hash through the destination path. The current fragment
  object is separate from that historical set. Iterate objects and bounded copy
  chunks through the recovery cursor, yielding between units; a verified
  same-inode hard link need not recopy bytes. Do not carry unreachable directory
  entries into the new session.

- [ ] Resolve quarantine before recovery creates anything. A default-store ledger uses `<epi-session-directory>/quarantine`; a custom ledger uses sibling `<source-parent>/.epi-quarantine`; an explicit override is accepted only after source-parent and quarantine-parent device identities prove same-filesystem rename. A cross-device or indeterminate result fails with unchanged source, objects, destination, and quarantine. Allocate a recovery UUID and write canonical, fsynced `<quarantine-directory>/.epi-recovery/<recovery-id>/manifest.jcs` before any publication or move. The immutable manifest binds exact source path/session/device/inode/size/change identity, header hash, valid-prefix end/head, fragment offset/size/hash, source-evidence digest, quarantine device, destination path/session/head, and the sorted at-most-256-entry historical reachable-object set, together with hidden staging paths and the final quarantine path. Each live attempt establishes a fresh process-local identity epoch for those objects only after complete size/hash verification, then raw-restats that epoch across callback boundaries; identities are not persisted across crashes. Re-entry revalidates the chain, exact fragment, and reachable object contents rather than hashing the whole ledger in one unbounded operation. A replace-by-rename phase field has exactly these monotonic values: `prepared`, `objects-transferred`, `destination-objects-published`, `destination-ledger-published`, `source-ledger-staged`, `source-objects-staged`, and `quarantine-published`. Record an explicit absent-source-object marker so the same phases apply when no source object directory exists.

- [ ] Build the destination under hidden sibling names. Exclusively reserve and populate the destination object directory first, publish its canonical verified completion marker, and publish the destination ledger last, so normal session discovery cannot observe a ledger whose objects are absent. Then move the original ledger and original object directory, without byte changes, through the manifest's hidden quarantine staging paths into an exclusively reserved visible quarantine directory and publish its canonical fsynced `complete.jcs` marker last. Never use check-then-rename as a no-clobber directory primitive; normal discovery ignores every hidden recovery/staging path and every quarantine directory without its marker.

- [ ] On entry, scan matching recovery manifests before starting a new recovery. Resume each phase idempotently by verifying the manifest-bound source, destination, staged files, and hashes; never infer completion from absence alone. A process crash after destination publication or between the two source moves must converge to one validated destination plus one complete quarantine directory without losing, duplicating, or overwriting evidence. Delete the manifest and empty hidden staging root only after the `quarantine-published` manifest update has been flushed/read-verified and both final trees have been re-statted and hash-verified. Do not claim directory-entry durability beyond Emacs's available file flush semantics.

- [ ] Expose test-only injected barriers after source validation, reachable-object transfer, destination object publication, destination ledger publication, source-ledger move, source-object-directory move, and final quarantine publication. Task 15 kills worker processes at every barrier and proves restart from the manifest.

- [ ] Exclude quarantine paths from normal session discovery. A second recovery attempt, destination collision, missing reachable object, changed source head, or changed lock token fails without overwriting either copy.

- [ ] Test that a complete malformed record, hash break, duplicate ID, extra bytes after a fragment, fragment exactly at and one byte above the 16 MiB complete-frame cap, oversized object, impossible parent, injected cross-device identity, or unstatable quarantine parent never enters recovery. Every refusal leaves the exact source and its objects in place and creates no manifest or destination.

- [ ] Run all ledger tests, all prior tests, compile, and checkdoc.

- [ ] Commit:

```sh
git add epi-ledger.el test/epi-ledger-io-test.el test/fixtures/ledger
git commit -m "feat: recover torn Epi tails without rewriting evidence"
```

## Task 7: Implement Pure Reduction, Branches, and Typed Context

**Files:**

- Modify: `epi-ledger.el`
- Create: `test/epi-reducer-test.el`
- Create: `test/fixtures/ledger/forked-session.org`
- Create: `test/fixtures/ledger/sequential-tools.org`

**Interfaces produced:** `epi-state`, `epi-message`, active-leaf/branch/children projections, provider-neutral context, in-memory incremental refresh.

- [ ] Port the behavior—not the TypeScript shape—of Pi's session-manager tree traversal, build-context, and tool history tests. Cover a root, fork, nested fork, explicit leaf selection, continuation after selection, sequential calls, and deep-chain, wide-star, and balanced-tree shapes.

```elisp
(ert-deftest epi-reducer-leaf-selection-branches-by-append ()
  (epi-test-with-forked-ledger (ledger ids)
    (epi-test-append-complete-leaf-operation
     ledger (plist-get ids :first-assistant))
    (epi-ledger--append
     ledger
     (vector (epi-test-message-draft
              "alternative" :parent (plist-get ids :first-assistant))))
    (let* ((state (epi-ledger-reduce ledger))
           (branch (epi-ledger-branch state)))
      (should (equal (epi-test-record-texts branch)
                     '("root" "first answer" "alternative"))))))

(ert-deftest epi-reducer-projects-paired-tool-history ()
  (let ((messages
         (epi-ledger-context
          (epi-ledger-reduce
           (epi-ledger-open
            (epi-test-fixture "ledger/sequential-tools.org"))))))
    (should (equal '("call-1" "call-2")
                   (epi-test-context-call-ids messages)))
    (should (equal '(0 1) (epi-test-context-call-orders messages)))))
```

- [ ] Run:

```sh
direnv exec . make test-one TEST=test/epi-reducer-test.el SELECTOR='^epi-reducer-'
```

Expected red: reducer and branch/context functions are absent.

- [ ] Implement a pure iterative fold over validated records. Produce session/project identity, record-by-ID references, child-ID vectors, active leaf, active branch IDs, operation/turn status, interruption or uncertain-tool state, and ordered provider-neutral messages. Accumulate each parent's children with O(1)-amortized insertion, then finalize each edge into a vector exactly once; branch/context/tree traversal uses explicit worklists rather than Elisp recursion.

- [ ] Apply conversation semantics exactly: a conversation message's parent is the prior model-visible conversation record; operational records do not become tree nodes; a tool-result message is the child of its assistant tool-call message; `leaf` targets a conversation message, carries its turnless structural operation ID, and is not context; the next message after the completed selection operation uses that target as parent.

- [ ] Project `prompt`/user text, `response`/assistant text, and paired tool call/results without provider types. Retain call ID, name, arguments, result, status, order, and nullable group ID. Omit reasoning from first-slice replay and reject unpaired or parallel history except for a terminal uncertain call, which is retained as blocked audit state and omitted from context. A three-leg fixture with two completed calls and a final text leg must preserve turn-global orders `0` and `1` after cold reopen; no reducer derives order from list position.

- [ ] Detect orphan results, duplicate calls, impossible tree edges, conversations rooted in operational records, and terminal contradictions as deterministic reducer errors, not UI warnings. A planned or started call without its terminal is legal only inside the final nonterminal operation suffix: expose it as typed unfinished-call state so abort/reopen can conservatively terminalize it. A completed uncertain call with no model-result message is likewise valid audit state and reduces to blocked continuation, not corruption.

- [ ] Add `epi-ledger-refresh` for a still-live ledger object. It may validate only bytes after its trusted in-memory `validated-end` when file identity and the prefix head still agree; otherwise it signals conflict or performs an explicit cold reopen. Do not create a persistent index in this slice.

- [ ] Prove that discarding every in-memory index and reopening cold yields identical state/context; state indexes point to record objects rather than duplicating payload bodies. Instrument edge insertions/copies and traversal stack depth on chain, star, and balanced fixtures: each edge is inserted once and copied at most once during vector finalization, every traversal visits no node more than once, and Elisp recursion depth remains constant.

- [ ] Run reducer, ledger, and all prior tests.

- [ ] Commit:

```sh
git add epi-ledger.el test/epi-reducer-test.el test/fixtures/ledger/forked-session.org test/fixtures/ledger/sequential-tools.org
git commit -m "feat: reduce Epi ledgers into branches and typed context"
```

## Task 8: Implement the Runtime FSM Against a Fake Adapter

**Files:**

- Create: `epi-runtime.el`
- Create: `test/epi-runtime-test.el`
- Modify: `test/epi-test-helper.el`

**Interfaces produced:** opaque live session, operation and pending-tool values, runtime API behind the public facade, fake adapter protocol, semantic event FIFO and settlement.

- [ ] Define a scripted adapter in `test/epi-test-helper.el` that implements the same five operations as the GPTel adapter—start, submit tool result, abort, close, and compatibility—but contains no GPTel value. Script events synchronously and through timers.

- [ ] Write lifecycle tests for atomic creation of the header plus `session-info`, base-prompt and user-prompt byte limits, create-close-open before the first prompt, exact backend/model and empty-tool-set rebinding on open, one-operation admission, acceptance-before-start, streaming volatility, slow-drip per-leg/turn output and call-count limits, O(1) chunk/FIFO accounting, final message commit, leg completion, success/error/abort terminality, timeout, close, reopen interruption, stale generation, subscriber arity/order/unsubscribe/failure/overrun, the settled-callback arity/event identity/deferred ordering/exception/overrun contract, turnless leaf-selection settlement, and every ledger commit barrier. Add canonical-path, symlink, hard-link, copied-session-ID, duplicate/concurrent-open, conflicting-binding, failed-reservation, replaced-path, exact-close-unregister, close/reopen, and recovery-registry cases. Recovery cases cover live idle/active/failed source, hard-link and symlink source aliases, copied source session ID, live or existing destination alias, create/open/recovery reservation on either endpoint, partial acquisition rollback, exact-token cleanup on every error, success cleanup, and explicit open of the returned destination. Include planned-before-start and started-read/mutation fixtures for both abort and reopen; assert exactly one call terminal precedes the optional result message, turn terminal, operation terminal, and one `agent-settled`.

```elisp
(ert-deftest epi-runtime-prompt-is-durable-before-adapter-start ()
  (epi-test-with-runtime (session adapter)
    (epi-session-prompt session "hello")
    (should
     (equal '(operation-started turn-started message)
            (epi-test-record-types-before-adapter-start adapter)))))

(ert-deftest epi-runtime-leg-finished-does-not-settle ()
  (epi-test-with-runtime (session adapter)
    (epi-session-prompt session "hello")
    (epi-test-adapter-emit adapter 'leg-finished nil)
    (epi-test-drain-events)
    (should-not (epi-test-event-kind-seen-p session 'agent-settled))
    (should (eq 'turn (epi-session-phase session)))))
```

- [ ] Run:

```sh
direnv exec . make test-one TEST=test/epi-runtime-test.el SELECTOR='^epi-runtime-'
```

Expected red: the runtime module and its autoloaded public definitions are
absent; `epi.el` contains declarations, not placeholder delegates.

- [ ] Define opaque `epi--session`, `epi-operation`, and `epi-pending-tool` structs. Keep session ID, canonical file, project root, durable working directory/base system prompt/backend/model/request parameters/tool descriptors/capability, generation, phase, reduced blocked reason, ledger/state, request buffer/handle, operation, subscribers, committed/live sequence counters, FIFO, drain timer, registry, pending tool, and closed flag. The private `epi--session` struct keeps its private generated predicate (or suppresses it); it must never generate, alias, or overwrite the public `epi-session-p` generic.

- [ ] Define the runtime-owned public names declared by the Task 1 autoloads
  directly in `epi-runtime.el`, and add an `epi-session-p` method specialized
  on `epi--session`. Do not replace the generic or introduce wrapper-facing
  `epi-runtime-*` public names.

- [ ] Implement one private live-session registry with separate file-identity, canonical-path-reservation, and session-ID maps. Reserve using an opaque token before any cooperative open/create work; publish the exact session object only after validation. An identical completed open with identical bindings returns that object; every alias/conflict fails or reports busy as frozen above. Cleanup and close use compare-and-remove against the exact token/object so a stale failure cannot unregister a newer session. Implement `epi-session-recover-tail` on that same registry: atomically acquire a deterministic-order composite reservation for source path/identity/session ID and destination path/existing identity/new session ID, reject every live or reserved alias with `epi-busy`, pass the reserved new ID to `epi-ledger-recover-tail`, and release only the exact composite token on every exit without publishing a session.

- [ ] Use injectable adapter functions privately; production defaults resolve to `epi-gptel-*`, while tests dynamically bind the complete set to the fake adapter. Do not branch on a `fake` provider inside production logic.

- [ ] Implement phases:

```text
idle -> preparing -> turn
turn -> tool-policy -> tool-execution -> turn
turn -> settling -> idle
turn/tool-* -> settling -> idle
open unfinished -> settling -> idle
open uncertain mutation -> settling -> idle + reduced blocked-reason
```

- [ ] Keep phase and recovery state orthogonal. A session may be phase `idle` yet carry a reduced `blocked-reason`; such a session rejects prompts, leaf changes, approvals, and all other new operations until a later reconciliation feature clears it. No transition targets a `blocked` phase.

- [ ] Create a session by reserving its canonical path, validating the base prompt's encoded-byte limit, constructing immutable defaults and a `session-info` draft, then passing it to `epi-ledger-create` so header plus first record publish atomically. Publish the session in both registry indexes before returning. Close and reopen that session before any turn and prove that working directory, base prompt, backend/model, request parameters, the temporary empty tool vector, and fake-adapter capability come only from the ledger. Exact built-in/custom tool rebinding is deferred to Task 12, after `epi-tools.el` exists.

- [ ] Admit a prompt only from unblocked idle and reject its encoded bytes above the user-prompt limit before allocating an operation. Use the task-local empty resource vector until Task 9 supplies discovery, allocate all IDs, and append `operation-started`, `turn-started`, and the user message in one batch. Copy the durable base prompt/defaults into `turn-started`. Return the operation ID only after read verification, then start the adapter.

- [ ] Copy adapter events into a head/tail per-session FIFO with O(1) enqueue/dequeue. A zero-delay timer drains at configurable item, byte, and elapsed-time quotas, preserving order. Deduct the frozen one-item/4-KiB control reserve from both ordinary admission ceilings. If an event would cross its per-event cap or either ordinary ceiling, discard that event, latch overflow once, invalidate the generation, abort the adapter, enqueue exactly one fixed-charge `request-failed(code=queue-overflow)` into the reserve, and drop all later callbacks. Tests fill item and byte admission independently to the exact reduced boundary, cross by one, and prove total high-water counters never exceed the configured maxima, prior events precede the failure, and no second terminal is admitted. Only the drain may append, call tools, invoke subscribers, update presentation events, or settle.

- [ ] Accumulate text and reasoning as chunk collections with O(1)-amortized append and explicit UTF-8 byte counters, never repeated string concatenation. Enforce per-leg and per-turn output limits even when a slow-drip stream is fully drained between chunks, plus the sequential-call limit. Flatten each collection exactly once at its commit boundary. A committed event uses the physical record sequence; `agent-settled` points to the last terminal record sequence.

- [ ] Implement success, provider/runtime failure, abort, and reopen terminal sequences from the frozen table. Every enclosing terminal path closes an open call first: planned becomes `tool-denied` with the cause-specific reason; started and provably side-effect-free becomes `tool-finished(cancelled|error)`; started with a possible side effect becomes `tool-finished(uncertain)` and reduced blocked state. Append the prescribed truthful result message only for the first two classes and never release an obsolete continuation. Build every proposal/lifecycle/result batch from one immutable pending-call snapshot so all duplicated fields satisfy the frozen cross-record equality contract. An uncertain normal/runtime/abort path uses failed turn/operation terminals; uncertain reopen uses interrupted terminals. Then emit settlement. Guard settlement and the optional settled callback exactly once. Validate a callback before admission, defer all drain dispatch until `epi-session-prompt` has returned its operation ID, deliver the exact same `eq` `agent-settled` event to snapshotted subscribers before the callback, and wait for any rescheduled subscriber remainder before calling it. Construct each event once through the private constructor; dispatch no per-subscriber event copies. Prove that mutation of caller-owned input or the fresh string/payload returned by a public accessor cannot mutate ledger/runtime state or the accessor result later observed by subscriber two or the callback. Time subscribers and the settled callback with the injectable deadline clock. After the first subscriber overrun, disable that repeating subscriber, emit a diagnostic, and reschedule remaining drain work; a one-shot settled-callback exception or overrun is diagnosed after the outcome and never retried. Exceptions or overruns after an underlying commit never change its outcome, and Epi does not claim to preempt synchronous Elisp.

- [ ] Implement `epi-session-wait` by snapshotting the latest admitted operation ID and first checking its terminal record/settled sequence, so a synchronously settled operation returns immediately even if its event preceded the call. Otherwise register the waiter before pumping process output/timers until that operation's exactly-once `agent-settled` event or timeout. A reduced blocked reason by itself is not settlement and cannot terminate the wait early. The function must not require a selected frame, window, minibuffer, or UI buffer.

- [ ] On open, reduce the ledger and terminalize one unfinished suffix in one ordered crash barrier before returning the session: planned call -> `tool-denied(reason=interrupted)` plus denied result message; started side-effect-free call -> `tool-finished(error, details.code=interrupted)` plus error result message; started possibly-mutating call -> `tool-finished(uncertain)` with no result message. Follow with `turn-interrupted` and `operation-interrupted`, return to phase `idle`, and emit one settlement. Only the uncertain path retains a reduced blocked/uncertain-tool reason that rejects new work. A turnless operation receives only its operation terminal. Increment the generation and discard every late callback from older session/request objects.

- [ ] Implement `epi-session-select-leaf` test-first as a turnless structural operation. Require unblocked idle, reserve one operation ID, validate that the target is a conversation node in this session, and append/read-verify `operation-started(kind=select-leaf)`, `leaf(operation=<id>)`, and `operation-finished(status=success)` in one ordered crash barrier. Reduce/refresh state, emit their committed events followed by one committed `agent-settled`, and return the selected record ID. Busy, blocked, unknown, operational-record, and cross-session targets fail before operation admission or any write.

- [ ] Inject ledger failure before acceptance, assistant completion, each terminal, and the reserved continuation barrier used by Task 12. Assert no downstream provider/tool action happens after a failed barrier and no duplicate terminal appears after retrying open.

- [ ] Run runtime tests and all prior tests.

- [ ] Commit:

```sh
git add epi-runtime.el test/epi-runtime-test.el test/epi-test-helper.el
git commit -m "feat: add the provider-independent Epi runtime"
```

## Task 9: Implement Project-Instruction Discovery and Snapshots

**Files:**

- Create: `epi-resources.el`
- Create: `test/epi-resources-test.el`
- Modify: `epi-runtime.el`
- Modify: `test/epi-runtime-test.el`

**Interfaces produced:** `epi-resource`, deterministic AGENTS/CLAUDE discovery, provenance prompt rendering, immutable descriptors.

- [ ] Write temporary-project tests for global-first ordering, root-to-working-directory ordering, `AGENTS.md` precedence over same-directory `CLAUDE.md`, canonical-path deduplication, symlink handling, a working directory outside the root, a modified visiting buffer, coding system, stable hashes, post-snapshot file edits, and exact-boundary/one-byte-over per-resource, aggregate, base-prompt, and projected-context limits.

```elisp
(ert-deftest epi-resources-use-agents-before-claude-by-directory ()
  (epi-test-with-instruction-tree (root working)
    (let ((resources
           (epi-resources-discover-instructions root working)))
      (should
       (equal '("AGENTS.md" "sub/CLAUDE.md" "sub/deep/AGENTS.md")
              (epi-test-relative-resource-paths root resources))))))

(ert-deftest epi-resources-snapshot-a-modified-buffer ()
  (epi-test-with-modified-instruction-buffer (root file "unsaved rules")
    (let ((resource
           (aref (epi-resources-discover-instructions root root) 0)))
      (should (epi-resource-modified-p resource))
      (should (equal "unsaved rules" (epi-resource-content resource)))
      (should-not
       (equal (epi-resource-hash resource)
              (epi-test-file-sha256 file))))))
```

- [ ] Run:

```sh
direnv exec . make test-one TEST=test/epi-resources-test.el SELECTOR='^epi-resources-'
```

Expected red: resource type and discovery functions are absent.

- [ ] Define `epi-resource` with kind, canonical path, scope, trust, hash, snapshotted content, modified flag, and coding system. The value owns a copied string and no buffer or marker.

- [ ] Canonicalize project root and working directory, require working directory to lie within root, and walk directories from root to working directory. At each level choose `AGENTS.md` when present; otherwise choose `CLAUDE.md`. A project instruction symlink resolving outside the root is rejected; the explicitly configured global file is the only outside-root source. The `global-file` keyword defaults to `epi-global-instructions-file`; prepend that canonical global file when non-nil.

- [ ] Reject an oversized disk instruction from `file-attribute-size` before reading it. Prefer a visiting buffer's current contents to disk, including unsaved changes; reject an obvious character-count overflow before encoding, then encode through a bounded temporary buffer under that buffer's file coding system and enforce the exact byte limit. Record `modified-p` and reject an unencodable value. Otherwise read exact bounded file bytes and decode under a recorded coding system. Stop discovery as soon as the aggregate limit would be crossed.

- [ ] Deduplicate by canonical true name after precedence ordering. A symlink cannot include the same file twice or escape the project walk.

- [ ] Render this exact visible wrapper for each resource, separated deterministically:

```text
--- BEGIN EPI INSTRUCTIONS ---
Path: <canonical path>
Trust: untrusted-context
SHA256: <content hash>

<verbatim content>
--- END EPI INSTRUCTIONS ---
```

- [ ] Produce string-keyed, canonical descriptor objects for `turn-started`. Include path, scope, trust, hash, modified flag, coding system, and content byte size. Compose the complete resolved prompt from the durable, creation-bounded `session-info.base_system_prompt` plus current resource wrappers; snapshot and hash that result without mutating the base. Before prompt acceptance, count the complete provider-neutral branch projection plus resolved system prompt and fail if the projected-context byte limit would be exceeded.

- [ ] Add negative tests proving instructions cannot alter tool roots/authority, and proving `.epi`, `SYSTEM.md`, `APPEND_SYSTEM.md`, skills, templates, ancestor skill directories, and project Elisp are neither scanned nor loaded.

- [ ] Use the optional creation `working-directory` persisted in `session-info`, defaulting to canonical project root. Reopen before a first turn must rediscover instructions from that durable directory and base prompt; after an instruction-file edit, the next reopened turn records a new resource/system-prompt snapshot while historical turns remain unchanged. Never derive either default from current `default-directory` or from a prior expanded prompt.

- [ ] Run resource, runtime, and all prior tests.

- [ ] Commit:

```sh
git add epi-resources.el epi-runtime.el test/epi-resources-test.el test/epi-runtime-test.el
git commit -m "feat: snapshot project instructions with provenance"
```

## Task 10: Implement the Minimal Epi Tool Boundary

**Files:**

- Create: `epi-tools.el`
- Create: `test/epi-tools-test.el`
- Create: `test/epi-mutation-test.el`

**Interfaces produced:** provider-neutral tool/call/context/outcome types, registry, policy/preview/execute split, `read_file`, and `replace_text`.

- [ ] Write registry tests for valid JSON object schemas, duplicate-name rejection, immutable definition snapshots, authority/confirmation policy, exact tool version, exactly-once completion, timeout/cancellation metadata, absence of GPTel types, and exact-boundary/one-byte-over `read_file` results from disk and live buffers.

```elisp
(ert-deftest epi-tools-registry-rejects-name-collision ()
  (let ((registry (epi-tools-registry-create)))
    (epi-tools-register registry (epi-tools-read-file))
    (should-error
     (epi-tools-register registry (epi-tools-read-file))
     :type 'epi-tool-error)))

(ert-deftest epi-tools-done-is-exactly-once ()
  (let ((done (epi-test-exactly-once-tool-done)))
    (funcall done (epi-tool-outcome-create
                   :status 'success :model-result "ok" :details nil))
    (should-error
     (funcall done (epi-tool-outcome-create
                    :status 'success :model-result "again" :details nil))
     :type 'epi-tool-error)))
```

- [ ] Run:

```sh
direnv exec . make test-one TEST=test/epi-tools-test.el SELECTOR='^epi-tools-'
```

Expected red: tool types and registry functions are absent.

- [ ] Define `epi-tool`, `epi-tool-call`, `epi-tool-context`, and `epi-tool-outcome`. Tool schemas must match the frozen flat-primitive subset exactly; reject every other otherwise-valid JSON Schema form. Arguments are string-keyed canonical data, and executors receive `(context arguments done)`. Deep-copy definitions when snapshotting.

- [ ] Implement a registry with exact string names, collision rejection, deterministic enumeration, schema validation, and a provider-neutral snapshot containing name, version, description, schema, authority, confirmation, timeout, idempotence, and provenance.

- [ ] Implement model-visible `read_file(path)`: authority `read`, auto-approved, canonical-root confined, symlink-safe, live-buffer-aware, cancellation-aware, and capped by the frozen result bytes. Reject an oversized disk file from metadata before reading; for a live buffer, reject an obvious character overflow before bounded encoding and enforce the exact encoded-byte limit. Return model text plus details containing canonical path, source (`buffer` or `disk`), modified flag, coding system, byte count, and SHA-256.

- [ ] Write mutation tests before the mutation implementation: root escape, symlink escape, zero/multiple matches, optional expected-hash mismatch, modified visiting buffer, nonmutating preview, diff hash, approval ordering, revalidation race, one undo unit, exact save, save error, save-hook mutation, interactive save hook, cancellation, and uncertain outcome.

```elisp
(ert-deftest epi-mutation-revalidates-after-human-approval ()
  (epi-test-with-project-file (context file "old")
    (let* ((call (epi-test-replace-call file "old" "new"))
           (preview (epi-tools-preview context call))
           outcome)
      (epi-test-external-write file "changed")
      (setq outcome
            (epi-test-execute-approved context call preview))
      (should (eq 'error (epi-tool-outcome-status outcome)))
      (should (equal "precondition-failed"
                     (alist-get "code" (epi-tool-outcome-details outcome)
                                nil nil #'string=)))
      (should (equal "changed" (epi-test-file-string file))))))
```

- [ ] Run:

```sh
direnv exec . make test-one TEST=test/epi-mutation-test.el SELECTOR='^epi-mutation-'
```

Expected red: preview/execution and `replace_text` are absent.

- [ ] Implement model-visible `replace_text(path, old_text, new_text, expected_sha256?)`: authority `write`, always confirm, exactly one match, no pre-modified visiting buffer, no dirty-buffer override in this slice. Reject files or proposed diffs above the configured first-slice byte caps before synchronous hashing/diffing.

- [ ] Preview before approval. Capture canonical path, disk/buffer hash, buffer modification tick, one unified diff, and SHA-256 of canonical diff bytes. Runtime persists that diff hash in `tool-approved`.

- [ ] After approval, acquire an in-process lock keyed by canonical path; revalidate path containment, symlink resolution, file identity, expected content hash, visiting-buffer identity/cleanliness/tick, and cancellation. A mismatch before Epi changes anything returns an ordinary `error` outcome with code `precondition-failed`; the runtime durably reports it to the model and may continue. Only after revalidation succeeds may Epi use one `atomic-change-group`, save, and verify realized buffer and disk bytes. Cache preview input/proposed hashes by buffer tick, and when the post-save hash equals the preview's proposed hash and no hook changed the tick, reuse the approved diff rather than computing another full diff.

- [ ] Never prompt while the path lock is held. During save, replace standard minibuffer/query entry points with functions that signal a structured `interactive-save-hook` tool error. Reserve `epi-tool-uncertain` for a path where Epi may already have changed buffer or disk bytes and cannot prove the realized result. A save hook that changes realized bytes or any post-side-effect ambiguity includes before/after hashes and never reports a guessed rollback.

- [ ] Release only the lock instance acquired by this execution. Ensure `done` is observed exactly once for synchronous success, denial, structured error, cancellation, and uncertainty.

- [ ] Run tool/mutation tests, all prior tests, compile, and checkdoc.

- [ ] Commit:

```sh
git add epi-tools.el test/epi-tools-test.el test/epi-mutation-test.el
git commit -m "feat: add bounded read and mutation tools"
```

## Task 11: Complete the GPTel Adapter as the Runtime Driver

**Files:**

- Modify: `epi-gptel.el`
- Modify: `test/epi-gptel-contract-test.el`
- Modify: `test/epi-gptel-fixture-transport.el`
- Create: `test/epi-architecture-test.el`

**Interfaces consumed:** `epi-message`, frozen tool snapshots, `epi-gptel-snapshot`, runtime enqueue callback.

**Interfaces produced:** reusable hidden request buffer, complete typed-history projection, copied adapter events, abort/close, submit-after-commit continuation.

- [ ] Add tests through the public adapter API for a text-only request, a two-leg read call, a three-leg read/write sequence, reopened history, exact system/tool/request snapshot, pre-parse and TOOL-guard rejection before stock dispatch, lossless raw argument extraction, a hostile global post-request hook, abort during transport and while paused in TOOL, late callback, duplicate result submission, and persistence-barrier simulation.

```elisp
(ert-deftest epi-gptel-driver-submit-happens-only-after-caller-releases-it ()
  (epi-test-with-gptel-tool-request (request observed)
    (should (equal '(tool-proposed) (epi-test-event-kinds observed)))
    (should-not (epi-test-next-leg-started-p request))
    (epi-gptel-submit-tool-result request "call-1"
                                  (epi-test-tool-result "contents"))
    (should (epi-test-next-leg-started-p request))
    (should-error
     (epi-gptel-submit-tool-result request "call-1"
                                   (epi-test-tool-result "duplicate"))
     :type 'epi-gptel-error)))
```

- [ ] Run:

```sh
direnv exec . make test-one TEST=test/epi-gptel-contract-test.el SELECTOR='^epi-gptel-driver-'
```

Expected red: the Task 2 seam does not yet provide the complete runtime driver.

- [ ] Reuse one hidden buffer named from the session ID for successive turns. Never save it. Reset its contents and request-local state before each operation, and kill it on session close.

- [ ] Set every request-sensitive GPTel variable buffer-locally and explicitly: backend, exact model, tool objects, tool use, confirmation, Curl, streaming, no GPTel context, no prompt transforms, no media tracking, reasoning capture, request parameters, and `gptel-post-request-hook` set to nil. Do not inherit user chat-buffer state.

- [ ] Convert provider-neutral messages to GPTel's advanced list: `(prompt . text)` for users, `(response . text)` for assistants, and one `(tool . plist)` entry for each paired sequential call/result. Require nonempty raw IDs and reject unsupported content rather than flattening it.

- [ ] Translate only the frozen flat-primitive JSON Schema subset into GPTel's documented tool-argument representation. Compare the effective dry-run parameters object with the independently normalized Epi schema before starting. The Epi executor is never installed as the GPTel tool function; the stub can only yield a proposal through confirmation.

- [ ] Keep the Task 2 raw-transport guard, pre-parse outer-envelope auditor, and TOOL guard ahead of GPTel's inner-argument parse/stock handler in the completed driver. Reject count, nonzero/multiple indices, mixed semantics, undeclared name, schema, ID/name size, or raw-argument failures by taking the terminal error path before an inner argument object, continuation, or second transport leg can exist. Accepted input still traverses GPTel's real parser and FSM exactly once.

- [ ] Normalize callbacks into the closed event vocabulary. Copy text and reasoning immediately. For a tool callback, require GPTel's accepted raw call ID/name to match the pre-parse attestation, run the separate bounded callback normalizer over the attested raw bytes to construct canonical arguments, copy raw-byte charge/member count plus redacted diagnostics, and erase raw bytes/attestation before enqueue. Do not retain raw argument strings, GPTel info plists, response buffers, provider objects beyond the pinned backend identity, parser-owned structures, or GPTel's lossy keyword argument plist after normalization. Do not assign durable call order here: the runtime allocates the next turn-global order only when `tool-planned` commits; first-slice group ID is null.

- [ ] Store pending continuations privately by raw call ID. `epi-gptel-submit-tool-result` marks one consumed before invoking it with the hidden request buffer current. Increment leg identity only after the continuation returns; a synchronous `tool-result-observed` event still belongs to the preceding leg.

- [ ] Implement `epi-gptel-abort` by atomically invalidating every continuation before calling public `gptel-abort` on the hidden buffer. If an active transport exists, callback plus terminal post path emits one terminal. If the request is paused in TOOL and absent from GPTel's active-request registry, Epi itself marks the handle terminal and enqueues exactly one `request-aborted` without advancing the FSM. The watchdog uses the same fallback with `request-failed`. Reject all later or stale-generation events.

- [ ] Add architecture tests that scan production S-expressions, not comments or documentation, and fail if GPTel internals occur outside `epi-gptel.el`. Tests outside that file may name only the public Epi adapter API and the Epi fixture helper.

- [ ] Re-run every Task 2 contract through the completed driver. Expected green: identical offline semantics for two- and three-leg fixtures and no alternate provider implementation.

- [ ] Run all prior tests, compile, checkdoc, and architecture checks.

- [ ] Commit:

```sh
git add epi-gptel.el test/epi-gptel-contract-test.el test/epi-gptel-fixture-transport.el test/epi-architecture-test.el
git commit -m "feat: drive frozen Epi turns through GPTel"
```

## Task 12: Integrate the Complete First-Slice Lifecycle

**Files:**

- Modify: `epi-runtime.el`
- Modify: `epi-ledger.el`
- Modify: `epi-resources.el`
- Modify: `epi-tools.el`
- Modify: `epi-gptel.el`
- Modify: `test/epi-runtime-test.el`
- Modify: `test/epi-gptel-contract-test.el`
- Modify: `test/epi-test-helper.el`

**Interfaces consumed:** every provider-neutral module seam and the proven GPTel driver.

**Interfaces produced:** complete first-slice outer lifecycle with durable tool commit barriers and a frozen whole-loop snapshot.

- [ ] Add scripted lifecycle tests that assert exact record/event order for create-close-open before first turn, exact built-in and caller-supplied custom-tool rebinding (plus missing/mismatched rejection), durable base-prompt/resource refresh after reopen, text success, reasoning plus text, three sequential calls with orders 0/1/2, auto-approved read, approved mutation, denied mutation, approval timeout, execution timeout, pre-mutation conflict, provider error, abort in each phase including paused TOOL, uncertain mutation, missing object, blocked-idle admission rejection, and append failure at each barrier. For every tool path, assert proposal/lifecycle/result target-parent, turn, operation, call ID, name, JCS arguments, order, model-result, and status equality against the immutable pending-call snapshot; assert uncertainty has no result.

```elisp
(ert-deftest epi-runtime-integrated-tool-result-commits-before-continuation ()
  (epi-test-with-integrated-runtime (session adapter)
    (epi-session-prompt session "read the file")
    (epi-test-adapter-propose-read adapter "call-9")
    (epi-test-run-until-tool-completes session)
    (should
     (equal '(tool-finished message)
            (epi-test-record-types-before-submit adapter "call-9")))
    (should (epi-test-submit-observed-p adapter "call-9"))))
```

- [ ] Run:

```sh
direnv exec . make test-one TEST=test/epi-runtime-test.el SELECTOR='^epi-runtime-integrated-'
```

Expected red: runtime still uses its task-local empty resources/tools and does not drive commit-held continuations.

- [ ] At prompt admission, load working directory, base prompt, backend/model, request parameters, immutable tool descriptors, and capability from durable `session-info`; verify caller-supplied runtime/custom-tool bindings exactly. Resolve current instruction resources and compose base plus provenance without reusing an expanded historical prompt. Project and byte-count the complete provider context before GPTel dry-run. Canonicalize and hash the bounded turn snapshot, including disabled parallel calls; append it in `turn-started` with operation/turn starts and user message before adapter start.

- [ ] On text/reasoning deltas, update only volatile accumulators/events. At final request completion, append any completed reasoning, assistant text message, `turn-finished`, and `operation-finished` in semantic order under one crash barrier, then emit committed events followed by exactly one `agent-settled`.

- [ ] On `tool-proposed`, reject mixed/parallel semantics; allocate the next zero-based turn-global order in the runtime, create one immutable pending-call snapshot containing target, turn, operation, raw call ID/name, canonical arguments, authority, null group ID, and order, and append completed reasoning if present, one assistant tool-call message, and `tool-planned` from that snapshot. Do not increment the counter or invoke policy before this batch commits.

- [ ] For `read_file`, append `tool-approved` and `tool-started`, then execute. For `replace_text`, compute preview, emit `tool-approval-needed`, and wait in `tool-policy`; approval appends `tool-approved` with diff hash and `tool-started`, while denial appends `tool-denied`.

- [ ] Keep provider-leg, human-policy, and tool-execution timing independent. A valid proposal has already stopped the leg watchdog. The optional policy timer is a runtime timer disabled by default and dynamically shortened in tests; if enabled and reached, it durably denies with reason `approval-timeout` before releasing the held continuation. Execution uses the frozen tool descriptor's timeout and cancellation contract; it never reuses the provider-leg timer.

- [ ] On denial, append a model-facing tool-result message in the same barrier as `tool-denied`, then release the continuation. On successful or ordinary-error execution completion—including a safe pre-mutation `precondition-failed` outcome—append `tool-finished` and the model-facing tool-result message in one barrier, then release the continuation. The result string sent to GPTel is exactly the durable message result.

- [ ] Treat `epi-tool-uncertain` separately: append `tool-finished(status=uncertain)`, `turn-failed(code=tool-uncertain)`, and `operation-failed(code=tool-uncertain)`; invalidate the generation, abort GPTel, settle to phase `idle`, retain a reduced blocked reason, and never append a guessed tool-result message or release the continuation.

- [ ] Apply the same call-first terminal protocol to cancellation and reopen. A planned call gets `tool-denied(reason=operation-cancelled|interrupted)` plus a denied result; a started `read_file` gets `tool-finished(cancelled|error)` plus an error result; a started `replace_text` whose no-side-effect point cannot be proved gets `tool-finished(uncertain)` and no result. The uncertain abort path then uses failed terminals with `tool-uncertain`; the uncertain reopen path uses interrupted terminals with that reason. Commit the call terminal and optional result before the enclosing terminals, invalidate the request, and never submit any of these terminalization results to the dead provider continuation.

- [ ] If any required append fails, do not release the continuation or retry a side effect. Invalidate the operation generation and call `epi-gptel-abort` through the public adapter seam; no pause/resume shim is required for this first-slice barrier. Finish any provable terminal pair and settle idle; otherwise retain a reduced error/blocked reason and let cold reopen determine interruption from ledger evidence.

- [ ] Keep the original snapshot for every subsequent GPTel leg. Reject an attempt to update model, system prompt, tools, resources, working directory, request parameters, steering, or follow-up until the logical request terminates.

- [ ] Map terminal paths exactly: provider/runtime terminal error to `turn-failed`/`operation-failed`; user abort to `turn-cancelled`/`operation-cancelled` only when all outcomes are provably cancelled; uncertain execution or abort to the failed `tool-uncertain` pair; and reopen to `turn-interrupted`/`operation-interrupted`, always after terminalizing any open call as above. Started unterminated mutation adds reduced blocked uncertainty. Every admitted path that can be proven terminal returns phase to `idle` and emits exactly one `agent-settled`.

- [ ] Exercise the same assertions once with the scripted adapter and once with the real GPTel fixture transport. The scripted adapter proves Epi order; the GPTel fixture proves the compatibility boundary.

- [ ] Run runtime, tools, resources, GPTel contract, ledger tests, and then the whole suite.

- [ ] Commit:

```sh
git add epi-runtime.el epi-ledger.el epi-resources.el epi-tools.el epi-gptel.el test/epi-runtime-test.el test/epi-gptel-contract-test.el test/epi-test-helper.el
git commit -m "feat: integrate Epi turn and tool settlement"
```

## Task 13: Build Disposable Conversation, Composer, Ledger, and Tree Views

**Files:**

- Create: `epi-ui.el`
- Create: `test/epi-ui-test.el`

**Interfaces produced:** `epi-session-mode`, `epi-ledger-mode`, `epi-tree-mode`, public display functions, interactive entry commands, projection rendering, composer and approval commands.

- [ ] Write buffer-level tests for the public and interactive entry points, deterministic buffer ownership/names, repeated-call reuse, killed-buffer rebuild, read-only committed history, writable composer, send failure/success, volatile overlays, foldable reasoning/tool details, tree buttons, approval diff, raw ledger protection, exact message-byte/tree-node render caps, bounded continuation actions, and the absence of direct ledger mutation in UI commands.

```elisp
(ert-deftest epi-ui-history-is-read-only-composer-is-writable ()
  (epi-test-with-session-view (session buffer)
    (with-current-buffer buffer
      (goto-char (point-min))
      (should-error (insert "tamper") :type 'text-read-only)
      (goto-char (epi-test-composer-start))
      (insert "next prompt")
      (should (equal "next prompt" (epi-test-composer-string))))))

(ert-deftest epi-ui-failed-acceptance-keeps-composer ()
  (epi-test-with-session-view (session buffer)
    (epi-test-set-composer buffer "keep me")
    (epi-test-fail-next-ledger-append session)
    (should-error (with-current-buffer buffer (epi-send)))
    (should (equal "keep me" (epi-test-composer-string buffer)))))
```

- [ ] Run:

```sh
direnv exec . make test-one TEST=test/epi-ui-test.el SELECTOR='^epi-ui-'
```

Expected red: the UI module and the implementations named by the existing
autoload declarations are absent.

- [ ] Define `epi-session-mode` from `org-mode`, `epi-ledger-mode` from `org-mode`, and `epi-tree-mode` from `special-mode`. The raw ledger mode is unconditionally read-only, disables ordinary save/edit commands, and clearly states that the file is append-only Epi data.

- [ ] Define the UI-owned public display functions and interactive commands
  directly under the symbols declared by Task 1's autoloads. Do not add a
  second wrapper or `epi-ui-*` public command layer.

- [ ] Implement the public entry points exactly. `epi-display-session` returns/reuses `*Epi:<session-id>*`, `epi-display-tree` returns/reuses `*Epi Tree:<session-id>*`, and `epi-display-ledger` returns/reuses the buffer visiting the session's canonical ledger path under `epi-ledger-mode`. If a disposable session/tree buffer was killed, the next call recreates it from ledger-derived state. `epi` creates and displays; `epi-open-session` opens a selected ledger and displays; `epi-show-tree` and `epi-show-ledger` display the current session. A closed session must be reopened rather than silently resurrected.

- [ ] Render committed conversation from `epi-state` under read-only text properties. Keep a marked composer region outside that projection writable. Stop each initial or load-earlier action at both message-count and content-byte limits; if one message exceeds the remaining budget, insert a bounded preview and a button that opens a chunked message view governed by the same per-action content cap. Internal refresh uses `inhibit-read-only`; user edits never do.

- [ ] Subscribe to semantic events. Render text/reasoning deltas as volatile overlays keyed by operation/turn/live sequence. Remove them when the corresponding committed projection arrives or the generation changes.

- [ ] Render reasoning and tool lifecycle as foldable detail regions while keeping provider-visible messages clear. Tool approval opens a read-only proposed diff and calls only `epi-tool-approve` or `epi-tool-deny`.

- [ ] Implement `epi-send`: retain composer text until `epi-session-prompt` returns durable acceptance, then clear it. `epi-abort` delegates to the public API. Neither command depends on a selected window after resolving its session.

- [ ] Render the logical parent/children tree iteratively with record IDs on buttons. Bound each display label to 384 encoded bytes without truncating the full record ID stored on its button; stop independently at 1,000 nodes or 512 KiB of tree content, represent undisplayed children by collapsed continuation buttons, and bound every expansion to one additional node/byte budget. Selection calls `epi-session-select-leaf` only while idle; it never edits the ledger buffer or rewrites history.

- [ ] Instrument records visited, messages, content bytes/characters inserted, total inserted bytes, tree-label bytes, and tree nodes materialized. Assert dimensions separately: conversation messages <= 200, conversation content <= 1 MiB, conversation total <= content allowance + 64 KiB chrome; tree nodes <= 1,000, each label <= 384 bytes, tree content <= 512 KiB, and tree total <= tree-content allowance + 64 KiB chrome. No action visits an undisplayed subtree. Rebuilding after killing every view/request buffer must derive the same committed presentation from ledger state.

- [ ] Run UI, runtime, and all prior tests.

- [ ] Commit:

```sh
git add epi-ui.el test/epi-ui-test.el
git commit -m "feat: add native disposable Epi views"
```

## Task 14: Prove Reopen, Branch, and Continue End to End

**Files:**

- Create: `test/epi-acceptance-test.el`
- Create: `test/fixtures/gptel/acceptance-*.sse`
- Modify only when required by a failing acceptance assertion: `epi.el`,
  `epi-ledger.el`, `epi-resources.el`, `epi-tools.el`, `epi-gptel.el`,
  `epi-runtime.el`, and `epi-ui.el`.

**Gate produced:** every Section 16.3 clause is exercised through the public API and real GPTel fixture transport.

- [ ] Write a create-close-open-before-first-prompt journey plus one named full acceptance journey and focused failure journeys. The first proves immutable defaults are recoverable without any `turn-started` record. The main journey creates a session, streams text, runs `read_file`, approves `replace_text`, settles, destroys all live buffers/state, reopens from ledger/objects, selects an earlier message, continues the new branch, returns to the prior leaf, and verifies both contexts.

```elisp
(ert-deftest epi-acceptance-create-tool-reopen-branch-continue ()
  (epi-test-with-acceptance-project (project fixtures)
    (let* ((session (epi-session-create
                     project :working-directory project
                     :backend "fixture-openai" :model "fixture-model"))
           (original (epi-test-run-acceptance-turn session fixtures)))
      (epi-session-close session)
      (epi-test-kill-all-epi-buffers)
      (setq session
            (epi-session-open (plist-get original :file)
                              :backend "fixture-openai"
                              :model "fixture-model"))
      (epi-session-select-leaf session (plist-get original :early-leaf))
      (epi-test-run-branch-turn session fixtures)
      (should (epi-test-both-branches-preserve-tool-semantics-p session)))))
```

- [ ] Run:

```sh
direnv exec . make test-one TEST=test/epi-acceptance-test.el SELECTOR='^epi-acceptance-'
```

Expected red: at least one integration boundary is incomplete; use the exact assertion to make the smallest production correction.

- [ ] Assert ledger record order and hash validity after each step, including `operation-started`/`leaf`/`operation-finished` around every selection; immutable object reachability; one hidden GPTel buffer while live; no GPTel buffer after close; and recovery using only ledger plus objects.

- [ ] Assert replay preserves provider role, raw call ID, name, canonical arguments (including empty object, false, and safe numbers), model result, status, and turn-global orders `0` and `1` across each three-leg branch containing two completed calls and a final text leg. Compare captured dry-run OpenAI request data before and after reopen.

- [ ] Parameterize destruction of the hidden request buffer immediately after every durable boundary. A committed state must reopen conservatively; an uncommitted provider continuation must never be reconstructed or serialized.

- [ ] Add acceptance cases for abort during model I/O, abort while awaiting mutation approval, abort during a started read, abort after a possibly-effectful mutation, reopen after a planned call, reopen after a started read, and reopen after an unterminated started mutation. Assert the exact call-terminal/result-message/turn-terminal/operation-terminal order, exactly one terminal per entity, no revived continuation, and valid replay context for denied/ordinary calls. Uncertain abort uses failed terminals; uncertain reopen uses interrupted terminals. Both deliberately lack a result message and block provider continuation without making the ledger corrupt.

- [ ] Rebuild conversation/tree views after close and compare committed logical content and record IDs, not incidental point/overlay values.

- [ ] Run the complete acceptance file, then the complete suite, compile, checkdoc, and architecture checks.

- [ ] Commit:

```sh
git add test/epi-acceptance-test.el test/fixtures/gptel
git add -u -- epi.el epi-ledger.el epi-resources.el epi-tools.el epi-gptel.el epi-runtime.el epi-ui.el
git commit -m "test: prove Epi reopen and branch continuity"
```

Before staging, inspect `git diff --name-only` and omit any unchanged production path; never stage files outside this explicit list.

## Task 15: Harden Concurrency, Crash, Scale, and Static Gates

**Files:**

- Create: `test/epi-ledger-worker.el`
- Create: `test/epi-ledger-process-test.el`
- Create: `test/epi-scale-test.el`
- Create: `test/epi-scale-runner.el`
- Create: `test/fixtures/performance/time-darwin.txt`
- Create: `test/fixtures/performance/time-gnu.txt`
- Create: `test/fixtures/performance/reference.json`
- Modify: `test/epi-architecture-test.el`
- Modify: `test/epi-test-helper.el`
- Modify: `Makefile`
- Modify only when required by a failing gate: `epi.el`, `epi-ledger.el`,
  `epi-resources.el`, `epi-tools.el`, `epi-gptel.el`, `epi-runtime.el`, and
  `epi-ui.el`.

**Gates produced:** competing-process safety, forced-death evidence, bounded projections/queues, offline full suite, warning-free static checks.

- [ ] Create the process/scale test files and Make targets first. Write failing process tests for disabled `create-lockfiles`, two concurrent appenders, stale same-host owner, live owner refusal, PID reuse/start mismatch, remote owner refusal, indeterminate identity refusal, lock-token replacement, head race, stale-lock archive recovery, and every restartable tail-recovery phase. Write failing scale tests for cooperative cold/recovery work, chain/star/balanced reduction, queue/accumulator/output/input limits, subscriber timing, conversation/tree rendering, warm-tail work, mutation caps, and the exact counter inequalities below before changing production code.

```elisp
(ert-deftest epi-process-competing-append-has-one-winner ()
  (epi-test-with-worker-ledger (file)
    (let ((results (epi-test-run-synchronized-appenders file 2)))
      (should (= 1 (epi-test-count-status results 'committed)))
      (should (= 1 (epi-test-count-status results 'conflict)))
      (should (epi-test-ledger-valid-p file)))))
```

- [ ] Run:

```sh
direnv exec . make process-test
direnv exec . make scale
```

Expected red: the worker protocol, recovery failpoints/resume path, and scale instrumentation are absent; both targets must execute the intended test files rather than fail because the target is undefined.

- [ ] Implement a deterministic worker protocol invoked with the exact `EPI_EMACS --batch -Q` command and declared load paths. It accepts a temporary ledger path, operation, barrier name, and synchronization files; it never touches a non-test ledger.

- [ ] Add forced-death helpers that terminate only spawned temporary workers at these barriers: after lock, before append, during a test-only partial tail write, after write before read-back, after tool policy commit, after tool start, after tool terminal, after result-message commit, and before provider continuation. For tail recovery also kill after source validation, reachable-object transfer, destination-object publication, destination-ledger publication, source-ledger move, source-object-directory move, and final quarantine publication; rerunning recovery must resume the durable manifest idempotently.

- [ ] Verify conservative outcomes: unchanged ledger, a valid complete append, a quarantinable torn final frame, one validated recovered destination plus complete quarantined source, an interrupted operation, or an idle session carrying reduced blocked uncertainty. No crash point may lose evidence, expose a destination ledger before its objects, produce a silently continued provider request, or duplicate a side effect.

- [ ] Generate deterministic 1k, 5k, and 10k chain, wide-star, and balanced ledgers. Instrument file bytes read, chain-hash bytes, lexical-validator bytes, decoder-input bytes, record objects, retained duplicate payload bodies, edge insertions/finalizations, recursive calls, work-slice maxima/yields, rendered messages/bytes/nodes, queue items/charged bytes, accumulator copies/flatten count, and tail bytes. Use these hardware-independent gates:

  - Cold open reads each ledger file byte exactly once. For total stored JSON bytes `j`, chain hashing consumes exactly `j`, lexical validation consumes exactly `j`, and the size-checked decoder receives exactly `j`; these are three explicit processing passes, not one overloaded counter. Record objects are at most `n + 1`, retained duplicate payload-body copies are exactly zero (the one decoded payload per record is not a duplicate), JCS encoder/render calls are zero, and no persistent index appears.
  - Each of `E` conversation edges has one O(1) insertion and at most one finalization copy; recursive traversal calls are zero; branch/tree traversal visits each returned node at most once.
  - Every ledger/recovery I/O or lexical work slice processes no more than 256 records or 1 MiB and stops at the first bounded unit after the injected clock reaches 8 ms. Whole-record JSON decode and `secure-hash` are separately counted nonpreemptible units, capped at 15 MiB for record JSON and 16 MiB for an object/fragment; the cursor yields immediately before and after each. A maximum-frame fixture proves I/O and lexical yields occur within its frame, then observes exactly one bounded hash and one bounded decode with their elapsed durations. A heartbeat timer fires between records during each 10k cold-open and recovery run, and every exceptional hash/decode duration is reported rather than falsely claimed preemptible.
  - Warm refresh after appending `k` records visits exactly `k` records and reads exactly the bytes from the old validated end to new EOF; it never parses or hashes a prefix record again.
  - Let `n` be validated records. Instrumented reducer-owned hash entries plus cons cells plus vector elements are at most `12*n + 1024`; retained payload-body copies are exactly zero. The same inequality holds independently for chain, star, and balanced fixtures.
  - UI dimensions are asserted separately: conversation messages, conversation content bytes, tree nodes, tree label bytes, and tree content bytes each obey their frozen cap; total conversation/tree insertion is at most its respective content allowance plus 64 KiB chrome. No action visits an undisplayed subtree.
  - FIFO counters never exceed their charged maxima; per-event, slow-drip raw/semantic per-leg and request-wide turn totals, record JSON nesting/container-entry count, raw argument bytes/member count, schema property/enum count, resource, context, and `read_file` limits pass exactly at the boundary and fail one unit over. Chunk collectors perform one final flatten and no concatenation proportional to prior accumulated length.

- [ ] During cold validation, temporarily replace the JCS encoder and record renderer with functions that signal, while an independent oracle hashes every exact stored JSON byte range; reopening must still succeed. For recovery, assert each valid-prefix record is resealed once, each reachable object is linked or copied once, transferred bytes do not exceed the sum of non-linked reachable bytes plus the fragment, and resumption never repeats a published phase.

- [ ] Add mutation scale cases at the configured maximum file size. Assert one preview diff, bounded synchronous bytes, cached preview hash reuse, no second diff on an unchanged save-hook path, and rejection above the cap.

- [ ] Make the entire ERT runner fail if ordinary network entry points are used. The GPTel fixture driver must prove every request consumed recorded bytes; no paid/live smoke is a release gate.

- [ ] Strengthen the S-expression architecture scan: GPTel internals only in `epi-gptel.el`; no `request`, `url-retrieve`, independent Curl invocation, provider parser, TypeScript, or executable project-resource load in other production modules; raw ledger append called only from `epi-runtime.el` in production. Inside `epi-gptel.el`, permit only the pinned raw-byte filter wrapper, outer-envelope safety auditor, TOOL guard, history adapter, and documented GPTel calls; fail if the safety auditor emits provider-semantic events or if any alternate request/parser/FSM loop appears. Also reject a public event copier, use of private event raw accessors outside `epi.el`, direct production `signal` calls for Epi conditions, or any private struct definition that defines/overwrites `epi-session-p`.

- [ ] Implement one shared `test/epi-scale-runner.el` used unchanged by both reference targets, with `generate-fixture`, `record`, `compare`, and single-sample worker modes. Before any warm-up or timed sample, the parent launches a separate fresh `EPI_EMACS --batch -Q` process to generate one temporary immutable fixture. A frozen benchmark-only generator, not the production renderer, uses a private PRNG with seed 424242 without changing global random state and writes the `reference-v1` shape: a 100,000-record linear conversation alternating user/assistant messages whose deterministic ASCII content is exactly 128 bytes. The generator completes the real chain fields, then the parent validates the chain, profile, count, and exact SHA-256 through production read code, changes the fixture mode to `0444`, and records device/inode/size/change identity. Generation, validation, permission changes, and full hashing finish before measurement and are never children of a time adapter. Immediately before every timed spawn, the parent re-stats that identity and verifies the full expected SHA-256; after all samples it verifies both again. A measured worker performs only bounded mode/identity/size/change checks before and after its cold open/reduction, never hashes or mutates the fixture, and exits. No sample reuses an Emacs process.

- [ ] Freeze two measurement adapters and unit-test their parsers against `time-darwin.txt` and `time-gnu.txt`. With `LC_ALL=C` forced for the adapter and child, adapter `darwin-time-l-v1` invokes `/usr/bin/time -l`, reads `maximum resident set size` as bytes, and is eligible only on Darwin; adapter `gnu-time-v-v1` invokes `/usr/bin/time -v`, reads `Maximum resident set size (kbytes)` as an unsigned integer, checks multiplication overflow, and multiplies by 1024 to normalize bytes, and is eligible only on GNU/Linux with GNU time. Probe the platform, executable, C-locale output, and parser fixture before generating the benchmark fixture or invoking a timed child. Compute the executable's ordinary SHA-256 and a normalized version signature: GNU uses the first nonempty C-locale `--version` line; Darwin uses `bsd-time:<kern.osproductversion>:<kern.osversion>` from fixed `sysctl -n` fields. Reject a missing/ambiguous signature, and re-stat the same executable identity before each sample. Never attempt a platform-incompatible or failed probe. Parser tests cover both fixtures, missing/duplicate fields, malformed numbers, overflow, locale variation rejection, and the KiB-to-byte conversion. Record the adapter ID, executable hash, normalized version signature, and normalized peak RSS bytes, never unlabelled native units.

- [ ] In every single-sample worker, load only declared production paths, verify the passed bounded fixture identity metadata, set `gc-cons-threshold` to 67108864 and `gc-cons-percentage` to 0.1, run one `garbage-collect`, and only then measure cold open plus reduction with the process-local nondecreasing deadline clock. This is the frozen high-water mark over wall time, not an OS monotonic primitive. The external time adapter wraps only that worker process, so its lifetime peak RSS includes Emacs/library startup and the operation under test but neither fixture construction nor full-file preverification. Both `scale-reference-record` and `scale-reference` run one discarded warm-up followed by exactly five fresh-process samples.

- [ ] Have the runner emit a canonical `benchmark-protocol-v1` descriptor covering the fixture generator/profile, seed, record/content shape, measurement window, warm-up/sample count, both GC settings, adapter commands/parser rules, runner mode contract, locale, and normalized units. Put both Make reference targets and no unrelated commands inside one uniquely marked benchmark-protocol region; tests reject missing/duplicate markers or benchmark commands outside it. Hash bytewise-sorted UTF-8 manifest lines for `test/epi-scale-runner.el`, `test/fixtures/performance/time-darwin.txt`, and `test/fixtures/performance/time-gnu.txt`, the exact UTF-8 bytes between the Makefile markers, and the canonical descriptor; call the result the benchmark-protocol hash. Mutation tests prove any runner invocation, environment, adapter flag, measurement setting, or sample-orchestration change alters that hash. The exact compatibility key is reference schema, benchmark-protocol hash, pinned GPTel commit, `system-type`, `system-configuration`, full Emacs version, CPU brand/logical-core count, OS release, adapter ID, adapter executable SHA-256, normalized adapter version signature, record count, fixture-profile hash, fixture SHA-256, seed, and both GC settings.

- [ ] Separately compute an ordered production-source manifest over `Makefile`, `epi.el`, `epi-ledger.el`, `epi-resources.el`, `epi-tools.el`, `epi-gptel.el`, `epi-runtime.el`, `epi-ui.el`, `test/epi-scale-test.el`, and `test/epi-test-helper.el`; bytewise-sorted UTF-8 lines `<sha256><two spaces><relative-path><LF>` are hashed once. Store the baseline and current production-source hashes as provenance and print both in comparison output, but do **not** include either in the compatibility key or use a mismatch to suppress the gate. Thus an ordinary production change remains comparable and can fail the regression thresholds, while a change to the benchmark protocol itself requires a reviewed baseline refresh.

- [ ] Define the reference-host identity independently of adapter success as `system-type`, `system-configuration`, full Emacs version, CPU brand/logical-core count, and OS release, and store it explicitly in the reference. `make scale-reference-record` refuses to write without `EPI_UPDATE_SCALE_REFERENCE=1`, requires a supported adapter, and records host identity, the compatibility key, protocol and production provenance, fixture hash, adapter/unit metadata, all five elapsed/RSS samples, and medians. `make scale-reference` first requires only the host-independent protocol/workload invariants to match: reference schema, benchmark-protocol hash, pinned GPTel commit, record count, fixture-profile descriptor/hash, seed, and both GC settings; any mismatch is a nonzero `baseline refresh required` failure on every host. Next compare the adapter-independent reference-host identity. On the same host, require the complete key—including adapter ID/executable hash/version signature—to match, and treat an absent/changed/failing adapter as nonzero, never `not-applicable`. On a different host, local system/Emacs/CPU/OS and adapter fields may differ: a supported adapter runs and prints local measurements with `not-applicable`, while an unsupported adapter reports `not-applicable` before fixture generation or timed invocation. Whenever a fixture is generated, its exact SHA-256 must match the protocol-bound reference value or fail. On an identical complete compatibility key, require elapsed median at most 2.0 times baseline and peak-RSS median at most 1.5 times baseline regardless of production-source hash. No non-success path rewrites the reference. Updating the baseline requires review of the measured cause and inclusion in the Task 15 commit.

- [ ] Drive the benchmark decision matrix with injected host facts and adapter probes, never the test machine's actual identity. Prove: a protocol/workload mismatch fails on both same and different hosts; same-host adapter absence, ID/hash/version change, probe failure, or parser failure exits nonzero; a different host with a supported adapter measures then reports `not-applicable`; a different host without one reports `not-applicable` before fixture generation or time invocation; a generated fixture-hash mismatch exits nonzero; a production-source hash change remains comparable; and a matching key enforces both thresholds. Snapshot `reference.json` bytes before every row and require byte identity afterward for every failure and `not-applicable` result.

```sh
direnv exec . env EPI_SCALE_RECORDS=100000 EPI_UPDATE_SCALE_REFERENCE=1 make scale-reference-record
direnv exec . env EPI_SCALE_RECORDS=100000 make scale-reference
```

- [ ] After the runner, adapters, reference logic, and every preceding hardening step exist, run the complete Task 15 gate:

```sh
direnv exec . make process-test
direnv exec . make scale
direnv exec . make test
direnv exec . make compile
direnv exec . make checkdoc
direnv exec . make architecture
direnv exec . make verify
```

Expected: all commands exit 0, no network attempt, no warning, no `.elc` in the tree, no test process remains, and the checked-in performance reference is unchanged.

- [ ] Commit:

```sh
git add Makefile test/epi-ledger-worker.el test/epi-ledger-process-test.el test/epi-scale-test.el test/epi-scale-runner.el test/epi-architecture-test.el test/epi-test-helper.el test/fixtures/performance
git add -u -- epi.el epi-ledger.el epi-resources.el epi-tools.el epi-gptel.el epi-runtime.el epi-ui.el
git commit -m "test: harden Epi durability and scale gates"
```

## Task 16: Document and Verify the Delivered Slice

**Files:**

- Create: `test/epi-documentation-test.el`
- Modify: `README.md`
- Modify: `Makefile`
- Modify documentation only when verification finds a mismatch.

**Outcome produced:** accurate installation, operation, security, recovery, capability, exclusion, and verification documentation.

- [ ] Write `test/epi-documentation-test.el` first. Assert that the README names every public/interactive entry point, the pinned capability, append-only ledger rule, permissions/recovery behavior, tool boundary, preflight inputs, all Make targets, and every explicit exclusion; cross-check function names against `epi.el` and test-target names against the Makefile.

- [ ] Run:

```sh
direnv exec . make test-one TEST=test/epi-documentation-test.el SELECTOR='^epi-documentation-'
```

Expected red: the existing README does not yet describe the delivered first-slice contract.

- [ ] Rewrite the README around the delivered behavior: existing-environment setup, exact dependency pin, create/open/send/abort/wait/branch commands, conversation/composer/tree views, read-only ledger rule, ledger sensitivity and permissions, explicit tail recovery, project-instruction provenance, `read_file`, and confirmed `replace_text`.

- [ ] Name the sole enabled capability `openai-chat-completions/sequential-tools-v1`. State that GPTel performs provider communication and that Epi will fail visibly rather than flattening incompatible typed history.

- [ ] Document that ledgers must only be viewed, never edited; corrections, leaf changes, interruptions, and recovery are appended through Epi commands. Explain that objects are immutable payloads but the Org ledger remains semantic authority.

- [ ] Document the exact first-slice exclusions: steering/follow-up queues, pause/resume refresh, retry, compaction/summaries, full file/shell/process tools, MCP resources/prompts/roots/lifecycle, skills/templates/extensions, JSONL/Pi import, subagents, background jobs, parallel calls, and parallel mutation.

- [ ] Document all Make targets and the preflight inputs. Clearly separate required offline fixtures from any optional manual live smoke; a live provider call is never required for release.

- [ ] From a fresh Emacs process and clean test temporary root, run:

```sh
direnv exec . make clean
direnv exec . make verify
git diff --check
git status --short
```

Expected: verification exits 0; only the intended README/implementation changes appear before commit; no generated build/test artifacts remain.

- [ ] Re-run the documentation test and inspect README claims against the public API, capability report, and test names. Remove any implied later-slice behavior.

- [ ] Commit:

```sh
git add README.md Makefile test/epi-documentation-test.el
git commit -m "docs: describe the delivered Epi first slice"
```

- [ ] Run `direnv exec . make verify` once more against the committed tree and record the commit SHA plus exact command results in the executor's final report. Do not invent or modify an unlisted handoff file after the task commit.

## Coverage Matrix: Approved First Slice

| Section 16.1 requirement | Planned proof |
|---|---|
| V1 Org header/parser | Tasks 3–4 codec goldens and corruption fixtures |
| Locked append, hash chain, tail recovery | Tasks 5–6 and Task 15 process tests |
| Message/reasoning/tool/turn/leaf/interruption records | Tasks 3–4 schema tests; Tasks 7, 8, and 12 lifecycle tests |
| Pure branch/model-context reduction | Task 7 Pi-oracle behavior and cold rebuild |
| One live session and hidden GPTel buffer | Tasks 8, 11, and 14 |
| Streaming GPTel-backed outer lifecycle | Tasks 11–12 real fixture transport |
| Callback normalization and pre-parse safety | Tasks 2 and 11 exhaustive callback, all-index, mixed-content, and exact-byte contracts |
| Read and buffer-aware mutation tools | Task 10 and Task 12 integration |
| OpenAI-compatible sequential replay | Tasks 2, 7, 11, and 14 dry-run request equality |
| Conversation/composer/tree | Task 13 rebuild tests |
| Abort/interrupted recovery | Tasks 8, 12, 14, and 15 prove call terminal, optional result, turn terminal, operation terminal, then settlement |
| AGENTS/CLAUDE provenance | Task 9 temporary projects and snapshot hashes |
| Fake provider and GPTel contracts | Tasks 2, 8, 11, 12, and 14 |

## Coverage Matrix: Verification and Validation Gates

| Gate | Planned proof |
|---|---|
| Pure parse/validate/reduce/tree/context | Tasks 3, 4, and 7 |
| Temporary-file locking/append/recovery/objects | Tasks 5–6, plus Task 8 registry exclusion for public recovery |
| Competing Emacs and forced death | Task 15 |
| Scripted fake-model lifecycle | Tasks 8 and 12 |
| Real GPTel construction/parser/FSM/continuation offline | Tasks 2, 11, and 14 |
| Project provenance and safe mutation | Tasks 9–10 |
| Crash after every durable transition | Tasks 12 and 15 |
| Rebuild-only rendering | Task 13 |
| Large ledger, warm tail, queue and view bounds | Task 15 |
| Byte-compile, checkdoc, architecture, no network | Tasks 1, 11, 15, and 16 |
| Reproducible Pi/JCS development oracles | Task 1 preflight and Task 3 checked-in goldens |
| Section 20.1 typed-history adapter | Tasks 2 and 11; fail closed before runtime |
| Section 20.2 pause/resume shim | Not enabled; first-slice commit failure withholds continuation and aborts publicly |
| Section 20.3 Unicode/adversarial/JCS framing | Task 3, including full number corpus and pinned independent oracle metadata |
| Section 20.4 measure before persistent index | Task 15; no persistent index in this slice |
| Section 20.5 mcp.el audit | Not enabled and not downloaded by implementation |
| Section 20.6 competing processes/torn tail | Tasks 5, 6, and 15 |

## Design-Invariant Audit

| Invariant | Enforcement |
|---|---|
| Ledger plus objects is sole authority | Tasks 3–7 and acceptance destroys every projection |
| Every other representation is disposable | Tasks 7, 11, 13, and 14 |
| GPTel owns communication/semantic parsing; Epi owns authority | Tasks 2, 10–12 prove the narrow safety audit emits no semantics and architecture scan rejects an alternate loop |
| At most one active logical operation | Task 8 admission FSM |
| Leg completion is not settlement | Tasks 2, 8, and 12 |
| Every tool call has one durable terminal; duplicated proposal/lifecycle/result fields agree exactly; mutable tools have policy evidence | Tasks 4, 7, 8, 10, 12, 14, and 15 |
| Instructions never grant authority | Task 9 negative tests |
| Unsaved buffers are not overwritten | Task 10 mutation refusal |
| Compaction changes projection, not history | Compaction remains disabled; ledger schema is append-only |
| Old generations cannot mutate replacements | Tasks 8, 11, and 15 |
| Compatibility uncertainty fails visibly | Tasks 2 and 11 capability gates/watchdog |
| Kernel is independent of selected UI state | Tasks 8, 12, and 13 |

## First-Slice Definition of Done

Implementation is complete only when all boxes below can be checked with committed evidence:

- [ ] A session can be created, text streamed, `read_file` run, `replace_text` approved, and the logical request settled.
- [ ] Closing every live/request/view buffer and reopening only the ledger and objects reproduces provider-semantic history.
- [ ] Selecting an earlier leaf and continuing creates a new append-only branch; both branches remain continuable.
- [ ] The stored Org JSON bytes, header root, and record chain pass independent RFC 8785/hash goldens.
- [ ] Competing writers yield one winner without corrupting existing bytes; torn final writes require explicit evidence-preserving recovery.
- [ ] Raw provider role, call ID, name, arguments, result, and order survive replay, and every duplicated proposal/lifecycle/result field passes exact cross-record validation.
- [ ] User abort, provider failure, interrupted reopen, queue overflow, undeclared tool, and uncertain mutation each reach one conservative terminal Epi outcome; every planned/started call receives exactly one terminal before its turn/operation terminal.
- [ ] Parallel/mixed/oversized OpenAI tool proposals are rejected before GPTel's inner argument parser, while accepted fixtures traverse the real pinned parser and FSM once.
- [ ] Canonical JSON/frame/nesting/container-entry, decode-unit, raw response, event, argument, context, resource, object, rendering, and reducer-metadata limits pass exact-boundary and one-over tests.
- [ ] Conversation, composer, tree, and raw ledger modes cannot modify canonical history outside public append operations.
- [ ] No GPTel internal symbol occurs outside `epi-gptel.el`; no independent provider loop exists.
- [ ] The complete ERT, process, scale, compile, checkdoc, architecture, and no-network gates pass from a clean process.
- [ ] README behavior and exclusions match the implementation exactly.

## Gated Later-Slice Roadmap

These are context only, not executable tasks in this plan:

1. Complete buffer-aware file and process tools, artifacts, quotas, and cancellation. Count process bytes incrementally, then compute the ordinary content SHA-256 at quota-bounded promotion time (or through a separately tested external checksum); do not invent a chained hash.
2. Add trusted resource discovery, skills, prompt templates, and ordinary Elisp extension hooks.
3. Add durable steering/follow-up queues, a proven pause/resume save-point seam, retry, and exact settlement.
4. Add manual/automatic compaction and branch summaries.
5. Audit a pinned `mcp.el`, then enable tools, resources, prompts, roots, and lifecycle one capability at a time.
6. Add richer session selection, tree interaction, context inspection, and diagnostics.
7. Add optional versioned JSON-lines hosting and Pi import only after the in-process API stabilizes.

Every later slice needs its own behavioral tests, compatibility identifier, ledger-schema review, security review, and fail-closed upgrade gate.

## Execution Discipline

- Execute tasks in numeric order. Use one implementing subagent per task and an independent spec/code reviewer before committing that task.
- At Tasks 2, 6, 12, and 15, stop for an explicit architecture checkpoint even when tests are green; these gates validate the highest-risk assumptions.
- A red test caused by a missing external dependency is a preflight failure, not permission to install or weaken the test.
- A red compatibility test stops the affected capability. Do not flatten typed history, serialize a continuation, or move provider code out of GPTel.
- Keep commits exactly scoped to each task's file list, except for the named “production files required by a failing gate” escape hatch; list every such exception in the commit body.
- Before declaring the slice complete, review the aggregate diff against Sections 16, 18, 20, and 21 of the approved design, then run the complete clean verification one final time.
