;;; epi-package-test.el --- Package contract tests for Epi  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley
;; Keywords: tools

;;; Commentary:

;; Test the dependency-light public facade before any implementation exists.
;; In particular, do not require `epi' at top level: every test enters the
;; shared fixture so the runner can register and count the tests while the
;; package is intentionally absent during the first red run.
;;
;; The coordinator intentionally adopts the private Task 1 seam spellings
;; exercised below: `epi--event-create', `epi--new-id', `epi--wall-time',
;; `epi--format-timestamp', `epi--deadline-time', and their frozen bindable
;; source variables.  These private names were unspecified by the prose and
;; are made concrete here so the red contract and implementation agree.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'rx)
(require 'subr-x)
(require 'epi-test-helper)

(defconst epi-test-package--condition-chains
  '((epi-error epi-error error)
    (epi-busy epi-busy epi-error error)
    (epi-invalid-state epi-invalid-state epi-error error)
    (epi-stale-generation
     epi-stale-generation epi-invalid-state epi-error error)
    (epi-limit-exceeded epi-limit-exceeded epi-error error)
    (epi-ledger-error epi-ledger-error epi-error error)
    (epi-ledger-format-error
     epi-ledger-format-error epi-ledger-error epi-error error)
    (epi-ledger-corrupt
     epi-ledger-corrupt epi-ledger-error epi-error error)
    (epi-ledger-truncated-tail
     epi-ledger-truncated-tail epi-ledger-corrupt
     epi-ledger-error epi-error error)
    (epi-ledger-conflict
     epi-ledger-conflict epi-ledger-error epi-error error)
    (epi-missing-object
     epi-missing-object epi-ledger-error epi-error error)
    (epi-gptel-error epi-gptel-error epi-error error)
    (epi-gptel-incompatible
     epi-gptel-incompatible epi-gptel-error epi-error error)
    (epi-provider-error
     epi-provider-error epi-gptel-error epi-error error)
    (epi-tool-error epi-tool-error epi-error error)
    (epi-tool-denied epi-tool-denied epi-tool-error epi-error error)
    (epi-tool-uncertain
     epi-tool-uncertain epi-tool-error epi-error error)
    (epi-interaction-required epi-interaction-required epi-error error)
    (epi-cancelled epi-cancelled epi-error error))
  "Exact transitive `error-conditions' chains for Epi conditions.")

(defconst epi-test-package--option-specs
  '((epi-ledger-work-record-limit 256 positive-integer)
    (epi-ledger-work-byte-limit 1048576 positive-integer)
    (epi-ledger-work-time-budget 0.008 nonnegative-seconds)
    (epi-record-json-byte-limit 15728640 positive-integer)
    (epi-record-frame-byte-limit 16777216 positive-integer)
    (epi-record-decode-byte-limit 15728640 positive-integer)
    (epi-hash-input-byte-limit 16777216 positive-integer)
    (epi-json-depth-limit 32 positive-integer)
    (epi-json-item-limit 131072 positive-integer)
    (epi-object-byte-limit 16777216 positive-integer)
    (epi-recovery-fragment-byte-limit 16777216 positive-integer)
    (epi-drain-item-limit 128 positive-integer)
    (epi-drain-byte-limit 524288 positive-integer)
    (epi-drain-time-budget 0.008 nonnegative-seconds)
    (epi-callback-queue-item-limit 4096 positive-integer)
    (epi-callback-queue-byte-limit 16777216 positive-integer)
    (epi-callback-queue-reserve-items 1 positive-integer)
    (epi-callback-queue-reserve-bytes 4096 positive-integer)
    (epi-callback-event-byte-limit 524288 positive-integer)
    (epi-tool-argument-byte-limit 262144 positive-integer)
    (epi-tool-schema-byte-limit 262144 positive-integer)
    (epi-tool-schema-property-limit 64 positive-integer)
    (epi-tool-schema-required-limit 64 positive-integer)
    (epi-tool-schema-enum-per-property-limit 64 positive-integer)
    (epi-tool-schema-enum-total-limit 256 positive-integer)
    (epi-tool-argument-member-limit 64 positive-integer)
    (epi-provider-call-id-byte-limit 4096 positive-integer)
    (epi-provider-tool-name-byte-limit 128 positive-integer)
    (epi-provider-leg-raw-byte-limit 4194304 positive-integer)
    (epi-provider-turn-raw-byte-limit 33554432 positive-integer)
    (epi-provider-leg-output-byte-limit 2097152 positive-integer)
    (epi-provider-turn-output-byte-limit 16777216 positive-integer)
    (epi-provider-tool-call-limit 32 positive-integer)
    (epi-gptel-no-progress-timeout 120 nonnegative-seconds)
    (epi-tool-approval-timeout nil nil-or-nonnegative-seconds)
    (epi-user-prompt-byte-limit 2097152 positive-integer)
    (epi-system-prompt-byte-limit 262144 positive-integer)
    (epi-instruction-resource-byte-limit 262144 positive-integer)
    (epi-instruction-total-byte-limit 1048576 positive-integer)
    (epi-provider-context-byte-limit 16777216 positive-integer)
    (epi-read-file-result-byte-limit 1048576 positive-integer)
    (epi-replace-text-input-byte-limit 4194304 positive-integer)
    (epi-replace-text-diff-byte-limit 1048576 positive-integer)
    (epi-ui-initial-message-limit 200 positive-integer)
    (epi-ui-conversation-action-byte-limit 1048576 positive-integer)
    (epi-ui-tree-node-limit 1000 positive-integer)
    (epi-ui-tree-label-byte-limit 384 positive-integer)
    (epi-ui-tree-action-byte-limit 524288 positive-integer)
    (epi-callback-time-budget 0.004 nonnegative-seconds)
    (epi-session-directory epi-test-package--session-directory directory)
    (epi-global-instructions-file nil nil-or-file))
  "Frozen Task 1 option names, defaults, and Customize contracts.")

