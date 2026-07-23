;;; epi-ledger.el --- Canonical append-only Epi ledgers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley
;; Keywords: tools, convenience

;;; Commentary:

;; This module owns Epi's version-one canonical JSON and Org framing.  Org is
;; presentation only: framing is scanned as bounded literal bytes, without
;; Babel, property evaluation, or general Org interpretation.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'epi)

(defconst epi-header-value-byte-limit 1048576
  "Maximum encoded bytes retained for one version-one header value.
This fixed semantic bound is independent of the cooperative work slice.  It
covers ordinary local pathname limits and bounds the one contiguous retained
header-field materialization required by portable Emacs Lisp.")

(defconst epi-ledger--batch-record-limit 256
  "Maximum number of drafts accepted by one create or append operation.")

(defconst epi-ledger--batch-byte-limit 33554432
  "Maximum exact rendered bytes accepted by one create or append batch.")

(defconst epi-ledger--lock-token-byte-limit 65536
  "Maximum number of bytes in one canonical Epi lock token.")

(cl-defstruct (epi-header
               (:constructor epi-ledger--make-header)
               (:conc-name epi-header--raw-))
  "Immutable version-one ledger header metadata."
  (title nil :read-only t)
  (format nil :read-only t)
  (session-id nil :read-only t)
  (created-at nil :read-only t)
  (project-root nil :read-only t)
  (coding-system nil :read-only t)
  (hash nil :read-only t)
  (byte-size nil :read-only t)
  (end-offset nil :read-only t))

(cl-defstruct epi-draft
  "Unsealed canonical record input."
  id type at parent target turn operation payload)

(cl-defstruct (epi-record
               (:constructor epi-ledger--make-record)
               (:conc-name epi-record--raw-))
  "One validated canonical ledger record.
SEALED-JSON is transient output owned by a newly sealed record.  Records read
from a ledger leave it nil so the decoded PAYLOAD is the sole retained body."
  (id nil :read-only t)
  (type nil :read-only t)
  (schema nil :read-only t)
  (at nil :read-only t)
  (previous-hash nil :read-only t)
  (hash nil :read-only t)
  (parent nil :read-only t)
  (target nil :read-only t)
  (turn nil :read-only t)
  (operation nil :read-only t)
  (payload nil :read-only t)
  (sequence nil :read-only t)
  (start-offset nil :read-only t)
  (json-start-offset nil :read-only t)
  (json-end-offset nil :read-only t)
  (end-offset nil :read-only t)
  (frame-byte-size nil :read-only t)
  (sealed-json nil :read-only t))

(cl-defstruct (epi-ledger--semantic-capsule
               (:constructor epi-ledger--make-semantic-capsule)
               (:conc-name epi-ledger--semantic-capsule-raw-))
  "Immutable-by-convention cross-record validation state.
The capsule deliberately excludes the transient reverse record accumulator."
  (by-id nil :read-only t)
  (operations nil :read-only t)
  (turns nil :read-only t)
  (turn-operation-index nil :read-only t)
  (calls nil :read-only t)
  (calls-by-target nil :read-only t)
  (reserved-call-ids nil :read-only t)
  (intents nil :read-only t)
  (active-operation nil :read-only t)
  (active-call nil :read-only t)
  (session-seen nil :read-only t)
  (first-nonsession nil :read-only t)
  (pending-proposal nil :read-only t)
  (pending-result nil :read-only t)
  (terminalization-required nil :read-only t)
  (recovery-evidence nil :read-only t)
  (latest-recovery-origin nil :read-only t)
  (recovery-terminalization-required nil :read-only t)
  (deferred-references nil :read-only t)
  (uncertain nil :read-only t)
  (uncertainty-phase nil :read-only t)
  (uncertainty-class nil :read-only t)
  (uncertainty-turn nil :read-only t)
  (uncertainty-operation nil :read-only t))

(cl-defstruct (epi-ledger--checkpoint
               (:constructor epi-ledger--make-checkpoint)
               (:conc-name epi-ledger--checkpoint-raw-))
  "Immutable publication checkpoint for one validated ledger prefix."
  (file-identity nil :read-only t)
  (validated-end-offset 0 :read-only t)
  (tail-hash nil :read-only t)
  (records [] :read-only t)
  (by-id nil :read-only t)
  (turn-operation-index nil :read-only t)
  (tool-facts nil :read-only t)
  (semantic-capsule nil :read-only t)
  (uncertain nil :read-only t))

(cl-defstruct (epi-ledger--inspection
               (:constructor epi-ledger--make-inspection)
               (:conc-name epi-ledger--inspection-raw-))
  "One identity-bound result of the authoritative cold ledger scanner."
  (state nil :read-only t)
  (canonical-path nil :read-only t)
  (file-identity nil :read-only t)
  (source-size 0 :read-only t)
  (header nil :read-only t)
  (record-index nil :read-only t)
  (semantic-capsule nil :read-only t)
  (last-record nil :read-only t)
  (next-sequence 1 :read-only t)
  (validated-end 0 :read-only t)
  (valid-prefix-head nil :read-only t)
  (fragment-offset nil :read-only t)
  (fragment-size nil :read-only t)
  (fragment-hash nil :read-only t)
  (fragment-bytes nil :read-only t))

(defconst epi-ledger--inspection-record-size
  (length (epi-ledger--make-inspection))
  "Exact private record size of a cold ledger inspection.")

(cl-defstruct (epi-ledger--recovery-record-proof
               (:constructor epi-ledger--make-recovery-record-proof))
  "One frame-free proof produced by a recovery reseal dry run."
  source-previous-hash source-hash destination-hash frame-byte-size)

(cl-defstruct (epi-ledger--recovery-source-proof
               (:constructor epi-ledger--make-recovery-source-proof))
  "Owned scalar evidence binding a recovery plan to one source prefix."
  canonical-path file-identity source-size
  header-title header-format header-session-id header-created-at
  header-project-root header-coding-system header-hash
  validated-end valid-prefix-head next-sequence
  fragment-offset fragment-size fragment-hash
  record-count record-proofs)

(cl-defstruct (epi-ledger--recovery-reseal-plan
               (:constructor epi-ledger--make-recovery-reseal-plan))
  "Frame-free deterministic plan for one recovery reseal stream."
  source-proof destination-session-id origin-id origin-at origin-payload
  source-evidence-sha256 destination-header-sha256
  destination-header-byte-size destination-prefix-head final-head
  origin-frame-byte-size source-record-count output-record-count byte-size)

(cl-defstruct
    (epi-ledger--recovery-layout
     (:constructor epi-ledger--make-recovery-layout)
     (:conc-name epi-ledger--recovery-layout-raw-))
  "Immutable path and device layout for one recovery transaction."
  (source-path nil :read-only t)
  (source-objects-path nil :read-only t)
  (destination-path nil :read-only t)
  (destination-objects-path nil :read-only t)
  (staged-destination-ledger-path nil :read-only t)
  (staged-destination-objects-path nil :read-only t)
  (quarantine-root nil :read-only t)
  (quarantine-device nil :read-only t)
  (quarantine-anchor-path nil :read-only t)
  (quarantine-anchor-identity nil :read-only t)
  (quarantine-root-identity nil :read-only t)
  (control-directory nil :read-only t)
  (control-identity nil :read-only t)
  (transaction-directory nil :read-only t)
  (manifest-path nil :read-only t)
  (manifest-temporary-path nil :read-only t)
  (source-stage-path nil :read-only t)
  (staged-source-ledger-path nil :read-only t)
  (staged-source-objects-path nil :read-only t)
  (absent-source-objects-marker-path nil :read-only t)
  (final-quarantine-path nil :read-only t))

(cl-defstruct
    (epi-ledger--recovery-preflight
     (:constructor epi-ledger--make-recovery-preflight)
     (:conc-name epi-ledger--recovery-preflight-raw-))
  "Immutable closed preflight for one prepared recovery manifest."
  (inspection nil :read-only t)
  (source-proof nil :read-only t)
  (reseal-plan nil :read-only t)
  (recovery-id nil :read-only t)
  (layout nil :read-only t)
  (destination-parent-identity nil :read-only t)
  (source-object-tree-state nil :read-only t)
  (source-objects-identity nil :read-only t)
  (reachable-objects [] :read-only t)
  (reachable-object-identities [] :read-only t)
  (manifest-object nil :read-only t)
  (manifest-bytes nil :read-only t))

(cl-defstruct
    (epi-ledger--recovery-prepared
     (:constructor epi-ledger--make-recovery-prepared)
     (:conc-name epi-ledger--recovery-prepared-raw-))
  "Verified durable prepared-manifest result for one recovery transaction."
  (preflight nil :read-only t)
  (quarantine-anchor-identity nil :read-only t)
  (quarantine-root-identity nil :read-only t)
  (control-identity nil :read-only t)
  (directory-receipts nil :read-only t)
  (transaction-identity nil :read-only t)
  (manifest-identity nil :read-only t)
  (transaction-entry-state nil :read-only t)
  (source-last-record nil :read-only t)
  (path-layout nil :read-only t))

(cl-defstruct
    (epi-ledger--recovery-phase-state
     (:constructor epi-ledger--make-recovery-phase-state)
     (:conc-name epi-ledger--recovery-phase-state-raw-))
  "Closed authority for one durable recovery transaction phase."
  (phase nil :read-only t)
  (preflight nil :read-only t)
  (path-layout nil :read-only t)
  (source-last-record nil :read-only t)
  (quarantine-anchor-identity nil :read-only t)
  (quarantine-root-identity nil :read-only t)
  (control-identity nil :read-only t)
  (directory-receipts nil :read-only t)
  (transaction-identity nil :read-only t)
  (manifest-identity nil :read-only t)
  (manifest-bytes nil :read-only t)
  (transaction-entry-state nil :read-only t)
  (destination-parent-identity nil :read-only t)
  (staged-object-root-identity nil :read-only t)
  (staged-directory-receipts nil :read-only t)
  (staged-object-receipts nil :read-only t)
  (staged-ledger-identity nil :read-only t))

(defconst epi-ledger--recovery-record-proof-record-size
  (length (epi-ledger--make-recovery-record-proof))
  "Exact private record size of a recovery record proof.")

(defconst epi-ledger--recovery-source-proof-record-size
  (length (epi-ledger--make-recovery-source-proof))
  "Exact private record size of a recovery source proof.")

(defconst epi-ledger--recovery-reseal-plan-record-size
  (length (epi-ledger--make-recovery-reseal-plan))
  "Exact private record size of a recovery reseal plan.")

(defconst epi-ledger--recovery-preflight-record-size
  (length (epi-ledger--make-recovery-preflight))
  "Exact private record size of a recovery preflight.")

(defconst epi-ledger--recovery-layout-record-size
  (length (epi-ledger--make-recovery-layout))
  "Exact private record size of a recovery path layout.")

(defconst epi-ledger--recovery-prepared-record-size
  (length (epi-ledger--make-recovery-prepared))
  "Exact private record size of a durable prepared-manifest result.")

(cl-defstruct (epi-ledger--record-chunk
               (:constructor epi-ledger--make-record-chunk)
               (:conc-name epi-ledger--record-chunk-raw-))
  "One bounded immutable chunk in a cold-open record index."
  (values [] :read-only t)
  (count 0 :read-only t))

(cl-defstruct (epi-ledger--record-index
               (:constructor epi-ledger--make-record-index)
               (:conc-name epi-ledger--record-index-raw-))
  "Immutable record order represented by bounded vector chunks."
  (chunks nil :read-only t)
  (count 0 :read-only t))

(defconst epi-ledger--header-record-size
  (length (epi-ledger--make-header))
  "Exact private record size of a ledger header.")

(defconst epi-ledger--record-record-size
  (length (epi-ledger--make-record))
  "Exact private record size of a sealed ledger record.")

(defconst epi-ledger--semantic-capsule-record-size
  (length (epi-ledger--make-semantic-capsule))
  "Exact private record size of a semantic capsule.")

(defconst epi-ledger--record-chunk-record-size
  (length (epi-ledger--make-record-chunk))
  "Exact private record size of a record-index chunk.")

(defconst epi-ledger--record-index-record-size
  (length (epi-ledger--make-record-index))
  "Exact private record size of a record index.")

(defun epi-ledger--recovery-exact-record-p (value predicate size)
  "Return non-nil when VALUE satisfies PREDICATE with exact record SIZE."
  (and (funcall predicate value) (= (length value) size)))

(cl-defstruct (epi-ledger--source-region
               (:constructor epi-ledger--make-source-region)
               (:conc-name epi-ledger--source-region-raw-))
  "Immutable unibyte buffer range used by the cold framing scanner."
  (buffer nil :read-only t)
  (start 1 :read-only t)
  (end 1 :read-only t)
  (tick 0 :read-only t))

(cl-defstruct (epi-ledger--checkpoint-cell
               (:constructor epi-ledger--make-checkpoint-cell)
               (:conc-name epi-ledger--checkpoint-cell-raw-))
  "Private mutable cell publishing a ledger checkpoint atomically."
  value)

(cl-defstruct (epi-ledger--lock
               (:constructor epi-ledger--make-lock))
  "Private proof of ownership for one exact Epi lock token."
  lock-file bytes sha256 file-identity expected-file expected-end expected-head)

(cl-defstruct (epi-ledger
               (:constructor epi-ledger--make-ledger)
               (:conc-name epi-ledger--raw-))
  "Opaque validated ledger handle.
All structural fields are immutable.  Only CHECKPOINT-CELL may publish a new
  private immutable checkpoint after a future append has been read back."
  (path nil :read-only t)
  (header nil :read-only t)
  (session-id nil :read-only t)
  (project-root nil :read-only t)
  (checkpoint-cell nil :read-only t))

(cl-defstruct (epi-object-ref
               (:constructor epi-ledger--make-object-ref)
               (:conc-name epi-object-ref--raw-))
  "Immutable reference to one content-addressed ledger object."
  (hash nil :read-only t)
  (size nil :read-only t)
  (media-type nil :read-only t)
  (role nil :read-only t))

(cl-defstruct (epi-message
               (:constructor epi-ledger--make-message)
               (:conc-name epi-message--raw-))
  "Provider-neutral copied projection of one message record."
  (record-id nil :read-only t)
  (role nil :read-only t)
  (content nil :read-only t)
  (parent nil :read-only t)
  (turn nil :read-only t)
  (sequence nil :read-only t))

(defconst epi-ledger--work-clock-check-interval 4096
  "Maximum charged work units between deadline clock checks.")

(cl-defstruct (epi-ledger--work-state
               (:constructor epi-ledger--make-work-state-internal))
  processed last-yield next-check deadline check-interval)

(defvar epi-ledger--operation-work-state nil
  "Dynamic cooperative-work cursor shared by one public operation.")

(defvar epi-ledger--operation-yield-buffer nil
  "Private neutral buffer made current across cooperative yields.")

(defvar epi-ledger--operation-yield-owner nil
  "Private cell retaining the neutral buffer owned by an outer operation.")

(defvar epi-ledger--work-protected-buffer nil
  "Private operation buffer whose text must remain stable across a yield.")

(defvar epi-ledger--work-protected-change-handler nil
  "Function called when a protected operation buffer changes across a yield.")

(defun epi-ledger--new-work-state ()
  "Return a fresh cooperative byte/work cursor."
  (let ((interval
         (max 1 (min epi-ledger--work-clock-check-interval
                     epi-ledger-work-byte-limit))))
    (epi-ledger--make-work-state-internal
     :processed 0 :last-yield 0 :next-check interval
     :deadline (+ (epi--deadline-time) epi-ledger-work-time-budget)
     :check-interval interval)))

(defun epi-ledger--make-work-state ()
  "Return the current operation cursor, or a fresh standalone cursor."
  (or epi-ledger--operation-work-state (epi-ledger--new-work-state)))

(defun epi-ledger--kill-yield-buffer (buffer)
  "Kill owned neutral yield BUFFER without running callback-installed hooks."
  (when (buffer-live-p buffer)
    (condition-case nil
        (with-current-buffer buffer
          (let ((kill-buffer-hook nil)
                (kill-buffer-query-functions nil))
            (kill-buffer buffer)))
      (error nil))))

(defmacro epi-ledger--with-operation-work-state (&rest body)
  "Evaluate BODY with one shared work cursor and neutral yield buffer."
  (declare (indent 0) (debug t))
  (let ((outermost (make-symbol "outermost"))
        (owner (make-symbol "owner")))
    `(let* ((,outermost (not (consp epi-ledger--operation-yield-owner)))
            (,owner (or epi-ledger--operation-yield-owner (list nil)))
            (epi-ledger--operation-yield-owner ,owner)
            (epi-ledger--operation-work-state
             (or epi-ledger--operation-work-state
                 (epi-ledger--new-work-state)))
            (epi-ledger--operation-yield-buffer
             (or (car ,owner) epi-ledger--operation-yield-buffer)))
       (unwind-protect
           (progn ,@body)
         (when ,outermost
           (epi-ledger--kill-yield-buffer (car ,owner))
           (setcar ,owner nil))))))

(defun epi-ledger--public-value-copy (value)
  "Return an ownership-isolated public projection of immutable VALUE."
  (epi-ledger--trusted-value-copy value))

(defmacro epi-ledger--define-public-reader (name raw-reader)
  "Define public accessor NAME as a defensive view of RAW-READER."
  `(defun ,name (object)
     ,(format "Return an ownership-isolated `%s' value from OBJECT." name)
     (epi-ledger--public-value-copy (,raw-reader object))))

(epi-ledger--define-public-reader epi-header-title epi-header--raw-title)
(epi-ledger--define-public-reader epi-header-format epi-header--raw-format)
(epi-ledger--define-public-reader epi-header-session-id
                                  epi-header--raw-session-id)
(epi-ledger--define-public-reader epi-header-created-at
                                  epi-header--raw-created-at)
(epi-ledger--define-public-reader epi-header-project-root
                                  epi-header--raw-project-root)
(epi-ledger--define-public-reader epi-header-coding-system
                                  epi-header--raw-coding-system)
(epi-ledger--define-public-reader epi-header-hash epi-header--raw-hash)
(epi-ledger--define-public-reader epi-header-byte-size
                                  epi-header--raw-byte-size)
(epi-ledger--define-public-reader epi-header-end-offset
                                  epi-header--raw-end-offset)

(epi-ledger--define-public-reader epi-record-id epi-record--raw-id)
(epi-ledger--define-public-reader epi-record-type epi-record--raw-type)
(epi-ledger--define-public-reader epi-record-schema epi-record--raw-schema)
(epi-ledger--define-public-reader epi-record-at epi-record--raw-at)
(epi-ledger--define-public-reader epi-record-previous-hash
                                  epi-record--raw-previous-hash)
(epi-ledger--define-public-reader epi-record-hash epi-record--raw-hash)
(epi-ledger--define-public-reader epi-record-parent epi-record--raw-parent)
(epi-ledger--define-public-reader epi-record-target epi-record--raw-target)
(epi-ledger--define-public-reader epi-record-turn epi-record--raw-turn)
(epi-ledger--define-public-reader epi-record-operation
                                  epi-record--raw-operation)
(epi-ledger--define-public-reader epi-record-payload epi-record--raw-payload)
(epi-ledger--define-public-reader epi-record-sequence
                                  epi-record--raw-sequence)
(epi-ledger--define-public-reader epi-record-start-offset
                                  epi-record--raw-start-offset)
(epi-ledger--define-public-reader epi-record-json-start-offset
                                  epi-record--raw-json-start-offset)
(epi-ledger--define-public-reader epi-record-json-end-offset
                                  epi-record--raw-json-end-offset)
(epi-ledger--define-public-reader epi-record-end-offset
                                  epi-record--raw-end-offset)
(epi-ledger--define-public-reader epi-record-frame-byte-size
                                  epi-record--raw-frame-byte-size)
(epi-ledger--define-public-reader epi-record-sealed-json
                                  epi-record--raw-sealed-json)

(epi-ledger--define-public-reader epi-object-ref-hash
                                  epi-object-ref--raw-hash)
(epi-ledger--define-public-reader epi-object-ref-size
                                  epi-object-ref--raw-size)
(epi-ledger--define-public-reader epi-object-ref-media-type
                                  epi-object-ref--raw-media-type)
(epi-ledger--define-public-reader epi-object-ref-role
                                  epi-object-ref--raw-role)

(epi-ledger--define-public-reader epi-message-record-id
                                  epi-message--raw-record-id)
(epi-ledger--define-public-reader epi-message-role epi-message--raw-role)
(epi-ledger--define-public-reader epi-message-content
                                  epi-message--raw-content)
(epi-ledger--define-public-reader epi-message-parent epi-message--raw-parent)
(epi-ledger--define-public-reader epi-message-turn epi-message--raw-turn)
(epi-ledger--define-public-reader epi-message-sequence
                                  epi-message--raw-sequence)

(epi-ledger--define-public-reader epi-ledger-path epi-ledger--raw-path)
(epi-ledger--define-public-reader epi-ledger-session-id
                                  epi-ledger--raw-session-id)
(epi-ledger--define-public-reader epi-ledger-project-root
                                  epi-ledger--raw-project-root)

(defun epi-ledger--copy-header (header)
  "Return a recursively ownership-isolated copy of HEADER."
  (epi-ledger--make-header
   :title (epi-ledger--trusted-value-copy (epi-header--raw-title header))
   :format (epi-header--raw-format header)
   :session-id
   (epi-ledger--trusted-value-copy (epi-header--raw-session-id header))
   :created-at
   (epi-ledger--trusted-value-copy (epi-header--raw-created-at header))
   :project-root
   (epi-ledger--trusted-value-copy (epi-header--raw-project-root header))
   :coding-system
   (epi-ledger--trusted-value-copy (epi-header--raw-coding-system header))
   :hash (epi-ledger--trusted-value-copy (epi-header--raw-hash header))
   :byte-size (epi-header--raw-byte-size header)
   :end-offset (epi-header--raw-end-offset header)))

(defun epi-ledger--copy-record (record)
  "Return a recursively ownership-isolated copy of RECORD."
  (epi-ledger--make-record
   :id (epi-ledger--trusted-value-copy (epi-record--raw-id record))
   :type (epi-record--raw-type record)
   :schema (epi-record--raw-schema record)
   :at (epi-ledger--trusted-value-copy (epi-record--raw-at record))
   :previous-hash
   (epi-ledger--trusted-value-copy (epi-record--raw-previous-hash record))
   :hash (epi-ledger--trusted-value-copy (epi-record--raw-hash record))
   :parent (and (epi-record--raw-parent record)
                (epi-ledger--trusted-value-copy
                 (epi-record--raw-parent record)))
   :target (and (epi-record--raw-target record)
                (epi-ledger--trusted-value-copy
                 (epi-record--raw-target record)))
   :turn (and (epi-record--raw-turn record)
              (epi-ledger--trusted-value-copy
               (epi-record--raw-turn record)))
   :operation (and (epi-record--raw-operation record)
                   (epi-ledger--trusted-value-copy
                    (epi-record--raw-operation record)))
   :payload (epi-ledger--trusted-value-copy (epi-record--raw-payload record))
   :sequence (epi-record--raw-sequence record)
   :start-offset (epi-record--raw-start-offset record)
   :json-start-offset (epi-record--raw-json-start-offset record)
   :json-end-offset (epi-record--raw-json-end-offset record)
   :end-offset (epi-record--raw-end-offset record)
   :frame-byte-size (epi-record--raw-frame-byte-size record)
   :sealed-json nil))

(defun epi-ledger-header (ledger)
  "Return a defensive copy of LEDGER's validated header."
  (epi-ledger--copy-header (epi-ledger--raw-header ledger)))

(defun epi-ledger-records (ledger)
  "Return defensive copies of LEDGER's validated records."
  (epi-ledger--with-operation-work-state
    (let* ((source
            (epi-ledger--checkpoint-raw-records
             (epi-ledger--checkpoint-snapshot ledger)))
           (work (epi-ledger--make-work-state))
           (count (epi-ledger--record-source-length source))
           (result
            (epi-ledger--run-bounded-unit
             'allocate 'public-records (* 8 count) work
             (lambda () (make-vector count nil))))
           (index 0))
      (epi-ledger--record-source-each
       source
       (lambda (record)
         (epi-ledger--work-charge work 1)
         (aset result index (epi-ledger--copy-record record))
         (setq index (1+ index))))
      result)))

(defun epi-ledger-record-by-id (ledger record-id)
  "Return a defensive copy of LEDGER's RECORD-ID record, or nil."
  (let ((record
         (gethash record-id
                  (epi-ledger--checkpoint-raw-by-id
                   (epi-ledger--checkpoint-snapshot ledger)))))
    (and record (epi-ledger--copy-record record))))

(defun epi-ledger--checkpoint-snapshot (ledger)
  "Return LEDGER's current private immutable checkpoint object."
  (epi-ledger--checkpoint-cell-raw-value
   (epi-ledger--raw-checkpoint-cell ledger)))

(defun epi-ledger--checkpoint-cas (ledger expected replacement)
  "Publish REPLACEMENT in LEDGER only when its checkpoint is EXPECTED.
The comparison is by identity.  This primitive performs no cooperative yield,
callback, traversal, or I/O between the comparison and the cell store."
  (let ((cell (epi-ledger--raw-checkpoint-cell ledger)))
    (when (eq expected (epi-ledger--checkpoint-cell-raw-value cell))
      (setf (epi-ledger--checkpoint-cell-raw-value cell) replacement)
      t)))

(defun epi-ledger--checkpoint-uncertain-successor (checkpoint)
  "Return a successor of CHECKPOINT whose storage uncertainty bit is set.
All retained checkpoint authorities, including the semantic capsule, are
shared by identity; CHECKPOINT itself is not changed."
  (epi-ledger--make-checkpoint
   :file-identity
   (epi-ledger--checkpoint-raw-file-identity checkpoint)
   :validated-end-offset
   (epi-ledger--checkpoint-raw-validated-end-offset checkpoint)
   :tail-hash (epi-ledger--checkpoint-raw-tail-hash checkpoint)
   :records (epi-ledger--checkpoint-raw-records checkpoint)
   :by-id (epi-ledger--checkpoint-raw-by-id checkpoint)
   :turn-operation-index
   (epi-ledger--checkpoint-raw-turn-operation-index checkpoint)
   :tool-facts (epi-ledger--checkpoint-raw-tool-facts checkpoint)
   :semantic-capsule
   (epi-ledger--checkpoint-raw-semantic-capsule checkpoint)
   :uncertain t))

(defun epi-ledger--record-source-length (source)
  "Return the number of records in private ordered SOURCE."
  (cond
   ((epi-ledger--record-index-p source)
    (epi-ledger--record-index-raw-count source))
   ((vectorp source) (length source))
   ((listp source)
    (epi-ledger--with-operation-work-state
      (let ((tail source)
            (work (epi-ledger--make-work-state))
            (count 0))
        (while (consp tail)
          (setq tail (epi-ledger--work-cdr tail work)
                count (1+ count)))
        (unless (null tail)
          (error "Improper private record source"))
        count)))
   (t (signal 'wrong-type-argument (list 'sequencep source)))))

(defun epi-ledger--record-source-each (source function)
  "Call FUNCTION for each record in private ordered SOURCE."
  (cond
   ((epi-ledger--record-index-p source)
    (dolist (chunk (epi-ledger--record-index-raw-chunks source))
      (let ((values (epi-ledger--record-chunk-raw-values chunk)))
        (dotimes (index (epi-ledger--record-chunk-raw-count chunk))
          (funcall function (aref values index))))))
   ((vectorp source)
    (seq-doseq (record source)
      (funcall function record)))
   ((listp source)
    (epi-ledger--with-operation-work-state
      (let ((tail source)
            (work (epi-ledger--make-work-state)))
        (while (consp tail)
          (let ((record (epi-ledger--work-car tail work))
                (next (epi-ledger--work-cdr tail work)))
            (funcall function record)
            (setq tail next)))
        (unless (null tail)
          (error "Improper private record source")))))
   (t (signal 'wrong-type-argument (list 'sequencep source)))))

(defun epi-ledger--record-source-elt (source index)
  "Return record INDEX from private ordered SOURCE."
  (unless (and (integerp index) (<= 0 index))
    (signal 'args-out-of-range (list source index)))
  (cond
   ((epi-ledger--record-index-p source)
    (unless (< index (epi-ledger--record-index-raw-count source))
      (signal 'args-out-of-range (list source index)))
    (let ((offset index))
      (catch 'record
        (dolist (chunk (epi-ledger--record-index-raw-chunks source))
          (let ((count (epi-ledger--record-chunk-raw-count chunk)))
            (if (< offset count)
                (throw 'record
                       (aref (epi-ledger--record-chunk-raw-values chunk)
                             offset))
              (setq offset (- offset count))))))))
   ((vectorp source)
    (unless (< index (length source))
      (signal 'args-out-of-range (list source index)))
    (aref source index))
   ((listp source)
    (epi-ledger--with-operation-work-state
      (let ((tail source)
            (offset index)
            (work (epi-ledger--make-work-state)))
        (while (and (consp tail) (> offset 0))
          (setq tail (epi-ledger--work-cdr tail work)
                offset (1- offset)))
        (if (consp tail)
            (epi-ledger--work-car tail work)
          (signal 'args-out-of-range (list source index))))))
   (t (signal 'wrong-type-argument (list 'sequencep source)))))

(defun epi-ledger--record-source-last (source)
  "Return the retained final record in private ordered SOURCE, or nil.
This structural lookup neither copies nor visits record bodies."
  (cond
   ((epi-ledger--record-index-p source)
    (let (last-chunk)
      (dolist (chunk (epi-ledger--record-index-raw-chunks source))
        (setq last-chunk chunk))
      (when last-chunk
        (let ((count (epi-ledger--record-chunk-raw-count last-chunk)))
          (and (> count 0)
               (aref (epi-ledger--record-chunk-raw-values last-chunk)
                     (1- count)))))))
   ((vectorp source)
    (and (> (length source) 0) (aref source (1- (length source)))))
   ((listp source)
    (let ((tail source)
          last)
      (while (consp tail)
        (setq last (car tail)
              tail (cdr tail)))
      (unless (null tail)
        (error "Improper private record source"))
      last))
   (t (signal 'wrong-type-argument (list 'sequencep source)))))

(defun epi-ledger-file-identity (ledger)
  "Return a defensive copy of LEDGER's validated file identity."
  (epi-ledger--copy-tree-and-strings
   (epi-ledger--checkpoint-raw-file-identity
    (epi-ledger--checkpoint-snapshot ledger))))

(defun epi-ledger-validated-end-offset (ledger)
  "Return LEDGER's last completely validated absolute byte offset."
  (epi-ledger--checkpoint-raw-validated-end-offset
   (epi-ledger--checkpoint-snapshot ledger)))

(defun epi-ledger-tail-hash (ledger)
  "Return a defensive copy of LEDGER's validated chain-head hash."
  (epi-ledger--public-value-copy
   (epi-ledger--checkpoint-raw-tail-hash
    (epi-ledger--checkpoint-snapshot ledger))))

(defconst epi-ledger--maximum-safe-integer 9007199254740991
  "Largest integer accepted by the version-one canonical codec.")

(defconst epi-ledger--maximum-canonical-number-byte-length 25
  "Maximum byte length of a canonical binary64 or safe-integer number.
Shortest binary64 spellings use at most 17 significant digits.  Fixed form
adds at most a sign, decimal point, and five leading zeroes; scientific form
adds at most a sign, decimal point, exponent marker, sign, and three digits.")

(defconst epi-ledger--envelope-key-order
  '("id" "type" "schema" "at" "previous_hash" "parent" "target"
    "turn" "operation" "payload")
  "Closed set of version-one record-envelope keys.")

(defconst epi-ledger--record-schemas
  '((session-info
     :required-envelope nil
     :required-payload
     ("session_id" "working_directory" "base_system_prompt" "backend"
      "model" "request_params" "tools" "capability"))
    (operation-started
     :required-envelope (operation)
     :required-payload ("operation_id" "kind"))
    (turn-started
     :required-envelope (turn operation)
     :required-payload
     ("turn_id" "operation_id" "attempt_id" "message_id"
      "working_directory" "base_system_prompt" "resources" "system_prompt"
      "backend" "model" "request_params" "tools" "snapshot_hash"))
    (message
     :required-envelope (turn)
     :optional-envelope (parent)
     :required-payload ("role" "content"))
    (reasoning
     :required-envelope (turn)
     :required-payload ("text" "leg" "replay"))
    (leaf
     :required-envelope (target operation)
     :required-payload nil)
    (tool-planned
     :required-envelope (target turn operation)
     :required-payload ("call_id" "name" "arguments" "authority" "order"))
    (tool-approved
     :required-envelope (target turn operation)
     :required-payload ("call_id" "policy")
     :optional-payload ("approved_diff_sha256"))
    (tool-denied
     :required-envelope (target turn operation)
     :required-payload ("call_id" "reason" "model_result"))
    (tool-started
     :required-envelope (target turn operation)
     :required-payload ("call_id" "tool_version"))
    (tool-finished
     :required-envelope (target turn operation)
     :required-payload ("call_id" "status" "details")
     :optional-payload ("model_result"))
    (turn-finished
     :required-envelope (turn operation)
     :required-payload ("turn_id" "status"))
    (turn-failed
     :required-envelope (turn operation)
     :required-payload ("turn_id" "code" "details"))
    (turn-cancelled
     :required-envelope (turn operation)
     :required-payload ("turn_id" "reason"))
    (turn-interrupted
     :required-envelope (turn operation)
     :required-payload ("turn_id" "reason"))
    (operation-finished
     :required-envelope (operation)
     :required-payload ("operation_id" "status"))
    (operation-failed
     :required-envelope (operation)
     :required-payload ("operation_id" "code" "details"))
    (operation-cancelled
     :required-envelope (operation)
     :required-payload ("operation_id" "reason"))
    (operation-interrupted
     :required-envelope (operation)
     :required-payload ("operation_id" "reason"))
    (recovery-origin
     :required-envelope nil
     :required-payload
     ("source_path" "source_session_id" "source_file_size"
      "source_header_sha256" "source_valid_prefix_head_sha256"
      "fragment_offset" "fragment_sha256" "fragment_size"
      "fragment_object" "destination_valid_prefix_head_sha256"
      "source_evidence_sha256")))
  "Closed schema descriptor for the twenty first-slice record types.")

(defconst epi-ledger--recovery-evidence-v1-fields
  '("source_path" "source_session_id" "source_file_size"
    "source_header_sha256" "source_valid_prefix_head_sha256"
    "fragment_offset" "fragment_sha256" "fragment_size"
    "fragment_object" "destination_valid_prefix_head_sha256")
  "Recovery-origin payload fields authenticated by evidence version one.")

(defconst epi-ledger--maximum-record-type-byte-length
  (apply #'max
         (mapcar (lambda (entry) (length (symbol-name (car entry))))
                 epi-ledger--record-schemas))
  "Maximum ASCII byte length of a version-one record type name.")

(defconst epi-ledger--maximum-headline-byte-length
  (+ (length "* ") epi-ledger--maximum-record-type-byte-length 1 36)
  "Maximum bytes in a complete version-one record headline without LF.")

(defun epi-ledger--copy-tree-and-strings (value)
  "Return a recursive copy of VALUE, including mutable string values."
  (cond
   ((stringp value) (substring-no-properties value))
   ((consp value)
    (cons (epi-ledger--copy-tree-and-strings (car value))
          (epi-ledger--copy-tree-and-strings (cdr value))))
   ((vectorp value)
    (apply #'vector (mapcar #'epi-ledger--copy-tree-and-strings value)))
   (t value)))

(defun epi-ledger-schema-descriptor ()
  "Return an ownership-isolated version-one record schema descriptor."
  (epi-ledger--copy-tree-and-strings epi-ledger--record-schemas))

(defun epi-ledger--fail (condition code &rest properties)
  "Signal CONDITION with CODE and redacted PROPERTIES."
  (epi--signal condition (append (list :code code) properties)))

(defun epi-ledger--format-fail (code &rest properties)
  "Signal a ledger format error with CODE and PROPERTIES."
  (apply #'epi-ledger--fail 'epi-ledger-format-error code properties))

(defun epi-ledger--limit-fail (code &rest properties)
  "Signal a limit error with CODE and PROPERTIES."
  (apply #'epi-ledger--fail 'epi-limit-exceeded code properties))

(defun epi-ledger--work-yield (&optional state)
  "Yield and reset cadence for optional work STATE and the current operation."
  (let* ((protected epi-ledger--work-protected-buffer)
         (protected-live (buffer-live-p protected))
         (protected-tick
          (and protected-live
               (buffer-chars-modified-tick protected)))
         (protected-multibyte
          (and protected-live
               (buffer-local-value 'enable-multibyte-characters protected)))
         (protected-read-only
          (and protected-live
               (buffer-local-value 'buffer-read-only protected))))
    (when protected-live
      (with-current-buffer protected
        (setq buffer-read-only t)))
    (unwind-protect
        (save-match-data
          (save-excursion
            (save-restriction
              (let ((yield-buffer
                     (and (consp epi-ledger--operation-yield-owner)
                          (car epi-ledger--operation-yield-owner))))
                (when (and epi-ledger--operation-work-state
                           (consp epi-ledger--operation-yield-owner)
                           (not (buffer-live-p yield-buffer)))
                  (setq yield-buffer
                        (generate-new-buffer " *epi-ledger-yield*" t)
                        epi-ledger--operation-yield-buffer yield-buffer)
                  (setcar epi-ledger--operation-yield-owner yield-buffer))
                (if (buffer-live-p yield-buffer)
                    (with-current-buffer yield-buffer
                      (epi--yield))
                  (with-temp-buffer
                    (epi--yield)))))))
      (when (buffer-live-p protected)
        (with-current-buffer protected
          (setq buffer-read-only protected-read-only))))
    (when (and protected
               (or (not (buffer-live-p protected))
                   (/= protected-tick
                       (buffer-chars-modified-tick protected))
                   (not (eq protected-multibyte
                            (buffer-local-value
                             'enable-multibyte-characters protected)))))
      (if epi-ledger--work-protected-change-handler
          (funcall epi-ledger--work-protected-change-handler)
        (error "Protected Epi work buffer changed across a yield"))))
  (let ((work (or state epi-ledger--operation-work-state)))
    (when work
      (let ((processed (epi-ledger--work-state-processed work)))
        (setf (epi-ledger--work-state-last-yield work) processed
              (epi-ledger--work-state-deadline work)
              (+ (epi--deadline-time) epi-ledger-work-time-budget)
              (epi-ledger--work-state-next-check work)
              (+ processed (epi-ledger--work-state-check-interval work)))))))

(defun epi-ledger--work-charge (state amount)
  "Reserve one bounded, nonnegative AMOUNT of cooperative work in STATE.
The caller performs the corresponding indivisible unit only after this
function returns, so a required yield occurs before the whole reservation."
  (unless (and (integerp amount)
               (<= 0 amount epi-ledger-work-byte-limit))
    (error "Unbounded cooperative work reservation: %S" amount))
  (when (> amount 0)
    (let* ((processed (epi-ledger--work-state-processed state))
           (crosses-clock-check
            (>= (+ processed amount)
                (epi-ledger--work-state-next-check state)))
           (deadline-expired
            (and crosses-clock-check
                 (>= (epi--deadline-time)
                     (epi-ledger--work-state-deadline state))))
           (fills-byte-slice
            (>= (+ (- processed
                      (epi-ledger--work-state-last-yield state))
                   amount)
                epi-ledger-work-byte-limit)))
      (when (or fills-byte-slice deadline-expired)
        (epi-ledger--work-yield state))
      (cl-incf (epi-ledger--work-state-processed state) amount)
      (when (>= (epi-ledger--work-state-processed state)
                (epi-ledger--work-state-next-check state))
        (setf (epi-ledger--work-state-next-check state)
              (+ (epi-ledger--work-state-processed state)
                 (epi-ledger--work-state-check-interval state)))))))

(defun epi-ledger--work-charge-count (state amount)
  "Charge nonnegative conceptual AMOUNT to STATE in bounded reservations.
Use this for constant-size scalar work or accounting without a matching
indivisible byte-copy primitive; byte-scanning callers must segment the
physical operation itself before calling `epi-ledger--work-charge'."
  (unless (and (integerp amount) (>= amount 0))
    (error "Invalid cooperative work charge: %S" amount))
  (while (> amount 0)
    (let ((step (min amount epi-ledger-work-byte-limit)))
      (epi-ledger--work-charge state step)
      (setq amount (- amount step)))))

(defun epi-ledger--work-car (cell work)
  "Return CELL's car after reserving one unit in WORK."
  (epi-ledger--work-charge work 1)
  (car cell))

(defun epi-ledger--work-cdr (cell work)
  "Return CELL's cdr after reserving one unit in WORK."
  (epi-ledger--work-charge work 1)
  (cdr cell))

(defun epi-ledger--work-cons (car cdr work)
  "Return a cons of CAR and CDR after reserving one unit in WORK."
  (epi-ledger--work-charge work 1)
  (cons car cdr))

(defun epi-ledger--work-nreverse-list (list work)
  "Destructively reverse proper LIST, charging WORK before every cons."
  (let ((tail list)
        reversed)
    (while (consp tail)
      (let ((next (epi-ledger--work-cdr tail work)))
        (epi-ledger--work-charge work 1)
        (setcdr tail reversed)
        (setq reversed tail
              tail next)))
    (unless (null tail)
      (error "Cannot cooperatively reverse an improper list"))
    reversed))

(defun epi-ledger--work-reverse-list (list work)
  "Return a reversed copy of proper LIST, charging WORK before every cons."
  (let ((tail list)
        reversed)
    (while (consp tail)
      (let ((value (epi-ledger--work-car tail work))
            (next (epi-ledger--work-cdr tail work)))
        (setq reversed (epi-ledger--work-cons value reversed work)
              tail next)))
    (unless (null tail)
      (error "Cannot cooperatively copy an improper list"))
    reversed))

(defun epi-ledger--work-append-one (list value work)
  "Copy proper LIST and append VALUE, charging WORK before every cons."
  (let ((tail list)
        head last)
    (while (consp tail)
      (let* ((item (epi-ledger--work-car tail work))
             (next (epi-ledger--work-cdr tail work))
             (cell (epi-ledger--work-cons item nil work)))
        (if last
            (progn
              (epi-ledger--work-charge work 1)
              (setcdr last cell))
          (setq head cell))
        (setq last cell
              tail next)))
    (unless (null tail)
      (error "Cannot cooperatively append to an improper list"))
    (let ((cell (epi-ledger--work-cons value nil work)))
      (if last
          (progn
            (epi-ledger--work-charge work 1)
            (setcdr last cell))
        (setq head cell)))
    head))

(defun epi-ledger--work-list-to-vector (list work field)
  "Copy proper LIST to a vector cooperatively using WORK and FIELD."
  (let ((tail list)
        (count 0))
    (while (consp tail)
      (setq count (1+ count)
            tail (epi-ledger--work-cdr tail work)))
    (unless (null tail)
      (error "Cannot cooperatively vectorize an improper list"))
    (let ((vector
           (epi-ledger--run-bounded-unit
            'allocate field count work (lambda () (make-vector count nil)))))
      (setq tail list)
      (dotimes (index count)
        (let ((value (epi-ledger--work-car tail work))
              (next (epi-ledger--work-cdr tail work)))
          (epi-ledger--work-charge work 1)
          (aset vector index value)
          (setq tail next)))
      vector)))

(defun epi-ledger--work-list-to-record-chunks (records work)
  "Return (COUNT . CHUNKS) for proper ordered RECORDS using WORK.
Each chunk vector is bounded by both cooperative record and byte cadence.
The records themselves are shared; only vectors, chunk objects, and their
list spine are new."
  (let* ((chunk-limit
          (max 1
               (min epi-ledger-work-record-limit
                    (max 1 (/ epi-ledger-work-byte-limit 8)))))
         (tail records)
         chunks
         (total 0))
    (while (consp tail)
      (let ((probe tail)
            (capacity 0))
        (while (and (< capacity chunk-limit) (consp probe))
          (setq capacity (1+ capacity)
                probe (epi-ledger--work-cdr probe work)))
        (let* (
             (bytes (* capacity 8))
             (values
              (progn
                (epi-ledger--open-observe-work
                 'allocate 'record-index-chunk bytes
                 :records capacity :bounded t)
                (epi-ledger--run-bounded-unit
                 'allocate 'record-index-chunk bytes work
                 (lambda () (make-vector capacity nil)))))
             (count 0))
        (while (< count capacity)
          (let ((record (epi-ledger--work-car tail work))
                (next (epi-ledger--work-cdr tail work)))
            (epi-ledger--work-charge work 1)
            (aset values count record)
            (setq count (1+ count)
                  total (1+ total)
                  tail next)))
        (setq chunks
              (epi-ledger--work-cons
               (epi-ledger--make-record-chunk :values values :count count)
               chunks work)))))
    (unless (null tail)
      (error "Cannot cooperatively chunk an improper record list"))
    (epi-ledger--work-cons
     total (epi-ledger--work-nreverse-list chunks work) work)))

(defun epi-ledger--work-list-to-record-index (list work)
  "Copy proper ordered LIST into a bounded-chunk record index using WORK."
  (if (< epi-ledger-work-byte-limit 8)
      list
    (let ((result (epi-ledger--work-list-to-record-chunks list work)))
      (epi-ledger--make-record-index
       :chunks (cdr result)
       :count (car result)))))

(defun epi-ledger--record-index-extend (index suffix work)
  "Return INDEX extended by proper ordered SUFFIX using WORK.
The old chunk-list spine is copied, while every old chunk and prefix record is
shared.  Only SUFFIX receives new bounded chunk vectors."
  (unless (epi-ledger--record-index-p index)
    (signal 'wrong-type-argument (list 'epi-ledger--record-index-p index)))
  (when (< epi-ledger-work-byte-limit 8)
    (epi-ledger--limit-fail
     'record-index-work-byte-limit
     :limit epi-ledger-work-byte-limit :minimum 8))
  (let* ((chunk-result
          (epi-ledger--work-list-to-record-chunks suffix work))
         (suffix-count (car chunk-result))
         (suffix-chunks (cdr chunk-result))
         (old-tail (epi-ledger--record-index-raw-chunks index))
         (new-tail suffix-chunks)
         head last)
    (while (consp old-tail)
      (let* ((chunk (epi-ledger--work-car old-tail work))
             (next (epi-ledger--work-cdr old-tail work))
             (cell (epi-ledger--work-cons chunk nil work)))
        (if last
            (progn
              (epi-ledger--work-charge work 1)
              (setcdr last cell))
          (setq head cell))
        (setq last cell
              old-tail next)))
    (unless (null old-tail)
      (error "Improper private record chunk spine"))
    (while (consp new-tail)
      (let* ((chunk (epi-ledger--work-car new-tail work))
             (next (epi-ledger--work-cdr new-tail work))
             (cell (epi-ledger--work-cons chunk nil work)))
        (if last
            (progn
              (epi-ledger--work-charge work 1)
              (setcdr last cell))
          (setq head cell))
        (setq last cell
              new-tail next)))
    (unless (null new-tail)
      (error "Improper private suffix chunk spine"))
    (epi-ledger--make-record-index
     :chunks head
     :count (+ (epi-ledger--record-index-raw-count index) suffix-count))))

(defun epi-ledger--record-index-to-list-with-suffix (index suffix work)
  "Copy INDEX order and proper SUFFIX into one proper list using WORK.
Only list cells are new; every record is shared by identity.  This is the
positive tiny-byte-cadence fallback where an eight-byte vector slot cannot be
reserved without exceeding the configured work slice."
  (let ((chunk-tail (epi-ledger--record-index-raw-chunks index))
        head last)
    (cl-labels
        ((append-record
          (record)
          (let ((cell (epi-ledger--work-cons record nil work)))
            (if last
                (progn
                  (epi-ledger--work-charge work 1)
                  (setcdr last cell))
              (setq head cell))
            (setq last cell))))
      (while (consp chunk-tail)
        (let* ((chunk (epi-ledger--work-car chunk-tail work))
               (next (epi-ledger--work-cdr chunk-tail work))
               (values (epi-ledger--record-chunk-raw-values chunk)))
          (dotimes (offset (epi-ledger--record-chunk-raw-count chunk))
            (epi-ledger--work-charge work 1)
            (append-record (aref values offset)))
          (setq chunk-tail next)))
      (unless (null chunk-tail)
        (error "Improper private record chunk spine"))
      (let ((tail suffix))
        (while (consp tail)
          (let ((record (epi-ledger--work-car tail work))
                (next (epi-ledger--work-cdr tail work)))
            (append-record record)
            (setq tail next)))
        (unless (null tail)
          (error "Improper private record suffix")))
      head)))

(defun epi-ledger--record-source-extend (source suffix work)
  "Return private ordered SOURCE extended by proper ordered SUFFIX under WORK.
Only sequence containers are copied.  All records and, for a record index,
all prefix chunk objects remain shared by identity."
  (cond
   ((epi-ledger--record-index-p source)
    (if (< epi-ledger-work-byte-limit 8)
        (epi-ledger--record-index-to-list-with-suffix source suffix work)
      (epi-ledger--record-index-extend source suffix work)))
   ((vectorp source)
    (let ((tail suffix)
          (suffix-count 0))
      (while (consp tail)
        (setq suffix-count (1+ suffix-count)
              tail (epi-ledger--work-cdr tail work)))
      (unless (null tail)
        (error "Improper private record suffix"))
      (let* ((prefix-count (length source))
             (count (+ prefix-count suffix-count))
             (result
              (epi-ledger--run-bounded-unit
               'allocate 'record-source-extension (* 8 count) work
               (lambda () (make-vector count nil)))))
        (dotimes (index prefix-count)
          (epi-ledger--work-charge work 1)
          (aset result index (aref source index)))
        (setq tail suffix)
        (dotimes (index suffix-count)
          (let ((record (epi-ledger--work-car tail work))
                (next (epi-ledger--work-cdr tail work)))
            (epi-ledger--work-charge work 1)
            (aset result (+ prefix-count index) record)
            (setq tail next)))
        result)))
   ((listp source)
    (let ((prefix-tail source)
          (suffix-tail suffix)
          head last)
      (dolist (which '(prefix suffix))
        (let ((tail (if (eq which 'prefix) prefix-tail suffix-tail)))
          (while (consp tail)
            (let* ((record (epi-ledger--work-car tail work))
                   (next (epi-ledger--work-cdr tail work))
                   (cell (epi-ledger--work-cons record nil work)))
              (if last
                  (progn
                    (epi-ledger--work-charge work 1)
                    (setcdr last cell))
                (setq head cell))
              (setq last cell
                    tail next)))
          (unless (null tail)
            (error "Improper private record source"))))
      head))
   (t (signal 'wrong-type-argument (list 'sequencep source)))))

(defun epi-ledger--work-sort-list-to-vector (list predicate work field)
  "Sort proper LIST into a vector with PREDICATE, charging WORK for FIELD."
  (let* ((source (epi-ledger--work-list-to-vector list work field))
         (count (length source)))
    (if (< count 2)
        source
      (let ((destination
             (epi-ledger--run-bounded-unit
              'allocate field count work
              (lambda () (make-vector count nil))))
            (width 1))
        (while (< width count)
          (let ((start 0))
            (while (< start count)
              (let ((left start)
                    (left-end (min count (+ start width)))
                    (right (min count (+ start width)))
                    (right-end (min count (+ start (* 2 width))))
                    (output start))
                (while (and (< left left-end) (< right right-end))
                  (epi-ledger--work-charge work 1)
                  (let ((left-value (aref source left)))
                    (epi-ledger--work-charge work 1)
                    (let ((right-value (aref source right)))
                      (if (funcall predicate right-value left-value)
                          (progn
                            (epi-ledger--work-charge work 1)
                            (aset destination output right-value)
                            (setq right (1+ right)))
                        (epi-ledger--work-charge work 1)
                        (aset destination output left-value)
                        (setq left (1+ left)))))
                  (setq output (1+ output)))
                (while (< left left-end)
                  (epi-ledger--work-charge work 1)
                  (let ((value (aref source left)))
                    (epi-ledger--work-charge work 1)
                    (aset destination output value))
                  (setq left (1+ left)
                        output (1+ output)))
                (while (< right right-end)
                  (epi-ledger--work-charge work 1)
                  (let ((value (aref source right)))
                    (epi-ledger--work-charge work 1)
                    (aset destination output value))
                  (setq right (1+ right)
                        output (1+ output))))
              (setq start (+ start (* 2 width)))))
          (let ((swap source))
            (setq source destination
                  destination swap
                  width (* 2 width))))
        source))))

(defun epi-ledger--work-concat-chunks (chunks bytes work field)
  "Flatten proper unibyte CHUNKS totaling BYTES cooperatively.
WORK receives list-traversal and copy charges; FIELD identifies measured
allocation or copy units that exceed the cooperative slice."
  (unless (and (integerp bytes) (>= bytes 0))
    (error "Invalid cooperative concatenation size: %S" bytes))
  (let ((result
         (epi-ledger--run-bounded-unit
          'allocate field bytes work (lambda () (make-string bytes 0))))
        (tail chunks)
        (offset 0))
    (while (consp tail)
      (let* ((chunk (epi-ledger--work-car tail work))
             (next (epi-ledger--work-cdr tail work))
             (amount (and (stringp chunk) (length chunk))))
        (setq tail next)
        (unless (and amount (not (multibyte-string-p chunk))
                     (<= (+ offset amount) bytes))
          (error "Invalid cooperative concatenation chunk"))
        (epi-ledger--run-bounded-unit
         'copy field amount work
         (lambda () (store-substring result offset chunk)))
        (setq offset (+ offset amount))))
    (unless (and (null tail) (= offset bytes))
      (error "Cooperative concatenation size mismatch"))
    result))

(defun epi-ledger--work-encode-utf8 (text work field)
  "Encode TEXT as UTF-8 bytes in one measured unit using WORK and FIELD."
  (let ((bytes (string-bytes text)))
    (epi-ledger--run-bounded-unit
     'encode field bytes work
     (lambda () (encode-coding-string text 'utf-8-unix)))))

(defun epi-ledger--work-member-p (item list work)
  "Return non-nil when ITEM is `equal' to a member of LIST.
Charge WORK before every cons inspection."
  (let ((tail list)
        found)
    (while (and (consp tail) (not found))
      (let ((value (epi-ledger--work-car tail work))
            (next (epi-ledger--work-cdr tail work)))
        (setq found (equal item value)
              tail next)))
    found))

(cl-defun make-epi-object-ref (&key hash size media-type role)
  "Return an immutable object reference for HASH, SIZE, MEDIA-TYPE, and ROLE."
  (epi-ledger--with-operation-work-state
    (let* ((object
            (epi-ledger--snapshot-canonical-value
             `(("hash" . ,hash) ("size" . ,size)
               ("media_type" . ,media-type) ("role" . ,role))))
           (_preflight (epi-ledger--preflight-canonical-value object))
           (owned-hash (epi-ledger--object-value object "hash"))
           (owned-size (epi-ledger--object-value object "size"))
           (owned-media-type
            (epi-ledger--object-value object "media_type"))
           (owned-role (epi-ledger--object-value object "role")))
      (epi-ledger--require-hash owned-hash "hash")
      (epi-ledger--require-nonnegative-integer owned-size "size")
      (when (> owned-size epi-object-byte-limit)
        (epi-ledger--limit-fail
         'object-byte-limit :field "size" :limit epi-object-byte-limit))
      (epi-ledger--require-string owned-media-type "media_type" t)
      (epi-ledger--require-string owned-role "role" t)
      (epi-ledger--make-object-ref
       :hash owned-hash :size owned-size
       :media-type owned-media-type :role owned-role))))

(defun epi-ledger--trusted-value-copy (value)
  "Cooperatively copy immutable, already validated canonical VALUE."
  (epi-ledger--with-operation-work-state
    (let ((work (epi-ledger--make-work-state)))
      (cl-labels
          ((copy-string
            (string)
            (let ((storage (string-bytes string)))
              (if (> storage epi-ledger-work-byte-limit)
                  (epi-ledger--run-nonpreemptible
                   'copy 'trusted-string storage
                   (lambda () (substring-no-properties string)))
                (epi-ledger--work-charge work storage)
                (substring-no-properties string))))
           (copy-value
            (node)
            (cond
             ((stringp node) (copy-string node))
             ((vectorp node)
              (let* ((storage (* (length node) 8))
                     (result
                      (if (> storage epi-ledger-work-byte-limit)
                          (epi-ledger--run-nonpreemptible
                           'copy 'trusted-vector storage
                           (lambda () (make-vector (length node) nil)))
                        (epi-ledger--work-charge work storage)
                        (make-vector (length node) nil))))
                (dotimes (index (length node))
                  (epi-ledger--work-charge work 1)
                  (let* ((child (aref node index))
                         (copy (copy-value child)))
                    (epi-ledger--work-charge work 1)
                    (aset result index copy)))
                result))
             ((consp node)
              (let ((tail node)
                    head last)
                (while (consp tail)
                  (let* ((entry (epi-ledger--work-car tail work))
                         (next (epi-ledger--work-cdr tail work)))
                    (unless (consp entry)
                      (epi-ledger--format-fail
                       'object-entry-required :field 'trusted-value))
                    (let* ((key (epi-ledger--work-car entry work))
                           (child (epi-ledger--work-cdr entry work))
                           (owned-key (copy-string key))
                           (owned-child (copy-value child))
                           (pair (epi-ledger--work-cons
                                  owned-key owned-child work))
                           (cell (epi-ledger--work-cons pair nil work)))
                      (if last
                          (progn
                            (epi-ledger--work-charge work 1)
                            (setcdr last cell))
                        (setq head cell))
                      (setq last cell
                            tail next))))
                head))
             (t node))))
        (copy-value value)))))

(defun epi-ledger--copy-owned-unibyte-range
    (bytes start end field &optional work-state)
  "Copy owned unibyte BYTES from START to END with measured FIELD work.
Optional WORK-STATE receives the bounded copy reservation."
  (let ((amount (- end start))
        (work (or work-state (epi-ledger--make-work-state))))
    (if (> amount epi-ledger-work-byte-limit)
        (epi-ledger--run-nonpreemptible
         'copy field amount (lambda () (substring bytes start end)))
      (epi-ledger--work-charge work amount)
      (substring bytes start end))))

(defun epi-ledger--source-length (source)
  "Return the byte length of immutable string or buffer-region SOURCE."
  (if (epi-ledger--source-region-p source)
      (- (epi-ledger--source-region-raw-end source)
         (epi-ledger--source-region-raw-start source))
    (length source)))

(defun epi-ledger--source-assert-current (source)
  "Reject a stale or modified private buffer-region SOURCE."
  (when (epi-ledger--source-region-p source)
    (let ((buffer (epi-ledger--source-region-raw-buffer source)))
      (unless (and (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (= (buffer-modified-tick)
                        (epi-ledger--source-region-raw-tick source))))
        (epi-ledger--format-fail 'modified-private-source)))))

(defun epi-ledger--source-byte (source position)
  "Return SOURCE byte at zero-based POSITION."
  (if (epi-ledger--source-region-p source)
      (progn
        (epi-ledger--source-assert-current source)
        (with-current-buffer
            (epi-ledger--source-region-raw-buffer source)
          (char-after (+ (epi-ledger--source-region-raw-start source)
                         position))))
    (aref source position)))

(defun epi-ledger--source-copy-range (source start end field work)
  "Copy SOURCE's START..END range as bounded FIELD work using WORK."
  (if (epi-ledger--source-region-p source)
      (let ((amount (- end start)))
        (epi-ledger--source-assert-current source)
        (epi-ledger--run-bounded-unit
         'copy field amount work
         (lambda ()
           (with-current-buffer
               (epi-ledger--source-region-raw-buffer source)
             (buffer-substring-no-properties
              (+ (epi-ledger--source-region-raw-start source) start)
              (+ (epi-ledger--source-region-raw-start source) end))))))
    (epi-ledger--copy-owned-unibyte-range source start end field work)))

(defun epi-ledger--source-range-prefix-p (source start end prefix work)
  "Return whether SOURCE range START..END begins with unibyte PREFIX.
Every source-byte comparison is reserved through WORK before inspection."
  (let ((prefix-length (length prefix))
        (index 0)
        (matched t))
    (when (<= prefix-length (- end start))
      (while (and matched (< index prefix-length))
        (let* ((amount
                (min (- prefix-length index)
                     (max 1 epi-ledger-work-byte-limit)))
               (limit (+ index amount)))
          (epi-ledger--work-charge work amount)
          (while (and matched (< index limit))
            (setq matched
                  (= (epi-ledger--source-byte source (+ start index))
                     (aref prefix index))
                  index (1+ index)))))
      matched)))

(defun epi-ledger--source-subregion (source start end)
  "Return SOURCE's immutable START..END subregion without copying bytes."
  (if (epi-ledger--source-region-p source)
      (progn
        (epi-ledger--source-assert-current source)
        (epi-ledger--make-source-region
         :buffer (epi-ledger--source-region-raw-buffer source)
         :start (+ (epi-ledger--source-region-raw-start source) start)
         :end (+ (epi-ledger--source-region-raw-start source) end)
         :tick (epi-ledger--source-region-raw-tick source)))
    (substring source start end)))

(defun epi-ledger--source-hash (source field)
  "Return SHA-256 of exact immutable SOURCE bytes used for FIELD."
  (if (not (epi-ledger--source-region-p source))
      (epi-ledger--hash source field)
    (let ((bytes (epi-ledger--source-length source)))
      (when (> bytes epi-hash-input-byte-limit)
        (epi-ledger--limit-fail
         'hash-input-byte-limit :field field
         :limit epi-hash-input-byte-limit))
      (epi-ledger--source-assert-current source)
      (epi-ledger--run-nonpreemptible
       'hash field bytes
       (lambda ()
         (secure-hash
          'sha256
          (epi-ledger--source-region-raw-buffer source)
          (epi-ledger--source-region-raw-start source)
          (epi-ledger--source-region-raw-end source)))))))

(defun epi-ledger--decode-json-source (source)
  "Decode capped canonical JSON SOURCE without a frame-sized string copy."
  (if (not (epi-ledger--source-region-p source))
      (epi-ledger--decode-json source)
    (let ((bytes (epi-ledger--source-length source)))
      (when (> bytes epi-record-decode-byte-limit)
        (epi-ledger--limit-fail 'record-decode-byte-limit
                                :limit epi-record-decode-byte-limit))
      (epi-ledger--source-assert-current source)
      (epi-ledger--run-nonpreemptible
       'decode 'record-json bytes
       (lambda ()
         (with-current-buffer
             (epi-ledger--source-region-raw-buffer source)
           (save-restriction
             (narrow-to-region
              (epi-ledger--source-region-raw-start source)
              (epi-ledger--source-region-raw-end source))
             (goto-char (point-min))
             (let ((decoded
                    (condition-case nil
                        (json-parse-buffer
                         :object-type 'hash-table
                         :array-type 'array
                         :null-object epi-json-null
                         :false-object epi-json-false)
                      (error (epi-ledger--format-fail 'invalid-json)))))
               (unless (= (point) (point-max))
                 (epi-ledger--format-fail 'trailing-json-data))
               (epi-ledger--normalize-decoded-numbers decoded)))))))))

(defconst epi-ledger--invalid-unibyte-scalar-regexp
  (concat "[" (unibyte-string 128) "-" (unibyte-string 255) "]")
  "Regexp matching a byte not admitted in a canonical unibyte string.")

(defvar epi-ledger--canonical-value-preflighted nil
  "Non-nil while validating an owned value proven by canonical preflight.")

(defun epi-ledger--canonical-string-p (value &optional work-state)
  "Return whether VALUE is a canonical JSON string, charging WORK-STATE."
  (when (stringp value)
    (let ((work (or work-state (epi-ledger--make-work-state)))
          (valid t))
      (if (not (multibyte-string-p value))
          (if (= epi-ledger-work-byte-limit 1)
              (let ((index 0))
                (while (and valid (< index (length value)))
                  (epi-ledger--work-charge work 1)
                  (setq valid (<= (aref value index) #x7f)
                        index (1+ index))))
            (let ((cursor 0)
                  (chunk-size
                   (max 1
                        (min 65536 (/ epi-ledger-work-byte-limit 2)))))
              (while (and valid (< cursor (length value)))
                (let* ((end (min (length value) (+ cursor chunk-size)))
                       (amount (- end cursor)))
                  (epi-ledger--work-charge work (* 2 amount))
                  (setq valid
                        (not
                         (string-match-p
                          epi-ledger--invalid-unibyte-scalar-regexp
                          (substring value cursor end)))
                        cursor end)))))
        (let ((index 0))
          (while (and valid (< index (length value)))
            (epi-ledger--work-charge work 1)
            (let ((character (aref value index)))
              (setq valid
                    (and (<= character #x10ffff)
                         (not (<= #xd800 character #xdfff))))
              (when valid
                (epi-ledger--work-charge-count
                 work (1- (cond ((<= character #x7f) 1)
                                ((<= character #x7ff) 2)
                                ((<= character #xffff) 3)
                                (t 4))))))
            (setq index (1+ index)))))
      valid)))

(defun epi-ledger--canonical-string (value field &optional work-state)
  "Require VALUE to be a canonical string for FIELD without copying it.
Optional WORK-STATE receives the validation charge."
  (unless (and (stringp value)
               (or epi-ledger--canonical-value-preflighted
                   (epi-ledger--canonical-string-p value work-state)))
    (epi-ledger--format-fail 'invalid-string :field field))
  value)

(defun epi-ledger--uuid-p (value)
  "Return non-nil when VALUE is a lowercase UUID spelling."
  (and (stringp value)
       (let ((case-fold-search nil))
         (string-match-p
          (concat "\\`[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-"
                  "[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-"
                  "[0-9a-f]\\{12\\}\\'")
          value))))

(defun epi-ledger--hash-p (value)
  "Return non-nil when VALUE is a lowercase SHA-256 spelling."
  (and (stringp value)
       (let ((case-fold-search nil))
         (string-match-p "\\`[0-9a-f]\\{64\\}\\'" value))))

(defun epi-ledger--leap-year-p (year)
  "Return non-nil when YEAR is a Gregorian leap year."
  (and (zerop (% year 4))
       (or (not (zerop (% year 100)))
           (zerop (% year 400)))))

(defun epi-ledger--days-in-month (year month)
  "Return the number of days in Gregorian MONTH of YEAR."
  (aref (if (epi-ledger--leap-year-p year)
            [0 31 29 31 30 31 30 31 31 30 31 30 31]
          [0 31 28 31 30 31 30 31 31 30 31 30 31])
        month))

(defun epi-ledger--decimal-at (value start count)
  "Return the decimal in VALUE beginning at START and spanning COUNT digits."
  (let ((result 0)
        (index 0))
    (while (< index count)
      (setq result (+ (* result 10)
                      (- (epi-ledger--source-byte value (+ start index)) ?0))
            index (1+ index)))
    result))

(defun epi-ledger--timestamp-zone-prefix-minimum (value start end)
  "Return bytes completing VALUE's numeric offset from START to END.
Return nil when the selected range cannot be such an offset prefix."
  (let ((length (- end start))
        (valid t))
    (when (and (<= 1 length 6)
               (memq (epi-ledger--source-byte value start) '(?+ ?-)))
      (let ((offset 1))
        (while (and valid (< offset length))
          (setq valid
                (if (= offset 3)
                    (= (epi-ledger--source-byte value (+ start offset)) ?:)
                  (<= ?0 (epi-ledger--source-byte value (+ start offset)) ?9)))
          (setq offset (1+ offset))))
      (when (and valid
                 (or (< length 2)
                     (<= (epi-ledger--source-byte value (1+ start)) ?2))
                 (or (< length 3)
                     (<= (epi-ledger--decimal-at value (1+ start) 2) 23))
                 (or (< length 5)
                     (<= (epi-ledger--source-byte value (+ start 4)) ?5))
                 (or (< length 6)
                     (<= (epi-ledger--decimal-at value (+ start 4) 2) 59)))
        (- 6 length)))))

(defun epi-ledger--timestamp-fraction-zone-start (value start end)
  "Return VALUE's zone index after fractional digits from START to END.
Return END when no zone has arrived, or nil on an invalid byte.  Long digit
runs obey the cooperative-work budget."
  (let ((cursor start)
        (work (epi-ledger--make-work-state))
        (chunk-size (max 1 (min 65536 epi-ledger-work-byte-limit))))
    (catch 'done
      (while (< cursor end)
        (let* ((chunk-end (min end (+ cursor chunk-size)))
               (amount (- chunk-end cursor)))
          (epi-ledger--work-charge work amount)
          (while (< cursor chunk-end)
            (let ((byte (epi-ledger--source-byte value cursor)))
              (if (<= ?0 byte ?9)
                  (setq cursor (1+ cursor))
                (throw 'done (and (memq byte '(?Z ?+ ?-)) cursor)))))))
      end)))

(defun epi-ledger--timestamp-scan (value &optional start end)
  "Return minimum bytes completing VALUE's timestamp range, or nil.
START defaults to zero and END to the source length.  VALUE may be an immutable
string or private buffer-region source.  A zero result means the
range is an exact valid timestamp in Epi's RFC 3339 profile, including year
0000.  The profile admits ordinary seconds 00 through 59, but not leap-second
spellings.  The scanner uses indices plus bounded fractional chunks and
charges their shared operation."
  (when (or (stringp value) (epi-ledger--source-region-p value))
    (let* ((start (or start 0))
           (source-length (epi-ledger--source-length value))
           (end (or end source-length))
           (length (- end start)))
      (when (and (<= 0 start end) (<= end source-length))
        (catch 'result
          (let ((base-length (min length 19)))
            (dotimes (index base-length)
              (let ((byte (epi-ledger--source-byte value (+ start index))))
                (unless
                    (if (memq index '(4 7 10 13 16))
                        (= byte (aref "0000-00-00T00:00:00" index))
                      (<= ?0 byte ?9))
                  (throw 'result nil))))
            (when (and (>= base-length 6)
                       (not (memq (epi-ledger--source-byte
                                   value (+ start 5))
                                  '(?0 ?1))))
              (throw 'result nil))
            (when (and (>= base-length 7)
                       (not (<= 1 (epi-ledger--decimal-at value (+ start 5) 2)
                                  12)))
              (throw 'result nil))
            (when (>= base-length 9)
              (let ((day-tens
                     (epi-ledger--source-byte value (+ start 8))))
                (when (or (> day-tens ?3)
                          (and (= day-tens ?3)
                               (< (epi-ledger--days-in-month
                                   (epi-ledger--decimal-at value start 4)
                                   (epi-ledger--decimal-at
                                    value (+ start 5) 2))
                                  30)))
                  (throw 'result nil))))
            (when (>= base-length 10)
              (let ((year (epi-ledger--decimal-at value start 4))
                    (month (epi-ledger--decimal-at value (+ start 5) 2))
                    (day (epi-ledger--decimal-at value (+ start 8) 2)))
                (unless (<= 1 day (epi-ledger--days-in-month year month))
                  (throw 'result nil))))
            (when (and (>= base-length 12)
                       (> (epi-ledger--source-byte value (+ start 11)) ?2))
              (throw 'result nil))
            (when (and (>= base-length 13)
                       (> (epi-ledger--decimal-at value (+ start 11) 2) 23))
              (throw 'result nil))
            (dolist (field-start '(14 17))
              (when (and (>= base-length (1+ field-start))
                         (> (epi-ledger--source-byte
                             value (+ start field-start))
                            ?5))
                (throw 'result nil))
              (when (and (>= base-length (+ field-start 2))
                         (> (epi-ledger--decimal-at
                             value (+ start field-start) 2)
                            59))
                (throw 'result nil)))
            (when (< length 19)
              (throw 'result (+ (- 19 length) 1)))
            (let ((suffix-start (+ start 19)))
              (when (= suffix-start end)
                (throw 'result 1))
              (pcase (epi-ledger--source-byte value suffix-start)
                (?Z (throw 'result (and (= (1+ suffix-start) end) 0)))
                ((or ?+ ?-)
                 (throw 'result
                        (epi-ledger--timestamp-zone-prefix-minimum
                         value suffix-start end)))
                (?.
                 (let ((fraction-start (1+ suffix-start)))
                   (when (= fraction-start end)
                     (throw 'result 2))
                   (let ((zone-start
                          (epi-ledger--timestamp-fraction-zone-start
                           value fraction-start end)))
                     (unless (and zone-start (> zone-start fraction-start))
                       (throw 'result nil))
                     (when (= zone-start end)
                       (throw 'result 1))
                     (pcase (epi-ledger--source-byte value zone-start)
                       (?Z
                        (throw 'result (and (= (1+ zone-start) end) 0)))
                       ((or ?+ ?-)
                        (throw 'result
                               (epi-ledger--timestamp-zone-prefix-minimum
                                value zone-start end)))))))
                (_ (throw 'result nil))))))))))

(defun epi-ledger--timestamp-p (value)
  "Return non-nil when VALUE is a valid Epi RFC 3339-profile timestamp."
  (equal 0 (epi-ledger--timestamp-scan value)))

(defun epi-ledger--decode-utf8 (bytes field &optional offset)
  "Strictly decode UTF-8 BYTES for FIELD, reporting optional OFFSET."
  (let* ((work (epi-ledger--make-work-state))
         (decoded-and-validity
          (epi-ledger--run-nonpreemptible
           'decode field (length bytes)
           (lambda ()
             (let* ((decoded (decode-coding-string bytes 'utf-8-unix t))
                    (roundtrip (encode-coding-string decoded 'utf-8-unix)))
               (cons decoded (equal bytes roundtrip))))))
         (decoded (epi-ledger--work-car decoded-and-validity work))
         (valid (epi-ledger--work-cdr decoded-and-validity work)))
    (unless (and (epi-ledger--canonical-string-p decoded work) valid)
      (epi-ledger--format-fail 'malformed-utf8
                               :field field :offset (or offset 0)))
    decoded))

(defun epi-ledger--require-uuid (value field)
  "Require UUID VALUE for FIELD."
  (unless (epi-ledger--uuid-p value)
    (epi-ledger--format-fail 'invalid-id :field field)))

(defun epi-ledger--require-hash (value field)
  "Require lowercase SHA-256 VALUE for FIELD."
  (unless (epi-ledger--hash-p value)
    (epi-ledger--format-fail 'invalid-hash :field field)))

(defun epi-ledger--require-string (value field &optional nonempty)
  "Require canonical string VALUE for FIELD, optionally NONEMPTY."
  (epi-ledger--canonical-string value field)
  (when (and nonempty (string-empty-p value))
    (epi-ledger--format-fail 'empty-string :field field)))

(defvar epi-ledger--cold-open-validation nil
  "Non-nil while stored ledger text is being validated by the cold loader.")

(defun epi-ledger--require-canonical-directory (value field)
  "Require VALUE to be a canonical absolute directory for FIELD."
  (epi-ledger--require-string value field t)
  (unless
      (epi-ledger--run-nonpreemptible
       'validate field (string-bytes value)
       (lambda ()
         (let ((file-name-handler-alist
                (if epi-ledger--cold-open-validation
                    nil
                  file-name-handler-alist)))
           (condition-case nil
               (let ((validation-copy (substring-no-properties value)))
                 (and (not (string-match-p "[\0\r\n]" validation-copy))
                      (file-name-absolute-p
                       (substring-no-properties value))
                      (equal value
                             (file-name-as-directory
                              (expand-file-name
                               (substring-no-properties value))))))
             (error nil)))))
    (epi-ledger--format-fail 'canonical-directory-required :field field)))

(defun epi-ledger--require-absolute-path (value field)
  "Require VALUE to be a NUL-free absolute file name for FIELD."
  (epi-ledger--require-string value field t)
  (unless
      (epi-ledger--run-nonpreemptible
       'validate field (string-bytes value)
       (lambda ()
         (let ((file-name-handler-alist
                (if epi-ledger--cold-open-validation
                    nil
                  file-name-handler-alist)))
           (condition-case nil
               (and (not (string-match-p
                          "[\0\r\n]" (substring-no-properties value)))
                    (file-name-absolute-p
                     (substring-no-properties value)))
             (error nil)))))
    (epi-ledger--format-fail 'absolute-path-required :field field)))

(defun epi-ledger--require-canonical-absolute-file (value field)
  "Require VALUE to be a lexically canonical absolute file name for FIELD."
  (epi-ledger--require-string value field t)
  (pcase
      (epi-ledger--run-nonpreemptible
       'validate field (string-bytes value)
       (lambda ()
         (let ((file-name-handler-alist
                (if epi-ledger--cold-open-validation
                    nil
                  file-name-handler-alist)))
           (if (condition-case nil
                   (and
                    (not (string-match-p
                          "[\0\r\n]" (substring-no-properties value)))
                    (file-name-absolute-p
                     (substring-no-properties value)))
                 (error nil))
               (condition-case nil
                   (if (and
                        (not (directory-name-p
                              (substring-no-properties value)))
                        (equal value
                               (expand-file-name
                                (substring-no-properties value))))
                       'valid
                     'noncanonical)
                 (error 'noncanonical))
             'not-absolute))))
    ('valid nil)
    ('not-absolute
     (epi-ledger--format-fail 'absolute-path-required :field field))
    (_
     (epi-ledger--format-fail 'canonical-absolute-file-required
                              :field field))))

(defun epi-ledger--require-nonnegative-integer (value field)
  "Require a nonnegative safe integer VALUE for FIELD."
  (unless (and (integerp value)
               (<= 0 value epi-ledger--maximum-safe-integer))
    (epi-ledger--format-fail 'invalid-integer :field field)))

(defun epi-ledger--object-keys (object field &optional work-state)
  "Return unique string keys from canonical OBJECT named FIELD.
Optional WORK-STATE receives the traversal charge."
  (let ((work (or work-state (epi-ledger--make-work-state)))
        (tail object)
        (fast object)
        (count 0)
        sort-keys
        keys)
    (while (consp tail)
      (let ((entry (epi-ledger--work-car tail work))
            (next (epi-ledger--work-cdr tail work)))
        (when (consp fast)
          (setq fast (epi-ledger--work-cdr fast work))
          (when (consp fast)
            (setq fast (epi-ledger--work-cdr fast work))))
        (setq count (1+ count))
        (when (> count epi-json-item-limit)
          (epi-ledger--limit-fail
           'json-item-limit :limit epi-json-item-limit))
        (unless (consp entry)
          (epi-ledger--format-fail 'object-required :field field))
        (let ((key (epi-ledger--work-car entry work)))
          (epi-ledger--canonical-string key field work)
          (let ((sort-key (epi-ledger--utf16be-key-chunks key work)))
            (setq sort-keys
                  (epi-ledger--work-cons sort-key sort-keys work))
            (setq keys (epi-ledger--work-cons key keys work))))
        (setq tail next)
        (when (and (consp tail) (eq tail fast))
          (epi-ledger--format-fail 'cyclic-json :field field))))
    (unless (null tail)
      (epi-ledger--format-fail 'object-required :field field))
    (epi-ledger--assert-unique-sort-keys sort-keys field work)
    (epi-ledger--work-nreverse-list keys work)))

(defun epi-ledger--object-value (object key)
  "Return the value stored under string KEY in OBJECT."
  (cdr (assoc-string key object nil)))

(defun epi-ledger--object-has-key-p (object key)
  "Return whether OBJECT has string KEY."
  (and (assoc-string key object nil) t))

(defun epi-ledger--closed-object (object required optional field)
  "Validate OBJECT has exactly REQUIRED and OPTIONAL keys for FIELD."
  (let* ((work (epi-ledger--make-work-state))
         (keys (epi-ledger--object-keys object field work))
         (tail required))
    (while (consp tail)
      (let ((key (epi-ledger--work-car tail work))
            (next (epi-ledger--work-cdr tail work)))
        (unless (epi-ledger--work-member-p key keys work)
          (epi-ledger--format-fail 'missing-key :field field :key key))
        (setq tail next)))
    (setq tail keys)
    (while (consp tail)
      (let ((key (epi-ledger--work-car tail work))
            (next (epi-ledger--work-cdr tail work)))
        (unless (or (epi-ledger--work-member-p key required work)
                    (epi-ledger--work-member-p key optional work))
          (epi-ledger--format-fail 'unknown-key :field field :key key))
        (setq tail next)))))

(defun epi-ledger--utf16be-key-chunks (value &optional work-state)
  "Return bounded BOM-free UTF-16BE sort-key chunks for string VALUE.
Optional WORK-STATE receives the conversion charge."
  (let ((work (or work-state (epi-ledger--make-work-state)))
        (maximum-chunk-size
         (max 4 (* 2 (/ (min 4096 (max 4 epi-ledger-work-byte-limit)) 2))))
        (buffer nil)
        (buffer-length 0)
        chunks)
    (epi-ledger--canonical-string value 'object-key work)
    (cl-labels
        ((allocate-buffer
          (size)
          (epi-ledger--run-bounded-unit
           'allocate 'utf16-sort-key-buffer size work
           (lambda () (make-string size 0))))
         (flush
          ()
          (when (> buffer-length 0)
            (let ((chunk
                   (epi-ledger--run-bounded-unit
                    'copy 'utf16-sort-key-chunk buffer-length work
                    (lambda () (substring buffer 0 buffer-length)))))
              (epi-ledger--work-charge work 1)
              (push chunk chunks))
            (setq buffer-length 0)))
         (ensure-room
          (needed)
          (when (or (null buffer)
                    (> (+ buffer-length needed) (length buffer)))
            (if (and buffer (= (length buffer) maximum-chunk-size))
                (flush)
              (let* ((old buffer)
                     (new-length
                      (if old
                          (min maximum-chunk-size (* 2 (length old)))
                        (min 64 maximum-chunk-size))))
                (while (< new-length (+ buffer-length needed))
                  (setq new-length
                        (min maximum-chunk-size (* 2 new-length))))
                (let ((new-buffer (allocate-buffer new-length)))
                  (when old
                    (epi-ledger--run-bounded-unit
                     'copy 'utf16-sort-key-growth (length old) work
                     (lambda ()
                       (store-substring new-buffer 0 old))))
                  (setq buffer new-buffer))))))
         (write-unit
          (unit)
          (epi-ledger--work-charge work 1)
          (aset buffer buffer-length (ash unit -8))
          (epi-ledger--work-charge work 1)
          (aset buffer (1+ buffer-length) (logand unit #xff))
          (setq buffer-length (+ buffer-length 2))))
      (dotimes (index (length value))
        (epi-ledger--work-charge work 1)
        (let ((character (aref value index)))
          (if (< character #x10000)
              (progn
                (ensure-room 2)
                (write-unit character))
            (let* ((adjusted (- character #x10000))
                   (high (+ #xd800 (ash adjusted -10)))
                   (low (+ #xdc00 (logand adjusted #x3ff))))
              (ensure-room 4)
              (write-unit high)
              (write-unit low)))))
      (flush)
      (or (epi-ledger--work-nreverse-list chunks work)
          (epi-ledger--work-cons "" nil work)))))

(defun epi-ledger--utf16be-key (value)
  "Return BOM-free UTF-16BE sort bytes for canonical string VALUE."
  (epi-ledger--with-operation-work-state
    (let* ((work (epi-ledger--make-work-state))
           (chunks (epi-ledger--utf16be-key-chunks value work))
           (tail chunks)
           (bytes 0))
      (while (consp tail)
        (let ((chunk (epi-ledger--work-car tail work))
              (next (epi-ledger--work-cdr tail work)))
          (setq bytes (+ bytes (length chunk))
                tail next)))
      (epi-ledger--work-concat-chunks
       chunks bytes work 'utf16-sort-key))))

(defconst epi-ledger--jcs-string-run-character-limit 1024
  "Maximum ordinary characters encoded as one bounded string chunk.")

(defconst epi-ledger--jcs-special-unibyte-regexp
  (concat "[" (unibyte-string 0) "-" (unibyte-string 31) "\"\\\\"
          (unibyte-string 128) "-" (unibyte-string 255) "]")
  "Regexp matching a byte needing JCS handling or rejection.")

(defun epi-ledger--jcs-string-byte-length
    (value limit &optional reported-limit limit-code work-state)
  "Return VALUE's canonical JSON string byte length without allocating it.
Signal a structured limit error as soon as the encoded length exceeds LIMIT.
Optional REPORTED-LIMIT is the enclosing public cap named by that error.
LIMIT-CODE defaults to `record-json-byte-limit'.  Optional WORK-STATE receives
the scan charge."
  (unless (stringp value)
    (epi-ledger--format-fail 'invalid-string :field 'string))
  (let ((work (or work-state (epi-ledger--make-work-state)))
        (total 2))
    (cl-labels
        ((check-limit
          ()
          (when (> total limit)
            (epi-ledger--limit-fail
             (or limit-code 'record-json-byte-limit)
             :limit (or reported-limit limit))))
         (charge-character
          (character multibyte)
          (unless (if multibyte
                      (and (<= character #x10ffff)
                           (not (<= #xd800 character #xdfff)))
                    (<= character #x7f))
            (epi-ledger--format-fail 'invalid-string :field 'string))
          (let ((amount
                 (cond
                  ((memq character '(8 9 10 12 13 34 92)) 2)
                  ((< character 32) 6)
                  ((<= character #x7f) 1)
                  ((<= character #x7ff) 2)
                  ((<= character #xffff) 3)
                  (t 4))))
            (setq total (+ total amount))
            amount)))
      (check-limit)
      (if (not (multibyte-string-p value))
          (if (= epi-ledger-work-byte-limit 1)
              (dotimes (index (length value))
                (epi-ledger--work-charge work 1)
                (let ((amount (charge-character (aref value index) nil)))
                  (epi-ledger--work-charge-count work (1- amount)))
                (check-limit))
            (let ((cursor 0)
                  (chunk-size
                   (max 1
                        (min 65536 (/ epi-ledger-work-byte-limit 2)))))
              (while (< cursor (length value))
                (let* ((end (min (length value) (+ cursor chunk-size)))
                       (chunk-length (- end cursor)))
                  (epi-ledger--work-charge work (* 2 chunk-length))
                  (let* ((chunk (substring value cursor end))
                         (special
                          (string-match-p
                           epi-ledger--jcs-special-unibyte-regexp chunk)))
                    (if special
                        (dotimes (index (length chunk))
                          (epi-ledger--work-charge work 1)
                          (let ((amount
                                 (charge-character (aref chunk index) nil)))
                            (epi-ledger--work-charge-count work (1- amount))))
                      (setq total (+ total chunk-length))))
                  (check-limit)
                  (setq cursor end)))))
        (dotimes (index (length value))
          (epi-ledger--work-charge work 1)
          (let ((amount (charge-character (aref value index) t)))
            (epi-ledger--work-charge-count work (1- amount)))
          (check-limit)))
      total)))

(defun epi-ledger--jcs-write-string (value state)
  "Stream canonical JSON string VALUE into encoder STATE."
  (unless (epi-ledger--jcs-state-trusted state)
    (epi-ledger--jcs-string-byte-length
     value (- (epi-ledger--jcs-state-max-bytes state)
              (epi-ledger--jcs-state-bytes state))
     (epi-ledger--jcs-state-max-bytes state) nil
     (epi-ledger--jcs-state-work state)))
  (epi-ledger--jcs-add state "\"")
  (let ((pending nil)
        (pending-bytes 0)
        (pending-limit (max 1 (min 4096 epi-ledger-work-byte-limit))))
    (cl-labels
        ((flush
          ()
          (when pending
            (let* ((ordered
                    (epi-ledger--work-nreverse-list
                     pending (epi-ledger--jcs-state-work state))))
              (let* ((work (epi-ledger--jcs-state-work state))
                     (first (epi-ledger--work-car ordered work))
                     (rest (epi-ledger--work-cdr ordered work))
                     (chunk
                    (if rest
                        (epi-ledger--work-concat-chunks
                         ordered pending-bytes
                         work
                         'json-string-pending)
                      first)))
                (epi-ledger--jcs-add state chunk)))
            (setq pending nil pending-bytes 0)))
         (queue
          (chunk)
          (when (multibyte-string-p chunk)
            (let ((storage (string-bytes chunk)))
              (setq chunk
                    (if (> storage epi-ledger-work-byte-limit)
                        (epi-ledger--run-nonpreemptible
                         'encode 'json-string-chunk storage
                         (lambda ()
                           (encode-coding-string chunk 'utf-8-unix)))
                      (epi-ledger--work-charge
                       (epi-ledger--jcs-state-work state) storage)
                      (encode-coding-string chunk 'utf-8-unix)))))
          (when (> (+ (epi-ledger--jcs-state-bytes state)
                      pending-bytes (length chunk))
                   (epi-ledger--jcs-state-max-bytes state))
            (epi-ledger--limit-fail
             'record-json-byte-limit
             :limit (epi-ledger--jcs-state-max-bytes state)))
          (when (> (+ pending-bytes (length chunk)) pending-limit)
            (flush))
          (setq pending
                (epi-ledger--work-cons
                 chunk pending (epi-ledger--jcs-state-work state)))
          (setq pending-bytes (+ pending-bytes (length chunk))))
         (ordinary-character-p
          (character)
          (and (>= character 32)
               (/= character 34)
               (/= character 92))))
      (let ((index 0)
            (value-length (length value)))
        (while (< index value-length)
          (let* ((start index)
                 (limit (min value-length
                             (+ index
                                (min
                                 epi-ledger--jcs-string-run-character-limit
                                 (max 1
                                      (/ epi-ledger-work-byte-limit 5)))))))
            ;; Reserve the complete bounded scan before inspecting its first
            ;; character.  A later escaped character can make this reservation
            ;; conservative, but no physical scan may precede its work charge.
            (epi-ledger--work-charge
             (epi-ledger--jcs-state-work state) (- limit start))
            (let ((character (aref value index)))
              (if (ordinary-character-p character)
                  (progn
                    (setq index (1+ index))
                    (while (and (< index limit)
                                (ordinary-character-p (aref value index)))
                      (setq index (1+ index)))
                    ;; The scan reserves one unit per character above.  A
                    ;; canonical Unicode scalar occupies at most four bytes,
                    ;; so reserve that independent worst-case copy before the
                    ;; substring primitive.  The run cap makes scan+copy at
                    ;; most one slice; cap=1 uses a measured bounded unit.
                    (let ((copy-work (* 4 (- index start))))
                      (queue
                       (epi-ledger--run-bounded-unit
                        'copy 'json-string-run copy-work
                        (epi-ledger--jcs-state-work state)
                        (lambda ()
                          (substring-no-properties
                           value start index))))))
                (queue
                 (pcase character
                   (8 "\\b") (9 "\\t") (10 "\\n") (12 "\\f") (13 "\\r")
                   (34 "\\\"") (92 "\\\\")
                   (_ (format "\\u%04x" character))))
                (setq index (1+ index)))))))
      (flush)))
  (epi-ledger--jcs-add state "\""))

(defun epi-ledger--jcs-number (value)
  "Return ECMAScript-compatible canonical number bytes for VALUE."
  (cond
   ((integerp value)
    (unless (<= (- epi-ledger--maximum-safe-integer)
                value epi-ledger--maximum-safe-integer)
      (epi-ledger--format-fail 'integer-out-of-range :field 'number))
    (number-to-string value))
   ((not (and (floatp value) (epi--finite-number-p value)))
    (epi-ledger--format-fail 'nonfinite-number :field 'number))
   ((zerop value) "0")
   (t
    (let* ((token (json-serialize value))
           (negative (eq (aref token 0) ?-))
           (unsigned (if negative (substring token 1) token))
           (parts (split-string unsigned "[eE]"))
           (mantissa (car parts))
           (exponent (if (cadr parts) (string-to-number (cadr parts)) 0))
           (dot (string-match-p "\\." mantissa))
           (integer-length (or dot (length mantissa)))
           (coefficient (replace-regexp-in-string "\\." "" mantissa))
           (leading (- (length coefficient)
                       (length (string-trim-left coefficient "0+"))))
           (digits (substring coefficient leading))
           (position (- (+ integer-length exponent) leading)))
      (when (string-empty-p digits)
        (setq digits "0" position 1))
      (while (and (> (length digits) 1)
                  (eq (aref digits (1- (length digits))) ?0))
        (setq digits (substring digits 0 -1)))
      (let* ((normalized-exponent (1- position))
             (body
              (if (<= -6 normalized-exponent 20)
                  (cond
                   ((<= position 0)
                    (concat "0." (make-string (- position) ?0) digits))
                   ((>= position (length digits))
                    (concat digits
                            (make-string (- position (length digits)) ?0)))
                   (t
                    (concat (substring digits 0 position) "."
                            (substring digits position))))
                (concat
                 (substring digits 0 1)
                 (if (> (length digits) 1)
                     (concat "." (substring digits 1))
                   "")
                 "e"
                 (if (>= normalized-exponent 0) "+" "")
                 (number-to-string normalized-exponent)))))
        (concat (if negative "-" "") body))))))

(cl-defstruct (epi-ledger--jcs-state
               (:constructor epi-ledger--make-jcs-state))
  chunks bytes items active max-bytes work trusted)

(defun epi-ledger--jcs-add (state bytes)
  "Append unibyte BYTES to encoder STATE without crossing its cap."
  (unless (and (stringp bytes) (not (multibyte-string-p bytes)))
    (let ((storage (string-bytes bytes)))
      (setq bytes
            (if (> storage epi-ledger-work-byte-limit)
                (epi-ledger--run-nonpreemptible
                 'encode 'json-chunk storage
                 (lambda () (encode-coding-string bytes 'utf-8-unix)))
              (epi-ledger--work-charge
               (epi-ledger--jcs-state-work state) storage)
              (encode-coding-string bytes 'utf-8-unix)))))
  (let ((total (+ (epi-ledger--jcs-state-bytes state) (length bytes))))
    (when (> total (epi-ledger--jcs-state-max-bytes state))
      (epi-ledger--limit-fail 'record-json-byte-limit
                              :limit (epi-ledger--jcs-state-max-bytes state)))
    (epi-ledger--work-charge-count
     (epi-ledger--jcs-state-work state) (length bytes))
    (let ((work (epi-ledger--jcs-state-work state)))
      (epi-ledger--work-charge work 1)
      (setf (epi-ledger--jcs-state-bytes state) total)
      (epi-ledger--work-charge work 1)
      (let* ((chunks (epi-ledger--jcs-state-chunks state))
             (new-chunks (epi-ledger--work-cons bytes chunks work)))
        (epi-ledger--work-charge work 1)
        (setf (epi-ledger--jcs-state-chunks state) new-chunks)))))

(defun epi-ledger--jcs-count-item (state)
  "Charge one container item to encoder STATE."
  (let ((work (epi-ledger--jcs-state-work state)))
    (epi-ledger--work-charge work 1)
    (let ((items (1+ (epi-ledger--jcs-state-items state))))
      (setf (epi-ledger--jcs-state-items state) items)
      (when (> items epi-json-item-limit)
        (epi-ledger--limit-fail
         'json-item-limit :limit epi-json-item-limit)))))

(defun epi-ledger--jcs-enter (state value depth)
  "Mark container VALUE active in STATE and validate DEPTH."
  (when (> depth epi-json-depth-limit)
    (epi-ledger--limit-fail 'json-depth-limit :limit epi-json-depth-limit))
  (when (gethash value (epi-ledger--jcs-state-active state))
    (epi-ledger--format-fail 'cyclic-json))
  (puthash value t (epi-ledger--jcs-state-active state)))

(defun epi-ledger--jcs-write (value state depth)
  "Encode VALUE into STATE at container DEPTH."
  (cond
   ((stringp value)
    (epi-ledger--jcs-write-string value state))
   ((or (integerp value) (floatp value))
    (epi-ledger--jcs-add state
                         (encode-coding-string
                          (epi-ledger--jcs-number value) 'utf-8-unix)))
   ((eq value t) (epi-ledger--jcs-add state "true"))
   ((eq value epi-json-false) (epi-ledger--jcs-add state "false"))
   ((eq value epi-json-null) (epi-ledger--jcs-add state "null"))
   ((vectorp value)
    (epi-ledger--jcs-enter state value (1+ depth))
    (unwind-protect
        (progn
          (epi-ledger--jcs-add state "[")
          (dotimes (index (length value))
            (when (> index 0) (epi-ledger--jcs-add state ","))
            (epi-ledger--jcs-count-item state)
            (epi-ledger--work-charge
             (epi-ledger--jcs-state-work state) 1)
            (let ((child (aref value index)))
              (epi-ledger--jcs-write child state (1+ depth))))
          (epi-ledger--jcs-add state "]"))
      (remhash value (epi-ledger--jcs-state-active state))))
   ((or (null value) (consp value))
    (epi-ledger--jcs-enter state value (1+ depth))
    (unwind-protect
        (let ((tail value)
              (fast value)
              (prospective-bytes 2)
              (first-entry t)
              entries)
          (while (consp tail)
            (let* ((work (epi-ledger--jcs-state-work state))
                   (entry (epi-ledger--work-car tail work))
                   (next (epi-ledger--work-cdr tail work)))
              (when (consp fast)
                (setq fast (epi-ledger--work-cdr fast work))
                (when (consp fast)
                  (setq fast (epi-ledger--work-cdr fast work))))
              (epi-ledger--jcs-count-item state)
              (unless (consp entry)
                (epi-ledger--format-fail 'object-required :field 'object))
              (let* ((key (epi-ledger--work-car entry work))
                     (child (epi-ledger--work-cdr entry work))
                     (separator-bytes (if first-entry 0 1))
                     (overhead-bytes (1+ separator-bytes))
                     (available
                      (- (epi-ledger--jcs-state-max-bytes state)
                         (epi-ledger--jcs-state-bytes state)
                         prospective-bytes overhead-bytes))
                     (key-bytes
                      (unless (epi-ledger--jcs-state-trusted state)
                        (epi-ledger--jcs-string-byte-length
                         key available
                         (epi-ledger--jcs-state-max-bytes state) nil
                         work))))
                (when key-bytes
                  (setq prospective-bytes
                        (+ prospective-bytes overhead-bytes key-bytes)))
                (let* ((sort-key
                        (epi-ledger--utf16be-key-chunks key work))
                       (triple
                        (epi-ledger--work-cons
                         key
                         (epi-ledger--work-cons
                          sort-key
                          (epi-ledger--work-cons child nil work)
                          work)
                         work)))
                  (setq entries
                        (epi-ledger--work-cons triple entries work))))
              (setq first-entry nil
                    tail next)
              (when (and (consp tail) (eq tail fast))
                (epi-ledger--format-fail 'cyclic-json))))
          (unless (null tail)
            (epi-ledger--format-fail 'object-required :field 'object))
          (setq entries
                (epi-ledger--work-sort-list-to-vector
                 entries
                 (lambda (left right)
                   (let ((work (epi-ledger--jcs-state-work state)))
                     (= -1
                        (epi-ledger--sort-key-compare
                         (epi-ledger--work-car
                          (epi-ledger--work-cdr left work) work)
                         (epi-ledger--work-car
                          (epi-ledger--work-cdr right work) work)
                         work))))
                 (epi-ledger--jcs-state-work state)
                 'json-object-order))
          (let (previous-key)
            (dotimes (index (length entries))
              (epi-ledger--work-charge
               (epi-ledger--jcs-state-work state) 1)
              (let* ((work (epi-ledger--jcs-state-work state))
                     (entry (aref entries index))
                     (tail (epi-ledger--work-cdr entry work))
                     (key (epi-ledger--work-car tail work)))
                (when (and previous-key
                           (zerop
                            (epi-ledger--sort-key-compare
                             previous-key key
                             (epi-ledger--jcs-state-work state))))
                  (epi-ledger--format-fail
                   'duplicate-key :field 'object))
                (setq previous-key key))))
          (epi-ledger--jcs-add state "{")
          (dotimes (index (length entries))
            (when (> index 0) (epi-ledger--jcs-add state ","))
            (epi-ledger--work-charge
             (epi-ledger--jcs-state-work state) 1)
            (let* ((work (epi-ledger--jcs-state-work state))
                   (entry (aref entries index))
                   (key (epi-ledger--work-car entry work))
                   (tail (epi-ledger--work-cdr entry work))
                   (value-tail (epi-ledger--work-cdr tail work))
                   (child (epi-ledger--work-car value-tail work)))
              (epi-ledger--jcs-write-string key state)
              (epi-ledger--jcs-add state ":")
              (epi-ledger--jcs-write child state (1+ depth))))
          (epi-ledger--jcs-add state "}"))
      (remhash value (epi-ledger--jcs-state-active state))))
   (t
    (epi-ledger--format-fail 'unsupported-json-value
                             :type (type-of value)))))

(defun epi-ledger--jcs-encode (value &optional max-bytes trusted)
  "Return canonical UTF-8 JCS bytes for VALUE.
MAX-BYTES defaults to `epi-record-json-byte-limit'.  When TRUSTED is non-nil,
VALUE has already passed exact canonical preflight."
  (epi-ledger--with-operation-work-state
    (let ((state
           (epi-ledger--make-jcs-state
            :chunks nil :bytes 0 :items 0
            :active (make-hash-table :test #'eq)
            :max-bytes (or max-bytes epi-record-json-byte-limit)
            :work (epi-ledger--make-work-state) :trusted trusted)))
      (epi-ledger--jcs-write value state 0)
      (let ((chunks
             (epi-ledger--work-nreverse-list
              (epi-ledger--jcs-state-chunks state)
              (epi-ledger--jcs-state-work state)))
            (bytes (epi-ledger--jcs-state-bytes state)))
        (epi-ledger--work-concat-chunks
         chunks bytes (epi-ledger--jcs-state-work state)
         'canonical-json)))))

(defconst epi-ledger--lex-clock-check-byte-interval 4096
  "Maximum lexical bytes consumed between deadline clock checks.")

(defvar epi-ledger--lex-raw-reservation-limit nil
  "Optional dynamic upper bound for one raw lexical reservation.")

(cl-defstruct (epi-ledger--lex-state
               (:constructor epi-ledger--make-lex-state))
  bytes length position depth items work charged-position
  next-check-position completion-bytes peeked-byte)

(defun epi-ledger--lex-stop (kind code state &optional minimum-completion)
  "Stop scanning with KIND and CODE at STATE.
Optional MINIMUM-COMPLETION records the least suffix byte count."
  (throw 'epi-ledger--lex-stop
         (append
          (list :kind kind :code code
                :offset (epi-ledger--lex-state-position state))
          (when minimum-completion
            (list :minimum-completion-bytes minimum-completion)))))

(defun epi-ledger--lex-invalid (state code)
  "Stop lexical STATE as invalid with CODE."
  (epi-ledger--lex-stop 'invalid code state))

(defun epi-ledger--lex-incomplete (state code &optional local-minimum)
  "Stop STATE as incomplete with CODE and optional LOCAL-MINIMUM bytes."
  (epi-ledger--lex-stop
   'incomplete code state
   (+ (or local-minimum 1)
      (epi-ledger--lex-state-completion-bytes state))))

(defun epi-ledger--lex-with-completion (state additional thunk)
  "Call THUNK with ADDITIONAL completion bytes charged in lexical STATE."
  (let ((original (epi-ledger--lex-state-completion-bytes state)))
    (setf (epi-ledger--lex-state-completion-bytes state)
          (+ original additional))
    (unwind-protect (funcall thunk)
      (setf (epi-ledger--lex-state-completion-bytes state) original))))

(defun epi-ledger--lex-maybe-yield (state)
  "Reserve the next bounded raw lexical unit in STATE before reading it."
  (let ((position (epi-ledger--lex-state-position state)))
    (when (>= position (epi-ledger--lex-state-charged-position state))
      (let ((reserved-through
             (min (epi-ledger--lex-state-length state)
                  (+ position
                     (max 1
                          (min epi-ledger--lex-clock-check-byte-interval
                               epi-ledger-work-byte-limit
                               (or epi-ledger--lex-raw-reservation-limit
                                   epi-ledger-work-byte-limit)))))))
      (epi-ledger--work-charge
       (epi-ledger--lex-state-work state)
       (- reserved-through position))
      (setf (epi-ledger--lex-state-charged-position state) reserved-through
            (epi-ledger--lex-state-next-check-position state)
            reserved-through)))))

(defun epi-ledger--lex-flush-work (state)
  "End STATE's raw reservation before auxiliary cooperative processing."
  (when (> (epi-ledger--lex-state-position state)
           (epi-ledger--lex-state-charged-position state))
    (error "Unreserved lexical work"))
  ;; Auxiliary work can yield.  Discard any unused raw reservation so bytes
  ;; read after that yield must reserve against the new physical slice.  A
  ;; cached peek may remain logically reserved because consuming it performs
  ;; no later physical input read.
  (let ((reserved-through
         (+ (epi-ledger--lex-state-position state)
            (if (epi-ledger--lex-state-peeked-byte state) 1 0))))
    (setf (epi-ledger--lex-state-charged-position state) reserved-through
          (epi-ledger--lex-state-next-check-position state)
          reserved-through)))

(defun epi-ledger--lex-byte (state)
  "Return the next byte from STATE and advance."
  (when (>= (epi-ledger--lex-state-position state)
            (epi-ledger--lex-state-length state))
    (epi-ledger--lex-incomplete state 'unexpected-end-of-json))
  (let* ((position (epi-ledger--lex-state-position state))
         (peeked (epi-ledger--lex-state-peeked-byte state))
         (byte
          (if peeked
              peeked
            (epi-ledger--lex-maybe-yield state)
            (epi-ledger--source-byte
             (epi-ledger--lex-state-bytes state) position))))
    (setf (epi-ledger--lex-state-position state) (1+ position)
          (epi-ledger--lex-state-peeked-byte state) nil)
    byte))

(defun epi-ledger--lex-peek (state)
  "Return STATE's next byte without advancing, or nil at end."
  (when (< (epi-ledger--lex-state-position state)
           (epi-ledger--lex-state-length state))
    (or (epi-ledger--lex-state-peeked-byte state)
        (progn
          (epi-ledger--lex-maybe-yield state)
          (setf (epi-ledger--lex-state-peeked-byte state)
                (epi-ledger--source-byte
                 (epi-ledger--lex-state-bytes state)
                 (epi-ledger--lex-state-position state)))))))

(defun epi-ledger--lex-expect (state expected code)
  "Consume EXPECTED byte from STATE or stop with CODE."
  (unless (= (epi-ledger--lex-byte state) expected)
    (epi-ledger--lex-invalid state code)))

(defun epi-ledger--lex-utf8-sequence (state first)
  "Consume UTF-8 beginning with FIRST in STATE and return its scalar."
  (cond
   ((<= #xc2 first #xdf)
    (let ((second (epi-ledger--lex-byte state)))
      (unless (<= #x80 second #xbf)
        (epi-ledger--lex-invalid state 'malformed-utf8))
      (logior (ash (logand first #x1f) 6) (logand second #x3f))))
   ((<= #xe0 first #xef)
    (let ((second (epi-ledger--lex-byte state))
          third)
      (unless (pcase first
                (#xe0 (<= #xa0 second #xbf))
                (#xed (<= #x80 second #x9f))
                (_ (<= #x80 second #xbf)))
        (epi-ledger--lex-invalid state 'malformed-utf8))
      (setq third (epi-ledger--lex-byte state))
      (unless (<= #x80 third #xbf)
        (epi-ledger--lex-invalid state 'malformed-utf8))
      (logior (ash (logand first #x0f) 12)
              (ash (logand second #x3f) 6)
              (logand third #x3f))))
   ((<= #xf0 first #xf4)
    (let ((second (epi-ledger--lex-byte state)) third fourth)
      (unless (pcase first
                (#xf0 (<= #x90 second #xbf))
                (#xf4 (<= #x80 second #x8f))
                (_ (<= #x80 second #xbf)))
        (epi-ledger--lex-invalid state 'malformed-utf8))
      (setq third (epi-ledger--lex-byte state)
            fourth (epi-ledger--lex-byte state))
      (unless (and (<= #x80 third #xbf) (<= #x80 fourth #xbf))
        (epi-ledger--lex-invalid state 'malformed-utf8))
      (logior (ash (logand first #x07) 18)
              (ash (logand second #x3f) 12)
              (ash (logand third #x3f) 6)
              (logand fourth #x3f))))
   (t
    (epi-ledger--lex-invalid state 'malformed-utf8))))

(defun epi-ledger--lex-hex-value (byte)
  "Return lowercase hexadecimal value of BYTE, or nil."
  (cond ((<= ?0 byte ?9) (- byte ?0))
        ((<= ?a byte ?f) (+ 10 (- byte ?a)))
        (t nil)))

(defun epi-ledger--lex-partial-escape-maximum (state start)
  "Return the greatest scalar allowed by a partial escape at START in STATE."
  (let* ((bytes (epi-ledger--lex-state-bytes state))
         (length (- (epi-ledger--lex-state-position state) start)))
    (pcase length
      (1 #x5c)
      ((or 2 3 4) #x1f)
      (5
       (epi-ledger--work-charge (epi-ledger--lex-state-work state) 1)
       (if (= (epi-ledger--source-byte bytes (+ start 4)) ?0) #x0f #x1f))
      (_ (epi-ledger--lex-invalid state 'nonminimal-string-escape)))))

(defun epi-ledger--lex-partial-escape-minimum (state start)
  "Return bytes needed to finish partial escape at START in STATE and quote."
  (let ((length (- (epi-ledger--lex-state-position state) start)))
    (if (= length 1)
        2
      (+ 1 (- 6 length)))))

(defun epi-ledger--lex-partial-utf8-maximum (state start)
  "Return the greatest scalar allowed by partial UTF-8 at START in STATE."
  (let* ((bytes (epi-ledger--lex-state-bytes state))
         (end (epi-ledger--lex-state-position state))
         (_lead-reserved
          (epi-ledger--work-charge (epi-ledger--lex-state-work state) 1))
         (lead (epi-ledger--source-byte bytes start))
         (second
          (and (< (1+ start) end)
               (progn
                 (epi-ledger--work-charge
                  (epi-ledger--lex-state-work state) 1)
                 (epi-ledger--source-byte bytes (1+ start)))))
         (third
          (and (< (+ start 2) end)
               (progn
                 (epi-ledger--work-charge
                  (epi-ledger--lex-state-work state) 1)
                 (epi-ledger--source-byte bytes (+ start 2))))))
    (cond
     ((<= #xc2 lead #xdf)
      (logior (ash (logand lead #x1f) 6) #x3f))
     ((<= #xe0 lead #xef)
      (setq second (or second (if (= lead #xed) #x9f #xbf)))
      (logior (ash (logand lead #x0f) 12)
              (ash (logand second #x3f) 6)
              #x3f))
     ((<= #xf0 lead #xf4)
      (setq second (or second (if (= lead #xf4) #x8f #xbf))
            third (or third #xbf))
      (logior (ash (logand lead #x07) 18)
              (ash (logand second #x3f) 12)
              (ash (logand third #x3f) 6)
              #x3f))
     (t (epi-ledger--lex-invalid state 'malformed-utf8)))))

(defun epi-ledger--lex-partial-utf8-minimum (state start)
  "Return bytes needed to finish partial UTF-8 at START in STATE and quote."
  (let* ((_reserved
          (epi-ledger--work-charge (epi-ledger--lex-state-work state) 1))
         (lead (epi-ledger--source-byte
                (epi-ledger--lex-state-bytes state) start))
         (total (cond ((<= #xc2 lead #xdf) 2)
                      ((<= #xe0 lead #xef) 3)
                      ((<= #xf0 lead #xf4) 4)
                      (t (epi-ledger--lex-invalid state 'malformed-utf8))))
         (consumed (- (epi-ledger--lex-state-position state) start)))
    (+ 1 (- total consumed))))

(defun epi-ledger--canonical-scalar-byte-length (scalar)
  "Return canonical JSON content byte length for Unicode SCALAR."
  (cond
   ((memq scalar '(8 9 10 12 13 34 92)) 2)
   ((< scalar 32) 6)
   ((<= scalar #x7f) 1)
   ((<= scalar #x7ff) 2)
   ((<= scalar #xffff) 3)
   (t 4)))

(defun epi-ledger--greater-scalar-minimum-byte-length (scalar)
  "Return least JSON bytes for one scalar sorting after SCALAR, or nil."
  (cond ((< scalar #x7f) 1)
        ((< scalar #x7ff) 2)
        ((< scalar #xffff) 3)
        ((> scalar #xffff) 3)
        (t nil)))

(defun epi-ledger--sort-key-chunks (key &optional work)
  "Return UTF-16BE sort KEY as a forward list of bounded chunks.
When WORK is non-nil, reserve the singleton cons used for a flat key."
  (if (stringp key)
      (if work
          (epi-ledger--work-cons key nil work)
        (list key))
    key))

(defun epi-ledger--sort-key-compare (left right &optional work-state)
  "Compare chunked UTF-16BE sort keys LEFT and RIGHT cooperatively.
Optional WORK-STATE shares cadence across a whole encoder sort."
  (let* ((work (or work-state (epi-ledger--make-work-state)))
         (left-tail (epi-ledger--sort-key-chunks left work))
         (right-tail (epi-ledger--sort-key-chunks right work))
        (left-index 0)
         (right-index 0))
    (catch 'comparison
      (while (and left-tail right-tail)
        (let ((left-chunk (epi-ledger--work-car left-tail work))
              (left-next (epi-ledger--work-cdr left-tail work))
              (right-chunk (epi-ledger--work-car right-tail work))
              (right-next (epi-ledger--work-cdr right-tail work)))
          (let* ((amount
                  (min (- (length left-chunk) left-index)
                       (- (length right-chunk) right-index)
                       (max 1 epi-ledger-work-byte-limit)))
                 (_reserved
                  (epi-ledger--work-charge work (max 1 amount)))
                 (comparison
                  (compare-strings
                   left-chunk left-index (+ left-index amount)
                   right-chunk right-index (+ right-index amount))))
            (if (eq comparison t)
                (progn
                  (setq left-index (+ left-index amount)
                        right-index (+ right-index amount)))
              (throw 'comparison (if (> comparison 0) 1 -1))))
          (when (= left-index (length left-chunk))
            (setq left-tail left-next left-index 0))
          (when (= right-index (length right-chunk))
            (setq right-tail right-next right-index 0))))
      (cond (left-tail 1) (right-tail -1) (t 0)))))

(defun epi-ledger--assert-unique-sort-keys (keys field work)
  "Reject duplicate chunked sort KEYS for FIELD, cooperatively using WORK."
  (let ((ordered
         (epi-ledger--work-sort-list-to-vector
          keys
          (lambda (left right)
            (= -1 (epi-ledger--sort-key-compare left right work)))
          work 'json-key-order)))
    (let (previous)
      (dotimes (index (length ordered))
        (epi-ledger--work-charge work 1)
        (let ((current (aref ordered index)))
          (when (and previous
                     (zerop (epi-ledger--sort-key-compare
                             previous current work)))
            (epi-ledger--format-fail 'duplicate-key :field field))
          (setq previous current))))
    ordered))

(defun epi-ledger--sort-key-prefix-relation
    (prefix previous &optional work-state)
  "Return PREFIX relation to PREVIOUS as `after', `prefix', or `before'.
Optional WORK-STATE receives the comparison charge."
  (let* ((work (or work-state (epi-ledger--make-work-state)))
         (prefix-tail (epi-ledger--sort-key-chunks prefix work))
         (previous-tail (epi-ledger--sort-key-chunks previous work))
        (prefix-index 0)
         (previous-index 0))
    (catch 'relation
      (while (and prefix-tail previous-tail)
        (let ((prefix-chunk (epi-ledger--work-car prefix-tail work))
              (prefix-next (epi-ledger--work-cdr prefix-tail work))
              (previous-chunk (epi-ledger--work-car previous-tail work))
              (previous-next (epi-ledger--work-cdr previous-tail work)))
          (let* ((amount
                  (min (- (length prefix-chunk) prefix-index)
                       (- (length previous-chunk) previous-index)
                       (max 1 epi-ledger-work-byte-limit)))
                 (_reserved
                  (epi-ledger--work-charge work (max 1 amount)))
                 (comparison
                  (compare-strings
                   prefix-chunk prefix-index (+ prefix-index amount)
                   previous-chunk previous-index
                   (+ previous-index amount))))
            (if (eq comparison t)
                (progn
                  (setq prefix-index (+ prefix-index amount)
                        previous-index (+ previous-index amount)))
              (throw 'relation
                     (if (> comparison 0) 'after 'before))))
          (when (= prefix-index (length prefix-chunk))
            (setq prefix-tail prefix-next prefix-index 0))
          (when (= previous-index (length previous-chunk))
            (setq previous-tail previous-next previous-index 0))))
      (if prefix-tail 'after 'prefix))))

(defun epi-ledger--sort-key-tail-after-prefix
    (prefix previous &optional work-state)
  "Return bounded PREVIOUS chunks following its known PREFIX.
The cursor walk obeys the cooperative-work budget independently of callers."
  (let* ((work (or work-state (epi-ledger--make-work-state)))
         (prefix-tail (epi-ledger--sort-key-chunks prefix work))
         (previous-tail (epi-ledger--sort-key-chunks previous work))
        (prefix-index 0)
         (previous-index 0))
    (cl-labels
        ((advance
          (amount)
          (epi-ledger--work-charge work (max 1 amount))
          (setq prefix-index (+ prefix-index amount)
                previous-index (+ previous-index amount))))
      (while prefix-tail
        (let* ((prefix-chunk (epi-ledger--work-car prefix-tail work))
               (prefix-next (epi-ledger--work-cdr prefix-tail work))
               (previous-chunk (epi-ledger--work-car previous-tail work))
               (previous-next (epi-ledger--work-cdr previous-tail work))
               (amount
                (min (- (length prefix-chunk) prefix-index)
                     (- (length previous-chunk) previous-index)
                     epi-ledger-work-byte-limit)))
          (advance amount)
          (when (= prefix-index (length prefix-chunk))
            (setq prefix-tail prefix-next prefix-index 0))
          (when (= previous-index (length previous-chunk))
            (setq previous-tail previous-next previous-index 0)))))
    (if (zerop previous-index)
        previous-tail
      (let* ((chunk (epi-ledger--work-car previous-tail work))
             (next (epi-ledger--work-cdr previous-tail work))
             (amount (- (length chunk) previous-index))
             (copy
              (epi-ledger--run-bounded-unit
               'copy 'sort-key-tail amount work
               (lambda () (substring chunk previous-index)))))
        (epi-ledger--work-cons copy next work)))))

(defun epi-ledger--key-successor-content-byte-cost
    (prefix previous &optional work-state)
  "Return least content bytes extending UTF-16BE PREFIX beyond PREVIOUS.
The backward scan of PREVIOUS obeys the cooperative-work budget.  Optional
WORK-STATE receives both the prefix and backward-scan charges."
  (let* ((work (or work-state (epi-ledger--make-work-state)))
         (tail
          (epi-ledger--work-reverse-list
           (epi-ledger--sort-key-tail-after-prefix prefix previous work)
           work))
         (cost 1))
    (while (consp tail)
      (let ((chunk (epi-ledger--work-car tail work))
            (next (epi-ledger--work-cdr tail work)))
        (let ((index (length chunk)))
        (while (> index 0)
          (epi-ledger--work-charge work 2)
          (let* ((low-index (- index 2))
                 (low (+ (ash (aref chunk low-index) 8)
                         (aref chunk (1+ low-index))))
                 scalar)
            (if (<= #xdc00 low #xdfff)
                (let* ((_reserved (epi-ledger--work-charge work 2))
                       (high-index (- index 4))
                       (high (+ (ash (aref chunk high-index) 8)
                                (aref chunk (1+ high-index)))))
                  (setq scalar
                        (+ #x10000 (ash (- high #xd800) 10)
                           (- low #xdc00))
                        index high-index))
              (setq scalar low index low-index))
            (let ((greater
                   (epi-ledger--greater-scalar-minimum-byte-length scalar)))
              (setq cost
                    (if greater
                        (min greater
                             (+ (epi-ledger--canonical-scalar-byte-length scalar)
                                cost))
                      (+ (epi-ledger--canonical-scalar-byte-length scalar)
                         cost)))))))
        (setq tail next)))
    cost))

(defun epi-ledger--lex-key-prefix-order (state chunks previous
                                               &optional maximum-next-scalar)
  "Return minimum extra key bytes or reject an irreversible STATE prefix.
CHUNKS are forward UTF-16BE chunks for the captured key prefix.  PREVIOUS is
the preceding complete chunked sort key.  Optional MAXIMUM-NEXT-SCALAR
constrains a partial escape or UTF-8 token."
  (let ((maximum-chunk
         (and maximum-next-scalar
              (if (<= maximum-next-scalar #xffff)
                  (unibyte-string (ash maximum-next-scalar -8)
                                  (logand maximum-next-scalar #xff))
                (let* ((code (- maximum-next-scalar #x10000))
                       (high (+ #xd800 (ash code -10)))
                       (low (+ #xdc00 (logand code #x3ff))))
                  (unibyte-string (ash high -8) (logand high #xff)
                                  (ash low -8) (logand low #xff)))))))
    (epi-ledger--lex-flush-work state)
    (let ((prefix
           (if maximum-chunk
               (epi-ledger--work-append-one
                chunks maximum-chunk (epi-ledger--lex-state-work state))
             chunks)))
      (pcase (epi-ledger--sort-key-prefix-relation
              prefix previous (epi-ledger--lex-state-work state))
       ('after 0)
       ('prefix
        (epi-ledger--key-successor-content-byte-cost
         prefix previous (epi-ledger--lex-state-work state)))
       (_ (epi-ledger--lex-invalid state 'unsorted-key))))))

(defun epi-ledger--lex-string (state capture &optional previous-sort-key)
  "Scan one canonical JSON string from STATE.
When CAPTURE is non-nil, return bounded UTF-16BE sort-key chunks.  Optional
PREVIOUS-SORT-KEY proves that an unterminated object key can still sort after
the preceding key."
  (epi-ledger--lex-expect state ?\" 'string-required)
  (let ((epi-ledger--lex-raw-reservation-limit
         (if capture 1 epi-ledger--lex-raw-reservation-limit))
        (maximum-capture-chunk-size
         (max 4 (* 2 (/ (min 4096 (max 4 epi-ledger-work-byte-limit)) 2))))
        (capture-buffer nil)
        (capture-length 0)
        chunks done)
    (when capture
      (epi-ledger--lex-flush-work state))
    (cl-labels
        ((capture-run-bounded
          (kind field amount thunk)
          (epi-ledger--lex-flush-work state)
          (epi-ledger--run-bounded-unit
           kind field amount (epi-ledger--lex-state-work state) thunk))
         (capture-flush
          ()
          (when (and capture (> capture-length 0))
            (let ((chunk
                   (capture-run-bounded
                    'copy 'lex-key-chunk capture-length
                    (lambda ()
                      (substring capture-buffer 0 capture-length)))))
              (epi-ledger--work-charge
               (epi-ledger--lex-state-work state) 1)
              (push chunk chunks))
            (setq capture-length 0)))
         (capture-ensure-room
          (needed)
          (when capture
            (when (or (null capture-buffer)
                      (> (+ capture-length needed)
                         (length capture-buffer)))
              (if (and capture-buffer
                       (= (length capture-buffer)
                          maximum-capture-chunk-size))
                  (capture-flush)
                (let* ((new-length
                        (if capture-buffer
                            (min maximum-capture-chunk-size
                                 (* 2 (length capture-buffer)))
                          (min 64 maximum-capture-chunk-size))))
                  (while (< new-length (+ capture-length needed))
                    (setq new-length
                          (min maximum-capture-chunk-size
                               (* 2 new-length))))
                  (let ((new-buffer
                         (capture-run-bounded
                          'allocate 'lex-key-buffer new-length
                          (lambda () (make-string new-length 0)))))
                    (when capture-buffer
                      (capture-run-bounded
                       'copy 'lex-key-buffer-growth
                       (length capture-buffer)
                       (lambda ()
                         (store-substring new-buffer 0 capture-buffer))))
                    (setq capture-buffer new-buffer)))))))
         (capture-scalar
          (scalar)
          (when capture
            (capture-ensure-room (if (<= scalar #xffff) 2 4))
            (epi-ledger--lex-flush-work state)
            (if (<= scalar #xffff)
                (progn
                  (epi-ledger--work-charge
                   (epi-ledger--lex-state-work state) 1)
                  (aset capture-buffer capture-length (ash scalar -8))
                  (epi-ledger--work-charge
                   (epi-ledger--lex-state-work state) 1)
                  (aset capture-buffer (1+ capture-length)
                        (logand scalar #xff))
                  (setq capture-length (+ capture-length 2)))
              (let* ((code (- scalar #x10000))
                     (high (+ #xd800 (ash code -10)))
                     (low (+ #xdc00 (logand code #x3ff))))
                (epi-ledger--work-charge
                 (epi-ledger--lex-state-work state) 1)
                (aset capture-buffer capture-length (ash high -8))
                (epi-ledger--work-charge
                 (epi-ledger--lex-state-work state) 1)
                (aset capture-buffer (1+ capture-length)
                      (logand high #xff))
                (epi-ledger--work-charge
                 (epi-ledger--lex-state-work state) 1)
                (aset capture-buffer (+ capture-length 2) (ash low -8))
                (epi-ledger--work-charge
                 (epi-ledger--lex-state-work state) 1)
                (aset capture-buffer (+ capture-length 3)
                      (logand low #xff))
                (setq capture-length (+ capture-length 4))))
            (when (= capture-length maximum-capture-chunk-size)
              (capture-flush))))
         (capture-result
          ()
          (capture-flush)
          (epi-ledger--lex-flush-work state)
          (or (epi-ledger--work-nreverse-list
               chunks (epi-ledger--lex-state-work state))
              (epi-ledger--work-cons
               "" nil (epi-ledger--lex-state-work state)))))
      (while (not done)
        (when (>= (epi-ledger--lex-state-position state)
                  (epi-ledger--lex-state-length state))
          (let* ((prefix (and capture (capture-result)))
                 (ordering-extra
                  (if (and capture previous-sort-key)
                      (epi-ledger--lex-key-prefix-order
                       state prefix previous-sort-key)
                    0)))
            (epi-ledger--lex-incomplete
             state 'unexpected-end-of-json (1+ ordering-extra))))
        (let* ((position (epi-ledger--lex-state-position state))
               (byte (epi-ledger--lex-byte state)))
          (cond
           ((= byte ?\")
            (setq done t))
           ((= byte ?\\)
            (let ((stop
                   (catch 'epi-ledger--lex-stop
                     (let ((escape (epi-ledger--lex-byte state)))
                       (cond
                       ((memq escape '(?\" ?\\))
                         (capture-scalar escape))
                        ((memq escape '(?b ?t ?n ?f ?r))
                         (capture-scalar
                          (alist-get escape
                                     '((?b . 8) (?t . 9) (?n . 10)
                                       (?f . 12) (?r . 13)))))
                        ((= escape ?u)
                         (let ((value 0))
                           (dotimes (index 4)
                             (let ((digit
                                    (epi-ledger--lex-hex-value
                                     (epi-ledger--lex-byte state))))
                               (unless digit
                                 (epi-ledger--lex-invalid
                                  state 'nonminimal-string-escape))
                               (when (or (and (< index 2)
                                              (not (zerop digit)))
                                         (and (= index 2) (> digit 1)))
                                 (epi-ledger--lex-invalid
                                  state 'nonminimal-string-escape))
                               (setq value (+ (ash value 4) digit))))
                           (unless (and (< value 32)
                                        (not (memq value
                                                   '(8 9 10 12 13))))
                             (epi-ledger--lex-invalid
                              state 'nonminimal-string-escape))
                           (capture-scalar value)))
                        (t
                         (epi-ledger--lex-invalid
                          state 'nonminimal-string-escape))))
                     nil)))
              (when stop
                (when (eq (plist-get stop :kind) 'incomplete)
                  (let ((ordering-extra 0))
                    (when (and capture previous-sort-key)
                      (setq ordering-extra
                            (epi-ledger--lex-key-prefix-order
                             state (capture-result) previous-sort-key
                             (epi-ledger--lex-partial-escape-maximum
                              state position))))
                    (setq stop
                          (plist-put
                           stop :minimum-completion-bytes
                           (+ (epi-ledger--lex-state-completion-bytes state)
                              (epi-ledger--lex-partial-escape-minimum
                               state position)
                              ordering-extra)))))
                (throw 'epi-ledger--lex-stop stop))))
           ((< byte 32)
            (epi-ledger--lex-invalid state 'unescaped-control-character))
           ((>= byte #x80)
            (let* (scalar
                  (stop
                   (catch 'epi-ledger--lex-stop
                     (setq scalar
                           (epi-ledger--lex-utf8-sequence state byte))
                     nil)))
              (when stop
                (when (eq (plist-get stop :kind) 'incomplete)
                  (let ((ordering-extra 0))
                    (when (and capture previous-sort-key)
                      (setq ordering-extra
                            (epi-ledger--lex-key-prefix-order
                             state (capture-result) previous-sort-key
                             (epi-ledger--lex-partial-utf8-maximum
                              state position))))
                    (setq stop
                          (plist-put
                           stop :minimum-completion-bytes
                           (+ (epi-ledger--lex-state-completion-bytes state)
                              (epi-ledger--lex-partial-utf8-minimum
                               state position)
                              ordering-extra)))))
                (throw 'epi-ledger--lex-stop stop))
              (capture-scalar scalar)))
           (t (capture-scalar byte)))))
      (when capture (capture-result)))))

(defun epi-ledger--lex-count-item (state)
  "Charge one object member or array element to lexical STATE."
  (cl-incf (epi-ledger--lex-state-items state))
  (when (> (epi-ledger--lex-state-items state) epi-json-item-limit)
    (epi-ledger--lex-invalid state 'json-item-limit)))

(defun epi-ledger--lex-enter (state)
  "Enter one JSON container in STATE."
  (cl-incf (epi-ledger--lex-state-depth state))
  (when (> (epi-ledger--lex-state-depth state) epi-json-depth-limit)
    (epi-ledger--lex-invalid state 'json-depth-limit)))

(defconst epi-ledger--numeric-clock-check-work-interval 256
  "Maximum numeric witness candidates between deadline checks.")

(defun epi-ledger--make-numeric-work-checkpoint ()
  "Return a closure that cooperatively charges one numeric search unit."
  (let ((work (epi-ledger--make-work-state)))
    (lambda () (epi-ledger--work-charge work 1))))

(defun epi-ledger--canonical-integer-prefix-witness-minimum
    (token checkpoint)
  "Return shortest canonical fixed-form completion length for integer TOKEN.
Call CHECKPOINT once for every binary64 candidate examined."
  (let* ((negative (= (aref token 0) ?-))
         (digits (if negative (substring token 1) token))
         (digit-count (length digits))
         (prefix-magnitude (string-to-number digits)))
    (and
     (< digit-count 21)
     (catch 'witness
       (let ((target-length (1+ digit-count)))
         (while (<= target-length 21)
           (let* ((scale (expt 10 (- target-length digit-count)))
                  (magnitude (* prefix-magnitude scale))
                  (end (* (1+ prefix-magnitude) scale))
                  previous-float)
             (while (< magnitude end)
               (funcall checkpoint)
               (let ((candidate-float
                      (float (if negative (- magnitude) magnitude))))
                 (unless (and previous-float
                              (= previous-float candidate-float))
                   (setq previous-float candidate-float)
                   (let ((canonical
                          (epi-ledger--jcs-number candidate-float)))
                     (when (and (> (length canonical) (length token))
                                (string-prefix-p token canonical)
                                (string-match-p
                                 "\\`-?[1-9][0-9]*\\'" canonical))
                       (throw 'witness
                              (- (length canonical) (length token)))))))
               (setq magnitude (1+ magnitude))))
           (setq target-length (1+ target-length))))
       nil))))

(defun epi-ledger--canonical-number-token-p (token)
  "Return whether ASCII TOKEN is a complete canonical binary64 spelling."
  (let ((value (condition-case nil
                   (json-parse-string token)
                 (error nil))))
    (when (and (integerp value)
               (> (abs value) epi-ledger--maximum-safe-integer))
      (setq value (condition-case nil (float value) (error nil))))
    (and (numberp value)
         (epi--finite-number-p value)
         (equal token
                (encode-coding-string
                 (epi-ledger--jcs-number value) 'utf-8-unix)))))

(defun epi-ledger--canonical-decimal-prefix-witness-minimum
    (token checkpoint)
  "Return shortest one-digit canonical fixed completion for decimal TOKEN.
Call CHECKPOINT once for every binary64 candidate examined."
  (catch 'witness
    (dotimes (digit 10)
      (funcall checkpoint)
      (let ((candidate (concat token (string (+ ?0 digit)))))
        (when (epi-ledger--canonical-number-token-p candidate)
          (throw 'witness 1))))
    nil))

(defconst epi-ledger--canonical-exponent-suffixes
  (sort
   (mapcar (lambda (exponent)
             (if (< exponent 0)
                 (format "e-%d" (- exponent))
               (format "e+%d" exponent)))
           (number-sequence -324 308))
   (lambda (left right)
     (or (< (length left) (length right))
         (and (= (length left) (length right))
              (string< left right)))))
  "Binary64 exponent suffixes ordered by byte length, then lexically.")

(defun epi-ledger--canonical-scientific-prefix-witness-minimum
    (token mantissa checkpoint)
  "Return shortest canonical exponent completion for TOKEN and MANTISSA.
Call CHECKPOINT once for every binary64 candidate examined."
  (catch 'witness
    (dolist (suffix epi-ledger--canonical-exponent-suffixes)
      (funcall checkpoint)
      (let ((candidate (concat mantissa suffix)))
        (when (and (string-prefix-p token candidate)
                   (> (length candidate) (length token))
                   (epi-ledger--canonical-number-token-p candidate))
          (throw 'witness (- (length candidate) (length token))))))
    nil))

(defun epi-ledger--canonical-mantissa-prefix-witness-minimum
    (token checkpoint)
  "Return shortest scientific completion for unfinished MANTISSA TOKEN.
Use CHECKPOINT throughout the shared exponent search."
  (let ((digit-count
         (cl-count-if (lambda (byte) (<= ?0 byte ?9)) token)))
    (when (<= digit-count 17)
      (or
       (and (string-match-p
             "\\`-?[1-9]\\(?:\\.[0-9]*[1-9]\\)?\\'" token)
            (epi-ledger--canonical-scientific-prefix-witness-minimum
             token token checkpoint))
       (and (< digit-count 17)
            (let ((digit 1)
                  minimum)
              (while (<= digit 9)
                (let* ((mantissa (concat token (string (+ ?0 digit))))
                       (exponent-minimum
                        (epi-ledger--canonical-scientific-prefix-witness-minimum
                         mantissa mantissa checkpoint)))
                  (when exponent-minimum
                    (setq minimum
                          (min (or minimum most-positive-fixnum)
                               (1+ exponent-minimum)))))
                (setq digit (1+ digit)))
              minimum))))))

(defun epi-ledger--incomplete-number-prefix-minimum (token)
  "Return a lower bound on bytes completing canonical number TOKEN, or nil."
  (let ((case-fold-search nil)
        (scientific-mantissa "-?[1-9]\\(?:\\.[0-9]*[1-9]\\)?"))
    (or (and (equal token "-") 1)
        (and (equal token "-0") 2)
        (let ((checkpoint (epi-ledger--make-numeric-work-checkpoint)))
          (or
           (and (string-match-p "\\`-?[1-9][0-9]*\\'" token)
                (epi-ledger--canonical-integer-prefix-witness-minimum
                 token checkpoint))
           (and (string-match
                 "\\`-?\\(0\\|[1-9][0-9]*\\)\\.\\([0-9]*\\)\\'" token)
                (epi-ledger--canonical-decimal-prefix-witness-minimum
                 token checkpoint))
           (and (string-match-p "\\`-?[1-9]\\(?:\\.[0-9]*\\)?\\'" token)
                (epi-ledger--canonical-mantissa-prefix-witness-minimum
                 token checkpoint))
           (and (string-match
                 (concat "\\`" scientific-mantissa
                         "e\\([+-]?\\)\\([0-9]*\\)\\'")
                 token)
                (epi-ledger--canonical-scientific-prefix-witness-minimum
                 token (substring token 0 (string-match "e" token))
                 checkpoint)))))))

(defun epi-ledger--incomplete-number-prefix-p (token)
  "Return whether TOKEN is a proper prefix of a canonical JCS number."
  (not (null (epi-ledger--incomplete-number-prefix-minimum token))))

(defun epi-ledger--lex-number (state)
  "Scan and verify one canonical JSON number from STATE."
  (let ((start (epi-ledger--lex-state-position state)))
    (while (let ((byte (epi-ledger--lex-peek state)))
             (and byte (or (<= ?0 byte ?9) (memq byte '(?- ?+ ?. ?e ?E)))))
      (epi-ledger--lex-byte state)
      (when (> (- (epi-ledger--lex-state-position state) start)
               epi-ledger--maximum-canonical-number-byte-length)
        (epi-ledger--lex-invalid state 'noncanonical-number)))
    (when (= start (epi-ledger--lex-state-position state))
      (epi-ledger--lex-invalid state 'number-required))
    (let ((end (epi-ledger--lex-state-position state)))
      (epi-ledger--lex-flush-work state)
      (let* ((token
              (epi-ledger--source-copy-range
               (epi-ledger--lex-state-bytes state) start end 'json-number
               (epi-ledger--lex-state-work state)))
           (at-end (= end
                      (epi-ledger--lex-state-length state)))
           (value (condition-case nil
                      (json-parse-string token)
                    (error nil)))
           minimum-completion)
      ;; Canonical IEEE-754 floats can use an integer spelling outside Epi's
      ;; safe-integer range (for example 2^53).  The spelling itself proves
      ;; float provenance because writers reject such integer inputs.
      (when (and (integerp value)
                 (> (abs value) epi-ledger--maximum-safe-integer))
        (setq value
              (condition-case nil
                  (let ((float (float value)))
                    (and (epi--finite-number-p float) float))
                (error nil))))
      (cond
       ((and (numberp value)
             (equal token
                    (encode-coding-string
                     (epi-ledger--jcs-number value) 'utf-8-unix))))
       ((and at-end
             (setq minimum-completion
                   (epi-ledger--incomplete-number-prefix-minimum token)))
        (epi-ledger--lex-incomplete
         state 'incomplete-number minimum-completion))
       ((not (numberp value))
        (epi-ledger--lex-invalid state 'invalid-number))
       (t
        (epi-ledger--lex-invalid state 'noncanonical-number)))))))

(defun epi-ledger--lex-literal (state literal)
  "Consume ASCII LITERAL from STATE."
  (dotimes (index (length literal))
    (when (null (epi-ledger--lex-peek state))
      (epi-ledger--lex-incomplete state 'unexpected-end-of-json
                                  (- (length literal) index)))
    (epi-ledger--lex-expect state (aref literal index) 'invalid-literal)))

(defun epi-ledger--lex-value (state)
  "Scan one canonical JSON value from STATE."
  (pcase (epi-ledger--lex-peek state)
    (?\" (epi-ledger--lex-string state nil))
    (?{ (epi-ledger--lex-object state))
    (?\[ (epi-ledger--lex-array state))
    (?t (epi-ledger--lex-literal state "true"))
    (?f (epi-ledger--lex-literal state "false"))
    (?n (epi-ledger--lex-literal state "null"))
    ((or (pred (lambda (byte) (and byte (<= ?0 byte ?9)))) ?-)
     (epi-ledger--lex-number state))
    (_ (if (null (epi-ledger--lex-peek state))
           (epi-ledger--lex-incomplete state 'value-required)
         (epi-ledger--lex-invalid state 'value-required)))))

(defun epi-ledger--lex-object (state)
  "Scan one canonical JSON object from STATE."
  (epi-ledger--lex-enter state)
  (epi-ledger--lex-expect state ?{ 'object-required)
  (cond
   ((eq (epi-ledger--lex-peek state) ?})
    (epi-ledger--lex-byte state))
   ((null (epi-ledger--lex-peek state))
    (epi-ledger--lex-incomplete state 'object-key-required 1))
   (t
    (let (previous done)
      (while (not done)
        (when (>= (epi-ledger--lex-state-items state) epi-json-item-limit)
          (epi-ledger--lex-invalid state 'json-item-limit))
        (when (null (epi-ledger--lex-peek state))
          (epi-ledger--lex-flush-work state)
          (epi-ledger--lex-incomplete
           state 'object-key-required
           (+ 5 (if previous
                    (epi-ledger--key-successor-content-byte-cost
                     "" previous (epi-ledger--lex-state-work state))
                  0))))
        (unless (eq (epi-ledger--lex-peek state) ?\")
          (epi-ledger--lex-invalid state 'object-key-required))
        (let ((sort-key
               (epi-ledger--lex-with-completion
                state 3
                (lambda () (epi-ledger--lex-string state t previous)))))
          (when previous
            (epi-ledger--lex-flush-work state)
            (pcase (epi-ledger--sort-key-compare
                    previous sort-key (epi-ledger--lex-state-work state))
             (0
              (epi-ledger--lex-invalid state 'duplicate-key))
             (1 (epi-ledger--lex-invalid state 'unsorted-key))))
          (setq previous sort-key))
        (epi-ledger--lex-with-completion
         state 2
         (lambda ()
           (epi-ledger--lex-expect state ?: 'object-colon-required)))
        (epi-ledger--lex-count-item state)
        (epi-ledger--lex-with-completion
         state 1 (lambda () (epi-ledger--lex-value state)))
        (when (null (epi-ledger--lex-peek state))
          (epi-ledger--lex-incomplete state 'unexpected-end-of-json 1))
        (pcase (epi-ledger--lex-byte state)
          (?, nil)
          (?} (setq done t))
          (_ (epi-ledger--lex-invalid state 'object-delimiter-required)))))))
  (cl-decf (epi-ledger--lex-state-depth state)))

(defun epi-ledger--lex-array (state)
  "Scan one canonical JSON array from STATE."
  (epi-ledger--lex-enter state)
  (epi-ledger--lex-expect state ?\[ 'array-required)
  (cond
   ((eq (epi-ledger--lex-peek state) ?\])
    (epi-ledger--lex-byte state))
   ((null (epi-ledger--lex-peek state))
    (epi-ledger--lex-incomplete state 'value-required 1))
   (t
    (let (done)
      (while (not done)
        (epi-ledger--lex-count-item state)
        (epi-ledger--lex-with-completion
         state 1 (lambda () (epi-ledger--lex-value state)))
        (when (null (epi-ledger--lex-peek state))
          (epi-ledger--lex-incomplete state 'unexpected-end-of-json 1))
        (pcase (epi-ledger--lex-byte state)
          (?, nil)
          (?\] (setq done t))
          (_ (epi-ledger--lex-invalid state 'array-delimiter-required)))))))
  (cl-decf (epi-ledger--lex-state-depth state)))

(defun epi-ledger--jcs-lex-result (bytes)
  "Return lexical validation result plist for unibyte JSON source BYTES."
  (unless (or (epi-ledger--source-region-p bytes)
              (and (stringp bytes) (not (multibyte-string-p bytes))))
    (epi-ledger--format-fail 'unibyte-json-required))
  (epi-ledger--with-operation-work-state
    (let* ((length (epi-ledger--source-length bytes))
           (clock-check-byte-interval
            (max 1 (min epi-ledger--lex-clock-check-byte-interval
                        epi-ledger-work-byte-limit)))
           (state
            (epi-ledger--make-lex-state
             :bytes bytes :length length :position 0 :depth 0
             :items 0 :work (epi-ledger--make-work-state)
             :charged-position 0
             :next-check-position clock-check-byte-interval
             :completion-bytes 0))
           (result
            (or
             (catch 'epi-ledger--lex-stop
               (epi-ledger--lex-value state)
               (if (= (epi-ledger--lex-state-position state) length)
                   (list :kind 'complete :code 'ok :offset length)
                 (list :kind 'invalid :code 'trailing-json-data
                       :offset (epi-ledger--lex-state-position state))))
             (list :kind 'invalid :code 'internal-lexical-error :offset 0))))
      (epi-ledger--lex-flush-work state)
      result)))

(defun epi-ledger--jcs-validate-bytes (bytes &optional offset-origin)
  "Validate canonical JCS BYTES and return non-nil.
This lexical pass never materializes decoded values.  Optional OFFSET-ORIGIN
is added to reported byte offsets."
  (let ((result (epi-ledger--jcs-lex-result bytes)))
    (unless (eq (plist-get result :kind) 'complete)
      (epi-ledger--format-fail (plist-get result :code)
                               :offset (+ (or offset-origin 0)
                                          (plist-get result :offset))))
    t))

(defun epi-ledger--normalize-decoded-numbers (value)
  "Normalize native decoded JSON VALUE to Epi's canonical Lisp shape."
  (cond
   ((and (integerp value)
         (> (abs value) epi-ledger--maximum-safe-integer))
    (let ((float
           (condition-case nil
               (float value)
             (error nil))))
      (unless (and float (epi--finite-number-p float))
        (epi-ledger--format-fail 'number-out-of-range :field 'number))
      float))
   ((hash-table-p value)
    (let (object)
      (maphash
       (lambda (key child)
         (unless (stringp key)
           (epi-ledger--format-fail 'invalid-json-object-key))
         (push (cons key (epi-ledger--normalize-decoded-numbers child))
               object))
       value)
      object))
   ((vectorp value)
    (dotimes (index (length value))
      (aset value index
            (epi-ledger--normalize-decoded-numbers (aref value index))))
    value)
   ((consp value)
    (dolist (entry value)
      (setcdr entry
              (epi-ledger--normalize-decoded-numbers (cdr entry))))
    value)
   (t value)))

(defvar epi-ledger--nonpreemptible-observer nil
  "Optional private observer for bounded nonpreemptible ledger operations.
When non-nil, it is called with an ownership-isolated, redacted event plist.
Observer errors are ignored and cannot affect the observed operation.")

(defun epi-ledger--run-nonpreemptible (kind field bytes thunk)
  "Run THUNK as measured KIND work for FIELD over BYTES bytes.
The operation is bracketed by cooperative yields.  Report only bounded,
  redacted metadata through `epi-ledger--nonpreemptible-observer'."
  (epi-ledger--work-yield)
  (let ((started-at (epi--deadline-time))
        (outcome 'error))
    (unwind-protect
        (prog1 (funcall thunk)
          (setq outcome 'success))
      (let* ((elapsed (max 0.0 (- (epi--deadline-time) started-at)))
             (event (list :kind kind
                          :field (if (or (symbolp field) (stringp field))
                                     (epi-ledger--owned-string field)
                                   'unknown)
                          :bytes bytes
                          :elapsed elapsed
                          :outcome outcome
                          :exceptional (> elapsed
                                          epi-ledger-work-time-budget))))
        (epi-ledger--work-yield)
        (when epi-ledger--nonpreemptible-observer
          (condition-case nil
              (funcall epi-ledger--nonpreemptible-observer
                       (copy-tree event t))
            (error nil)))))))

(defun epi-ledger--run-bounded-unit (kind field bytes work thunk)
  "Run THUNK over BYTES bytes, charging WORK or measuring KIND and FIELD."
  (if (> bytes epi-ledger-work-byte-limit)
      (epi-ledger--run-nonpreemptible kind field bytes thunk)
    (epi-ledger--work-charge work bytes)
    (funcall thunk)))

(defun epi-ledger--work-equal (left right field work)
  "Compare LEFT and RIGHT after reserving or measuring equality work.
FIELD identifies a measured comparison and WORK receives bounded charges."
  (if (and (stringp left) (stringp right))
      (let ((bytes (max (string-bytes left) (string-bytes right))))
        (epi-ledger--run-bounded-unit
         'compare field bytes work (lambda () (equal left right))))
    (epi-ledger--work-charge work 1)
    (equal left right)))

(defun epi-ledger--decode-json (bytes)
  "Decode size-checked canonical UTF-8 BYTES as string-keyed data."
  (when (> (length bytes) epi-record-decode-byte-limit)
    (epi-ledger--limit-fail 'record-decode-byte-limit
                            :limit epi-record-decode-byte-limit))
  (epi-ledger--run-nonpreemptible
   'decode 'record-json (length bytes)
   (lambda ()
     (let ((decoded
             (condition-case nil
                 (json-parse-string
                  (decode-coding-string bytes 'utf-8-unix t)
                  :object-type 'hash-table
                  :array-type 'array
                  :null-object epi-json-null
                  :false-object epi-json-false)
               (error (epi-ledger--format-fail 'invalid-json)))))
       (epi-ledger--normalize-decoded-numbers decoded)))))

(defun epi-ledger--hash (bytes field)
  "Return SHA-256 of bounded unibyte BYTES used for FIELD."
  (unless (and (stringp bytes) (not (multibyte-string-p bytes)))
    (epi-ledger--format-fail 'unibyte-hash-input-required :field field))
  (when (> (length bytes) epi-hash-input-byte-limit)
    (epi-ledger--limit-fail 'hash-input-byte-limit
                            :field field :limit epi-hash-input-byte-limit))
  (epi-ledger--run-nonpreemptible
   'hash field (length bytes)
   (lambda () (secure-hash 'sha256 bytes))))

(defun epi-ledger--schema (type)
  "Return the schema descriptor for record TYPE, or fail closed."
  (or (assq type epi-ledger--record-schemas)
      (epi-ledger--format-fail 'unknown-record-type :type type)))

(defun epi-ledger--validate-message-content (role content)
  "Validate message ROLE and typed CONTENT vector."
  (unless (member role '("user" "assistant" "tool"))
    (epi-ledger--format-fail 'invalid-role :field "role"))
  (unless (vectorp content)
    (epi-ledger--format-fail 'array-required :field "content"))
  (unless (= (length content) 1)
    (epi-ledger--format-fail 'invalid-content-count :field "content"))
  (let ((item (aref content 0)))
    (epi-ledger--object-keys item "content")
    (let ((content-type (epi-ledger--object-value item "type")))
      (unless (member content-type '("text" "tool-call" "tool-result"))
        (epi-ledger--format-fail 'unknown-content-type :field "content"))
      (unless (pcase role
                ("user" (equal content-type "text"))
                ("assistant" (member content-type '("text" "tool-call")))
                ("tool" (equal content-type "tool-result")))
        (epi-ledger--format-fail 'role-content-mismatch :field "content"))))
  (seq-doseq (item content)
    (let ((type (epi-ledger--object-value item "type")))
      (pcase type
        ("text"
         (epi-ledger--closed-object item '("type" "text") nil "content")
         (epi-ledger--require-string
          (epi-ledger--object-value item "text") "text"))
        ("tool-call"
         (epi-ledger--closed-object
          item '("type" "call_id" "name" "arguments" "order" "group_id")
          nil "content")
         (unless (equal role "assistant")
           (epi-ledger--format-fail 'role-content-mismatch :field "content"))
         (epi-ledger--require-string
          (epi-ledger--object-value item "call_id") "call_id" t)
         (epi-ledger--require-string
          (epi-ledger--object-value item "name") "name" t)
         (epi-ledger--object-keys
          (epi-ledger--object-value item "arguments") "arguments")
         (epi-ledger--require-nonnegative-integer
          (epi-ledger--object-value item "order") "order")
         (unless (eq (epi-ledger--object-value item "group_id")
                     epi-json-null)
           (epi-ledger--format-fail 'null-required :field "group_id")))
        ("tool-result"
         (epi-ledger--closed-object
          item '("type" "call_id" "name" "result" "status") nil "content")
         (unless (equal role "tool")
           (epi-ledger--format-fail 'role-content-mismatch :field "content"))
         (dolist (field '("call_id" "name" "result"))
           (epi-ledger--require-string
            (epi-ledger--object-value item field) field
            (not (equal field "result"))))
         (unless (member (epi-ledger--object-value item "status")
                         '("success" "error" "denied"))
           (epi-ledger--format-fail 'invalid-status :field "status")))
        (_ (epi-ledger--format-fail 'unknown-content-type
                                    :field "content"))))))

(defun epi-ledger--validate-object-ref (value)
  "Validate canonical recovery fragment object reference VALUE."
  (epi-ledger--closed-object
   value '("hash" "size" "media_type" "role") nil "fragment_object")
  (epi-ledger--require-hash
   (epi-ledger--object-value value "hash") "fragment_object.hash")
  (epi-ledger--require-nonnegative-integer
   (epi-ledger--object-value value "size") "fragment_object.size")
  (when (> (epi-ledger--object-value value "size") epi-object-byte-limit)
    (epi-ledger--limit-fail 'object-byte-limit
                            :field "fragment_object.size"
                            :limit epi-object-byte-limit))
  (epi-ledger--require-string
   (epi-ledger--object-value value "media_type")
   "fragment_object.media_type" t)
  (unless (equal (epi-ledger--object-value value "media_type")
                 "application/octet-stream")
    (epi-ledger--format-fail
     'invalid-media-type :field "fragment_object.media_type"))
  (unless (equal (epi-ledger--object-value value "role")
                 "recovery-fragment")
    (epi-ledger--format-fail 'invalid-role :field "fragment_object.role")))

(defun epi-ledger--validate-payload (type payload &optional skip-paths)
  "Validate the closed schema-one PAYLOAD for record TYPE.
When SKIP-PATHS is non-nil, defer handler-capable path checks until after
ownership isolation."
  (let* ((schema (epi-ledger--schema type))
         (required (plist-get (cdr schema) :required-payload))
         (optional (plist-get (cdr schema) :optional-payload)))
    (epi-ledger--closed-object payload required optional "payload")
    (pcase type
      ('session-info
       (epi-ledger--require-uuid
        (epi-ledger--object-value payload "session_id") "session_id")
       (dolist (field '("working_directory" "base_system_prompt"
                        "backend" "model" "capability"))
         (epi-ledger--require-string
          (epi-ledger--object-value payload field) field
          (member field '("working_directory" "backend" "model"
                          "capability"))))
       (unless skip-paths
         (epi-ledger--require-canonical-directory
          (epi-ledger--object-value payload "working_directory")
          "working_directory"))
       (epi-ledger--object-keys
        (epi-ledger--object-value payload "request_params") "request_params")
       (unless (vectorp (epi-ledger--object-value payload "tools"))
         (epi-ledger--format-fail 'array-required :field "tools"))
       (unless (equal
                (epi-ledger--object-value payload "capability")
                "openai-chat-completions/sequential-tools-v1")
         (epi-ledger--format-fail 'unsupported-capability
                                  :field "capability")))
      ('operation-started
       (epi-ledger--require-uuid
        (epi-ledger--object-value payload "operation_id") "operation_id")
       (epi-ledger--require-string
        (epi-ledger--object-value payload "kind") "kind" t))
      ('turn-started
       (dolist (field '("turn_id" "operation_id" "attempt_id" "message_id"))
         (epi-ledger--require-uuid
          (epi-ledger--object-value payload field) field))
       (dolist (field '("working_directory" "base_system_prompt"
                        "system_prompt" "backend" "model"))
         (epi-ledger--require-string
          (epi-ledger--object-value payload field) field
          (member field '("working_directory" "backend" "model"))))
       (unless skip-paths
         (epi-ledger--require-canonical-directory
          (epi-ledger--object-value payload "working_directory")
          "working_directory"))
       (dolist (field '("resources" "tools"))
         (unless (vectorp (epi-ledger--object-value payload field))
           (epi-ledger--format-fail 'array-required :field field)))
       (epi-ledger--object-keys
        (epi-ledger--object-value payload "request_params") "request_params")
       (epi-ledger--require-hash
        (epi-ledger--object-value payload "snapshot_hash") "snapshot_hash"))
      ('message
       (let ((role (epi-ledger--object-value payload "role")))
         (epi-ledger--require-string role "role" t)
         (epi-ledger--validate-message-content
          role (epi-ledger--object-value payload "content"))))
      ('reasoning
       (epi-ledger--require-string
        (epi-ledger--object-value payload "text") "text")
       (epi-ledger--require-nonnegative-integer
        (epi-ledger--object-value payload "leg") "leg")
       (unless (eq (epi-ledger--object-value payload "replay") epi-json-false)
         (epi-ledger--format-fail 'false-required :field "replay")))
      ('leaf nil)
      ('tool-planned
       (dolist (field '("call_id" "name"))
         (epi-ledger--require-string
          (epi-ledger--object-value payload field) field t))
       (dolist (field '("arguments" "authority"))
         (epi-ledger--object-keys
          (epi-ledger--object-value payload field) field))
       (epi-ledger--require-nonnegative-integer
        (epi-ledger--object-value payload "order") "order"))
      ('tool-approved
       (epi-ledger--require-string
        (epi-ledger--object-value payload "call_id") "call_id" t)
       (epi-ledger--object-keys
        (epi-ledger--object-value payload "policy") "policy")
       (when (epi-ledger--object-has-key-p payload "approved_diff_sha256")
         (epi-ledger--require-hash
          (epi-ledger--object-value payload "approved_diff_sha256")
          "approved_diff_sha256")))
      ('tool-denied
       (dolist (field '("call_id" "reason" "model_result"))
         (epi-ledger--require-string
          (epi-ledger--object-value payload field) field
          (not (equal field "model_result")))))
      ('tool-started
       (dolist (field '("call_id" "tool_version"))
         (epi-ledger--require-string
          (epi-ledger--object-value payload field) field t)))
      ('tool-finished
       (epi-ledger--require-string
        (epi-ledger--object-value payload "call_id") "call_id" t)
       (let ((status (epi-ledger--object-value payload "status")))
         (unless (member status '("success" "error" "cancelled"
                                  "timeout" "uncertain"))
           (epi-ledger--format-fail 'invalid-status :field "status"))
         (epi-ledger--object-keys
          (epi-ledger--object-value payload "details") "details")
         (if (equal status "uncertain")
             (when (epi-ledger--object-has-key-p payload "model_result")
               (epi-ledger--format-fail 'forbidden-key
                                        :field "model_result"))
           (unless (epi-ledger--object-has-key-p payload "model_result")
             (epi-ledger--format-fail 'missing-key
                                      :field "model_result"))
           (epi-ledger--require-string
            (epi-ledger--object-value payload "model_result")
            "model_result"))))
      ((or 'turn-finished 'turn-failed 'turn-cancelled 'turn-interrupted)
       (epi-ledger--require-uuid
        (epi-ledger--object-value payload "turn_id") "turn_id")
       (pcase type
         ('turn-finished
          (unless (equal (epi-ledger--object-value payload "status")
                         "success")
            (epi-ledger--format-fail 'invalid-status :field "status")))
         ('turn-failed
          (epi-ledger--require-string
           (epi-ledger--object-value payload "code") "code" t)
          (epi-ledger--object-keys
           (epi-ledger--object-value payload "details") "details"))
         (_
          (epi-ledger--require-string
           (epi-ledger--object-value payload "reason") "reason" t))))
      ((or 'operation-finished 'operation-failed 'operation-cancelled
           'operation-interrupted)
       (epi-ledger--require-uuid
        (epi-ledger--object-value payload "operation_id") "operation_id")
       (pcase type
         ('operation-finished
          (unless (equal (epi-ledger--object-value payload "status")
                         "success")
            (epi-ledger--format-fail 'invalid-status :field "status")))
         ('operation-failed
          (epi-ledger--require-string
           (epi-ledger--object-value payload "code") "code" t)
          (epi-ledger--object-keys
           (epi-ledger--object-value payload "details") "details"))
         (_
          (epi-ledger--require-string
           (epi-ledger--object-value payload "reason") "reason" t))))
      ('recovery-origin
       (unless skip-paths
         (epi-ledger--require-canonical-absolute-file
          (epi-ledger--object-value payload "source_path") "source_path"))
       (epi-ledger--require-uuid
        (epi-ledger--object-value payload "source_session_id")
        "source_session_id")
       (dolist (field '("source_file_size" "fragment_offset" "fragment_size"))
         (epi-ledger--require-nonnegative-integer
          (epi-ledger--object-value payload field) field))
       (let ((source-size
              (epi-ledger--object-value payload "source_file_size"))
             (fragment-offset
              (epi-ledger--object-value payload "fragment_offset"))
             (fragment-size
              (epi-ledger--object-value payload "fragment_size")))
         (unless (> fragment-size 0)
           (epi-ledger--format-fail 'empty-recovery-fragment
                                    :field "fragment_size"))
         (unless (and (<= fragment-offset source-size)
                      (= (+ fragment-offset fragment-size) source-size))
           (epi-ledger--format-fail 'recovery-fragment-range-mismatch)))
       (when (> (epi-ledger--object-value payload "fragment_size")
                epi-recovery-fragment-byte-limit)
         (epi-ledger--limit-fail 'recovery-fragment-byte-limit
                                 :field "fragment_size"
                                 :limit epi-recovery-fragment-byte-limit))
       (dolist (field '("source_header_sha256"
                        "source_valid_prefix_head_sha256" "fragment_sha256"
                        "destination_valid_prefix_head_sha256"
                        "source_evidence_sha256"))
         (epi-ledger--require-hash
          (epi-ledger--object-value payload field) field))
       (let ((object (epi-ledger--object-value payload "fragment_object")))
         (epi-ledger--validate-object-ref object)
         (unless (= (epi-ledger--object-value payload "fragment_size")
                    (epi-ledger--object-value object "size"))
           (epi-ledger--format-fail 'fragment-size-mismatch))
         (unless (equal (epi-ledger--object-value payload "fragment_sha256")
                        (epi-ledger--object-value object "hash"))
           (epi-ledger--format-fail 'fragment-hash-mismatch)))))))

(defun epi-ledger--envelope (record)
  "Return canonical envelope data for RECORD without retaining a copy."
  (let ((result
         `(("id" . ,(epi-record--raw-id record))
           ("type" . ,(symbol-name (epi-record--raw-type record)))
           ("schema" . ,(epi-record--raw-schema record))
           ("at" . ,(epi-record--raw-at record))
           ("previous_hash" . ,(epi-record--raw-previous-hash record)))))
    (dolist (slot '((parent . "parent") (target . "target")
                    (turn . "turn") (operation . "operation")))
      (let ((value (pcase (car slot)
                     ('parent (epi-record--raw-parent record))
                     ('target (epi-record--raw-target record))
                     ('turn (epi-record--raw-turn record))
                     ('operation (epi-record--raw-operation record)))))
        (when value
          (setq result (append result (list (cons (cdr slot) value)))))))
    (append result
            (list (cons "payload" (epi-record--raw-payload record))))))

(defun epi-ledger--validate-envelope-presence (envelope type)
  "Validate ENVELOPE reference-field presence and values for record TYPE."
  (let* ((schema (epi-ledger--schema type))
         (required (plist-get (cdr schema) :required-envelope))
         (optional (plist-get (cdr schema) :optional-envelope)))
    (dolist (field '(parent target turn operation))
      (let* ((key (symbol-name field))
             (present (epi-ledger--object-has-key-p envelope key))
             (value (and present (epi-ledger--object-value envelope key))))
        (cond
         ((memq field required)
          (unless present
            (epi-ledger--format-fail 'missing-envelope-field :field field))
          (epi-ledger--require-uuid value field))
         ((memq field optional)
          (when present (epi-ledger--require-uuid value field)))
         (present
          (epi-ledger--format-fail
           'forbidden-envelope-field :field field)))))))

(defun epi-ledger--validate-record-fields (record &optional skip-paths)
  "Validate the envelope and closed payload of RECORD.
SKIP-PATHS defers handler-capable path checks for caller-owned values."
  (epi-ledger--require-uuid (epi-record--raw-id record) "id")
  (unless (eq (epi-record--raw-schema record) 1)
    (epi-ledger--format-fail
     'unknown-schema :schema (epi-record--raw-schema record)))
  (unless (epi-ledger--timestamp-p (epi-record--raw-at record))
    (epi-ledger--format-fail 'invalid-timestamp :field "at"))
  (epi-ledger--require-hash
   (epi-record--raw-previous-hash record) "previous_hash")
  (let* ((schema (epi-ledger--schema (epi-record--raw-type record)))
         (required (plist-get (cdr schema) :required-envelope))
         (optional (plist-get (cdr schema) :optional-envelope)))
    (dolist (field '(parent target turn operation))
      (let ((value (pcase field
                     ('parent (epi-record--raw-parent record))
                     ('target (epi-record--raw-target record))
                     ('turn (epi-record--raw-turn record))
                     ('operation (epi-record--raw-operation record)))))
        (cond
         ((memq field required)
          (unless value
            (epi-ledger--format-fail 'missing-envelope-field :field field))
          (epi-ledger--require-uuid value field))
         ((memq field optional)
          (when value (epi-ledger--require-uuid value field)))
         (value
          (epi-ledger--format-fail 'forbidden-envelope-field :field field)))))
    (epi-ledger--validate-payload
     (epi-record--raw-type record) (epi-record--raw-payload record)
     skip-paths))
  (pcase (epi-record--raw-type record)
    ((or 'operation-started 'operation-finished 'operation-failed
         'operation-cancelled 'operation-interrupted)
     (unless (equal (epi-record--raw-operation record)
                    (epi-ledger--object-value
                     (epi-record--raw-payload record) "operation_id"))
       (epi-ledger--format-fail 'operation-id-mismatch)))
    ((or 'turn-finished 'turn-failed 'turn-cancelled 'turn-interrupted)
     (unless (equal (epi-record--raw-turn record)
                    (epi-ledger--object-value
                     (epi-record--raw-payload record) "turn_id"))
       (epi-ledger--format-fail 'turn-id-mismatch)))
    ('turn-started
     (unless (and (equal (epi-record--raw-turn record)
                         (epi-ledger--object-value
                          (epi-record--raw-payload record) "turn_id"))
                  (equal (epi-record--raw-operation record)
                         (epi-ledger--object-value
                          (epi-record--raw-payload record) "operation_id")))
       (epi-ledger--format-fail 'lifecycle-id-mismatch))))
  record)

(defun epi-ledger--snapshot-header-inputs
    (session-id created-at project-root)
  "Capture SESSION-ID, CREATED-AT, and PROJECT-ROOT without callbacks."
  (let ((gc-cons-threshold most-positive-fixnum))
    (unless (stringp session-id)
      (epi-ledger--format-fail 'invalid-id :field "session_id"))
    (unless (stringp created-at)
      (epi-ledger--format-fail 'invalid-timestamp :field "created_at"))
    (unless (stringp project-root)
      (epi-ledger--format-fail 'invalid-string :field "project_root"))
    (when (string-empty-p project-root)
      (epi-ledger--format-fail 'empty-string :field "project_root"))
    (dolist (entry `(("session_id" . ,session-id)
                     ("created_at" . ,created-at)
                     ("project_root" . ,project-root)))
      (when (> (string-bytes (cdr entry)) epi-header-value-byte-limit)
        (epi-ledger--limit-fail
         'header-value-byte-limit :field (car entry)
         :limit epi-header-value-byte-limit)))
    (let ((lower-size
           (cl-loop
            for (prefix . value)
            in `(("#+title: " . "Epi session")
                 ("#+EPI_FORMAT: " . "1")
                 ("#+EPI_SESSION_ID: " . ,session-id)
                 ("#+EPI_CREATED_AT: " . ,created-at)
                 ("#+EPI_PROJECT_ROOT: " . ,project-root)
                 ("#+EPI_CODING_SYSTEM: " . "utf-8-unix")
                 ("#+EPI_HEADER_SHA256: " . ,(make-string 64 ?0)))
            sum (+ (length prefix) 1 (length value)))))
      (when (> lower-size epi-record-frame-byte-limit)
        (epi-ledger--limit-fail
         'header-byte-limit :limit epi-record-frame-byte-limit)))
    (epi-ledger--snapshot-canonical-value
     `(("title" . "Epi session") ("format" . 1)
       ("session_id" . ,session-id)
       ("created_at" . ,created-at)
       ("project_root" . ,project-root)
       ("coding_system" . "utf-8-unix"))
     epi-record-frame-byte-limit 'header-byte-limit)))

(cl-defun epi-ledger-seal-header (&key session-id created-at project-root)
  "Seal and return a version-one header.
SESSION-ID is a UUID, CREATED-AT uses Epi's RFC 3339 profile, and PROJECT-ROOT
is canonical."
  (epi-ledger--with-operation-work-state
   (let* ((object
          (epi-ledger--snapshot-header-inputs
           session-id created-at project-root))
         (_preflight
          (epi-ledger--preflight-canonical-value
           object epi-record-frame-byte-limit 'header-byte-limit))
         (owned-session-id
          (epi-ledger--object-value object "session_id"))
         (owned-created-at
          (epi-ledger--object-value object "created_at"))
         (owned-project-root
          (epi-ledger--object-value object "project_root")))
    (let ((epi-ledger--canonical-value-preflighted t))
      (epi-ledger--require-uuid owned-session-id "session_id")
      (unless (epi-ledger--timestamp-p owned-created-at)
        (epi-ledger--format-fail 'invalid-timestamp :field "created_at"))
      (let ((rendered-size
             (epi-ledger--header-rendered-byte-size
              owned-session-id owned-created-at owned-project-root)))
        (when (> rendered-size epi-record-frame-byte-limit)
          (epi-ledger--limit-fail
           'header-byte-limit :limit epi-record-frame-byte-limit)))
      ;; File-name handlers see only owned values after exact preflight.
      (epi-ledger--require-canonical-directory
       owned-project-root "project_root")
      (let* ((json (epi-ledger--jcs-encode
                    object epi-record-frame-byte-limit t))
             (hash (epi-ledger--hash json 'header)))
        (epi-ledger--make-header
         :title "Epi session" :format 1
         :session-id owned-session-id
         :created-at owned-created-at
         :project-root owned-project-root
         :coding-system "utf-8-unix" :hash hash))))))

(defun epi-ledger--utf8-byte-length (value field &optional work-state)
  "Return the exact UTF-8 byte length of canonical string VALUE for FIELD.
Optional WORK-STATE receives the scan charge."
  (let ((work (or work-state (epi-ledger--make-work-state))))
    (epi-ledger--canonical-string value field work)
    (if (not (multibyte-string-p value))
        (progn
          (let ((remaining (length value))
                (chunk-size
                 (max 1 (min 65536 epi-ledger-work-byte-limit))))
            (while (> remaining 0)
              (let ((amount (min remaining chunk-size)))
                (epi-ledger--work-charge work amount)
                (setq remaining (- remaining amount)))))
          (length value))
      (let ((total 0))
        (dotimes (index (length value))
          (epi-ledger--work-charge work 1)
          (let* ((character (aref value index))
                 (amount
                  (cond ((<= character #x7f) 1)
                        ((<= character #x7ff) 2)
                        ((<= character #xffff) 3)
                        (t 4))))
            (setq total (+ total amount))
            (epi-ledger--work-charge-count work (1- amount))))
        total))))

(defun epi-ledger--header-rendered-byte-size
    (session-id created-at project-root)
  "Return exact header bytes for SESSION-ID, CREATED-AT, and PROJECT-ROOT."
  (let ((work (epi-ledger--make-work-state)))
    (cl-loop
     for (prefix . value)
     in `(("#+title: " . "Epi session")
          ("#+EPI_FORMAT: " . "1")
          ("#+EPI_SESSION_ID: " . ,session-id)
          ("#+EPI_CREATED_AT: " . ,created-at)
          ("#+EPI_PROJECT_ROOT: " . ,project-root)
          ("#+EPI_CODING_SYSTEM: " . "utf-8-unix")
          ("#+EPI_HEADER_SHA256: " . ,(make-string 64 ?0)))
     sum (+ (length prefix) 1
            (epi-ledger--utf8-byte-length
             value 'header-value work)))))

(defun epi-ledger--utf8-byte-length-no-callback (value field)
  "Return VALUE's exact UTF-8 byte length without callbacks for FIELD."
  (unless (stringp value)
    (epi-ledger--format-fail 'invalid-string :field field))
  (let ((multibyte (multibyte-string-p value))
        (total 0))
    (dotimes (index (length value))
      (let ((character (aref value index)))
        (unless (if multibyte
                    (and (<= character #x10ffff)
                         (not (<= #xd800 character #xdfff)))
                  (<= character #x7f))
          (epi-ledger--format-fail 'invalid-string :field field))
        (setq total
              (+ total
                 (cond ((<= character #x7f) 1)
                       ((<= character #x7ff) 2)
                       ((<= character #xffff) 3)
                       (t 4))))))
    total))

(defun epi-ledger--header-rendered-byte-size-no-callback
    (session-id created-at project-root)
  "Return header bytes for SESSION-ID, CREATED-AT, and PROJECT-ROOT.
Perform the exact sizing without invoking any callback."
  (cl-loop
   for (prefix . value)
   in `(("#+title: " . "Epi session")
        ("#+EPI_FORMAT: " . "1")
        ("#+EPI_SESSION_ID: " . ,session-id)
        ("#+EPI_CREATED_AT: " . ,created-at)
        ("#+EPI_PROJECT_ROOT: " . ,project-root)
        ("#+EPI_CODING_SYSTEM: " . "utf-8-unix")
        ("#+EPI_HEADER_SHA256: " . ,(make-string 64 ?0)))
   sum (+ (length prefix) 1
          (epi-ledger--utf8-byte-length-no-callback
           value 'header-value))))

(defun epi-ledger-render-header (header)
  "Return exact UTF-8/LF framing bytes for sealed HEADER."
  (epi-ledger--with-operation-work-state
    (unless (epi-header-p header)
      (epi-ledger--format-fail 'header-required))
    (let* ((title (epi-header--raw-title header))
           (format-text (number-to-string (epi-header--raw-format header)))
           (session-id (epi-header--raw-session-id header))
           (created-at (epi-header--raw-created-at header))
           (project-root (epi-header--raw-project-root header))
           (coding-system (epi-header--raw-coding-system header))
           (hash (epi-header--raw-hash header))
           (work (epi-ledger--make-work-state))
           (byte-size
            (+ (length "#+title: \n")
               (length "#+EPI_FORMAT: \n")
               (length "#+EPI_SESSION_ID: \n")
               (length "#+EPI_CREATED_AT: \n")
               (length "#+EPI_PROJECT_ROOT: \n")
               (length "#+EPI_CODING_SYSTEM: \n")
               (length "#+EPI_HEADER_SHA256: \n")
               (epi-ledger--utf8-byte-length title 'header-value work)
               (epi-ledger--utf8-byte-length format-text 'header-value work)
               (epi-ledger--utf8-byte-length session-id 'header-value work)
               (epi-ledger--utf8-byte-length created-at 'header-value work)
               (epi-ledger--utf8-byte-length project-root 'header-value work)
               (epi-ledger--utf8-byte-length coding-system 'header-value work)
               (epi-ledger--utf8-byte-length hash 'header-value work))))
      (when (> byte-size epi-record-frame-byte-limit)
        (epi-ledger--limit-fail 'header-byte-limit
                                :limit epi-record-frame-byte-limit))
      (let (chunks)
        (cl-labels
            ((queue
              (text field)
              (let ((bytes (epi-ledger--work-encode-utf8 text work field)))
                (setq chunks
                      (epi-ledger--work-cons bytes chunks work))))
             (queue-line
              (prefix value)
              (queue prefix 'ledger-header-prefix)
              (queue value 'ledger-header-value)
              (queue "\n" 'ledger-header-prefix)))
          (queue-line "#+title: " title)
          (queue-line "#+EPI_FORMAT: " format-text)
          (queue-line "#+EPI_SESSION_ID: " session-id)
          (queue-line "#+EPI_CREATED_AT: " created-at)
          (queue-line "#+EPI_PROJECT_ROOT: " project-root)
          (queue-line "#+EPI_CODING_SYSTEM: " coding-system)
          (queue-line "#+EPI_HEADER_SHA256: " hash))
        (setq chunks (epi-ledger--work-nreverse-list chunks work))
        (epi-ledger--work-concat-chunks
         chunks byte-size work 'ledger-header)))))

(defun epi-ledger--header-object (header)
  "Return the canonical hash object represented by HEADER."
  `(("title" . ,(epi-header--raw-title header))
    ("format" . ,(epi-header--raw-format header))
    ("session_id" . ,(epi-header--raw-session-id header))
    ("created_at" . ,(epi-header--raw-created-at header))
    ("project_root" . ,(epi-header--raw-project-root header))
    ("coding_system" . ,(epi-header--raw-coding-system header))))

(defun epi-ledger--owned-string (value)
  "Return an ownership-safe copy of string VALUE, preserving other values."
  (if (stringp value) (substring-no-properties value) value))

(defun epi-ledger--snapshot-canonical-value
    (value &optional byte-limit byte-limit-code)
  "Return one ownership snapshot of VALUE under hard canonical bounds.
This entry snapshot neither yields nor permits automatic GC callbacks while
caller-owned data is reachable.  It checks depth, item count, cycles, scalar
types, a conservative canonical byte lower bound, and aggregate copied-string
storage.  Exact validity and encoded size are checked cooperatively afterward
by `epi-ledger--preflight-canonical-value'.  Optional BYTE-LIMIT selects the
hard cap, and BYTE-LIMIT-CODE selects its structured error code."
  (let ((gc-cons-threshold most-positive-fixnum))
   (let ((maximum-bytes (or byte-limit epi-record-json-byte-limit))
         (maximum-bytes-code (or byte-limit-code 'record-json-byte-limit))
         (string-copies (make-hash-table :test #'eq))
         (active (make-hash-table :test #'eq))
         (items 0)
         (bytes 0)
         (copied-string-bytes 0)
         (container-allocation-units 0))
    (cl-labels
        ((charge
          (amount)
          (setq bytes (+ bytes amount))
          (when (> bytes maximum-bytes)
            (epi-ledger--limit-fail
             maximum-bytes-code :limit maximum-bytes)))
         (count-item
          ()
          (setq items (1+ items))
          (when (> items epi-json-item-limit)
            (epi-ledger--limit-fail 'json-item-limit
                                    :limit epi-json-item-limit)))
         (check-depth
          (depth)
          (let ((next-depth (1+ depth)))
            (when (> next-depth epi-json-depth-limit)
              (epi-ledger--limit-fail 'json-depth-limit
                                      :limit epi-json-depth-limit))
            next-depth))
         (charge-container
          (amount)
          ;; A JSON item can retain at most two output conses plus bounded
          ;; traversal/hash-table bookkeeping.  Keep that independent bound
          ;; explicit instead of treating canonical bytes as heap bytes.
          (setq container-allocation-units
                (+ container-allocation-units amount))
          (when (> container-allocation-units
                   (+ 4 (* 6 epi-json-item-limit)))
            (epi-ledger--limit-fail 'json-item-limit
                                    :limit epi-json-item-limit)))
         (copy-string
          (string)
          (let ((remaining (- maximum-bytes bytes 2)))
            (when (> (length string) remaining)
              (epi-ledger--limit-fail
               maximum-bytes-code :limit maximum-bytes)))
          (charge (+ 2 (length string)))
          (or (gethash string string-copies)
              (let* ((storage (string-bytes string))
                     (maximum-storage
                      (/ (+ (* 5 maximum-bytes) 3) 4)))
                (when (> storage (- maximum-storage copied-string-bytes))
                  (epi-ledger--limit-fail
                   maximum-bytes-code :limit maximum-bytes))
                (setq copied-string-bytes (+ copied-string-bytes storage))
                (let ((copy (substring-no-properties string)))
                  (puthash string copy string-copies)
                  copy))))
         (copy-node
          (node depth)
          (cond
           ((stringp node) (copy-string node))
           ((null node) (charge 2) nil)
           ((vectorp node)
            (let ((child-depth (check-depth depth)))
              (when (gethash node active)
                (epi-ledger--format-fail 'cyclic-json))
              (when (> (+ items (length node)) epi-json-item-limit)
                (epi-ledger--limit-fail 'json-item-limit
                                        :limit epi-json-item-limit))
              (puthash node t active)
              (unwind-protect
                  (let ((copy (make-vector (length node) nil)))
                    (charge-container (1+ (length node)))
                    (charge 2)
                    (dotimes (index (length node))
                      (when (> index 0) (charge 1))
                      (count-item)
                      (aset copy index
                            (copy-node (aref node index) child-depth)))
                    copy)
                (remhash node active))))
           ((consp node)
            (let ((child-depth (check-depth depth))
                  (marked nil)
                  (tail node)
                  (first t)
                  copy)
              (unwind-protect
                  (progn
                    (charge-container 2)
                    (charge 2)
                    (while (consp tail)
                      (when (gethash tail active)
                        (epi-ledger--format-fail 'cyclic-json))
                      (puthash tail t active)
                      (push tail marked)
                      (charge-container 5)
                      (count-item)
                      (unless first (charge 1))
                      (setq first nil)
                      (let ((entry (car tail)))
                        (unless (consp entry)
                          (epi-ledger--format-fail
                           'object-entry-required :field 'payload))
                        (when (gethash entry active)
                          (epi-ledger--format-fail 'cyclic-json))
                        (puthash entry t active)
                        (push entry marked)
                        (let ((key (car entry)))
                          (unless (stringp key)
                            (epi-ledger--format-fail
                             'invalid-string :field 'object-key))
                          (let ((key-copy (copy-string key)))
                            (charge 1)
                            (push (cons key-copy
                                        (copy-node (cdr entry) child-depth))
                                  copy))))
                      (setq tail (cdr tail)))
                    (unless (null tail)
                      (epi-ledger--format-fail
                       'improper-object :field 'payload))
                    (nreverse copy))
                (dolist (container marked)
                  (remhash container active)))))
           ((eq node t) (charge 4) t)
           ((eq node epi-json-false) (charge 5) epi-json-false)
           ((eq node epi-json-null) (charge 4) epi-json-null)
           ((integerp node)
            (unless (<= (- epi-ledger--maximum-safe-integer)
                        node epi-ledger--maximum-safe-integer)
              (epi-ledger--format-fail 'integer-out-of-range
                                       :field 'number))
            (charge (length (number-to-string node)))
            node)
           ((floatp node)
            (unless (epi--finite-number-p node)
              (epi-ledger--format-fail 'nonfinite-number :field 'number))
            (charge 1)
            node)
           (t
            (epi-ledger--format-fail
             'unsupported-json-value :type (type-of node))))))
      (copy-node value 0)))))

(defun epi-ledger--canonical-string-byte-length-no-callback (value)
  "Return VALUE's exact JCS string byte length without yielding or copying."
  (unless (stringp value)
    (epi-ledger--format-fail 'invalid-string :field 'string))
  (let ((multibyte (multibyte-string-p value))
        (total 2))
    (dotimes (index (length value))
      (let ((character (aref value index)))
        (unless (if multibyte
                    (and (<= character #x10ffff)
                         (not (<= #xd800 character #xdfff)))
                  (<= character #x7f))
          (epi-ledger--format-fail 'invalid-string :field 'string))
        (setq total
              (+ total
                 (cond
                  ((memq character '(8 9 10 12 13 34 92)) 2)
                  ((< character 32) 6)
                  ((<= character #x7f) 1)
                  ((<= character #x7ff) 2)
                  ((<= character #xffff) 3)
                  (t 4))))))
    total))

(defun epi-ledger--canonical-value-byte-length-no-callback (value)
  "Return canonical JCS byte length of already snapshotted VALUE.
This helper performs no cooperative yield and invokes no Epi callback."
  (cl-labels
      ((measure
        (node)
        (cond
         ((stringp node)
          (epi-ledger--canonical-string-byte-length-no-callback node))
         ((null node) 2)
         ((vectorp node)
          (let ((total 2))
            (dotimes (index (length node))
              (when (> index 0)
                (setq total (1+ total)))
              (setq total (+ total (measure (aref node index)))))
            total))
         ((consp node)
          (let ((tail node)
                (first t)
                (total 2))
            (while (consp tail)
              (let ((entry (car tail)))
                (unless (and (consp entry) (stringp (car entry)))
                  (epi-ledger--format-fail
                   'object-entry-required :field 'payload))
                (unless first
                  (setq total (1+ total)))
                (setq first nil
                      total
                      (+ total
                         (epi-ledger--canonical-string-byte-length-no-callback
                          (car entry))
                         1
                         (measure (cdr entry)))
                      tail (cdr tail))))
            (unless (null tail)
              (epi-ledger--format-fail 'improper-object :field 'payload))
            total))
         ((eq node t) 4)
         ((eq node epi-json-false) 5)
         ((eq node epi-json-null) 4)
         ((or (integerp node) (floatp node))
          (length (epi-ledger--jcs-number node)))
         (t
          (epi-ledger--format-fail
           'unsupported-json-value :type (type-of node))))))
    (measure value)))

(defun epi-ledger--draft-projected-frame-byte-size (draft)
  "Return DRAFT's exact rendered size using fixed generated-value widths.
Nil identifiers and timestamps are replaced only for this callback-free size
projection; the owned DRAFT remains unchanged."
  (let* ((id (or (epi-draft-id draft)
                 "00000000-0000-4000-8000-000000000000"))
         (at (or (epi-draft-at draft)
                 "2000-01-01T00:00:00.000000000Z"))
         (type (epi-draft-type draft))
         (_schema (epi-ledger--schema type))
         (record
          (epi-ledger--make-record
           :id id :type type :schema 1 :at at
           :previous-hash (make-string 64 ?0)
           :hash (make-string 64 ?0)
           :parent (epi-draft-parent draft)
           :target (epi-draft-target draft)
           :turn (epi-draft-turn draft)
           :operation (epi-draft-operation draft)
           :payload (epi-draft-payload draft)))
         (json-size
          (epi-ledger--canonical-value-byte-length-no-callback
           (epi-ledger--envelope record)))
         (properties (epi-ledger--record-render-properties record)))
    (+ (length "*  \n:PROPERTIES:\n")
       (string-bytes (symbol-name type))
       (string-bytes id)
       (cl-loop
        for (name . value) in properties
        sum (+ (length name) 4 (string-bytes value)))
       (length ":END:\n#+begin_epi-json\n")
       json-size
       (length "\n#+end_epi-json\n"))))

(defun epi-ledger--snapshot-draft-batch (drafts &optional header-bytes)
  "Return an owned vector snapshot of DRAFTS under aggregate batch caps.
HEADER-BYTES, when non-nil, is an already rendered unibyte header whose exact
length participates in the byte cap.  Collection ownership and byte
projection complete without yields, ID/time sources, or file I/O."
  (let ((gc-cons-threshold most-positive-fixnum)
        (count 0)
        source)
    (cond
     ((vectorp drafts)
      (setq count (length drafts))
      (when (> count epi-ledger--batch-record-limit)
        (epi-ledger--limit-fail
         'batch-record-limit :limit epi-ledger--batch-record-limit
         :count count))
      (setq source (append drafts nil)))
     ((listp drafts)
      (let ((tail drafts)
            reverse)
        (while (and (consp tail)
                    (<= count epi-ledger--batch-record-limit))
          (push (car tail) reverse)
          (setq count (1+ count)
                tail (cdr tail)))
        (when (> count epi-ledger--batch-record-limit)
          (epi-ledger--limit-fail
           'batch-record-limit :limit epi-ledger--batch-record-limit
           :count count))
        (unless (null tail)
          (epi-ledger--format-fail 'invalid-draft-batch))
        (setq source (nreverse reverse))))
     (t
      (epi-ledger--format-fail 'invalid-draft-batch)))
    (let* ((header-size
            (cond
             ((null header-bytes) 0)
             ((and (stringp header-bytes)
                   (not (multibyte-string-p header-bytes)))
              (length header-bytes))
             (t
              (epi-ledger--format-fail 'invalid-header-bytes))))
           (bytes header-size)
           (owned (make-vector count nil))
           (tail source))
      (when (> bytes epi-ledger--batch-byte-limit)
        (epi-ledger--limit-fail
         'batch-byte-limit :limit epi-ledger--batch-byte-limit
         :bytes bytes))
      (cl-labels
          ((copy-field
            (value field)
            (cond
             ((null value) nil)
             ((not (stringp value))
              (epi-ledger--format-fail 'invalid-string :field field))
             (t
              (let ((storage (string-bytes value)))
                (when (> storage (- epi-ledger--batch-byte-limit bytes))
                  (epi-ledger--limit-fail
                   'batch-byte-limit :limit epi-ledger--batch-byte-limit
                   :bytes (+ bytes storage)))
                (substring-no-properties value))))))
        (dotimes (index count)
          (let ((draft (car tail)))
            (unless (epi-draft-p draft)
              (epi-ledger--format-fail 'draft-required))
            (let ((copy
                   (make-epi-draft
                    :id (copy-field (epi-draft-id draft) "id")
                    :type (epi-draft-type draft)
                    :at (copy-field (epi-draft-at draft) "at")
                    :parent (copy-field (epi-draft-parent draft) "parent")
                    :target (copy-field (epi-draft-target draft) "target")
                    :turn (copy-field (epi-draft-turn draft) "turn")
                    :operation
                    (copy-field (epi-draft-operation draft) "operation")
                    :payload
                    (epi-ledger--snapshot-canonical-value
                     (epi-draft-payload draft)
                     epi-record-json-byte-limit
                     'record-json-byte-limit))))
              (setq bytes
                    (+ bytes
                       (epi-ledger--draft-projected-frame-byte-size copy)))
              (when (> bytes epi-ledger--batch-byte-limit)
                (epi-ledger--limit-fail
                 'batch-byte-limit :limit epi-ledger--batch-byte-limit
                 :bytes bytes))
              (aset owned index copy)))
          (setq tail (cdr tail))))
      owned)))

(defun epi-ledger--fill-owned-draft-defaults (owned-drafts)
  "Fill nil IDs and timestamps in owned vector OWNED-DRAFTS.
Each draft is visited in physical order.  Its ID is filled before its
timestamp, and every callback result is copied and validated before any later
callback can run.  Return the same vector."
  (unless (vectorp owned-drafts)
    (epi-ledger--format-fail 'invalid-draft-batch))
  (dotimes (index (length owned-drafts))
    (let ((draft (aref owned-drafts index)))
      (unless (epi-draft-p draft)
        (epi-ledger--format-fail 'draft-required))
      (unless (epi-draft-id draft)
        (let ((generated (epi--new-id)))
          (unless (stringp generated)
            (epi-ledger--format-fail 'invalid-id :field "id"))
          (let ((owned (substring-no-properties generated)))
            (unless (epi-ledger--uuid-p owned)
              (epi-ledger--format-fail 'invalid-id :field "id"))
            (setf (epi-draft-id draft) owned))))
      (unless (epi-draft-at draft)
        (let ((generated (epi--format-timestamp)))
          (unless (stringp generated)
            (epi-ledger--format-fail 'invalid-timestamp :field "at"))
          (let ((owned (substring-no-properties generated)))
            (unless (epi-ledger--timestamp-p owned)
              (epi-ledger--format-fail 'invalid-timestamp :field "at"))
            (setf (epi-draft-at draft) owned))))))
  owned-drafts)

(defun epi-ledger--preflight-canonical-value
    (value &optional byte-limit byte-limit-code)
  "Validate VALUE within canonical limits before copying it.
BYTE-LIMIT defaults to `epi-record-json-byte-limit', and BYTE-LIMIT-CODE
defaults to `record-json-byte-limit'.
The bounded recursive descent stops before exceeding `epi-json-depth-limit';
object spines are walked incrementally so malformed, cyclic, or oversized
lists never trigger an unbounded proper-list prepass."
  (epi-ledger--with-operation-work-state
   (let ((maximum-bytes (or byte-limit epi-record-json-byte-limit))
        (maximum-bytes-code (or byte-limit-code 'record-json-byte-limit))
        (work (epi-ledger--make-work-state))
        (active (make-hash-table :test #'eq))
        (items 0)
        (bytes 0))
    (cl-labels
        ((charge
          (amount &optional already-charged)
          (setq bytes (+ bytes amount))
          (unless already-charged
            (epi-ledger--work-charge-count work amount))
          (when (> bytes maximum-bytes)
            (epi-ledger--limit-fail
             maximum-bytes-code :limit maximum-bytes)))
         (count-item
          ()
          (setq items (1+ items))
          (epi-ledger--work-charge work 1)
          (when (> items epi-json-item-limit)
            (epi-ledger--limit-fail 'json-item-limit
                                    :limit epi-json-item-limit)))
         (enter
          (container depth)
          (let ((container-depth (1+ depth)))
            (when (> container-depth epi-json-depth-limit)
              (epi-ledger--limit-fail 'json-depth-limit
                                      :limit epi-json-depth-limit))
            (when (gethash container active)
              (epi-ledger--format-fail 'cyclic-json))
            (puthash container t active)
            container-depth))
         (walk
          (node depth)
          (cond
           ((stringp node)
            (charge
             (epi-ledger--jcs-string-byte-length
              node (- maximum-bytes bytes) maximum-bytes
              maximum-bytes-code work)
             t))
           ((null node)
            (enter node depth)
            (unwind-protect
                (charge 2)
              (remhash node active)))
           ((vectorp node)
            (let ((child-depth (enter node depth)))
              (unwind-protect
                  (progn
                    (charge 2)
                    (dotimes (index (length node))
                      (when (> index 0) (charge 1))
                      (count-item)
                      (epi-ledger--work-charge work 1)
                      (let ((child (aref node index)))
                        (walk child child-depth))))
                (remhash node active))))
           ((consp node)
            (let ((child-depth (enter node depth))
                  (tail node)
                  (fast node)
                  (first-entry t)
                  sort-keys)
              (unwind-protect
                  (progn
                    (charge 2)
                    (while (consp tail)
                      (let ((entry (epi-ledger--work-car tail work))
                            (next (epi-ledger--work-cdr tail work)))
                        (when (consp fast)
                          (setq fast (epi-ledger--work-cdr fast work))
                          (when (consp fast)
                            (setq fast (epi-ledger--work-cdr fast work))))
                        (count-item)
                        (unless first-entry (charge 1))
                        (unless (consp entry)
                          (epi-ledger--format-fail
                           'object-entry-required :field 'payload))
                        (when (gethash entry active)
                          (epi-ledger--format-fail 'cyclic-json))
                        (puthash entry t active)
                        (unwind-protect
                            (let ((key (epi-ledger--work-car entry work))
                                  (child (epi-ledger--work-cdr entry work)))
                              (charge
                               (epi-ledger--jcs-string-byte-length
                                key (- maximum-bytes bytes) maximum-bytes
                                maximum-bytes-code work)
                               t)
                              (charge 1)
                              (let ((epi-ledger--canonical-value-preflighted t))
                                (let ((sort-key
                                       (epi-ledger--utf16be-key-chunks
                                        key work)))
                                  (setq sort-keys
                                        (epi-ledger--work-cons
                                         sort-key sort-keys work))))
                              (walk child child-depth))
                          (remhash entry active))
                        (setq first-entry nil
                              tail next)
                        (when (and (consp tail) (eq tail fast))
                          (epi-ledger--format-fail 'cyclic-json))))
                    (unless (null tail)
                      (epi-ledger--format-fail
                       'improper-object :field 'payload))
                    (epi-ledger--assert-unique-sort-keys
                     sort-keys 'payload work))
                (remhash node active))))
           ((eq node t) (charge 4))
           ((eq node epi-json-false) (charge 5))
           ((eq node epi-json-null) (charge 4))
           ((or (integerp node) (floatp node))
            (charge (length (epi-ledger--jcs-number node))))
           (t
            (epi-ledger--format-fail
             'unsupported-json-value :type (type-of node))))))
      (walk value 0))
    value)))

(defun epi-ledger--line-at (bytes offset limit &optional prefix-validator
                                  prefix-error limit-code limit-value
                                  trailing-minimum offset-origin)
  "Return (LINE NEXT) from BYTES at OFFSET, bounded by LIMIT.
Signal `end-of-file' when the final LF has not arrived.  When supplied,
PREFIX-VALIDATOR must return non-nil for the unterminated fragment; an integer
return is the exact number of content bytes still required.  Otherwise signal
a ledger format error using PREFIX-ERROR.  LIMIT-CODE and LIMIT-VALUE customize
the structured error at the byte boundary.  TRAILING-MINIMUM is the number of
mandatory bytes after this line's LF.  Optional OFFSET-ORIGIN is added to
reported byte offsets."
  (let ((origin (or offset-origin 0))
        (source-length (epi-ledger--source-length bytes)))
  (when (<= limit 0)
    (epi-ledger--limit-fail (or limit-code 'record-frame-byte-limit)
                            :limit (or limit-value limit)
                            :offset (+ origin offset)))
  (let* ((end (min source-length (+ offset limit)))
         (cursor offset)
         (reserved-position offset)
         (work (epi-ledger--make-work-state))
         (check-interval
          (max 1 (min epi-ledger--lex-clock-check-byte-interval
                      epi-ledger-work-byte-limit)))
         newline)
    (while (and (< cursor end) (not newline))
      (when (>= cursor reserved-position)
        (let ((next (min end (+ cursor check-interval))))
          (epi-ledger--work-charge work (- next cursor))
          (setq reserved-position next)))
      (if (= (epi-ledger--source-byte bytes cursor) ?\n)
          (setq newline cursor)
        (setq cursor (1+ cursor))))
    (cond
     (newline
      (let ((line (epi-ledger--source-copy-range
                   bytes offset newline 'line work)))
        (epi-ledger--work-cons
         line (epi-ledger--work-cons (1+ newline) nil work) work)))
     ((>= (- source-length offset) limit)
      (epi-ledger--limit-fail (or limit-code 'record-frame-byte-limit)
                              :limit (or limit-value limit)
                              :offset (+ origin end)))
     (t
      (let* ((fragment
              (epi-ledger--source-copy-range
               bytes offset end 'line-prefix work))
             (prefix-result
              (if prefix-validator (funcall prefix-validator fragment) t)))
        (unless prefix-result
          (epi-ledger--format-fail (or prefix-error 'invalid-line-prefix)
                                   :offset (+ origin offset)))
        (let* ((minimum
                (+ (if (integerp prefix-result) prefix-result 0)
                   1 (or trailing-minimum 0)))
               (payload
                (epi-ledger--work-cons
                 :minimum-completion-bytes
                 (epi-ledger--work-cons minimum nil work)
                 work))
               (condition-data
                (epi-ledger--work-cons payload nil work)))
          (signal 'end-of-file condition-data))))))))

(defun epi-ledger--line-range-at
    (source offset limit &optional limit-code limit-value offset-origin)
  "Return `(START END NEXT)' for SOURCE's line at OFFSET within LIMIT bytes.
Unlike `epi-ledger--line-at', this never copies the LF-terminated line body.
LIMIT-CODE and LIMIT-VALUE customize limit errors; OFFSET-ORIGIN translates
their byte offsets."
  (let ((origin (or offset-origin 0))
        (length (epi-ledger--source-length source)))
    (when (<= limit 0)
      (epi-ledger--limit-fail (or limit-code 'record-frame-byte-limit)
                              :limit (or limit-value limit)
                              :offset (+ origin offset)))
    (let* ((end (min length (+ offset limit)))
           (cursor offset)
           (reserved offset)
           (work (epi-ledger--make-work-state))
           (interval
            (max 1 (min epi-ledger--lex-clock-check-byte-interval
                        epi-ledger-work-byte-limit)))
           newline)
      (while (and (< cursor end) (not newline))
        (when (>= cursor reserved)
          (let ((next (min end (+ cursor interval))))
            (epi-ledger--work-charge work (- next cursor))
            (setq reserved next)))
        (if (= (epi-ledger--source-byte source cursor) ?\n)
            (setq newline cursor)
          (setq cursor (1+ cursor))))
      (cond
       (newline (list offset newline (1+ newline)))
       ((>= (- length offset) limit)
        (epi-ledger--limit-fail (or limit-code 'record-frame-byte-limit)
                                :limit (or limit-value limit)
                                :offset (+ origin end)))
       (t
        (signal 'end-of-file
                (list (list :minimum-completion-bytes 1))))))))

(defun epi-ledger--snapshot-byte-window (bytes offset maximum)
  "Copy at most MAXIMUM bytes plus one sentinel from BYTES at OFFSET.
This ownership boundary deliberately does not yield: no caller-owned byte can
remain reachable when subsequent incremental scanners yield."
  (let ((gc-cons-threshold most-positive-fixnum))
    (substring-no-properties
     bytes offset (min (length bytes) (+ offset maximum 1)))))

(defun epi-ledger--header-hash-from-fields
    (session-id created-at project-root)
  "Return the canonical header hash for SESSION-ID, CREATED-AT, PROJECT-ROOT.
This is the read path counterpart of `epi-ledger-seal-header'.  It uses the
low-level canonical writer directly so opening a ledger never calls the
public sealing encoder or retains a second canonical header representation."
  (epi-ledger--require-uuid session-id "session_id")
  (unless (epi-ledger--timestamp-p created-at)
    (epi-ledger--format-fail 'invalid-timestamp :field "created_at"))
  (epi-ledger--require-canonical-directory project-root "project_root")
  (let* ((object
          `(("title" . "Epi session")
            ("format" . 1)
            ("session_id" . ,session-id)
            ("created_at" . ,created-at)
            ("project_root" . ,project-root)
            ("coding_system" . "utf-8-unix")))
         (work (epi-ledger--make-work-state))
         (state
          (epi-ledger--make-jcs-state
           :chunks nil :bytes 0 :items 0
           :active (make-hash-table :test #'eq)
           :max-bytes epi-record-frame-byte-limit
           :work work :trusted nil)))
    (epi-ledger--jcs-write object state 0)
    (let ((chunks
           (epi-ledger--work-nreverse-list
            (epi-ledger--jcs-state-chunks state) work)))
      (epi-ledger--hash
       (epi-ledger--work-concat-chunks
        chunks (epi-ledger--jcs-state-bytes state) work 'header-json)
       'header))))

(defun epi-ledger--parse-header-owned (bytes origin)
  "Parse an owned header window BYTES whose byte zero is absolute ORIGIN."
  (epi-ledger--with-operation-work-state
   (let ((cursor 0)
         (work (epi-ledger--make-work-state))
         (prefixes '("#+title: " "#+EPI_FORMAT: " "#+EPI_SESSION_ID: "
                     "#+EPI_CREATED_AT: " "#+EPI_PROJECT_ROOT: "
                     "#+EPI_CODING_SYSTEM: " "#+EPI_HEADER_SHA256: "))
         values)
    (while (consp prefixes)
      (let* ((prefix (epi-ledger--work-car prefixes work))
             (next-prefix (epi-ledger--work-cdr prefixes work))
             (source-region-p (epi-ledger--source-region-p bytes))
             (line-limit (+ (length prefix)
                            epi-header-value-byte-limit 1))
             (line-result
              (condition-case nil
                  (if source-region-p
                      (epi-ledger--line-range-at
                       bytes cursor line-limit 'header-value-byte-limit
                       epi-header-value-byte-limit origin)
                    (epi-ledger--line-at
                     bytes cursor line-limit nil nil
                     'header-value-byte-limit epi-header-value-byte-limit
                     nil origin))
                (end-of-file
                 (epi-ledger--format-fail
                  'truncated-header :offset (+ origin cursor)))))
             (line
              (and (not source-region-p)
                   (epi-ledger--work-car line-result work)))
             (line-end
              (if source-region-p
                  (nth 1 line-result)
                (+ cursor (length line))))
             (next
              (if source-region-p
                  (nth 2 line-result)
                (let ((result-tail
                       (epi-ledger--work-cdr line-result work)))
                  (epi-ledger--work-car result-tail work)))))
        (unless
            (if source-region-p
                (epi-ledger--source-range-prefix-p
                 bytes cursor line-end prefix work)
              (string-prefix-p prefix line))
          (epi-ledger--format-fail
           'invalid-header-line :offset (+ origin cursor)))
        (let* ((value-start (+ cursor (length prefix)))
               (encoded
                (if source-region-p
                    (epi-ledger--source-copy-range
                     bytes value-start line-end 'header-value work)
                  (epi-ledger--copy-owned-unibyte-range
                   line (length prefix) (length line) 'header-value work)))
               (value
                (epi-ledger--decode-utf8
                 encoded 'header-value (+ origin value-start))))
          (setq values (epi-ledger--work-cons value values work)))
        (setq cursor next
              prefixes next-prefix)))
    (when (> cursor epi-record-frame-byte-limit)
      (epi-ledger--limit-fail
       'header-byte-limit :limit epi-record-frame-byte-limit
       :offset (+ origin epi-record-frame-byte-limit)))
    (setq values (epi-ledger--work-nreverse-list values work))
    (let* ((title (epi-ledger--work-car values work))
           (tail (epi-ledger--work-cdr values work))
           (format-text (epi-ledger--work-car tail work))
           (tail (epi-ledger--work-cdr tail work))
           (session-id (epi-ledger--work-car tail work))
           (tail (epi-ledger--work-cdr tail work))
           (created-at (epi-ledger--work-car tail work))
           (tail (epi-ledger--work-cdr tail work))
           (project-root (epi-ledger--work-car tail work))
           (tail (epi-ledger--work-cdr tail work))
           (coding-system (epi-ledger--work-car tail work))
           (tail (epi-ledger--work-cdr tail work))
           (stored-hash (epi-ledger--work-car tail work)))
      (unless (equal title "Epi session")
        (epi-ledger--format-fail 'unsupported-header))
      (unless (equal format-text "1")
        (epi-ledger--format-fail 'unsupported-format))
      (unless (equal coding-system "utf-8-unix")
        (epi-ledger--format-fail 'unsupported-coding-system))
      (let ((actual
             (epi-ledger--header-hash-from-fields
              session-id created-at project-root)))
        (unless (equal stored-hash actual)
          (epi-ledger--format-fail
           'header-hash-mismatch :offset (+ origin cursor)))
        (epi-ledger--make-header
         :title "Epi session" :format 1
         :session-id session-id :created-at created-at
         :project-root project-root :coding-system "utf-8-unix"
         :hash actual
         :byte-size cursor
         :end-offset (+ origin cursor)))))))

(defun epi-ledger-parse-header (bytes &optional offset)
  "Parse a strict version-one header from unibyte BYTES at OFFSET."
  (unless (and (stringp bytes) (not (multibyte-string-p bytes)))
    (epi-ledger--format-fail 'unibyte-header-required))
  (let ((start (or offset 0)))
    (unless (and (integerp start) (<= 0 start (length bytes)))
      (epi-ledger--format-fail 'invalid-offset :offset 0))
    (epi-ledger--parse-header-owned
     (epi-ledger--snapshot-byte-window
      bytes start epi-record-frame-byte-limit)
     start)))

(defun epi-ledger--snapshot-draft-envelope (draft previous-hash sequence)
  "Capture DRAFT, PREVIOUS-HASH, and SEQUENCE as one callback-free envelope."
  (let* ((gc-cons-threshold most-positive-fixnum)
         (_previous-hash-check
          (epi-ledger--require-hash previous-hash "previous_hash"))
         (type (epi-draft-type draft))
         (_schema (epi-ledger--schema type))
         (raw-record
          (epi-ledger--make-record
           :id (epi-draft-id draft)
           :type type :schema 1
           :at (epi-draft-at draft)
           :previous-hash previous-hash
           :parent (epi-draft-parent draft)
           :target (epi-draft-target draft)
           :turn (epi-draft-turn draft)
           :operation (epi-draft-operation draft)
           :payload (epi-draft-payload draft)
           :sequence sequence))
         (envelope
          (epi-ledger--snapshot-canonical-value
           (epi-ledger--envelope raw-record)
           epi-record-json-byte-limit 'record-json-byte-limit)))
    (cons type envelope)))

(defun epi-ledger-seal-record (draft previous-hash &optional sequence)
  "Seal DRAFT after PREVIOUS-HASH and return a canonical record.
Optional SEQUENCE is the eventual positive physical record sequence."
  (unless (epi-draft-p draft)
    (epi-ledger--format-fail 'draft-required))
  (when (and sequence (not (and (integerp sequence) (> sequence 0))))
    (epi-ledger--format-fail 'invalid-sequence :field 'sequence))
  (epi-ledger--with-operation-work-state
   (let* ((capture
          (epi-ledger--snapshot-draft-envelope
           draft previous-hash sequence))
         (type (car capture))
         (envelope (cdr capture))
         (_preflight
          (epi-ledger--preflight-canonical-value
           envelope epi-record-json-byte-limit 'record-json-byte-limit))
         (record
          (epi-ledger--make-record
           :id (epi-ledger--object-value envelope "id")
           :type type :schema 1
           :at (epi-ledger--object-value envelope "at")
           :previous-hash
           (epi-ledger--object-value envelope "previous_hash")
           :parent (epi-ledger--object-value envelope "parent")
           :target (epi-ledger--object-value envelope "target")
           :turn (epi-ledger--object-value envelope "turn")
           :operation (epi-ledger--object-value envelope "operation")
           :payload (epi-ledger--object-value envelope "payload")
           :sequence sequence)))
    (let ((epi-ledger--canonical-value-preflighted t))
      (epi-ledger--validate-record-fields record)
      (let* ((json (epi-ledger--jcs-encode
                    envelope epi-record-json-byte-limit t))
             (hash (epi-ledger--hash json 'record)))
        (epi-ledger--make-record
         :id (epi-record--raw-id record)
         :type (epi-record--raw-type record)
         :schema (epi-record--raw-schema record)
         :at (epi-record--raw-at record)
         :previous-hash (epi-record--raw-previous-hash record)
         :hash hash
         :parent (epi-record--raw-parent record)
         :target (epi-record--raw-target record)
         :turn (epi-record--raw-turn record)
         :operation (epi-record--raw-operation record)
         :payload (epi-record--raw-payload record)
         :sequence (epi-record--raw-sequence record)
         :start-offset (epi-record--raw-start-offset record)
         :json-start-offset (epi-record--raw-json-start-offset record)
         :json-end-offset (epi-record--raw-json-end-offset record)
         :end-offset (epi-record--raw-end-offset record)
         :frame-byte-size (epi-record--raw-frame-byte-size record)
         :sealed-json json))))))

(defun epi-ledger--record-json (record)
  "Return canonical JSON bytes for RECORD, revalidating its hash."
  (let ((json (or (epi-record--raw-sealed-json record)
                  (epi-ledger--jcs-encode
                   (epi-ledger--envelope record)
                   epi-record-json-byte-limit))))
    (unless (equal (epi-record--raw-hash record)
                   (epi-ledger--hash json 'record))
      (epi-ledger--format-fail 'record-hash-mismatch
                               :sequence (epi-record--raw-sequence record)))
    json))

(defun epi-ledger--record-render-properties (record)
  "Return internal drawer property pairs for sealed RECORD."
  (let ((properties
         (list (cons "EPI_ID" (epi-record--raw-id record))
               (cons "EPI_TYPE"
                     (symbol-name (epi-record--raw-type record)))
               (cons "EPI_SCHEMA"
                     (number-to-string (epi-record--raw-schema record)))
               (cons "EPI_AT" (epi-record--raw-at record))))
        (optional
         `(("EPI_PARENT" . ,(epi-record--raw-parent record))
           ("EPI_TARGET" . ,(epi-record--raw-target record))
           ("EPI_TURN" . ,(epi-record--raw-turn record))
           ("EPI_OPERATION" . ,(epi-record--raw-operation record)))))
    (append properties (seq-filter #'cdr optional)
            (list (cons "EPI_PREV_SHA256"
                        (epi-record--raw-previous-hash record))
                  (cons "EPI_RECORD_SHA256"
                        (epi-record--raw-hash record))))))

(defun epi-ledger--record-rendered-byte-size (record json properties)
  "Return exact frame bytes for RECORD, JSON, and drawer PROPERTIES."
  (+ (length "*  \n:PROPERTIES:\n")
     (epi-ledger--utf8-byte-length
      (symbol-name (epi-record--raw-type record)) 'record-type)
     (epi-ledger--utf8-byte-length
      (epi-record--raw-id record) 'record-id)
     (cl-loop
      for (name . value) in properties
      sum (+ (length name) 4
             (epi-ledger--utf8-byte-length value 'drawer-value)))
     (length ":END:\n#+begin_epi-json\n")
     (length json)
     (length "\n#+end_epi-json\n")))

(defun epi-ledger-render-record (record)
  "Render sealed RECORD as exact level-one Org framing bytes."
  (epi-ledger--with-operation-work-state
    (unless (epi-record-p record)
      (epi-ledger--format-fail 'record-required))
    (let* ((type-text (symbol-name (epi-record--raw-type record)))
           (id (epi-record--raw-id record))
           (json (epi-ledger--record-json record))
           (properties (epi-ledger--record-render-properties record))
           (frame-size
            (epi-ledger--record-rendered-byte-size record json properties)))
      (when (> frame-size epi-record-frame-byte-limit)
        (epi-ledger--limit-fail 'record-frame-byte-limit
                                :limit epi-record-frame-byte-limit))
      (let ((work (epi-ledger--make-work-state))
            chunks)
        (cl-labels
            ((queue-text
              (text field)
              (let ((bytes (epi-ledger--work-encode-utf8 text work field)))
                (setq chunks
                      (epi-ledger--work-cons bytes chunks work))))
             (queue-bytes
              (bytes)
              (setq chunks (epi-ledger--work-cons bytes chunks work))))
          (queue-text "* " 'ledger-record-prefix)
          (queue-text type-text 'ledger-record-type)
          (queue-text " " 'ledger-record-prefix)
          (queue-text id 'ledger-record-id)
          (queue-text "\n:PROPERTIES:\n" 'ledger-record-prefix)
          (let ((tail properties))
            (while (consp tail)
              (let* ((property (epi-ledger--work-car tail work))
                     (next (epi-ledger--work-cdr tail work))
                     (name (epi-ledger--work-car property work))
                     (value (epi-ledger--work-cdr property work)))
                (queue-text ":" 'ledger-record-prefix)
                (queue-text name 'ledger-record-property-name)
                (queue-text ": " 'ledger-record-prefix)
                (queue-text value 'ledger-record-property-value)
                (queue-text "\n" 'ledger-record-prefix)
                (setq tail next))))
          (queue-text ":END:\n#+begin_epi-json\n" 'ledger-record-prefix)
          (queue-bytes json)
          (queue-text "\n#+end_epi-json\n" 'ledger-record-prefix))
        (setq chunks (epi-ledger--work-nreverse-list chunks work))
        (epi-ledger--work-concat-chunks
         chunks frame-size work 'ledger-record)))))

(defconst epi-ledger--drawer-property-order
  '("EPI_ID" "EPI_TYPE" "EPI_SCHEMA" "EPI_AT" "EPI_PARENT" "EPI_TARGET"
    "EPI_TURN" "EPI_OPERATION" "EPI_PREV_SHA256" "EPI_RECORD_SHA256")
  "Exact allowed property order for version-one record drawers.")

(defconst epi-ledger--required-drawer-properties
  '("EPI_ID" "EPI_TYPE" "EPI_SCHEMA" "EPI_AT"
    "EPI_PREV_SHA256" "EPI_RECORD_SHA256")
  "Required properties in every version-one record drawer.")

(defun epi-ledger--literal-prefix-p (fragment literal)
  "Return whether FRAGMENT is a byte prefix of LITERAL."
  (and (<= (length fragment) (length literal))
       (string-prefix-p fragment literal)))

(defun epi-ledger--uuid-prefix-p (fragment)
  "Return whether FRAGMENT is a prefix of a lowercase UUID spelling."
  (and (<= (length fragment) 36)
       (let ((index 0)
             (valid t))
         (while (and valid (< index (length fragment)))
           (let ((byte (aref fragment index)))
             (setq valid
                   (if (memq index '(8 13 18 23))
                       (= byte ?-)
                     (or (<= ?0 byte ?9) (<= ?a byte ?f)))))
           (setq index (1+ index)))
         valid)))

(defun epi-ledger--timestamp-prefix-p (fragment)
  "Return whether FRAGMENT can be extended to a valid RFC 3339 timestamp."
  (not (null (epi-ledger--timestamp-scan fragment))))

(defun epi-ledger--drawer-value-p (name value)
  "Return whether VALUE is an exact completed drawer property NAME."
  (cond
   ((member name '("EPI_ID" "EPI_PARENT" "EPI_TARGET"
                   "EPI_TURN" "EPI_OPERATION"))
    (epi-ledger--uuid-p value))
   ((equal name "EPI_TYPE")
    (let ((type (intern-soft value)))
      (and type (assq type epi-ledger--record-schemas))))
   ((equal name "EPI_SCHEMA") (equal value "1"))
   ((equal name "EPI_AT") (epi-ledger--timestamp-p value))
   ((member name '("EPI_PREV_SHA256" "EPI_RECORD_SHA256"))
    (epi-ledger--hash-p value))
   (t nil)))

(defun epi-ledger--drawer-required-names (type-text)
  "Return ordered mandatory drawer names for record TYPE-TEXT."
  (let* ((type (intern-soft type-text))
         (schema (and type (assq type epi-ledger--record-schemas)))
         (envelope-fields (and schema
                               (plist-get (cdr schema) :required-envelope)))
         (names
          (append
           (copy-sequence epi-ledger--required-drawer-properties)
           (mapcar (lambda (field)
                     (concat "EPI_" (upcase (symbol-name field))))
                   envelope-fields))))
    (sort names
          (lambda (left right)
            (< (cl-position left epi-ledger--drawer-property-order
                            :test #'equal)
               (cl-position right epi-ledger--drawer-property-order
                            :test #'equal))))))

(defun epi-ledger--drawer-allowed-names (type-text)
  "Return ordered drawer names permitted for record TYPE-TEXT."
  (let* ((type (intern-soft type-text))
         (schema (and type (assq type epi-ledger--record-schemas)))
         (fields
          (append (and schema (plist-get (cdr schema) :required-envelope))
                  (and schema (plist-get (cdr schema) :optional-envelope))))
         (names
          (append
           (copy-sequence epi-ledger--required-drawer-properties)
           (mapcar (lambda (field)
                     (concat "EPI_" (upcase (symbol-name field))))
                   fields))))
    (sort (delete-dups names)
          (lambda (left right)
            (< (cl-position left epi-ledger--drawer-property-order
                            :test #'equal)
               (cl-position right epi-ledger--drawer-property-order
                            :test #'equal))))))

(defun epi-ledger--minimum-json-block-byte-size ()
  "Return the structural minimum bytes from JSON begin through JSON end."
  (+ (length "#+begin_epi-json\n")
     2
     (length "\n#+end_epi-json\n")))

(defun epi-ledger--drawer-value-minimum-byte-length (name type-text)
  "Return minimum exact drawer value bytes for NAME and TYPE-TEXT."
  (cond
   ((member name '("EPI_ID" "EPI_PARENT" "EPI_TARGET"
                   "EPI_TURN" "EPI_OPERATION"))
    36)
   ((equal name "EPI_TYPE") (length type-text))
   ((equal name "EPI_SCHEMA") 1)
   ((equal name "EPI_AT") 20)
   ((member name '("EPI_PREV_SHA256" "EPI_RECORD_SHA256")) 64)
   (t 0)))

(defun epi-ledger--drawer-value-maximum-byte-length (name expected-type)
  "Return maximum prefix bytes for fixed drawer NAME and EXPECTED-TYPE."
  (cond
   ((member name '("EPI_ID" "EPI_PARENT" "EPI_TARGET"
                   "EPI_TURN" "EPI_OPERATION"))
    36)
   ((equal name "EPI_TYPE") (length expected-type))
   ((equal name "EPI_SCHEMA") 1)
   ((member name '("EPI_PREV_SHA256" "EPI_RECORD_SHA256")) 64)
   (t nil)))

(defun epi-ledger--drawer-tail-minimum
    (last-order seen type-text &optional current-name)
  "Return mandatory bytes after a property at LAST-ORDER.
SEEN records completed properties.  TYPE-TEXT selects type-specific required
envelope fields, and CURRENT-NAME is treated as completed."
  (+
   (cl-loop
    for name in (epi-ledger--drawer-required-names type-text)
    for order = (cl-position name epi-ledger--drawer-property-order
                             :test #'equal)
    unless (or (gethash name seen) (equal name current-name))
    when (> order last-order)
    sum (+ (length name) 4
           (epi-ledger--drawer-value-minimum-byte-length name type-text)))
   (length ":END:\n")
   (epi-ledger--minimum-json-block-byte-size)))

(defun epi-ledger--timestamp-prefix-minimum (value)
  "Return least suffix bytes completing timestamp prefix VALUE, or nil."
  (epi-ledger--timestamp-scan value))

(defun epi-ledger--drawer-value-prefix-minimum
    (name value expected-id expected-type)
  "Return least bytes completing drawer NAME's VALUE, or nil.
EXPECTED-ID and EXPECTED-TYPE bind the drawer to its completed headline."
  (cond
   ((equal name "EPI_ID")
    (and (string-prefix-p value expected-id)
         (- (length expected-id) (length value))))
   ((equal name "EPI_TYPE")
    (and (string-prefix-p value expected-type)
         (- (length expected-type) (length value))))
   ((member name '("EPI_PARENT" "EPI_TARGET" "EPI_TURN" "EPI_OPERATION"))
    (and (epi-ledger--uuid-prefix-p value) (- 36 (length value))))
   ((equal name "EPI_SCHEMA")
    (and (epi-ledger--literal-prefix-p value "1")
         (- 1 (length value))))
   ((equal name "EPI_AT") (epi-ledger--timestamp-prefix-minimum value))
   ((member name '("EPI_PREV_SHA256" "EPI_RECORD_SHA256"))
    (and (<= (length value) 64)
         (cl-every (lambda (byte)
                     (or (<= ?0 byte ?9) (<= ?a byte ?f)))
                   (append value nil))
         (- 64 (length value))))
   (t nil)))

(defun epi-ledger--drawer-prefix-minimum
    (fragment last-order seen expected-id expected-type)
  "Return mandatory suffix bytes after drawer line FRAGMENT, or nil.
LAST-ORDER and SEEN describe prior properties.  EXPECTED-ID and EXPECTED-TYPE
bind the drawer to its completed headline."
  (let ((required (epi-ledger--drawer-required-names expected-type))
        candidates)
    (when (and (cl-every (lambda (name) (gethash name seen)) required)
               (epi-ledger--literal-prefix-p fragment ":END:"))
      (push (+ (- (length ":END:") (length fragment))
               (epi-ledger--minimum-json-block-byte-size))
            candidates))
    (dolist (name (epi-ledger--drawer-allowed-names expected-type))
      (let* ((order (cl-position name epi-ledger--drawer-property-order
                                 :test #'equal))
             (prefix (concat ":" name ": "))
             (skips-required
              (cl-some
               (lambda (required-name)
                 (let ((required-order
                        (cl-position required-name
                                     epi-ledger--drawer-property-order
                                     :test #'equal)))
                   (and (> required-order last-order)
                        (< required-order order)
                        (not (gethash required-name seen)))))
               required))
             value-minimum)
        (when (and (> order last-order)
                   (not (gethash name seen))
                   (not skips-required)
                   (setq value-minimum
                         (cond
                          ((epi-ledger--literal-prefix-p fragment prefix)
                           (+ (- (length prefix) (length fragment))
                              (epi-ledger--drawer-value-minimum-byte-length
                               name expected-type)))
                          ((string-prefix-p prefix fragment)
                           (if (equal name "EPI_AT")
                               (epi-ledger--timestamp-scan
                                fragment (length prefix) (length fragment))
                             (let* ((value-start (length prefix))
                                    (value-length
                                     (- (length fragment) value-start))
                                    (maximum
                                     (epi-ledger--drawer-value-maximum-byte-length
                                      name expected-type)))
                               (and maximum
                                    (<= value-length maximum)
                                    (epi-ledger--drawer-value-prefix-minimum
                                     name (substring fragment value-start)
                                     expected-id expected-type))))))))
          (push (+ value-minimum
                   (epi-ledger--drawer-tail-minimum
                    order seen expected-type name))
                candidates))))
    (when candidates (apply #'min candidates))))

(defun epi-ledger--headline-prefix-candidates (fragment)
  "Return (TYPE . MISSING-CONTENT-BYTES) pairs for headline FRAGMENT."
  (let ((types (mapcar (lambda (entry) (symbol-name (car entry)))
                       epi-ledger--record-schemas))
        candidates)
    (when (<= (length fragment) epi-ledger--maximum-headline-byte-length)
      (cond
       ((epi-ledger--literal-prefix-p fragment "* ")
        (dolist (type types)
          (push (cons type (+ (- 2 (length fragment))
                              (length type) 1 36))
                candidates)))
       ((string-prefix-p "* " fragment)
        (let* ((body (substring fragment 2))
               (space (string-match " " body)))
          (if (null space)
              (dolist (type types)
                (when (string-prefix-p body type)
                  (push (cons type
                              (+ (- (length type) (length body)) 1 36))
                        candidates)))
            (let ((type (substring body 0 space))
                  (uuid-prefix (substring body (1+ space))))
              (when (and (member type types)
                         (not (string-match-p " " uuid-prefix))
                         (epi-ledger--uuid-prefix-p uuid-prefix))
                (push (cons type (- 36 (length uuid-prefix)))
                      candidates))))))))
    candidates))

(defun epi-ledger--headline-frame-prefix-minimum (fragment)
  "Return mandatory frame suffix bytes after headline FRAGMENT, or nil."
  (let (candidates)
    (dolist (candidate (epi-ledger--headline-prefix-candidates fragment))
      (let ((type (car candidate))
            (missing (cdr candidate))
            (seen (make-hash-table :test #'equal)))
        (push (+ missing
                 (length ":PROPERTIES:\n")
                 (epi-ledger--drawer-tail-minimum -1 seen type))
              candidates)))
    (when candidates (apply #'min candidates))))

(defun epi-ledger--json-prefix-with-cap-p (fragment limit offset)
  "Return FRAGMENT's minimum completion within LIMIT, or reject it.
FRAGMENT may be an owned unibyte string or a private source region.  OFFSET is
the absolute byte position used in structured limit errors."
  (let* ((fragment-length (epi-ledger--source-length fragment))
         (result (epi-ledger--jcs-lex-result fragment))
         (kind (plist-get result :kind)))
    (cond
     ((eq kind 'complete) 0)
     ((eq kind 'incomplete)
      (let ((minimum
             (or (plist-get result :minimum-completion-bytes) 1)))
        (if (<= (+ fragment-length minimum)
              limit)
            minimum
          (epi-ledger--limit-fail 'record-json-byte-limit
                                  :limit limit
                                  :offset (+ offset fragment-length)))))
     (t nil))))

(defun epi-ledger--drawer-name-end (line)
  "Return the bounded closing-colon index of LINE's drawer name, or nil."
  (let ((index 1)
        (limit (min (length line) 32))
        found)
    (when (and (> (length line) 3) (= (aref line 0) ?:))
      (while (and (< index limit) (not found))
        (if (= (aref line index) ?:)
            (setq found index)
          (setq index (1+ index))))
      (and found
           (< (1+ found) (length line))
           (= (aref line (1+ found)) ?\s)
           found))))

(defun epi-ledger--drawer-value-range-p (name line start)
  "Return whether LINE's value range from START is exact for NAME."
  (let ((length (- (length line) start)))
    (cond
     ((member name '("EPI_ID" "EPI_PARENT" "EPI_TARGET"
                     "EPI_TURN" "EPI_OPERATION"))
      (and (= length 36)
           (epi-ledger--uuid-p (substring line start))))
     ((equal name "EPI_TYPE")
      (and (<= length 64)
           (epi-ledger--drawer-value-p name (substring line start))))
     ((equal name "EPI_SCHEMA")
      (and (= length 1) (= (aref line start) ?1)))
     ((equal name "EPI_AT")
      (equal 0 (epi-ledger--timestamp-scan line start (length line))))
     ((member name '("EPI_PREV_SHA256" "EPI_RECORD_SHA256"))
      (and (= length 64)
           (epi-ledger--hash-p (substring line start))))
     (t nil))))

(defun epi-ledger--source-range-equal-string-p
    (source start end expected work)
  "Return whether SOURCE's START..END range is exactly EXPECTED using WORK."
  (and (= (- end start) (length expected))
       (epi-ledger--source-range-prefix-p source start end expected work)))

(defun epi-ledger--source-fragment-prefix-of-string-p
    (source start end expected work)
  "Return whether SOURCE's START..END range prefixes EXPECTED using WORK."
  (let ((length (- end start))
        (index 0)
        (matched t))
    (when (<= length (length expected))
      (while (and matched (< index length))
        (let* ((amount
                (min (- length index)
                     (max 1 epi-ledger-work-byte-limit)))
               (limit (+ index amount)))
          (epi-ledger--work-charge work amount)
          (while (and matched (< index limit))
            (setq matched
                  (= (epi-ledger--source-byte source (+ start index))
                     (aref expected index))
                  index (1+ index)))))
      matched)))

(defun epi-ledger--source-uuid-prefix-p (source start end work)
  "Return whether SOURCE's START..END range prefixes a UUID using WORK."
  (let ((length (- end start))
        (index 0)
        (valid t))
    (when (<= length 36)
      (while (and valid (< index length))
        (epi-ledger--work-charge work 1)
        (let ((byte (epi-ledger--source-byte source (+ start index))))
          (setq valid
                (if (memq index '(8 13 18 23))
                    (= byte ?-)
                  (or (<= ?0 byte ?9) (<= ?a byte ?f)))))
        (setq index (1+ index)))
      valid)))

(defun epi-ledger--source-drawer-value-prefix-minimum
    (source name start end expected-id expected-type work)
  "Return minimum suffix for SOURCE drawer NAME at START..END using WORK.
EXPECTED-ID and EXPECTED-TYPE bind headline values for the incomplete line."
  (let ((length (- end start)))
    (cond
     ((equal name "EPI_ID")
      (and (epi-ledger--source-fragment-prefix-of-string-p
            source start end expected-id work)
           (- (length expected-id) length)))
     ((equal name "EPI_TYPE")
      (and (epi-ledger--source-fragment-prefix-of-string-p
            source start end expected-type work)
           (- (length expected-type) length)))
     ((member name '("EPI_PARENT" "EPI_TARGET" "EPI_TURN"
                     "EPI_OPERATION"))
      (and (epi-ledger--source-uuid-prefix-p source start end work)
           (- 36 length)))
     ((equal name "EPI_SCHEMA")
      (and (epi-ledger--source-fragment-prefix-of-string-p
            source start end "1" work)
           (- 1 length)))
     ((equal name "EPI_AT")
      (epi-ledger--timestamp-scan source start end))
     ((member name '("EPI_PREV_SHA256" "EPI_RECORD_SHA256"))
      (and
       (<= length 64)
       (let ((index 0)
             (valid t))
         (while (and valid (< index length))
           (epi-ledger--work-charge work 1)
           (let ((byte (epi-ledger--source-byte source (+ start index))))
             (setq valid (or (<= ?0 byte ?9) (<= ?a byte ?f))))
           (setq index (1+ index)))
         valid)
       (- 64 length))))))

(defun epi-ledger--source-drawer-prefix-minimum
    (source start end last-order seen expected-id expected-type work)
  "Return mandatory suffix for SOURCE drawer bytes at START..END using WORK.
LAST-ORDER and SEEN describe prior properties; EXPECTED-ID and EXPECTED-TYPE
bind headline values.  This is the zero-copy drawer-prefix counterpart."
  (let ((required (epi-ledger--drawer-required-names expected-type))
        (fragment-length (- end start))
        candidates)
    (when (and (cl-every (lambda (name) (gethash name seen)) required)
               (epi-ledger--source-fragment-prefix-of-string-p
                source start end ":END:" work))
      (push (+ (- (length ":END:") fragment-length)
               (epi-ledger--minimum-json-block-byte-size))
            candidates))
    (dolist (name (epi-ledger--drawer-allowed-names expected-type))
      (let* ((order (cl-position name epi-ledger--drawer-property-order
                                 :test #'equal))
             (prefix (concat ":" name ": "))
             (prefix-length (length prefix))
             (skips-required
              (cl-some
               (lambda (required-name)
                 (let ((required-order
                        (cl-position required-name
                                     epi-ledger--drawer-property-order
                                     :test #'equal)))
                   (and (> required-order last-order)
                        (< required-order order)
                        (not (gethash required-name seen)))))
               required))
             value-minimum)
        (when (and (> order last-order)
                   (not (gethash name seen))
                   (not skips-required)
                   (setq
                    value-minimum
                    (cond
                     ((epi-ledger--source-fragment-prefix-of-string-p
                       source start end prefix work)
                      (+ (- prefix-length fragment-length)
                         (epi-ledger--drawer-value-minimum-byte-length
                          name expected-type)))
                     ((and (>= fragment-length prefix-length)
                           (epi-ledger--source-range-prefix-p
                            source start end prefix work))
                      (epi-ledger--source-drawer-value-prefix-minimum
                       source name (+ start prefix-length) end
                       expected-id expected-type work)))))
          (push (+ value-minimum
                   (epi-ledger--drawer-tail-minimum
                    order seen expected-type name))
                candidates))))
    (when candidates (apply #'min candidates))))

(defun epi-ledger--source-drawer-name-end (source start end work)
  "Return SOURCE drawer name's closing colon in START..END using WORK."
  (let ((cursor (1+ start))
        (limit (min end (+ start 32)))
        found)
    (when (and (> (- end start) 3)
               (= (epi-ledger--source-byte source start) ?:))
      (while (and (< cursor limit) (not found))
        (epi-ledger--work-charge work 1)
        (if (= (epi-ledger--source-byte source cursor) ?:)
            (setq found cursor)
          (setq cursor (1+ cursor))))
      (and found
           (< (1+ found) end)
           (= (epi-ledger--source-byte source (1+ found)) ?\s)
           found))))

(defun epi-ledger--source-drawer-value
    (source name start end work)
  "Return validated SOURCE drawer value NAME from START..END using WORK.
All cold-open drawer values remain zero-copy source subregions."
  (let ((length (- end start)))
    (when
        (cond
         ((member name '("EPI_ID" "EPI_PARENT" "EPI_TARGET"
                         "EPI_TURN" "EPI_OPERATION"))
          (and (= length 36)
               (epi-ledger--source-uuid-prefix-p
                source start end work)))
         ((equal name "EPI_TYPE")
          (and
           (<= length 64)
           (let ((schemas epi-ledger--record-schemas)
                 matched)
             (while (and (consp schemas) (not matched))
               (let* ((schema (epi-ledger--work-car schemas work))
                      (next (epi-ledger--work-cdr schemas work))
                      (type (symbol-name
                             (epi-ledger--work-car schema work))))
                 (when (epi-ledger--source-range-equal-string-p
                        source start end type work)
                   (setq matched t))
                 (setq schemas next)))
             matched)))
         ((equal name "EPI_SCHEMA")
          (and (= length 1)
               (= (epi-ledger--source-byte source start) ?1)))
         ((equal name "EPI_AT")
          (equal 0 (epi-ledger--timestamp-scan source start end)))
         ((member name '("EPI_PREV_SHA256" "EPI_RECORD_SHA256"))
          (and (= length 64)
               (equal
                0
                (epi-ledger--source-drawer-value-prefix-minimum
                 source name start end nil nil work)))))
      (epi-ledger--source-subregion source start end))))

(defun epi-ledger--parse-drawer-source
    (source cursor frame-start expected-id expected-type &optional origin)
  "Parse SOURCE's strict cold-open drawer at CURSOR after FRAME-START.
EXPECTED-ID and EXPECTED-TYPE bind headline values; ORIGIN translates offsets."
  (epi-ledger--with-operation-work-state
    (let ((seen (make-hash-table :test #'equal))
          (last-order -1)
          (base (or origin 0))
          (work (epi-ledger--make-work-state))
          properties done)
      (while (not done)
        (let* ((line
                (condition-case nil
                    (epi-ledger--line-range-at
                     source cursor
                     (- epi-record-frame-byte-limit (- cursor frame-start))
                     'record-frame-byte-limit epi-record-frame-byte-limit base)
                  (end-of-file
                   (let ((minimum
                          (epi-ledger--source-drawer-prefix-minimum
                           source cursor (epi-ledger--source-length source)
                           last-order seen expected-id expected-type work)))
                     (unless minimum
                       (epi-ledger--format-fail
                        'invalid-property-prefix :offset (+ base cursor)))
                     (signal
                      'end-of-file
                      (list
                       (list :minimum-completion-bytes
                             (1+ minimum))))))))
               (line-start (nth 0 line))
               (line-end (nth 1 line))
               (next (nth 2 line)))
          (setq cursor next)
          (if (epi-ledger--source-range-equal-string-p
               source line-start line-end ":END:" work)
              (setq done t)
            (let ((name-end
                   (epi-ledger--source-drawer-name-end
                    source line-start line-end work)))
              (unless name-end
                (epi-ledger--format-fail
                 'invalid-property :offset (+ base cursor)))
              (let* ((name-start (1+ line-start))
                     (value-start (+ name-end 2))
                     (names epi-ledger--drawer-property-order)
                     (position 0)
                     name
                     order)
                (while (and (consp names) (null order))
                  (let ((candidate (epi-ledger--work-car names work))
                        (next-name (epi-ledger--work-cdr names work)))
                    (when (epi-ledger--source-range-equal-string-p
                           source name-start name-end candidate work)
                      (setq name candidate
                            order position))
                    (setq names next-name
                          position (1+ position))))
                (unless order
                  (epi-ledger--format-fail
                   'unknown-property :offset (+ base cursor)))
                (unless
                    (epi-ledger--work-member-p
                     name (epi-ledger--drawer-allowed-names expected-type)
                     work)
                  (epi-ledger--format-fail
                   'forbidden-property :property name
                   :offset (+ base cursor)))
                (epi-ledger--work-charge work 1)
                (when (or (gethash name seen) (<= order last-order))
                  (epi-ledger--format-fail
                   'property-order :offset (+ base cursor)))
                (let ((value
                       (epi-ledger--source-drawer-value
                        source name value-start line-end work)))
                  (unless value
                    (epi-ledger--format-fail
                     (if (equal name "EPI_SCHEMA")
                         'unsupported-schema
                       'invalid-property-value)
                     :property name :offset (+ base cursor)))
                  (when (or (and
                             (equal name "EPI_ID")
                             (not (epi-ledger--drawer-value-agrees-p
                                   value expected-id work)))
                            (and
                             (equal name "EPI_TYPE")
                             (not (epi-ledger--drawer-value-agrees-p
                                   value expected-type work))))
                    (epi-ledger--format-fail
                     (if (equal name "EPI_TYPE")
                         'drawer-json-disagreement
                       'invalid-property-value)
                     :property name :offset (+ base cursor)))
                  (epi-ledger--work-charge work 1)
                  (puthash name t seen)
                  (setq last-order order)
                  (let ((property
                         (epi-ledger--work-cons name value work)))
                    (setq properties
                          (epi-ledger--work-cons
                           property properties work)))))))))
      (let ((required-tail
             (epi-ledger--drawer-required-names expected-type)))
        (while (consp required-tail)
          (let ((required (epi-ledger--work-car required-tail work))
                (next (epi-ledger--work-cdr required-tail work)))
            (epi-ledger--work-charge work 1)
            (unless (gethash required seen)
              (epi-ledger--format-fail
               'missing-property :property required))
            (setq required-tail next))))
      (let ((ordered
             (epi-ledger--work-nreverse-list properties work)))
        (epi-ledger--work-cons
         ordered (epi-ledger--work-cons cursor nil work) work)))))

(defun epi-ledger--parse-drawer-owned
    (bytes cursor frame-start expected-id expected-type &optional origin)
  "Parse a strict drawer from BYTES at CURSOR after FRAME-START.
EXPECTED-ID and EXPECTED-TYPE bind completed drawer values to the headline.
Optional ORIGIN is added to reported byte offsets."
  (epi-ledger--with-operation-work-state
    (let ((seen (make-hash-table :test #'equal))
          (last-order -1)
          (base (or origin 0))
          (work (epi-ledger--make-work-state))
          properties done)
      (while (not done)
        (let* ((line-result
                (epi-ledger--line-at
                 bytes cursor
                 (- epi-record-frame-byte-limit (- cursor frame-start))
                 (lambda (fragment)
                   (epi-ledger--drawer-prefix-minimum
                    fragment last-order seen expected-id expected-type))
                 'invalid-property-prefix nil nil nil base))
               (line (epi-ledger--work-car line-result work))
               (result-tail (epi-ledger--work-cdr line-result work))
               (next (epi-ledger--work-car result-tail work)))
          (setq cursor next)
          (if (equal line ":END:")
              (setq done t)
            (let ((name-end (epi-ledger--drawer-name-end line)))
              (unless name-end
                (epi-ledger--format-fail
                 'invalid-property :offset (+ base cursor)))
              (let* ((name (substring line 1 name-end))
                     (value-start (+ name-end 2))
                     (names epi-ledger--drawer-property-order)
                     (position 0)
                     order)
                (while (and (consp names) (null order))
                  (let ((candidate (epi-ledger--work-car names work))
                        (next-name (epi-ledger--work-cdr names work)))
                    (when (equal name candidate)
                      (setq order position))
                    (setq names next-name
                          position (1+ position))))
                (unless order
                  (epi-ledger--format-fail
                   'unknown-property :offset (+ base cursor)))
                (unless
                    (epi-ledger--work-member-p
                     name (epi-ledger--drawer-allowed-names expected-type)
                     work)
                  (epi-ledger--format-fail
                   'forbidden-property :property name
                   :offset (+ base cursor)))
                (epi-ledger--work-charge work 1)
                (when (or (gethash name seen) (<= order last-order))
                  (epi-ledger--format-fail
                   'property-order :offset (+ base cursor)))
                (unless (epi-ledger--drawer-value-range-p
                         name line value-start)
                  (epi-ledger--format-fail
                   (if (equal name "EPI_SCHEMA")
                       'unsupported-schema
                     'invalid-property-value)
                   :property name :offset (+ base cursor)))
                (let ((value
                       (epi-ledger--copy-owned-unibyte-range
                        line value-start (length line) 'drawer-value work)))
                  (when (or (and (equal name "EPI_ID")
                                 (not (equal value expected-id)))
                            (and (equal name "EPI_TYPE")
                                 (not (equal value expected-type))))
                    (epi-ledger--format-fail
                     (if (equal name "EPI_TYPE")
                         'drawer-json-disagreement
                       'invalid-property-value)
                     :property name :offset (+ base cursor)))
                  (epi-ledger--work-charge work 1)
                  (puthash name t seen)
                  (setq last-order order)
                  (let ((property
                         (epi-ledger--work-cons name value work)))
                    (setq properties
                          (epi-ledger--work-cons
                           property properties work)))))))))
      (let ((required-tail
             (epi-ledger--drawer-required-names expected-type)))
        (while (consp required-tail)
          (let ((required (epi-ledger--work-car required-tail work))
                (next (epi-ledger--work-cdr required-tail work)))
            (epi-ledger--work-charge work 1)
            (unless (gethash required seen)
              (epi-ledger--format-fail
               'missing-property :property required))
            (setq required-tail next))))
      (let ((ordered
             (epi-ledger--work-nreverse-list properties work)))
        (epi-ledger--work-cons
         ordered (epi-ledger--work-cons cursor nil work) work)))))

(defun epi-ledger--parse-drawer
    (bytes cursor frame-start expected-id expected-type &optional origin)
  "Parse a strict drawer from BYTES at CURSOR after FRAME-START.
EXPECTED-ID and EXPECTED-TYPE bind headline values; ORIGIN translates offsets.
Cold buffer-region sources retain arbitrary-length values as range views;
owned strings keep the codec's exact prefix diagnostics."
  (if (epi-ledger--source-region-p bytes)
      (epi-ledger--parse-drawer-source
       bytes cursor frame-start expected-id expected-type origin)
    (epi-ledger--parse-drawer-owned
     bytes cursor frame-start expected-id expected-type origin)))

(defun epi-ledger--drawer-value (drawer name)
  "Return property NAME from DRAWER."
  (cdr (assoc-string name drawer nil)))

(defun epi-ledger--record-from-envelope
    (envelope hash sequence start json-start json-end end frame-size)
  "Build a record from validated ENVELOPE with HASH and physical metadata.
SEQUENCE gives its ordinal; START and END bound its frame.  JSON-START and
JSON-END bound its body, whose containing frame has FRAME-SIZE bytes."
  (epi-ledger--closed-object
   envelope '("id" "type" "schema" "at" "previous_hash" "payload")
   '("parent" "target" "turn" "operation") "envelope")
  (let* ((type-text (epi-ledger--object-value envelope "type"))
         (type (and (stringp type-text) (intern-soft type-text)))
         (_presence
          (epi-ledger--validate-envelope-presence envelope type))
         (record
          (epi-ledger--make-record
           :id (epi-ledger--object-value envelope "id")
           :type type :schema (epi-ledger--object-value envelope "schema")
           :at (epi-ledger--object-value envelope "at")
           :previous-hash
           (epi-ledger--object-value envelope "previous_hash")
           :parent (epi-ledger--object-value envelope "parent")
           :target (epi-ledger--object-value envelope "target")
           :turn (epi-ledger--object-value envelope "turn")
           :operation (epi-ledger--object-value envelope "operation")
           :payload (epi-ledger--object-value envelope "payload")
           :hash hash :sequence sequence :start-offset start
           :json-start-offset json-start :json-end-offset json-end
           :end-offset end :frame-byte-size frame-size :sealed-json nil)))
    ;; The loader's semantic vocabulary is deliberately more precise than the
    ;; reusable codec vocabulary.  Detect these envelope contradictions before
    ;; the generic field validator collapses them to an authoring-time error.
    (unless (eq (epi-record--raw-schema record) 1)
      (epi-ledger--format-fail 'unsupported-schema))
    (pcase type
      ('operation-started
       (unless (equal
                (epi-record--raw-operation record)
                (epi-ledger--object-value
                 (epi-record--raw-payload record) "operation_id"))
         (epi-ledger--format-fail 'operation-envelope-payload-id)))
      ('turn-started
       (unless (equal
                (epi-record--raw-turn record)
                (epi-ledger--object-value
                 (epi-record--raw-payload record) "turn_id"))
         (epi-ledger--format-fail 'turn-envelope-payload-id))
       (unless (equal
                (epi-record--raw-operation record)
                (epi-ledger--object-value
                 (epi-record--raw-payload record) "operation_id"))
         (epi-ledger--format-fail 'turn-operation-payload-id)))
      ('tool-finished
       (unless (member
                (epi-ledger--object-value
                 (epi-record--raw-payload record) "status")
                '("success" "error" "cancelled" "timeout" "uncertain"))
         (epi-ledger--format-fail 'invalid-tool-status))))
    (let ((epi-ledger--canonical-value-preflighted t))
      (epi-ledger--validate-record-fields record))
    record))

(defun epi-ledger--drawer-value-agrees-p (drawer-value record-value work)
  "Return whether DRAWER-VALUE equals RECORD-VALUE using bounded WORK."
  (if (epi-ledger--source-region-p drawer-value)
      (and (stringp record-value)
           (= (epi-ledger--source-length drawer-value)
              (length record-value))
           (let ((cursor 0)
                 (length (length record-value))
                 (matched t))
             (while (and matched (< cursor length))
               (let* ((amount
                       (min (- length cursor)
                            (max 1 epi-ledger-work-byte-limit)))
                      (end (+ cursor amount)))
                 (epi-ledger--work-charge work amount)
                 (while (and matched (< cursor end))
                   (setq matched
                         (= (epi-ledger--source-byte drawer-value cursor)
                            (aref record-value cursor))
                         cursor (1+ cursor)))))
             matched))
    (epi-ledger--work-equal
     drawer-value record-value 'drawer-agreement work)))

(defun epi-ledger--validate-drawer-agreement (headline-type headline-id
                                                            drawer record)
  "Validate that HEADLINE-TYPE, HEADLINE-ID, and DRAWER agree with RECORD."
  (let ((work (epi-ledger--make-work-state))
        (pairs
         `(("EPI_ID" . ,(epi-record--raw-id record))
           ("EPI_TYPE" . ,(symbol-name (epi-record--raw-type record)))
           ("EPI_SCHEMA" . ,(number-to-string
                              (epi-record--raw-schema record)))
           ("EPI_AT" . ,(epi-record--raw-at record))
           ("EPI_PARENT" . ,(epi-record--raw-parent record))
           ("EPI_TARGET" . ,(epi-record--raw-target record))
           ("EPI_TURN" . ,(epi-record--raw-turn record))
           ("EPI_OPERATION" . ,(epi-record--raw-operation record))
           ("EPI_PREV_SHA256" . ,(epi-record--raw-previous-hash record))
           ("EPI_RECORD_SHA256" . ,(epi-record--raw-hash record)))))
    (unless (and
             (epi-ledger--work-equal
              headline-type (symbol-name (epi-record--raw-type record))
              'drawer-agreement work)
             (epi-ledger--work-equal
              headline-id (epi-record--raw-id record)
              'drawer-agreement work))
      (epi-ledger--format-fail 'headline-json-disagreement))
    (dolist (pair pairs)
      (unless (epi-ledger--drawer-value-agrees-p
               (epi-ledger--drawer-value drawer (car pair)) (cdr pair) work)
        (epi-ledger--format-fail 'drawer-json-disagreement
                                 :property (car pair))))))

(defun epi-ledger--scan-frame-complete (bytes offset sequence &optional origin)
  "Scan one complete record frame in BYTES at OFFSET and SEQUENCE.
ORIGIN is the absolute position represented by byte zero of owned BYTES."
  (epi-ledger--with-operation-work-state
    (let* ((cursor offset)
           (base (or origin 0))
           (work (epi-ledger--make-work-state))
           (headline-result
            (epi-ledger--line-at
             bytes cursor (1+ epi-ledger--maximum-headline-byte-length)
             #'epi-ledger--headline-frame-prefix-minimum
             'invalid-headline 'invalid-headline
             epi-ledger--maximum-headline-byte-length nil base))
           (headline (epi-ledger--work-car headline-result work))
           (headline-tail (epi-ledger--work-cdr headline-result work))
           (after-headline (epi-ledger--work-car headline-tail work)))
    (setq cursor after-headline)
    (unless (and
             (<= (length headline) epi-ledger--maximum-headline-byte-length)
             (string-match
              "\\`\\* \\([a-z][a-z0-9-]*\\) \\([0-9a-f-]+\\)\\'"
              headline))
      (epi-ledger--format-fail
       'invalid-headline :offset (+ base offset)))
    (let ((headline-type (match-string 1 headline))
          (headline-id (match-string 2 headline)))
      (unless (and (epi-ledger--uuid-p headline-id)
                   (let ((type (intern-soft headline-type)))
                     (and type (assq type epi-ledger--record-schemas))))
        (epi-ledger--format-fail
         'invalid-headline :offset (+ base offset)))
      (let* ((properties-result
              (epi-ledger--line-at
               bytes cursor
               (- epi-record-frame-byte-limit (- cursor offset))
               (lambda (fragment)
                 (and (epi-ledger--literal-prefix-p
                       fragment ":PROPERTIES:")
                      (+ (- (length ":PROPERTIES:")
                            (length fragment))
                         (epi-ledger--drawer-tail-minimum
                          -1 (make-hash-table :test #'equal)
                          headline-type))))
               'missing-property-drawer nil nil nil base))
             (properties-line
              (epi-ledger--work-car properties-result work))
             (properties-tail
              (epi-ledger--work-cdr properties-result work))
             (next (epi-ledger--work-car properties-tail work)))
        (unless (equal properties-line ":PROPERTIES:")
          (epi-ledger--format-fail
           'missing-property-drawer :offset (+ base cursor)))
        (setq cursor next))
      (let* ((drawer-result
              (epi-ledger--parse-drawer
               bytes cursor offset headline-id headline-type base))
             (drawer (epi-ledger--work-car drawer-result work))
             (drawer-tail (epi-ledger--work-cdr drawer-result work))
             (next (epi-ledger--work-car drawer-tail work)))
        (setq cursor next)
        (let* ((begin-result
                (epi-ledger--line-at
                 bytes cursor
                 (- epi-record-frame-byte-limit (- cursor offset))
                 (lambda (fragment)
                   (and (epi-ledger--literal-prefix-p
                         fragment "#+begin_epi-json")
                        (+ (- (length "#+begin_epi-json")
                              (length fragment))
                           2
                           (length "\n#+end_epi-json\n"))))
                 'missing-json-begin nil nil nil base))
               (begin (epi-ledger--work-car begin-result work))
               (begin-tail (epi-ledger--work-cdr begin-result work))
               (after-begin (epi-ledger--work-car begin-tail work)))
          (unless (equal begin "#+begin_epi-json")
            (epi-ledger--format-fail
             'missing-json-begin :offset (+ base cursor)))
          (setq cursor after-begin))
        (let* ((json-start cursor)
               (source-region-p (epi-ledger--source-region-p bytes))
               (remaining-frame-bytes
                (- epi-record-frame-byte-limit (- cursor offset)))
               (json-line-limit
                (min remaining-frame-bytes
                     (1+ epi-record-json-byte-limit)))
               (json-limit-active
                (<= (1+ epi-record-json-byte-limit)
                    remaining-frame-bytes))
               (json-line
                (if source-region-p
                    (condition-case nil
                        (epi-ledger--line-range-at
                         bytes cursor json-line-limit
                         (if json-limit-active
                             'record-json-byte-limit
                           'record-frame-byte-limit)
                         (if json-limit-active
                             epi-record-json-byte-limit
                           json-line-limit)
                         base)
                      (end-of-file
                       (let* ((fragment
                               (epi-ledger--source-subregion
                                bytes cursor
                                (epi-ledger--source-length bytes)))
                              (minimum
                               (epi-ledger--json-prefix-with-cap-p
                                fragment epi-record-json-byte-limit
                                (+ base cursor))))
                         (unless minimum
                           (epi-ledger--format-fail
                            'invalid-json-prefix :offset (+ base cursor)))
                         (signal
                          'end-of-file
                          (list
                           (list
                            :minimum-completion-bytes
                            (+ minimum 1
                               (1+ (length "#+end_epi-json")))))))))
                  (epi-ledger--line-at
                   bytes cursor json-line-limit
                   (lambda (fragment)
                     (epi-ledger--json-prefix-with-cap-p
                      fragment epi-record-json-byte-limit (+ base cursor)))
                   'invalid-json-prefix
                   (if json-limit-active
                       'record-json-byte-limit
                     'record-frame-byte-limit)
                   (if json-limit-active
                       epi-record-json-byte-limit
                     json-line-limit)
                   (1+ (length "#+end_epi-json"))
                   base)))
               (json-text
                (and (not source-region-p)
                     (epi-ledger--work-car json-line work)))
               (json-tail
                (and (not source-region-p)
                     (epi-ledger--work-cdr json-line work)))
               (json-end
                (if source-region-p
                    (nth 1 json-line)
                  (+ cursor (length json-text))))
               (after-json
                (if source-region-p
                    (nth 2 json-line)
                  (epi-ledger--work-car json-tail work)))
               (json
                (epi-ledger--source-subregion bytes cursor json-end))
               (json-size (- json-end cursor)))
          (setq cursor after-json)
          (let* ((end-result
                  (epi-ledger--line-at
                   bytes cursor
                   (- epi-record-frame-byte-limit (- cursor offset))
                   (lambda (fragment)
                     (and (epi-ledger--literal-prefix-p
                           fragment "#+end_epi-json")
                          (- (length "#+end_epi-json")
                             (length fragment))))
                   'missing-json-end nil nil nil base))
                 (end-line (epi-ledger--work-car end-result work))
                 (end-tail (epi-ledger--work-cdr end-result work))
                 (next (epi-ledger--work-car end-tail work)))
            (unless (equal end-line "#+end_epi-json")
              (epi-ledger--format-fail
               'missing-json-end :offset (+ base cursor)))
            (setq cursor next))
          (let ((frame-size (- cursor offset)))
            (when (> frame-size epi-record-frame-byte-limit)
              (epi-ledger--limit-fail 'record-frame-byte-limit
                                      :limit epi-record-frame-byte-limit))
            (when (> json-size epi-record-json-byte-limit)
              (epi-ledger--limit-fail 'record-json-byte-limit
                                      :limit epi-record-json-byte-limit))
            (let* ((actual-hash (epi-ledger--source-hash json 'record))
                   (stored-hash
                    (epi-ledger--drawer-value drawer "EPI_RECORD_SHA256")))
              (unless (epi-ledger--drawer-value-agrees-p
                       stored-hash actual-hash work)
                (epi-ledger--format-fail 'record-hash-mismatch
                                         :offset (+ base json-start)))
              (epi-ledger--jcs-validate-bytes json (+ base json-start))
              (let* ((envelope (epi-ledger--decode-json-source json))
                     (record
                      (epi-ledger--record-from-envelope
                       envelope actual-hash sequence (+ base offset)
                       (+ base json-start) (+ base json-end)
                       (+ base cursor) frame-size)))
                (epi-ledger--validate-drawer-agreement
                 headline-type headline-id drawer record)
                (list :state 'complete :code 'ok :offset (+ base offset)
                      :json-start-offset (+ base json-start)
                      :json-end-offset (+ base json-end)
                      :end-offset (+ base cursor)
                      :next-offset (+ base cursor) :record record))))))))))

(defun epi-ledger--condition-plist (condition)
  "Return the one structured plist carried by Epi CONDITION."
  (let* ((work (epi-ledger--make-work-state))
         (data (epi-ledger--work-cdr condition work)))
    (when (consp data)
      (let ((detail (epi-ledger--work-car data work))
            (rest (epi-ledger--work-cdr data work)))
        (and (null rest) detail)))))

(defun epi-ledger--scan-frame-owned
    (bytes &optional offset sequence offset-origin)
  "Incrementally scan one frame from immutable owned unibyte BYTES.
OFFSET defaults to zero, SEQUENCE defaults to one, and OFFSET-ORIGIN is added
to every reported byte position.  Return a plist whose
`:state' is `complete', `incomplete', `invalid', or `eof'.  Complete results
contain RECORD and exact next/end/JSON offsets.  Other non-EOF results contain
a stable `:code', byte `:offset', and redacted canonical `:cause'."
  (epi-ledger--with-operation-work-state
   (let ((start (or offset 0))
        (origin (or offset-origin 0)))
    (cond
     ((not (or (epi-ledger--source-region-p bytes)
               (and (stringp bytes) (not (multibyte-string-p bytes)))))
      (list :state 'invalid :code 'unibyte-frame-required
            :offset (+ origin start)
            :cause '(:code unibyte-frame-required)))
     ((not (and (integerp start)
                (<= 0 start (epi-ledger--source-length bytes))))
      (list :state 'invalid :code 'invalid-offset :offset origin
            :cause '(:code invalid-offset)))
     ((= start (epi-ledger--source-length bytes))
      (list :state 'eof :code 'clean-eof :offset (+ origin start)
            :next-offset (+ origin start)))
     (t
      (condition-case condition
          (epi-ledger--scan-frame-complete
           bytes start (or sequence 1) origin)
        (end-of-file
         (let* ((detail (epi-ledger--condition-plist condition))
                (minimum
                 (or (plist-get detail :minimum-completion-bytes) 1)))
           (if (> (+ (- (epi-ledger--source-length bytes) start) minimum)
                  epi-record-frame-byte-limit)
             (list :state 'invalid :code 'record-frame-byte-limit
                   :offset (+ origin start epi-record-frame-byte-limit)
                   :cause (list :code 'record-frame-byte-limit))
             (list :state 'incomplete :code 'truncated-frame
                   :offset (+ origin (epi-ledger--source-length bytes))
                   :fragment-start-offset (+ origin start)
                   :fragment-byte-size
                   (- (epi-ledger--source-length bytes) start)
                   :cause (list :code 'truncated-frame)))))
        (epi-ledger-error
         (let* ((detail (epi-ledger--condition-plist condition))
                (code (or (plist-get detail :code) 'invalid-frame))
                (position (or (plist-get detail :offset)
                              (+ origin start))))
           (list :state 'invalid :code code :offset position
                 :cause (list :code code))))
        (epi-limit-exceeded
         (let* ((detail (epi-ledger--condition-plist condition))
                (code (or (plist-get detail :code) 'limit-exceeded))
                (position (or (plist-get detail :offset)
                              (+ origin start))))
           (list :state 'invalid :code code :offset position
                 :cause (list :code code))))
        (error
         (list :state 'invalid :code 'invalid-frame
               :offset (+ origin start)
               :cause (list :code 'invalid-frame)))))))))

(defun epi-ledger--scan-frame (bytes &optional offset sequence)
  "Snapshot and scan one bounded frame from caller-owned unibyte BYTES.
OFFSET defaults to zero and SEQUENCE defaults to one.  Code that already owns
an immutable carry window may call `epi-ledger--scan-frame-owned' directly."
  (let ((start (or offset 0)))
    (cond
     ((not (and (stringp bytes) (not (multibyte-string-p bytes))))
      (list :state 'invalid :code 'unibyte-frame-required :offset start
            :cause '(:code unibyte-frame-required)))
     ((not (and (integerp start) (<= 0 start (length bytes))))
      (list :state 'invalid :code 'invalid-offset :offset 0
            :cause '(:code invalid-offset)))
     ((= start (length bytes))
      (list :state 'eof :code 'clean-eof :offset start :next-offset start))
     (t
      (epi-ledger--scan-frame-owned
      (epi-ledger--snapshot-byte-window
        bytes start epi-record-frame-byte-limit)
       0 sequence start)))))

;;;; Read-only ledger loading and cross-record validation

(cl-defstruct (epi-ledger--validation-state
               (:constructor epi-ledger--make-validation-state))
  records-reverse by-id operations turns turn-operation-index
  calls calls-by-target reserved-call-ids intents active-operation active-call
  session-seen first-nonsession pending-proposal pending-result
  terminalization-required
  recovery-evidence latest-recovery-origin recovery-terminalization-required
  deferred-references uncertain uncertainty-phase uncertainty-class
  uncertainty-turn uncertainty-operation)

(defun epi-ledger--semantic-capsule-from-state (state)
  "Publish STATE's semantic roots as an immutable-by-convention capsule.
The transient reverse record accumulator is intentionally not represented."
  (when (epi-ledger--validation-state-records-reverse state)
    (epi-ledger--format-fail
     'semantic-capsule-record-accumulator-not-empty))
  (epi-ledger--make-semantic-capsule
   :by-id (epi-ledger--validation-state-by-id state)
   :operations (epi-ledger--validation-state-operations state)
   :turns (epi-ledger--validation-state-turns state)
   :turn-operation-index
   (epi-ledger--validation-state-turn-operation-index state)
   :calls (epi-ledger--validation-state-calls state)
   :calls-by-target (epi-ledger--validation-state-calls-by-target state)
   :reserved-call-ids
   (epi-ledger--validation-state-reserved-call-ids state)
   :intents (epi-ledger--validation-state-intents state)
   :active-operation (epi-ledger--validation-state-active-operation state)
   :active-call (epi-ledger--validation-state-active-call state)
   :session-seen (epi-ledger--validation-state-session-seen state)
   :first-nonsession (epi-ledger--validation-state-first-nonsession state)
   :pending-proposal (epi-ledger--validation-state-pending-proposal state)
   :pending-result (epi-ledger--validation-state-pending-result state)
   :terminalization-required
   (epi-ledger--validation-state-terminalization-required state)
   :recovery-evidence
   (epi-ledger--validation-state-recovery-evidence state)
   :latest-recovery-origin
   (epi-ledger--validation-state-latest-recovery-origin state)
   :recovery-terminalization-required
   (epi-ledger--validation-state-recovery-terminalization-required state)
   :deferred-references
   (epi-ledger--validation-state-deferred-references state)
   :uncertain (epi-ledger--validation-state-uncertain state)
   :uncertainty-phase
   (epi-ledger--validation-state-uncertainty-phase state)
   :uncertainty-class
   (epi-ledger--validation-state-uncertainty-class state)
   :uncertainty-turn
   (epi-ledger--validation-state-uncertainty-turn state)
   :uncertainty-operation
   (epi-ledger--validation-state-uncertainty-operation state)))

(defun epi-ledger--semantic-capsule-clone (capsule)
  "Return one mutable validation accumulator cloned from CAPSULE.
All mutable graph nodes are copied through one identity memo, preserving
aliases and cycles within the clone.  Immutable `epi-record' leaves remain
shared.  The returned record accumulator starts empty."
  (unless (epi-ledger--semantic-capsule-p capsule)
    (signal 'wrong-type-argument
            (list 'epi-ledger--semantic-capsule-p capsule)))
  (let ((memo (make-hash-table :test #'eq)))
    (cl-labels
        ((clone
          (node)
          (cond
           ((or (null node) (numberp node) (symbolp node)
                (epi-record-p node))
            node)
           ((gethash node memo))
           ((stringp node)
            (let ((copy (substring-no-properties node)))
              (puthash node copy memo)
              copy))
           ((consp node)
            (let ((copy (cons nil nil)))
              (puthash node copy memo)
              (setcar copy (clone (car node)))
              (setcdr copy (clone (cdr node)))
              copy))
           ((hash-table-p node)
            (let ((copy (copy-hash-table node)))
              (clrhash copy)
              (puthash node copy memo)
              (maphash (lambda (key value)
                         (puthash (clone key) (clone value) copy))
                       node)
              copy))
           ((vectorp node)
            (let ((copy (make-vector (length node) nil)))
              (puthash node copy memo)
              (dotimes (index (length node))
                (aset copy index (clone (aref node index))))
              copy))
           (t
            (epi-ledger--format-fail
             'unsupported-semantic-node :type (type-of node))))))
      (epi-ledger--make-validation-state
       :records-reverse nil
       :by-id (clone (epi-ledger--semantic-capsule-raw-by-id capsule))
       :operations
       (clone (epi-ledger--semantic-capsule-raw-operations capsule))
       :turns (clone (epi-ledger--semantic-capsule-raw-turns capsule))
       :turn-operation-index
       (clone
        (epi-ledger--semantic-capsule-raw-turn-operation-index capsule))
       :calls (clone (epi-ledger--semantic-capsule-raw-calls capsule))
       :calls-by-target
       (clone (epi-ledger--semantic-capsule-raw-calls-by-target capsule))
       :reserved-call-ids
       (clone (epi-ledger--semantic-capsule-raw-reserved-call-ids capsule))
       :intents (clone (epi-ledger--semantic-capsule-raw-intents capsule))
       :active-operation
       (clone (epi-ledger--semantic-capsule-raw-active-operation capsule))
       :active-call
       (clone (epi-ledger--semantic-capsule-raw-active-call capsule))
       :session-seen
       (clone (epi-ledger--semantic-capsule-raw-session-seen capsule))
       :first-nonsession
       (clone (epi-ledger--semantic-capsule-raw-first-nonsession capsule))
       :pending-proposal
       (clone (epi-ledger--semantic-capsule-raw-pending-proposal capsule))
       :pending-result
       (clone (epi-ledger--semantic-capsule-raw-pending-result capsule))
       :terminalization-required
       (clone
        (epi-ledger--semantic-capsule-raw-terminalization-required capsule))
       :recovery-evidence
       (clone (epi-ledger--semantic-capsule-raw-recovery-evidence capsule))
       :latest-recovery-origin
       (clone
        (epi-ledger--semantic-capsule-raw-latest-recovery-origin capsule))
       :recovery-terminalization-required
       (clone
        (epi-ledger--semantic-capsule-raw-recovery-terminalization-required
         capsule))
       :deferred-references
       (clone
        (epi-ledger--semantic-capsule-raw-deferred-references capsule))
       :uncertain
       (clone (epi-ledger--semantic-capsule-raw-uncertain capsule))
       :uncertainty-phase
       (clone (epi-ledger--semantic-capsule-raw-uncertainty-phase capsule))
       :uncertainty-class
       (clone (epi-ledger--semantic-capsule-raw-uncertainty-class capsule))
       :uncertainty-turn
       (clone (epi-ledger--semantic-capsule-raw-uncertainty-turn capsule))
       :uncertainty-operation
       (clone
        (epi-ledger--semantic-capsule-raw-uncertainty-operation capsule))))))

(defun epi-ledger--validation-suffix-records (state work)
  "Extract STATE's newly validated records in physical order using WORK.
Clear the reverse accumulator before returning so no published capsule can
retain a second all-record list spine."
  (let ((reverse (epi-ledger--validation-state-records-reverse state)))
    (setf (epi-ledger--validation-state-records-reverse state) nil)
    (epi-ledger--work-nreverse-list reverse work)))

(defun epi-ledger--resolve-local-write-path (path)
  "Return an owned canonical local file name for caller-supplied PATH.
Resolve only an existing ancestor, then append validated absent components.
Reject handlers before remote-name detection or any handler bypass."
  (unless (stringp path)
    (epi-ledger--format-fail 'invalid-write-path))
  (let ((owned (substring-no-properties path)))
    (when (or (string-empty-p owned)
              (string-match-p "[\0\r\n]" owned)
              (directory-name-p owned)
              (find-file-name-handler owned 'write-region))
      (epi-ledger--format-fail 'invalid-write-path))
    (when (condition-case nil (file-remote-p owned) (error t))
      (epi-ledger--format-fail 'invalid-write-path))
    (unless (file-name-absolute-p owned)
      (epi-ledger--format-fail 'invalid-write-path))
    (let ((expanded
           (condition-case nil
               (expand-file-name owned)
             (error (epi-ledger--format-fail 'invalid-write-path)))))
      (unless (equal owned expanded)
        (epi-ledger--format-fail 'invalid-write-path))
      (let ((probe expanded)
            missing
            exists)
        (while (not exists)
          (when (or (find-file-name-handler probe 'file-exists-p)
                    (condition-case nil (file-remote-p probe) (error t)))
            (epi-ledger--format-fail 'invalid-write-path))
          (setq exists
                (condition-case nil
                    (file-exists-p probe)
                  (file-error
                   (epi-ledger--format-fail 'invalid-write-path))))
          (unless exists
            (when (condition-case nil
                      (file-symlink-p probe)
                    (file-error
                     (epi-ledger--format-fail 'invalid-write-path)))
              (epi-ledger--format-fail 'invalid-write-path))
            (let* ((component (file-name-nondirectory probe))
                   (parent
                    (directory-file-name (file-name-directory probe))))
              (when (or (string-empty-p component)
                        (member component '("." ".."))
                        (equal parent probe))
                (epi-ledger--format-fail 'invalid-write-path))
              (push component missing)
              (setq probe parent))))
        (when (and (null missing)
                   (condition-case nil
                       (file-symlink-p probe)
                     (file-error
                      (epi-ledger--format-fail 'invalid-write-path))))
          (epi-ledger--format-fail 'non-regular-storage-leaf))
        (when (or (find-file-name-handler probe 'file-truename)
                  (condition-case nil (file-remote-p probe) (error t)))
          (epi-ledger--format-fail 'invalid-write-path))
        (unless
            (condition-case nil
                (if missing
                    (file-directory-p probe)
                  (file-regular-p probe))
              (file-error
               (epi-ledger--format-fail 'invalid-write-path)))
          (epi-ledger--format-fail
           (if missing 'non-directory-parent 'non-regular-storage-leaf)))
        (let ((resolved
               (condition-case nil
                   (file-truename probe)
                 (file-error
                  (epi-ledger--format-fail 'invalid-write-path)))))
          (dolist (component missing)
            (setq resolved
                  (expand-file-name component
                                    (file-name-as-directory resolved))))
          (when (or (find-file-name-handler resolved 'write-region)
                    (condition-case nil
                        (file-remote-p resolved)
                      (error t)))
            (epi-ledger--format-fail 'invalid-write-path))
          (substring-no-properties resolved))))))

(defun epi-ledger--resolve-local-directory-path (path)
  "Return an owned canonical local directory name for PATH.
PATH may be absent, but its nearest existing ancestor must be a local
directory.  The returned spelling has no trailing slash."
  (unless (stringp path)
    (epi-ledger--format-fail 'invalid-write-path))
  (let ((raw (substring-no-properties path)))
    (when (or (find-file-name-handler raw 'directory-file-name)
              (find-file-name-handler raw 'expand-file-name)
              (find-file-name-handler raw 'file-exists-p)
              (find-file-name-handler raw 'file-attributes))
      (epi-ledger--format-fail 'invalid-write-path))
    (let ((owned (directory-file-name raw)))
      (when (or (string-empty-p owned)
              (string-match-p "[\0\r\n]" owned)
              (not (file-name-absolute-p owned))
              (find-file-name-handler owned 'expand-file-name)
              (find-file-name-handler owned 'file-exists-p)
              (find-file-name-handler owned 'file-attributes))
        (epi-ledger--format-fail 'invalid-write-path))
      (let* ((expanded
            (condition-case nil
                (directory-file-name (expand-file-name owned))
              (error (epi-ledger--format-fail 'invalid-write-path))))
           (_local
            (when (condition-case nil (file-remote-p expanded) (error t))
              (epi-ledger--format-fail 'invalid-write-path)))
           (probe expanded)
          missing
          exists)
      (while (not exists)
        (when (or (find-file-name-handler probe 'file-exists-p)
                  (find-file-name-handler probe 'file-attributes)
                  (condition-case nil (file-remote-p probe) (error t)))
          (epi-ledger--format-fail 'invalid-write-path))
        (setq exists
              (condition-case nil
                  (file-exists-p probe)
                (file-error
                 (epi-ledger--format-fail 'invalid-write-path))))
        (unless exists
          (when (condition-case nil
                    (file-symlink-p probe)
                  (file-error
                   (epi-ledger--format-fail 'invalid-write-path)))
            (epi-ledger--format-fail 'invalid-write-path))
          (let* ((component (file-name-nondirectory probe))
                 (parent
                  (directory-file-name (file-name-directory probe))))
            (when (or (string-empty-p component)
                      (member component '("." ".."))
                      (equal parent probe))
              (epi-ledger--format-fail 'invalid-write-path))
            (push component missing)
            (setq probe parent))))
      (unless (condition-case nil
                  (file-directory-p probe)
                (file-error nil))
        (epi-ledger--format-fail 'non-directory-parent))
      (when (or (find-file-name-handler probe 'file-truename)
                (condition-case nil (file-remote-p probe) (error t)))
        (epi-ledger--format-fail 'invalid-write-path))
      (let ((resolved
             (condition-case nil
                 (directory-file-name (file-truename probe))
               (file-error
                (epi-ledger--format-fail 'invalid-write-path)))))
        (dolist (component missing)
          (setq resolved
                (expand-file-name component
                                  (file-name-as-directory resolved))))
        (when (or (find-file-name-handler resolved 'make-directory)
                  (find-file-name-handler resolved 'file-attributes)
                  (condition-case nil (file-remote-p resolved) (error t)))
          (epi-ledger--format-fail 'invalid-write-path))
        (directory-file-name (substring-no-properties resolved)))))))

(defun epi-ledger--ensure-private-parent (path)
  "Create PATH's absent parent directories one at a time with mode 0700.
Existing directories retain their modes.  Return PATH's canonical parent."
  (let* ((canonical (epi-ledger--resolve-local-write-path path))
         (probe (directory-file-name (file-name-directory canonical)))
         missing)
    (condition-case condition
        (let ((file-name-handler-alist nil))
          (while (not (file-exists-p probe))
            (when (file-symlink-p probe)
              (epi-ledger--format-fail 'invalid-write-path))
            (push probe missing)
            (let ((parent
                   (directory-file-name (file-name-directory probe))))
              (when (equal parent probe)
                (epi-ledger--format-fail 'non-directory-parent))
              (setq probe parent)))
          (unless (and (file-directory-p probe)
                       (not (file-symlink-p probe)))
            (epi-ledger--format-fail 'non-directory-parent))
          (dolist (directory missing)
            (condition-case create-condition
                (progn
                  (with-file-modes #o700
                    (make-directory directory nil))
                  (set-file-modes directory #o700))
              (file-already-exists
               (unless (and (file-directory-p directory)
                            (not (file-symlink-p directory)))
                 (epi-ledger--fail
                  'epi-ledger-conflict 'storage-write-failed)))
              (file-error
               (ignore create-condition)
               (epi-ledger--fail
                'epi-ledger-conflict 'storage-write-failed)))))
      (file-error
       (ignore condition)
       (epi-ledger--fail 'epi-ledger-conflict 'storage-write-failed)))
    (file-name-as-directory
     (substring-no-properties
      (directory-file-name (file-name-directory canonical))))))

(defun epi-ledger--hidden-sibling (path &optional suffix)
  "Return a hidden sibling of canonical PATH using optional SUFFIX.
When SUFFIX is nil, generate a fresh Epi temporary suffix."
  (let* ((canonical (epi-ledger--resolve-local-write-path path))
         (owned-suffix
          (substring-no-properties
           (or suffix (concat "epi-tmp-" (epi--new-id))))))
    (when (or (string-empty-p owned-suffix)
              (string-match-p "[\0\r\n/]" owned-suffix)
              (member owned-suffix '("." "..")))
      (epi-ledger--format-fail 'invalid-hidden-sibling-suffix))
    (expand-file-name
     (concat "." (file-name-nondirectory canonical) "." owned-suffix)
     (file-name-directory canonical))))

(defun epi-ledger--write-bytes (path bytes mode durablep)
  "Write owned unibyte BYTES to proven-local PATH in closed MODE.
MODE is `exclusive-create', `append', or `replace'.  DURABLEP enables the
`write-region' fsync path.  Return nil after an exact no-conversion write."
  (unless (memq mode '(exclusive-create append replace))
    (epi-ledger--format-fail 'invalid-write-mode :mode mode))
  (unless (and (stringp bytes) (not (multibyte-string-p bytes)))
    (epi-ledger--format-fail 'unibyte-write-required))
  (when (and (> (length bytes) 0)
             (or (text-properties-at 0 bytes)
                 (let ((change (next-property-change 0 bytes)))
                   (and change (< change (length bytes))))))
    (epi-ledger--format-fail 'property-free-write-required))
  ;; Resolution performs the handler and locality proof before the deliberate
  ;; bypass below.  Preserve the already-proven input spelling at the system
  ;; call boundary; callers carry the resolver's canonical result between
  ;; operations, while direct low-level callers can still close an injected
  ;; `write-region' race against the exact name they supplied.
  (let* ((_proven (epi-ledger--resolve-local-write-path path))
         (local (substring-no-properties path)))
    (condition-case condition
        (let ((newp
               (or (eq mode 'exclusive-create)
                   (let ((file-name-handler-alist nil))
                     (not (file-exists-p local)))))
              (coding-system-for-write 'no-conversion)
              (buffer-file-coding-system 'no-conversion)
              (buffer-file-format nil)
              (file-coding-system-alist nil)
              (format-alist nil)
              (write-region-annotate-functions nil)
              (write-region-post-annotation-function nil)
              (write-region-inhibit-fsync (not durablep))
              (create-lockfiles nil)
              (file-name-handler-alist nil))
          (with-file-modes #o600
            (pcase mode
              ('exclusive-create
               (write-region bytes nil local nil 'silent nil 'excl))
              ('append
               (write-region bytes nil local t 'silent nil nil))
              ('replace
               (write-region bytes nil local nil 'silent nil nil))))
          (when newp
            (set-file-modes local #o600))
          nil)
      (file-already-exists
       (ignore condition)
       (epi-ledger--fail 'epi-ledger-conflict 'destination-exists))
      (file-error
       (ignore condition)
       (epi-ledger--fail 'epi-ledger-conflict 'storage-write-failed)))))

(defun epi-ledger--read-bytes (path begin end)
  "Return a fresh unibyte copy of PATH's bytes from BEGIN through END.
BEGIN is inclusive and END exclusive, as for `insert-file-contents-literally'."
  (unless (and (integerp begin) (integerp end)
               (<= 0 begin) (<= begin end))
    (epi-ledger--format-fail 'invalid-byte-range))
  ;; Resolution rejects a handler-owned or non-regular leaf before bypass.
  (let ((canonical (epi-ledger--resolve-local-write-path path)))
    (condition-case condition
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (let ((coding-system-for-read 'no-conversion)
                (buffer-file-coding-system 'no-conversion)
                (file-coding-system-alist nil)
                (format-alist nil)
                (after-insert-file-functions nil)
                (inhibit-modification-hooks t)
                (file-name-handler-alist nil))
            (insert-file-contents-literally canonical nil begin end))
          (buffer-substring-no-properties (point-min) (point-max)))
      (file-error
       (ignore condition)
       (epi-ledger--fail 'epi-ledger-conflict 'storage-read-failed)))))

(defun epi-ledger--stat-local-file (path)
  "Return PATH's full local identity plist, or nil when PATH is absent."
  (let ((canonical (epi-ledger--resolve-local-write-path path)))
    (condition-case condition
        (let* ((file-name-handler-alist nil)
               (attributes (file-attributes canonical 'string)))
          (when attributes
            (unless (null (file-attribute-type attributes))
              (epi-ledger--format-fail 'non-regular-storage-leaf))
            (list :path (substring-no-properties canonical)
                  :device (file-attribute-device-number attributes)
                  :inode (file-attribute-inode-number attributes)
                  :links (file-attribute-link-number attributes)
                  :size (file-attribute-size attributes)
                  :modified (file-attribute-modification-time attributes)
                  :changed (file-attribute-status-change-time attributes))))
      (file-error
       (ignore condition)
       (epi-ledger--fail 'epi-ledger-conflict 'storage-stat-failed)))))

(defun epi-ledger--stat-local-directory (path)
  "Return PATH's local directory identity, or nil when PATH is absent."
  (let ((canonical (epi-ledger--resolve-local-directory-path path)))
    (condition-case condition
        (let* ((file-name-handler-alist nil)
               (attributes (file-attributes canonical 'string)))
          (when attributes
            (unless (eq t (file-attribute-type attributes))
              (epi-ledger--format-fail 'non-directory-parent))
            (list :path (substring-no-properties canonical)
                  :device (file-attribute-device-number attributes)
                  :inode (file-attribute-inode-number attributes)
                  :links (file-attribute-link-number attributes)
                  :modified (file-attribute-modification-time attributes)
                  :changed (file-attribute-status-change-time attributes))))
      (file-error
       (ignore condition)
       (epi-ledger--fail 'epi-ledger-conflict 'storage-stat-failed)))))

(defvar epi-ledger--byte-writer #'epi-ledger--write-bytes
  "Dynamically bindable exact local-byte writer.")

(defvar epi-ledger--lock-create-function #'epi-ledger--default-lock-create
  "Dynamically bindable exclusive lock-token creator.")

(defvar epi-ledger--lock-acquisition-receiver nil
  "Legacy direct-call fallback receiving a verified lock before return.
Trusted orchestration passes a lexical receiver and masks this special.")

(defvar epi-ledger--append-function #'epi-ledger--default-append
  "Dynamically bindable single data-append operation.")

(defvar epi-ledger--flush-function #'epi-ledger--default-flush
  "Dynamically bindable final file flush operation.")

(defvar epi-ledger--stat-function #'epi-ledger--stat-local-file
  "Dynamically bindable local file identity reader.")

(defvar epi-ledger--directory-stat-function
  #'epi-ledger--stat-local-directory
  "Dynamically bindable local directory identity reader.")

(defvar epi-ledger--read-function #'epi-ledger--read-bytes
  "Dynamically bindable exact ranged local-byte reader.")

(defvar epi-ledger--unlock-function #'epi-ledger--default-unlock
  "Dynamically bindable exact lock release operation.")

(defvar epi-ledger--publish-function #'epi-ledger--default-publish
  "Dynamically bindable sibling no-clobber publication operation.")

(defvar epi-ledger--publish-expected-source-identity nil
  "Optional exact prepublication source identity for the default publisher.")

(defvar epi-ledger--publication-receipt-receiver nil
  "Internal callback receiving PATH and its raw post-link identity.")

(defvar epi-ledger--create-prepublication-function #'ignore
  "Zero-argument barrier immediately before atomic ledger publication.")

(defvar epi-ledger--create-postpublication-function #'ignore
  "Zero-argument barrier after ledger publication and source cleanup.")

(defun epi-ledger--default-lock-create (path token-bytes)
  "Exclusively create PATH from TOKEN-BYTES and return its identity."
  (funcall epi-ledger--byte-writer
           path token-bytes 'exclusive-create t)
  (or (funcall epi-ledger--stat-function path)
      (epi-ledger--fail 'epi-ledger-conflict 'storage-stat-failed)))

(defun epi-ledger--default-append (path suffix-bytes)
  "Append owned SUFFIX-BYTES to PATH once without a final fsync."
  (funcall epi-ledger--byte-writer path suffix-bytes 'append nil))

(defun epi-ledger--default-flush (path)
  "Run PATH's final fsync path through one empty durable append."
  (funcall epi-ledger--byte-writer
           path "" 'append t))

(defun epi-ledger--default-unlock (lock)
  "Release opaque LOCK through the exact-token implementation when loaded."
  (if (fboundp 'epi-ledger--release-lock)
      (funcall (symbol-function 'epi-ledger--release-lock) lock)
    (epi-ledger--fail 'epi-ledger-conflict 'unlock-unavailable)))

(defun epi-ledger--same-file-object-p (left right)
  "Return non-nil when identity plists LEFT and RIGHT name one file object."
  (and left right
       (equal (plist-get left :device) (plist-get right :device))
       (equal (plist-get left :inode) (plist-get right :inode))))

(defun epi-ledger--owned-stat (path)
  "Return an ownership-isolated stat-seam result for PATH."
  (epi-ledger--copy-tree-and-strings
   (funcall epi-ledger--stat-function (substring-no-properties path))))

(defun epi-ledger--default-publish (temporary destination)
  "Hard-link TEMPORARY to sibling DESTINATION without overwriting a winner.
Return only after both names are verified to designate the same file object;
the caller owns postpublication removal of the source name."
  (let* ((source (epi-ledger--resolve-local-write-path temporary))
         (target (epi-ledger--resolve-local-write-path destination))
         (source-identity
          (condition-case nil
              (if epi-ledger--publish-expected-source-identity
                  (epi-ledger--stat-local-file source)
                (epi-ledger--owned-stat source))
            (error nil))))
    (unless (equal (file-name-directory source)
                   (file-name-directory target))
      (epi-ledger--format-fail 'publication-sibling-required))
    (unless source-identity
      (epi-ledger--fail 'epi-ledger-conflict 'storage-publication-failed))
    (when (and epi-ledger--publish-expected-source-identity
               (not (equal epi-ledger--publish-expected-source-identity
                           source-identity)))
      (epi-ledger--fail
       'epi-ledger-conflict 'storage-publication-failed))
    (condition-case condition
        (let ((file-name-handler-alist nil))
          (add-name-to-file
           (substring-no-properties source)
           (substring-no-properties target) nil))
      (file-already-exists
       (ignore condition)
       (epi-ledger--fail 'epi-ledger-conflict 'destination-exists))
      (file-error
       (ignore condition)
       (let ((published-target
              (condition-case nil
                  (epi-ledger--owned-stat target)
                (error nil))))
         (if (epi-ledger--same-file-object-p
              source-identity published-target)
             (epi-ledger--fail
              'epi-ledger-conflict 'storage-publication-failed :published t)
           (if published-target
               (epi-ledger--fail
                'epi-ledger-conflict 'destination-exists)
             (epi-ledger--fail
              'epi-ledger-conflict 'storage-publication-failed))))))
    ;; A successful primitive publication is the only unambiguous ownership
    ;; point.  Deliver its raw receipt before the injectable post-link stat
    ;; seams or an outer publisher wrapper can exit.
    (when epi-ledger--publication-receipt-receiver
      (let ((gc-cons-threshold most-positive-fixnum))
        (let ((published-source (epi-ledger--stat-local-file source))
              (published-target (epi-ledger--stat-local-file target)))
          (unless (and (epi-ledger--same-file-object-p
                        source-identity published-source)
                       (epi-ledger--same-file-object-p
                        published-source published-target))
            (epi-ledger--fail
             'epi-ledger-conflict 'storage-publication-failed :published t))
          (funcall
           epi-ledger--publication-receipt-receiver
           (substring-no-properties target)
           (epi-ledger--copy-tree-and-strings published-target)))))
    (let ((published-source
           (condition-case nil
               (epi-ledger--owned-stat source)
             (error nil)))
          (published-target
           (condition-case nil
               (epi-ledger--owned-stat target)
             (error nil))))
      (unless (and (epi-ledger--same-file-object-p
                    source-identity published-source)
                   (epi-ledger--same-file-object-p
                    published-source published-target))
        (epi-ledger--fail
         'epi-ledger-conflict 'storage-publication-failed :published t)))
    nil))

(defun epi-ledger--string-has-properties-p (value)
  "Return non-nil when string VALUE carries any text property."
  (and (> (length value) 0)
       (or (text-properties-at 0 value)
           (let ((position 0)
                 found)
             (while (and (< position (length value)) (not found))
               (setq position (or (next-property-change
                                   position value (length value))
                                  (length value)))
               (when (< position (length value))
                 (setq found (text-properties-at position value))))
             found))))

(defun epi-ledger--safe-integer-p (value)
  "Return non-nil when VALUE is an integer representable exactly by JCS."
  (and (integerp value)
       (<= (- epi-ledger--maximum-safe-integer)
           value epi-ledger--maximum-safe-integer)))

(defun epi-ledger--normalize-time-vector (value)
  "Normalize Emacs time VALUE to an owned four-safe-integer vector."
  (let ((parts
         (condition-case nil
             (time-convert
              (if (vectorp value) (append value nil) value) 'list)
           (error nil))))
    (unless (and (listp parts)
                 (= 4 (length parts))
                 (seq-every-p #'epi-ledger--safe-integer-p parts))
      (epi-ledger--format-fail 'invalid-lock-time))
    (vconcat parts)))

(defun epi-ledger--lock-time-vector-p (value)
  "Return non-nil when VALUE has the lock token's exact time shape."
  (and (vectorp value)
       (= 4 (length value))
       (seq-every-p #'epi-ledger--safe-integer-p value)
       (condition-case nil
           (equal value (epi-ledger--normalize-time-vector value))
         (error nil))))

(defun epi-ledger--canonical-lock-ledger-path-p (value)
  "Return non-nil when VALUE is a canonical absolute ledger file spelling."
  (and (stringp value)
       (not (string-empty-p value))
       (not (string-match-p "[\0\r\n]" value))
       (not (directory-name-p value))
       (file-name-absolute-p value)
       (let ((file-name-handler-alist nil))
         (equal value (expand-file-name value)))))

(defun epi-ledger--unsigned-decimal-string (value field)
  "Return nonnegative integer VALUE as a canonical decimal for FIELD."
  (unless (and (integerp value) (>= value 0))
    (epi-ledger--format-fail 'invalid-unsigned-decimal :field field))
  (number-to-string value))

(defun epi-ledger--parse-unsigned-decimal (value field)
  "Return canonical unsigned decimal string VALUE as an integer for FIELD."
  (unless (and (stringp value)
               (let ((case-fold-search nil))
                 (string-match-p "\\`\\(?:0\\|[1-9][0-9]*\\)\\'" value)))
    (epi-ledger--format-fail 'invalid-unsigned-decimal :field field))
  (string-to-number value))

(defun epi-ledger--lock-file-identity-object (identity)
  "Return the closed lock-token file object for plist IDENTITY."
  (unless (and (listp identity)
               (stringp (plist-get identity :path)))
    (epi-ledger--format-fail 'invalid-lock-file-identity))
  (list
   (cons "path" (substring-no-properties (plist-get identity :path)))
   (cons "device"
         (epi-ledger--unsigned-decimal-string
          (plist-get identity :device) 'device))
   (cons "inode"
         (epi-ledger--unsigned-decimal-string
          (plist-get identity :inode) 'inode))
   (cons "links"
         (epi-ledger--unsigned-decimal-string
          (plist-get identity :links) 'links))
   (cons "size"
         (epi-ledger--unsigned-decimal-string
          (plist-get identity :size) 'size))
   (cons "modified"
         (epi-ledger--normalize-time-vector
          (plist-get identity :modified)))
   (cons "changed"
         (epi-ledger--normalize-time-vector
          (plist-get identity :changed)))))

(defun epi-ledger--encode-lock-token
    (host pid process-start nonce ledger-path
          expected-file expected-end expected-head)
  "Encode the exact closed lock token.
HOST, PID, PROCESS-START, NONCE, and LEDGER-PATH identify its owner and target;
EXPECTED-FILE, EXPECTED-END, and EXPECTED-HEAD bind the ledger state."
  (unless (and (stringp host) (not (string-empty-p host))
               (epi-ledger--canonical-lock-ledger-path-p ledger-path)
               (epi-ledger--uuid-p nonce))
    (epi-ledger--format-fail 'invalid-lock-token-input))
  (let* ((owned-path (substring-no-properties ledger-path))
         (end-string
          (epi-ledger--unsigned-decimal-string expected-end 'expected-end))
         (file-object
          (if (equal expected-file "absent")
              "absent"
            (epi-ledger--lock-file-identity-object expected-file)))
         (head
          (if expected-head
              (progn
                (epi-ledger--require-hash expected-head 'expected-head)
                (substring-no-properties expected-head))
            epi-json-null)))
    (unless
        (if (equal file-object "absent")
            (and (= expected-end 0) (null expected-head))
          (and (equal owned-path
                      (epi-ledger--object-value file-object "path"))
               (= expected-end
                  (string-to-number
                   (epi-ledger--object-value file-object "size")))
               expected-head))
      (epi-ledger--format-fail 'incoherent-lock-token-input))
    (epi-ledger--jcs-encode
     (list
      (cons "version" 1)
      (cons "host" (substring-no-properties host))
      (cons "pid" (epi-ledger--unsigned-decimal-string pid 'pid))
      (cons "process_start"
            (epi-ledger--normalize-time-vector process-start))
      (cons "nonce" (substring-no-properties nonce))
      (cons "ledger_path" owned-path)
      (cons "expected_file" file-object)
      (cons "expected_end" end-string)
      (cons "expected_head" head))
     epi-ledger--lock-token-byte-limit)))

(defun epi-ledger--lock-decode-fail ()
  "Signal the stable conflict for a malformed lock token."
  (epi-ledger--fail 'epi-ledger-conflict 'malformed-lock-token))

(defun epi-ledger--decode-lock-file-object (object ledger-path expected-end)
  "Validate and reorder present file OBJECT for LEDGER-PATH and EXPECTED-END."
  (epi-ledger--closed-object
   object '("path" "device" "inode" "links" "size" "modified" "changed")
   nil 'expected-file)
  (let* ((path (epi-ledger--object-value object "path"))
         (device (epi-ledger--object-value object "device"))
         (inode (epi-ledger--object-value object "inode"))
         (links (epi-ledger--object-value object "links"))
         (size (epi-ledger--object-value object "size"))
         (modified (epi-ledger--object-value object "modified"))
         (changed (epi-ledger--object-value object "changed")))
    (unless (and (stringp path) (equal path ledger-path))
      (epi-ledger--format-fail 'invalid-lock-file-path))
    (dolist (entry `((,device . device) (,inode . inode)
                     (,links . links) (,size . size)))
      (epi-ledger--parse-unsigned-decimal (car entry) (cdr entry)))
    (unless (= (epi-ledger--parse-unsigned-decimal size 'size)
               expected-end)
      (epi-ledger--format-fail 'incoherent-lock-file-size))
    (unless (and (epi-ledger--lock-time-vector-p modified)
                 (epi-ledger--lock-time-vector-p changed))
      (epi-ledger--format-fail 'invalid-lock-time))
    (let ((normalized-modified (epi-ledger--normalize-time-vector modified))
          (normalized-changed (epi-ledger--normalize-time-vector changed)))
      (list (cons "path" (substring-no-properties path))
            (cons "device" (substring-no-properties device))
            (cons "inode" (substring-no-properties inode))
            (cons "links" (substring-no-properties links))
            (cons "size" (substring-no-properties size))
            (cons "modified" normalized-modified)
            (cons "changed" normalized-changed)))))

(defun epi-ledger--decode-lock-token (bytes)
  "Decode and validate canonical unibyte lock-token BYTES.
The returned object owns all mutable values and has a schema-ordered nested
file identity so independent re-encoding reproduces BYTES exactly."
  (condition-case nil
      (progn
        (unless (and (stringp bytes)
                     (not (multibyte-string-p bytes))
                     (<= (length bytes) epi-ledger--lock-token-byte-limit)
                     (not (epi-ledger--string-has-properties-p bytes)))
          (error "Invalid lock byte container"))
        (let* ((decoded-text (decode-coding-string bytes 'utf-8-unix t))
               (roundtrip (encode-coding-string decoded-text 'utf-8-unix))
               (json-object-type 'alist)
               (json-array-type 'vector)
               (json-key-type 'string)
               (json-null epi-json-null)
               (json-false epi-json-false)
               (object
                (and (equal bytes roundtrip)
                     (json-read-from-string decoded-text))))
          (unless (and object
                       (equal bytes
                              (epi-ledger--jcs-encode
                               object epi-ledger--lock-token-byte-limit)))
            (error "Noncanonical lock token"))
          (epi-ledger--closed-object
           object '("version" "host" "pid" "process_start" "nonce"
                    "ledger_path" "expected_file" "expected_end"
                    "expected_head")
           nil 'lock-token)
          (let* ((version (epi-ledger--object-value object "version"))
                 (host (epi-ledger--object-value object "host"))
                 (pid (epi-ledger--object-value object "pid"))
                 (process-start
                  (epi-ledger--object-value object "process_start"))
                 (nonce (epi-ledger--object-value object "nonce"))
                 (ledger-path
                  (epi-ledger--object-value object "ledger_path"))
                 (expected-file
                  (epi-ledger--object-value object "expected_file"))
                 (end-string
                  (epi-ledger--object-value object "expected_end"))
                 (expected-head
                  (epi-ledger--object-value object "expected_head"))
                 (expected-end
                  (epi-ledger--parse-unsigned-decimal
                   end-string 'expected-end)))
            (unless (and (eq version 1)
                         (stringp host) (not (string-empty-p host))
                         (epi-ledger--canonical-lock-ledger-path-p ledger-path)
                         (epi-ledger--uuid-p nonce))
              (error "Invalid lock scalar"))
            (epi-ledger--parse-unsigned-decimal pid 'pid)
            (unless (epi-ledger--lock-time-vector-p process-start)
              (error "Invalid process start"))
            (epi-ledger--normalize-time-vector process-start)
            (cond
             ((stringp expected-file)
              (unless (and (equal expected-file "absent")
                           (= expected-end 0)
                           (eq expected-head epi-json-null))
                (error "Incoherent absent token")))
             ((listp expected-file)
              (unless (epi-ledger--hash-p expected-head)
                (error "Invalid present head"))
              (let ((ordered
                     (epi-ledger--decode-lock-file-object
                      expected-file ledger-path expected-end)))
                (setcdr (assoc-string "expected_file" object nil) ordered)))
             (t (error "Invalid expected file")))
            (epi-ledger--copy-tree-and-strings object))))
    (error (epi-ledger--lock-decode-fail))))

(defun epi-ledger--lock-path (ledger-path)
  "Return the canonical dedicated lock sibling for LEDGER-PATH."
  (epi-ledger--resolve-local-write-path
   (concat (epi-ledger--resolve-local-write-path ledger-path) ".epi-lock")))

(defun epi-ledger--lock-archive-path (ledger-path token-sha256)
  "Return the canonical stale-token archive for LEDGER-PATH and TOKEN-SHA256."
  (epi-ledger--require-hash token-sha256 'expected-token-sha256)
  (let* ((canonical (epi-ledger--resolve-local-write-path ledger-path))
         (candidate
          (concat (file-name-directory canonical)
                  "." (file-name-nondirectory canonical)
                  ".epi-stale-lock-" token-sha256 ".jcs")))
    (epi-ledger--resolve-local-write-path candidate)))

(defun epi-ledger--bounded-lock-read (path identity mismatch-code)
  "Read the exact bounded token at PATH under IDENTITY.
Signal MISMATCH-CODE when the read container, length, or identity changes."
  (setq path (substring-no-properties path)
        identity (epi-ledger--copy-tree-and-strings identity))
  (unless identity
    (epi-ledger--fail 'epi-ledger-conflict mismatch-code))
  (let ((size (plist-get identity :size)))
    (unless (and (integerp size) (>= size 0))
      (epi-ledger--fail 'epi-ledger-conflict mismatch-code))
    (when (> size epi-ledger--lock-token-byte-limit)
      (epi-ledger--limit-fail
       'lock-token-byte-limit
       :limit epi-ledger--lock-token-byte-limit :bytes size))
    (let ((bytes
           (funcall epi-ledger--read-function
                    (substring-no-properties path) 0 size)))
      (unless (and (stringp bytes)
                   (not (multibyte-string-p bytes))
                   (= (length bytes) size)
                   (not (epi-ledger--string-has-properties-p bytes))
                   (equal identity (epi-ledger--owned-stat path)))
        (epi-ledger--fail 'epi-ledger-conflict mismatch-code))
      (substring-no-properties bytes))))

(defun epi-ledger--local-parent-directory (ledger-path)
  "Return canonical LEDGER-PATH's proven-local parent directory."
  (file-name-as-directory
   (directory-file-name (file-name-directory ledger-path))))

(defun epi-ledger--process-start-from-attributes (attributes)
  "Return the normalized start in proper process ATTRIBUTES, or nil."
  (when (and (listp attributes) (proper-list-p attributes))
    (let ((start
           (condition-case nil
               (cdr (assq 'start attributes))
             (error nil))))
      (when (and (listp start)
                 (proper-list-p start)
                 (= 4 (length start))
                 (seq-every-p #'epi-ledger--safe-integer-p start))
        (condition-case nil
            (epi-ledger--normalize-time-vector start)
          (error nil))))))

(defun epi-ledger--current-process-start (ledger-path)
  "Return the current process start vector while rooted beside LEDGER-PATH."
  (let* ((default-directory
          (epi-ledger--local-parent-directory ledger-path))
         (attributes
          (condition-case nil
              (process-attributes (emacs-pid))
            (error :indeterminate)))
         (start (epi-ledger--process-start-from-attributes attributes)))
    (unless start
      (epi-ledger--fail 'epi-ledger-conflict 'lock-owner-indeterminate))
    start))

(defun epi-ledger--lock-owner-state (token)
  "Classify decoded lock TOKEN as `live', `dead', or `indeterminate'."
  (let* ((host (epi-ledger--copy-tree-and-strings
                (epi-ledger--object-value token "host")))
         (ledger-path
          (epi-ledger--copy-tree-and-strings
           (epi-ledger--object-value token "ledger_path")))
         (pid-value
          (epi-ledger--copy-tree-and-strings
           (epi-ledger--object-value token "pid")))
         (stored-start
          (epi-ledger--copy-tree-and-strings
           (epi-ledger--object-value token "process_start"))))
    (if (not (and (stringp host) (equal host (system-name))))
        'indeterminate
      (let* ((pid
              (condition-case nil
                  (epi-ledger--parse-unsigned-decimal pid-value 'pid)
                (error nil)))
             (default-directory
              (and (stringp ledger-path)
                   (epi-ledger--local-parent-directory ledger-path)))
         (attributes
              (and pid default-directory
                   (condition-case nil
                       (process-attributes pid)
                     (error :indeterminate)))))
        (cond
         ((or (null pid) (null default-directory)
              (eq attributes :indeterminate))
          'indeterminate)
         (attributes
          (let ((observed
                 (epi-ledger--process-start-from-attributes attributes)))
            (if (not observed)
                'indeterminate
              (if (equal observed stored-start) 'live 'dead))))
         ((not (fboundp 'list-system-processes)) 'indeterminate)
         (t
          (let ((processes
                 (condition-case nil
                     (list-system-processes)
                   (error :indeterminate))))
            (if (not (listp processes))
                'indeterminate
              (if (not (and (proper-list-p processes)
                            (consp processes)
                            (seq-every-p
                             (lambda (process)
                               (and (integerp process) (> process 0)))
                             processes)
                            (memq (emacs-pid) processes)))
                  'indeterminate
                (if (memq pid processes) 'indeterminate 'dead))))))))))

(defun epi-ledger--delete-exact-lock-name (path failure-code)
  "Delete lock PATH, mapping any failure to structured FAILURE-CODE."
  (condition-case nil
      (let ((file-name-handler-alist nil))
        (delete-file (substring-no-properties path)))
    (file-error
     (epi-ledger--fail 'epi-ledger-conflict failure-code))))

(defun epi-ledger--delete-published-source-name (path)
  "Delete published source PATH or report uncertain postpublication cleanup."
  (condition-case nil
      (let ((file-name-handler-alist nil))
        (delete-file (substring-no-properties path)))
    (file-error
     (epi-ledger--fail
      'epi-ledger-conflict 'storage-publication-failed :published t))))

(defun epi-ledger--exact-published-lock-object
    (path expected-object expected-bytes expected-sha256)
  "Return PATH's identity when it is EXPECTED-OBJECT with exact token bytes.
EXPECTED-BYTES and EXPECTED-SHA256 bind the complete token content.  Return
nil rather than leaking a read or stat failure after publication."
  (condition-case nil
      (let ((identity (epi-ledger--owned-stat path)))
        (when (epi-ledger--same-file-object-p expected-object identity)
          (let ((bytes
                 (epi-ledger--bounded-lock-read
                  path identity 'lock-token-changed)))
            (and (equal bytes expected-bytes)
                 (equal (secure-hash 'sha256 bytes) expected-sha256)
                 identity))))
    (error nil)))

(defun epi-ledger--cleanup-unreturned-lock-token
    (path candidate created-identity)
  "Remove CANDIDATE at PATH only with its exact CREATED-IDENTITY receipt."
  (condition-case condition
      (let ((epi-ledger--stat-function #'epi-ledger--stat-local-file)
            (epi-ledger--read-function #'epi-ledger--read-bytes)
            (epi--yield-function #'ignore)
            (epi--deadline-clock-function #'float-time)
            (epi-ledger--nonpreemptible-observer nil))
        (let* ((identity (epi-ledger--owned-stat path))
               (sha256 (secure-hash 'sha256 candidate)))
          (cond
           ((null identity) t)
           ((and created-identity
                 (epi-ledger--exact-published-lock-object
                  path created-identity candidate sha256))
            (epi-ledger--delete-exact-lock-name path 'lock-token-changed)
            (unless (null (epi-ledger--owned-stat path))
              (epi-ledger--fail
               'epi-ledger-conflict 'lock-token-changed))
            t)
           (t
            (epi-ledger--fail
             'epi-ledger-conflict 'lock-token-changed)))))
    ((error quit)
     (ignore condition)
     (epi-ledger--fail 'epi-ledger-conflict 'lock-token-changed))))

(defun epi-ledger--create-and-bind-lock
    (lock-path candidate expected-file expected-end expected-head
               &optional receipt-receiver)
  "Create CANDIDATE at LOCK-PATH and return its verified lock proof.
EXPECTED-FILE, EXPECTED-END, and EXPECTED-HEAD are copied into that proof.
When RECEIPT-RECEIVER is non-nil, call it with an ownership-disjoint proof
before returning.  The legacy dynamic receiver remains a direct-call fallback."
  (let* ((receiver
          (or receipt-receiver epi-ledger--lock-acquisition-receiver))
         ;; Never expose trusted cleanup authority through a documented
         ;; callback's dynamic continuation.
         (epi-ledger--lock-acquisition-receiver nil)
         (owned-path (substring-no-properties lock-path))
         (owned-candidate (substring-no-properties candidate))
         created-identity verified result handed-off)
    (condition-case condition
        (unwind-protect
            (progn
              (setq
               result
               (let* ((_created
                       (setq created-identity
                             (epi-ledger--copy-tree-and-strings
                              (funcall epi-ledger--lock-create-function
                                       (substring-no-properties owned-path)
                                       (substring-no-properties
                                        owned-candidate)))))
                      (observed (epi-ledger--owned-stat owned-path)))
                 (unless (and created-identity observed
                              (equal created-identity observed))
                   (epi-ledger--fail
                    'epi-ledger-conflict 'lock-token-changed))
                 (let ((readback
                        (epi-ledger--bounded-lock-read
                         owned-path observed 'lock-token-changed))
                       (sha256 (secure-hash 'sha256 owned-candidate)))
                   (unless (and (equal owned-candidate readback)
                                (equal sha256 (secure-hash 'sha256 readback)))
                     (epi-ledger--fail
                      'epi-ledger-conflict 'lock-token-changed))
                   ;; From this point the exact created object and bytes are a
                   ;; deletion receipt even if a pending quit arrives while
                   ;; the immutable lock value is being constructed.
                   (setq verified t)
                   (epi-ledger--make-lock
                    :lock-file (substring-no-properties owned-path)
                    :bytes (substring-no-properties owned-candidate)
                    :sha256 (substring-no-properties sha256)
                    :file-identity
                    (epi-ledger--copy-tree-and-strings observed)
                    :expected-file
                    (epi-ledger--copy-tree-and-strings expected-file)
                    :expected-end expected-end
                    :expected-head
                    (and expected-head
                         (substring-no-properties expected-head))))))
              (when receiver
                (funcall receiver
                         (epi-ledger--recovery-copy-lock result)))
              (setq handed-off t)
              result)
          ;; Before RESULT exists, no verified lock proof has crossed the
          ;; acquisition boundary.  Preserve that conservative distinction:
          ;; failed verification must not authorize deletion.  Once VERIFIED
          ;; is set, construction or receiver failure leaves an exact
          ;; unreturned receipt that this unwind may safely clean up.
          (when (and (or result verified) (not handed-off))
            (epi-ledger--cleanup-unreturned-lock-token
             owned-path owned-candidate created-identity)))
      ((error quit)
       (let* ((detail
               (and (eq (car condition) 'epi-ledger-conflict)
                    (epi-ledger--condition-plist condition)))
              (code (and detail (plist-get detail :code))))
         (cond
          ;; A verified receipt was either handed to a failing receiver or
          ;; rejected during its exact cleanup.  Preserve that outcome.
          (result (signal (car condition) (cdr condition)))
          ;; Losing exclusive creation is an ordinary competing owner, never
          ;; evidence that this attempt wrote the token now at the path.
          ((memq code '(destination-exists lock-held))
           (signal (car condition) (cdr condition)))
          ;; A creator that failed after making a path returned no deletion
          ;; authority.  Preserve the path and close the ambiguous outcome.
          ((condition-case nil
               (not (null (epi-ledger--stat-local-file owned-path)))
             (error t))
           (epi-ledger--fail 'epi-ledger-conflict 'lock-token-changed))
          (t (signal (car condition) (cdr condition)))))))
    result))

(defun epi-ledger--acquire-lock
    (path expected-file expected-end expected-head &optional receipt-receiver)
  "Acquire PATH's exact dedicated token.
Bind it to EXPECTED-FILE, EXPECTED-END, and EXPECTED-HEAD.  Deliver the
verified proof to RECEIPT-RECEIVER before returning when it is non-nil."
  (let* ((receiver
          (or receipt-receiver epi-ledger--lock-acquisition-receiver))
         (epi-ledger--lock-acquisition-receiver nil)
         (owned-input-path (substring-no-properties path))
         (owned-file (epi-ledger--copy-tree-and-strings expected-file))
         (owned-end expected-end)
         (owned-head
          (and expected-head (substring-no-properties expected-head)))
         (ledger-path
          (epi-ledger--resolve-local-write-path owned-input-path))
         (lock-path (epi-ledger--lock-path ledger-path))
         (process-start (epi-ledger--current-process-start ledger-path))
         (host (substring-no-properties (system-name)))
         (nonce (substring-no-properties (epi--new-id)))
         (candidate
          (epi-ledger--encode-lock-token
           host (emacs-pid) process-start nonce ledger-path
           owned-file owned-end owned-head))
         (existing (epi-ledger--owned-stat lock-path)))
    (when existing
      (let* ((bytes
              (epi-ledger--bounded-lock-read
               lock-path existing 'lock-token-changed))
             (token
              (epi-ledger--decode-lock-token
               (substring-no-properties bytes))))
        (unless (equal ledger-path
                       (epi-ledger--object-value token "ledger_path"))
          (epi-ledger--lock-decode-fail))
        (let ((state (epi-ledger--lock-owner-state token)))
        (pcase state
          ('live (epi-ledger--fail 'epi-ledger-conflict 'lock-held))
          ('indeterminate
           (epi-ledger--fail
            'epi-ledger-conflict 'lock-owner-indeterminate))
          ('dead
           (let ((rechecked (epi-ledger--owned-stat lock-path)))
             (unless (equal existing rechecked)
               (epi-ledger--fail
                'epi-ledger-conflict 'lock-token-changed))
             (let ((reread
                    (epi-ledger--bounded-lock-read
                     lock-path rechecked 'lock-token-changed)))
               (unless (equal bytes reread)
                 (epi-ledger--fail
                  'epi-ledger-conflict 'lock-token-changed)))
             (epi-ledger--delete-exact-lock-name
              lock-path 'lock-token-changed)))))))
    (epi-ledger--create-and-bind-lock
     lock-path candidate owned-file owned-end owned-head receiver)))

(defun epi-ledger--release-lock (lock)
  "Release LOCK only if its pathname still names the exact owned token."
  (unless (epi-ledger--lock-p lock)
    (epi-ledger--format-fail 'invalid-lock))
  (let* ((path (epi-ledger--lock-lock-file lock))
         (identity (epi-ledger--owned-stat path)))
    (unless (equal identity (epi-ledger--lock-file-identity lock))
      (epi-ledger--fail 'epi-ledger-conflict 'lock-token-changed))
    (let ((bytes
           (epi-ledger--bounded-lock-read
            path identity 'lock-token-changed)))
      (unless (and (equal bytes (epi-ledger--lock-bytes lock))
                   (equal (secure-hash 'sha256 bytes)
                          (epi-ledger--lock-sha256 lock)))
        (epi-ledger--fail 'epi-ledger-conflict 'lock-token-changed))
      (epi-ledger--delete-exact-lock-name path 'lock-token-changed)
      nil)))

(defun epi-ledger--lock-file-object-to-identity (object)
  "Convert validated lock file OBJECT to an owned identity plist."
  (list
   :path (substring-no-properties
          (epi-ledger--object-value object "path"))
   :device (epi-ledger--parse-unsigned-decimal
            (epi-ledger--object-value object "device") 'device)
   :inode (epi-ledger--parse-unsigned-decimal
           (epi-ledger--object-value object "inode") 'inode)
   :links (epi-ledger--parse-unsigned-decimal
           (epi-ledger--object-value object "links") 'links)
   :size (epi-ledger--parse-unsigned-decimal
          (epi-ledger--object-value object "size") 'size)
   :modified (append
              (epi-ledger--object-value object "modified") nil)
   :changed (append
             (epi-ledger--object-value object "changed") nil)))

(defun epi-ledger--insert-read-range (path _visit begin end)
  "Insert exact bytes BEGIN through END from PATH using the Task 5 read seam."
  (let ((bytes
         (funcall epi-ledger--read-function
                  (substring-no-properties path) begin end)))
    (unless (and (stringp bytes)
                 (not (multibyte-string-p bytes))
                 (= (length bytes) (- end begin))
                 (not (epi-ledger--string-has-properties-p bytes)))
      (epi-ledger--fail 'epi-ledger-conflict 'file-chain-head-changed))
    (insert bytes)
    (list path (length bytes))))

;; These private loader seams are initialized later in the file.  Declare
;; them here so byte compilation treats the verification bindings as dynamic.
(defvar epi-ledger--open-identity-reader)
(defvar epi-ledger--open-source-inserter)
(defvar epi-ledger--open-head-inserter)

(defun epi-ledger--file-authority-equal-p (left right)
  "Return non-nil when LEFT and RIGHT have equal non-size authority fields."
  (and (listp left) (listp right)
       (cl-every
        (lambda (key) (equal (plist-get left key) (plist-get right key)))
        '(:path :device :inode :links :modified :changed))))

(defun epi-ledger--verify-present-identity
    (identity expected-identity expected-end)
  "Verify IDENTITY against EXPECTED-IDENTITY and EXPECTED-END."
  (unless (epi-ledger--file-authority-equal-p identity expected-identity)
    (epi-ledger--fail 'epi-ledger-conflict 'file-identity-changed))
  (unless (and (integerp expected-end)
               (= (or (plist-get expected-identity :size) -1) expected-end)
               (= (or (plist-get identity :size) -1) expected-end))
    (epi-ledger--fail 'epi-ledger-conflict 'file-end-changed)))

(defun epi-ledger--verify-state-stat (path)
  "Return PATH's owned identity or report a closed identity conflict."
  (condition-case condition
      (epi-ledger--owned-stat path)
    (error
     (ignore condition)
     (epi-ledger--fail 'epi-ledger-conflict 'file-identity-changed))))

(defun epi-ledger--verify-file-state-core-impl
    (path expected-identity expected-end expected-head last-record)
  "Verify already-owned PATH against the expected file and chain state.
EXPECTED-IDENTITY, EXPECTED-END, and EXPECTED-HEAD are trusted checkpoint
authorities.  LAST-RECORD, when non-nil, is their retained chain-head record."
  (let ((identity (epi-ledger--verify-state-stat path)))
    (if (equal expected-identity "absent")
        (unless (and (null identity) (= expected-end 0)
                     (null expected-head))
          (epi-ledger--fail 'epi-ledger-conflict 'file-identity-changed))
      (epi-ledger--verify-present-identity
       identity expected-identity expected-end)
      (if last-record
          (let ((epi-ledger--open-identity-reader
                 epi-ledger--stat-function)
                (epi-ledger--open-head-inserter
                 #'epi-ledger--insert-read-range))
            (unless (equal expected-head
                           (epi-record--raw-hash last-record))
              (epi-ledger--fail
               'epi-ledger-conflict 'file-chain-head-changed))
            (condition-case condition
                (epi-ledger--open-verify-current-head
                 path last-record identity
                 (epi-ledger--make-work-state)
                 (epi-record--raw-sequence last-record))
              (epi-ledger-conflict
               (let* ((detail (epi-ledger--condition-plist condition))
                      (code (and detail (plist-get detail :code))))
                 (if (memq code
                           '(file-identity-changed file-chain-head-changed))
                     (signal (car condition) (cdr condition))
                   (epi-ledger--fail
                    'epi-ledger-conflict 'file-chain-head-changed))))
              (error
               (epi-ledger--fail
                'epi-ledger-conflict 'file-chain-head-changed))))
        (let ((opened
               (condition-case nil
                   (let ((epi-ledger--open-identity-reader
                          epi-ledger--stat-function)
                         (epi-ledger--open-source-inserter
                          #'epi-ledger--insert-read-range)
                         (epi-ledger--open-head-inserter
                          #'epi-ledger--insert-read-range))
                     (epi-ledger-open path))
                 (error
                  (epi-ledger--fail
                   'epi-ledger-conflict 'file-chain-head-changed)))))
          (let ((checkpoint (epi-ledger--checkpoint-snapshot opened)))
            (unless (= (epi-ledger--checkpoint-raw-validated-end-offset
                        checkpoint)
                       expected-end)
              (epi-ledger--fail 'epi-ledger-conflict 'file-end-changed))
            (unless (equal (epi-ledger--checkpoint-raw-tail-hash checkpoint)
                           expected-head)
              (epi-ledger--fail
               'epi-ledger-conflict 'file-chain-head-changed)))))
      (epi-ledger--verify-present-identity
       (epi-ledger--verify-state-stat path)
       expected-identity expected-end))
    nil))

(defun epi-ledger--verify-file-state-core
    (path expected-identity expected-end expected-head last-record)
  "Verify PATH against EXPECTED-IDENTITY, EXPECTED-END, and EXPECTED-HEAD.
LAST-RECORD supplies the retained chain head.  This named wrapper remains an
injectable verification boundary."
  (epi-ledger--verify-file-state-core-impl
   path expected-identity expected-end expected-head last-record))

(defun epi-ledger--verify-file-state-raw
    (path expected-identity expected-end expected-head last-record)
  "Verify PATH against EXPECTED-IDENTITY, EXPECTED-END, and EXPECTED-HEAD.
LAST-RECORD supplies the retained chain head.  Do not invoke cooperative or
storage seam callbacks."
  (let ((epi-ledger--stat-function #'epi-ledger--stat-local-file)
        (epi-ledger--read-function #'epi-ledger--read-bytes)
        (epi--yield-function #'ignore)
        (epi--deadline-clock-function #'float-time)
        (epi-ledger--nonpreemptible-observer nil))
    (epi-ledger--verify-file-state-core-impl
     path expected-identity expected-end expected-head last-record)))

(defun epi-ledger--verify-file-state
    (path expected-identity expected-end expected-head last-record)
  "Verify PATH against EXPECTED-IDENTITY, EXPECTED-END, and EXPECTED-HEAD.
LAST-RECORD enables the loader's bounded final-record head verifier when the
caller already holds that validated private record."
  (epi-ledger--verify-file-state-core
   (substring-no-properties path)
   (epi-ledger--copy-tree-and-strings expected-identity)
   expected-end
   (and expected-head (substring-no-properties expected-head))
   last-record))

(defun epi-ledger--archive-stale-lock
    (lock-path archive original-identity token-bytes)
  "Archive exact TOKEN-BYTES from LOCK-PATH at ARCHIVE without overwrite.
ORIGINAL-IDENTITY binds the source file object across publication."
  (setq lock-path (substring-no-properties lock-path)
        archive (substring-no-properties archive)
        original-identity
        (epi-ledger--copy-tree-and-strings original-identity)
        token-bytes (substring-no-properties token-bytes))
  (let ((archive-identity (epi-ledger--owned-stat archive))
        (token-sha256 (secure-hash 'sha256 token-bytes)))
    (if archive-identity
        (let ((archived
               (epi-ledger--bounded-lock-read
                archive archive-identity 'destination-exists)))
          (unless (equal archived token-bytes)
            (epi-ledger--fail 'epi-ledger-conflict 'destination-exists))
          (let ((rechecked (epi-ledger--owned-stat lock-path)))
            (unless (equal original-identity rechecked)
              (epi-ledger--fail 'epi-ledger-conflict 'lock-token-changed))
            (let ((reread
                   (epi-ledger--bounded-lock-read
                    lock-path rechecked 'lock-token-changed)))
              (unless (equal token-bytes reread)
                (epi-ledger--fail
                 'epi-ledger-conflict 'lock-token-changed))))
          (epi-ledger--delete-published-source-name lock-path))
      ;; Revalidate the exact source immediately before invoking the atomic
      ;; hard-link primitive.  Its callback remains a mutation boundary, so
      ;; both names are independently checked again afterward.
      (let ((prelink-identity (epi-ledger--owned-stat lock-path)))
        (unless (equal original-identity prelink-identity)
          (epi-ledger--fail 'epi-ledger-conflict 'lock-token-changed))
        (let ((prelink-bytes
               (epi-ledger--bounded-lock-read
                lock-path prelink-identity 'lock-token-changed)))
          (unless (and (equal token-bytes prelink-bytes)
                       (equal token-sha256
                              (secure-hash 'sha256 prelink-bytes)))
            (epi-ledger--fail
             'epi-ledger-conflict 'lock-token-changed))))
      (condition-case condition
          (let ((file-name-handler-alist nil))
            (add-name-to-file
             (substring-no-properties lock-path)
             (substring-no-properties archive) nil))
        (file-already-exists
         (ignore condition)
         (epi-ledger--fail 'epi-ledger-conflict 'destination-exists))
        (file-error
         (ignore condition)
         (let ((source-after
                (condition-case nil
                    (epi-ledger--owned-stat lock-path)
                  (error nil)))
               (archive-after
                (condition-case nil
                    (epi-ledger--owned-stat archive)
                  (error :unverifiable))))
           (cond
            ((and (consp archive-after)
                  (or (null source-after)
                      (epi-ledger--same-file-object-p
                       source-after archive-after)))
             (epi-ledger--fail
              'epi-ledger-conflict 'storage-publication-failed :published t))
            ((consp archive-after)
             (epi-ledger--fail
              'epi-ledger-conflict 'destination-exists))
            ((eq archive-after :unverifiable)
             (epi-ledger--fail
              'epi-ledger-conflict 'storage-publication-failed :published t))
            (t
             (epi-ledger--fail
              'epi-ledger-conflict 'storage-publication-failed))))))
      (let* ((source-after
              (epi-ledger--exact-published-lock-object
               lock-path original-identity token-bytes token-sha256))
             (archive-after
              (epi-ledger--exact-published-lock-object
               archive original-identity token-bytes token-sha256)))
        (unless (and source-after archive-after
                     (epi-ledger--same-file-object-p
                      source-after archive-after))
          (epi-ledger--fail
           'epi-ledger-conflict 'storage-publication-failed :published t))
        (unless (epi-ledger--exact-published-lock-object
                 lock-path source-after token-bytes token-sha256)
          (epi-ledger--fail
           'epi-ledger-conflict 'storage-publication-failed :published t)))
      (epi-ledger--delete-published-source-name lock-path))
    archive))

(cl-defun epi-ledger-recover-stale-lock
    (path &key expected-token-sha256)
  "Recover PATH from the exact stale token authorized by EXPECTED-TOKEN-SHA256.
Archive the authorized bytes, acquire a fresh state-equivalent lock, verify
the complete expected ledger state, release the fresh lock, and return the
canonical archive pathname."
  (epi-ledger--require-hash
   expected-token-sha256 'expected-token-sha256)
  (let* ((owned-path
          (copy-sequence (substring-no-properties path)))
         (owned-token-sha256
          (copy-sequence
           (substring-no-properties expected-token-sha256)))
         (ledger-path (epi-ledger--resolve-local-write-path owned-path))
         (lock-path (epi-ledger--lock-path ledger-path))
         (identity (epi-ledger--owned-stat lock-path))
         (token-bytes
          (epi-ledger--bounded-lock-read
           lock-path identity 'lock-token-changed)))
    (unless (equal owned-token-sha256
                   (secure-hash 'sha256 token-bytes))
      (epi-ledger--fail
       'epi-ledger-conflict 'stale-lock-sha-mismatch))
    (let* ((token
            (epi-ledger--decode-lock-token
             (substring-no-properties token-bytes)))
           (bound-path
            (epi-ledger--object-value token "ledger_path")))
      (unless (equal ledger-path bound-path)
        (epi-ledger--lock-decode-fail))
      (let* ((archive
              (epi-ledger--lock-archive-path
               ledger-path owned-token-sha256))
             (decoded-file
              (epi-ledger--object-value token "expected_file"))
             (expected-file
              (if (equal decoded-file "absent")
                  "absent"
                (epi-ledger--lock-file-object-to-identity decoded-file)))
             (expected-end
              (epi-ledger--parse-unsigned-decimal
               (epi-ledger--object-value token "expected_end")
               'expected-end))
             (decoded-head
              (epi-ledger--object-value token "expected_head"))
             (expected-head
              (unless (eq decoded-head epi-json-null)
                (substring-no-properties decoded-head))))
        (epi-ledger--archive-stale-lock
         lock-path archive identity token-bytes)
        (let ((fresh
               (epi-ledger--acquire-lock
                ledger-path expected-file expected-end expected-head)))
          (unwind-protect
              (progn
                (epi-ledger--verify-file-state
                 ledger-path expected-file expected-end expected-head nil)
                archive)
            (funcall epi-ledger--unlock-function fresh)))))))

(defun epi-ledger--snapshot-object-input (bytes media-type role)
  "Return an exact private plist snapshot of object input values.
Snapshot caller BYTES, MEDIA-TYPE, and ROLE without yielding or invoking an
Epi callback.  BYTES must be unibyte and within `epi-object-byte-limit'."
  (unless (and (stringp bytes) (not (multibyte-string-p bytes)))
    (epi-ledger--format-fail 'unibyte-object-required))
  (when (> (length bytes) epi-object-byte-limit)
    (epi-ledger--limit-fail
     'object-byte-limit :limit epi-object-byte-limit :bytes (length bytes)))
  (unless (and (stringp media-type) (not (string-empty-p media-type))
               (stringp role) (not (string-empty-p role)))
    (epi-ledger--format-fail 'invalid-object-metadata))
  ;; This validator is callback-free; unlike the cooperative public string
  ;; validator it cannot yield before all three values have been copied.
  (epi-ledger--canonical-string-byte-length-no-callback media-type)
  (epi-ledger--canonical-string-byte-length-no-callback role)
  (let ((gc-cons-threshold most-positive-fixnum))
    (list :bytes (substring-no-properties bytes)
          :media-type (substring-no-properties media-type)
          :role (substring-no-properties role))))

(defun epi-ledger--snapshot-object-reference (object-ref)
  "Return an exact callback-free private snapshot of OBJECT-REF."
  (unless (epi-object-ref-p object-ref)
    (signal 'wrong-type-argument (list 'epi-object-ref-p object-ref)))
  (let ((hash (epi-object-ref--raw-hash object-ref))
        (size (epi-object-ref--raw-size object-ref))
        (media-type (epi-object-ref--raw-media-type object-ref))
        (role (epi-object-ref--raw-role object-ref)))
    (epi-ledger--require-hash hash "object.hash")
    (epi-ledger--require-nonnegative-integer size "object.size")
    (when (> size epi-object-byte-limit)
      (epi-ledger--limit-fail
       'object-byte-limit :field "object.size"
       :limit epi-object-byte-limit :bytes size))
    (unless (and (stringp media-type) (not (string-empty-p media-type))
                 (stringp role) (not (string-empty-p role)))
      (epi-ledger--format-fail 'invalid-object-metadata))
    (epi-ledger--canonical-string-byte-length-no-callback media-type)
    (epi-ledger--canonical-string-byte-length-no-callback role)
    (let ((gc-cons-threshold most-positive-fixnum))
      (list :hash (substring-no-properties hash)
            :size size
            :media-type (substring-no-properties media-type)
            :role (substring-no-properties role)))))

(defun epi-ledger--object-path-for-ledger-path (ledger-path hash)
  "Return canonical LEDGER-PATH's immutable-object path for HASH."
  (epi-ledger--require-hash hash "object.hash")
  (let* ((canonical (epi-ledger--resolve-local-write-path ledger-path))
         (objects (concat canonical ".objects"))
         (sha-directory
          (expand-file-name "sha256" (file-name-as-directory objects)))
         (prefix-directory
          (expand-file-name
           (substring hash 0 2) (file-name-as-directory sha-directory))))
    (expand-file-name hash (file-name-as-directory prefix-directory))))

(defun epi-ledger--object-path (ledger hash)
  "Return LEDGER's canonical immutable-object path for HASH."
  (unless (epi-ledger-p ledger)
    (signal 'wrong-type-argument (list 'epi-ledger-p ledger)))
  (epi-ledger--object-path-for-ledger-path
   (epi-ledger--raw-path ledger) hash))

(defun epi-ledger--object-read-fail (family code)
  "Signal FAMILY's stable object-read failure for CODE."
  (pcase family
    ('missing
     (epi-ledger--fail 'epi-missing-object code))
    ('corrupt
     (epi-ledger--fail 'epi-ledger-corrupt 'object-content-mismatch))
    ('write
     (epi-ledger--fail 'epi-ledger-conflict 'storage-write-failed))
    ('proof
     (epi-ledger--fail 'epi-ledger-conflict code))
    (_ (error "Unknown Epi object-read failure family: %S" family))))

(defun epi-ledger--object-stat-fail (family)
  "Signal FAMILY's stable object-stat failure."
  (if (eq family 'put)
      (epi-ledger--fail 'epi-ledger-conflict 'storage-write-failed)
    (epi-ledger--object-read-fail family 'object-read-failed)))

(defun epi-ledger--object-stat (path family)
  "Return PATH's identity, mapping every stat failure through FAMILY."
  (condition-case condition
      (epi-ledger--owned-stat path)
    (epi-ledger-format-error
     (if (eq family 'put)
       (epi-ledger--fail
          'epi-ledger-corrupt 'object-content-mismatch)
       (epi-ledger--object-read-fail family 'object-read-failed)))
    (file-error
     (epi-ledger--object-stat-fail family))
    (epi-error
     (if (eq 'storage-stat-failed
             (plist-get (epi-ledger--condition-plist condition) :code))
         (epi-ledger--object-stat-fail family)
       (signal (car condition) (cdr condition))))
    (error
     (epi-ledger--object-stat-fail family))))

(defun epi-ledger--object-storage-call (code function &rest arguments)
  "Call FUNCTION with ARGUMENTS, mapping raw file failures to CODE."
  (condition-case condition
      (apply function arguments)
    (file-error
     (ignore condition)
     (epi-ledger--fail 'epi-ledger-conflict code))
    (epi-ledger-format-error
     (epi-ledger--fail 'epi-ledger-conflict code))
    (epi-ledger-conflict
     (if (eq 'storage-stat-failed
             (plist-get (epi-ledger--condition-plist condition) :code))
         (epi-ledger--fail 'epi-ledger-conflict code)
       (signal (car condition) (cdr condition))))))

(defun epi-ledger--object-read-bounded (path maximum family)
  "Read at most MAXIMUM bytes from PATH for error FAMILY.
Every storage request is bounded by `epi-ledger-work-byte-limit'."
  (let ((work (epi-ledger--make-work-state))
        (chunk-limit (max 1 epi-ledger-work-byte-limit))
        (cursor 0)
        (total 0)
        chunks
        done)
    (while (and (< cursor maximum) (not done))
      (let* ((end (min maximum (+ cursor chunk-limit)))
             (requested (- end cursor)))
        (epi-ledger--work-charge work requested)
        (let ((chunk
               (condition-case nil
                   (funcall epi-ledger--read-function path cursor end)
                 (error
                  (epi-ledger--object-read-fail
                   family 'object-read-failed)))))
          (unless (and (stringp chunk)
                       (not (multibyte-string-p chunk))
                       (<= (length chunk) requested))
            (epi-ledger--object-read-fail family 'object-read-failed))
          ;; Own the seam result before any later yield or callback.
          (let* ((owned (substring-no-properties chunk))
                 (amount (length owned)))
            (if (= amount 0)
                (setq done t)
              (push owned chunks)
              (setq cursor (+ cursor amount)
                    total (+ total amount))
              (when (< amount requested)
                (setq done t)))))))
    (setq chunks (epi-ledger--work-nreverse-list chunks work))
    (epi-ledger--work-concat-chunks
     chunks total work 'object-read)))

(defun epi-ledger--object-read-verified-state-impl
    (path expected-size expected-hash family)
  "Return verified PATH bytes and identity for EXPECTED-SIZE and EXPECTED-HASH.
FAMILY selects the stable public error classification."
  (epi-ledger--require-nonnegative-integer expected-size "object.size")
  (when (> expected-size epi-object-byte-limit)
    (epi-ledger--limit-fail
     'object-byte-limit :field "object.size"
     :limit epi-object-byte-limit :bytes expected-size))
  (epi-ledger--require-hash expected-hash "object.hash")
  (let ((identity (epi-ledger--object-stat path family)))
    (unless identity
      (epi-ledger--object-read-fail family 'object-missing))
    (unless (and (integerp (plist-get identity :size))
                 (= expected-size (plist-get identity :size)))
      (epi-ledger--object-read-fail family 'object-size-mismatch))
    (let ((bytes
           (epi-ledger--object-read-bounded
            path (1+ expected-size) family)))
      (unless (= expected-size (length bytes))
        (epi-ledger--object-read-fail family 'object-size-mismatch))
      (unless (equal expected-hash
                     (epi-ledger--hash bytes 'object-content))
        (epi-ledger--object-read-fail family 'object-hash-mismatch))
      (let ((rechecked (epi-ledger--object-stat path family)))
        (unless (equal identity rechecked)
          (epi-ledger--object-read-fail family 'object-read-failed))
        (list :bytes bytes :identity rechecked)))))

(defun epi-ledger--object-read-verified-state
    (path expected-size expected-hash family)
  "Return verified PATH state for EXPECTED-SIZE, EXPECTED-HASH, and FAMILY."
  (epi-ledger--object-read-verified-state-impl
   path expected-size expected-hash family))

(defun epi-ledger--object-read-verified-raw
    (path expected-size expected-hash)
  "Verify PATH against EXPECTED-SIZE and EXPECTED-HASH without seams."
  (let ((epi-ledger--stat-function #'epi-ledger--stat-local-file)
        (epi-ledger--read-function #'epi-ledger--read-bytes)
        (epi--yield-function #'ignore)
        (epi--deadline-clock-function #'float-time)
        (epi-ledger--nonpreemptible-observer nil))
    (epi-ledger--object-read-verified-state-impl
     path expected-size expected-hash 'proof)))

(defun epi-ledger--object-read-verified
    (path expected-size expected-hash family)
  "Read PATH and verify EXPECTED-SIZE and EXPECTED-HASH for FAMILY."
  (plist-get
   (epi-ledger--object-read-verified-state
    path expected-size expected-hash family)
   :bytes))

(defun epi-ledger--write-object-temporary (path bytes)
  "Write owned BYTES to temporary PATH and return its created identity."
  (unless (and (stringp bytes) (not (multibyte-string-p bytes)))
    (epi-ledger--format-fail 'unibyte-object-required))
  (let ((work (epi-ledger--make-work-state))
        (cursor 0)
        (first t)
        (chunk-limit (max 1 epi-ledger-work-byte-limit))
        identity
        complete)
    (unwind-protect
        (progn
          (if (= (length bytes) 0)
              (progn
                (epi-ledger--object-storage-call
                 'storage-write-failed epi-ledger--byte-writer
                 path "" 'exclusive-create nil)
                (setq identity
                      (epi-ledger--object-storage-call
                       'storage-write-failed
                       #'epi-ledger--stat-local-file path)))
            (while (< cursor (length bytes))
              (let* ((end (min (length bytes) (+ cursor chunk-limit)))
                     (amount (- end cursor)))
                (epi-ledger--work-charge work amount)
                (epi-ledger--object-storage-call
                 'storage-write-failed epi-ledger--byte-writer
                 path (substring-no-properties bytes cursor end)
                 (if first 'exclusive-create 'append) nil)
                (when first
                  (setq identity
                        (epi-ledger--object-storage-call
                         'storage-write-failed
                         #'epi-ledger--stat-local-file path)))
                (setq cursor end
                      first nil))))
          (unless identity
            (epi-ledger--fail
             'epi-ledger-conflict 'storage-write-failed))
          (epi-ledger--object-storage-call
           'storage-write-failed epi-ledger--byte-writer
           path "" 'append t)
          (setq complete t)
          identity)
      (unless complete
        (epi-ledger--delete-owned-object-name path identity nil)))))

(defun epi-ledger--raw-object-name-state (path)
  "Return callback-free storage state for the exact local name PATH.
The result is nil for absence, `:replacement' for a non-regular leaf,
`:unknown' on an indeterminate probe, or a regular-file identity plist."
  (condition-case nil
      (let* ((file-name-handler-alist nil)
             (owned (substring-no-properties path))
             (attributes (file-attributes owned 'string)))
        (cond
         ((null attributes) nil)
         ((file-attribute-type attributes) :replacement)
         (t
          (list :path owned
                :device (file-attribute-device-number attributes)
                :inode (file-attribute-inode-number attributes)
                :links (file-attribute-link-number attributes)
                :size (file-attribute-size attributes)
                :modified (file-attribute-modification-time attributes)
                :changed (file-attribute-status-change-time attributes)))))
    (error :unknown)))

(defun epi-ledger--delete-owned-object-name (path expected requiredp)
  "Delete PATH only if it still denotes EXPECTED's exact file object.
When REQUIREDP is non-nil, report a failed exact deletion as an ambiguous
postpublication cleanup.  A replacement name is never deleted."
  (when expected
    (let ((identity
           (condition-case condition
               (epi-ledger--stat-local-file path)
             (epi-ledger-format-error
              (if (eq 'non-regular-storage-leaf
                      (plist-get
                       (epi-ledger--condition-plist condition) :code))
                  (epi-ledger--raw-object-name-state path)
                :unknown))
             (error :unknown))))
      (cond
       ((null identity) nil)
       ((eq identity :replacement) nil)
       ((eq identity :unknown)
        (when requiredp
          (epi-ledger--fail
           'epi-ledger-conflict 'storage-publication-failed
           :published t)))
       ((not (epi-ledger--same-file-object-p expected identity)) nil)
       (t
        (condition-case nil
            (let ((file-name-handler-alist nil))
              (delete-file (substring-no-properties path)))
          (file-error
           (when requiredp
             (epi-ledger--fail
              'epi-ledger-conflict 'storage-publication-failed
              :published t)))))))))

(defun epi-ledger--object-publication-failure
    (destination source-identity)
  "Classify a failed publication to DESTINATION from SOURCE-IDENTITY."
  (let ((target
         (condition-case condition
             (epi-ledger--stat-local-file destination)
           (epi-ledger-format-error
            (if (eq 'non-regular-storage-leaf
                    (plist-get
                     (epi-ledger--condition-plist condition) :code))
                (epi-ledger--raw-object-name-state destination)
              :unknown))
           (error :unknown))))
    (cond
     ((eq target :unknown)
      (epi-ledger--fail
       'epi-ledger-conflict 'storage-publication-failed :published t))
     ((eq target :replacement)
      (epi-ledger--fail 'epi-ledger-conflict 'destination-exists))
     ((epi-ledger--same-file-object-p source-identity target)
      (epi-ledger--fail
       'epi-ledger-conflict 'storage-publication-failed :published t))
     (target
      (epi-ledger--fail 'epi-ledger-conflict 'destination-exists))
     (t
      (epi-ledger--fail
       'epi-ledger-conflict 'storage-publication-failed)))))

(defun epi-ledger--object-publication-format-failure (destination)
  "Classify a path-format failure while publishing to DESTINATION."
  (let ((occupied
         (condition-case nil
             (let ((file-name-handler-alist nil)
                   (path (substring-no-properties destination)))
               (or (file-exists-p path) (file-symlink-p path)))
           (error nil))))
    (if occupied
        (epi-ledger--fail 'epi-ledger-conflict 'destination-exists)
      (epi-ledger--fail
       'epi-ledger-conflict 'storage-publication-failed))))

(defun epi-ledger--publish-object
    (temporary destination source-identity &optional receipt-receiver)
  "Publish TEMPORARY at DESTINATION while bound to SOURCE-IDENTITY.
RECEIPT-RECEIVER, when non-nil, receives the raw normal-return publication
receipt before injectable post-link observations."
  (let* ((owned-temporary (substring-no-properties temporary))
         (owned-destination (substring-no-properties destination))
         (owned-source
          (epi-ledger--copy-tree-and-strings source-identity))
         (epi-ledger--publish-expected-source-identity
          (epi-ledger--copy-tree-and-strings owned-source))
         ;; Mask any dynamically enclosing publication.  Only the call that
         ;; explicitly supplies RECEIPT-RECEIVER may receive this receipt.
         (epi-ledger--publication-receipt-receiver receipt-receiver))
    (condition-case condition
        (funcall epi-ledger--publish-function
                 (substring-no-properties owned-temporary)
                 (substring-no-properties owned-destination))
    (file-error
     (ignore condition)
     (epi-ledger--object-publication-failure
      owned-destination owned-source))
    (epi-ledger-format-error
     (epi-ledger--object-publication-format-failure owned-destination))
      (epi-ledger-conflict
       (if (eq 'storage-stat-failed
               (plist-get (epi-ledger--condition-plist condition) :code))
           (epi-ledger--object-publication-failure
            owned-destination owned-source)
         (signal (car condition) (cdr condition)))))))

(defun epi-ledger--object-condition-code (condition)
  "Return the stable code carried by structured Epi CONDITION."
  (let ((detail (and (consp (cdr condition)) (cadr condition))))
    (and (listp detail) (plist-get detail :code))))

(defun epi-ledger--verify-object-for-put
    (path expected-size expected-hash &optional published-identity)
  "Verify PATH for put against EXPECTED-SIZE and EXPECTED-HASH.
PUBLISHED-IDENTITY, when non-nil, permits rollback only after the raw proof
establishes size or hash corruption of that exact owned publication."
  (let (dynamic-failure raw-failure)
    (condition-case condition
        (epi-ledger--object-read-verified
         path expected-size expected-hash 'corrupt)
      (error (setq dynamic-failure condition)))
    (condition-case condition
        (epi-ledger--object-read-verified-raw
         path expected-size expected-hash)
      (error (setq raw-failure condition)))
    (when raw-failure
      (let ((code (epi-ledger--object-condition-code raw-failure)))
        (when (and published-identity
                   (memq code '(object-size-mismatch object-hash-mismatch)))
          (epi-ledger--delete-owned-object-name
           path published-identity nil))
        (if (and published-identity (eq code 'object-missing))
            (epi-ledger--fail
             'epi-ledger-conflict 'storage-publication-failed)
          (if dynamic-failure
            (signal (car dynamic-failure) (cdr dynamic-failure))
            (if (memq code '(object-size-mismatch object-hash-mismatch))
                (epi-ledger--fail
                 'epi-ledger-corrupt 'object-content-mismatch)
              (if published-identity
                  (epi-ledger--fail
                   'epi-ledger-conflict 'storage-publication-failed
                   :published t)
                (epi-ledger--fail
                 'epi-ledger-conflict 'storage-read-failed)))))))
    (when dynamic-failure
      (signal (car dynamic-failure) (cdr dynamic-failure)))
    t))

(cl-defun epi-ledger-object-put (ledger bytes &key media-type role)
  "Store BYTES for LEDGER with MEDIA-TYPE and ROLE and return its reference."
  (unless (epi-ledger-p ledger)
    (signal 'wrong-type-argument (list 'epi-ledger-p ledger)))
  ;; Own all caller data before operation-state initialization samples a
  ;; clock or any measured hash performs its first cooperative yield.
  (let ((input (epi-ledger--snapshot-object-input bytes media-type role)))
    (epi-ledger--with-operation-work-state
      (let* ((owned-bytes (plist-get input :bytes))
             (owned-media-type (plist-get input :media-type))
             (owned-role (plist-get input :role))
             (size (length owned-bytes))
             (hash (epi-ledger--hash owned-bytes 'object-content))
             (path (epi-ledger--object-path ledger hash))
             (reference
              (make-epi-object-ref
               :hash hash :size size
               :media-type owned-media-type :role owned-role)))
        (if (epi-ledger--object-stat path 'put)
            (progn
              (epi-ledger--verify-object-for-put path size hash)
              reference)
          (epi-ledger--ensure-private-parent path)
          ;; A winner may have appeared while the private directory chain was
          ;; being created.  Verify it without creating another temporary.
          (if (epi-ledger--object-stat path 'put)
              (progn
                (epi-ledger--verify-object-for-put path size hash)
                reference)
            (let ((temporary (epi-ledger--hidden-sibling path))
                  temporary-identity)
              (unwind-protect
                  (progn
                    (setq temporary-identity
                          (epi-ledger--write-object-temporary
                           temporary owned-bytes))
        (let ((state
               (epi-ledger--object-read-verified-state
                temporary size hash 'write)))
          (unless
              (epi-ledger--same-file-object-p
               temporary-identity
               (plist-get state :identity))
            (epi-ledger--fail
             'epi-ledger-conflict 'storage-write-failed))
          (setq temporary-identity (plist-get state :identity)))
                    (let ((outcome
                           (condition-case condition
                               (progn
                                 (epi-ledger--publish-object
                                  temporary path temporary-identity)
                                 'published)
                             (epi-ledger-conflict
                              (let* ((detail
                                      (epi-ledger--condition-plist
                                       condition))
                                     (code
                                      (and detail
                                           (plist-get detail :code))))
                                (if (eq code 'destination-exists)
                                    'collision
                                  (signal (car condition)
                                          (cdr condition))))))))
                      (epi-ledger--verify-object-for-put
                       path size hash
                       (and (eq outcome 'published)
                            temporary-identity)))
                    (epi-ledger--delete-owned-object-name
                     temporary temporary-identity t)
                    (setq temporary nil)
                    reference)
                (when temporary-identity
                  (epi-ledger--delete-owned-object-name
                   temporary temporary-identity nil))))))))))

(defun epi-ledger-object-get (ledger object-ref)
  "Return verified object bytes from LEDGER for OBJECT-REF."
  (unless (epi-ledger-p ledger)
    (signal 'wrong-type-argument (list 'epi-ledger-p ledger)))
  (let ((reference (epi-ledger--snapshot-object-reference object-ref)))
    (epi-ledger--with-operation-work-state
      (epi-ledger--object-read-verified
       (epi-ledger--object-path ledger (plist-get reference :hash))
       (plist-get reference :size)
       (plist-get reference :hash)
       'missing))))

(defun epi-ledger--object-present-p (ledger object-ref)
  "Return non-nil if LEDGER has the exact OBJECT-REF bytes."
  (unless (epi-ledger-p ledger)
    (signal 'wrong-type-argument (list 'epi-ledger-p ledger)))
  (let ((reference (epi-ledger--snapshot-object-reference object-ref)))
    (epi-ledger--with-operation-work-state
      (let ((path
             (epi-ledger--object-path ledger
                                      (plist-get reference :hash))))
        (when (epi-ledger--object-stat path 'corrupt)
          (epi-ledger--object-read-verified
           path (plist-get reference :size)
           (plist-get reference :hash) 'corrupt)
          (condition-case nil
              (epi-ledger--object-read-verified-raw
               path (plist-get reference :size)
               (plist-get reference :hash))
            (error
             (epi-ledger--object-read-fail
              'corrupt 'object-read-failed)))
          t)))))

(defconst epi-ledger--frame-terminator "\n#+end_epi-json\n"
  "Literal byte sequence terminating one canonical ledger record frame.")

(defun epi-ledger--file-identity (path)
  "Return the publication identity of canonical file PATH."
  (let ((attributes (file-attributes path 'string)))
    (unless attributes
      (epi-ledger--format-fail 'ledger-file-missing))
    (list :path (substring-no-properties path)
          :device (file-attribute-device-number attributes)
          :inode (file-attribute-inode-number attributes)
          :links (file-attribute-link-number attributes)
          :size (file-attribute-size attributes)
          :modified (file-attribute-modification-time attributes)
          :changed (file-attribute-status-change-time attributes))))

(defvar epi-ledger--open-identity-reader #'epi-ledger--file-identity
  "Private publication-identity seam used by `epi-ledger-open'.")

(defun epi-ledger--open-signal
    (condition code path sequence record-id offset &optional cause-code)
  "Signal loader CONDITION with CODE for PATH at SEQUENCE and OFFSET.
RECORD-ID is the known record identifier or nil; CAUSE-CODE is the redacted
nested cause when it differs from CODE."
  (epi--signal
   condition
   (list :code code
         :path (substring-no-properties path)
         :sequence sequence
         :record-id (and record-id (substring-no-properties record-id))
         :offset offset
         :cause (list :code (or cause-code code)))))

(defun epi-ledger--open-condition-code (condition fallback)
  "Return CONDITION's structured code, or FALLBACK."
  (let ((detail (epi-ledger--condition-plist condition)))
    (or (and detail (plist-get detail :code)) fallback)))

(defun epi-ledger--open-condition-offset (condition fallback)
  "Return CONDITION's structured byte offset, or FALLBACK."
  (let ((detail (epi-ledger--condition-plist condition)))
    (or (and detail (plist-get detail :offset)) fallback)))

(defun epi-ledger--frame-headline-fields (source)
  "Return (TYPE-TEXT ID) from SOURCE's charged bounded headline prefix."
  (condition-case nil
      (let* ((work (epi-ledger--make-work-state))
             (line-result
              (epi-ledger--line-at
               source 0 (1+ epi-ledger--maximum-headline-byte-length)))
             (headline (epi-ledger--work-car line-result work)))
        (when (string-match
               "\\`\\* \\([a-z][a-z0-9-]*\\) \\([0-9a-f-]+\\)\\'"
               headline)
          (list (match-string 1 headline)
                (match-string 2 headline))))
    (error nil)))

(defun epi-ledger--loader-frame-code (code)
  "Map physical scanner CODE to the loader's stable corruption code."
  (if (eq code 'missing-json-end) 'bytes-after-fragment code))

(defvar epi-ledger--open-work-observer nil
  "Private collector cell for redacted loader work events.
Tests may dynamically bind this to a one-element list.  The loader prepends
metadata plists to that element; it never executes a caller-supplied value.")

(defvar epi-ledger--open-source-inserter #'insert-file-contents-literally
  "Private source-insertion seam used by `epi-ledger-open'.")

(defvar epi-ledger--open-head-inserter #'insert-file-contents-literally
  "Private current-head verification seam used by `epi-ledger-open'.")

(defvar epi-ledger--open-publication-phase nil
  "Non-nil only while the final no-yield publication identity is read.")

(defun epi-ledger--open-observe-work (kind field bytes &rest properties)
  "Record redacted loader work metadata KIND, FIELD, BYTES, and PROPERTIES."
  (let ((collector epi-ledger--open-work-observer))
    (when (and (consp collector) (listp (car collector)))
      (setcar collector
              (cons (append (list :kind kind :field field :bytes bytes)
                            properties)
                    (car collector))))))

(defun epi-ledger--open-charge-scan (work field bytes)
  "Reserve and report a bounded FIELD scan of BYTES in WORK."
  (epi-ledger--work-charge work bytes)
  (epi-ledger--open-observe-work 'scan field bytes :bounded t))

(defun epi-ledger--open-require-identity
    (path expected sequence offset)
  "Require PATH's identity to equal EXPECTED at SEQUENCE and OFFSET."
  (let ((current
         (condition-case nil
             (funcall epi-ledger--open-identity-reader path)
           (error nil))))
    (unless (equal expected current)
      (epi-ledger--open-signal
       'epi-ledger-conflict 'file-identity-changed path sequence nil offset
       'file-identity-changed))))

(defun epi-ledger--open-insert-source-range
    (path begin end work identity sequence &optional inserter field)
  "Insert PATH's exact half-open byte range BEGIN..END at point.
Charge WORK and require IDENTITY around the sliced read at SEQUENCE.
INSERTER overrides the reader; FIELD labels observed work."
  (let ((amount (- end begin))
        (before (buffer-size))
        (inserter (or inserter epi-ledger--open-source-inserter))
        (field (or field 'source-read)))
    (epi-ledger--open-require-identity path identity sequence begin)
    (epi-ledger--work-charge work amount)
    (epi-ledger--open-observe-work
     'read field amount :begin begin :end end :bounded t)
    (funcall inserter path nil begin end)
    (unless (= (- (buffer-size) before) amount)
      (epi-ledger--format-fail 'short-ledger-read :offset begin))
    (epi-ledger--open-require-identity path identity sequence end)))

(defun epi-ledger--open-discard-prefix (end work)
  "Discard bytes before END using WORK without moving a frame-sized suffix."
  (let ((remaining (- (point-max) end)))
    (when (> remaining epi-ledger-work-byte-limit)
      (error "Unbounded loader compaction suffix: %S" remaining))
    (let ((suffix
           (when (> remaining 0)
             (epi-ledger--open-observe-work
              'copy 'compaction-read remaining :bounded t)
             (epi-ledger--work-charge work remaining)
             (buffer-substring-no-properties end (point-max)))))
      (erase-buffer)
      (when suffix
        (epi-ledger--open-observe-work
         'copy 'compaction-write remaining :bounded t)
        (epi-ledger--work-charge work remaining)
        (insert suffix)))))

(defun epi-ledger--open-search-newline (start limit field work)
  "Search START..LIMIT for LF as bounded FIELD work using WORK.
Return a cons whose car is the point after LF, or nil, and whose cdr is the
next position from which newly inserted bytes should be searched."
  (let ((cursor start)
        found)
    (while (and (not found) (< cursor limit))
      (let* ((end (min limit (+ cursor epi-ledger-work-byte-limit)))
             (amount (- end cursor)))
        (epi-ledger--open-charge-scan work field amount)
        (setq found
              (save-excursion
                (goto-char cursor)
                (search-forward "\n" end t))
              cursor (or found end))))
    (cons found cursor)))

(defun epi-ledger--open-terminator-at-p (start work)
  "Return non-nil when the frame terminator begins at START.
Charge the comparison in bounded pieces to WORK."
  (let ((index 0)
        (length (length epi-ledger--frame-terminator))
        (matched t))
    (while (and matched (< index length))
      (let ((amount
             (min (- length index) epi-ledger-work-byte-limit)))
        (epi-ledger--open-charge-scan work 'terminator-compare amount)
        (dotimes (offset amount)
          (unless (= (char-after (+ start index offset))
                     (aref epi-ledger--frame-terminator
                           (+ index offset)))
            (setq matched nil)))
        (setq index (+ index amount))))
    matched))

(defun epi-ledger--open-find-frame-end (start limit work)
  "Find a frame terminator between START and LIMIT using WORK.
Return a plist containing either :end or the incremental :search cursor."
  (let ((search start)
        result
        frame-end)
    (while (and (not frame-end) (< search limit))
      (setq result
            (epi-ledger--open-search-newline
             search limit 'terminator-scan work))
      (let ((after-newline (car result)))
        (if (not after-newline)
            (setq search (cdr result))
          (let ((candidate (1- after-newline)))
            (cond
             ((> (+ candidate (length epi-ledger--frame-terminator))
                 limit)
              (setq search candidate
                    limit candidate))
             ((epi-ledger--open-terminator-at-p candidate work)
              (setq frame-end
                    (+ candidate (length epi-ledger--frame-terminator))))
             (t
              (setq search after-newline)))))))
    (if frame-end
        (list :end frame-end :search frame-end)
      (list :search search))))

(defun epi-ledger--payload-value (record key)
  "Return KEY from RECORD's validated payload."
  (epi-ledger--object-value (epi-record--raw-payload record) key))

(defun epi-ledger--message-item (record)
  "Return RECORD's sole validated message content item."
  (aref (epi-ledger--payload-value record "content") 0))

(defun epi-ledger--message-kind (record)
  "Return RECORD's message content type, or nil for another record type."
  (and (eq (epi-record--raw-type record) 'message)
       (epi-ledger--object-value (epi-ledger--message-item record) "type")))

(defun epi-ledger--terminal-class (type)
  "Return the outer lifecycle class represented by terminal TYPE."
  (pcase type
    ((or 'turn-finished 'operation-finished) 'success)
    ((or 'turn-failed 'operation-failed) 'failed)
    ((or 'turn-cancelled 'operation-cancelled) 'cancelled)
    ((or 'turn-interrupted 'operation-interrupted) 'interrupted)))

(defun epi-ledger--turn-terminal-p (type)
  "Return non-nil when TYPE terminates a turn."
  (memq type '(turn-finished turn-failed turn-cancelled turn-interrupted)))

(defun epi-ledger--operation-terminal-p (type)
  "Return non-nil when TYPE terminates an operation."
  (memq type '(operation-finished operation-failed operation-cancelled
               operation-interrupted)))

(defun epi-ledger--semantic-fail (code)
  "Abort semantic validation with stable loader CODE."
  (epi-ledger--format-fail code))

(defun epi-ledger--require-ordinary-interruption-reason (record uncertain)
  "Require RECORD's ordinary interruption reason unless UNCERTAIN."
  (when (and (eq (epi-ledger--terminal-class
                  (epi-record--raw-type record))
                 'interrupted)
             (not uncertain)
             (not (equal (epi-ledger--payload-value record "reason")
                         "interrupted")))
    (epi-ledger--semantic-fail 'interrupted-terminal-reason)))

(defun epi-ledger--uncertainty-detail-valid-p (record class)
  "Return non-nil when RECORD carries CLASS's exact uncertainty detail."
  (equal (epi-ledger--payload-value
          record (if (eq class 'failed) "code" "reason"))
         "tool-uncertain"))

(defun epi-ledger--validate-uncertainty-admission (state record kind)
  "Admit RECORD only when it advances STATE's uncertainty barrier.
KIND is RECORD's validated message-content kind, when RECORD is a message."
  (let ((phase (epi-ledger--validation-state-uncertainty-phase state))
        (type (epi-record--raw-type record)))
    (pcase phase
      ('turn-terminal
       (cond
        ((and (eq type 'message) (equal kind "tool-result"))
         (epi-ledger--semantic-fail 'result-after-uncertain))
        ((memq type '(turn-finished turn-cancelled))
         (epi-ledger--semantic-fail 'uncertain-success-terminal))
        ((not (memq type '(turn-failed turn-interrupted)))
         (epi-ledger--semantic-fail 'uncertain-terminal-adjacency))
        ((not (and
               (equal (epi-record--raw-turn record)
                      (epi-ledger--validation-state-uncertainty-turn state))
               (equal
                (epi-record--raw-operation record)
                (epi-ledger--validation-state-uncertainty-operation state))))
         (epi-ledger--semantic-fail 'uncertain-terminal-adjacency))
        (t
         (let ((class (epi-ledger--terminal-class type)))
           (unless (epi-ledger--uncertainty-detail-valid-p record class)
             (epi-ledger--semantic-fail 'uncertain-terminal-detail))))))
      ('operation-terminal
       (let ((class (epi-ledger--terminal-class type)))
         (unless (and
                  (memq type '(operation-failed operation-interrupted))
                  (or (eq type 'operation-interrupted)
                      (eq class
                          (epi-ledger--validation-state-uncertainty-class
                           state)))
                  (equal
                   (epi-record--raw-operation record)
                   (epi-ledger--validation-state-uncertainty-operation state)))
           (epi-ledger--semantic-fail 'uncertain-terminal-adjacency))
         (unless (epi-ledger--uncertainty-detail-valid-p record class)
           (epi-ledger--semantic-fail 'uncertain-terminal-detail))))
      ('blocked
       (epi-ledger--semantic-fail 'record-after-uncertainty)))))

(defun epi-ledger--state-turn-operation (state turn-id)
  "Return TURN-ID's operation in STATE, when known."
  (let ((turn (and turn-id
                   (gethash turn-id
                            (epi-ledger--validation-state-turns state)))))
    (and turn (plist-get turn :operation))))

(defun epi-ledger--state-record-operation (state record)
  "Return the operation associated with RECORD in STATE."
  (or (epi-record--raw-operation record)
      (epi-ledger--state-turn-operation state (epi-record--raw-turn record))))

(defun epi-ledger--validate-turn-admission (state record)
  "Reject RECORD in STATE when its established turn is already terminal."
  (let* ((type (epi-record--raw-type record))
         (turn-id (epi-record--raw-turn record))
         (turn
          (and turn-id
               (gethash turn-id
                        (epi-ledger--validation-state-turns state)))))
    (when (and turn
               (eq (plist-get turn :state) 'terminal)
               (not (epi-ledger--turn-terminal-p type))
               ;; Tool results get the more precise pending-call ownership
               ;; checks, including a turn from a different operation.
               (not (and (eq type 'message)
                         (equal (epi-ledger--message-kind record)
                                "tool-result"))))
      (epi-ledger--semantic-fail 'record-after-turn-terminal))))

(defun epi-ledger--validate-intended-message (state record)
  "Validate STATE's sole forward intent against message RECORD.
This check deliberately does not mutate the intent fact."
  (when (eq (epi-record--raw-type record) 'message)
    (let* ((id (epi-record--raw-id record))
           (turn-id (epi-record--raw-turn record))
           (role (epi-ledger--payload-value record "role"))
           (intended-turn
            (gethash id (epi-ledger--validation-state-intents state)))
           (turn
            (gethash turn-id (epi-ledger--validation-state-turns state))))
      (cond
       (intended-turn
        (unless (equal turn-id intended-turn)
          (epi-ledger--semantic-fail 'intended-message-turn))
       (unless (equal role "user")
          (epi-ledger--semantic-fail 'intended-message-role)))
       ((and turn (eq (plist-get turn :intent-state) 'pending))
        (epi-ledger--semantic-fail 'intended-message-id))
       ((and turn (equal role "user"))
        (epi-ledger--semantic-fail 'unexpected-user-message))))))

(defun epi-ledger--commit-intended-message (state record)
  "Mark RECORD's already validated intended message satisfied in STATE."
  (let ((intended-turn
         (gethash (epi-record--raw-id record)
                  (epi-ledger--validation-state-intents state))))
    (when intended-turn
      (let ((fact (gethash intended-turn
                           (epi-ledger--validation-state-turns state))))
        (setf (plist-get fact :intent-state) 'satisfied)))))

(defun epi-ledger--validate-intent-admission (state record)
  "Require STATE's intended input before RECORD advances its active turn."
  (let* ((operation (epi-ledger--validation-state-active-operation state))
         (turn (and operation (plist-get operation :active-turn))))
    (when (and turn (eq (plist-get turn :intent-state) 'pending))
      (let ((type (epi-record--raw-type record)))
        (cond
         ((eq type 'message)
          (unless (equal (epi-record--raw-id record)
                         (plist-get turn :expected-message))
            (epi-ledger--semantic-fail 'intended-message-id)))
         ((and (eq type 'turn-interrupted)
               (equal (epi-record--raw-turn record) (plist-get turn :id))
               (equal (epi-record--raw-operation record)
                      (plist-get turn :operation)))
          (unless (equal (epi-ledger--payload-value record "reason")
                         "interrupted")
            (epi-ledger--semantic-fail 'interrupted-terminal-reason)))
         (t
          (epi-ledger--semantic-fail 'intended-message-adjacency)))))))

(defun epi-ledger--defer-reference (state kind record referenced-id)
  "Remember in STATE unresolved KIND from RECORD to REFERENCED-ID."
  (push (list :kind kind :record record :id referenced-id)
        (epi-ledger--validation-state-deferred-references state)))

(defun epi-ledger--earliest-deferred-reference (state)
  "Return STATE's earliest unresolved backward reference, or nil."
  (let ((earliest nil))
    (dolist (reference
             (epi-ledger--validation-state-deferred-references state))
      (when (or (null earliest)
                (< (epi-record--raw-sequence (plist-get reference :record))
                   (epi-record--raw-sequence (plist-get earliest :record))))
        (setq earliest reference)))
    earliest))

(defun epi-ledger--deferred-reference-code (reference present)
  "Return REFERENCE's stable error code, refined by PRESENT."
  (if present
      (if (eq (plist-get reference :kind) 'parent)
          'forward-parent
        'forward-target)
    (if (eq (plist-get reference :kind) 'parent)
        'missing-parent
      'missing-target)))

(defun epi-ledger--validate-message-parent (state record)
  "Validate ordinary message RECORD's parent in STATE.
Return non-nil only when the parent is absent or already resolved."
  (let ((parent (epi-record--raw-parent record)))
    (if (not parent)
        t
      (let ((referenced
             (gethash parent (epi-ledger--validation-state-by-id state))))
        (cond
         ((null referenced)
          (epi-ledger--defer-reference state 'parent record parent)
          nil)
         ((not (eq (epi-record--raw-type referenced) 'message))
          (epi-ledger--semantic-fail 'wrong-family-parent))
         (t t))))))

(defun epi-ledger--validate-leaf-target (state record)
  "Validate leaf RECORD's target in STATE."
  (let* ((target (epi-record--raw-target record))
         (referenced
          (gethash target (epi-ledger--validation-state-by-id state))))
    (cond
     ((null referenced)
      (epi-ledger--defer-reference state 'target record target))
     ((not (eq (epi-record--raw-type referenced) 'message))
      (epi-ledger--semantic-fail 'wrong-family-target)))))

(defun epi-ledger--validate-select-leaf-admission (state record)
  "Require RECORD to advance STATE's active select-leaf in exact order."
  (let ((operation (epi-ledger--validation-state-active-operation state)))
    (when (and operation
               (eq (plist-get operation :state) 'open)
               (equal (plist-get operation :kind) "select-leaf"))
      (let ((type (epi-record--raw-type record))
            (phase (plist-get operation :select-state)))
        (unless
            (pcase phase
              ('awaiting-leaf
               (or (eq type 'leaf)
                   (epi-ledger--operation-terminal-p type)))
              ('awaiting-terminal
               (epi-ledger--operation-terminal-p type)))
          (epi-ledger--semantic-fail 'select-leaf-order))))))

(defun epi-ledger--validate-leaf (state record)
  "Validate and consume one turnless leaf-selection RECORD in STATE."
  (let* ((operation-id (epi-record--raw-operation record))
         (operation
          (gethash operation-id
                   (epi-ledger--validation-state-operations state))))
    (unless (and operation
                 (equal (plist-get operation :kind) "select-leaf")
                 (eq operation
                     (epi-ledger--validation-state-active-operation state)))
      (epi-ledger--semantic-fail 'leaf-operation-kind))
    (when (> (plist-get operation :leaf-count) 0)
      (epi-ledger--semantic-fail 'select-leaf-order))
    (epi-ledger--validate-leaf-target state record)
    (setf (plist-get operation :leaf-count) 1
          (plist-get operation :select-state) 'awaiting-terminal)))

(defun epi-ledger--validate-operation-reference
    (state record &optional existence-only)
  "Validate RECORD's established turn and operation ownership in STATE.
When EXISTENCE-ONLY is non-nil, defer the terminal-operation check so a known
open-turn intent mismatch can retain its more precise diagnostic."
  (let* ((turn-id (epi-record--raw-turn record))
         (turn
          (and turn-id
               (gethash turn-id
                        (epi-ledger--validation-state-turns state))))
         (operation-id
          (or (epi-record--raw-operation record)
              (and turn (plist-get turn :operation))))
         (operation
          (and operation-id
               (gethash operation-id
                        (epi-ledger--validation-state-operations state)))))
    (when (and turn-id (null turn))
      (epi-ledger--semantic-fail 'missing-turn))
    (when (and operation-id (null operation))
      (epi-ledger--semantic-fail 'missing-operation))
    (when (and (not existence-only)
               operation (eq (plist-get operation :state) 'terminal))
      (epi-ledger--semantic-fail 'record-after-operation-terminal))))

(defun epi-ledger--validate-operation-start (state record)
  "Consume operation-started RECORD into STATE."
  (let* ((operation-id (epi-record--raw-operation record))
         (operations (epi-ledger--validation-state-operations state))
         (kind (epi-ledger--payload-value record "kind")))
    (unless (member kind '("prompt" "select-leaf"))
      (epi-ledger--semantic-fail 'unsupported-operation-kind))
    (when (gethash operation-id operations)
      (epi-ledger--semantic-fail 'duplicate-operation-start))
    (let ((active (epi-ledger--validation-state-active-operation state)))
      (when (and active (eq (plist-get active :state) 'open))
        (epi-ledger--semantic-fail 'duplicate-operation-start)))
    (let ((fact (list :id operation-id :state 'open :record record
                      :kind kind
                      :turn-count 0 :active-turn nil :last-turn-class nil
                      :terminal-class nil :uncertain nil :leaf-count 0
                      :select-state (and (equal kind "select-leaf")
                                         'awaiting-leaf))))
      (puthash operation-id fact operations)
      (setf (epi-ledger--validation-state-active-operation state) fact))))

(defun epi-ledger--validate-turn-start (state record)
  "Consume turn-started RECORD into STATE."
  (let* ((turn-id (epi-record--raw-turn record))
         (operation-id (epi-record--raw-operation record))
         (operations (epi-ledger--validation-state-operations state))
         (operation (gethash operation-id operations))
         (turns (epi-ledger--validation-state-turns state)))
    (unless operation
      (epi-ledger--semantic-fail 'turn-without-operation))
    (when (eq (plist-get operation :state) 'terminal)
      (epi-ledger--semantic-fail 'record-after-operation-terminal))
    (when (gethash turn-id turns)
      (epi-ledger--semantic-fail 'duplicate-turn-start))
    (let ((active-turn (plist-get operation :active-turn)))
      (when (and active-turn
                 (eq (plist-get active-turn :state) 'open))
        (epi-ledger--semantic-fail 'duplicate-turn-start)))
    (when (> (plist-get operation :turn-count) 0)
      (epi-ledger--semantic-fail 'operation-turn-limit))
    (let* ((message-id (epi-ledger--payload-value record "message_id"))
           (by-id (epi-ledger--validation-state-by-id state))
           (intents (epi-ledger--validation-state-intents state))
           (fact (list :id turn-id :operation operation-id :state 'open
                       :record record :expected-message message-id
                       :intent-state 'pending :next-order 0
                       :terminal-class nil :uncertain nil
                       :tool-terminal-cause nil)))
      (when (or (equal message-id (epi-record--raw-id record))
                (gethash message-id by-id))
        (epi-ledger--semantic-fail 'intended-message-not-forward))
      (when (gethash message-id intents)
        (epi-ledger--semantic-fail 'duplicate-intended-message))
      (puthash turn-id fact turns)
      (puthash turn-id operation-id
               (epi-ledger--validation-state-turn-operation-index state))
      (puthash message-id turn-id intents)
      (setf (plist-get operation :active-turn) fact
            (plist-get operation :turn-count)
            (1+ (plist-get operation :turn-count))))))

(defun epi-ledger--validate-active-call-continuation (state type)
  "Require STATE's nonterminal call to continue as record TYPE or reach EOF."
  (let ((call (epi-ledger--validation-state-active-call state)))
    (when (and call
               (memq (plist-get call :state) '(planned approved started))
               (not (memq type '(tool-approved tool-denied
                                 tool-started tool-finished))))
      (epi-ledger--semantic-fail 'invalid-tool-pairing))))

(defun epi-ledger--validate-proposal (state record)
  "Validate and reserve proposal RECORD for its adjacent plan in STATE."
  (let* ((turn
          (gethash (epi-record--raw-turn record)
                   (epi-ledger--validation-state-turns state)))
         (call-id (epi-ledger--proposal-field record "call_id"))
         (order (epi-ledger--proposal-field record "order"))
         (expected (plist-get turn :next-order)))
    (when (gethash call-id
                   (epi-ledger--validation-state-reserved-call-ids state))
      (epi-ledger--semantic-fail 'duplicate-call-id))
    (unless (= order expected)
      (epi-ledger--semantic-fail
       (cond ((zerop expected) 'first-call-order-nonzero)
             ((< order expected) 'duplicate-call-order)
             (t 'call-order-gap))))
    ;; Durable proposal IDs remain globally reserved even when an exact crash
    ;; interruption abandons the proposal before its plan is written.
    (puthash call-id t
             (epi-ledger--validation-state-reserved-call-ids state))
    (setf (epi-ledger--validation-state-pending-proposal state) record)))

(defun epi-ledger--proposal-field (record key)
  "Return tool-call KEY from proposal message RECORD."
  (epi-ledger--object-value (epi-ledger--message-item record) key))

(defun epi-ledger--proposal-interruption-p (state record)
  "Return non-nil when RECORD exactly abandons STATE's pending proposal."
  (let ((proposal (epi-ledger--validation-state-pending-proposal state)))
    (and proposal
         (eq (epi-record--raw-type record) 'turn-interrupted)
         (equal (epi-record--raw-turn record)
                (epi-record--raw-turn proposal))
         (equal (epi-record--raw-operation record)
                (epi-ledger--state-record-operation state proposal))
         (equal (epi-ledger--payload-value record "reason")
                "interrupted"))))

(defun epi-ledger--validate-tool-plan (state record)
  "Validate RECORD against STATE's immediately preceding proposal."
  (let ((proposal (epi-ledger--validation-state-pending-proposal state)))
    (unless proposal
      (epi-ledger--semantic-fail 'orphan-tool-planned))
    (unless (equal (epi-record--raw-target record)
                   (epi-record--raw-id proposal))
      (epi-ledger--semantic-fail 'plan-target-mismatch))
    (unless (equal (epi-record--raw-turn record)
                   (epi-record--raw-turn proposal))
      (epi-ledger--semantic-fail 'plan-turn-mismatch))
    (let* ((turn-id (epi-record--raw-turn record))
           (turn (gethash turn-id
                          (epi-ledger--validation-state-turns state)))
           (operation-id (and turn (plist-get turn :operation))))
      (unless (equal (epi-record--raw-operation record) operation-id)
        (epi-ledger--semantic-fail 'plan-operation-mismatch))
      (dolist (entry '(("call_id" . proposal-call-id-mismatch)
                       ("name" . proposal-name-mismatch)
                       ("arguments" . proposal-arguments-mismatch)
                       ("order" . proposal-order-mismatch)))
        (unless (equal (epi-ledger--payload-value record (car entry))
                       (epi-ledger--proposal-field proposal (car entry)))
          (epi-ledger--semantic-fail (cdr entry))))
      (let* ((call-id (epi-ledger--payload-value record "call_id"))
             (calls (epi-ledger--validation-state-calls state))
             (order (epi-ledger--payload-value record "order"))
             (expected (plist-get turn :next-order)))
        (when (gethash call-id calls)
          (epi-ledger--semantic-fail 'duplicate-call-id))
        (unless (= order expected)
          (epi-ledger--semantic-fail
           (cond ((zerop expected) 'first-call-order-nonzero)
                 ((< order expected) 'duplicate-call-order)
                 (t 'call-order-gap))))
        (let ((call
               (list :call-id call-id :proposal proposal
                     :target (epi-record--raw-id proposal)
                     :turn turn-id :operation operation-id
                     :name (epi-ledger--payload-value record "name")
                     :order order :state 'planned :plan record
                     :terminal nil :status nil :result nil)))
          (puthash call-id call calls)
          (puthash (epi-record--raw-id proposal) call
                   (epi-ledger--validation-state-calls-by-target state))
          (setf (plist-get turn :next-order) (1+ expected)
                (epi-ledger--validation-state-active-call state) call
                (epi-ledger--validation-state-pending-proposal state) nil))))))

(defun epi-ledger--call-for-lifecycle (state record)
  "Return the call RECORD is expected to advance in STATE."
  (or (epi-ledger--validation-state-active-call state)
      (gethash (epi-record--raw-target record)
               (epi-ledger--validation-state-calls-by-target state))))

(defun epi-ledger--validate-lifecycle-identity (record call)
  "Validate RECORD's target, turn, operation, and call id against CALL."
  (unless call
    (epi-ledger--semantic-fail 'invalid-tool-pairing))
  (unless (equal (epi-record--raw-target record) (plist-get call :target))
    (epi-ledger--semantic-fail 'lifecycle-target-mismatch))
  (unless (equal (epi-record--raw-turn record) (plist-get call :turn))
    (epi-ledger--semantic-fail 'lifecycle-turn-mismatch))
  (unless (equal (epi-record--raw-operation record)
                 (plist-get call :operation))
    (epi-ledger--semantic-fail 'lifecycle-operation-mismatch))
  (unless (equal (epi-ledger--payload-value record "call_id")
                 (plist-get call :call-id))
    (epi-ledger--semantic-fail 'lifecycle-call-mismatch)))

(defun epi-ledger--latch-tool-terminal-cause (state call cause)
  "Latch CALL's provider-terminal CAUSE on its turn and in STATE."
  (when cause
    (let ((turn
           (gethash (plist-get call :turn)
                    (epi-ledger--validation-state-turns state))))
      (setf (plist-get turn :tool-terminal-cause) cause
            (epi-ledger--validation-state-terminalization-required state)
            (list :turn (plist-get call :turn) :cause cause)))))

(defun epi-ledger--validate-tool-lifecycle (state record)
  "Advance one tool lifecycle RECORD in STATE."
  (let* ((type (epi-record--raw-type record))
         (call (epi-ledger--call-for-lifecycle state record)))
    (epi-ledger--validate-lifecycle-identity record call)
    (let ((call-state (plist-get call :state)))
      (pcase type
        ('tool-approved
         (unless (eq call-state 'planned)
           (epi-ledger--semantic-fail 'invalid-tool-pairing))
         (setf (plist-get call :state) 'approved))
        ('tool-started
         (unless (eq call-state 'approved)
           (epi-ledger--semantic-fail 'invalid-tool-pairing))
         (setf (plist-get call :state) 'started))
        ('tool-finished
         (when (memq call-state '(finished denied))
           (epi-ledger--semantic-fail
            (if (eq call-state 'finished)
                'duplicate-call-terminal
              'opposite-call-terminal)))
         (unless (eq call-state 'started)
           (epi-ledger--semantic-fail 'finished-without-start))
         (let ((status (epi-ledger--payload-value record "status")))
           (setf (plist-get call :state) 'finished
                 (plist-get call :terminal) record
                 (plist-get call :status) status)
           (if (equal status "uncertain")
               (let* ((turn
                       (gethash (plist-get call :turn)
                                (epi-ledger--validation-state-turns state)))
                      (operation
                       (gethash
                        (plist-get call :operation)
                        (epi-ledger--validation-state-operations state))))
                 (setf (plist-get turn :uncertain) t
                       (plist-get operation :uncertain) t
                       (epi-ledger--validation-state-uncertain state) t
                       (epi-ledger--validation-state-uncertainty-phase state)
                       'turn-terminal
                       (epi-ledger--validation-state-uncertainty-turn state)
                       (plist-get call :turn)
                       (epi-ledger--validation-state-uncertainty-operation
                        state)
                       (plist-get call :operation)
                       (epi-ledger--validation-state-active-call state) nil))
             (progn
               (let* ((details
                       (epi-ledger--payload-value record "details"))
                      (detail-code
                       (and (listp details)
                            (epi-ledger--object-value details "code")))
                      (cause
                       (cond ((equal status "cancelled") 'cancelled)
                             ((and (equal status "error")
                                   (equal detail-code "interrupted"))
                              'interrupted))))
                 (epi-ledger--latch-tool-terminal-cause state call cause))
               (setf (epi-ledger--validation-state-pending-result state)
                     call)))))
        ('tool-denied
         (when (memq call-state '(finished denied))
           (epi-ledger--semantic-fail
            (if (eq call-state 'denied)
                'duplicate-call-terminal
              'opposite-call-terminal)))
         (let ((reason (epi-ledger--payload-value record "reason")))
           (unless (or (eq call-state 'planned)
                       (and (eq call-state 'approved)
                            (member reason
                                    '("interrupted"
                                      "operation-cancelled"
                                      "operation-failed"))))
             (epi-ledger--semantic-fail 'invalid-tool-pairing))
           (let ((cause
                  (cond ((equal reason "interrupted") 'interrupted)
                        ((equal reason "operation-cancelled")
                         'cancelled)
                        ((equal reason "operation-failed") 'failed))))
             (epi-ledger--latch-tool-terminal-cause state call cause))
           (setf (plist-get call :state) 'denied
                 (plist-get call :terminal) record
                 (plist-get call :status) "denied"
                 (epi-ledger--validation-state-pending-result state) call)))))))

(defun epi-ledger--validate-tool-result (state record)
  "Validate tool-result RECORD against STATE's pending call."
  (let ((call (epi-ledger--validation-state-pending-result state)))
    (unless call
      (let ((prior
             (gethash (epi-record--raw-parent record)
                      (epi-ledger--validation-state-calls-by-target state))))
        (if (and prior (equal (plist-get prior :status) "uncertain"))
            (epi-ledger--semantic-fail 'result-after-uncertain)
          (epi-ledger--semantic-fail 'orphan-tool-result))))
    (unless (equal (epi-record--raw-parent record) (plist-get call :target))
      (epi-ledger--semantic-fail 'result-parent-mismatch))
    (unless (equal (epi-record--raw-turn record) (plist-get call :turn))
      (let ((result-operation
             (epi-ledger--state-turn-operation
              state (epi-record--raw-turn record))))
        (if (and result-operation
                 (not (equal result-operation (plist-get call :operation))))
            (epi-ledger--semantic-fail 'result-different-operation)
          (epi-ledger--semantic-fail 'result-turn-mismatch))))
    (let ((item (epi-ledger--message-item record)))
      (unless (equal (epi-ledger--object-value item "call_id")
                     (plist-get call :call-id))
        (epi-ledger--semantic-fail 'result-call-mismatch))
      (unless (equal (epi-ledger--object-value item "name")
                     (plist-get call :name))
        (epi-ledger--semantic-fail 'result-name-mismatch))
      (unless (equal (epi-ledger--object-value item "result")
                     (epi-ledger--payload-value
                      (plist-get call :terminal) "model_result"))
        (epi-ledger--semantic-fail 'result-model-result-mismatch))
      (let* ((terminal-status (plist-get call :status))
             (actual (epi-ledger--object-value item "status"))
             (expected
              (cond ((equal terminal-status "success") "success")
                    ((equal terminal-status "denied") "denied")
                    (t "error"))))
        (unless (equal actual expected)
          (epi-ledger--semantic-fail
           (pcase terminal-status
             ("denied" 'denied-result-mapping)
             ("error" 'error-result-mapping)
             ("timeout" 'timeout-result-mapping)
             ("cancelled" 'cancelled-result-mapping)
             (_ 'result-status-mismatch))))))
    (setf (plist-get call :result) record
          (epi-ledger--validation-state-pending-result state) nil
          (epi-ledger--validation-state-active-call state) nil)))

(defun epi-ledger--validate-turn-terminal (state record)
  "Consume turn terminal RECORD into STATE."
  (let* ((turn-id (epi-record--raw-turn record))
         (turn (gethash turn-id
                        (epi-ledger--validation-state-turns state)))
         (terminalization
          (epi-ledger--validation-state-terminalization-required state))
         (class (epi-ledger--terminal-class (epi-record--raw-type record))))
    (unless turn
      (epi-ledger--semantic-fail 'turn-without-operation))
    (when (eq (plist-get turn :state) 'terminal)
      (epi-ledger--semantic-fail 'duplicate-terminal))
    (unless (equal (epi-record--raw-operation record)
                   (plist-get turn :operation))
      (epi-ledger--semantic-fail 'contradictory-terminal))
    (when (and terminalization
               (not (equal turn-id (plist-get terminalization :turn))))
      (epi-ledger--semantic-fail 'tool-cause-terminal-mismatch))
    (epi-ledger--require-ordinary-interruption-reason
     record (plist-get turn :uncertain))
    (pcase (plist-get turn :tool-terminal-cause)
      ('interrupted
       (unless (eq class 'interrupted)
         (epi-ledger--semantic-fail 'tool-cause-terminal-mismatch)))
      ('cancelled
       (unless (memq class '(cancelled interrupted))
         (epi-ledger--semantic-fail 'tool-cause-terminal-mismatch)))
      ('failed
       (unless (memq class '(failed interrupted))
         (epi-ledger--semantic-fail 'tool-cause-terminal-mismatch))))
    (when (plist-get turn :uncertain)
      (unless (or (eq class 'interrupted)
                  (and (eq class 'failed)
                       (equal (epi-ledger--payload-value record "code")
                              "tool-uncertain")))
        (epi-ledger--semantic-fail 'uncertain-success-terminal)))
    (setf (plist-get turn :state) 'terminal
          (plist-get turn :terminal-class) class
          (epi-ledger--validation-state-terminalization-required state) nil)
    (let ((operation
           (gethash (plist-get turn :operation)
                    (epi-ledger--validation-state-operations state))))
      (setf (plist-get operation :active-turn) nil
            (plist-get operation :last-turn-class) class))
    (when (eq (epi-ledger--validation-state-uncertainty-phase state)
              'turn-terminal)
      (setf (epi-ledger--validation-state-uncertainty-class state) class
            (epi-ledger--validation-state-uncertainty-phase state)
            'operation-terminal))))

(defun epi-ledger--validate-operation-terminal (state record)
  "Consume operation terminal RECORD into STATE."
  (let* ((operation-id (epi-record--raw-operation record))
         (operation
          (gethash operation-id
                   (epi-ledger--validation-state-operations state)))
         (class (epi-ledger--terminal-class (epi-record--raw-type record))))
    (unless operation
      (epi-ledger--semantic-fail 'operation-terminal-before-turn))
    (when (eq (plist-get operation :state) 'terminal)
      (epi-ledger--semantic-fail
       (if (eq class (plist-get operation :terminal-class))
           'duplicate-operation-terminal
         'opposite-operation-terminal)))
    (when (and (plist-get operation :active-turn)
               (eq (plist-get (plist-get operation :active-turn) :state)
                   'open))
      (epi-ledger--semantic-fail 'operation-terminal-before-turn))
    (epi-ledger--require-ordinary-interruption-reason
     record (plist-get operation :uncertain))
    (if (equal (plist-get operation :kind) "select-leaf")
        (progn
          (unless (memq class '(success failed interrupted))
            (epi-ledger--semantic-fail 'select-leaf-terminal))
          (when (and (eq class 'success)
                     (/= (plist-get operation :leaf-count) 1))
            (epi-ledger--semantic-fail 'select-leaf-count)))
      (unless (or
               (and (eq class 'interrupted)
                    (or (= (plist-get operation :turn-count) 0)
                        (and (= (plist-get operation :turn-count) 1)
                             (plist-get operation :last-turn-class))))
               (and (= (plist-get operation :turn-count) 1)
                    (eq class (plist-get operation :last-turn-class))))
        (epi-ledger--semantic-fail 'contradictory-terminal)))
    (when (plist-get operation :uncertain)
      (unless (or (eq class 'interrupted)
                  (and (eq class 'failed)
                       (equal (epi-ledger--payload-value record "code")
                              "tool-uncertain")))
        (epi-ledger--semantic-fail 'uncertain-success-terminal)))
    (setf (plist-get operation :state) 'terminal
          (plist-get operation :terminal-class) class
          (epi-ledger--validation-state-active-operation state) nil)
    (when (eq (epi-ledger--validation-state-uncertainty-phase state)
              'operation-terminal)
      (setf (epi-ledger--validation-state-uncertainty-phase state)
            'blocked))))

(defun epi-ledger--recovery-evidence-v1 (payload)
  "Return PAYLOAD's closed version-one recovery evidence object."
  (append
   '(("kind" . "epi-recovery-source-evidence") ("version" . 1))
   (mapcar
    (lambda (field)
      (cons field (epi-ledger--object-value payload field)))
    epi-ledger--recovery-evidence-v1-fields)))

(defun epi-ledger--recovery-evidence-v1-sha256 (payload)
  "Return the version-one source-evidence digest for recovery PAYLOAD."
  (epi-ledger--hash
   (epi-ledger--jcs-encode
    (epi-ledger--recovery-evidence-v1 payload))
   'recovery-source-evidence))

(defun epi-ledger--require-recovery-origin-admissible
    (record by-id evidence terminalization-required)
  "Require RECORD to be a fresh origin after the supplied semantic facts.
BY-ID and EVIDENCE are the existing identifier and evidence tables.
TERMINALIZATION-REQUIRED is non-nil when an earlier recovery barrier remains
unreconciled.  Return RECORD's verified evidence digest without mutation."
  (when (gethash (epi-record--raw-id record) by-id)
    (epi-ledger--semantic-fail 'duplicate-id))
  (let* ((payload (epi-record--raw-payload record))
         (expected
          (epi-ledger--object-value payload "source_evidence_sha256"))
         (actual (epi-ledger--recovery-evidence-v1-sha256 payload)))
    (unless (equal expected actual)
      (epi-ledger--semantic-fail 'source-evidence-mismatch))
    (when (gethash expected evidence)
      (epi-ledger--semantic-fail 'duplicate-recovery-evidence))
    (when terminalization-required
      (epi-ledger--semantic-fail 'recovery-terminalization-required))
    expected))

(defun epi-ledger--validate-recovery-origin (state record)
  "Validate recovery-origin RECORD and retain its provenance in STATE."
  (let* ((evidence
          (epi-ledger--validation-state-recovery-evidence state))
         (expected
          (epi-ledger--require-recovery-origin-admissible
           record (epi-ledger--validation-state-by-id state) evidence
           (epi-ledger--validation-state-recovery-terminalization-required
            state))))
    (puthash expected t evidence)
    (setf (epi-ledger--validation-state-latest-recovery-origin state) record
          (epi-ledger--validation-state-recovery-terminalization-required
           state)
          (and (epi-ledger--validation-state-active-operation state) t))))

(defun epi-ledger--recovery-terminalization-record-p (state record kind)
  "Return non-nil when RECORD passes STATE's recovery terminalization gate.
KIND is RECORD's message content type, when it is a message.  This gate checks
recovery-specific type and tool payload constraints.  Ordinary semantic
validation proves interruption literals, lifecycle identities, and adjacency."
  (let* ((type (epi-record--raw-type record))
         (payload (epi-record--raw-payload record))
         (call (epi-ledger--validation-state-active-call state))
         (call-state (and call (plist-get call :state)))
         (phase (epi-ledger--validation-state-uncertainty-phase state))
         (operation (epi-ledger--validation-state-active-operation state))
         (turn (and operation (plist-get operation :active-turn))))
    (cond
     ((epi-ledger--validation-state-pending-result state)
      (and (eq type 'message) (equal kind "tool-result")))
     ((eq phase 'turn-terminal)
      (eq type 'turn-interrupted))
     ((eq phase 'operation-terminal)
      (eq type 'operation-interrupted))
     ((memq call-state '(planned approved))
      (and (eq type 'tool-denied)
           (equal (epi-ledger--payload-value record "reason") "interrupted")
           (equal (epi-ledger--payload-value record "model_result")
                  "Denied")))
     ((eq call-state 'started)
      (and
       (eq type 'tool-finished)
       (let ((status (epi-ledger--payload-value record "status"))
             (details (epi-ledger--payload-value record "details")))
         (or
          (and (equal status "error")
               (equal details '(("code" . "interrupted")))
               (equal (epi-ledger--payload-value record "model_result")
                      "Interrupted"))
          (and (equal status "uncertain")
               (null details)
               (not (epi-ledger--object-has-key-p
                     payload "model_result")))))))
     (turn
      (eq type 'turn-interrupted))
     (operation
      (eq type 'operation-interrupted)))))

(defun epi-ledger--validate-record-semantic (state header record)
  "Validate RECORD against HEADER and retain it after STATE's prefix."
  (let* ((type (epi-record--raw-type record))
         (sequence (epi-record--raw-sequence record))
         (by-id (epi-ledger--validation-state-by-id state))
         (kind (epi-ledger--message-kind record))
         (reference-required
          (not (or (eq type 'session-info)
                   (eq type 'operation-started)
                   (epi-ledger--operation-terminal-p type)
                   (epi-ledger--turn-terminal-p type)
                   (eq type 'turn-started)
                   (memq type '(tool-planned tool-approved tool-started
                                tool-finished tool-denied))
                   (and (eq type 'message) (equal kind "tool-result"))))))
    (when (and (= sequence 1) (not (eq type 'session-info)))
      (epi-ledger--semantic-fail 'missing-session-info))
    (if (eq type 'recovery-origin)
        (progn
          (when (gethash (epi-record--raw-id record) by-id)
            (epi-ledger--semantic-fail 'duplicate-id))
          (epi-ledger--validate-recovery-origin state record))
      (when
          (and
           (epi-ledger--validation-state-recovery-terminalization-required
            state)
           (not
            (epi-ledger--recovery-terminalization-record-p
             state record kind)))
        (epi-ledger--semantic-fail 'recovery-terminalization-required))
      (epi-ledger--validate-uncertainty-admission state record kind)
      (epi-ledger--validate-select-leaf-admission state record)
      (epi-ledger--validate-turn-admission state record)
      (epi-ledger--validate-intent-admission state record)
      (when (gethash (epi-record--raw-id record) by-id)
        (epi-ledger--semantic-fail 'duplicate-id))
      (cond
       ((eq type 'session-info)
        (cond
         ((epi-ledger--validation-state-session-seen state)
          (epi-ledger--semantic-fail 'duplicate-session-info))
         ((/= sequence 1)
          (epi-ledger--semantic-fail 'nonfirst-session-info)))
        (unless (equal (epi-ledger--payload-value record "session_id")
                       (epi-header--raw-session-id header))
          (epi-ledger--semantic-fail 'session-id-mismatch))
        (setf (epi-ledger--validation-state-session-seen state) t))
       ((= sequence 1)
        (setf (epi-ledger--validation-state-first-nonsession state) record)))
      ;; These adjacency checks deliberately precede unrelated semantics.
      (when (epi-ledger--proposal-interruption-p state record)
        (setf (epi-ledger--validation-state-pending-proposal state) nil))
      (when (and (epi-ledger--validation-state-pending-proposal state)
                 (not (eq type 'tool-planned)))
        (epi-ledger--semantic-fail 'delayed-tool-plan))
      (when (and (epi-ledger--validation-state-pending-result state)
                 (not (equal kind "tool-result")))
        (epi-ledger--semantic-fail 'delayed-required-result))
      (when (and
             (epi-ledger--validation-state-terminalization-required state)
             (not (or (epi-ledger--turn-terminal-p type)
                      (and
                       (epi-ledger--validation-state-pending-result state)
                       (equal kind "tool-result")))))
        (epi-ledger--semantic-fail 'tool-cause-terminal-mismatch))
      (epi-ledger--validate-active-call-continuation state type)
      (when reference-required
        (epi-ledger--validate-operation-reference
         state record (eq type 'message)))
      (epi-ledger--validate-intended-message state record)
      (when (and reference-required (eq type 'message))
        (epi-ledger--validate-operation-reference state record))
      (pcase type
        ('operation-started
         (epi-ledger--validate-operation-start state record))
        ('turn-started
         (epi-ledger--validate-turn-start state record))
        ('leaf
         (epi-ledger--validate-leaf state record))
        ('tool-planned
         (epi-ledger--validate-tool-plan state record))
        ((or 'tool-approved 'tool-started 'tool-finished 'tool-denied)
         (epi-ledger--validate-tool-lifecycle state record))
        ((pred epi-ledger--turn-terminal-p)
         (epi-ledger--validate-turn-terminal state record))
        ((pred epi-ledger--operation-terminal-p)
         (epi-ledger--validate-operation-terminal state record))
        ('message
         (cond
          ((equal kind "tool-result")
           (epi-ledger--validate-tool-result state record))
          (t
           (let ((parent-valid
                  (epi-ledger--validate-message-parent state record)))
             (when parent-valid
               (epi-ledger--commit-intended-message state record)
               (when (equal kind "tool-call")
                 (epi-ledger--validate-proposal state record))))))))
      (when
          (and
           (epi-ledger--validation-state-recovery-terminalization-required
            state)
           (not (epi-ledger--validation-state-active-operation state)))
        (setf
         (epi-ledger--validation-state-recovery-terminalization-required
          state)
         nil)))
    (puthash (epi-record--raw-id record) record by-id)
    (push record (epi-ledger--validation-state-records-reverse state))))

(defun epi-ledger--validation-final-error (state)
  "Return (CODE RECORD) for STATE's first EOF semantic error, or nil."
  (cond
   ((not (epi-ledger--validation-state-session-seen state))
    (list 'missing-session-info
          (epi-ledger--validation-state-first-nonsession state)))
   ((epi-ledger--validation-state-deferred-references state)
    (let* ((reference (epi-ledger--earliest-deferred-reference state))
           (record (plist-get reference :record)))
      (list (epi-ledger--deferred-reference-code reference nil) record)))
   ((let ((origin
           (epi-ledger--validation-state-latest-recovery-origin state)))
      (and
       origin
       (not
        (equal
         (epi-ledger--payload-value
          origin "destination_valid_prefix_head_sha256")
         (epi-record--raw-previous-hash origin)))))
    (list
     'recovery-prefix-head-mismatch
     (epi-ledger--validation-state-latest-recovery-origin state)))
   ;; Proposal/plan and terminal/result pairs are written in one crash barrier,
   ;; but complete first frames remain truthful typed EOF prefixes when a
   ;; regular-file write stops at that boundary.  Interior violations are
   ;; rejected by the adjacency checks above rather than by EOF finalization.
   ))

(defun epi-ledger--make-empty-validation-state ()
  "Return an empty mutable validation accumulator."
  (epi-ledger--make-validation-state
   :records-reverse nil
   :by-id (make-hash-table :test #'equal)
   :operations (make-hash-table :test #'equal)
   :turns (make-hash-table :test #'equal)
   :turn-operation-index (make-hash-table :test #'equal)
   :calls (make-hash-table :test #'equal)
   :calls-by-target (make-hash-table :test #'equal)
   :reserved-call-ids (make-hash-table :test #'equal)
   :intents (make-hash-table :test #'equal)
   :session-seen nil :first-nonsession nil
   :pending-proposal nil :pending-result nil
   :terminalization-required nil
   :recovery-evidence (make-hash-table :test #'equal)
   :latest-recovery-origin nil
   :recovery-terminalization-required nil
   :deferred-references nil :uncertain nil
   :uncertainty-phase nil :uncertainty-class nil
   :uncertainty-turn nil :uncertainty-operation nil))

(defun epi-ledger--open-header (bytes path)
  "Parse header BYTES from PATH and map codec failures to loader conditions."
  (condition-case condition
      (epi-ledger--parse-header-owned bytes 0)
    ((epi-ledger-error epi-limit-exceeded)
     (let ((code (epi-ledger--open-condition-code condition 'invalid-header))
           (offset (epi-ledger--open-condition-offset condition 0)))
       (epi-ledger--open-signal
        'epi-ledger-corrupt code path 0 nil offset code)))))

(defun epi-ledger--open-signal-deferred-reference (state path present)
  "Signal STATE's leading reference defect for PATH.
PRESENT says that a later fully valid record supplied the referenced ID."
  (let ((reference (epi-ledger--earliest-deferred-reference state)))
    (when reference
      (let* ((record (plist-get reference :record))
             (code (epi-ledger--deferred-reference-code reference present)))
        (epi-ledger--open-signal
         'epi-ledger-corrupt code path
         (epi-record--raw-sequence record)
         (epi-record--raw-id record)
         (epi-record--raw-start-offset record) code)))))

(defun epi-ledger--open-frame (frame origin sequence tail path header state)
  "Validate FRAME at ORIGIN and SEQUENCE after TAIL for PATH.
Advance HEADER's validation STATE and return the frame's record hash."
  (let* ((headline (epi-ledger--frame-headline-fields frame))
         (record-id (cadr headline))
         (scan (epi-ledger--scan-frame-owned frame 0 sequence origin))
         (scan-state (plist-get scan :state)))
    (unless (eq scan-state 'complete)
      (epi-ledger--open-signal-deferred-reference state path nil)
      (let* ((cause-code (plist-get scan :code))
             (code (epi-ledger--loader-frame-code cause-code)))
        (epi-ledger--open-signal
         (if (eq scan-state 'incomplete)
             'epi-ledger-truncated-tail
           'epi-ledger-corrupt)
         code path sequence record-id (plist-get scan :offset)
         cause-code)))
    (let ((record (plist-get scan :record)))
      (unless (equal (epi-record--raw-previous-hash record) tail)
        (epi-ledger--open-signal-deferred-reference state path nil)
        (epi-ledger--open-signal
         'epi-ledger-corrupt 'previous-hash-mismatch path sequence
         (epi-record--raw-id record) (epi-record--raw-start-offset record)
         'previous-hash-mismatch))
      ;; A missing backward-only edge is already the leading semantic defect.
      ;; Later frames are decoded only to refine it as forward versus absent.
      (let ((reference (epi-ledger--earliest-deferred-reference state)))
        (when (and reference
                   (equal (epi-record--raw-id record)
                          (plist-get reference :id)))
          (epi-ledger--open-signal-deferred-reference state path t)))
      (unless (epi-ledger--validation-state-deferred-references state)
        (condition-case condition
            (epi-ledger--validate-record-semantic state header record)
          (epi-ledger-format-error
           (let ((code
                  (epi-ledger--open-condition-code
                   condition 'invalid-record-semantics)))
             (epi-ledger--open-signal
              'epi-ledger-corrupt code path sequence
              (epi-record--raw-id record)
              (epi-record--raw-start-offset record) code)))))
      (epi-record--raw-hash record))))

(defun epi-ledger--open-finalize-state (state path sequence offset)
  "Signal STATE's EOF error for PATH at next SEQUENCE and OFFSET, if any."
  (let ((error (epi-ledger--validation-final-error state)))
    (when error
      (let* ((code (car error))
             (record (cadr error)))
        (epi-ledger--open-signal
         'epi-ledger-corrupt code path
         (if record (epi-record--raw-sequence record) sequence)
         (and record (epi-record--raw-id record))
         (if record (epi-record--raw-start-offset record) offset)
         code)))))

(defun epi-ledger--open-buffer-source (start end)
  "Return an immutable source view over current buffer START..END."
  (epi-ledger--make-source-region
   :buffer (current-buffer) :start start :end end
   :tick (buffer-modified-tick)))

(defun epi-ledger--copy-recovery-fragment (source work)
  "Return an owned unibyte copy of bounded recovery fragment SOURCE.
Copy and store each slice through WORK; the later digest remains one measured
nonpreemptible unit."
  (let* ((size (epi-ledger--source-length source))
         (result
          (epi-ledger--run-bounded-unit
           'allocate 'recovery-fragment size work
           (lambda () (make-string size 0))))
         (chunk-size (max 1 (min 1048576 epi-ledger-work-byte-limit)))
         (offset 0))
    (while (< offset size)
      (let* ((end (min size (+ offset chunk-size)))
             (chunk
              (epi-ledger--source-copy-range
               source offset end 'recovery-fragment-read work)))
        (epi-ledger--work-charge work (- end offset))
        (store-substring result offset chunk)
        (setq offset end)))
    result))

(defun epi-ledger--open-reread-recovery-fragment
    (path begin end expected identity work sequence record-id)
  "Reread PATH's recovery fragment BEGIN..END and return its digest.
EXPECTED contains the independently captured inspection bytes.  Require the
current PATH under IDENTITY to contain exactly those bytes, using WORK and
RECORD-ID for bounded reads and stable diagnostics at SEQUENCE."
  (let ((chunk-size (max 1 (min 1048576 epi-ledger-work-byte-limit))))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (let ((offset begin)
            (epi-ledger--work-protected-buffer (current-buffer))
            (epi-ledger--work-protected-change-handler
             (lambda ()
               (epi-ledger--open-signal
                'epi-ledger-conflict 'loader-buffer-modified path sequence
                record-id begin 'loader-buffer-modified))))
        (while (< offset end)
          (let ((next (min end (+ offset chunk-size))))
            (goto-char (point-max))
            (condition-case condition
                (epi-ledger--open-insert-source-range
                 path offset next work identity sequence
                 epi-ledger--open-head-inserter
                 'recovery-fragment-source-read)
              (epi-ledger-conflict
               (signal (car condition) (cdr condition)))
              ((epi-ledger-format-error file-error)
               (epi-ledger--open-signal
                'epi-ledger-conflict 'file-fragment-changed path sequence
                record-id offset 'file-fragment-changed)))
            (setq offset next)))
        (setq buffer-read-only t)
        (let ((source
               (epi-ledger--open-buffer-source
                (point-min) (point-max))))
          (unless
              (epi-ledger--source-range-equal-string-p
               source 0 (- end begin) expected work)
            (epi-ledger--open-signal
             'epi-ledger-conflict 'file-fragment-changed path sequence
             record-id begin 'file-fragment-changed))
          (epi-ledger--source-hash source 'recovery-fragment))))))

(defun epi-ledger--open-verify-current-head
    (path record identity work sequence)
  "Require PATH's chain head to equal RECORD's hash under IDENTITY.
Use WORK for bounded rereads and report failures at SEQUENCE."
  (let ((begin (epi-record--raw-start-offset record))
        (end (epi-record--raw-json-start-offset record))
        (chunk-size (max 1 (min 1048576 epi-ledger-work-byte-limit))))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (let ((offset begin))
        (while (< offset end)
          (let ((next (min end (+ offset chunk-size))))
            (goto-char (point-max))
            (condition-case condition
                (epi-ledger--open-insert-source-range
                 path offset next work identity sequence
                 epi-ledger--open-head-inserter 'source-head-read)
              ((epi-ledger-format-error epi-limit-exceeded file-error)
               (let ((code
                      (epi-ledger--open-condition-code
                       condition 'ledger-read-failed))
                     (failure-offset
                      (epi-ledger--open-condition-offset condition offset)))
                 (epi-ledger--open-signal
                  'epi-ledger-corrupt code path sequence
                  (epi-record--raw-id record) failure-offset code))))
            (setq offset next))))
      (let* ((marker ":EPI_RECORD_SHA256: ")
             (marker-length (length marker))
             (cursor (point-min))
             (matched 0)
             hash-start)
        (while (and (not hash-start) (< cursor (point-max)))
          (epi-ledger--open-charge-scan work 'source-head-scan 1)
          (let ((byte (char-after cursor)))
            (if (= byte (aref marker matched))
                (setq matched (1+ matched))
              (setq matched (if (= byte (aref marker 0)) 1 0)))
            (setq cursor (1+ cursor))
            (when (= matched marker-length)
              (setq hash-start cursor))))
        (let* ((expected (epi-record--raw-hash record))
               (available
                (and hash-start (<= (+ hash-start 64) (point-max))))
               (matches available)
               (index 0))
          (while (and matches (< index 64))
            (let* ((amount
                    (min (- 64 index)
                         (max 1 epi-ledger-work-byte-limit)))
                   (limit (+ index amount)))
              (epi-ledger--work-charge work amount)
              (while (and matches (< index limit))
                (setq matches
                      (= (char-after (+ hash-start index))
                         (aref expected index))
                      index (1+ index)))))
          (unless matches
            (epi-ledger--open-signal
             'epi-ledger-conflict 'file-chain-head-changed path sequence
             (epi-record--raw-id record) begin
             'file-chain-head-changed)))))))

(defun epi-ledger--inspect-path-core (path policy)
  "Inspect PATH once under closed tail POLICY.
POLICY is `complete' or `allow-one-incomplete-final-frame'.  The latter
returns the same identity-bound complete-prefix state plus exact owned bytes
for one structurally completable final frame.  No write or recovery occurs."
  (unless (memq policy '(complete allow-one-incomplete-final-frame))
    (epi-ledger--format-fail 'invalid-inspection-policy))
  (epi-ledger--with-operation-work-state
   (let* ((epi-ledger--cold-open-validation t)
          (canonical-path
           (condition-case nil
               (file-truename (expand-file-name path))
             (error (expand-file-name path))))
          (initial-identity
           (condition-case condition
               (funcall epi-ledger--open-identity-reader canonical-path)
             ((epi-ledger-error epi-limit-exceeded file-error)
              (let ((code
                     (epi-ledger--open-condition-code
                      condition 'ledger-file-unreadable)))
                (epi-ledger--open-signal
                 'epi-ledger-corrupt code canonical-path 0 nil 0 code)))))
          (size (plist-get initial-identity :size))
          (work (epi-ledger--make-work-state))
          (chunk-size (max 1 (min 1048576 epi-ledger-work-byte-limit)))
          (source-offset 0)
          (buffer-origin 0)
          (header nil)
          (header-newlines 0)
          (header-search 1)
          (frame-search 1)
          (sequence 1)
          (tail nil)
          (validated-end 0)
          (inspection-state 'complete)
          fragment-offset
          fragment-size
          fragment-hash
          fragment-bytes
          fragment-record-id
          prefix-finalized
          (records-since-yield 0)
          (state (epi-ledger--make-empty-validation-state)))
     (with-temp-buffer
       (set-buffer-multibyte nil)
       (let ((epi-ledger--work-protected-buffer (current-buffer))
             (epi-ledger--work-protected-change-handler
              (lambda ()
                (let ((record
                       (car
                        (epi-ledger--validation-state-records-reverse
                         state))))
                  (epi-ledger--open-signal
                   'epi-ledger-conflict 'loader-buffer-modified
                   canonical-path sequence
                   (and record (epi-record--raw-id record))
                   validated-end 'loader-buffer-modified)))))
         (while (< source-offset size)
           (let* ((available
                   (- epi-record-frame-byte-limit (buffer-size)))
                  (end
                   (min size (+ source-offset chunk-size)
			(+ source-offset (max 0 available)))))
             (when (<= available 0)
               (if (not header)
                   (epi-ledger--open-signal
                    'epi-ledger-corrupt 'header-byte-limit canonical-path
                    0 nil buffer-origin 'header-byte-limit)
                 (let* ((source
                         (epi-ledger--open-buffer-source
                          (point-min) (point-max)))
			(headline (epi-ledger--frame-headline-fields source)))
                   (epi-ledger--open-signal
                    'epi-ledger-corrupt 'record-frame-byte-limit
                    canonical-path sequence (cadr headline)
                    (+ buffer-origin epi-record-frame-byte-limit)
                    'record-frame-byte-limit))))
             (condition-case condition
                 (progn
                   (goto-char (point-max))
                   (epi-ledger--open-insert-source-range
                    canonical-path source-offset end work initial-identity
                    sequence))
               (epi-ledger-conflict
		(signal (car condition) (cdr condition)))
               ((epi-ledger-error epi-limit-exceeded file-error)
		(let ((code
                       (epi-ledger--open-condition-code
			condition 'ledger-read-failed)))
                  (epi-ledger--open-signal
                   'epi-ledger-corrupt code canonical-path sequence nil
                   source-offset code))))
             (setq source-offset end))
           (unless header
             (let (newline-result newline)
               (while (and (< header-newlines 7)
                           (progn
                             (setq newline-result
                                   (epi-ledger--open-search-newline
                                    header-search (point-max)
                                    'header-scan work)
                                   newline (car newline-result)
                                   header-search (cdr newline-result))
                             newline))
                 (setq header-newlines (1+ header-newlines)))
               (when (= header-newlines 7)
                 (let* ((header-end header-search)
			(header-size (- header-end (point-min)))
			(header-source
                         (epi-ledger--open-buffer-source
                          (point-min) header-end)))
                   (setq header
                         (epi-ledger--open-header
                          header-source canonical-path)
                         tail (epi-header--raw-hash header)
                         validated-end (+ buffer-origin header-size))
                   (epi-ledger--open-discard-prefix header-end work)
                   (setq buffer-origin (+ buffer-origin header-size)
                         frame-search (point-min)))))
             (when (and (not header)
			(>= (buffer-size) epi-record-frame-byte-limit))
               (epi-ledger--open-signal
		'epi-ledger-corrupt 'header-byte-limit canonical-path
		0 nil buffer-origin 'header-byte-limit)))
           (when header
             (let ((frame-start (point-min))
                   search-result frame-end)
               (while (progn
			(setq search-result
                              (epi-ledger--open-find-frame-end
                               frame-search (point-max) work)
                              frame-end (plist-get search-result :end)
                              frame-search
                              (plist-get search-result :search))
			frame-end)
                 (let* ((frame-size (- frame-end frame-start))
			(frame-origin
                         (+ buffer-origin (- frame-start (point-min))))
			(frame
                         (epi-ledger--open-buffer-source
                          frame-start frame-end)))
                   (setq tail
                         (epi-ledger--open-frame
                          frame frame-origin sequence tail canonical-path
                          header state)
                         validated-end (+ frame-origin frame-size)
                         frame-start frame-end
                         frame-search frame-end
                         sequence (1+ sequence)
                         records-since-yield (1+ records-since-yield))
                   (when (>= records-since-yield
                             epi-ledger-work-record-limit)
                     (epi-ledger--work-yield work)
                     (setq records-since-yield 0))))
               (when (> frame-start (point-min))
                 (let ((consumed (- frame-start (point-min)))
                       (search-offset (- frame-search frame-start)))
                   (epi-ledger--open-discard-prefix frame-start work)
                   (setq buffer-origin (+ buffer-origin consumed)
                         frame-search (+ (point-min) search-offset))))
               (when (and (< source-offset size)
                          (>= (buffer-size) epi-record-frame-byte-limit))
                 (epi-ledger--open-signal-deferred-reference
                  state canonical-path nil)
                 (let* ((frame
                         (epi-ledger--open-buffer-source
                          (point-min) (point-max)))
			(headline (epi-ledger--frame-headline-fields frame))
			(record-id (cadr headline)))
                   (epi-ledger--open-signal
                    'epi-ledger-corrupt 'record-frame-byte-limit
                    canonical-path sequence record-id
                    (+ buffer-origin epi-record-frame-byte-limit)
                    'record-frame-byte-limit))))))
         (unless header
           (if (>= (buffer-size) epi-record-frame-byte-limit)
               (epi-ledger--open-signal
		'epi-ledger-corrupt 'header-byte-limit canonical-path
		0 nil buffer-origin 'header-byte-limit)
             (epi-ledger--open-signal
              'epi-ledger-corrupt 'truncated-header canonical-path
              0 nil (+ buffer-origin (buffer-size)) 'truncated-header)))
         (when (> (buffer-size) 0)
           (epi-ledger--open-signal-deferred-reference
            state canonical-path nil)
           (let* ((frame
                   (epi-ledger--open-buffer-source
                    (point-min) (point-max)))
                  (headline (epi-ledger--frame-headline-fields frame))
                  (record-id (cadr headline))
                  (scan
                   (epi-ledger--scan-frame-owned
                    frame 0 sequence buffer-origin))
                  (scan-state (plist-get scan :state))
                  (cause-code (plist-get scan :code)))
             (pcase scan-state
               ('invalid
                (let ((code (epi-ledger--loader-frame-code cause-code)))
                  (epi-ledger--open-signal
                   'epi-ledger-corrupt code canonical-path sequence record-id
                   (plist-get scan :offset) cause-code)))
               ('incomplete
                (if (eq policy 'complete)
                    (epi-ledger--open-signal
                     'epi-ledger-truncated-tail 'truncated-frame
                     canonical-path sequence record-id
                     (+ buffer-origin (buffer-size))
                     (or cause-code 'truncated-frame))
                  (let ((scan-offset
                         (plist-get scan :fragment-start-offset))
                        (scan-size
                         (plist-get scan :fragment-byte-size)))
                    (unless (and (= buffer-origin validated-end)
                                 (= scan-offset buffer-origin)
                                 (= scan-size (buffer-size))
                                 (> scan-size 0))
                      (epi-ledger--open-signal
                       'epi-ledger-conflict 'incomplete-ledger-scan
                       canonical-path sequence record-id validated-end
                       'incomplete-ledger-scan))
                    (epi-ledger--open-finalize-state
                     state canonical-path sequence validated-end)
                    (setq prefix-finalized t)
                    (when (> scan-size epi-recovery-fragment-byte-limit)
                      (epi-ledger--limit-fail
                       'recovery-fragment-byte-limit
                       :limit epi-recovery-fragment-byte-limit))
                    (setq inspection-state 'truncated-tail
                          fragment-offset buffer-origin
                          fragment-size scan-size
                          fragment-bytes
                          (epi-ledger--copy-recovery-fragment frame work)
                          fragment-record-id record-id))))
               (_
                (epi-ledger--open-signal
                 'epi-ledger-conflict 'incomplete-ledger-scan
                 canonical-path sequence record-id validated-end
                 'incomplete-ledger-scan)))))))
     (unless (= (if (eq inspection-state 'truncated-tail)
                    (+ validated-end fragment-size)
                  validated-end)
                size)
       (let ((record
              (car (epi-ledger--validation-state-records-reverse state))))
         (epi-ledger--open-signal
          'epi-ledger-conflict 'incomplete-ledger-scan canonical-path
          sequence (and record (epi-record--raw-id record))
          validated-end 'incomplete-ledger-scan)))
     (unless prefix-finalized
       (epi-ledger--open-finalize-state
        state canonical-path sequence validated-end))
     (let* ((last-record
             (car (epi-ledger--validation-state-records-reverse state)))
            (ordered-records
             (epi-ledger--validation-suffix-records state work))
            (records
             (epi-ledger--work-list-to-record-index
              ordered-records work))
            (capsule (epi-ledger--semantic-capsule-from-state state)))
       (epi-ledger--open-verify-current-head
        canonical-path last-record initial-identity work sequence)
       (when (eq inspection-state 'truncated-tail)
         (setq fragment-hash
               (epi-ledger--open-reread-recovery-fragment
                canonical-path fragment-offset
                (+ fragment-offset fragment-size) fragment-bytes
                initial-identity work sequence fragment-record-id)))
       ;; This is the final cooperative boundary.  Only raw constructors and
       ;; field stores occur after the publication identity succeeds.
       (epi-ledger--work-yield work)
       (let ((final-identity
              (let ((epi-ledger--open-publication-phase t))
                (condition-case nil
                    (funcall epi-ledger--open-identity-reader canonical-path)
                  (error nil)))))
         (unless (equal initial-identity final-identity)
           (epi-ledger--open-signal
            'epi-ledger-conflict 'file-identity-changed canonical-path
            sequence nil validated-end 'file-identity-changed)))
       (epi-ledger--make-inspection
        :state inspection-state
        :canonical-path canonical-path
        :file-identity initial-identity
        :source-size size
        :header header
        :record-index records
        :semantic-capsule capsule
        :last-record last-record
        :next-sequence sequence
        :validated-end validated-end
        :valid-prefix-head tail
        :fragment-offset fragment-offset
        :fragment-size fragment-size
       :fragment-hash fragment-hash
       :fragment-bytes fragment-bytes)))))

(defun epi-ledger--inspect-path (path policy)
  "Inspect PATH once under closed tail POLICY through the test seam."
  (epi-ledger--inspect-path-core path policy))

(defun epi-ledger--ledger-from-inspection (inspection)
  "Return a complete ledger handle from identity-bound INSPECTION."
  (unless (and (epi-ledger--inspection-p inspection)
               (eq (epi-ledger--inspection-raw-state inspection) 'complete))
    (epi-ledger--format-fail 'invalid-complete-inspection))
  (let* ((capsule
          (epi-ledger--inspection-raw-semantic-capsule inspection))
         (header (epi-ledger--inspection-raw-header inspection))
         (checkpoint
          (epi-ledger--make-checkpoint
           :file-identity
           (epi-ledger--inspection-raw-file-identity inspection)
           :validated-end-offset
           (epi-ledger--inspection-raw-validated-end inspection)
           :tail-hash
           (epi-ledger--inspection-raw-valid-prefix-head inspection)
           :records (epi-ledger--inspection-raw-record-index inspection)
           :by-id (epi-ledger--semantic-capsule-raw-by-id capsule)
           :turn-operation-index
           (epi-ledger--semantic-capsule-raw-turn-operation-index capsule)
           :tool-facts (epi-ledger--semantic-capsule-raw-calls capsule)
           :semantic-capsule capsule
           :uncertain (epi-ledger--semantic-capsule-raw-uncertain capsule))))
    (epi-ledger--make-ledger
     :path (epi-ledger--inspection-raw-canonical-path inspection)
     :header header
     :session-id (epi-header--raw-session-id header)
     :project-root (epi-header--raw-project-root header)
     :checkpoint-cell (epi-ledger--make-checkpoint-cell :value checkpoint))))

(defun epi-ledger-open (path)
  "Open PATH as a validated read-only append-only Epi ledger.
Validation uses one forward scan in monotonically increasing bounded ranges.
Before publication, a bounded reread of the final record prefix binds the
result to the current chain head.  Per-range identity sandwiches detect
persistent replacement, but portable filename reads without a stable file
descriptor cannot exclude adversarial rename-away/read/restore ABA.  No
repair, recovery, Org evaluation, rendering, or write occurs on this path."
  (epi-ledger--ledger-from-inspection
   (epi-ledger--inspect-path path 'complete)))

(defun epi-ledger--recovery-reseal-source-changed (&rest properties)
  "Signal that recovery reseal source evidence changed with PROPERTIES."
  (apply #'epi-ledger--fail
         'epi-ledger-conflict 'recovery-reseal-source-changed properties))

(defun epi-ledger--recovery-reseal-plan-changed (&rest properties)
  "Signal that a recovery reseal plan changed with PROPERTIES."
  (apply #'epi-ledger--fail
         'epi-ledger-conflict 'recovery-reseal-plan-changed properties))

(defun epi-ledger--recovery-require-truncated-inspection (inspection)
  "Require INSPECTION to describe one recoverable truncated final frame."
  (unless (and (epi-ledger--inspection-p inspection)
               (= (length inspection) epi-ledger--inspection-record-size))
    (epi-ledger--format-fail 'recovery-inspection-required))
  (unless (eq (epi-ledger--inspection-raw-state inspection)
              'truncated-tail)
    (epi-ledger--format-fail 'recovery-truncated-tail-required)))

(defun epi-ledger--recovery-snapshot-origin-admission (capsule origin-id)
  "Snapshot CAPSULE facts needed to admit ORIGIN-ID without callbacks."
  (unless
      (epi-ledger--recovery-exact-record-p
       capsule #'epi-ledger--semantic-capsule-p
       epi-ledger--semantic-capsule-record-size)
    (epi-ledger--recovery-reseal-source-changed))
  (let ((source-by-id
         (epi-ledger--semantic-capsule-raw-by-id capsule))
        (source-evidence
         (epi-ledger--semantic-capsule-raw-recovery-evidence capsule))
        (gc-cons-threshold most-positive-fixnum)
        (by-id (make-hash-table :test #'equal))
        (evidence (make-hash-table :test #'equal)))
    (unless (and (hash-table-p source-by-id)
                 (hash-table-p source-evidence))
      (epi-ledger--recovery-reseal-source-changed))
    (when (gethash origin-id source-by-id)
      (puthash (epi-ledger--owned-string origin-id) t by-id))
    (list
     :by-id by-id :evidence evidence
     :terminalization-required
     (and
      (epi-ledger--semantic-capsule-raw-recovery-terminalization-required
      capsule)
      t))))

(defun epi-ledger--recovery-source-proof-equal-p (left right)
  "Return non-nil when LEFT and RIGHT bind the same recovery source.
Per-record dry-run proofs are deliberately excluded from this comparison."
  (and
   (epi-ledger--recovery-source-proof-p left)
   (epi-ledger--recovery-source-proof-p right)
   (equal
    (list
     (epi-ledger--recovery-source-proof-canonical-path left)
     (epi-ledger--recovery-source-proof-file-identity left)
     (epi-ledger--recovery-source-proof-source-size left)
     (epi-ledger--recovery-source-proof-header-title left)
     (epi-ledger--recovery-source-proof-header-format left)
     (epi-ledger--recovery-source-proof-header-session-id left)
     (epi-ledger--recovery-source-proof-header-created-at left)
     (epi-ledger--recovery-source-proof-header-project-root left)
     (epi-ledger--recovery-source-proof-header-coding-system left)
     (epi-ledger--recovery-source-proof-header-hash left)
     (epi-ledger--recovery-source-proof-validated-end left)
     (epi-ledger--recovery-source-proof-valid-prefix-head left)
     (epi-ledger--recovery-source-proof-next-sequence left)
     (epi-ledger--recovery-source-proof-fragment-offset left)
     (epi-ledger--recovery-source-proof-fragment-size left)
     (epi-ledger--recovery-source-proof-fragment-hash left)
     (epi-ledger--recovery-source-proof-record-count left))
    (list
     (epi-ledger--recovery-source-proof-canonical-path right)
     (epi-ledger--recovery-source-proof-file-identity right)
     (epi-ledger--recovery-source-proof-source-size right)
     (epi-ledger--recovery-source-proof-header-title right)
     (epi-ledger--recovery-source-proof-header-format right)
     (epi-ledger--recovery-source-proof-header-session-id right)
     (epi-ledger--recovery-source-proof-header-created-at right)
     (epi-ledger--recovery-source-proof-header-project-root right)
     (epi-ledger--recovery-source-proof-header-coding-system right)
     (epi-ledger--recovery-source-proof-header-hash right)
     (epi-ledger--recovery-source-proof-validated-end right)
     (epi-ledger--recovery-source-proof-valid-prefix-head right)
     (epi-ledger--recovery-source-proof-next-sequence right)
     (epi-ledger--recovery-source-proof-fragment-offset right)
     (epi-ledger--recovery-source-proof-fragment-size right)
     (epi-ledger--recovery-source-proof-fragment-hash right)
     (epi-ledger--recovery-source-proof-record-count right)))))

(defun epi-ledger--recovery-snapshot-source-proof (inspection)
  "Return owned scalar and fragment evidence for INSPECTION."
  (let* ((captured
          (condition-case nil
              (let* ((gc-cons-threshold most-positive-fixnum)
                     (header
                      (epi-ledger--inspection-raw-header inspection))
                     (index
                      (epi-ledger--inspection-raw-record-index inspection))
                     (next-sequence
                      (epi-ledger--inspection-raw-next-sequence inspection))
                     (chunked-index-p
                      (epi-ledger--recovery-exact-record-p
                       index #'epi-ledger--record-index-p
                       epi-ledger--record-index-record-size))
                     (last-record
                      (epi-ledger--inspection-raw-last-record inspection))
                     (fragment
                      (epi-ledger--inspection-raw-fragment-bytes inspection)))
                (unless (and
                             (epi-ledger--recovery-exact-record-p
                              header #'epi-header-p
                              epi-ledger--header-record-size)
                             (or chunked-index-p (consp index))
                             (epi-ledger--recovery-bounded-unsigned-p
                              next-sequence)
                             (> next-sequence 1)
                             (epi-ledger--recovery-exact-record-p
                              last-record #'epi-record-p
                              epi-ledger--record-record-size)
                             (stringp fragment))
                  (epi-ledger--recovery-reseal-source-changed))
                (list
                 :canonical-path
                 (epi-ledger--owned-string
                  (epi-ledger--inspection-raw-canonical-path inspection))
                 :file-identity
                 (epi-ledger--lock-file-object-to-identity
                  (epi-ledger--lock-file-identity-object
                   (epi-ledger--inspection-raw-file-identity inspection)))
                 :source-size
                 (epi-ledger--inspection-raw-source-size inspection)
                 :header-title
                 (epi-ledger--owned-string
                  (epi-header--raw-title header))
                 :header-format (epi-header--raw-format header)
                 :header-session-id
                 (epi-ledger--owned-string
                  (epi-header--raw-session-id header))
                 :header-created-at
                 (epi-ledger--owned-string
                  (epi-header--raw-created-at header))
                 :header-project-root
                 (epi-ledger--owned-string
                  (epi-header--raw-project-root header))
                 :header-coding-system
                 (epi-ledger--owned-string
                  (epi-header--raw-coding-system header))
                 :header-hash
                 (epi-ledger--owned-string (epi-header--raw-hash header))
                 :validated-end
                 (epi-ledger--inspection-raw-validated-end inspection)
                 :last-record-end (epi-record--raw-end-offset last-record)
                 :valid-prefix-head
                 (epi-ledger--owned-string
                  (epi-ledger--inspection-raw-valid-prefix-head inspection))
                 :next-sequence
                 next-sequence
                 :fragment-offset
                 (epi-ledger--inspection-raw-fragment-offset inspection)
                 :fragment-size
                 (epi-ledger--inspection-raw-fragment-size inspection)
                 :fragment-hash
                 (epi-ledger--owned-string
                  (epi-ledger--inspection-raw-fragment-hash inspection))
                 :fragment-bytes fragment
                 :record-count
                 (if chunked-index-p
                     (epi-ledger--record-index-raw-count index)
                   (1- next-sequence))))
            (error (epi-ledger--recovery-reseal-source-changed))))
         (fragment (plist-get captured :fragment-bytes))
         (fragment-size (plist-get captured :fragment-size))
         (source-size (plist-get captured :source-size))
         (fragment-offset (plist-get captured :fragment-offset))
         (validated-end (plist-get captured :validated-end))
         (last-record-end (plist-get captured :last-record-end))
         (file-identity (plist-get captured :file-identity))
         (identity-size (and (listp file-identity)
                             (plist-get file-identity :size)))
         (record-count (plist-get captured :record-count))
         (next-sequence (plist-get captured :next-sequence)))
    (unless (and (stringp fragment)
                 (not (multibyte-string-p fragment))
                 (integerp fragment-size)
                 (> fragment-size 0))
      (epi-ledger--recovery-reseal-source-changed))
    (when (> fragment-size epi-recovery-fragment-byte-limit)
      (epi-ledger--limit-fail
       'recovery-fragment-byte-limit
       :limit epi-recovery-fragment-byte-limit))
    (unless (and (= fragment-size (length fragment))
                 (integerp fragment-offset)
                 (integerp validated-end)
                 (= validated-end fragment-offset)
                 (integerp last-record-end)
                 (= last-record-end validated-end)
                 (integerp source-size)
                 (= (+ fragment-offset fragment-size) source-size)
                 (integerp identity-size)
                 (= identity-size source-size)
                 (equal (plist-get captured :canonical-path)
                        (plist-get file-identity :path))
                 (integerp record-count)
                 (> record-count 0)
                 (integerp next-sequence)
                 (= next-sequence (1+ record-count)))
      (epi-ledger--recovery-reseal-source-changed))
    (let* ((computed-fragment-hash
            (condition-case nil
                (epi-ledger--hash fragment 'recovery-fragment)
              ((epi-ledger-error epi-limit-exceeded)
               (epi-ledger--recovery-reseal-source-changed))))
           (recomputed-header
            (condition-case nil
                (let ((epi-ledger--cold-open-validation t))
                  (epi-ledger-seal-header
                   :session-id (plist-get captured :header-session-id)
                   :created-at (plist-get captured :header-created-at)
                   :project-root (plist-get captured :header-project-root)))
              ((epi-ledger-error epi-limit-exceeded)
               (epi-ledger--recovery-reseal-source-changed)))))
      (unless
          (and
           (equal computed-fragment-hash
                  (plist-get captured :fragment-hash))
           (equal (plist-get captured :header-title) "Epi session")
           (integerp (plist-get captured :header-format))
           (= (plist-get captured :header-format) 1)
           (equal (plist-get captured :header-coding-system) "utf-8-unix")
           (equal (plist-get captured :header-hash)
                  (epi-header--raw-hash recomputed-header)))
        (epi-ledger--recovery-reseal-source-changed))
      (epi-ledger--make-recovery-source-proof
       :canonical-path (plist-get captured :canonical-path)
       :file-identity file-identity
       :source-size source-size
       :header-title (plist-get captured :header-title)
       :header-format (plist-get captured :header-format)
       :header-session-id (plist-get captured :header-session-id)
       :header-created-at (plist-get captured :header-created-at)
       :header-project-root (plist-get captured :header-project-root)
       :header-coding-system (plist-get captured :header-coding-system)
       :header-hash (plist-get captured :header-hash)
       :validated-end validated-end
       :valid-prefix-head (plist-get captured :valid-prefix-head)
       :next-sequence next-sequence
       :fragment-offset fragment-offset
       :fragment-size fragment-size
       :fragment-hash (plist-get captured :fragment-hash)
       :record-count record-count
       :record-proofs nil))))

(defun epi-ledger--recovery-snapshot-record (record)
  "Return a callback-free owned snapshot of source RECORD."
  (condition-case nil
      (let ((gc-cons-threshold most-positive-fixnum))
        (unless
            (epi-ledger--recovery-exact-record-p
             record #'epi-record-p epi-ledger--record-record-size)
          (epi-ledger--recovery-reseal-source-changed))
        (list
         :type (epi-record--raw-type record)
         :sequence (epi-record--raw-sequence record)
         :source-hash
         (epi-ledger--owned-string (epi-record--raw-hash record))
         :envelope
         (epi-ledger--snapshot-canonical-value
          (epi-ledger--envelope record)
          epi-record-json-byte-limit 'record-json-byte-limit)))
    (error (epi-ledger--recovery-reseal-source-changed))))

(defun epi-ledger--recovery-verify-source-record
    (snapshot expected-sequence expected-previous-hash expected-proof)
  "Verify source SNAPSHOT at EXPECTED-SEQUENCE against its chain.
EXPECTED-PREVIOUS-HASH anchors the source chain.  When non-nil,
EXPECTED-PROOF also binds the dry-run result."
  (let* ((envelope (plist-get snapshot :envelope))
         (source-previous-hash
          (epi-ledger--object-value envelope "previous_hash"))
         (source-hash (plist-get snapshot :source-hash))
         (sequence (plist-get snapshot :sequence)))
    (unless (and (integerp sequence)
                 (= sequence expected-sequence)
                 (equal source-previous-hash expected-previous-hash)
                 (or
                  (null expected-proof)
                  (and (epi-ledger--recovery-record-proof-p expected-proof)
                   (equal
                    source-previous-hash
                    (epi-ledger--recovery-record-proof-source-previous-hash
                     expected-proof))
                   (equal
                    source-hash
                    (epi-ledger--recovery-record-proof-source-hash
                     expected-proof)))))
      (epi-ledger--recovery-reseal-source-changed
       :sequence expected-sequence))
    (let ((actual
           (condition-case nil
               (epi-ledger--hash
                (epi-ledger--jcs-encode
                 envelope epi-record-json-byte-limit)
                'record)
             ((epi-ledger-error epi-limit-exceeded)
              (epi-ledger--recovery-reseal-source-changed
               :sequence expected-sequence)))))
      (unless (equal actual source-hash)
        (epi-ledger--recovery-reseal-source-changed
         :sequence expected-sequence)))
    source-hash))

(defun epi-ledger--recovery-destination-draft
    (snapshot firstp destination-session-id)
  "Return SNAPSHOT's owned draft for DESTINATION-SESSION-ID.
When FIRSTP is non-nil, replace the owned session-info identity."
  (let* ((type (plist-get snapshot :type))
         (envelope (plist-get snapshot :envelope))
         (payload (epi-ledger--object-value envelope "payload")))
    (if firstp
        (progn
          (unless (eq type 'session-info)
            (epi-ledger--recovery-reseal-source-changed :sequence 1))
          (let ((session (assoc "session_id" payload)))
            (unless session
              (epi-ledger--recovery-reseal-source-changed :sequence 1))
            (setcdr session destination-session-id)))
      (when (eq type 'session-info)
        (epi-ledger--recovery-reseal-source-changed
         :sequence (plist-get snapshot :sequence))))
    (make-epi-draft
     :id (epi-ledger--object-value envelope "id")
     :type type
     :at (epi-ledger--object-value envelope "at")
     :parent (epi-ledger--object-value envelope "parent")
     :target (epi-ledger--object-value envelope "target")
     :turn (epi-ledger--object-value envelope "turn")
     :operation (epi-ledger--object-value envelope "operation")
     :payload payload)))

(defun epi-ledger--recovery-record-source-each
    (source expected-count function work)
  "Call FUNCTION for EXPECTED-COUNT exact records in recovery SOURCE through WORK.
Reject malformed, cyclic, sparse, or count-incoherent private record-source
graphs with the recovery source-conflict taxonomy."
  (unless (epi-ledger--recovery-bounded-unsigned-p expected-count)
    (epi-ledger--recovery-reseal-source-changed))
  (cond
   ((epi-ledger--record-index-p source)
    (unless
        (epi-ledger--recovery-exact-record-p
         source #'epi-ledger--record-index-p
         epi-ledger--record-index-record-size)
      (epi-ledger--recovery-reseal-source-changed))
    (let ((tail (epi-ledger--record-index-raw-chunks source))
          (stored-count (epi-ledger--record-index-raw-count source))
          (seen (make-hash-table :test #'eq))
          (total 0))
      (unless (and (epi-ledger--recovery-bounded-unsigned-p stored-count)
                   (= stored-count expected-count))
        (epi-ledger--recovery-reseal-source-changed))
      (while (consp tail)
        (when (gethash tail seen)
          (epi-ledger--recovery-reseal-source-changed))
        (puthash tail t seen)
        (epi-ledger--work-charge-count work 1)
        (let* ((chunk (car tail))
               (next (cdr tail)))
          (unless
              (epi-ledger--recovery-exact-record-p
               chunk #'epi-ledger--record-chunk-p
               epi-ledger--record-chunk-record-size)
            (epi-ledger--recovery-reseal-source-changed))
          (let ((values (epi-ledger--record-chunk-raw-values chunk))
                (count (epi-ledger--record-chunk-raw-count chunk)))
            (unless (and (vectorp values) (integerp count) (> count 0)
                         (= count (length values))
                         (<= (+ total count) stored-count))
              (epi-ledger--recovery-reseal-source-changed))
            (dotimes (offset count)
              (epi-ledger--work-charge-count work 1)
              (let ((record (aref values offset)))
                (unless
                    (epi-ledger--recovery-exact-record-p
                     record #'epi-record-p epi-ledger--record-record-size)
                  (epi-ledger--recovery-reseal-source-changed))
                (funcall function record)))
            (setq total (+ total count)
                  tail next))))
      (unless (and (null tail) (= total stored-count))
        (epi-ledger--recovery-reseal-source-changed))
      total))
   ((consp source)
    (let ((tail source)
          (seen (make-hash-table :test #'eq))
          (total 0))
      (while (consp tail)
        (when (gethash tail seen)
          (epi-ledger--recovery-reseal-source-changed))
        (puthash tail t seen)
        (epi-ledger--work-charge-count work 1)
        (let ((record (car tail))
              (next (cdr tail)))
          (unless
              (epi-ledger--recovery-exact-record-p
               record #'epi-record-p epi-ledger--record-record-size)
            (epi-ledger--recovery-reseal-source-changed))
          (funcall function record)
          (setq tail next
                total (1+ total))
          (when (> total expected-count)
            (epi-ledger--recovery-reseal-source-changed))))
      (unless (and (null tail) (= total expected-count))
        (epi-ledger--recovery-reseal-source-changed))
      total))
   (t
    (epi-ledger--recovery-reseal-source-changed))))

(defun epi-ledger--recovery-reseal-source-pass
    (inspection source-proof destination-session-id expected-plan emit)
  "Reseal INSPECTION's prefix and return its frame-free pass summary.
SOURCE-PROOF is the frozen scalar binding, and DESTINATION-SESSION-ID names
the new chain.  EXPECTED-PLAN is checked before any corresponding emission.
EMIT, when non-nil, receives each exact bounded chunk."
  (let* ((verify-p (and expected-plan t))
         (work (epi-ledger--make-work-state))
         (header
          (let ((epi-ledger--cold-open-validation t))
            (epi-ledger-seal-header
             :session-id destination-session-id
             :created-at
             (epi-ledger--recovery-source-proof-header-created-at
              source-proof)
             :project-root
             (epi-ledger--recovery-source-proof-header-project-root
              source-proof))))
         (header-bytes (and emit (epi-ledger-render-header header)))
         (header-size
          (if header-bytes
              (length header-bytes)
            (epi-ledger--header-rendered-byte-size
             (epi-header--raw-session-id header)
             (epi-header--raw-created-at header)
             (epi-header--raw-project-root header))))
         (destination-tail (epi-header--raw-hash header))
         (source-tail
          (epi-ledger--recovery-source-proof-header-hash source-proof))
         (proof-tail
          (and verify-p
               (epi-ledger--recovery-source-proof-record-proofs
                source-proof)))
         (recovery-evidence
          (and (not verify-p) (make-hash-table :test #'equal)))
         proofs-reverse
         (count 0)
         (byte-size header-size)
         (records-since-yield 0))
    (when
        (and
         verify-p
         (not
          (and
           (equal
            (epi-header--raw-hash header)
            (epi-ledger--recovery-reseal-plan-destination-header-sha256
             expected-plan))
           (=
            header-size
            (epi-ledger--recovery-reseal-plan-destination-header-byte-size
             expected-plan)))))
      (epi-ledger--recovery-reseal-plan-changed))
    (when emit
      (funcall emit header-bytes))
    (epi-ledger--recovery-record-source-each
     (epi-ledger--inspection-raw-record-index inspection)
     (epi-ledger--recovery-source-proof-record-count source-proof)
     (lambda (source-record)
         (let* ((sequence (1+ count))
                (expected-proof
                 (and verify-p
                      (or (car proof-tail)
                          (epi-ledger--recovery-reseal-source-changed
                           :sequence sequence))))
                (snapshot
                 (epi-ledger--recovery-snapshot-record source-record))
                (verified-source-hash
                 (epi-ledger--recovery-verify-source-record
                  snapshot sequence source-tail expected-proof))
                (_authenticated-evidence
                 (when
                     (and recovery-evidence
                          (eq (plist-get snapshot :type) 'recovery-origin))
                   (let* ((payload
                           (epi-ledger--object-value
                            (plist-get snapshot :envelope) "payload"))
                          (digest
                           (epi-ledger--object-value
                            payload "source_evidence_sha256")))
                     (unless (epi-ledger--hash-p digest)
                       (epi-ledger--recovery-reseal-source-changed
                        :sequence sequence))
                     (puthash
                      (substring-no-properties digest) t
                      recovery-evidence))))
                (draft
                 (epi-ledger--recovery-destination-draft
                  snapshot (= sequence 1) destination-session-id))
                (record
                 (let ((epi-ledger--cold-open-validation t))
                   (epi-ledger-seal-record
                    draft destination-tail sequence)))
                (frame (and emit (epi-ledger-render-record record)))
                (frame-size
                 (if frame
                     (length frame)
                   (let* ((json (epi-ledger--record-json record))
                          (properties
                           (epi-ledger--record-render-properties record))
                          (size
                           (epi-ledger--record-rendered-byte-size
                            record json properties)))
                     (when (> size epi-record-frame-byte-limit)
                       (epi-ledger--limit-fail
                        'record-frame-byte-limit
                        :limit epi-record-frame-byte-limit))
                     size))))
           (when verify-p
             (unless
                 (and
                  (equal
                   (epi-ledger--recovery-record-proof-destination-hash
                    expected-proof)
                   (epi-record--raw-hash record))
                  (=
                   (epi-ledger--recovery-record-proof-frame-byte-size
                    expected-proof)
                   frame-size))
               (epi-ledger--recovery-reseal-source-changed
                :sequence sequence))
             (setq proof-tail (cdr proof-tail)))
           (unless verify-p
             (setq proofs-reverse
                   (epi-ledger--work-cons
                    (epi-ledger--make-recovery-record-proof
                     :source-previous-hash source-tail
                     :source-hash verified-source-hash
                     :destination-hash (epi-record--raw-hash record)
                     :frame-byte-size frame-size)
                    proofs-reverse work)))
           (setq source-tail verified-source-hash
                 destination-tail (epi-record--raw-hash record)
                 byte-size (+ byte-size frame-size)
                 count sequence
                 records-since-yield (1+ records-since-yield))
           (when emit
             (funcall emit frame))
           (when (>= records-since-yield epi-ledger-work-record-limit)
             (epi-ledger--work-yield work)
             (setq records-since-yield 0))))
     work)
    (when (and verify-p proof-tail)
      (epi-ledger--recovery-reseal-source-changed
       :sequence (1+ count)))
    (unless (and
             (= count
                (epi-ledger--recovery-source-proof-record-count
                 source-proof))
             (= (1+ count)
                (epi-ledger--recovery-source-proof-next-sequence
                 source-proof))
             (equal source-tail
                    (epi-ledger--recovery-source-proof-valid-prefix-head
                     source-proof)))
      (epi-ledger--recovery-reseal-source-changed
       :sequence (1+ count)))
    (list
     :header-sha256 (epi-header--raw-hash header)
     :header-byte-size header-size
     :destination-prefix-head destination-tail
     :source-record-count count
     :byte-size byte-size
     :recovery-evidence recovery-evidence
     :record-proofs
     (and (not verify-p)
          (epi-ledger--work-nreverse-list proofs-reverse work)))))

(defun epi-ledger--recovery-origin-payload (source-proof destination-head)
  "Return fresh recovery-origin payload for SOURCE-PROOF and DESTINATION-HEAD."
  (let* ((payload
          `(("source_path" .
             ,(epi-ledger--recovery-source-proof-canonical-path source-proof))
            ("source_session_id" .
             ,(epi-ledger--recovery-source-proof-header-session-id
               source-proof))
            ("source_file_size" .
             ,(epi-ledger--recovery-source-proof-source-size source-proof))
            ("source_header_sha256" .
             ,(epi-ledger--recovery-source-proof-header-hash source-proof))
            ("source_valid_prefix_head_sha256" .
             ,(epi-ledger--recovery-source-proof-valid-prefix-head
               source-proof))
            ("fragment_offset" .
             ,(epi-ledger--recovery-source-proof-fragment-offset
               source-proof))
            ("fragment_sha256" .
             ,(epi-ledger--recovery-source-proof-fragment-hash source-proof))
            ("fragment_size" .
             ,(epi-ledger--recovery-source-proof-fragment-size source-proof))
            ("fragment_object" .
             (("hash" .
               ,(epi-ledger--recovery-source-proof-fragment-hash
                 source-proof))
              ("size" .
               ,(epi-ledger--recovery-source-proof-fragment-size
                 source-proof))
              ("media_type" . "application/octet-stream")
              ("role" . "recovery-fragment")))
            ("destination_valid_prefix_head_sha256" . ,destination-head)))
         (digest (epi-ledger--recovery-evidence-v1-sha256 payload)))
    (append payload `(("source_evidence_sha256" . ,digest)))))

(defun epi-ledger--recovery-seal-origin
    (payload origin-id origin-at previous-hash sequence renderp)
  "Seal one fresh recovery origin, returning a bounded summary.
PAYLOAD, ORIGIN-ID, and ORIGIN-AT are its semantic inputs.  PREVIOUS-HASH and
SEQUENCE place it after the re-sealed destination prefix.  When RENDERP is
non-nil, include its exact frame bytes; otherwise only preflight their size."
  (let* ((epi-ledger--cold-open-validation t)
         (record
          (epi-ledger-seal-record
           (make-epi-draft
            :id origin-id :type 'recovery-origin :at origin-at
            :payload payload)
           previous-hash sequence))
         (frame (and renderp (epi-ledger-render-record record)))
         (frame-size
          (if frame
              (length frame)
            (let* ((json (epi-ledger--record-json record))
                   (properties (epi-ledger--record-render-properties record))
                   (size
                    (epi-ledger--record-rendered-byte-size
                     record json properties)))
              (when (> size epi-record-frame-byte-limit)
                (epi-ledger--limit-fail
                 'record-frame-byte-limit :limit epi-record-frame-byte-limit))
              size))))
    (list :record record :frame frame :frame-byte-size frame-size)))

(defun epi-ledger--recovery-plan-reseal
    (inspection destination-session-id origin-id origin-at)
  "Plan a deterministic frame-free recovery reseal of INSPECTION.
DESTINATION-SESSION-ID, ORIGIN-ID, and ORIGIN-AT are caller-owned identities
that are copied before any cooperative yield."
  (epi-ledger--with-operation-work-state
    (epi-ledger--recovery-require-truncated-inspection inspection)
    (let* ((inputs
            (let ((gc-cons-threshold most-positive-fixnum))
              (let ((header (epi-ledger--inspection-raw-header inspection)))
                (unless
                    (epi-ledger--recovery-exact-record-p
                     header #'epi-header-p epi-ledger--header-record-size)
                  (epi-ledger--recovery-reseal-source-changed))
                (unless (epi-ledger--uuid-p destination-session-id)
                  (epi-ledger--format-fail
                   'invalid-id :field "destination_session_id"))
                (unless (epi-ledger--uuid-p origin-id)
                  (epi-ledger--format-fail 'invalid-id :field "origin_id"))
                (unless
                    (and (stringp origin-at)
                         (<= (length origin-at) epi-record-json-byte-limit)
                         (<= (string-bytes origin-at)
                             epi-record-json-byte-limit))
                  (epi-ledger--format-fail
                   'invalid-timestamp :field "origin_at"))
                (unless
                    (epi-ledger--uuid-p (epi-header--raw-session-id header))
                  (epi-ledger--recovery-reseal-source-changed))
                (list
                 (substring-no-properties destination-session-id)
                 (substring-no-properties origin-id)
                 (substring-no-properties origin-at)
                 (substring-no-properties
                  (epi-header--raw-session-id header))))))
           (destination-session-id (nth 0 inputs))
           (origin-id (nth 1 inputs))
           (origin-at (nth 2 inputs))
           (source-session-id (nth 3 inputs))
           (capsule
            (epi-ledger--inspection-raw-semantic-capsule inspection))
           (admission
            (epi-ledger--recovery-snapshot-origin-admission
             capsule origin-id))
           (source-proof
            (epi-ledger--recovery-snapshot-source-proof inspection)))
      (epi-ledger--require-uuid
       destination-session-id "destination_session_id")
      (when (equal destination-session-id source-session-id)
        (epi-ledger--format-fail 'recovery-session-id-reused))
      (epi-ledger--require-uuid origin-id "origin_id")
      (when (gethash
             origin-id (plist-get admission :by-id))
        (epi-ledger--format-fail 'duplicate-id))
      (unless (epi-ledger--timestamp-p origin-at)
        (epi-ledger--format-fail 'invalid-timestamp :field "origin_at"))
      (let* ((pass
              (epi-ledger--recovery-reseal-source-pass
               inspection source-proof destination-session-id nil nil))
             (after-proof
              (epi-ledger--recovery-snapshot-source-proof inspection))
             (_source-stable
              (unless
                  (epi-ledger--recovery-source-proof-equal-p
                   source-proof after-proof)
                (epi-ledger--recovery-reseal-source-changed)))
             (proofs (plist-get pass :record-proofs))
             (_proof-publication
              (setf
               (epi-ledger--recovery-source-proof-record-proofs source-proof)
               proofs))
             (destination-head
              (plist-get pass :destination-prefix-head))
             (origin-payload
              (epi-ledger--recovery-origin-payload
               source-proof destination-head))
             (origin-result
              (epi-ledger--recovery-seal-origin
               origin-payload origin-id origin-at destination-head
               (epi-ledger--recovery-source-proof-next-sequence
                source-proof)
               nil))
             (origin-record (plist-get origin-result :record))
             (sealed-origin-payload
              (epi-record--raw-payload origin-record))
             (canonical-origin-payload
              (epi-ledger--decode-json
               (epi-ledger--jcs-encode sealed-origin-payload)))
             (origin-evidence
              (epi-ledger--object-value
               canonical-origin-payload "source_evidence_sha256"))
             (_evidence-publication
              (when (gethash
                     origin-evidence (plist-get pass :recovery-evidence))
                (puthash
                 (substring-no-properties origin-evidence) t
                 (plist-get admission :evidence))))
             (origin-frame-size
              (plist-get origin-result :frame-byte-size)))
        (epi-ledger--require-recovery-origin-admissible
         origin-record
         (plist-get admission :by-id)
         (plist-get admission :evidence)
         (plist-get admission :terminalization-required))
        (unless
            (equal
             destination-head
             (epi-ledger--payload-value
              origin-record "destination_valid_prefix_head_sha256"))
          (epi-ledger--semantic-fail 'recovery-prefix-head-mismatch))
        (let ((final-proof
               (epi-ledger--recovery-snapshot-source-proof inspection)))
          (unless
              (epi-ledger--recovery-source-proof-equal-p
               source-proof final-proof)
            (epi-ledger--recovery-reseal-source-changed))
          (epi-ledger--make-recovery-reseal-plan
           :source-proof source-proof
           :destination-session-id destination-session-id
           :origin-id origin-id :origin-at origin-at
           :origin-payload canonical-origin-payload
           :source-evidence-sha256 origin-evidence
           :destination-header-sha256 (plist-get pass :header-sha256)
           :destination-header-byte-size
           (plist-get pass :header-byte-size)
           :destination-prefix-head destination-head
           :final-head (epi-record--raw-hash origin-record)
           :origin-frame-byte-size origin-frame-size
           :source-record-count (plist-get pass :source-record-count)
           :output-record-count
           (1+ (plist-get pass :source-record-count))
           :byte-size
           (+ (plist-get pass :byte-size) origin-frame-size)))))))

(defun epi-ledger--recovery-copy-plan-string (value maximum-bytes)
  "Return an owned copy of recovery string VALUE below MAXIMUM-BYTES.
The bound is checked before allocation and is independent of cooperative work
slices."
  (unless (and (stringp value)
               (<= (length value) maximum-bytes)
               (<= (string-bytes value) maximum-bytes))
    (epi-ledger--recovery-reseal-plan-changed))
  (substring-no-properties value))

(defun epi-ledger--recovery-copy-record-proof (proof work)
  "Return an ownership-isolated copy of recovery record PROOF.
Charge its bounded scalar fields through WORK."
  (let* ((captured
          (condition-case nil
              (let ((gc-cons-threshold most-positive-fixnum))
                (unless
                    (epi-ledger--recovery-exact-record-p
                     proof #'epi-ledger--recovery-record-proof-p
                     epi-ledger--recovery-record-proof-record-size)
                  (epi-ledger--recovery-reseal-plan-changed))
                (list
                 (epi-ledger--recovery-record-proof-frame-byte-size proof)
                 (epi-ledger--recovery-copy-plan-string
                  (epi-ledger--recovery-record-proof-source-previous-hash
                   proof)
                  64)
                 (epi-ledger--recovery-copy-plan-string
                  (epi-ledger--recovery-record-proof-source-hash proof)
                  64)
                 (epi-ledger--recovery-copy-plan-string
                  (epi-ledger--recovery-record-proof-destination-hash proof)
                  64)))
            (error (epi-ledger--recovery-reseal-plan-changed))))
         (frame-size (nth 0 captured))
         (source-previous-hash (nth 1 captured))
         (source-hash (nth 2 captured))
         (destination-hash (nth 3 captured)))
    (unless (and (epi-ledger--hash-p source-previous-hash)
                 (epi-ledger--hash-p source-hash)
                 (epi-ledger--hash-p destination-hash)
                 (integerp frame-size) (> frame-size 0)
                 (<= frame-size epi-record-frame-byte-limit))
      (epi-ledger--recovery-reseal-plan-changed))
    (epi-ledger--work-charge-count
     work (+ (string-bytes source-previous-hash)
             (string-bytes source-hash)
             (string-bytes destination-hash)
             1))
    (epi-ledger--make-recovery-record-proof
     :source-previous-hash source-previous-hash
     :source-hash source-hash
     :destination-hash destination-hash
     :frame-byte-size frame-size)))

(defun epi-ledger--recovery-copy-record-proofs
    (proofs expected-count work)
  "Copy PROOFS iteratively through WORK and require EXPECTED-COUNT entries."
  (unless (and (integerp expected-count) (> expected-count 0))
    (epi-ledger--recovery-reseal-plan-changed))
  (let ((tail proofs)
        (seen (make-hash-table :test #'eq))
        reversed
        (count 0)
        (records-since-yield 0))
    (while (consp tail)
      (when (gethash tail seen)
        (epi-ledger--recovery-reseal-plan-changed))
      (puthash tail t seen)
      (let* ((proof (car tail))
             (next (cdr tail))
             (owned-proof
              (epi-ledger--recovery-copy-record-proof proof work)))
        (epi-ledger--work-charge-count work 2)
        (setq reversed
              (epi-ledger--work-cons
               owned-proof reversed work)
              tail next
              count (1+ count)
              records-since-yield (1+ records-since-yield)))
      (when (> count expected-count)
        (epi-ledger--recovery-reseal-plan-changed))
      (when (>= records-since-yield epi-ledger-work-record-limit)
        (epi-ledger--work-yield work)
        (setq records-since-yield 0)))
    (unless (and (null tail) (= count expected-count))
      (epi-ledger--recovery-reseal-plan-changed))
    (epi-ledger--work-nreverse-list reversed work)))

(defun epi-ledger--recovery-bounded-unsigned-p (value)
  "Return non-nil when VALUE fits an unsigned 64-bit recovery scalar."
  (and (integerp value) (<= 0 value 18446744073709551615)))

(defun epi-ledger--recovery-parse-bounded-unsigned-decimal (value field)
  "Parse canonical decimal VALUE for FIELD as an unsigned 64-bit integer."
  (unless (and (stringp value) (<= (length value) 20))
    (epi-ledger--format-fail 'invalid-unsigned-decimal :field field))
  (let ((number (epi-ledger--parse-unsigned-decimal value field)))
    (unless (epi-ledger--recovery-bounded-unsigned-p number)
      (epi-ledger--format-fail 'invalid-unsigned-decimal :field field))
    number))

(defun epi-ledger--recovery-copy-time (value)
  "Return an owned canonical four-part time VALUE without unbounded walks."
  (let (parts)
    (cond
     ((vectorp value)
      (unless (= (length value) 4)
        (epi-ledger--recovery-reseal-plan-changed))
      (setq parts (list (aref value 0) (aref value 1)
                        (aref value 2) (aref value 3))))
     ((listp value)
      (let ((tail value))
        (dotimes (_ 4)
          (unless (consp tail)
            (epi-ledger--recovery-reseal-plan-changed))
          (push (car tail) parts)
          (setq tail (cdr tail)))
        (unless (null tail)
          (epi-ledger--recovery-reseal-plan-changed))
        (setq parts (nreverse parts))))
     (t (epi-ledger--recovery-reseal-plan-changed)))
    (unless (seq-every-p #'epi-ledger--safe-integer-p parts)
      (epi-ledger--recovery-reseal-plan-changed))
    (condition-case nil
        (epi-ledger--normalize-time-vector parts)
      (error (epi-ledger--recovery-reseal-plan-changed)))))

(defun epi-ledger--recovery-copy-file-identity (identity)
  "Return a closed bounded ownership copy of file IDENTITY."
  (condition-case nil
      (let ((tail identity)
            values)
        (dolist (key '(:path :device :inode :links :size :modified :changed))
          (unless (and (consp tail) (eq (car tail) key)
                       (consp (cdr tail)))
            (epi-ledger--recovery-reseal-plan-changed))
          (push (cadr tail) values)
          (setq tail (cddr tail)))
        (unless (null tail)
          (epi-ledger--recovery-reseal-plan-changed))
        (setq values (nreverse values))
        (let ((path
               (epi-ledger--recovery-copy-plan-string
                (nth 0 values) epi-header-value-byte-limit))
              (device (nth 1 values))
              (inode (nth 2 values))
              (links (nth 3 values))
              (size (nth 4 values)))
          (unless (and (epi-ledger--recovery-bounded-unsigned-p device)
                       (epi-ledger--recovery-bounded-unsigned-p inode)
                       (epi-ledger--recovery-bounded-unsigned-p links)
                       (epi-ledger--recovery-bounded-unsigned-p size))
            (epi-ledger--recovery-reseal-plan-changed))
          (list :path path :device device :inode inode :links links :size size
                :modified
                (append (epi-ledger--recovery-copy-time (nth 5 values)) nil)
                :changed
                (append (epi-ledger--recovery-copy-time (nth 6 values)) nil))))
    (error (epi-ledger--recovery-reseal-plan-changed))))

(defun epi-ledger--recovery-copy-directory-identity (identity)
  "Return a closed bounded ownership copy of directory IDENTITY."
  (condition-case nil
      (let ((tail identity)
            values)
        (dolist (key '(:path :device :inode :links :modified :changed))
          (unless (and (consp tail) (eq (car tail) key)
                       (consp (cdr tail)))
            (epi-ledger--recovery-reseal-plan-changed))
          (push (cadr tail) values)
          (setq tail (cddr tail)))
        (unless (null tail)
          (epi-ledger--recovery-reseal-plan-changed))
        (setq values (nreverse values))
        (let ((path
               (epi-ledger--recovery-copy-plan-string
                (nth 0 values) epi-header-value-byte-limit))
              (device (nth 1 values))
              (inode (nth 2 values))
              (links (nth 3 values)))
          (unless (and (epi-ledger--recovery-bounded-unsigned-p device)
                       (epi-ledger--recovery-bounded-unsigned-p inode)
                       (epi-ledger--recovery-bounded-unsigned-p links))
            (epi-ledger--recovery-reseal-plan-changed))
          (list :path path :device device :inode inode :links links
                :modified
                (append (epi-ledger--recovery-copy-time (nth 4 values)) nil)
                :changed
                (append (epi-ledger--recovery-copy-time (nth 5 values)) nil))))
    (error (epi-ledger--recovery-reseal-plan-changed))))

(defun epi-ledger--recovery-copy-source-proof-scalars (proof)
  "Return an ownership snapshot of source PROOF without its record proofs."
  (condition-case nil
      (let ((gc-cons-threshold most-positive-fixnum))
        (unless
            (epi-ledger--recovery-exact-record-p
             proof #'epi-ledger--recovery-source-proof-p
             epi-ledger--recovery-source-proof-record-size)
          (epi-ledger--recovery-reseal-plan-changed))
        (epi-ledger--make-recovery-source-proof
         :canonical-path
         (epi-ledger--recovery-copy-plan-string
          (epi-ledger--recovery-source-proof-canonical-path proof)
          epi-header-value-byte-limit)
         :file-identity
         (epi-ledger--recovery-copy-file-identity
          (epi-ledger--recovery-source-proof-file-identity proof))
         :source-size (epi-ledger--recovery-source-proof-source-size proof)
         :header-title
         (epi-ledger--recovery-copy-plan-string
          (epi-ledger--recovery-source-proof-header-title proof) 11)
         :header-format (epi-ledger--recovery-source-proof-header-format proof)
         :header-session-id
         (epi-ledger--recovery-copy-plan-string
          (epi-ledger--recovery-source-proof-header-session-id proof) 36)
         :header-created-at
         (epi-ledger--recovery-copy-plan-string
          (epi-ledger--recovery-source-proof-header-created-at proof)
          epi-header-value-byte-limit)
         :header-project-root
         (epi-ledger--recovery-copy-plan-string
          (epi-ledger--recovery-source-proof-header-project-root proof)
          epi-header-value-byte-limit)
         :header-coding-system
         (epi-ledger--recovery-copy-plan-string
          (epi-ledger--recovery-source-proof-header-coding-system proof) 10)
         :header-hash
         (epi-ledger--recovery-copy-plan-string
          (epi-ledger--recovery-source-proof-header-hash proof) 64)
         :validated-end
         (epi-ledger--recovery-source-proof-validated-end proof)
         :valid-prefix-head
         (epi-ledger--recovery-copy-plan-string
          (epi-ledger--recovery-source-proof-valid-prefix-head proof) 64)
         :next-sequence
         (epi-ledger--recovery-source-proof-next-sequence proof)
         :fragment-offset
         (epi-ledger--recovery-source-proof-fragment-offset proof)
         :fragment-size
         (epi-ledger--recovery-source-proof-fragment-size proof)
         :fragment-hash
         (epi-ledger--recovery-copy-plan-string
          (epi-ledger--recovery-source-proof-fragment-hash proof) 64)
         :record-count
         (epi-ledger--recovery-source-proof-record-count proof)
         :record-proofs nil))
    (error (epi-ledger--recovery-reseal-plan-changed))))

(defun epi-ledger--recovery-validate-source-proof-scalars (proof)
  "Validate the already owned scalar fields in source PROOF."
  (let ((source-size (epi-ledger--recovery-source-proof-source-size proof))
        (header-format (epi-ledger--recovery-source-proof-header-format proof))
        (validated-end (epi-ledger--recovery-source-proof-validated-end proof))
        (next-sequence (epi-ledger--recovery-source-proof-next-sequence proof))
        (fragment-offset (epi-ledger--recovery-source-proof-fragment-offset proof))
        (fragment-size (epi-ledger--recovery-source-proof-fragment-size proof))
        (record-count (epi-ledger--recovery-source-proof-record-count proof))
        (file-identity (epi-ledger--recovery-source-proof-file-identity proof)))
    (unless
        (and
         (epi-ledger--recovery-bounded-unsigned-p source-size)
         (> source-size 0)
         (integerp header-format) (= header-format 1)
         (epi-ledger--recovery-bounded-unsigned-p validated-end)
         (epi-ledger--recovery-bounded-unsigned-p fragment-offset)
         (= validated-end fragment-offset)
         (epi-ledger--recovery-bounded-unsigned-p fragment-size)
         (> fragment-size 0)
         (<= fragment-size epi-recovery-fragment-byte-limit)
         (= (+ fragment-offset fragment-size) source-size)
         (= (plist-get file-identity :size) source-size)
         (equal (epi-ledger--recovery-source-proof-canonical-path proof)
                (plist-get file-identity :path))
         (epi-ledger--recovery-bounded-unsigned-p record-count)
         (> record-count 0)
         (epi-ledger--recovery-bounded-unsigned-p next-sequence)
         (= next-sequence (1+ record-count))
         (epi-ledger--canonical-lock-ledger-path-p
          (epi-ledger--recovery-source-proof-canonical-path proof))
         (equal (epi-ledger--recovery-source-proof-header-title proof)
                "Epi session")
         (epi-ledger--uuid-p
          (epi-ledger--recovery-source-proof-header-session-id proof))
         (epi-ledger--timestamp-p
          (epi-ledger--recovery-source-proof-header-created-at proof))
         (stringp
          (epi-ledger--recovery-source-proof-header-project-root proof))
         (equal
          (epi-ledger--recovery-source-proof-header-coding-system proof)
          "utf-8-unix")
         (epi-ledger--hash-p
          (epi-ledger--recovery-source-proof-header-hash proof))
         (epi-ledger--hash-p
          (epi-ledger--recovery-source-proof-valid-prefix-head proof))
         (epi-ledger--hash-p
          (epi-ledger--recovery-source-proof-fragment-hash proof)))
      (epi-ledger--recovery-reseal-plan-changed))
    proof))

(defun epi-ledger--recovery-copy-plan
    (plan work &optional captured-authority snapshot-only)
  "Return an ownership snapshot of recovery PLAN, charging WORK.
CAPTURED-AUTHORITY, when non-nil, supplies a prior callback-free scalar
snapshot instead of reading PLAN.  When SNAPSHOT-ONLY is non-nil, return that
scalar snapshot before charging WORK or copying the linear proof graph."
  (unless
      (or captured-authority
          (epi-ledger--recovery-exact-record-p
           plan #'epi-ledger--recovery-reseal-plan-p
           epi-ledger--recovery-reseal-plan-record-size))
    (epi-ledger--recovery-reseal-plan-changed))
  (let* ((captured
          (or
           captured-authority
           (condition-case nil
               (let ((gc-cons-threshold most-positive-fixnum))
                 (let* ((original-source-proof
                        (epi-ledger--recovery-reseal-plan-source-proof plan))
                       (source-proof
                        (epi-ledger--recovery-copy-source-proof-scalars
                         original-source-proof))
                       (original-record-proofs
                        (epi-ledger--recovery-source-proof-record-proofs
                         original-source-proof))
                   (origin-payload
                        (epi-ledger--snapshot-canonical-value
                         (epi-ledger--recovery-reseal-plan-origin-payload plan)
                         epi-record-json-byte-limit 'record-json-byte-limit))
                   (copy
                    (epi-ledger--make-recovery-reseal-plan
                     :source-proof source-proof
                     :destination-session-id
                     (epi-ledger--recovery-copy-plan-string
                      (epi-ledger--recovery-reseal-plan-destination-session-id
                       plan)
                      36)
                     :origin-id
                     (epi-ledger--recovery-copy-plan-string
                      (epi-ledger--recovery-reseal-plan-origin-id plan)
                      36)
                     :origin-at
                     (epi-ledger--recovery-copy-plan-string
                      (epi-ledger--recovery-reseal-plan-origin-at plan)
                      epi-record-json-byte-limit)
                     :origin-payload origin-payload
                     :source-evidence-sha256
                     (epi-ledger--recovery-copy-plan-string
                      (epi-ledger--recovery-reseal-plan-source-evidence-sha256
                       plan)
                      64)
                     :destination-header-sha256
                     (epi-ledger--recovery-copy-plan-string
                      (epi-ledger--recovery-reseal-plan-destination-header-sha256
                       plan)
                      64)
                     :destination-header-byte-size
                     (epi-ledger--recovery-reseal-plan-destination-header-byte-size
                      plan)
                     :destination-prefix-head
                     (epi-ledger--recovery-copy-plan-string
                      (epi-ledger--recovery-reseal-plan-destination-prefix-head
                       plan)
                      64)
                     :final-head
                     (epi-ledger--recovery-copy-plan-string
                      (epi-ledger--recovery-reseal-plan-final-head plan)
                      64)
                     :origin-frame-byte-size
                     (epi-ledger--recovery-reseal-plan-origin-frame-byte-size
                      plan)
                     :source-record-count
                     (epi-ledger--recovery-reseal-plan-source-record-count plan)
                     :output-record-count
                     (epi-ledger--recovery-reseal-plan-output-record-count plan)
                     :byte-size
                     (epi-ledger--recovery-reseal-plan-byte-size plan)))
                   (scalar-strings
                    (list
                     (epi-ledger--recovery-source-proof-canonical-path
                      source-proof)
                     (epi-ledger--recovery-source-proof-header-title
                      source-proof)
                     (epi-ledger--recovery-source-proof-header-session-id
                      source-proof)
                     (epi-ledger--recovery-source-proof-header-created-at
                      source-proof)
                     (epi-ledger--recovery-source-proof-header-project-root
                      source-proof)
                     (epi-ledger--recovery-source-proof-header-coding-system
                      source-proof)
                     (epi-ledger--recovery-source-proof-header-hash source-proof)
                     (epi-ledger--recovery-source-proof-valid-prefix-head
                      source-proof)
                     (epi-ledger--recovery-source-proof-fragment-hash
                      source-proof)
                     (epi-ledger--recovery-reseal-plan-destination-session-id
                      copy)
                     (epi-ledger--recovery-reseal-plan-origin-id copy)
                     (epi-ledger--recovery-reseal-plan-origin-at copy)
                     (epi-ledger--recovery-reseal-plan-source-evidence-sha256
                      copy)
                     (epi-ledger--recovery-reseal-plan-destination-header-sha256
                      copy)
                     (epi-ledger--recovery-reseal-plan-destination-prefix-head
                      copy)
                     (epi-ledger--recovery-reseal-plan-final-head copy))))
                   (list copy source-proof original-record-proofs
                         scalar-strings)))
             (error (epi-ledger--recovery-reseal-plan-changed)))))
         (copy (nth 0 captured))
         (source-proof (nth 1 captured))
         (original-record-proofs (nth 2 captured))
         (scalar-strings (nth 3 captured)))
    (if snapshot-only
        captured
      ;; No cooperative callback runs until every scalar that authenticates
      ;; the output has been detached from the caller-owned plan.  The linear
      ;; proof graph can then be copied incrementally because every changed
      ;; proof is checked against those frozen source and destination bindings.
      (epi-ledger--recovery-validate-source-proof-scalars source-proof)
      (let ((header-size
           (epi-ledger--recovery-reseal-plan-destination-header-byte-size copy))
          (origin-size
           (epi-ledger--recovery-reseal-plan-origin-frame-byte-size copy))
          (source-count
           (epi-ledger--recovery-reseal-plan-source-record-count copy))
          (output-count
           (epi-ledger--recovery-reseal-plan-output-record-count copy))
          (byte-size (epi-ledger--recovery-reseal-plan-byte-size copy)))
      (unless
          (and
           (epi-ledger--uuid-p
            (epi-ledger--recovery-reseal-plan-destination-session-id copy))
           (epi-ledger--uuid-p
            (epi-ledger--recovery-reseal-plan-origin-id copy))
           (epi-ledger--timestamp-p
            (epi-ledger--recovery-reseal-plan-origin-at copy))
           (epi-ledger--hash-p
            (epi-ledger--recovery-reseal-plan-source-evidence-sha256 copy))
           (epi-ledger--hash-p
            (epi-ledger--recovery-reseal-plan-destination-header-sha256 copy))
           (epi-ledger--hash-p
            (epi-ledger--recovery-reseal-plan-destination-prefix-head copy))
           (epi-ledger--hash-p
            (epi-ledger--recovery-reseal-plan-final-head copy))
           (epi-ledger--recovery-bounded-unsigned-p header-size)
           (> header-size 0) (<= header-size epi-record-frame-byte-limit)
           (epi-ledger--recovery-bounded-unsigned-p origin-size)
           (> origin-size 0) (<= origin-size epi-record-frame-byte-limit)
           (epi-ledger--recovery-bounded-unsigned-p source-count)
           (> source-count 0)
           (= source-count
              (epi-ledger--recovery-source-proof-record-count source-proof))
           (epi-ledger--recovery-bounded-unsigned-p output-count)
           (= output-count (1+ source-count))
           (epi-ledger--recovery-bounded-unsigned-p byte-size)
           (> byte-size (+ header-size origin-size)))
        (epi-ledger--recovery-reseal-plan-changed)))
      (dolist (text scalar-strings)
        (epi-ledger--work-charge-count work (string-bytes text)))
      (setf
       (epi-ledger--recovery-source-proof-record-proofs source-proof)
       (epi-ledger--recovery-copy-record-proofs
        original-record-proofs
        (epi-ledger--recovery-source-proof-record-count source-proof)
        work))
      copy)))

(defun epi-ledger--recovery-snapshot-plan-authority (plan)
  "Capture PLAN's authority-bearing scalars without charging work or yielding."
  (epi-ledger--recovery-copy-plan plan nil nil t))

(defun epi-ledger--recovery-validate-copied-plan (plan work)
  "Close copied recovery PLAN before output and return its sealed origin.
WORK charges the iterative proof walk.  The returned frame is private owned
data and is not published until the source pass has matched the same plan."
  (condition-case nil
      (let* ((source-proof
              (epi-ledger--recovery-reseal-plan-source-proof plan))
             (destination-header
              (let ((epi-ledger--cold-open-validation t))
                (epi-ledger-seal-header
                 :session-id
                 (epi-ledger--recovery-reseal-plan-destination-session-id plan)
                 :created-at
                 (epi-ledger--recovery-source-proof-header-created-at
                  source-proof)
                 :project-root
                 (epi-ledger--recovery-source-proof-header-project-root
                  source-proof))))
             (header-size
              (epi-ledger--header-rendered-byte-size
               (epi-header--raw-session-id destination-header)
               (epi-header--raw-created-at destination-header)
               (epi-header--raw-project-root destination-header)))
             (source-tail
              (epi-ledger--recovery-source-proof-header-hash source-proof))
             (destination-tail (epi-header--raw-hash destination-header))
             (proof-tail
              (epi-ledger--recovery-source-proof-record-proofs source-proof))
             (prefix-size header-size)
             (count 0)
             (records-since-yield 0))
        (unless
            (and
             (equal
              destination-tail
              (epi-ledger--recovery-reseal-plan-destination-header-sha256
               plan))
             (=
              header-size
              (epi-ledger--recovery-reseal-plan-destination-header-byte-size
               plan)))
          (epi-ledger--recovery-reseal-plan-changed))
        (while (consp proof-tail)
          (let* ((proof (car proof-tail))
                 (source-previous
                  (epi-ledger--recovery-record-proof-source-previous-hash
                   proof))
                 (source-hash
                  (epi-ledger--recovery-record-proof-source-hash proof))
                 (destination-hash
                  (epi-ledger--recovery-record-proof-destination-hash proof))
                 (frame-size
                  (epi-ledger--recovery-record-proof-frame-byte-size proof)))
            (unless (equal source-previous source-tail)
              (epi-ledger--recovery-reseal-plan-changed))
            (setq source-tail source-hash
                  destination-tail destination-hash
                  prefix-size (+ prefix-size frame-size)
                  count (1+ count)
                  records-since-yield (1+ records-since-yield)
                  proof-tail (cdr proof-tail))
            (unless (epi-ledger--recovery-bounded-unsigned-p prefix-size)
              (epi-ledger--recovery-reseal-plan-changed))
            (epi-ledger--work-charge-count work 4)
            (when (>= records-since-yield epi-ledger-work-record-limit)
              (epi-ledger--work-yield work)
              (setq records-since-yield 0))))
        (unless
            (and
             (null proof-tail)
             (= count
                (epi-ledger--recovery-reseal-plan-source-record-count plan))
             (equal
              source-tail
              (epi-ledger--recovery-source-proof-valid-prefix-head
               source-proof))
             (equal
              destination-tail
              (epi-ledger--recovery-reseal-plan-destination-prefix-head plan)))
          (epi-ledger--recovery-reseal-plan-changed))
        (let* ((origin-payload
                (epi-ledger--recovery-origin-payload
                 source-proof destination-tail))
               (origin-digest
                (epi-ledger--object-value
                 origin-payload "source_evidence_sha256")))
          (unless
              (and
               (equal
                origin-digest
                (epi-ledger--recovery-reseal-plan-source-evidence-sha256 plan))
               (equal
                (epi-ledger--jcs-encode origin-payload)
                (epi-ledger--jcs-encode
                 (epi-ledger--recovery-reseal-plan-origin-payload plan))))
            (epi-ledger--recovery-reseal-plan-changed))
          (let* ((origin-result
                  (epi-ledger--recovery-seal-origin
                   origin-payload
                   (epi-ledger--recovery-reseal-plan-origin-id plan)
                   (epi-ledger--recovery-reseal-plan-origin-at plan)
                   destination-tail
                   (epi-ledger--recovery-source-proof-next-sequence
                    source-proof)
                   t))
                 (origin-record (plist-get origin-result :record))
                 (origin-frame (plist-get origin-result :frame))
                 (origin-size (plist-get origin-result :frame-byte-size)))
            (unless
                (and
                 (equal
                  (epi-record--raw-previous-hash origin-record)
                  destination-tail)
                 (equal
                  (epi-record--raw-hash origin-record)
                  (epi-ledger--recovery-reseal-plan-final-head plan))
                 (=
                  origin-size
                  (epi-ledger--recovery-reseal-plan-origin-frame-byte-size
                   plan))
                 (=
                  (1+ count)
                  (epi-ledger--recovery-reseal-plan-output-record-count plan))
                 (=
                  (+ prefix-size origin-size)
                  (epi-ledger--recovery-reseal-plan-byte-size plan)))
              (epi-ledger--recovery-reseal-plan-changed))
            origin-frame)))
    (error (epi-ledger--recovery-reseal-plan-changed))))

(defun epi-ledger--recovery-require-source-pass-summary (pass plan)
  "Require PASS to match the complete source-prefix summary in PLAN."
  (unless
      (and
       (equal
        (plist-get pass :header-sha256)
        (epi-ledger--recovery-reseal-plan-destination-header-sha256 plan))
       (=
        (plist-get pass :header-byte-size)
        (epi-ledger--recovery-reseal-plan-destination-header-byte-size plan))
       (equal
        (plist-get pass :destination-prefix-head)
        (epi-ledger--recovery-reseal-plan-destination-prefix-head plan))
       (=
        (plist-get pass :source-record-count)
        (epi-ledger--recovery-reseal-plan-source-record-count plan))
       (=
        (plist-get pass :byte-size)
        (- (epi-ledger--recovery-reseal-plan-byte-size plan)
           (epi-ledger--recovery-reseal-plan-origin-frame-byte-size plan))))
    (epi-ledger--recovery-reseal-plan-changed))
  pass)

(defun epi-ledger--recovery-authenticate-copied-plan (inspection plan)
  "Authenticate owned PLAN against every source record in INSPECTION."
  (let* ((source-proof
          (epi-ledger--recovery-reseal-plan-source-proof plan))
         (before-proof
          (epi-ledger--recovery-snapshot-source-proof inspection)))
    (unless
        (epi-ledger--recovery-source-proof-equal-p
         source-proof before-proof)
      (epi-ledger--recovery-reseal-source-changed))
    (let* ((pass
            (epi-ledger--recovery-reseal-source-pass
             inspection source-proof
             (epi-ledger--recovery-reseal-plan-destination-session-id plan)
             plan nil))
           (after-proof
            (epi-ledger--recovery-snapshot-source-proof inspection)))
      (unless
          (epi-ledger--recovery-source-proof-equal-p
           source-proof after-proof)
        (epi-ledger--recovery-reseal-source-changed))
      (epi-ledger--recovery-require-source-pass-summary pass plan))))

(defun epi-ledger--recovery-stream-reseal (inspection plan emit)
  "Stream INSPECTION's exact reseal under PLAN to bounded callback EMIT."
  (unless (epi-ledger--recovery-reseal-plan-p plan)
    (epi-ledger--format-fail 'recovery-reseal-plan-required))
  (unless (functionp emit)
    (epi-ledger--format-fail 'recovery-reseal-emitter-required))
  (epi-ledger--recovery-require-truncated-inspection inspection)
  (epi-ledger--with-operation-work-state
    (let* ((plan
            (epi-ledger--recovery-copy-plan
             plan (epi-ledger--make-work-state)))
           (prepared-origin
            (epi-ledger--recovery-validate-copied-plan
             plan (epi-ledger--make-work-state)))
           (source-proof
            (epi-ledger--recovery-reseal-plan-source-proof plan))
           (current-proof
            (epi-ledger--recovery-snapshot-source-proof inspection)))
      (unless
          (epi-ledger--recovery-source-proof-equal-p
           source-proof current-proof)
        (epi-ledger--recovery-reseal-source-changed))
      (let* ((pass
              (epi-ledger--recovery-reseal-source-pass
               inspection source-proof
               (epi-ledger--recovery-reseal-plan-destination-session-id plan)
               plan emit))
             (after-proof
              (epi-ledger--recovery-snapshot-source-proof inspection)))
        (unless
            (epi-ledger--recovery-source-proof-equal-p
             source-proof after-proof)
          (epi-ledger--recovery-reseal-source-changed))
        (epi-ledger--recovery-require-source-pass-summary pass plan)
        (funcall emit prepared-origin)
        plan))))

(defconst epi-ledger--recovery-manifest-keys
  '("version" "recovery_id" "phase" "fixed_timestamp" "origin_id"
    "source_path" "source_session_id" "source_identity"
    "source_header_sha256" "source_valid_prefix_end"
    "source_valid_prefix_head_sha256" "fragment_offset" "fragment_size"
    "fragment_sha256" "fragment_object" "source_evidence_sha256"
    "source_object_tree_state" "reachable_objects" "destination_path"
    "destination_objects_path" "destination_session_id"
    "destination_header_sha256" "destination_header_byte_size"
    "destination_valid_prefix_head_sha256" "destination_final_head_sha256"
    "origin_frame_byte_size" "source_record_count" "output_record_count"
    "destination_byte_size" "staged_destination_ledger_path"
    "staged_destination_objects_path" "quarantine_root"
    "quarantine_device" "final_quarantine_path" "source_stage_path"
    "staged_source_ledger_path" "staged_source_objects_path"
    "absent_source_objects_marker_path" "directory_mode" "file_mode")
  "Closed structural key order for a version-one recovery manifest.")

(defconst epi-ledger--recovery-manifest-phases
  '("prepared" "objects-transferred" "destination-objects-published"
    "destination-ledger-published" "source-ledger-staged"
    "source-objects-staged" "quarantine-published")
  "Ordered durable phases accepted by a version-one recovery manifest.")

(defconst epi-ledger--recovery-atomic-object-limit 256
  "Maximum reachable objects in one version-one atomic recovery proof.")

(defvar epi-ledger--recovery-phase-barrier-function #'ignore
  "Dynamically bindable callback after one durable recovery phase.")

(defvar epi-ledger--recovery-directory-receipt-receiver nil
  "Legacy direct-call fallback for a verified new-directory receipt.
Trusted orchestration passes a lexical receiver and masks this special.")

(defvar epi-ledger--recovery-file-receipt-receiver nil
  "Legacy direct-call fallback receiving ROLE, PATH, and file identity.
Trusted orchestration passes a lexical receiver and masks this special.")

(defun epi-ledger--recovery-require-atomic-object-count (count)
  "Return COUNT when it fits one atomic recovery authority proof."
  (unless (and (integerp count) (>= count 0))
    (epi-ledger--format-fail 'recovery-object-count-invalid))
  (when (> count epi-ledger--recovery-atomic-object-limit)
    (epi-ledger--limit-fail
     'recovery-atomic-object-limit
     :limit epi-ledger--recovery-atomic-object-limit
     :objects count))
  count)

(defun epi-ledger--recovery-owned-directory-stat (path)
  "Return an ownership-isolated directory stat result for PATH."
  (epi-ledger--copy-tree-and-strings
   (funcall epi-ledger--directory-stat-function
            (substring-no-properties path))))

(defun epi-ledger--recovery-existing-directory-anchor (path)
  "Return the nearest existing directory identity at or above PATH."
  (let ((probe (epi-ledger--resolve-local-directory-path path))
        identity done)
    (while (not done)
      (setq identity
            (condition-case nil
                (epi-ledger--recovery-owned-directory-stat probe)
              (error
               (epi-ledger--fail
                'epi-ledger-conflict 'quarantine-device-unknown))))
      (if identity
          (setq done t)
        (let ((parent
               (directory-file-name (file-name-directory probe))))
          (when (equal parent probe)
            (epi-ledger--fail
             'epi-ledger-conflict 'quarantine-device-unknown))
          (setq probe parent))))
    identity))

(defun epi-ledger--recovery-name-kind (path)
  "Return nil, `file', `directory', or `other' for exact local PATH."
  (condition-case nil
      (let* ((file-name-handler-alist nil)
             (attributes
              (file-attributes (substring-no-properties path) 'string))
             (type (and attributes (file-attribute-type attributes))))
        (cond ((null attributes) nil)
              ((null type) 'file)
              ((eq type t) 'directory)
              (t 'other)))
    (error (epi-ledger--fail 'epi-ledger-conflict 'recovery-path-conflict))))

(defun epi-ledger--recovery-require-absent-name (path code)
  "Require exact local PATH to be absent, otherwise signal CODE."
  (when (epi-ledger--recovery-name-kind path)
    (epi-ledger--fail 'epi-ledger-conflict code :path path)))

(defun epi-ledger--recovery-directory-path-p (path)
  "Return non-nil when PATH is a canonical absolute directory spelling."
  (and (stringp path)
       (not (string-empty-p path))
       (not (string-match-p "[\0\r\n]" path))
       (file-name-absolute-p path)
       (not (directory-name-p path))
       (let ((file-name-handler-alist nil))
         (equal path (directory-file-name (expand-file-name path))))))

(defun epi-ledger--recovery-layout
    (source-proof plan recovery-id destination quarantine-directory)
  "Resolve the immutable filesystem layout for one recovery transaction.
SOURCE-PROOF and PLAN bind the source and resealed output.  RECOVERY-ID
names the transaction.  DESTINATION and QUARANTINE-DIRECTORY optionally
override their deterministic defaults."
  (epi-ledger--require-uuid recovery-id "recovery_id")
  (let* ((source
          (epi-ledger--resolve-local-write-path
           (epi-ledger--recovery-source-proof-canonical-path source-proof)))
         (source-session-id
          (epi-ledger--recovery-source-proof-header-session-id source-proof))
         (destination-session-id
          (epi-ledger--recovery-reseal-plan-destination-session-id plan))
         (source-parent
          (directory-file-name (file-name-directory source)))
         (session-root
          (epi-ledger--resolve-local-directory-path epi-session-directory))
         (default-source
          (epi-ledger--resolve-local-write-path
           (expand-file-name
            (concat source-session-id ".org")
            (file-name-as-directory session-root))))
         (destination-input
          (or destination
              (expand-file-name
               (concat destination-session-id ".org")
               (file-name-as-directory source-parent))))
         (destination-input-parent
          (directory-file-name (file-name-directory destination-input)))
         (_destination-parent-observed
          (unless
              (condition-case nil
                  (epi-ledger--recovery-owned-directory-stat
                   destination-input-parent)
                (error nil))
            (epi-ledger--fail
             'epi-ledger-conflict 'recovery-path-conflict)))
         (destination-path
          (epi-ledger--resolve-local-write-path destination-input))
         (source-objects-name (concat source ".objects"))
         (_source-objects-not-link
          (when (condition-case nil
                    (let ((file-name-handler-alist nil))
                      (file-symlink-p source-objects-name))
                  (file-error t))
            (epi-ledger--fail
             'epi-ledger-conflict 'recovery-path-conflict)))
         (source-objects
          (epi-ledger--resolve-local-directory-path source-objects-name))
         (destination-objects
          (epi-ledger--resolve-local-directory-path
           (concat destination-path ".objects")))
         (quarantine-root
          (epi-ledger--resolve-local-directory-path
           (or quarantine-directory
               (if (equal source default-source)
                   (expand-file-name
                    "quarantine" (file-name-as-directory session-root))
                 (expand-file-name
                  ".epi-quarantine"
                  (file-name-as-directory source-parent))))))
         (source-parent-identity
          (condition-case nil
              (epi-ledger--recovery-owned-directory-stat source-parent)
            (error nil)))
         (quarantine-anchor
          (epi-ledger--recovery-existing-directory-anchor quarantine-root))
         (quarantine-anchor-path
          (and quarantine-anchor (plist-get quarantine-anchor :path)))
         (quarantine-root-identity
          (pcase (epi-ledger--recovery-name-kind quarantine-root)
            ('nil nil)
            ('directory
             (epi-ledger--recovery-owned-directory-stat quarantine-root))
            (_ (epi-ledger--fail
                'epi-ledger-conflict 'recovery-path-conflict))))
         (control-name
          (expand-file-name
           ".epi-recovery" (file-name-as-directory quarantine-root)))
         (_control-not-link
          (when (condition-case nil
                    (let ((file-name-handler-alist nil))
                      (file-symlink-p control-name))
                  (file-error t))
            (epi-ledger--fail
             'epi-ledger-conflict 'recovery-path-conflict)))
         (control-directory
          (epi-ledger--resolve-local-directory-path control-name))
         (control-identity
          (pcase (epi-ledger--recovery-name-kind control-directory)
            ('nil nil)
            ('directory
             (epi-ledger--recovery-owned-directory-stat control-directory))
            (_ (epi-ledger--fail
                'epi-ledger-conflict 'recovery-path-conflict))))
         (source-device
          (plist-get
           (epi-ledger--recovery-source-proof-file-identity source-proof)
           :device))
         (parent-device (plist-get source-parent-identity :device))
         (quarantine-device (plist-get quarantine-anchor :device))
         (fold-case
          (or (file-name-case-insensitive-p source-parent)
              (and quarantine-anchor-path
                   (file-name-case-insensitive-p quarantine-anchor-path))))
         (suffix (concat "epi-recovery-" recovery-id))
         (staged-destination-ledger
          (epi-ledger--hidden-sibling destination-path suffix))
         (staged-destination-objects
          (epi-ledger--hidden-sibling destination-objects suffix))
         (transaction
          (epi-ledger--resolve-local-directory-path
           (expand-file-name
            recovery-id
            (file-name-as-directory control-directory))))
         (manifest
          (epi-ledger--resolve-local-write-path
           (expand-file-name "manifest.jcs"
                             (file-name-as-directory transaction))))
         (manifest-temporary
          (epi-ledger--hidden-sibling manifest suffix))
         (source-stage
          (epi-ledger--resolve-local-directory-path
           (expand-file-name "source-stage"
                             (file-name-as-directory transaction))))
         (staged-source-ledger
          (epi-ledger--resolve-local-write-path
           (expand-file-name (file-name-nondirectory source)
                             (file-name-as-directory source-stage))))
         (staged-source-objects
          (epi-ledger--resolve-local-directory-path
           (concat staged-source-ledger ".objects")))
         (absent-marker
          (epi-ledger--resolve-local-write-path
           (expand-file-name "absent-source-objects.jcs"
                             (file-name-as-directory source-stage))))
         (final-quarantine
          (epi-ledger--resolve-local-directory-path
           (expand-file-name
            (concat source-session-id "-"
                    (epi-ledger--recovery-reseal-plan-origin-at plan))
            (file-name-as-directory quarantine-root))))
         (exclusive-paths
          (list destination-path destination-objects
                staged-destination-ledger staged-destination-objects
                transaction manifest manifest-temporary source-stage
                staged-source-ledger staged-source-objects absent-marker
                final-quarantine)))
    (unless (and source-parent-identity
                 (stringp quarantine-anchor-path)
                 (integerp source-device)
                 (integerp parent-device)
                 (integerp quarantine-device))
      (epi-ledger--fail
       'epi-ledger-conflict 'quarantine-device-unknown))
    (unless (and (= source-device parent-device)
                 (= source-device quarantine-device))
      (epi-ledger--fail 'epi-ledger-conflict 'quarantine-cross-device))
    (epi-ledger--recovery-require-separated-top-level-paths
     (list source source-objects destination-path destination-objects
           staged-destination-ledger staged-destination-objects
           quarantine-root)
     fold-case)
    (when (or (equal source destination-path)
              (equal source source-objects))
      (epi-ledger--fail 'epi-ledger-conflict 'recovery-path-conflict))
    (epi-ledger--recovery-require-distinct-paths exclusive-paths fold-case)
    (dolist (path exclusive-paths)
      (epi-ledger--recovery-require-absent-name
       path (if (member path (list destination-path destination-objects))
                'recovery-destination-exists
              'recovery-path-conflict)))
    (epi-ledger--make-recovery-layout
     :source-path source
     :source-objects-path source-objects
     :destination-path destination-path
     :destination-objects-path destination-objects
     :staged-destination-ledger-path staged-destination-ledger
     :staged-destination-objects-path staged-destination-objects
     :quarantine-root quarantine-root
     :quarantine-device quarantine-device
     :quarantine-anchor-path
     (substring-no-properties quarantine-anchor-path)
     :quarantine-anchor-identity quarantine-anchor
     :quarantine-root-identity quarantine-root-identity
     :control-directory control-directory
     :control-identity control-identity
     :transaction-directory transaction
     :manifest-path manifest
     :manifest-temporary-path manifest-temporary
     :source-stage-path source-stage
     :staged-source-ledger-path staged-source-ledger
     :staged-source-objects-path staged-source-objects
     :absent-source-objects-marker-path absent-marker
     :final-quarantine-path final-quarantine)))

(defun epi-ledger--recovery-destination-parent-path (layout)
  "Return the one canonical parent shared by LAYOUT's destination names."
  (let* ((paths
          (list
           (epi-ledger--recovery-layout-raw-destination-path layout)
           (epi-ledger--recovery-layout-raw-destination-objects-path layout)
           (epi-ledger--recovery-layout-raw-staged-destination-ledger-path
            layout)
           (epi-ledger--recovery-layout-raw-staged-destination-objects-path
            layout)))
         (parents
          (mapcar
           (lambda (path)
             (directory-file-name (file-name-directory path)))
           paths))
         (parent (car parents)))
    (unless (and (epi-ledger--recovery-directory-path-p parent)
                 (seq-every-p (lambda (candidate) (equal parent candidate))
                              (cdr parents)))
      (epi-ledger--fail 'epi-ledger-conflict 'recovery-path-conflict))
    (substring-no-properties parent)))

(defun epi-ledger--recovery-capture-destination-parent (layout)
  "Capture LAYOUT's stable destination-parent identity through public seams."
  (let* ((path (epi-ledger--recovery-destination-parent-path layout))
         (first (epi-ledger--recovery-owned-directory-stat path))
         (second (epi-ledger--recovery-owned-directory-stat path)))
    (unless (and first second (equal first second)
                 (equal path (plist-get second :path))
                 (integerp (plist-get second :device))
                 (plist-member second :inode))
      (epi-ledger--fail 'epi-ledger-conflict 'recovery-path-conflict))
    (epi-ledger--copy-tree-and-strings second)))

(defun epi-ledger--recovery-close-destination-parent-raw
    (layout expected)
  "Raw-close LAYOUT's destination parent against caller-held EXPECTED."
  (let* ((path (epi-ledger--recovery-destination-parent-path layout))
         (owned (epi-ledger--recovery-copy-directory-identity expected))
         (device (and (listp owned) (plist-get owned :device))))
    (unless (and (integerp device)
                 (equal path (plist-get owned :path)))
      (epi-ledger--fail 'epi-ledger-conflict 'recovery-path-conflict))
    (epi-ledger--recovery-require-bound-directory-raw
     path owned device)))

(defun epi-ledger--recovery-reprove-destination-parent-raw
    (preflight layout)
  "Raw-reprove PREFLIGHT's destination-parent authority for LAYOUT."
  (epi-ledger--recovery-close-destination-parent-raw
   layout
   (epi-ledger--recovery-preflight-raw-destination-parent-identity
    preflight)))

(defun epi-ledger--recovery-source-object-tree-state (layout)
  "Return LAYOUT's source object state and exact directory identity."
  (pcase (epi-ledger--recovery-name-kind
          (epi-ledger--recovery-layout-raw-source-objects-path layout))
    ('directory
     (let ((identity
            (condition-case nil
                (epi-ledger--recovery-owned-directory-stat
                 (epi-ledger--recovery-layout-raw-source-objects-path layout))
              (error nil))))
       (unless (and identity
                    (= (or (plist-get identity :device) -1)
                       (epi-ledger--recovery-layout-raw-quarantine-device
                        layout)))
         (epi-ledger--fail
          'epi-ledger-conflict 'quarantine-cross-device))
       (list :state 'present :identity identity)))
    ('nil (list :state 'absent :identity nil))
    (_ (epi-ledger--fail
        'epi-ledger-conflict 'recovery-path-conflict))))

(defun epi-ledger--recovery-object-reference (record)
  "Return RECORD's owned typed recovery object reference, or nil."
  (when (eq (epi-record--raw-type record) 'recovery-origin)
    (let ((reference
           (condition-case nil
               (let* ((gc-cons-threshold most-positive-fixnum)
                      (object
                       (epi-ledger--object-value
                        (epi-record--raw-payload record) "fragment_object")))
                 (list
                  (cons "hash"
                        (substring-no-properties
                         (epi-ledger--object-value object "hash")))
                  (cons "size" (epi-ledger--object-value object "size"))
                  (cons "media_type"
                        (substring-no-properties
                         (epi-ledger--object-value object "media_type")))
                  (cons "role"
                        (substring-no-properties
                         (epi-ledger--object-value object "role")))))
             (error (epi-ledger--recovery-reseal-source-changed)))))
      (epi-ledger--validate-object-ref reference)
      reference)))

(defun epi-ledger--recovery-reachable-objects
    (inspection source-proof layout state)
  "Return verified historical references and identities for INSPECTION.
SOURCE-PROOF binds its record count.  The result is a two-element list
containing parallel vectors.  LAYOUT names the source object tree, whose
verified presence is STATE."
  (let ((work (epi-ledger--make-work-state))
        (by-hash (make-hash-table :test #'equal))
        (count 0)
        references)
    (epi-ledger--recovery-record-source-each
     (epi-ledger--inspection-raw-record-index inspection)
     (epi-ledger--recovery-source-proof-record-count source-proof)
     (lambda (record)
       (let ((reference (epi-ledger--recovery-object-reference record)))
         (when reference
           (let* ((hash (epi-ledger--object-value reference "hash"))
                  (prior (gethash hash by-hash)))
             (cond
              ((null prior)
               (setq count (1+ count))
               (epi-ledger--recovery-require-atomic-object-count count)
               (puthash hash reference by-hash)
               (push reference references))
              ((not (equal prior reference))
               (epi-ledger--fail
                'epi-ledger-conflict
                'recovery-object-reference-conflict)))))))
     work)
    (setq references
          (epi-ledger--work-sort-list-to-vector
           references
           (lambda (left right)
             (string< (epi-ledger--object-value left "hash")
                      (epi-ledger--object-value right "hash")))
           work 'recovery-reachable-objects))
    (epi-ledger--recovery-require-atomic-object-count (length references))
    (when (and (> (length references) 0) (eq state 'absent))
      (epi-ledger--fail 'epi-missing-object 'object-missing))
    (let ((identities (make-vector (length references) nil)))
      (dotimes (index (length references))
        (let* ((reference (aref references index))
               (verified
                (epi-ledger--object-read-verified-state
                 (epi-ledger--object-path-for-ledger-path
                  (epi-ledger--recovery-layout-raw-source-path layout)
                  (epi-ledger--object-value reference "hash"))
                 (epi-ledger--object-value reference "size")
                 (epi-ledger--object-value reference "hash")
                 'missing)))
          (aset identities index
                (epi-ledger--copy-tree-and-strings
                 (plist-get verified :identity)))))
      (list references identities))))

(defun epi-ledger--recovery-copy-reachable-object-identities (identities)
  "Return an ownership-disjoint copy of reachable object IDENTITIES."
  (unless (vectorp identities)
    (error "Reachable object identities must be a vector"))
  (let ((copy (make-vector (length identities) nil)))
    (dotimes (index (length identities))
      (aset copy index
            (epi-ledger--recovery-copy-file-identity
             (aref identities index))))
    copy))

(defun epi-ledger--recovery-close-reachable-object-identities
    (references identities layout)
  "Close parallel REFERENCES and IDENTITIES against source LAYOUT."
  (unless (and (vectorp references) (vectorp identities)
               (= (length references) (length identities)))
    (error "Incoherent reachable object identity proof"))
  (let ((source (epi-ledger--recovery-layout-raw-source-path layout))
        (device (epi-ledger--recovery-layout-raw-quarantine-device layout))
        (work (epi-ledger--make-work-state))
        (closed (make-vector (length identities) nil)))
    (dotimes (index (length references))
      (let* ((reference (aref references index))
             (hash (epi-ledger--object-value reference "hash"))
             (size (epi-ledger--object-value reference "size"))
             (expected-path
              (epi-ledger--object-path-for-ledger-path source hash)))
        (epi-ledger--work-charge-count
         work (+ (string-bytes hash) (string-bytes expected-path)))
        (let ((identity
               (epi-ledger--recovery-copy-file-identity
                (aref identities index))))
        (unless (and (listp identity)
                     (equal expected-path (plist-get identity :path))
                     (equal device (plist-get identity :device))
                     (plist-member identity :inode)
                     (integerp (plist-get identity :links))
                     (integerp (plist-get identity :size))
                     (= size (plist-get identity :size)))
          (error "Invalid reachable object identity"))
          (aset closed index identity))))
    closed))

(defun epi-ledger--recovery-manifest-object
    (source-proof plan recovery-id layout source-object-state reachable)
  "Return the closed prepared-manifest object for recovery inputs.
SOURCE-PROOF, PLAN, RECOVERY-ID, and LAYOUT bind the transaction.
SOURCE-OBJECT-STATE records whether the source object tree exists, and
REACHABLE is the verified historical-object reference vector."
  (let* ((origin-payload
          (epi-ledger--recovery-reseal-plan-origin-payload plan))
         (fragment-object
          (copy-tree
           (epi-ledger--object-value origin-payload "fragment_object") t)))
    (list
     (cons "version" 1)
     (cons "recovery_id" recovery-id)
     (cons "phase" "prepared")
     (cons "fixed_timestamp"
           (epi-ledger--recovery-reseal-plan-origin-at plan))
     (cons "origin_id" (epi-ledger--recovery-reseal-plan-origin-id plan))
     (cons "source_path"
           (epi-ledger--recovery-layout-raw-source-path layout))
     (cons "source_session_id"
           (epi-ledger--recovery-source-proof-header-session-id source-proof))
     (cons "source_identity"
           (epi-ledger--lock-file-identity-object
            (epi-ledger--recovery-source-proof-file-identity source-proof)))
     (cons "source_header_sha256"
           (epi-ledger--recovery-source-proof-header-hash source-proof))
     (cons "source_valid_prefix_end"
           (epi-ledger--recovery-source-proof-validated-end source-proof))
     (cons "source_valid_prefix_head_sha256"
           (epi-ledger--recovery-source-proof-valid-prefix-head source-proof))
     (cons "fragment_offset"
           (epi-ledger--recovery-source-proof-fragment-offset source-proof))
     (cons "fragment_size"
           (epi-ledger--recovery-source-proof-fragment-size source-proof))
     (cons "fragment_sha256"
           (epi-ledger--recovery-source-proof-fragment-hash source-proof))
     (cons "fragment_object" fragment-object)
     (cons "source_evidence_sha256"
           (epi-ledger--recovery-reseal-plan-source-evidence-sha256 plan))
     (cons "source_object_tree_state" (symbol-name source-object-state))
     (cons "reachable_objects" reachable)
     (cons "destination_path"
           (epi-ledger--recovery-layout-raw-destination-path layout))
     (cons "destination_objects_path"
           (epi-ledger--recovery-layout-raw-destination-objects-path layout))
     (cons "destination_session_id"
           (epi-ledger--recovery-reseal-plan-destination-session-id plan))
     (cons "destination_header_sha256"
           (epi-ledger--recovery-reseal-plan-destination-header-sha256 plan))
     (cons "destination_header_byte_size"
           (epi-ledger--recovery-reseal-plan-destination-header-byte-size plan))
     (cons "destination_valid_prefix_head_sha256"
           (epi-ledger--recovery-reseal-plan-destination-prefix-head plan))
     (cons "destination_final_head_sha256"
           (epi-ledger--recovery-reseal-plan-final-head plan))
     (cons "origin_frame_byte_size"
           (epi-ledger--recovery-reseal-plan-origin-frame-byte-size plan))
     (cons "source_record_count"
           (epi-ledger--recovery-reseal-plan-source-record-count plan))
     (cons "output_record_count"
           (epi-ledger--recovery-reseal-plan-output-record-count plan))
     (cons "destination_byte_size"
           (epi-ledger--recovery-reseal-plan-byte-size plan))
     (cons "staged_destination_ledger_path"
           (epi-ledger--recovery-layout-raw-staged-destination-ledger-path
            layout))
     (cons "staged_destination_objects_path"
           (epi-ledger--recovery-layout-raw-staged-destination-objects-path
            layout))
     (cons "quarantine_root"
           (epi-ledger--recovery-layout-raw-quarantine-root layout))
     (cons "quarantine_device"
           (epi-ledger--unsigned-decimal-string
            (epi-ledger--recovery-layout-raw-quarantine-device layout)
            'quarantine-device))
     (cons "final_quarantine_path"
           (epi-ledger--recovery-layout-raw-final-quarantine-path layout))
     (cons "source_stage_path"
           (epi-ledger--recovery-layout-raw-source-stage-path layout))
     (cons "staged_source_ledger_path"
           (epi-ledger--recovery-layout-raw-staged-source-ledger-path layout))
     (cons "staged_source_objects_path"
           (epi-ledger--recovery-layout-raw-staged-source-objects-path layout))
     (cons "absent_source_objects_marker_path"
           (epi-ledger--recovery-layout-raw-absent-source-objects-marker-path
            layout))
     (cons "directory_mode" #o700)
     (cons "file_mode" #o600))))

(defun epi-ledger--recovery-manifest-invalid ()
  "Signal the stable conflict for a malformed recovery manifest."
  (epi-ledger--fail 'epi-ledger-conflict 'recovery-manifest-invalid))

(defun epi-ledger--recovery-manifest-file (value field)
  "Require VALUE to be a canonical local file spelling for FIELD."
  (epi-ledger--require-canonical-absolute-file value field)
  (unless (equal value (epi-ledger--resolve-local-write-path value))
    (epi-ledger--format-fail 'canonical-file-required :field field))
  value)

(defun epi-ledger--recovery-manifest-directory (value field)
  "Require VALUE to be a canonical local non-trailing directory for FIELD."
  (epi-ledger--require-string value field t)
  (unless (and (epi-ledger--recovery-directory-path-p value)
               (equal value
                      (epi-ledger--resolve-local-directory-path value)))
    (epi-ledger--format-fail 'canonical-directory-required :field field))
  value)

(defun epi-ledger--recovery-manifest-object-reference (value field)
  "Return an owned, schema-ordered recovery object VALUE named FIELD."
  (epi-ledger--validate-object-ref value)
  (let ((size (epi-ledger--object-value value "size")))
    (unless (and (> size 0) (<= size epi-recovery-fragment-byte-limit))
      (epi-ledger--format-fail 'invalid-recovery-fragment :field field)))
  (mapcar (lambda (key)
            (cons key (epi-ledger--object-value value key)))
          '("hash" "size" "media_type" "role")))

(defun epi-ledger--recovery-manifest-reachable (value)
  "Return VALUE as an owned, strictly hash-sorted reference vector."
  (unless (vectorp value)
    (epi-ledger--format-fail 'array-required :field "reachable_objects"))
  (let* ((work (epi-ledger--make-work-state))
         (count (length value))
         (_bounded
          (epi-ledger--recovery-require-atomic-object-count count))
         (result
          (epi-ledger--run-bounded-unit
           'allocate 'recovery-reachable-objects (* 8 count) work
           (lambda () (make-vector count nil))))
         previous)
    (dotimes (index count)
      (epi-ledger--work-charge work 1)
      (let* ((reference
              (epi-ledger--recovery-manifest-object-reference
               (aref value index) "reachable_objects"))
             (hash (epi-ledger--object-value reference "hash")))
        (unless (or (null previous) (string< previous hash))
          (epi-ledger--format-fail
           'recovery-object-order-invalid :field "reachable_objects"))
        (setq previous hash)
        (aset result index reference)))
    result))

(defun epi-ledger--recovery-manifest-pure-hidden-sibling (path suffix)
  "Return canonical PATH's hidden sibling using the owned SUFFIX."
  (let ((file-name-handler-alist nil))
    (expand-file-name
     (concat "." (file-name-nondirectory path) "." suffix)
     (file-name-directory path))))

(defun epi-ledger--recovery-paths-overlap-p (left right &optional fold-case)
  "Return non-nil when canonical LEFT and RIGHT overlap.
FOLD-CASE is non-nil on a case-insensitive filesystem."
  (let ((left-directory (file-name-as-directory left))
        (right-directory (file-name-as-directory right)))
    (or (string-prefix-p left-directory right-directory fold-case)
        (string-prefix-p right-directory left-directory fold-case))))

(defun epi-ledger--recovery-require-separated-top-level-paths
    (paths &optional fold-case)
  "Require every pair in canonical top-level PATHS to be disjoint.
FOLD-CASE is non-nil on a case-insensitive filesystem."
  (let ((left-tail paths))
    (while (consp left-tail)
      (let ((left (car left-tail))
            (right-tail (cdr left-tail)))
        (while (consp right-tail)
          (let ((right (car right-tail)))
            (when (epi-ledger--recovery-paths-overlap-p
                   left right fold-case)
              (epi-ledger--fail
               'epi-ledger-conflict 'recovery-path-conflict)))
          (setq right-tail (cdr right-tail))))
      (setq left-tail (cdr left-tail)))))

(defun epi-ledger--recovery-require-distinct-paths (paths &optional fold-case)
  "Require every pathname in PATHS to be distinct.
FOLD-CASE is non-nil on a case-insensitive filesystem."
  (let ((left-tail paths))
    (while (consp left-tail)
      (let ((left (car left-tail))
            (right-tail (cdr left-tail)))
        (while (consp right-tail)
          (let ((right (car right-tail)))
            (when (and (= (length left) (length right))
                       (string-prefix-p left right fold-case))
              (epi-ledger--fail
               'epi-ledger-conflict 'recovery-path-conflict)))
          (setq right-tail (cdr right-tail))))
      (setq left-tail (cdr left-tail)))))

(defun epi-ledger--recovery-path-set-case-insensitive-p (paths)
  "Return non-nil when an existing parent volume for PATHS folds case."
  (seq-some
   (lambda (path)
     (condition-case nil
         (let ((file-name-handler-alist nil))
           (file-name-case-insensitive-p
            (directory-file-name (file-name-directory path))))
       (file-error nil)))
   paths))

(defun epi-ledger--recovery-manifest-layout (manifest)
  "Return the filesystem layout derived purely from validated MANIFEST."
  (let* ((file-name-handler-alist nil)
         (get (lambda (key) (epi-ledger--object-value manifest key)))
         (source (funcall get "source_path"))
         (source-objects (concat source ".objects"))
         (destination (funcall get "destination_path"))
         (destination-objects (concat destination ".objects"))
         (quarantine (funcall get "quarantine_root"))
         (recovery-id (funcall get "recovery_id"))
         (suffix (concat "epi-recovery-" recovery-id))
         (staged-destination-ledger
          (epi-ledger--recovery-manifest-pure-hidden-sibling
           destination suffix))
         (staged-destination-objects
          (epi-ledger--recovery-manifest-pure-hidden-sibling
           destination-objects suffix))
         (transaction
          (expand-file-name
           recovery-id
           (file-name-as-directory
            (expand-file-name ".epi-recovery"
                              (file-name-as-directory quarantine)))))
         (manifest-path
          (expand-file-name "manifest.jcs"
                            (file-name-as-directory transaction)))
         (source-stage
          (expand-file-name "source-stage"
                            (file-name-as-directory transaction)))
         (staged-source-ledger
          (expand-file-name (file-name-nondirectory source)
                            (file-name-as-directory source-stage)))
         (top-level-paths
          (list source source-objects destination destination-objects
                staged-destination-ledger staged-destination-objects
                quarantine))
         (fold-case
          (epi-ledger--recovery-path-set-case-insensitive-p
           top-level-paths))
         (layout
          (epi-ledger--make-recovery-layout
           :source-path source
           :source-objects-path source-objects
           :destination-path destination
           :destination-objects-path destination-objects
           :staged-destination-ledger-path
           staged-destination-ledger
           :staged-destination-objects-path
           staged-destination-objects
           :quarantine-root quarantine
           :quarantine-device
           (epi-ledger--recovery-parse-bounded-unsigned-decimal
            (funcall get "quarantine_device") 'quarantine-device)
           :transaction-directory transaction
           :manifest-path manifest-path
           :manifest-temporary-path
           (epi-ledger--recovery-manifest-pure-hidden-sibling
            manifest-path suffix)
           :source-stage-path source-stage
           :staged-source-ledger-path staged-source-ledger
           :staged-source-objects-path (concat staged-source-ledger ".objects")
           :absent-source-objects-marker-path
           (expand-file-name "absent-source-objects.jcs"
                             (file-name-as-directory source-stage))
           :final-quarantine-path
           (expand-file-name
            (concat (funcall get "source_session_id") "-"
                    (funcall get "fixed_timestamp"))
            (file-name-as-directory quarantine)))))
    (dolist (binding
             `(("destination_objects_path" .
                ,(epi-ledger--recovery-layout-raw-destination-objects-path
                  layout))
               ("staged_destination_ledger_path" .
                ,(epi-ledger--recovery-layout-raw-staged-destination-ledger-path
                  layout))
               ("staged_destination_objects_path" .
                ,(epi-ledger--recovery-layout-raw-staged-destination-objects-path
                  layout))
               ("final_quarantine_path" .
                ,(epi-ledger--recovery-layout-raw-final-quarantine-path layout))
               ("source_stage_path" .
                ,(epi-ledger--recovery-layout-raw-source-stage-path layout))
               ("staged_source_ledger_path" .
                ,(epi-ledger--recovery-layout-raw-staged-source-ledger-path
                  layout))
               ("staged_source_objects_path" .
                ,(epi-ledger--recovery-layout-raw-staged-source-objects-path
                  layout))
               ("absent_source_objects_marker_path" .
                ,(epi-ledger--recovery-layout-raw-absent-source-objects-marker-path
                  layout))))
      (unless (equal (funcall get (car binding)) (cdr binding))
        (epi-ledger--format-fail
         'recovery-path-binding-mismatch :field (car binding))))
    (epi-ledger--recovery-require-separated-top-level-paths
     top-level-paths fold-case)
    (let ((paths
           (list source source-objects destination destination-objects
                 (epi-ledger--recovery-layout-raw-staged-destination-ledger-path
                  layout)
                 (epi-ledger--recovery-layout-raw-staged-destination-objects-path
                  layout)
                 transaction manifest-path
                 (epi-ledger--recovery-layout-raw-manifest-temporary-path
                  layout)
                 source-stage staged-source-ledger
                 (epi-ledger--recovery-layout-raw-staged-source-objects-path
                  layout)
                 (epi-ledger--recovery-layout-raw-absent-source-objects-marker-path
                  layout)
                 (epi-ledger--recovery-layout-raw-final-quarantine-path
                  layout))))
      (epi-ledger--recovery-require-distinct-paths paths fold-case))
    layout))

(defun epi-ledger--recovery-validate-prepared-manifest-1
    (manifest expected-phase)
  "Validate owned MANIFEST for EXPECTED-PHASE and return schema order."
  (epi-ledger--closed-object
   manifest epi-ledger--recovery-manifest-keys nil "recovery_manifest")
  (let* ((get (lambda (key) (epi-ledger--object-value manifest key)))
         (version (funcall get "version"))
         (recovery-id (funcall get "recovery_id"))
         (phase (funcall get "phase"))
         (fixed-at (funcall get "fixed_timestamp"))
         (origin-id (funcall get "origin_id"))
         (source (funcall get "source_path"))
         (source-session-id (funcall get "source_session_id"))
         (source-end (funcall get "source_valid_prefix_end"))
         (fragment-offset (funcall get "fragment_offset"))
         (fragment-size (funcall get "fragment_size"))
         (destination (funcall get "destination_path"))
         (destination-session-id (funcall get "destination_session_id"))
         (destination-header-size
          (funcall get "destination_header_byte_size"))
         (origin-frame-size (funcall get "origin_frame_byte_size"))
         (source-count (funcall get "source_record_count"))
         (output-count (funcall get "output_record_count"))
         (destination-size (funcall get "destination_byte_size")))
    (unless (and (eq version 1)
                 (member phase epi-ledger--recovery-manifest-phases)
                 (equal phase expected-phase))
      (epi-ledger--format-fail 'recovery-manifest-version-or-phase))
    (dolist (entry `((,recovery-id . "recovery_id")
                     (,origin-id . "origin_id")
                     (,source-session-id . "source_session_id")
                     (,destination-session-id . "destination_session_id")))
      (epi-ledger--require-uuid (car entry) (cdr entry)))
    (unless (epi-ledger--timestamp-p fixed-at)
      (epi-ledger--format-fail
       'invalid-timestamp :field "fixed_timestamp"))
    (epi-ledger--recovery-manifest-file source "source_path")
    (epi-ledger--recovery-manifest-file destination "destination_path")
    (dolist (field '("destination_objects_path"
                     "staged_destination_objects_path" "quarantine_root"
                     "final_quarantine_path" "source_stage_path"
                     "staged_source_objects_path"))
      (epi-ledger--recovery-manifest-directory
       (funcall get field) field))
    (dolist (field '("staged_destination_ledger_path"
                     "staged_source_ledger_path"
                     "absent_source_objects_marker_path"))
      (epi-ledger--recovery-manifest-file
       (funcall get field) field))
    (dolist (field '("source_header_sha256"
                     "source_valid_prefix_head_sha256" "fragment_sha256"
                     "source_evidence_sha256" "destination_header_sha256"
                     "destination_valid_prefix_head_sha256"
                     "destination_final_head_sha256"))
      (epi-ledger--require-hash (funcall get field) field))
    (dolist (entry `((,source-end . "source_valid_prefix_end")
                     (,fragment-offset . "fragment_offset")
                     (,fragment-size . "fragment_size")
                     (,destination-header-size . "destination_header_byte_size")
                     (,origin-frame-size . "origin_frame_byte_size")
                     (,source-count . "source_record_count")
                     (,output-count . "output_record_count")
                     (,destination-size . "destination_byte_size")))
      (epi-ledger--require-nonnegative-integer (car entry) (cdr entry)))
    (unless (and (> source-end 0)
                 (= source-end fragment-offset)
                 (> fragment-size 0)
                 (<= fragment-size epi-recovery-fragment-byte-limit)
                 (epi-ledger--safe-integer-p (+ fragment-offset fragment-size))
                 (> destination-header-size 0)
                 (<= destination-header-size epi-record-frame-byte-limit)
                 (> origin-frame-size 0)
                 (<= origin-frame-size epi-record-frame-byte-limit)
                 (> source-count 0)
                 (= output-count (1+ source-count))
                 (> destination-size
                    (+ destination-header-size origin-frame-size))
                 (not (equal source-session-id destination-session-id)))
      (epi-ledger--format-fail 'recovery-manifest-incoherent))
    (let* ((source-size (+ fragment-offset fragment-size))
           (identity
            (epi-ledger--decode-lock-file-object
             (funcall get "source_identity") source source-size))
           (quarantine-device
            (funcall get "quarantine_device"))
           (device
            (epi-ledger--recovery-parse-bounded-unsigned-decimal
             quarantine-device 'quarantine-device))
           (fragment-object
            (epi-ledger--recovery-manifest-object-reference
             (funcall get "fragment_object") "fragment_object"))
           (state (funcall get "source_object_tree_state"))
           (reachable
            (epi-ledger--recovery-manifest-reachable
             (funcall get "reachable_objects"))))
      (unless (and
                   (seq-every-p
                    #'epi-ledger--recovery-bounded-unsigned-p
                    (mapcar
                     (lambda (field)
                       (epi-ledger--recovery-parse-bounded-unsigned-decimal
                        (epi-ledger--object-value identity field) field))
                     '("device" "inode" "links" "size")))
                   (= 1 (epi-ledger--recovery-parse-bounded-unsigned-decimal
                          (epi-ledger--object-value identity "links") 'links))
                   (= device
                      (epi-ledger--recovery-parse-bounded-unsigned-decimal
                       (epi-ledger--object-value identity "device") 'device))
                   (equal quarantine-device
                          (epi-ledger--object-value identity "device"))
                   (member state '("present" "absent"))
                   (or (equal state "present") (= 0 (length reachable)))
                   (= fragment-size
                      (epi-ledger--object-value fragment-object "size"))
                   (equal (funcall get "fragment_sha256")
                          (epi-ledger--object-value fragment-object "hash"))
                   (= (funcall get "directory_mode") #o700)
                   (= (funcall get "file_mode") #o600))
        (epi-ledger--format-fail 'recovery-manifest-incoherent))
      (let ((payload
             `(("source_path" . ,source)
               ("source_session_id" . ,source-session-id)
               ("source_file_size" . ,source-size)
               ("source_header_sha256" .
                ,(funcall get "source_header_sha256"))
               ("source_valid_prefix_head_sha256" .
                ,(funcall get "source_valid_prefix_head_sha256"))
               ("fragment_offset" . ,fragment-offset)
               ("fragment_sha256" . ,(funcall get "fragment_sha256"))
               ("fragment_size" . ,fragment-size)
               ("fragment_object" . ,fragment-object)
               ("destination_valid_prefix_head_sha256" .
                ,(funcall get "destination_valid_prefix_head_sha256")))))
        (unless (equal (funcall get "source_evidence_sha256")
                       (epi-ledger--recovery-evidence-v1-sha256 payload))
          (epi-ledger--format-fail 'source-evidence-mismatch)))
      (let ((normalized
             (mapcar
              (lambda (key)
                (cons key
                      (cond ((equal key "source_identity") identity)
                            ((equal key "fragment_object") fragment-object)
                            ((equal key "reachable_objects") reachable)
                            (t (funcall get key)))))
              epi-ledger--recovery-manifest-keys)))
        (epi-ledger--recovery-manifest-layout normalized)
        normalized))))

(defun epi-ledger--recovery-validate-manifest (manifest expected-phase)
  "Return a closed MANIFEST snapshot for EXPECTED-PHASE.
Every malformed value maps to the stable recovery-manifest conflict."
  (condition-case condition
      (let ((owned
             (epi-ledger--snapshot-canonical-value
              manifest epi-record-json-byte-limit
              'record-json-byte-limit)))
        (let ((epi-ledger--cold-open-validation t))
          (epi-ledger--recovery-validate-prepared-manifest-1
           owned expected-phase)))
    (epi-ledger-conflict
     (ignore condition)
     (epi-ledger--recovery-manifest-invalid))
    (error (epi-ledger--recovery-manifest-invalid))))

(defun epi-ledger--recovery-validate-prepared-manifest (manifest)
  "Return a closed ownership snapshot of valid prepared MANIFEST."
  (epi-ledger--recovery-validate-manifest manifest "prepared"))

(defun epi-ledger--recovery-manifest-encode (manifest)
  "Validate, own, and encode one closed version-one prepared MANIFEST."
  (epi-ledger--jcs-encode
   (epi-ledger--recovery-validate-prepared-manifest manifest)
   epi-record-json-byte-limit))

(defun epi-ledger--recovery-snapshot-preflight-authority (preflight)
  "Snapshot PREFLIGHT's authoritative manifest, bytes, and plan without yield."
  (unless (epi-ledger--recovery-exact-record-p
           preflight #'epi-ledger--recovery-preflight-p
           epi-ledger--recovery-preflight-record-size)
    (epi-ledger--format-fail 'recovery-preflight-required))
  (condition-case nil
      (let* ((gc-cons-threshold most-positive-fixnum)
             (bytes (epi-ledger--recovery-preflight-raw-manifest-bytes
                     preflight))
             (manifest
              (epi-ledger--snapshot-canonical-value
               (epi-ledger--recovery-preflight-raw-manifest-object preflight)
               epi-record-json-byte-limit 'record-json-byte-limit))
             (reachable
              (epi-ledger--object-value manifest "reachable_objects"))
             (identities
              (epi-ledger--recovery-preflight-raw-reachable-object-identities
               preflight)))
        (unless (and (stringp bytes) (not (multibyte-string-p bytes))
                     (not (epi-ledger--string-has-properties-p bytes))
                     (<= (length bytes) epi-record-json-byte-limit)
                     (vectorp reachable)
                     (vectorp identities)
                     (= (length reachable) (length identities))
                     (<= (length identities)
                         epi-ledger--recovery-atomic-object-limit))
          (error "Invalid private manifest bytes"))
        (list
         manifest
         (substring-no-properties bytes)
         (epi-ledger--recovery-snapshot-plan-authority
          (epi-ledger--recovery-preflight-raw-reseal-plan preflight))
         (let ((identity
                (epi-ledger--recovery-preflight-raw-source-objects-identity
                 preflight)))
           (and identity
                (epi-ledger--recovery-copy-directory-identity identity)))
         (epi-ledger--recovery-copy-reachable-object-identities
          identities)
         (epi-ledger--recovery-copy-directory-identity
          (epi-ledger--recovery-preflight-raw-destination-parent-identity
           preflight))))
    (error (epi-ledger--recovery-manifest-invalid))))

(defun epi-ledger--recovery-close-preflight
    (preflight &optional captured-authority)
  "Return a fully owned, revalidated closure of caller-held PREFLIGHT.
The manifest and reseal plan are authoritative.  Redundant inspection,
layout, ID, state, and reference slots are reconstructed rather than trusted.
CAPTURED-AUTHORITY, when non-nil, is a prior private entry snapshot."
  (let* ((captured
          (or captured-authority
              (epi-ledger--recovery-snapshot-preflight-authority preflight)))
         (manifest-input (nth 0 captured))
         (bytes (nth 1 captured))
         (plan-input (nth 2 captured))
         (source-objects-identity-input (nth 3 captured))
         (reachable-identities-input (nth 4 captured))
         (destination-parent-identity-input (nth 5 captured)))
    (condition-case nil
        (epi-ledger--with-operation-work-state
          (let* ((plan
                 (epi-ledger--recovery-copy-plan
                  nil (epi-ledger--make-work-state) plan-input))
                 (manifest
                  (epi-ledger--recovery-validate-prepared-manifest
                   manifest-input))
                 (_validated-plan
                  (epi-ledger--recovery-validate-copied-plan
                   plan (epi-ledger--make-work-state)))
                 (source-proof
                  (epi-ledger--recovery-reseal-plan-source-proof plan))
                 (layout (epi-ledger--recovery-manifest-layout manifest))
                 (destination-parent-identity
                  (epi-ledger--recovery-close-destination-parent-raw
                   layout destination-parent-identity-input))
                 (recovery-id
                  (epi-ledger--object-value manifest "recovery_id"))
                 (state-name
                  (epi-ledger--object-value
                   manifest "source_object_tree_state"))
                 (state (if (equal state-name "present") 'present 'absent))
                 (source-objects-identity
                  (and source-objects-identity-input
                       (epi-ledger--recovery-copy-directory-identity
                        source-objects-identity-input)))
                 (reachable
                  (epi-ledger--object-value manifest "reachable_objects"))
                 (reachable-identities
                  (epi-ledger--recovery-close-reachable-object-identities
                   reachable reachable-identities-input layout))
                 (expected
                  (epi-ledger--recovery-manifest-object
                   source-proof plan recovery-id layout state reachable))
                 (encoded
                  (epi-ledger--jcs-encode manifest epi-record-json-byte-limit)))
            (unless (and
                     (if (eq state 'present)
                         (and source-objects-identity
                              (equal
                               (plist-get source-objects-identity :path)
                               (epi-ledger--recovery-layout-raw-source-objects-path
                                layout))
                              (= (plist-get source-objects-identity :device)
                                 (epi-ledger--recovery-layout-raw-quarantine-device
                                  layout)))
                       (null source-objects-identity))
                     (equal encoded
                            (epi-ledger--jcs-encode
                             expected epi-record-json-byte-limit))
                     (equal bytes encoded))
              (error "Incoherent private recovery preflight"))
            (epi-ledger--make-recovery-preflight
             :inspection nil
             :source-proof source-proof
             :reseal-plan plan
             :recovery-id recovery-id
             :layout layout
             :destination-parent-identity destination-parent-identity
             :source-object-tree-state state
             :source-objects-identity source-objects-identity
             :reachable-objects reachable
             :reachable-object-identities reachable-identities
             :manifest-object manifest
             :manifest-bytes encoded)))
      (error (epi-ledger--recovery-manifest-invalid)))))

(defun epi-ledger--recovery-snapshot-preflight-arguments
    (recovery-id destination quarantine-directory session-directory)
  "Own recovery scalar inputs before any cooperative callback.
RECOVERY-ID names the transaction.  DESTINATION, QUARANTINE-DIRECTORY,
and SESSION-DIRECTORY are path inputs."
  (let ((gc-cons-threshold most-positive-fixnum))
    (epi-ledger--require-uuid recovery-id "recovery_id")
    (cl-labels
        ((path
          (value optional)
          (when (or value (not optional))
            (unless (and (stringp value)
                         (<= (length value) epi-header-value-byte-limit)
                         (<= (string-bytes value)
                             epi-header-value-byte-limit))
              (epi-ledger--format-fail 'invalid-write-path))
            (substring-no-properties value))))
      (list (substring-no-properties recovery-id)
            (path destination t)
            (path quarantine-directory t)
            (path session-directory nil)))))

(cl-defun epi-ledger--recovery-preflight
    (inspection plan recovery-id &key destination quarantine-directory)
  "Close and verify one recovery plan without creating persistent state.
INSPECTION and PLAN bind the source and resealed output.  RECOVERY-ID
names the transaction.  DESTINATION and QUARANTINE-DIRECTORY optionally
override their deterministic defaults."
  (pcase-let*
      ((`(,owned-recovery-id ,owned-destination ,owned-quarantine
                              ,owned-session-directory)
        (epi-ledger--recovery-snapshot-preflight-arguments
         recovery-id destination quarantine-directory
         epi-session-directory))
       (epi-session-directory owned-session-directory))
    (epi-ledger--recovery-require-truncated-inspection inspection)
    (epi-ledger--with-operation-work-state
      (let* ((owned-plan
              (epi-ledger--recovery-copy-plan
               plan (epi-ledger--make-work-state)))
             (_validated-plan
              (epi-ledger--recovery-validate-copied-plan
               owned-plan (epi-ledger--make-work-state)))
             (source-proof
              (epi-ledger--recovery-reseal-plan-source-proof owned-plan))
             (current-identity
              (epi-ledger--owned-stat
               (epi-ledger--recovery-source-proof-canonical-path
                source-proof))))
        (unless current-identity
          (epi-ledger--recovery-reseal-source-changed))
        (unless (= 1 (plist-get current-identity :links))
          (epi-ledger--fail
           'epi-ledger-conflict 'recovery-source-multiply-linked))
        (unless
            (equal current-identity
                   (epi-ledger--recovery-source-proof-file-identity
                    source-proof))
          (epi-ledger--recovery-reseal-source-changed))
        (epi-ledger--recovery-authenticate-copied-plan
         inspection owned-plan)
        (let* ((layout
                (epi-ledger--recovery-layout
                 source-proof owned-plan owned-recovery-id
                 owned-destination owned-quarantine))
               (tree-proof
                (epi-ledger--recovery-source-object-tree-state layout))
               (destination-parent-identity
                (epi-ledger--recovery-capture-destination-parent layout))
               (tree-state (plist-get tree-proof :state))
               (tree-identity (plist-get tree-proof :identity))
               (reachable-proof
                (epi-ledger--recovery-reachable-objects
                 inspection source-proof layout tree-state))
               (reachable (nth 0 reachable-proof))
               (reachable-identities (nth 1 reachable-proof))
               (manifest
                (epi-ledger--recovery-manifest-object
                 source-proof owned-plan owned-recovery-id layout
                 tree-state reachable))
               (manifest-bytes
                (epi-ledger--recovery-manifest-encode manifest)))
          (epi-ledger--make-recovery-preflight
           :inspection inspection
           :source-proof source-proof
           :reseal-plan owned-plan
           :recovery-id owned-recovery-id
           :layout layout
           :destination-parent-identity destination-parent-identity
           :source-object-tree-state tree-state
           :source-objects-identity tree-identity
           :reachable-objects reachable
           :reachable-object-identities reachable-identities
           :manifest-object manifest
           :manifest-bytes manifest-bytes))))))

(defun epi-ledger--recovery-raw-directory-stat (path)
  "Return exact local directory identity for PATH without storage seams.
Return nil for absence and reject a symlink or non-directory exact name."
  (condition-case nil
      (let* ((file-name-handler-alist nil)
             (owned (substring-no-properties path))
             (attributes (file-attributes owned 'string)))
        (when attributes
          (unless (eq t (file-attribute-type attributes))
            (epi-ledger--fail
             'epi-ledger-conflict 'recovery-path-conflict))
          (list :path owned
                :device (file-attribute-device-number attributes)
                :inode (file-attribute-inode-number attributes)
                :links (file-attribute-link-number attributes)
                :modified (file-attribute-modification-time attributes)
                :changed (file-attribute-status-change-time attributes))))
    (file-error
     (epi-ledger--fail
      'epi-ledger-conflict 'quarantine-device-unknown))))

(defun epi-ledger--recovery-raw-mode (path)
  "Return exact permission bits for local PATH without storage seams."
  (condition-case nil
      (let ((file-name-handler-alist nil)
            (mode (file-modes (substring-no-properties path))))
        (unless (integerp mode)
          (epi-ledger--fail
           'epi-ledger-conflict 'quarantine-device-unknown))
        (logand #o7777 mode))
    (file-error
     (epi-ledger--fail
      'epi-ledger-conflict 'quarantine-device-unknown))))

(defun epi-ledger--recovery-same-directory-object-p
    (path expected actual)
  "Return non-nil when PATH still names EXPECTED directory object ACTUAL."
  (and expected actual
       (equal path (plist-get expected :path))
       (equal path (plist-get actual :path))
       (epi-ledger--same-file-object-p expected actual)))

(defun epi-ledger--recovery-require-directory-state-raw (path expected)
  "Raw-reprove exact PATH as EXPECTED directory identity or absence."
  (let ((actual (epi-ledger--recovery-raw-directory-stat path)))
    (if expected
        (unless (epi-ledger--recovery-same-directory-object-p
                 path expected actual)
          (epi-ledger--fail
           'epi-ledger-conflict 'recovery-path-conflict))
      (when actual
        (epi-ledger--fail
         'epi-ledger-conflict 'recovery-path-conflict)))
    actual))

(defun epi-ledger--recovery-require-bound-directory-raw
    (path expected device &optional mode)
  "Raw-reprove PATH as EXPECTED on DEVICE and optional exact MODE.
Return a fresh stable identity snapshot."
  (let* ((first (epi-ledger--recovery-raw-directory-stat path))
         (permissions (and first (epi-ledger--recovery-raw-mode path)))
         (second (epi-ledger--recovery-raw-directory-stat path)))
    (unless (and first (equal first second)
                 (epi-ledger--recovery-same-directory-object-p
                  path expected second)
                 (= device (or (plist-get second :device) -1))
                 (or (null mode) (= mode permissions)))
      (epi-ledger--fail
       'epi-ledger-conflict
       (if (and second
                (/= device (or (plist-get second :device) -1)))
           'quarantine-cross-device
         'recovery-path-conflict)))
    second))

(defun epi-ledger--recovery-reprove-directory-bindings-raw
    (layout anchor root control transaction receipts)
  "Raw-reprove LAYOUT using ANCHOR, ROOT, CONTROL, and TRANSACTION.
RECEIPTS bind every private ancestor created during this preparation."
  (let ((device (epi-ledger--recovery-layout-raw-quarantine-device layout)))
    (epi-ledger--recovery-require-bound-directory-raw
     (epi-ledger--recovery-layout-raw-quarantine-anchor-path layout)
     anchor device)
    (epi-ledger--recovery-require-bound-directory-raw
     (epi-ledger--recovery-layout-raw-quarantine-root layout)
     root device)
    (epi-ledger--recovery-require-bound-directory-raw
     (epi-ledger--recovery-layout-raw-control-directory layout)
     control device #o700)
    (dolist (receipt receipts)
      (unless (and (consp receipt) (stringp (car receipt))
                   (listp (cdr receipt)))
        (epi-ledger--fail
         'epi-ledger-conflict 'recovery-path-conflict))
      (epi-ledger--recovery-require-bound-directory-raw
       (car receipt) (cdr receipt) device #o700))
    (when transaction
      (epi-ledger--recovery-require-bound-directory-raw
       (epi-ledger--recovery-layout-raw-transaction-directory layout)
       transaction device #o700))))

(defun epi-ledger--recovery-reprove-source-object-state-raw
    (preflight layout)
  "Raw-reprove PREFLIGHT's exact source-object state named by LAYOUT."
  (let ((path
         (epi-ledger--recovery-layout-raw-source-objects-path layout))
        (state
         (epi-ledger--recovery-preflight-raw-source-object-tree-state
          preflight))
        (expected
         (epi-ledger--recovery-preflight-raw-source-objects-identity
          preflight)))
    (pcase state
      ('absent
       (when (epi-ledger--recovery-name-kind path)
         (epi-ledger--fail
          'epi-ledger-conflict 'recovery-path-conflict)))
      ('present
       (epi-ledger--recovery-require-bound-directory-raw
        path expected
        (epi-ledger--recovery-layout-raw-quarantine-device layout)))
      (_ (epi-ledger--format-fail 'recovery-preflight-required)))))

(defun epi-ledger--recovery-source-object-authority-equal-p
    (frozen observed)
  "Return non-nil when FROZEN and OBSERVED bind one source object tree."
  (let* ((frozen-layout
          (epi-ledger--recovery-preflight-raw-layout frozen))
         (observed-layout
          (epi-ledger--recovery-preflight-raw-layout observed))
         (frozen-path
          (epi-ledger--recovery-layout-raw-source-objects-path
           frozen-layout))
         (observed-path
          (epi-ledger--recovery-layout-raw-source-objects-path
           observed-layout))
         (frozen-state
          (epi-ledger--recovery-preflight-raw-source-object-tree-state
           frozen))
         (observed-state
          (epi-ledger--recovery-preflight-raw-source-object-tree-state
           observed))
         (frozen-identity
          (epi-ledger--recovery-preflight-raw-source-objects-identity
           frozen))
         (observed-identity
          (epi-ledger--recovery-preflight-raw-source-objects-identity
           observed))
         (frozen-object-identities
          (epi-ledger--recovery-preflight-raw-reachable-object-identities
           frozen))
         (observed-object-identities
          (epi-ledger--recovery-preflight-raw-reachable-object-identities
           observed)))
    (and (equal frozen-path observed-path)
         (eq frozen-state observed-state)
         (equal frozen-object-identities observed-object-identities)
         (pcase frozen-state
           ('absent
            (and (null frozen-identity) (null observed-identity)))
           ('present
            (epi-ledger--recovery-same-directory-object-p
             frozen-path frozen-identity observed-identity))
           (_ nil)))))

(defun epi-ledger--recovery-absent-publication-paths (layout)
  "Return LAYOUT paths that must remain absent throughout preparation."
  (list
   (epi-ledger--recovery-layout-raw-destination-path layout)
   (epi-ledger--recovery-layout-raw-destination-objects-path layout)
   (epi-ledger--recovery-layout-raw-staged-destination-ledger-path layout)
   (epi-ledger--recovery-layout-raw-staged-destination-objects-path layout)
   (epi-ledger--recovery-layout-raw-source-stage-path layout)
   (epi-ledger--recovery-layout-raw-staged-source-ledger-path layout)
   (epi-ledger--recovery-layout-raw-staged-source-objects-path layout)
   (epi-ledger--recovery-layout-raw-absent-source-objects-marker-path layout)
   (epi-ledger--recovery-layout-raw-final-quarantine-path layout)))

(defun epi-ledger--recovery-reprove-absent-publication-paths-raw (layout)
  "Raw-reprove every destination, staging, and final path in LAYOUT absent."
  (dolist (path (epi-ledger--recovery-absent-publication-paths layout))
    (when (epi-ledger--recovery-name-kind path)
      (epi-ledger--fail
       'epi-ledger-conflict
       (if (member
            path
            (list
             (epi-ledger--recovery-layout-raw-destination-path layout)
             (epi-ledger--recovery-layout-raw-destination-objects-path
              layout)))
           'recovery-destination-exists
         'recovery-path-conflict)))))

(defun epi-ledger--recovery-require-manifest-temporary-absent-raw (layout)
  "Raw-require LAYOUT's deterministic manifest temporary to be absent."
  (when
      (epi-ledger--raw-object-name-state
       (epi-ledger--recovery-layout-raw-manifest-temporary-path layout))
    (epi-ledger--fail
     'epi-ledger-conflict 'recovery-manifest-invalid)))

(defun epi-ledger--recovery-reprove-reachable-objects-raw (preflight layout)
  "Raw-restat every verified historical object in PREFLIGHT and LAYOUT."
  (let ((references
         (epi-ledger--recovery-preflight-raw-reachable-objects preflight))
        (identities
         (epi-ledger--recovery-preflight-raw-reachable-object-identities
          preflight))
        (source (epi-ledger--recovery-layout-raw-source-path layout)))
    (unless (and (vectorp references) (vectorp identities)
                 (= (length references) (length identities))
                 (<= (length references)
                     epi-ledger--recovery-atomic-object-limit))
      (epi-ledger--fail
       'epi-ledger-conflict 'recovery-preflight-changed))
    (dotimes (index (length references))
      (let* ((reference (aref references index))
             (hash (epi-ledger--object-value reference "hash"))
             (path
              (let ((file-name-handler-alist nil))
                (epi-ledger--object-path-for-ledger-path source hash)))
             (expected (aref identities index))
             (actual (epi-ledger--raw-object-name-state path)))
        (unless (and (listp expected)
                     (equal path (plist-get expected :path))
                     (equal expected actual))
          (epi-ledger--fail
           'epi-ledger-conflict 'recovery-preflight-changed))))))

(defun epi-ledger--recovery-reprove-runtime-authority-raw
    (preflight layout anchor root control transaction receipts)
  "Raw-reprove PREFLIGHT and LAYOUT runtime authority.
ANCHOR, ROOT, CONTROL, and TRANSACTION are frozen directory identities;
RECEIPTS bind every newly created quarantine ancestor."
  (epi-ledger--recovery-reprove-directory-bindings-raw
   layout anchor root control transaction receipts)
  (epi-ledger--recovery-reprove-destination-parent-raw preflight layout)
  (epi-ledger--recovery-reprove-source-object-state-raw preflight layout)
  (epi-ledger--recovery-reprove-reachable-objects-raw preflight layout)
  (epi-ledger--recovery-reprove-absent-publication-paths-raw layout))

(defun epi-ledger--recovery-create-private-directory
    (path device &optional receipt-receiver)
  "Exclusively create private directory PATH on DEVICE.
Return its exact raw identity.  On a failed post-create proof, best-effort
rollback follows the documented portable pathname-ABA boundary.  Deliver a
disjoint exact receipt to RECEIPT-RECEIVER before returning when non-nil."
  (let* ((receiver
          (or receipt-receiver
              epi-ledger--recovery-directory-receipt-receiver))
         (epi-ledger--recovery-directory-receipt-receiver nil)
         created created-identity identity complete)
    (unwind-protect
        (condition-case condition
            (let ((file-name-handler-alist nil))
              (with-file-modes #o700
                (make-directory (substring-no-properties path) nil))
              (setq created t
                    created-identity
                    (epi-ledger--recovery-raw-directory-stat path))
              (unless created-identity
                (epi-ledger--fail
                 'epi-ledger-conflict 'storage-write-failed))
              (set-file-modes path #o700)
              (setq identity
                    (epi-ledger--recovery-require-bound-directory-raw
                     path created-identity device #o700))
              (when receiver
                (funcall
                 receiver
                 (substring-no-properties path)
                 (epi-ledger--recovery-copy-directory-identity identity)))
              (setq complete t)
              identity)
          (file-already-exists
           (ignore condition)
           (epi-ledger--fail
            'epi-ledger-conflict 'recovery-path-conflict))
          (file-error
           (ignore condition)
           (epi-ledger--fail
            'epi-ledger-conflict 'storage-write-failed)))
      (when (and created (not complete))
        (let ((actual
               (condition-case nil
                   (epi-ledger--recovery-raw-directory-stat path)
                 ((error quit) nil))))
          (when (and created-identity actual
                     (epi-ledger--same-file-object-p
                      created-identity actual))
            (condition-case nil
                (let ((file-name-handler-alist nil))
                  (delete-directory (substring-no-properties path) nil))
              ((error quit) nil))))))))

(defun epi-ledger--recovery-directory-chain (ancestor target)
  "Return canonical directory names strictly below ANCESTOR through TARGET."
  (let* ((base (file-name-as-directory ancestor))
         (target-directory (file-name-as-directory target)))
    (unless (and (not (equal ancestor target))
                 (string-prefix-p base target-directory))
      (epi-ledger--fail
       'epi-ledger-conflict 'recovery-path-conflict))
    (let ((components
           (split-string
            (substring target-directory (length base)) "/" t))
          (cursor ancestor)
          result)
      (unless (and components
                   (seq-every-p
                    (lambda (component)
                      (and (not (string-empty-p component))
                           (not (member component '("." "..")))))
                    components))
        (epi-ledger--fail
         'epi-ledger-conflict 'recovery-path-conflict))
      (dolist (component components)
        (setq cursor
              (expand-file-name component (file-name-as-directory cursor)))
        (push cursor result))
      (nreverse result))))

(defun epi-ledger--recovery-reprove-created-directories-raw
    (anchor-path anchor device receipts)
  "Raw-reprove ANCHOR at ANCHOR-PATH and RECEIPTS on DEVICE."
  (epi-ledger--recovery-require-bound-directory-raw
   anchor-path anchor device)
  (dolist (receipt receipts)
    (epi-ledger--recovery-require-bound-directory-raw
     (car receipt) (cdr receipt) device #o700)))

(defun epi-ledger--recovery-prepare-private-directories
    (layout anchor root control &optional receipt-receiver)
  "Create missing quarantine directories for LAYOUT with exact receipts.
ANCHOR, ROOT, and CONTROL are the frozen pre-creation identities.  Return
the final root identity, control identity, and ordered creation receipts.
RECEIPT-RECEIVER receives a disjoint validated copy of each new receipt."
  (let* ((device
          (epi-ledger--recovery-layout-raw-quarantine-device layout))
         (anchor-path
          (epi-ledger--recovery-layout-raw-quarantine-anchor-path layout))
         (root-path
          (epi-ledger--recovery-layout-raw-quarantine-root layout))
         (control-path
          (epi-ledger--recovery-layout-raw-control-directory layout))
         (outer-receiver
          (or receipt-receiver
              epi-ledger--recovery-directory-receipt-receiver))
         (epi-ledger--recovery-directory-receipt-receiver nil)
         (expected-creations
          (append
           (unless root
             (epi-ledger--recovery-directory-chain anchor-path root-path))
           (unless control (list control-path))))
         (remaining-creations (copy-sequence expected-creations))
         receipts result complete)
    (cl-labels
        ((receive
          (path identity)
          (let* ((owned-path (substring-no-properties path))
                 (owned-identity
                  (epi-ledger--recovery-copy-directory-identity identity)))
            (unless (and remaining-creations
                         (equal owned-path (car remaining-creations))
                         (equal owned-path (plist-get owned-identity :path))
                         (equal
                          owned-identity
                          (epi-ledger--recovery-require-bound-directory-raw
                           owned-path owned-identity device #o700)))
              (epi-ledger--fail
               'epi-ledger-conflict 'recovery-path-conflict))
            (setq remaining-creations (cdr remaining-creations))
            (push (cons owned-path owned-identity) receipts)
            (when outer-receiver
              (funcall outer-receiver
                       (substring-no-properties owned-path)
                       (epi-ledger--recovery-copy-directory-identity
                        owned-identity)))
            owned-identity))
         (accept-return
          (path identity)
          (let* ((owned-identity
                  (epi-ledger--recovery-copy-directory-identity identity))
                 (prior (assoc path receipts)))
            (if prior
                (unless (equal (cdr prior) owned-identity)
                  (epi-ledger--fail
                   'epi-ledger-conflict 'recovery-path-conflict))
              (receive path owned-identity))
            (cdr (assoc path receipts)))))
      (unwind-protect
            (setq
             result
             (progn
               (epi-ledger--recovery-require-bound-directory-raw
                anchor-path anchor device)
               (if root
                   (setq root
                         (epi-ledger--recovery-require-bound-directory-raw
                          root-path root device))
                 (dolist
                     (path
                      (epi-ledger--recovery-directory-chain
                       anchor-path root-path))
                   (epi-ledger--recovery-require-directory-state-raw path nil)
                   (epi-ledger--recovery-reprove-created-directories-raw
                    anchor-path anchor device receipts)
                   (let ((identity
                          (epi-ledger--recovery-create-private-directory
                           path device #'receive)))
                     (accept-return path identity)
                     (epi-ledger--recovery-reprove-created-directories-raw
                      anchor-path anchor device receipts)))
                 (setq root (cdar receipts))
                 (unless (and root
                              (equal root-path (caar receipts)))
                   (epi-ledger--fail
                    'epi-ledger-conflict 'recovery-path-conflict)))
               (epi-ledger--recovery-require-bound-directory-raw
                root-path root device)
               (if control
                   (setq control
                         (epi-ledger--recovery-require-bound-directory-raw
                          control-path control device #o700))
                 (epi-ledger--recovery-require-directory-state-raw
                  control-path nil)
                 (epi-ledger--recovery-reprove-created-directories-raw
                  anchor-path anchor device receipts)
                 (epi-ledger--recovery-require-bound-directory-raw
                  root-path root device)
                 (setq control
                       (accept-return
                        control-path
                        (epi-ledger--recovery-create-private-directory
                         control-path device #'receive))))
               (epi-ledger--recovery-reprove-created-directories-raw
                anchor-path anchor device receipts)
               (epi-ledger--recovery-require-bound-directory-raw
                root-path root device)
               (setq control
                     (epi-ledger--recovery-require-bound-directory-raw
                      control-path control device #o700))
               (when remaining-creations
                 (epi-ledger--fail
                  'epi-ledger-conflict 'recovery-path-conflict))
               (setq receipts (nreverse receipts)
                     complete t)
               (list root control receipts)))
          (unless complete
            (epi-ledger--recovery-rollback-directory-receipts
             (reverse (copy-sequence receipts))))))
    result))

(defun epi-ledger--recovery-require-manifest-oracle (oracle)
  "Require ORACLE to be owned canonical unibyte manifest bytes."
  (unless (and (stringp oracle)
               (not (multibyte-string-p oracle))
               (not (epi-ledger--string-has-properties-p oracle))
               (<= (length oracle) epi-record-json-byte-limit))
    (epi-ledger--format-fail 'unibyte-write-required))
  oracle)

(defun epi-ledger--recovery-readback-manifest
    (path oracle &optional expected-identity)
  "Observe PATH as ORACLE with bounded injectable read operations.
When EXPECTED-IDENTITY is non-nil, require that complete identity throughout."
  (epi-ledger--recovery-require-manifest-oracle oracle)
  (let* ((owned-path (substring-no-properties path))
         (work (epi-ledger--make-work-state))
         (limit (max 1 epi-ledger-work-byte-limit))
         (identity (epi-ledger--owned-stat owned-path))
         (size (and identity (plist-get identity :size)))
         (mode
          (condition-case nil
              (file-modes owned-path)
            (file-error nil)))
         (cursor 0))
    (unless (and identity
                 (or (null expected-identity)
                     (equal expected-identity identity))
                 (integerp size)
                 (= size (length oracle))
                 (integerp mode)
                 (= #o600 (logand #o7777 mode)))
      (epi-ledger--fail
       'epi-ledger-conflict 'recovery-manifest-invalid))
    (while (< cursor size)
      (let* ((end (min size (+ cursor limit)))
             (amount (- end cursor)))
        (epi-ledger--work-charge work amount)
        (unless (equal identity (epi-ledger--owned-stat owned-path))
          (epi-ledger--fail
           'epi-ledger-conflict 'recovery-manifest-invalid))
        (let ((chunk
               (funcall epi-ledger--read-function
                        (substring-no-properties owned-path) cursor end)))
          (unless (and (stringp chunk)
                       (not (multibyte-string-p chunk))
                       (not (epi-ledger--string-has-properties-p chunk))
                       (= amount (length chunk))
                       (equal-including-properties
                        (substring-no-properties oracle cursor end)
                        chunk))
            (epi-ledger--fail
             'epi-ledger-conflict 'recovery-manifest-invalid)))
        (unless (equal identity (epi-ledger--owned-stat owned-path))
          (epi-ledger--fail
           'epi-ledger-conflict 'recovery-manifest-invalid))
        (setq cursor end)))
    identity))

(defun epi-ledger--recovery-capture-manifest-epoch-raw
    (path &optional expected-size expected-object exact-identity-p)
  "Raw-capture stable private PATH, optionally constrained by EXPECTED values.
EXPECTED-SIZE constrains byte size.  EXPECTED-OBJECT constrains the file object,
or the complete identity when EXACT-IDENTITY-P is non-nil."
  (let* ((first (epi-ledger--raw-object-name-state path))
         (mode
          (and (listp first)
               (condition-case nil
                   (epi-ledger--recovery-raw-mode path)
                 (error nil))))
         (second (epi-ledger--raw-object-name-state path)))
    (unless (and (listp first)
                 (equal first second)
                 (equal path (plist-get second :path))
                 (integerp (plist-get second :size))
                 (or (null expected-size)
                     (= expected-size (plist-get second :size)))
                 (integerp (plist-get second :links))
                 (> (plist-get second :links) 0)
                 (integerp mode)
                 (= #o600 mode)
                 (or (null expected-object)
                     (if exact-identity-p
                         (equal expected-object second)
                       (epi-ledger--same-file-object-p
                        expected-object second))))
      (epi-ledger--fail
       'epi-ledger-conflict 'recovery-manifest-invalid))
    second))

(defun epi-ledger--recovery-require-manifest-epoch-raw (path expected)
  "Raw-require private PATH to retain exact manifest epoch EXPECTED."
  (unless (listp expected)
    (epi-ledger--fail
     'epi-ledger-conflict 'recovery-manifest-invalid))
  (epi-ledger--recovery-capture-manifest-epoch-raw
   path (plist-get expected :size) expected t))

(defun epi-ledger--recovery-verify-manifest-epoch
    (path oracle &optional expected-object exact-identity-p)
  "Establish PATH's exact ORACLE epoch with bounded direct-local read operations.
EXPECTED-OBJECT constrains the file object, or its complete identity when
EXACT-IDENTITY-P is non-nil."
  (epi-ledger--recovery-require-manifest-oracle oracle)
  (let* ((owned-path (substring-no-properties path))
         (work (epi-ledger--make-work-state))
         (limit (max 1 epi-ledger-work-byte-limit))
         (size (length oracle))
         (identity
          (epi-ledger--recovery-capture-manifest-epoch-raw
           owned-path size expected-object exact-identity-p))
         (cursor 0))
    (while (< cursor size)
      (let* ((end (min size (+ cursor limit)))
             (amount (- end cursor)))
        (epi-ledger--work-charge work amount)
        (epi-ledger--recovery-require-manifest-epoch-raw
         owned-path identity)
        (let ((chunk (epi-ledger--read-bytes owned-path cursor end)))
          (unless (and (stringp chunk)
                       (not (multibyte-string-p chunk))
                       (not (epi-ledger--string-has-properties-p chunk))
                       (= amount (length chunk))
                       (equal-including-properties
                        (substring-no-properties oracle cursor end)
                        chunk))
            (epi-ledger--fail
             'epi-ledger-conflict 'recovery-manifest-invalid)))
        (epi-ledger--recovery-require-manifest-epoch-raw
         owned-path identity)
        (setq cursor end)))
    (epi-ledger--recovery-require-manifest-epoch-raw
     owned-path identity)))

(defun epi-ledger--recovery-renamed-manifest-epoch-p
    (path temporary identity)
  "Return non-nil when IDENTITY is PATH's rename successor of TEMPORARY."
  (and (listp temporary)
       (listp identity)
       (equal path (plist-get identity :path))
       (epi-ledger--same-file-object-p temporary identity)
       (= 1 (or (plist-get identity :links) -1))
       (= (or (plist-get temporary :size) -1)
          (or (plist-get identity :size) -2))
       (equal (plist-get temporary :modified)
              (plist-get identity :modified))))

(defun epi-ledger--recovery-classify-phase-manifest-raw
    (layout old-identity temporary-identity &optional new-identity)
  "Classify LAYOUT's canonical manifest by identity without reading content.
OLD-IDENTITY binds the prepared epoch.  TEMPORARY-IDENTITY binds the phase
temporary, and NEW-IDENTITY, when non-nil, binds its captured rename successor.
A metadata-only rename successor is returned as `candidate-new', never `new'."
  (let* ((path (epi-ledger--recovery-layout-raw-manifest-path layout))
         (identity
          (condition-case nil
              (epi-ledger--recovery-capture-manifest-epoch-raw path)
            ((error quit) nil))))
    (cond
     ((and identity
           (= 1 (or (plist-get identity :links) -1))
           (equal old-identity identity))
      (list :state 'old :identity identity))
     ((and identity
           (= 1 (or (plist-get identity :links) -1))
           new-identity
           (equal new-identity identity))
      (list :state 'new :identity identity))
     ((and identity
           (= 1 (or (plist-get identity :links) -1))
           (null new-identity)
           (epi-ledger--recovery-renamed-manifest-epoch-p
            path temporary-identity identity))
      (list :state 'candidate-new :identity identity))
     (t (list :state 'unknown :identity nil)))))

(defun epi-ledger--recovery-classify-phase-manifest
    (layout old-identity temporary-identity new-bytes
            &optional new-identity)
  "Content-prove LAYOUT's phase manifest before classifying a rename candidate.
OLD-IDENTITY, TEMPORARY-IDENTITY, and NEW-IDENTITY have the meanings used by
`epi-ledger--recovery-classify-phase-manifest-raw'.  NEW-BYTES is the owned
canonical successor oracle."
  (let ((classification
         (epi-ledger--recovery-classify-phase-manifest-raw
          layout old-identity temporary-identity new-identity)))
    (if (not (eq 'candidate-new (plist-get classification :state)))
        classification
      (let ((candidate (plist-get classification :identity))
            (path (epi-ledger--recovery-layout-raw-manifest-path layout)))
        (condition-case nil
            (let ((verified
                   (epi-ledger--recovery-verify-manifest-epoch
                    path new-bytes candidate t)))
              (if (equal candidate verified)
                  (list :state 'new :identity verified)
                (list :state 'unknown :identity nil)))
          ((error quit)
           (list :state 'unknown :identity nil)))))))

(defun epi-ledger--recovery-require-phase-manifest-core-raw
    (layout expected-identity)
  "Raw-require LAYOUT's canonical manifest as EXPECTED-IDENTITY."
  (epi-ledger--recovery-require-manifest-epoch-raw
   (epi-ledger--recovery-layout-raw-manifest-path layout)
   expected-identity))

(defun epi-ledger--recovery-observe-and-prove-manifest
    (path oracle &optional expected-identity)
  "Run injectable readback for PATH, then establish raw ORACLE authority.
The injectable reader receives its own byte copy so it cannot mutate ORACLE.
When non-nil, EXPECTED-IDENTITY must remain exact."
  (epi-ledger--recovery-readback-manifest path (copy-sequence oracle))
  (epi-ledger--recovery-verify-manifest-epoch
   path oracle expected-identity (and expected-identity t)))

(defun epi-ledger--recovery-require-manifest-links (identity expected)
  "Return manifest IDENTITY only when its link count is EXPECTED."
  (unless (and (listp identity)
               (= expected (or (plist-get identity :links) -1)))
    (epi-ledger--fail
     'epi-ledger-conflict 'recovery-manifest-invalid))
  identity)

(defun epi-ledger--recovery-capture-published-manifest-raw
    (path publication-source)
  "Raw-capture PATH as the same file object as PUBLICATION-SOURCE."
  (let ((identity (epi-ledger--raw-object-name-state path)))
    (unless (and (listp identity)
                 (epi-ledger--same-file-object-p
                  publication-source identity))
      (if identity
          (epi-ledger--fail
           'epi-ledger-conflict 'recovery-manifest-invalid)
        (epi-ledger--fail
         'epi-ledger-conflict 'storage-publication-failed)))
    (epi-ledger--recovery-require-manifest-links identity 2)))

(defun epi-ledger--recovery-delete-exact-empty-directory (path expected)
  "Best-effort delete PATH after proving its current EXPECTED identity.
Deletion is nonrecursive, so a nonempty replacement survives.  Portable
pathname ABA between the final stat and deletion remains outside the
first-slice guarantee."
  (let ((actual (epi-ledger--recovery-raw-directory-stat path)))
    (when actual
      (unless (epi-ledger--recovery-same-directory-object-p
               path expected actual)
        (epi-ledger--fail
         'epi-ledger-conflict 'recovery-path-conflict))
      (condition-case nil
          (let ((file-name-handler-alist nil))
            (delete-directory (substring-no-properties path) nil))
        (file-error
         (epi-ledger--fail
          'epi-ledger-conflict 'storage-write-failed)))
      (when (epi-ledger--recovery-raw-directory-stat path)
        (epi-ledger--fail
         'epi-ledger-conflict 'storage-write-failed)))))

(defun epi-ledger--recovery-rollback-directory-receipts (receipts)
  "Attempt every owned directory in RECEIPTS in reverse creation order."
  (let ((complete t)
        (pending (reverse (copy-sequence receipts))))
    (cl-labels
        ((attempt
          (remaining)
          (when remaining
            (unwind-protect
                (condition-case nil
                    (progn
                      (epi-ledger--recovery-delete-exact-empty-directory
                       (caar remaining) (cdar remaining))
                      (when
                          (epi-ledger--recovery-raw-directory-stat
                           (caar remaining))
                        (setq complete nil)))
                  ((error quit)
                   (setq complete nil)))
              (attempt (cdr remaining))))))
      (attempt pending))
    complete))

(defun epi-ledger--recovery-delete-exact-file-for-rollback (path identity)
  "Delete PATH only as exact IDENTITY, returning non-nil on proven absence."
  (condition-case nil
      (progn
        (epi-ledger--delete-owned-object-name path identity t)
        (null (epi-ledger--raw-object-name-state path)))
    (error nil)))

(defun epi-ledger--recovery-rollback-exact-manifest (path expected-identity)
  "Remove PATH only as exact EXPECTED-IDENTITY, or accept proven absence."
  (let ((state (epi-ledger--raw-object-name-state path)))
    (cond
     ((null state) t)
     ((or (null expected-identity)
          (not (listp state))
          (not (equal expected-identity state)))
      nil)
     (t (epi-ledger--recovery-delete-exact-file-for-rollback path state)))))

(defun epi-ledger--recovery-rollback-exact-temporary (path identity)
  "Remove PATH only while it names the reserved temporary IDENTITY."
  (let ((state (epi-ledger--raw-object-name-state path)))
    (cond
     ((null state) t)
     ((or (null identity)
          (not (listp state))
          (not (epi-ledger--same-file-object-p identity state)))
      nil)
     (t
      (epi-ledger--recovery-delete-exact-file-for-rollback path state)))))

(defun epi-ledger--recovery-clean-prebarrier-transaction
    (layout transaction-identity temporary-identity publication-identity
            directory-receipts)
  "Best-effort exact rollback of pre-barrier state described by LAYOUT.
TRANSACTION-IDENTITY and TEMPORARY-IDENTITY bind created storage objects;
PUBLICATION-IDENTITY binds any exact canonical publication, and
DIRECTORY-RECEIPTS names every private directory created for the transaction.
Return non-nil only when canonical, temporary, and transaction are all proven
removed.  Persistent replacements and unknown objects are preserved, subject
to the documented portable pathname-ABA boundary."
  (let* ((manifest
          (epi-ledger--recovery-layout-raw-manifest-path layout))
         (temporary
          (epi-ledger--recovery-layout-raw-manifest-temporary-path layout))
         (transaction
          (epi-ledger--recovery-layout-raw-transaction-directory layout))
         manifest-clean temporary-clean transaction-clean directories-clean)
    (unwind-protect
        (setq manifest-clean
              (condition-case nil
                  (epi-ledger--recovery-rollback-exact-manifest
                   manifest publication-identity)
                ((error quit) nil)))
      (unwind-protect
          (setq temporary-clean
                (condition-case nil
                    (epi-ledger--recovery-rollback-exact-temporary
                     temporary temporary-identity)
                  ((error quit) nil)))
        (unwind-protect
            (setq transaction-clean
                  (condition-case nil
                      (progn
                        (epi-ledger--recovery-delete-exact-empty-directory
                         transaction transaction-identity)
                        (null
                         (epi-ledger--recovery-raw-directory-stat
                          transaction)))
                    ((error quit) nil)))
          (setq directories-clean
                (epi-ledger--recovery-rollback-directory-receipts
                 directory-receipts)))))
    (and manifest-clean temporary-clean transaction-clean directories-clean)))

(defun epi-ledger--recovery-copy-lock (lock)
  "Return an ownership-disjoint exact copy of opaque LOCK authority."
  (unless (epi-ledger--lock-p lock)
    (epi-ledger--format-fail 'invalid-lock))
  (epi-ledger--make-lock
   :lock-file
   (substring-no-properties (epi-ledger--lock-lock-file lock))
   :bytes
   (substring-no-properties (epi-ledger--lock-bytes lock))
   :sha256
   (substring-no-properties (epi-ledger--lock-sha256 lock))
   :file-identity
   (epi-ledger--copy-tree-and-strings
    (epi-ledger--lock-file-identity lock))
   :expected-file
   (epi-ledger--copy-tree-and-strings
    (epi-ledger--lock-expected-file lock))
   :expected-end (epi-ledger--lock-expected-end lock)
   :expected-head
   (and (epi-ledger--lock-expected-head lock)
        (substring-no-properties
         (epi-ledger--lock-expected-head lock)))))

(defun epi-ledger--recovery-verify-lock-receipt-raw
    (receipt source expected-file expected-end expected-head)
  "Return a disjoint verified copy of RECEIPT authority for SOURCE.
The receipt must bind SOURCE's exact lock pathname, EXPECTED-FILE,
EXPECTED-END, and EXPECTED-HEAD and must still name its exact token object and
bytes.  Every proof bypasses injectable storage seams and callback hooks."
  (condition-case condition
      (let* ((lock (epi-ledger--recovery-copy-lock receipt))
             (expected-lock-path (epi-ledger--lock-path source)))
        (unless
            (and (equal expected-lock-path
                        (epi-ledger--lock-lock-file lock))
                 (equal expected-file
                        (epi-ledger--lock-expected-file lock))
                 (equal expected-end
                        (epi-ledger--lock-expected-end lock))
                 (equal expected-head
                        (epi-ledger--lock-expected-head lock)))
          (epi-ledger--fail 'epi-ledger-conflict 'lock-token-changed))
        (let ((file-name-handler-alist nil)
              (gc-cons-threshold most-positive-fixnum)
              (epi-ledger--stat-function #'epi-ledger--stat-local-file)
              (epi-ledger--read-function #'epi-ledger--read-bytes)
              (epi--yield-function #'ignore)
              (epi--deadline-clock-function #'float-time)
              (epi-ledger--nonpreemptible-observer nil)
              (epi-ledger--lock-acquisition-receiver nil))
          (epi-ledger--assert-lock-owned-core lock)
          (let* ((token
                  (epi-ledger--decode-lock-token
                   (epi-ledger--lock-bytes lock)))
                 (decoded-file-object
                  (epi-ledger--object-value token "expected_file"))
                 (decoded-file
                  (if (equal decoded-file-object "absent")
                      "absent"
                    (epi-ledger--lock-file-object-to-identity
                     decoded-file-object)))
                 (decoded-end
                  (epi-ledger--parse-unsigned-decimal
                   (epi-ledger--object-value token "expected_end")
                   'expected-end))
                 (decoded-head-object
                  (epi-ledger--object-value token "expected_head"))
                 (decoded-head
                  (unless (eq decoded-head-object epi-json-null)
                    (substring-no-properties decoded-head-object))))
            (unless
                (and
                 (equal source
                        (epi-ledger--object-value token "ledger_path"))
                 (equal expected-file decoded-file)
                 (equal expected-end decoded-end)
                 (equal expected-head decoded-head)
                 (equal (epi-ledger--lock-expected-file lock)
                        decoded-file)
                 (equal (epi-ledger--lock-expected-end lock)
                        decoded-end)
                 (equal (epi-ledger--lock-expected-head lock)
                        decoded-head))
              (epi-ledger--fail
               'epi-ledger-conflict 'lock-token-changed))))
        (epi-ledger--recovery-copy-lock lock))
    ((error quit)
     (ignore condition)
     (epi-ledger--fail 'epi-ledger-conflict 'lock-token-changed))))

(defun epi-ledger--recovery-require-lock-absent-raw (lock)
  "Require LOCK's exact pathname to be absent without invoking a seam."
  (unless (and (epi-ledger--lock-p lock)
               (null
                (epi-ledger--raw-object-name-state
                 (epi-ledger--lock-lock-file lock))))
    (epi-ledger--fail
     'epi-ledger-conflict 'lock-token-changed)))

(defun epi-ledger--recovery-raw-directory-entry-names
    (path expected-count)
  "Return sorted owned entry names from local directory PATH.
Read at most one name beyond EXPECTED-COUNT so unexpected membership remains
detectable without an unbounded directory allocation."
  (unless (and (epi-ledger--recovery-bounded-unsigned-p expected-count)
               (<= expected-count
                   (+ 2 epi-ledger--recovery-atomic-object-limit)))
    (epi-ledger--fail
     'epi-ledger-conflict 'recovery-path-conflict))
  (condition-case condition
      (let ((file-name-handler-alist nil)
            entries)
        (dolist (name
                 (directory-files
                  path nil directory-files-no-dot-files-regexp t
                  (1+ expected-count)))
          (unless (member name '("." ".."))
            (unless (and (stringp name)
                         (not (string-match-p "[\0/\r\n]" name)))
              (epi-ledger--fail
               'epi-ledger-conflict 'recovery-path-conflict))
            (push (substring-no-properties name) entries)))
        (sort entries #'string<))
    ((error quit)
     (ignore condition)
     (epi-ledger--fail
      'epi-ledger-conflict 'recovery-path-conflict))))

(defun epi-ledger--recovery-capture-transaction-entry-state-core-raw
    (layout expected-identity expected-entries)
  "Capture LAYOUT transaction as EXPECTED-IDENTITY with EXPECTED-ENTRIES."
  (let ((tail expected-entries)
        (expected-count 0))
    (while (consp tail)
      (setq expected-count (1+ expected-count))
      (when (> expected-count
               (+ 2 epi-ledger--recovery-atomic-object-limit))
        (epi-ledger--fail
         'epi-ledger-conflict 'recovery-path-conflict))
      (setq tail (cdr tail)))
    (unless (null tail)
      (epi-ledger--fail
       'epi-ledger-conflict 'recovery-path-conflict))
    (let* ((transaction
          (epi-ledger--recovery-layout-raw-transaction-directory layout))
         (first (epi-ledger--recovery-raw-directory-stat transaction))
         (entries
          (and first
               (epi-ledger--recovery-raw-directory-entry-names
                transaction expected-count)))
         (second (epi-ledger--recovery-raw-directory-stat transaction)))
      (unless (and first second (equal first second)
                   (epi-ledger--recovery-same-directory-object-p
                    transaction expected-identity second)
                   (equal expected-entries entries))
        (epi-ledger--fail
         'epi-ledger-conflict 'recovery-path-conflict))
      (list :identity second :entries entries))))

(defun epi-ledger--recovery-capture-transaction-entry-state-raw
    (layout expected-identity &optional expected-entries)
  "Capture LAYOUT's exact transaction under EXPECTED-IDENTITY.
EXPECTED-ENTRIES defaults to the canonical manifest name."
  (epi-ledger--recovery-capture-transaction-entry-state-core-raw
   layout expected-identity
   (or expected-entries
       (list
        (file-name-nondirectory
         (epi-ledger--recovery-layout-raw-manifest-path layout))))))

(defun epi-ledger--recovery-require-transaction-entry-state-raw
    (layout expected &optional exact-identity-p)
  "Require LAYOUT's transaction to retain EXPECTED state.
When EXACT-IDENTITY-P is non-nil, require its complete directory identity."
  (unless (and (listp expected)
               (listp (plist-get expected :identity))
               (listp (plist-get expected :entries)))
    (epi-ledger--fail
     'epi-ledger-conflict 'recovery-path-conflict))
  (let ((actual
         (epi-ledger--recovery-capture-transaction-entry-state-core-raw
          layout (plist-get expected :identity)
          (plist-get expected :entries))))
    (unless (and
             (equal (plist-get expected :entries)
                    (plist-get actual :entries))
             (if exact-identity-p
                 (equal (plist-get expected :identity)
                        (plist-get actual :identity))
               (epi-ledger--recovery-same-directory-object-p
                (epi-ledger--recovery-layout-raw-transaction-directory
                 layout)
                (plist-get expected :identity)
                (plist-get actual :identity))))
      (epi-ledger--fail
       'epi-ledger-conflict 'recovery-path-conflict))
    actual))

(defun epi-ledger--recovery-inspect-source-head-raw (preflight)
  "Return PREFLIGHT's freshly inspected, owned final valid record.
The scan admits one incomplete final frame and bypasses every storage and
cooperative seam.  Its complete source proof must still equal PREFLIGHT's
closed plan authority."
  (unless (epi-ledger--recovery-preflight-p preflight)
    (epi-ledger--format-fail 'recovery-preflight-required))
  (let* ((source-proof
          (epi-ledger--recovery-preflight-raw-source-proof preflight))
         (source
          (epi-ledger--recovery-source-proof-canonical-path source-proof))
         (file-name-handler-alist nil)
         (epi-ledger--open-identity-reader #'epi-ledger--file-identity)
         (epi-ledger--open-source-inserter
          #'insert-file-contents-literally)
         (epi-ledger--open-head-inserter
          #'insert-file-contents-literally)
         (epi--yield-function #'ignore)
         (epi--deadline-clock-function #'float-time)
         (epi-ledger--nonpreemptible-observer nil)
         (inspection
          (epi-ledger--inspect-path-core
           source 'allow-one-incomplete-final-frame))
         (observed-proof
          (epi-ledger--recovery-snapshot-source-proof inspection))
         (last-record
          (epi-ledger--inspection-raw-last-record inspection)))
    (unless (and
             (epi-ledger--recovery-source-proof-equal-p
              source-proof observed-proof)
             (epi-ledger--recovery-exact-record-p
              last-record #'epi-record-p epi-ledger--record-record-size))
      (epi-ledger--fail
       'epi-ledger-conflict 'recovery-preflight-changed))
    (epi-ledger--copy-record last-record)))

(defun epi-ledger--recovery-close-prebarrier-authority-raw
    (preflight last-record)
  "Raw-close failed PREFLIGHT authority against owned LAST-RECORD."
  (unless (epi-ledger--recovery-preflight-p preflight)
    (epi-ledger--format-fail 'recovery-preflight-required))
  (let* ((layout (epi-ledger--recovery-preflight-raw-layout preflight))
         (source-proof
          (epi-ledger--recovery-preflight-raw-source-proof preflight)))
    (unless (epi-ledger--recovery-exact-record-p
             last-record #'epi-record-p epi-ledger--record-record-size)
      (epi-ledger--fail
       'epi-ledger-conflict 'recovery-preflight-changed))
    (epi-ledger--recovery-reprove-destination-parent-raw preflight layout)
    (epi-ledger--recovery-reprove-source-object-state-raw
     preflight layout)
    (epi-ledger--recovery-reprove-reachable-objects-raw
     preflight layout)
    (epi-ledger--recovery-reprove-absent-publication-paths-raw layout)
    (epi-ledger--verify-source-authority-raw
     (epi-ledger--recovery-layout-raw-source-path layout)
     (epi-ledger--recovery-source-proof-file-identity source-proof)
     (epi-ledger--recovery-source-proof-source-size source-proof)
     (epi-ledger--recovery-source-proof-valid-prefix-head source-proof)
     last-record)
    t))

(defun epi-ledger--recovery-prebarrier-residual-state-raw (layout)
  "Return LAYOUT's exact residual manifest, temporary, and transaction state."
  (list
   (epi-ledger--raw-object-name-state
    (epi-ledger--recovery-layout-raw-manifest-path layout))
   (epi-ledger--raw-object-name-state
    (epi-ledger--recovery-layout-raw-manifest-temporary-path layout))
   (epi-ledger--recovery-raw-directory-stat
    (epi-ledger--recovery-layout-raw-transaction-directory layout))))

(defun epi-ledger--recovery-prebarrier-directory-paths (layout)
  "Return every directory name whose cleanup state LAYOUT must retain."
  (let* ((root (epi-ledger--recovery-layout-raw-quarantine-root layout))
         (transaction
          (epi-ledger--recovery-layout-raw-transaction-directory layout))
         (control
          (directory-file-name (file-name-directory transaction)))
         (anchor
          (let ((probe root) identity)
            (while (null identity)
              (setq identity
                    (epi-ledger--recovery-raw-directory-stat probe))
              (unless identity
                (let ((parent
                       (directory-file-name (file-name-directory probe))))
                  (when (equal parent probe)
                    (epi-ledger--fail
                     'epi-ledger-conflict 'quarantine-device-unknown))
                  (setq probe parent))))
            probe))
         (paths (list (substring-no-properties anchor))))
    (unless (equal anchor root)
      (setq paths
            (append
             paths
             (mapcar #'substring-no-properties
                     (epi-ledger--recovery-directory-chain anchor root)))))
    (unless (member control paths)
      (setq paths
            (append paths (list (substring-no-properties control)))))
    paths))

(defun epi-ledger--recovery-prebarrier-directory-state-raw (layout)
  "Return exact present-or-absent directory-name state for LAYOUT."
  (mapcar
   (lambda (path)
     (cons path (epi-ledger--recovery-raw-directory-stat path)))
   (epi-ledger--recovery-prebarrier-directory-paths layout)))

(defun epi-ledger--recovery-require-prebarrier-directory-state-raw
    (expected)
  "Require every directory name in EXPECTED to retain its captured state."
  (dolist (entry expected)
    (unless (and (consp entry) (stringp (car entry)))
      (epi-ledger--fail
       'epi-ledger-conflict 'recovery-path-conflict))
    (epi-ledger--recovery-require-directory-state-raw
     (car entry) (cdr entry)))
  t)

(defun epi-ledger--recovery-require-prebarrier-residual-state-raw
    (layout expected)
  "Require LAYOUT's residual state to remain exact EXPECTED."
  (let ((actual
         (epi-ledger--recovery-prebarrier-residual-state-raw layout)))
    (unless (equal (nth 0 expected) (nth 0 actual))
      (epi-ledger--fail
       'epi-ledger-conflict 'recovery-manifest-invalid))
    (unless (equal (nth 1 expected) (nth 1 actual))
      (epi-ledger--fail
       'epi-ledger-conflict 'recovery-manifest-invalid))
    (unless (equal (nth 2 expected) (nth 2 actual))
      (epi-ledger--fail
       'epi-ledger-conflict 'recovery-path-conflict))
    t))

(defun epi-ledger--recovery-close-unlocked-prepared-raw (prepared)
  "Raw-reprove durable PREPARED state after unlock by exact identity."
  (unless (epi-ledger--recovery-prepared-p prepared)
    (epi-ledger--format-fail 'recovery-preflight-required))
  (let* ((preflight
          (epi-ledger--recovery-prepared-raw-preflight prepared))
         (layout
          (epi-ledger--recovery-prepared-raw-path-layout prepared))
         (source-proof
          (epi-ledger--recovery-preflight-raw-source-proof preflight))
         (source-last-record
          (epi-ledger--recovery-prepared-raw-source-last-record prepared))
         (source (epi-ledger--recovery-layout-raw-source-path layout))
         (manifest (epi-ledger--recovery-layout-raw-manifest-path layout))
         (transaction-state
          (epi-ledger--recovery-prepared-raw-transaction-entry-state
           prepared)))
    (unless (epi-ledger--recovery-exact-record-p
             source-last-record #'epi-record-p epi-ledger--record-record-size)
      (epi-ledger--fail
       'epi-ledger-conflict 'recovery-preflight-changed))
    (epi-ledger--recovery-reprove-runtime-authority-raw
     preflight layout
     (epi-ledger--recovery-prepared-raw-quarantine-anchor-identity prepared)
     (epi-ledger--recovery-prepared-raw-quarantine-root-identity prepared)
     (epi-ledger--recovery-prepared-raw-control-identity prepared)
     (epi-ledger--recovery-prepared-raw-transaction-identity prepared)
     (epi-ledger--recovery-prepared-raw-directory-receipts prepared))
    (epi-ledger--recovery-require-manifest-temporary-absent-raw layout)
    (epi-ledger--verify-source-authority-raw
     source
     (epi-ledger--recovery-source-proof-file-identity source-proof)
     (epi-ledger--recovery-source-proof-source-size source-proof)
     (epi-ledger--recovery-source-proof-valid-prefix-head source-proof)
     source-last-record)
    (epi-ledger--recovery-require-manifest-links
     (epi-ledger--recovery-require-manifest-epoch-raw
      manifest
      (epi-ledger--recovery-prepared-raw-manifest-identity prepared))
     1)
    (epi-ledger--recovery-require-manifest-temporary-absent-raw layout)
    (epi-ledger--recovery-require-transaction-entry-state-raw
     layout transaction-state)
    (epi-ledger--recovery-reprove-runtime-authority-raw
     preflight layout
     (epi-ledger--recovery-prepared-raw-quarantine-anchor-identity prepared)
     (epi-ledger--recovery-prepared-raw-quarantine-root-identity prepared)
     (epi-ledger--recovery-prepared-raw-control-identity prepared)
     (epi-ledger--recovery-prepared-raw-transaction-identity prepared)
     (epi-ledger--recovery-prepared-raw-directory-receipts prepared))
    (epi-ledger--verify-source-authority-raw
     source
     (epi-ledger--recovery-source-proof-file-identity source-proof)
     (epi-ledger--recovery-source-proof-source-size source-proof)
     (epi-ledger--recovery-source-proof-valid-prefix-head source-proof)
     source-last-record)
    (epi-ledger--recovery-require-manifest-temporary-absent-raw layout)
    (epi-ledger--recovery-require-transaction-entry-state-raw
     layout transaction-state)
    t))

(defun epi-ledger--recovery-prepare-manifest (preflight)
  "Close and reprove PREFLIGHT, then durably publish phase prepared."
  (unless (epi-ledger--recovery-exact-record-p
           preflight #'epi-ledger--recovery-preflight-p
           epi-ledger--recovery-preflight-record-size)
    (epi-ledger--format-fail 'recovery-preflight-required))
  (let* ((preflight
          (condition-case nil
              (epi-ledger--recovery-close-preflight preflight)
            (error
             (epi-ledger--fail
              'epi-ledger-conflict 'recovery-preflight-changed))))
         (source-proof
          (epi-ledger--recovery-preflight-raw-source-proof preflight))
         (plan (epi-ledger--recovery-preflight-raw-reseal-plan preflight))
         (layout (epi-ledger--recovery-preflight-raw-layout preflight))
         (recovery-id
          (epi-ledger--recovery-preflight-raw-recovery-id preflight))
         (frozen-bytes
          (epi-ledger--recovery-preflight-raw-manifest-bytes preflight))
         ;; The writer and every injectable observer receive copies disjoint
         ;; from the authority oracle.
         (writer-bytes (copy-sequence frozen-bytes))
         (oracle-bytes (copy-sequence frozen-bytes))
         (source (epi-ledger--recovery-layout-raw-source-path layout))
         (expected-identity
          (epi-ledger--recovery-source-proof-file-identity source-proof))
         (expected-end
          (epi-ledger--recovery-source-proof-source-size source-proof))
         (expected-head
          (epi-ledger--recovery-source-proof-valid-prefix-head source-proof))
         lock acquired-lock durable-prepared prepared closure-last-record
         preunlock-residual
         preunlock-directory-residual
         body-condition preunlock-condition unlock-condition)
    (unwind-protect
        (condition-case condition
            (progn
              (unless (and (stringp writer-bytes)
                           (not (eq writer-bytes oracle-bytes))
                           (not (multibyte-string-p writer-bytes))
                           (not (multibyte-string-p oracle-bytes))
                           (not
                            (epi-ledger--string-has-properties-p
                             writer-bytes))
                           (not
                            (epi-ledger--string-has-properties-p
                             oracle-bytes))
                           (equal writer-bytes oracle-bytes))
                (epi-ledger--format-fail 'recovery-manifest-invalid))
              (let ((lock-receipt-receiver
                     (lambda (receipt)
                       (when acquired-lock
                         (epi-ledger--fail
                          'epi-ledger-conflict 'lock-token-changed))
                       (setq acquired-lock
                             (epi-ledger--recovery-verify-lock-receipt-raw
                              receipt source expected-identity expected-end
                              expected-head))))
                    returned-lock)
                (unwind-protect
                    (progn
                      (setq returned-lock
                            (epi-ledger--acquire-lock
                             (substring-no-properties source)
                             (epi-ledger--copy-tree-and-strings
                              expected-identity)
                             expected-end
                             (and expected-head
                                  (substring-no-properties expected-head))
                             lock-receipt-receiver))
                      (unless (and acquired-lock
                                   (epi-ledger--lock-p returned-lock)
                                   (equal acquired-lock returned-lock))
                        (epi-ledger--fail
                         'epi-ledger-conflict 'lock-token-changed))
                      (setq lock
                            (epi-ledger--recovery-copy-lock acquired-lock)))
                  (when (and acquired-lock (null lock))
                    ;; Preserve the receiver-bound authority for the outer,
                    ;; unavoidable unlock and post-unlock closure.
                    (setq lock
                          (epi-ledger--recovery-copy-lock acquired-lock)))))
              (let* ((second-inspection
                (epi-ledger--inspect-path
                 (substring-no-properties source)
                 'allow-one-incomplete-final-frame))
               (last-record
                (epi-ledger--copy-record
                 (epi-ledger--inspection-raw-last-record second-inspection)))
               (second-proof
                (epi-ledger--recovery-snapshot-source-proof second-inspection))
               (second
                (condition-case condition
                    (epi-ledger--recovery-preflight
                     second-inspection plan recovery-id
                     :destination
                     (substring-no-properties
                      (epi-ledger--recovery-layout-raw-destination-path
                       layout))
                     :quarantine-directory
                     (substring-no-properties
                      (epi-ledger--recovery-layout-raw-quarantine-root
                       layout)))
                  (epi-ledger-conflict
                   (if
                       (memq
                        (plist-get
                         (epi-ledger--condition-plist condition) :code)
                        '(recovery-reseal-plan-changed
                          recovery-reseal-source-changed))
                       (epi-ledger--fail
                        'epi-ledger-conflict 'recovery-preflight-changed)
                     (signal (car condition) (cdr condition))))))
               (closed-second
                (epi-ledger--recovery-close-preflight second))
               (second-layout
                (epi-ledger--recovery-preflight-raw-layout second))
               (second-bytes
                (epi-ledger--recovery-preflight-raw-manifest-bytes second))
               (device
                (epi-ledger--recovery-layout-raw-quarantine-device
                 second-layout))
               (anchor
                (epi-ledger--recovery-layout-raw-quarantine-anchor-identity
                 second-layout))
               (root
                (epi-ledger--recovery-layout-raw-quarantine-root-identity
                 second-layout))
               (control
                (epi-ledger--recovery-layout-raw-control-identity
                 second-layout))
               (transaction
                (epi-ledger--recovery-layout-raw-transaction-directory
                 second-layout))
               (manifest
                (epi-ledger--recovery-layout-raw-manifest-path second-layout))
               (temporary
                (epi-ledger--recovery-layout-raw-manifest-temporary-path
                 second-layout))
               (parent-expected-creations
                (append
                 (unless root
                   (epi-ledger--recovery-directory-chain
                    (epi-ledger--recovery-layout-raw-quarantine-anchor-path
                     second-layout)
                    (epi-ledger--recovery-layout-raw-quarantine-root
                     second-layout)))
                 (unless control
                   (list
                    (epi-ledger--recovery-layout-raw-control-directory
                     second-layout)))))
               (parent-remaining-creations
                (copy-sequence parent-expected-creations))
               transaction-identity temporary-identity publication-identity
               manifest-identity transaction-entry-state
               barrier-started directory-receipts)
          (setq closure-last-record
                (epi-ledger--copy-record last-record))
          (unless
              (and
               (epi-ledger--recovery-source-proof-equal-p
                source-proof second-proof)
               (epi-ledger--recovery-source-object-authority-equal-p
                preflight second)
               (equal oracle-bytes second-bytes))
            (epi-ledger--fail
             'epi-ledger-conflict 'recovery-preflight-changed))
          (epi-ledger--verify-prewrite-authority-raw
           source expected-identity expected-end expected-head last-record lock)
          ;; Freeze pre-creation state at the exact pathnames.
          (epi-ledger--recovery-require-directory-state-raw
           (epi-ledger--recovery-layout-raw-quarantine-anchor-path
            second-layout)
           anchor)
          (epi-ledger--recovery-require-directory-state-raw
           (epi-ledger--recovery-layout-raw-quarantine-root second-layout)
           root)
          (epi-ledger--recovery-require-directory-state-raw
           (epi-ledger--recovery-layout-raw-control-directory second-layout)
           control)
          (dolist (path parent-expected-creations)
            (epi-ledger--recovery-require-directory-state-raw path nil))
          (unwind-protect
              (progn
                (let* ((directory-receipt-receiver
                        (lambda (path identity)
                          (let* ((owned-path
                                  (substring-no-properties path))
                                 (owned-identity
                                  (epi-ledger--recovery-copy-directory-identity
                                   identity))
                                 (receipt
                                  (cons owned-path owned-identity)))
                            (unless
                                (and parent-remaining-creations
                                     (equal
                                      owned-path
                                      (car parent-remaining-creations))
                                     (equal
                                      owned-path
                                      (plist-get owned-identity :path))
                                     (equal
                                      owned-identity
                                      (epi-ledger--recovery-require-bound-directory-raw
                                       owned-path owned-identity device #o700)))
                              (epi-ledger--fail
                               'epi-ledger-conflict
                               'recovery-path-conflict))
                            (setq parent-remaining-creations
                                  (cdr parent-remaining-creations))
                            (setq directory-receipts
                                  (append directory-receipts
                                          (list receipt)))
                            (cond
                             ((equal
                               (car receipt)
                               (epi-ledger--recovery-layout-raw-quarantine-root
                                second-layout))
                              (setq root (cdr receipt)))
                             ((equal
                               (car receipt)
                               (epi-ledger--recovery-layout-raw-control-directory
                                second-layout))
                              (setq control (cdr receipt)))))))
                       (directories
                        (epi-ledger--recovery-prepare-private-directories
                         second-layout anchor root control
                         directory-receipt-receiver)))
                  (unless (and (listp directories)
                               (= 3 (length directories))
                               (null parent-remaining-creations)
                               (equal root (nth 0 directories))
                               (equal control (nth 1 directories))
                               (equal directory-receipts
                                      (nth 2 directories)))
                    (epi-ledger--fail
                     'epi-ledger-conflict 'recovery-path-conflict))
                  (setq root
                        (epi-ledger--recovery-copy-directory-identity
                         (nth 0 directories))
                        control
                        (epi-ledger--recovery-copy-directory-identity
                         (nth 1 directories))))
                ;; This is the mandatory post-parent-creation reproof: source
                ;; object state plus every destination/staging/final absence.
                (epi-ledger--recovery-reprove-runtime-authority-raw
                 second second-layout anchor root control nil
                 directory-receipts)
                (when (epi-ledger--recovery-name-kind transaction)
                  (epi-ledger--fail
                   'epi-ledger-conflict 'recovery-path-conflict))
                (let* ((directory-receipt-receiver
                        (lambda (path identity)
                          (let* ((owned-path
                                  (substring-no-properties path))
                                 (owned-identity
                                  (epi-ledger--recovery-copy-directory-identity
                                   identity)))
                            (unless
                                (and (equal owned-path transaction)
                                     (null transaction-identity)
                                     (equal
                                      owned-path
                                      (plist-get owned-identity :path))
                                     (equal
                                      owned-identity
                                      (epi-ledger--recovery-require-bound-directory-raw
                                       owned-path owned-identity device #o700)))
                              (epi-ledger--fail
                               'epi-ledger-conflict
                               'recovery-path-conflict))
                            (setq transaction-identity owned-identity))))
                       (returned-transaction
                        (epi-ledger--recovery-create-private-directory
                         transaction device directory-receipt-receiver)))
                  (unless transaction-identity
                    (setq transaction-identity
                          (epi-ledger--recovery-copy-directory-identity
                           returned-transaction)))
                  (unless (equal transaction-identity returned-transaction)
                    (epi-ledger--fail
                     'epi-ledger-conflict 'recovery-path-conflict)))
                (epi-ledger--recovery-reprove-runtime-authority-raw
                 second second-layout anchor root control
                 transaction-identity directory-receipts)
                (dolist (path (list manifest temporary))
                  (when (epi-ledger--raw-object-name-state path)
                    (epi-ledger--fail
                     'epi-ledger-conflict 'recovery-path-conflict)))
                (epi-ledger--verify-prewrite-authority-raw
                 source expected-identity expected-end expected-head
                 last-record lock)
                ;; Reserve the exact temporary object outside the injectable
                ;; writer.  A later callback may mutate this object, but bytes
                ;; alone can never make a replacement ours.
                (condition-case reserve-condition
                    (epi-ledger--write-bytes
                     (substring-no-properties temporary)
                     "" 'exclusive-create t)
                  ((error quit)
                   (signal
                    (car reserve-condition) (cdr reserve-condition))))
                (setq temporary-identity
                      (epi-ledger--recovery-capture-manifest-epoch-raw
                       temporary 0))
                (unless (= 1 (or (plist-get temporary-identity :links) 0))
                  (epi-ledger--fail
                   'epi-ledger-conflict 'recovery-manifest-invalid))
                (funcall epi-ledger--byte-writer
                         (substring-no-properties temporary)
                         writer-bytes 'replace t)
                (let ((written
                       (epi-ledger--recovery-observe-and-prove-manifest
                        temporary oracle-bytes)))
                  (unless (and
                           (epi-ledger--same-file-object-p
                            temporary-identity written)
                           (= 1 (or (plist-get written :links) 0)))
                    (epi-ledger--fail
                     'epi-ledger-conflict 'recovery-manifest-invalid))
                  (setq temporary-identity written))
                (epi-ledger--recovery-reprove-runtime-authority-raw
                 second second-layout anchor root control
                 transaction-identity directory-receipts)
                (epi-ledger--verify-prewrite-authority-raw
                 source expected-identity expected-end expected-head
                 last-record lock)
                (epi-ledger--publish-object
                 temporary manifest temporary-identity
                 (lambda (path identity)
                   (let ((gc-cons-threshold most-positive-fixnum))
                     (let ((captured
                            (epi-ledger--recovery-capture-published-manifest-raw
                             manifest temporary-identity)))
                       ;; Store the raw receipt before rejecting any hostile
                       ;; callback value so unwind cleanup owns the already-
                       ;; created canonical name.
                       (when publication-identity
                         (epi-ledger--fail
                          'epi-ledger-conflict 'recovery-manifest-invalid))
                       (setq publication-identity captured)
                       (let ((owned-path
                              (and (stringp path)
                                   (<= (string-bytes path)
                                       epi-header-value-byte-limit)
                                   (substring-no-properties path)))
                             (owned-identity
                              (condition-case nil
                                  (epi-ledger--recovery-copy-file-identity
                                   identity)
                                (error nil))))
                         (unless
                             (and owned-path
                                  (equal owned-path manifest)
                                  (equal owned-identity captured))
                           (epi-ledger--fail
                            'epi-ledger-conflict
                            'recovery-manifest-invalid)))))))
                ;; The publisher is injectable.  Raw-capture its canonical
                ;; file object before any source or lock proof.
                (let ((captured
                       (epi-ledger--recovery-capture-published-manifest-raw
                        manifest temporary-identity)))
                  (when (and publication-identity
                             (not (equal publication-identity captured)))
                    (epi-ledger--fail
                     'epi-ledger-conflict 'recovery-manifest-invalid))
                  (setq publication-identity captured))
                (epi-ledger--recovery-reprove-runtime-authority-raw
                 second second-layout anchor root control
                 transaction-identity directory-receipts)
                (epi-ledger--verify-prewrite-authority-raw
                 source expected-identity expected-end expected-head
                 last-record lock)
                ;; Observe injected read/stat faults, then let the raw oracle
                ;; decide authority.  Reprove callbacks' other authority too.
                (setq publication-identity
                      (epi-ledger--recovery-require-manifest-links
                       (epi-ledger--recovery-observe-and-prove-manifest
                        manifest oracle-bytes publication-identity)
                       2))
                (epi-ledger--recovery-reprove-runtime-authority-raw
                 second second-layout anchor root control
                 transaction-identity directory-receipts)
                (epi-ledger--verify-prewrite-authority-raw
                 source expected-identity expected-end expected-head
                 last-record lock)
                ;; Remove the temporary name only by its captured identity.
                (unless (epi-ledger--recovery-rollback-exact-temporary
                         temporary temporary-identity)
                  (epi-ledger--fail
                   'epi-ledger-conflict 'storage-publication-failed
                   :published t))
                (setq temporary-identity nil
                      ;; Removing the sibling link intentionally changes link
                      ;; count/ctime; establish a fresh raw canonical identity.
                      manifest-identity
                      (epi-ledger--recovery-require-manifest-links
                       (epi-ledger--recovery-capture-manifest-epoch-raw
                        manifest (length oracle-bytes)
                        publication-identity)
                       1))
                (unless
                    (epi-ledger--recovery-renamed-manifest-epoch-p
                     manifest publication-identity manifest-identity)
                  (epi-ledger--fail
                   'epi-ledger-conflict 'recovery-manifest-invalid))
                (epi-ledger--recovery-require-manifest-temporary-absent-raw
                 second-layout)
                (epi-ledger--recovery-reprove-runtime-authority-raw
                 second second-layout anchor root control
                 transaction-identity directory-receipts)
                (epi-ledger--verify-prewrite-authority-raw
                 source expected-identity expected-end expected-head
                 last-record lock)
                (setq transaction-entry-state
                      (epi-ledger--recovery-capture-transaction-entry-state-raw
                       second-layout transaction-identity))
                ;; From this assignment onward canonical state is durable
                ;; resume evidence and must never be rolled back.
                (setq durable-prepared
                      (epi-ledger--make-recovery-prepared
                       :preflight closed-second
                       :quarantine-anchor-identity anchor
                       :quarantine-root-identity root
                       :control-identity control
                       :directory-receipts directory-receipts
                       :transaction-identity transaction-identity
                       :manifest-identity manifest-identity
                       :transaction-entry-state transaction-entry-state
                       :source-last-record
                       (epi-ledger--copy-record last-record)
                       :path-layout second-layout))
                (setq barrier-started t)
                (funcall epi-ledger--recovery-phase-barrier-function
                         'prepared)
                (epi-ledger--recovery-require-manifest-temporary-absent-raw
                 second-layout)
                (epi-ledger--recovery-reprove-runtime-authority-raw
                 second second-layout anchor root control
                 transaction-identity directory-receipts)
                (epi-ledger--verify-prewrite-authority-raw
                 source expected-identity expected-end expected-head
                 last-record lock)
                (setq manifest-identity
                      (epi-ledger--recovery-require-manifest-links
                       (epi-ledger--recovery-require-manifest-epoch-raw
                        manifest manifest-identity)
                       1))
                (epi-ledger--recovery-require-manifest-temporary-absent-raw
                 second-layout)
                (epi-ledger--recovery-require-transaction-entry-state-raw
                 second-layout transaction-entry-state)
                ;; The barrier was the last body callback before unlock: close
                ;; it with one final raw proof of every retained authority.
                (epi-ledger--recovery-reprove-runtime-authority-raw
                 second second-layout anchor root control
                 transaction-identity directory-receipts)
                (epi-ledger--verify-prewrite-authority-raw
                 source expected-identity expected-end expected-head
                 last-record lock)
                (epi-ledger--recovery-require-manifest-temporary-absent-raw
                 second-layout)
                (setq prepared durable-prepared))
            (unless prepared
              ;; Before the barrier, rollback is permitted only through exact
              ;; object and oracle proofs.  Once barrier invocation starts or
              ;; signals, preserve canonical and transaction state for resume.
              (unless barrier-started
                (when (or transaction-identity temporary-identity
                          publication-identity directory-receipts)
                  (epi-ledger--recovery-clean-prebarrier-transaction
                   second-layout transaction-identity temporary-identity
                   (or manifest-identity publication-identity)
                   directory-receipts)))))
              prepared))
          ((error quit)
           (setq body-condition condition)))
      ;; Each cleanup layer is itself protected so arbitrary `throw' from the
      ;; body, pre-unlock proof, or unlock callback still reaches the final
      ;; raw post-unlock closure.  A closure failure deliberately overrides
      ;; the original nonlocal exit.
      (unwind-protect
          (unless (or prepared durable-prepared)
            (condition-case condition
                (progn
                  (unless closure-last-record
                    (setq closure-last-record
                          (epi-ledger--recovery-inspect-source-head-raw
                           preflight)))
                  (epi-ledger--recovery-close-prebarrier-authority-raw
                   preflight closure-last-record)
                  (setq preunlock-residual
                        (epi-ledger--recovery-prebarrier-residual-state-raw
                         layout))
                  (setq preunlock-directory-residual
                        (epi-ledger--recovery-prebarrier-directory-state-raw
                         layout)))
              ((error quit)
               (setq preunlock-condition condition))))
        (unwind-protect
            (when lock
              (condition-case condition
                  (let ((epi-ledger--stat-function
                         #'epi-ledger--stat-local-file)
                        (epi-ledger--read-function #'epi-ledger--read-bytes)
                        (epi--yield-function #'ignore)
                        (epi--deadline-clock-function #'float-time)
                        (epi-ledger--nonpreemptible-observer nil))
                    (funcall epi-ledger--unlock-function
                             (epi-ledger--recovery-copy-lock lock)))
                ((error quit)
                 (setq unlock-condition condition))))
          (progn
            (when lock
              (epi-ledger--recovery-require-lock-absent-raw lock))
            (if (or prepared durable-prepared)
                (epi-ledger--recovery-close-unlocked-prepared-raw
                 (or prepared durable-prepared))
              (progn
                (unless closure-last-record
                  (setq closure-last-record
                        (epi-ledger--recovery-inspect-source-head-raw
                         preflight)))
                (epi-ledger--recovery-close-prebarrier-authority-raw
                 preflight closure-last-record)
                (when preunlock-residual
                  (epi-ledger--recovery-require-prebarrier-residual-state-raw
                   layout preunlock-residual))
                (when preunlock-directory-residual
                  (epi-ledger--recovery-require-prebarrier-directory-state-raw
                   preunlock-directory-residual))))
            (when lock
              (epi-ledger--recovery-require-lock-absent-raw lock))))))
    (cond
     (preunlock-condition
      (signal (car preunlock-condition) (cdr preunlock-condition)))
     (body-condition
      (signal (car body-condition) (cdr body-condition)))
     (unlock-condition
      (signal (car unlock-condition) (cdr unlock-condition)))
     (t prepared))))

(defun epi-ledger--recovery-manifest-layout-signature (layout)
  "Return LAYOUT's ordered manifest-derived authority fields."
  (list
   (epi-ledger--recovery-layout-raw-source-path layout)
   (epi-ledger--recovery-layout-raw-source-objects-path layout)
   (epi-ledger--recovery-layout-raw-destination-path layout)
   (epi-ledger--recovery-layout-raw-destination-objects-path layout)
   (epi-ledger--recovery-layout-raw-staged-destination-ledger-path layout)
   (epi-ledger--recovery-layout-raw-staged-destination-objects-path layout)
   (epi-ledger--recovery-layout-raw-quarantine-root layout)
   (epi-ledger--recovery-layout-raw-quarantine-device layout)
   (epi-ledger--recovery-layout-raw-transaction-directory layout)
   (epi-ledger--recovery-layout-raw-manifest-path layout)
   (epi-ledger--recovery-layout-raw-manifest-temporary-path layout)
   (epi-ledger--recovery-layout-raw-source-stage-path layout)
   (epi-ledger--recovery-layout-raw-staged-source-ledger-path layout)
   (epi-ledger--recovery-layout-raw-staged-source-objects-path layout)
   (epi-ledger--recovery-layout-raw-absent-source-objects-marker-path layout)
   (epi-ledger--recovery-layout-raw-final-quarantine-path layout)))

(defun epi-ledger--recovery-snapshot-operational-layout (layout)
  "Return LAYOUT's bounded locator signature and control path without yield."
  (condition-case nil
      (let ((gc-cons-threshold most-positive-fixnum))
        (unless (epi-ledger--recovery-exact-record-p
                 layout #'epi-ledger--recovery-layout-p
                 epi-ledger--recovery-layout-record-size)
          (error "Invalid recovery layout"))
        (let ((fields
               (epi-ledger--recovery-manifest-layout-signature layout))
              owned)
          (dotimes (index 16)
            (push
             (if (= index 7)
                 (let ((device (nth index fields)))
                   (unless (epi-ledger--recovery-bounded-unsigned-p device)
                     (error "Invalid recovery device"))
                   device)
               (epi-ledger--recovery-copy-plan-string
                (nth index fields) epi-header-value-byte-limit))
             owned))
          (list
           (nreverse owned)
           (epi-ledger--recovery-copy-plan-string
            (epi-ledger--recovery-layout-raw-control-directory layout)
            epi-header-value-byte-limit))))
    (error
     (epi-ledger--fail
      'epi-ledger-conflict 'recovery-preflight-changed))))

(defun epi-ledger--recovery-snapshot-source-head-record (record)
  "Return RECORD's bounded head-verification scalars without a callback."
  (condition-case nil
      (let ((gc-cons-threshold most-positive-fixnum))
        (unless (epi-ledger--recovery-exact-record-p
                 record #'epi-record-p epi-ledger--record-record-size)
          (error "Invalid recovery source head"))
        (let* ((hash
                (epi-ledger--recovery-copy-plan-string
                 (epi-record--raw-hash record) 64))
               (sequence (epi-record--raw-sequence record))
               (start (epi-record--raw-start-offset record))
               (json-start (epi-record--raw-json-start-offset record))
               (end (epi-record--raw-end-offset record))
               (frame-size (epi-record--raw-frame-byte-size record)))
          (unless (and (epi-ledger--hash-p hash)
                       (epi-ledger--recovery-bounded-unsigned-p sequence)
                       (> sequence 0)
                       (epi-ledger--recovery-bounded-unsigned-p start)
                       (epi-ledger--recovery-bounded-unsigned-p json-start)
                       (epi-ledger--recovery-bounded-unsigned-p end)
                       (epi-ledger--recovery-bounded-unsigned-p frame-size)
                       (< start json-start)
                       (< json-start end)
                       (<= frame-size epi-record-frame-byte-limit)
                       (= frame-size (- end start)))
            (error "Invalid recovery source head scalars"))
          ;; Only these scalars participate in the raw final-head proof.  Do
          ;; not copy the caller's potentially large payload before yielding.
          (epi-ledger--make-record
           :hash hash :sequence sequence
           :start-offset start :json-start-offset json-start
           :end-offset end :frame-byte-size frame-size)))
    (error
     (epi-ledger--fail
      'epi-ledger-conflict 'recovery-preflight-changed))))

(defun epi-ledger--recovery-snapshot-complete-record (record)
  "Return a callback-free, ownership-disjoint complete copy of RECORD."
  (condition-case nil
      (let ((gc-cons-threshold most-positive-fixnum))
        (unless (epi-ledger--recovery-exact-record-p
                 record #'epi-record-p epi-ledger--record-record-size)
          (error "Invalid recovery source record"))
        (let* ((type (epi-record--raw-type record))
               (sequence (epi-record--raw-sequence record))
               (start (epi-record--raw-start-offset record))
               (json-start (epi-record--raw-json-start-offset record))
               (json-end (epi-record--raw-json-end-offset record))
               (end (epi-record--raw-end-offset record))
               (frame-size (epi-record--raw-frame-byte-size record))
               (hash
                (epi-ledger--recovery-copy-plan-string
                 (epi-record--raw-hash record) 64))
               (envelope
                (epi-ledger--snapshot-canonical-value
                 (epi-ledger--envelope record)
                 epi-record-json-byte-limit 'record-json-byte-limit))
               (value
                (lambda (key) (epi-ledger--object-value envelope key)))
               (optional
                (lambda (key)
                  (and (epi-ledger--object-has-key-p envelope key)
                       (funcall value key)))))
          (unless
              (and (symbolp type)
                   (equal (symbol-name type) (funcall value "type"))
                   (epi-ledger--hash-p hash)
                   (epi-ledger--recovery-bounded-unsigned-p sequence)
                   (> sequence 0)
                   (epi-ledger--recovery-bounded-unsigned-p start)
                   (epi-ledger--recovery-bounded-unsigned-p json-start)
                   (epi-ledger--recovery-bounded-unsigned-p json-end)
                   (epi-ledger--recovery-bounded-unsigned-p end)
                   (epi-ledger--recovery-bounded-unsigned-p frame-size)
                   (< start json-start)
                   (< json-start json-end)
                   (< json-end end)
                   (= frame-size (- end start))
                   (<= frame-size epi-record-frame-byte-limit))
            (error "Invalid recovery source record fields"))
          (epi-ledger--make-record
           :id (funcall value "id")
           :type type
           :schema (funcall value "schema")
           :at (funcall value "at")
           :previous-hash (funcall value "previous_hash")
           :hash hash
           :parent (funcall optional "parent")
           :target (funcall optional "target")
           :turn (funcall optional "turn")
           :operation (funcall optional "operation")
           :payload (funcall value "payload")
           :sequence sequence
           :start-offset start
           :json-start-offset json-start
           :json-end-offset json-end
           :end-offset end
           :frame-byte-size frame-size
           :sealed-json nil)))
    (error
     (epi-ledger--fail
      'epi-ledger-conflict 'recovery-preflight-changed))))

(defun epi-ledger--recovery-require-source-head-snapshot
    (record preflight)
  "Require owned head RECORD to agree with closed PREFLIGHT authority."
  (let* ((proof (epi-ledger--recovery-preflight-raw-source-proof preflight))
         (next (epi-ledger--recovery-source-proof-next-sequence proof))
         (end (epi-ledger--recovery-source-proof-validated-end proof)))
    (unless (and (epi-ledger--recovery-exact-record-p
                  record #'epi-record-p epi-ledger--record-record-size)
                 (epi-ledger--recovery-bounded-unsigned-p next)
                 (> next 1)
                 (= (epi-record--raw-sequence record) (1- next))
                 (= (epi-record--raw-end-offset record) end)
                 (equal (epi-record--raw-hash record)
                        (epi-ledger--recovery-source-proof-valid-prefix-head
                         proof)))
      (epi-ledger--fail
       'epi-ledger-conflict 'recovery-preflight-changed))
    record))

(defun epi-ledger--recovery-require-complete-source-record
    (record preflight)
  "Cooperatively verify owned complete RECORD against closed PREFLIGHT."
  (condition-case nil
      (progn
        (epi-ledger--validate-record-fields record t)
        (let ((snapshot (epi-ledger--recovery-snapshot-record record)))
          (epi-ledger--recovery-verify-source-record
           snapshot
           (epi-record--raw-sequence record)
           (epi-record--raw-previous-hash record)
           nil))
        (epi-ledger--recovery-require-source-head-snapshot record preflight))
    (error
     (epi-ledger--fail
      'epi-ledger-conflict 'recovery-preflight-changed))))

(defun epi-ledger--recovery-close-operational-layout
    (candidate-signature candidate-control authoritative root control)
  "Close CANDIDATE-SIGNATURE against AUTHORITATIVE and rebuild authority.
CANDIDATE-CONTROL is the separately captured redundant control path.
ROOT and CONTROL are freshly captured identities.  Durable manifests do not
authenticate parent-directory creation receipts, so re-entry deliberately
normalizes the runtime anchor to the quarantine root and retains no receipts."
  (let* ((fields
          (epi-ledger--recovery-manifest-layout-signature authoritative))
         (transaction-path (nth 8 fields))
         (root-path (nth 6 fields))
         (control-directory
          (directory-file-name (file-name-directory transaction-path))))
    (unless
        (and
         (equal candidate-signature fields)
         (equal candidate-control control-directory)
         (equal root-path (plist-get root :path))
         (equal control-directory (plist-get control :path)))
      (epi-ledger--fail
       'epi-ledger-conflict 'recovery-preflight-changed))
    (cl-labels ((path (index)
                  (substring-no-properties (nth index fields))))
      (epi-ledger--make-recovery-layout
       :source-path (path 0)
       :source-objects-path (path 1)
       :destination-path (path 2)
       :destination-objects-path (path 3)
       :staged-destination-ledger-path (path 4)
       :staged-destination-objects-path (path 5)
       :quarantine-root (path 6)
       :quarantine-device (nth 7 fields)
       :quarantine-anchor-path (path 6)
       :quarantine-anchor-identity
       (epi-ledger--copy-tree-and-strings root)
       :quarantine-root-identity
       (epi-ledger--copy-tree-and-strings root)
       :control-directory (substring-no-properties control-directory)
       :control-identity (epi-ledger--copy-tree-and-strings control)
       :transaction-directory (path 8)
       :manifest-path (path 9)
       :manifest-temporary-path (path 10)
       :source-stage-path (path 11)
       :staged-source-ledger-path (path 12)
       :staged-source-objects-path (path 13)
       :absent-source-objects-marker-path (path 14)
       :final-quarantine-path (path 15)))))

(defun epi-ledger--recovery-snapshot-prepared-entry (prepared)
  "Capture PREPARED's authority-bearing entry state without a callback."
  (let ((gc-cons-threshold most-positive-fixnum))
    (unless (epi-ledger--recovery-exact-record-p
             prepared #'epi-ledger--recovery-prepared-p
             epi-ledger--recovery-prepared-record-size)
      (epi-ledger--format-fail 'recovery-preflight-required))
    (list
     (epi-ledger--recovery-snapshot-preflight-authority
      (epi-ledger--recovery-prepared-raw-preflight prepared))
     (epi-ledger--recovery-snapshot-operational-layout
      (epi-ledger--recovery-prepared-raw-path-layout prepared))
     (epi-ledger--recovery-snapshot-source-head-record
      (epi-ledger--recovery-prepared-raw-source-last-record prepared)))))

(defun epi-ledger--recovery-close-prepared-input
    (prepared &optional entry-snapshot)
  "Return an ownership-disjoint closed copy of durable PREPARED.
ENTRY-SNAPSHOT, when non-nil, is prior private callback-free entry authority."
  (let* ((entry
          (or entry-snapshot
              (epi-ledger--recovery-snapshot-prepared-entry prepared)))
         (input-preflight (nth 0 entry))
         (locator (nth 1 entry))
         (candidate-signature (nth 0 locator))
         (candidate-control (nth 1 locator))
         (owned-last-record (nth 2 entry)))
    (let* ((preflight
              (epi-ledger--recovery-close-preflight nil input-preflight))
             (_source-head
              (epi-ledger--recovery-require-source-head-snapshot
               owned-last-record preflight))
             (oracle
              (epi-ledger--recovery-preflight-raw-manifest-bytes
               preflight))
             (authoritative-layout
              (epi-ledger--recovery-preflight-raw-layout preflight))
             (fields
              (epi-ledger--recovery-manifest-layout-signature
               authoritative-layout))
             (device (nth 7 fields))
             (root-path (nth 6 fields))
             (transaction-path (nth 8 fields))
             (manifest-path (nth 9 fields))
             (control-path
              (directory-file-name
               (file-name-directory transaction-path)))
             (root-initial
              (epi-ledger--recovery-raw-directory-stat root-path))
             (root
              (epi-ledger--recovery-require-bound-directory-raw
               root-path root-initial device))
             (control-initial
              (epi-ledger--recovery-raw-directory-stat control-path))
             (control
              (epi-ledger--recovery-require-bound-directory-raw
               control-path control-initial device #o700))
             (transaction-initial
              (epi-ledger--recovery-raw-directory-stat transaction-path))
             (transaction
              (epi-ledger--recovery-require-bound-directory-raw
               transaction-path transaction-initial device #o700))
             (manifest
              (epi-ledger--recovery-require-manifest-links
               (epi-ledger--recovery-verify-manifest-epoch
                manifest-path oracle)
               1))
             (_manifest-device
              (unless (= device (or (plist-get manifest :device) -1))
                (epi-ledger--fail
                 'epi-ledger-conflict 'quarantine-cross-device)))
             (_temporary-absent
              (epi-ledger--recovery-require-manifest-temporary-absent-raw
               authoritative-layout))
             (entry-state
              (epi-ledger--recovery-capture-transaction-entry-state-raw
               authoritative-layout transaction))
             (transaction-state-identity
              (epi-ledger--copy-tree-and-strings
               (plist-get entry-state :identity)))
             (transaction-final
              (epi-ledger--recovery-require-bound-directory-raw
               transaction-path transaction-state-identity device #o700))
             (_transaction-exact
              (unless (equal transaction-state-identity transaction-final)
                (epi-ledger--fail
                 'epi-ledger-conflict 'recovery-path-conflict)))
             (_manifest-exact
              (epi-ledger--recovery-require-manifest-epoch-raw
               manifest-path manifest))
             (closed-layout
              (epi-ledger--recovery-close-operational-layout
               candidate-signature candidate-control
               authoritative-layout root control))
             (closed
              (epi-ledger--make-recovery-prepared
               :preflight preflight
               :quarantine-anchor-identity root
               :quarantine-root-identity root
               :control-identity control
               :directory-receipts nil
               :transaction-identity transaction-final
               :manifest-identity manifest
               :transaction-entry-state entry-state
               :source-last-record owned-last-record
               :path-layout closed-layout)))
        (epi-ledger--recovery-close-unlocked-prepared-raw closed)
        (epi-ledger--recovery-require-transaction-entry-state-raw
         closed-layout entry-state t)
        closed)))

(defun epi-ledger--recovery-manifest-for-phase (preflight phase)
  "Return PREFLIGHT's owned manifest object and canonical bytes for PHASE."
  (unless (member phase epi-ledger--recovery-manifest-phases)
    (epi-ledger--recovery-manifest-invalid))
  (let* ((manifest
          (copy-tree
           (epi-ledger--recovery-preflight-raw-manifest-object preflight)
           t))
         (entry (assoc "phase" manifest)))
    (unless entry
      (epi-ledger--recovery-manifest-invalid))
    (setcdr entry (substring-no-properties phase))
    (setq manifest
          (epi-ledger--recovery-validate-manifest manifest phase))
    (list manifest
          (epi-ledger--jcs-encode manifest epi-record-json-byte-limit))))

(defun epi-ledger--recovery-object-path-under-root (root hash)
  "Return HASH's immutable object pathname below existing ROOT."
  (epi-ledger--require-hash hash "object.hash")
  (expand-file-name
   hash
   (file-name-as-directory
    (expand-file-name
     (substring hash 0 2)
     (file-name-as-directory
      (expand-file-name "sha256" (file-name-as-directory root)))))))

(defun epi-ledger--recovery-transfer-items (preflight)
  "Return the sorted physical object work vector for PREFLIGHT."
  (let* ((references
          (epi-ledger--recovery-preflight-raw-reachable-objects preflight))
         (identities
          (epi-ledger--recovery-preflight-raw-reachable-object-identities
           preflight))
         (layout (epi-ledger--recovery-preflight-raw-layout preflight))
         (source (epi-ledger--recovery-layout-raw-source-path layout))
         (manifest
          (epi-ledger--recovery-preflight-raw-manifest-object preflight))
         (fragment
          (copy-tree
           (epi-ledger--object-value manifest "fragment_object") t))
         (by-hash (make-hash-table :test #'equal))
         items)
    (unless (and (vectorp references) (vectorp identities)
                 (= (length references) (length identities)))
      (epi-ledger--recovery-manifest-invalid))
    (dotimes (index (length references))
      (let* ((reference (aref references index))
             (hash (epi-ledger--object-value reference "hash"))
             (size (epi-ledger--object-value reference "size"))
             (item
              (list :hash (substring-no-properties hash)
                    :size size
                    :kind 'historical
                    :source
                    (epi-ledger--object-path-for-ledger-path source hash)
                    :source-identity
                    (epi-ledger--recovery-copy-file-identity
                     (aref identities index)))))
        (puthash hash item by-hash)
        (push item items)))
    (let* ((hash (epi-ledger--object-value fragment "hash"))
           (size (epi-ledger--object-value fragment "size"))
           (prior (gethash hash by-hash)))
      (if prior
          (unless (= size (plist-get prior :size))
            (epi-ledger--recovery-manifest-invalid))
        (let ((item
               (list :hash (substring-no-properties hash)
                     :size size :kind 'fragment)))
          (puthash hash item by-hash)
          (push item items))))
    (vconcat
     (sort items
           (lambda (left right)
             (string< (plist-get left :hash)
                      (plist-get right :hash)))))))

(defun epi-ledger--recovery-read-range-bounded (path start size)
  "Read exactly SIZE bytes from PATH at START through bounded requests."
  (unless (and (integerp start) (>= start 0)
               (integerp size) (> size 0)
               (epi-ledger--safe-integer-p (+ start size)))
    (epi-ledger--recovery-manifest-invalid))
  (let ((owned-path (substring-no-properties path))
        (work (epi-ledger--make-work-state))
        (limit (max 1 epi-ledger-work-byte-limit))
        (cursor 0)
        chunks)
    (while (< cursor size)
      (let* ((amount (min limit (- size cursor)))
             (begin (+ start cursor))
             (end (+ begin amount)))
        (epi-ledger--work-charge work amount)
        (let ((chunk
               (condition-case nil
                   (funcall epi-ledger--read-function
                            (substring-no-properties owned-path) begin end)
                 (error
                  (epi-ledger--fail
                   'epi-ledger-conflict 'recovery-preflight-changed)))))
          (unless (and (stringp chunk)
                       (not (multibyte-string-p chunk))
                       (= amount (length chunk))
                       (not (epi-ledger--string-has-properties-p chunk)))
            (epi-ledger--fail
             'epi-ledger-conflict 'recovery-preflight-changed))
          (push (substring-no-properties chunk) chunks))
        (setq cursor (+ cursor amount))))
    (setq chunks (epi-ledger--work-nreverse-list chunks work))
    (epi-ledger--work-concat-chunks
     chunks size work 'recovery-fragment)))

(defun epi-ledger--recovery-object-stage-directory-paths (layout items)
  "Return ordered private directory paths for LAYOUT and transfer ITEMS."
  (let* ((root
          (epi-ledger--recovery-layout-raw-staged-destination-objects-path
           layout))
         (sha (expand-file-name "sha256" (file-name-as-directory root)))
         prefixes)
    (dotimes (index (length items))
      (cl-pushnew
       (substring (plist-get (aref items index) :hash) 0 2)
       prefixes :test #'equal))
    (setq prefixes (sort prefixes #'string<))
    (append
     (list root sha)
     (mapcar
      (lambda (prefix)
        (expand-file-name prefix (file-name-as-directory sha)))
      prefixes))))

(defun epi-ledger--recovery-create-object-stage-directories
    (layout items destination-parent-identity &optional receipt-receiver)
  "Create LAYOUT's object stage for ITEMS under DESTINATION-PARENT-IDENTITY.
Deliver each exact new-directory receipt to RECEIPT-RECEIVER when non-nil."
  (let* ((receiver
          (or receipt-receiver
              epi-ledger--recovery-directory-receipt-receiver))
         (epi-ledger--recovery-directory-receipt-receiver nil)
         (device (plist-get destination-parent-identity :device))
         (paths
          (epi-ledger--recovery-object-stage-directory-paths layout items))
         receipts complete)
    (epi-ledger--recovery-close-destination-parent-raw
     layout destination-parent-identity)
    (unwind-protect
        (progn
          (dolist (path paths)
            (push
             (cons
              (substring-no-properties path)
              (epi-ledger--recovery-create-private-directory
               path device receiver))
             receipts))
          (setq receipts (nreverse receipts)
                complete t)
          receipts)
      (unless complete
        (epi-ledger--recovery-rollback-directory-receipts
         (nreverse receipts))))))

(defun epi-ledger--recovery-require-private-file-state-raw
    (path expected expected-size code &optional exact-identity-p)
  "Raw-require PATH as private EXPECTED with EXPECTED-SIZE or fail CODE.
When EXACT-IDENTITY-P is non-nil, require the complete identity epoch rather
than only the same file object."
  (let* ((first (epi-ledger--raw-object-name-state path))
         (mode (and first (epi-ledger--recovery-raw-mode path)))
         (second (epi-ledger--raw-object-name-state path)))
    (unless (and first (equal first second)
                 (equal path (plist-get expected :path))
                 (equal path (plist-get second :path))
                 (epi-ledger--same-file-object-p expected second)
                 (or (not exact-identity-p) (equal expected second))
                 (= expected-size (or (plist-get second :size) -1))
                 (= 1 (or (plist-get second :links) -1))
                 (= #o600 mode))
      (epi-ledger--fail 'epi-ledger-conflict code))
    second))

(defun epi-ledger--recovery-delete-owned-file-best-effort (path identity)
  "Best-effort delete PATH only while it remains exact IDENTITY."
  (condition-case nil
      (epi-ledger--delete-owned-object-name path identity nil)
    ((error quit) nil)))

(defun epi-ledger--recovery-reserve-private-file-raw
    (path role &optional receipt-receiver)
  "Reserve empty private PATH for ROLE without an injectable storage seam.
Return the exact one-link identity receipt.  Before return, deliver an owned
receipt to RECEIPT-RECEIVER when it is non-nil.  The legacy dynamic receiver
remains a direct-call fallback."
  (let* ((receiver
          (or receipt-receiver epi-ledger--recovery-file-receipt-receiver))
         (epi-ledger--recovery-file-receipt-receiver nil)
         (owned-path (substring-no-properties path)) identity complete)
    (unwind-protect
        (progn
          (when (epi-ledger--raw-object-name-state owned-path)
            (epi-ledger--fail
             'epi-ledger-conflict 'recovery-path-conflict))
          (condition-case condition
              (epi-ledger--write-bytes
               owned-path "" 'exclusive-create t)
            ((error quit)
             (signal (car condition) (cdr condition))))
          (setq identity
                (epi-ledger--recovery-require-private-file-state-raw
                 owned-path
                 (epi-ledger--recovery-require-manifest-links
                  (epi-ledger--recovery-capture-manifest-epoch-raw
                   owned-path 0)
                  1)
                 0 'recovery-path-conflict))
          (when receiver
            (funcall
             receiver role
             (substring-no-properties owned-path)
             (epi-ledger--recovery-copy-file-identity identity)))
          (setq complete t)
          identity)
      (unless complete
        (when identity
          (epi-ledger--recovery-delete-owned-file-best-effort
           owned-path identity))))))

(defun epi-ledger--recovery-copy-object-bytes
    (path bytes size hash &optional receipt-receiver)
  "Copy BYTES to new staged PATH and return its verified identity.
Deliver the exact empty-file reservation to RECEIPT-RECEIVER before writes."
  (unless (and (stringp bytes) (not (multibyte-string-p bytes))
               (= size (length bytes))
               (equal hash
                      (epi-ledger--hash bytes 'recovery-object-copy)))
    (epi-ledger--fail
     'epi-ledger-conflict 'recovery-object-content-changed))
  (let* ((receiver
          (or receipt-receiver epi-ledger--recovery-file-receipt-receiver))
         (epi-ledger--recovery-file-receipt-receiver nil)
         (owned-path (substring-no-properties path))
        (oracle bytes)
        (work (epi-ledger--make-work-state))
        (limit (max 1 epi-ledger-work-byte-limit))
        (cursor 0)
        (first t)
        created final complete)
    (cl-labels
        ((require-created
          (expected-size)
          (epi-ledger--recovery-require-private-file-state-raw
           owned-path created expected-size
           'recovery-object-content-changed)))
      (unwind-protect
          (progn
            (setq created
                  (epi-ledger--recovery-reserve-private-file-raw
                   owned-path 'staged-object receiver))
            (while (< cursor size)
              (let* ((end (min size (+ cursor limit)))
                     (amount (- end cursor)))
                ;; Yield before touching the reserved object, then prove the
                ;; same exact file and prefix on both sides of the callback.
                (epi-ledger--work-charge work amount)
                (require-created cursor)
                (funcall epi-ledger--byte-writer
                         (substring-no-properties owned-path)
                         (substring-no-properties oracle cursor end)
                         (if first 'replace 'append) nil)
                (setq first nil
                      cursor end)
                (require-created cursor)))
            (require-created size)
            (funcall epi-ledger--byte-writer
                     (substring-no-properties owned-path) "" 'append t)
            (require-created size)
          ;; The cooperative pass is the one content authority for this live
          ;; epoch.  Keep normal yields, but bypass caller-injectable storage
          ;; readers so fabricated bytes cannot acquire a trusted identity.
          (let* ((file-name-handler-alist nil)
                 (epi-ledger--stat-function #'epi-ledger--stat-local-file)
                 (epi-ledger--read-function #'epi-ledger--read-bytes)
                 (verified
                  (epi-ledger--object-read-verified-state
                   (substring-no-properties owned-path) size hash 'proof)))
            (setq final
                  (epi-ledger--copy-tree-and-strings
                   (plist-get verified :identity))))
          ;; Content was verified cooperatively exactly once above.  Close
          ;; that epoch without repeating an unyielding hash pass.
          (setq final
                (epi-ledger--recovery-require-private-file-state-raw
                 owned-path final size
                 'recovery-object-content-changed t))
          (unless (epi-ledger--same-file-object-p created final)
            (epi-ledger--fail
             'epi-ledger-conflict 'recovery-object-content-changed))
            (setq complete t)
            final)
        (unless complete
          (when created
            (epi-ledger--recovery-delete-owned-file-best-effort
             owned-path created)))))))

(defun epi-ledger--recovery-clean-object-stage
    (ledger-path ledger-identity files directories)
  "Best-effort remove staged LEDGER-PATH as LEDGER-IDENTITY.
Also remove receipt-bound FILES and DIRECTORIES."
  (cl-labels
      ((clean-files
        (pending)
        (when pending
          (unwind-protect
              (condition-case nil
                  (epi-ledger--delete-owned-object-name
                   (caar pending) (cdar pending) nil)
                ((error quit) nil))
            (clean-files (cdr pending)))))
       (clean-directories
        (pending)
        (when pending
          (unwind-protect
              (condition-case nil
                  (epi-ledger--recovery-delete-exact-empty-directory
                   (caar pending) (cdar pending))
                ((error quit) nil))
            (clean-directories (cdr pending))))))
    (unwind-protect
        (when ledger-identity
          (condition-case nil
              (epi-ledger--delete-owned-object-name
               ledger-path ledger-identity nil)
            ((error quit) nil)))
      (unwind-protect
          (clean-files (reverse (copy-sequence files)))
        (clean-directories (reverse (copy-sequence directories)))))))

(defun epi-ledger--recovery-require-object-stage-raw
    (layout items directory-receipts file-receipts
            destination-parent-identity &optional exact-directories-p)
  "Raw-prove LAYOUT's exact staged tree from its original receipts.
ITEMS names the expected object leaves.  DIRECTORY-RECEIPTS and FILE-RECEIPTS
bind storage under DESTINATION-PARENT-IDENTITY.  When EXACT-DIRECTORIES-P is
non-nil, directory metadata epochs must also remain exact.  Return refreshed
receipts."
  (let* ((root
          (epi-ledger--recovery-layout-raw-staged-destination-objects-path
           layout))
         (sha (expand-file-name "sha256" (file-name-as-directory root)))
         (device (plist-get destination-parent-identity :device))
         prefixes expected-files expected-directories
         refreshed-files refreshed-directories)
    (epi-ledger--recovery-close-destination-parent-raw
     layout destination-parent-identity)
    (dotimes (index (length items))
      (let* ((item (aref items index))
             (hash (plist-get item :hash))
             (path (epi-ledger--recovery-object-path-under-root root hash)))
        (push (cons hash path) expected-files)
        (cl-pushnew (substring hash 0 2) prefixes :test #'equal)))
    (setq prefixes (sort prefixes #'string<)
          expected-files
          (sort expected-files (lambda (left right) (string< (car left)
                                                              (car right))))
          expected-directories
          (append
           (list root sha)
           (mapcar
            (lambda (prefix)
              (expand-file-name prefix (file-name-as-directory sha)))
            prefixes)))
    (unless (equal '("sha256")
                   (epi-ledger--recovery-raw-directory-entry-names root 1))
      (epi-ledger--fail 'epi-ledger-conflict 'recovery-path-conflict))
    (unless (equal prefixes
                   (epi-ledger--recovery-raw-directory-entry-names
                    sha (length prefixes)))
      (epi-ledger--fail 'epi-ledger-conflict 'recovery-path-conflict))
    (dolist (prefix prefixes)
      (let* ((directory
              (expand-file-name prefix (file-name-as-directory sha)))
             (expected
              (mapcar #'car
                      (seq-filter
                       (lambda (entry)
                         (equal prefix (substring (car entry) 0 2)))
                       expected-files))))
        (unless (equal expected
                       (epi-ledger--recovery-raw-directory-entry-names
                        directory (length expected)))
          (epi-ledger--fail
           'epi-ledger-conflict 'recovery-path-conflict))))
    (let ((receipt-tail directory-receipts))
      (dolist (path expected-directories)
        (let ((receipt (and (consp receipt-tail) (car receipt-tail))))
          (unless (and (consp receipt)
                       (equal path (car receipt))
                       (listp (cdr receipt)))
            (epi-ledger--fail
             'epi-ledger-conflict 'recovery-path-conflict))
          (let ((actual
                 (epi-ledger--recovery-require-bound-directory-raw
                  path (cdr receipt) device #o700)))
            (when (and exact-directories-p
                       (not (equal (cdr receipt) actual)))
              (epi-ledger--fail
               'epi-ledger-conflict 'recovery-path-conflict))
            (push (cons path actual) refreshed-directories))
          (setq receipt-tail (cdr receipt-tail))))
      (unless (null receipt-tail)
        (epi-ledger--fail
         'epi-ledger-conflict 'recovery-path-conflict)))
    (setq refreshed-directories (nreverse refreshed-directories))
    (dolist (entry expected-files)
      (let* ((hash (car entry))
             (path (cdr entry))
             (item
              (seq-find
               (lambda (candidate)
                 (equal hash (plist-get candidate :hash)))
               items))
             (receipt (assoc path file-receipts))
             (identity
              (and receipt
                   (epi-ledger--recovery-require-private-file-state-raw
                    path (cdr receipt) (plist-get item :size)
                    'recovery-object-content-changed t))))
        (unless (and receipt identity
                     (equal (cdr receipt) identity)
                     (= device (or (plist-get identity :device) -1))
                     (= 1 (or (plist-get identity :links) -1)))
          (epi-ledger--fail
           'epi-ledger-conflict 'recovery-object-content-changed))
        (push (cons path identity) refreshed-files)))
    (epi-ledger--recovery-close-destination-parent-raw
     layout destination-parent-identity)
    (list
     (cdr (assoc root refreshed-directories))
     refreshed-directories
     (nreverse refreshed-files))))

(defun epi-ledger--recovery-record-source-count-p (source expected)
  "Return non-nil when private record SOURCE has exactly EXPECTED entries.
Record indexes and vectors answer in constant time.  The tiny-work fallback
list is traversed cooperatively for at most EXPECTED plus one cells, so an
improper or cyclic source cannot turn validation into an unbounded walk."
  (and
   (epi-ledger--recovery-bounded-unsigned-p expected)
   (cond
    ((epi-ledger--recovery-exact-record-p
      source #'epi-ledger--record-index-p
      epi-ledger--record-index-record-size)
     (= expected (epi-ledger--record-index-raw-count source)))
    ((vectorp source) (= expected (length source)))
    ((or (null source) (consp source))
     (epi-ledger--with-operation-work-state
       (let ((tail source)
             (work (epi-ledger--make-work-state))
             (count 0))
         (while (and (consp tail) (<= count expected))
           (setq tail (epi-ledger--work-cdr tail work)
                 count (1+ count)))
         (and (= count expected) (null tail)))))
    (t nil))))

(defun epi-ledger--recovery-stage-ledger
    (inspection preflight layout &optional receipt-receiver)
  "Stream INSPECTION under PREFLIGHT into LAYOUT's hidden destination ledger.
Deliver the exact empty-file reservation to RECEIPT-RECEIVER before writes."
  (let* ((receiver
          (or receipt-receiver epi-ledger--recovery-file-receipt-receiver))
         (epi-ledger--recovery-file-receipt-receiver nil)
         (path
          (epi-ledger--recovery-layout-raw-staged-destination-ledger-path
           layout))
         (plan (epi-ledger--recovery-preflight-raw-reseal-plan preflight))
         (destination-device
          (plist-get
           (epi-ledger--recovery-preflight-raw-destination-parent-identity
            preflight)
           :device))
         (work (epi-ledger--make-work-state))
         (limit (max 1 epi-ledger-work-byte-limit))
         (first t)
         (total 0)
         created final complete)
    (unwind-protect
        (condition-case err
            (progn
              (epi-ledger--recovery-reprove-destination-parent-raw
               preflight layout)
              (setq created
                    (epi-ledger--recovery-reserve-private-file-raw
                     path 'staged-ledger receiver))
              (epi-ledger--recovery-stream-reseal
               inspection plan
               (lambda (bytes)
                 (unless (and (stringp bytes)
                              (not (multibyte-string-p bytes))
                              (not
                               (epi-ledger--string-has-properties-p bytes)))
                   (epi-ledger--fail
                    'epi-ledger-conflict 'recovery-staged-ledger-invalid))
                 (let ((cursor 0))
                   (while (< cursor (length bytes))
                     (let* ((end (min (length bytes) (+ cursor limit)))
                            (amount (- end cursor)))
                       (epi-ledger--work-charge work amount)
                       ;; The yield above may have rebound either pathname.
                       ;; Close both before and after delegating the write.
                       (epi-ledger--recovery-reprove-destination-parent-raw
                        preflight layout)
                       (epi-ledger--recovery-require-private-file-state-raw
                        path created total
                        'recovery-staged-ledger-invalid)
                       (funcall
                        epi-ledger--byte-writer
                        (substring-no-properties path)
                        (substring-no-properties bytes cursor end)
                        (if first 'replace 'append) nil)
                       (setq first nil
                             cursor end
                             total (+ total amount))
                       (epi-ledger--recovery-require-private-file-state-raw
                        path created total
                        'recovery-staged-ledger-invalid)
                       (epi-ledger--recovery-reprove-destination-parent-raw
                        preflight layout))))))
              (when first
                (epi-ledger--fail
                 'epi-ledger-conflict 'recovery-staged-ledger-invalid))
              (epi-ledger--recovery-reprove-destination-parent-raw
               preflight layout)
              (epi-ledger--recovery-require-private-file-state-raw
               path created total 'recovery-staged-ledger-invalid)
              (funcall epi-ledger--byte-writer
                       (substring-no-properties path) "" 'append t)
              (epi-ledger--recovery-require-private-file-state-raw
               path created total 'recovery-staged-ledger-invalid)
              (epi-ledger--recovery-reprove-destination-parent-raw
               preflight layout)
              (setq final (epi-ledger--stat-local-file path))
              (unless (and final
                           (epi-ledger--same-file-object-p created final)
                           (= total
                              (epi-ledger--recovery-reseal-plan-byte-size
                               plan))
                           (= total (or (plist-get final :size) -1))
                           (= destination-device
                              (or (plist-get final :device) -1))
                           (= 1 (or (plist-get final :links) -1))
                           (= #o600 (epi-ledger--recovery-raw-mode path)))
                (epi-ledger--fail
                 'epi-ledger-conflict 'recovery-staged-ledger-invalid))
              ;; Validation remains cooperative, but its bytes and publication
              ;; identities come from the local file rather than injectable
              ;; reader seams.  Later raw closures need only restat this epoch.
              (let* ((file-name-handler-alist nil)
                     (epi-ledger--stat-function
                      #'epi-ledger--stat-local-file)
                     (epi-ledger--read-function #'epi-ledger--read-bytes)
                     (epi-ledger--open-identity-reader
                      #'epi-ledger--file-identity)
                     (epi-ledger--open-source-inserter
                      #'insert-file-contents-literally)
                     (epi-ledger--open-head-inserter
                      #'insert-file-contents-literally)
                     (opened
                      (epi-ledger--inspect-path-core
                       (substring-no-properties path) 'complete)))
                (unless
                    (and
                     (eq (epi-ledger--inspection-raw-state opened) 'complete)
                     (equal
                      final
                      (epi-ledger--inspection-raw-file-identity opened))
                     (= total
                        (epi-ledger--inspection-raw-source-size opened))
                     (equal
                      (epi-ledger--recovery-reseal-plan-destination-session-id
                       plan)
                      (epi-header--raw-session-id
                       (epi-ledger--inspection-raw-header opened)))
                     (equal
                      (epi-ledger--recovery-reseal-plan-destination-header-sha256
                       plan)
                      (epi-header--raw-hash
                       (epi-ledger--inspection-raw-header opened)))
                     (equal
                      (epi-ledger--recovery-reseal-plan-final-head plan)
                      (epi-ledger--inspection-raw-valid-prefix-head opened))
                     (let* ((index
                             (epi-ledger--inspection-raw-record-index opened))
                            (expected
                             (epi-ledger--recovery-reseal-plan-output-record-count
                              plan)))
                       (and
                        (epi-ledger--recovery-record-source-count-p
                         index expected)
                        (= (1+ expected)
                           (epi-ledger--inspection-raw-next-sequence
                            opened)))))
                  (epi-ledger--fail
                   'epi-ledger-conflict 'recovery-staged-ledger-invalid)))
              (setq final
                    (epi-ledger--recovery-require-private-file-state-raw
                     path final total
                     'recovery-staged-ledger-invalid t))
              (setq complete t)
              (epi-ledger--copy-tree-and-strings final))
          (epi-ledger-conflict
           (if (eq
                'recovery-path-conflict
                (plist-get
                 (epi-ledger--condition-plist err) :code))
               (signal (car err) (cdr err))
             (epi-ledger--fail
              'epi-ledger-conflict 'recovery-staged-ledger-invalid)))
          (quit
           (signal (car err) (cdr err)))
          (error
           (epi-ledger--fail
            'epi-ledger-conflict 'recovery-staged-ledger-invalid)))
      (unless complete
        (when created
          (epi-ledger--recovery-delete-owned-file-best-effort
           path created))))))

(defun epi-ledger--recovery-require-staged-ledger-raw
    (preflight layout expected)
  "Raw-prove PREFLIGHT's hidden destination ledger in LAYOUT as EXPECTED."
  (let* ((path
          (epi-ledger--recovery-layout-raw-staged-destination-ledger-path
           layout))
         (plan (epi-ledger--recovery-preflight-raw-reseal-plan preflight))
         (destination-device
          (plist-get
           (epi-ledger--recovery-preflight-raw-destination-parent-identity
            preflight)
           :device))
         (identity
          (and expected
               (epi-ledger--recovery-require-private-file-state-raw
                path expected
                (epi-ledger--recovery-reseal-plan-byte-size plan)
                'recovery-staged-ledger-invalid t))))
    (unless (and expected identity
                 (listp identity)
                 (epi-ledger--same-file-object-p expected identity)
                 (equal expected identity)
                 (=
                  (epi-ledger--recovery-reseal-plan-byte-size plan)
                  (or (plist-get identity :size) -1))
                 (= destination-device
                    (or (plist-get identity :device) -1))
                 (= 1 (or (plist-get identity :links) -1)))
      (epi-ledger--fail
       'epi-ledger-conflict 'recovery-staged-ledger-invalid))
    identity))

(defun epi-ledger--recovery-transferred-absent-paths (layout)
  "Return LAYOUT names that remain absent after object transfer."
  (list
   (epi-ledger--recovery-layout-raw-destination-path layout)
   (epi-ledger--recovery-layout-raw-destination-objects-path layout)
   (epi-ledger--recovery-layout-raw-source-stage-path layout)
   (epi-ledger--recovery-layout-raw-staged-source-ledger-path layout)
   (epi-ledger--recovery-layout-raw-staged-source-objects-path layout)
   (epi-ledger--recovery-layout-raw-absent-source-objects-marker-path layout)
   (epi-ledger--recovery-layout-raw-final-quarantine-path layout)))

(defun epi-ledger--recovery-require-transferred-absences-raw (layout)
  "Raw-require all post-transfer unpublished LAYOUT names absent."
  (dolist (path (epi-ledger--recovery-transferred-absent-paths layout))
    (when (epi-ledger--recovery-name-kind path)
      (epi-ledger--fail
       'epi-ledger-conflict
       (if (member
            path
            (list
             (epi-ledger--recovery-layout-raw-destination-path layout)
             (epi-ledger--recovery-layout-raw-destination-objects-path
              layout)))
           'recovery-destination-exists
         'recovery-path-conflict)))))

(defun epi-ledger--recovery-phase-transaction-entry-names
    (layout temporaryp)
  "Return sorted transaction entry names for LAYOUT and TEMPORARYP."
  (sort
   (append
    (list
     (file-name-nondirectory
      (epi-ledger--recovery-layout-raw-manifest-path layout)))
    (when temporaryp
      (list
       (file-name-nondirectory
        (epi-ledger--recovery-layout-raw-manifest-temporary-path layout)))))
   #'string<))

(defun epi-ledger--recovery-prepare-phase-manifest-temporary
    (prepared new-bytes &optional receipt-receiver)
  "Write PREPARED's NEW-BYTES phase temporary while old state remains exact.
Return its exact identity and the original transaction's two-entry state.
Deliver the exact empty-file reservation to RECEIPT-RECEIVER before writes."
  (let* ((receiver
          (or receipt-receiver epi-ledger--recovery-file-receipt-receiver))
         (epi-ledger--recovery-file-receipt-receiver nil)
         (layout (epi-ledger--recovery-prepared-raw-path-layout prepared))
         (manifest (epi-ledger--recovery-layout-raw-manifest-path layout))
         (temporary
          (epi-ledger--recovery-layout-raw-manifest-temporary-path layout))
         (old-identity
          (epi-ledger--recovery-prepared-raw-manifest-identity prepared))
         (transaction-identity
          (epi-ledger--recovery-prepared-raw-transaction-identity prepared))
         (transaction
          (epi-ledger--recovery-layout-raw-transaction-directory layout))
         (device
          (epi-ledger--recovery-layout-raw-quarantine-device layout))
         (work (epi-ledger--make-work-state))
         (limit (max 1 epi-ledger-work-byte-limit))
         (cursor 0)
         (first t)
         temporary-identity transaction-state complete)
    (unwind-protect
        (progn
          (epi-ledger--recovery-require-manifest-epoch-raw
           manifest old-identity)
          (epi-ledger--recovery-require-transaction-entry-state-raw
           layout
           (epi-ledger--recovery-prepared-raw-transaction-entry-state
            prepared))
          (epi-ledger--recovery-require-manifest-temporary-absent-raw layout)
          (setq temporary-identity
                (epi-ledger--recovery-reserve-private-file-raw
                 temporary 'phase-temporary receiver))
          (while (< cursor (length new-bytes))
            (let* ((end (min (length new-bytes) (+ cursor limit)))
                   (amount (- end cursor)))
              (epi-ledger--work-charge work amount)
              (epi-ledger--recovery-require-bound-directory-raw
               transaction transaction-identity device #o700)
              (epi-ledger--recovery-require-private-file-state-raw
               temporary temporary-identity cursor
               'recovery-manifest-invalid)
              (funcall epi-ledger--byte-writer
                       (substring-no-properties temporary)
                       (substring-no-properties new-bytes cursor end)
                       (if first 'replace 'append) nil)
              (setq first nil
                    cursor end)
              (epi-ledger--recovery-require-private-file-state-raw
               temporary temporary-identity cursor
               'recovery-manifest-invalid)
              (epi-ledger--recovery-require-bound-directory-raw
               transaction transaction-identity device #o700)))
          (when first
            (epi-ledger--fail
             'epi-ledger-conflict 'recovery-manifest-invalid))
          (epi-ledger--recovery-require-private-file-state-raw
           temporary temporary-identity cursor
           'recovery-manifest-invalid)
          (funcall epi-ledger--byte-writer
                   (substring-no-properties temporary) "" 'append t)
          (epi-ledger--recovery-require-private-file-state-raw
           temporary temporary-identity cursor
           'recovery-manifest-invalid)
          (epi-ledger--recovery-require-bound-directory-raw
           transaction transaction-identity device #o700)
          (let ((written
                 (epi-ledger--recovery-verify-manifest-epoch
                  temporary new-bytes temporary-identity)))
            (unless (and written
                         (epi-ledger--same-file-object-p
                          temporary-identity written))
              (epi-ledger--fail
               'epi-ledger-conflict 'recovery-manifest-invalid))
            (setq temporary-identity written))
          (setq transaction-state
                (epi-ledger--recovery-capture-transaction-entry-state-core-raw
                 layout transaction-identity
                 (epi-ledger--recovery-phase-transaction-entry-names
                  layout t))
                complete t)
          (list temporary-identity transaction-state))
      (unless complete
        (when temporary-identity
          (epi-ledger--recovery-delete-owned-file-best-effort
           temporary temporary-identity))))))

(defun epi-ledger--recovery-commit-phase-manifest-raw
    (temporary manifest temporary-identity)
  "Rename verified TEMPORARY to MANIFEST and return its new exact epoch.
TEMPORARY-IDENTITY binds the exact private file authorized for publication."
  (let ((file-name-handler-alist nil))
    ;; This full-epoch restat must be the last filesystem operation before the
    ;; primitive rename.  Callers suppress automatic GC across this boundary.
    (epi-ledger--recovery-require-manifest-epoch-raw
     temporary temporary-identity)
    (rename-file temporary manifest t)
    (let ((identity
           (epi-ledger--recovery-capture-manifest-epoch-raw
            manifest (plist-get temporary-identity :size)
            temporary-identity)))
      (unless (and (epi-ledger--recovery-renamed-manifest-epoch-p
                    manifest temporary-identity identity)
                   (null (epi-ledger--raw-object-name-state temporary)))
        (epi-ledger--fail
         'epi-ledger-conflict 'recovery-manifest-invalid))
      identity)))

(defun epi-ledger--recovery-require-transfer-authority-round-raw
    (prepared items directory-receipts file-receipts staged-ledger-identity
              destination-parent-identity source-last-record lock
              manifest-identity transaction-state &optional temporary-identity)
  "Raw-close one transferred-stage authority round for PREPARED.
ITEMS, DIRECTORY-RECEIPTS, FILE-RECEIPTS, STAGED-LEDGER-IDENTITY, and
DESTINATION-PARENT-IDENTITY bind staged storage.  SOURCE-LAST-RECORD and LOCK
bind source authority.  MANIFEST-IDENTITY and TRANSACTION-STATE bind durable
state; optional TEMPORARY-IDENTITY binds an update."
  (let* ((preflight (epi-ledger--recovery-prepared-raw-preflight prepared))
         (layout (epi-ledger--recovery-prepared-raw-path-layout prepared))
         (proof (epi-ledger--recovery-preflight-raw-source-proof preflight))
         (source (epi-ledger--recovery-layout-raw-source-path layout))
         (actual-parent
          (epi-ledger--recovery-reprove-destination-parent-raw
           preflight layout)))
    (unless (epi-ledger--recovery-same-directory-object-p
             (epi-ledger--recovery-destination-parent-path layout)
             destination-parent-identity actual-parent)
      (epi-ledger--fail 'epi-ledger-conflict 'recovery-path-conflict))
    (epi-ledger--recovery-reprove-directory-bindings-raw
     layout
     (epi-ledger--recovery-prepared-raw-quarantine-anchor-identity prepared)
     (epi-ledger--recovery-prepared-raw-quarantine-root-identity prepared)
     (epi-ledger--recovery-prepared-raw-control-identity prepared)
     (epi-ledger--recovery-prepared-raw-transaction-identity prepared)
     (epi-ledger--recovery-prepared-raw-directory-receipts prepared))
    (epi-ledger--recovery-reprove-source-object-state-raw preflight layout)
    (epi-ledger--recovery-reprove-reachable-objects-raw preflight layout)
    (epi-ledger--recovery-require-transferred-absences-raw layout)
    (epi-ledger--recovery-require-phase-manifest-core-raw
     layout manifest-identity)
    (epi-ledger--recovery-require-transaction-entry-state-raw
     layout transaction-state t)
    (epi-ledger--recovery-require-object-stage-raw
     layout items directory-receipts file-receipts
     destination-parent-identity t)
    (epi-ledger--recovery-require-staged-ledger-raw
     preflight layout staged-ledger-identity)
    (if lock
        (epi-ledger--verify-prewrite-authority-raw
         source
         (epi-ledger--recovery-source-proof-file-identity proof)
         (epi-ledger--recovery-source-proof-source-size proof)
         (epi-ledger--recovery-source-proof-valid-prefix-head proof)
         source-last-record lock)
      (epi-ledger--verify-source-authority-raw
       source
       (epi-ledger--recovery-source-proof-file-identity proof)
       (epi-ledger--recovery-source-proof-source-size proof)
       (epi-ledger--recovery-source-proof-valid-prefix-head proof)
       source-last-record))
    ;; This exact temporary restat is deliberately the last filesystem proof
    ;; in a round.  The final round can therefore be adjacent to phase rename.
    (if temporary-identity
        (epi-ledger--recovery-require-manifest-epoch-raw
         (epi-ledger--recovery-layout-raw-manifest-temporary-path layout)
         temporary-identity)
      (epi-ledger--recovery-require-manifest-temporary-absent-raw layout))
    t))

(defun epi-ledger--recovery-require-transfer-authority-raw
    (prepared items directory-receipts file-receipts staged-ledger-identity
              destination-parent-identity source-last-record lock
              manifest-identity transaction-state &optional temporary-identity)
  "Raw-close transferred PREPARED and ITEMS twice around all proof passes.
DIRECTORY-RECEIPTS, FILE-RECEIPTS, STAGED-LEDGER-IDENTITY, and
DESTINATION-PARENT-IDENTITY bind staged storage.  SOURCE-LAST-RECORD and LOCK
bind source authority.  MANIFEST-IDENTITY and TRANSACTION-STATE bind durable
state; optional TEMPORARY-IDENTITY binds an update."
  (dotimes (_ 2)
    (epi-ledger--recovery-require-transfer-authority-round-raw
     prepared items directory-receipts file-receipts staged-ledger-identity
     destination-parent-identity source-last-record lock
     manifest-identity transaction-state temporary-identity))
  t)

(defun epi-ledger--recovery-require-prepared-after-transfer-raw
    (prepared source-last-record lock)
  "Raw-close PREPARED after an exact-old transfer rollback.
SOURCE-LAST-RECORD and optional LOCK bind the source epoch."
  (let* ((preflight (epi-ledger--recovery-prepared-raw-preflight prepared))
         (layout (epi-ledger--recovery-prepared-raw-path-layout prepared))
         (proof (epi-ledger--recovery-preflight-raw-source-proof preflight))
         (source (epi-ledger--recovery-layout-raw-source-path layout)))
    (dotimes (_ 2)
      (epi-ledger--recovery-reprove-runtime-authority-raw
       preflight layout
       (epi-ledger--recovery-prepared-raw-quarantine-anchor-identity prepared)
       (epi-ledger--recovery-prepared-raw-quarantine-root-identity prepared)
       (epi-ledger--recovery-prepared-raw-control-identity prepared)
       (epi-ledger--recovery-prepared-raw-transaction-identity prepared)
       (epi-ledger--recovery-prepared-raw-directory-receipts prepared))
      (epi-ledger--recovery-require-manifest-temporary-absent-raw layout)
      (epi-ledger--recovery-require-phase-manifest-core-raw
       layout
       (epi-ledger--recovery-prepared-raw-manifest-identity prepared))
      (epi-ledger--recovery-require-transaction-entry-state-raw
       layout
       (epi-ledger--recovery-prepared-raw-transaction-entry-state prepared))
      (if lock
          (epi-ledger--verify-prewrite-authority-raw
           source
           (epi-ledger--recovery-source-proof-file-identity proof)
           (epi-ledger--recovery-source-proof-source-size proof)
           (epi-ledger--recovery-source-proof-valid-prefix-head proof)
           source-last-record lock)
        (epi-ledger--verify-source-authority-raw
         source
         (epi-ledger--recovery-source-proof-file-identity proof)
         (epi-ledger--recovery-source-proof-source-size proof)
         (epi-ledger--recovery-source-proof-valid-prefix-head proof)
         source-last-record)))
    t))

(defun epi-ledger--recovery-transferred-transaction-state-raw
    (prepared layout)
  "Raw-capture PREPARED's canonical one-manifest state under LAYOUT."
  (epi-ledger--recovery-capture-transaction-entry-state-core-raw
   layout
   (epi-ledger--recovery-prepared-raw-transaction-identity prepared)
   (epi-ledger--recovery-phase-transaction-entry-names layout nil)))

(defun epi-ledger--recovery-clean-exact-old-transfer
    (layout temporary-identity staged-ledger-identity
            file-receipts directory-receipts)
  "Best-effort clean an exact-old transfer attempt described by receipts.
LAYOUT names every cleanup path.  TEMPORARY-IDENTITY and STAGED-LEDGER-IDENTITY
bind created files; FILE-RECEIPTS and DIRECTORY-RECEIPTS bind the object tree.
Return non-nil when the owned phase temporary is proven absent after cleanup;
an absent receipt means that temporary was never created.  Object-stage cleanup
is unavoidable even if temporary cleanup exits abnormally."
  (let ((temporary-clean t))
    (unwind-protect
        (when temporary-identity
          (setq temporary-clean
                (epi-ledger--recovery-rollback-exact-temporary
                 (epi-ledger--recovery-layout-raw-manifest-temporary-path
                  layout)
                 temporary-identity)))
      (epi-ledger--recovery-clean-object-stage
       (epi-ledger--recovery-layout-raw-staged-destination-ledger-path layout)
       staged-ledger-identity file-receipts directory-receipts))
    temporary-clean))

(defun epi-ledger--recovery-transfer-objects (prepared)
  "Stage PREPARED's exact objects and ledger, then advance one phase."
  (let ((entry (epi-ledger--recovery-snapshot-prepared-entry prepared)))
    (epi-ledger--with-operation-work-state
      (let* ((prepared
              (epi-ledger--recovery-close-prepared-input nil entry))
             (preflight
              (epi-ledger--recovery-prepared-raw-preflight prepared))
             (layout
              (epi-ledger--recovery-prepared-raw-path-layout prepared))
             (proof
              (epi-ledger--recovery-preflight-raw-source-proof preflight))
             (source
              (epi-ledger--recovery-layout-raw-source-path layout))
             (source-last-record
              (epi-ledger--recovery-prepared-raw-source-last-record prepared))
             (new-manifest
              (epi-ledger--recovery-manifest-for-phase
               preflight "objects-transferred"))
             (new-bytes (nth 1 new-manifest))
             (items (epi-ledger--recovery-transfer-items preflight))
             (fragment-reference
              (epi-ledger--object-value
               (epi-ledger--recovery-preflight-raw-manifest-object preflight)
               "fragment_object"))
             (fragment-hash
              (epi-ledger--object-value fragment-reference "hash"))
             (fragment-size
              (epi-ledger--object-value fragment-reference "size"))
             (fragment-offset
              (epi-ledger--recovery-source-proof-fragment-offset proof))
             (manifest
              (substring-no-properties
               (epi-ledger--recovery-layout-raw-manifest-path layout)))
             (phase-temporary
              (substring-no-properties
               (epi-ledger--recovery-layout-raw-manifest-temporary-path
                layout)))
             (staged-ledger
              (epi-ledger--recovery-layout-raw-staged-destination-ledger-path
               layout))
             (expected-directory-paths
              (epi-ledger--recovery-object-stage-directory-paths
               layout items))
             (remaining-directory-paths
              (copy-sequence expected-directory-paths))
             (expected-object-paths
              (mapcar
               (lambda (item)
                 (epi-ledger--recovery-object-path-under-root
                  (epi-ledger--recovery-layout-raw-staged-destination-objects-path
                   layout)
                  (plist-get item :hash)))
               items))
             (remaining-object-paths
              (copy-sequence expected-object-paths))
             lock acquired-lock inspection fragment-bytes
             directory-receipts file-receipts
             destination-parent-identity staged-ledger-identity stage-proof
             temporary-identity temporary-state
             manifest-identity transaction-state classification
             successor result
             body-condition preunlock-condition unlock-condition
             ;; Trusted receipt collectors are lexical capabilities.  The
             ;; legacy special variables remain nil throughout every
             ;; documented callback in this phase.
             (epi-ledger--lock-acquisition-receiver nil)
             (epi-ledger--recovery-directory-receipt-receiver nil)
             (epi-ledger--recovery-file-receipt-receiver nil)
             (directory-receipt-receiver
              (lambda (path identity)
                (let* ((owned-path (substring-no-properties path))
                       (owned-identity
                        (epi-ledger--recovery-copy-directory-identity
                         identity))
                       (device
                        (and destination-parent-identity
                             (plist-get destination-parent-identity :device))))
                  (unless
                      (and remaining-directory-paths
                           (integerp device)
                           (equal owned-path
                                  (car remaining-directory-paths))
                           (equal owned-path
                                  (plist-get owned-identity :path))
                           (equal
                            owned-identity
                            (epi-ledger--recovery-require-bound-directory-raw
                             owned-path owned-identity device #o700)))
                    (epi-ledger--fail
                     'epi-ledger-conflict 'recovery-path-conflict))
                  (setq directory-receipts
                        (append directory-receipts
                                (list (cons owned-path owned-identity)))
                        remaining-directory-paths
                        (cdr remaining-directory-paths)))))
             (file-receipt-receiver
              (lambda (role path identity)
                (let ((owned-path (substring-no-properties path))
                      (owned-identity
                       (epi-ledger--recovery-copy-file-identity identity)))
                  (unless
                      (and
                       (equal owned-path (plist-get owned-identity :path))
                       (equal
                        owned-identity
                        (epi-ledger--recovery-require-private-file-state-raw
                         owned-path owned-identity 0
                         'recovery-path-conflict t)))
                    (epi-ledger--fail
                     'epi-ledger-conflict 'recovery-path-conflict))
                  (pcase role
                    ('staged-object
                     (unless
                         (and remaining-object-paths
                              (equal owned-path
                                     (car remaining-object-paths))
                              (null (assoc owned-path file-receipts)))
                       (epi-ledger--fail
                        'epi-ledger-conflict 'recovery-path-conflict))
                     (setq file-receipts
                           (append file-receipts
                                   (list
                                    (cons owned-path owned-identity)))
                           remaining-object-paths
                           (cdr remaining-object-paths)))
                    ('staged-ledger
                     (unless (and (equal owned-path staged-ledger)
                                  (null staged-ledger-identity))
                       (epi-ledger--fail
                        'epi-ledger-conflict 'recovery-path-conflict))
                     (setq staged-ledger-identity owned-identity))
                    ('phase-temporary
                     (unless (and (equal owned-path phase-temporary)
                                  (null temporary-identity))
                       (epi-ledger--fail
                        'epi-ledger-conflict 'recovery-path-conflict))
                     (setq temporary-identity owned-identity))
                    (_
                     (epi-ledger--fail
                      'epi-ledger-conflict 'recovery-path-conflict)))))))
        (unwind-protect
            (condition-case condition
                (progn
                  (let ((lock-receipt-receiver
                         (lambda (receipt)
                           (when acquired-lock
                             (epi-ledger--fail
                              'epi-ledger-conflict 'lock-token-changed))
                           (setq acquired-lock
                                 (epi-ledger--recovery-verify-lock-receipt-raw
                                  receipt source
                                  (epi-ledger--recovery-source-proof-file-identity
                                   proof)
                                  (epi-ledger--recovery-source-proof-source-size
                                   proof)
                                  (epi-ledger--recovery-source-proof-valid-prefix-head
                                   proof)))))
                        returned-lock)
                    (unwind-protect
                        (progn
                          (setq returned-lock
                                (epi-ledger--acquire-lock
                                 source
                                 (epi-ledger--recovery-source-proof-file-identity
                                  proof)
                                 (epi-ledger--recovery-source-proof-source-size
                                  proof)
                                 (epi-ledger--recovery-source-proof-valid-prefix-head
                                  proof)
                                 lock-receipt-receiver))
                          (unless (and acquired-lock
                                       (epi-ledger--lock-p returned-lock)
                                       (equal acquired-lock returned-lock))
                            (epi-ledger--fail
                             'epi-ledger-conflict 'lock-token-changed))
                          (setq lock
                                (epi-ledger--recovery-copy-lock
                                 acquired-lock)))
                      (when (and acquired-lock (null lock))
                        (setq lock
                              (epi-ledger--recovery-copy-lock
                               acquired-lock)))))
                  ;; PREPARED remains only a locator until every exact
                  ;; under-lock authority proof has closed the durable epoch.
                  (epi-ledger--recovery-close-unlocked-prepared-raw prepared)
                  (epi-ledger--verify-prewrite-authority-raw
                   source
                   (epi-ledger--recovery-source-proof-file-identity proof)
                   (epi-ledger--recovery-source-proof-source-size proof)
                   (epi-ledger--recovery-source-proof-valid-prefix-head proof)
                   source-last-record lock)
                  (setq inspection
                        (epi-ledger--inspect-path
                         source 'allow-one-incomplete-final-frame))
                  (unless
                      (epi-ledger--recovery-source-proof-equal-p
                       proof
                       (epi-ledger--recovery-snapshot-source-proof
                        inspection))
                    (epi-ledger--fail
                     'epi-ledger-conflict 'recovery-preflight-changed))
                  ;; The callback-free entry record is deliberately a bounded
                  ;; head proof.  Once the under-lock inspection is closed,
                  ;; replace it with the complete private validated record
                  ;; retained by the phase successor.
                  (setq source-last-record
                        (epi-ledger--recovery-snapshot-complete-record
                         (epi-ledger--inspection-raw-last-record inspection)))
                  (setq source-last-record
                        (epi-ledger--recovery-require-complete-source-record
                         source-last-record preflight))
                  (epi-ledger--verify-prewrite-authority-raw
                   source
                   (epi-ledger--recovery-source-proof-file-identity proof)
                   (epi-ledger--recovery-source-proof-source-size proof)
                   (epi-ledger--recovery-source-proof-valid-prefix-head proof)
                   source-last-record lock)
                  (setq destination-parent-identity
                        (epi-ledger--recovery-reprove-destination-parent-raw
                         preflight layout))
                  (setq fragment-bytes
                        (epi-ledger--recovery-read-range-bounded
                         source fragment-offset fragment-size))
                  (unless
                      (equal fragment-hash
                             (epi-ledger--hash
                              fragment-bytes 'recovery-fragment))
                    (epi-ledger--fail
                     'epi-ledger-conflict 'recovery-preflight-changed))
                  (epi-ledger--verify-prewrite-authority-raw
                   source
                   (epi-ledger--recovery-source-proof-file-identity proof)
                   (epi-ledger--recovery-source-proof-source-size proof)
                   (epi-ledger--recovery-source-proof-valid-prefix-head proof)
                   source-last-record lock)
                  (let ((returned-directories
                         (epi-ledger--recovery-create-object-stage-directories
                          layout items destination-parent-identity
                          directory-receipt-receiver)))
                    (unless (and (null remaining-directory-paths)
                                 (equal directory-receipts
                                        returned-directories))
                      (epi-ledger--fail
                       'epi-ledger-conflict 'recovery-path-conflict)))
                  (dotimes (index (length items))
                    (let* ((item (aref items index))
                           (hash (plist-get item :hash))
                           (size (plist-get item :size))
                           (target
                            (epi-ledger--recovery-object-path-under-root
                             (epi-ledger--recovery-layout-raw-staged-destination-objects-path
                              layout)
                             hash))
                           (bytes
                            (if (eq (plist-get item :kind) 'fragment)
                                fragment-bytes
                              (let* ((verified
                                      (epi-ledger--object-read-verified-state
                                       (plist-get item :source) size hash
                                       'proof))
                                     (identity
                                      (plist-get verified :identity)))
                                (unless
                                    (equal
                                     (plist-get item :source-identity)
                                     identity)
                                  (epi-ledger--fail
                                   'epi-ledger-conflict
                                   'recovery-preflight-changed))
                                (plist-get verified :bytes))))
                           (identity
                           (epi-ledger--recovery-copy-object-bytes
                             target bytes size hash file-receipt-receiver)))
                      (let ((receipt (assoc target file-receipts)))
                        (unless
                            (and receipt
                                 (epi-ledger--same-file-object-p
                                  (cdr receipt) identity))
                          (epi-ledger--fail
                           'epi-ledger-conflict
                           'recovery-object-content-changed))
                        (setcdr
                         receipt
                         (epi-ledger--recovery-copy-file-identity identity)))
                      (epi-ledger--recovery-close-destination-parent-raw
                       layout destination-parent-identity)
                      (epi-ledger--recovery-reprove-source-object-state-raw
                       preflight layout)
                      (epi-ledger--recovery-reprove-reachable-objects-raw
                       preflight layout)
                      (epi-ledger--verify-prewrite-authority-raw
                       source
                       (epi-ledger--recovery-source-proof-file-identity proof)
                       (epi-ledger--recovery-source-proof-source-size proof)
                       (epi-ledger--recovery-source-proof-valid-prefix-head
                        proof)
                       source-last-record lock)
                      (epi-ledger--recovery-require-manifest-epoch-raw
                       manifest
                       (epi-ledger--recovery-prepared-raw-manifest-identity
                        prepared))))
                  (unless (null remaining-object-paths)
                    (epi-ledger--fail
                     'epi-ledger-conflict 'recovery-path-conflict))
                  (let ((returned-ledger
                         (epi-ledger--recovery-stage-ledger
                          inspection preflight layout file-receipt-receiver)))
                    (unless
                        (epi-ledger--same-file-object-p
                         staged-ledger-identity returned-ledger)
                      (epi-ledger--fail
                       'epi-ledger-conflict
                       'recovery-staged-ledger-invalid))
                    (setq staged-ledger-identity
                          (epi-ledger--recovery-copy-file-identity
                           returned-ledger)))
                  (epi-ledger--recovery-close-destination-parent-raw
                   layout destination-parent-identity)
                  (epi-ledger--verify-prewrite-authority-raw
                   source
                   (epi-ledger--recovery-source-proof-file-identity proof)
                   (epi-ledger--recovery-source-proof-source-size proof)
                   (epi-ledger--recovery-source-proof-valid-prefix-head proof)
                   source-last-record lock)
                  (epi-ledger--recovery-reprove-source-object-state-raw
                   preflight layout)
                  (epi-ledger--recovery-reprove-reachable-objects-raw
                   preflight layout)
                  (setq stage-proof
                        (epi-ledger--recovery-require-object-stage-raw
                         layout items directory-receipts file-receipts
                         destination-parent-identity)
                        directory-receipts (nth 1 stage-proof)
                        file-receipts (nth 2 stage-proof)
                        staged-ledger-identity
                        (epi-ledger--recovery-require-staged-ledger-raw
                         preflight layout staged-ledger-identity))
                  (epi-ledger--recovery-require-transferred-absences-raw
                   layout)
                  (epi-ledger--recovery-reprove-directory-bindings-raw
                   layout
                   (epi-ledger--recovery-prepared-raw-quarantine-anchor-identity
                    prepared)
                   (epi-ledger--recovery-prepared-raw-quarantine-root-identity
                    prepared)
                   (epi-ledger--recovery-prepared-raw-control-identity
                    prepared)
                   (epi-ledger--recovery-prepared-raw-transaction-identity
                    prepared)
                   (epi-ledger--recovery-prepared-raw-directory-receipts
                    prepared))
                  (epi-ledger--recovery-require-transaction-entry-state-raw
                   layout
                   (epi-ledger--recovery-prepared-raw-transaction-entry-state
                    prepared))
                  (epi-ledger--recovery-require-manifest-epoch-raw
                   manifest
                   (epi-ledger--recovery-prepared-raw-manifest-identity
                    prepared))
                  (epi-ledger--verify-prewrite-authority-raw
                   source
                   (epi-ledger--recovery-source-proof-file-identity proof)
                   (epi-ledger--recovery-source-proof-source-size proof)
                   (epi-ledger--recovery-source-proof-valid-prefix-head proof)
                   source-last-record lock)
                  (let ((phase-preparation
                         (epi-ledger--recovery-prepare-phase-manifest-temporary
                          prepared new-bytes file-receipt-receiver)))
                    (unless
                        (epi-ledger--same-file-object-p
                         temporary-identity (nth 0 phase-preparation))
                      (epi-ledger--fail
                       'epi-ledger-conflict 'recovery-manifest-invalid))
                    (setq temporary-identity
                          (epi-ledger--recovery-copy-file-identity
                           (nth 0 phase-preparation))
                          temporary-state (nth 1 phase-preparation)))
                  ;; Suppress automatic GC from the final raw closure through
                  ;; exact temporary restat, atomic rename, and canonical
                  ;; epoch capture.  No content is reread in this boundary.
                  (let ((gc-cons-threshold most-positive-fixnum)
                        (file-name-handler-alist nil))
                    (epi-ledger--recovery-require-transfer-authority-raw
                     prepared items directory-receipts file-receipts
                     staged-ledger-identity destination-parent-identity
                     source-last-record lock
                     (epi-ledger--recovery-prepared-raw-manifest-identity
                      prepared)
                     temporary-state temporary-identity)
                    (setq manifest-identity
                          (epi-ledger--recovery-commit-phase-manifest-raw
                           phase-temporary manifest temporary-identity)))
                  (epi-ledger--recovery-require-manifest-links
                   manifest-identity 1)
                  (unless
                      (epi-ledger--same-file-object-p
                       temporary-identity manifest-identity)
                    (epi-ledger--fail
                     'epi-ledger-conflict 'recovery-manifest-invalid))
                  (epi-ledger--recovery-require-manifest-temporary-absent-raw
                   layout)
                  (setq transaction-state
                        (epi-ledger--recovery-capture-transaction-entry-state-raw
                         layout
                         (epi-ledger--recovery-prepared-raw-transaction-identity
                          prepared)))
                  (setq successor
                        (epi-ledger--make-recovery-phase-state
                         :phase 'objects-transferred
                         :preflight preflight
                         :path-layout layout
                         :source-last-record
                         (epi-ledger--copy-record source-last-record)
                         :quarantine-anchor-identity
                         (epi-ledger--copy-tree-and-strings
                          (epi-ledger--recovery-prepared-raw-quarantine-anchor-identity
                           prepared))
                         :quarantine-root-identity
                         (epi-ledger--copy-tree-and-strings
                          (epi-ledger--recovery-prepared-raw-quarantine-root-identity
                           prepared))
                         :control-identity
                         (epi-ledger--copy-tree-and-strings
                          (epi-ledger--recovery-prepared-raw-control-identity
                           prepared))
                         :directory-receipts
                         (epi-ledger--copy-tree-and-strings
                          (epi-ledger--recovery-prepared-raw-directory-receipts
                           prepared))
                         :transaction-identity
                         (epi-ledger--copy-tree-and-strings
                          (plist-get transaction-state :identity))
                         :manifest-identity
                         (epi-ledger--copy-tree-and-strings
                          manifest-identity)
                         :manifest-bytes
                         (substring-no-properties new-bytes)
                         :transaction-entry-state
                         (epi-ledger--copy-tree-and-strings
                          transaction-state)
                         :destination-parent-identity
                         (epi-ledger--copy-tree-and-strings
                          destination-parent-identity)
                         :staged-object-root-identity
                         (epi-ledger--copy-tree-and-strings
                          (nth 0 stage-proof))
                         :staged-directory-receipts
                         (epi-ledger--copy-tree-and-strings
                          directory-receipts)
                         :staged-object-receipts
                         (epi-ledger--copy-tree-and-strings
                          file-receipts)
                         :staged-ledger-identity
                         (epi-ledger--copy-tree-and-strings
                          staged-ledger-identity)))
                  (let ((gc-cons-threshold most-positive-fixnum))
                    (epi-ledger--recovery-require-transfer-authority-raw
                     prepared items directory-receipts file-receipts
                     staged-ledger-identity destination-parent-identity
                     source-last-record lock manifest-identity
                     transaction-state)
                    (funcall epi-ledger--recovery-phase-barrier-function
                             'objects-transferred))
                  (epi-ledger--recovery-require-transfer-authority-raw
                   prepared items directory-receipts file-receipts
                   staged-ledger-identity destination-parent-identity
                   source-last-record lock manifest-identity transaction-state)
                  (setq result successor))
              ((error quit)
               (setq body-condition condition)))
          ;; The manifest classification owns cleanup policy: only the exact
          ;; original object permits rollback; exact successor state is durable
          ;; resume evidence and every unknown state is preserved.
          (unwind-protect
              ;; Suppress automatic GC while classifying.  On the exact-old
              ;; branch, classification, receipt-bound cleanup, and immediate
              ;; prepared-state reclosure then form one callback-free epoch.
              ;; Candidate-new classification may cooperatively yield while
              ;; content-proving the successor and is reclosed separately.
              (let ((gc-cons-threshold most-positive-fixnum))
                (condition-case condition
                    (progn
                    (setq classification
                          (epi-ledger--recovery-classify-phase-manifest
                           layout
                           (epi-ledger--recovery-prepared-raw-manifest-identity
                            prepared)
                           temporary-identity new-bytes manifest-identity))
                    (pcase (plist-get classification :state)
                      ('old
                       (unless
                           (epi-ledger--recovery-clean-exact-old-transfer
                            layout temporary-identity
                            staged-ledger-identity
                            file-receipts directory-receipts)
                         (epi-ledger--fail
                          'epi-ledger-conflict
                          'recovery-manifest-invalid))
                       (setq temporary-identity nil)
                       (epi-ledger--recovery-require-prepared-after-transfer-raw
                        prepared source-last-record lock))
                      ('new
                       (unless temporary-identity
                         (epi-ledger--fail
                          'epi-ledger-conflict
                          'recovery-manifest-invalid))
                       (let ((classified-identity
                              (plist-get classification :identity)))
                         (unless
                             (or (null manifest-identity)
                                 (equal manifest-identity
                                        classified-identity))
                           (epi-ledger--fail
                            'epi-ledger-conflict
                            'recovery-manifest-invalid))
                         (unless manifest-identity
                           (setq manifest-identity classified-identity)))
                       (unless transaction-state
                         (setq transaction-state
                               (epi-ledger--recovery-transferred-transaction-state-raw
                                prepared layout)))
                       (epi-ledger--recovery-require-transfer-authority-raw
                        prepared items directory-receipts file-receipts
                        staged-ledger-identity destination-parent-identity
                        source-last-record lock manifest-identity
                        transaction-state))
                      (_
                       (epi-ledger--fail
                        'epi-ledger-conflict
                        'recovery-manifest-invalid))))
                  ((error quit)
                   (setq preunlock-condition condition))))
            (unwind-protect
                (when lock
                  (condition-case condition
                      (let ((epi-ledger--stat-function
                             #'epi-ledger--stat-local-file)
                            (epi-ledger--read-function
                             #'epi-ledger--read-bytes)
                            (epi--yield-function #'ignore)
                            (epi--deadline-clock-function #'float-time)
                            (epi-ledger--nonpreemptible-observer nil))
                        (funcall epi-ledger--unlock-function
                                 (epi-ledger--recovery-copy-lock lock)))
                    ((error quit)
                     (setq unlock-condition condition))))
              ;; This raw post-unlock closure is deliberately outside every
              ;; callback's dynamic continuation.  Its failure overrides an
              ;; error, quit, or throw from the body, barrier, or unlock.
              (let ((gc-cons-threshold most-positive-fixnum))
                (when lock
                  (epi-ledger--recovery-require-lock-absent-raw lock))
                (setq classification
                      (epi-ledger--recovery-classify-phase-manifest-raw
                       layout
                       (epi-ledger--recovery-prepared-raw-manifest-identity
                        prepared)
                       temporary-identity manifest-identity))
                (pcase (plist-get classification :state)
                  ('old
                   (epi-ledger--recovery-require-prepared-after-transfer-raw
                    prepared source-last-record nil))
                  ('new
                   (unless temporary-identity
                     (epi-ledger--fail
                      'epi-ledger-conflict 'recovery-manifest-invalid))
                   (let ((classified-identity
                          (plist-get classification :identity)))
                     (unless
                         (or (null manifest-identity)
                             (equal manifest-identity classified-identity))
                       (epi-ledger--fail
                        'epi-ledger-conflict 'recovery-manifest-invalid))
                     (unless manifest-identity
                       (setq manifest-identity classified-identity)))
                   (unless transaction-state
                     (setq transaction-state
                           (epi-ledger--recovery-transferred-transaction-state-raw
                            prepared layout)))
                   (epi-ledger--recovery-require-transfer-authority-raw
                    prepared items directory-receipts file-receipts
                    staged-ledger-identity destination-parent-identity
                    source-last-record nil manifest-identity
                    transaction-state))
                  (_
                   (epi-ledger--fail
                    'epi-ledger-conflict 'recovery-manifest-invalid)))
                (when lock
                  (epi-ledger--recovery-require-lock-absent-raw lock))))))
        (cond
         (preunlock-condition
          (signal (car preunlock-condition) (cdr preunlock-condition)))
         (body-condition
          (signal (car body-condition) (cdr body-condition)))
         (unlock-condition
          (signal (car unlock-condition) (cdr unlock-condition)))
         (t result))))))
(defun epi-ledger--create-validate-draft-shape (drafts session-id)
  "Require owned DRAFTS to lead with session-info for SESSION-ID."
  (when (= 0 (length drafts))
    (epi-ledger--format-fail 'empty-draft-batch))
  (unless (eq (epi-draft-type (aref drafts 0)) 'session-info)
    (epi-ledger--format-fail 'missing-session-info))
  (dotimes (index (1- (length drafts)))
    (when (eq (epi-draft-type (aref drafts (1+ index))) 'session-info)
      (epi-ledger--format-fail 'duplicate-session-info)))
  (let* ((payload (epi-draft-payload (aref drafts 0)))
         (entry (and (listp payload)
                     (assoc-string "session_id" payload nil))))
    (when (and entry (not (equal session-id (cdr entry))))
      (epi-ledger--format-fail 'session-id-mismatch))))

(defun epi-ledger--create-document-bytes (header drafts session-id)
  "Render and prevalidate HEADER plus owned DRAFTS for SESSION-ID."
  (let* ((work (epi-ledger--make-work-state))
         (header-bytes (epi-ledger-render-header header))
         (total (length header-bytes))
         (tail (epi-header--raw-hash header))
         (sequence 1)
         (state (epi-ledger--make-empty-validation-state))
         (chunks (list header-bytes)))
    (dotimes (index (length drafts))
      (let* ((record
              (epi-ledger-seal-record (aref drafts index) tail sequence))
             (frame (epi-ledger-render-record record)))
        (when (and (= index 0)
                   (not (equal
                         session-id
                         (epi-ledger--object-value
                          (epi-record--raw-payload record) "session_id"))))
          (epi-ledger--format-fail 'session-id-mismatch))
        (epi-ledger--validate-record-semantic state header record)
        (setq total (+ total (length frame)))
        (when (> total epi-ledger--batch-byte-limit)
          (epi-ledger--limit-fail
           'batch-byte-limit :limit epi-ledger--batch-byte-limit
           :bytes total))
        (push frame chunks)
        (setq tail (epi-record--raw-hash record)
              sequence (1+ sequence))))
    (let ((failure (epi-ledger--validation-final-error state)))
      (when failure
        (epi-ledger--semantic-fail (car failure))))
    (epi-ledger--work-concat-chunks
     (nreverse chunks) total work 'create-document)))

(defun epi-ledger--prepare-record-batch
    (header capsule drafts previous-hash first-sequence byte-overhead)
  "Seal and prevalidate owned DRAFTS after BYTE-OVERHEAD.
HEADER and CAPSULE provide the trusted semantic prefix; PREVIOUS-HASH and
FIRST-SEQUENCE bind the first suffix record.  Return owned records, frames,
their one concatenated suffix, and its final hash."
  (unless (and (epi-header-p header)
               (epi-ledger--semantic-capsule-p capsule)
               (vectorp drafts)
               (> (length drafts) 0)
               (<= (length drafts) epi-ledger--batch-record-limit)
               (stringp previous-hash)
               (integerp first-sequence)
               (> first-sequence 0)
               (integerp byte-overhead)
               (>= byte-overhead 0))
    (epi-ledger--format-fail 'invalid-record-batch))
  (let ((work (epi-ledger--make-work-state))
        (state (epi-ledger--semantic-capsule-clone capsule))
        (tail previous-hash)
        (sequence first-sequence)
        (suffix-bytes 0)
        frames-reverse)
    (dotimes (index (length drafts))
      (let* ((record
              (epi-ledger-seal-record (aref drafts index) tail sequence))
             (frame (epi-ledger-render-record record)))
        (epi-ledger--validate-record-semantic state header record)
        (setq suffix-bytes (+ suffix-bytes (length frame)))
        (when (> (+ byte-overhead suffix-bytes)
                 epi-ledger--batch-byte-limit)
          (epi-ledger--limit-fail
           'batch-byte-limit :limit epi-ledger--batch-byte-limit
           :bytes (+ byte-overhead suffix-bytes)))
        (push frame frames-reverse)
        (setq tail (epi-record--raw-hash record)
              sequence (1+ sequence))))
    (let ((failure (epi-ledger--validation-final-error state)))
      (when failure
        (epi-ledger--semantic-fail (car failure))))
    (let* ((records (epi-ledger--validation-suffix-records state work))
           (frames (epi-ledger--work-nreverse-list frames-reverse work))
           (suffix
            (epi-ledger--work-concat-chunks
             frames suffix-bytes work 'append-suffix)))
      (list :records records :frames frames :suffix suffix
            :final-hash tail))))

(defun epi-ledger--validate-realized-suffix
    (bytes origin first-sequence previous-hash header capsule path)
  "Validate realized suffix BYTES after the trusted prefix at ORIGIN.
FIRST-SEQUENCE and PREVIOUS-HASH bind the suffix to that prefix.  HEADER and
CAPSULE supply its trusted semantic state, and PATH identifies the ledger for
redacted diagnostics.  Return realized records, their semantic capsule, and
the final hash without reopening the complete ledger."
  (unless (and (stringp bytes)
               (not (multibyte-string-p bytes))
               (not (epi-ledger--string-has-properties-p bytes))
               (> (length bytes) 0)
               (integerp origin) (>= origin 0)
               (integerp first-sequence) (> first-sequence 0)
               (stringp previous-hash)
               (epi-header-p header)
               (epi-ledger--semantic-capsule-p capsule)
               (stringp path))
    (epi-ledger--format-fail 'invalid-realized-suffix))
  (let ((work (epi-ledger--make-work-state))
        (state (epi-ledger--semantic-capsule-clone capsule))
        (byte-count (length bytes))
        (offset 0)
        (sequence first-sequence)
        (tail previous-hash)
        records realized-capsule)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert bytes)
      (setq buffer-read-only t)
      (let* ((buffer (current-buffer))
             (source
              (epi-ledger--make-source-region
               :buffer buffer :start (point-min) :end (point-max)
               :tick (buffer-modified-tick)))
             (epi-ledger--work-protected-buffer buffer)
             (epi-ledger--work-protected-change-handler
              (lambda ()
                (epi-ledger--fail
                 'epi-ledger-conflict 'realized-readback-changed))))
        (while (< offset byte-count)
          (let* ((scan
                  (epi-ledger--scan-frame-owned
                   source offset sequence origin))
                 (scan-state (plist-get scan :state)))
            (unless (eq scan-state 'complete)
              (epi-ledger--format-fail
               (or (plist-get scan :code) 'invalid-realized-suffix)
               :offset (or (plist-get scan :offset) (+ origin offset))))
            (let* ((record (plist-get scan :record))
                   (absolute-next (plist-get scan :next-offset))
                   (next (and (integerp absolute-next)
                              (- absolute-next origin))))
              (unless (and (epi-record-p record)
                           (integerp next)
                           (> next offset)
                           (<= next byte-count))
                (epi-ledger--format-fail
                 'invalid-realized-suffix :offset (+ origin offset)))
              (unless (equal (epi-record--raw-previous-hash record) tail)
                (epi-ledger--format-fail
                 'previous-hash-mismatch
                 :offset (epi-record--raw-start-offset record)))
              (epi-ledger--validate-record-semantic state header record)
              (setq tail (epi-record--raw-hash record)
                    sequence (1+ sequence)
                    offset next))))
        (let ((eof
               (epi-ledger--scan-frame-owned
                source offset sequence origin)))
          (unless (and (eq (plist-get eof :state) 'eof)
                       (= (or (plist-get eof :next-offset) -1)
                          (+ origin byte-count)))
            (epi-ledger--format-fail
             'invalid-realized-suffix :offset (+ origin offset))))
        (let ((failure (epi-ledger--validation-final-error state)))
          (when failure
            (epi-ledger--semantic-fail (car failure))))
        (setq records
              (epi-ledger--validation-suffix-records state work)
              realized-capsule
              (epi-ledger--semantic-capsule-from-state state))))
    (list :records records :capsule realized-capsule :final-hash tail)))

(defun epi-ledger--publish-uncertain-successor (ledger checkpoint)
  "Publish CHECKPOINT's uncertain successor in LEDGER and return it.
Never replace a checkpoint that has already won the publication race."
  (let ((uncertain
         (epi-ledger--checkpoint-uncertain-successor checkpoint)))
    (unless (epi-ledger--checkpoint-cas ledger checkpoint uncertain)
      (epi-ledger--fail 'epi-ledger-conflict 'stale-checkpoint))
    uncertain))

(defun epi-ledger--mark-append-uncertain
    (ledger checkpoint phase cause)
  "Mark CHECKPOINT uncertain in LEDGER and signal ambiguous append PHASE.
CAUSE is deliberately not exposed because storage failures may contain
untrusted paths or operating-system text."
  (ignore cause)
  (epi-ledger--publish-uncertain-successor ledger checkpoint)
  (epi-ledger--fail
   'epi-ledger-conflict 'append-uncertain :phase phase))

(defun epi-ledger--assert-lock-owned-core (lock)
  "Require LOCK's path to retain its exact token object and bytes."
  (unless (epi-ledger--lock-p lock)
    (epi-ledger--format-fail 'invalid-lock))
  (unless
      (epi-ledger--exact-published-lock-object
       (epi-ledger--lock-lock-file lock)
       (epi-ledger--lock-file-identity lock)
       (epi-ledger--lock-bytes lock)
       (epi-ledger--lock-sha256 lock))
    (epi-ledger--fail 'epi-ledger-conflict 'lock-token-changed))
  t)

(defun epi-ledger--assert-lock-owned (lock)
  "Require LOCK's path to retain its exact token object and bytes."
  (epi-ledger--assert-lock-owned-core lock))

(defun epi-ledger--verify-source-authority-raw
    (path expected-identity expected-end expected-head last-record)
  "Verify PATH against expected source authority without storage seams.
EXPECTED-IDENTITY, EXPECTED-END, and EXPECTED-HEAD bind the source, while
LAST-RECORD supplies its retained chain head."
  (let ((epi-ledger--stat-function #'epi-ledger--stat-local-file)
        (epi-ledger--read-function #'epi-ledger--read-bytes)
        (epi--yield-function #'ignore)
        (epi--deadline-clock-function #'float-time)
        (epi-ledger--nonpreemptible-observer nil))
    (epi-ledger--verify-file-state-core-impl
     path expected-identity expected-end expected-head last-record)))

(defun epi-ledger--verify-prewrite-authority-raw
    (path expected-identity expected-end expected-head last-record lock)
  "Verify PATH and exact LOCK ownership without storage seams.
EXPECTED-IDENTITY, EXPECTED-END, EXPECTED-HEAD, and LAST-RECORD bind PATH."
  (let ((epi-ledger--stat-function #'epi-ledger--stat-local-file)
        (epi-ledger--read-function #'epi-ledger--read-bytes)
        (epi--yield-function #'ignore)
        (epi--deadline-clock-function #'float-time)
        (epi-ledger--nonpreemptible-observer nil))
    (epi-ledger--verify-source-authority-raw
     path expected-identity expected-end expected-head last-record)
    (epi-ledger--assert-lock-owned-core lock)))

(defun epi-ledger--create-storage-call (code function &rest arguments)
  "Call FUNCTION with ARGUMENTS, mapping raw file failures to CODE.
Already structured Epi conditions propagate without alteration."
  (condition-case condition
      (apply function arguments)
    (file-error
     (ignore condition)
     (epi-ledger--fail 'epi-ledger-conflict code))))

(defun epi-ledger--create-publish (temporary destination source)
  "Publish TEMPORARY at DESTINATION using owned source identity SOURCE.
A raw file failure after the destination becomes the same file object is
reported with `:published t'; an independently published winner is reported
as `destination-exists'."
  (unless source
    (epi-ledger--fail 'epi-ledger-conflict 'storage-publication-failed))
  (let ((epi-ledger--publication-receipt-receiver nil))
    (condition-case condition
        (funcall epi-ledger--publish-function temporary destination)
      (file-error
       (ignore condition)
       (let ((target
              (condition-case nil
                  (epi-ledger--owned-stat destination)
                (error nil))))
         (cond
          ((epi-ledger--same-file-object-p source target)
           (epi-ledger--fail
            'epi-ledger-conflict 'storage-publication-failed :published t))
          (target
           (epi-ledger--fail 'epi-ledger-conflict 'destination-exists))
          (t
           (epi-ledger--fail
            'epi-ledger-conflict 'storage-publication-failed))))))))

(defun epi-ledger--require-current-checkpoint (ledger expected)
  "Require LEDGER to still publish EXPECTED by identity."
  (unless (eq expected (epi-ledger--checkpoint-snapshot ledger))
    (epi-ledger--fail 'epi-ledger-conflict 'stale-checkpoint)))

(defun epi-ledger--append (ledger drafts)
  "Append DRAFTS to LEDGER through one verified crash barrier.
Publish only records parsed back from the realized suffix.  Any failure after
writer invocation marks the expected checkpoint uncertain and is never
retried."
  (unless (epi-ledger-p ledger)
    (signal 'wrong-type-argument (list 'epi-ledger-p ledger)))
  (let ((expected (epi-ledger--checkpoint-snapshot ledger)))
    (when (epi-ledger--checkpoint-raw-uncertain expected)
      (epi-ledger--fail
       'epi-ledger-conflict 'append-uncertain :phase 'possibly-written))
    (when (or (null drafts)
              (and (vectorp drafts) (= (length drafts) 0)))
      (epi-ledger--format-fail 'empty-draft-batch))
    ;; Ownership and aggregate caps precede default sources, yields, and I/O.
    (let ((owned (epi-ledger--snapshot-draft-batch drafts)))
      (when (= (length owned) 0)
        (epi-ledger--format-fail 'empty-draft-batch))
      (epi-ledger--with-operation-work-state
        (setq owned (epi-ledger--fill-owned-draft-defaults owned))
        (let* ((source (epi-ledger--checkpoint-raw-records expected))
               (old-count (epi-ledger--record-source-length source))
               (prepared
                (epi-ledger--prepare-record-batch
                 (epi-ledger--raw-header ledger)
                 (epi-ledger--checkpoint-raw-semantic-capsule expected)
                 owned
                 (epi-ledger--checkpoint-raw-tail-hash expected)
                 (1+ old-count)
                 0)))
          ;; Preparation is cooperative and may run arbitrary callbacks.
          (epi-ledger--require-current-checkpoint ledger expected)
          (let* ((path (epi-ledger--raw-path ledger))
                 (expected-file
                  (epi-ledger--checkpoint-raw-file-identity expected))
                 (expected-end
                  (epi-ledger--checkpoint-raw-validated-end-offset expected))
                 (expected-head
                  (epi-ledger--checkpoint-raw-tail-hash expected))
                 (last-record (epi-ledger--record-source-last source))
                 (suffix (plist-get prepared :suffix))
                 (lock
                  (epi-ledger--acquire-lock
                   path expected-file expected-end expected-head))
                 (phase 'prewrite)
                 replacement
                 failure
                 result)
            (unwind-protect
                (condition-case condition
                    (progn
                  ;; The first full sandwich binds the freshly acquired lock.
                  (epi-ledger--require-current-checkpoint ledger expected)
                  (epi-ledger--verify-file-state
                   path expected-file expected-end expected-head last-record)
                  ;; The injectable verifier is itself a callback boundary.
                  (epi-ledger--require-current-checkpoint ledger expected)
                  (epi-ledger--verify-file-state-core
                   path expected-file expected-end expected-head last-record)
                  ;; Re-prove the exact token after every preceding callback.
                  ;; Then bypass every injectable callback while jointly
                  ;; re-proving file and lock authority.  The pure checkpoint
                  ;; comparison closes the remaining gap before the writer.
                  (epi-ledger--assert-lock-owned lock)
                  (epi-ledger--verify-prewrite-authority-raw
                   path expected-file expected-end expected-head last-record
                   lock)
                  (epi-ledger--require-current-checkpoint ledger expected)
                  (setq phase 'possibly-written)
                  (funcall epi-ledger--append-function path suffix)
                  (funcall epi-ledger--flush-function path)
                  (let* ((new-identity (epi-ledger--owned-stat path))
                         (new-end
                          (and (listp new-identity)
                               (plist-get new-identity :size))))
                    (unless (and new-identity
                                 (epi-ledger--same-file-object-p
                                  expected-file new-identity)
                                 (equal path (plist-get new-identity :path))
                                 (integerp new-end)
                                 (= new-end (+ expected-end
                                               (length suffix))))
                      (epi-ledger--fail
                       'epi-ledger-conflict 'realized-end-mismatch))
                    (let ((readback
                           (funcall epi-ledger--read-function
                                    path expected-end new-end)))
                      (unless (and (stringp readback)
                                   (not (multibyte-string-p readback))
                                   (not
                                    (epi-ledger--string-has-properties-p
                                     readback))
                                   (= (length readback) (length suffix))
                                   (equal readback suffix))
                        (epi-ledger--fail
                         'epi-ledger-conflict 'realized-readback-mismatch))
                      (let* ((realized
                              (epi-ledger--validate-realized-suffix
                               readback expected-end (1+ old-count)
                               expected-head (epi-ledger--raw-header ledger)
                               (epi-ledger--checkpoint-raw-semantic-capsule
                                expected)
                               path))
                             (records (plist-get realized :records))
                             (capsule (plist-get realized :capsule))
                             (new-head (plist-get realized :final-hash))
                             (new-source
                              (epi-ledger--record-source-extend
                               source records
                               (epi-ledger--make-work-state)))
                             (new-last-record
                              (epi-ledger--record-source-last new-source)))
                        (setq replacement
                              (funcall
                               (symbol-function
                                'epi-ledger--make-checkpoint)
                               :file-identity new-identity
                               :validated-end-offset new-end
                               :tail-hash new-head
                               :records new-source
                               :by-id
                               (epi-ledger--semantic-capsule-raw-by-id
                                capsule)
                               :turn-operation-index
                               (epi-ledger--semantic-capsule-raw-turn-operation-index
                                capsule)
                               :tool-facts
                               (epi-ledger--semantic-capsule-raw-calls
                                capsule)
                               :semantic-capsule capsule
                               :uncertain
                               (epi-ledger--semantic-capsule-raw-uncertain
                                capsule))
                              result
                              (epi-ledger--work-list-to-vector
                               records (epi-ledger--make-work-state)
                               'append-records))
                        ;; The verifier may observe storage, but cooperative
                        ;; callbacks stay suppressed until the pure CAS ends.
                        (let ((epi--yield-function #'ignore))
                          (epi-ledger--verify-file-state
                           path new-identity new-end new-head new-last-record)
                          (epi-ledger--verify-file-state-raw
                           path new-identity new-end new-head new-last-record)
                          (epi-ledger--require-current-checkpoint
                           ledger expected)
                          (unless (epi-ledger--checkpoint-cas
                                   ledger expected replacement)
                            ;; Cleanup performs the one ambiguity CAS after
                            ;; releasing the exact lock.
                            (epi-ledger--fail
                             'epi-ledger-conflict 'publication-cas-lost))
                          (setq phase 'published)))))
                      result)
                  ((error quit)
                   (setq failure condition)
                   (signal (car condition) (cdr condition))))
              (when lock
                (let ((owned-lock lock))
                  (setq lock nil)
                  (pcase phase
                    ('prewrite
                     (condition-case condition
                         (funcall epi-ledger--unlock-function owned-lock)
                       (epi-error
                        (signal (car condition) (cdr condition)))
                       ((error quit)
                        (epi-ledger--fail
                         'epi-ledger-conflict 'unlock-uncertain
                         :phase 'prewrite))))
                    ('possibly-written
                     ;; Publish uncertainty before another writer can acquire
                     ;; the lock, but always attempt exact release before the
                     ;; ambiguity signal becomes observable to the caller.
                     (let (uncertainty-condition)
                       (unwind-protect
                           (condition-case condition
                               (epi-ledger--mark-append-uncertain
                                ledger expected phase failure)
                             ((error quit)
                              (setq uncertainty-condition condition)))
                         (unwind-protect
                             (funcall epi-ledger--unlock-function owned-lock)
                           (when uncertainty-condition
                             (signal (car uncertainty-condition)
                                     (cdr uncertainty-condition)))))))
                    ('published
                     (let ((released nil))
                       (unwind-protect
                           (progn
                             (funcall epi-ledger--unlock-function owned-lock)
                             (setq released t))
                         (unless released
                           (epi-ledger--publish-uncertain-successor
                            ledger replacement)
                           (epi-ledger--fail
                            'epi-ledger-conflict 'unlock-uncertain
                            :phase 'published)))))))))))))))

(cl-defun epi-ledger-create
    (path &key session-id created-at project-root initial-drafts)
  "Atomically create a complete append-only ledger at PATH.
SESSION-ID, CREATED-AT, and PROJECT-ROOT define its explicit header.
INITIAL-DRAFTS must contain exactly one leading session-info record."
  ;; Everything reachable from the caller is owned before operation-state
  ;; initialization can sample a clock or any later callback can run.
  (let* ((owned-path
          (if (stringp path)
              (substring-no-properties path)
            (epi-ledger--format-fail 'invalid-write-path)))
         (header-inputs
          (epi-ledger--snapshot-header-inputs
           session-id created-at project-root))
         (owned-session-id
          (epi-ledger--object-value header-inputs "session_id"))
         (owned-created-at
          (epi-ledger--object-value header-inputs "created_at"))
         (owned-project-root
          (epi-ledger--object-value header-inputs "project_root"))
         (owned-drafts
          (epi-ledger--snapshot-draft-batch initial-drafts)))
    (epi-ledger--create-validate-draft-shape
     owned-drafts owned-session-id)
    ;; Reject the exact aggregate cap before work-state initialization or any
    ;; cooperative callback.  The placeholder contributes only its length.
    (let* ((header-size
            (epi-ledger--header-rendered-byte-size-no-callback
             owned-session-id owned-created-at owned-project-root))
           (header-placeholder (make-string header-size 0)))
      (setq owned-drafts
            (epi-ledger--snapshot-draft-batch
             owned-drafts header-placeholder)))
    (epi-ledger--with-operation-work-state
      (setq owned-drafts
            (epi-ledger--fill-owned-draft-defaults owned-drafts))
      (epi-ledger--create-validate-draft-shape
       owned-drafts owned-session-id)
      (let* ((header
              (epi-ledger-seal-header
               :session-id owned-session-id
               :created-at owned-created-at
               :project-root owned-project-root)))
        (let* ((document
                (epi-ledger--create-document-bytes
                 header owned-drafts owned-session-id))
               ;; This is deliberately the first path resolution or probe.
               (canonical
                (epi-ledger--resolve-local-write-path owned-path))
               (lock nil)
               (published nil)
               result)
          (epi-ledger--ensure-private-parent canonical)
          (when (epi-ledger--create-storage-call
                 'storage-write-failed #'epi-ledger--owned-stat canonical)
            (epi-ledger--fail 'epi-ledger-conflict 'destination-exists))
          (condition-case condition
              (progn
                (setq lock
                      (epi-ledger--create-storage-call
                       'storage-write-failed #'epi-ledger--acquire-lock
                       canonical "absent" 0 nil))
                (when (epi-ledger--create-storage-call
                       'storage-write-failed
                       #'epi-ledger--owned-stat canonical)
                  (epi-ledger--fail
                   'epi-ledger-conflict 'destination-exists))
                (let ((temporary (epi-ledger--hidden-sibling canonical)))
                  (epi-ledger--create-storage-call
                   'storage-write-failed epi-ledger--byte-writer
                   temporary document 'exclusive-create nil)
                  (epi-ledger--create-storage-call
                   'storage-flush-failed epi-ledger--flush-function temporary)
                  (unless
                      (equal document
                             (epi-ledger--create-storage-call
                              'storage-write-failed epi-ledger--read-function
                              temporary 0 (length document)))
                    (epi-ledger--fail
                     'epi-ledger-conflict 'storage-write-failed))
                  ;; A full cold open proves that the temporary is not merely
                  ;; byte-equal to our intent but a complete valid ledger.
                  (epi-ledger-open temporary)
                  (funcall epi-ledger--create-prepublication-function)
                  (let ((source
                         (epi-ledger--create-storage-call
                          'storage-publication-failed
                          #'epi-ledger--owned-stat temporary)))
                    (unless source
                      (epi-ledger--fail
                       'epi-ledger-conflict 'storage-publication-failed))
                    (when (epi-ledger--create-storage-call
                           'storage-write-failed
                           #'epi-ledger--owned-stat canonical)
                      (epi-ledger--fail
                       'epi-ledger-conflict 'destination-exists))
                    (epi-ledger--assert-lock-owned lock)
                    ;; No callback or yield may intervene between this exact
                    ;; ownership proof and entry into the publication seam.
                    (epi-ledger--create-publish
                     temporary canonical source))
                  (setq published t)
                  (epi-ledger--delete-published-source-name temporary)
                  (funcall epi-ledger--create-postpublication-function)
                  (setq result (epi-ledger-open canonical)))
                (let ((owned-lock lock))
                  (setq lock nil)
                  (condition-case nil
                      (funcall epi-ledger--unlock-function owned-lock)
                    (error
                     (epi-ledger--fail
                      'epi-ledger-conflict 'unlock-uncertain))))
                result)
            (error
             (let* ((detail (and (consp (cdr condition))
                                 (cadr condition)))
                    (publication-visible
                     (or published
                         (and (listp detail)
                              (plist-get detail :published)))))
               (when lock
                 (let ((owned-lock lock))
                   (setq lock nil)
                   (condition-case nil
                       (funcall epi-ledger--unlock-function owned-lock)
                     (error
                      (when publication-visible
                        (epi-ledger--fail
                         'epi-ledger-conflict 'unlock-uncertain))))))
               (signal (car condition) (cdr condition))))))))))

(defun epi-ledger-message-from-record (record)
  "Return an ownership-isolated `epi-message' projection of message RECORD."
  (epi-ledger--with-operation-work-state
    (unless (and (epi-record-p record)
                 (eq (epi-record--raw-type record) 'message))
      (epi-ledger--format-fail 'message-record-required))
    (let ((payload (epi-record--raw-payload record)))
      (epi-ledger--make-message
       :record-id (epi-ledger--trusted-value-copy
                   (epi-record--raw-id record))
       :role (epi-ledger--trusted-value-copy
              (epi-ledger--object-value payload "role"))
       :content (epi-ledger--trusted-value-copy
                 (epi-ledger--object-value payload "content"))
       :parent (when (epi-record--raw-parent record)
                 (epi-ledger--trusted-value-copy
                  (epi-record--raw-parent record)))
       :turn (when (epi-record--raw-turn record)
               (epi-ledger--trusted-value-copy
                (epi-record--raw-turn record)))
       :sequence (epi-record--raw-sequence record)))))

(provide 'epi-ledger)
;;; epi-ledger.el ends here
