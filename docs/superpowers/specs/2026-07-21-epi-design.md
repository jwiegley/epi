# Epi: An Emacs-First Agent Harness

Status: approved design

Date: 2026-07-21

Implementation status: not started

## Purpose

Epi is an Emacs-first implementation of the agent-harness concepts developed
by Pi. It preserves the semantics that make Pi useful as an agent runtime:
durable branching sessions, explicit turn and tool lifecycles, steering and
follow-up queues, compaction, project-resource trust, progressive resource
discovery, and an extension surface. It does not reproduce Pi's terminal
interface or TypeScript extension ABI.

GPTel remains the sole model-communication substrate. It supplies provider
implementations, authentication, request construction, HTTP streaming,
semantic response parsing, model metadata, and the GPTel/mcp.el path to MCP
servers. Epi owns the durable and policy-bearing layers above that substrate.
The pinned adapter may inspect bounded raw transport bytes and outer streaming
envelopes solely to enforce fail-closed capability limits before GPTel decodes
inner tool arguments; that safety audit neither emits provider semantics nor
replaces GPTel's parser or request/FSM loop.

The first objective of this document is architectural: define the complete
target and the invariants that every implementation slice preserves. The
first implementation slice is specified more narrowly in Section 16.

## Source baseline

The design rests on a read-only study of the following source snapshots. The
initial feasibility report at /Users/johnw/dl/report.md supplied the starting
thesis; current source and behavioral tests take precedence where that report
or upstream prose differs from implementation.