(defconst epi-test-package--committed-event-kinds
  '(session-info operation-started turn-started message reasoning leaf
    tool-planned tool-approved tool-denied tool-started tool-finished
    turn-finished turn-failed turn-cancelled turn-interrupted
    operation-finished operation-failed operation-cancelled
    operation-interrupted recovery-origin tool-approval-needed agent-settled)
  "All first-slice committed event kinds.")

(defconst epi-test-package--volatile-event-kinds
  '(text-delta reasoning-delta tool-progress diagnostic)
  "All first-slice volatile event kinds.")

(defconst epi-test-package--runtime-autoloads
  '(epi-session-create epi-session-open epi-session-close
    epi-session-id epi-session-file epi-session-phase epi-session-state
    epi-session-prompt epi-session-abort epi-session-wait
    epi-session-select-leaf epi-session-subscribe epi-session-unsubscribe
    epi-tool-approve epi-tool-deny epi-session-recover-tail)
  "Runtime-owned noninteractive public autoloads.")

(defconst epi-test-package--ui-autoloads
  '(epi-display-session epi-display-tree epi-display-ledger)
  "UI-owned noninteractive public autoloads.")

(defconst epi-test-package--ui-command-autoloads
  '(epi epi-open-session epi-send epi-abort epi-show-tree epi-show-ledger
    epi-session-mode epi-ledger-mode epi-tree-mode)
  "UI-owned interactive command and public mode autoloads.")

