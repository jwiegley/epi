;;; epi.el --- Emacs-native agent harness  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (org "9.7") (gptel "0.9.9.5") (transient "0.7.8") (compat "30.1.0.0"))
;; Keywords: tools, convenience

;;; Commentary:

;; Epi is an Emacs-native agent harness.  This file defines its lightweight
;; public facade, immutable event values, stable errors, and configuration.
;; Runtime and user-interface implementations remain lazily loaded.

;;; Code:

(require 'cl-generic)
(require 'cl-lib)
(require 'subr-x)
(require 'wid-edit)

(defgroup epi nil
  "An Emacs-native agent harness."
  :group 'applications)

(defun epi--positive-integer-match (_widget value)
  "Return non-nil when VALUE is a positive integer.
_WIDGET is the Customize widget requesting the match."
  (and (integerp value) (> value 0)))

(defun epi--finite-number-p (value)
  "Return non-nil when VALUE is a finite integer or float."
  (or (integerp value)
      (and (floatp value)
           (= value value)
           (= (- value value) 0.0))))

(defun epi--nonnegative-seconds-match (_widget value)
  "Return non-nil when VALUE is a nonnegative number of seconds.
_WIDGET is the Customize widget requesting the match."
  (and (epi--finite-number-p value) (>= value 0)))

(define-widget 'epi-positive-integer 'integer
  "A strictly positive integer."
  :match #'epi--positive-integer-match)

(define-widget 'epi-nonnegative-seconds 'number
  "A nonnegative number of seconds."
  :match #'epi--nonnegative-seconds-match)

(defcustom epi-ledger-work-record-limit 256
  "Maximum ledger records processed in one work slice."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-ledger-work-byte-limit 1048576
  "Maximum ledger bytes processed in one work slice."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-ledger-work-time-budget 0.008
  "Target duration in seconds for one ledger work slice."
  :type 'epi-nonnegative-seconds
  :group 'epi)

(defcustom epi-record-json-byte-limit 15728640
  "Maximum encoded JSON bytes in one ledger record."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-record-frame-byte-limit 16777216
  "Maximum framed bytes in one ledger record."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-record-decode-byte-limit 15728640
  "Maximum bytes decoded from one ledger record."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-hash-input-byte-limit 16777216
  "Maximum bytes accepted by one hashing operation."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-json-depth-limit 32
  "Maximum nesting depth accepted in canonical JSON data."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-json-item-limit 131072
  "Maximum item count accepted in canonical JSON data."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-object-byte-limit 16777216
  "Maximum encoded size in bytes of one stored object."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-recovery-fragment-byte-limit 16777216
  "Maximum byte size of one ledger recovery fragment."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-drain-item-limit 128
  "Maximum items drained in one scheduling slice."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-drain-byte-limit 524288
  "Maximum bytes drained in one scheduling slice."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-drain-time-budget 0.008
  "Target duration in seconds for one drain slice."
  :type 'epi-nonnegative-seconds
  :group 'epi)

(defcustom epi-callback-queue-item-limit 4096
  "Maximum number of pending callback queue items."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-callback-queue-byte-limit 16777216
  "Maximum byte size of the pending callback queue."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-callback-queue-reserve-items 1
  "Number of callback queue items reserved for terminal events."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-callback-queue-reserve-bytes 4096
  "Callback queue bytes reserved for terminal events."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-callback-event-byte-limit 524288
  "Maximum byte size of one callback event."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-tool-argument-byte-limit 262144
  "Maximum encoded byte size of tool arguments."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-tool-schema-byte-limit 262144
  "Maximum encoded byte size of a tool schema."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-tool-schema-property-limit 64
  "Maximum property count in a tool schema."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-tool-schema-required-limit 64
  "Maximum required-property count in a tool schema."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-tool-schema-enum-per-property-limit 64
  "Maximum enumeration members for one tool schema property."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-tool-schema-enum-total-limit 256
  "Maximum enumeration members across one tool schema."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-tool-argument-member-limit 64
  "Maximum top-level members in tool arguments."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-provider-call-id-byte-limit 4096
  "Maximum provider call identifier size in bytes."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-provider-tool-name-byte-limit 128
  "Maximum provider tool name size in bytes."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-provider-leg-raw-byte-limit 4194304
  "Maximum raw provider response bytes in one request leg."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-provider-turn-raw-byte-limit 33554432
  "Maximum raw provider response bytes in one turn."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-provider-leg-output-byte-limit 2097152
  "Maximum normalized provider output bytes in one request leg."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-provider-turn-output-byte-limit 16777216
  "Maximum normalized provider output bytes in one turn."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-provider-tool-call-limit 32
  "Maximum provider tool calls accepted in one response."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-gptel-no-progress-timeout 120
  "Seconds without GPTel progress before failing a provider leg."
  :type 'epi-nonnegative-seconds
  :group 'epi)

(defcustom epi-tool-approval-timeout nil
  "Seconds to wait for tool approval, or nil to wait indefinitely."
  :type '(choice (const :tag "Disabled" nil)
                 epi-nonnegative-seconds)
  :group 'epi)

(defcustom epi-user-prompt-byte-limit 2097152
  "Maximum user prompt size in bytes."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-system-prompt-byte-limit 262144
  "Maximum system prompt size in bytes."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-instruction-resource-byte-limit 262144
  "Maximum size in bytes of one instruction resource."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-instruction-total-byte-limit 1048576
  "Maximum combined size in bytes of instruction resources."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-provider-context-byte-limit 16777216
  "Maximum provider context size in bytes."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-read-file-result-byte-limit 1048576
  "Maximum byte size returned by one file read."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-replace-text-input-byte-limit 4194304
  "Maximum input byte size for one text replacement."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-replace-text-diff-byte-limit 1048576
  "Maximum diff byte size for one text replacement."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-ui-initial-message-limit 200
  "Maximum messages initially rendered by an Epi view."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-ui-conversation-action-byte-limit 1048576
  "Maximum payload byte size of one conversation action."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-ui-tree-node-limit 1000
  "Maximum number of nodes rendered in an Epi tree."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-ui-tree-label-byte-limit 384
  "Maximum byte size of one Epi tree label."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-ui-tree-action-byte-limit 524288
  "Maximum payload byte size of one Epi tree action."
  :type 'epi-positive-integer
  :group 'epi)

(defcustom epi-callback-time-budget 0.004
  "Target duration in seconds for one callback slice."
  :type 'epi-nonnegative-seconds
  :group 'epi)

(defcustom epi-session-directory
  (expand-file-name "epi/sessions/" user-emacs-directory)
  "Directory in which Epi stores session ledgers."
  :type 'directory
  :group 'epi)

(defcustom epi-global-instructions-file nil
  "File containing global Epi instructions, or nil for none."
  :type '(choice (const :tag "None" nil) file)
  :group 'epi)

(define-error 'epi-error "Epi error")
(define-error 'epi-busy "Epi is busy" 'epi-error)
(define-error 'epi-invalid-state "Epi state is invalid" 'epi-error)
(define-error 'epi-stale-generation "Epi generation is stale"
  'epi-invalid-state)
(define-error 'epi-limit-exceeded "Epi limit exceeded" 'epi-error)
(define-error 'epi-ledger-error "Epi ledger error" 'epi-error)
(define-error 'epi-ledger-format-error "Epi ledger format error"
  'epi-ledger-error)
(define-error 'epi-ledger-corrupt "Epi ledger is corrupt" 'epi-ledger-error)
(define-error 'epi-ledger-truncated-tail "Epi ledger tail is truncated"
  'epi-ledger-corrupt)
(define-error 'epi-ledger-conflict "Epi ledger conflict" 'epi-ledger-error)
(define-error 'epi-missing-object "Epi object is missing" 'epi-ledger-error)
(define-error 'epi-gptel-error "Epi GPTel error" 'epi-error)
(define-error 'epi-gptel-incompatible "GPTel is incompatible with Epi"
  'epi-gptel-error)
(define-error 'epi-provider-error "Epi provider error" 'epi-gptel-error)
(define-error 'epi-tool-error "Epi tool error" 'epi-error)
(define-error 'epi-tool-denied "Epi tool call denied" 'epi-tool-error)
(define-error 'epi-tool-uncertain "Epi tool outcome is uncertain"
  'epi-tool-error)
(define-error 'epi-interaction-required "Epi interaction required" 'epi-error)
(define-error 'epi-cancelled "Epi operation cancelled" 'epi-error)

(defun epi--signal (condition plist)
  "Signal CONDITION with exactly one validated PLIST data item.
PLIST must be proper, even in length, and contain a non-nil symbolic `:code'."
  (unless (and (proper-list-p plist)
               (zerop (% (length plist) 2))
               (plist-member plist :code)
               (let ((code (plist-get plist :code)))
                 (and code (symbolp code))))
    (error "Malformed Epi condition data"))
  (signal condition (list plist)))

(defconst epi-json-false 'epi-json-false
  "Canonical Epi representation of JSON false.")

(defconst epi-json-null 'epi-json-null
  "Canonical Epi representation of JSON null.")

(defconst epi--committed-event-kinds
  '(session-info operation-started turn-started message reasoning leaf
    tool-planned tool-approved tool-denied tool-started tool-finished
    turn-finished turn-failed turn-cancelled turn-interrupted
    operation-finished operation-failed operation-cancelled
    operation-interrupted recovery-origin tool-approval-needed agent-settled)
  "Event kinds that must be committed to a session ledger.")

(defconst epi--volatile-event-kinds
  '(text-delta reasoning-delta tool-progress diagnostic)
  "Event kinds that exist only in live delivery.")

(defconst epi--maximum-safe-integer 9007199254740991
  "Largest integer admitted by Epi canonical payload data.")

(defun epi--finite-float-p (value)
  "Return non-nil when VALUE is a finite floating-point number."
  (and (floatp value) (epi--finite-number-p value)))

(defun epi--canonical-string-p (value)
  "Return non-nil when VALUE is a string admitted by canonical JSON."
  (and
   (stringp value)
   (let ((index 0)
         (multibyte (multibyte-string-p value))
         (valid t))
     (while (and valid (< index (length value)))
       (let ((character (aref value index)))
         (setq valid
               (if multibyte
                   (and (<= character #x10ffff)
                        (not (<= #xd800 character #xdfff)))
                 (<= character #x7f))))
       (setq index (1+ index)))
     valid)))

(defun epi--plain-string-copy (value)
  "Return an ownership-safe copy of VALUE without text properties.
Emacs may canonicalize zero-length strings, which have no mutable contents."
  (substring-no-properties value))

(defun epi--signal-invalid-payload (reason)
  "Signal a redacted invalid-payload error for REASON."
  (epi--signal 'epi-error
               (list :code 'invalid-event
                     :field 'payload
                     :reason reason)))

(defun epi--canonical-copy (value &optional active)
  "Return an ownership-isolated canonical copy of VALUE.
ACTIVE is the private traversal stack used to reject cyclic containers."
  (let ((active (or active (make-hash-table :test #'eq))))
    (cond
     ((stringp value)
      (unless (epi--canonical-string-p value)
        (epi--signal-invalid-payload 'invalid-string))
      (epi--plain-string-copy value))
     ((consp value)
      (let ((copy nil)
            (marked nil)
            (seen-keys (make-hash-table :test #'equal))
            (tail value))
        (unwind-protect
            (progn
              (while (consp tail)
                (when (gethash tail active)
                  (epi--signal-invalid-payload 'cyclic))
                (puthash tail t active)
                (push tail marked)
                (let ((entry (car tail)))
                  (unless (consp entry)
                    (epi--signal-invalid-payload 'object-entry-required))
                  (when (gethash entry active)
                    (epi--signal-invalid-payload 'cyclic))
                  (puthash entry t active)
                  (push entry marked)
                  (let ((key (car entry)))
                    (unless (stringp key)
                      (epi--signal-invalid-payload
                       'string-object-key-required))
                    (unless (epi--canonical-string-p key)
                      (epi--signal-invalid-payload 'invalid-string))
                    (let ((key-copy (epi--plain-string-copy key)))
                      (when (gethash key-copy seen-keys)
                        (epi--signal-invalid-payload 'duplicate-object-key))
                      (puthash key-copy t seen-keys)
                      (push (cons key-copy
                                  (epi--canonical-copy (cdr entry) active))
                            copy))))
                (setq tail (cdr tail)))
              (unless (null tail)
                (epi--signal-invalid-payload 'improper-object))
              (nreverse copy))
          (dolist (container marked)
            (remhash container active)))))
     ((vectorp value)
      (when (gethash value active)
        (epi--signal-invalid-payload 'cyclic))
      (puthash value t active)
      (unwind-protect
          (let ((copy (make-vector (length value) nil)))
            (dotimes (index (length value))
              (aset copy index
                    (epi--canonical-copy (aref value index) active)))
            copy)
        (remhash value active)))
     ((null value) nil)
     ((or (eq value t)
          (eq value epi-json-false)
          (eq value epi-json-null))
      value)
     ((integerp value)
      (if (<= (- epi--maximum-safe-integer)
              value
              epi--maximum-safe-integer)
          value
        (epi--signal-invalid-payload 'integer-out-of-range)))
     ((epi--finite-float-p value) value)
     (t
      (epi--signal-invalid-payload 'unsupported-type)))))

(cl-defstruct (epi-event
               (:constructor epi--event-create-raw)
               (:copier nil)
               (:conc-name epi--event-raw-))
  "An immutable event delivered by an Epi session."
  (kind nil :read-only t)
  (durability nil :read-only t)
  (session-id nil :read-only t)
  (generation nil :read-only t)
  (operation-id nil :read-only t)
  (turn-id nil :read-only t)
  (attempt-id nil :read-only t)
  (call-id nil :read-only t)
  (record-id nil :read-only t)
  (sequence nil :read-only t)
  (live-sequence nil :read-only t)
  (payload nil :read-only t))

(defun epi--copy-optional-identity (value name)
  "Return an owned copy of optional identity VALUE named NAME."
  (cond
   ((null value) nil)
   ((stringp value)
    (unless (epi--canonical-string-p value)
      (epi--signal 'epi-error
                   (list :code 'invalid-event
                         :field name
                         :reason 'invalid-string)))
    (epi--plain-string-copy value))
   (t
    (epi--signal 'epi-error
                 (list :code 'invalid-event
                       :field name
                       :reason 'string-or-nil-required)))))

(cl-defun epi--event-create
    (&key kind durability session-id generation operation-id turn-id
          attempt-id call-id record-id sequence live-sequence payload)
  "Construct an immutable Epi event after validating all keyword fields.
KIND and DURABILITY select the event class.  SESSION-ID, GENERATION,
OPERATION-ID, TURN-ID, ATTEMPT-ID, CALL-ID, and RECORD-ID are optional string
identities.  Exactly one of SEQUENCE and LIVE-SEQUENCE is a positive integer
according to durability.  PAYLOAD is canonical JSON data."
  (cond
   ((memq kind epi--committed-event-kinds)
    (unless (eq durability 'committed)
      (epi--signal 'epi-error
                   (list :code 'invalid-event
                         :field 'durability
                         :reason 'kind-durability-mismatch))))
   ((memq kind epi--volatile-event-kinds)
    (unless (eq durability 'volatile)
      (epi--signal 'epi-error
                   (list :code 'invalid-event
                         :field 'durability
                         :reason 'kind-durability-mismatch))))
   (t
    (epi--signal 'epi-error
                 (list :code 'invalid-event
                       :field 'kind
                       :reason 'unsupported-kind))))
  (pcase durability
    ('committed
     (unless (and (integerp sequence)
                  (> sequence 0)
                  (null live-sequence))
       (epi--signal 'epi-error
                    (list :code 'invalid-event
                          :field 'sequence
                          :reason 'positive-integer-inverse-required))))
    ('volatile
     (unless (and (null sequence)
                  (integerp live-sequence)
                  (> live-sequence 0))
       (epi--signal 'epi-error
                    (list :code 'invalid-event
                          :field 'live-sequence
                          :reason 'positive-integer-inverse-required))))
    (_
     (epi--signal 'epi-error
                  (list :code 'invalid-event
                        :field 'durability
                        :reason 'unsupported-durability))))
  (epi--event-create-raw
   :kind kind
   :durability durability
   :session-id (epi--copy-optional-identity session-id 'session-id)
   :generation (epi--copy-optional-identity generation 'generation)
   :operation-id (epi--copy-optional-identity operation-id 'operation-id)
   :turn-id (epi--copy-optional-identity turn-id 'turn-id)
   :attempt-id (epi--copy-optional-identity attempt-id 'attempt-id)
   :call-id (epi--copy-optional-identity call-id 'call-id)
   :record-id (epi--copy-optional-identity record-id 'record-id)
   :sequence sequence
   :live-sequence live-sequence
   :payload (epi--canonical-copy payload)))

(defun epi-event-kind (event)
  "Return the kind of EVENT."
  (epi--event-raw-kind event))

(defun epi-event-durability (event)
  "Return the durability of EVENT."
  (epi--event-raw-durability event))

(defun epi-event-session-id (event)
  "Return a fresh copy of the session identifier of EVENT, or nil."
  (when-let ((value (epi--event-raw-session-id event)))
    (epi--plain-string-copy value)))

(defun epi-event-generation (event)
  "Return a fresh copy of the generation identifier of EVENT, or nil."
  (when-let ((value (epi--event-raw-generation event)))
    (epi--plain-string-copy value)))

(defun epi-event-operation-id (event)
  "Return a fresh copy of the operation identifier of EVENT, or nil."
  (when-let ((value (epi--event-raw-operation-id event)))
    (epi--plain-string-copy value)))

(defun epi-event-turn-id (event)
  "Return a fresh copy of the turn identifier of EVENT, or nil."
  (when-let ((value (epi--event-raw-turn-id event)))
    (epi--plain-string-copy value)))

(defun epi-event-attempt-id (event)
  "Return a fresh copy of the attempt identifier of EVENT, or nil."
  (when-let ((value (epi--event-raw-attempt-id event)))
    (epi--plain-string-copy value)))

(defun epi-event-call-id (event)
  "Return a fresh copy of the call identifier of EVENT, or nil."
  (when-let ((value (epi--event-raw-call-id event)))
    (epi--plain-string-copy value)))

(defun epi-event-record-id (event)
  "Return a fresh copy of the ledger record identifier of EVENT, or nil."
  (when-let ((value (epi--event-raw-record-id event)))
    (epi--plain-string-copy value)))

(defun epi-event-sequence (event)
  "Return the committed ledger sequence of EVENT, or nil."
  (epi--event-raw-sequence event))

(defun epi-event-live-sequence (event)
  "Return the volatile delivery sequence of EVENT, or nil."
  (epi--event-raw-live-sequence event))

(defun epi-event-payload (event)
  "Return an ownership-isolated copy of the payload of EVENT."
  (epi--canonical-copy (epi--event-raw-payload event)))

(autoload 'uuidgen-4 "uuidgen" nil nil)

(defvar epi--id-function #'uuidgen-4
  "Function called without arguments to produce a fresh UUID string.")

(defvar epi--wall-clock-function #'current-time
  "Function called without arguments to sample Epi wall time.")

(defvar epi--deadline-clock-function #'float-time
  "Function called without arguments to sample deadline wall seconds.")

(defvar epi--deadline-high-water nil
  "Process-local high-water mark for Epi deadline clock samples.")

(defvar epi--yield-function (lambda () (sit-for 0))
  "Function called without arguments to yield cooperatively to Emacs.")

(defun epi--new-id ()
  "Return a new Epi identifier from the configured ID source."
  (funcall epi--id-function))

(defun epi--wall-time ()
  "Return the current sample from the configured Epi wall clock."
  (funcall epi--wall-clock-function))

(defun epi--format-timestamp ()
  "Return the configured Epi wall time as an RFC 3339 timestamp."
  (format-time-string "%Y-%m-%dT%H:%M:%S.%9NZ" (epi--wall-time) t))

(defun epi--deadline-time ()
  "Return a nondecreasing process-local deadline clock sample."
  (let ((sample (funcall epi--deadline-clock-function)))
    (unless (and (epi--finite-number-p sample) (>= sample 0))
      (epi--signal 'epi-error
                   (list :code 'invalid-clock-sample
                         :field 'deadline-clock
                         :reason 'nonnegative-finite-number-required)))
    (setq epi--deadline-high-water
          (if epi--deadline-high-water
              (max epi--deadline-high-water sample)
            sample))))

(defun epi--yield ()
  "Yield cooperatively to Emacs using the configured yield function."
  (funcall epi--yield-function))

(cl-defgeneric epi-session-p (object)
  "Return non-nil when OBJECT is an Epi session.")

(cl-defmethod epi-session-p ((_object t))
  "Return nil for objects without a concrete Epi session method."
  nil)

(autoload 'epi-session-create "epi-runtime"
  "Create and return an Epi session." nil)
(autoload 'epi-session-open "epi-runtime"
  "Open and return an Epi session." nil)
(autoload 'epi-session-close "epi-runtime"
  "Close an Epi session." nil)
(autoload 'epi-session-id "epi-runtime"
  "Return an Epi session identifier." nil)
(autoload 'epi-session-file "epi-runtime"
  "Return an Epi session ledger file." nil)
(autoload 'epi-session-phase "epi-runtime"
  "Return the current Epi session phase." nil)
(autoload 'epi-session-state "epi-runtime"
  "Return the current Epi session state." nil)
(autoload 'epi-session-prompt "epi-runtime"
  "Submit a prompt to an Epi session." nil)
(autoload 'epi-session-abort "epi-runtime"
  "Abort the active operation of an Epi session." nil)
(autoload 'epi-session-wait "epi-runtime"
  "Wait for an Epi session to settle." nil)
(autoload 'epi-session-select-leaf "epi-runtime"
  "Select a conversation leaf in an Epi session." nil)
(autoload 'epi-session-subscribe "epi-runtime"
  "Subscribe a function to events from an Epi session." nil)
(autoload 'epi-session-unsubscribe "epi-runtime"
  "Remove an Epi session event subscription." nil)
(autoload 'epi-tool-approve "epi-runtime"
  "Approve a pending Epi tool call." nil)
(autoload 'epi-tool-deny "epi-runtime"
  "Deny a pending Epi tool call." nil)
(autoload 'epi-session-recover-tail "epi-runtime"
  "Recover a session ledger with a truncated tail." nil)

(autoload 'epi-display-session "epi-ui"
  "Display an Epi session." nil)
(autoload 'epi-display-tree "epi-ui"
  "Display an Epi session tree." nil)
(autoload 'epi-display-ledger "epi-ui"
  "Display an Epi session ledger." nil)

(autoload 'epi "epi-ui" "Open the Epi user interface." t)
(autoload 'epi-open-session "epi-ui" "Open an Epi session interactively." t)
(autoload 'epi-send "epi-ui" "Send a prompt from an Epi session buffer." t)
(autoload 'epi-abort "epi-ui" "Abort the current Epi operation." t)
(autoload 'epi-show-tree "epi-ui" "Show the current Epi session tree." t)
(autoload 'epi-show-ledger "epi-ui" "Show the current Epi session ledger." t)
(autoload 'epi-session-mode "epi-ui" "Major mode for Epi sessions." t)
(autoload 'epi-ledger-mode "epi-ui" "Major mode for Epi ledgers." t)
(autoload 'epi-tree-mode "epi-ui" "Major mode for Epi session trees." t)

(provide 'epi)
;;; epi.el ends here
