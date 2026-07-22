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
  (uncertain nil :read-only t))

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

(defun epi-ledger-file-identity (ledger)
  "Return a defensive copy of LEDGER's validated file identity."
  (epi-ledger--public-value-copy
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

(defun epi-ledger--work-list-to-record-index (list work)
  "Copy proper ordered LIST into a bounded-chunk record index using WORK."
  (if (< epi-ledger-work-byte-limit 8)
      list
    (let* ((chunk-limit
          (max 1
               (min epi-ledger-work-record-limit
                    (max 1 (/ epi-ledger-work-byte-limit 8)))))
         (tail list)
         chunks
         (total 0))
    (while (consp tail)
      (let* ((capacity chunk-limit)
             (bytes (* capacity 8))
             (values
              (progn
                (epi-ledger--open-observe-work
                 'allocate 'record-index-chunk bytes
                 :records capacity :bounded t)
                (epi-ledger--work-charge work bytes)
                (make-vector capacity nil)))
             (count 0))
        (while (and (< count capacity) (consp tail))
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
               chunks work))))
    (unless (null tail)
      (error "Cannot cooperatively index an improper record list"))
      (epi-ledger--make-record-index
       :chunks (epi-ledger--work-nreverse-list chunks work)
       :count total))))

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
  deferred-references uncertain uncertainty-phase uncertainty-class
  uncertainty-turn uncertainty-operation)

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
                     :arguments
                     (epi-ledger--payload-value record "arguments")
                     :order order :state 'planned :plan record
                     :terminal nil :status nil :model-result nil
                     :result nil)))
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
                 (plist-get call :status) status
                 (plist-get call :model-result)
                 (and (not (equal status "uncertain"))
                      (epi-ledger--payload-value record "model_result")))
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
                 (plist-get call :model-result)
                 (epi-ledger--payload-value record "model_result")
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
                     (plist-get call :model-result))
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
    ;; These adjacency checks deliberately precede all unrelated semantics.
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

(defun epi-ledger-open (path)
  "Open PATH as a validated read-only append-only Epi ledger.
Validation uses one forward scan in monotonically increasing bounded ranges.
Before publication, a bounded reread of the final record prefix binds the
result to the current chain head.  Per-range identity sandwiches detect
persistent replacement, but portable filename reads without a stable file
descriptor cannot exclude adversarial rename-away/read/restore ABA.  No
repair, recovery, Org evaluation, rendering, or write occurs on this path."
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
             (if (eq scan-state 'invalid)
                 (let ((code (epi-ledger--loader-frame-code cause-code)))
                   (epi-ledger--open-signal
                    'epi-ledger-corrupt code canonical-path sequence record-id
                    (plist-get scan :offset) cause-code))
               (epi-ledger--open-signal
		'epi-ledger-truncated-tail 'truncated-frame
		canonical-path sequence record-id
		(+ buffer-origin (buffer-size))
		(or cause-code 'truncated-frame)))))))
     (unless (= validated-end size)
       (let ((record
              (car (epi-ledger--validation-state-records-reverse state))))
         (epi-ledger--open-signal
          'epi-ledger-conflict 'incomplete-ledger-scan canonical-path
          sequence (and record (epi-record--raw-id record))
          validated-end 'incomplete-ledger-scan)))
     (epi-ledger--open-finalize-state
      state canonical-path sequence validated-end)
     (let* ((last-record
             (car (epi-ledger--validation-state-records-reverse state)))
            (records
             (epi-ledger--work-list-to-record-index
              (epi-ledger--work-nreverse-list
               (epi-ledger--validation-state-records-reverse state) work)
              work)))
       (epi-ledger--open-verify-current-head
        canonical-path last-record initial-identity work sequence)
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
       (let* (
              (checkpoint
               (epi-ledger--make-checkpoint
		:file-identity initial-identity
		:validated-end-offset validated-end
		:tail-hash tail
		:records records
		:by-id (epi-ledger--validation-state-by-id state)
		:turn-operation-index
		(epi-ledger--validation-state-turn-operation-index state)
		:tool-facts (epi-ledger--validation-state-calls state)
		:uncertain (epi-ledger--validation-state-uncertain state))))
         (epi-ledger--make-ledger
          :path canonical-path :header header
          :session-id (epi-header--raw-session-id header)
          :project-root (epi-header--raw-project-root header)
          :checkpoint-cell (epi-ledger--make-checkpoint-cell
                            :value checkpoint)))))))

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
