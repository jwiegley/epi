;;; epi-gptel-fixture-transport.el --- Offline GPTel fixtures -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley
;; Keywords: tools

;;; Commentary:

;; Data-only fixtures and provider-neutral helpers for the pinned GPTel seam.
;; The transport driver itself belongs to epi-gptel.el so contract tests never
;; invoke a provider parser, request registry, or state-machine accessor.

;;; Code:

(require 'cl-lib)
(require 'epi)
(require 'epi-gptel nil t)

(defconst epi-test-gptel-fixture-directory
  (expand-file-name "fixtures/gptel/"
                    (file-name-directory
                     (file-truename (or load-file-name buffer-file-name))))
  "Directory containing raw offline GPTel response fixtures.")

(defun epi-test-gptel-fixture (name)
  "Return the exact unibyte contents of fixture NAME."
  (let ((coding-system-for-read 'no-conversion))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally
       (expand-file-name name epi-test-gptel-fixture-directory))
      (buffer-string))))

(defun epi-test-gptel-sse (&rest payloads)
  "Return an SSE body whose data records contain PAYLOADS."
  (mapconcat (lambda (payload) (format "data: %s\n\n" payload))
             payloads ""))

(defmacro epi-test-with-gptel-fixtures (names &rest body)
  "Run BODY with offline fixture NAMES as consecutive provider legs."
  (declare (indent 1) (debug (form body)))
  `(epi-gptel-fixture-call-with-transport
    (mapcar #'epi-test-gptel-fixture ,names)
    (lambda () ,@body)))

(defmacro epi-test-with-gptel-fixtures/options (names options &rest body)
  "Run BODY with fixture NAMES and fixture-backend OPTIONS."
  (declare (indent 2) (debug (form form body)))
  `(epi-gptel-fixture-call-with-transport
    (mapcar #'epi-test-gptel-fixture ,names)
    (lambda () ,@body)
    ,options))

(defun epi-test-gptel-string-schema ()
  "Return the frozen flat schema for one required string property."
  '(("type" . "object")
    ("properties" . (("path" . (("type" . "string")
                                  ("description" . "Path to read")))))
    ("required" . ["path"])
    ("additionalProperties" . epi-json-false)))

(defun epi-test-gptel-empty-argument-schema ()
  "Return a schema that admits an empty object through an optional property."
  '(("type" . "object")
    ("properties" . (("label" . (("type" . "string")))))
    ("required" . [])
    ("additionalProperties" . epi-json-false)))

(defun epi-test-gptel-zero-property-schema ()
  "Return the valid frozen schema with no properties."
  '(("type" . "object")
    ("properties" . nil)
    ("required" . [])
    ("additionalProperties" . epi-json-false)))

(defun epi-test-gptel-tool (name schema)
  "Return a provider-neutral descriptor named NAME with SCHEMA."
  `(("name" . ,name)
    ("description" . ,(format "Fixture tool %s" name))
    ("schema" . ,schema)))

(defun epi-test-text-snapshot (&optional history tools)
  "Return a fixture snapshot containing HISTORY and TOOLS."
  (epi-gptel-snapshot-create
   :backend "epi-fixture"
   :model 'epi-fixture-model
   :system "You are the offline fixture agent."
   :history history
   :prompt (if history nil "Hello")
   :tools tools
   :request-params nil
   :transport 'curl))

(defun epi-test-tool-snapshot (&optional history)
  "Return the standard two-tool fixture snapshot with HISTORY."
  (epi-test-text-snapshot
   history
   (list
    (epi-test-gptel-tool "read_file" (epi-test-gptel-string-schema))
    (epi-test-gptel-tool
     "replace_text"
     '(("type" . "object")
       ("properties" .
        (("path" . (("type" . "string")))
         ("old_text" . (("type" . "string")))
         ("new_text" . (("type" . "string")))))
       ("required" . ["path" "old_text" "new_text"])
       ("additionalProperties" . epi-json-false))))))

(defun epi-test-open-gptel-request (snapshot)
  "Start SNAPSHOT and return mutable test state [request events]."
  (let ((state (vector nil nil)))
    (aset state 0
          (epi-gptel-start
           snapshot
           (lambda (event)
             (aset state 1 (append (aref state 1) (list event))))))
    (epi-gptel-fixture-pump)
    state))

(defun epi-test-gptel-request (state)
  "Return the Epi request stored in fixture STATE."
  (aref state 0))

(defun epi-test-gptel-events (state)
  "Return the normalized events currently stored in fixture STATE."
  (copy-sequence (aref state 1)))

(defun epi-test-gptel-event-kinds (events)
  "Return the ordered kinds from adapter EVENTS."
  (mapcar #'epi-gptel-event-kind events))

(defun epi-test-count-kind (events kind)
  "Count KIND in adapter EVENTS."
  (cl-count kind events :key #'epi-gptel-event-kind))

(defun epi-test-event-index (events kind)
  "Return the zero-based index of KIND in EVENTS."
  (cl-position kind events :key #'epi-gptel-event-kind))

(defun epi-test-last-gptel-event (events kind)
  "Return the last event of KIND in EVENTS."
  (car (last (cl-remove kind events :test-not #'eq
                        :key #'epi-gptel-event-kind))))

(defun epi-test-run-gptel-contract (snapshot &optional results)
  "Run SNAPSHOT, submitting model-facing RESULTS, and return its events."
  (let ((state (epi-test-open-gptel-request snapshot)))
    (dolist (result results)
      (let* ((proposal
              (epi-test-last-gptel-event
               (epi-test-gptel-events state) 'tool-proposed))
             (call-id (and proposal (epi-gptel-event-call-id proposal))))
        (unless call-id
          (error "Fixture result has no pending proposal"))
        (epi-gptel-submit-tool-result
         (epi-test-gptel-request state) call-id result)
        (epi-gptel-fixture-pump)))
    (epi-test-gptel-events state)))

(defun epi-test-gptel-dry-run-data (snapshot)
  "Return the copied effective request data for SNAPSHOT."
  (epi-gptel-dry-run snapshot))

(defun epi-test-gptel-json-false-p (value)
  "Return non-nil when VALUE is GPTel's private JSON-false sentinel."
  (eq value (epi-gptel-request-false-sentinel)))

(defun epi-test-gptel-fixture-wire-byte-count (body)
  "Return the raw byte count charged for one fixture BODY."
  (epi-gptel-fixture-wire-byte-count body))

(provide 'epi-gptel-fixture-transport)

;;; epi-gptel-fixture-transport.el ends here
