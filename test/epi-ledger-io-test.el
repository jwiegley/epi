;;; epi-ledger-io-test.el --- Epi ledger storage tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley
;; Keywords: tools

;;; Commentary:

;; Task 5 storage, locking, append, and object tests.  This initial RED slice
;; freezes the Wave 0 semantic-capsule, record-index, checkpoint-CAS, and batch
;; ownership contracts before any filesystem mutation is implemented.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'seq)
(require 'subr-x)
(require 'epi-test-helper)
(require 'epi)
(require 'epi-ledger)

(defconst epi-test-ledger-io--session-id
  "11111111-1111-4111-8111-111111111111")
(defconst epi-test-ledger-io--operation-id
  "20000000-0000-4000-8000-000000000001")
(defconst epi-test-ledger-io--turn-id
  "30000000-0000-4000-8000-000000000001")
(defconst epi-test-ledger-io--user-id
  "10000000-0000-4000-8000-000000000012")
(defconst epi-test-ledger-io--proposal-id
  "10000000-0000-4000-8000-000000000013")
(defconst epi-test-ledger-io--call-id "call-1")

(defun epi-test-ledger-io--condition-detail (condition)
  "Return the sole structured plist carried by CONDITION."
  (car (cdr condition)))

(defun epi-test-ledger-io--condition-code (condition)
  "Return CONDITION's structured Epi code."
  (plist-get (epi-test-ledger-io--condition-detail condition) :code))

(defun epi-test-ledger-io--header ()
  "Return the deterministic header used by Wave 0 fixtures."
  (epi-ledger-seal-header
   :session-id epi-test-ledger-io--session-id
   :created-at "2026-07-21T18:42:17-07:00"
   :project-root "/tmp/epi-project/"))

(defun epi-test-ledger-io--draft (record-id type payload &rest envelope)
  "Return a deterministic draft with RECORD-ID, TYPE, PAYLOAD, and ENVELOPE."
  (apply #'make-epi-draft
         :id record-id :type type :at "2026-07-21T18:43:02-07:00"
         :payload payload envelope))

(defun epi-test-ledger-io--session-info ()
  "Return the mandatory deterministic session-info draft."
  (epi-test-ledger-io--draft
   "10000000-0000-4000-8000-000000000001"
   'session-info
   `(("session_id" . ,epi-test-ledger-io--session-id)
     ("working_directory" . "/tmp/epi-project/")
     ("base_system_prompt" . "Be exact.")
     ("backend" . "test-backend")
     ("model" . "test-model")
     ("request_params")
     ("tools" . [])
     ("capability" . "openai-chat-completions/sequential-tools-v1"))))

(defun epi-test-ledger-io--operation-started ()
  "Return the deterministic prompt operation start."
  (epi-test-ledger-io--draft
   "10000000-0000-4000-8000-000000000010"
   'operation-started
   `(("operation_id" . ,epi-test-ledger-io--operation-id)
     ("kind" . "prompt"))
   :operation epi-test-ledger-io--operation-id))

(defun epi-test-ledger-io--turn-started ()
  "Return the deterministic turn start with one forward message intent."
  (epi-test-ledger-io--draft
   "10000000-0000-4000-8000-000000000011"
   'turn-started
   `(("turn_id" . ,epi-test-ledger-io--turn-id)
     ("operation_id" . ,epi-test-ledger-io--operation-id)
     ("attempt_id" . "40000000-0000-4000-8000-000000000001")
     ("message_id" . ,epi-test-ledger-io--user-id)
     ("working_directory" . "/tmp/epi-project/")
     ("base_system_prompt" . "Be exact.")
     ("resources" . [])
     ("system_prompt" . "Be exact.")
     ("backend" . "test-backend")
     ("model" . "test-model")
     ("request_params")
     ("tools" . [])
     ("snapshot_hash" .
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
   :turn epi-test-ledger-io--turn-id
   :operation epi-test-ledger-io--operation-id))

(defun epi-test-ledger-io--user-message ()
  "Return the intended deterministic user message."
  (epi-test-ledger-io--draft
   epi-test-ledger-io--user-id
   'message
   `(("role" . "user")
     ("content" .
      ,(vector '(("type" . "text") ("text" . "hello")))))
   :turn epi-test-ledger-io--turn-id))

(defun epi-test-ledger-io--proposal ()
  "Return the deterministic assistant tool-call proposal."
  (epi-test-ledger-io--draft
   epi-test-ledger-io--proposal-id
   'message
   `(("role" . "assistant")
     ("content" .
      ,(vector
        `(("type" . "tool-call")
          ("call_id" . ,epi-test-ledger-io--call-id)
          ("name" . "read_file")
          ("arguments" . (("path" . "/tmp/a")))
          ("order" . 0)
          ("group_id" . ,epi-json-null)))))
   :parent epi-test-ledger-io--user-id
   :turn epi-test-ledger-io--turn-id))

(defun epi-test-ledger-io--tool-planned ()
  "Return the deterministic tool plan paired with the proposal."
  (epi-test-ledger-io--draft
   "10000000-0000-4000-8000-000000000014"
   'tool-planned
   `(("call_id" . ,epi-test-ledger-io--call-id)
     ("name" . "read_file")
     ("arguments" . (("path" . "/tmp/a")))
     ("authority")
     ("order" . 0))
   :target epi-test-ledger-io--proposal-id
   :turn epi-test-ledger-io--turn-id
   :operation epi-test-ledger-io--operation-id))

(defun epi-test-ledger-io--tool-approved ()
  "Return the deterministic approval following the plan."
  (epi-test-ledger-io--draft
   "10000000-0000-4000-8000-000000000015"
   'tool-approved
   `(("call_id" . ,epi-test-ledger-io--call-id) ("policy"))
   :target epi-test-ledger-io--proposal-id
   :turn epi-test-ledger-io--turn-id
   :operation epi-test-ledger-io--operation-id))

(defun epi-test-ledger-io--tool-started ()
  "Return the deterministic tool start."
  (epi-test-ledger-io--draft
   "10000000-0000-4000-8000-000000000016"
   'tool-started
   `(("call_id" . ,epi-test-ledger-io--call-id)
     ("tool_version" . "1"))
   :target epi-test-ledger-io--proposal-id
   :turn epi-test-ledger-io--turn-id
   :operation epi-test-ledger-io--operation-id))

(defun epi-test-ledger-io--tool-finished ()
  "Return the deterministic successful tool terminal."
  (epi-test-ledger-io--draft
   "10000000-0000-4000-8000-000000000017"
   'tool-finished
   `(("call_id" . ,epi-test-ledger-io--call-id)
     ("status" . "success")
     ("details")
     ("model_result" . "contents"))
   :target epi-test-ledger-io--proposal-id
   :turn epi-test-ledger-io--turn-id
   :operation epi-test-ledger-io--operation-id))

(defun epi-test-ledger-io--tool-result ()
  "Return the deterministic tool-result message."
  (epi-test-ledger-io--draft
   "10000000-0000-4000-8000-000000000018"
   'message
   `(("role" . "tool")
     ("content" .
      ,(vector
        `(("type" . "tool-result")
          ("call_id" . ,epi-test-ledger-io--call-id)
          ("name" . "read_file")
          ("result" . "contents")
          ("status" . "success")))))
   :parent epi-test-ledger-io--proposal-id
   :turn epi-test-ledger-io--turn-id))

(defun epi-test-ledger-io--turn-finished ()
  "Return the deterministic successful turn terminal."
  (epi-test-ledger-io--draft
   "10000000-0000-4000-8000-000000000019"
   'turn-finished
   `(("turn_id" . ,epi-test-ledger-io--turn-id) ("status" . "success"))
   :turn epi-test-ledger-io--turn-id
   :operation epi-test-ledger-io--operation-id))

(defun epi-test-ledger-io--operation-finished ()
  "Return the deterministic successful operation terminal."
  (epi-test-ledger-io--draft
   "10000000-0000-4000-8000-000000000020"
   'operation-finished
   `(("operation_id" . ,epi-test-ledger-io--operation-id)
     ("status" . "success"))
   :operation epi-test-ledger-io--operation-id))

(defun epi-test-ledger-io--full-drafts ()
  "Return a fresh complete deterministic tool-call history."
  (list
   (epi-test-ledger-io--session-info)
   (epi-test-ledger-io--operation-started)
   (epi-test-ledger-io--turn-started)
   (epi-test-ledger-io--user-message)
   (epi-test-ledger-io--proposal)
   (epi-test-ledger-io--tool-planned)
   (epi-test-ledger-io--tool-approved)
   (epi-test-ledger-io--tool-started)
   (epi-test-ledger-io--tool-finished)
   (epi-test-ledger-io--tool-result)
   (epi-test-ledger-io--turn-finished)
   (epi-test-ledger-io--operation-finished)))

(defun epi-test-ledger-io--pending-result-drafts ()
  "Return a fresh valid history ending with one pending tool result."
  (cl-subseq (epi-test-ledger-io--full-drafts) 0 9))

(defun epi-test-ledger-io--document-bytes (drafts)
  "Return a complete fixed-header ledger containing DRAFTS."
  (let* ((header (epi-test-ledger-io--header))
         (tail (epi-header-hash header))
         (sequence 1)
         (chunks (list (epi-ledger-render-header header))))
    (dolist (draft drafts)
      (let ((record (epi-ledger-seal-record draft tail sequence)))
        (push (epi-ledger-render-record record) chunks)
        (setq tail (epi-record-hash record)
              sequence (1+ sequence))))
    (apply #'concat (nreverse chunks))))

(defun epi-test-ledger-io--write-document (root drafts)
  "Write DRAFTS as a fixture below ROOT and return its absolute path."
  (let ((file (expand-file-name "session.org" root))
        (bytes (epi-test-ledger-io--document-bytes drafts)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert bytes)
      (let ((coding-system-for-write 'no-conversion)
            (create-lockfiles nil)
            (write-region-annotate-functions nil)
            (write-region-post-annotation-function nil))
        (write-region (point-min) (point-max) file nil 'silent)))
    file))

(defun epi-test-ledger-io--open-history (root drafts)
  "Write and open DRAFTS below ROOT."
  (epi-ledger-open (epi-test-ledger-io--write-document root drafts)))

(defun epi-test-ledger-io--capsule (ledger)
  "Return LEDGER's private semantic capsule."
  (epi-ledger--checkpoint-raw-semantic-capsule
   (epi-ledger--checkpoint-snapshot ledger)))

(defun epi-test-ledger-io--capsule-roots (capsule)
  "Return every graph root retained by CAPSULE."
  (list
   (epi-ledger--semantic-capsule-raw-by-id capsule)
   (epi-ledger--semantic-capsule-raw-operations capsule)
   (epi-ledger--semantic-capsule-raw-turns capsule)
   (epi-ledger--semantic-capsule-raw-turn-operation-index capsule)
   (epi-ledger--semantic-capsule-raw-calls capsule)
   (epi-ledger--semantic-capsule-raw-calls-by-target capsule)
   (epi-ledger--semantic-capsule-raw-reserved-call-ids capsule)
   (epi-ledger--semantic-capsule-raw-intents capsule)
   (epi-ledger--semantic-capsule-raw-active-operation capsule)
   (epi-ledger--semantic-capsule-raw-active-call capsule)
   (epi-ledger--semantic-capsule-raw-session-seen capsule)
   (epi-ledger--semantic-capsule-raw-first-nonsession capsule)
   (epi-ledger--semantic-capsule-raw-pending-proposal capsule)
   (epi-ledger--semantic-capsule-raw-pending-result capsule)
   (epi-ledger--semantic-capsule-raw-terminalization-required capsule)
   (epi-ledger--semantic-capsule-raw-deferred-references capsule)
   (epi-ledger--semantic-capsule-raw-uncertain capsule)
   (epi-ledger--semantic-capsule-raw-uncertainty-phase capsule)
   (epi-ledger--semantic-capsule-raw-uncertainty-class capsule)
   (epi-ledger--semantic-capsule-raw-uncertainty-turn capsule)
   (epi-ledger--semantic-capsule-raw-uncertainty-operation capsule)))

(defun epi-test-ledger-io--validation-roots (state)
  "Return every semantic graph root retained by validation STATE."
  (list
   (epi-ledger--validation-state-by-id state)
   (epi-ledger--validation-state-operations state)
   (epi-ledger--validation-state-turns state)
   (epi-ledger--validation-state-turn-operation-index state)
   (epi-ledger--validation-state-calls state)
   (epi-ledger--validation-state-calls-by-target state)
   (epi-ledger--validation-state-reserved-call-ids state)
   (epi-ledger--validation-state-intents state)
   (epi-ledger--validation-state-active-operation state)
   (epi-ledger--validation-state-active-call state)
   (epi-ledger--validation-state-session-seen state)
   (epi-ledger--validation-state-first-nonsession state)
   (epi-ledger--validation-state-pending-proposal state)
   (epi-ledger--validation-state-pending-result state)
   (epi-ledger--validation-state-terminalization-required state)
   (epi-ledger--validation-state-deferred-references state)
   (epi-ledger--validation-state-uncertain state)
   (epi-ledger--validation-state-uncertainty-phase state)
   (epi-ledger--validation-state-uncertainty-class state)
   (epi-ledger--validation-state-uncertainty-turn state)
   (epi-ledger--validation-state-uncertainty-operation state)))

(defun epi-test-ledger-io--mutable-graph-nodes (roots)
  "Return an eq-set of mutable nodes reachable from ROOTS.
Validated `epi-record' values are immutable leaves and are not traversed."
  (let ((seen (make-hash-table :test #'eq)))
    (cl-labels
        ((visit
          (value)
          (cond
           ((or (null value) (numberp value) (symbolp value)
                (epi-record-p value)))
           ((gethash value seen))
           ((stringp value)
            (puthash value t seen))
           ((consp value)
            (puthash value t seen)
            (visit (car value))
            (visit (cdr value)))
           ((hash-table-p value)
            (puthash value t seen)
            (maphash (lambda (key item)
                       (visit key)
                       (visit item))
                     value))
           ((vectorp value)
            (puthash value t seen)
            (seq-doseq (item value)
              (visit item)))
           (t
            (ert-fail (format "unexpected semantic graph node: %S"
                              value))))))
      (mapc #'visit roots))
    seen))

(defun epi-test-ledger-io--assert-disjoint-graphs (left right)
  "Assert that mutable semantic graphs LEFT and RIGHT share no node."
  (let ((left-nodes (epi-test-ledger-io--mutable-graph-nodes left))
        (right-nodes (epi-test-ledger-io--mutable-graph-nodes right)))
    (maphash (lambda (node _present)
               (should-not (gethash node right-nodes)))
             left-nodes)))

(defun epi-test-ledger-io--source-records (ledger count)
  "Return the first COUNT retained records from LEDGER as a list."
  (let ((source
         (epi-ledger--checkpoint-raw-records
          (epi-ledger--checkpoint-snapshot ledger)))
        records)
    (dotimes (index count)
      (push (epi-ledger--record-source-elt source index) records))
    (nreverse records)))

(defun epi-test-ledger-io--seal-suffix (ledger drafts)
  "Seal DRAFTS after LEDGER and return their records in physical order."
  (let* ((checkpoint (epi-ledger--checkpoint-snapshot ledger))
         (tail (epi-ledger--checkpoint-raw-tail-hash checkpoint))
         (sequence
          (1+ (epi-ledger--record-source-length
               (epi-ledger--checkpoint-raw-records checkpoint))))
         records)
    (dolist (draft drafts)
      (let ((record (epi-ledger-seal-record draft tail sequence)))
        (push record records)
        (setq tail (epi-record-hash record)
              sequence (1+ sequence))))
    (nreverse records)))

(defun epi-test-ledger-io--draft-with-defaults (text)
  "Return a valid message draft with nil ID/time and TEXT content."
  (make-epi-draft
   :id nil :type 'message :at nil
   :turn epi-test-ledger-io--turn-id
   :payload
   `(("role" . "user")
     ("content" . ,(vector `(("type" . "text") ("text" . ,text)))))))

(ert-deftest epi-ledger-open-publishes-complete-semantic-capsule ()
  (should (fboundp 'epi-ledger--checkpoint-raw-semantic-capsule))
  (should (fboundp 'epi-ledger--semantic-capsule-p))
  (dolist (accessor
           '(epi-ledger--semantic-capsule-raw-by-id
             epi-ledger--semantic-capsule-raw-operations
             epi-ledger--semantic-capsule-raw-turns
             epi-ledger--semantic-capsule-raw-turn-operation-index
             epi-ledger--semantic-capsule-raw-calls
             epi-ledger--semantic-capsule-raw-calls-by-target
             epi-ledger--semantic-capsule-raw-reserved-call-ids
             epi-ledger--semantic-capsule-raw-intents
             epi-ledger--semantic-capsule-raw-active-operation
             epi-ledger--semantic-capsule-raw-active-call
             epi-ledger--semantic-capsule-raw-session-seen
             epi-ledger--semantic-capsule-raw-first-nonsession
             epi-ledger--semantic-capsule-raw-pending-proposal
             epi-ledger--semantic-capsule-raw-pending-result
             epi-ledger--semantic-capsule-raw-terminalization-required
             epi-ledger--semantic-capsule-raw-deferred-references
             epi-ledger--semantic-capsule-raw-uncertain
             epi-ledger--semantic-capsule-raw-uncertainty-phase
             epi-ledger--semantic-capsule-raw-uncertainty-class
             epi-ledger--semantic-capsule-raw-uncertainty-turn
             epi-ledger--semantic-capsule-raw-uncertainty-operation))
    (should (fboundp accessor)))
  (epi-test-with-temporary-root (root)
    (let* ((ledger
            (epi-test-ledger-io--open-history
             root (epi-test-ledger-io--pending-result-drafts)))
           (checkpoint (epi-ledger--checkpoint-snapshot ledger))
           (capsule (epi-test-ledger-io--capsule ledger))
           (by-id (epi-ledger--semantic-capsule-raw-by-id capsule))
           (operations
            (epi-ledger--semantic-capsule-raw-operations capsule))
           (turns (epi-ledger--semantic-capsule-raw-turns capsule))
           (calls (epi-ledger--semantic-capsule-raw-calls capsule))
           (operation (gethash epi-test-ledger-io--operation-id operations))
           (turn (gethash epi-test-ledger-io--turn-id turns))
           (call (gethash epi-test-ledger-io--call-id calls)))
      (should (epi-ledger--semantic-capsule-p capsule))
      (should (= 9 (hash-table-count by-id)))
      (dolist (table
               (list by-id operations turns
                (epi-ledger--semantic-capsule-raw-turn-operation-index capsule)
                calls
                (epi-ledger--semantic-capsule-raw-calls-by-target capsule)
                (epi-ledger--semantic-capsule-raw-reserved-call-ids capsule)
                (epi-ledger--semantic-capsule-raw-intents capsule)))
        (should (hash-table-p table)))
      (should
       (eq (epi-ledger--checkpoint-raw-by-id checkpoint)
           by-id))
      (should
       (eq (epi-ledger--checkpoint-raw-turn-operation-index checkpoint)
           (epi-ledger--semantic-capsule-raw-turn-operation-index capsule)))
      (should
       (eq (epi-ledger--checkpoint-raw-tool-facts checkpoint)
           calls))
      (should (eq operation
                  (epi-ledger--semantic-capsule-raw-active-operation capsule)))
      (should (eq turn (plist-get operation :active-turn)))
      (should (eq call
                  (epi-ledger--semantic-capsule-raw-active-call capsule)))
      (should
       (eq call
           (epi-ledger--semantic-capsule-raw-pending-result capsule)))
      (should
       (eq call
           (gethash epi-test-ledger-io--proposal-id
                    (epi-ledger--semantic-capsule-raw-calls-by-target
                     capsule))))
      (should
       (equal epi-test-ledger-io--operation-id
              (gethash epi-test-ledger-io--turn-id
                       (epi-ledger--semantic-capsule-raw-turn-operation-index
                        capsule))))
      (should
       (equal epi-test-ledger-io--turn-id
              (gethash epi-test-ledger-io--user-id
                       (epi-ledger--semantic-capsule-raw-intents capsule))))
      (should
       (gethash epi-test-ledger-io--call-id
                (epi-ledger--semantic-capsule-raw-reserved-call-ids capsule)))
      (should (epi-ledger--semantic-capsule-raw-session-seen capsule))
      (should (eq 'open (plist-get operation :state)))
      (should (eq 'open (plist-get turn :state)))
      (should (eq 'finished (plist-get call :state)))
      (should-not (epi-ledger--semantic-capsule-raw-first-nonsession capsule))
      (should-not (epi-ledger--semantic-capsule-raw-pending-proposal capsule))
      (should-not
       (epi-ledger--semantic-capsule-raw-terminalization-required capsule))
      (should-not
       (epi-ledger--semantic-capsule-raw-deferred-references capsule))
      (should-not (epi-ledger--semantic-capsule-raw-uncertain capsule))
      (should-not
       (epi-ledger--semantic-capsule-raw-uncertainty-phase capsule))
      (should-not
       (epi-ledger--semantic-capsule-raw-uncertainty-class capsule))
      (should-not
       (epi-ledger--semantic-capsule-raw-uncertainty-turn capsule))
      (should-not
       (epi-ledger--semantic-capsule-raw-uncertainty-operation capsule)))))

(ert-deftest epi-ledger-open-capsule-retains-no-record-accumulator-spine ()
  (should (fboundp 'epi-ledger--semantic-capsule-from-state))
  (should (fboundp 'epi-ledger--checkpoint-raw-semantic-capsule))
  (epi-test-with-temporary-root (root)
    (let* ((original
            (symbol-function 'epi-ledger--semantic-capsule-from-state))
           (publication-count 0)
           (accumulator-at-publication :not-called)
           ledger)
      (cl-letf (((symbol-function 'epi-ledger--semantic-capsule-from-state)
                 (lambda (state)
                   (setq publication-count (1+ publication-count)
                         accumulator-at-publication
                         (epi-ledger--validation-state-records-reverse state))
                   (funcall original state))))
        (setq ledger
              (epi-test-ledger-io--open-history
               root (epi-test-ledger-io--pending-result-drafts))))
      (let* (
           (checkpoint (epi-ledger--checkpoint-snapshot ledger))
           (capsule (epi-test-ledger-io--capsule ledger))
           (records (epi-ledger--checkpoint-raw-records checkpoint)))
        (should (= 1 publication-count))
        (should-not accumulator-at-publication)
        (should (= 9 (epi-ledger--record-source-length records)))
        (should (epi-ledger--semantic-capsule-p capsule))
        (should-not
         (fboundp 'epi-ledger--semantic-capsule-raw-records-reverse))))))

(ert-deftest epi-ledger-semantic-capsule-rejects-record-accumulator ()
  (let ((state (epi-ledger--make-empty-validation-state))
        condition)
    (setf (epi-ledger--validation-state-records-reverse state)
          (list :unpublished-record))
    (setq condition
          (should-error
           (epi-ledger--semantic-capsule-from-state state)
           :type 'epi-ledger-format-error))
    (should
     (eq 'semantic-capsule-record-accumulator-not-empty
         (epi-test-ledger-io--condition-code condition)))))

(ert-deftest epi-ledger-semantic-capsule-clone-isolates-all-mutable-state ()
  (should (fboundp 'epi-ledger--semantic-capsule-clone))
  (epi-test-with-temporary-root (root)
    (let* ((ledger
            (epi-test-ledger-io--open-history
             root (epi-test-ledger-io--pending-result-drafts)))
           (capsule (epi-test-ledger-io--capsule ledger))
           (clone-a (epi-ledger--semantic-capsule-clone capsule))
           (clone-b (epi-ledger--semantic-capsule-clone capsule))
           (capsule-roots (epi-test-ledger-io--capsule-roots capsule))
           (clone-a-roots (epi-test-ledger-io--validation-roots clone-a))
           (clone-b-roots (epi-test-ledger-io--validation-roots clone-b))
           (record-id "10000000-0000-4000-8000-000000000001")
           (capsule-record
            (gethash record-id
                     (epi-ledger--semantic-capsule-raw-by-id capsule))))
      (should-not (epi-ledger--validation-state-records-reverse clone-a))
      (should-not (epi-ledger--validation-state-records-reverse clone-b))
      (epi-test-ledger-io--assert-disjoint-graphs
       capsule-roots clone-a-roots)
      (epi-test-ledger-io--assert-disjoint-graphs
       capsule-roots clone-b-roots)
      (epi-test-ledger-io--assert-disjoint-graphs
       clone-a-roots clone-b-roots)
      (should
       (eq capsule-record
           (gethash record-id
                    (epi-ledger--validation-state-by-id clone-a))))
      (should
       (eq capsule-record
           (gethash record-id
                    (epi-ledger--validation-state-by-id clone-b)))))))

(ert-deftest epi-ledger-semantic-capsule-clone-preserves-fact-aliases ()
  (should (fboundp 'epi-ledger--semantic-capsule-clone))
  (epi-test-with-temporary-root (root)
    (let* ((ledger
            (epi-test-ledger-io--open-history
             root (epi-test-ledger-io--pending-result-drafts)))
           (clone-a
            (epi-ledger--semantic-capsule-clone
             (epi-test-ledger-io--capsule ledger)))
           (clone-b
            (epi-ledger--semantic-capsule-clone
             (epi-test-ledger-io--capsule ledger))))
      (dolist (clone (list clone-a clone-b))
        (let* ((operation
                (gethash epi-test-ledger-io--operation-id
                         (epi-ledger--validation-state-operations clone)))
               (turn
                (gethash epi-test-ledger-io--turn-id
                         (epi-ledger--validation-state-turns clone)))
               (call
                (gethash epi-test-ledger-io--call-id
                         (epi-ledger--validation-state-calls clone))))
          (should (eq operation
                      (epi-ledger--validation-state-active-operation clone)))
          (should (eq turn (plist-get operation :active-turn)))
          (should (eq call (epi-ledger--validation-state-active-call clone)))
          (should (eq call
                      (epi-ledger--validation-state-pending-result clone)))
          (should
           (eq call
               (gethash
                epi-test-ledger-io--proposal-id
                (epi-ledger--validation-state-calls-by-target clone))))
          (should
           (eq (plist-get call :proposal)
               (gethash epi-test-ledger-io--proposal-id
                        (epi-ledger--validation-state-by-id clone))))))
      (should-not
       (eq (gethash epi-test-ledger-io--call-id
                    (epi-ledger--validation-state-calls clone-a))
           (gethash epi-test-ledger-io--call-id
                    (epi-ledger--validation-state-calls clone-b)))))))

(ert-deftest epi-ledger-semantic-capsule-clone-shares-record-owned-bodies ()
  (epi-test-with-temporary-root (root)
    (let* ((drafts (epi-test-ledger-io--pending-result-drafts))
           (argument-text (make-string 8192 ?a))
           (model-result (make-string 8192 ?r))
           (proposal (nth 4 drafts))
           (plan (nth 5 drafts))
           (terminal (nth 8 drafts)))
      (setf
       (epi-draft-payload proposal)
       `(("role" . "assistant")
         ("content" .
          ,(vector
            `(("type" . "tool-call")
              ("call_id" . ,epi-test-ledger-io--call-id)
              ("name" . "read_file")
              ("arguments" . (("body" . ,argument-text)))
              ("order" . 0)
              ("group_id" . ,epi-json-null)))))
       (epi-draft-payload plan)
       `(("call_id" . ,epi-test-ledger-io--call-id)
         ("name" . "read_file")
         ("arguments" . (("body" . ,argument-text)))
         ("authority")
         ("order" . 0))
       (epi-draft-payload terminal)
       `(("call_id" . ,epi-test-ledger-io--call-id)
         ("status" . "success")
         ("details")
         ("model_result" . ,model-result)))
      (let* ((ledger (epi-test-ledger-io--open-history root drafts))
             (capsule (epi-test-ledger-io--capsule ledger))
             (calls (epi-ledger--semantic-capsule-raw-calls capsule))
             (call (gethash epi-test-ledger-io--call-id calls))
             (by-id (epi-ledger--semantic-capsule-raw-by-id capsule))
             (plan-record
              (gethash "10000000-0000-4000-8000-000000000014" by-id))
             (terminal-record
              (gethash "10000000-0000-4000-8000-000000000017" by-id))
             (record-arguments
              (epi-ledger--payload-value plan-record "arguments"))
             (record-argument-text
              (epi-ledger--object-value record-arguments "body"))
             (record-model-result
              (epi-ledger--payload-value terminal-record "model_result"))
             (original-substring
              (symbol-function 'substring-no-properties))
             clone)
        (cl-letf (((symbol-function 'substring-no-properties)
                   (lambda (string &rest bounds)
                     (when (or (eq string record-argument-text)
                               (eq string record-model-result))
                       (ert-fail "clone copied a record-owned canonical body"))
                     (apply original-substring string bounds))))
          (setq clone (epi-ledger--semantic-capsule-clone capsule)))
        (let ((clone-call
               (gethash epi-test-ledger-io--call-id
                        (epi-ledger--validation-state-calls clone))))
          (should-not (eq calls
                          (epi-ledger--validation-state-calls clone)))
          (should-not (eq call clone-call))
          (should-not (plist-member clone-call :arguments))
          (should-not (plist-member clone-call :model-result))
          (should (eq plan-record (plist-get clone-call :plan)))
          (should (eq terminal-record (plist-get clone-call :terminal)))
          (should
           (eq record-arguments
               (epi-ledger--payload-value
                (plist-get clone-call :plan) "arguments")))
          (should
           (eq record-argument-text
               (epi-ledger--object-value
                (epi-ledger--payload-value
                 (plist-get clone-call :plan) "arguments")
                "body")))
          (should
           (eq record-model-result
               (epi-ledger--payload-value
                (plist-get clone-call :terminal) "model_result"))))))))

(ert-deftest epi-ledger-semantic-capsule-clones-validate-independently ()
  (should (fboundp 'epi-ledger--semantic-capsule-clone))
  (should (fboundp 'epi-ledger--validation-suffix-records))
  (epi-test-with-temporary-root (root)
    (let* ((ledger
            (epi-test-ledger-io--open-history
             root (epi-test-ledger-io--pending-result-drafts)))
           (capsule (epi-test-ledger-io--capsule ledger))
           (clone-a (epi-ledger--semantic-capsule-clone capsule))
           (clone-b (epi-ledger--semantic-capsule-clone capsule))
           (suffix
            (epi-test-ledger-io--seal-suffix
             ledger (cl-subseq (epi-test-ledger-io--full-drafts) 9)))
           suffix-a suffix-b)
      (dolist (record suffix)
        (epi-ledger--validate-record-semantic
         clone-a (epi-ledger--raw-header ledger) record))
      (should-not (epi-ledger--validation-final-error clone-a))
      (should
       (eq 'finished
           (plist-get
            (gethash epi-test-ledger-io--call-id
                     (epi-ledger--validation-state-calls clone-b))
            :state)))
      (should
       (eq (gethash epi-test-ledger-io--call-id
                    (epi-ledger--validation-state-calls clone-b))
           (epi-ledger--validation-state-pending-result clone-b)))
      (should
       (eq 'finished
           (plist-get
            (gethash epi-test-ledger-io--call-id
                     (epi-ledger--semantic-capsule-raw-calls capsule))
            :state)))
      (dolist (record suffix)
        (epi-ledger--validate-record-semantic
         clone-b (epi-ledger--raw-header ledger) record))
      (should-not (epi-ledger--validation-final-error clone-b))
      (epi-ledger--with-operation-work-state
        (setq suffix-a
              (epi-ledger--validation-suffix-records
               clone-a (epi-ledger--make-work-state))
              suffix-b
              (epi-ledger--validation-suffix-records
               clone-b (epi-ledger--make-work-state))))
      (should (equal suffix suffix-a))
      (should (equal suffix suffix-b))
      (should-not (epi-ledger--validation-state-records-reverse clone-a))
      (should-not (epi-ledger--validation-state-records-reverse clone-b))
      (should-not
       (epi-ledger--semantic-capsule-raw-terminalization-required capsule))
      (should
       (eq (gethash epi-test-ledger-io--call-id
                    (epi-ledger--semantic-capsule-raw-calls capsule))
           (epi-ledger--semantic-capsule-raw-pending-result capsule))))))

(ert-deftest epi-ledger-record-index-extension-shares-prefix-records-and-chunks ()
  (should (fboundp 'epi-ledger--record-index-extend))
  (epi-test-with-temporary-root (root)
    (let* ((ledger
            (epi-test-ledger-io--open-history
             root (epi-test-ledger-io--full-drafts)))
           (old
            (epi-ledger--checkpoint-raw-records
             (epi-ledger--checkpoint-snapshot ledger)))
           (suffix (epi-test-ledger-io--source-records ledger 3))
           (work (epi-ledger--make-work-state))
           (old-chunks (epi-ledger--record-index-raw-chunks old))
           (old-chunk-values (copy-sequence old-chunks))
           (old-cells (cl-loop for tail on old-chunks collect tail))
           (new
            (epi-ledger--with-operation-work-state
              (epi-ledger--record-index-extend old suffix work)))
           (new-chunks (epi-ledger--record-index-raw-chunks new)))
      (should (epi-ledger--record-index-p old))
      (should (= (+ (epi-ledger--record-source-length old) (length suffix))
                 (epi-ledger--record-source-length new)))
      (should (equal old-chunk-values old-chunks))
      (should-not (eq old-chunks new-chunks))
      (cl-mapc
       (lambda (old-cell new-cell)
         (should-not (eq old-cell new-cell))
         (should (eq (car old-cell) (car new-cell))))
       old-cells
       (cl-loop repeat (length old-cells)
                for tail on new-chunks collect tail))
      (dotimes (index (epi-ledger--record-source-length old))
        (should (eq (epi-ledger--record-source-elt old index)
                    (epi-ledger--record-source-elt new index))))
      (dotimes (index (length suffix))
        (should
         (eq (nth index suffix)
             (epi-ledger--record-source-elt
              new (+ (epi-ledger--record-source-length old) index))))))))

(ert-deftest epi-ledger-record-index-extension-bounds-only-suffix-chunks ()
  (should (fboundp 'epi-ledger--record-index-extend))
  (epi-test-with-temporary-root (root)
    (let* ((ledger
            (epi-test-ledger-io--open-history
             root (epi-test-ledger-io--full-drafts)))
           (old
            (epi-ledger--checkpoint-raw-records
             (epi-ledger--checkpoint-snapshot ledger)))
           (suffix (epi-test-ledger-io--source-records ledger 5))
           (old-chunks (epi-ledger--record-index-raw-chunks old))
           (old-counts
            (mapcar #'epi-ledger--record-chunk-raw-count old-chunks)))
      (should (seq-some (lambda (count) (> count 2)) old-counts))
      (let* ((epi-ledger-work-record-limit 2)
             (epi-ledger-work-byte-limit 32)
             (epi-ledger-work-time-budget 1000.0)
             (new
              (epi-ledger--with-operation-work-state
                (epi-ledger--record-index-extend
                 old suffix (epi-ledger--make-work-state))))
             (new-chunks (epi-ledger--record-index-raw-chunks new))
             (new-prefix-chunks (seq-take new-chunks (length old-chunks)))
             (suffix-chunks (nthcdr (length old-chunks) new-chunks)))
        (should (equal old-counts
                       (mapcar #'epi-ledger--record-chunk-raw-count
                               new-prefix-chunks)))
        (cl-mapc (lambda (old-chunk new-chunk)
                   (should (eq old-chunk new-chunk)))
                 old-chunks new-prefix-chunks)
        (should (equal '(2 2 1)
                       (mapcar #'epi-ledger--record-chunk-raw-count
                               suffix-chunks)))
        (dolist (chunk suffix-chunks)
          (should
           (= (epi-ledger--record-chunk-raw-count chunk)
              (length (epi-ledger--record-chunk-raw-values chunk))))
          (should (<= (epi-ledger--record-chunk-raw-count chunk)
                      epi-ledger-work-record-limit))
          (should (<= (* 8 (length
                            (epi-ledger--record-chunk-raw-values chunk)))
                      epi-ledger-work-byte-limit)))))))

(ert-deftest epi-ledger-record-index-repeated-singletons-retain-exact-slots ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger
            (epi-test-ledger-io--open-history
             root (epi-test-ledger-io--full-drafts)))
           (index
            (epi-ledger--checkpoint-raw-records
             (epi-ledger--checkpoint-snapshot ledger)))
           (prefix-chunk-count
            (length (epi-ledger--record-index-raw-chunks index)))
           (record (epi-ledger--record-source-elt index 0))
           (append-count 100))
      (dotimes (_ append-count)
        (setq index
              (epi-ledger--with-operation-work-state
                (epi-ledger--record-index-extend
                 index (list record) (epi-ledger--make-work-state)))))
      (let* ((suffix-chunks
              (nthcdr prefix-chunk-count
                      (epi-ledger--record-index-raw-chunks index)))
             (retained-slots
              (cl-loop
               for chunk in suffix-chunks
               sum (length (epi-ledger--record-chunk-raw-values chunk))))
             (retained-slot-bytes (* 8 retained-slots)))
        (should (= append-count (length suffix-chunks)))
        (dolist (chunk suffix-chunks)
          (should (= 1 (epi-ledger--record-chunk-raw-count chunk)))
          (should (= 1 (length
                        (epi-ledger--record-chunk-raw-values chunk)))))
        (should (= append-count retained-slots))
        (should (<= retained-slot-bytes
                    (+ (* 12 append-count) 1024)))))))

(ert-deftest epi-ledger-record-index-extension-does-not-copy-or-hash-prefix ()
  (should (fboundp 'epi-ledger--record-index-extend))
  (should (fboundp 'epi-ledger--record-source-extend))
  (epi-test-with-temporary-root (root)
    (let* ((ledger
            (epi-test-ledger-io--open-history
             root (epi-test-ledger-io--full-drafts)))
           (old
            (epi-ledger--checkpoint-raw-records
             (epi-ledger--checkpoint-snapshot ledger)))
           (suffix (epi-test-ledger-io--source-records ledger 2))
           (original-hash (symbol-function 'epi-ledger--hash))
           (original-copy (symbol-function 'epi-ledger--copy-record))
           (original-public (symbol-function 'epi-ledger-records))
           (hash-calls 0)
           (copy-calls 0)
           (public-calls 0)
           new)
      (cl-letf (((symbol-function 'epi-ledger--hash)
                 (lambda (&rest arguments)
                   (setq hash-calls (1+ hash-calls))
                   (apply original-hash arguments)))
                ((symbol-function 'epi-ledger--copy-record)
                 (lambda (&rest arguments)
                   (setq copy-calls (1+ copy-calls))
                   (apply original-copy arguments)))
                ((symbol-function 'epi-ledger-records)
                 (lambda (&rest arguments)
                   (setq public-calls (1+ public-calls))
                   (apply original-public arguments))))
        (setq new
              (epi-ledger--with-operation-work-state
                (epi-ledger--record-source-extend
                 old suffix (epi-ledger--make-work-state)))))
      (should (= 0 hash-calls))
      (should (= 0 copy-calls))
      (should (= 0 public-calls))
      (dotimes (index (epi-ledger--record-source-length old))
        (let ((old-record (epi-ledger--record-source-elt old index))
              (new-record (epi-ledger--record-source-elt new index)))
          (should (eq old-record new-record))
          (should (eq (epi-record--raw-payload old-record)
                      (epi-record--raw-payload new-record))))))))

(ert-deftest epi-ledger-record-source-extension-falls-back-at-tiny-byte-limits ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger
            (epi-test-ledger-io--open-history
             root (epi-test-ledger-io--full-drafts)))
           (old
            (epi-ledger--checkpoint-raw-records
             (epi-ledger--checkpoint-snapshot ledger)))
           (suffix (epi-test-ledger-io--source-records ledger 3))
           (expected
            (append
             (epi-test-ledger-io--source-records
              ledger (epi-ledger--record-source-length old))
             suffix)))
      (should (epi-ledger--record-index-p old))
      (dolist (byte-limit '(1 2 3 4 5 6 7))
        (let ((epi-ledger-work-byte-limit byte-limit)
              (epi-ledger-work-record-limit 2)
              (epi-ledger-work-time-budget 1000.0)
              (nonpreemptible-calls 0)
              (hash-calls 0)
              (copy-calls 0)
              result direct-condition)
          (cl-letf (((symbol-function 'epi-ledger--run-nonpreemptible)
                     (lambda (&rest _arguments)
                       (setq nonpreemptible-calls
                             (1+ nonpreemptible-calls))
                       (ert-fail "tiny record extension was nonpreemptible")))
                    ((symbol-function 'epi-ledger--hash)
                     (lambda (&rest _arguments)
                       (setq hash-calls (1+ hash-calls))
                       (ert-fail "tiny record extension hashed a record")))
                    ((symbol-function 'epi-ledger--copy-record)
                     (lambda (&rest _arguments)
                       (setq copy-calls (1+ copy-calls))
                       (ert-fail "tiny record extension copied a record"))))
            (setq result
                  (epi-ledger--with-operation-work-state
                    (epi-ledger--record-source-extend
                     old suffix (epi-ledger--make-work-state))))
            (setq direct-condition
                  (should-error
                   (epi-ledger--with-operation-work-state
                     (epi-ledger--record-index-extend
                      old suffix (epi-ledger--make-work-state)))
                   :type 'epi-limit-exceeded)))
          (should (listp result))
          (should (= (length expected) (proper-list-p result)))
          (cl-mapc (lambda (wanted actual) (should (eq wanted actual)))
                   expected result)
          (should
           (eq 'record-index-work-byte-limit
               (epi-test-ledger-io--condition-code direct-condition)))
          (should (= 0 nonpreemptible-calls))
          (should (= 0 hash-calls))
          (should (= 0 copy-calls)))))))

(ert-deftest epi-ledger-checkpoint-cas-is-eq-guarded ()
  (should (fboundp 'epi-ledger--checkpoint-cas))
  (should (fboundp 'epi-ledger--checkpoint-uncertain-successor))
  (epi-test-with-temporary-root (root)
    (let* ((ledger
            (epi-test-ledger-io--open-history
             root (epi-test-ledger-io--full-drafts)))
           (expected (epi-ledger--checkpoint-snapshot ledger))
           (equal-twin (copy-sequence expected))
           (replacement (epi-ledger--checkpoint-uncertain-successor expected)))
      (should-not (eq expected replacement))
      (should-not (epi-ledger--checkpoint-raw-uncertain expected))
      (should (epi-ledger--checkpoint-raw-uncertain replacement))
      (dolist (accessor
               '(epi-ledger--checkpoint-raw-file-identity
                 epi-ledger--checkpoint-raw-validated-end-offset
                 epi-ledger--checkpoint-raw-tail-hash
                 epi-ledger--checkpoint-raw-records
                 epi-ledger--checkpoint-raw-by-id
                 epi-ledger--checkpoint-raw-turn-operation-index
                 epi-ledger--checkpoint-raw-tool-facts
                 epi-ledger--checkpoint-raw-semantic-capsule))
        (should (eq (funcall accessor expected)
                    (funcall accessor replacement))))
      (should (equal expected equal-twin))
      (should-not (eq expected equal-twin))
      (let ((epi--yield-function
             (lambda () (ert-fail "checkpoint CAS invoked yield callback"))))
        (cl-letf (((symbol-function 'epi--yield)
                   (lambda () (ert-fail "checkpoint CAS yielded"))))
          (should-not
           (epi-ledger--checkpoint-cas ledger equal-twin replacement))
          (should (eq expected (epi-ledger--checkpoint-snapshot ledger)))
          (should (epi-ledger--checkpoint-cas ledger expected replacement))
          (should (eq replacement (epi-ledger--checkpoint-snapshot ledger)))
          (should-not (epi-ledger--checkpoint-cas ledger expected equal-twin))
          (should
           (eq replacement (epi-ledger--checkpoint-snapshot ledger))))))))

(ert-deftest epi-ledger-file-identity-is-a-defensive-plist-copy ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger
            (epi-test-ledger-io--open-history
             root (epi-test-ledger-io--full-drafts)))
           (raw
            (epi-ledger--checkpoint-raw-file-identity
             (epi-ledger--checkpoint-snapshot ledger)))
           expected first second)
      (cl-labels
          ((copy-value
            (value)
            (cond
             ((stringp value) (substring-no-properties value))
             ((consp value)
              (cons (copy-value (car value)) (copy-value (cdr value))))
             ((vectorp value)
              (apply #'vector (mapcar #'copy-value value)))
             (t value))))
        (setq expected (copy-value raw)))
      ;; RED before the fix: the public JSON-value copier rejects keyword
      ;; plist entries as non-object entries.
      (setq first (epi-ledger-file-identity ledger))
      (should (equal expected first))
      (should-not (eq raw first))
      (should-not (eq (plist-get raw :path) (plist-get first :path)))
      (should-not
       (eq (plist-get raw :modified) (plist-get first :modified)))
      (setf (plist-get first :size) -1)
      (aset (plist-get first :path) 0 ?X)
      (let ((time (plist-get first :modified)))
        (cond
         ((consp time) (setcar time -1))
         ((vectorp time) (aset time 0 -1))
         (t (ert-fail "file identity time is not a mutable sequence"))))
      (should (equal expected raw))
      (setq second (epi-ledger-file-identity ledger))
      (should (equal expected second))
      (should-not (eq first second))
      (should-not (eq (plist-get first :path) (plist-get second :path)))
      (should-not
       (eq (plist-get first :modified) (plist-get second :modified))))))

(ert-deftest epi-ledger-batch-limits-are-independent-of-work-cadence ()
  (should (boundp 'epi-ledger--batch-record-limit))
  (should (boundp 'epi-ledger--batch-byte-limit))
  (should (fboundp 'epi-ledger--snapshot-draft-batch))
  (should (= 256 epi-ledger--batch-record-limit))
  (should (= 33554432 epi-ledger--batch-byte-limit))
  (let* ((id (copy-sequence "50000000-0000-4000-8000-000000000001"))
         (at (copy-sequence "2026-07-21T18:44:02-07:00"))
         (text (copy-sequence "owned text"))
         (draft
          (make-epi-draft
           :id id :type 'message :at at :turn epi-test-ledger-io--turn-id
           :payload
           `(("role" . "user")
             ("content" .
              ,(vector `(("type" . "text") ("text" . ,text)))))))
         (drafts (list draft (epi-test-ledger-io--operation-started)))
         (expected-id (copy-sequence id))
         (expected-at (copy-sequence at))
         low high)
    (cl-labels
        ((snapshot
          (record-limit byte-limit time-budget)
          (let ((epi-ledger-work-record-limit record-limit)
                (epi-ledger-work-byte-limit byte-limit)
                (epi-ledger-work-time-budget time-budget)
                (yield-count 0)
                owned)
            (let ((epi--yield-function
                   (lambda () (setq yield-count (1+ yield-count)))))
              (setq owned (epi-ledger--snapshot-draft-batch drafts)))
            (cons owned yield-count))))
      (setq low (snapshot 1 1 0.0)
            high (snapshot 4096 1048576 1000.0)))
    (dolist (result (list low high))
      (let ((owned (car result)))
        (should (vectorp owned))
        (should (= 2 (length owned)))
        (should (= 0 (cdr result)))
        (should-not (eq draft (aref owned 0)))
        (should-not (eq (epi-draft-payload draft)
                        (epi-draft-payload (aref owned 0))))))
    (should (equal (car low) (car high)))
    (should-not (eq (car low) (car high)))
    (setcar drafts nil)
    (aset id 0 ?9)
    (aset at 0 ?9)
    (aset text 0 ?X)
    (setf (epi-draft-payload draft) nil)
    (dolist (owned (list (car low) (car high)))
      (let* ((owned-draft (aref owned 0))
             (content (cdr (assoc "content"
                                  (epi-draft-payload owned-draft))))
             (owned-text (cdr (assoc "text" (aref content 0)))))
        (should (equal expected-id (epi-draft-id owned-draft)))
        (should (equal expected-at (epi-draft-at owned-draft)))
        (should (equal "owned text" owned-text))))))

(ert-deftest epi-ledger-batch-record-limit-precedes-default-sources-and-io ()
  (should (boundp 'epi-ledger--batch-record-limit))
  (should (fboundp 'epi-ledger--snapshot-draft-batch))
  (let ((epi--id-function
         (lambda () (ert-fail "record cap invoked ID source")))
        (epi--wall-clock-function
         (lambda () (ert-fail "record cap invoked wall clock")))
        (epi--yield-function
         (lambda () (ert-fail "record cap yielded")))
        condition)
    (cl-labels ((unexpected-io
                 (&rest _arguments)
                 (ert-fail "record cap invoked file I/O")))
      (cl-letf (((symbol-function 'write-region) #'unexpected-io)
                ((symbol-function 'insert-file-contents) #'unexpected-io)
                ((symbol-function 'insert-file-contents-literally)
                 #'unexpected-io)
                ((symbol-function 'file-attributes) #'unexpected-io))
        (setq condition
              (should-error
               (epi-ledger--snapshot-draft-batch (make-list 257 nil))
               :type 'epi-limit-exceeded))))
    (let ((detail (epi-test-ledger-io--condition-detail condition)))
      (should (eq :code (car detail)))
      (should (eq 'batch-record-limit
                  (epi-test-ledger-io--condition-code condition)))
      (should (= 256 (plist-get detail :limit)))
      (should (= 257 (plist-get detail :count))))))

(ert-deftest epi-ledger-batch-byte-limit-precedes-default-sources-and-io ()
  (should (boundp 'epi-ledger--batch-byte-limit))
  (should (fboundp 'epi-ledger--snapshot-draft-batch))
  (let* ((draft
          (epi-test-ledger-io--draft-with-defaults (make-string 2048 ?x)))
         (epi--id-function
          (lambda () (ert-fail "byte cap invoked ID source")))
         (epi--wall-clock-function
          (lambda () (ert-fail "byte cap invoked wall clock")))
         (epi--yield-function
          (lambda () (ert-fail "byte cap yielded")))
         condition)
    (cl-labels ((unexpected-io
                 (&rest _arguments)
                 (ert-fail "byte cap invoked file I/O")))
      (cl-letf (((symbol-function 'write-region) #'unexpected-io)
                ((symbol-function 'insert-file-contents) #'unexpected-io)
                ((symbol-function 'insert-file-contents-literally)
                 #'unexpected-io)
                ((symbol-function 'file-attributes) #'unexpected-io))
        (cl-progv '(epi-ledger--batch-byte-limit) '(512)
          (setq condition
                (should-error
                 (epi-ledger--snapshot-draft-batch (vector draft))
                 :type 'epi-limit-exceeded)))))
    (let ((detail (epi-test-ledger-io--condition-detail condition)))
      (should (eq :code (car detail)))
      (should (eq 'batch-byte-limit
                  (epi-test-ledger-io--condition-code condition)))
      (should (= 512 (plist-get detail :limit)))
      (should (> (plist-get detail :bytes) 512)))
    (should-not (epi-draft-id draft))
    (should-not (epi-draft-at draft))))

;;;; Wave 1: path ownership and exact byte I/O

(defconst epi-test-ledger-io--wave1-storage-mutation-seams
  '(epi-ledger--byte-writer
    epi-ledger--lock-create-function
    epi-ledger--append-function
    epi-ledger--flush-function
    epi-ledger--read-function
    epi-ledger--unlock-function
    epi-ledger--publish-function)
  "Storage mutation seams forbidden during Wave 1 path rejection tests.")

(defun epi-test-ledger-io--literal-file-bytes (path)
  "Return PATH's exact bytes in a fresh property-free unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'no-conversion)
          (file-name-handler-alist nil))
      (insert-file-contents-literally path))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun epi-test-ledger-io--permission-bits (path)
  "Return PATH's low nine Unix permission bits."
  (logand #o777 (file-modes path)))

(defun epi-test-ledger-io--unexpected-storage-call (&rest arguments)
  "Fail because a rejected path reached a storage seam with ARGUMENTS."
  (ert-fail (format "rejected path reached storage seam: %S" arguments)))

(defun epi-test-ledger-io--resolve-error-before-mutation
    (path &optional expected-code)
  "Resolve PATH and require EXPECTED-CODE before storage mutation.
EXPECTED-CODE defaults to `invalid-write-path'."
  (let ((values
         (make-list
          (length epi-test-ledger-io--wave1-storage-mutation-seams)
          #'epi-test-ledger-io--unexpected-storage-call)))
    (cl-progv epi-test-ledger-io--wave1-storage-mutation-seams values
      (let ((condition
             (should-error
              (epi-ledger--resolve-local-write-path path)
              :type 'epi-ledger-format-error)))
        (should (eq (or expected-code 'invalid-write-path)
                    (epi-test-ledger-io--condition-code condition)))
        condition))))

(defun epi-test-ledger-io--hostile-file-handler
    (operation &rest arguments)
  "Fail if hostile file handler OPERATION receives ARGUMENTS."
  (ert-fail
   (format "hostile file handler invoked: %S %S" operation arguments)))

(defun epi-test-ledger-io--hostile-annotation (&rest arguments)
  "Fail if a write annotation hook receives ARGUMENTS."
  (ert-fail (format "write annotation invoked: %S" arguments)))

(defun epi-test-ledger-io--hostile-format (&rest arguments)
  "Fail if ambient format conversion receives ARGUMENTS."
  (ert-fail (format "file format conversion invoked: %S" arguments)))

(ert-deftest epi-ledger-byte-writer-preserves-bytes-in-hostile-environment ()
  (should (fboundp 'epi-ledger--write-bytes))
  (epi-test-with-temporary-root (root)
    (let* ((path (expand-file-name "hostile.bin" root))
           (bytes (apply #'unibyte-string
                         '(0 1 9 10 13 27 65 127 128 254 255)))
           (file-coding-system-alist
            `((,(regexp-quote path) . utf-16)))
           (coding-system-for-write 'utf-16)
           (buffer-file-coding-system 'utf-16)
           (buffer-file-format '(epi-test-ledger-io--hostile-format))
           (format-alist
            '((epi-test-ledger-io--hostile-format
               "hostile test format" nil nil
               epi-test-ledger-io--hostile-format nil nil nil)))
           (write-region-annotate-functions
            '(epi-test-ledger-io--hostile-annotation))
           (write-region-post-annotation-function
            #'epi-test-ledger-io--hostile-annotation)
           (write-region-inhibit-fsync t)
           (create-lockfiles t)
           (file-name-handler-alist
            '(("\\`/hostile:" . epi-test-ledger-io--hostile-file-handler))))
      (epi-ledger--write-bytes path bytes 'exclusive-create t)
      (should (equal bytes (epi-test-ledger-io--literal-file-bytes path)))
      (should-not
       (seq-some (lambda (name) (string-prefix-p ".#" name))
                 (directory-files root nil nil t))))))

(ert-deftest epi-ledger-byte-writer-durable-flag-controls-fsync ()
  (should (fboundp 'epi-ledger--write-bytes))
  (epi-test-with-temporary-root (root)
    (let ((path (expand-file-name "durability.bin" root))
          (saved-write-region (symbol-function 'write-region))
          observations)
      (cl-letf
          (((symbol-function 'write-region)
            (lambda (&rest arguments)
              (push write-region-inhibit-fsync observations)
              (apply saved-write-region arguments))))
        (epi-ledger--write-bytes path "nondurable" 'exclusive-create nil)
        (epi-ledger--write-bytes path "durable" 'replace t))
      (should (equal '(t nil) (nreverse observations)))
      (should (equal "durable"
                     (epi-test-ledger-io--literal-file-bytes path))))))

(ert-deftest epi-ledger-byte-writer-enforces-three-closed-modes ()
  (should (fboundp 'epi-ledger--write-bytes))
  (epi-test-with-temporary-root (root)
    (let ((path (expand-file-name "modes.bin" root)))
      (epi-ledger--write-bytes path "alpha" 'exclusive-create nil)
      (let ((condition
             (should-error
              (epi-ledger--write-bytes
               path "replacement" 'exclusive-create nil)
              :type 'epi-ledger-conflict)))
        (should (eq 'destination-exists
                    (epi-test-ledger-io--condition-code condition))))
      (should (equal "alpha" (epi-test-ledger-io--literal-file-bytes path)))
      (epi-ledger--write-bytes path "-beta" 'append nil)
      (should
       (equal "alpha-beta" (epi-test-ledger-io--literal-file-bytes path)))
      (epi-ledger--write-bytes path "gamma" 'replace t)
      (should (equal "gamma" (epi-test-ledger-io--literal-file-bytes path)))
      (dolist (mode '(nil exclusive create overwrite write t))
        (let ((condition
               (should-error
                (epi-ledger--write-bytes path "bad" mode nil)
                :type 'epi-ledger-format-error)))
          (should (eq 'invalid-write-mode
                      (epi-test-ledger-io--condition-code condition))))
        (should
         (equal "gamma" (epi-test-ledger-io--literal-file-bytes path))))
      (let ((condition
             (should-error
              (epi-ledger--write-bytes path "multibyte-é" 'replace nil)
              :type 'epi-ledger-format-error)))
        (should (eq 'unibyte-write-required
                    (epi-test-ledger-io--condition-code condition))))
      (should (equal "gamma" (epi-test-ledger-io--literal-file-bytes path))))))

(ert-deftest epi-ledger-final-flush-is-an-empty-fsyncing-append ()
  (dolist (variable
           '(epi-ledger--byte-writer
             epi-ledger--lock-create-function
             epi-ledger--append-function
             epi-ledger--flush-function
             epi-ledger--stat-function
             epi-ledger--read-function
             epi-ledger--unlock-function
             epi-ledger--publish-function))
    (should (boundp variable)))
  (let ((path "/tmp/epi-wave1-flush.bin")
        (payload (string-make-unibyte "suffix"))
        calls)
    (let ((epi-ledger--byte-writer
           (lambda (target bytes mode durablep)
             (push (list target bytes mode durablep) calls))))
      (funcall epi-ledger--append-function path payload)
      (funcall epi-ledger--flush-function path))
    (setq calls (nreverse calls))
    (should (= 2 (length calls)))
    (should (equal (list path payload 'append nil) (car calls)))
    (pcase-let ((`(,target ,bytes ,mode ,durablep) (cadr calls)))
      (should (equal path target))
      (should (stringp bytes))
      (should-not (multibyte-string-p bytes))
      (should (= 0 (length bytes)))
      (should (eq 'append mode))
      (should durablep))))

(ert-deftest epi-ledger-write-path-rejects-remote-handler-and-directory-before-io ()
  (should (fboundp 'epi-ledger--resolve-local-write-path))
  (dolist (variable epi-test-ledger-io--wave1-storage-mutation-seams)
    (should (boundp variable)))
  (epi-test-with-temporary-root (root)
    (let ((directory (expand-file-name "existing-directory" root))
          (handled (expand-file-name "handled/session.org" root)))
      (make-directory directory)
      (epi-test-ledger-io--resolve-error-before-mutation
       "/ssh:epi-wave1.invalid:/tmp/session.org")
      (let ((file-name-handler-alist
             `((,(concat "\\`" (regexp-quote
                                  (file-name-directory handled)))
                . epi-test-ledger-io--hostile-file-handler))))
        (cl-letf (((symbol-function 'file-remote-p)
                   #'epi-test-ledger-io--unexpected-storage-call)
                  ((symbol-function 'file-exists-p)
                   #'epi-test-ledger-io--unexpected-storage-call)
                  ((symbol-function 'file-attributes)
                   #'epi-test-ledger-io--unexpected-storage-call)
                  ((symbol-function 'file-directory-p)
                   #'epi-test-ledger-io--unexpected-storage-call)
                  ((symbol-function 'file-truename)
                   #'epi-test-ledger-io--unexpected-storage-call))
          (epi-test-ledger-io--resolve-error-before-mutation handled)))
      (epi-test-ledger-io--resolve-error-before-mutation
       directory 'non-regular-storage-leaf)
      (epi-test-ledger-io--resolve-error-before-mutation
       (file-name-as-directory directory)))))

(ert-deftest epi-ledger-byte-writer-rejects-handler-owned-path-before-bypass ()
  (should (fboundp 'epi-ledger--write-bytes))
  (epi-test-with-temporary-root (root)
    (let* ((parent (expand-file-name "handled" root))
           (path (expand-file-name "session.org" parent))
           (file-name-handler-alist
            `((,(concat "\\`" (regexp-quote
                                 (file-name-as-directory parent)))
               . epi-test-ledger-io--hostile-file-handler))))
      (cl-letf (((symbol-function 'file-remote-p)
                 #'epi-test-ledger-io--unexpected-storage-call)
                ((symbol-function 'file-exists-p)
                 #'epi-test-ledger-io--unexpected-storage-call)
                ((symbol-function 'file-attributes)
                 #'epi-test-ledger-io--unexpected-storage-call)
                ((symbol-function 'file-directory-p)
                 #'epi-test-ledger-io--unexpected-storage-call)
                ((symbol-function 'file-truename)
                 #'epi-test-ledger-io--unexpected-storage-call)
                ((symbol-function 'write-region)
                 #'epi-test-ledger-io--unexpected-storage-call)
                ((symbol-function 'set-file-modes)
                 #'epi-test-ledger-io--unexpected-storage-call))
        (let ((condition
               (should-error
                (epi-ledger--write-bytes
                 path (string-make-unibyte "forbidden") 'replace nil)
                :type 'epi-ledger-format-error)))
          (should (eq 'invalid-write-path
                      (epi-test-ledger-io--condition-code condition))))))))

(ert-deftest epi-ledger-byte-writer-maps-postproof-probe-errors ()
  (should (fboundp 'epi-ledger--write-bytes))
  (epi-test-with-temporary-root (root)
    (let* ((path (expand-file-name "probe-error.bin" root))
           (canonical (epi-ledger--resolve-local-write-path path))
           write-called)
      (cl-letf (((symbol-function 'epi-ledger--resolve-local-write-path)
                 (lambda (_path) canonical))
                ((symbol-function 'file-exists-p)
                 (lambda (_path) (signal 'file-error '("injected probe"))))
                ((symbol-function 'write-region)
                 (lambda (&rest _arguments) (setq write-called t))))
        (let ((condition
               (should-error
                (epi-ledger--write-bytes path "bytes" 'replace nil)
                :type 'epi-ledger-conflict)))
          (should (eq 'storage-write-failed
                      (epi-test-ledger-io--condition-code condition)))))
      (should-not write-called)
      (should-not (file-exists-p path)))))

(ert-deftest epi-ledger-private-parent-maps-postproof-probe-errors ()
  (should (fboundp 'epi-ledger--ensure-private-parent))
  (epi-test-with-temporary-root (root)
    (let* ((path (expand-file-name "missing/session.org" root))
           (canonical (epi-ledger--resolve-local-write-path path))
           (saved-file-symlink-p (symbol-function 'file-symlink-p))
           (saved-file-directory-p (symbol-function 'file-directory-p))
           (cases
            (list
             (list (lambda (_path)
                     (signal 'file-error '("exists probe failed")))
                   saved-file-symlink-p saved-file-directory-p)
             (list (lambda (_path) nil)
                   (lambda (_path)
                     (signal 'file-error '("symlink probe failed")))
                   saved-file-directory-p)
             (list (lambda (_path) t)
                   (lambda (_path) nil)
                   (lambda (_path)
                     (signal 'file-error '("directory probe failed")))))))
      (dolist (case cases)
        (cl-letf (((symbol-function 'epi-ledger--resolve-local-write-path)
                   (lambda (_path) canonical))
                  ((symbol-function 'file-exists-p) (nth 0 case))
                  ((symbol-function 'file-symlink-p) (nth 1 case))
                  ((symbol-function 'file-directory-p) (nth 2 case))
                  ((symbol-function 'make-directory)
                   #'epi-test-ledger-io--unexpected-storage-call))
          (let ((condition
                 (should-error
                  (epi-ledger--ensure-private-parent canonical)
                  :type 'epi-ledger-conflict)))
            (should (eq 'storage-write-failed
                        (epi-test-ledger-io--condition-code condition))))))
      (should-not (file-exists-p (file-name-directory canonical))))))

(ert-deftest epi-ledger-byte-writer-exclusive-create-closes-precheck-race ()
  (should (fboundp 'epi-ledger--write-bytes))
  (epi-test-with-temporary-root (root)
    (let* ((path (expand-file-name "exclusive-race.bin" root))
           (winner (string-make-unibyte "winner"))
           (candidate (string-make-unibyte "candidate"))
           (saved-write-region (symbol-function 'write-region))
           installed
           candidate-mustbenew)
      (cl-letf
          (((symbol-function 'write-region)
            (lambda (start end filename
                           &optional append visit lockname mustbenew)
              (when (and (equal filename path) (not installed))
                (setq installed t)
                (funcall saved-write-region
                         winner nil path nil 'silent nil 'excl))
              (setq candidate-mustbenew mustbenew)
              (funcall saved-write-region
                       start end filename append visit lockname mustbenew))))
        (let ((condition
               (should-error
                (epi-ledger--write-bytes
                 path candidate 'exclusive-create nil)
                :type 'epi-ledger-conflict)))
          (should (eq 'destination-exists
                      (epi-test-ledger-io--condition-code condition)))))
      (should installed)
      (should (eq 'excl candidate-mustbenew))
      (should (equal winner
                     (epi-test-ledger-io--literal-file-bytes path))))))

(ert-deftest epi-ledger-byte-reader-returns-exact-owned-unibyte-range ()
  (should (boundp 'epi-ledger--read-function))
  (epi-test-with-temporary-root (root)
    (let* ((path (expand-file-name "literal-range.bin" root))
           (bytes (apply #'unibyte-string '(65 0 127 128 255 66)))
           (expected (substring-no-properties bytes 1 5)))
      (let ((coding-system-for-write 'no-conversion)
            (file-name-handler-alist nil))
        (write-region bytes nil path nil 'silent nil 'excl))
      (let* ((coding-system-for-read 'utf-16)
             (file-coding-system-alist
              `((,(regexp-quote path) . utf-16)))
             (file-name-handler-alist
              '(("\\`/irrelevant:" .
                 epi-test-ledger-io--hostile-file-handler)))
             (first (funcall epi-ledger--read-function path 1 5)))
        (should (stringp first))
        (should-not (multibyte-string-p first))
        (should-not (text-properties-at 0 first))
        (should (equal expected first))
        (aset first 0 ?X)
        (let ((second (funcall epi-ledger--read-function path 1 5)))
          (should (equal expected second))
          (should-not (eq first second))
          (should-not (multibyte-string-p second))
          (should-not (text-properties-at 0 second)))))))

(ert-deftest epi-ledger-byte-reader-inhibits-modification-hooks ()
  (should (boundp 'epi-ledger--read-function))
  (epi-test-with-temporary-root (root)
    (let* ((path (expand-file-name "hook-isolation.bin" root))
           (bytes (apply #'unibyte-string '(0 1 2 127 128 254 255)))
           (old-before (default-value 'before-change-functions))
           (old-after (default-value 'after-change-functions))
           (calls 0)
           (hostile
            (lambda (&rest _arguments)
              (setq calls (1+ calls))
              (ert-fail "literal byte read ran a modification hook"))))
      (epi-ledger--write-bytes path bytes 'exclusive-create t)
      (unwind-protect
          (progn
            (set-default 'before-change-functions (list hostile))
            (set-default 'after-change-functions (list hostile))
            (should (equal bytes
                           (funcall epi-ledger--read-function
                                    path 0 (length bytes)))))
        (set-default 'before-change-functions old-before)
        (set-default 'after-change-functions old-after))
      (should (= 0 calls)))))

(ert-deftest epi-ledger-write-path-rejects-newline-nul-and-lexical-escape-before-io ()
  (should (fboundp 'epi-ledger--resolve-local-write-path))
  (dolist (variable epi-test-ledger-io--wave1-storage-mutation-seams)
    (should (boundp variable)))
  (epi-test-with-temporary-root (root)
    (dolist (path
             (list
              (concat root "bad\nname.org")
              (concat root "bad\rname.org")
              (concat root "bad" (string 0) "name.org")
              (concat (file-name-as-directory root)
                      "missing/../../escape/session.org")))
      (epi-test-ledger-io--resolve-error-before-mutation path))))

(ert-deftest epi-ledger-write-path-resolves-an-absent-leaf-once ()
  (should (fboundp 'epi-ledger--resolve-local-write-path))
  (should (fboundp 'epi-ledger--ensure-private-parent))
  (should (fboundp 'epi-ledger--hidden-sibling))
  (epi-test-with-temporary-root (root)
    (let* ((real-parent (expand-file-name "real-parent" root))
           (alternate-parent (expand-file-name "alternate-parent" root))
           (alias (expand-file-name "alias" root)))
      (make-directory real-parent)
      (make-directory alternate-parent)
      (make-symbolic-link real-parent alias)
      (let* ((raw
              (expand-file-name
               "one/two/session.org" (file-name-as-directory alias)))
             (expected
              (expand-file-name
               "one/two/session.org"
               (file-name-as-directory (file-truename real-parent))))
             (resolved (epi-ledger--resolve-local-write-path raw)))
        (should (stringp resolved))
        (should-not (text-properties-at 0 resolved))
        (should-not (eq raw resolved))
        (should (equal expected resolved))
        (aset raw (1- (length raw)) ?X)
        (delete-file alias)
        (make-symbolic-link alternate-parent alias)
        (epi-ledger--ensure-private-parent resolved)
        (should
         (file-directory-p (expand-file-name "one/two" real-parent)))
        (should-not
         (file-exists-p (expand-file-name "one" alternate-parent)))
        (let ((sibling (epi-ledger--hidden-sibling resolved "fixed")))
          (should (equal (file-name-directory resolved)
                         (file-name-directory sibling)))
          (should
           (equal ".session.org.fixed" (file-name-nondirectory sibling)))
          (should-not (text-properties-at 0 sibling)))
        (dolist (suffix '("" "." ".." "bad/name" "bad\nname"))
          (let ((condition
                 (should-error
                  (epi-ledger--hidden-sibling resolved suffix)
                  :type 'epi-ledger-format-error)))
            (should (eq 'invalid-hidden-sibling-suffix
                        (epi-test-ledger-io--condition-code condition)))))
        (should (equal expected resolved))))))

(ert-deftest epi-ledger-created-directories-and-files-have-private-modes ()
  (should (fboundp 'epi-ledger--resolve-local-write-path))
  (should (fboundp 'epi-ledger--ensure-private-parent))
  (should (fboundp 'epi-ledger--write-bytes))
  (epi-test-with-temporary-root (root)
    (let* ((requested (expand-file-name "private/a/session.org" root))
           (path (epi-ledger--resolve-local-write-path requested))
           (first (file-name-directory
                   (directory-file-name (file-name-directory path))))
           (second (file-name-directory path)))
      (should-not (file-exists-p first))
      (epi-ledger--ensure-private-parent path)
      (epi-ledger--write-bytes path "private" 'exclusive-create t)
      (should (= #o700 (epi-test-ledger-io--permission-bits first)))
      (should (= #o700 (epi-test-ledger-io--permission-bits second)))
      (should (= #o600 (epi-test-ledger-io--permission-bits path)))
      (should
       (equal "private" (epi-test-ledger-io--literal-file-bytes path))))))

(ert-deftest epi-ledger-created-directories-are-private-before-chmod ()
  (should (fboundp 'epi-ledger--resolve-local-write-path))
  (should (fboundp 'epi-ledger--ensure-private-parent))
  (epi-test-with-temporary-root (root)
    (let* ((requested (expand-file-name "private-before/a/session.org" root))
           (path (epi-ledger--resolve-local-write-path requested))
           (saved-set-file-modes (symbol-function 'set-file-modes))
           observations)
      (cl-letf
          (((symbol-function 'set-file-modes)
            (lambda (file mode &optional flag)
              (when (file-in-directory-p file root)
                (push (list (substring-no-properties file)
                            (epi-test-ledger-io--permission-bits file)
                            mode)
                      observations))
              (funcall saved-set-file-modes file mode flag))))
        (with-file-modes #o777
          (epi-ledger--ensure-private-parent path)))
      (setq observations (nreverse observations))
      (should (= 2 (length observations)))
      (dolist (observation observations)
        (should (= #o700 (nth 1 observation)))
        (should (= #o700 (nth 2 observation)))))))

(ert-deftest epi-ledger-write-path-preserves-existing-parent-mode ()
  (should (fboundp 'epi-ledger--resolve-local-write-path))
  (should (fboundp 'epi-ledger--ensure-private-parent))
  (should (fboundp 'epi-ledger--write-bytes))
  (epi-test-with-temporary-root (root)
    (let* ((parent (expand-file-name "custom-parent" root))
           (requested (expand-file-name "owned/session.org" parent)))
      (make-directory parent)
      (set-file-modes parent #o751)
      (let* ((original-mode (epi-test-ledger-io--permission-bits parent))
             (path (epi-ledger--resolve-local-write-path requested))
             (created (file-name-directory path)))
        (epi-ledger--ensure-private-parent path)
        (epi-ledger--write-bytes path "mode" 'exclusive-create nil)
        (should (= #o751 original-mode))
        (should (= original-mode
                   (epi-test-ledger-io--permission-bits parent)))
        (should (= #o700 (epi-test-ledger-io--permission-bits created)))
        (should (= #o600 (epi-test-ledger-io--permission-bits path)))))))

(ert-deftest epi-ledger-object-input-is-owned-before-the-first-yield ()
  (should (fboundp 'epi-ledger--snapshot-object-input))
  (let* ((bytes (make-string epi-object-byte-limit ?a))
         (media-type (copy-sequence "application/octet-stream"))
         (role (copy-sequence "artifact"))
         (yield-count 0)
         snapshot)
    (put-text-property 0 1 'epi-test-property t bytes)
    (put-text-property 0 1 'epi-test-property t media-type)
    (put-text-property 0 1 'epi-test-property t role)
    (let ((epi--yield-function
           (lambda ()
             (setq yield-count (1+ yield-count))
             (when (= yield-count 1)
               (aset bytes 0 ?z)
               (aset media-type 0 ?X)
               (aset role 0 ?X)))))
      ;; The frozen private result is a plist so later object work consumes
      ;; only these owned values.  Hashing it supplies the first yield.
      (setq snapshot
            (epi-ledger--snapshot-object-input bytes media-type role))
      (should (equal
               "5b6ff2e19d0da0fe323061018fc381393492884e74af8296c81ab9cb2694783a"
               (epi-ledger--hash (plist-get snapshot :bytes) 'object))))
    (should (> yield-count 0))
    (let ((owned-bytes (plist-get snapshot :bytes))
          (owned-media-type (plist-get snapshot :media-type))
          (owned-role (plist-get snapshot :role)))
      (should (stringp owned-bytes))
      (should-not (multibyte-string-p owned-bytes))
      (should (= epi-object-byte-limit (length owned-bytes)))
      (should (= ?a (aref owned-bytes 0)))
      (should-not (text-properties-at 0 owned-bytes))
      (should-not (eq bytes owned-bytes))
      (should (equal "application/octet-stream" owned-media-type))
      (should (equal "artifact" owned-role))
      (should-not (eq media-type owned-media-type))
      (should-not (eq role owned-role))
      (should-not (text-properties-at 0 owned-media-type))
      (should-not (text-properties-at 0 owned-role))
      (should
       (equal (list :bytes owned-bytes
                    :media-type owned-media-type
                    :role owned-role)
              snapshot)))
    (should (= ?z (aref bytes 0)))
    (should (= ?X (aref media-type 0)))
    (should (= ?X (aref role 0)))))


;;;; Wave 2: lock token, ownership, and stale recovery

(defconst epi-test-ledger-io--wave2-start [11 22 33 44]
  "Fixed normalized process-start identity used by Wave 2 tests.")

(defconst epi-test-ledger-io--wave2-other-start [55 66 77 88]
  "Second process-start identity used to prove PID reuse.")

(defconst epi-test-ledger-io--wave2-nonce
  "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  "Fixed lock nonce used by Wave 2 tests.")

(defconst epi-test-ledger-io--wave2-second-nonce
  "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  "Distinct lock nonce used for replacements and fresh acquisition.")

(defconst epi-test-ledger-io--wave2-null-head (make-string 64 ?0)
  "A valid but deterministic non-null lock head for focused tests.")

(defconst epi-test-ledger-io--wave2-write-seams
  '(epi-ledger--byte-writer
    epi-ledger--lock-create-function
    epi-ledger--append-function
    epi-ledger--flush-function
    epi-ledger--unlock-function
    epi-ledger--publish-function)
  "All storage mutation seams that rejected Wave 2 operations must not enter.")

(defmacro epi-test-ledger-io--wave2-with-forbidden-mutations (&rest body)
  "Run BODY while making every Wave 2 storage mutation seam fail."
  (declare (indent 0) (debug t))
  `(let ((values
          (make-list (length epi-test-ledger-io--wave2-write-seams)
                     #'epi-test-ledger-io--unexpected-storage-call)))
     (cl-progv epi-test-ledger-io--wave2-write-seams values
       ,@body)))

(defun epi-test-ledger-io--wave2-time-vector (value)
  "Return VALUE as the exact four-component time vector in lock tokens."
  (let ((parts (time-convert value 'list)))
    (unless (= 4 (length parts))
      (ert-fail (format "test time did not normalize to four parts: %S"
                        value)))
    (vconcat parts)))

(defun epi-test-ledger-io--wave2-file-object (identity)
  "Return the independently specified lock-token object for IDENTITY."
  (list
   (cons "path" (plist-get identity :path))
   (cons "device" (number-to-string (plist-get identity :device)))
   (cons "inode" (number-to-string (plist-get identity :inode)))
   (cons "links" (number-to-string (plist-get identity :links)))
   (cons "size" (number-to-string (plist-get identity :size)))
   (cons "modified"
         (epi-test-ledger-io--wave2-time-vector
          (plist-get identity :modified)))
   (cons "changed"
         (epi-test-ledger-io--wave2-time-vector
          (plist-get identity :changed)))))

(cl-defun epi-test-ledger-io--wave2-token-object
    (ledger-path &key
                 (host (system-name))
                 (pid "4242")
                 (process-start epi-test-ledger-io--wave2-start)
                 (nonce epi-test-ledger-io--wave2-nonce)
                 (expected-file "absent")
                 (expected-end 0)
                 expected-head)
  "Return an independently assembled closed token object for LEDGER-PATH."
  (list
   (cons "version" 1)
   (cons "host" host)
   (cons "pid" (if (stringp pid) pid (number-to-string pid)))
   (cons "process_start" (vconcat process-start))
   (cons "nonce" nonce)
   (cons "ledger_path" ledger-path)
   (cons "expected_file"
         (if (stringp expected-file)
             expected-file
           (epi-test-ledger-io--wave2-file-object expected-file)))
   (cons "expected_end"
         (if (stringp expected-end)
             expected-end
           (number-to-string expected-end)))
   (cons "expected_head" (or expected-head epi-json-null))))

(cl-defun epi-test-ledger-io--wave2-token-bytes
    (ledger-path &rest keys &key &allow-other-keys)
  "Return canonical bytes for the independently assembled token.
KEYS are forwarded to `epi-test-ledger-io--wave2-token-object'."
  (epi-ledger--jcs-encode
   (apply #'epi-test-ledger-io--wave2-token-object ledger-path keys)
   65536))

(defun epi-test-ledger-io--wave2-lock-path (ledger-path)
  "Return the literal lock sibling specified for LEDGER-PATH."
  (concat ledger-path ".epi-lock"))

(defun epi-test-ledger-io--wave2-path (root leaf)
  "Return canonical absent LEAF below the existing temporary ROOT."
  (expand-file-name leaf (file-name-as-directory (file-truename root))))

(defun epi-test-ledger-io--wave2-archive-path (ledger-path sha256)
  "Return the deterministic stale-token archive for LEDGER-PATH and SHA256."
  (expand-file-name
   (format ".%s.epi-stale-lock-%s.jcs"
           (file-name-nondirectory ledger-path) sha256)
   (file-name-directory ledger-path)))

(defun epi-test-ledger-io--wave2-write-private (path bytes)
  "Write exact unibyte BYTES to absent PATH using the Wave 1 primitive."
  (epi-ledger--write-bytes path bytes 'exclusive-create t)
  path)

(defun epi-test-ledger-io--wave2-replace-private (path bytes)
  "Replace PATH with exact unibyte BYTES using the Wave 1 primitive."
  (when (file-exists-p path)
    (delete-file path))
  (epi-test-ledger-io--wave2-write-private path bytes))

(defun epi-test-ledger-io--wave2-good-attributes (&optional start)
  "Return process attributes containing START or the fixed Wave 2 start."
  (list (append (list 'start)
                (append (or start epi-test-ledger-io--wave2-start) nil))))

(defun epi-test-ledger-io--wave2-token-value (token key)
  "Return string KEY from decoded TOKEN."
  (alist-get key token nil nil #'string=))

(defun epi-test-ledger-io--wave2-tree-snapshot (root)
  "Return a byte-exact shallow snapshot of files below ROOT."
  (mapcar
   (lambda (path)
     (let ((relative (file-relative-name path root)))
       (if (file-directory-p path)
           (list relative 'directory (file-modes path))
         (list relative 'file (file-modes path)
               (epi-test-ledger-io--literal-file-bytes path)))))
   (sort (directory-files root t directory-files-no-dot-files-regexp t)
         #'string<)))

(defun epi-test-ledger-io--wave2-structured-code-p (condition codes)
  "Return non-nil when CONDITION has one of stable CODES."
  (memq (epi-test-ledger-io--condition-code condition) codes))

(defun epi-test-ledger-io--wave2-last-record (ledger)
  "Return LEDGER's final private record, or nil for an empty ledger."
  (let* ((checkpoint (epi-ledger--checkpoint-snapshot ledger))
         (records (epi-ledger--checkpoint-raw-records checkpoint))
         (count (epi-ledger--record-source-length records)))
    (and (> count 0)
         (epi-ledger--record-source-elt records (1- count)))))

(defun epi-test-ledger-io--wave2-present-token (ledger-path ledger &rest keys)
  "Return a canonical token for LEDGER-PATH's current LEDGER checkpoint."
  (let ((checkpoint (epi-ledger--checkpoint-snapshot ledger)))
    (apply
     #'epi-test-ledger-io--wave2-token-bytes ledger-path
     :expected-file
     (epi-ledger--checkpoint-raw-file-identity checkpoint)
     :expected-end
     (epi-ledger--checkpoint-raw-validated-end-offset checkpoint)
     :expected-head (epi-ledger--checkpoint-raw-tail-hash checkpoint)
     keys)))

(defun epi-test-ledger-io--wave2-write-document (root drafts)
  "Write DRAFTS below ROOT and return the resulting canonical ledger path."
  (file-truename (epi-test-ledger-io--write-document root drafts)))

(ert-deftest epi-ledger-lock-token-has-the-exact-canonical-wire-shape ()
  (should (fboundp 'epi-ledger--encode-lock-token))
  (should (fboundp 'epi-ledger--decode-lock-token))
  (let* ((path "/tmp/epi-wave2/session.org")
         (expected
          (string-make-unibyte
           (concat
            "{\"expected_end\":\"0\",\"expected_file\":\"absent\","
            "\"expected_head\":null,\"host\":\"epi.example\","
            "\"ledger_path\":\"/tmp/epi-wave2/session.org\","
            "\"nonce\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\","
            "\"pid\":\"4242\",\"process_start\":[11,22,33,44],"
            "\"version\":1}")))
         (actual
          (epi-ledger--encode-lock-token
           "epi.example" 4242 '(11 22 33 44)
           epi-test-ledger-io--wave2-nonce path "absent" 0 nil)))
    (should (equal expected actual))
    (should-not (multibyte-string-p actual))
    (should-not (text-properties-at 0 actual))
    (should
     (equal "68de983938e22735b06bc3a2c735a52749c8810c17a9a4522a035be4dc14d92e"
            (secure-hash 'sha256 actual)))
    (let ((decoded (epi-ledger--decode-lock-token actual)))
      (should (= 1 (epi-test-ledger-io--wave2-token-value
                    decoded "version")))
      (should (equal path
                     (epi-test-ledger-io--wave2-token-value
                      decoded "ledger_path"))))))

(ert-deftest epi-ledger-lock-token-roundtrip-preserves-four-part-times ()
  (should (fboundp 'epi-ledger--encode-lock-token))
  (should (fboundp 'epi-ledger--decode-lock-token))
  (let* ((path "/tmp/epi-wave2/present.org")
         (identity
          (list :path path :device 7 :inode 9 :links 1 :size 12345
                :modified '(101 202 303 404)
                :changed '(505 606 707 808)))
         (head epi-test-ledger-io--wave2-null-head)
         (expected
          (string-make-unibyte
           (concat
            "{\"expected_end\":\"12345\",\"expected_file\":{"
            "\"changed\":[505,606,707,808],\"device\":\"7\","
            "\"inode\":\"9\",\"links\":\"1\","
            "\"modified\":[101,202,303,404],"
            "\"path\":\"/tmp/epi-wave2/present.org\","
            "\"size\":\"12345\"},"
            "\"expected_head\":"
            "\"0000000000000000000000000000000000000000000000000000000000000000\","
            "\"host\":\"epi.example\","
            "\"ledger_path\":\"/tmp/epi-wave2/present.org\","
            "\"nonce\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\","
            "\"pid\":\"42\",\"process_start\":[11,22,33,44],"
            "\"version\":1}")))
         (bytes
          (epi-ledger--encode-lock-token
           "epi.example" 42 '(11 22 33 44)
           epi-test-ledger-io--wave2-nonce path identity 12345 head))
         (decoded (epi-ledger--decode-lock-token bytes))
         (expected-file
          (epi-test-ledger-io--wave2-token-value decoded "expected_file")))
    (should (equal expected bytes))
    (should-not (multibyte-string-p bytes))
    (should-not (text-properties-at 0 bytes))
    (should
     (equal "2123ab2fc1ffb110237aca530f162d0a0ea46f5630f01469a8c4502bf02d3b7d"
            (secure-hash 'sha256 bytes)))
    (should (equal [11 22 33 44]
                   (epi-test-ledger-io--wave2-token-value
                    decoded "process_start")))
    (should (equal [101 202 303 404]
                   (epi-test-ledger-io--wave2-token-value
                    expected-file "modified")))
    (should (equal [505 606 707 808]
                   (epi-test-ledger-io--wave2-token-value
                    expected-file "changed")))
    ;; Canonical decoding is closed: its independently re-encoded value is
    ;; byte-identical, not merely semantically equal JSON.
    (should (equal bytes (epi-ledger--jcs-encode decoded 65536)))))

(ert-deftest epi-ledger-lock-token-decoder-rejects-open-or-incoherent-shapes ()
  (should (fboundp 'epi-ledger--decode-lock-token))
  (let* ((path "/tmp/epi-wave2/closed.org")
         (other "/tmp/epi-wave2/other.org")
         (base (epi-test-ledger-io--wave2-token-object path))
         (identity
          (list :path path :device 7 :inode 9 :links 1 :size 12
                :modified '(1 2 3 4) :changed '(5 6 7 8)))
         (present
          (epi-test-ledger-io--wave2-token-object
           path :expected-file identity :expected-end 12
           :expected-head epi-test-ledger-io--wave2-null-head))
         (replace
          (lambda (object key value)
            (mapcar (lambda (entry)
                      (if (equal key (car entry))
                          (cons key value)
                        entry))
                    object)))
         (remove
          (lambda (object key)
            (seq-remove (lambda (entry) (equal key (car entry))) object)))
         (file-object (epi-test-ledger-io--wave2-file-object identity))
         (base-bytes (epi-ledger--jcs-encode base 65536))
         (present-bytes (epi-ledger--jcs-encode present 65536))
         cases)
    (cl-labels
        ((add-object (name object)
           (push (cons name object) cases))
         (add-bytes (name bytes)
           (push (cons name bytes) cases))
         (replace-literal (bytes old new)
           (let ((result
                  (replace-regexp-in-string
                   (regexp-quote old) new bytes t t)))
             (unless (= 1 (/ (- (length result) (length bytes))
                              (- (length new) (length old))))
               (ert-fail (format "malformed-case replacement failed: %s"
                                 old)))
             (string-make-unibyte result)))
         (replace-file-key (object key value)
           (funcall replace object "expected_file"
                    (funcall replace file-object key value))))
      ;; The top-level and present-file objects are both closed schemas.  Test
      ;; every required key, rather than allowing a decoder that validates only
      ;; one representative omission.
      (dolist (key '("version" "host" "pid" "process_start" "nonce"
                     "ledger_path" "expected_file" "expected_end"
                     "expected_head"))
        (add-object (format "missing top-level key %s" key)
                    (funcall remove base key)))
      (add-object "extra top-level key"
                  (append base '(("unexpected" . 1))))
      (dolist (key '("path" "device" "inode" "links" "size"
                     "modified" "changed"))
        (add-object
         (format "missing expected_file key %s" key)
         (funcall replace present "expected_file"
                  (funcall remove file-object key))))
      (add-object
       "extra expected_file key"
       (funcall replace present "expected_file"
                (append file-object '(("unexpected" . 1)))))

      ;; Each unsigned-decimal field rejects empty, signed, leading-zero, and
      ;; non-string spellings.  Cover every field so validation cannot be
      ;; accidentally field-specific.
      (dolist (spec '(("pid" . "4242") ("expected_end" . "12")
                      ("device" . "7") ("inode" . "9")
                      ("links" . "1") ("size" . "12")))
        (let ((key (car spec))
              (canonical (cdr spec)))
          (dolist (invalid (list "" (concat "+" canonical)
                                 (concat "-" canonical)
                                 (concat "0" canonical)
                                 (string-to-number canonical)))
            (add-object
             (format "invalid decimal %s=%S" key invalid)
             (if (member key '("pid" "expected_end"))
                 (funcall replace
                          (if (equal key "pid") base present) key invalid)
               (replace-file-key present key invalid))))))

      ;; All three time vectors require exact arity, integer components, and
      ;; JCS-safe integer range.  Unsafe values are injected as canonical raw
      ;; JSON so the test oracle does not reject them before the decoder does.
      (dolist (spec '(("process_start" . "[11,22,33,44]")
                      ("modified" . "[1,2,3,4]")
                      ("changed" . "[5,6,7,8]")))
        (let ((key (car spec))
              (literal (cdr spec)))
          (dolist (invalid '([1 2 3] [1 2 3 "4"] [1 2 3 4.5]))
            (add-object
             (format "invalid time %s=%S" key invalid)
             (if (equal key "process_start")
                 (funcall replace base key invalid)
               (replace-file-key present key invalid))))
          (dolist (invalid '([0 0 1000000 0] [0 0 0 1000000]))
            (add-object
             (format "unnormalized time %s=%S" key invalid)
             (if (equal key "process_start")
                 (funcall replace base key invalid)
               (replace-file-key present key invalid))))
          (add-bytes
           (format "unsafe time component in %s" key)
           (replace-literal
            (if (equal key "process_start") base-bytes present-bytes)
            (format "\"%s\":%s" key literal)
            (format "\"%s\":%s" key
                    (replace-regexp-in-string
                     "[0-9]+\\]\\'" "9007199254740992]" literal))))))

      (add-object "invalid version value" (funcall replace base "version" 2))
      (add-object "invalid version type"
                  (funcall replace base "version" "1"))
      (add-object "invalid host type" (funcall replace base "host" 1))
      (add-object "invalid ledger path type"
                  (funcall replace base "ledger_path" 1))
      (add-object "invalid expected_file type"
                  (funcall replace base "expected_file" []))
      (add-object "alternate expected_file string"
                  (funcall replace base "expected_file" "missing"))
      (add-object "invalid nonce"
                  (funcall replace base "nonce" "not-a-uuid"))
      (add-object "uppercase nonce"
                  (funcall replace base "nonce"
                           (upcase epi-test-ledger-io--wave2-nonce)))
      (add-object "invalid head length"
                  (funcall replace present "expected_head"
                           (make-string 63 ?0)))
      (add-object "invalid head alphabet"
                  (funcall replace present "expected_head"
                           (make-string 64 ?g)))
      (add-object "uppercase head"
                  (funcall replace present "expected_head"
                           (make-string 64 ?A)))
      (add-object "invalid head type"
                  (funcall replace present "expected_head" 0))

      ;; Absent and present forms have closed cross-field relationships.
      (add-object "absent token with nonzero end"
                  (funcall replace base "expected_end" "1"))
      (add-object "absent token with non-null head"
                  (funcall replace base "expected_head"
                           epi-test-ledger-io--wave2-null-head))
      (add-object
       "present token with mismatched path"
       (funcall replace
                present "expected_file"
                (epi-test-ledger-io--wave2-file-object
                 (plist-put (copy-sequence identity) :path other))))
      (add-object "present token with mismatched end"
                  (funcall replace present "expected_end" "11"))
      (add-object "present token with mismatched size"
                  (replace-file-key present "size" "11"))
      (add-object "present token with null head"
                  (funcall replace present "expected_head" epi-json-null))

      ;; Even semantically valid JSON is rejected unless its bytes are already
      ;; the unique canonical encoding.
      (add-bytes "noncanonical leading whitespace"
                 (concat (string-make-unibyte " ") base-bytes))
      (let ((body
             (string-remove-prefix
              "{"
              (string-remove-suffix ",\"version\":1}" base-bytes))))
        (add-bytes
         "noncanonical member order"
         (string-make-unibyte
          (concat "{\"version\":1," body "}")))))
    (dolist (case (nreverse cases))
      (let* ((value (cdr case))
             (bytes (if (stringp value)
                        value
                      (epi-ledger--jcs-encode value 65536)))
             (condition
              (should-error
               (epi-ledger--decode-lock-token bytes)
               :type 'epi-ledger-conflict)))
        (should (eq 'malformed-lock-token
                    (epi-test-ledger-io--condition-code condition)))))))

(ert-deftest epi-ledger-lock-current-process-identity-fails-closed-before-write ()
  (should (fboundp 'epi-ledger--acquire-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-path root "session.org"))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (write-count 0)
           (forbidden (lambda (&rest _arguments)
                        (setq write-count (1+ write-count))
                        (ert-fail "current-self failure reached a write seam"))))
      (dolist (probe
               (list
                (lambda (_pid) nil)
                (lambda (_pid) (error "self attributes unavailable"))
                (lambda (_pid) '((start . malformed)))))
        (let ((values (make-list
                       (length epi-test-ledger-io--wave2-write-seams)
                       forbidden)))
          (cl-progv epi-test-ledger-io--wave2-write-seams values
            (cl-letf (((symbol-function 'process-attributes) probe))
              (let ((condition
                     (should-error
                      (epi-ledger--acquire-lock path "absent" 0 nil)
                      :type 'epi-ledger-conflict)))
                (should (eq 'lock-owner-indeterminate
                            (epi-test-ledger-io--condition-code
                             condition))))))
        (should-not (file-exists-p lock-path)))
      (should (= 0 write-count))))))

(ert-deftest epi-ledger-lock-acquisition-binds-the-exact-current-token ()
  (should (fboundp 'epi-ledger--acquire-lock))
  (should (fboundp 'epi-ledger--release-lock))
  (should (fboundp 'epi-ledger--lock-path))
  (should (fboundp 'epi-ledger--lock-lock-file))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-path root "session.org"))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (self (emacs-pid))
           (host-source (copy-sequence "epi.mutable"))
           (host-snapshot (copy-sequence host-source))
           (nonce-source
            (copy-sequence epi-test-ledger-io--wave2-nonce))
           (nonce-snapshot (copy-sequence nonce-source))
           (start-source (append epi-test-ledger-io--wave2-start nil))
           (start-snapshot (copy-sequence start-source))
           (expected-file-source
            (list :path (copy-sequence path)
                  :device 7 :inode 9 :links 1 :size 12
                  :modified (list 101 202 303 404)
                  :changed (list 505 606 707 808)))
           (expected-file-snapshot
            (list :path (copy-sequence path)
                  :device 7 :inode 9 :links 1 :size 12
                  :modified (list 101 202 303 404)
                  :changed (list 505 606 707 808)))
           (expected-head-source (make-string 64 ?a))
           (expected-head-snapshot (copy-sequence expected-head-source))
           (expected
            (epi-test-ledger-io--wave2-token-bytes
             path :host host-snapshot :pid self
             :process-start start-snapshot :nonce nonce-snapshot
             :expected-file expected-file-snapshot :expected-end 12
             :expected-head expected-head-snapshot))
           (real-resolve
            (symbol-function 'epi-ledger--resolve-local-write-path))
           (real-create epi-ledger--lock-create-function)
           resolver-mutation-seen
           (yield-count 0)
           lock)
      (should (equal lock-path (epi-ledger--lock-path path)))
      (let ((epi--id-function (lambda () nonce-source))
            (epi--yield-function
             (lambda ()
               (setq yield-count (1+ yield-count))
               (aset host-source 0 ?X)
               (aset nonce-source 0 ?b)
               (setcar start-source 99)
               (aset (plist-get expected-file-source :path) 0 ?X)
               (setf (plist-get expected-file-source :size) 13)
               (setcar (plist-get expected-file-source :modified) 99)
               (setcar (plist-get expected-file-source :changed) 99)
               (aset expected-head-source 0 ?f)))
            (epi-ledger--lock-create-function
             (lambda (target candidate)
               (should (equal lock-path target))
               (should (equal expected candidate))
               ;; Exercise a callback/yield boundary after acquisition has
               ;; collected its sources but before the token becomes owned.
               (epi--yield)
               (funcall real-create target candidate))))
        (cl-letf (((symbol-function 'system-name)
                   (lambda () host-source))
                  ((symbol-function 'epi-ledger--resolve-local-write-path)
                   (lambda (target)
                     ;; The caller's state must be owned before even the
                     ;; first resolver callback can invoke Lisp.
                     (unless resolver-mutation-seen
                       (setq resolver-mutation-seen t)
                       (setf (plist-get expected-file-source :device) 99)
                       (aset expected-head-source 0 ?e))
                     (funcall real-resolve target)))
                  ((symbol-function 'process-attributes)
                   (lambda (pid)
                     (and (= pid self)
                          (list (cons 'start start-source))))))
          (setq lock
                (epi-ledger--acquire-lock
                 path expected-file-source 12 expected-head-source))))
      (should resolver-mutation-seen)
      (should (> yield-count 0))
      (should-not (equal host-source host-snapshot))
      (should-not (equal nonce-source nonce-snapshot))
      (should-not (equal start-source start-snapshot))
      (should-not (equal expected-file-source expected-file-snapshot))
      (should-not (equal expected-head-source expected-head-snapshot))
      (should (epi-ledger--lock-p lock))
      ;; `epi-ledger--lock-path' is reserved for deriving a lock pathname from
      ;; a ledger pathname; the struct's first slot has its own real accessor.
      (should (equal lock-path (epi-ledger--lock-lock-file lock)))
      (should (equal expected (epi-ledger--lock-bytes lock)))
      (should (equal (secure-hash 'sha256 expected)
                     (epi-ledger--lock-sha256 lock)))
      (should (equal (funcall epi-ledger--stat-function lock-path)
                     (epi-ledger--lock-file-identity lock)))
      (should (equal expected-file-snapshot
                     (epi-ledger--lock-expected-file lock)))
      (should-not (eq expected-file-source
                      (epi-ledger--lock-expected-file lock)))
      (should (= 12 (epi-ledger--lock-expected-end lock)))
      (should (equal expected-head-snapshot
                     (epi-ledger--lock-expected-head lock)))
      (should-not (eq expected-head-source
                      (epi-ledger--lock-expected-head lock)))
      (should (equal expected
                     (epi-test-ledger-io--literal-file-bytes lock-path)))
      (epi-ledger--release-lock lock)
      (should-not (file-exists-p lock-path)))))

(ert-deftest epi-ledger-lock-acquisition-verifies-created-token-before-ownership ()
  (should (fboundp 'epi-ledger--acquire-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-path root "session.org"))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (self (emacs-pid))
           (candidate
            (epi-test-ledger-io--wave2-token-bytes
             path :pid self :process-start epi-test-ledger-io--wave2-start))
           (canonical-other
            (epi-test-ledger-io--wave2-token-bytes
             path :pid self :process-start epi-test-ledger-io--wave2-start
             :nonce epi-test-ledger-io--wave2-second-nonce))
           (real-create epi-ledger--lock-create-function)
           (real-read epi-ledger--read-function)
           (real-stat epi-ledger--stat-function))
      (should (= (length candidate) (length canonical-other)))
      (dolist (variant '(short-read same-size-altered-read annotated-read
                         canonical-other-read replaced-token
                         changed-file-identity))
        (when (file-exists-p lock-path)
          (delete-file lock-path))
        (let ((create-count 0)
              (read-count 0)
              created-identity)
          (let ((epi--id-function
                 (lambda () epi-test-ledger-io--wave2-nonce))
                (epi-ledger--stat-function
                 (lambda (target)
                   (cond
                    ((and (equal target lock-path) created-identity
                          (eq variant 'replaced-token))
                     ;; Hide the replacement's identity so exact readback is
                     ;; independently required.
                     created-identity)
                    ((and (equal target lock-path) created-identity
                          (eq variant 'changed-file-identity))
                     (let ((changed (copy-sequence created-identity)))
                       (plist-put
                        changed :inode
                        (1+ (plist-get created-identity :inode)))))
                    (t (funcall real-stat target)))))
                (epi-ledger--read-function
                 (lambda (target begin end)
                   (let ((actual (funcall real-read target begin end)))
                     (when (equal target lock-path)
                       (setq read-count (1+ read-count)))
                     (pcase variant
                       ('short-read (substring actual 0 -1))
                       ('same-size-altered-read
                        (let ((altered (copy-sequence actual)))
                          (aset altered 0
                                (if (eq (aref altered 0) ?\{) ?\[ ?\{))
                          altered))
                       ('annotated-read
                        (propertize actual 'epi-wave2-annotation t))
                       ('canonical-other-read canonical-other)
                       (_ actual)))))
                (epi-ledger--lock-create-function
                 (lambda (target bytes)
                   (setq create-count (1+ create-count))
                   (should (equal lock-path target))
                   (should (equal candidate bytes))
                   (setq created-identity (funcall real-create target bytes))
                   (when (eq variant 'replaced-token)
                     (epi-test-ledger-io--wave2-replace-private
                      target canonical-other))
                   created-identity))
                (epi-ledger--unlock-function
                 #'epi-test-ledger-io--unexpected-storage-call))
            (cl-letf (((symbol-function 'process-attributes)
                       (lambda (pid)
                         (and (= pid self)
                              (epi-test-ledger-io--wave2-good-attributes)))))
              (let ((condition
                     (should-error
                      (epi-ledger--acquire-lock path "absent" 0 nil)
                      :type 'epi-ledger-conflict)))
                (should (eq 'lock-token-changed
                            (epi-test-ledger-io--condition-code condition))))))
          (should (= 1 create-count))
          (unless (eq variant 'changed-file-identity)
            (should (> read-count 0)))
          (should
           (equal (if (eq variant 'replaced-token)
                      canonical-other
                    candidate)
                  (epi-test-ledger-io--literal-file-bytes lock-path))))))))

(ert-deftest epi-ledger-lock-process-probes-use-local-default-directory ()
  (should (fboundp 'epi-ledger--acquire-lock))
  (should (fboundp 'epi-ledger--lock-owner-state))
  (should (fboundp 'epi-ledger--release-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-path root "session.org"))
           (parent (file-name-as-directory (file-truename root)))
           (self (emacs-pid))
           (old-pid (+ self 100000))
           observed
           lock)
      (let ((default-directory "/ssh:epi-wave2.invalid:/tmp/")
            (epi--id-function
             (lambda () epi-test-ledger-io--wave2-second-nonce)))
        (cl-letf
            (((symbol-function 'process-attributes)
              (lambda (pid)
                (push (list (if (= pid self) 'self 'stale-attributes)
                            default-directory)
                      observed)
                (and (= pid self)
                     (epi-test-ledger-io--wave2-good-attributes))))
             ((symbol-function 'list-system-processes)
              (lambda ()
                (push (list 'stale-process-list default-directory) observed)
                (list self))))
          (setq lock (epi-ledger--acquire-lock path "absent" 0 nil))
          (let* ((old-bytes
                  (epi-test-ledger-io--wave2-token-bytes
                   path :pid old-pid))
                 (old-token (epi-ledger--decode-lock-token old-bytes)))
            (should (eq 'dead
                        (epi-ledger--lock-owner-state old-token))))
          (epi-ledger--release-lock lock)))
      (dolist (entry observed)
        (should (equal parent (cadr entry))))
      (should (assq 'self observed))
      (should (assq 'stale-attributes observed))
      (should (assq 'stale-process-list observed)))))

(ert-deftest epi-ledger-lock-acquisition-ignores-ordinary-emacs-lockfiles ()
  (should (fboundp 'epi-ledger--acquire-lock))
  (should (fboundp 'epi-ledger--release-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-path root "session.org"))
           (ordinary (expand-file-name ".#session.org" root))
           (ordinary-bytes (string-make-unibyte "somebody@else.999:boot"))
           lock)
      (epi-test-ledger-io--wave2-write-private ordinary ordinary-bytes)
      (let ((create-lockfiles t)
            (epi--id-function
             (lambda () epi-test-ledger-io--wave2-nonce)))
        (cl-letf (((symbol-function 'process-attributes)
                   (lambda (_pid)
                     (epi-test-ledger-io--wave2-good-attributes))))
          (setq lock (epi-ledger--acquire-lock path "absent" 0 nil))
          (should (file-exists-p
                   (epi-test-ledger-io--wave2-lock-path path)))
          (should (equal ordinary-bytes
                         (epi-test-ledger-io--literal-file-bytes ordinary)))
          (epi-ledger--release-lock lock)))
      (should (equal ordinary-bytes
                     (epi-test-ledger-io--literal-file-bytes ordinary)))
      (should-not (file-exists-p
                   (epi-test-ledger-io--wave2-lock-path path))))))

(ert-deftest epi-ledger-lock-refuses-live-same-host-owner ()
  (should (fboundp 'epi-ledger--lock-owner-state))
  (should (fboundp 'epi-ledger--acquire-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-path root "session.org"))
           (self (emacs-pid))
           (old-pid (+ self 100000))
           (bytes (epi-test-ledger-io--wave2-token-bytes
                   path :pid old-pid))
           (lock-path (epi-test-ledger-io--wave2-lock-path path)))
      (epi-test-ledger-io--wave2-write-private lock-path bytes)
      (cl-letf (((symbol-function 'process-attributes)
                 (lambda (pid)
                   (cond
                    ((= pid self)
                     (epi-test-ledger-io--wave2-good-attributes))
                    ((= pid old-pid)
                     (epi-test-ledger-io--wave2-good-attributes))))))
        (should
         (eq 'live
             (epi-ledger--lock-owner-state
              (epi-ledger--decode-lock-token bytes))))
        (let ((condition
               (should-error
                (epi-ledger--acquire-lock path "absent" 0 nil)
                :type 'epi-ledger-conflict)))
          (should (eq 'lock-held
                      (epi-test-ledger-io--condition-code condition)))))
      (should (equal bytes
                     (epi-test-ledger-io--literal-file-bytes lock-path))))))

(ert-deftest epi-ledger-lock-refuses-remote-malformed-or-missing-start-owner ()
  (should (fboundp 'epi-ledger--decode-lock-token))
  (should (fboundp 'epi-ledger--lock-owner-state))
  (should (fboundp 'epi-ledger--acquire-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-path root "session.org"))
           (other (epi-test-ledger-io--wave2-path root "other.org"))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (remote-bytes
            (epi-test-ledger-io--wave2-token-bytes
             path :host "remote.example"))
           (cross-ledger-bytes
            (epi-test-ledger-io--wave2-token-bytes other))
           (missing-object
            (seq-remove
             (lambda (entry) (equal "process_start" (car entry)))
             (epi-test-ledger-io--wave2-token-object path)))
           (malformed-object
            (mapcar
             (lambda (entry)
               (if (equal "process_start" (car entry))
                   (cons "process_start" [1 2 3])
                 entry))
             (epi-test-ledger-io--wave2-token-object path))))
      (should
       (eq 'indeterminate
           (epi-ledger--lock-owner-state
            (epi-ledger--decode-lock-token remote-bytes))))
      (let ((missing-bytes (epi-ledger--jcs-encode missing-object 65536))
            (malformed-bytes
             (epi-ledger--jcs-encode malformed-object 65536)))
        (dolist (bytes (list missing-bytes malformed-bytes))
          (let ((condition
                 (should-error
                  (epi-ledger--decode-lock-token bytes)
                  :type 'epi-ledger-conflict)))
            (should (eq 'malformed-lock-token
                        (epi-test-ledger-io--condition-code condition)))))
        ;; Classification is not enough: every form must remain byte exact
        ;; when automatic acquisition encounters it.  The cross-ledger token
        ;; must be rejected before its otherwise-live owner is classified.
        (dolist (case `((,remote-bytes lock-owner-indeterminate)
                        (,missing-bytes malformed-lock-token)
                        (,malformed-bytes malformed-lock-token)
                        (,cross-ledger-bytes malformed-lock-token)))
          (epi-test-ledger-io--wave2-replace-private lock-path (car case))
          (let ((epi--id-function
                 (lambda () epi-test-ledger-io--wave2-second-nonce)))
            (cl-letf (((symbol-function 'process-attributes)
                       (lambda (_pid)
                         (epi-test-ledger-io--wave2-good-attributes))))
              (let ((condition
                     (should-error
                      (epi-ledger--acquire-lock path "absent" 0 nil)
                      :type 'epi-ledger-conflict)))
                (should (eq (cadr case)
                            (epi-test-ledger-io--condition-code
                             condition))))))
          (should (equal (car case)
                         (epi-test-ledger-io--literal-file-bytes
                          lock-path))))))))

(ert-deftest epi-ledger-lock-refuses-indeterminate-observed-start ()
  (should (fboundp 'epi-ledger--lock-owner-state))
  (should (fboundp 'epi-ledger--acquire-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-path root "session.org"))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (self (emacs-pid))
           (old-pid (+ (emacs-pid) 100000))
           (bytes
            (epi-test-ledger-io--wave2-token-bytes path :pid old-pid))
           (token (epi-ledger--decode-lock-token bytes)))
      (dolist (attributes
               (list '((comm . "alive"))
                     '((start . malformed))
                     '((start 1 2 3))))
        (cl-letf (((symbol-function 'process-attributes)
                   (lambda (_pid) attributes))
                  ((symbol-function 'list-system-processes)
                   (lambda () (ert-fail "present PID consulted process list"))))
          (should (eq 'indeterminate
                      (epi-ledger--lock-owner-state token)))))
      (epi-test-ledger-io--wave2-write-private lock-path bytes)
      (cl-letf (((symbol-function 'process-attributes)
                 (lambda (pid)
                   (if (= pid self)
                       (epi-test-ledger-io--wave2-good-attributes)
                     '((start . malformed)))))
                ((symbol-function 'list-system-processes)
                 (lambda () (ert-fail "present PID consulted process list"))))
        (let ((condition
               (should-error
                (epi-ledger--acquire-lock path "absent" 0 nil)
                :type 'epi-ledger-conflict)))
          (should (eq 'lock-owner-indeterminate
                      (epi-test-ledger-io--condition-code condition)))))
      (should (equal bytes
                     (epi-test-ledger-io--literal-file-bytes lock-path))))))

(ert-deftest epi-ledger-lock-signaling-owner-probes-are-indeterminate ()
  (should (fboundp 'epi-ledger--lock-owner-state))
  (should (fboundp 'epi-ledger--acquire-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-path root "session.org"))
           (current-path
            (epi-test-ledger-io--wave2-path root "current-probe.org"))
           (current-lock-path
            (epi-test-ledger-io--wave2-lock-path current-path))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (self (emacs-pid))
           (old-pid (+ (emacs-pid) 100000))
           (bytes
            (epi-test-ledger-io--wave2-token-bytes path :pid old-pid)))
      (epi-test-ledger-io--wave2-write-private lock-path bytes)
      ;; An improper current-process attribute alist is not a usable owner
      ;; proof, even when its first entry happens to contain a valid start.
      (dolist (attributes
               '(((comm . "emacs") . malformed-tail)
                 ((start 11 22 33 44) . malformed-tail)))
        (when (file-exists-p current-lock-path)
          (delete-file current-lock-path))
        (epi-test-ledger-io--wave2-with-forbidden-mutations
          (cl-letf (((symbol-function 'process-attributes)
                     (lambda (_pid) attributes)))
            (let ((condition
                   (should-error
                    (epi-ledger--acquire-lock current-path "absent" 0 nil)
                    :type 'epi-ledger-conflict)))
              (should (eq 'lock-owner-indeterminate
                          (epi-test-ledger-io--condition-code
                           condition))))))
        (should-not (file-exists-p current-lock-path)))
      (dolist (probe '(attributes process-list))
        (epi-test-ledger-io--wave2-with-forbidden-mutations
          (cl-letf
              (((symbol-function 'process-attributes)
                (lambda (pid)
                  (cond
                   ((= pid self)
                    (epi-test-ledger-io--wave2-good-attributes))
                   ((eq probe 'attributes)
                    (error "attributes failed")))))
               ((symbol-function 'list-system-processes)
                (lambda ()
                  (if (eq probe 'process-list)
                      (error "process list failed")
                    (ert-fail "attributes failure consulted process list")))))
            (let ((condition
                   (should-error
                    (epi-ledger--acquire-lock path "absent" 0 nil)
                    :type 'epi-ledger-conflict)))
              (should (eq 'lock-owner-indeterminate
                          (epi-test-ledger-io--condition-code
                           condition))))))
        (should (equal bytes
                       (epi-test-ledger-io--literal-file-bytes
                        lock-path))))
      ;; Only a proper list containing PIDs can prove an absent stale PID.
      ;; Improper or non-PID snapshots remain indeterminate and inert.
      (dolist (snapshot
               (list (cons self 'malformed-tail)
                     '("not-a-pid")
                     (list self "not-a-pid")))
        (epi-test-ledger-io--wave2-replace-private lock-path bytes)
        (epi-test-ledger-io--wave2-with-forbidden-mutations
          (cl-letf
              (((symbol-function 'process-attributes)
                (lambda (pid)
                  (and (= pid self)
                       (epi-test-ledger-io--wave2-good-attributes))))
               ((symbol-function 'list-system-processes)
                (lambda () snapshot)))
            (let ((condition
                   (should-error
                    (epi-ledger--acquire-lock path "absent" 0 nil)
                    :type 'epi-ledger-conflict)))
              (should (eq 'lock-owner-indeterminate
                          (epi-test-ledger-io--condition-code
                           condition))))))
        (should (equal bytes
                       (epi-test-ledger-io--literal-file-bytes
                        lock-path)))))))

(ert-deftest epi-ledger-lock-takes-over-proven-dead-owner ()
  (should (fboundp 'epi-ledger--acquire-lock))
  (should (fboundp 'epi-ledger--release-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-path root "session.org"))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (self (emacs-pid))
           (old-pid (+ self 100000))
           (old-bytes
            (epi-test-ledger-io--wave2-token-bytes path :pid old-pid))
           lock)
      (epi-test-ledger-io--wave2-write-private lock-path old-bytes)
      (let ((epi--id-function
             (lambda () epi-test-ledger-io--wave2-second-nonce)))
        (cl-letf
            (((symbol-function 'process-attributes)
              (lambda (pid)
                (and (= pid self)
                     (epi-test-ledger-io--wave2-good-attributes))))
             ((symbol-function 'list-system-processes)
              (lambda () (list self))))
          (setq lock (epi-ledger--acquire-lock path "absent" 0 nil))
          (should-not
           (equal old-bytes
                  (epi-test-ledger-io--literal-file-bytes lock-path)))
          (epi-ledger--release-lock lock)))
      (should-not (file-exists-p lock-path)))))

(ert-deftest epi-ledger-lock-takes-over-reused-pid-with-different-start ()
  (should (fboundp 'epi-ledger--acquire-lock))
  (should (fboundp 'epi-ledger--release-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-path root "session.org"))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (self (emacs-pid))
           (old-pid (+ self 100000))
           (old-bytes
            (epi-test-ledger-io--wave2-token-bytes path :pid old-pid))
           lock)
      (epi-test-ledger-io--wave2-write-private lock-path old-bytes)
      (let ((epi--id-function
             (lambda () epi-test-ledger-io--wave2-second-nonce)))
        (cl-letf
            (((symbol-function 'process-attributes)
              (lambda (pid)
                (cond
                 ((= pid self)
                  (epi-test-ledger-io--wave2-good-attributes))
                 ((= pid old-pid)
                  (epi-test-ledger-io--wave2-good-attributes
                   epi-test-ledger-io--wave2-other-start)))))
             ((symbol-function 'list-system-processes)
              (lambda () (ert-fail "PID reuse consulted process list"))))
          (setq lock (epi-ledger--acquire-lock path "absent" 0 nil))
          (should-not
           (equal old-bytes
                  (epi-test-ledger-io--literal-file-bytes lock-path)))
          (epi-ledger--release-lock lock)))
      (should-not (file-exists-p lock-path)))))

(ert-deftest epi-ledger-lock-age-never-authorizes-takeover ()
  (should (fboundp 'epi-ledger--acquire-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-path root "session.org"))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (self (emacs-pid))
           (old-pid (+ self 100000))
           (old-bytes
            (epi-test-ledger-io--wave2-token-bytes path :pid old-pid)))
      (epi-test-ledger-io--wave2-write-private lock-path old-bytes)
      (set-file-times lock-path (seconds-to-time 1))
      (cl-letf (((symbol-function 'process-attributes)
                 (lambda (pid)
                   (cond
                    ((= pid self)
                     (epi-test-ledger-io--wave2-good-attributes))
                    ((= pid old-pid)
                     (epi-test-ledger-io--wave2-good-attributes)))))
                ((symbol-function 'list-system-processes)
                 (lambda () (ert-fail "live owner consulted process list"))))
        (let ((condition
               (should-error
                (epi-ledger--acquire-lock path "absent" 0 nil)
                :type 'epi-ledger-conflict)))
          (should (eq 'lock-held
                      (epi-test-ledger-io--condition-code condition)))))
      (should (equal old-bytes
                     (epi-test-ledger-io--literal-file-bytes lock-path))))))

(ert-deftest epi-ledger-lock-release-preserves-a-replacement-token ()
  (should (fboundp 'epi-ledger--acquire-lock))
  (should (fboundp 'epi-ledger--release-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-path root "session.org"))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (self (emacs-pid))
           lock)
      (let ((epi--id-function
             (lambda () epi-test-ledger-io--wave2-nonce)))
        (cl-letf (((symbol-function 'process-attributes)
                   (lambda (_pid)
                     (epi-test-ledger-io--wave2-good-attributes))))
          (setq lock (epi-ledger--acquire-lock path "absent" 0 nil))))
      (let* ((owned-bytes (epi-ledger--lock-bytes lock))
             (owned-identity (epi-ledger--lock-file-identity lock))
             (replacement
              (epi-test-ledger-io--wave2-token-bytes
               path :pid self
               :process-start epi-test-ledger-io--wave2-start
               :nonce epi-test-ledger-io--wave2-second-nonce)))
        (should (= (length owned-bytes) (length replacement)))
        ;; Preserve the pathname and apparent identity so only an exact byte
        ;; reread can notice the replacement.
        (epi-ledger--write-bytes lock-path replacement 'replace t)
        (let ((epi-ledger--stat-function
               (lambda (target)
                 (if (equal target lock-path)
                     owned-identity
                   (ert-fail (format "unexpected release stat: %S" target)))))
              (epi-ledger--unlock-function
               #'epi-test-ledger-io--unexpected-storage-call))
          (let ((condition
                 (should-error
                  (epi-ledger--release-lock lock)
                  :type 'epi-ledger-conflict)))
            (should (eq 'lock-token-changed
                        (epi-test-ledger-io--condition-code condition)))))
        (should (equal replacement
                       (epi-test-ledger-io--literal-file-bytes
                        lock-path)))))))

(ert-deftest epi-ledger-stale-lock-recovery-wrong-sha-is-inert ()
  (should (fboundp 'epi-ledger-recover-stale-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-write-document
                  root (list (epi-test-ledger-io--session-info))))
           (ledger (epi-ledger-open path))
           (token (epi-test-ledger-io--wave2-present-token path ledger))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (actual-sha (secure-hash 'sha256 token))
           (wrong-sha (if (eq (aref actual-sha 0) ?0)
                          (concat "1" (substring actual-sha 1))
                        (concat "0" (substring actual-sha 1))))
           (wrong-archive
            (epi-test-ledger-io--wave2-archive-path path wrong-sha))
           (invalid-shas
            (list nil 1 (make-string 63 ?0) (make-string 65 ?0)
                  (make-string 64 ?g) (make-string 64 ?A)))
           precedence-condition
           before)
      (epi-test-ledger-io--wave2-write-private lock-path token)
      ;; Authorization failure must precede even resolving the deterministic
      ;; archive leaf.  Make the wrong-SHA leaf nonregular to expose inversion.
      (make-directory wrong-archive)
      (setq before (epi-test-ledger-io--wave2-tree-snapshot root))
      (let* ((read-count 0)
             (epi-ledger--read-function
              (lambda (&rest _arguments)
                (setq read-count (1+ read-count))
                (ert-fail "malformed recovery SHA reached token read"))))
        (cl-labels
            ((unexpected-direct-mutation
              (&rest _arguments)
              (ert-fail
               "malformed recovery SHA reached direct mutation primitive")))
          (cl-letf (((symbol-function 'add-name-to-file)
                     #'unexpected-direct-mutation)
                    ((symbol-function 'copy-file)
                     #'unexpected-direct-mutation)
                    ((symbol-function 'rename-file)
                     #'unexpected-direct-mutation)
                    ((symbol-function 'delete-file)
                     #'unexpected-direct-mutation))
            (dolist (invalid invalid-shas)
              (epi-test-ledger-io--wave2-with-forbidden-mutations
                (let ((condition
                       (should-error
                        (epi-ledger-recover-stale-lock
                         path :expected-token-sha256 invalid)
                        :type 'epi-ledger-format-error)))
                  (should
                   (eq 'invalid-hash
                       (epi-test-ledger-io--condition-code condition))))))))
        (should (= 0 read-count)))
      (should (equal before
                     (epi-test-ledger-io--wave2-tree-snapshot root)))
      (setq precedence-condition
            (condition-case condition
                (list :returned
                      (epi-ledger-recover-stale-lock
                       path :expected-token-sha256 wrong-sha))
              (error condition)))
      (should (equal before
                     (epi-test-ledger-io--wave2-tree-snapshot root)))

      ;; The valid authorization string itself is caller-owned before the
      ;; first resolver callback.  A callback cannot turn a wrong SHA into the
      ;; token's real SHA and thereby grant recovery authority.
      (let* ((mutable-path
              (epi-test-ledger-io--wave2-path root "mutable-sha.org"))
             (mutable-token
              (epi-test-ledger-io--wave2-token-bytes mutable-path))
             (mutable-lock
              (epi-test-ledger-io--wave2-lock-path mutable-path))
             (mutable-actual (secure-hash 'sha256 mutable-token))
             (mutable-wrong
              (if (eq (aref mutable-actual 0) ?0)
                  (concat "1" (substring mutable-actual 1))
                (concat "0" (substring mutable-actual 1))))
             (real-resolve
              (symbol-function 'epi-ledger--resolve-local-write-path))
             mutable-before
             mutation-seen
             mutable-condition)
        (epi-test-ledger-io--wave2-write-private mutable-lock mutable-token)
        (setq mutable-before
              (epi-test-ledger-io--wave2-tree-snapshot root))
        (cl-letf (((symbol-function 'epi-ledger--resolve-local-write-path)
                   (lambda (target)
                     (unless mutation-seen
                       (setq mutation-seen t)
                       (dotimes (index (length mutable-wrong))
                         (aset mutable-wrong index
                               (aref mutable-actual index))))
                     (funcall real-resolve target))))
          (setq mutable-condition
                (condition-case condition
                    (list :returned
                          (epi-ledger-recover-stale-lock
                           mutable-path
                           :expected-token-sha256 mutable-wrong))
                  (error condition))))
        (should mutation-seen)
        (should (eq 'epi-ledger-conflict (car mutable-condition)))
        (should (eq 'stale-lock-sha-mismatch
                    (epi-test-ledger-io--condition-code
                     mutable-condition)))
        (should (equal mutable-before
                       (epi-test-ledger-io--wave2-tree-snapshot root))))
      (should (eq 'epi-ledger-conflict (car precedence-condition)))
      (should (eq 'stale-lock-sha-mismatch
                  (epi-test-ledger-io--condition-code
                   precedence-condition))))))

(ert-deftest epi-ledger-stale-lock-recovery-refuses-mismatched-existing-archive ()
  (should (fboundp 'epi-ledger-recover-stale-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-write-document
                  root (list (epi-test-ledger-io--session-info))))
           (ledger (epi-ledger-open path))
           (token (epi-test-ledger-io--wave2-present-token path ledger))
           (sha (secure-hash 'sha256 token))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (archive (epi-test-ledger-io--wave2-archive-path path sha))
           (mismatch (copy-sequence token))
           before)
      (aset mismatch (1- (length mismatch))
            (if (eq (aref mismatch (1- (length mismatch))) ?}) ?\] ?}))
      (epi-test-ledger-io--wave2-write-private lock-path token)
      (epi-test-ledger-io--wave2-write-private archive mismatch)
      (setq before (epi-test-ledger-io--wave2-tree-snapshot root))
      (epi-test-ledger-io--wave2-with-forbidden-mutations
        (let ((condition
               (should-error
                (epi-ledger-recover-stale-lock
                 path :expected-token-sha256 sha)
                :type 'epi-ledger-conflict)))
          (should (eq 'destination-exists
                      (epi-test-ledger-io--condition-code condition)))))
      (should (equal before
                     (epi-test-ledger-io--wave2-tree-snapshot root))))))

(ert-deftest epi-ledger-stale-lock-recovery-rejects-cross-ledger-token-binding ()
  (should (fboundp 'epi-ledger-recover-stale-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-write-document
                  root (list (epi-test-ledger-io--session-info))))
           (other (epi-test-ledger-io--wave2-path root "other.org"))
           (token
            (epi-test-ledger-io--wave2-token-bytes other))
           (sha (secure-hash 'sha256 token))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           before)
      (epi-test-ledger-io--wave2-write-private lock-path token)
      (setq before (epi-test-ledger-io--wave2-tree-snapshot root))
      (epi-test-ledger-io--wave2-with-forbidden-mutations
        (let ((condition
               (should-error
                (epi-ledger-recover-stale-lock
                 path :expected-token-sha256 sha)
                :type 'epi-ledger-conflict)))
          (should (eq 'malformed-lock-token
                      (epi-test-ledger-io--condition-code condition)))))
      (should (equal before
                     (epi-test-ledger-io--wave2-tree-snapshot root))))))

(ert-deftest epi-ledger-stale-lock-recovery-archives-exact-bytes ()
  (should (fboundp 'epi-ledger-recover-stale-lock))
  (epi-test-with-temporary-root (root)
    ;; Present-ledger recovery proves hard-link archival, owned state across a
    ;; yield-capable publication callback, exact fresh binding, and release.
    (let* ((path (epi-test-ledger-io--wave2-write-document
                  root (list (epi-test-ledger-io--session-info))))
           (ledger (epi-ledger-open path))
           (checkpoint (epi-ledger--checkpoint-snapshot ledger))
           (expected-file
            (epi-ledger--checkpoint-raw-file-identity checkpoint))
           (expected-end
            (epi-ledger--checkpoint-raw-validated-end-offset checkpoint))
           (expected-head
            (epi-ledger--checkpoint-raw-tail-hash checkpoint))
           (ledger-bytes (epi-test-ledger-io--literal-file-bytes path))
           (token (epi-test-ledger-io--wave2-present-token path ledger))
           (sha (secure-hash 'sha256 token))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (expected-archive
            (epi-test-ledger-io--wave2-archive-path path sha))
           (self (emacs-pid))
           (expected-candidate
            (epi-test-ledger-io--wave2-token-bytes
             path :pid self :process-start epi-test-ledger-io--wave2-start
             :nonce epi-test-ledger-io--wave2-second-nonce
             :expected-file expected-file :expected-end expected-end
             :expected-head expected-head))
           (real-create epi-ledger--lock-create-function)
           (real-decode (symbol-function 'epi-ledger--decode-lock-token))
           (real-add-name (symbol-function 'add-name-to-file))
           (real-delete (symbol-function 'delete-file))
           original-lock-identity
           decoded-stale
           link-calls
           (original-unlink-count 0)
           (yield-count 0)
           archive-callback-active
           fresh-create-seen
           candidates
           archive)
      (epi-test-ledger-io--wave2-write-private lock-path token)
      (setq original-lock-identity
            (funcall epi-ledger--stat-function lock-path))
      (let ((epi--id-function
             (lambda () epi-test-ledger-io--wave2-second-nonce))
            (epi--yield-function
             (lambda ()
               (when archive-callback-active
                 (setq yield-count (1+ yield-count))
                 (unless decoded-stale
                   (ert-fail "archive callback ran before token decoding"))
                 ;; Attempt to mutate every mutable class returned by
                 ;; decoding.  Recovery must already own the expected state.
                 (let ((decoded-file
                        (epi-test-ledger-io--wave2-token-value
                         decoded-stale "expected_file")))
                   (aset (epi-test-ledger-io--wave2-token-value
                          decoded-stale "host") 0 ?X)
                   (aset (epi-test-ledger-io--wave2-token-value
                          decoded-stale "nonce") 0 ?b)
                   (aset (epi-test-ledger-io--wave2-token-value
                          decoded-stale "process_start") 0 99)
                   (aset (epi-test-ledger-io--wave2-token-value
                          decoded-stale "expected_end") 0 ?9)
                   (aset (epi-test-ledger-io--wave2-token-value
                          decoded-stale "expected_head") 0 ?f)
                   (aset (epi-test-ledger-io--wave2-token-value
                          decoded-file "path") 0 ?X)
                   (aset (epi-test-ledger-io--wave2-token-value
                          decoded-file "size") 0 ?9)
                   (aset (epi-test-ledger-io--wave2-token-value
                          decoded-file "modified") 0 99)))))
            (epi-ledger--append-function
             #'epi-test-ledger-io--unexpected-storage-call)
            (epi-ledger--lock-create-function
             (lambda (target candidate)
               ;; Archival must precede fresh ownership, and the new token is
               ;; an exact restatement of the archived token's ledger guard.
               (should (equal lock-path target))
               (should (file-exists-p expected-archive))
               (should-not (file-exists-p lock-path))
               (push candidate candidates)
               (let* ((decoded (epi-ledger--decode-lock-token candidate))
                      (candidate-file
                       (epi-test-ledger-io--wave2-token-value
                        decoded "expected_file")))
                 (should
                  (equal (epi-test-ledger-io--wave2-file-object expected-file)
                         candidate-file))
                 (should
                  (equal (number-to-string expected-end)
                         (epi-test-ledger-io--wave2-token-value
                          decoded "expected_end")))
                 (should
                  (equal expected-head
                         (epi-test-ledger-io--wave2-token-value
                          decoded "expected_head"))))
               (setq fresh-create-seen t)
               (funcall real-create target candidate))))
        (cl-letf (((symbol-function 'epi-ledger--decode-lock-token)
                   (lambda (bytes)
                     (let ((decoded (funcall real-decode bytes)))
                       (when (and (not decoded-stale)
                                  (equal bytes token))
                         (setq decoded-stale decoded))
                       decoded)))
                  ((symbol-function 'add-name-to-file)
                   (lambda (source destination &optional ok-if-exists)
                     (push (list source destination ok-if-exists) link-calls)
                     (should (equal lock-path source))
                     (should (equal expected-archive destination))
                     (should-not ok-if-exists)
                     ;; A seam may yield and mutate values returned earlier.
                     (setq archive-callback-active t)
                     (unwind-protect
                         (epi--yield)
                       (setq archive-callback-active nil))
                     (funcall real-add-name source destination ok-if-exists)
                     (let ((source-id
                            (funcall epi-ledger--stat-function source))
                           (archive-id
                            (funcall epi-ledger--stat-function destination)))
                       (dolist (key '(:device :inode))
                         (should
                          (= (plist-get original-lock-identity key)
                             (plist-get source-id key)))
                         (should
                          (= (plist-get source-id key)
                             (plist-get archive-id key)))))))
                  ((symbol-function 'delete-file)
                   (lambda (target &optional trash)
                     (when (and (equal target lock-path)
                                (not fresh-create-seen))
                       (setq original-unlink-count
                             (1+ original-unlink-count))
                       (let ((source-id
                              (funcall epi-ledger--stat-function lock-path))
                             (archive-id
                              (funcall epi-ledger--stat-function
                                       expected-archive)))
                         ;; The archive is the same inode before the original
                         ;; name is unlinked; copy-file plus delete cannot pass.
                         (dolist (key '(:device :inode))
                           (should
                            (= (plist-get original-lock-identity key)
                               (plist-get source-id key)))
                           (should
                            (= (plist-get source-id key)
                               (plist-get archive-id key))))))
                     (funcall real-delete target trash)))
                  ((symbol-function 'process-attributes)
                   (lambda (pid)
                     (and (= pid self)
                          (epi-test-ledger-io--wave2-good-attributes)))))
          (setq archive
                (epi-ledger-recover-stale-lock
                 path :expected-token-sha256 sha))))
      (should (equal (list expected-candidate) (nreverse candidates)))
      (should
       (equal (list (list lock-path expected-archive nil))
              (nreverse link-calls)))
      (should (= 1 original-unlink-count))
      (should (= 1 yield-count))
      (should (equal expected-archive archive))
      (should (equal token
                     (epi-test-ledger-io--literal-file-bytes archive)))
      (let ((archive-identity
             (funcall epi-ledger--stat-function expected-archive)))
        (dolist (key '(:device :inode))
          (should (= (plist-get original-lock-identity key)
                     (plist-get archive-identity key)))))
      (should (= #o600 (epi-test-ledger-io--permission-bits archive)))
      (should-not (file-exists-p lock-path))
      (should (equal ledger-bytes
                     (epi-test-ledger-io--literal-file-bytes path))))

    ;; The absent form is a successful recovery state in its own right.  Its
    ;; fresh token must preserve absent/zero/null exactly and no ledger appears.
    (let* ((path (epi-test-ledger-io--wave2-path root "absent.org"))
           (token (epi-test-ledger-io--wave2-token-bytes path))
           (sha (secure-hash 'sha256 token))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (expected-archive
            (epi-test-ledger-io--wave2-archive-path path sha))
           (self (emacs-pid))
           (expected-candidate
            (epi-test-ledger-io--wave2-token-bytes
             path :pid self :process-start epi-test-ledger-io--wave2-start
             :nonce epi-test-ledger-io--wave2-second-nonce))
           (real-create epi-ledger--lock-create-function)
           candidates
           archive)
      (should-not (file-exists-p path))
      (epi-test-ledger-io--wave2-write-private lock-path token)
      (let ((epi--id-function
             (lambda () epi-test-ledger-io--wave2-second-nonce))
            (epi-ledger--append-function
             #'epi-test-ledger-io--unexpected-storage-call)
            (epi-ledger--lock-create-function
             (lambda (target candidate)
               (should (equal lock-path target))
               (push candidate candidates)
               (let ((decoded (epi-ledger--decode-lock-token candidate)))
                 (should
                  (equal "absent"
                         (epi-test-ledger-io--wave2-token-value
                          decoded "expected_file")))
                 (should
                  (equal "0"
                         (epi-test-ledger-io--wave2-token-value
                          decoded "expected_end")))
                 (should
                  (eq epi-json-null
                      (epi-test-ledger-io--wave2-token-value
                       decoded "expected_head"))))
               (funcall real-create target candidate))))
        (cl-letf (((symbol-function 'process-attributes)
                   (lambda (pid)
                     (and (= pid self)
                          (epi-test-ledger-io--wave2-good-attributes)))))
          (setq archive
                (epi-ledger-recover-stale-lock
                 path :expected-token-sha256 sha))))
      (should (equal (list expected-candidate) (nreverse candidates)))
      (should (equal expected-archive archive))
      (should (equal token
                     (epi-test-ledger-io--literal-file-bytes archive)))
      (should-not (file-exists-p path))
      (should-not (file-exists-p lock-path)))

    ;; A callback can replace the source in place after the last pre-link
    ;; check.  The resulting hard link is a publication, but never a valid
    ;; archive of the caller-authorized SHA.
    (let* ((path (epi-test-ledger-io--wave2-path
                  root "mutated-archive-source.org"))
           (token (epi-test-ledger-io--wave2-token-bytes path))
           (replacement
            (epi-test-ledger-io--wave2-token-bytes
             path :nonce epi-test-ledger-io--wave2-second-nonce))
           (sha (secure-hash 'sha256 token))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (archive (epi-test-ledger-io--wave2-archive-path path sha))
           (real-add-name (symbol-function 'add-name-to-file)))
      (should (= (length token) (length replacement)))
      (epi-test-ledger-io--wave2-write-private lock-path token)
      (let ((epi-ledger--lock-create-function
             #'epi-test-ledger-io--unexpected-storage-call))
        (cl-letf (((symbol-function 'add-name-to-file)
                   (lambda (source destination &optional ok-if-exists)
                     (epi-ledger--write-bytes source replacement 'replace t)
                     (funcall real-add-name
                              source destination ok-if-exists))))
          (let ((condition
                 (should-error
                  (epi-ledger-recover-stale-lock
                   path :expected-token-sha256 sha)
                  :type 'epi-ledger-conflict)))
            (should (eq 'storage-publication-failed
                        (epi-test-ledger-io--condition-code condition)))
            (should (eq t (plist-get
                           (epi-test-ledger-io--condition-detail condition)
                           :published))))))
      (should (equal replacement
                     (epi-test-ledger-io--literal-file-bytes lock-path)))
      (should (equal replacement
                     (epi-test-ledger-io--literal-file-bytes archive)))
      (should (epi-ledger--same-file-object-p
               (epi-ledger--file-identity lock-path)
               (epi-ledger--file-identity archive))))

    ;; A hard-link primitive may publish successfully and then report an I/O
    ;; error.  Presence of the exact same object makes the outcome explicitly
    ;; postpublication rather than a retryable prepublication failure.
    (let* ((path (epi-test-ledger-io--wave2-path
                  root "ambiguous-archive-link.org"))
           (token (epi-test-ledger-io--wave2-token-bytes path))
           (sha (secure-hash 'sha256 token))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (archive (epi-test-ledger-io--wave2-archive-path path sha))
           (real-add-name (symbol-function 'add-name-to-file)))
      (epi-test-ledger-io--wave2-write-private lock-path token)
      (let ((epi-ledger--lock-create-function
             #'epi-test-ledger-io--unexpected-storage-call))
        (cl-letf (((symbol-function 'add-name-to-file)
                   (lambda (source destination &optional ok-if-exists)
                     (funcall real-add-name
                              source destination ok-if-exists)
                     (signal 'file-error '("injected post-link failure")))))
          (let ((condition
                 (should-error
                  (epi-ledger-recover-stale-lock
                   path :expected-token-sha256 sha)
                  :type 'epi-ledger-conflict)))
            (should (eq 'storage-publication-failed
                        (epi-test-ledger-io--condition-code condition)))
            (should (eq t (plist-get
                           (epi-test-ledger-io--condition-detail condition)
                           :published))))))
      (should (equal token
                     (epi-test-ledger-io--literal-file-bytes lock-path)))
      (should (equal token
                     (epi-test-ledger-io--literal-file-bytes archive)))
      (should (epi-ledger--same-file-object-p
               (epi-ledger--file-identity lock-path)
               (epi-ledger--file-identity archive))))))

(ert-deftest epi-ledger-stale-lock-recovery-revalidates-file-end-and-head ()
  (should (fboundp 'epi-ledger-recover-stale-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-write-document
                  root (list (epi-test-ledger-io--session-info))))
           (ledger (epi-ledger-open path))
           (token (epi-test-ledger-io--wave2-present-token path ledger))
           (sha (secure-hash 'sha256 token))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (archive (epi-test-ledger-io--wave2-archive-path path sha))
           (real-lock-create epi-ledger--lock-create-function)
           (create-count 0))
      (epi-test-ledger-io--wave2-write-private lock-path token)
      (let ((epi--id-function
             (lambda () epi-test-ledger-io--wave2-second-nonce))
            (epi-ledger--append-function
             #'epi-test-ledger-io--unexpected-storage-call)
            (epi-ledger--lock-create-function
             (lambda (target bytes)
               (setq create-count (1+ create-count))
               ;; This is an external competitor, not Epi's append seam.
               (let ((coding-system-for-write 'no-conversion)
                     (create-lockfiles nil)
                     (write-region-annotate-functions nil)
                     (write-region-post-annotation-function nil))
                 (write-region (string-make-unibyte "X") nil
                               path t 'silent))
               (funcall real-lock-create target bytes))))
        (cl-letf (((symbol-function 'process-attributes)
                   (lambda (_pid)
                     (epi-test-ledger-io--wave2-good-attributes))))
          (let ((condition
                 (should-error
                  (epi-ledger-recover-stale-lock
                   path :expected-token-sha256 sha)
                  :type 'epi-ledger-conflict)))
            (should
             (epi-test-ledger-io--wave2-structured-code-p
              condition '(file-identity-changed file-end-changed
                          file-chain-head-changed))))))
      (should (= 1 create-count))
      (should (file-exists-p archive))
      (should (equal token
                     (epi-test-ledger-io--literal-file-bytes archive)))
      (should-not (file-exists-p lock-path)))))

(ert-deftest epi-ledger-stale-lock-recovery-revalidates-chain-head-independently ()
  (should (fboundp 'epi-ledger-recover-stale-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-write-document
                  root (list (epi-test-ledger-io--session-info))))
           (ledger (epi-ledger-open path))
           (checkpoint (epi-ledger--checkpoint-snapshot ledger))
           (expected-identity
            (epi-ledger--checkpoint-raw-file-identity checkpoint))
           (token (epi-test-ledger-io--wave2-present-token path ledger))
           (sha (secure-hash 'sha256 token))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (archive (epi-test-ledger-io--wave2-archive-path path sha))
           (alternative-draft (epi-test-ledger-io--session-info))
           (alternative-payload
            (copy-tree (epi-draft-payload alternative-draft)))
           alternative
           (real-create epi-ledger--lock-create-function)
           (real-stat epi-ledger--stat-function)
           (mutation-count 0))
      (setf (alist-get "base_system_prompt" alternative-payload
                       nil nil #'string=)
            "Go exact.")
      (setf (epi-draft-payload alternative-draft) alternative-payload)
      (setq alternative
            (epi-test-ledger-io--document-bytes
             (list alternative-draft)))
      (should (= (length alternative)
                 (plist-get expected-identity :size)))
      (should-not
       (equal alternative
              (epi-test-ledger-io--literal-file-bytes path)))
      (epi-test-ledger-io--wave2-write-private lock-path token)
      (let ((epi--id-function
             (lambda () epi-test-ledger-io--wave2-second-nonce))
            (epi-ledger--append-function
             #'epi-test-ledger-io--unexpected-storage-call)
            (epi-ledger--stat-function
             (lambda (target)
               (if (equal target path)
                   expected-identity
                 (funcall real-stat target))))
            (epi-ledger--lock-create-function
             (lambda (target candidate)
               (let ((identity (funcall real-create target candidate)))
                 (when (equal target lock-path)
                   (setq mutation-count (1+ mutation-count))
                   ;; External same-size replacement; the stat seam above
                   ;; deliberately leaves identity and EOF apparently stable.
                   (epi-ledger--write-bytes path alternative 'replace t))
                 identity))))
        (cl-letf (((symbol-function 'process-attributes)
                   (lambda (_pid)
                     (epi-test-ledger-io--wave2-good-attributes))))
          (let ((condition
                 (should-error
                  (epi-ledger-recover-stale-lock
                   path :expected-token-sha256 sha)
                  :type 'epi-ledger-conflict)))
            (should (eq 'file-chain-head-changed
                        (epi-test-ledger-io--condition-code condition))))))
      (should (= 1 mutation-count))
      (should (equal alternative
                     (epi-test-ledger-io--literal-file-bytes path)))
      (should (equal token
                     (epi-test-ledger-io--literal-file-bytes archive)))
      (should-not (file-exists-p lock-path)))))

(ert-deftest epi-ledger-lock-does-not-infer-death-from-nil-process-attributes ()
  (should (fboundp 'epi-ledger--lock-owner-state))
  (should (fboundp 'epi-ledger--acquire-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-path root "session.org"))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (self (emacs-pid))
           (old-pid (+ (emacs-pid) 100000))
           (bytes
            (epi-test-ledger-io--wave2-token-bytes path :pid old-pid)))
      (epi-test-ledger-io--wave2-write-private lock-path bytes)
      (dolist (snapshot '(listed unavailable))
        (epi-test-ledger-io--wave2-with-forbidden-mutations
          (cl-letf
              (((symbol-function 'process-attributes)
                (lambda (pid)
                  (and (= pid self)
                       (epi-test-ledger-io--wave2-good-attributes))))
               ((symbol-function 'list-system-processes)
                (and (eq snapshot 'listed)
                     (lambda () (list self old-pid)))))
            (let ((condition
                   (should-error
                    (epi-ledger--acquire-lock path "absent" 0 nil)
                    :type 'epi-ledger-conflict)))
              (should (eq 'lock-owner-indeterminate
                          (epi-test-ledger-io--condition-code
                           condition))))))
        (should (equal bytes
                       (epi-test-ledger-io--literal-file-bytes
                        lock-path)))))))

(ert-deftest epi-ledger-lock-takeover-race-is-not-retried ()
  (should (fboundp 'epi-ledger--acquire-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-path root "session.org"))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (self (emacs-pid))
           (old-pid (+ self 100000))
           (old-token
            (epi-test-ledger-io--wave2-token-bytes path :pid old-pid))
           (winner
            (epi-test-ledger-io--wave2-token-bytes
             path :host "winner.example"
             :nonce epi-test-ledger-io--wave2-second-nonce))
           (expected-candidate
            (epi-test-ledger-io--wave2-token-bytes
             path :pid self
             :process-start epi-test-ledger-io--wave2-start))
           (real-create epi-ledger--lock-create-function)
           (create-count 0)
           candidates)
      (epi-test-ledger-io--wave2-write-private lock-path old-token)
      (let ((epi--id-function
             (lambda () epi-test-ledger-io--wave2-nonce))
            (epi-ledger--lock-create-function
             (lambda (target candidate)
               (setq create-count (1+ create-count))
               (push candidate candidates)
               (should (equal expected-candidate candidate))
               (when (> create-count 1)
                 (ert-fail "takeover retried after losing its one attempt"))
               (when (not (file-exists-p target))
                 (epi-test-ledger-io--wave2-write-private target winner))
               (funcall real-create target candidate))))
        (cl-letf
            (((symbol-function 'process-attributes)
              (lambda (pid)
                (and (= pid self)
                     (epi-test-ledger-io--wave2-good-attributes))))
             ((symbol-function 'list-system-processes)
              (lambda () (list self))))
          (let ((condition
                 (should-error
                  (epi-ledger--acquire-lock path "absent" 0 nil)
                  :type 'epi-ledger-conflict)))
            (should
             (epi-test-ledger-io--wave2-structured-code-p
              condition '(destination-exists lock-held))))))
      (should (= 1 create-count))
      (should (equal (list expected-candidate) (nreverse candidates)))
      (should (equal winner
                     (epi-test-ledger-io--literal-file-bytes lock-path))))))

(ert-deftest epi-ledger-lock-takeover-refuses-replaced-token-after-death-proof ()
  (should (fboundp 'epi-ledger--acquire-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-path root "session.org"))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (self (emacs-pid))
           (old-pid (+ self 100000))
           (old-token
            (epi-test-ledger-io--wave2-token-bytes path :pid old-pid))
           (winner
            (epi-test-ledger-io--wave2-token-bytes
             path :pid old-pid
             :nonce epi-test-ledger-io--wave2-second-nonce))
           (stable-identity nil)
           (real-read epi-ledger--read-function)
           (real-stat epi-ledger--stat-function)
           (real-create epi-ledger--lock-create-function)
           (read-count 0)
           (create-count 0))
      (should (= (length old-token) (length winner)))
      (epi-test-ledger-io--wave2-write-private lock-path old-token)
      (setq stable-identity (funcall real-stat lock-path))
      (let ((epi--id-function
             (lambda () epi-test-ledger-io--wave2-nonce))
            (epi-ledger--stat-function
             (lambda (target)
               (if (equal target lock-path)
                   stable-identity
                 (funcall real-stat target))))
            (epi-ledger--read-function
             (lambda (target begin end)
               (when (equal target lock-path)
                 (setq read-count (1+ read-count))
                 (when (= read-count 2)
                   (epi-ledger--write-bytes target winner 'replace t)))
               (funcall real-read target begin end)))
            (epi-ledger--lock-create-function
             (lambda (target candidate)
               (setq create-count (1+ create-count))
               (funcall real-create target candidate))))
        (cl-letf
            (((symbol-function 'process-attributes)
              (lambda (pid)
                (and (= pid self)
                     (epi-test-ledger-io--wave2-good-attributes))))
             ((symbol-function 'list-system-processes)
              (lambda () (list self))))
          (let ((condition
                 (should-error
                  (epi-ledger--acquire-lock path "absent" 0 nil)
                  :type 'epi-ledger-conflict)))
            (should (eq 'lock-token-changed
                        (epi-test-ledger-io--condition-code condition))))))
      (should (= 2 read-count))
      (should (= 0 create-count))
      (should (equal winner
                     (epi-test-ledger-io--literal-file-bytes lock-path))))))

(ert-deftest epi-ledger-lock-derived-path-handler-is-rejected-before-io ()
  (should (fboundp 'epi-ledger--acquire-lock))
  (should (fboundp 'epi-ledger-recover-stale-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-path root "session.org"))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (lock-pattern (concat "\\`" (regexp-quote lock-path) "\\'")))
      (epi-test-ledger-io--wave2-with-forbidden-mutations
        (let ((file-name-handler-alist
               `((,lock-pattern . epi-test-ledger-io--hostile-file-handler))))
          (let ((condition
                 (should-error
                  (epi-ledger--acquire-lock path "absent" 0 nil)
                  :type 'epi-ledger-format-error)))
            (should (eq 'invalid-write-path
                        (epi-test-ledger-io--condition-code condition))))))
      (let* ((ledger-path
              (epi-test-ledger-io--wave2-write-document
               root (list (epi-test-ledger-io--session-info))))
             (ledger (epi-ledger-open ledger-path))
             (token
              (epi-test-ledger-io--wave2-present-token ledger-path ledger))
             (sha (secure-hash 'sha256 token))
             (token-path
              (epi-test-ledger-io--wave2-lock-path ledger-path))
             (archive
              (epi-test-ledger-io--wave2-archive-path ledger-path sha))
             (archive-pattern (concat "\\`" (regexp-quote archive) "\\'")))
        (epi-test-ledger-io--wave2-write-private token-path token)
        (let ((before (epi-test-ledger-io--wave2-tree-snapshot root)))
          (epi-test-ledger-io--wave2-with-forbidden-mutations
            (let ((file-name-handler-alist
                   `((,archive-pattern .
                      epi-test-ledger-io--hostile-file-handler))))
              (let ((condition
                     (should-error
                      (epi-ledger-recover-stale-lock
                       ledger-path :expected-token-sha256 sha)
                      :type 'epi-ledger-format-error)))
                (should (eq 'invalid-write-path
                            (epi-test-ledger-io--condition-code
                             condition))))))
          (should (equal before
                         (epi-test-ledger-io--wave2-tree-snapshot root))))))))

(ert-deftest epi-ledger-lock-token-size-cap-precedes-read ()
  (should (fboundp 'epi-ledger--acquire-lock))
  (should (fboundp 'epi-ledger-recover-stale-lock))
  (should (boundp 'epi-ledger--lock-token-byte-limit))
  (should (= 65536 epi-ledger--lock-token-byte-limit))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-path root "session.org"))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (oversized (make-string 65537 ?x))
           (read-count 0))
      (epi-test-ledger-io--wave2-write-private lock-path oversized)
      (let ((epi-ledger--read-function
             (lambda (&rest _arguments)
               (setq read-count (1+ read-count))
               (ert-fail "oversized token was read"))))
        (epi-test-ledger-io--wave2-with-forbidden-mutations
          (cl-letf (((symbol-function 'process-attributes)
                     (lambda (_pid)
                       (epi-test-ledger-io--wave2-good-attributes))))
            (let ((condition
                   (should-error
                    (epi-ledger--acquire-lock path "absent" 0 nil)
                    :type 'epi-limit-exceeded)))
              (should (eq 'lock-token-byte-limit
                          (epi-test-ledger-io--condition-code
                           condition))))))
        (epi-test-ledger-io--wave2-with-forbidden-mutations
          (let ((condition
                 (should-error
                  (epi-ledger-recover-stale-lock
                   path :expected-token-sha256
                   (secure-hash 'sha256 oversized))
                  :type 'epi-limit-exceeded)))
            (should (eq 'lock-token-byte-limit
                        (epi-test-ledger-io--condition-code condition))))))
      (should (= 0 read-count))
      ;; At the exact literal cap, acquisition and explicit recovery each read
      ;; one bounded range and never request byte 65537.
      (epi-test-ledger-io--wave2-replace-private
       lock-path (make-string 65536 ?x))
      (let ((exact (epi-test-ledger-io--literal-file-bytes lock-path))
            (real-read epi-ledger--read-function))
        (dolist (operation '(acquire recover))
          (let (ranges)
            (let ((epi-ledger--read-function
                   (lambda (target begin end)
                     (push (list begin end) ranges)
                     (funcall real-read target begin end))))
              (epi-test-ledger-io--wave2-with-forbidden-mutations
                (cl-letf (((symbol-function 'process-attributes)
                           (lambda (_pid)
                             (epi-test-ledger-io--wave2-good-attributes))))
                  (let ((condition
                         (should-error
                          (if (eq operation 'acquire)
                              (epi-ledger--acquire-lock
                               path "absent" 0 nil)
                            (epi-ledger-recover-stale-lock
                             path :expected-token-sha256
                             (secure-hash 'sha256 exact)))
                          :type 'epi-ledger-conflict)))
                    (should (eq 'malformed-lock-token
                                (epi-test-ledger-io--condition-code
                                 condition)))))))
            (should (equal '((0 65536)) (nreverse ranges)))
            (should (equal exact
                           (epi-test-ledger-io--literal-file-bytes
                            lock-path)))))))))

(ert-deftest epi-ledger-stale-lock-recovery-resumes-an-existing-exact-archive ()
  (should (fboundp 'epi-ledger-recover-stale-lock))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave2-write-document
                  root (list (epi-test-ledger-io--session-info))))
           (ledger (epi-ledger-open path))
           (ledger-bytes (epi-test-ledger-io--literal-file-bytes path))
           (token (epi-test-ledger-io--wave2-present-token path ledger))
           (sha (secure-hash 'sha256 token))
           (lock-path (epi-test-ledger-io--wave2-lock-path path))
           (archive (epi-test-ledger-io--wave2-archive-path path sha))
           (replacement
            (epi-test-ledger-io--wave2-present-token
             path ledger :nonce epi-test-ledger-io--wave2-second-nonce))
           (real-read epi-ledger--read-function)
           (real-stat epi-ledger--stat-function)
           archive-identity
           result)
      (should (= (length token) (length replacement)))
      (epi-test-ledger-io--wave2-write-private lock-path token)
      (epi-test-ledger-io--wave2-write-private archive token)
      (setq archive-identity (epi-ledger--file-identity archive))
      (let ((epi--id-function
             (lambda () epi-test-ledger-io--wave2-second-nonce))
            (epi-ledger--append-function
             #'epi-test-ledger-io--unexpected-storage-call))
        (cl-letf (((symbol-function 'process-attributes)
                   (lambda (_pid)
                     (epi-test-ledger-io--wave2-good-attributes))))
          (setq result
                (epi-ledger-recover-stale-lock
                 path :expected-token-sha256 sha))))
      (should (equal archive result))
      (should (equal archive-identity
                     (epi-ledger--file-identity archive)))
      (should (equal token
                     (epi-test-ledger-io--literal-file-bytes archive)))
      (should-not (file-exists-p lock-path))
      (should (equal ledger-bytes
                     (epi-test-ledger-io--literal-file-bytes path)))

      ;; Resume is also race-safe: once the existing archive has been checked,
      ;; replacing the original token before its final reread/deletion must
      ;; preserve the winner and prevent fresh acquisition.
      (epi-test-ledger-io--wave2-write-private lock-path token)
      (let ((original-identity (funcall real-stat lock-path))
            archive-read-seen
            injected)
        (let ((epi-ledger--append-function
               #'epi-test-ledger-io--unexpected-storage-call)
              (epi-ledger--lock-create-function
               #'epi-test-ledger-io--unexpected-storage-call)
              (epi-ledger--publish-function
               #'epi-test-ledger-io--unexpected-storage-call)
              (epi-ledger--stat-function
               (lambda (target)
                 (if (equal target lock-path)
                     original-identity
                   (funcall real-stat target))))
              (epi-ledger--read-function
               (lambda (target begin end)
                 (cond
                  ((equal target archive)
                   (prog1 (funcall real-read target begin end)
                     (setq archive-read-seen t)))
                  ((and (equal target lock-path)
                        archive-read-seen
                        (not injected))
                   (setq injected t)
                   (epi-test-ledger-io--wave2-replace-private
                    lock-path replacement)
                   (funcall real-read target begin end))
                  (t (funcall real-read target begin end))))))
          (let ((condition
                 (should-error
                  (epi-ledger-recover-stale-lock
                   path :expected-token-sha256 sha)
                  :type 'epi-ledger-conflict)))
            (should (eq 'lock-token-changed
                        (epi-test-ledger-io--condition-code condition)))))
        (should archive-read-seen)
        (should injected))
      (should (equal replacement
                     (epi-test-ledger-io--literal-file-bytes lock-path)))
      (should (equal archive-identity
                     (epi-ledger--file-identity archive)))
      (should (equal token
                     (epi-test-ledger-io--literal-file-bytes archive)))
      (should (equal ledger-bytes
                     (epi-test-ledger-io--literal-file-bytes path)))

      ;; Once an exact archive already exists, removing the still-identical
      ;; source name is nevertheless postpublication cleanup.
      (epi-test-ledger-io--wave2-replace-private lock-path token)
      (let ((real-delete (symbol-function 'delete-file))
            (epi-ledger--lock-create-function
             #'epi-test-ledger-io--unexpected-storage-call))
        (cl-letf (((symbol-function 'delete-file)
                   (lambda (target &optional trash)
                     (if (equal target lock-path)
                         (signal 'file-error
                                 '("injected archive cleanup failure"))
                       (funcall real-delete target trash)))))
          (let ((condition
                 (should-error
                  (epi-ledger-recover-stale-lock
                   path :expected-token-sha256 sha)
                  :type 'epi-ledger-conflict)))
            (should (eq 'storage-publication-failed
                        (epi-test-ledger-io--condition-code condition)))
            (should (eq t (plist-get
                           (epi-test-ledger-io--condition-detail condition)
                           :published))))))
      (should (equal token
                     (epi-test-ledger-io--literal-file-bytes lock-path)))
      (should (equal token
                     (epi-test-ledger-io--literal-file-bytes archive)))
      (should (equal ledger-bytes
                     (epi-test-ledger-io--literal-file-bytes path))))))

(declare-function epi-ledger-create "epi-ledger" (path &rest keys))
(declare-function epi-ledger--decode-lock-token "epi-ledger" (bytes))

;;;; Wave 3: complete atomic creation

;; The execution brief freezes two zero-argument private create barriers.
;; This RED artifact uses dynamically bindable function variables so the
;; barriers remain test-only implementation seams:
;;
;;   epi-ledger--create-prepublication-function
;;   epi-ledger--create-postpublication-function

(define-error 'epi-test-ledger-io-wave3-stop
  "Injected Wave 3 publication stop")

(defconst epi-test-ledger-io--wave3-created-at
  "2026-07-21T18:42:17-07:00"
  "Deterministic header creation timestamp used by Wave 3 tests.")

(defconst epi-test-ledger-io--wave3-project-root "/tmp/epi-project/"
  "Deterministic canonical project root used by Wave 3 tests.")

(defconst epi-test-ledger-io--wave3-mutation-seams
  '(epi-ledger--byte-writer
    epi-ledger--lock-create-function
    epi-ledger--append-function
    epi-ledger--flush-function
    epi-ledger--stat-function
    epi-ledger--read-function
    epi-ledger--unlock-function
    epi-ledger--publish-function)
  "Storage seams that rejected creation input must not reach.")

(defun epi-test-ledger-io--wave3-id-source ()
  "Return a closure producing distinct deterministic valid UUIDs."
  (let ((next 0))
    (lambda ()
      (setq next (1+ next))
      (format "90000000-0000-4000-8000-%012x" next))))

(defun epi-test-ledger-io--wave3-path (root &optional leaf)
  "Return canonical absent LEAF below existing temporary ROOT."
  (expand-file-name
   (or leaf "session.org")
   (file-name-as-directory (file-truename root))))

(defun epi-test-ledger-io--wave3-lock-path (path)
  "Return the exact Epi create-lock sibling for PATH."
  (concat path ".epi-lock"))

(defun epi-test-ledger-io--wave3-temporary-p (candidate path)
  "Return non-nil when CANDIDATE is a recognized create temporary for PATH."
  (and (stringp candidate)
       (equal (file-name-directory candidate) (file-name-directory path))
       (string-prefix-p
        (concat "." (file-name-nondirectory path) ".epi-tmp-")
        (file-name-nondirectory candidate))))

(defun epi-test-ledger-io--wave3-temporaries (path)
  "Return sorted recognized hidden create temporaries for PATH."
  (sort
   (seq-filter
    (lambda (candidate)
      (epi-test-ledger-io--wave3-temporary-p candidate path))
    (directory-files (file-name-directory path) t
                     directory-files-no-dot-files-regexp t))
   #'string<))

(defun epi-test-ledger-io--wave3-token-value (token key)
  "Return string KEY from decoded lock TOKEN."
  (alist-get key token nil nil #'string=))

(defun epi-test-ledger-io--wave3-session-info-with-id (record-id)
  "Return a session-info draft with unique RECORD-ID."
  (let ((draft (epi-test-ledger-io--session-info)))
    (setf (epi-draft-id draft) record-id)
    draft))

(defun epi-test-ledger-io--wave3-mismatched-session-info ()
  "Return session-info whose payload disagrees with the fixed header."
  (let ((draft (epi-test-ledger-io--session-info)))
    (setf (epi-draft-payload draft)
          (copy-tree (epi-draft-payload draft) t))
    (setcdr (assoc "session_id" (epi-draft-payload draft))
            "99999999-9999-4999-8999-999999999999")
    draft))

(cl-defun epi-test-ledger-io--wave3-create
    (path &key
          (session-id epi-test-ledger-io--session-id)
          (created-at epi-test-ledger-io--wave3-created-at)
          (project-root epi-test-ledger-io--wave3-project-root)
          (initial-drafts (vector (epi-test-ledger-io--session-info))))
  "Create PATH through the frozen public API with deterministic inputs.
SESSION-ID, CREATED-AT, PROJECT-ROOT, and INITIAL-DRAFTS may override the
fixed test values."
  (epi-ledger-create
   path
   :session-id session-id
   :created-at created-at
   :project-root project-root
   :initial-drafts initial-drafts))

(defun epi-test-ledger-io--wave3-records (ledger)
  "Return LEDGER's defensive record vector."
  (epi-ledger-records ledger))

(defun epi-test-ledger-io--wave3-projection (ledger)
  "Return every externally meaningful final authority in LEDGER."
  (list :path (epi-ledger-path ledger)
        :session-id (epi-ledger-session-id ledger)
        :project-root (epi-ledger-project-root ledger)
        :header (epi-ledger-header ledger)
        :records (epi-ledger-records ledger)
        :file-identity (epi-ledger-file-identity ledger)
        :validated-end (epi-ledger-validated-end-offset ledger)
        :tail-hash (epi-ledger-tail-hash ledger)))

(defun epi-test-ledger-io--wave3-assert-single-session (ledger)
  "Require exactly one agreeing session-info record in LEDGER."
  (let* ((header (epi-ledger-header ledger))
         (records (epi-test-ledger-io--wave3-records ledger))
         (record (and (= 1 (length records)) (aref records 0))))
    (should (epi-ledger-p ledger))
    (should (= 1 (length records)))
    (should (eq 'session-info (epi-record-type record)))
    (should
     (equal (epi-header-session-id header)
            (epi-ledger--object-value
             (epi-record-payload record) "session_id")))
    (should (equal epi-test-ledger-io--session-id
                   (epi-header-session-id header)))
    (should (= 1
               (seq-count
                (lambda (candidate)
                  (eq 'session-info (epi-record-type candidate)))
                records)))
    ledger))

(defun epi-test-ledger-io--wave3-temp-complete-p (path)
  "Return non-nil when PATH is a complete private one-session ledger."
  (condition-case nil
      (let ((ledger (epi-ledger-open path)))
        (and (= #o600 (epi-test-ledger-io--permission-bits path))
             (= 1 (length (epi-test-ledger-io--wave3-records ledger)))
             (eq 'session-info
                 (epi-record-type
                  (aref (epi-test-ledger-io--wave3-records ledger) 0)))
             (equal epi-test-ledger-io--session-id
                    (epi-ledger-session-id ledger))))
    (error nil)))

(defun epi-test-ledger-io--wave3-unexpected-mutation (&rest arguments)
  "Fail because rejected creation input reached storage with ARGUMENTS."
  (ert-fail
   (format "invalid create input reached storage seam: %S" arguments)))

(defun epi-test-ledger-io--wave3-call-with-forbidden-io
    (function &optional allow-work-callbacks)
  "Call FUNCTION while rejecting generation and filesystem callbacks.
When ALLOW-WORK-CALLBACKS is non-nil, allow deterministic deadline samples
and cooperative yields after ownership."
  (let ((values
         (make-list
          (length epi-test-ledger-io--wave3-mutation-seams)
          #'epi-test-ledger-io--wave3-unexpected-mutation))
        (epi--id-function #'epi-test-ledger-io--wave3-unexpected-mutation)
        (epi--wall-clock-function
         #'epi-test-ledger-io--wave3-unexpected-mutation)
        (epi--deadline-clock-function (lambda () 0.0))
        (epi--deadline-high-water nil)
        (epi--yield-function
         (if allow-work-callbacks
             #'ignore
           #'epi-test-ledger-io--wave3-unexpected-mutation)))
    (cl-progv epi-test-ledger-io--wave3-mutation-seams values
      (cl-letf
          (((symbol-function 'file-exists-p)
            #'epi-test-ledger-io--wave3-unexpected-mutation)
           ((symbol-function 'file-symlink-p)
            #'epi-test-ledger-io--wave3-unexpected-mutation)
           ((symbol-function 'file-remote-p)
            #'epi-test-ledger-io--wave3-unexpected-mutation)
           ((symbol-function 'file-truename)
            #'epi-test-ledger-io--wave3-unexpected-mutation)
           ((symbol-function 'file-attributes)
            #'epi-test-ledger-io--wave3-unexpected-mutation)
           ((symbol-function 'file-directory-p)
            #'epi-test-ledger-io--wave3-unexpected-mutation)
           ((symbol-function 'file-regular-p)
            #'epi-test-ledger-io--wave3-unexpected-mutation)
           ((symbol-function 'make-directory)
            #'epi-test-ledger-io--wave3-unexpected-mutation)
           ((symbol-function 'set-file-modes)
            #'epi-test-ledger-io--wave3-unexpected-mutation)
           ((symbol-function 'write-region)
            #'epi-test-ledger-io--wave3-unexpected-mutation)
           ((symbol-function 'insert-file-contents)
            #'epi-test-ledger-io--wave3-unexpected-mutation)
           ((symbol-function 'insert-file-contents-literally)
            #'epi-test-ledger-io--wave3-unexpected-mutation)
           ((symbol-function 'add-name-to-file)
            #'epi-test-ledger-io--wave3-unexpected-mutation)
           ((symbol-function 'rename-file)
            #'epi-test-ledger-io--wave3-unexpected-mutation)
           ((symbol-function 'delete-file)
            #'epi-test-ledger-io--wave3-unexpected-mutation))
        (funcall function)))))

(defun epi-test-ledger-io--wave3-copy-value (value)
  "Recursively copy VALUE, including every mutable string."
  (cond
   ((stringp value) (copy-sequence value))
   ((consp value)
    (cons (epi-test-ledger-io--wave3-copy-value (car value))
          (epi-test-ledger-io--wave3-copy-value (cdr value))))
   ((vectorp value)
    (apply #'vector
           (mapcar #'epi-test-ledger-io--wave3-copy-value value)))
   (t value)))

(defun epi-test-ledger-io--wave3-copy-draft (draft)
  "Return a caller-owned deep mutable copy of DRAFT."
  (make-epi-draft
   :id (epi-test-ledger-io--wave3-copy-value (epi-draft-id draft))
   :type (epi-draft-type draft)
   :at (epi-test-ledger-io--wave3-copy-value (epi-draft-at draft))
   :parent (epi-test-ledger-io--wave3-copy-value (epi-draft-parent draft))
   :target (epi-test-ledger-io--wave3-copy-value (epi-draft-target draft))
   :turn (epi-test-ledger-io--wave3-copy-value (epi-draft-turn draft))
   :operation
   (epi-test-ledger-io--wave3-copy-value (epi-draft-operation draft))
   :payload
   (epi-test-ledger-io--wave3-copy-value (epi-draft-payload draft))))

(defun epi-test-ledger-io--wave3-mutate-string (value)
  "Mutate nonempty string VALUE in place without changing its length."
  (when (and (stringp value) (> (length value) 0))
    (aset value 0 (if (= (aref value 0) ?X) ?Y ?X))))

(defun epi-test-ledger-io--wave3-mutate-value (value)
  "Mutate every mutable string reachable through caller VALUE."
  (cond
   ((stringp value)
    (epi-test-ledger-io--wave3-mutate-string value))
   ((consp value)
    (epi-test-ledger-io--wave3-mutate-value (car value))
    (epi-test-ledger-io--wave3-mutate-value (cdr value)))
   ((vectorp value)
    (seq-doseq (item value)
      (epi-test-ledger-io--wave3-mutate-value item)))))

(defun epi-test-ledger-io--wave3-mutate-draft (draft)
  "Destroy caller DRAFT fields after create has promised ownership."
  (dolist (value (list (epi-draft-id draft)
                       (epi-draft-at draft)
                       (epi-draft-parent draft)
                       (epi-draft-target draft)
                       (epi-draft-turn draft)
                       (epi-draft-operation draft)
                       (epi-draft-payload draft)))
    (epi-test-ledger-io--wave3-mutate-value value))
  (setf (epi-draft-type draft) nil
        (epi-draft-payload draft) nil))

(defun epi-test-ledger-io--wave3-identity-core (identity)
  "Return IDENTITY without its path spelling."
  (let ((copy (copy-sequence identity)))
    (plist-put copy :path nil)
    copy))

(defun epi-test-ledger-io--wave3-device-inode (identity)
  "Return the device and inode authority from file IDENTITY."
  (list :device (plist-get identity :device)
        :inode (plist-get identity :inode)))

(ert-deftest epi-ledger-create-publishes-header-and-session-info-together ()
  (should (fboundp 'epi-ledger-create))
  (should (fboundp 'epi-ledger--acquire-lock))
  (should (boundp 'epi-ledger--publish-function))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave3-path root))
           (lock-path (epi-test-ledger-io--wave3-lock-path path))
           (draft (epi-test-ledger-io--session-info))
           (expected (epi-test-ledger-io--document-bytes (list draft)))
           (real-acquire (symbol-function 'epi-ledger--acquire-lock))
           (real-writer epi-ledger--byte-writer)
           (real-flush epi-ledger--flush-function)
           (real-stat epi-ledger--stat-function)
           (real-read epi-ledger--read-function)
           (real-open (symbol-function 'epi-ledger-open))
           (real-publish epi-ledger--publish-function)
           (real-unlock epi-ledger--unlock-function)
           (real-add (symbol-function 'add-name-to-file))
           (real-delete (symbol-function 'delete-file))
           (epi--id-function (epi-test-ledger-io--wave3-id-source))
           trace temporary temp-writes add-calls acquired unlocked
           linked-authority final-opened ledger
           (phase 'before-prebarrier)
           (temp-read-count 0)
           (temp-open-count 0)
           (final-open-count 0)
           absence-rechecked lock-rechecked)
      (cl-labels
          ((record-once
            (event)
            (unless (memq event trace)
              (setq trace (append trace (list event))))))
        (cl-progv
            '(epi-ledger--create-prepublication-function
              epi-ledger--create-postpublication-function)
            (list
             (lambda ()
               (should (= 1 temp-open-count))
               (setq phase 'after-prebarrier)
               (record-once 'prebarrier))
             (lambda ()
               (should (eq phase 'after-cleanup))
               (record-once 'postbarrier)
               (setq phase 'after-postbarrier)))
          (cl-letf
              (((symbol-function 'epi-ledger--acquire-lock)
                (lambda (&rest arguments)
                  (let ((lock (apply real-acquire arguments)))
                    (setq acquired lock)
                    (record-once 'lock-acquired)
                    lock)))
               ((symbol-function 'epi-ledger-open)
                (lambda (target)
                  (let ((opened (funcall real-open target)))
                    (cond
                     ((epi-test-ledger-io--wave3-temporary-p target path)
                      (setq temp-open-count (1+ temp-open-count))
                      (record-once 'temp-cold-open))
                     ((equal target path)
                      (should (eq phase 'after-postbarrier))
                      (setq final-open-count (1+ final-open-count)
                            final-opened opened
                            phase 'after-final-open)
                      (record-once 'final-cold-open)))
                    opened)))
               ((symbol-function 'add-name-to-file)
                (lambda (source destination &optional overwrite)
                  (should (eq phase 'after-prebarrier))
                  (push (list source destination overwrite) add-calls)
                  (record-once 'hard-link-publish)
                  (funcall real-add source destination overwrite)))
               ((symbol-function 'copy-file)
                (lambda (&rest arguments)
                  (ert-fail
                   (format "create used copy publication: %S" arguments))))
               ((symbol-function 'rename-file)
                (lambda (&rest arguments)
                  (ert-fail
                   (format "create used rename publication: %S" arguments))))
               ((symbol-function 'delete-file)
                (lambda (target &optional trash)
                  (if (epi-test-ledger-io--wave3-temporary-p target path)
                      (progn
                        (should (eq phase 'after-hardlink))
                        (record-once 'source-unlink)
                        (prog1 (funcall real-delete target trash)
                          (setq phase 'after-cleanup)))
                    (funcall real-delete target trash)))))
            (let ((epi-ledger--byte-writer
                   (lambda (target bytes mode durablep)
                     (when (epi-test-ledger-io--wave3-temporary-p
                            target path)
                       (setq temporary target)
                       (push (list target bytes mode durablep) temp-writes)
                       (when (eq mode 'exclusive-create)
                         (record-once 'temp-exclusive-create)))
                     (funcall real-writer target bytes mode durablep)))
                  (epi-ledger--flush-function
                   (lambda (target)
                     (record-once 'flush)
                     (funcall real-flush target)))
                  (epi-ledger--stat-function
                   (lambda (target)
                     (when (and (eq phase 'after-prebarrier)
                                (equal target path)
                                (not absence-rechecked))
                       (setq absence-rechecked t)
                       (record-once 'absence-recheck))
                     (funcall real-stat target)))
                  (epi-ledger--read-function
                   (lambda (target begin end)
                     (let ((bytes (funcall real-read target begin end)))
                       (cond
                        ((epi-test-ledger-io--wave3-temporary-p target path)
                         (setq temp-read-count (1+ temp-read-count))
                         (should (= 0 begin))
                         (should (= (length expected) end))
                         (should (equal expected bytes))
                         (record-once 'exact-read))
                        ((and (eq phase 'after-prebarrier)
                              (equal target lock-path)
                              (not lock-rechecked))
                         (setq lock-rechecked t)
                         (record-once 'lock-recheck)))
                       bytes)))
                  (epi-ledger--publish-function
                   (lambda (source destination)
                     (should (equal temporary source))
                     (should (equal path destination))
                     (funcall real-publish source destination)
                     (let ((source-identity
                            (epi-ledger--stat-local-file source))
                           (destination-identity
                            (epi-ledger--stat-local-file destination)))
                       (should source-identity)
                       (should destination-identity)
                       (setq linked-authority
                             (epi-test-ledger-io--wave3-device-inode
                              source-identity))
                       (should
                        (equal linked-authority
                               (epi-test-ledger-io--wave3-device-inode
                                destination-identity))))
                     (setq phase 'after-hardlink)))
                  (epi-ledger--unlock-function
                   (lambda (lock)
                     (should (eq phase 'after-final-open))
                     (should final-opened)
                     (setq unlocked lock)
                     (record-once 'unlock)
                     (prog1 (funcall real-unlock lock)
                       (setq phase 'after-unlock)))))
              (setq ledger
                    (epi-test-ledger-io--wave3-create
                     path :initial-drafts (vector draft)))))))
      (setq temp-writes (nreverse temp-writes)
            add-calls (nreverse add-calls))
      (should acquired)
      (should (eq acquired unlocked))
      (should (eq ledger final-opened))
      (should
       (equal '(lock-acquired temp-exclusive-create flush exact-read
                              temp-cold-open prebarrier absence-recheck
                              lock-recheck hard-link-publish source-unlink
                              postbarrier final-cold-open unlock)
              trace))
      (should (= 2 (length temp-writes)))
      (pcase-let ((`(,target ,bytes ,mode ,durablep) (car temp-writes)))
        (should (equal temporary target))
        (should (equal expected bytes))
        (should (eq 'exclusive-create mode))
        (should-not durablep))
      (pcase-let ((`(,target ,bytes ,mode ,durablep) (cadr temp-writes)))
        (should (equal temporary target))
        (should (equal "" bytes))
        (should (eq 'append mode))
        (should durablep))
      (should (= 1 temp-read-count))
      (should (= 1 temp-open-count))
      (should (= 1 final-open-count))
      (should
       (equal (list (list temporary path nil)) add-calls))
      (should (equal (file-name-directory temporary)
                     (file-name-directory path)))
      (should (equal expected
                     (epi-test-ledger-io--literal-file-bytes path)))
      (should
       (equal linked-authority
              (epi-test-ledger-io--wave3-device-inode
               (epi-ledger--stat-local-file path))))
      (epi-test-ledger-io--wave3-assert-single-session ledger)
      (epi-test-ledger-io--wave3-assert-single-session
       (epi-ledger-open path))
      (should (= #o600 (epi-test-ledger-io--permission-bits path)))
      (should-not (file-exists-p lock-path))
      (should-not (epi-test-ledger-io--wave3-temporaries path))))
  ;; Locate all three destination-absence checks relative to lock acquisition,
  ;; the prepublication barrier, and publication entry.
  (epi-test-with-temporary-root (root)
    (let* ((path
            (epi-test-ledger-io--wave3-path root "three-stats.org"))
           (real-stat epi-ledger--stat-function)
           (real-acquire (symbol-function 'epi-ledger--acquire-lock))
           (real-publish epi-ledger--publish-function)
           (epi--id-function (epi-test-ledger-io--wave3-id-source))
           (before-publish t)
           (destination-stat-count 0)
           events ledger)
      (cl-progv
          '(epi-ledger--create-prepublication-function
            epi-ledger--create-postpublication-function)
          (list (lambda () (push 'prepublication-barrier events)) #'ignore)
        (cl-letf
            (((symbol-function 'epi-ledger--acquire-lock)
              (lambda (&rest arguments)
                (push 'acquire-entry events)
                (prog1 (apply real-acquire arguments)
                  (push 'acquire-return events)))))
          (let ((epi-ledger--stat-function
                 (lambda (target)
                   (when (and before-publish (equal target path))
                     (setq destination-stat-count
                           (1+ destination-stat-count))
                     (push (intern
                            (format "destination-stat-%d"
                                    destination-stat-count))
                           events))
                   (funcall real-stat target)))
                (epi-ledger--publish-function
                 (lambda (source destination)
                   (push 'publish-entry events)
                   (should (= 3 destination-stat-count))
                   (setq before-publish nil)
                   (funcall real-publish source destination))))
            (setq ledger (epi-test-ledger-io--wave3-create path)))))
      (should (epi-ledger-p ledger))
      (should
       (equal '(destination-stat-1
                acquire-entry acquire-return destination-stat-2
                prepublication-barrier destination-stat-3 publish-entry)
              (reverse events)))
      (epi-test-ledger-io--wave3-assert-single-session ledger))))

(ert-deftest epi-ledger-create-returns-a-handle-for-the-final-path ()
  (should (fboundp 'epi-ledger-create))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave3-path root))
           (epi--id-function (epi-test-ledger-io--wave3-id-source))
           (real-open (symbol-function 'epi-ledger-open))
           (real-unlock epi-ledger--unlock-function)
           internal-final-opened ledger unlocked)
      (cl-letf
          (((symbol-function 'epi-ledger-open)
            (lambda (target)
              (let ((opened (funcall real-open target)))
                (when (equal target path)
                  (should-not internal-final-opened)
                  (setq internal-final-opened opened))
                opened))))
        (let ((epi-ledger--unlock-function
               (lambda (lock)
                 (should internal-final-opened)
                 (setq unlocked t)
                 (funcall real-unlock lock))))
          (setq ledger (epi-test-ledger-io--wave3-create path))))
      (should internal-final-opened)
      (should unlocked)
      (should (eq ledger internal-final-opened))
      (let* ((canonical (file-truename path))
           (actual-identity (epi-ledger--stat-local-file canonical))
           (reopened (epi-ledger-open canonical)))
        (should (equal canonical (epi-ledger-path ledger)))
        (should-not (string-match-p "\\.epi-tmp-" (epi-ledger-path ledger)))
        (should (equal actual-identity (epi-ledger-file-identity ledger)))
        (should (= (plist-get actual-identity :size)
                   (epi-ledger-validated-end-offset ledger)))
        (should-not (eq ledger reopened))
        (should (equal (epi-test-ledger-io--wave3-projection reopened)
                       (epi-test-ledger-io--wave3-projection ledger)))
        (epi-test-ledger-io--wave3-assert-single-session ledger)
        (epi-test-ledger-io--wave3-assert-single-session reopened)))))

(ert-deftest epi-ledger-create-rejects-empty-nonfirst-duplicate-session-info ()
  (should (fboundp 'epi-ledger-create))
  (epi-test-with-temporary-root (root)
    (let* ((duplicate
            (epi-test-ledger-io--wave3-session-info-with-id
             "10000000-0000-4000-8000-000000000099"))
           (cases
            (list
             (list "empty.org" nil 'empty-draft-batch)
             (list "nonfirst.org"
                   (vector (epi-test-ledger-io--operation-started)
                           (epi-test-ledger-io--session-info))
                   'missing-session-info)
             (list "duplicate.org"
                   (vector (epi-test-ledger-io--session-info) duplicate)
                   'duplicate-session-info))))
      (dolist (case cases)
        (pcase-let ((`(,leaf ,drafts ,code) case))
          (let* ((path (epi-test-ledger-io--wave3-path root leaf))
                 (condition
                  (should-error
                   (epi-test-ledger-io--wave3-call-with-forbidden-io
                    (lambda ()
                      (epi-test-ledger-io--wave3-create
                       path :initial-drafts drafts)))
                   :type 'epi-ledger-format-error)))
            (should (eq code
                        (epi-test-ledger-io--condition-code condition)))
            (should-not (file-exists-p path))
            (should-not (file-exists-p
                         (epi-test-ledger-io--wave3-lock-path path)))
            (should-not (epi-test-ledger-io--wave3-temporaries path))))))))

(ert-deftest epi-ledger-create-rejects-header-payload-session-mismatch-before-io ()
  (should (fboundp 'epi-ledger-create))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave3-path root))
           (draft (epi-test-ledger-io--wave3-mismatched-session-info))
           (condition
            (should-error
             (epi-test-ledger-io--wave3-call-with-forbidden-io
              (lambda ()
                (epi-test-ledger-io--wave3-create
                 path :initial-drafts (vector draft))))
             :type 'epi-ledger-format-error)))
      (should (eq 'session-id-mismatch
                  (epi-test-ledger-io--condition-code condition)))
      (should-not (file-exists-p path))
      (should-not (file-exists-p
                   (epi-test-ledger-io--wave3-lock-path path)))
      (should-not (epi-test-ledger-io--wave3-temporaries path)))))

(ert-deftest epi-ledger-create-refuses-an-existing-destination-without-changing-it ()
  (should (fboundp 'epi-ledger-create))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave3-path root))
           (winner (encode-coding-string "existing-winner" 'us-ascii t))
           before-identity)
      (epi-ledger--write-bytes path winner 'exclusive-create t)
      (setq before-identity (epi-ledger--stat-local-file path))
      (let ((epi--id-function (epi-test-ledger-io--wave3-id-source)))
        (let ((condition
               (should-error
                (epi-test-ledger-io--wave3-create path)
                :type 'epi-ledger-conflict)))
          (should (eq 'destination-exists
                      (epi-test-ledger-io--condition-code condition)))))
      (should (equal winner
                     (epi-test-ledger-io--literal-file-bytes path)))
      (should (equal before-identity (epi-ledger--stat-local-file path)))
      (should-not (file-exists-p
                   (epi-test-ledger-io--wave3-lock-path path)))
      (should-not (epi-test-ledger-io--wave3-temporaries path)))))

(ert-deftest epi-ledger-create-no-clobber-collision-preserves-the-winner ()
  (should (fboundp 'epi-ledger-create))
  (should (boundp 'epi-ledger--publish-function))
  (epi-test-with-temporary-root (root)
    (dolist (stage '(after-lock-create after-prebarrier at-hard-link))
      (let* ((path
              (epi-test-ledger-io--wave3-path
               root (format "%s.org" stage)))
             (winner
              (encode-coding-string
               (format "winner-created-%s" stage) 'utf-8-unix))
             (real-lock-create epi-ledger--lock-create-function)
             (real-add (symbol-function 'add-name-to-file))
             (epi--id-function (epi-test-ledger-io--wave3-id-source))
             winner-identity
             (primitive-calls 0))
        (cl-labels
            ((install-winner
              ()
              (unless winner-identity
                (epi-ledger--write-bytes
                 path winner 'exclusive-create t)
                (setq winner-identity
                      (epi-ledger--stat-local-file path)))))
          (cl-progv
              '(epi-ledger--create-prepublication-function
                epi-ledger--create-postpublication-function)
              (list
               (lambda ()
                 (when (eq stage 'after-prebarrier)
                   (install-winner)))
               #'ignore)
            (cl-letf
                (((symbol-function 'add-name-to-file)
                  (lambda (source destination &optional overwrite)
                    (setq primitive-calls (1+ primitive-calls))
                    (should-not overwrite)
                    (should (equal (file-name-directory source)
                                   (file-name-directory destination)))
                    (when (eq stage 'at-hard-link)
                      (install-winner))
                    (funcall real-add source destination overwrite)))
                 ((symbol-function 'rename-file)
                  (lambda (&rest arguments)
                    (ert-fail
                     (format "create used rename publication: %S"
                             arguments)))))
              (let ((epi-ledger--lock-create-function
                     (lambda (lock-path token-bytes)
                       (let ((identity
                              (funcall real-lock-create
                                       lock-path token-bytes)))
                         (when (eq stage 'after-lock-create)
                           (install-winner))
                         identity))))
                (let ((condition
                       (should-error
                        (epi-test-ledger-io--wave3-create path)
                        :type 'epi-ledger-conflict)))
                  (should
                   (eq 'destination-exists
                       (epi-test-ledger-io--condition-code condition))))))))
        (should winner-identity)
        (should (= (if (eq stage 'at-hard-link) 1 0) primitive-calls))
        (should (equal winner
                       (epi-test-ledger-io--literal-file-bytes path)))
        (should (equal winner-identity
                       (epi-ledger--stat-local-file path)))
        (should-not
         (file-exists-p (epi-test-ledger-io--wave3-lock-path path)))
        (dolist (temporary (epi-test-ledger-io--wave3-temporaries path))
          (should (epi-test-ledger-io--wave3-temp-complete-p temporary))))))
  ;; A raw publication failure with a different file at the destination is a
  ;; no-clobber collision, not evidence that our temporary was published.
  (epi-test-with-temporary-root (root)
    (let* ((path
            (epi-test-ledger-io--wave3-path
             root "raw-different-winner.org"))
           (lock-path (epi-test-ledger-io--wave3-lock-path path))
           (winner
            (encode-coding-string "independent-winner" 'utf-8-unix t))
           (epi--id-function (epi-test-ledger-io--wave3-id-source))
           source source-identity winner-identity condition)
      (let ((epi-ledger--publish-function
             (lambda (temporary destination)
               (setq source temporary
                     source-identity
                     (epi-ledger--stat-local-file temporary))
               (epi-ledger--write-bytes
                destination winner 'exclusive-create t)
               (setq winner-identity
                     (epi-ledger--stat-local-file destination))
               (should-not
                (epi-ledger--same-file-object-p
                 source-identity winner-identity))
               (signal 'file-error '("raw different-winner ambiguity")))))
        (setq condition
              (should-error
               (epi-test-ledger-io--wave3-create path)
               :type 'epi-ledger-conflict)))
      (should (= 1 (length (cdr condition))))
      (let ((detail (epi-test-ledger-io--condition-detail condition)))
        (should (eq :code (car detail)))
        (should (eq 'destination-exists (plist-get detail :code)))
        (should-not (plist-get detail :published)))
      (should source)
      (should (equal winner
                     (epi-test-ledger-io--literal-file-bytes path)))
      (should (equal winner-identity
                     (epi-ledger--stat-local-file path)))
      (should-not (file-exists-p lock-path))
      (should (file-exists-p source))
      (should (epi-test-ledger-io--wave3-temp-complete-p source)))))

(ert-deftest epi-ledger-create-prepublication-failure-leaves-no-normal-ledger ()
  (should (fboundp 'epi-ledger-create))
  (should (boundp 'epi-ledger--create-prepublication-function))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave3-path root))
           (lock-path (epi-test-ledger-io--wave3-lock-path path))
           (epi--id-function (epi-test-ledger-io--wave3-id-source))
           observed)
      (cl-progv
          '(epi-ledger--create-prepublication-function
            epi-ledger--create-postpublication-function)
          (list
           (lambda ()
             (let ((temporaries
                    (epi-test-ledger-io--wave3-temporaries path)))
               (setq observed
                     (list :destination-absent (not (file-exists-p path))
                           :lock-present (file-exists-p lock-path)
                           :temporaries temporaries
                           :temporary-complete
                           (and (= 1 (length temporaries))
                                (epi-test-ledger-io--wave3-temp-complete-p
                                 (car temporaries)))))
               (signal 'epi-test-ledger-io-wave3-stop nil)))
           #'ignore)
        (let ((epi-ledger--publish-function
               (lambda (&rest arguments)
                 (ert-fail
                  (format "prepublication failure published: %S"
                          arguments)))))
          (should-error
           (epi-test-ledger-io--wave3-create path)
           :type 'epi-test-ledger-io-wave3-stop)))
      (should observed)
      (should (plist-get observed :destination-absent))
      (should (plist-get observed :lock-present))
      (should (= 1 (length (plist-get observed :temporaries))))
      (should (plist-get observed :temporary-complete))
      (should-not (file-exists-p path))
      (should-not (file-exists-p lock-path))
      (let ((survivors (epi-test-ledger-io--wave3-temporaries path)))
        (should (<= (length survivors) 1))
        (dolist (temporary survivors)
          (should (epi-test-ledger-io--wave3-temp-complete-p temporary)))))))

(ert-deftest epi-ledger-create-postpublication-failure-leaves-reopenable-ledger ()
  (should (fboundp 'epi-ledger-create))
  (should (boundp 'epi-ledger--create-postpublication-function))
  (epi-test-with-temporary-root (root)
    ;; The test barrier is after hard-link publication and source cleanup.
    (let* ((path (epi-test-ledger-io--wave3-path root "barrier.org"))
           (lock-path (epi-test-ledger-io--wave3-lock-path path))
           (epi--id-function (epi-test-ledger-io--wave3-id-source))
           observed)
      (cl-progv
          '(epi-ledger--create-prepublication-function
            epi-ledger--create-postpublication-function)
          (list
           #'ignore
           (lambda ()
             (let ((ledger (epi-ledger-open path)))
               (setq observed
                     (list :destination-present (file-exists-p path)
                           :lock-present (file-exists-p lock-path)
                           :temporary-count
                           (length
                            (epi-test-ledger-io--wave3-temporaries path))
                           :projection
                           (epi-test-ledger-io--wave3-projection ledger)))
               (signal 'epi-test-ledger-io-wave3-stop nil))))
        (should-error
         (epi-test-ledger-io--wave3-create path)
         :type 'epi-test-ledger-io-wave3-stop))
      (should observed)
      (should (plist-get observed :destination-present))
      (should (plist-get observed :lock-present))
      (should (= 0 (plist-get observed :temporary-count)))
      (should (equal (plist-get observed :projection)
                     (epi-test-ledger-io--wave3-projection
                      (epi-ledger-open path))))
      (should-not (file-exists-p lock-path)))
    ;; Failure to unlink the hard-link source is postpublication cleanup.
    (let* ((path (epi-test-ledger-io--wave3-path root "cleanup.org"))
           (real-delete (symbol-function 'delete-file))
           (epi--id-function (epi-test-ledger-io--wave3-id-source))
           source condition)
      (cl-letf
          (((symbol-function 'delete-file)
            (lambda (target &optional trash)
              (if (epi-test-ledger-io--wave3-temporary-p target path)
                  (progn
                    (setq source target)
                    (signal 'file-error '("injected source cleanup")))
                (funcall real-delete target trash)))))
        (setq condition
              (should-error
               (epi-test-ledger-io--wave3-create path)
               :type 'epi-ledger-conflict)))
      (should (eq 'storage-publication-failed
                  (epi-test-ledger-io--condition-code condition)))
      (should (eq t
                  (plist-get
                   (epi-test-ledger-io--condition-detail condition)
                   :published)))
      (should (file-exists-p path))
      (should (file-exists-p source))
      (should
       (equal (epi-test-ledger-io--wave3-identity-core
               (epi-ledger--stat-local-file source))
              (epi-test-ledger-io--wave3-identity-core
               (epi-ledger--stat-local-file path))))
      (epi-test-ledger-io--wave3-assert-single-session
       (epi-ledger-open path)))
    ;; An arbitrary storage failure during exact release is equally uncertain.
    ;; The published ledger and unchanged owned lock remain recovery evidence.
    (let* ((path (epi-test-ledger-io--wave3-path root "unlock-storage.org"))
           (lock-path (epi-test-ledger-io--wave3-lock-path path))
           (epi--id-function (epi-test-ledger-io--wave3-id-source))
           before-identity before-bytes condition
           (unlock-calls 0))
      (let ((epi-ledger--unlock-function
             (lambda (_lock)
               (setq unlock-calls (1+ unlock-calls)
                     before-identity (epi-ledger--stat-local-file lock-path)
                     before-bytes
                     (epi-test-ledger-io--literal-file-bytes lock-path))
               (signal 'file-error '("injected unlock storage failure")))))
        (setq condition
              (should-error
               (epi-test-ledger-io--wave3-create path)
               :type 'epi-ledger-conflict)))
      (should (= 1 unlock-calls))
      (should (eq 'unlock-uncertain
                  (epi-test-ledger-io--condition-code condition)))
      (should (file-exists-p path))
      (should (file-exists-p lock-path))
      (should (equal before-bytes
                     (epi-test-ledger-io--literal-file-bytes lock-path)))
      (should (equal before-identity
                     (epi-ledger--stat-local-file lock-path)))
      (should-not (epi-test-ledger-io--wave3-temporaries path))
      (epi-test-ledger-io--wave3-assert-single-session
       (epi-ledger-open path)))
    ;; Exact-token replacement at unlock is reported as postpublication
    ;; uncertainty; the final ledger and replacement evidence both survive.
    (let* ((path (epi-test-ledger-io--wave3-path root "unlock.org"))
           (lock-path (epi-test-ledger-io--wave3-lock-path path))
           (replacement-path (concat lock-path ".replacement"))
           (real-unlock epi-ledger--unlock-function)
           (epi--id-function (epi-test-ledger-io--wave3-id-source))
           replacement-identity replacement-bytes condition)
      (let ((epi-ledger--unlock-function
             (lambda (lock)
               (setq replacement-bytes
                     (epi-test-ledger-io--literal-file-bytes lock-path))
               (epi-ledger--write-bytes
                replacement-path replacement-bytes 'exclusive-create t)
               (should-not
                (= (plist-get (epi-ledger--stat-local-file lock-path) :inode)
                   (plist-get
                    (epi-ledger--stat-local-file replacement-path) :inode)))
               (delete-file lock-path)
               (add-name-to-file replacement-path lock-path nil)
               (delete-file replacement-path)
               (setq replacement-identity
                     (epi-ledger--stat-local-file lock-path))
               (funcall real-unlock lock))))
        (setq condition
              (should-error
               (epi-test-ledger-io--wave3-create path)
               :type 'epi-ledger-conflict)))
      (should (eq 'unlock-uncertain
                  (epi-test-ledger-io--condition-code condition)))
      (should (file-exists-p path))
      (should (file-exists-p lock-path))
      (should (equal replacement-bytes
                     (epi-test-ledger-io--literal-file-bytes lock-path)))
      (should (equal replacement-identity
                     (epi-ledger--stat-local-file lock-path)))
      (epi-test-ledger-io--wave3-assert-single-session
       (epi-ledger-open path))))
  ;; A raw failure after establishing the hard link is published ambiguity.
  ;; Its detail also governs cleanup when exact lock release then fails.
  (epi-test-with-temporary-root (root)
    (dolist (unlock-fails '(nil t))
      (let* ((path
              (epi-test-ledger-io--wave3-path
               root
               (if unlock-fails
                   "raw-postlink-unlock-fails.org"
                 "raw-postlink.org")))
             (lock-path (epi-test-ledger-io--wave3-lock-path path))
             (real-unlock epi-ledger--unlock-function)
             (epi--id-function (epi-test-ledger-io--wave3-id-source))
             source linked-identity condition
             (publish-calls 0)
             (unlock-calls 0))
        (let ((epi-ledger--publish-function
               (lambda (temporary destination)
                 (setq publish-calls (1+ publish-calls)
                       source temporary)
                 (add-name-to-file temporary destination nil)
                 (let ((source-identity
                        (epi-ledger--stat-local-file temporary))
                       (destination-identity
                        (epi-ledger--stat-local-file destination)))
                   (should
                    (epi-ledger--same-file-object-p
                     source-identity destination-identity))
                   (setq linked-identity destination-identity))
                 (signal 'file-error '("raw post-link ambiguity"))))
              (epi-ledger--unlock-function
               (lambda (lock)
                 (setq unlock-calls (1+ unlock-calls))
                 (if unlock-fails
                     (signal 'file-error '("postpublication unlock failed"))
                   (funcall real-unlock lock)))))
          (setq condition
                (should-error
                 (epi-test-ledger-io--wave3-create path)
                 :type 'epi-ledger-conflict)))
        (should (= 1 publish-calls))
        (should (= 1 unlock-calls))
        (should (= 1 (length (cdr condition))))
        (let ((detail (epi-test-ledger-io--condition-detail condition)))
          (should (eq :code (car detail)))
          (if unlock-fails
              (should (eq 'unlock-uncertain (plist-get detail :code)))
            (should
             (eq 'storage-publication-failed
                 (plist-get detail :code)))
            (should (eq t (plist-get detail :published)))))
        (should source)
        (should (file-exists-p path))
        (should (file-exists-p source))
        (should
         (epi-ledger--same-file-object-p
          linked-identity (epi-ledger--stat-local-file path)))
        (should
         (epi-ledger--same-file-object-p
          linked-identity (epi-ledger--stat-local-file source)))
        (if unlock-fails
            (should (file-exists-p lock-path))
          (should-not (file-exists-p lock-path)))
        (epi-test-ledger-io--wave3-assert-single-session
         (epi-ledger-open path))
        (should (epi-test-ledger-io--wave3-temp-complete-p source))))))

(ert-deftest epi-ledger-create-lock-remains-absent-bound-through-publication ()
  (should (fboundp 'epi-ledger-create))
  (should (fboundp 'epi-ledger--acquire-lock))
  (should (fboundp 'epi-ledger--decode-lock-token))
  (epi-test-with-temporary-root (root)
    ;; The exact opaque lock returned by acquisition must reach unlock by `eq'.
    (let* ((path (epi-test-ledger-io--wave3-path root "normal.org"))
           (lock-path (epi-test-ledger-io--wave3-lock-path path))
           (real-acquire (symbol-function 'epi-ledger--acquire-lock))
           (real-unlock epi-ledger--unlock-function)
           (real-publish epi-ledger--publish-function)
           (epi--id-function (epi-test-ledger-io--wave3-id-source))
           acquired unlocked token)
      (cl-letf
          (((symbol-function 'epi-ledger--acquire-lock)
            (lambda (&rest arguments)
              (setq acquired (apply real-acquire arguments)))))
        (let ((epi-ledger--publish-function
               (lambda (temporary destination)
                 (setq token
                       (epi-ledger--decode-lock-token
                        (epi-test-ledger-io--literal-file-bytes lock-path)))
                 (funcall real-publish temporary destination)))
              (epi-ledger--unlock-function
               (lambda (lock)
                 (setq unlocked lock)
                 (funcall real-unlock lock))))
          (epi-test-ledger-io--wave3-create path)))
      (should acquired)
      (should (eq acquired unlocked))
      (should (equal path
                     (epi-test-ledger-io--wave3-token-value
                      token "ledger_path")))
      (should (equal "absent"
                     (epi-test-ledger-io--wave3-token-value
                      token "expected_file")))
      (should (equal "0"
                     (epi-test-ledger-io--wave3-token-value
                      token "expected_end")))
      (should (eq epi-json-null
                  (epi-test-ledger-io--wave3-token-value
                   token "expected_head")))
      (should-not (file-exists-p lock-path)))
    ;; Byte equality is insufficient: a replacement inode before publication
    ;; invalidates ownership and must never be removed as cleanup.
    (let* ((path (epi-test-ledger-io--wave3-path root "replacement.org"))
           (lock-path (epi-test-ledger-io--wave3-lock-path path))
           (replacement-path (concat lock-path ".replacement"))
           (epi--id-function (epi-test-ledger-io--wave3-id-source))
           original-identity replacement-identity token-bytes condition)
      (cl-progv
          '(epi-ledger--create-prepublication-function
            epi-ledger--create-postpublication-function)
          (list
           (lambda ()
             (setq token-bytes
                   (epi-test-ledger-io--literal-file-bytes lock-path)
                   original-identity
                   (epi-ledger--stat-local-file lock-path))
             (epi-ledger--write-bytes
              replacement-path token-bytes 'exclusive-create t)
             (should-not
              (= (plist-get original-identity :inode)
                 (plist-get
                  (epi-ledger--stat-local-file replacement-path) :inode)))
             (delete-file lock-path)
             (add-name-to-file replacement-path lock-path nil)
             (delete-file replacement-path)
             (setq replacement-identity
                   (epi-ledger--stat-local-file lock-path)))
           #'ignore)
        (let ((epi-ledger--publish-function
               (lambda (&rest arguments)
                 (ert-fail
                  (format "changed lock allowed publication: %S"
                          arguments)))))
          (setq condition
                (should-error
                 (epi-test-ledger-io--wave3-create path)
                 :type 'epi-ledger-conflict))))
      (should (eq 'lock-token-changed
                  (epi-test-ledger-io--condition-code condition)))
      (should-not (file-exists-p path))
      (should (file-exists-p lock-path))
      (should (equal token-bytes
                     (epi-test-ledger-io--literal-file-bytes lock-path)))
      (should (equal replacement-identity
                     (epi-ledger--stat-local-file lock-path)))
      (should-not
       (= (plist-get original-identity :inode)
          (plist-get replacement-identity :inode)))
      (dolist (temporary (epi-test-ledger-io--wave3-temporaries path))
        (should (epi-test-ledger-io--wave3-temp-complete-p temporary))))
    ;; Replacing the lock during the source-identity stat closes the last
    ;; callback-bearing interval before the final lock proof and publication.
    (let* ((path
            (epi-test-ledger-io--wave3-path
             root "source-stat-lock-replacement.org"))
           (lock-path (epi-test-ledger-io--wave3-lock-path path))
           (replacement-path (concat lock-path ".replacement"))
           (real-stat epi-ledger--stat-function)
           (epi--id-function (epi-test-ledger-io--wave3-id-source))
           original-identity replacement-identity token-bytes source condition
           (source-stat-ready nil)
           (source-stat-calls 0)
           (publish-calls 0))
      (cl-progv
          '(epi-ledger--create-prepublication-function
            epi-ledger--create-postpublication-function)
          (list (lambda () (setq source-stat-ready t)) #'ignore)
        (let ((epi-ledger--stat-function
               (lambda (target)
                 (when (and source-stat-ready
                            (epi-test-ledger-io--wave3-temporary-p
                             target path))
                   (setq source-stat-calls (1+ source-stat-calls)
                         source target
                         token-bytes
                         (epi-test-ledger-io--literal-file-bytes lock-path)
                         original-identity
                         (epi-ledger--stat-local-file lock-path))
                   (epi-ledger--write-bytes
                    replacement-path token-bytes 'exclusive-create t)
                   (should-not
                    (= (plist-get original-identity :inode)
                       (plist-get
                        (epi-ledger--stat-local-file replacement-path)
                        :inode)))
                   (delete-file lock-path)
                   (add-name-to-file replacement-path lock-path nil)
                   (delete-file replacement-path)
                   (setq replacement-identity
                         (epi-ledger--stat-local-file lock-path)))
                 (funcall real-stat target)))
              (epi-ledger--publish-function
               (lambda (&rest arguments)
                 (setq publish-calls (1+ publish-calls))
                 (ert-fail
                  (format "source-stat lock replacement published: %S"
                          arguments)))))
          (setq condition
                (should-error
                 (epi-test-ledger-io--wave3-create path)
                 :type 'epi-ledger-conflict))))
      (should source-stat-ready)
      (should (= 1 source-stat-calls))
      (should (= 0 publish-calls))
      (should (eq 'lock-token-changed
                  (epi-test-ledger-io--condition-code condition)))
      (should-not (file-exists-p path))
      (should (file-exists-p source))
      (should (epi-test-ledger-io--wave3-temp-complete-p source))
      (should (file-exists-p lock-path))
      (should (equal token-bytes
                     (epi-test-ledger-io--literal-file-bytes lock-path)))
      (should (equal replacement-identity
                     (epi-ledger--stat-local-file lock-path)))
      (should-not
       (= (plist-get original-identity :inode)
          (plist-get replacement-identity :inode))))))

(ert-deftest epi-ledger-create-owns-and-caps-complete-initial-batch-before-io ()
  (should (fboundp 'epi-ledger-create))
  (should (fboundp 'epi-ledger--acquire-lock))
  ;; Both accepted collection shapes, every caller string, every draft, and
  ;; every payload are owned before the path resolver enters parent I/O.  A
  ;; complete multi-record history remains byte exact and in physical input
  ;; order after caller mutation at that first storage boundary.
  (epi-test-with-temporary-root (root)
    (dolist (shape '(vector list))
      (let* ((original-path
              (epi-test-ledger-io--wave3-path
               root (format "owned-%s.org" shape)))
             (caller-path (copy-sequence original-path))
             (session-id (copy-sequence epi-test-ledger-io--session-id))
             (created-at
              (copy-sequence epi-test-ledger-io--wave3-created-at))
             (project-root
              (copy-sequence epi-test-ledger-io--wave3-project-root))
             (expected-session-id (copy-sequence session-id))
             (expected-created-at (copy-sequence created-at))
             (expected-project-root (copy-sequence project-root))
             (drafts
              (mapcar #'epi-test-ledger-io--wave3-copy-draft
                      (epi-test-ledger-io--full-drafts)))
             (_payload-session
              (setcdr (assoc "session_id" (epi-draft-payload (car drafts)))
                      (copy-sequence session-id)))
             (collection
              (if (eq shape 'vector) (vconcat drafts) (copy-sequence drafts)))
             (expected (epi-test-ledger-io--document-bytes drafts))
             (expected-ids
              (mapcar (lambda (draft) (copy-sequence (epi-draft-id draft)))
                      drafts))
             (expected-types (mapcar #'epi-draft-type drafts))
             (real-resolve
              (symbol-function 'epi-ledger--resolve-local-write-path))
             (real-acquire (symbol-function 'epi-ledger--acquire-lock))
             (real-open (symbol-function 'epi-ledger-open))
             (real-file-exists-p (symbol-function 'file-exists-p))
             (real-file-attributes (symbol-function 'file-attributes))
             (real-file-directory-p (symbol-function 'file-directory-p))
             (real-file-regular-p (symbol-function 'file-regular-p))
             (real-file-symlink-p (symbol-function 'file-symlink-p))
             (real-file-truename (symbol-function 'file-truename))
             (real-file-remote-p (symbol-function 'file-remote-p))
             (real-file-modes (symbol-function 'file-modes))
             (real-file-readable-p (symbol-function 'file-readable-p))
             (real-file-writable-p (symbol-function 'file-writable-p))
             (real-file-equal-p (symbol-function 'file-equal-p))
             (real-make-directory (symbol-function 'make-directory))
             (real-make-temp-file (symbol-function 'make-temp-file))
             (real-set-file-modes (symbol-function 'set-file-modes))
             (real-write-region (symbol-function 'write-region))
             (real-insert-file-contents
              (symbol-function 'insert-file-contents))
             (real-insert-file-contents-literally
              (symbol-function 'insert-file-contents-literally))
             (real-directory-files (symbol-function 'directory-files))
             (real-add-name-to-file (symbol-function 'add-name-to-file))
             (real-rename-file (symbol-function 'rename-file))
             (real-copy-file (symbol-function 'copy-file))
             (real-delete-file (symbol-function 'delete-file))
             (real-delete-directory (symbol-function 'delete-directory))
             (epi--id-function (epi-test-ledger-io--wave3-id-source))
             mutated ledger)
        (cl-labels
            ((cross-first-storage-boundary
              ()
              (unless mutated
                (setq mutated t)
                (mapc #'epi-test-ledger-io--wave3-mutate-string
                      (list caller-path session-id created-at project-root))
                (mapc #'epi-test-ledger-io--wave3-mutate-draft drafts)
                (if (vectorp collection)
                    (aset collection 0 nil)
                  (setcar collection nil))))
             (guard-storage-boundary
              (function)
              (lambda (&rest arguments)
                (cross-first-storage-boundary)
                (apply function arguments))))
          (let ((epi-ledger--byte-writer
                 (guard-storage-boundary epi-ledger--byte-writer))
                (epi-ledger--lock-create-function
                 (guard-storage-boundary
                  epi-ledger--lock-create-function))
                (epi-ledger--append-function
                 (guard-storage-boundary epi-ledger--append-function))
                (epi-ledger--flush-function
                 (guard-storage-boundary epi-ledger--flush-function))
                (epi-ledger--stat-function
                 (guard-storage-boundary epi-ledger--stat-function))
                (epi-ledger--read-function
                 (guard-storage-boundary epi-ledger--read-function))
                (epi-ledger--unlock-function
                 (guard-storage-boundary epi-ledger--unlock-function))
                (epi-ledger--publish-function
                 (guard-storage-boundary epi-ledger--publish-function)))
            (cl-letf
                (((symbol-function 'epi-ledger--resolve-local-write-path)
                  (guard-storage-boundary real-resolve))
                 ((symbol-function 'epi-ledger--acquire-lock)
                  (guard-storage-boundary real-acquire))
                 ((symbol-function 'epi-ledger-open)
                  (guard-storage-boundary real-open))
                 ((symbol-function 'file-exists-p)
                  (guard-storage-boundary real-file-exists-p))
                 ((symbol-function 'file-attributes)
                  (guard-storage-boundary real-file-attributes))
                 ((symbol-function 'file-directory-p)
                  (guard-storage-boundary real-file-directory-p))
                 ((symbol-function 'file-regular-p)
                  (guard-storage-boundary real-file-regular-p))
                 ((symbol-function 'file-symlink-p)
                  (guard-storage-boundary real-file-symlink-p))
                 ((symbol-function 'file-truename)
                  (guard-storage-boundary real-file-truename))
                 ((symbol-function 'file-remote-p)
                  (guard-storage-boundary real-file-remote-p))
                 ((symbol-function 'file-modes)
                  (guard-storage-boundary real-file-modes))
                 ((symbol-function 'file-readable-p)
                  (guard-storage-boundary real-file-readable-p))
                 ((symbol-function 'file-writable-p)
                  (guard-storage-boundary real-file-writable-p))
                 ((symbol-function 'file-equal-p)
                  (guard-storage-boundary real-file-equal-p))
                 ((symbol-function 'make-directory)
                  (guard-storage-boundary real-make-directory))
                 ((symbol-function 'make-temp-file)
                  (guard-storage-boundary real-make-temp-file))
                 ((symbol-function 'set-file-modes)
                  (guard-storage-boundary real-set-file-modes))
                 ((symbol-function 'write-region)
                  (guard-storage-boundary real-write-region))
                 ((symbol-function 'insert-file-contents)
                  (guard-storage-boundary real-insert-file-contents))
                 ((symbol-function 'insert-file-contents-literally)
                  (guard-storage-boundary
                   real-insert-file-contents-literally))
                 ((symbol-function 'directory-files)
                  (guard-storage-boundary real-directory-files))
                 ((symbol-function 'add-name-to-file)
                  (guard-storage-boundary real-add-name-to-file))
                 ((symbol-function 'rename-file)
                  (guard-storage-boundary real-rename-file))
                 ((symbol-function 'copy-file)
                  (guard-storage-boundary real-copy-file))
                 ((symbol-function 'delete-file)
                  (guard-storage-boundary real-delete-file))
                 ((symbol-function 'delete-directory)
                  (guard-storage-boundary real-delete-directory)))
              (setq ledger
                    (epi-test-ledger-io--wave3-create
                     caller-path
                     :session-id session-id
                     :created-at created-at
                     :project-root project-root
                     :initial-drafts collection)))))
        (should mutated)
        (should (equal original-path (epi-ledger-path ledger)))
        (should (equal expected
                       (epi-test-ledger-io--literal-file-bytes original-path)))
        (let ((header (epi-ledger-header ledger)))
          (should (equal expected-session-id
                         (epi-ledger-session-id ledger)))
          (should (equal expected-session-id
                         (epi-header-session-id header)))
          (should (equal expected-created-at
                         (epi-header-created-at header)))
          (should (equal expected-project-root
                         (epi-ledger-project-root ledger)))
          (should (equal expected-project-root
                         (epi-header-project-root header))))
        (let ((records (epi-ledger-records ledger)))
          (should (equal expected-ids
                         (mapcar #'epi-record-id (append records nil))))
          (should (equal expected-types
                         (mapcar #'epi-record-type (append records nil)))))
        (should
         (equal (epi-test-ledger-io--wave3-projection
                 (epi-ledger-open original-path))
                (epi-test-ledger-io--wave3-projection ledger))))))
  ;; Nil defaults are generated only after ownership, in physical input
  ;; order, and never mutate the caller's drafts.
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave3-path root "defaults.org"))
           (first (epi-test-ledger-io--session-info))
           (second (epi-test-ledger-io--operation-started))
           (_clear-first (setf (epi-draft-id first) nil
                               (epi-draft-at first) nil))
           (_clear-second (setf (epi-draft-id second) nil
                                (epi-draft-at second) nil))
           (record-ids
            '("51000000-0000-4000-8000-000000000001"
              "51000000-0000-4000-8000-000000000002"))
           (id-values
            (append record-ids
                    '("51000000-0000-4000-8000-000000000003"
                      "51000000-0000-4000-8000-000000000004")))
           (time-values
            (list (encode-time 0 0 12 22 7 2026 t)
                  (encode-time 1 0 12 22 7 2026 t)))
           (expected-times
            (mapcar
             (lambda (value)
               (format-time-string "%Y-%m-%dT%H:%M:%S.%9NZ" value t))
             time-values))
           trace ledger)
      (let ((epi--id-function
             (lambda ()
               (push 'id trace)
               (or (pop id-values)
                   (ert-fail "create over-read the ID source"))))
            (epi--wall-clock-function
             (lambda ()
               (push 'time trace)
               (or (pop time-values)
                   (ert-fail "create over-read the wall clock")))))
        (setq ledger
              (epi-test-ledger-io--wave3-create
               path :initial-drafts (vector first second))))
      (should (equal '(id time id time id id) (nreverse trace)))
      (should-not id-values)
      (should-not time-values)
      (should-not (epi-draft-id first))
      (should-not (epi-draft-at first))
      (should-not (epi-draft-id second))
      (should-not (epi-draft-at second))
      (let ((records (append (epi-ledger-records ledger) nil)))
        (should (equal record-ids (mapcar #'epi-record-id records)))
        (should (equal expected-times (mapcar #'epi-record-at records))))))
  ;; Explicit header identity, semantic preparation, and record/byte caps
  ;; reject before even a direct filesystem probe, ID/time source, or yield.
  (epi-test-with-temporary-root (root)
    (let ((path (epi-test-ledger-io--wave3-path root "preio.org"))
          (draft (epi-test-ledger-io--session-info)))
      (dolist (arguments
               (list
                (list :created-at epi-test-ledger-io--wave3-created-at
                      :project-root epi-test-ledger-io--wave3-project-root
                      :initial-drafts (vector draft))
                (list :session-id epi-test-ledger-io--session-id
                      :project-root epi-test-ledger-io--wave3-project-root
                      :initial-drafts (vector draft))
                (list :session-id epi-test-ledger-io--session-id
                      :created-at epi-test-ledger-io--wave3-created-at
                      :initial-drafts (vector draft))))
        (let ((condition
               (should-error
                (epi-test-ledger-io--wave3-call-with-forbidden-io
                 (lambda ()
                   (apply #'epi-ledger-create path arguments)))
                :type 'epi-ledger-format-error)))
          (should (memq (epi-test-ledger-io--condition-code condition)
                        '(invalid-id invalid-timestamp invalid-string)))))
      (let* ((first (epi-test-ledger-io--operation-started))
             (second (epi-test-ledger-io--operation-started)))
        (setf (epi-draft-id second)
              "10000000-0000-4000-8000-000000000098")
        (let ((condition
               (should-error
                (epi-test-ledger-io--wave3-call-with-forbidden-io
                 (lambda ()
                   (epi-test-ledger-io--wave3-create
                    path
                    :initial-drafts
                    (vector (epi-test-ledger-io--session-info)
                            first second)))
                 t)
                :type 'epi-ledger-format-error)))
          (should
           (eq 'duplicate-operation-start
               (epi-test-ledger-io--condition-code condition)))))
      (should-not (file-exists-p path))
      (should-not
       (file-exists-p (epi-test-ledger-io--wave3-lock-path path)))
      (should-not
       (directory-files root nil "\\.epi-tmp-" t))
      (dolist (oversized
               (list (make-list 257 nil) (make-vector 257 nil)))
        (let ((condition
               (should-error
                (epi-test-ledger-io--wave3-call-with-forbidden-io
                 (lambda ()
                   (epi-test-ledger-io--wave3-create
                    path :initial-drafts oversized)))
                :type 'epi-limit-exceeded)))
          (should (eq 'batch-record-limit
                      (epi-test-ledger-io--condition-code condition)))
          (should (= 256
                     (plist-get
                      (epi-test-ledger-io--condition-detail condition)
                      :limit)))
          (should (= 257
                     (plist-get
                      (epi-test-ledger-io--condition-detail condition)
                      :count)))))
      (let* ((large (epi-test-ledger-io--session-info))
             (header-bytes
              (epi-ledger-render-header (epi-test-ledger-io--header)))
             (document
              (epi-test-ledger-io--document-bytes (list large)))
             (combined-bytes (length document))
             (frame-bytes (- combined-bytes (length header-bytes)))
             (limit (1- combined-bytes))
             condition)
        (should (< (length header-bytes) limit))
        (should (< frame-bytes limit))
        (cl-progv '(epi-ledger--batch-byte-limit
                    epi-ledger-work-byte-limit
                    epi-ledger-work-record-limit)
            (list limit 8 1)
          (setq condition
                (should-error
                 (epi-test-ledger-io--wave3-call-with-forbidden-io
                  (lambda ()
                    (epi-test-ledger-io--wave3-create
                     path :initial-drafts (vector large))))
                 :type 'epi-limit-exceeded)))
        (should (eq 'batch-byte-limit
                    (epi-test-ledger-io--condition-code condition)))
        (should (= limit
                   (plist-get
                    (epi-test-ledger-io--condition-detail condition)
                    :limit)))
        (should (= combined-bytes
                   (plist-get
                    (epi-test-ledger-io--condition-detail condition)
                    :bytes)))))))

(ert-deftest epi-ledger-create-readback-mismatch-never-publishes ()
  (should (fboundp 'epi-ledger-create))
  (should (boundp 'epi-ledger--read-function))
  (should (boundp 'epi-ledger--publish-function))
  (epi-test-with-temporary-root (root)
    (let* ((path (epi-test-ledger-io--wave3-path root))
           (real-read epi-ledger--read-function)
           (epi--id-function (epi-test-ledger-io--wave3-id-source))
           (mismatch-count 0)
           intended condition)
      (let ((epi-ledger--byte-writer
             (let ((real-writer epi-ledger--byte-writer))
               (lambda (target bytes mode durablep)
                 (when (and (eq mode 'exclusive-create)
                            (epi-test-ledger-io--wave3-temporary-p
                             target path))
                   (setq intended (copy-sequence bytes)))
                 (funcall real-writer target bytes mode durablep))))
            (epi-ledger--read-function
             (lambda (target begin end)
               (let ((bytes (funcall real-read target begin end)))
                 (if (epi-test-ledger-io--wave3-temporary-p target path)
                     (let ((mutated (copy-sequence bytes)))
                       (setq mismatch-count (1+ mismatch-count))
                       (should (> (length mutated) 0))
                       (aset mutated 0
                             (logxor #x01 (aref mutated 0)))
                       (should (= (length bytes) (length mutated)))
                       mutated)
                   bytes))))
            (epi-ledger--publish-function
             (lambda (&rest arguments)
               (ert-fail
                (format "mismatched readback published: %S" arguments)))))
        (cl-letf
            (((symbol-function 'add-name-to-file)
              (lambda (&rest arguments)
                (ert-fail
                 (format "mismatched readback hard-linked: %S"
                         arguments)))))
          (setq condition
                (should-error
                 (epi-test-ledger-io--wave3-create path)
                 :type 'epi-ledger-conflict))))
      (should intended)
      (should (= 1 mismatch-count))
      (should (eq 'storage-write-failed
                  (epi-test-ledger-io--condition-code condition)))
      (should-not (file-exists-p path))
      (should-not
       (file-exists-p (epi-test-ledger-io--wave3-lock-path path)))
      (dolist (temporary (epi-test-ledger-io--wave3-temporaries path))
        (should (equal intended
                       (epi-test-ledger-io--literal-file-bytes temporary)))
        (should (epi-test-ledger-io--wave3-temp-complete-p temporary)))))
  ;; Signaling storage seams are closed into the create phase's stable Epi
  ;; conflict codes; no raw `file-error' may cross the public boundary.
  (epi-test-with-temporary-root (root)
    (dolist (case '((stat . storage-write-failed)
                    (lock . storage-write-failed)
                    (writer . storage-write-failed)
                    (flush . storage-flush-failed)
                    (read . storage-write-failed)
                    (publish . storage-publication-failed)))
      (let* ((kind (car case))
             (expected-code (cdr case))
             (path
              (epi-test-ledger-io--wave3-path
               root (format "signaling-%s.org" kind)))
             (real-writer epi-ledger--byte-writer)
             (real-flush epi-ledger--flush-function)
             (real-stat epi-ledger--stat-function)
             (real-lock-create epi-ledger--lock-create-function)
             (real-read epi-ledger--read-function)
             (real-publish epi-ledger--publish-function)
             (epi--id-function (epi-test-ledger-io--wave3-id-source))
             condition)
        (let ((epi-ledger--byte-writer
               (lambda (target bytes mode durablep)
                 (if (and (eq kind 'writer)
                          (eq mode 'exclusive-create)
                          (epi-test-ledger-io--wave3-temporary-p target path))
                     (signal 'file-error '("injected create writer"))
                   (funcall real-writer target bytes mode durablep))))
              (epi-ledger--flush-function
               (lambda (target)
                 (if (eq kind 'flush)
                     (signal 'file-error '("injected create flush"))
                   (funcall real-flush target))))
              (epi-ledger--stat-function
               (lambda (target)
                 (if (and (eq kind 'stat) (equal target path))
                     (signal 'file-error '("injected create stat"))
                   (funcall real-stat target))))
              (epi-ledger--lock-create-function
               (lambda (target bytes)
                 (if (eq kind 'lock)
                     (signal 'file-error '("injected create lock"))
                   (funcall real-lock-create target bytes))))
              (epi-ledger--read-function
               (lambda (target begin end)
                 (if (and (eq kind 'read)
                          (epi-test-ledger-io--wave3-temporary-p target path))
                     (signal 'file-error '("injected create read"))
                   (funcall real-read target begin end))))
              (epi-ledger--publish-function
               (lambda (source destination)
                 (if (eq kind 'publish)
                     (signal 'file-error '("injected create publish"))
                   (funcall real-publish source destination)))))
          (setq condition
                (should-error
                 (epi-test-ledger-io--wave3-create path)
                 :type 'epi-ledger-conflict)))
        (let ((detail (epi-test-ledger-io--condition-detail condition)))
          (should (eq :code (car detail)))
          (should (eq expected-code (plist-get detail :code))))
        (should-not (file-exists-p path))
        (should-not
         (file-exists-p (epi-test-ledger-io--wave3-lock-path path))))))
  ;; Every destination-stat checkpoint maps a raw storage failure to the same
  ;; closed condition shape, not merely the initial absence check.
  (epi-test-with-temporary-root (root)
    (dolist (checkpoint '(1 2 3))
      (let* ((path
              (epi-test-ledger-io--wave3-path
               root (format "raw-stat-%d.org" checkpoint)))
             (lock-path (epi-test-ledger-io--wave3-lock-path path))
             (real-stat epi-ledger--stat-function)
             (epi--id-function (epi-test-ledger-io--wave3-id-source))
             (destination-stat-count 0)
             condition)
        (let ((epi-ledger--stat-function
               (lambda (target)
                 (if (equal target path)
                     (progn
                       (setq destination-stat-count
                             (1+ destination-stat-count))
                       (if (= checkpoint destination-stat-count)
                           (signal
                            'file-error
                            (list
                             (format "injected destination stat %d"
                                     checkpoint)))
                         (funcall real-stat target)))
                   (funcall real-stat target)))))
          (setq condition
                (should-error
                 (epi-test-ledger-io--wave3-create path)
                 :type 'epi-ledger-conflict)))
        (should (= checkpoint destination-stat-count))
        (should (= 1 (length (cdr condition))))
        (let ((detail (epi-test-ledger-io--condition-detail condition)))
          (should (eq :code (car detail)))
          (should (eq 'storage-write-failed
                      (plist-get detail :code))))
        (should-not (file-exists-p path))
        (should-not (file-exists-p lock-path))
        (dolist (temporary (epi-test-ledger-io--wave3-temporaries path))
          (should (epi-test-ledger-io--wave3-temp-complete-p temporary))))))
  ;; Structured Epi conditions retain their exact sole detail plist across
  ;; every create storage seam, including exact lock-file creation.
  (epi-test-with-temporary-root (root)
    (dolist (stage '(stat lock writer flush read publish))
      (let* ((path
              (epi-test-ledger-io--wave3-path
               root (format "structured-%s.org" stage)))
             (lock-path (epi-test-ledger-io--wave3-lock-path path))
             (real-stat epi-ledger--stat-function)
             (real-lock-create epi-ledger--lock-create-function)
             (real-writer epi-ledger--byte-writer)
             (real-flush epi-ledger--flush-function)
             (real-read epi-ledger--read-function)
             (real-publish epi-ledger--publish-function)
             (epi--id-function (epi-test-ledger-io--wave3-id-source))
             (marker (make-symbol (format "structured-%s" stage)))
             (detail
              (list :code 'injected-structured-create-seam
                    :stage stage :marker marker))
             (seam-calls 0)
             condition)
        (cl-labels
            ((injected
              ()
              (setq seam-calls (1+ seam-calls))
              (signal 'epi-ledger-conflict (list detail))))
          (let ((epi-ledger--stat-function
                 (lambda (target)
                   (if (and (eq stage 'stat) (equal target path))
                       (injected)
                     (funcall real-stat target))))
                (epi-ledger--lock-create-function
                 (lambda (target bytes)
                   (if (eq stage 'lock)
                       (injected)
                     (funcall real-lock-create target bytes))))
                (epi-ledger--byte-writer
                 (lambda (target bytes mode durablep)
                   (if (and (eq stage 'writer)
                            (eq mode 'exclusive-create)
                            (epi-test-ledger-io--wave3-temporary-p
                             target path))
                       (injected)
                     (funcall real-writer target bytes mode durablep))))
                (epi-ledger--flush-function
                 (lambda (target)
                   (if (and (eq stage 'flush)
                            (epi-test-ledger-io--wave3-temporary-p
                             target path))
                       (injected)
                     (funcall real-flush target))))
                (epi-ledger--read-function
                 (lambda (target begin end)
                   (if (and (eq stage 'read)
                            (epi-test-ledger-io--wave3-temporary-p
                             target path))
                       (injected)
                     (funcall real-read target begin end))))
                (epi-ledger--publish-function
                 (lambda (source destination)
                   (if (eq stage 'publish)
                       (injected)
                     (funcall real-publish source destination)))))
            (setq condition
                  (should-error
                   (epi-test-ledger-io--wave3-create path)
                   :type 'epi-ledger-conflict))))
        (should (= 1 seam-calls))
        (should (= 1 (length (cdr condition))))
        (should (eq detail
                    (epi-test-ledger-io--condition-detail condition)))
        (should (equal (list detail) (cdr condition)))
        (should-not (file-exists-p path))
        (should-not (file-exists-p lock-path))))))


;;;; Wave 4: append prewrite foundation

(defconst epi-test-ledger-io--wave4-lock-nonce
  "44444444-4444-4444-8444-444444444444"
  "Deterministic UUID used only for Wave 4 lock acquisition.")

(defconst epi-test-ledger-io--wave4-process-start [11 22 33 44]
  "Deterministic four-part process-start identity for Wave 4 locks.")

(defvar epi-test-ledger-io--wave4-race-case-filter nil
  "When non-nil, run only this identity race kind in table-driven tests.
This mutation-audit seam is nil during the real suite and does not alter the
ten-test public inventory.")

(defconst epi-test-ledger-io--wave4-first-id
  "50000000-0000-4000-8000-000000000001"
  "First deterministic default record ID used by Wave 4.")

(defconst epi-test-ledger-io--wave4-second-id
  "50000000-0000-4000-8000-000000000002"
  "Second deterministic default record ID used by Wave 4.")

(defconst epi-test-ledger-io--wave4-next-operation-id
  "60000000-0000-4000-8000-000000000001"
  "Operation ID for the valid operation following the shared fixture.")

(defun epi-test-ledger-io--wave4-next-operation ()
  "Return a valid new operation-started draft after the shared history."
  (epi-test-ledger-io--draft
   "50000000-0000-4000-8000-000000000010"
   'operation-started
   `(("operation_id" . ,epi-test-ledger-io--wave4-next-operation-id)
     ("kind" . "prompt"))
   :operation epi-test-ledger-io--wave4-next-operation-id))

(defun epi-test-ledger-io--wave4-default-draft (operation-id)
  "Return an operation-started draft with nil ID/time for OPERATION-ID."
  (make-epi-draft
   :id nil :type 'operation-started :at nil
   :operation operation-id
   :payload `(("operation_id" . ,operation-id) ("kind" . "prompt"))))

(defun epi-test-ledger-io--wave4-default-terminal (operation-id)
  "Return an operation-interrupted draft with nil ID/time for OPERATION-ID."
  (make-epi-draft
   :id nil :type 'operation-interrupted :at nil
   :operation operation-id
   :payload `(("operation_id" . ,operation-id) ("reason" . "interrupted"))))

(defun epi-test-ledger-io--wave4-snapshot (ledger)
  "Return LEDGER's byte-exact file bytes and checkpoint identity."
  (list
   (epi-test-ledger-io--literal-file-bytes (epi-ledger--raw-path ledger))
   (epi-ledger--checkpoint-snapshot ledger)))

(defun epi-test-ledger-io--wave4-race-winner (checkpoint)
  "Return an identity-distinct, authority-equivalent CHECKPOINT winner.
This models an in-process publication race without introducing Wave 5 storage
uncertainty into Wave 4 prewrite tests."
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
   :uncertain (epi-ledger--checkpoint-raw-uncertain checkpoint)))

(defun epi-test-ledger-io--wave4-assert-snapshot
    (ledger snapshot &optional expected-checkpoint)
  "Assert LEDGER still has SNAPSHOT's bytes and checkpoint authority.
EXPECTED-CHECKPOINT permits a test-injected concurrent winner; when omitted,
the exact checkpoint in SNAPSHOT must remain published."
  (should
   (equal (car snapshot)
          (epi-test-ledger-io--literal-file-bytes
           (epi-ledger--raw-path ledger))))
  (should
   (eq (or expected-checkpoint (cadr snapshot))
       (epi-ledger--checkpoint-snapshot ledger))))

(defun epi-test-ledger-io--wave4-unexpected-lock (&rest arguments)
  "Fail because invalid prewrite input reached lock acquisition.
ARGUMENTS are the unexpected lock-acquisition call arguments."
  (ert-fail (format "prewrite rejection reached lock: %S" arguments)))

(defun epi-test-ledger-io--wave4-unexpected-writer (&rest arguments)
  "Fail because a Wave 4 path reached a Wave 5 storage mutation seam.
ARGUMENTS are the unexpected storage-writer call arguments."
  (ert-fail (format "Wave 4 reached storage writer: %S" arguments)))

(defun epi-test-ledger-io--wave4-process-attributes (pid)
  "Return deterministic current-process attributes for PID."
  (let ((number (if (stringp pid) (string-to-number pid) pid)))
    (and (= number (emacs-pid))
         `((start . ,(append
                      epi-test-ledger-io--wave4-process-start nil))))))

(defun epi-test-ledger-io--wave4-time-vector (value)
  "Return VALUE as the exact four-component lock-token time vector."
  (let ((parts (time-convert value 'list)))
    (unless (= 4 (length parts))
      (ert-fail (format "lock identity time was not four-part: %S" value)))
    (vconcat parts)))

(defun epi-test-ledger-io--wave4-distinct-time-vector (value)
  "Return a valid four-part time vector one second after VALUE."
  (let ((parts
         (time-convert (time-add value (seconds-to-time 1)) 'list)))
    (unless (= 4 (length parts))
      (ert-fail (format "mutated identity time was not four-part: %S"
                        value)))
    (vconcat parts)))

(defun epi-test-ledger-io--wave4-mutated-identity (identity kind)
  "Return a same-size copy of IDENTITY with exactly KIND made distinct."
  (let ((copy (copy-tree identity)))
    (pcase kind
      ('replacement
       (setq copy
             (plist-put copy :path
                        (concat (plist-get copy :path) ".replacement"))))
      ('device
       (setq copy (plist-put copy :device
                             (1+ (plist-get copy :device)))))
      ('inode
       (setq copy (plist-put copy :inode
                             (1+ (plist-get copy :inode)))))
      ('links
       (setq copy (plist-put copy :links
                             (1+ (plist-get copy :links)))))
      ('modified
       (setq copy
             (plist-put
              copy :modified
              (epi-test-ledger-io--wave4-distinct-time-vector
               (plist-get copy :modified)))))
      ('changed
       (setq copy
             (plist-put
              copy :changed
              (epi-test-ledger-io--wave4-distinct-time-vector
               (plist-get copy :changed)))))
      (_ (ert-fail (format "unknown identity mutation: %S" kind))))
    (should (= (plist-get identity :size) (plist-get copy :size)))
    (when (memq kind '(device inode links modified changed))
      (let ((key (intern (concat ":" (symbol-name kind)))))
        (should (equal (plist-get identity :path) (plist-get copy :path)))
        (should-not (equal (plist-get identity key)
                           (plist-get copy key)))))
    copy))

(defun epi-test-ledger-io--wave4-race-cases (cases)
  "Return CASES, optionally narrowed by the mutation-audit filter."
  (if epi-test-ledger-io--wave4-race-case-filter
      (seq-filter
       (lambda (case)
         (eq epi-test-ledger-io--wave4-race-case-filter (car case)))
       cases)
    cases))

(defun epi-test-ledger-io--wave4-file-object (identity)
  "Return the independently specified lock-token object for IDENTITY."
  (list
   (cons "path" (plist-get identity :path))
   (cons "device" (number-to-string (plist-get identity :device)))
   (cons "inode" (number-to-string (plist-get identity :inode)))
   (cons "links" (number-to-string (plist-get identity :links)))
   (cons "size" (number-to-string (plist-get identity :size)))
   (cons "modified"
         (epi-test-ledger-io--wave4-time-vector
          (plist-get identity :modified)))
   (cons "changed"
         (epi-test-ledger-io--wave4-time-vector
          (plist-get identity :changed)))))

(defun epi-test-ledger-io--wave4-lock-token-bytes
    (path expected-file expected-end expected-head)
  "Independently encode the exact canonical lock token for PATH.
EXPECTED-FILE is the complete expected file identity, EXPECTED-END is its
trusted EOF, and EXPECTED-HEAD is its trusted chain head."
  (epi-ledger--jcs-encode
   (list
    (cons "version" 1)
    (cons "host" (system-name))
    (cons "pid" (number-to-string (emacs-pid)))
    (cons "process_start" epi-test-ledger-io--wave4-process-start)
    (cons "nonce" epi-test-ledger-io--wave4-lock-nonce)
    (cons "ledger_path" path)
    (cons "expected_file"
          (if (stringp expected-file)
              expected-file
            (epi-test-ledger-io--wave4-file-object expected-file)))
    (cons "expected_end"
          (if (stringp expected-end)
              expected-end
            (number-to-string expected-end)))
    (cons "expected_head" (or expected-head epi-json-null)))
   65536))

(defun epi-test-ledger-io--wave4-assert-owned-lock
    (lock lock-path token expected-file expected-end expected-head)
  "Assert LOCK owns the exact on-disk TOKEN at LOCK-PATH."
  (let ((identity (epi-ledger--stat-local-file lock-path))
        (sha256 (secure-hash 'sha256 token)))
    (should (epi-ledger--lock-p lock))
    (should (file-exists-p lock-path))
    (should identity)
    (should (equal lock-path (epi-ledger--lock-lock-file lock)))
    (should (equal token (epi-ledger--lock-bytes lock)))
    (should (equal sha256 (epi-ledger--lock-sha256 lock)))
    (should (equal identity (epi-ledger--lock-file-identity lock)))
    (should (equal token
                   (epi-test-ledger-io--literal-file-bytes lock-path)))
    (should (equal expected-file
                   (epi-ledger--lock-expected-file lock)))
    (should (= expected-end (epi-ledger--lock-expected-end lock)))
    (should (equal expected-head (epi-ledger--lock-expected-head lock)))))

(defun epi-test-ledger-io--wave4-private-fingerprint (value)
  "Return a cycle-safe exact printed fingerprint of private VALUE."
  (let ((print-circle t)
        (print-gensym t)
        (print-length nil)
        (print-level nil))
    (prin1-to-string value)))

(defun epi-test-ledger-io--wave4-capsule-fingerprint (capsule)
  "Return a private graph fingerprint for semantic CAPSULE."
  (epi-test-ledger-io--wave4-private-fingerprint
   (epi-test-ledger-io--capsule-roots capsule)))

(defun epi-test-ledger-io--wave4-prepared-field (prepared field)
  "Return required FIELD from PREPARED's private result plist."
  (unless (and (listp prepared) (plist-member prepared field))
    (ert-fail (format "prepared batch omitted %S: %S" field prepared)))
  (plist-get prepared field))

(defun epi-test-ledger-io--wave4-sequence-list (value field)
  "Return vector or proper-list VALUE as a list for required FIELD."
  (cond
   ((vectorp value) (append value nil))
   ((proper-list-p value) value)
   (t (ert-fail (format "prepared %S is not an ordered sequence: %S"
                        field value)))))

(defun epi-test-ledger-io--wave4-property-free-unibyte-p (value)
  "Return non-nil when VALUE is an unibyte string without properties."
  (and (stringp value)
       (not (multibyte-string-p value))
       (equal-including-properties value (substring-no-properties value))))

(defun epi-test-ledger-io--wave4-assert-prepared
    (prepared sealed rendered)
  "Assert PREPARED exactly retains SEALED records and RENDERED frames."
  (let* ((records
          (epi-test-ledger-io--wave4-sequence-list
           (epi-test-ledger-io--wave4-prepared-field prepared :records)
           :records))
         (frames
          (epi-test-ledger-io--wave4-sequence-list
           (epi-test-ledger-io--wave4-prepared-field prepared :frames)
           :frames))
         (suffix
          (epi-test-ledger-io--wave4-prepared-field prepared :suffix))
         (final-hash
          (epi-test-ledger-io--wave4-prepared-field prepared :final-hash)))
    (should (= (length sealed) (length records)))
    (should (cl-every #'eq sealed records))
    (should (equal rendered frames))
    (dolist (frame frames)
      (should (epi-test-ledger-io--wave4-property-free-unibyte-p frame)))
    (should (epi-test-ledger-io--wave4-property-free-unibyte-p suffix))
    (should (equal-including-properties (apply #'concat frames) suffix))
    (should sealed)
    (should (equal (epi-record--raw-hash (car (last sealed))) final-hash))))

(defun epi-test-ledger-io--wave4-filled-batch (drafts)
  "Own DRAFTS, fill owned defaults, and return the resulting vector.
The helper deliberately does not freeze whether the private fill function
returns its vector or mutates the already-owned vector in place."
  (let* ((owned (epi-ledger--snapshot-draft-batch drafts))
         (result (epi-ledger--fill-owned-draft-defaults owned))
         (filled (if (vectorp result) result owned)))
    (unless (and (vectorp filled)
                 (seq-every-p #'epi-draft-p filled))
      (ert-fail (format "default filler did not expose owned drafts: %S"
                        result)))
    filled))

(defun epi-test-ledger-io--wave4-prepare (ledger drafts)
  "Run the frozen suffix-preparation helper for LEDGER and DRAFTS."
  (let* ((checkpoint (epi-ledger--checkpoint-snapshot ledger))
         (source (epi-ledger--checkpoint-raw-records checkpoint))
         (first-sequence (1+ (epi-ledger--record-source-length source)))
         (owned (epi-test-ledger-io--wave4-filled-batch drafts)))
    (epi-ledger--prepare-record-batch
     (epi-ledger--raw-header ledger)
     (epi-ledger--checkpoint-raw-semantic-capsule checkpoint)
     owned
     (epi-ledger--checkpoint-raw-tail-hash checkpoint)
     first-sequence
     0)))

(defmacro epi-test-ledger-io--wave4-should-code (condition code &rest body)
  "Assert BODY signals CONDITION with stable Epi CODE."
  (declare (indent 2) (debug t))
  `(let ((caught (should-error (progn ,@body) :type ,condition)))
     (should (eq ,code (epi-test-ledger-io--condition-code caught)))
     caught))

(ert-deftest epi-ledger-append-rejects-empty-or-uncertain-batch-before-lock ()
  (should (fboundp 'epi-ledger--append))
  (should (fboundp 'epi-ledger--snapshot-draft-batch))
  (should (fboundp 'epi-ledger--fill-owned-draft-defaults))
  (should (fboundp 'epi-ledger--prepare-record-batch))
  (should (fboundp 'epi-ledger--acquire-lock))
  (epi-test-with-temporary-root (root)
    (let* ((ledger
            (epi-test-ledger-io--open-history
             root (list (epi-test-ledger-io--session-info))))
           (empty-snapshot (epi-test-ledger-io--wave4-snapshot ledger))
           (operation "60000000-0000-4000-8000-000000000001")
           (oversized
            (make-list
             (1+ epi-ledger--batch-record-limit)
             (epi-test-ledger-io--wave4-default-draft operation)))
           (epi-ledger--append-function
            #'epi-test-ledger-io--wave4-unexpected-writer)
           (epi-ledger--flush-function
            #'epi-test-ledger-io--wave4-unexpected-writer))
      (cl-labels
          ((unexpected-prework
            (&rest arguments)
            (ert-fail
             (format "append gate reached prework or I/O: %S" arguments))))
        (cl-letf
            (((symbol-function 'epi-ledger--snapshot-draft-batch)
              #'unexpected-prework)
             ((symbol-function 'epi-ledger--fill-owned-draft-defaults)
              #'unexpected-prework)
             ((symbol-function 'epi-ledger--prepare-record-batch)
              #'unexpected-prework)
             ((symbol-function 'epi-ledger--acquire-lock)
              #'unexpected-prework))
          (epi-test-ledger-io--wave4-should-code
              'epi-ledger-format-error 'empty-draft-batch
            (epi-ledger--append ledger [])))
      (epi-test-ledger-io--wave4-assert-snapshot ledger empty-snapshot)
      (let* ((ordinary (epi-ledger--checkpoint-snapshot ledger))
             (uncertain
              (epi-ledger--checkpoint-uncertain-successor ordinary)))
        (should (epi-ledger--checkpoint-cas ledger ordinary uncertain))
        (let ((uncertain-snapshot
               (epi-test-ledger-io--wave4-snapshot ledger)))
          (let ((epi--id-function #'unexpected-prework)
                (epi--wall-clock-function #'unexpected-prework)
                (epi--yield-function #'unexpected-prework)
                (epi-ledger--lock-create-function #'unexpected-prework)
                (epi-ledger--stat-function #'unexpected-prework)
                (epi-ledger--read-function #'unexpected-prework)
                (epi-ledger--unlock-function #'unexpected-prework))
            (cl-letf
                (((symbol-function 'epi-ledger--snapshot-draft-batch)
                  #'unexpected-prework)
                 ((symbol-function 'epi-ledger--fill-owned-draft-defaults)
                  #'unexpected-prework)
                 ((symbol-function 'epi-ledger--prepare-record-batch)
                  #'unexpected-prework)
                 ((symbol-function 'epi-ledger--acquire-lock)
                  #'unexpected-prework))
              (epi-test-ledger-io--wave4-should-code
                  'epi-ledger-conflict 'append-uncertain
                (epi-ledger--append ledger oversized))))
          (epi-test-ledger-io--wave4-assert-snapshot
           ledger uncertain-snapshot)))))))

(ert-deftest epi-ledger-append-fills-nil-id-and-time-only-on-owned-drafts ()
  (should (fboundp 'epi-ledger--append))
  (should (fboundp 'epi-ledger--snapshot-draft-batch))
  (should (fboundp 'epi-ledger--fill-owned-draft-defaults))
  (should (fboundp 'epi-ledger--prepare-record-batch))
  (should (fboundp 'epi-ledger--acquire-lock))
  (epi-test-with-temporary-root (root)
    (let* ((ledger
            (epi-test-ledger-io--open-history
             root (list (epi-test-ledger-io--session-info))))
           (expected (epi-ledger--checkpoint-snapshot ledger))
           (snapshot (epi-test-ledger-io--wave4-snapshot ledger))
           (operation "60000000-0000-4000-8000-000000000011")
           (nil-source
            (let ((draft
                   (epi-test-ledger-io--wave4-default-draft operation)))
              (setcdr (assoc "kind" (epi-draft-payload draft))
                      (copy-sequence "prompt"))
              draft))
           (fixed-source
            (epi-test-ledger-io--draft
             "50000000-0000-4000-8000-000000000003"
             'operation-interrupted
             `(("operation_id" . ,operation) ("reason" . "interrupted"))
             :operation operation))
           (fixed-id (epi-draft-id fixed-source))
           (fixed-time (epi-draft-at fixed-source))
           (wall-time (encode-time 0 0 12 22 7 2026 t))
           (expected-time
            (format-time-string "%Y-%m-%dT%H:%M:%S.%9NZ" wall-time t))
           (real-snapshot
            (symbol-function 'epi-ledger--snapshot-draft-batch))
           (real-fill
            (symbol-function 'epi-ledger--fill-owned-draft-defaults))
           (real-prepare
            (symbol-function 'epi-ledger--prepare-record-batch))
           (id-calls 0)
           (time-calls 0)
           ownership-trace owned-snapshot filled owned-kind-mutated winner
           (epi--id-function
            (lambda ()
              (setq id-calls (1+ id-calls))
              epi-test-ledger-io--wave4-first-id))
           (epi--wall-clock-function
            (lambda ()
              (setq time-calls (1+ time-calls))
              wall-time))
           (epi-ledger--append-function
            #'epi-test-ledger-io--wave4-unexpected-writer)
           (epi-ledger--flush-function
            #'epi-test-ledger-io--wave4-unexpected-writer))
      (cl-letf
          (((symbol-function 'epi-ledger--snapshot-draft-batch)
            (lambda (&rest arguments)
              (push 'snapshot ownership-trace)
              (setq owned-snapshot (apply real-snapshot arguments))))
           ((symbol-function 'epi-ledger--fill-owned-draft-defaults)
            (lambda (owned)
              (push 'fill ownership-trace)
              (should (eq owned-snapshot owned))
              (let ((result (funcall real-fill owned)))
                (setq filled (if (vectorp result) result owned))
                result)))
           ((symbol-function 'epi-ledger--prepare-record-batch)
            (lambda (&rest arguments)
              (push 'prepare ownership-trace)
              (should (eq filled (nth 2 arguments)))
              (let ((prepared (apply real-prepare arguments)))
                (let* ((owned-first (aref filled 0))
                       (owned-kind
                        (cdr (assoc "kind" (epi-draft-payload owned-first)))))
                  (aset owned-kind 0 ?X)
                  (setq owned-kind-mutated t))
                (setq winner
                      (epi-test-ledger-io--wave4-race-winner expected))
                (should (epi-ledger--checkpoint-cas ledger expected winner))
                prepared)))
           ((symbol-function 'epi-ledger--acquire-lock)
            #'epi-test-ledger-io--wave4-unexpected-lock))
        (epi-test-ledger-io--wave4-should-code
            'epi-ledger-conflict 'stale-checkpoint
          (epi-ledger--append ledger (vector nil-source fixed-source))))
      (should (vectorp filled))
      (should (equal '(snapshot fill prepare) (nreverse ownership-trace)))
      (should owned-kind-mutated)
      (should (= 1 id-calls))
      (should (= 1 time-calls))
      (should (equal epi-test-ledger-io--wave4-first-id
                     (epi-draft-id (aref filled 0))))
      (should (equal expected-time (epi-draft-at (aref filled 0))))
      (should (equal fixed-id (epi-draft-id (aref filled 1))))
      (should (equal fixed-time (epi-draft-at (aref filled 1))))
      (should-not (epi-draft-id nil-source))
      (should-not (epi-draft-at nil-source))
      (should (equal "prompt"
                     (cdr (assoc "kind" (epi-draft-payload nil-source)))))
      (should (equal "Xrompt"
                     (cdr (assoc "kind"
                                 (epi-draft-payload (aref filled 0))))))
      (should (equal fixed-id (epi-draft-id fixed-source)))
      (should (equal fixed-time (epi-draft-at fixed-source)))
      (should-not (eq nil-source (aref filled 0)))
      (should-not (eq fixed-source (aref filled 1)))
      (epi-test-ledger-io--wave4-assert-snapshot
       ledger snapshot winner))))

(ert-deftest epi-ledger-append-fills-defaults-in-deterministic-input-order ()
  (should (fboundp 'epi-ledger--append))
  (should (fboundp 'epi-ledger--snapshot-draft-batch))
  (should (fboundp 'epi-ledger--fill-owned-draft-defaults))
  (should (fboundp 'epi-ledger--prepare-record-batch))
  (should (fboundp 'epi-ledger--acquire-lock))
  (epi-test-with-temporary-root (root)
    (let* ((ledger
            (epi-test-ledger-io--open-history
             root (list (epi-test-ledger-io--session-info))))
           (expected (epi-ledger--checkpoint-snapshot ledger))
           (snapshot (epi-test-ledger-io--wave4-snapshot ledger))
           (operation "60000000-0000-4000-8000-000000000021")
           (first (epi-test-ledger-io--wave4-default-draft operation))
           (second (epi-test-ledger-io--wave4-default-terminal operation))
           (first-time (encode-time 0 0 13 22 7 2026 t))
           (second-time (encode-time 1 0 13 22 7 2026 t))
           (ids (list epi-test-ledger-io--wave4-first-id
                      epi-test-ledger-io--wave4-second-id))
           (times (list first-time second-time))
           (real-snapshot
            (symbol-function 'epi-ledger--snapshot-draft-batch))
           (real-fill
            (symbol-function 'epi-ledger--fill-owned-draft-defaults))
           (real-prepare
            (symbol-function 'epi-ledger--prepare-record-batch))
           trace filled winner
           (epi--id-function
            (lambda ()
              (push 'id trace)
              (or (pop ids)
                  (ert-fail "default filler over-read ID source"))))
           (epi--wall-clock-function
            (lambda ()
              (push 'time trace)
              (or (pop times)
                  (ert-fail "default filler over-read wall clock"))))
           (epi-ledger--append-function
            #'epi-test-ledger-io--wave4-unexpected-writer)
           (epi-ledger--flush-function
            #'epi-test-ledger-io--wave4-unexpected-writer))
      (cl-letf
          (((symbol-function 'epi-ledger--snapshot-draft-batch)
            (lambda (&rest arguments)
              (push 'snapshot trace)
              (apply real-snapshot arguments)))
           ((symbol-function 'epi-ledger--fill-owned-draft-defaults)
            (lambda (owned)
              (push 'fill trace)
              (let ((result (funcall real-fill owned)))
                (setq filled (if (vectorp result) result owned))
                result)))
           ((symbol-function 'epi-ledger--prepare-record-batch)
            (lambda (&rest arguments)
              (push 'prepare trace)
              (let ((prepared (apply real-prepare arguments)))
                (setq winner
                      (epi-test-ledger-io--wave4-race-winner expected))
                (should (epi-ledger--checkpoint-cas ledger expected winner))
                prepared)))
           ((symbol-function 'epi-ledger--acquire-lock)
            #'epi-test-ledger-io--wave4-unexpected-lock))
        (epi-test-ledger-io--wave4-should-code
            'epi-ledger-conflict 'stale-checkpoint
          (epi-ledger--append ledger (vector first second))))
      (should (equal '(snapshot fill id time id time prepare)
                     (nreverse trace)))
      (should-not ids)
      (should-not times)
      (should
       (equal
        (list epi-test-ledger-io--wave4-first-id
              epi-test-ledger-io--wave4-second-id)
        (mapcar #'epi-draft-id (append filled nil))))
      (should
       (equal
        (list (format-time-string "%Y-%m-%dT%H:%M:%S.%9NZ" first-time t)
              (format-time-string "%Y-%m-%dT%H:%M:%S.%9NZ" second-time t))
        (mapcar #'epi-draft-at (append filled nil))))
      (should-not (epi-draft-id first))
      (should-not (epi-draft-at first))
      (should-not (epi-draft-id second))
      (should-not (epi-draft-at second))
      (epi-test-ledger-io--wave4-assert-snapshot
       ledger snapshot winner)))
  ;; The integration order is cap/own first, before any default source,
  ;; cooperative callback, preparation, lock, or I/O seam.
  (epi-test-with-temporary-root (root)
    (let* ((ledger
            (epi-test-ledger-io--open-history
             root (list (epi-test-ledger-io--session-info))))
           (snapshot (epi-test-ledger-io--wave4-snapshot ledger))
           (operation "60000000-0000-4000-8000-000000000022")
           (draft (epi-test-ledger-io--wave4-default-draft operation))
           (oversized (make-list (1+ epi-ledger--batch-record-limit) draft))
           (real-snapshot
            (symbol-function 'epi-ledger--snapshot-draft-batch))
           trace)
      (cl-labels
          ((unexpected
            (&rest arguments)
            (ert-fail
             (format "batch cap reached defaults, callback, or I/O: %S"
                     arguments))))
        (let ((epi--id-function #'unexpected)
              (epi--wall-clock-function #'unexpected)
              (epi--yield-function #'unexpected)
              (epi-ledger--lock-create-function #'unexpected)
              (epi-ledger--append-function #'unexpected)
              (epi-ledger--flush-function #'unexpected)
              (epi-ledger--stat-function #'unexpected)
              (epi-ledger--read-function #'unexpected)
              (epi-ledger--unlock-function #'unexpected))
          (cl-letf
              (((symbol-function 'epi-ledger--snapshot-draft-batch)
                (lambda (&rest arguments)
                  (push 'cap trace)
                  (apply real-snapshot arguments)))
               ((symbol-function 'epi-ledger--fill-owned-draft-defaults)
                #'unexpected)
               ((symbol-function 'epi-ledger--prepare-record-batch)
                #'unexpected)
               ((symbol-function 'epi-ledger--acquire-lock)
                #'unexpected))
            (epi-test-ledger-io--wave4-should-code
                'epi-limit-exceeded 'batch-record-limit
              (epi-ledger--append ledger oversized)))))
      (should (equal '(cap) (nreverse trace)))
      (should-not (epi-draft-id draft))
      (should-not (epi-draft-at draft))
      (epi-test-ledger-io--wave4-assert-snapshot ledger snapshot))))

(ert-deftest epi-ledger-append-rejects-duplicate-ids-before-writing ()
  (should (fboundp 'epi-ledger--append))
  (should (fboundp 'epi-ledger--acquire-lock))
  (dolist (kind '(prefix suffix))
    (epi-test-with-temporary-root (root)
      (let* ((ledger
              (epi-test-ledger-io--open-history
               root (list (epi-test-ledger-io--session-info))))
             (snapshot (epi-test-ledger-io--wave4-snapshot ledger))
             (operation "60000000-0000-4000-8000-000000000031")
             (first
              (epi-test-ledger-io--draft
               "50000000-0000-4000-8000-000000000031"
               'operation-started
               `(("operation_id" . ,operation) ("kind" . "prompt"))
               :operation operation))
             (second
              (epi-test-ledger-io--draft
               (epi-draft-id first)
               'operation-interrupted
               `(("operation_id" . ,operation) ("reason" . "interrupted"))
               :operation operation))
             (drafts
              (if (eq kind 'prefix)
                  (progn
                    (setf (epi-draft-id first)
                          (epi-draft-id
                           (epi-test-ledger-io--session-info)))
                    (vector first))
                (vector first second)))
             (epi-ledger--append-function
              #'epi-test-ledger-io--wave4-unexpected-writer)
             (epi-ledger--flush-function
              #'epi-test-ledger-io--wave4-unexpected-writer))
        (cl-letf (((symbol-function 'epi-ledger--acquire-lock)
                   #'epi-test-ledger-io--wave4-unexpected-lock))
          (epi-test-ledger-io--wave4-should-code
              'epi-ledger-format-error 'duplicate-id
            (epi-ledger--append ledger drafts)))
        (epi-test-ledger-io--wave4-assert-snapshot ledger snapshot)))))

(ert-deftest epi-ledger-append-rejects-invalid-cross-record-lifecycle-before-writing ()
  (should (fboundp 'epi-ledger--append))
  (should (fboundp 'epi-ledger--acquire-lock))
  (should (fboundp 'epi-ledger--validation-final-error))
  (epi-test-with-temporary-root (root)
    (let* ((prefix (cl-subseq (epi-test-ledger-io--full-drafts) 0 7))
           (ledger (epi-test-ledger-io--open-history root prefix))
           (snapshot (epi-test-ledger-io--wave4-snapshot ledger))
           (epi-ledger--append-function
            #'epi-test-ledger-io--wave4-unexpected-writer)
           (epi-ledger--flush-function
            #'epi-test-ledger-io--wave4-unexpected-writer))
      (cl-letf (((symbol-function 'epi-ledger--acquire-lock)
                 #'epi-test-ledger-io--wave4-unexpected-lock))
        (epi-test-ledger-io--wave4-should-code
            'epi-ledger-format-error 'finished-without-start
          (epi-ledger--append
           ledger (vector (epi-test-ledger-io--tool-finished)))))
      (epi-test-ledger-io--wave4-assert-snapshot ledger snapshot)))
  ;; A missing backward reference is accepted by per-record validation and is
  ;; rejected only when the proposed suffix reaches semantic EOF.
  (epi-test-with-temporary-root (root)
    (let* ((prefix (cl-subseq (epi-test-ledger-io--full-drafts) 0 4))
           (ledger (epi-test-ledger-io--open-history root prefix))
           (snapshot (epi-test-ledger-io--wave4-snapshot ledger))
           (draft (epi-test-ledger-io--proposal))
           (real-validate
            (symbol-function 'epi-ledger--validate-record-semantic))
           (real-final
            (symbol-function 'epi-ledger--validation-final-error))
           (validate-count 0)
           (final-count 0)
           validation-returned
           (epi-ledger--append-function
            #'epi-test-ledger-io--wave4-unexpected-writer)
           (epi-ledger--flush-function
            #'epi-test-ledger-io--wave4-unexpected-writer))
      (setf (epi-draft-parent draft)
            "70000000-0000-4000-8000-000000000099")
      (cl-letf
          (((symbol-function 'epi-ledger--validate-record-semantic)
            (lambda (state header record)
              (setq validate-count (1+ validate-count))
              (let ((result (funcall real-validate state header record)))
                (setq validation-returned t)
                result)))
           ((symbol-function 'epi-ledger--validation-final-error)
            (lambda (state)
              (setq final-count (1+ final-count))
              (let ((result (funcall real-final state)))
                (should (eq 'missing-parent (car result)))
                result)))
           ((symbol-function 'epi-ledger--acquire-lock)
            #'epi-test-ledger-io--wave4-unexpected-lock))
        (epi-test-ledger-io--wave4-should-code
            'epi-ledger-format-error 'missing-parent
          (epi-ledger--append ledger (vector draft))))
      (should (= 1 validate-count))
      (should validation-returned)
      (should (= 1 final-count))
      (epi-test-ledger-io--wave4-assert-snapshot ledger snapshot))))

(ert-deftest epi-ledger-append-preseals-successive-linked-records ()
  (should (fboundp 'epi-ledger--append))
  (should (fboundp 'epi-ledger--prepare-record-batch))
  (should (fboundp 'epi-ledger--fill-owned-draft-defaults))
  (should (fboundp 'epi-ledger--semantic-capsule-clone))
  (should (fboundp 'epi-ledger--validate-record-semantic))
  (should (fboundp 'epi-ledger--validation-final-error))
  (epi-test-with-temporary-root (root)
    (let* ((prefix (cl-subseq (epi-test-ledger-io--full-drafts) 0 4))
           (ledger (epi-test-ledger-io--open-history root prefix))
           (checkpoint (epi-ledger--checkpoint-snapshot ledger))
           (capsule
            (epi-ledger--checkpoint-raw-semantic-capsule checkpoint))
           (capsule-before
            (epi-test-ledger-io--wave4-capsule-fingerprint capsule))
           (snapshot (epi-test-ledger-io--wave4-snapshot ledger))
           (old-tail (epi-ledger--checkpoint-raw-tail-hash checkpoint))
           (first-sequence
            (1+ (epi-ledger--record-source-length
                 (epi-ledger--checkpoint-raw-records checkpoint))))
           (drafts
            (vector (epi-test-ledger-io--proposal)
                    (epi-test-ledger-io--tool-planned)))
           (real-clone
            (symbol-function 'epi-ledger--semantic-capsule-clone))
           (real-validate
            (symbol-function 'epi-ledger--validate-record-semantic))
           (real-final
            (symbol-function 'epi-ledger--validation-final-error))
           (real-seal (symbol-function 'epi-ledger-seal-record))
           (real-render (symbol-function 'epi-ledger-render-record))
           (real-prepare
            (symbol-function 'epi-ledger--prepare-record-batch))
           (clone-count 0)
           (final-count 0)
           clone validated sealed rendered prepared append-prepared winner
           (epi-ledger--append-function
            #'epi-test-ledger-io--wave4-unexpected-writer)
           (epi-ledger--flush-function
            #'epi-test-ledger-io--wave4-unexpected-writer))
      ;; Exercise the preparation helper directly so a losing append cannot
      ;; hide malformed returned frames or suffix metadata.
      (cl-letf
          (((symbol-function 'epi-ledger--semantic-capsule-clone)
            (lambda (candidate)
              (should (eq capsule candidate))
              (setq clone-count (1+ clone-count)
                    clone (funcall real-clone candidate))
              clone))
           ((symbol-function 'epi-ledger--validate-record-semantic)
            (lambda (state header record)
              (should (eq clone state))
              (push record validated)
              (funcall real-validate state header record)))
           ((symbol-function 'epi-ledger--validation-final-error)
            (lambda (state)
              (should (eq clone state))
              (setq final-count (1+ final-count))
              (let ((result (funcall real-final state)))
                (should-not result)
                result)))
           ((symbol-function 'epi-ledger-seal-record)
            (lambda (&rest arguments)
              (let ((record (apply real-seal arguments)))
                (push record sealed)
                record)))
           ((symbol-function 'epi-ledger-render-record)
            (lambda (record)
              (let ((frame (funcall real-render record)))
                (push frame rendered)
                frame))))
        (setq prepared (epi-test-ledger-io--wave4-prepare ledger drafts)))
      (setq validated (nreverse validated)
            sealed (nreverse sealed)
            rendered (nreverse rendered))
      (should (= 1 clone-count))
      (should (= 1 final-count))
      (should (= 2 (length validated)))
      (should (= 2 (length sealed)))
      (should (= 2 (length rendered)))
      (should (cl-every #'eq sealed validated))
      (epi-test-ledger-io--assert-disjoint-graphs
       (epi-test-ledger-io--capsule-roots capsule)
       (epi-test-ledger-io--validation-roots clone))
      (should (equal capsule-before
                     (epi-test-ledger-io--wave4-capsule-fingerprint capsule)))
      (epi-test-ledger-io--wave4-assert-prepared prepared sealed rendered)
      (let ((proposal (nth 0 sealed))
            (plan (nth 1 sealed)))
        (should (= first-sequence (epi-record-sequence proposal)))
        (should (= (1+ first-sequence) (epi-record-sequence plan)))
        (should (equal old-tail (epi-record-previous-hash proposal)))
        (should (equal (epi-record-hash proposal)
                       (epi-record-previous-hash plan)))
        (should-not (equal (epi-record-hash proposal)
                           (epi-record-hash plan)))
        (should (equal epi-test-ledger-io--proposal-id
                       (epi-record-target plan))))
      ;; The append orchestration must consume the same exact prepared
      ;; contract while leaving the authoritative capsule untouched.
      (cl-letf
          (((symbol-function 'epi-ledger--prepare-record-batch)
            (lambda (&rest arguments)
              (setq append-prepared (apply real-prepare arguments)
                    winner
                    (epi-test-ledger-io--wave4-race-winner checkpoint))
              (should (epi-ledger--checkpoint-cas
                       ledger checkpoint winner))
              append-prepared))
           ((symbol-function 'epi-ledger--acquire-lock)
            #'epi-test-ledger-io--wave4-unexpected-lock))
        (epi-test-ledger-io--wave4-should-code
            'epi-ledger-conflict 'stale-checkpoint
          (epi-ledger--append ledger drafts)))
      (should append-prepared)
      (should
       (equal-including-properties
        (epi-test-ledger-io--wave4-prepared-field prepared :suffix)
        (epi-test-ledger-io--wave4-prepared-field append-prepared :suffix)))
      (should
       (equal (epi-test-ledger-io--wave4-prepared-field prepared :final-hash)
              (epi-test-ledger-io--wave4-prepared-field
               append-prepared :final-hash)))
      (should (equal capsule-before
                     (epi-test-ledger-io--wave4-capsule-fingerprint capsule)))
      (epi-test-ledger-io--wave4-assert-snapshot
       ledger snapshot winner))))

(ert-deftest epi-ledger-append-rejects-stale-checkpoint-before-writing ()
  (should (fboundp 'epi-ledger--append))
  (should (fboundp 'epi-ledger--acquire-lock))
  (should (fboundp 'epi-ledger--release-lock))
  (should (fboundp 'epi-ledger--verify-file-state))
  (should (fboundp 'epi-ledger--lock-path))
  (should (fboundp 'epi-ledger--lock-p))
  (should (fboundp 'epi-ledger--lock-lock-file))
  (should (fboundp 'epi-ledger--lock-bytes))
  (should (fboundp 'epi-ledger--lock-sha256))
  (should (fboundp 'epi-ledger--lock-file-identity))
  (epi-test-with-temporary-root (root)
    (let* ((ledger
            (epi-test-ledger-io--open-history
             root (list (epi-test-ledger-io--session-info))))
           (path (epi-ledger--raw-path ledger))
           (lock-path (epi-ledger--lock-path path))
           (expected (epi-ledger--checkpoint-snapshot ledger))
           (expected-file
            (epi-ledger--checkpoint-raw-file-identity expected))
           (expected-end
            (epi-ledger--checkpoint-raw-validated-end-offset expected))
           (expected-head (epi-ledger--checkpoint-raw-tail-hash expected))
           (expected-token
            (epi-test-ledger-io--wave4-lock-token-bytes
             path expected-file expected-end expected-head))
           (snapshot (epi-test-ledger-io--wave4-snapshot ledger))
           (real-acquire (symbol-function 'epi-ledger--acquire-lock))
           (real-release (symbol-function 'epi-ledger--release-lock))
           acquired acquired-bytes acquired-sha256 acquired-identity
           released winner
           (epi--id-function
            (lambda () epi-test-ledger-io--wave4-lock-nonce))
           (epi-ledger--append-function
            #'epi-test-ledger-io--wave4-unexpected-writer)
           (epi-ledger--flush-function
            #'epi-test-ledger-io--wave4-unexpected-writer))
      (cl-letf
          (((symbol-function 'process-attributes)
            #'epi-test-ledger-io--wave4-process-attributes)
           ((symbol-function 'epi-ledger--acquire-lock)
            (lambda (&rest arguments)
              (should (= 4 (length arguments)))
              (should (equal path (nth 0 arguments)))
              (should (equal expected-file (nth 1 arguments)))
              (should (= expected-end (nth 2 arguments)))
              (should (equal expected-head (nth 3 arguments)))
              (let ((lock (apply real-acquire arguments)))
                (setq acquired lock
                      acquired-bytes (epi-ledger--lock-bytes lock)
                      acquired-sha256 (epi-ledger--lock-sha256 lock)
                      acquired-identity
                      (epi-ledger--lock-file-identity lock))
                (epi-test-ledger-io--wave4-assert-owned-lock
                 lock lock-path expected-token
                 expected-file expected-end expected-head)
                (setq winner
                      (epi-test-ledger-io--wave4-race-winner expected))
                (should (epi-ledger--checkpoint-cas
                         ledger expected winner))
                lock)))
           ((symbol-function 'epi-ledger--release-lock)
            (lambda (lock)
              (should (eq acquired lock))
              (epi-test-ledger-io--wave4-assert-owned-lock
               lock lock-path expected-token
               expected-file expected-end expected-head)
              (should (equal acquired-bytes (epi-ledger--lock-bytes lock)))
              (should (equal acquired-sha256
                             (epi-ledger--lock-sha256 lock)))
              (should (equal acquired-identity
                             (epi-ledger--lock-file-identity lock)))
              (setq released lock)
              (funcall real-release lock)
              (should-not (file-exists-p lock-path)))))
        (epi-test-ledger-io--wave4-should-code
            'epi-ledger-conflict 'stale-checkpoint
          (epi-ledger--append
           ledger (vector (epi-test-ledger-io--operation-started)))))
      (should winner)
      (should (eq acquired released))
      (should (equal acquired-bytes (epi-ledger--lock-bytes released)))
      (should (equal acquired-sha256
                     (secure-hash 'sha256 acquired-bytes)))
      ;; The injected winner is the one intentional checkpoint change.  The
      ;; losing append must preserve it by identity and preserve all bytes.
      (epi-test-ledger-io--wave4-assert-snapshot ledger snapshot winner)
      (should-not (file-exists-p lock-path))))
  ;; A successful post-lock verifier is itself a callback boundary.  Inject
  ;; each external authority race only after that verifier has returned
  ;; success.  The immediate-prewrite sandwich must then repeat checkpoint
  ;; identity plus complete file identity/EOF/head validation without reaching
  ;; the writer; one verifier call with no post-callback sandwich is unsound.
  (dolist (case
           (epi-test-ledger-io--wave4-race-cases
            '((checkpoint . stale-checkpoint)
              (replacement . file-identity-changed)
              (device . file-identity-changed)
              (inode . file-identity-changed)
              (links . file-identity-changed)
              (modified . file-identity-changed)
              (changed . file-identity-changed)
              (wrong-eof . file-end-changed)
              (changed-head . file-chain-head-changed))))
    (epi-test-with-temporary-root (root)
      (let* ((ledger
              (epi-test-ledger-io--open-history
               root (list (epi-test-ledger-io--session-info))))
             (path (epi-ledger--raw-path ledger))
             (lock-path (epi-ledger--lock-path path))
             (expected (epi-ledger--checkpoint-snapshot ledger))
             (expected-file
              (epi-ledger--checkpoint-raw-file-identity expected))
             (expected-end
              (epi-ledger--checkpoint-raw-validated-end-offset expected))
             (expected-head
              (epi-ledger--checkpoint-raw-tail-hash expected))
             (expected-token
              (epi-test-ledger-io--wave4-lock-token-bytes
               path expected-file expected-end expected-head))
             (wrong-head
              (concat (if (= (aref expected-head 0) ?0) "1" "0")
                      (substring expected-head 1)))
             (snapshot (epi-test-ledger-io--wave4-snapshot ledger))
             (kind (car case))
             (expected-code (cdr case))
             (real-acquire (symbol-function 'epi-ledger--acquire-lock))
             (real-release (symbol-function 'epi-ledger--release-lock))
             (real-verify (symbol-function 'epi-ledger--verify-file-state))
             (real-stat epi-ledger--stat-function)
             (real-read epi-ledger--read-function)
             (verify-calls 0)
             (successful-verifiers 0)
             (post-success-stat-count 0)
             (post-success-read-count 0)
             (writer-count 0)
             injected post-success acquired released winner
             (epi--id-function
              (lambda () epi-test-ledger-io--wave4-lock-nonce))
             (epi-ledger--stat-function
              (lambda (candidate)
                (let ((identity (funcall real-stat candidate)))
                  (if (and post-success (equal candidate path) identity)
                      (progn
                        (setq post-success-stat-count
                              (1+ post-success-stat-count))
                        (pcase kind
                          ((or 'replacement 'device 'inode 'links
                               'modified 'changed)
                           (epi-test-ledger-io--wave4-mutated-identity
                            identity kind))
                          ('wrong-eof
                           (plist-put (copy-tree identity) :size
                                      (1+ (plist-get identity :size))))
                          (_ identity)))
                    identity))))
             (epi-ledger--read-function
              (lambda (candidate begin end)
                (let ((bytes (funcall real-read candidate begin end)))
                  (if (and post-success (equal candidate path))
                      (progn
                        (setq post-success-read-count
                              (1+ post-success-read-count))
                        (if (eq kind 'changed-head)
                            (replace-regexp-in-string
                             (regexp-quote expected-head) wrong-head bytes t t)
                          bytes))
                    bytes))))
             (epi-ledger--append-function
              (lambda (&rest arguments)
                (setq writer-count (1+ writer-count))
                (apply #'epi-test-ledger-io--wave4-unexpected-writer
                       arguments)))
             (epi-ledger--flush-function
              #'epi-test-ledger-io--wave4-unexpected-writer))
        (cl-letf
            (((symbol-function 'process-attributes)
              #'epi-test-ledger-io--wave4-process-attributes)
             ((symbol-function 'epi-ledger--acquire-lock)
              (lambda (&rest arguments)
                (setq acquired (apply real-acquire arguments))
                (epi-test-ledger-io--wave4-assert-owned-lock
                 acquired lock-path expected-token
                 expected-file expected-end expected-head)
                acquired))
             ((symbol-function 'epi-ledger--verify-file-state)
              (lambda (&rest arguments)
                (setq verify-calls (1+ verify-calls))
                (let ((result (apply real-verify arguments)))
                  (setq successful-verifiers (1+ successful-verifiers))
                  (unless injected
                    (setq injected t)
                    (if (eq kind 'checkpoint)
                        (progn
                          (setq winner
                                (epi-test-ledger-io--wave4-race-winner
                                 expected))
                          (should (epi-ledger--checkpoint-cas
                                   ledger expected winner)))
                      (setq post-success t)))
                  result)))
             ((symbol-function 'epi-ledger--release-lock)
              (lambda (lock)
                (should (eq acquired lock))
                (epi-test-ledger-io--wave4-assert-owned-lock
                 lock lock-path expected-token
                 expected-file expected-end expected-head)
                (setq released lock)
                (funcall real-release lock)
                (should-not (file-exists-p lock-path)))))
          (epi-test-ledger-io--wave4-should-code
              'epi-ledger-conflict expected-code
            (epi-ledger--append
             ledger (vector (epi-test-ledger-io--operation-started)))))
        (should injected)
        (should (= 1 successful-verifiers))
        (should (> verify-calls 0))
        (should (= 0 writer-count))
        (should (eq acquired released))
        (if (eq kind 'checkpoint)
            (progn
              (should winner)
              (epi-test-ledger-io--wave4-assert-snapshot
               ledger snapshot winner))
          (should post-success)
          (should (> post-success-stat-count 0))
          (when (eq kind 'changed-head)
            (should (> post-success-read-count 0)))
          (epi-test-ledger-io--wave4-assert-snapshot ledger snapshot))
        (should-not (file-exists-p lock-path)))))
  ;; A non-error nonlocal exit under the lock must still release the exact
  ;; token.  In particular, cooperative `quit' cannot strand a live lock.
  (epi-test-with-temporary-root (root)
    (let* ((ledger
            (epi-test-ledger-io--open-history
             root (list (epi-test-ledger-io--session-info))))
           (path (epi-ledger--raw-path ledger))
           (lock-path (epi-ledger--lock-path path))
           (snapshot (epi-test-ledger-io--wave4-snapshot ledger))
           (real-acquire (symbol-function 'epi-ledger--acquire-lock))
           (real-release (symbol-function 'epi-ledger--release-lock))
           (verify-count 0)
           acquired released
           condition
           (epi--id-function
            (lambda () epi-test-ledger-io--wave4-lock-nonce))
           (epi-ledger--append-function
            #'epi-test-ledger-io--wave4-unexpected-writer)
           (epi-ledger--flush-function
            #'epi-test-ledger-io--wave4-unexpected-writer))
      (cl-letf
          (((symbol-function 'process-attributes)
            #'epi-test-ledger-io--wave4-process-attributes)
           ((symbol-function 'epi-ledger--acquire-lock)
            (lambda (&rest arguments)
              (setq acquired (apply real-acquire arguments))))
           ((symbol-function 'epi-ledger--verify-file-state)
            (lambda (&rest _arguments)
              (setq verify-count (1+ verify-count))
              (signal 'quit nil)))
           ((symbol-function 'epi-ledger--release-lock)
            (lambda (lock)
              (should (eq acquired lock))
              (setq released lock)
              (funcall real-release lock))))
        (setq condition
              (condition-case caught
                  (epi-ledger--append
                   ledger (vector (epi-test-ledger-io--operation-started)))
                (quit caught))))
      (should (eq 'quit (car condition)))
      (should (= 1 verify-count))
      (should acquired)
      (should (eq acquired released))
      (should-not (file-exists-p lock-path))
      (epi-test-ledger-io--wave4-assert-snapshot ledger snapshot)))
)

(ert-deftest epi-ledger-append-rejects-replaced-file-wrong-eof-and-changed-head ()
  (should (fboundp 'epi-ledger--append))
  (should (fboundp 'epi-ledger--acquire-lock))
  (should (fboundp 'epi-ledger--release-lock))
  (should (fboundp 'epi-ledger--verify-file-state))
  (dolist (case
           (epi-test-ledger-io--wave4-race-cases
            '((replacement . file-identity-changed)
              (device . file-identity-changed)
              (inode . file-identity-changed)
              (links . file-identity-changed)
              (modified . file-identity-changed)
              (changed . file-identity-changed)
              (wrong-eof . file-end-changed)
              (changed-head . file-chain-head-changed))))
    (epi-test-with-temporary-root (root)
      (let* ((ledger
              (epi-test-ledger-io--open-history
               root (list (epi-test-ledger-io--session-info))))
             (path (epi-ledger--raw-path ledger))
             (lock-path (epi-ledger--lock-path path))
             (checkpoint (epi-ledger--checkpoint-snapshot ledger))
             (expected-file
              (epi-ledger--checkpoint-raw-file-identity checkpoint))
             (expected-end
              (epi-ledger--checkpoint-raw-validated-end-offset checkpoint))
             (expected-head
              (epi-ledger--checkpoint-raw-tail-hash checkpoint))
             (expected-token
              (epi-test-ledger-io--wave4-lock-token-bytes
               path expected-file expected-end expected-head))
             (wrong-head
              (concat (if (= (aref expected-head 0) ?0) "1" "0")
                      (substring expected-head 1)))
             (snapshot (epi-test-ledger-io--wave4-snapshot ledger))
             (kind (car case))
             (expected-code (cdr case))
             (post-lock nil)
             (ledger-read-count 0)
             (writer-count 0)
             (real-acquire (symbol-function 'epi-ledger--acquire-lock))
             (real-release (symbol-function 'epi-ledger--release-lock))
             (real-stat epi-ledger--stat-function)
             (real-read epi-ledger--read-function)
             acquired released
             (epi--id-function
              (lambda () epi-test-ledger-io--wave4-lock-nonce))
             (epi-ledger--stat-function
              (lambda (candidate)
                (let ((identity (funcall real-stat candidate)))
                  (if (and post-lock (equal candidate path) identity)
                      (pcase kind
                        ((or 'replacement 'device 'inode 'links
                             'modified 'changed)
                         (epi-test-ledger-io--wave4-mutated-identity
                          identity kind))
                        ('wrong-eof
                         (plist-put
                          (copy-tree identity) :size
                          (1+ (plist-get identity :size))))
                        (_ identity))
                    identity))))
             (epi-ledger--read-function
              (lambda (candidate begin end)
                (let ((bytes (funcall real-read candidate begin end)))
                  (if (and post-lock (eq kind 'changed-head)
                           (equal candidate path))
                      (progn
                        (setq ledger-read-count (1+ ledger-read-count))
                        (unless (string-match-p
                                 (regexp-quote expected-head) bytes)
                          (ert-fail
                           "head-verification read omitted the stored head"))
                        (replace-regexp-in-string
                         (regexp-quote expected-head) wrong-head bytes t t))
                    bytes))))
             (epi-ledger--append-function
              (lambda (&rest arguments)
                (setq writer-count (1+ writer-count))
                (apply #'epi-test-ledger-io--wave4-unexpected-writer
                       arguments)))
             (epi-ledger--flush-function
              #'epi-test-ledger-io--wave4-unexpected-writer))
        (cl-letf
            (((symbol-function 'process-attributes)
              #'epi-test-ledger-io--wave4-process-attributes)
             ((symbol-function 'epi-ledger--acquire-lock)
              (lambda (&rest arguments)
                (should (= 4 (length arguments)))
                (should (equal path (nth 0 arguments)))
                (should (equal expected-file (nth 1 arguments)))
                (should (= expected-end (nth 2 arguments)))
                (should (equal expected-head (nth 3 arguments)))
                (setq acquired (apply real-acquire arguments))
                (epi-test-ledger-io--wave4-assert-owned-lock
                 acquired lock-path expected-token
                 expected-file expected-end expected-head)
                (setq post-lock t)
                acquired))
             ((symbol-function 'epi-ledger--release-lock)
              (lambda (lock)
                (should (eq acquired lock))
                (epi-test-ledger-io--wave4-assert-owned-lock
                 lock lock-path expected-token
                 expected-file expected-end expected-head)
                (setq released lock)
                (funcall real-release lock)
                (should-not (file-exists-p lock-path)))))
          (epi-test-ledger-io--wave4-should-code
              'epi-ledger-conflict expected-code
            (epi-ledger--append
             ledger (vector (epi-test-ledger-io--operation-started)))))
        (should (= 0 writer-count))
        (should (eq acquired released))
        (when (eq kind 'changed-head)
          (should (> ledger-read-count 0)))
        (epi-test-ledger-io--wave4-assert-snapshot ledger snapshot)
        (should-not (file-exists-p lock-path)))))
  ;; A lower-level structured read failure is normalized at the verifier
  ;; boundary; storage implementation codes never escape prewrite head checks.
  (epi-test-with-temporary-root (root)
    (let* ((ledger
            (epi-test-ledger-io--open-history
             root (list (epi-test-ledger-io--session-info))))
           (path (epi-ledger--raw-path ledger))
           (lock-path (epi-ledger--lock-path path))
           (snapshot (epi-test-ledger-io--wave4-snapshot ledger))
           (real-read epi-ledger--read-function)
           (ledger-read-count 0)
           (epi--id-function
            (lambda () epi-test-ledger-io--wave4-lock-nonce))
           (epi-ledger--read-function
            (lambda (candidate begin end)
              (if (equal candidate path)
                  (progn
                    (setq ledger-read-count (1+ ledger-read-count))
                    (epi-ledger--fail
                     'epi-ledger-conflict 'storage-read-failed))
                (funcall real-read candidate begin end))))
           (epi-ledger--append-function
            #'epi-test-ledger-io--wave4-unexpected-writer)
           (epi-ledger--flush-function
            #'epi-test-ledger-io--wave4-unexpected-writer))
      (cl-letf (((symbol-function 'process-attributes)
                 #'epi-test-ledger-io--wave4-process-attributes))
        (epi-test-ledger-io--wave4-should-code
            'epi-ledger-conflict 'file-chain-head-changed
          (epi-ledger--append
           ledger (vector (epi-test-ledger-io--operation-started)))))
      (should (= 1 ledger-read-count))
      (should-not (file-exists-p lock-path))
      (epi-test-ledger-io--wave4-assert-snapshot ledger snapshot))))

(ert-deftest epi-ledger-append-rechecks-checkpoint-after-prevalidation-yields ()
  (should (fboundp 'epi-ledger--append))
  (should (fboundp 'epi-ledger--prepare-record-batch))
  (should (fboundp 'epi-ledger--acquire-lock))
  (epi-test-with-temporary-root (root)
    (let* ((ledger
            (epi-test-ledger-io--open-history
             root (list (epi-test-ledger-io--session-info))))
           (expected (epi-ledger--checkpoint-snapshot ledger))
           (snapshot (epi-test-ledger-io--wave4-snapshot ledger))
           (real-prepare
            (symbol-function 'epi-ledger--prepare-record-batch))
           (armed nil)
           (prepare-count 0)
           (yield-count 0)
           winner
           (epi--yield-function
            (lambda ()
              (when armed
                (setq yield-count (1+ yield-count)
                      winner
                      (epi-test-ledger-io--wave4-race-winner expected))
                (should (epi-ledger--checkpoint-cas ledger expected winner)))))
           (epi-ledger--append-function
            #'epi-test-ledger-io--wave4-unexpected-writer)
           (epi-ledger--flush-function
            #'epi-test-ledger-io--wave4-unexpected-writer))
      (cl-letf
          (((symbol-function 'epi-ledger--prepare-record-batch)
            (lambda (&rest arguments)
              (let ((prepared (apply real-prepare arguments)))
                (setq prepare-count (1+ prepare-count)
                      armed t)
                (unwind-protect
                    (progn (epi--yield) prepared)
                  (setq armed nil)))))
           ((symbol-function 'epi-ledger--acquire-lock)
            #'epi-test-ledger-io--wave4-unexpected-lock))
        (epi-test-ledger-io--wave4-should-code
            'epi-ledger-conflict 'stale-checkpoint
          (epi-ledger--append
           ledger (vector (epi-test-ledger-io--operation-started)))))
      (should (= 1 prepare-count))
      (should (= 1 yield-count))
      (should winner)
      (epi-test-ledger-io--wave4-assert-snapshot ledger snapshot winner))))

(ert-deftest epi-ledger-append-never-replays-or-copies-prefix-records ()
  (should (fboundp 'epi-ledger--append))
  (should (fboundp 'epi-ledger--prepare-record-batch))
  (should (fboundp 'epi-ledger--fill-owned-draft-defaults))
  (epi-test-with-temporary-root (root)
    (let* ((ledger
            (epi-test-ledger-io--open-history
             root (epi-test-ledger-io--full-drafts)))
           (checkpoint (epi-ledger--checkpoint-snapshot ledger))
           (prefix-source
            (epi-ledger--checkpoint-raw-records checkpoint))
           (prefix-count
            (epi-ledger--record-source-length
             prefix-source))
           (prefix-records
            (cl-loop for index below prefix-count
                     collect (epi-ledger--record-source-elt
                              prefix-source index)))
           (prefix-set
            (let ((table (make-hash-table :test #'eq)))
              (dolist (record prefix-records)
                (puthash record t table))
              table))
           (snapshot (epi-test-ledger-io--wave4-snapshot ledger))
           (real-validate
            (symbol-function 'epi-ledger--validate-record-semantic))
           (real-hash (symbol-function 'epi-ledger--hash))
           (real-seal (symbol-function 'epi-ledger-seal-record))
           (real-render (symbol-function 'epi-ledger-render-record))
           (real-make-record (symbol-function 'epi-ledger--make-record))
           (real-generated-copy (symbol-function 'copy-epi-record))
           (real-prepare
            (symbol-function 'epi-ledger--prepare-record-batch))
           validated-records hash-inputs sealed rendered-records
           constructed winner
           (epi-ledger--append-function
            #'epi-test-ledger-io--wave4-unexpected-writer)
           (epi-ledger--flush-function
            #'epi-test-ledger-io--wave4-unexpected-writer))
      (cl-letf
          (((symbol-function 'epi-ledger--validate-record-semantic)
           (lambda (state header record)
              (push record validated-records)
              (funcall real-validate state header record)))
           ((symbol-function 'epi-ledger--hash)
            (lambda (bytes field)
              (let* ((owned (substring-no-properties bytes))
                     (result (funcall real-hash bytes field)))
                (push (list field owned result) hash-inputs)
                result)))
           ((symbol-function 'epi-ledger-seal-record)
            (lambda (&rest arguments)
              (let ((record (apply real-seal arguments)))
                (push record sealed)
                record)))
           ((symbol-function 'epi-ledger-render-record)
            (lambda (record)
              (when (gethash record prefix-set)
                (ert-fail
                 (format "prewrite rendered prefix record: %S" record)))
              (push record rendered-records)
              (funcall real-render record)))
           ((symbol-function 'epi-ledger--make-record)
            (lambda (&rest arguments)
              (let ((record (apply real-make-record arguments)))
                (push record constructed)
                record)))
           ((symbol-function 'epi-ledger--record-source-each)
            (lambda (&rest arguments)
              (ert-fail (format "prewrite replayed prefix: %S" arguments))))
           ((symbol-function 'epi-ledger--record-source-elt)
            (lambda (&rest arguments)
              (ert-fail
               (format "prewrite indexed prefix source: %S" arguments))))
           ((symbol-function 'epi-ledger--copy-record)
            (lambda (&rest arguments)
              (ert-fail (format "prewrite copied prefix record: %S"
                                arguments))))
           ((symbol-function 'copy-epi-record)
            (lambda (record)
              (when (gethash record prefix-set)
                (ert-fail
                 (format "prewrite used generated prefix copier: %S"
                         record)))
              (funcall real-generated-copy record)))
           ((symbol-function 'epi-ledger-records)
            (lambda (&rest arguments)
              (ert-fail (format "prewrite called public record projection: %S"
                                arguments))))
           ((symbol-function 'epi-ledger-record-by-id)
            (lambda (&rest arguments)
              (ert-fail (format "prewrite called public record lookup: %S"
                                arguments))))
           ((symbol-function 'epi-ledger--prepare-record-batch)
            (lambda (&rest arguments)
              (let ((prepared (apply real-prepare arguments)))
                (setq winner
                      (epi-test-ledger-io--wave4-race-winner checkpoint))
                (should (epi-ledger--checkpoint-cas
                         ledger checkpoint winner))
                prepared)))
           ((symbol-function 'epi-ledger--acquire-lock)
            #'epi-test-ledger-io--wave4-unexpected-lock))
        (epi-test-ledger-io--wave4-should-code
            'epi-ledger-conflict 'stale-checkpoint
          (epi-ledger--append
           ledger (vector (epi-test-ledger-io--wave4-next-operation)))))
      (setq validated-records (nreverse validated-records)
            hash-inputs (nreverse hash-inputs)
            sealed (nreverse sealed)
            rendered-records (nreverse rendered-records)
            constructed (nreverse constructed))
      (should (= 12 prefix-count))
      (should
       (equal (list (1+ prefix-count))
              (mapcar #'epi-record--raw-sequence validated-records)))
      (should (= 1 (length sealed)))
      (should (cl-every #'eq sealed validated-records))
      (should (= (length sealed) (length rendered-records)))
      (should (cl-every #'eq sealed rendered-records))
      ;; `epi-ledger-seal-record' may construct a provisional unhashed record
      ;; before the final sealed one.  Every raw construction must nevertheless
      ;; belong to this one-record suffix; using the constructor as a hidden
      ;; prefix-copy path is forbidden.  Exact final identity is asserted above
      ;; at the validator boundary because compiled constructors may be inlined.
      (should constructed)
      (dolist (record constructed)
        (should (equal (epi-record--raw-id (car sealed))
                       (epi-record--raw-id record)))
        (should (= (epi-record--raw-sequence (car sealed))
                   (epi-record--raw-sequence record))))
      (let ((suffix-hash (epi-record--raw-hash (car sealed))))
        (should hash-inputs)
        ;; Every hash call, regardless of its caller-supplied field label,
        ;; must be for this one new suffix record.  A wrapper cannot hide a
        ;; prefix hash by changing the label away from `record'.
        (dolist (entry hash-inputs)
          (should (equal suffix-hash (nth 2 entry)))
          (should (equal suffix-hash
                         (secure-hash 'sha256 (nth 1 entry))))))
      (let ((retained
             (epi-ledger--checkpoint-raw-records winner)))
        (should (eq prefix-source retained))
        (dotimes (index prefix-count)
          (should (eq (nth index prefix-records)
                      (epi-ledger--record-source-elt retained index)))))
      (epi-test-ledger-io--wave4-assert-snapshot
       ledger snapshot winner))))

;;;; Wave 5: append, realized validation, publication, and ambiguity

(defconst epi-test-ledger-io--wave5-lock-nonce
  "77777777-7777-4777-8777-777777777777"
  "Deterministic lock nonce used by Wave 5 tests.")

(defun epi-test-ledger-io--wave5-process-attributes (pid)
  "Return deterministic current-process attributes for PID."
  (let ((number (if (stringp pid) (string-to-number pid) pid)))
    (and (= number (emacs-pid)) '((start 11 22 33 44)))))

(defmacro epi-test-ledger-io--wave5-with-process (&rest body)
  "Evaluate BODY with deterministic lock-owner identity."
  (declare (indent 0) (debug t))
  `(let ((epi--id-function
          (lambda () epi-test-ledger-io--wave5-lock-nonce)))
     (cl-letf (((symbol-function 'process-attributes)
                #'epi-test-ledger-io--wave5-process-attributes))
       ,@body)))

(defun epi-test-ledger-io--wave5-operation-started
    (record-id operation-id)
  "Return a fixed RECORD-ID start for OPERATION-ID."
  (epi-test-ledger-io--draft
   record-id 'operation-started
   `(("operation_id" . ,operation-id) ("kind" . "prompt"))
   :operation operation-id))

(defun epi-test-ledger-io--wave5-operation-interrupted
    (record-id operation-id)
  "Return a fixed RECORD-ID terminal for OPERATION-ID."
  (epi-test-ledger-io--draft
   record-id 'operation-interrupted
   `(("operation_id" . ,operation-id) ("reason" . "interrupted"))
   :operation operation-id))

(defun epi-test-ledger-io--wave5-batch (&optional alternate)
  "Return one complete valid two-record append batch.
When ALTERNATE is non-nil, use IDs disjoint from the primary batch."
  (let ((operation
         (if alternate
             "80000000-0000-4000-8000-000000000002"
           "80000000-0000-4000-8000-000000000001")))
    (vector
     (epi-test-ledger-io--wave5-operation-started
      (if alternate
          "70000000-0000-4000-8000-000000000003"
        "70000000-0000-4000-8000-000000000001")
      operation)
     (epi-test-ledger-io--wave5-operation-interrupted
      (if alternate
          "70000000-0000-4000-8000-000000000004"
        "70000000-0000-4000-8000-000000000002")
      operation))))

(defun epi-test-ledger-io--wave5-open (root &optional drafts)
  "Open a fixture below ROOT containing DRAFTS or session-info only."
  (epi-test-ledger-io--open-history
   root (or drafts (list (epi-test-ledger-io--session-info)))))

(defun epi-test-ledger-io--wave5-bytes (ledger)
  "Return LEDGER's current exact file bytes."
  (epi-test-ledger-io--literal-file-bytes (epi-ledger--raw-path ledger)))

(defun epi-test-ledger-io--wave5-checkpoint-clone (checkpoint)
  "Return an identity-distinct authority-equivalent CHECKPOINT."
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
   :uncertain (epi-ledger--checkpoint-raw-uncertain checkpoint)))

(defun epi-test-ledger-io--wave5-assert-uncertain-copy (expected current)
  "Assert CURRENT differs from EXPECTED only by storage uncertainty."
  (should-not (eq expected current))
  (should-not (epi-ledger--checkpoint-raw-uncertain expected))
  (should (epi-ledger--checkpoint-raw-uncertain current))
  (dolist (reader
           '(epi-ledger--checkpoint-raw-file-identity
             epi-ledger--checkpoint-raw-validated-end-offset
             epi-ledger--checkpoint-raw-tail-hash
             epi-ledger--checkpoint-raw-records
             epi-ledger--checkpoint-raw-by-id
             epi-ledger--checkpoint-raw-turn-operation-index
             epi-ledger--checkpoint-raw-tool-facts
             epi-ledger--checkpoint-raw-semantic-capsule))
    (should (eq (funcall reader expected) (funcall reader current))))
  current)

(defun epi-test-ledger-io--wave5-assert-uncertain-successor
    (ledger expected)
  "Assert LEDGER published only EXPECTED's uncertain successor."
  (epi-test-ledger-io--wave5-assert-uncertain-copy
   expected (epi-ledger--checkpoint-snapshot ledger)))

(defmacro epi-test-ledger-io--wave5-should-code
    (condition code phase &rest body)
  "Assert BODY signals CONDITION carrying stable Epi CODE and PHASE.
When PHASE is nil, require only CODE."
  (declare (indent 2) (debug t))
  `(let ((caught (should-error (progn ,@body) :type ,condition)))
     (should (eq ,code (epi-test-ledger-io--condition-code caught)))
     (when ,phase
       (let ((phase
              (plist-get (epi-test-ledger-io--condition-detail caught)
                         :phase)))
         (should (eq ,phase phase))))
     caught))

(defun epi-test-ledger-io--wave5-unexpected-write (&rest arguments)
  "Fail when an append path writes unexpected ARGUMENTS."
  (ert-fail (format "unexpected Wave 5 write/retry: %S" arguments)))

(defun epi-test-ledger-io--wave5-flip-first-byte (bytes)
  "Return a same-length copy of unibyte BYTES with byte zero changed."
  (let ((copy (substring-no-properties bytes)))
    (unless (> (length copy) 0)
      (ert-fail "cannot mutate empty readback"))
    (aset copy 0 (if (= (aref copy 0) ?X) ?Y ?X))
    copy))

(ert-deftest epi-ledger-append-performs-one-data-write-and-one-final-flush ()
  (should (fboundp 'epi-ledger--append))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave5-open root))
           (path (epi-ledger--raw-path ledger))
           (old-end
            (epi-ledger--checkpoint-raw-validated-end-offset
             (epi-ledger--checkpoint-snapshot ledger)))
           (real-append epi-ledger--append-function)
           (real-flush epi-ledger--flush-function)
           (real-read epi-ledger--read-function)
           (append-count 0)
           (flush-count 0)
           (readback-count 0)
           (writer-entered nil)
           (flush-complete nil)
           events
           appended-bytes
           (epi-ledger--append-function
            (lambda (candidate bytes)
              (push 'append events)
              (setq append-count (1+ append-count)
                    appended-bytes (substring-no-properties bytes))
              (should (equal path candidate))
              (prog1 (funcall real-append candidate bytes)
                (setq writer-entered t))))
           (epi-ledger--flush-function
            (lambda (candidate)
              (push 'flush events)
              (setq flush-count (1+ flush-count))
              (should (= 1 append-count))
              (should (equal path candidate))
              (prog1 (funcall real-flush candidate)
                (setq flush-complete t))))
           (epi-ledger--read-function
            (lambda (candidate begin end)
              (let ((bytes (funcall real-read candidate begin end)))
                (when (and writer-entered (equal candidate path)
                           (= begin old-end))
                  (push 'readback events)
                  (setq readback-count (1+ readback-count))
                  (should flush-complete)
                  (should (equal appended-bytes bytes)))
                bytes))))
      (epi-test-ledger-io--wave5-with-process
        (let ((records (epi-ledger--append
                        ledger (epi-test-ledger-io--wave5-batch))))
          (should (vectorp records))
          (should (= 2 (length records)))))
      (should (= 1 append-count))
      (should (= 1 flush-count))
      (should (= 1 readback-count))
      (should (equal '(append flush readback) (nreverse events)))
      (should (stringp appended-bytes))
      (should-not (multibyte-string-p appended-bytes))
      (should (> (length appended-bytes) 0))
      (should-not (file-exists-p (concat path ".epi-lock"))))))

(ert-deftest epi-ledger-append-preserves-the-prefix-byte-for-byte ()
  (should (fboundp 'epi-ledger--append))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave5-open root))
           (before (epi-test-ledger-io--wave5-bytes ledger)))
      (epi-test-ledger-io--wave5-with-process
        (epi-ledger--append ledger (epi-test-ledger-io--wave5-batch)))
      (let ((after (epi-test-ledger-io--wave5-bytes ledger)))
        (should (> (length after) (length before)))
        (should (equal before (substring after 0 (length before))))))))

(ert-deftest epi-ledger-append-publishes-only-realized-records-and-semantic-state ()
  (should (fboundp 'epi-ledger--append))
  (should (fboundp 'epi-ledger--validate-realized-suffix))
  (epi-test-with-temporary-root (root)
    (let* ((prefix (cl-subseq (epi-test-ledger-io--full-drafts) 0 4))
           (ledger (epi-test-ledger-io--wave5-open root prefix))
           (old-checkpoint (epi-ledger--checkpoint-snapshot ledger))
           (old-count
            (epi-ledger--record-source-length
             (epi-ledger--checkpoint-raw-records old-checkpoint)))
           (real-seal (symbol-function 'epi-ledger-seal-record))
           (real-clone
            (symbol-function 'epi-ledger--semantic-capsule-clone))
           (real-realize
            (symbol-function 'epi-ledger--validate-realized-suffix))
           (real-scan (symbol-function 'epi-ledger--scan-frame-owned))
           (realizing nil)
           presealed clones realized returned)
      (cl-letf
          (((symbol-function 'epi-ledger-seal-record)
            (lambda (&rest arguments)
              (let ((record (apply real-seal arguments)))
                (push record presealed)
                record)))
           ((symbol-function 'epi-ledger--semantic-capsule-clone)
            (lambda (capsule)
              (let ((state (funcall real-clone capsule)))
                (push state clones)
                state)))
           ((symbol-function 'epi-ledger--validate-realized-suffix)
            (lambda (&rest arguments)
              (setq realizing t)
              (unwind-protect
                  (apply real-realize arguments)
                (setq realizing nil))))
           ((symbol-function 'epi-ledger--scan-frame-owned)
            (lambda (&rest arguments)
              (let ((scan (apply real-scan arguments)))
                (when (and realizing (plist-get scan :record))
                  (push (plist-get scan :record) realized))
                scan)))
           ((symbol-function 'epi-ledger-open)
            (lambda (&rest arguments)
              (ert-fail
               (format "realized append reopened the whole ledger: %S"
                       arguments)))))
        (epi-test-ledger-io--wave5-with-process
          (setq returned
                (epi-ledger--append
                 ledger
                 (vector (epi-test-ledger-io--proposal)
                         (epi-test-ledger-io--tool-planned))))))
      (setq presealed (nreverse presealed)
            clones (nreverse clones)
            realized (nreverse realized))
      (should (= 2 (length presealed)))
      (should (= 2 (length clones)))
      (should (= 2 (length realized)))
      (should (= 2 (length returned)))
      (let* ((checkpoint (epi-ledger--checkpoint-snapshot ledger))
             (source (epi-ledger--checkpoint-raw-records checkpoint))
             (capsule
              (epi-ledger--checkpoint-raw-semantic-capsule checkpoint))
             (clone-a (nth 0 clones))
             (clone-b (nth 1 clones)))
        (dotimes (index 2)
          (let ((published
                 (epi-ledger--record-source-elt source (+ old-count index))))
            (should (eq published (nth index realized)))
            (should (eq published (aref returned index)))
            (should-not (epi-record--raw-sealed-json published))
            (should-not (memq published presealed))
            (should
             (eq published
                 (gethash
                  (epi-record--raw-id published)
                  (epi-ledger--semantic-capsule-raw-by-id capsule))))))
        (should
         (eq (epi-ledger--checkpoint-raw-by-id checkpoint)
             (epi-ledger--semantic-capsule-raw-by-id capsule)))
        (should
         (eq (epi-ledger--checkpoint-raw-turn-operation-index checkpoint)
             (epi-ledger--semantic-capsule-raw-turn-operation-index capsule)))
        (should
         (eq (epi-ledger--checkpoint-raw-tool-facts checkpoint)
             (epi-ledger--semantic-capsule-raw-calls capsule)))
        (let ((published-roots
               (epi-test-ledger-io--capsule-roots capsule))
              (realized-roots
               (epi-test-ledger-io--validation-roots clone-b)))
          (should (= (length published-roots) (length realized-roots)))
          (cl-mapc
           (lambda (published realized-root)
             (should (eq published realized-root)))
           published-roots realized-roots))
        (should-not
         (eq (epi-ledger--semantic-capsule-raw-by-id capsule)
             (epi-ledger--validation-state-by-id clone-a)))
        (epi-test-ledger-io--assert-disjoint-graphs
         (epi-test-ledger-io--validation-roots clone-a)
         (epi-test-ledger-io--capsule-roots capsule))))))

(ert-deftest epi-ledger-append-updates-identity-end-head-and-record-index ()
  (should (fboundp 'epi-ledger--append))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave5-open root))
           (path (epi-ledger--raw-path ledger))
           (old (epi-ledger--checkpoint-snapshot ledger))
           (old-source (epi-ledger--checkpoint-raw-records old))
           (old-count (epi-ledger--record-source-length old-source))
           returned first-returned)
      (epi-test-ledger-io--wave5-with-process
        (setq returned
              (epi-ledger--append ledger (epi-test-ledger-io--wave5-batch))))
      (let* ((current (epi-ledger--checkpoint-snapshot ledger))
             (source (epi-ledger--checkpoint-raw-records current))
             (end (epi-ledger--checkpoint-raw-validated-end-offset current))
             (identity
              (epi-ledger--checkpoint-raw-file-identity current)))
        (should-not (eq old current))
        (should-not (equal (epi-ledger--checkpoint-raw-file-identity old)
                           identity))
        (should (> end
                   (epi-ledger--checkpoint-raw-validated-end-offset old)))
        (should (= end (length (epi-test-ledger-io--wave5-bytes ledger))))
        (should (= end (plist-get identity :size)))
        (should (equal identity (funcall epi-ledger--stat-function path)))
        (should (= (+ old-count 2)
                   (epi-ledger--record-source-length source)))
        (dotimes (index old-count)
          (should
           (eq (epi-ledger--record-source-elt old-source index)
               (epi-ledger--record-source-elt source index))))
        (dotimes (index 2)
          (should
           (eq (aref returned index)
               (epi-ledger--record-source-elt source (+ old-count index)))))
        (should
         (equal (epi-record--raw-hash (aref returned 1))
                (epi-ledger--checkpoint-raw-tail-hash current)))
        ;; The return container is caller-owned even though its immutable
        ;; record elements are the exact realized published objects.
        (setq first-returned (aref returned 0))
        (aset returned 0 nil)
        (should
         (eq first-returned
             (epi-ledger--record-source-elt source old-count)))))))

(ert-deftest epi-ledger-append-error-after-invocation-marks-handle-uncertain ()
  (should (fboundp 'epi-ledger--append))
  (should (fboundp 'epi-ledger--mark-append-uncertain))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave5-open root))
           (path (epi-ledger--raw-path ledger))
           (expected (epi-ledger--checkpoint-snapshot ledger))
           (before (epi-test-ledger-io--wave5-bytes ledger))
           (real-append epi-ledger--append-function)
           (writer-count 0)
           (flush-count 0)
           written-suffix
           (epi-ledger--append-function
            (lambda (candidate suffix)
              (setq writer-count (1+ writer-count)
                    written-suffix (substring-no-properties suffix))
              (funcall real-append candidate suffix)
              (signal 'file-error '("injected writer failure"))))
           (epi-ledger--flush-function
            (lambda (&rest _arguments)
              (setq flush-count (1+ flush-count))
              (ert-fail "flush followed a signaling writer"))))
      (epi-test-ledger-io--wave5-with-process
        (epi-test-ledger-io--wave5-should-code
            'epi-ledger-conflict 'append-uncertain 'possibly-written
          (epi-ledger--append ledger (epi-test-ledger-io--wave5-batch))))
      (should (= 1 writer-count))
      (should (= 0 flush-count))
      (should (stringp written-suffix))
      (should-not (multibyte-string-p written-suffix))
      (should
       (equal (concat before written-suffix)
              (epi-test-ledger-io--wave5-bytes ledger)))
      (epi-test-ledger-io--wave5-assert-uncertain-successor ledger expected)
      (should-not (file-exists-p (concat path ".epi-lock"))))))

(ert-deftest epi-ledger-append-flush-error-marks-handle-uncertain ()
  (should (fboundp 'epi-ledger--append))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave5-open root))
           (path (epi-ledger--raw-path ledger))
           (expected (epi-ledger--checkpoint-snapshot ledger))
           (before (epi-test-ledger-io--wave5-bytes ledger))
           (real-append epi-ledger--append-function)
           (writer-count 0)
           (flush-count 0)
           (epi-ledger--append-function
            (lambda (path suffix)
              (setq writer-count (1+ writer-count))
              (funcall real-append path suffix)))
           (epi-ledger--flush-function
            (lambda (&rest _arguments)
              (setq flush-count (1+ flush-count))
              (signal 'file-error '("injected flush failure")))))
      (epi-test-ledger-io--wave5-with-process
        (epi-test-ledger-io--wave5-should-code
            'epi-ledger-conflict 'append-uncertain 'possibly-written
          (epi-ledger--append ledger (epi-test-ledger-io--wave5-batch))))
      (should (= 1 writer-count))
      (should (= 1 flush-count))
      (should (> (length (epi-test-ledger-io--wave5-bytes ledger))
                 (length before)))
      (epi-test-ledger-io--wave5-assert-uncertain-successor ledger expected)
      (should-not (file-exists-p (concat path ".epi-lock"))))))

(ert-deftest epi-ledger-append-short-or-mutated-readback-marks-handle-uncertain ()
  (should (fboundp 'epi-ledger--append))
  (dolist (kind '(short mutated))
    (epi-test-with-temporary-root (root)
      (let* ((ledger (epi-test-ledger-io--wave5-open root))
             (path (epi-ledger--raw-path ledger))
             (expected (epi-ledger--checkpoint-snapshot ledger))
             (old-end
              (epi-ledger--checkpoint-raw-validated-end-offset expected))
             (real-append epi-ledger--append-function)
             (real-read epi-ledger--read-function)
             (writer-count 0)
             (readback-count 0)
             (writer-entered nil)
             (epi-ledger--append-function
              (lambda (candidate suffix)
                (setq writer-count (1+ writer-count))
                (prog1 (funcall real-append candidate suffix)
                  (setq writer-entered t))))
             (epi-ledger--read-function
              (lambda (candidate begin end)
                (let ((bytes (funcall real-read candidate begin end)))
                  (if (and writer-entered (equal candidate path)
                           (= begin old-end))
                      (progn
                        (setq readback-count (1+ readback-count))
                        (pcase kind
                          ('short (substring bytes 0 (max 0 (1- (length bytes)))))
                          (_ (epi-test-ledger-io--wave5-flip-first-byte
                              bytes))))
                    bytes)))))
        (epi-test-ledger-io--wave5-with-process
          (epi-test-ledger-io--wave5-should-code
              'epi-ledger-conflict 'append-uncertain 'possibly-written
            (epi-ledger--append ledger (epi-test-ledger-io--wave5-batch))))
        (should (= 1 writer-count))
        (should (= 1 readback-count))
        (epi-test-ledger-io--wave5-assert-uncertain-successor
         ledger expected)
        (should-not (file-exists-p (concat path ".epi-lock"))))))
  ;; On the successful path, all replacement state must exist before the final
  ;; verifier begins.  From verifier entry through publication CAS, only the
  ;; verifier's own storage observations are permitted.  In particular, a
  ;; yield injected inside the verifier after its last real observation must
  ;; be suppressed by the append's no-yield publication boundary.
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave5-open root))
           (path (epi-ledger--raw-path ledger))
           (expected (epi-ledger--checkpoint-snapshot ledger))
           (real-realize
            (symbol-function 'epi-ledger--validate-realized-suffix))
           (real-extend (symbol-function 'epi-ledger--record-source-extend))
           (real-make-checkpoint
            (symbol-function 'epi-ledger--make-checkpoint))
           (real-verify (symbol-function 'epi-ledger--verify-file-state))
           (real-cas (symbol-function 'epi-ledger--checkpoint-cas))
           (real-append epi-ledger--append-function)
           (real-flush epi-ledger--flush-function)
           (real-stat epi-ledger--stat-function)
           (real-read epi-ledger--read-function)
           (real-unlock epi-ledger--unlock-function)
           (post-realized nil)
           (final-phase nil)
           (verification-observing nil)
           (extend-count 0)
           (checkpoint-build-count 0)
           (final-verify-count 0)
           (post-observation-yield-attempts 0)
           (pre-final-yields 0)
           (publication-cas-count 0)
           events
           (epi-ledger-work-byte-limit 1)
           (epi-ledger-work-record-limit 1)
           (epi-ledger-work-time-budget 1000.0)
           (epi--yield-function
            (lambda ()
              (if final-phase
                  (ert-fail
                   "yield callback escaped the final verify/CAS boundary")
                (setq pre-final-yields (1+ pre-final-yields)))))
           (epi-ledger--append-function
            (lambda (&rest arguments)
              (when final-phase
                (ert-fail "append callback occurred in final CAS gap"))
              (apply real-append arguments)))
           (epi-ledger--flush-function
            (lambda (&rest arguments)
              (when final-phase
                (ert-fail "flush callback occurred in final CAS gap"))
              (apply real-flush arguments)))
           (epi-ledger--stat-function
            (lambda (&rest arguments)
              (when (and final-phase (not verification-observing))
                (ert-fail "stat callback occurred in final CAS gap"))
              (apply real-stat arguments)))
           (epi-ledger--read-function
            (lambda (&rest arguments)
              (when (and final-phase (not verification-observing))
                (ert-fail "read callback occurred in final CAS gap"))
              (apply real-read arguments)))
           (epi-ledger--unlock-function
            (lambda (&rest arguments)
              (should-not final-phase)
              (should (= 1 publication-cas-count))
              (push 'unlock events)
              (apply real-unlock arguments))))
      (cl-letf
          (((symbol-function 'epi-ledger--validate-realized-suffix)
            (lambda (&rest arguments)
              (prog1 (apply real-realize arguments)
                (setq post-realized t)
                (push 'realized events))))
           ((symbol-function 'epi-ledger--record-source-extend)
            (lambda (&rest arguments)
              (when final-phase
                (ert-fail "record source built after final verification"))
              (when post-realized
                (setq extend-count (1+ extend-count))
                (push 'extended events))
              (apply real-extend arguments)))
           ((symbol-function 'epi-ledger--make-checkpoint)
            (lambda (&rest arguments)
              (when final-phase
                (ert-fail "checkpoint built after final verification"))
              (when post-realized
                (setq checkpoint-build-count
                      (1+ checkpoint-build-count))
                (push 'checkpoint-built events))
              (apply real-make-checkpoint arguments)))
           ((symbol-function 'epi-ledger--verify-file-state)
            (lambda (&rest arguments)
              (when final-phase
                (ert-fail "second verifier callback occurred in CAS gap"))
              (if (not post-realized)
                  (apply real-verify arguments)
                (should (= 1 extend-count))
                (should (= 1 checkpoint-build-count))
                (setq final-phase t
                      verification-observing t)
                (push 'final-verifier-entered events)
                (let ((result
                       (unwind-protect
                           (apply real-verify arguments)
                         (setq verification-observing nil))))
                  (setq final-verify-count (1+ final-verify-count)
                        post-observation-yield-attempts
                        (1+ post-observation-yield-attempts))
                  (push 'final-verified events)
                  ;; This call occurs after REAL-VERIFY's final observation but
                  ;; before the wrapper returns.  A correct append has already
                  ;; rebound cooperative yielding for the entire final phase.
                  (epi--yield)
                  result))))
           ((symbol-function 'epi-ledger--checkpoint-cas)
            (lambda (candidate old replacement)
              (unless (and final-phase (not verification-observing)
                           (= 1 post-observation-yield-attempts)
                           (eq candidate ledger) (eq old expected))
                (ert-fail
                 (format "publication CAS escaped final barrier: %S"
                         (list candidate old replacement))))
              (setq publication-cas-count (1+ publication-cas-count))
              (push 'published events)
              (prog1 (funcall real-cas candidate old replacement)
                (setq final-phase nil)))))
        (epi-test-ledger-io--wave5-with-process
          (let ((returned
                 (epi-ledger--append
                  ledger (epi-test-ledger-io--wave5-batch))))
            (should (= 2 (length returned))))))
      (should (= 1 extend-count))
      (should (= 1 checkpoint-build-count))
      (should (= 1 final-verify-count))
      (should (= 1 post-observation-yield-attempts))
      (should (> pre-final-yields 0))
      (should (= 1 publication-cas-count))
      (should
       (equal '(realized extended checkpoint-built final-verifier-entered
                final-verified published unlock)
              (nreverse events)))
      (should-not (file-exists-p (concat path ".epi-lock"))))))

(ert-deftest epi-ledger-append-readback-buffer-mutation-is-detected-across-yield ()
  (should (fboundp 'epi-ledger--append))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave5-open root))
           (path (epi-ledger--raw-path ledger))
           (expected (epi-ledger--checkpoint-snapshot ledger))
           (old-end
            (epi-ledger--checkpoint-raw-validated-end-offset expected))
           (real-append epi-ledger--append-function)
           (real-read epi-ledger--read-function)
           (real-realize
            (symbol-function 'epi-ledger--validate-realized-suffix))
           (real-scan (symbol-function 'epi-ledger--scan-frame-owned))
           (decoy (generate-new-buffer " *epi-wave5-readback-decoy*" t))
           (writer-entered nil)
           (writer-count 0)
           (readback-count 0)
           (scan-count 0)
           (mutation-count 0)
           (read-link-observed nil)
           (provenance-observed nil)
           (realizing nil)
           appended-bytes
           trusted-readback-bytes
           trusted-readback-buffer
           (epi-ledger-work-byte-limit 1)
           (epi-ledger-work-record-limit 1)
           (epi-ledger-work-time-budget 1000.0)
           ;; A same-content decoy is deliberately in scope.  The realized
           ;; validator must replace this binding with its exact source buffer.
           (epi-ledger--work-protected-buffer decoy)
           (epi-ledger--append-function
            (lambda (path suffix)
              (setq writer-count (1+ writer-count)
                    appended-bytes (substring-no-properties suffix))
              (with-current-buffer decoy
                (set-buffer-multibyte nil)
                (erase-buffer)
                (insert appended-bytes))
              (prog1 (funcall real-append path suffix)
                (setq writer-entered t))))
           (epi-ledger--read-function
            (lambda (candidate begin end)
              (let ((bytes (funcall real-read candidate begin end)))
                (when (and writer-entered (equal candidate path)
                           (= begin old-end))
                  (setq readback-count (1+ readback-count)
                        trusted-readback-bytes bytes))
                bytes)))
           (epi--yield-function
            (lambda ()
              (when (and writer-entered trusted-readback-buffer
                         (= mutation-count 0))
                (should provenance-observed)
                (should (eq epi-ledger--work-protected-buffer
                            trusted-readback-buffer))
                (should-not (eq trusted-readback-buffer decoy))
                (with-current-buffer decoy
                  (should
                   (equal appended-bytes
                          (buffer-substring-no-properties
                           (point-min) (point-max)))))
                (with-current-buffer trusted-readback-buffer
                    (let ((inhibit-read-only t))
                      (should appended-bytes)
                      (should-not (multibyte-string-p appended-bytes))
                      (should (> (buffer-size) 0))
                      (should
                       (equal appended-bytes
                              (buffer-substring-no-properties
                               (point-min) (point-max))))
                      (goto-char (point-min))
                      (let ((replacement
                             (if (= (char-after) ?X) ?Y ?X)))
                        (delete-char 1)
                        (insert-char replacement))))
                (setq mutation-count (1+ mutation-count))))))
      (unwind-protect
          (cl-letf
              (((symbol-function 'epi-ledger--validate-realized-suffix)
                (lambda (&rest arguments)
                  (when (eq (car arguments) trusted-readback-bytes)
                    (setq read-link-observed t
                          realizing t))
                  (unwind-protect
                      (apply real-realize arguments)
                    (setq realizing nil))))
               ((symbol-function 'epi-ledger--scan-frame-owned)
                (lambda (&rest arguments)
                  (when realizing
                    (let ((source (car arguments)))
                      (should (epi-ledger--source-region-p source))
                      (let ((source-buffer
                             (epi-ledger--source-region-raw-buffer source)))
                        (should (buffer-live-p source-buffer))
                        (if trusted-readback-buffer
                            (should (eq trusted-readback-buffer source-buffer))
                          (setq trusted-readback-buffer source-buffer))
                        (should-not (eq source-buffer decoy))
                        (should (eq source-buffer
                                    epi-ledger--work-protected-buffer))
                        (with-current-buffer source-buffer
                          (should-not enable-multibyte-characters)
                          (should
                           (equal trusted-readback-bytes
                                  (buffer-substring-no-properties
                                   (point-min) (point-max)))))
                        (setq scan-count (1+ scan-count)
                              provenance-observed t))))
                  (apply real-scan arguments))))
            (epi-test-ledger-io--wave5-with-process
              (epi-test-ledger-io--wave5-should-code
                  'epi-ledger-conflict 'append-uncertain 'possibly-written
                (epi-ledger--append
                 ledger (epi-test-ledger-io--wave5-batch)))))
        (when (buffer-live-p decoy)
          (kill-buffer decoy)))
      (should (= 1 writer-count))
      (should (= 1 readback-count))
      (should read-link-observed)
      (should provenance-observed)
      (should (> scan-count 0))
      (should (= 1 mutation-count))
      (epi-test-ledger-io--wave5-assert-uncertain-successor ledger expected)
      (should-not (file-exists-p (concat path ".epi-lock"))))))

(ert-deftest epi-ledger-append-realized-scan-or-semantic-error-marks-uncertain ()
  (should (fboundp 'epi-ledger--append))
  (should (fboundp 'epi-ledger--validate-realized-suffix))
  (dolist (kind '(scan semantic))
    (epi-test-with-temporary-root (root)
      (let* ((ledger (epi-test-ledger-io--wave5-open root))
             (path (epi-ledger--raw-path ledger))
             (expected (epi-ledger--checkpoint-snapshot ledger))
             (real-realize
              (symbol-function 'epi-ledger--validate-realized-suffix))
             (real-scan (symbol-function 'epi-ledger--scan-frame-owned))
             (real-semantic
              (symbol-function 'epi-ledger--validate-record-semantic))
             (real-append epi-ledger--append-function)
             (realizing nil)
             (injection-count 0)
             (writer-count 0)
             (epi-ledger--append-function
              (lambda (path suffix)
                (setq writer-count (1+ writer-count))
                (funcall real-append path suffix))))
        (cl-letf
            (((symbol-function 'epi-ledger--validate-realized-suffix)
              (lambda (&rest arguments)
                (setq realizing t)
                (unwind-protect
                    (apply real-realize arguments)
                  (setq realizing nil))))
             ((symbol-function 'epi-ledger--scan-frame-owned)
              (lambda (&rest arguments)
                (if (and realizing (eq kind 'scan) (= injection-count 0))
                    (progn
                      (setq injection-count (1+ injection-count))
                      '(:state invalid :code injected-scan :offset 0
                        :cause (:code injected-scan)))
                  (apply real-scan arguments))))
             ((symbol-function 'epi-ledger--validate-record-semantic)
              (lambda (&rest arguments)
                (if (and realizing (eq kind 'semantic)
                         (= injection-count 0))
                    (progn
                      (setq injection-count (1+ injection-count))
                      (epi-ledger--format-fail 'injected-semantic))
                  (apply real-semantic arguments)))))
          (epi-test-ledger-io--wave5-with-process
            (epi-test-ledger-io--wave5-should-code
                'epi-ledger-conflict 'append-uncertain 'possibly-written
              (epi-ledger--append
               ledger (epi-test-ledger-io--wave5-batch)))))
        (should (= 1 injection-count))
        (should (= 1 writer-count))
        (epi-test-ledger-io--wave5-assert-uncertain-successor
         ledger expected)
        (should-not (file-exists-p (concat path ".epi-lock")))))))

(ert-deftest epi-ledger-append-final-identity-or-head-race-marks-uncertain ()
  (should (fboundp 'epi-ledger--append))
  (should (fboundp 'epi-ledger--verify-file-state))
  (should (fboundp 'epi-ledger--validate-realized-suffix))
  (dolist (code '(file-identity-changed file-chain-head-changed))
    (epi-test-with-temporary-root (root)
      (let* ((ledger (epi-test-ledger-io--wave5-open root))
             (path (epi-ledger--raw-path ledger))
             (expected (epi-ledger--checkpoint-snapshot ledger))
             (real-realize
              (symbol-function 'epi-ledger--validate-realized-suffix))
             (real-verify (symbol-function 'epi-ledger--verify-file-state))
             (real-append epi-ledger--append-function)
             (post-realized nil)
             (race-count 0)
             (writer-count 0)
             (epi-ledger--append-function
              (lambda (path suffix)
                (setq writer-count (1+ writer-count))
                (funcall real-append path suffix))))
        (cl-letf
            (((symbol-function 'epi-ledger--validate-realized-suffix)
              (lambda (&rest arguments)
                (prog1 (apply real-realize arguments)
                  (setq post-realized t))))
             ((symbol-function 'epi-ledger--verify-file-state)
              (lambda (&rest arguments)
                (if (and post-realized (= race-count 0))
                    (progn
                      (setq race-count (1+ race-count))
                      (epi-ledger--fail 'epi-ledger-conflict code))
                  (apply real-verify arguments)))))
          (epi-test-ledger-io--wave5-with-process
            (epi-test-ledger-io--wave5-should-code
                'epi-ledger-conflict 'append-uncertain 'possibly-written
              (epi-ledger--append
               ledger (epi-test-ledger-io--wave5-batch)))))
        (should (= 1 race-count))
        (should (= 1 writer-count))
        (epi-test-ledger-io--wave5-assert-uncertain-successor
         ledger expected)
        (should-not (file-exists-p (concat path ".epi-lock")))))))

(ert-deftest epi-ledger-append-stale-publication-cas-never-overwrites-winner ()
  (should (fboundp 'epi-ledger--append))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave5-open root))
           (path (epi-ledger--raw-path ledger))
           (expected (epi-ledger--checkpoint-snapshot ledger))
           (winner (epi-test-ledger-io--wave5-checkpoint-clone expected))
           (real-cas (symbol-function 'epi-ledger--checkpoint-cas))
           (writer-count 0)
           (cas-count 0)
           (real-append epi-ledger--append-function)
           (epi-ledger--append-function
            (lambda (path suffix)
              (setq writer-count (1+ writer-count))
              (funcall real-append path suffix))))
      (cl-letf
          (((symbol-function 'epi-ledger--checkpoint-cas)
            (lambda (candidate old replacement)
              (setq cas-count (1+ cas-count))
              (should (eq candidate ledger))
              (should (eq old expected))
              (pcase cas-count
                (1
                 (should-not
                  (epi-ledger--checkpoint-raw-uncertain replacement))
                 (should (funcall real-cas ledger expected winner))
                 nil)
                (2
                 (epi-test-ledger-io--wave5-assert-uncertain-copy
                  expected replacement)
                 (should-not (funcall real-cas candidate old replacement))
                 nil)
                (_
                 (ert-fail
                  (format "unexpected extra checkpoint CAS: %S"
                          (list candidate old replacement))))))))
        (epi-test-ledger-io--wave5-with-process
          (epi-test-ledger-io--wave5-should-code
              'epi-ledger-conflict 'stale-checkpoint nil
            (epi-ledger--append ledger (epi-test-ledger-io--wave5-batch)))))
      (should (= 1 writer-count))
      (should (= 2 cas-count))
      (should (eq winner (epi-ledger--checkpoint-snapshot ledger)))
      (should-not (epi-ledger--checkpoint-raw-uncertain winner))
      (should-not (file-exists-p (concat path ".epi-lock"))))))

(ert-deftest epi-ledger-append-unlock-replacement-survives-and-marks-uncertain ()
  (should (fboundp 'epi-ledger--append))
  (should (fboundp 'epi-ledger--release-lock))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave5-open root))
           (path (epi-ledger--raw-path ledger))
           (old (epi-ledger--checkpoint-snapshot ledger))
           (old-end
            (epi-ledger--checkpoint-raw-validated-end-offset old))
           (replacement
            (encode-coding-string "replacement-lock-token" 'utf-8-unix))
           (real-append epi-ledger--append-function)
           (real-unlock epi-ledger--unlock-function)
           (replacement-path (concat path ".epi-lock"))
           (writer-count 0)
           (unlock-count 0)
           published
           (epi-ledger--append-function
            (lambda (candidate suffix)
              (setq writer-count (1+ writer-count))
              (funcall real-append candidate suffix)))
           (epi-ledger--unlock-function
            (lambda (lock)
              (setq unlock-count (1+ unlock-count)
                    published (epi-ledger--checkpoint-snapshot ledger))
              (should-not (epi-ledger--checkpoint-raw-uncertain published))
              (delete-file replacement-path)
              (epi-ledger--write-bytes
               replacement-path replacement 'exclusive-create t)
              (funcall real-unlock lock))))
      (epi-test-ledger-io--wave5-with-process
        (epi-test-ledger-io--wave5-should-code
            'epi-ledger-conflict 'unlock-uncertain 'published
          (epi-ledger--append ledger (epi-test-ledger-io--wave5-batch))))
      (should (= 1 unlock-count))
      (should (= 1 writer-count))
      (should (equal replacement
                     (epi-test-ledger-io--literal-file-bytes
                      replacement-path)))
      (should published)
      (let ((current
             (epi-test-ledger-io--wave5-assert-uncertain-successor
              ledger published)))
        (should (> (epi-ledger--checkpoint-raw-validated-end-offset current)
                   old-end))
        (should (= 3
                   (epi-ledger--record-source-length
                    (epi-ledger--checkpoint-raw-records current))))))))

(ert-deftest epi-ledger-append-uncertain-handle-refuses-a-second-append ()
  (should (fboundp 'epi-ledger--append))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave5-open root))
           (first-count 0)
           (epi-ledger--append-function
            (lambda (&rest _arguments)
              (setq first-count (1+ first-count))
              (signal 'file-error '("injected ambiguous writer")))))
      (epi-test-ledger-io--wave5-with-process
        (epi-test-ledger-io--wave5-should-code
            'epi-ledger-conflict 'append-uncertain 'possibly-written
          (epi-ledger--append ledger (epi-test-ledger-io--wave5-batch))))
      (should (= 1 first-count))
      (let ((uncertain (epi-ledger--checkpoint-snapshot ledger))
            (epi-ledger--append-function
             #'epi-test-ledger-io--wave5-unexpected-write)
            (epi-ledger--flush-function
             #'epi-test-ledger-io--wave5-unexpected-write))
        (cl-letf (((symbol-function 'epi-ledger--acquire-lock)
                   #'epi-test-ledger-io--wave5-unexpected-write))
          (epi-test-ledger-io--wave5-should-code
              'epi-ledger-conflict 'append-uncertain 'possibly-written
            (epi-ledger--append
             ledger (epi-test-ledger-io--wave5-batch 'alternate))))
        (should (eq uncertain (epi-ledger--checkpoint-snapshot ledger)))))))

(ert-deftest epi-ledger-append-rejects-a-stale-head-without-writing ()
  (should (fboundp 'epi-ledger--append))
  (epi-test-with-temporary-root (root)
    (let* ((path
            (epi-test-ledger-io--write-document
             root (list (epi-test-ledger-io--session-info))))
           (winner (epi-ledger-open path))
           (loser (epi-ledger-open path))
           (loser-checkpoint (epi-ledger--checkpoint-snapshot loser)))
      (epi-test-ledger-io--wave5-with-process
        (epi-ledger--append winner (epi-test-ledger-io--wave5-batch)))
      (let ((winner-bytes (epi-test-ledger-io--wave5-bytes winner))
            (epi-ledger--append-function
             #'epi-test-ledger-io--wave5-unexpected-write)
            (epi-ledger--flush-function
             #'epi-test-ledger-io--wave5-unexpected-write))
        (epi-test-ledger-io--wave5-with-process
          (let ((condition
                 (should-error
                  (epi-ledger--append
                   loser (epi-test-ledger-io--wave5-batch 'alternate))
                  :type 'epi-ledger-conflict)))
            (should
             (memq (epi-test-ledger-io--condition-code condition)
                   '(file-identity-changed file-end-changed
                     file-chain-head-changed)))))
        (should (equal winner-bytes (epi-test-ledger-io--wave5-bytes loser)))
        (should (eq loser-checkpoint
                    (epi-ledger--checkpoint-snapshot loser)))
        (should-not
         (epi-ledger--checkpoint-raw-uncertain
          (epi-ledger--checkpoint-snapshot loser)))))))

(ert-deftest epi-ledger-append-publishes-uncertainty-before-unlock ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave5-open root))
           (path (epi-ledger--raw-path ledger))
           (expected (epi-ledger--checkpoint-snapshot ledger))
           (real-append epi-ledger--append-function)
           (real-unlock epi-ledger--unlock-function)
           (real-cas (symbol-function 'epi-ledger--checkpoint-cas))
           uncertain-at-unlock
           events
           (epi-ledger--append-function
            (lambda (candidate suffix)
              (push 'writer events)
              (funcall real-append candidate suffix)
              (signal 'file-error '("injected ambiguous writer"))))
           (epi-ledger--unlock-function
            (lambda (lock)
              (setq uncertain-at-unlock
                    (epi-ledger--checkpoint-raw-uncertain
                     (epi-ledger--checkpoint-snapshot ledger)))
              (push 'unlock events)
              (funcall real-unlock lock))))
      (cl-letf
          (((symbol-function 'epi-ledger--checkpoint-cas)
            (lambda (candidate old replacement)
              (push 'uncertainty-cas events)
              (funcall real-cas candidate old replacement))))
        (epi-test-ledger-io--wave5-with-process
          (epi-test-ledger-io--wave5-should-code
              'epi-ledger-conflict 'append-uncertain 'possibly-written
            (epi-ledger--append
             ledger (epi-test-ledger-io--wave5-batch)))))
      (should uncertain-at-unlock)
      (should (equal '(writer uncertainty-cas unlock)
                     (nreverse events)))
      (epi-test-ledger-io--wave5-assert-uncertain-successor
       ledger expected)
      (should-not (file-exists-p (concat path ".epi-lock"))))))

(ert-deftest epi-ledger-append-normalizes-a-raw-prewrite-unlock-failure ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave5-open root))
           (path (epi-ledger--raw-path ledger))
           (expected (epi-ledger--checkpoint-snapshot ledger))
           (verify-count 0)
           (writer-count 0)
           (epi-ledger--append-function
            (lambda (&rest _arguments)
              (setq writer-count (1+ writer-count))))
           (epi-ledger--unlock-function
            (lambda (&rest _arguments)
              (signal 'file-error '("injected raw unlock failure")))))
      (cl-letf
          (((symbol-function 'epi-ledger--verify-file-state)
            (lambda (&rest _arguments)
              (setq verify-count (1+ verify-count))
              (epi-ledger--fail
               'epi-ledger-conflict 'injected-prewrite-failure))))
        (epi-test-ledger-io--wave5-with-process
          (epi-test-ledger-io--wave5-should-code
              'epi-ledger-conflict 'unlock-uncertain 'prewrite
            (epi-ledger--append
             ledger (epi-test-ledger-io--wave5-batch)))))
      (should (= 1 verify-count))
      (should (= 0 writer-count))
      (should (eq expected (epi-ledger--checkpoint-snapshot ledger)))
      (should (file-exists-p (concat path ".epi-lock"))))))

(ert-deftest epi-ledger-append-reproves-the-exact-lock-before-writing ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave5-open root))
           (path (epi-ledger--raw-path ledger))
           (lock-path (concat path ".epi-lock"))
           (expected (epi-ledger--checkpoint-snapshot ledger))
           (foreign
            (encode-coding-string "foreign-lock-token" 'utf-8-unix))
           (real-core
            (symbol-function 'epi-ledger--verify-file-state-core))
           (core-count 0)
           (writer-count 0)
           (epi-ledger--append-function
            (lambda (&rest _arguments)
              (setq writer-count (1+ writer-count))
              (signal 'file-error '("writer must remain unreachable"))))
           (epi-ledger--flush-function
            #'epi-test-ledger-io--wave5-unexpected-write))
      (cl-letf
          (((symbol-function 'epi-ledger--verify-file-state-core)
            (lambda (&rest arguments)
              (prog1 (apply real-core arguments)
                (setq core-count (1+ core-count))
                (when (= core-count 2)
                  (delete-file lock-path)
                  (epi-ledger--write-bytes
                   lock-path foreign 'exclusive-create t))))))
        (epi-test-ledger-io--wave5-with-process
          (epi-test-ledger-io--wave5-should-code
              'epi-ledger-conflict 'lock-token-changed nil
            (epi-ledger--append
             ledger (epi-test-ledger-io--wave5-batch)))))
      (should (= 2 core-count))
      (should (= 0 writer-count))
      (should (eq expected (epi-ledger--checkpoint-snapshot ledger)))
      (should (equal foreign
                     (epi-test-ledger-io--literal-file-bytes lock-path))))))

(ert-deftest epi-ledger-append-closes-the-lock-proof-callback-gap ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave5-open root))
           (path (epi-ledger--raw-path ledger))
           (lock-path (concat path ".epi-lock"))
           (expected (epi-ledger--checkpoint-snapshot ledger))
           (before (epi-test-ledger-io--wave5-bytes ledger))
           (mutated-bytes
            (epi-test-ledger-io--wave5-flip-first-byte before))
           (real-core
            (symbol-function 'epi-ledger--verify-file-state-core))
           (real-stat epi-ledger--stat-function)
           (real-append epi-ledger--append-function)
           (core-count 0)
           (writer-count 0)
           mutated
           (epi-ledger--stat-function
            (lambda (candidate)
              (let ((identity (funcall real-stat candidate)))
                (when (and (not mutated)
                           (= core-count 2)
                           (equal candidate lock-path))
                  (setq mutated t)
                  ;; Return the already-observed lock identity only after the
                  ;; lock-proof seam has invalidated ledger authority.
                  (epi-ledger--write-bytes
                   path mutated-bytes 'replace t))
                identity)))
           (epi-ledger--append-function
            (lambda (candidate suffix)
              (setq writer-count (1+ writer-count))
              (funcall real-append candidate suffix))))
      (cl-letf
          (((symbol-function 'epi-ledger--verify-file-state-core)
            (lambda (&rest arguments)
              (prog1 (apply real-core arguments)
                (setq core-count (1+ core-count))))))
        (epi-test-ledger-io--wave5-with-process
          (let ((condition
                 (should-error
                  (epi-ledger--append
                   ledger (epi-test-ledger-io--wave5-batch))
                  :type 'epi-ledger-conflict)))
            (should
             (memq (epi-test-ledger-io--condition-code condition)
                   '(file-identity-changed file-end-changed
                     file-chain-head-changed))))))
      (should mutated)
      (should (= 2 core-count))
      (should (= 0 writer-count))
      (should (eq expected (epi-ledger--checkpoint-snapshot ledger)))
      (should-not (file-exists-p lock-path))
      (should (equal mutated-bytes
                     (epi-test-ledger-io--wave5-bytes ledger))))))

(ert-deftest epi-ledger-append-closes-the-final-verifier-callback-gap ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave5-open root))
           (path (epi-ledger--raw-path ledger))
           (expected (epi-ledger--checkpoint-snapshot ledger))
           (real-append epi-ledger--append-function)
           (real-verify (symbol-function 'epi-ledger--verify-file-state))
           (verify-count 0)
           (writer-count 0)
           mutated
           (epi-ledger--append-function
            (lambda (candidate suffix)
              (setq writer-count (1+ writer-count))
              (funcall real-append candidate suffix))))
      (cl-letf
          (((symbol-function 'epi-ledger--verify-file-state)
            (lambda (&rest arguments)
              (setq verify-count (1+ verify-count))
              (prog1 (apply real-verify arguments)
                (when (= verify-count 2)
                  (setq mutated t)
                  ;; Mutate storage after the verifier's last observation but
                  ;; before its callback boundary returns to publication.
                  (epi-ledger--write-bytes
                   path (string-make-unibyte "X") 'append t))))))
        (epi-test-ledger-io--wave5-with-process
          (epi-test-ledger-io--wave5-should-code
              'epi-ledger-conflict 'append-uncertain 'possibly-written
            (epi-ledger--append
             ledger (epi-test-ledger-io--wave5-batch)))))
      (should mutated)
      (should (= 2 verify-count))
      (should (= 1 writer-count))
      (epi-test-ledger-io--wave5-assert-uncertain-successor
       ledger expected)
      (should-not (file-exists-p (concat path ".epi-lock"))))))

;;;; Wave 6: immutable objects

(defconst epi-test-ledger-io--wave6-media-type
  "application/octet-stream"
  "Deterministic media type used by Wave 6 object references.")

(defconst epi-test-ledger-io--wave6-role
  "test-artifact"
  "Deterministic role used by Wave 6 object references.")

(defconst epi-test-ledger-io--wave6-temporary-id
  "66666666-6666-4666-8666-666666666666"
  "Deterministic identifier used for Wave 6 hidden siblings.")

(defun epi-test-ledger-io--wave6-open (root)
  "Open a session-info-only ledger below ROOT."
  (epi-test-ledger-io--open-history
   root (list (epi-test-ledger-io--session-info))))

(defun epi-test-ledger-io--wave6-put (ledger bytes)
  "Store BYTES in LEDGER with deterministic Wave 6 metadata."
  (epi-ledger-object-put
   ledger bytes
   :media-type epi-test-ledger-io--wave6-media-type
   :role epi-test-ledger-io--wave6-role))

(defun epi-test-ledger-io--wave6-bytes (text)
  "Return TEXT encoded as a fresh property-free unibyte string."
  (encode-coding-string text 'utf-8-unix))

(defun epi-test-ledger-io--wave6-ref (bytes)
  "Return a deterministic object reference for unibyte BYTES."
  (make-epi-object-ref
   :hash (secure-hash 'sha256 bytes)
   :size (length bytes)
   :media-type epi-test-ledger-io--wave6-media-type
   :role epi-test-ledger-io--wave6-role))

(defun epi-test-ledger-io--wave6-stat (path size &optional inode)
  "Return a complete synthetic file identity for PATH and SIZE.
INODE defaults to 606."
  (list :path (substring-no-properties path)
        :device 60 :inode (or inode 606) :links 1 :size size
        :modified '(11 22 33 44) :changed '(55 66 77 88)))

(defun epi-test-ledger-io--wave6-assert-structured (condition)
  "Assert that CONDITION carries exactly one well-formed Epi detail plist."
  (let ((data (cdr condition)))
    (should (= 1 (length data)))
    (should (plistp (car data)))
    (should (eq :code (car (car data))))
    (should (symbolp (plist-get (car data) :code)))
    (should (plist-get (car data) :code))))

(defun epi-test-ledger-io--wave6-unexpected (label &rest arguments)
  "Fail because forbidden operation LABEL received ARGUMENTS."
  (ert-fail (format "Wave 6 %s was unexpectedly invoked: %S"
                    label arguments)))

(defun epi-test-ledger-io--wave6-safe-range (bytes begin end)
  "Return the available portion of BYTES between BEGIN and END."
  (if (>= begin (length bytes))
      ""
    (substring-no-properties bytes begin (min end (length bytes)))))

(ert-deftest epi-ledger-object-put-is-content-addressed ()
  (should (fboundp 'epi-ledger-object-put))
  (should (fboundp 'epi-ledger-object-get))
  (should (fboundp 'epi-ledger--object-path))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "abc"))
           (expected-hash (secure-hash 'sha256 bytes))
           (one (epi-test-ledger-io--wave6-put ledger bytes))
           (two (epi-test-ledger-io--wave6-put ledger bytes))
           (path (epi-ledger--object-path ledger expected-hash)))
      (should (equal expected-hash (epi-object-ref-hash one)))
      (should (equal expected-hash (epi-object-ref-hash two)))
      (should (= 3 (epi-object-ref-size one)))
      (should (= 3 (epi-object-ref-size two)))
      (should (equal epi-test-ledger-io--wave6-media-type
                     (epi-object-ref-media-type one)))
      (should (equal epi-test-ledger-io--wave6-role
                     (epi-object-ref-role one)))
      (should (equal path
                     (epi-ledger--object-path
                      ledger (epi-object-ref-hash two))))
      (should (equal bytes
                     (epi-test-ledger-io--literal-file-bytes path)))
      (should (equal bytes (epi-ledger-object-get ledger one)))
      (should (equal bytes (epi-ledger-object-get ledger two))))

    ;; Empty bytes are a valid content-addressed object and still pass through
    ;; exclusive temporary creation plus the one durable empty flush.
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (empty (epi-test-ledger-io--wave6-bytes ""))
           (hash (secure-hash 'sha256 empty))
           (real-writer epi-ledger--byte-writer)
           writer-calls
           reference)
      (let ((epi-ledger--byte-writer
             (lambda (path payload mode durablep)
               (push (list (substring-no-properties path)
                           (substring-no-properties payload)
                           mode durablep)
                     writer-calls)
               (funcall real-writer path payload mode durablep))))
        (setq reference (epi-test-ledger-io--wave6-put ledger empty)))
      (let* ((path (epi-ledger--object-path ledger hash))
             (calls (nreverse writer-calls))
             (temporary (caar calls))
             (returned (epi-ledger-object-get ledger reference)))
        (should (equal hash (epi-object-ref-hash reference)))
        (should (= 0 (epi-object-ref-size reference)))
        (should (equal
                 (list (list temporary "" 'exclusive-create nil)
                       (list temporary "" 'append t))
                 calls))
        (should (file-regular-p path))
        (should (= 0 (file-attribute-size (file-attributes path))))
        (should (equal empty returned))
        (should-not (multibyte-string-p returned))
        (should (equal empty
                       (epi-test-ledger-io--literal-file-bytes path)))))))

(ert-deftest epi-ledger-object-put-hashes-the-owned-input-once ()
  (should (fboundp 'epi-ledger-object-put))
  (should (fboundp 'epi-ledger--snapshot-object-input))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (caller (epi-test-ledger-io--wave6-bytes "abcdef"))
           (expected (secure-hash 'sha256 caller))
           (real-secure-hash (symbol-function 'secure-hash))
           (real-snapshot
            (symbol-function 'epi-ledger--snapshot-object-input))
           captured-snapshot
           (snapshot-count 0)
           first-owned
           (first-owned-count 0)
           (hash-call-count 0))
      (put-text-property 0 1 'epi-wave6-caller t caller)
      (cl-letf
          (((symbol-function 'epi-ledger--snapshot-object-input)
            (lambda (bytes media-type role)
              (setq snapshot-count (1+ snapshot-count)
                    captured-snapshot
                    (funcall real-snapshot bytes media-type role))))
           ((symbol-function 'secure-hash)
            (lambda (algorithm object &optional start end binary)
              (when (and (eq algorithm 'sha256) (stringp object))
                (setq hash-call-count (1+ hash-call-count))
                (unless first-owned
                  (setq first-owned object)
                  (should captured-snapshot)
                  (should
                   (eq object (plist-get captured-snapshot :bytes)))
                  (should-not (eq caller first-owned))
                  (should-not (multibyte-string-p first-owned))
                  (should-not (text-properties-at 0 first-owned))
                  ;; Mutate caller authority at the first measured hash.  The
                  ;; hash and later writes must use the already-owned copy.
                  (aset caller 0 ?Z))
                (when (eq object first-owned)
                  (setq first-owned-count (1+ first-owned-count))))
              (funcall real-secure-hash
                       algorithm object start end binary))))
        (let ((reference (epi-test-ledger-io--wave6-put ledger caller)))
          (should (equal expected (epi-object-ref-hash reference)))
          (should (equal (epi-test-ledger-io--wave6-bytes "abcdef")
                         (epi-ledger-object-get ledger reference)))))
      (should (= 1 snapshot-count))
      (should first-owned)
      (should (= 1 first-owned-count))
      ;; Publication verification hashes fresh reads, not the owned input
      ;; object itself, so the complete put normally performs further hashes.
      (should (> hash-call-count 1))
      (should (= ?Z (aref caller 0)))
      (should (text-properties-at 0 caller)))))

(ert-deftest epi-ledger-object-put-accepts-the-exact-cap ()
  (should (fboundp 'epi-ledger-object-put))
  (should (fboundp 'epi-ledger--object-path))
  (epi-test-with-temporary-root (root)
    (let* ((epi-object-byte-limit 16777216)
           (epi-hash-input-byte-limit 16777216)
           (epi-ledger-work-byte-limit 1048576)
           (ledger (epi-test-ledger-io--wave6-open root))
           (bytes (make-string 16777216 ?x))
           (reference (epi-test-ledger-io--wave6-put ledger bytes))
           (path (epi-ledger--object-path
                  ledger (epi-object-ref-hash reference))))
      (should-not (multibyte-string-p bytes))
      (should (= 16777216 (epi-object-ref-size reference)))
      (should (= 16777216
                 (file-attribute-size (file-attributes path))))
      (should (equal (secure-hash 'sha256 bytes)
                     (epi-object-ref-hash reference))))))

(ert-deftest epi-ledger-object-put-rejects-one-byte-over-before-hash-or-write ()
  (should (fboundp 'epi-ledger-object-put))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (ledger-path (epi-ledger--raw-path ledger))
           (objects (concat ledger-path ".objects"))
           (bytes (make-string 9 ?x))
           (before (epi-test-ledger-io--wave2-tree-snapshot root))
           (hash-count 0)
           (input-copy-count 0)
           (real-secure-hash (symbol-function 'secure-hash))
           (real-substring (symbol-function 'substring-no-properties))
           (epi-object-byte-limit 8)
           (epi-ledger--byte-writer
            (apply-partially #'epi-test-ledger-io--wave6-unexpected
                             'byte-writer))
           (epi-ledger--publish-function
            (apply-partially #'epi-test-ledger-io--wave6-unexpected
                             'publisher)))
      (cl-letf
          (((symbol-function 'secure-hash)
            (lambda (&rest arguments)
              (setq hash-count (1+ hash-count))
              (apply real-secure-hash arguments)))
           ((symbol-function 'substring-no-properties)
            (lambda (string &optional from to)
              (when (eq string bytes)
                (setq input-copy-count (1+ input-copy-count)))
              (funcall real-substring string from to))))
        (let ((condition
               (should-error
                (epi-test-ledger-io--wave6-put ledger bytes)
                :type 'epi-limit-exceeded)))
          (should (eq 'object-byte-limit
                      (epi-test-ledger-io--wave6-assert-structured condition)))
          (let ((detail (epi-test-ledger-io--condition-detail condition)))
            (should (= 8 (plist-get detail :limit)))
            (should (= 9 (plist-get detail :bytes))))))
      (should (= 0 hash-count))
      (should (= 0 input-copy-count))

      ;; The public operation, not merely the snapshot helper, rejects a
      ;; multibyte caller before hashing, copying, or storage work.
      (let ((multibyte (string #x3bb)))
        (should (multibyte-string-p multibyte))
        (setq hash-count 0
              input-copy-count 0)
        (cl-letf
            (((symbol-function 'secure-hash)
              (lambda (&rest arguments)
                (setq hash-count (1+ hash-count))
                (apply real-secure-hash arguments)))
             ((symbol-function 'substring-no-properties)
              (lambda (string &optional from to)
                (when (eq string multibyte)
                  (setq input-copy-count (1+ input-copy-count)))
                (funcall real-substring string from to))))
          (let ((condition
                 (should-error
                  (epi-test-ledger-io--wave6-put ledger multibyte)
                  :type 'epi-ledger-format-error)))
            (should
             (eq 'unibyte-object-required
                 (epi-test-ledger-io--wave6-assert-structured
                  condition)))))
        (should (= 0 hash-count))
        (should (= 0 input-copy-count)))
      (should-not (file-exists-p objects))
      (should (equal before
                     (epi-test-ledger-io--wave2-tree-snapshot root)))
      (should (equal bytes (make-string 9 ?x))))))

(ert-deftest epi-ledger-object-path-and-private-modes-are-exact ()
  (should (fboundp 'epi-ledger-object-put))
  (should (fboundp 'epi-ledger--object-path))
  (should (fboundp 'epi-ledger--write-object-temporary))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (ledger-path (epi-ledger--raw-path ledger))
           (bytes (epi-test-ledger-io--wave6-bytes "private"))
           (hash (secure-hash 'sha256 bytes))
           (objects (concat ledger-path ".objects"))
           (sha-directory (expand-file-name "sha256" objects))
           (prefix-directory
            (expand-file-name (substring hash 0 2) sha-directory))
           (expected
            (expand-file-name hash (file-name-as-directory prefix-directory)))
           (real-writer epi-ledger--byte-writer)
           (real-publisher epi-ledger--publish-function)
           writer-calls
           temporary
           published-source-mode
           published-source-bytes
           published-destination)
      (let ((epi--id-function
             (lambda () epi-test-ledger-io--wave6-temporary-id))
            (epi-ledger-work-byte-limit 2)
            (epi-ledger--byte-writer
             (lambda (path payload mode durablep)
               (push (list (substring-no-properties path)
                           (substring-no-properties payload)
                           mode durablep)
                     writer-calls)
               (funcall real-writer path payload mode durablep)))
            (epi-ledger--publish-function
             (lambda (source destination)
               (setq temporary (substring-no-properties source)
                     published-destination
                     (substring-no-properties destination)
                     published-source-mode
                     (epi-test-ledger-io--permission-bits source)
                     published-source-bytes
                     (epi-test-ledger-io--literal-file-bytes source))
               (funcall real-publisher source destination))))
        (let ((reference (epi-test-ledger-io--wave6-put ledger bytes)))
          (should (equal hash (epi-object-ref-hash reference)))))
      (should (equal expected (epi-ledger--object-path ledger hash)))
      (should (equal expected published-destination))
      (should temporary)
      (should-not (equal temporary expected))
      (should (equal (file-name-directory expected)
                     (file-name-directory temporary)))
      (should (string-prefix-p
               (concat "." (file-name-nondirectory expected) ".")
               (file-name-nondirectory temporary)))
      (should (= #o700 (epi-test-ledger-io--permission-bits objects)))
      (should (= #o700
                 (epi-test-ledger-io--permission-bits sha-directory)))
      (should (= #o700
                 (epi-test-ledger-io--permission-bits prefix-directory)))
      (should (= #o600 published-source-mode))
      (should (= #o600 (epi-test-ledger-io--permission-bits expected)))
      (should (equal bytes published-source-bytes))
      (should (equal bytes
                     (epi-test-ledger-io--literal-file-bytes expected)))
      (should-not (file-exists-p temporary))
      (should
       (equal
        (list (list temporary
                    (epi-test-ledger-io--wave6-bytes "pr")
                    'exclusive-create nil)
              (list temporary
                    (epi-test-ledger-io--wave6-bytes "iv")
                    'append nil)
              (list temporary
                    (epi-test-ledger-io--wave6-bytes "at")
                    'append nil)
              (list temporary
                    (epi-test-ledger-io--wave6-bytes "e")
                    'append nil)
              (list temporary "" 'append t))
        (nreverse writer-calls)))))

  ;; The exact readback is a prepublication gate.  A same-length corrupt
  ;; temporary must fail as a write failure without invoking publication.
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "readback"))
           ;; Preserve every byte except the last so a prefix-only temporary
           ;; verification cannot reject by accident and pass this test.
           (corrupt (epi-test-ledger-io--wave6-bytes "readbacX"))
           (real-writer epi-ledger--byte-writer)
           (real-reader epi-ledger--read-function)
           temporary
           temporary-ranges
           (publish-count 0))
      (let ((epi-ledger-work-byte-limit 2)
            (epi-ledger--byte-writer
             (lambda (path payload mode durablep)
               (setq temporary (substring-no-properties path))
               (funcall real-writer path payload mode durablep)))
            (epi-ledger--read-function
             (lambda (path begin end)
               (if (and temporary (equal path temporary))
                   (progn
                     (push (list begin end) temporary-ranges)
                     (epi-test-ledger-io--wave6-safe-range
                      corrupt begin end))
                 (funcall real-reader path begin end))))
            (epi-ledger--publish-function
             (lambda (&rest _arguments)
               (setq publish-count (1+ publish-count))
               (ert-fail "corrupt temporary reached publication"))))
        (let ((condition
               (should-error
                (epi-test-ledger-io--wave6-put ledger bytes)
                :type 'epi-ledger-conflict)))
          (should
           (eq 'storage-write-failed
               (epi-test-ledger-io--wave6-assert-structured condition)))))
      (should temporary)
      (should (= 0 publish-count))
      (setq temporary-ranges (nreverse temporary-ranges))
      (should temporary-ranges)
      (should (= 0 (caar temporary-ranges)))
      (should (= (1+ (length bytes))
                 (cadar (last temporary-ranges))))
      (dolist (range temporary-ranges)
        (pcase-let ((`(,begin ,end) range))
          (should (<= 0 begin end (1+ (length bytes))))
          (should (<= (- end begin) 2))))
      (cl-loop for left on temporary-ranges
               while (cdr left)
               do (should (= (cadar left) (caadr left))))
      (should-not
       (file-exists-p
        (epi-ledger--object-path ledger (secure-hash 'sha256 bytes)))))))

(ert-deftest epi-ledger-object-put-accepts-only-a-verified-identical-winner ()
  (should (fboundp 'epi-ledger-object-put))
  (should (fboundp 'epi-ledger--object-path))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "winner"))
           (hash (secure-hash 'sha256 bytes))
           (destination (epi-ledger--object-path ledger hash))
           (real-writer epi-ledger--byte-writer)
           (real-reader epi-ledger--read-function)
           (real-stat epi-ledger--stat-function)
           collision
           temporary
           winner-events
           winner-ranges)
      (let ((epi-ledger-work-byte-limit 2)
            (epi-ledger--publish-function
             (lambda (source target)
               (should (equal destination target))
               (setq temporary (substring-no-properties source))
               (funcall real-writer target bytes 'exclusive-create t)
               (setq collision t)
               (epi-ledger--fail
                'epi-ledger-conflict 'destination-exists)))
            (epi-ledger--stat-function
             (lambda (path)
               (when (and collision (equal path destination))
                 (push 'stat winner-events))
               (funcall real-stat path)))
            (epi-ledger--read-function
             (lambda (path begin end)
               (when (and collision (equal path destination))
                 (push (list 'read begin end) winner-events)
                 (push (list begin end) winner-ranges))
               (funcall real-reader path begin end))))
        (let ((reference (epi-test-ledger-io--wave6-put ledger bytes)))
          (should (equal hash (epi-object-ref-hash reference)))
          (should (= (length bytes) (epi-object-ref-size reference)))))
      (should collision)
      (should temporary)
      (should-not (file-exists-p temporary))
      (should (equal bytes
                     (epi-test-ledger-io--literal-file-bytes destination)))
      (should winner-ranges)
      (setq winner-events (nreverse winner-events))
      (should (eq 'stat (car winner-events)))
      (setq winner-ranges (nreverse winner-ranges))
      (should (= 0 (caar winner-ranges)))
      (should (= (1+ (length bytes))
                 (cadar (last winner-ranges))))
      (dolist (range winner-ranges)
        (pcase-let ((`(,begin ,end) range))
          (should (<= 0 begin end (1+ (length bytes))))
          (should (<= (- end begin) 2))))
      (cl-loop for left on winner-ranges
               while (cdr left)
               do (should (= (cadar left) (caadr left)))))))

(ert-deftest epi-ledger-object-put-preserves-and-rejects-a-mismatched-winner ()
  (should (fboundp 'epi-ledger-object-put))
  (should (fboundp 'epi-ledger--object-path))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "abcdef"))
           ;; Share every byte except the last so a first-chunk or prefix-only
           ;; winner check cannot mistake corruption for identity.
           (winner (epi-test-ledger-io--wave6-bytes "abcdeX"))
           (hash (secure-hash 'sha256 bytes))
           (destination (epi-ledger--object-path ledger hash))
           (real-writer epi-ledger--byte-writer)
           temporary
           winner-identity
           (publish-count 0))
      (let ((epi-ledger-work-byte-limit 2)
            (epi-ledger--publish-function
             (lambda (source target)
               (setq publish-count (1+ publish-count)
                     temporary (substring-no-properties source))
               (should (equal destination target))
               (funcall real-writer target winner 'exclusive-create t)
               (setq winner-identity
                     (funcall epi-ledger--stat-function target))
               (epi-ledger--fail
                'epi-ledger-conflict 'destination-exists))))
        (let ((condition
               (should-error
                (epi-test-ledger-io--wave6-put ledger bytes)
                :type 'epi-ledger-corrupt)))
          (should
           (eq 'object-content-mismatch
               (epi-test-ledger-io--wave6-assert-structured condition)))))
      (should (= 1 publish-count))
      (should temporary)
      (should-not (file-exists-p temporary))
      (should (equal winner
                     (epi-test-ledger-io--literal-file-bytes destination)))
      (should (equal winner-identity
                     (funcall epi-ledger--stat-function destination)))

      ;; A later put must verify the existing path before trusting it.  It
      ;; neither writes nor publishes and preserves the corrupt inode exactly.
      (let ((epi-ledger--byte-writer
             (apply-partially #'epi-test-ledger-io--wave6-unexpected
                              'byte-writer))
            (epi-ledger--publish-function
             (apply-partially #'epi-test-ledger-io--wave6-unexpected
                              'publisher)))
        (let ((condition
               (should-error
                (epi-test-ledger-io--wave6-put ledger bytes)
                :type 'epi-ledger-corrupt)))
          (should
           (eq 'object-content-mismatch
               (epi-test-ledger-io--wave6-assert-structured condition)))))
      (should (= 1 publish-count))
      (should (equal winner
                     (epi-test-ledger-io--literal-file-bytes destination)))
      (should (equal winner-identity
                     (funcall epi-ledger--stat-function destination))))))

(ert-deftest epi-ledger-object-get-returns-a-fresh-unibyte-copy ()
  (should (fboundp 'epi-ledger-object-put))
  (should (fboundp 'epi-ledger-object-get))
  (should (fboundp 'epi-ledger--object-path))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "fresh-copy"))
           (reference (epi-test-ledger-io--wave6-put ledger bytes))
           (path (epi-ledger--object-path
                  ledger (epi-object-ref-hash reference)))
           (one (epi-ledger-object-get ledger reference))
           (two (epi-ledger-object-get ledger reference)))
      (should (equal bytes one))
      (should (equal bytes two))
      (should-not (eq one two))
      (should-not (multibyte-string-p one))
      (should-not (multibyte-string-p two))
      (should-not (text-properties-at 0 one))
      (should-not (text-properties-at 0 two))
      (aset one 0 ?X)
      (should (equal bytes two))
      (should (equal bytes (epi-ledger-object-get ledger reference)))
      (should (equal bytes
                     (epi-test-ledger-io--literal-file-bytes path))))))

(ert-deftest epi-ledger-object-get-bounds-missing-size-excess-and-oversize-reads ()
  (should (fboundp 'epi-ledger-object-get))
  (should (fboundp 'epi-ledger--object-path))
  (should (fboundp 'epi-ledger--object-read-verified))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (expected (epi-test-ledger-io--wave6-bytes "abcde"))
           (reference (epi-test-ledger-io--wave6-ref expected))
           (path (epi-ledger--object-path
                  ledger (epi-object-ref-hash reference))))
      (cl-labels
          ((assert-no-read
            (stat-result expected-code)
            (let* ((read-count 0)
                   (stat-count 0)
                   (epi-object-byte-limit 8)
                   (epi-ledger--stat-function
                   (lambda (target)
                     (should (equal path target))
                     (setq stat-count (1+ stat-count))
                     stat-result))
                   (epi-ledger--read-function
                   (lambda (&rest arguments)
                     (setq read-count (1+ read-count))
                     (apply #'epi-test-ledger-io--wave6-unexpected
                            'read arguments))))
              (let ((condition
                     (should-error
                      (epi-ledger-object-get ledger reference)
                      :type 'epi-missing-object)))
                (should
                 (eq expected-code
                     (epi-test-ledger-io--wave6-assert-structured
                      condition))))
              (should (> stat-count 0))
              (should (= 0 read-count)))))
        (assert-no-read nil 'object-missing)
        (assert-no-read (epi-test-ledger-io--wave6-stat path 6 607)
                        'object-size-mismatch)
        (assert-no-read (epi-test-ledger-io--wave6-stat path 9 608)
                        'object-size-mismatch))

      ;; An injected reader failure is normalized at the public boundary and
      ;; still cannot request an unbounded range.
      (let ((epi-object-byte-limit 8)
            (epi-ledger-work-byte-limit 2)
            ranges)
        (let ((epi-ledger--stat-function
               (lambda (target)
                 (should (equal path target))
                 (epi-test-ledger-io--wave6-stat target 5 611)))
              (epi-ledger--read-function
               (lambda (target begin end)
                 (should (equal path target))
                 (push (list begin end) ranges)
                 (should (<= 0 begin end 6))
                 (should (<= (- end begin) 2))
                 (epi-ledger--fail
                  'epi-ledger-conflict 'storage-read-failed))))
          (let ((condition
                 (should-error
                  (epi-ledger-object-get ledger reference)
                  :type 'epi-missing-object)))
            (should
             (eq 'object-read-failed
                 (epi-test-ledger-io--wave6-assert-structured
                  condition)))))
        (should ranges)
        (should (= 0 (caar (last ranges)))))

      ;; Even after an exact-size stat, a replacement can expose one extra
      ;; byte.  Reads stay within declared-size plus one and within each
      ;; cooperative range bound.
      (let ((source (epi-test-ledger-io--wave6-bytes "abcdeX"))
            (epi-object-byte-limit 8)
            (epi-ledger-work-byte-limit 2)
            ranges
            events)
        (let ((epi-ledger--stat-function
               (lambda (target)
                 (should (equal path target))
                 (push 'stat events)
                 (epi-test-ledger-io--wave6-stat target 5 609)))
              (epi-ledger--read-function
               (lambda (target begin end)
                 (should (equal path target))
                 (push (list 'read begin end) events)
                 (push (list begin end) ranges)
                 (should (<= 0 begin end 6))
                 (should (<= (- end begin) 2))
                 (epi-test-ledger-io--wave6-safe-range
                  source begin end))))
          (let ((condition
                 (should-error
                  (epi-ledger-object-get ledger reference)
                  :type 'epi-missing-object)))
            (should
             (eq 'object-size-mismatch
                 (epi-test-ledger-io--wave6-assert-structured
                  condition)))))
        (setq events (nreverse events)
              ranges (nreverse ranges))
        (should (eq 'stat (car events)))
        (should ranges)
        (should (= 0 (caar ranges)))
        (should (= 6 (cadar (last ranges))))
        (cl-loop for left on ranges
                 while (cdr left)
                 do (should (= (cadar left) (caadr left))))))))

(ert-deftest epi-ledger-object-get-rejects-wrong-length-and-hash-as-missing ()
  (should (fboundp 'epi-ledger-object-get))
  (should (fboundp 'epi-ledger--object-path))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (expected (epi-test-ledger-io--wave6-bytes "abcde"))
           (reference (epi-test-ledger-io--wave6-ref expected))
           (path (epi-ledger--object-path
                  ledger (epi-object-ref-hash reference))))
      (dolist (case (list
                     (list (epi-test-ledger-io--wave6-bytes "abcd")
                           'object-size-mismatch 0)
                     (list (epi-test-ledger-io--wave6-bytes "abcdef")
                           'object-size-mismatch 0)
                     (list (epi-test-ledger-io--wave6-bytes "abcdf")
                           'object-hash-mismatch 1)))
        (pcase-let ((`(,source ,expected-code ,expected-hash-count) case))
          (let* ((read-count 0)
                 (hash-count 0)
                 (real-secure-hash (symbol-function 'secure-hash))
                 (epi-object-byte-limit 8)
                 (epi-ledger--stat-function
                  (lambda (target)
                    (should (equal path target))
                    (epi-test-ledger-io--wave6-stat target 5 610)))
                 (epi-ledger--read-function
                  (lambda (target begin end)
                    (should (equal path target))
                    (should (<= 0 begin end 6))
                    (setq read-count (1+ read-count))
                    (epi-test-ledger-io--wave6-safe-range
                     source begin end))))
            (cl-letf (((symbol-function 'secure-hash)
                       (lambda (algorithm object &optional start end binary)
                         (when (and (eq algorithm 'sha256)
                                    (stringp object))
                           (should (equal source object))
                           (should (= (length expected)
                                      (length object)))
                           (setq hash-count (1+ hash-count)))
                         (funcall real-secure-hash
                                  algorithm object start end binary))))
              (let ((condition
                     (should-error
                      (epi-ledger-object-get ledger reference)
                      :type 'epi-missing-object)))
                (should
                 (eq expected-code
                     (epi-test-ledger-io--wave6-assert-structured
                      condition)))))
            (should (> read-count 0))
            (should (= expected-hash-count hash-count))))))))

(ert-deftest epi-ledger-object-presence-distinguishes-absent-valid-and-corrupt ()
  (should (fboundp 'epi-ledger-object-put))
  (should (fboundp 'epi-ledger--object-path))
  (should (fboundp 'epi-ledger--object-present-p))
  (epi-test-with-temporary-root (root)
    (let* ((epi-ledger-work-byte-limit 2)
           (ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "good"))
           (reference (epi-test-ledger-io--wave6-put ledger bytes))
           (absent-bytes (epi-test-ledger-io--wave6-bytes "absent"))
           (absent (epi-test-ledger-io--wave6-ref absent-bytes))
           (path (epi-ledger--object-path
                  ledger (epi-object-ref-hash reference)))
           ;; Preserve a long prefix so presence must verify the whole body.
           (corrupt (epi-test-ledger-io--wave6-bytes "goox")))
      (should (eq t (epi-ledger--object-present-p ledger reference)))
      (should-not (epi-ledger--object-present-p ledger absent))
      (epi-ledger--write-bytes path corrupt 'replace t)
      (let ((condition
             (should-error
              (epi-ledger--object-present-p ledger reference)
              :type 'epi-ledger-corrupt)))
        (should
         (eq 'object-content-mismatch
             (epi-test-ledger-io--wave6-assert-structured condition))))
      (should (equal corrupt
                     (epi-test-ledger-io--literal-file-bytes path))))))

(ert-deftest epi-ledger-object-directory-contents-never-imply-presence ()
  (should (fboundp 'epi-ledger-object-get))
  (should (fboundp 'epi-ledger--object-path))
  (should (fboundp 'epi-ledger--object-present-p))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (hash (concat "ab" (make-string 62 ?c)))
           (reference
            (make-epi-object-ref
             :hash hash :size 3
             :media-type epi-test-ledger-io--wave6-media-type
             :role epi-test-ledger-io--wave6-role))
           (target (epi-ledger--object-path ledger hash))
           (directory (file-name-directory target))
           (decoy (expand-file-name (make-string 64 ?d) directory))
           (marker (expand-file-name "not-an-object" directory))
           (stat-count 0))
      (make-directory directory t)
      (set-file-modes directory #o700)
      (epi-ledger--write-bytes decoy
                               (epi-test-ledger-io--wave6-bytes "decoy")
                               'exclusive-create t)
      (epi-ledger--write-bytes marker
                               (epi-test-ledger-io--wave6-bytes "marker")
                               'exclusive-create t)
      (let ((epi-ledger--stat-function
             (lambda (path)
               (should (equal target path))
               (setq stat-count (1+ stat-count))
               nil))
            (epi-ledger--read-function
             (apply-partially #'epi-test-ledger-io--wave6-unexpected
                              'read)))
        (cl-letf
            (((symbol-function 'directory-files)
              (apply-partially #'epi-test-ledger-io--wave6-unexpected
                               'directory-files))
             ((symbol-function 'directory-files-recursively)
              (apply-partially #'epi-test-ledger-io--wave6-unexpected
                               'directory-files-recursively))
             ((symbol-function 'file-expand-wildcards)
              (apply-partially #'epi-test-ledger-io--wave6-unexpected
                               'file-expand-wildcards))
             ((symbol-function 'directory-files-and-attributes)
              (apply-partially #'epi-test-ledger-io--wave6-unexpected
                               'directory-files-and-attributes))
             ((symbol-function 'file-name-all-completions)
              (apply-partially #'epi-test-ledger-io--wave6-unexpected
                               'file-name-all-completions))
             ((symbol-function 'file-name-completion)
              (apply-partially #'epi-test-ledger-io--wave6-unexpected
                               'file-name-completion)))
          (should-not (epi-ledger--object-present-p ledger reference))
          (let ((condition
                 (should-error
                  (epi-ledger-object-get ledger reference)
                  :type 'epi-missing-object)))
            (should
             (eq 'object-missing
                 (epi-test-ledger-io--wave6-assert-structured
                  condition))))))
      (should (>= stat-count 2))
      (should-not (file-exists-p target))
      (should (equal (epi-test-ledger-io--wave6-bytes "decoy")
                     (epi-test-ledger-io--literal-file-bytes decoy)))
      (should (equal (epi-test-ledger-io--wave6-bytes "marker")
                     (epi-test-ledger-io--literal-file-bytes marker))))))

(ert-deftest epi-ledger-object-storage-seam-errors-are-closed ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "closed-writer"))
           (epi-ledger--byte-writer
            (lambda (&rest _arguments)
              (signal 'file-error '("injected object writer failure")))))
      (let ((condition
             (should-error
              (epi-test-ledger-io--wave6-put ledger bytes)
              :type 'epi-ledger-conflict)))
        (should
         (eq 'storage-write-failed
             (epi-test-ledger-io--wave6-assert-structured condition))))))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "closed-publisher"))
           (epi-ledger--publish-function
            (lambda (&rest _arguments)
              (signal 'file-error '("injected object publisher failure")))))
      (let ((condition
             (should-error
              (epi-test-ledger-io--wave6-put ledger bytes)
              :type 'epi-ledger-conflict)))
        (should
         (eq 'storage-publication-failed
             (epi-test-ledger-io--wave6-assert-structured condition))))))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "closed-stat"))
           (reference (epi-test-ledger-io--wave6-ref bytes))
           (path (epi-ledger--object-path ledger
                                          (epi-object-ref-hash reference)))
           (real-stat epi-ledger--stat-function)
           (epi-ledger--stat-function
            (lambda (candidate)
              (if (equal candidate path)
                  (signal 'file-error '("injected object stat failure"))
                (funcall real-stat candidate)))))
      (let ((condition
             (should-error
              (epi-test-ledger-io--wave6-put ledger bytes)
              :type 'epi-ledger-conflict)))
        (should
         (eq 'storage-write-failed
             (epi-test-ledger-io--wave6-assert-structured condition))))
      (let ((condition
             (should-error
              (epi-ledger--object-present-p ledger reference)
              :type 'epi-ledger-corrupt)))
        (should
         (eq 'object-content-mismatch
             (epi-test-ledger-io--wave6-assert-structured condition)))))))

(ert-deftest epi-ledger-object-structured-stat-errors-are-normalized ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "structured-stat"))
           (reference (epi-test-ledger-io--wave6-ref bytes))
           (path (epi-ledger--object-path
                  ledger (epi-object-ref-hash reference)))
           (real-stat epi-ledger--stat-function)
           (epi-ledger--stat-function
            (lambda (candidate)
              (if (equal candidate path)
                  (epi-ledger--fail
                   'epi-ledger-conflict 'storage-stat-failed)
                (funcall real-stat candidate)))))
      (let ((condition
             (should-error
              (epi-test-ledger-io--wave6-put ledger bytes)
              :type 'epi-ledger-conflict)))
        (should
         (eq 'storage-write-failed
             (epi-test-ledger-io--wave6-assert-structured condition))))
      (let ((condition
             (should-error
              (epi-ledger-object-get ledger reference)
              :type 'epi-missing-object)))
        (should
         (eq 'object-read-failed
             (epi-test-ledger-io--wave6-assert-structured condition))))
      (let ((condition
             (should-error
              (epi-ledger--object-present-p ledger reference)
              :type 'epi-ledger-corrupt)))
        (should
         (eq 'object-content-mismatch
             (epi-test-ledger-io--wave6-assert-structured condition))))))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "unrelated-stat"))
           (reference (epi-test-ledger-io--wave6-ref bytes))
           (epi-ledger--stat-function
            (lambda (_path)
              (epi-ledger--fail 'epi-ledger-conflict 'unrelated-stat))))
      (let ((condition
             (should-error
              (epi-ledger-object-get ledger reference)
              :type 'epi-ledger-conflict)))
        (should
         (eq 'unrelated-stat
             (epi-test-ledger-io--wave6-assert-structured condition)))))))

(ert-deftest epi-ledger-object-stage-specific-stat-errors-are-normalized ()
  (dolist (case '((epi-ledger-conflict
                   storage-stat-failed storage-write-failed)
                  (epi-ledger-conflict
                   unrelated-temp-stat unrelated-temp-stat)
                  (epi-ledger-format-error
                   non-regular-storage-leaf storage-write-failed)))
    (epi-test-with-temporary-root (root)
      (let* ((ledger (epi-test-ledger-io--wave6-open root))
             (bytes (epi-test-ledger-io--wave6-bytes "temporary-stat"))
             (condition-type (car case))
             (injected (cadr case))
             (expected (caddr case))
             (real-stat (symbol-function 'epi-ledger--stat-local-file))
             (temp-stat-count 0))
        (cl-letf (((symbol-function 'epi-ledger--stat-local-file)
                   (lambda (path)
                     (if (string-match-p "\\.epi-tmp-" path)
                         (progn
                           (setq temp-stat-count (1+ temp-stat-count))
                           (epi-ledger--fail
                            condition-type injected))
                       (funcall real-stat path)))))
          (let ((condition
                 (should-error
                  (epi-test-ledger-io--wave6-put ledger bytes)
                  :type 'epi-ledger-conflict)))
            (should
             (eq expected
                 (epi-test-ledger-io--wave6-assert-structured
                  condition)))))
        (should (>= temp-stat-count 1)))))
  (dolist (case '((storage-stat-failed storage-publication-failed)
                  (unrelated-publish-stat unrelated-publish-stat)))
    (epi-test-with-temporary-root (root)
      (let* ((ledger (epi-test-ledger-io--wave6-open root))
             (bytes (epi-test-ledger-io--wave6-bytes "publication-stat"))
             (injected (car case))
             (expected (cadr case))
             (epi-ledger--publish-function
              (lambda (&rest _arguments)
                (epi-ledger--fail 'epi-ledger-conflict injected))))
        (let ((condition
               (should-error
                (epi-test-ledger-io--wave6-put ledger bytes)
                :type 'epi-ledger-conflict)))
          (should
           (eq expected
               (epi-test-ledger-io--wave6-assert-structured
                condition))))))))

(ert-deftest epi-ledger-object-publication-races-have-stable-taxonomy ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "nonregular-winner"))
           (hash (secure-hash 'sha256 bytes))
           (destination (epi-ledger--object-path ledger hash))
           (real-publisher epi-ledger--publish-function)
           (epi-ledger--publish-function
            (lambda (source target)
              (make-directory target)
              (funcall real-publisher source target))))
      (let ((condition
             (should-error
              (epi-test-ledger-io--wave6-put ledger bytes)
              :type 'epi-ledger-corrupt)))
        (should
         (eq 'object-content-mismatch
             (epi-test-ledger-io--wave6-assert-structured condition))))
      (should (file-directory-p destination))))
  (dolist (failure '(raw structured))
    (epi-test-with-temporary-root (root)
      (let* ((ledger (epi-test-ledger-io--wave6-open root))
             (bytes (epi-test-ledger-io--wave6-bytes "reported-winner"))
             (hash (secure-hash 'sha256 bytes))
             (destination (epi-ledger--object-path ledger hash))
             (epi-ledger--publish-function
              (lambda (_source target)
                (make-directory target)
                (pcase failure
                  ('raw
                   (signal 'file-error
                           '("injected occupied publication")))
                  ('structured
                   (epi-ledger--fail
                    'epi-ledger-conflict 'storage-stat-failed))))))
        (let ((condition
               (should-error
                (epi-test-ledger-io--wave6-put ledger bytes)
                :type 'epi-ledger-corrupt)))
          (should
           (eq 'object-content-mismatch
               (epi-test-ledger-io--wave6-assert-structured
                condition))))
        (should (file-directory-p destination)))))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "published-stat"))
           (reference (epi-test-ledger-io--wave6-ref bytes))
           (destination (epi-ledger--object-path
                         ledger (epi-object-ref-hash reference)))
           (real-publisher epi-ledger--publish-function)
           (epi-ledger--publish-function
            (lambda (source target)
              (funcall real-publisher source target)
              (epi-ledger--fail
               'epi-ledger-conflict 'storage-stat-failed))))
      (let ((condition
             (should-error
              (epi-test-ledger-io--wave6-put ledger bytes)
              :type 'epi-ledger-conflict)))
        (should
         (eq 'storage-publication-failed
             (epi-test-ledger-io--wave6-assert-structured condition)))
        (should
         (plist-get (epi-test-ledger-io--condition-detail condition)
                    :published)))
      (should (file-exists-p destination))
      (should (equal bytes
                     (epi-test-ledger-io--literal-file-bytes
                      destination)))))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "unknown-published-stat"))
           (reference (epi-test-ledger-io--wave6-ref bytes))
           (destination (epi-ledger--object-path
                         ledger (epi-object-ref-hash reference)))
           (real-publisher epi-ledger--publish-function)
           (real-stat-local
            (symbol-function 'epi-ledger--stat-local-file))
           reported)
      (let ((epi-ledger--publish-function
             (lambda (source target)
               (funcall real-publisher source target)
               (setq reported t)
               (epi-ledger--fail
                'epi-ledger-conflict 'storage-stat-failed))))
        (cl-letf
            (((symbol-function 'epi-ledger--stat-local-file)
              (lambda (path)
                (if (and reported (equal path destination))
                    (signal 'file-error
                            '("injected publication proof failure"))
                  (funcall real-stat-local path)))))
          (let* ((condition
                  (should-error
                   (epi-test-ledger-io--wave6-put ledger bytes)
                   :type 'epi-ledger-conflict))
                 (detail
                  (epi-test-ledger-io--condition-detail condition)))
            (should (eq 'storage-publication-failed
                        (plist-get detail :code)))
            (should (plist-get detail :published)))))
      (should (file-exists-p destination))
      (should (equal bytes
                     (epi-test-ledger-io--literal-file-bytes
                      destination)))))
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "missing-publication"))
           (hash (secure-hash 'sha256 bytes))
           (destination (epi-ledger--object-path ledger hash))
           (epi-ledger--publish-function
            (lambda (_source _target) nil)))
      (let* ((condition
              (should-error
               (epi-test-ledger-io--wave6-put ledger bytes)
               :type 'epi-ledger-conflict))
             (detail (epi-test-ledger-io--condition-detail condition)))
        (should (eq 'storage-publication-failed
                    (plist-get detail :code)))
        (should-not (plist-member detail :published)))
      (should-not (file-exists-p destination)))))

(ert-deftest epi-ledger-object-preexisting-temporary-is-never-deleted ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "object"))
           (foreign (epi-test-ledger-io--wave6-bytes "foreign"))
           (hash (secure-hash 'sha256 bytes))
           (destination (epi-ledger--object-path ledger hash))
           (epi--id-function
            (lambda () epi-test-ledger-io--wave6-temporary-id)))
      (epi-ledger--ensure-private-parent destination)
      (let ((temporary (epi-ledger--hidden-sibling destination)))
        (epi-ledger--write-bytes temporary foreign 'exclusive-create t)
        (let ((condition
               (should-error
                (epi-test-ledger-io--wave6-put ledger bytes)
                :type 'epi-ledger-conflict)))
          (should
           (eq 'destination-exists
               (epi-test-ledger-io--wave6-assert-structured condition))))
        (should (equal foreign
                       (epi-test-ledger-io--literal-file-bytes temporary)))
        (should-not (file-exists-p destination))))))

(ert-deftest epi-ledger-object-cleanup-preserves-a-replacement-temporary ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "winner"))
           (foreign (epi-test-ledger-io--wave6-bytes "foreign"))
           (hash (secure-hash 'sha256 bytes))
           (destination (epi-ledger--object-path ledger hash))
           (real-writer epi-ledger--byte-writer)
           temporary
           (epi-ledger--publish-function
            (lambda (source target)
              (setq temporary (substring-no-properties source))
              (delete-file source)
              (funcall real-writer source foreign 'exclusive-create t)
              (funcall real-writer target bytes 'exclusive-create t)
              (epi-ledger--fail
               'epi-ledger-conflict 'destination-exists))))
      (let ((reference (epi-test-ledger-io--wave6-put ledger bytes)))
        (should (equal hash (epi-object-ref-hash reference))))
      (should temporary)
      (should (equal foreign
                     (epi-test-ledger-io--literal-file-bytes temporary)))
      (should (equal bytes
                     (epi-test-ledger-io--literal-file-bytes destination))))))

(ert-deftest epi-ledger-object-cleanup-preserves-nonregular-replacements ()
  (dolist (kind '(directory symlink))
    (epi-test-with-temporary-root (root)
      (let* ((ledger (epi-test-ledger-io--wave6-open root))
             (bytes (epi-test-ledger-io--wave6-bytes "winner"))
             (foreign (epi-test-ledger-io--wave6-bytes "foreign"))
             (hash (secure-hash 'sha256 bytes))
             (destination (epi-ledger--object-path ledger hash))
             (external (expand-file-name "external.bin" root))
             (real-writer epi-ledger--byte-writer)
             temporary
             (epi-ledger--publish-function
              (lambda (source target)
                (setq temporary (substring-no-properties source))
                (delete-file source)
                (pcase kind
                  ('directory (make-directory source))
                  ('symlink
                   (funcall real-writer
                            external foreign 'exclusive-create t)
                   (make-symbolic-link external source)))
                (funcall real-writer target bytes 'exclusive-create t)
                (epi-ledger--fail
                 'epi-ledger-conflict 'destination-exists))))
        (let ((reference (epi-test-ledger-io--wave6-put ledger bytes)))
          (should (equal hash (epi-object-ref-hash reference))))
        (should temporary)
        (pcase kind
          ('directory (should (file-directory-p temporary)))
          ('symlink (should (equal external (file-symlink-p temporary)))))
        (should (equal bytes
                       (epi-test-ledger-io--literal-file-bytes
                        destination)))
        (when (eq kind 'symlink)
          (should (equal foreign
                         (epi-test-ledger-io--literal-file-bytes
                          external))))))))

(ert-deftest epi-ledger-object-refuses-a-replaced-publication-source ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "publish"))
           (corrupt (epi-test-ledger-io--wave6-bytes "corrupt"))
           (hash (secure-hash 'sha256 bytes))
           (destination (epi-ledger--object-path ledger hash))
           (real-writer epi-ledger--byte-writer)
           (real-publisher epi-ledger--publish-function)
           temporary
           (epi-ledger--publish-function
            (lambda (source target)
              (setq temporary (substring-no-properties source))
              (delete-file source)
              (funcall real-writer source corrupt 'exclusive-create t)
              (funcall real-publisher source target))))
      (let ((condition
             (should-error
              (epi-test-ledger-io--wave6-put ledger bytes)
              :type 'epi-ledger-conflict)))
        (should
         (eq 'storage-publication-failed
             (epi-test-ledger-io--wave6-assert-structured condition))))
      (should temporary)
      (should-not (file-exists-p destination))
      (should (equal corrupt
                     (epi-test-ledger-io--literal-file-bytes temporary))))))

(ert-deftest epi-ledger-object-revalidates-a-successful-publication ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "abcdef"))
           (corrupt (epi-test-ledger-io--wave6-bytes "abcdeX"))
           (hash (secure-hash 'sha256 bytes))
           (destination (epi-ledger--object-path ledger hash))
           (real-writer epi-ledger--byte-writer)
           (real-publisher epi-ledger--publish-function)
           (epi-ledger--publish-function
            (lambda (source target)
              (funcall real-publisher source target)
              (funcall real-writer source corrupt 'replace t))))
      (let ((condition
             (should-error
              (epi-test-ledger-io--wave6-put ledger bytes)
              :type 'epi-ledger-corrupt)))
        (should
         (eq 'object-content-mismatch
             (epi-test-ledger-io--wave6-assert-structured condition))))
      (should-not (file-exists-p destination)))))

(ert-deftest epi-ledger-object-nonregular-hash-path-is-corruption ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "directory"))
           (reference (epi-test-ledger-io--wave6-ref bytes))
           (path (epi-ledger--object-path ledger
                                          (epi-object-ref-hash reference))))
      (make-directory path t)
      (dolist (thunk
               (list (lambda ()
                       (epi-test-ledger-io--wave6-put ledger bytes))
                     (lambda ()
                       (epi-ledger--object-present-p ledger reference))))
        (let ((condition
               (should-error (funcall thunk) :type 'epi-ledger-corrupt)))
          (should
           (eq 'object-content-mismatch
               (epi-test-ledger-io--wave6-assert-structured
                condition))))))))

(ert-deftest epi-ledger-object-hash-path-never-follows-a-leaf-symlink ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "symlink"))
           (reference (epi-test-ledger-io--wave6-ref bytes))
           (path (epi-ledger--object-path
                  ledger (epi-object-ref-hash reference)))
           (external (expand-file-name "external.bin" root)))
      (epi-ledger--write-bytes external bytes 'exclusive-create t)
      (epi-ledger--ensure-private-parent path)
      (make-symbolic-link external path)
      (dolist (thunk
               (list (lambda ()
                       (epi-test-ledger-io--wave6-put ledger bytes))
                     (lambda ()
                       (epi-ledger--object-present-p ledger reference))))
        (let ((condition
               (should-error (funcall thunk) :type 'epi-ledger-corrupt)))
          (should
           (eq 'object-content-mismatch
               (epi-test-ledger-io--wave6-assert-structured
                condition)))))
      (let ((condition
             (should-error
              (epi-ledger-object-get ledger reference)
              :type 'epi-missing-object)))
        (should
         (eq 'object-read-failed
             (epi-test-ledger-io--wave6-assert-structured condition))))
      (should (equal external (file-symlink-p path)))
      (should (equal bytes
                     (epi-test-ledger-io--literal-file-bytes
                      external))))))

(ert-deftest epi-ledger-object-required-cleanup-failure-is-ambiguous ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "cleanup"))
           (hash (secure-hash 'sha256 bytes))
           (destination (epi-ledger--object-path ledger hash))
           (real-publisher epi-ledger--publish-function)
           (real-stat-local
            (symbol-function 'epi-ledger--stat-local-file))
           published
           temporary)
      (let ((epi-ledger--publish-function
             (lambda (source target)
               (setq temporary (substring-no-properties source))
               (funcall real-publisher source target)
               (setq published t))))
        (cl-letf
            (((symbol-function 'epi-ledger--stat-local-file)
              (lambda (path)
                (if (and published (equal path temporary))
                    (signal 'file-error '("injected cleanup stat failure"))
                  (funcall real-stat-local path)))))
          (let ((condition
                 (should-error
                  (epi-test-ledger-io--wave6-put ledger bytes)
                  :type 'epi-ledger-conflict)))
            (should
             (eq 'storage-publication-failed
                 (epi-test-ledger-io--wave6-assert-structured
                  condition)))
            (should
             (plist-get (epi-test-ledger-io--condition-detail condition)
                        :published)))))
      (should temporary)
      (should (file-exists-p temporary))
      (should (file-exists-p destination))
      (should (file-equal-p temporary destination)))))

(ert-deftest epi-ledger-object-later-chunk-failure-removes-owned-temporary ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "partial"))
           (real-writer epi-ledger--byte-writer)
           (writer-count 0)
           temporary
           (epi-ledger-work-byte-limit 2)
           (epi-ledger--byte-writer
            (lambda (path payload mode durablep)
              (setq writer-count (1+ writer-count)
                    temporary (substring-no-properties path))
              (if (= writer-count 2)
                  (signal 'file-error '("injected later chunk failure"))
                (funcall real-writer path payload mode durablep)))))
      (let ((condition
             (should-error
              (epi-test-ledger-io--wave6-put ledger bytes)
              :type 'epi-ledger-conflict)))
        (should
         (eq 'storage-write-failed
             (epi-test-ledger-io--wave6-assert-structured condition))))
      (should (= 2 writer-count))
      (should temporary)
      (should-not (file-exists-p temporary)))))

(ert-deftest epi-ledger-object-final-stat-callback-cannot-publish-corruption ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "abcdef"))
           (corrupt (epi-test-ledger-io--wave6-bytes "abcdeX"))
           (hash (secure-hash 'sha256 bytes))
           (destination (epi-ledger--object-path ledger hash))
           (real-stat epi-ledger--stat-function)
           (real-writer epi-ledger--byte-writer)
           (real-publisher epi-ledger--publish-function)
           published
           (target-stat-count 0)
           (epi-ledger--publish-function
            (lambda (source target)
              (funcall real-publisher source target)
              (setq published t)))
           (epi-ledger--stat-function
            (lambda (path)
              (let ((identity (funcall real-stat path)))
                (when (and published (equal path destination))
                  (setq target-stat-count (1+ target-stat-count))
                  (when (= target-stat-count 2)
                    (funcall real-writer path corrupt 'replace t)))
                identity))))
      (let ((condition
             (should-error
              (epi-test-ledger-io--wave6-put ledger bytes)
              :type 'epi-ledger-corrupt)))
        (should
         (eq 'object-content-mismatch
             (epi-test-ledger-io--wave6-assert-structured condition))))
      (should (= 2 target-stat-count))
      (should-not (file-exists-p destination)))))

(ert-deftest epi-ledger-object-presence-has-a-final-raw-proof ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "abcdef"))
           (corrupt (epi-test-ledger-io--wave6-bytes "abcdeX"))
           (reference (epi-test-ledger-io--wave6-put ledger bytes))
           (destination (epi-ledger--object-path
                         ledger (epi-object-ref-hash reference)))
           (real-stat epi-ledger--stat-function)
           (real-writer epi-ledger--byte-writer)
           (target-stat-count 0)
           (epi-ledger--stat-function
            (lambda (path)
              (let ((identity (funcall real-stat path)))
                (when (equal path destination)
                  (setq target-stat-count (1+ target-stat-count))
                  (when (= target-stat-count 3)
                    (funcall real-writer path corrupt 'replace t)))
                identity))))
      (let ((condition
             (should-error
              (epi-ledger--object-present-p ledger reference)
              :type 'epi-ledger-corrupt)))
        (should
         (eq 'object-content-mismatch
             (epi-test-ledger-io--wave6-assert-structured condition))))
      (should (= 3 target-stat-count))
      (should (equal corrupt
                     (epi-test-ledger-io--literal-file-bytes
                      destination))))))

(ert-deftest epi-ledger-object-indeterminate-verification-preserves-publication ()
  (epi-test-with-temporary-root (root)
    (let* ((ledger (epi-test-ledger-io--wave6-open root))
           (bytes (epi-test-ledger-io--wave6-bytes "accepted"))
           (reference (epi-test-ledger-io--wave6-ref bytes))
           (destination (epi-ledger--object-path
                         ledger (epi-object-ref-hash reference)))
           (real-reader epi-ledger--read-function)
           (real-publisher epi-ledger--publish-function)
           fail-read
           accepted
           (epi-ledger--publish-function
            (lambda (source target)
              (funcall real-publisher source target)
              (should (equal bytes
                             (epi-ledger-object-get ledger reference)))
              (setq accepted t
                    fail-read t)))
           (epi-ledger--read-function
            (lambda (path begin end)
              (if (and fail-read (equal path destination))
                  (signal 'file-error
                          '("injected indeterminate verification"))
                (funcall real-reader path begin end)))))
      (should-error
       (epi-test-ledger-io--wave6-put ledger bytes)
       :type 'epi-ledger-corrupt)
      (should accepted)
      (should (file-exists-p destination))
      (should (equal bytes
                     (epi-test-ledger-io--literal-file-bytes
                      destination))))))


(provide 'epi-ledger-io-test)

;;; epi-ledger-io-test.el ends here