| Project | Snapshot | Principal evidence |
|---|---|---|
| [Pi](https://github.com/earendil-works/pi/tree/dd6bea41efa8caa7a10fe5a6401676dc5699f83f) | dd6bea41efa8caa7a10fe5a6401676dc5699f83f | packages/agent, packages/coding-agent, session, compaction, trust, resource, extension, SDK, and RPC tests |
| [GPTel](https://github.com/karthink/gptel/tree/8701e2bd80c5d2091ce2decef5d34d6fce4a3ada) | 8701e2bd80c5d2091ce2decef5d34d6fce4a3ada | gptel-request.el, gptel.el, gptel-org.el, provider implementations, and gptel-integrations.el |
| [JSON Canonicalization](https://github.com/cyberphone/json-canonicalization/tree/19d51d7fe467d4706a3ff08adf8a748f29fc21e0) | 19d51d7fe467d4706a3ff08adf8a748f29fc21e0 | Official test data and the development-only Node ES6 reference used to generate checked-in JCS goldens |
| [gptel-agent](https://github.com/karthink/gptel-agent/tree/e833bcaf617baf8c8075eac098231c4457386814) | e833bcaf617baf8c8075eac098231c4457386814 | gptel-agent.el and gptel-agent-tools.el |
| [Superpowers](https://github.com/obra/superpowers/tree/d884ae04edebef577e82ff7c4e143debd0bbec99) | d884ae04edebef577e82ff7c4e143debd0bbec99 | brainstorming, specification, and parallel-analysis methods |

References of the form Pi: path:line-line and GPTel: path:line-line refer to
these snapshots.

Several findings materially constrain the design:

- Pi's durable value lies in its session projections, lifecycle boundaries,
  resource provenance, trust decisions, and extension semantics rather than
  its terminal renderer (Pi: packages/coding-agent/src/core/session-manager.ts:
  30-153,334-469; packages/coding-agent/src/core/agent-session.ts:545-664).
- Current Pi deliberately omits built-in MCP, subagents, permission popups,
  plan mode, and background shell jobs. MCP support in Epi is therefore a
  deliberate Emacs integration, not a Pi compatibility requirement (Pi:
  packages/coding-agent/docs/usage.md:305-309).
- GPTel's request library is intended for packages and alternate interfaces,
  and already owns provider payloads, parsing, streaming, and its inner tool
  loop (GPTel: gptel-request.el:23-41,1799-2018,2038-2219).
- GPTel's successful streaming marker denotes one HTTP leg, not necessarily a
  settled agent turn. GPTel's custom FSM and advanced typed-history input are
  explicitly less stable than its ordinary request entry point (GPTel:
  gptel-request.el:2038-2219,2446-2480).
- At the pinned revision, the OpenAI streaming parser decodes accumulated
  inner tool arguments before the TOOL-state handler, examines only
  `tool_calls[0]`, and treats nonempty content as excluding tool handling for
  that delta. Sequential-only and no-mixed-content promises therefore require
  a narrow pre-parse outer-envelope audit in the adapter; the later TOOL guard
  remains a second defense, not the first opportunity to reject.
- GPTel's saved Org chat is editable text plus positional role metadata. It is
  useful as a chat format, but it is not an append-only agent ledger (GPTel:
  gptel.el:693-798; gptel-org.el:530-677).
- GPTel's shipped MCP integration imports MCP tools. It does not itself expose
  the complete MCP resource and prompt surface (GPTel:
  gptel-integrations.el:99-189,244-270).
- gptel-agent contains useful prior art for tools, skills, subagents, and
  compaction. It is an optional integration source, not a core dependency:
  its current implementation depends on GPTel internals and does not provide
  the trust and live-buffer mutation rules required here.

## 1. Goals and exclusions

### 1.1 Goals

Epi provides:

1. A versioned, append-only, human-inspectable Org session ledger.
2. A parent-linked conversation tree with explicit active-leaf selection,
   branch navigation, and separate-session forks.
3. A logical agent lifecycle above GPTel's provider and tool-request loop.
4. Durable and distinguishable steering, follow-up, and next-turn input.
5. Provider-neutral messages, reasoning, tool calls, tool results, and usage.
6. Context construction with source provenance and reproducible resource
   snapshots.
7. Iterative compaction and abandoned-branch summaries without deleting
   history.
8. Pi-compatible project-resource trust boundaries, with separate tool and
   operating-system authority.
9. Emacs Lisp extensions expressed through ordinary packages, hooks,
   commands, generic functions, keymaps, and GPTel-compatible tools.
10. An Emacs-native interface composed from Org buffers, completion,
    Transient, diff buffers, compilation buffers, faces, overlays, and
    buttons.
11. A buffer-aware workspace tool model that preserves unsaved user work.
12. A presentation-independent public API suitable for later batch and
    JSON-lines hosts.

### 1.2 Deliberate exclusions

The target does not include:

- TypeScript or Pi terminal-component compatibility.
- A replacement provider library, MCP protocol implementation, or
  authentication store.
- A package installer parallel to package.el, package-vc, Nix, or the user's
  existing package manager.
- Pi theme JSON or ANSI rendering compatibility.
- Silent loading of project-local Elisp.
- An internal sandbox presented as a substitute for process or operating
  system isolation.
- Cross-session merge semantics.
- Durable resurrection of a provider stream or an in-memory GPTel tool
  continuation.
- Exact replication of Pi's screen layout, keybindings, or command syntax.

Pi session import, a versioned JSON-lines host, subagent orchestration, and
managed background processes are possible later facilities. They are not
assumed by the kernel.

## 2. Architectural decision

The canonical architecture is an Org-ledger kernel with a one-way GPTel
projection.

~~~text
Emacs session and tree views
             |
             v
Epi semantic kernel
  ledger | reducer | runtime | trust | tools | compaction
             |
             v
epi-gptel compatibility adapter
             |
             v
GPTel and GPTel/mcp.el
  providers | auth | HTTP | streaming | wire formats | MCP transport
~~~

The dependency direction is one way. The ledger is the only durable source of
truth. The reducer derives active state from the ledger. The runtime creates
immutable operation snapshots from reduced state. The GPTel adapter consumes
those snapshots and reports normalized events. Views consume ledger state and
events, but they cannot become authoritative.

One hidden GPTel request buffer exists for each live Epi session. The buffer
persists long enough to support GPTel's asynchronous request and tool
machinery, which reads some settings from the originating buffer, but its
contents remain replaceable. It is neither saved nor used for recovery.

## 3. Ownership boundaries

### 3.1 GPTel owns

GPTel owns:

- Provider and model definitions.
- Authentication lookup and provider-specific authorization flows.
- Provider payload generation.
- Curl transport and incremental response parsing.
- Provider-specific reasoning, media, tool-call, and tool-result wire forms.
- The current provider request and its inner multi-leg tool continuation.
- GPTel tool schema serialization.
- MCP protocol and process communication through the GPTel/mcp.el stack.

Epi does not reproduce these mechanisms.

### 3.2 Epi owns

Epi owns:

- Session identity, storage, tree structure, and active leaf.
- Logical operations, turns, attempts, save points, and settled state.
- Model-context projection and exact resource provenance.
- Queues and their delivery semantics.
- Tool registration, authority, confirmation, execution, and durable
  lifecycle.
- Retry, timeout, cancellation, and interrupted-operation recovery.
- Project trust and resource precedence.
- Compaction and branch-summary policy.
- Extension lifecycle and session-generation validity.
- All persistent state and every user-facing projection.

The distinction is consequential: GPTel determines how a provider is spoken
to; Epi determines what the agent is allowed to do and what the session means.

## 4. Canonical Org ledger

### 4.1 File organization

Each session occupies one UTF-8 Org file beneath a customizable
epi-session-directory. The default location is private to Epi under
user-emacs-directory. A session file is created with restrictive permissions
because prompts, tool results, and project paths may be sensitive.

The file begins with immutable metadata:

~~~org
#+title: Epi session
#+EPI_FORMAT: 1
#+EPI_SESSION_ID: 8bd8ec8e-...
#+EPI_CREATED_AT: 2026-07-21T18:42:17-07:00
#+EPI_PROJECT_ROOT: /absolute/project/path
#+EPI_CODING_SYSTEM: utf-8-unix
~~~

Every later record is a level-one Org headline appended at end of file:

~~~org
* message 6615e449-...
:PROPERTIES:
:EPI_ID:         6615e449-...
:EPI_TYPE:       message
:EPI_SCHEMA:     1
:EPI_AT:         2026-07-21T18:43:02-07:00
:EPI_PARENT:     b328db4d-...
:EPI_TURN:       4dfd2fe1-...
:EPI_PREV_SHA256: 7b91...
:EPI_RECORD_SHA256: 3fe5...
:END:
#+begin_epi-json
{"at":"2026-07-21T18:43:02-07:00","id":"6615e449-...","parent":"b328db4d-...","payload":{"content":[{"text":"Implement the approved change.","type":"text"}],"role":"user"},"previous_hash":"7b91...","schema":1,"turn":"4dfd2fe1-...","type":"message"}
#+end_epi-json
~~~

The JSON block carries the complete typed record envelope. The property drawer
duplicates fields needed for Org indexing and inspection, and loading rejects
any disagreement. Its body is exactly one line of UTF-8 JSON Canonicalization
Scheme (RFC 8785) output, with no BOM or surrounding whitespace. JSON string
escaping prevents message text from being interpreted as Org structure.
EPI_RECORD_SHA256 covers the exact stored UTF-8 bytes of that canonical JSON
line, excluding the Org block delimiters and line terminator; the append path
canonicalizes once, while cold validation hashes the stored byte range without
parsing and reserializing it. EPI_PREV_SHA256 covers the preceding record hash,
with a canonical header hash serving as the chain root. Every append, import,
and migration passes through the same canonical writer. A dedicated Epi
canonicalizer validates I-JSON, orders object member names by UTF-16 code units,
and implements ECMAScript number serialization; output from json-serialize is
not assumed to be JCS. It accepts Unicode scalar values only: lone surrogates,
characters above U+10FFFF, malformed multibyte strings, and raw non-ASCII bytes
in unibyte strings are rejected before hashing. The chain detects altered
metadata, interior deletion, and reordering as well as payload modification.
The first slice limits canonical JSON to 15 MiB and the complete framed record
to 16 MiB, leaving framing overhead explicit. A torn-tail fragment is bounded
by the complete-frame limit, independently of the immutable-object limit.
Both the canonical writer and the pre-decode lexical validator cap JSON nesting
at 32 containers and the sum of object members plus array elements at 131,072
per record. The validator enforces those structural limits before invoking
Emacs's JSON decoder, so a size-compliant depth or breadth bomb is rejected
without materializing it.
After a fresh restart, deletion
of a complete valid suffix is indistinguishable from an earlier valid head
unless an external trusted witness exists; Epi does not claim adversarial
rollback detection.

Physical Org nesting does not encode branches. All records remain at level
one so that a new child of an old node can still be appended at end of file.
The EPI_PARENT property supplies the logical edge.

The first record in a version-one session is `session-info`. It durably freezes
the working directory, unexpanded base system prompt, backend/model names,
request parameters, tool descriptors, and capability before session creation
returns. Header plus this record publish as one create barrier, so a session
closed before its first prompt remains independently reopenable. Runtime
objects rebind these durable descriptors and never reconstruct creation
defaults from a previous expanded turn prompt or current Emacs defaults.

### 4.2 Record families

The schema contains the following families:

| Family | Representative types | Model context |
|---|---|---|
| Conversation | message, custom-message | Yes, according to role and visibility |
| Structure | leaf, label, session-info, fork-origin, recovery-origin, migration-origin | No |
| Configuration | model-change, thinking-change, active-tools-change, resource-change, session-config | No; reduced according to declared branch or session scope |
| Checkpoint | compaction, branch-summary | Yes, through projection rules |
| Queue | queue-enqueued, queue-consumed, queue-cleared | No until delivery creates context |
| Operation | operation-started, operation-finished, operation-failed, operation-cancelled, operation-interrupted | No |
| Turn | turn-started, turn-finished, turn-failed, turn-cancelled, turn-interrupted | No |
| Tool | tool-planned, tool-approved, tool-denied, tool-started, tool-checkpoint, tool-finished | Tool calls and results project through their associated messages |
| Retry | retry-scheduled, retry-started, retry-finished | No |
| Extension | custom, extension-write-enqueued, extension-write-applied, extension-write-failed | No unless an explicit projector converts it |

Tool lifecycle records are operational evidence, not a second model
transcript. Before a side effect begins, Epi commits an assistant message whose
typed content contains the proposed call IDs, names, arguments, order, and
grouping. After the terminal tool record commits, Epi appends the corresponding
typed tool-result message. Projection uses those messages and correlates them
with lifecycle records by call ID. Epi, not GPTel, assigns durable order as a
zero-based counter for the complete turn; a provider-local list position is
not an order oracle. The first sequential-only capability stores null grouping.
Ledger validation requires exact equality across these duplicates: proposal
call ID/name/arguments/order, lifecycle target/turn/operation/call ID, and
result parent/turn/call/name/model-result/status. Denial maps to a denied model
result; success to success; error, timeout, and provable cancellation to error;
uncertainty forbids a guessed result. A mismatch is corruption even when each
individual record and the record hash chain are otherwise valid.

Conversation, checkpoint, and branch-scoped configuration entries carry a
parent ID and form the logical tree. Appending one selects it as the active
leaf. Model, thinking, active-tool, and model-context resource changes are
branch-scoped and inherit along that path. Queue modes and presentation
preferences use session-scoped configuration records reduced by physical
order. Structural and operational records carry a target ID, operation ID,
turn ID, or cause ID as appropriate. An explicit leaf record changes the
selection without rewriting history.

turn-started carries intended-message and intended-queue-item IDs, and
extension-write-enqueued carries its deterministic target-record ID, as typed
payload fields. These are forward intents, not parent or target edges, and may
name records that are not present yet or never arrive after a crash.

### 4.3 Ledger invariants

The store enforces these invariants:

1. The header has a supported format version and is followed immediately by
   exactly one `session-info` record before any other record.
2. Record IDs are unique.
3. A parent or target refers only to an earlier valid record, except where a
   typed record explicitly permits an external session reference. Only payload
   fields declared by the schema as forward intents may name later or absent
   records; format version one permits this for turn-started's intended-message
   and intended-queue-item IDs and extension-write-enqueued's deterministic
   target-record ID.
4. Physical record order never changes.
5. Existing properties and payloads are never edited or removed.
6. Labels, names, configuration, corrections, and leaf selection are later
   records.
7. Queued input is not a conversation message until delivery.
8. Operational records do not enter model context by default.
9. A tool result retains its tool-call ID and cannot project without the
   corresponding call.
10. Derived indexes, caches, and rendered buffers can be discarded and
    rebuilt from the ledger.
11. The canonical record hash covers IDs, type, schema, time, parent, target,
    turn, operation, payload, and the preceding record hash.

These rules are stricter than ordinary Org editing. Raw ledger buffers
therefore use epi-ledger-mode, which is read-only and intended for inspection.
Users edit sessions through Epi commands and derived views.

### 4.4 Append, locking, and recovery

Before an append, Epi acquires an Epi-owned lock by exclusive lock-file
creation, independently of the user's create-lockfiles setting. The lock spans
comparison of file identity and the last canonical hash, append, flush, and
post-write verification. Every canonical write uses one private local-byte
primitive over unibyte data with no conversion, write annotations disabled,
and explicit exclusive-create/append/replace modes; Epi binds
write-region-inhibit-fsync to nil at durability barriers. If the lock cannot
be acquired or the comparison changes, the append fails without writing.
This contract provides process-crash and competing
Emacs-process safety; a torn final write remains possible after machine or
filesystem failure and is handled as recovery rather than described as an
atomic append.

Session creation uses the same discipline with expected file identity
`absent`: write and verify the complete header plus `session-info` at a hidden
sibling, revalidate absence, and publish by a no-clobber same-filesystem rename
under the create lock. A process crash can expose a recognized hidden
temporary or a complete normal ledger, never a header-only normal session.

Where several adjacent records share one crash barrier, Epi writes their
complete hash-linked forms under one lock and performs one flush. This does
not combine their semantic identities or permit a continuation between them.

The lock token records host, process ID, process-start identity, nonce, and
expected ledger head. Same-host takeover is automatic only when the recorded
process identity is provably no longer live. A remote or indeterminate owner
is never displaced automatically. Explicit stale-lock recovery archives the
token, obtains a new exclusive lock, and revalidates file identity and the
complete expected head before writing.

A truncated final record quarantines the ledger. Epi never appends beyond the
fragment, because that would turn it into interior corruption. The explicit
recovery command preserves the original unchanged, copies the valid prefix
into a new ledger, stores the fragment as a recovery artifact, and appends a
recovery-origin record containing the original path, session ID, and hashes.
The recovered ledger receives a new session ID. Its valid prefix is re-sealed
under the new root while preserving semantic fields, except that the first
session-info payload's session ID changes to agree with the new header; the
recovery-origin record retains the source identity. The original moves, without
content alteration, into a quarantine directory excluded from normal resume;
reachable objects are copied or linked by verified hash. A malformed interior
record, duplicate ID, backward-inconsistent schema, hash-chain failure, or
impossible parent likewise stops normal loading. Epi never guesses past
interior corruption.

Recovery is a restartable multi-file transaction. A canonical fsynced manifest
at `<quarantine-directory>/.epi-recovery/<recovery-id>/manifest.jcs` binds the
exact source file identity/size, header and valid-prefix chain head, exact
fragment offset/size/hash, destination identity/head, reachable-object set,
staging paths, final quarantine path, and last completed phase. Its monotonic
phases are prepared, objects transferred, destination objects published,
destination ledger published, source ledger staged, source objects staged, and
quarantine published. Destination objects publish and verify before the
destination ledger; source ledger and object directory then move into a hidden
quarantine staging directory whose final rename publishes quarantine. Normal
discovery ignores hidden recovery paths. Re-entry verifies and resumes each
idempotent phase, including a crash between source moves, and removes the
manifest only after destination and final quarantine have both been verified.
No extra whole-ledger digest is needed: validation already hashes each record
into the chain head, while the bounded fragment digest covers every trailing
byte. Re-entry revalidates those components cooperatively.
For a default-store ledger the quarantine is under the session directory; for
a custom ledger it defaults to a sibling `.epi-quarantine`. An explicit
quarantine override must be proven on the same filesystem device as the source
parent before recovery creates anything. Source staging and final quarantine
publication are therefore rename-only on one filesystem. The recovered
destination may be elsewhere because it is built and published independently
on its own filesystem.

Schema migration reads the old ledger and writes a new ledger beside it. It
does not rewrite the original. The migrated ledger receives a new session ID
and records migration provenance; the source moves to a versioned archive
excluded from ordinary session selection.

The canonical session store comprises the Org ledger and its immutable,
content-addressed object directory. The ledger is the sole semantic authority:
objects contain bytes but cannot define state or order. Small text payloads
remain inline; large output, binary media, and exact context snapshots may be
objects whose hash, size, media type, and role appear in the ledger. A missing
replay-critical object fails closed with an epi-missing-object condition.
Objects reachable from a ledger are retained; explicit session deletion or
export includes them, and garbage collection removes only unreachable
objects.

### 4.5 Reduction and projections

A pure reducer consumes records in order and yields:

- Session name and project identity.
- Active leaf and parent/child indexes.
- Active root-to-leaf branch.
- Effective branch-scoped model, thinking, active tools, and resources, plus
  session-scoped queue modes.
- Pending queues and pending extension writes.
- Current operation and recovery state.
- Latest applicable compaction.
- Provider-neutral model messages.

The principal projections are the full ledger, logical tree, active branch,
model context, conversation view, and diagnostic operation view. Each has one
defined reducer path; no view independently interprets raw records.

Cold open validates the ledger in order through a private records/bytes/time
cursor and cooperatively yields between bounded I/O and lexical chunks. Emacs's
JSON decoder materializes one already size-checked record as a measured
nonpreemptible unit of at most 15 MiB. Likewise, `secure-hash` consumes one
already bounded record, object, or recovery fragment as a measured
nonpreemptible unit of at most 16 MiB. Epi yields immediately before and after
each hash/decode and reports a slow unit rather than claiming mid-primitive
preemption. Prefix
resealing and reachable-object transfer use the same cursor discipline during
recovery; partial state is never published, and generation plus file
identity/head are revalidated before completion. Thereafter an in-memory, disposable index keyed by file identity,
format, validated byte offset, and tail hash supports tail-only validation and
append-time incremental reduction. A mismatch discards the index and forces a
full validation. Warm append parses only new bytes, reducer metadata is O(n)
without retaining duplicate payload bodies. Parent/child construction uses
O(1)-amortized edge insertion followed by one finalization copy, and traversal
is iterative so deep branches do not consume Elisp recursion. Conversation and
tree views render bounded windows with older regions or child sets materialized
on demand. Large-ledger tests require reducer-owned hash entries plus cons
cells plus vector elements to remain at most `12*n + 1024` for `n` records,
with exactly zero retained payload-body copies. They also assert bounded
rendering, heartbeat interleaving, adversarial chain/star/balanced shapes, and
linear memory growth. Wall-clock/RSS benchmarks compare only a matching
reference-host fingerprint against a versioned baseline.

## 5. Runtime lifecycle

### 5.1 Concurrency and phases

One session admits one structural or agent operation at a time. Independent
sessions may operate concurrently because each has a separate runtime object,
request buffer, cancellation token, and event sequence.

Within one Emacs process, a live-session registry indexes canonical file
identity and durable session ID. Opening the same identity with matching
bindings returns the exact existing object; symlink/hard-link aliases,
conflicting bindings, copied IDs, and path replacement cannot create a second
runtime. Open/create reserves identity before cooperative work, and close or
failure removes only the exact object/token it installed.

Public tail recovery uses that same registry. Before the closed-ledger recovery
primitive may lock, move, or publish anything, the facade atomically reserves
the source path/identity/session ID and destination path/identity/new session
ID in deterministic key order. Any live or reserved alias is busy even if its
runtime is idle; it must be closed first. Exact-token cleanup runs on every
exit, recovery publishes no live runtime, and the caller explicitly opens the
new ledger afterward.

The outer phase is one of:

~~~text
idle
preparing
turn
tool-policy
tool-execution
retry-wait
compaction
branch-summary
settling
~~~

Prompt, explicit compaction, branch navigation, session replacement, and fork
are structural operations. They begin only from idle. Steering, follow-up,
abort, configuration setters, and controlled extension writes may be accepted
at their documented safe points.

First-slice leaf selection is a turnless structural operation whose one crash
barrier appends operation-started, leaf, and operation-finished in that order,
then emits committed agent-settled. It never bypasses operation admission.

`blocked` is not an outer phase. Recovery may reduce a terminalized session to
phase `idle` with a separate blocked reason (for example an uncertain mutation).
Such a session has settled but rejects new structural or agent operations until
an explicit reconciliation record clears the reduced state.

### 5.2 Prompt lifecycle

A user prompt follows this sequence:

1. Assert that the requested action is legal in the current phase.
2. Refresh project identity, trust, and resource diagnostics.
3. Expand a command, skill, or prompt template before queueing.
4. Perform preflight authorization and any required pre-prompt compaction.
5. Allocate deterministic operation, turn, message, and queue-delivery IDs.
6. Append operation-started and turn-started records; turn-started names the
   intended message and queue items but does not consume them.
7. Append next-turn custom context and the accepted user message. A message
   sourced from a queue atomically names and consumes those queue IDs.
8. Construct one immutable turn snapshot.
9. Project the active branch into the hidden GPTel request buffer.
10. Begin the GPTel request and normalize every callback.
11. Persist completed messages and tool lifecycle records at their save
    points.
12. Apply safe configuration changes before a subsequent provider leg.
13. Handle retry, overflow compaction, steering, and follow-up continuation.
14. Append terminal turn and operation records and emit agent-settled.

Preflight failure does not append an accepted user message. Once a mutation is
durably committed, an observational hook failure cannot roll it back.

### 5.3 Turn snapshots and save points

A turn snapshot contains:

- Session, operation, turn, attempt, and generation IDs.
- Active branch and compaction boundary.
- Resolved system prompt and resource provenance.
- Preset identity and definition hash, together with the fully resolved
  backend, model, reasoning level, and request parameters.
- Complete tool definitions and active tool names.
- Queue modes and timeout policy.
- Context and configuration hashes.

The current provider leg uses one fixed snapshot. Configuration setters update
future state immediately but do not mutate an in-flight provider request. A
save point follows a completed assistant/tool batch. At that boundary, pending
session writes flush in deterministic order and a fresh snapshot governs the
next provider leg when save-point continuation is enabled.

The stock GPTel request FSM materializes backend, model, tools, and data once
and immediately enters its next WAIT leg after tool results. It cannot provide
this target behavior by configuration alone. Save-point continuation,
steering, and in-run configuration refresh therefore depend on the explicit,
pinned pause/resume shim specified in Section 6.3. Until that shim or an
equivalent stable upstream API passes its contract suite, the adapter freezes
one snapshot for the complete GPTel request loop and disables those features.

Independently of that shim, each provider leg has a finite progress deadline.
If GPTel becomes nonterminal without producing a documented callback or other
contracted progress before the deadline, the adapter invalidates the operation
generation, aborts the hidden request buffer through public gptel-abort, and
fails the turn. A watchdog can stop a stalled leg; it can never authorize a
tool or continue to another provider leg.

A valid tool-proposal callback with a captured continuation completes that
network leg and cancels its watchdog before Epi queues policy work. Human
approval and tool execution are not provider stalls: the runtime owns their
independent optional policy timer and descriptor-defined execution timer. The
next leg watchdog starts only when a committed result releases the continuation
and GPTel actually begins the next network request.

### 5.4 Settlement

Message completion and agent settlement are distinct. A completed assistant
message may be followed by a transient retry, overflow compaction, steering
continuation, or follow-up turn. agent-settled is emitted exactly once after
all such work has ended and the session is idle.

Batch callers, busy indicators, deferred exports, session replacement, and
tests use agent-settled as their completion boundary.

The optional first-slice prompt settlement callback receives the same committed
agent-settled event as `(callback session event)`, once, after subscribers for
that event have been attempted. Prompt admission validates it, prompt returns
the operation ID before it can run, and callback failure or overrun is diagnosed
without changing or retrying the committed outcome.

## 6. GPTel compatibility adapter

### 6.1 Responsibilities

epi-gptel.el is the only module permitted to depend on GPTel's version-sensitive
representation. It:

- Resolves and validates an explicit GPTel backend and model.
- Installs all request settings buffer-locally, including disabling ambient
  GPTel post-request hooks in the hidden request buffer.
- Requires Curl and effective streaming for the agent lane.
- Converts provider-neutral Epi history into the representation accepted by
  the tested GPTel snapshot.
- Calls gptel-request.
- Normalizes callback values into Epi events.
- Copies a redacted allowlist from GPTel's mutable request information.
- Correlates HTTP legs with the enclosing Epi turn and attempt.
- Sets gptel-use-tools, gptel-confirm-tool-calls, Curl use, and streaming
  explicitly and buffer-locally; confirmation is forced for every tool call.
- Wraps imported tool functions so that GPTel cannot execute them before Epi
  policy.
- Replaces only the Epi request's pinned WAIT action with a wrapper that calls
  a captured, hash-verified function object for GPTel's complete stock WAIT
  handler once while narrowly intercepting its `set-process-filter` call. This
  preserves the stock per-leg clearing of tool-result, tool-use, error, HTTP,
  reasoning, and token fields as well as Curl dispatch and the buffer-local
  post-request hook. GPTel's attempted stock stream filter becomes a
  request-local closure over that exact filter, then the interceptor is
  restored. The closure counts raw leg/turn bytes before GPTel inserts a
  crossing chunk; safe chunks delegate unchanged to GPTel's filter, and
  non-Epi requests remain untouched.
- Runs a pinned around-method safety audit before the OpenAI streaming parser
  decodes inner `function.arguments`. It incrementally inspects every complete
  outer `data:` envelope, every tool-call vector entry/index, raw ID/name and
  raw argument-string bytes, and same-delta content/tool mixture. A bounded
  single-pass scanner validates only the frozen flat primitive argument
  object, including duplicate/member/schema limits, before GPTel's inner
  parser. Transient validation scalars are discarded; it retains bounded raw
  bytes and a length/hash/member/schema attestation, not canonical arguments.
  It produces no response event and calls the stock parser exactly once only
  when the envelope and arguments are safe.
- Guards the pinned TOOL transition before GPTel's stock handler, rejecting
  undeclared, mixed, parallel-when-disabled, malformed, or unsupported calls
  before a continuation or another provider leg can exist.
- After GPTel semantically accepts a tool callback, correlates its raw call ID
  and name with the exact attested raw argument bytes and only then runs a
  separate bounded callback normalizer to produce duplicate-free canonical Epi
  arguments. It erases the raw bytes/attestation before enqueue and never
  treats GPTel's lossy keyword plist as durable arguments.
- Wraps every GPTel tool-result continuation with an exactly-once guard.
- Exposes cancellation and compatibility diagnostics.

The adapter never permits GPTel's silent model fallback to change an Epi
snapshot. Unsupported backend/model pairs fail preflight.
The first-slice pin applies to loaded artifacts, not adjacent source claims:
clean preflight resolves and loads the exact truenamed GPTel `.el` files,
rejects shadowing `.elc`/native artifacts, and verifies representative
functions' `symbol-file` locations. Epi refuses a compiled or shadowed GPTel
even when a nearby source file has the expected hash.

The first slice accepts only a root object schema with
`additionalProperties: false`, deterministic properties and required sets, and
flat string, integer, number, or boolean properties with optional descriptions
and same-type enums. Arrays, nested objects, null unions, combinators,
references, defaults, pattern properties, and unproven keywords fail
compatibility. The adapter compares GPTel's effective dry-run parameters with
an independently normalized expected schema before starting.

### 6.2 Callback normalization

The adapter handles every documented response form:

| GPTel response | Epi interpretation |
|---|---|
| String | Assistant text delta |
| Nil with error information | Transport or provider failure |
| abort | Cancellation acknowledgement |
| t | End of one HTTP leg, not necessarily agent settlement |
| reasoning with text | Reasoning delta |
| reasoning with t | Reasoning block ended |
| tool-call | Tool proposals awaiting Epi policy and execution |
| tool-result | Tool results ready for provider continuation |

GPTel may clear or reuse request information between legs. The adapter copies
the fields it needs during the callback and retains no mutable GPTel plist as
durable state. The Epi layer in the Curl filter stack performs only bounded
raw-byte counting and outer-envelope safety inspection before invoking GPTel's
stock filter; it never emits semantic events or mutates the ledger. Normalized
callbacks copy and enqueue. A head/tail FIFO and chunk collectors provide
O(1)-amortized append; content flattens once at a semantic commit boundary. A timer drains the per-session FIFO in bounded item, byte, and time
quanta. One item and 4 KiB of the published FIFO maxima are unavailable to
ordinary callbacks and reserved for one fixed queue-overflow failure. An
ordinary enqueue that would cross either reduced ceiling is discarded, latches
overflow, invalidates and aborts the request, and occupies that reserve; later
callbacks are dropped. Thus accepted events retain order and total counters
never exceed their maxima while settlement remains representable. Adjacent volatile text or reasoning deltas may coalesce while retaining
their first and last live sequence numbers; committed content never coalesces
across a semantic boundary. Separate hard ceilings cover one event, queued
backlog, raw tool-argument JSON before parsing, each provider leg, the complete
turn, and sequential call count. Crossing one invalidates the generation and
aborts; draining quickly cannot evade total-output limits.
Subscribers are timed and disabled after exceeding the configured execution
budget. Emacs remains a single event thread, so the first slow callback can
still delay later work; the design limits and reports that delay rather than
claiming preemption.

The pre-parse audit first retains `function.arguments` as bounded raw JSON text,
then runs the frozen flat-object scanner to detect duplicate keys, excessive
members, unsupported shapes/types, and schema/enum violations without an
unbounded general JSON materialization. Duplicate outer keys, malformed
envelopes, a second tool index/call, mixed content and tool data, or any
ID/name/argument bound violation terminalizes the adapter without invoking the
stock parser for the rejected envelope. The scanner discards transient values
and records only a nonsemantic attestation. GPTel's stock parser and FSM then
run exactly once and remain the semantic response authority; only its accepted
tool callback authorizes a separate normalizer to turn the exact attested raw
bytes into canonical Epi arguments.

Streaming text and reasoning appear as volatile live signals and remain
transient until a complete provider-neutral message can be committed. A live
signal carries a monotonic volatile sequence but has no replay or durability
guarantee. Should Emacs stop in the middle of a stream, recovery observes an
unfinished turn and marks it interrupted.

At every tool callback and leg boundary, the adapter reconciles the raw
provider proposals with the complete tool registry in the turn snapshot. An
undeclared name never reaches an Epi executor or authorization path. The pinned
GPTel snapshot may synthesize an unavailable-tool result and immediately
advance before Epi's queued drain runs, so the adapter-owned TOOL-state guard
must reject undeclared-only and mixed declared/undeclared responses before the
stock handler. If a proposal cannot be reconciled or GPTel makes no observable
progress, the leg watchdog invalidates continuations, takes exactly one
terminal path, and never starts another provider leg.

Every transition that can permit a tool side effect or another provider leg
has a commit barrier. The adapter does not rely on callback exceptions,
because GPTel may demote them and continue. If ledger persistence fails, the
adapter invalidates the operation generation and withholds every wrapped
tool-result continuation. Before the pause/resume shim is enabled, it aborts
the hidden request through public gptel-abort and rejects every late callback;
after the shim is enabled, it may additionally drive that shim to error or
abort. If the ledger itself cannot record the failure, Epi stops the session
and reports an out-of-ledger diagnostic; it never advances the model loop.

### 6.3 Typed history and save-point seam

Provider-semantic replay across tool-bearing history is a compatibility gate.
The durable model includes roles, ordered content, call ID, name, arguments,
result, and an explicit parallel-group ID. Reasoning and media are retained
for audit, but they are replayed only when the enabled provider capability
declares a tested representation. The current GPTel advanced input can encode
individual prompt, response, and tool entries; it cannot by itself reproduce
all reasoning history or original parallel grouping.

The current GPTel snapshot also advances immediately from tool results to its
next provider request. Exact steering, save-point pausing, and configuration
refresh therefore require a pause/resume FSM seam rather than the stock
callback alone. The baseline commit barrier does not: it withholds the guarded
continuation and aborts through public gptel-abort as specified above.

The design therefore adopts five rules:

1. All typed-history and FSM handling remains in epi-gptel.el.
2. Save-point continuation capabilities explicitly depend on a pinned, tested
   pause/resume FSM shim until GPTel supplies an equivalent stable API.
3. The tested GPTel revision and enabled capability matrix are recorded in
   compatibility diagnostics.
4. Contract tests cover text, supported reasoning and media, duplicate
   parallel tool calls, result IDs, grouping, persistence failure, reopening,
   branching, and each enabled provider family.
5. Epi refuses an unverified GPTel version or capability rather than silently
   flattening typed history.

A stable upstream typed-message and save-point API is preferable. Until one
exists, the adapter contains this documented compatibility dependency over the
tested snapshot. No other Epi module may depend on a GPTel FSM, internal
request registry, text property layout, or provider parser.

### 6.4 MCP boundary

GPTel and mcp.el remain responsible for MCP protocol traffic and server
processes. The studied GPTel baseline supports tool import only. MCP tools
become namespaced Epi tools and pass through ordinary tool policy; removal of a
GPTel tool is not treated as termination of its server.

MCP resources, prompts, roots, and broader lifecycle control remain disabled
until a specific mcp.el snapshot has been downloaded, studied, pinned, and
covered by adapter contracts. The Epi resource-provider interface reserves
their eventual provenance without claiming that the present baseline supplies
it.

## 7. Queues, cancellation, retry, and recovery

### 7.1 Queue semantics

Epi maintains separate queues:

- Steering input enters at the next tool-safe continuation boundary.
- Follow-up input begins after the current agent would otherwise settle.
- Next-turn context waits for the next user-initiated prompt.

Each queue supports all-at-once or one-at-a-time delivery. Skills and prompt
templates expand before enqueueing, so a later resource reload cannot change
queued meaning. Extension commands execute as host actions and are not queued
as model text.

An enqueue record is durable before the API reports success. turn-started may
announce intended queue items, but it does not consume them. Normal delivery
is atomic with the model-visible message: that message carries source-queue
and queue-item IDs, and the reducer considers them consumed only when the
message record is valid. A crash before the message leaves the items pending;
a crash after it cannot redeliver them. Steering delivery uses the same rule
within the existing turn. queue-consumed is reserved for an explicit
administrative drop that never becomes model context. Queue removal becomes
visible before the corresponding committed message-start event.

### 7.2 Cancellation

Cancellation proceeds as follows:

1. Mark cancellation requested for the operation generation.
2. Cancel Epi-owned processes, timers, approvals, and cooperative tools.
3. Abort the active Curl request through GPTel when one exists.
4. Reject or ignore late callbacks from the cancelled generation.
5. Preserve pending writes and next-turn context according to policy.
6. Terminalize every open call before its enclosing entities. A planned call
   receives tool-denied(reason=operation-cancelled) plus a truthful denied
   result message. A started provably side-effect-free call receives
   tool-finished(cancelled) plus a truthful error result message. A started
   mutable call whose side effect cannot be disproved receives
   tool-finished(uncertain) and no guessed result message.
7. Append exactly one terminal record for each enclosing entity. Ordinary
   cancellation then appends turn-cancelled followed by operation-cancelled.
   An outcome that cannot be classified as cancelled uses the matching failed
   or interrupted record type once determined; it never reuses a cancelled
   type. One agent-settled signal follows the durable terminals.

Synchronous Elisp cannot be safely preempted. Tools expected to block therefore
use asynchronous processes or cooperative continuations.

If a mutable tool has started and its executor cannot prove that cancellation
preceded every side effect or completed a rollback, its terminal outcome is
uncertain rather than cancelled. The session blocks provider continuation
until the user records reconciliation.

Such an uncertain normal-execution or abort path uses failed turn/operation
terminals with code tool-uncertain, because it is not truthfully cancelled. An
uncertain state discovered during reopen uses interrupted terminals. Both
orders put tool-finished(uncertain) first and omit a guessed result message.

A request paused in GPTel's TOOL state may have no active transport for public
gptel-abort to find. The adapter therefore invalidates continuations first,
attempts the public abort, and owns exactly-once terminalization of the adapter
handle when no transport exists. It does not advance the FSM or fabricate a
tool result.

### 7.3 Retry

Retry is bounded and semantic. Epi may automatically retry selected connection
failures, rate limits, and server failures only when no visible assistant
output or mutable side effect has occurred. Attempts have distinct IDs and
retain their provider diagnostics. Retry-After takes precedence when present.

Context overflow is not an ordinary transient retry. It invokes compaction and
allows at most one controlled replay of the failed model leg.

### 7.4 Restart recovery

On opening a ledger, Epi reduces the complete record sequence and reconciles
unfinished work:

- Recovery first terminalizes every open call. A planned call receives
  tool-denied(reason=interrupted) and a denied result message; a started
  side-effect-free call receives tool-finished(error, code=interrupted) and an
  error result message; a started possibly-mutating call receives
  tool-finished(uncertain) and no result message. Recovery then appends
  turn-interrupted to every nonterminal turn and operation-interrupted to every
  nonterminal operation. When both exist, the turn terminal precedes its
  enclosing operation terminal. A turnless
  structural operation, including compaction, branch-summary generation,
  branch navigation, session replacement, or fork, receives only
  operation-interrupted. Recovery never appends a second terminal record for
  either entity.
- A turn-started record whose intended message is absent uses those same
  interruption records; its announced queue items remain pending because no
  message consumed them.
- A started mutable tool without a provable result, or one cancelled after a
  possible side effect, settles to outer phase idle after its uncertain call
  terminal and interruption terminals, and retains a separate blocked reason
  requiring user reconciliation. This terminal-but-resultless history is valid
  audit state; it is not replayable provider context and is not corruption.
- An idempotent tool may be offered for explicit retry; it is not retried
  silently.
- Durable queue items remain pending unless a valid model-visible message
  atomically consumed them.
- An extension-write-enqueued record without an applied or failed partner is
  retried by deterministic target ID; if that target already exists, recovery
  appends extension-write-applied without repeating the mutation.
- After recovery has terminalized its old operation, incomplete compaction may
  run again as a new operation only if no final checkpoint exists.
- GPTel continuations, processes, markers, buffers, and FSM objects are never
  recovered.

## 8. Context and resource model

### 8.1 Instruction context

Epi follows Pi's project-instruction model. In each directory, AGENTS.md takes
precedence over CLAUDE.md. A global instruction file loads first; project
ancestors then load from root toward the session working directory.

These instruction files enter model context even before project-resource
trust. The context projector wraps each file in model-visible provenance
delimiters containing its canonical path and trust status, in addition to
retaining that status in diagnostics and the turn snapshot. Instruction text
cannot grant tool authority, expand allowed roots, suppress confirmation, or
approve executable extensions.

### 8.2 Protected project resources

The following project resources remain disabled until trusted:

- Epi settings.
- Elisp extensions.
- Skills and prompt templates.
- Face or presentation definitions.
- SYSTEM.md and APPEND_SYSTEM.md.
- Project and ancestor Agent Skills directories.

Trust decisions reside outside the project and use canonical true names.
Choices include the exact directory, an ancestor, the current session only, or
denial. The closest stored ancestor decision governs. The trust prompt lists
the exact protected resources that caused it.

Project Elisp requires both Epi project-resource trust and Emacs native content
trust. Epi queries trusted-content-p and never grants global trust on the
user's behalf.

### 8.3 Resource records and precedence

Each resource record contains:

- Kind and logical name.
- Canonical path or MCP identity.
- User, project, session, package, or server scope.
- Origin and package identifier.
- Precedence rank.
- Content hash and snapshot reference.
- Enabled and trusted state.
- Collision and loading diagnostics.

Explicit session resources take precedence, followed by project resources and
then user resources. Within a class, ordering is deterministic. Canonical-path
deduplication follows precedence sorting. Named prompt, skill, and presentation
collisions retain the first winner and report the shadowed sources.

SYSTEM.md and APPEND_SYSTEM.md use source selection rather than concatenating
all discovered copies: an explicit source wins, otherwise a trusted project
source wins, otherwise the user source wins.

### 8.4 Skills and prompt templates

Skills follow the Agent Skills progressive-disclosure convention. The system
prompt contains name, description, and source metadata; the complete SKILL.md
body is read only when invoked. Project skill paths remain trust-gated.

Prompt templates are Markdown resources whose front matter supplies metadata
and whose body supplies expansion text. Expansion occurs before enqueueing and
supports documented positional, default, and slice arguments. Resource front
matter is parsed as data and never evaluated as Elisp.

### 8.5 Context snapshots

A turn records the resolved resource set, hashes, bounds, media types, trust
decisions, and final system prompt. Live buffers may supply context, but their
contents are snapshotted at preflight; replay does not silently read a newer
version under an old hash.

Model-visible local inputs have explicit byte ceilings: base prompt,
individual and aggregate instruction resources, each file-read result, and the
complete projected provider context. Disk metadata rejects obvious oversize
inputs before reading; live buffers are encoded through bounded temporaries and
checked by encoded byte count. Limit failure precedes prompt acceptance or tool
content publication.

## 9. Tool and workspace model

### 9.1 Tool definition

An Epi tool contains:

- Stable name and version.
- Description and JSON-compatible argument schema.
- Read, write, execute, or network authority class.
- Allowed-root policy.
- Confirmation policy.
- Timeout and cancellation behavior.
- Idempotency and retry-safety declarations.
- Executor and result encoder.
- Provenance and redaction policy.

Epi compiles this definition into a GPTel tool schema. The Epi registry, not
GPTel's global registry, is authoritative for a session snapshot. Each
imported tool receives a stable canonical identity containing origin, server
when applicable, declared name, and schema hash. Model-facing names are
sanitized aliases; duplicate aliases reject snapshot construction until the
user supplies an explicit rename.

An imported tool without complete Epi metadata receives write, execute, and
network authority; confirmation on every call; no allowed project root; no
automatic retry; sequential scheduling; and the default finite timeout.
Explicit user configuration may narrow these defaults. Tool discovery never
silently shadows another tool.

Every call follows this durable sequence:

~~~text
planned -> approved or denied -> started -> progress -> finished
                                           +-> failed
                                           +-> timed out
                                           +-> cancelled
~~~

Progress in this diagram is a volatile live signal by default. A tool may
commit a semantic tool-checkpoint at a named milestone or a configured
rate-limited interval, but arbitrary progress chunks do not each acquire the
ledger lock or force a flush.

The terminal record is committed before GPTel receives the model-facing
result. A structured Epi error remains available even when the provider sees a
textual error result.

Abort and reopen use the same entity order even though their provider
continuation is dead: call terminal, optional truthful model-result message,
turn terminal, operation terminal, then agent-settled. Planned calls terminate
by denial; started side-effect-free calls terminate by cancellation or
interrupted error; started calls with a possible unprovable side effect
terminate uncertain without a guessed result. Every call therefore has exactly
one durable terminal even when the enclosing operation does not complete
normally.

The enclosing type still reflects truth: uncertain execution/abort is failed,
whereas uncertain evidence found on reopen is interrupted. Ordinary abort is
cancelled only when every affected outcome is provably cancelled.

The ordering applies equally when a provider or runtime failure ends an
operation while a call is open. Its planned call is denied with the failure
cause, its started side-effect-free call finishes with an ordinary error, and
its started possibly-effectful call finishes uncertain; only then do the failed
turn and operation terminals commit.

### 9.2 File reads

When a path is already visited, a read tool reads the live buffer rather than
stale disk content. The snapshot records the file name, buffer identity,
modification state, bounds, coding system, and content hash. An unsaved read is
clearly marked.

Path policy resolves canonical existing paths and canonical parent
directories for new paths. Symlink aliases cannot escape an allowed root.

### 9.3 File mutation

A mutation:

1. Resolves the target and required authority.
2. Opens or reuses the visiting buffer.
3. Validates an expected hash or range precondition and detects modifications
   that predate the Epi change.
4. Computes a non-mutating proposed diff in a temporary buffer. When policy
   requires confirmation, approval occurs before any shared lock is held.
5. Refuses automatic mutation of a buffer with pre-existing user changes. An
   explicit interactive override shows both the pre-existing and proposed
   diffs and obtains consent to save the entire buffer, including user work.
6. Acquires a canonical-path mutation lock shared by every Epi session.
7. Revalidates the modification tick, expected hash, path identity, and disk
   state under the lock.
8. Applies the edit as one atomic undo group and saves the buffer so
   subprocesses observe the same state. The save may consume only decisions
   approved in steps 4 and 5. Epi-owned UI and extension callbacks do not run
   inside this critical section, and an interaction guard makes any attempt by
   save code or an ordinary save hook to read input or open a modal dialog
   signal epi-interaction-required instead of waiting for the user.
9. Verifies the realized disk and buffer diff, including save-hook effects,
   then releases the lock.
10. Records before and after hashes, the approved and realized diffs, and
    change provenance before provider continuation.
11. Presents the realized result outside the critical section.

The single-edit path has explicit work bounds. Epi caches the current buffer
hash only while buffer identity, coding, bounds, and
buffer-chars-modified-tick remain unchanged; under-lock disk revalidation is
never skipped on the strength of that cache. The proposed-result hash is
computed with the approved diff. After save, if the disk hash equals that
proposed hash and buffer identity, coding, and modification tick prove that no
save hook changed the content, the approved diff is also the realized diff and
is reused rather than recomputed. Any mismatch takes the full verification
path and may produce an uncertain outcome. A configurable byte ceiling rejects
automatic mutation of oversized files with epi-limit-exceeded unless the user
explicitly raises it for that operation. Batch mutation remains a later-slice
capability, not a requirement of the first minimal mutation tool.

Epi never reverts, overwrites, or silently merges a modified user buffer. An
interaction request before disk mutation rolls back the buffer edit, releases
the lock, and may be presented outside the critical section; acceptance starts
a new transaction at step 1 rather than resuming the locked one. A failure
before disk mutation rolls back when exact restoration is provable. A save
failure, interaction request after a hook side effect, unexpected save-hook
change, or unverifiable partial write produces an uncertain tool outcome and
blocks continuation for reconciliation. A reversal is a new, explicit change
whose history remains visible.

A conflict found during step 7, before Epi changes buffer or disk bytes, is an
ordinary precondition-failed tool result and may be returned to the model.
Uncertainty is reserved for a path where an Epi side effect may already have
occurred and the realized outcome cannot be proved.

### 9.4 Processes

Process tools prefer argument vectors and make-process over shell evaluation.
They use an explicit working directory, separate standard output and error,
timeouts, and cancellation. Output streams directly into private mode-0600
temporary files while byte counts update incrementally; it is not accumulated
without bound in Emacs strings. Per-call and aggregate session quotas, together
with a free-space reserve, constrain artifact growth. When the stream closes,
Epi computes the ordinary SHA-256 content hash once from the quota-bounded file
in a unibyte temporary buffer, then promotes successful output under that same
hash into the immutable object store. Crossing a hard limit cancels the
process, closes and hashes the captured file by the same procedure, and commits
an output-limit terminal result containing byte counts, truncation state, and
hashes. Model-facing output remains separately bounded. Process tools and this
promotion contract enter their own later implementation slice.

Allowed roots and confirmation are policy controls, not a process sandbox. A
shell may access every resource available to the Emacs process unless an
external operating-system boundary says otherwise.

### 9.5 Parallelism

Read-only calls may run concurrently when their tools declare that behavior
safe. Mutating calls are serialized by default. Parallel mutation requires an
explicit commutativity or isolation guarantee; absence of metadata means
sequential execution.

## 10. Compaction and branch summaries

### 10.1 Model-context projection

The context reducer walks the active root-to-leaf path, applies configuration
records from the complete path, locates the latest applicable compaction, and
projects only model-visible entries. Operational records remain available for
diagnostics but do not consume model context.

### 10.2 Compaction preparation

Compaction chooses a valid cut boundary under a configurable recent-context
budget. It never separates a tool result from the assistant tool call that
caused it. It detects a cut inside a user turn and preserves the necessary
prefix semantics.

The generated checkpoint records:

- Goal and governing constraints.
- Work completed and current progress.
- Decisions and their rationale.
- Remaining work and known blockers.
- Critical names, paths, commands, and values.
- Files read and files modified, derived from Epi tool records.
- Source entry range and first retained entry.
- Tokens before compaction and the estimation method.
- Summarizer backend, model, prompt version, usage, and origin.

The user or an extension may preview, replace, or cancel the summary before
commit. Once committed, correction takes the form of another checkpoint.

### 10.3 Iteration and automatic compaction

Compaction is iterative. A later checkpoint incorporates the previous
checkpoint and summarizes only the newly eligible history. The ledger is
never truncated. Model context begins with the latest checkpoint, continues
at its first retained entry, and then includes subsequent branch entries.

Automatic compaction runs before the model's context reserve is exhausted.
Provider-reported usage is preferred; a documented estimate serves as a
fallback. Threshold compaction does not repeat a completed answer. A context
overflow may compact and retry once.

### 10.4 Branch summaries

When navigation abandons one path for another, Epi may summarize the abandoned
path from the common ancestor to the old leaf. The branch summary omits raw
operational noise, retains relevant earlier checkpoints, and is appended at
the destination branch. It imports useful context without changing either
source path.

Branch-summary policy is configurable as off, ask, or automatic.

## 11. Extension model

Extensions are ordinary Emacs Lisp packages. User extensions load through the
existing Emacs package configuration. Trusted project extensions may load
from .epi/extensions after both Epi and native Emacs trust checks succeed.

The public extension surface contains:

- Lifecycle and observational hooks.
- Input, context, tool, and compaction transformation hooks.
- Interactive commands and Transient suffixes.
- Keymap contributions.
- Tool and resource providers.
- Renderer generic functions.
- Completion sources.
- Header-line, mode-line, and status contributions.
- Session custom records and model-context projectors.
- GPTel backend and preset selection through existing GPTel facilities.

Epi introduces no extension factory ABI and no package installer. Commands are
interactive functions; flags are defcustom options or Transient state; themes
are faces; renderers produce propertized Emacs text or standard buffers.

### 11.1 Hook settlement

Transforming hooks run before commit in deterministic registration order.
Their event-specific contract states whether they may replace, block, or
cancel. Observational hooks run after commit. If an observer fails, the
committed mutation remains and the initiating API returns a committed outcome
carrying observer diagnostics. It does not signal an ordinary retryable
mutation failure. A stricter caller may request an epi-committed-hook-error,
whose condition data states unambiguously that the mutation committed.

Extensions do not receive the raw mutable ledger or runtime object. A
session-scoped facade supplies supported reads and writes. Writes requested
while busy append extension-write-enqueued before the API reports acceptance.
The record contains the extension identity, runtime generation, stable write
ID, deterministic target record ID, payload hash, and idempotency contract.
Writes flush after agent-emitted messages at the next save point and append
extension-write-applied or extension-write-failed. Operation settlement flushes
or fails every remaining write, so a request cannot remain merely in memory.
Recovery uses the deterministic target ID to avoid duplicate application. A
write from a stale generation fails against the old session and never migrates
into its replacement.

### 11.2 Session replacement

New, resume, fork, import, and project-switch operations create a new runtime
generation. The old runtime emits shutdown, releases processes and
subscriptions, and invalidates its facade before the new generation becomes
visible. An extension object captured from an old generation fails loudly.

## 12. Emacs interaction model

### 12.1 Session buffer

The primary session buffer uses Org presentation but is not the ledger. It
contains:

- A compact session header.
- Read-only conversation history.
- Foldable reasoning, tool, checkpoint, and metadata regions.
- Transient streaming and progress regions.
- A writable prompt composer at the end.

When a message completes, the durable ledger projection replaces transient
output. Killing or rebuilding the view cannot lose session state.

Rendering is bounded by both logical items and inserted content bytes. The
conversation view uses bounded previews plus explicit load/view actions; the
tree uses iterative, node-capped expansion with continuation nodes. Each user
action has its own cap, so one large message or a wide branch cannot bypass the
initial-window limit.

### 12.2 Native interaction

Epi uses:

- Org folding and navigation.
- Standard buttons and text properties.
- diff-mode buffers for mutation review.
- compilation-mode buffers for process output.
- completing-read and compatible completion front ends.
- Transient for session and agent commands.
- Header-line or mode-line status for model, branch, queues, context, and
  operation state.
- Standard minibuffer confirmation, quit, and recursive-edit conventions.

No terminal component factory or raw-input compatibility layer is present.

### 12.3 Branch editing

The tree view reconstructs logical parent relationships and labels from the
ledger. Selecting a leaf changes the active branch by appending a leaf record.
Editing an earlier message copies its content into the prompt composer and
selects that message's parent; sending appends a new branch. The original
message remains unchanged.

A fork creates a new ledger from a selected branch and records the source
session and source leaf. Branching stays within one ledger; forking does not.

### 12.4 Commands

The principal commands include:

- Create, open, name, and close a session.
- Send, steer, follow up, queue for next turn, and abort.
- Select a model, preset, thinking level, and active tools.
- Navigate, label, branch, edit-as-branch, and fork.
- Compact and summarize a branch.
- Inspect context, resources, trust, ledger records, and diagnostics.
- Review, approve, deny, or reverse a tool change.
- Wait until settled.

The first slice exposes `epi`, `epi-open-session`, `epi-send`, `epi-abort`,
`epi-show-tree`, and `epi-show-ledger`, backed by public display functions that
return buffers. Session and tree buffers are owned by session ID, reused while
live, and rebuilt from ledger state after they are killed; the raw ledger buffer
visits the canonical file under read-only `epi-ledger-mode`.

The public functions behind these commands do not require a selected window or
active minibuffer. A later batch or JSON-lines host calls the same kernel.

## 13. Public API, events, and errors

### 13.1 Public operations

The public API is organized around session operations:

- Create, open, inspect, and close.
- Prompt, steer, follow up, and supply next-turn context.
- Abort and wait until settled.
- Compact, navigate, branch, and fork.
- Read and update supported configuration.
- Register tools, resources, renderers, and hooks.
- Subscribe to semantic events.

Raw record append remains internal except through a validated custom-record
operation.

### 13.2 Event identity and ordering

Committed semantic events carry the applicable session, generation,
operation, turn, attempt, tool-call, record, and durable sequence identifiers.
Their order follows ledger commit order and they are replayable. Volatile live
signals carry a separate monotonic live sequence and are never replayed; they
cover streaming text, streaming reasoning, and non-durable progress. A later
committed message or tool record supersedes its live signals. The committed
event families cover:

- Session, replacement, resource, and trust lifecycle.
- Operation and turn lifecycle.
- Message and reasoning completion.
- Tool policy, execution, rate-limited semantic checkpoints, and result.
- Queue changes and delivery.
- Retry and compaction.
- Error, cancellation, and agent-settled.

Subscribers may reconstruct presentation from ledger plus events without
observing an item as both queued and active.

### 13.3 Error hierarchy

Epi defines conditions for:

- Busy or invalid phase.
- Stale session generation.
- Ledger format, corruption, and append conflict.
- Resource and trust failure.
- Invalid backend, model, or GPTel compatibility.
- Provider and transport failure.
- Tool denial, execution failure, timeout, and uncertain side effect.
- Cancellation and interruption.
- Hook failure.

Conditions preserve structured causes and stable error codes. Committed
outcomes cannot be mistaken for retryable pre-commit failures. User messages
remain concise; the diagnostic buffer exposes the particulars after redaction.

## 14. Security posture

Project-resource trust, tool authority, and operating-system isolation answer
different questions:

| Boundary | Question |
|---|---|
| Resource trust | May project prompts, skills, settings, presentation, and code load? |
| Tool policy | May this model invoke this tool with these arguments in this session? |
| OS isolation | What files, credentials, network, and processes can Emacs actually reach? |

None implies another.

Additional rules follow:

- The ledger hash chain detects corruption and interior history edits, not
  adversarial deletion of a complete suffix after restart. Deployments
  requiring rollback evidence maintain an external signed head witness.
- Canonical paths and true names govern trust and allowed roots.
- Project instructions cannot modify tool policy.
- Project Elisp never loads merely because an instruction file mentions it.
- Skill and prompt metadata is parsed as data and never evaluated.
- Epi-captured authorization headers, OAuth tokens, backend key material, and
  transport diagnostics never enter the ledger. User prompts, project files,
  and tool output may themselves contain secrets; Epi cannot infer otherwise
  and warns that sessions are sensitive records.
- GPTel debug logging remains disabled by default; diagnostic redaction is
  tested.
- Mutable tools display their effective target and diff or command before
  approval unless an explicit user policy grants otherwise.
- Tool denial returns a valid model-facing result without disguising the
  durable denial reason.
- External containers, virtual machines, or operating-system profiles remain
  the appropriate boundary for hostile execution.

Session and object directories use mode 0700 and files use mode 0600 by
default. Export applies an explicit redaction policy. Session deletion covers
the ledger and every reachable object; garbage collection removes only
unreachable objects after a user-visible retention interval.

## 15. Module boundaries

The initial package uses a small set of files:

| File | Responsibility |
|---|---|
| epi.el | Public API, customization group, entry commands, and feature |
| epi-ledger.el | Org record format, validation, append, reduction, tree, and projections |
| epi-runtime.el | Operations, turns, events, queues, cancellation, recovery, and settlement |
| epi-gptel.el | Sole GPTel compatibility and MCP-discovery boundary |
| epi-ui.el | Session buffer, composer, tree view, rendering, and Transient entry |

Further files appear when implemented responsibility warrants the split:

| File | Responsibility |
|---|---|
| epi-tools.el | Tool registry, policy, execution, file and process tools |
| epi-resources.el | Instructions, skills, templates, provenance, and trust |
| epi-compact.el | Context budgeting, compaction, and branch summaries |
| epi-jsonl.el | Optional versioned external host |

The split is not a mandate to create empty scaffolding. A new file appears
only when it contains a coherent implemented boundary.

The minimum platform is Emacs 30.1 with Org 9.7 or later. GPTel compatibility is expressed by a
tested source snapshot and contract capabilities rather than an optimistic
version comparison.

## 16. First implementation slice

The first slice validates the riskiest boundaries without implementing the
entire target.

### 16.1 Included

The slice includes:

1. Version-one Org header and record parser.
2. Locked append, semantic hash-chain validation, and final-tail recovery.
3. Session-info, user, assistant, reasoning, tool, turn, operation, leaf,
   interruption, and recovery-origin records.
4. Pure active-branch and model-context reduction.
5. One live session object and one hidden GPTel request buffer.
6. Streaming one GPTel-backed turn through the Epi outer lifecycle.
7. Callback normalization for text, reasoning, tool, error, abort, and
   per-leg completion.
8. One read-only tool and one minimal buffer-aware, confirmable mutation tool
   through Epi policy.
9. Provider-semantic replay of text and sequential tool calls after reopen and
   branch selection for one explicitly enabled OpenAI-compatible GPTel
   backend. Parallel grouping, replayed reasoning, and additional provider
   families remain capability-gated.
10. A read-only conversation view, writable composer, and logical tree view.
11. Abort and conservative interrupted-turn recovery.
12. AGENTS.md and CLAUDE.md discovery with source provenance.
13. Deterministic fake-provider tests and the GPTel contract suite.

### 16.2 Excluded from the slice

The slice excludes:

- Durable steering and follow-up queues.
- Automatic compaction and branch summarization.
- Generic transient retry.
- The full file, shell, and MCP resource toolset.
- Skills, prompt templates, and project extension loading.
- JSON-lines control and Pi session import.
- Subagents, background jobs, and parallel mutation.

These exclusions bound implementation effort; the ledger and public types
already reserve their target semantics.

### 16.3 Definition of done

The slice is complete when an Epi session can be created, streamed,
tool-extended, saved, reopened, branched, and continued while meeting all of
the following conditions:

- The append-only Org ledger is the sole semantic authority; every required
  external object is immutable and named by a ledger hash.
- No mutable GPTel chat buffer is required for recovery.
- Tool-bearing history retains the enabled provider semantics: role, call ID,
  name, arguments, result, and order.
- A cancelled or interrupted turn reaches one terminal Epi state.
- The conversation and tree views rebuild from the ledger.
- No GPTel internal symbol appears outside epi-gptel.el.
- The required ERT and byte-compilation gates pass without network access.

## 17. Subsequent slices

After the first slice, implementation proceeds by behavior rather than by
calendar estimate:

1. Complete buffer-aware file and process tools, confirmation, artifacts, and
   cancellation.
2. Add resource discovery, trust, skills, prompt templates, and ordinary Elisp
   extension hooks.
3. Add durable queues, save-point delivery, retries, and exact settlement.
4. Add manual and automatic compaction, then branch summaries.
5. After the required mcp.el source audit, complete the capabilities that its
   pinned adapter proves, beginning with tools and enabling resources, prompts,
   roots, and lifecycle control separately.
6. Add session selection, richer tree interaction, context inspection, and
   operational diagnostics.
7. Add an optional versioned JSON-lines host and Pi import only after the
   in-process API has stabilized.

Each slice supplies its own behavioral tests and leaves the ledger readable by
the preceding version where its schema permits.

## 18. Verification

### 18.1 Test layers

The complete target test suite contains the following layers. A layer becomes
a release gate when its corresponding implementation slice lands; excluded
features do not gate the first slice.

- Pure ERT tests for parsing, validation, reduction, tree traversal, queue
  reduction, context construction, compaction preparation, and recovery.
- Temporary-file tests for locking, complete append, partial tail, corruption,
  migration, permissions, and content-addressed objects.
- Competing-Emacs and forced-death tests for lock ownership, same-host stale
  takeover, remote-owner refusal, head revalidation, batched flushes, and every
  recovery-manifest phase including the interval between the two source moves.
- Scripted fake-model tests for the lifecycle features present in the slice,
  expanding to retries, overflow, queues, compaction, and settlement as those
  features land.
- GPTel adapter contract tests for every callback form, two- and three-leg
  tool turns, all tool-call vector indices, same- and cross-delta mixed
  content/tool proposals, tool IDs/names/arguments at exact byte boundaries,
  effective streaming, malformed responses, and abort. Accepted fixtures run
  through GPTel's real parser; rejected envelopes prove the stock inner-argument
  parse, TOOL handler, and next transport leg never run.
- Temporary-project tests beginning with project instructions and the minimal
  mutation tool, then adding trust, symlink traversal, resource precedence,
  modified-buffer override, atomic undo, save hooks, and process cancellation
  with their respective slices. Mutation tests include a save hook that tries
  to query the user and prove that no prompt blocks while the path lock is held.
  They instrument hash and diff passes, exercise the oversized-file ceiling,
  and prove that the unchanged-save-hook path reuses the approved diff. When
  process tools land, a quota-sized promotion fixture compares the object name
  with an independent SHA-256 of the exact captured bytes.
- Crash-point tests after each durable transition. When each turnless
  structural-operation slice lands, its tests interrupt the operation before
  its terminal record and prove recovery appends one operation-interrupted and
  reduces the outer phase to idle.
- Rendering tests proving that a view rebuilds from records and does not
  mutate them.
- Large-ledger fixtures asserting tail-only warm append, bounded initial
  rendering, incremental reduction, bounded callback queues, linear metadata
  memory, adversarial chain/star/balanced trees, cooperative heartbeat
  interleaving, slow-drip total-output limits, and exact per-stage counters.
  A versioned 100k-record reference fixture gates matching-host elapsed median
  at 2.0 times baseline and peak RSS at 1.5 times baseline; other fingerprints
  report without comparison. A cold-validation fixture
  proves record-chain hashing consumes stored canonical JSON byte ranges and
  does not invoke record reserialization.
- Byte-compilation, checkdoc, and warning-free package checks.

No paid provider request forms part of the required suite. Optional live
smokes are diagnostic and never substitute for deterministic tests.

The first-slice adapter gate enables one OpenAI-compatible GPTel backend with
sequential tool calls. Its offline contract harness replaces only the network
transport: real GPTel request construction, FSM transitions, callback
normalization, and tool continuations run against recorded raw SSE and JSON
fixtures. Separate provider-parser fixtures are required before Anthropic,
Gemini, or another family is enabled.

### 18.2 Upstream behavioral oracles

Pi's tests serve as independent behavioral oracles for:

- Parent-linked tree traversal, branch extraction, and delayed persistence.
- Compaction cut boundaries, retained context, and iterative checkpoints.
- Steering and follow-up delivery order.
- Queue visibility before message start.
- Exactly one settled event after continuation.
- Resource precedence and canonical-path deduplication.
- Closest-ancestor trust decisions.
- Session-runtime replacement and stale-context invalidation.
- JSON-lines framing, should that host be implemented.

The tests are ported for behavior, not translated line for line.

### 18.3 Compatibility gates

A GPTel upgrade is accepted only after the adapter contract suite proves:

1. Explicit backend and model selection.
2. Effective Curl streaming.
3. Every documented callback form.
4. Logical completion across multi-leg tool use.
5. Typed replay for each enabled provider capability.
6. Cancellation during model I/O, approval, and tool execution.
7. Commit-barrier behavior when ledger append fails at stream completion,
   tool proposal, and tool result.
8. Undeclared-only and mixed declared/undeclared tool proposals reach one
   terminal Epi state within the leg-watchdog bound without unauthorized
   execution or a hung GPTel FSM.
9. Duplicate identical parallel proposals remain distinct by provider call
   ID when parallel capability is enabled.
10. Redacted diagnostic behavior.
11. No reliance on serialized GPTel continuations.
12. The raw-byte and outer-envelope guards reject parallel, mixed, and
    oversized proposals before GPTel's inner argument parser, while accepted
    proposals still traverse the real pinned parser and FSM exactly once.

Failure closes the affected capability. Epi does not silently downgrade a
typed session to flattened text.

## 19. Alternatives considered

### 19.1 GPTel Org chat as canonical state

This option requires less initial code and uses GPTel's existing save and
restore behavior. It was rejected for the target because editable positional
metadata does not provide append-only history, durable queues, explicit
operation recovery, or an independent settled boundary. Ordinary GPTel Org
chat remains a useful import or export view.

### 19.2 Independent provider-leg implementation

This option gives Epi complete control over provider and tool sequencing. It
was rejected because it would reproduce provider-sensitive machinery already
present in GPTel and would increase the surface tied to GPTel internals.

### 19.3 Durable Epi records with a bidirectionally editable GPTel buffer

This option combines an Epi ledger with an editable GPTel materialization. It
was rejected because two representations could accept authoritative edits and
diverge after a crash. The selected architecture retains only one-way,
replaceable GPTel projection.

## 20. Validation gates

The following matters require implementation probes, but they do not reopen
the architectural decision:

1. Prove the pinned typed-history adapter for the first enabled sequential-tool
   provider capability, then extend the matrix only with provider fixtures.
2. Before enabling steering or in-run configuration refresh, prove the
   explicit pause/resume FSM shim or replace it with an equivalent stable
   upstream hook.
3. Confirm Org special-block framing and checksum normalization against
   arbitrary Unicode and adversarial message text. Prove the dedicated
   canonicalizer against RFC 8785 Appendix B, including its number vectors,
   and compare canonical bytes and digests with an independent JCS
   implementation.
4. Measure reducer and rendering behavior on large ledgers before introducing
   any persistent index.
5. Download and audit a pinned mcp.el snapshot before enabling resources,
   prompts, roots, or lifecycle beyond GPTel's current tool importer.
6. Test competing Emacs processes, disabled ordinary lockfiles, forced process
   death during append, and torn-tail recovery under the explicit Epi lock.

Each gate fails closed. No result justifies introducing a second durable
session representation.

## 21. Design invariants

The implementation remains conformant only while these statements stay true:

1. The append-only Org ledger is the sole semantic session authority;
   immutable hash-addressed objects are payload members of the canonical
   session store.
2. Every other representation is a pure or replaceable projection.
3. GPTel owns provider and MCP communication plus semantic response parsing;
   Epi owns harness semantics, authority, and the narrow pinned safety audit
   needed to fail closed before unsafe inner tool-argument parsing.
4. One session has at most one active logical operation.
5. A provider-leg boundary is not an agent-settled boundary.
6. Every mutable tool call has durable policy and terminal records.
7. Project instructions never grant tool authority.
8. Existing unsaved buffers are never overwritten silently.
9. Compaction changes context projection, not source history.
10. Old session-generation objects cannot mutate a replacement session.
11. Compatibility uncertainty fails visibly rather than flattening or
    guessing.
12. The kernel remains independent of selected windows, minibuffers, and
    rendered buffers.

These invariants are the standard against which implementation plans, code
reviews, and future extensions are judged.