(defun epi-test-package--expected-default (expected)
  "Resolve EXPECTED when it names a dynamic frozen default."
  (if (eq expected 'epi-test-package--session-directory)
      (expand-file-name "epi/sessions/" user-emacs-directory)
    expected))

(defun epi-test-package--custom-type-matches-p (type value)
  "Return non-nil when Customize TYPE accepts VALUE."
  (require 'wid-edit)
  (widget-apply (widget-convert type) :match value))

(defun epi-test-package--const-nil-type-p (type)
  "Return non-nil when TYPE is a Customize const arm whose value is nil."
  (and (consp type)
       (eq (car type) 'const)
       (null (car (last type)))))

(defun epi-test-package--assert-nil-choice (type value-type)
  "Assert TYPE is a two-arm choice between nil and VALUE-TYPE."
  (should (consp type))
  (should (eq (car type) 'choice))
  (let ((arms (cdr type)))
    (should (= 2 (length arms)))
    (should (= 1 (cl-count value-type arms :test #'equal)))
    (should (= 1 (cl-count-if
                  #'epi-test-package--const-nil-type-p arms)))))

(defun epi-test-package--assert-custom-contract (type contract)
  "Assert that Customize TYPE implements CONTRACT."
  (pcase contract
    ('positive-integer
     (should (eq type 'epi-positive-integer)))
    ('nonnegative-seconds
     (should (eq type 'epi-nonnegative-seconds)))
    ('nil-or-nonnegative-seconds
     (epi-test-package--assert-nil-choice
      type 'epi-nonnegative-seconds))
    ('directory
     (should (eq type 'directory)))
    ('nil-or-file
     (epi-test-package--assert-nil-choice type 'file))
    (_ (ert-fail (format "Unknown custom contract %S" contract))))
  (pcase contract
    ('positive-integer
     (dolist (value '(1 19))
       (should (epi-test-package--custom-type-matches-p type value)))
     (dolist (value '(0 -1 1.0 0.5 nil "1"))
       (should-not (epi-test-package--custom-type-matches-p type value))))
    ('nonnegative-seconds
     (dolist (value '(0 1 0.0 0.125))
       (should (epi-test-package--custom-type-matches-p type value)))
     (dolist (value '(-1 -0.125 nil "0"))
       (should-not (epi-test-package--custom-type-matches-p type value))))
    ('nil-or-nonnegative-seconds
     (dolist (value '(nil 0 1 0.0 0.125))
       (should (epi-test-package--custom-type-matches-p type value)))
     (dolist (value '(-1 -0.125 "0"))
       (should-not (epi-test-package--custom-type-matches-p type value))))
    ('directory
     (should (epi-test-package--custom-type-matches-p type default-directory))
     (should-not (epi-test-package--custom-type-matches-p type nil))
     (should-not (epi-test-package--custom-type-matches-p type 7)))
    ('nil-or-file
     (should (epi-test-package--custom-type-matches-p type nil))
     (should (epi-test-package--custom-type-matches-p
              type (or (locate-library "epi") "epi.el")))
     (should-not (epi-test-package--custom-type-matches-p type 7)))
    (_ (ert-fail (format "Unknown custom contract %S" contract)))))

(defun epi-test-package--sort-requirements (requirements)
  "Return a fresh PACKAGE REQUIREMENTS list sorted by package name."
  (sort (copy-tree requirements)
        (lambda (left right)
          (string-lessp (symbol-name (car left))
                        (symbol-name (car right))))))

(cl-defun epi-test-package--make-event
    (&key
     (kind 'message)
     (durability 'committed)
     (session-id "session")
     (generation "generation")
     (operation-id "operation")
     (turn-id "turn")
     (attempt-id "attempt")
     (call-id "call")
     (record-id "record")
     (sequence 1)
     live-sequence
     (payload '(("value" . "payload"))))
  "Construct an event through the frozen private validation seam."
  (epi--event-create
   :kind kind
   :durability durability
   :session-id session-id
   :generation generation
   :operation-id operation-id
   :turn-id turn-id
   :attempt-id attempt-id
   :call-id call-id
   :record-id record-id
   :sequence sequence
   :live-sequence live-sequence
   :payload payload))

(defun epi-test-package--assert-autoload (symbol file interactive)
  "Assert SYMBOL is an autoload from FILE with INTERACTIVE status."
  (should (fboundp symbol))
  (let ((definition (symbol-function symbol)))
    (should (autoloadp definition))
    (should (equal file (nth 1 definition))))
  (if interactive
      (should (commandp symbol))
    (should-not (commandp symbol))))

(ert-deftest epi-package-load-is-gptel-lazy ()
  (epi-test-with-epi-loaded
    ;; The Makefile runs requested test files in fresh batch processes, so
    ;; this assertion observes Epi's load boundary rather than prior suites.
    (should (featurep 'epi))
    (should-not
     (cl-remove-if-not
      (lambda (feature)
        (string-prefix-p "gptel" (symbol-name feature)))
      features))))

(ert-deftest epi-package-has-frozen-metadata ()
  (epi-test-with-epi-loaded
    (require 'lisp-mnt)
    (let ((library (locate-library "epi"))
          (expected
           '((emacs "30.1")
             (org "9.7")
             (gptel "0.9.9.5")
             (transient "0.7.8")
             (compat "30.1.0.0"))))
      (should library)
      (with-temp-buffer
        (insert-file-contents library)
        (goto-char (point-min))
        (should (string-match-p
                 "lexical-binding:[[:space:]]*t"
                 (buffer-substring-no-properties
                  (line-beginning-position) (line-end-position))))
        (let ((requirements (lm-package-requires)))
          (should (= (length requirements)
                     (length (delete-dups
                              (mapcar #'car requirements)))))
          (should
           (equal (epi-test-package--sort-requirements expected)
                  (epi-test-package--sort-requirements requirements))))))))

(ert-deftest epi-package-json-sentinels-are-stable-and-distinct ()
  (epi-test-with-epi-loaded
    (should (boundp 'epi-json-false))
    (should (boundp 'epi-json-null))
    (should (symbolp epi-json-false))
    (should (symbolp epi-json-null))
    (should-not (memq epi-json-false '(nil t)))
    (should-not (memq epi-json-null '(nil t)))
    (should-not (eq epi-json-false epi-json-null))))

(ert-deftest epi-package-condition-hierarchy-is-exact ()
  (epi-test-with-epi-loaded
    (dolist (entry epi-test-package--condition-chains)
      (pcase-let ((`(,condition . ,chain) entry))
        (should (equal chain (get condition 'error-conditions)))
        (should (eq condition (car chain)))
        (unless (eq condition 'epi-error)
          (should (eq 'epi-error (car (last chain 2)))))))))

(ert-deftest epi-package-condition-children-are-caught-transitively ()
  (epi-test-with-epi-loaded
    (dolist (entry (cdr epi-test-package--condition-chains))
      (let ((condition (car entry))
            caught)
        (condition-case error-data
            (epi--signal condition (list :code 'probe))
          (epi-error (setq caught error-data)))
        (should caught)
        (should (eq condition (car caught)))
        (should (equal '(:code probe) (cadr caught)))))))

(ert-deftest epi-package-errors-have-one-stable-code-plist ()
  (epi-test-with-epi-loaded
    (let* ((input (list :code 'not-idle :session-id "s-1"))
           (condition
            (should-error
             (epi--signal 'epi-invalid-state input)
             :type 'epi-invalid-state))
           (data (cdr condition))
           (plist (car data)))
      (should (= 1 (length data)))
      (should (proper-list-p plist))
      (should (zerop (% (length plist) 2)))
      (should (plist-member plist :code))
      (should (eq 'not-idle (plist-get plist :code)))
      (should (equal "s-1" (plist-get plist :session-id))))))

(ert-deftest epi-package-signal-helper-rejects-malformed-data ()
  (epi-test-with-epi-loaded
    (dolist (data (list "not-a-plist"
                        '(:code valid . improper)
                        '(:code)
                        '(:code valid :dangling)
                        '(:session-id "s-1")
                        '(:code nil)
                        '(:code "not-a-symbol")))
      (let ((condition
             (should-error
              (epi--signal 'epi-invalid-state data))))
        ;; Rejection must happen before signaling the requested condition with
        ;; malformed data; otherwise `should-error' alone would be vacuous.
        (should-not (eq 'epi-invalid-state (car condition)))))
    (let ((condition
           (should-error
            (epi--signal
             'epi-invalid-state
             (list :code "invalid" :secret "do-not-disclose")))))
      (should-not
       (string-match-p "do-not-disclose" (prin1-to-string condition))))))

(ert-deftest epi-package-options-have-frozen-defaults-and-types ()
  (epi-test-with-epi-loaded
    (require 'cus-edit)
    (should (stringp (get 'epi 'group-documentation)))
    (should (= 51 (length epi-test-package--option-specs)))
    (let ((seen nil))
      (dolist (spec epi-test-package--option-specs)
        (pcase-let ((`(,option ,expected ,contract) spec))
          (should-not (memq option seen))
          (push option seen)
          (should (custom-variable-p option))
          (should (equal (epi-test-package--expected-default expected)
                         (default-value option)))
          (let ((type (get option 'custom-type)))
            (should type)
            (epi-test-package--assert-custom-contract type contract)))))))

(ert-deftest epi-package-event-has-private-read-only-raw-slots ()
  (epi-test-with-epi-loaded
    (let* ((payload '(("value" . ["one" "two"])))
           (event (epi-test-package--make-event :payload payload))
           (slot-names
            '(kind durability session-id generation operation-id turn-id
              attempt-id call-id record-id sequence live-sequence payload))
           (slot-info (cl-struct-slot-info 'epi-event))
           (slots
            `((kind epi--event-raw-kind message)
              (durability epi--event-raw-durability committed)
              (session-id epi--event-raw-session-id "session")
              (generation epi--event-raw-generation "generation")
              (operation-id epi--event-raw-operation-id "operation")
              (turn-id epi--event-raw-turn-id "turn")
              (attempt-id epi--event-raw-attempt-id "attempt")
              (call-id epi--event-raw-call-id "call")
              (record-id epi--event-raw-record-id "record")
              (sequence epi--event-raw-sequence 1)
              (live-sequence epi--event-raw-live-sequence nil)
              (payload epi--event-raw-payload ,payload))))
      (should (epi-event-p event))
      (should-not (fboundp 'make-epi-event))
      (should-not (fboundp 'copy-epi-event))
      (should-not (fboundp 'epi-event-copy))
      (should
       (equal slot-names
              (delq 'cl-tag-slot (mapcar #'car slot-info))))
      (dolist (slot slot-names)
        (let ((description (assq slot slot-info)))
          (should description)
          (should (plist-get (cddr description) :read-only))))
      (dolist (slot slots)
        (pcase-let ((`(,_ ,accessor ,expected) slot))
          (should (fboundp accessor))
          (should (equal expected (funcall accessor event)))
          (should-error
           (eval `(setf (,accessor ',event) :mutated) t)))))))

(ert-deftest epi-package-event-public-accessor-inventory-is-complete ()
  (epi-test-with-epi-loaded
    (let ((event (epi-test-package--make-event)))
      (dolist (entry
               '((epi-event-kind message)
                 (epi-event-durability committed)
                 (epi-event-session-id "session")
                 (epi-event-generation "generation")
                 (epi-event-operation-id "operation")
                 (epi-event-turn-id "turn")
                 (epi-event-attempt-id "attempt")
                 (epi-event-call-id "call")
                 (epi-event-record-id "record")
                 (epi-event-sequence 1)
                 (epi-event-live-sequence nil)
                 (epi-event-payload (("value" . "payload")))))
        (should (fboundp (car entry)))
        (should (equal (cadr entry) (funcall (car entry) event)))))))

(ert-deftest epi-package-event-allows-nil-ids-and-immutable-atoms ()
  (epi-test-with-epi-loaded
    (dolist (payload (list -9007199254740991 0 9007199254740991
                           1.25 t epi-json-false epi-json-null))
      (let ((event
             (epi-test-package--make-event
              :kind 'diagnostic
              :durability 'volatile
              :session-id nil
              :generation nil
              :operation-id nil
              :turn-id nil
              :attempt-id nil
              :call-id nil
              :record-id nil
              :sequence nil
              :live-sequence 1
              :payload payload)))
        (dolist (accessor
                 '(epi-event-session-id epi-event-generation
                   epi-event-operation-id epi-event-turn-id
                   epi-event-attempt-id epi-event-call-id
                   epi-event-record-id epi-event-sequence))
          (should-not (funcall accessor event)))
        (should (= 1 (epi-event-live-sequence event)))
        (should (equal payload (epi-event-payload event)))))))

(ert-deftest epi-package-event-kinds-have-one-durability ()
  (epi-test-with-epi-loaded
    (dolist (kind epi-test-package--committed-event-kinds)
      (let ((event (epi-test-package--make-event
                    :kind kind :durability 'committed
                    :sequence 1 :live-sequence nil)))
        (should (eq kind (epi-event-kind event)))
        (should (eq 'committed (epi-event-durability event)))
        (should (= 1 (epi-event-sequence event)))
        (should-not (epi-event-live-sequence event))))
    (dolist (kind epi-test-package--volatile-event-kinds)
      (let ((event (epi-test-package--make-event
                    :kind kind :durability 'volatile
                    :sequence nil :live-sequence 1)))
        (should (eq kind (epi-event-kind event)))
        (should (eq 'volatile (epi-event-durability event)))
        (should-not (epi-event-sequence event))
        (should (= 1 (epi-event-live-sequence event)))))))

(ert-deftest epi-package-event-constructor-rejects-kind-durability-mismatch ()
  (epi-test-with-epi-loaded
    (dolist (arguments
             '((:kind message :durability volatile
                :sequence nil :live-sequence 1)
               (:kind text-delta :durability committed
                :sequence 1 :live-sequence nil)
               (:kind unknown-kind :durability committed
                :sequence 1 :live-sequence nil)
               (:kind unknown-kind :durability volatile
                :sequence nil :live-sequence 1)
               (:kind message :durability unknown-durability
                :sequence 1 :live-sequence nil)))
      (should-error (apply #'epi-test-package--make-event arguments)))))

(ert-deftest epi-package-event-constructor-enforces-positive-inverse-sequences ()
  (epi-test-with-epi-loaded
    (dolist (arguments
             '((:kind message :durability committed
                :sequence nil :live-sequence nil)
               (:kind message :durability committed
                :sequence 0 :live-sequence nil)
               (:kind message :durability committed
                :sequence -1 :live-sequence nil)
               (:kind message :durability committed
                :sequence 1.0 :live-sequence nil)
               (:kind message :durability committed
                :sequence 1 :live-sequence 1)
               (:kind diagnostic :durability volatile
                :sequence nil :live-sequence nil)
               (:kind diagnostic :durability volatile
                :sequence nil :live-sequence 0)
               (:kind diagnostic :durability volatile
                :sequence nil :live-sequence -1)
               (:kind diagnostic :durability volatile
                :sequence nil :live-sequence 1.0)
               (:kind diagnostic :durability volatile
                :sequence 1 :live-sequence 1)))
      (should-error (apply #'epi-test-package--make-event arguments)))))

(ert-deftest epi-package-event-construction-copies-all-mutable-inputs ()
  (epi-test-with-epi-loaded
    (let* ((session-id (copy-sequence "session"))
           (generation (copy-sequence "generation"))
           (operation-id (copy-sequence "operation"))
           (turn-id (copy-sequence "turn"))
           (attempt-id (copy-sequence "attempt"))
           (call-id (copy-sequence "call"))
           (record-id (copy-sequence "record"))
           (root-key (copy-sequence "root"))
           (nested-key (copy-sequence "nested"))
           (cdr-string (copy-sequence "cdr-value"))
           (vector-string (copy-sequence "vector-value"))
           (nested-pair (cons nested-key cdr-string))
           (nested-object (list nested-pair))
           (inner-vector (vector vector-string))
           (outer-vector (vector nested-object inner-vector))
           (payload-entry (cons root-key outer-vector))
           (payload (list payload-entry))
           (event
            (epi-test-package--make-event
             :session-id session-id
             :generation generation
             :operation-id operation-id
             :turn-id turn-id
             :attempt-id attempt-id
             :call-id call-id
             :record-id record-id
             :payload payload)))
      (dolist (entry
               `((epi--event-raw-session-id ,session-id)
                 (epi--event-raw-generation ,generation)
                 (epi--event-raw-operation-id ,operation-id)
                 (epi--event-raw-turn-id ,turn-id)
                 (epi--event-raw-attempt-id ,attempt-id)
                 (epi--event-raw-call-id ,call-id)
                 (epi--event-raw-record-id ,record-id)))
        (should-not (eq (funcall (car entry) event) (cadr entry))))
      (should-not (eq payload (epi--event-raw-payload event)))
      (should-not (eq payload-entry
                      (car (epi--event-raw-payload event))))
      (let* ((raw-entry (car (epi--event-raw-payload event)))
             (raw-outer-vector (cdr raw-entry))
             (raw-nested-object (aref raw-outer-vector 0))
             (raw-nested-pair (car raw-nested-object))
             (raw-inner-vector (aref raw-outer-vector 1)))
        (should-not (eq root-key (car raw-entry)))
        (should-not (eq outer-vector raw-outer-vector))
        (should-not (eq nested-object raw-nested-object))
        (should-not (eq nested-pair raw-nested-pair))
        (should-not (eq nested-key (car raw-nested-pair)))
        (should-not (eq cdr-string (cdr raw-nested-pair)))
        (should-not (eq inner-vector raw-inner-vector))
        (should-not (eq vector-string (aref raw-inner-vector 0))))
      (aset session-id 0 ?X)
      (aset generation 0 ?X)
      (aset operation-id 0 ?X)
      (aset turn-id 0 ?X)
      (aset attempt-id 0 ?X)
      (aset call-id 0 ?X)
      (aset record-id 0 ?X)
      (aset root-key 0 ?X)
      (aset nested-key 0 ?X)
      (aset cdr-string 0 ?X)
      (aset vector-string 0 ?X)
      (setcar nested-pair "changed")
      (setcdr nested-pair "changed")
      (setcar nested-object "changed")
      (aset inner-vector 0 "changed")
      (aset outer-vector 0 "changed")
      (setcar payload-entry "changed")
      (setcdr payload-entry nil)
      (setcar payload "changed")
      (should (equal "session" (epi-event-session-id event)))
      (should (equal "generation" (epi-event-generation event)))
      (should (equal "operation" (epi-event-operation-id event)))
      (should (equal "turn" (epi-event-turn-id event)))
      (should (equal "attempt" (epi-event-attempt-id event)))
      (should (equal "call" (epi-event-call-id event)))
      (should (equal "record" (epi-event-record-id event)))
      (should (equal '(("root" . [(("nested" . "cdr-value"))
                                  ["vector-value"]]))
                     (epi-event-payload event))))))

(ert-deftest epi-package-event-accessors-copy-on-every-read ()
  (epi-test-with-epi-loaded
    (let ((event
           (epi-test-package--make-event
            :payload '(("root" . [(("nested" . "cdr-value"))
                                  ["vector-value"]])
                       ("other" . "two")))))
      (dolist (entry
               '((epi-event-session-id "session")
                 (epi-event-generation "generation")
                 (epi-event-operation-id "operation")
                 (epi-event-turn-id "turn")
                 (epi-event-attempt-id "attempt")
                 (epi-event-call-id "call")
                 (epi-event-record-id "record")))
        (let ((first (funcall (car entry) event))
              (second (funcall (car entry) event)))
          (should-not (eq first second))
          (aset first 0 ?X)
          (should (equal (cadr entry) (funcall (car entry) event)))))
      (let ((first (epi-event-payload event))
            (second (epi-event-payload event)))
        (should-not (eq first second))
        (should-not (eq (car first) (car second)))
        (should-not (eq (caar first) (caar second)))
        (should-not (eq (cdar first) (cdar second)))
        (let* ((first-outer (cdar first))
               (second-outer (cdar second))
               (first-object (aref first-outer 0))
               (second-object (aref second-outer 0))
               (first-pair (car first-object))
               (second-pair (car second-object))
               (first-inner (aref first-outer 1))
               (second-inner (aref second-outer 1)))
          (should-not (eq first-object second-object))
          (should-not (eq first-pair second-pair))
          (should-not (eq (car first-pair) (car second-pair)))
          (should-not (eq (cdr first-pair) (cdr second-pair)))
          (should-not (eq first-inner second-inner))
          (should-not (eq (aref first-inner 0) (aref second-inner 0)))
          (aset (caar first) 0 ?X)
          (aset (car first-pair) 0 ?X)
          (aset (cdr first-pair) 0 ?X)
          (aset (aref first-inner 0) 0 ?X)
          (setcar first-pair "changed")
          (setcdr first-pair "changed")
          (setcar first-object "changed")
          (aset first-inner 0 "changed")
          (aset first-outer 0 "changed")
          (setcdr (car first) nil))
        (setcdr first nil)
        (should (equal '(("root" . [(("nested" . "cdr-value"))
                                    ["vector-value"]])
                         ("other" . "two"))
                       (epi-event-payload event)))))))

(ert-deftest epi-package-empty-sequences-have-no-mutable-alias-surface ()
  (epi-test-with-epi-loaded
    (let* ((empty-string (substring-no-properties ""))
           (empty-vector (make-vector 0 nil))
           (event
            (epi-test-package--make-event
             :session-id empty-string
             :payload (list (cons empty-string empty-vector))))
           (raw-payload (epi--event-raw-payload event))
           (public-payload (epi-event-payload event)))
      ;; Emacs may canonicalize zero-length strings and vectors.  Identity is
      ;; irrelevant because neither kind contains an addressable element.
      (dolist (sequence
               (list empty-string
                     empty-vector
                     (epi--event-raw-session-id event)
                     (caar raw-payload)
                     (cdar raw-payload)
                     (epi-event-session-id event)
                     (caar public-payload)
                     (cdar public-payload)))
        (should (zerop (length sequence)))
        (should-error (aset sequence 0 ?X) :type 'args-out-of-range))
      (should (equal "" (epi-event-session-id event)))
      (should (equal '(("" . [])) (epi-event-payload event))))))

(ert-deftest epi-package-event-rejects-noncanonical-mutable-payloads ()
  (epi-test-with-epi-loaded
    (let ((hash-table (make-hash-table))
          (marker (make-marker)))
      (dolist (payload
               (list hash-table
                     marker
                     (make-char-table nil)
                     (list (cons "nested" (vector hash-table)))
                     (list
                      (cons "outer"
                            (vector
                             (list (cons "nested" marker)))))))
        (should-error (epi-test-package--make-event :payload payload))))
    (let ((buffer (generate-new-buffer " *epi-mutable-payload*")))
      (unwind-protect
          (should-error (epi-test-package--make-event :payload buffer))
        (kill-buffer buffer)))
    (let ((cyclic-cons (cons "cycle" nil)))
      (setcdr cyclic-cons cyclic-cons)
      (should-error
       (epi-test-package--make-event :payload cyclic-cons)))
    (let ((cyclic-vector (vector nil)))
      (aset cyclic-vector 0 cyclic-vector)
      (should-error
       (epi-test-package--make-event :payload cyclic-vector)))))

(ert-deftest epi-package-event-rejects-noncanonical-shapes-and-strings ()
  (epi-test-with-epi-loaded
    (dolist (payload
             (list '(1 2)
                   '((t . 1))
                   '(("duplicate" . 1) ("duplicate" . 2))
                   (cons '("key" . 1) 'improper-tail)
                   '("key" . 1)
                   (unibyte-string #x80)
                   (string #xd800)
                   (string #x110000)))
      (should-error
       (epi-test-package--make-event :payload payload)
       :type 'epi-error))
    (let* ((payload '(("κόσμος" . ["𝄞" nil])))
           (event (epi-test-package--make-event :payload payload)))
      (should (equal payload (epi-event-payload event))))))

(ert-deftest epi-package-event-strips-string-properties-and-aliases ()
  (epi-test-with-epi-loaded
    (let* ((property-value (vector "secret"))
           (session-id (propertize "session" 'epi-secret property-value))
           (payload-key (propertize "key" 'epi-secret property-value))
           (payload-value (propertize "value" 'epi-secret property-value))
           (event
            (epi-test-package--make-event
             :session-id session-id
             :payload (list (cons payload-key payload-value))))
           (raw-payload (epi--event-raw-payload event)))
      (should-not (text-properties-at 0 (epi--event-raw-session-id event)))
      (should-not (text-properties-at 0 (caar raw-payload)))
      (should-not (text-properties-at 0 (cdar raw-payload)))
      (aset property-value 0 "mutated")
      (should (equal "session" (epi-event-session-id event)))
      (should-not (text-properties-at 0 (epi-event-session-id event)))
      (let ((payload (epi-event-payload event)))
        (should (equal '(("key" . "value")) payload))
        (should-not (text-properties-at 0 (caar payload)))
        (should-not (text-properties-at 0 (cdar payload)))))))

(ert-deftest epi-package-validation-errors-are-structured-and-redacted ()
  (epi-test-with-epi-loaded
    (let ((payload (make-hash-table :test #'equal)))
      (puthash "secret-payload" t payload)
      (let* ((condition
              (should-error
               (epi-test-package--make-event :payload payload)
               :type 'epi-error))
             (plist (cadr condition)))
        (should (= 1 (length (cdr condition))))
        (should (eq 'invalid-event (plist-get plist :code)))
        (should (eq 'payload (plist-get plist :field)))
        (should (eq 'unsupported-type (plist-get plist :reason)))
        (should-not
         (string-match-p "secret-payload" (prin1-to-string condition)))))
    (let ((epi--deadline-clock-function (lambda () "secret-clock"))
          (epi--deadline-high-water nil))
      (let* ((condition (should-error (epi--deadline-time) :type 'epi-error))
             (plist (cadr condition)))
        (should (= 1 (length (cdr condition))))
        (should (eq 'invalid-clock-sample (plist-get plist :code)))
        (should (eq 'deadline-clock (plist-get plist :field)))
        (should-not
         (string-match-p "secret-clock" (prin1-to-string condition)))))))

(ert-deftest epi-package-validation-redacts-attacker-chosen-record-types ()
  (epi-test-with-epi-loaded
    (let* ((secret 'epi-test-do-not-disclose-record-type)
           (condition
            (should-error
             (epi-test-package--make-event :payload (record secret))
             :type 'epi-error))
           (plist (cadr condition))
           (secret-name (symbol-name secret)))
      (should (= 1 (length (cdr condition))))
      (should (eq 'invalid-event (plist-get plist :code)))
      (should (eq 'payload (plist-get plist :field)))
      (should (eq 'unsupported-type (plist-get plist :reason)))
      (should-not (string-match-p secret-name (prin1-to-string (cdr condition))))
      (should-not (string-match-p secret-name (error-message-string condition))))))

(ert-deftest epi-package-id-wall-and-deadline-sources-are-independent ()
  (epi-test-with-epi-loaded
    (let* ((wall-time (encode-time 6 5 4 3 2 2026 t))
           (epi-test--id-values (list "id-1" "id-2"))
           (epi-test--wall-time-values (list wall-time wall-time))
           (epi-test--deadline-values nil)
           (epi--id-function #'epi-test-next-id)
           (epi--wall-clock-function #'epi-test-wall-time)
           (epi--deadline-clock-function #'epi-test-deadline-time)
           (epi--deadline-high-water nil))
      (should (equal "id-1" (epi--new-id)))
      (should (equal "id-2" (epi--new-id)))
      (should (equal wall-time (epi--wall-time)))
      (let ((timestamp (epi--format-timestamp)))
        (should (string-match-p
                 (rx string-start
                     (= 4 digit) "-" (= 2 digit) "-" (= 2 digit) "T"
                     (= 2 digit) ":" (= 2 digit) ":" (= 2 digit)
                     (optional "." (+ digit))
                     (or "Z"
                         (seq (or "+" "-")
                              (= 2 digit) ":" (= 2 digit)))
                     string-end)
                 timestamp))
        (should (time-equal-p wall-time (date-to-time timestamp)))))
    (let ((epi-test--wall-time-values nil)
          (epi-test--deadline-values (list 17.25))
          (epi--wall-clock-function #'epi-test-wall-time)
          (epi--deadline-clock-function #'epi-test-deadline-time)
          (epi--deadline-high-water nil))
      (should (= 17.25 (epi--deadline-time))))))

(ert-deftest epi-package-deadline-clock-high-water-is-process-local ()
  (epi-test-with-epi-loaded
    (let ((epi-test--deadline-values (list 10.0 8.0 12.5))
          (epi--deadline-clock-function #'epi-test-deadline-time)
          (epi--deadline-high-water nil))
      (should (= 10.0 (epi--deadline-time)))
      (should (= 10.0 (epi--deadline-time)))
      (should (= 12.5 (epi--deadline-time)))
      (should (= 12.5 epi--deadline-high-water)))))

(ert-deftest epi-package-nonfinite-time-values-are-rejected ()
  (epi-test-with-epi-loaded
    (let ((infinity (/ 1.0 0.0))
          (nan (/ 0.0 0.0))
          (type (get 'epi-gptel-no-progress-timeout 'custom-type)))
      (should-not (epi-test-package--custom-type-matches-p type infinity))
      (should-not (epi-test-package--custom-type-matches-p type nan))
      (dolist (sample (list infinity nan))
        (let ((epi--deadline-clock-function
               (apply-partially #'identity sample))
              (epi--deadline-high-water nil))
          (let* ((condition
                  (should-error (epi--deadline-time) :type 'epi-error))
                 (plist (cadr condition)))
            (should (eq 'invalid-clock-sample (plist-get plist :code)))))))))

(ert-deftest epi-package-default-id-source-produces-uuid-v4 ()
  (epi-test-with-epi-loaded
    (let ((pattern
           (rx string-start
               (= 8 (in "0-9a-fA-F")) "-"
               (= 4 (in "0-9a-fA-F")) "-4"
               (= 3 (in "0-9a-fA-F")) "-"
               (in "89aAbB") (= 3 (in "0-9a-fA-F")) "-"
               (= 12 (in "0-9a-fA-F"))
               string-end))
          (first (epi--new-id))
          (second (epi--new-id)))
      (should (string-match-p pattern first))
      (should (string-match-p pattern second))
      (should-not (equal first second)))))

(ert-deftest epi-package-cooperative-yield-is-injectable ()
  (epi-test-with-epi-loaded
    (let* ((calls 0)
           (epi--yield-function (lambda () (cl-incf calls) 'yielded)))
      (epi--yield)
      (should (= 1 calls)))))

(ert-deftest epi-package-session-p-is-a-default-false-generic ()
  (epi-test-with-epi-loaded
    (should (cl-generic-p 'epi-session-p))
    (dolist (object (list nil t 0 1.5 "session" 'session [] (cons 1 2)))
      (should-not (epi-session-p object)))))

(ert-deftest epi-package-runtime-api-is-lazily-autoloaded ()
  (epi-test-with-epi-loaded
    (should-not (featurep 'epi-runtime))
    (dolist (symbol epi-test-package--runtime-autoloads)
      (epi-test-package--assert-autoload symbol "epi-runtime" nil))
    (should-not (featurep 'epi-runtime))))

(ert-deftest epi-package-ui-api-and-modes-are-lazily-autoloaded ()
  (epi-test-with-epi-loaded
    (should-not (featurep 'epi-ui))
    (dolist (symbol epi-test-package--ui-autoloads)
      (epi-test-package--assert-autoload symbol "epi-ui" nil))
    (dolist (symbol epi-test-package--ui-command-autoloads)
      (epi-test-package--assert-autoload symbol "epi-ui" t))
    (should-not (featurep 'epi-ui))))

(provide 'epi-package-test)
;;; epi-package-test.el ends here
