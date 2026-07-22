;;; epi-preflight-test.el --- Epi bootstrap preflight contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley
;; Keywords: tools

;;; Commentary:

;; These tests intentionally precede the preflight implementation.  The
;; validator entry point is `epi-test-preflight-validate'.  With no keyword
;; arguments it reads EPI_EMACS, GPTEL_ROOT, PI_ROOT, JCS_ORACLE_ROOT, and
;; EPI_EXTRA_LOAD_PATH.  Tests pass those inputs explicitly and use only these
;; additional, test-only keywords:
;;
;;   :scope                    `all' (the default) or
;;                             `gptel-source-resolution'
;;   :gptel-probe-root         an exact source copy used by the child source
;;                             probe; defaults to :gptel-root
;;   :load-path-prefix         directories placed before the probe root
;;   :native-artifact-overrides
;;                             an alist from library name to an existing .eln
;;                             path, replacing only native-artifact discovery
;;                             in the child probe
;;
;; The override keywords exist only to inject failures without modifying the
;; pinned, read-only upstream checkouts.  Production preflight uses :scope
;; `all' and none of the three artifact overrides.  On success the validator
;; returns a plist of observed values; on mismatch it signals an error whose
;; text includes both "observed:" and "required:".

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'subr-x)
(require 'epi-test-helper)

(declare-function epi-test-preflight-validate "epi-test-helper" (&rest options))

(defconst epi-preflight--gptel-commit
  "8701e2bd80c5d2091ce2decef5d34d6fce4a3ada")

(defconst epi-preflight--gptel-hashes
  '(("gptel.el" .
     "2a1a7aba6bb4d7af7bf302ebed75ad74c598ccb7383fc5f5318b15295c42bbe5")
    ("gptel-request.el" .
     "f4a42353208dc52ac14cd90e77e06d6b656d00c6bc5ee5a72cb9d517e088d66b")
    ("gptel-openai.el" .
     "8467b1693a768230d6fa7f57f636756282c613626b94b0ff05f656b212d69677")))

(defconst epi-preflight--pi-commit
  "dd6bea41efa8caa7a10fe5a6401676dc5699f83f")

(defconst epi-preflight--pi-hashes
  '(("packages/coding-agent/src/core/session-manager.ts" .
     "5ca662efec88c135559630deda469fcf022035ddfb61b4610de8d74cee5c8b39")
    ("packages/coding-agent/src/core/agent-session.ts" .
     "7fe22be86e251af9f820c816f0c847e6db390682e33882f8fce388715fea4dc5")
    ("packages/coding-agent/src/core/resource-loader.ts" .
     "e2b999d280fcf640a995fadca84cfc9ddfd83aef1d3748f29dd71edae0c408a8")
    ("packages/coding-agent/src/core/tools/read.ts" .
     "1acc6fcb88a29317d4f800fa1e9e1ff3d13d32527dd8c6f1cdbeeab5107ae06d")
    ("packages/coding-agent/src/core/tools/edit.ts" .
     "a42f745488ab89553173479986efc222544eeac26e1820692954031c63c27fdd")))

(defconst epi-preflight--jcs-commit
  "19d51d7fe467d4706a3ff08adf8a748f29fc21e0")

(defconst epi-preflight--jcs-hashes
  '(("node-es6/canonicalize.js" .
     "f9f498b55c99eefe348c99018ddcfe08efa6f7ff96b9ba9dce4b7090b33c4438")
    ("node-es6/verify-canonicalization.js" .
     "314898c8f08ed5b14a3f5903b27ec4789ac5dc7fd59a168e72a6d876f192be6f")))

(defconst epi-preflight--jcs-vector-digest
  "823c07e7e1b1bbfc903354435b508026e43d2bf3183450a8773cf6cab7668933")

(defun epi-preflight--required-environment (name)
  "Return environment variable NAME, failing clearly when it is absent."
  (let ((value (getenv name)))
    (unless (and value (not (string-empty-p value)))
      (error "Preflight test requires environment variable %s" name))
    value))

(defun epi-preflight--extra-load-path ()
  "Return the declared EPI_EXTRA_LOAD_PATH as a list of directories."
  (let ((separator (if (characterp path-separator)
                       (char-to-string path-separator)
                     path-separator)))
    (split-string
     (epi-preflight--required-environment "EPI_EXTRA_LOAD_PATH")
     (regexp-quote separator) t)))

(defun epi-preflight--options (&rest overrides)
  "Return explicit validator options, applying keyword OVERRIDES."
  (let ((options
         (list :emacs (epi-preflight--required-environment "EPI_EMACS")
               :gptel-root (epi-preflight--required-environment "GPTEL_ROOT")
               :pi-root (epi-preflight--required-environment "PI_ROOT")
               :jcs-oracle-root
               (epi-preflight--required-environment "JCS_ORACLE_ROOT")
               :extra-load-path (epi-preflight--extra-load-path))))
    (while overrides
      (setq options (plist-put options (pop overrides) (pop overrides))))
    options))

(defun epi-preflight--report-alist-equal (expected observed key)
  "Assert EXPECTED and OBSERVED alists have equal values under KEY."
  (ert-info ((format "Preflight report key %S" key))
    (should observed)
    (dolist (entry expected)
      (should
       (equal (cdr entry)
              (alist-get (car entry) observed nil nil #'string=))))
    (should (= (length expected) (length observed)))))

(defun epi-preflight--version-at-least-p (observed required)
  "Return non-nil when version OBSERVED is at least REQUIRED."
  (and (stringp observed) (version<= required observed)))

(defun epi-preflight--copy-elisp-tree (source destination)
  "Copy every Emacs Lisp file below SOURCE into DESTINATION."
  (make-directory destination t)
  (dolist (file (directory-files-recursively source "\\.el\\'"))
    (let ((target (expand-file-name (file-relative-name file source)
                                    destination)))
      (make-directory (file-name-directory target) t)
      (copy-file file target nil t))))

(defun epi-preflight--copy-relative-files (source destination relative-files)
  "Copy RELATIVE-FILES from SOURCE to the same paths below DESTINATION."
  (dolist (relative relative-files)
    (let ((source-file (expand-file-name relative source))
          (destination-file (expand-file-name relative destination)))
      (make-directory (file-name-directory destination-file) t)
      (copy-file source-file destination-file nil t))))

(defun epi-preflight--jcs-vector-relative-files (source)
  "Return JCS vector paths below SOURCE relative to that directory."
  (append
   (mapcar (lambda (file) (file-relative-name file source))
           (directory-files-recursively
            (expand-file-name "testdata/input" source) "\\.json\\'"))
   (mapcar (lambda (file) (file-relative-name file source))
           (directory-files-recursively
            (expand-file-name "testdata/output" source) "\\.json\\'"))))

(defun epi-preflight--append-tamper (file)
  "Append a harmless deterministic mutation to FILE."
  (with-temp-buffer
    (insert "\n")
    (write-region (point-min) (point-max) file t 'silent)))

(defun epi-preflight--failure-text (&rest options)
  "Run the validator with OPTIONS and return its error text."
  (condition-case condition
      (progn
        (apply #'epi-test-preflight-validate options)
        (ert-fail "Preflight validator unexpectedly accepted bad input"))
    ;; Preserve the deliberate first red: the validator does not exist yet.
    (void-function (signal (car condition) (cdr condition)))
    (error (error-message-string condition))))

(defun epi-preflight--assert-mismatch-shape (text)
  "Assert that mismatch diagnostic TEXT reports observed and required values."
  (should (string-match-p "observed:" text))
  (should (string-match-p "required:" text)))

(defun epi-preflight--normalized-truename (file)
  "Return FILE's exact normalized truename string."
  (file-truename (expand-file-name file)))

(defun epi-preflight--helper-load-history (helper-file)
  "Return the `load-history' entry for HELPER-FILE."
  (cl-find-if
   (lambda (entry)
     (and (stringp (car-safe entry))
          (equal (epi-preflight--normalized-truename (car entry))
                 helper-file)))
   load-history))

(defun epi-preflight--read-top-level-forms (file)
  "Read and return every top-level Lisp form in FILE without evaluating it."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let (forms form)
      (condition-case nil
          (while t
            (setq form (read (current-buffer)))
            (push form forms))
        (end-of-file nil))
      (nreverse forms))))

(defun epi-preflight--test-symbol-p (symbol)
  "Return non-nil when SYMBOL belongs to the test-helper namespace."
  (and (symbolp symbol)
       (string-prefix-p "epi-test-" (symbol-name symbol))))

(defun epi-preflight--symbol-designator (form)
  "Return the symbol designated by FORM, or nil."
  (cond
   ((symbolp form) form)
   ((and (consp form) (eq (car form) 'quote) (symbolp (cadr form)))
    (cadr form))
   ((and (consp form) (symbolp (car form)))
    (car form))))

(defun epi-preflight--top-level-targets (form)
  "Return symbols defined or mutated by top-level FORM.

This deliberately recognizes only definition and mutation forms permitted in
the helper.  Advice and function-cell substitution are reported separately."
  (pcase form
    (`(,(or 'defconst 'defvar 'defcustom 'defun 'defmacro
            'cl-defun 'cl-defmacro 'cl-defstruct 'define-error)
       ,name . ,_)
     (list (epi-preflight--symbol-designator name)))
    (`(provide ,feature)
     (list (epi-preflight--symbol-designator feature)))
    (`(setq . ,bindings)
     (cl-loop for (name _value) on bindings by #'cddr collect name))
    (`(set ,name . ,_)
     (list (epi-preflight--symbol-designator name)))
    (`(set-default ,name . ,_)
     (list (epi-preflight--symbol-designator name)))
    (`(,(or 'advice-add 'advice-remove 'defalias 'fset) ,name . ,_)
     (list (epi-preflight--symbol-designator name)))
    (_ nil)))

(defun epi-preflight--forbidden-top-level-mutation-p (form)
  "Return non-nil when FORM is an uninspectable top-level mutation."
  (eq (car-safe form) 'setf))

(ert-deftest epi-preflight-helper-load-is-gptel-lazy ()
  (dolist (feature '(gptel gptel-request gptel-openai))
    (should-not (featurep feature)))
  ;; Validation must load GPTel only in its clean child process.
  (apply #'epi-test-preflight-validate
         (epi-preflight--options :scope 'gptel-source-resolution))
  (dolist (feature '(gptel gptel-request gptel-openai))
    (should-not (featurep feature))))

(ert-deftest epi-preflight-helper-definitions-use-test-namespace ()
  (let* ((helper-file
          (epi-preflight--normalized-truename
           (locate-library "epi-test-helper")))
         (history (epi-preflight--helper-load-history helper-file))
         history-offenders form-offenders mutation-offenders)
    (should history)
    (dolist (entry (cdr history))
      (when (and (consp entry)
                 (memq (car entry)
                       '(defun defvar defconst defcustom define-type
                         define-error provide))
                 (symbolp (cdr entry))
                 (not (epi-preflight--test-symbol-p (cdr entry))))
        (push (cdr entry) history-offenders)))
    (dolist (form (epi-preflight--read-top-level-forms helper-file))
      (when (epi-preflight--forbidden-top-level-mutation-p form)
        (push form mutation-offenders))
      (when (and (eq (car-safe form) 'require)
                 (memq (epi-preflight--symbol-designator (cadr form))
                       '(gptel gptel-request gptel-openai)))
        (push form mutation-offenders))
      (dolist (target (epi-preflight--top-level-targets form))
        (unless (epi-preflight--test-symbol-p target)
          (push (cons target form) form-offenders))))
    (should (equal nil history-offenders))
    (should (equal nil mutation-offenders))
    (should (equal nil form-offenders))))

(ert-deftest epi-preflight-validates-exact-frozen-baselines ()
  (let* ((options (epi-preflight--options))
         (report (apply #'epi-test-preflight-validate options)))
    (should (epi-preflight--version-at-least-p
             (plist-get report :emacs-version) "30.1"))
    (should (epi-preflight--version-at-least-p
             (plist-get report :org-version) "9.7"))
    (should (equal "0.9.9.5" (plist-get report :gptel-version)))
    (should (epi-preflight--version-at-least-p
             (plist-get report :transient-version) "0.7.8"))
    (should (epi-preflight--version-at-least-p
             (plist-get report :compat-version) "30.1.0.0"))
    (should (equal epi-preflight--gptel-commit
                   (plist-get report :gptel-commit)))
    (should (equal epi-preflight--pi-commit
                   (plist-get report :pi-commit)))
    (should (equal epi-preflight--jcs-commit
                   (plist-get report :jcs-commit)))
    (epi-preflight--report-alist-equal
     epi-preflight--gptel-hashes
     (plist-get report :gptel-source-hashes) :gptel-source-hashes)
    (epi-preflight--report-alist-equal
     epi-preflight--pi-hashes
     (plist-get report :pi-source-hashes) :pi-source-hashes)
    (epi-preflight--report-alist-equal
     epi-preflight--jcs-hashes
     (plist-get report :jcs-source-hashes) :jcs-source-hashes)
    (should (equal epi-preflight--jcs-vector-digest
                   (plist-get report :jcs-vector-digest)))
    (should (eq t (plist-get report :source-only)))
    (should (eq t (plist-get report :native-jit-disabled)))
    (should (eq t (plist-get report :child-probe)))
    (dolist (library '("gptel" "gptel-request" "gptel-openai"))
      (let ((observed (alist-get library
                                 (plist-get report :gptel-library-files)
                                 nil nil #'string=))
            (required (expand-file-name (concat library ".el")
                                        (plist-get options :gptel-root))))
        (should observed)
        (should
         (equal (epi-preflight--normalized-truename observed)
                (epi-preflight--normalized-truename required)))))
    (dolist (entry '((gptel . "gptel.el")
                     (gptel-request . "gptel-request.el")
                     (gptel-make-openai . "gptel-openai.el")))
      (let ((observed (alist-get (car entry)
                                 (plist-get report :gptel-symbol-files))))
        (should observed)
        (should
         (equal
          (epi-preflight--normalized-truename observed)
          (epi-preflight--normalized-truename
           (expand-file-name (cdr entry)
                             (plist-get options :gptel-root)))))))))

(ert-deftest epi-preflight-accepts-exact-source-only-resolution ()
  (let ((report
         (apply #'epi-test-preflight-validate
                (epi-preflight--options
                 :scope 'gptel-source-resolution))))
    (should (eq t (plist-get report :source-only)))
    (should (eq t (plist-get report :native-jit-disabled)))
    (should (eq t (plist-get report :child-probe)))))

(ert-deftest epi-preflight-rejects-stale-sibling-elc ()
  (dolist (library '("gptel" "gptel-request" "gptel-openai"))
    (ert-info ((format "Injected sibling byte-code for %s" library))
      (epi-test-with-temporary-root (temporary-root)
        (let* ((source (epi-preflight--required-environment "GPTEL_ROOT"))
               (probe-root (expand-file-name "gptel" temporary-root))
               (artifact (expand-file-name (concat library ".elc")
                                           probe-root)))
          (epi-preflight--copy-elisp-tree source probe-root)
          (with-temp-file artifact
            (insert "deliberately stale byte code\n"))
          (let ((text
                 (epi-preflight--failure-text
                  :emacs (epi-preflight--required-environment "EPI_EMACS")
                  :gptel-root source
                  :gptel-probe-root probe-root
                  :extra-load-path (epi-preflight--extra-load-path)
                  :scope 'gptel-source-resolution)))
            (epi-preflight--assert-mismatch-shape text)
            (should (string-match-p "sibling.*\\.elc" text))
            (should
             (string-match-p
              (regexp-quote (epi-preflight--normalized-truename artifact))
              text))))))))

(ert-deftest epi-preflight-rejects-earlier-shadow-source ()
  (dolist (library '("gptel" "gptel-request" "gptel-openai"))
    (ert-info ((format "Earlier load-path shadow for %s" library))
      (epi-test-with-temporary-root (temporary-root)
        (let* ((source (epi-preflight--required-environment "GPTEL_ROOT"))
               (shadow-root (expand-file-name "shadow" temporary-root))
               (shadow (expand-file-name (concat library ".el") shadow-root))
               (required (expand-file-name (concat library ".el") source)))
          (make-directory shadow-root t)
          (copy-file required shadow)
          (let ((text
                 (epi-preflight--failure-text
                  :emacs (epi-preflight--required-environment "EPI_EMACS")
                  :gptel-root source
                  :extra-load-path (epi-preflight--extra-load-path)
                  :load-path-prefix (list shadow-root)
                  :scope 'gptel-source-resolution)))
            (epi-preflight--assert-mismatch-shape text)
            (should (string-match-p "shadow\\|resolution" text))
            (should
             (string-match-p
              (regexp-quote (epi-preflight--normalized-truename shadow)) text))
            (should
             (string-match-p
              (regexp-quote (epi-preflight--normalized-truename required))
              text))))))))

(defun epi-preflight--write-executing-shadow (directory feature sentinel)
  "Write a FEATURE shadow below DIRECTORY that records SENTINEL then fails."
  (make-directory directory t)
  (with-temp-file (expand-file-name (format "%s.el" feature) directory)
    (insert "(with-temp-file " (prin1-to-string sentinel)
            " (insert \"unverified dependency executed\"))\n"
            "(error \"unverified dependency shadow executed\")\n")))

(defun epi-preflight--assert-gptel-dependency-shadows-inert (location)
  "Assert GPTel dependency shadows at LOCATION are never evaluated."
  (dolist (feature
           (append '(url mailcap text-property-search)
                   (and (eq location 'extra-load-path)
                        '(cond-let eieio edmacro format-spec llama
                                   pcase pp seq))))
    (ert-info ((format "%s shadow in %s" feature location))
      (epi-test-with-temporary-root (temporary-root)
        (let* ((source (epi-preflight--required-environment "GPTEL_ROOT"))
               (probe-root (expand-file-name "gptel" temporary-root))
               (shadow-root
                (if (eq location 'probe-root)
                    probe-root
                  (expand-file-name "earlier-shadow" temporary-root)))
               (sentinel
                (expand-file-name
                 (format "%s-%s-executed" location feature)
                 temporary-root)))
          (epi-preflight--copy-elisp-tree source probe-root)
          (epi-preflight--write-executing-shadow
           shadow-root feature sentinel)
          (apply
           #'epi-test-preflight-validate
           (epi-preflight--options
            :gptel-root source
            :gptel-probe-root probe-root
            :extra-load-path
            (if (eq location 'extra-load-path)
                (cons shadow-root (epi-preflight--extra-load-path))
              (epi-preflight--extra-load-path))
            :load-path-prefix
            (and (eq location 'load-path-prefix) (list shadow-root))
            :scope 'gptel-source-resolution))
          (should-not (file-exists-p sentinel)))))))

(ert-deftest epi-preflight-gptel-probe-root-dependency-shadows-are-inert ()
  (epi-preflight--assert-gptel-dependency-shadows-inert 'probe-root))

(ert-deftest epi-preflight-gptel-load-path-prefix-dependency-shadows-are-inert ()
  (epi-preflight--assert-gptel-dependency-shadows-inert 'load-path-prefix))

(ert-deftest epi-preflight-gptel-extra-load-path-builtin-shadows-are-inert ()
  (epi-preflight--assert-gptel-dependency-shadows-inert 'extra-load-path))

(ert-deftest epi-preflight-dependency-versions-ignore-probe-shadows ()
  (epi-test-with-temporary-root (temporary-root)
    (let* ((source (epi-preflight--required-environment "GPTEL_ROOT"))
           (probe-root (expand-file-name "gptel" temporary-root))
           (options (epi-preflight--options
                     :scope 'gptel-source-resolution))
           (trusted-report (apply #'epi-test-preflight-validate options)))
      (epi-preflight--copy-elisp-tree source probe-root)
      (dolist (library '("compat" "transient"))
        (with-temp-file (expand-file-name (concat library ".el") probe-root)
          (insert ";; Package-Version: 999.0\n")))
      (let ((shadowed-report
             (apply #'epi-test-preflight-validate
                    (plist-put (copy-sequence options)
                               :gptel-probe-root probe-root))))
        (dolist (key '(:compat-version :transient-version))
          (should (equal (plist-get trusted-report key)
                         (plist-get shadowed-report key)))
          (should-not (equal "999.0" (plist-get shadowed-report key))))))))

(ert-deftest epi-preflight-rejects-native-artifact ()
  (dolist (library '("gptel" "gptel-request" "gptel-openai"))
    (ert-info ((format "Injected native artifact for %s" library))
      (epi-test-with-temporary-root (temporary-root)
        (let* ((source (epi-preflight--required-environment "GPTEL_ROOT"))
               (artifact
                (expand-file-name (concat library "-injected.eln")
                                  temporary-root)))
          (with-temp-file artifact
            (insert "deliberately injected native artifact\n"))
          (let ((text
                 (epi-preflight--failure-text
                  :emacs (epi-preflight--required-environment "EPI_EMACS")
                  :gptel-root source
                  :extra-load-path (epi-preflight--extra-load-path)
                  :native-artifact-overrides (list (cons library artifact))
                  :scope 'gptel-source-resolution)))
            (epi-preflight--assert-mismatch-shape text)
            (should (string-match-p "native.*artifact\\|\\.eln" text))
            (should
             (string-match-p
              (regexp-quote (epi-preflight--normalized-truename artifact))
              text))))))))

(ert-deftest epi-preflight-rejects-tampered-gptel-root ()
  (epi-test-with-temporary-root (temporary-root)
    (let* ((source (epi-preflight--required-environment "GPTEL_ROOT"))
           (probe-root (expand-file-name "gptel" temporary-root))
           (tampered (expand-file-name "gptel.el" probe-root))
           (execution-sentinel
            (expand-file-name "tampered-gptel-executed" temporary-root)))
      (epi-preflight--copy-elisp-tree source probe-root)
      (with-temp-buffer
        (insert "\n(with-temp-file " (prin1-to-string execution-sentinel)
                " (insert \"unsafe\"))\n")
        (write-region (point-min) (point-max) tampered t 'silent))
      (let ((text
             (epi-preflight--failure-text
              :emacs (epi-preflight--required-environment "EPI_EMACS")
              :gptel-root probe-root
              :pi-root (epi-preflight--required-environment "PI_ROOT")
              :jcs-oracle-root
              (epi-preflight--required-environment "JCS_ORACLE_ROOT")
              :extra-load-path (epi-preflight--extra-load-path)
              :scope 'all)))
        (epi-preflight--assert-mismatch-shape text)
        (should (string-match-p "gptel\\.el" text))
        (should (string-match-p (regexp-quote epi-preflight--gptel-commit)
                                text))
        (should (string-match-p
                 (regexp-quote
                  (alist-get "gptel.el" epi-preflight--gptel-hashes
                             nil nil #'string=))
                 text))
        (should-not (file-exists-p execution-sentinel))))))

(ert-deftest epi-preflight-rejects-wrong-tampered-pi-root ()
  (epi-test-with-temporary-root (temporary-root)
    (let* ((source (epi-preflight--required-environment "PI_ROOT"))
           (relative-files (mapcar #'car epi-preflight--pi-hashes))
           (tampered-relative (car relative-files))
           (tampered (expand-file-name tampered-relative temporary-root)))
      (epi-preflight--copy-relative-files source temporary-root relative-files)
      (epi-preflight--append-tamper tampered)
      (let ((text
             (epi-preflight--failure-text
              :emacs (epi-preflight--required-environment "EPI_EMACS")
              :gptel-root (epi-preflight--required-environment "GPTEL_ROOT")
              :pi-root temporary-root
              :jcs-oracle-root
              (epi-preflight--required-environment "JCS_ORACLE_ROOT")
              :extra-load-path (epi-preflight--extra-load-path))))
        (epi-preflight--assert-mismatch-shape text)
        (should (string-match-p "Pi\\|pi" text))
        (should (string-match-p (regexp-quote tampered-relative) text))
        (should (string-match-p (regexp-quote epi-preflight--pi-commit) text))
        (should (string-match-p
                 (regexp-quote
                  (alist-get tampered-relative epi-preflight--pi-hashes
                             nil nil #'string=))
                 text))))))

(ert-deftest epi-preflight-rejects-wrong-tampered-jcs-root ()
  (epi-test-with-temporary-root (temporary-root)
    (let* ((source
            (epi-preflight--required-environment "JCS_ORACLE_ROOT"))
           (relative-files
            (append
             (mapcar #'car epi-preflight--jcs-hashes)
             (epi-preflight--jcs-vector-relative-files source)))
           (tampered-relative (car relative-files))
           (tampered (expand-file-name tampered-relative temporary-root)))
      (epi-preflight--copy-relative-files source temporary-root relative-files)
      (epi-preflight--append-tamper tampered)
      (let ((text
             (epi-preflight--failure-text
              :emacs (epi-preflight--required-environment "EPI_EMACS")
              :gptel-root (epi-preflight--required-environment "GPTEL_ROOT")
              :pi-root (epi-preflight--required-environment "PI_ROOT")
              :jcs-oracle-root temporary-root
              :extra-load-path (epi-preflight--extra-load-path))))
        (epi-preflight--assert-mismatch-shape text)
        (should (string-match-p "JCS\\|jcs\\|canonicalization" text))
        (should (string-match-p (regexp-quote tampered-relative) text))
        (should (string-match-p (regexp-quote epi-preflight--jcs-commit) text))
        (should (string-match-p
                 (regexp-quote
                 (alist-get tampered-relative epi-preflight--jcs-hashes
                             nil nil #'string=))
                 text))))))

(ert-deftest epi-preflight-rejects-tampered-jcs-vector ()
  (epi-test-with-temporary-root (temporary-root)
    (let* ((source
            (epi-preflight--required-environment "JCS_ORACLE_ROOT"))
           (vectors (epi-preflight--jcs-vector-relative-files source))
           (relative-files
            (append (mapcar #'car epi-preflight--jcs-hashes) vectors))
           (tampered-relative (car vectors))
           (tampered (expand-file-name tampered-relative temporary-root)))
      (should tampered-relative)
      (epi-preflight--copy-relative-files source temporary-root relative-files)
      (epi-preflight--append-tamper tampered)
      (let ((text
             (epi-preflight--failure-text
              :emacs (epi-preflight--required-environment "EPI_EMACS")
              :gptel-root (epi-preflight--required-environment "GPTEL_ROOT")
              :pi-root (epi-preflight--required-environment "PI_ROOT")
              :jcs-oracle-root temporary-root
              :extra-load-path (epi-preflight--extra-load-path))))
        (epi-preflight--assert-mismatch-shape text)
        (should (string-match-p "vector\\|testdata\\|digest" text))
        (should
         (string-match-p
          (regexp-quote epi-preflight--jcs-vector-digest) text))))))

(ert-deftest epi-preflight-jcs-validation-does-not-execute-node ()
  (epi-test-with-temporary-root (temporary-root)
    (let* ((bin-directory (expand-file-name "bin" temporary-root))
           (sentinel (expand-file-name "node-executed" temporary-root))
           (process-environment (copy-sequence process-environment))
           (script
            (format "#!/bin/sh\n: > %s\nexit 97\n"
                    (shell-quote-argument sentinel))))
      (make-directory bin-directory t)
      (dolist (name '("node" "nodejs"))
        (let ((program (expand-file-name name bin-directory)))
          (with-temp-file program
            (insert script))
          (set-file-modes program #o700)))
      (setenv "EPI_NODE_SENTINEL" sentinel)
      (setenv "PATH"
              (concat bin-directory
                      (if (characterp path-separator)
                          (char-to-string path-separator)
                        path-separator)
                      (or (getenv "PATH") "")))
      (apply #'epi-test-preflight-validate (epi-preflight--options))
      (should-not (file-exists-p sentinel)))))

(defun epi-preflight--run-checkdoc-child (file)
  "Run the batch Checkdoc driver against FILE in a clean child Emacs."
  (let ((emacs (epi-preflight--required-environment "EPI_EMACS"))
        (stderr-file (make-temp-file "epi-checkdoc-stderr-"))
        (process-environment (copy-sequence process-environment))
        (default-directory epi-test-repository-root))
    (setenv "EPI_CHECKDOC_FILES" file)
    (unwind-protect
        (with-temp-buffer
          (let* ((status
                  (call-process
                   emacs nil (list (current-buffer) stderr-file) nil
                   "--batch" "-Q"
                   "-l" "checkdoc"
                   "-L" epi-test-repository-root
                   "-L" (expand-file-name "test" epi-test-repository-root)
                   "-l" (expand-file-name
                          "test/checkdoc.el" epi-test-repository-root)))
                 (stdout (buffer-string))
                 (stderr
                  (with-temp-buffer
                    (insert-file-contents stderr-file)
                    (buffer-string))))
            (list :status status :stdout stdout :stderr stderr)))
      (delete-file stderr-file))))

(ert-deftest epi-preflight-checkdoc-driver-fails-closed ()
  (epi-test-with-temporary-root (temporary-root)
    (let ((bad-source (expand-file-name "epi-checkdoc-bad.el" temporary-root)))
      (with-temp-file bad-source
        (insert
         ";;; epi-checkdoc-bad.el --- Deliberately invalid docs -*- lexical-binding: t; -*-\n"
         ";;; Commentary:\n;;; Code:\n"
         "(defun epi-checkdoc-bad (tests)\n"
         "  \"TESTS are ignored.\"\n"
         "  nil)\n"
         "(provide 'epi-checkdoc-bad)\n"
         ";;; epi-checkdoc-bad.el ends here\n"))
      (let* ((result (epi-preflight--run-checkdoc-child bad-source))
             (output (concat (plist-get result :stdout)
                             (plist-get result :stderr))))
        (should (integerp (plist-get result :status)))
        (should-not (zerop (plist-get result :status)))
        (should (string-match-p "Checkdoc failed" output))
        (should (string-match-p "imperative" output))))))

(ert-deftest epi-preflight-source-snapshot-does-not-reopen-path ()
  (epi-test-with-temporary-root (temporary-root)
    (let* ((source (expand-file-name "verified-source.el" temporary-root))
           (sentinel (expand-file-name "swapped-source-ran" temporary-root)))
      (with-temp-file source
        (insert "(setq epi-preflight--snapshot-observed 'verified)\n"))
      (let ((snapshot (epi-test--preflight-read-source-snapshot source)))
        (with-temp-file source
          (insert
           "(setq epi-preflight--snapshot-observed 'swapped)\n"
           "(with-temp-file " (prin1-to-string sentinel)
           " (insert \"unsafe\"))\n"))
        (unwind-protect
            (progn
              (epi-test--preflight-eval-source-snapshot snapshot source)
              (should (eq 'verified epi-preflight--snapshot-observed))
              (should-not (file-exists-p sentinel)))
          (makunbound 'epi-preflight--snapshot-observed))))))

(defun epi-preflight--run-make (directory arguments &rest environment)
  "Run Make in DIRECTORY with ARGUMENTS and ENVIRONMENT overrides."
  (let ((make (executable-find "make"))
        (stderr-file (make-temp-file "epi-make-stderr-"))
        (process-environment (copy-sequence process-environment))
        (default-directory directory))
    (unless make
      (ert-fail "make is required for the Makefile injection contract"))
    (while environment
      (setenv (pop environment) (pop environment)))
    (unwind-protect
        (with-temp-buffer
          (let* ((status
                  (apply
                   #'call-process
                   make nil (list (current-buffer) stderr-file) nil
                   "--no-print-directory"
                   arguments))
                 (stdout (buffer-string))
                 (stderr
                  (with-temp-buffer
                    (insert-file-contents stderr-file)
                    (buffer-string))))
            (list :status status :stdout stdout :stderr stderr)))
      (delete-file stderr-file))))

(defun epi-preflight--run-make-test-one (&rest environment)
  "Run one package test through Make with ENVIRONMENT overrides."
  (apply
   #'epi-preflight--run-make
   epi-test-repository-root
   '("test-one"
     "TEST=test/epi-package-test.el"
     "SELECTOR=^epi-package-json-sentinels-are-stable-and-distinct$")
   environment))

(ert-deftest epi-preflight-make-paths-are-shell-safe ()
  (epi-test-with-temporary-root (temporary-root)
    (let* ((sentinel-name ".epi-make-injection-sentinel")
           (sentinel (expand-file-name sentinel-name epi-test-repository-root))
           (payload (concat "\";touch " sentinel-name ";#"))
           (gptel-link
            (expand-file-name (concat "gptel" payload) temporary-root))
           (transient-link
            (expand-file-name (concat "transient" payload) temporary-root))
           (extra-paths (epi-preflight--extra-load-path))
           (separator (if (characterp path-separator)
                          (char-to-string path-separator)
                        path-separator)))
      (when (file-exists-p sentinel)
        (delete-file sentinel))
      (make-symbolic-link
       (epi-preflight--required-environment "GPTEL_ROOT") gptel-link)
      (make-symbolic-link (car extra-paths) transient-link)
      (unwind-protect
          (dolist (environment
                   (list
                    (list "GPTEL_ROOT" gptel-link)
                    (list
                     "EPI_EXTRA_LOAD_PATH"
                     (mapconcat #'identity
                                (cons transient-link (cdr extra-paths))
                                separator))))
            (let* ((result
                    (apply #'epi-preflight--run-make-test-one environment))
                   (output (concat (plist-get result :stdout)
                                   (plist-get result :stderr))))
              (ert-info (output)
                (should (equal 0 (plist-get result :status))))
              (should-not (file-exists-p sentinel))))
        (when (file-exists-p sentinel)
          (delete-file sentinel))))))

(defun epi-preflight--make-fixture-copy (relative destination)
  "Copy repository RELATIVE file below DESTINATION."
  (let ((target (expand-file-name relative destination)))
    (make-directory (file-name-directory target) t)
    (copy-file (expand-file-name relative epi-test-repository-root)
               target nil t)))

(defun epi-preflight--make-parent-fixture (root)
  "Create a minimal real-Emacs preflight project below ROOT."
  (epi-preflight--make-fixture-copy "Makefile" root)
  (epi-preflight--make-fixture-copy "test/run-tests.el" root)
  (let ((gptel-root (expand-file-name "untrusted-gptel" root))
        (extra-root (expand-file-name "untrusted-extra" root))
        (pi-root (expand-file-name "pi" root))
        (jcs-root (expand-file-name "jcs" root)))
    (dolist (directory (list gptel-root extra-root pi-root jcs-root))
      (make-directory directory t))
    (with-temp-file (expand-file-name "test/epi-test-helper.el" root)
      (insert
       "(require 'cl-lib)\n"
       "(require 'subr-x)\n"
       "(defun epi-test-preflight-validate () t)\n"
       "(provide 'epi-test-helper)\n"))
    (with-temp-file (expand-file-name "test/epi-preflight-test.el" root)
      (insert
       "(require 'ert)\n"
       "(require 'epi-test-helper)\n"
       "(ert-deftest epi-preflight-fixture () (should t))\n"))
    (list
     :root root
     :gptel-root gptel-root
     :extra-root extra-root
     :environment
     (list
      "EPI_EMACS" (epi-preflight--required-environment "EPI_EMACS")
      "GPTEL_ROOT" gptel-root
      "PI_ROOT" pi-root
      "JCS_ORACLE_ROOT" jcs-root
      "EPI_EXTRA_LOAD_PATH" extra-root))))

(defun epi-preflight--run-make-fixture (fixture arguments &rest environment)
  "Run FIXTURE Make with ARGUMENTS plus additional ENVIRONMENT."
  (apply
   #'epi-preflight--run-make
   (plist-get fixture :root)
   arguments
   (append (plist-get fixture :environment) environment)))

(ert-deftest epi-preflight-make-keeps-gptel-root-out-of-parent-load-path ()
  (epi-test-with-temporary-root (temporary-root)
    (let* ((fixture (epi-preflight--make-parent-fixture temporary-root))
           (roots
            (list (cons "GPTEL_ROOT" (plist-get fixture :gptel-root))
                  (cons "EPI_EXTRA_LOAD_PATH"
                        (plist-get fixture :extra-root)))))
      (dolist (root roots)
        (dolist (feature '(ert subr-x))
          (ert-info ((format "%s must not shadow parent dependency %s"
                             (car root) feature))
            (let ((sentinel
                   (expand-file-name
                    (format "%s-%s-parent-shadow-executed"
                            (car root) feature)
                    temporary-root))
                  (shadow
                   (expand-file-name (format "%s.el" feature) (cdr root))))
              (unwind-protect
                  (progn
                    (epi-preflight--write-executing-shadow
                     (cdr root) feature sentinel)
                    (let* ((result
                            (epi-preflight--run-make-fixture
                             fixture '("preflight")))
                           (output (concat (plist-get result :stdout)
                                           (plist-get result :stderr))))
                      (ert-info (output)
                        (should (equal 0 (plist-get result :status))))
                      (should-not (file-exists-p sentinel))))
                (when (file-exists-p shadow)
                  (delete-file shadow))))))))))

(defun epi-preflight--make-gate-fixture (root)
  "Create a minimal fake-Emacs Make gate project below ROOT."
  (epi-preflight--make-fixture-copy "Makefile" root)
  (let ((emacs (expand-file-name "recording-emacs" root))
        (record (expand-file-name "emacs-environment.log" root))
        (gptel-root (expand-file-name "gptel" root))
        (pi-root (expand-file-name "pi" root))
        (jcs-root (expand-file-name "jcs" root))
        (extra-root (expand-file-name "extra" root)))
    (dolist (directory (list gptel-root pi-root jcs-root extra-root
                             (expand-file-name "test" root)))
      (make-directory directory t))
    (with-temp-file (expand-file-name "epi.el" root)
      (insert ";;; epi.el --- fixture -*- lexical-binding: t; -*-\n"))
    (dolist (test '("test/epi-alpha-test.el" "test/epi-beta-test.el"))
      (with-temp-file (expand-file-name test root)
        (insert ";; fixture\n")))
    (with-temp-file emacs
      (insert
       "#!/bin/sh\n"
       "if [ \"${TESTS+x}\" = x ]; then printf 'test=%s\\n' \"$TESTS\" >> \"$EPI_TEST_RECORD\"; fi\n"
       "if [ \"${EPI_COMPILE_FILES+x}\" = x ]; then printf 'compile=%s\\n' \"$EPI_COMPILE_FILES\" >> \"$EPI_TEST_RECORD\"; fi\n"
       "if [ \"${EPI_BUILD_DIRECTORY+x}\" = x ]; then printf 'build=%s\\n' \"$EPI_BUILD_DIRECTORY\" >> \"$EPI_TEST_RECORD\"; fi\n"
       "if [ \"${EPI_CHECKDOC_FILES+x}\" = x ]; then printf 'checkdoc=%s\\n' \"$EPI_CHECKDOC_FILES\" >> \"$EPI_TEST_RECORD\"; fi\n"
       "exit 0\n"))
    (set-file-modes emacs #o700)
    (list
     :root root
     :record record
     :environment
     (list "EPI_EMACS" emacs
           "GPTEL_ROOT" gptel-root
           "PI_ROOT" pi-root
           "JCS_ORACLE_ROOT" jcs-root
           "EPI_EXTRA_LOAD_PATH" extra-root
           "EPI_TEST_RECORD" record))))

(defun epi-preflight--make-fixture-record-lines (fixture)
  "Return FIXTURE's nonempty fake-Emacs record lines."
  (let ((record (plist-get fixture :record)))
    (if (file-exists-p record)
        (with-temp-buffer
          (insert-file-contents record)
          (split-string (buffer-string) "[\r\n]+" t))
      nil)))

(defun epi-preflight--clear-make-fixture-record (fixture)
  "Remove FIXTURE's fake-Emacs record."
  (let ((record (plist-get fixture :record)))
    (when (file-exists-p record)
      (delete-file record))))

(defun epi-preflight--make-fixture-record-values (fixture prefix)
  "Return values from FIXTURE record lines beginning with PREFIX."
  (mapcar
   (lambda (line) (string-remove-prefix prefix line))
   (seq-filter
    (lambda (line) (string-prefix-p prefix line))
    (epi-preflight--make-fixture-record-lines fixture))))

(defun epi-preflight--assert-make-result-success (result)
  "Assert RESULT is a successful Make invocation, reporting its output."
  (let ((output (concat (plist-get result :stdout)
                        (plist-get result :stderr))))
    (ert-info (output)
      (should (equal 0 (plist-get result :status))))))

(ert-deftest epi-preflight-make-offline-gate-cannot-be-overridden ()
  (epi-test-with-temporary-root (temporary-root)
    (let ((fixture (epi-preflight--make-gate-fixture temporary-root))
          (expected '("test=test/epi-alpha-test.el"
                      "test=test/epi-beta-test.el")))
      (dolist (attempt
               '(("OFFLINE_TESTS=cli-attack"
                  "NON_IN_PROCESS_TESTS=test/epi-alpha-test.el"
                  "EPI_BUILD_EMACS_ARGV=false")
                 ("MAKEFLAGS=OFFLINE_TESTS=makeflags-attack NON_IN_PROCESS_TESTS=test/epi-alpha-test.el EPI_BUILD_EMACS_ARGV=false")))
        (epi-preflight--clear-make-fixture-record fixture)
        (let ((result
               (if (string-prefix-p "MAKEFLAGS=" (car attempt))
                   (epi-preflight--run-make-fixture
                    fixture '("test") "MAKEFLAGS" (substring (car attempt) 10))
                 (epi-preflight--run-make-fixture
                  fixture (cons "test" attempt)))))
          (epi-preflight--assert-make-result-success result)
          (should
           (equal
            (mapcar (lambda (line) (string-remove-prefix "test=" line))
                    expected)
            (epi-preflight--make-fixture-record-values
             fixture "test="))))))))

(ert-deftest epi-preflight-make-compile-gate-cannot-be-overridden ()
  (epi-test-with-temporary-root (temporary-root)
    (let ((fixture (epi-preflight--make-gate-fixture temporary-root)))
      (dolist (attempt
               '((:arguments
                  "EPI_COMPILE_FILES=cli-attack.el"
                  "EPI_BUILD_DIRECTORY=cli-build"
                  "PRODUCTION_FILES=cli-production.el"
                  "BUILD_DIRECTORY=cli-root")
                 (:makeflags
                  "EPI_COMPILE_FILES=makeflags-attack.el EPI_BUILD_DIRECTORY=makeflags-build PRODUCTION_FILES=makeflags-production.el BUILD_DIRECTORY=makeflags-root")))
        (epi-preflight--clear-make-fixture-record fixture)
        (let ((result
               (if (eq (car attempt) :arguments)
                   (epi-preflight--run-make-fixture
                    fixture (cons "compile" (cdr attempt)))
                 (epi-preflight--run-make-fixture
                  fixture '("compile") "MAKEFLAGS" (cadr attempt)))))
          (epi-preflight--assert-make-result-success result)
          (let ((compile-values
                 (epi-preflight--make-fixture-record-values
                  fixture "compile="))
                (build-values
                 (epi-preflight--make-fixture-record-values
                  fixture "build=")))
            (should (equal '("epi.el")
                           (split-string (car compile-values))))
            (should
             (equal
              (epi-preflight--normalized-truename
              (expand-file-name ".build/elc" temporary-root))
              (epi-preflight--normalized-truename
               (car build-values))))))))))

(ert-deftest epi-preflight-make-checkdoc-gate-cannot-be-overridden ()
  (epi-test-with-temporary-root (temporary-root)
    (let ((fixture (epi-preflight--make-gate-fixture temporary-root)))
      (dolist (attempt
               '((:arguments
                  "EPI_CHECKDOC_FILES=cli-attack.el"
                  "PRODUCTION_FILES=cli-production.el")
                 (:makeflags
                  "EPI_CHECKDOC_FILES=makeflags-attack.el PRODUCTION_FILES=makeflags-production.el")))
        (epi-preflight--clear-make-fixture-record fixture)
        (let ((result
               (if (eq (car attempt) :arguments)
                   (epi-preflight--run-make-fixture
                    fixture (cons "checkdoc" (cdr attempt)))
                 (epi-preflight--run-make-fixture
                  fixture '("checkdoc") "MAKEFLAGS" (cadr attempt)))))
          (epi-preflight--assert-make-result-success result)
          (should
           (equal
            '("epi.el")
            (split-string
             (car
              (epi-preflight--make-fixture-record-values
               fixture "checkdoc="))))))))))

;; Runner semantics are tested here so an empty selection cannot pass a red
;; or green gate.  SELECTOR remains an unparsed raw regexp string.

(defconst epi-preflight--zero-selector-diagnostic
  "SELECTOR matched zero loaded ERT tests")

(defconst epi-preflight--no-tests-diagnostic
  "No loaded ERT tests")

(defconst epi-preflight--zero-body-marker
  "EPI-RUNNER-ZERO-BODY-RAN")

(defun epi-preflight--write-file (file contents)
  (with-temp-file file
    (insert contents))
  file)

(defun epi-preflight--runner-path ()
  (expand-file-name "test/run-tests.el" epi-test-repository-root))

(defun epi-preflight--tests-environment-value (tests)
  (cond
   ((null tests) nil)
   ((stringp tests) tests)
   ((cl-every #'stringp tests)
    (dolist (file tests)
      (when (string-match-p "[[:space:]]" file)
        (ert-fail (format "Runner fixture path contains whitespace: %S" file))))
    (mapconcat #'identity tests "\n"))
   (t (ert-fail (format "Invalid TESTS fixture: %S" tests)))))

(defun epi-preflight--run-runner-child
    (runner tests selector &optional preloads)
  (let ((emacs (getenv "EPI_EMACS")))
    (unless (and emacs (file-executable-p emacs))
      (ert-fail "EPI_EMACS must name an executable Emacs"))
    (let ((stderr-file (make-temp-file "epi-runner-stderr-"))
          (process-environment (copy-sequence process-environment))
          (default-directory epi-test-repository-root))
      (setenv "TESTS"
              (epi-preflight--tests-environment-value tests))
      (setenv "SELECTOR" selector)
      (unwind-protect
          (with-temp-buffer
            (let* ((arguments
                    (append
                     (list "--batch" "-Q"
                           "-L" epi-test-repository-root
                           "-L" (expand-file-name
                                 "test" epi-test-repository-root))
                     (cl-mapcan (lambda (file) (list "-l" file))
                                preloads)
                     (list "-l" runner)))
                   (status
                    (apply #'call-process emacs nil
                           (list (current-buffer) stderr-file) nil
                           arguments))
                   (stdout (buffer-string))
                   (stderr
                    (with-temp-buffer
                      (insert-file-contents stderr-file)
                      (buffer-string))))
              (list :status status
                    :stdout stdout
                    :stderr stderr)))
        (delete-file stderr-file)))))

(defun epi-preflight--exact-line-count (line output)
  (cl-count line (split-string output "[\r\n]+" t)
            :test #'string=))

(defun epi-preflight--result-line-count (line result)
  (+ (epi-preflight--exact-line-count
      line (plist-get result :stdout))
     (epi-preflight--exact-line-count
      line (plist-get result :stderr))))

(defun epi-preflight--zero-selector-result-p (result)
  (let ((status (plist-get result :status)))
    (and (integerp status)
         (not (zerop status))
         (= 1
            (epi-preflight--result-line-count
             epi-preflight--zero-selector-diagnostic result)))))

(defun epi-preflight--no-tests-result-p (result)
  (let ((status (plist-get result :status)))
    (and (integerp status)
         (not (zerop status))
         (= 1
            (epi-preflight--result-line-count
             epi-preflight--no-tests-diagnostic result))
         (= 0
            (epi-preflight--result-line-count
             epi-preflight--zero-selector-diagnostic result)))))

(defun epi-preflight--should-succeed-with-count
    (result count body-marker)
  (should (equal 0 (plist-get result :status)))
  (let* ((stdout (plist-get result :stdout))
         (count-line (format "%d loaded ERT tests" count))
         (count-position
          (string-match (regexp-quote count-line) stdout))
         (body-position
          (string-match (regexp-quote body-marker) stdout)))
    (should (= 1 (epi-preflight--exact-line-count count-line stdout)))
    (should (integerp count-position))
    (should (integerp body-position))
    (should (< count-position body-position))))

(defun epi-preflight--make-runner-fixtures (directory)
  (let ((pass-only (expand-file-name "pass-only-test.el" directory))
        (raw-a (expand-file-name "raw-a-test.el" directory))
        (raw-b (expand-file-name "raw-b-test.el" directory))
        (zero-body (expand-file-name "zero-body-test.el" directory))
        (ordered-first
         (expand-file-name "ordered-first-test.el" directory))
        (ordered-second
         (expand-file-name "ordered-second-test.el" directory))
        (unrequested (expand-file-name "unrequested-test.el" directory)))
    (epi-preflight--write-file
     pass-only
     (concat
      "(require 'ert)\n"
      "(ert-deftest epi-runner-pass-only ()\n"
      "  (princ \"EPI-RUNNER-BODY:pass-only\\n\")\n"
      "  (should t))\n"))
    (epi-preflight--write-file
     raw-a
     (concat
      "(require 'ert)\n"
      ;; The escaped delimiters and spaces form one symbol whose printed name
      ;; is the valid Lisp selector used by the parent test below.
      "(ert-deftest \\(member\\ epi-runner-read-trap-a\\ epi-runner-read-trap-b\\) ()\n"
      "  (princ \"EPI-RUNNER-BODY:raw-read-trap\\n\")\n"
      "  (should t))\n"
      "(ert-deftest epi-runner-read-trap-a () (ert-fail \"SELECTOR was read\"))\n"
      "(ert-deftest epi-runner-regexp-alpha ()\n"
      "  (princ \"EPI-RUNNER-BODY:regexp-alpha\\n\")\n"
      "  (should t))\n"
      "(ert-deftest epi-runner-unselected-trap () (ert-fail \"SELECTOR was ignored\"))\n"))
    (epi-preflight--write-file
     raw-b
     (concat
      "(require 'ert)\n"
      "(ert-deftest epi-runner-read-trap-b () (ert-fail \"SELECTOR was read\"))\n"
      "(ert-deftest epi-runner-regexp-beta ()\n"
      "  (princ \"EPI-RUNNER-BODY:regexp-beta\\n\")\n"
      "  (should t))\n"))
    (epi-preflight--write-file
     zero-body
     (concat
      "(require 'ert)\n"
      "(ert-deftest epi-runner-zero-body ()\n"
      "  (princ \"EPI-RUNNER-ZERO-BODY-RAN\\n\")\n"
      "  (should t))\n"))
    (epi-preflight--write-file
     ordered-first
     (concat
      "(defvar epi-runner-order-sentinel nil)\n"
      "(setq epi-runner-order-sentinel 'first-loaded)\n"))
    (epi-preflight--write-file
     ordered-second
     (concat
      "(unless (and (boundp 'epi-runner-order-sentinel)\n"
      "             (eq epi-runner-order-sentinel 'first-loaded))\n"
      "  (error \"TESTS files loaded out of declared order\"))\n"
      "(require 'ert)\n"
      "(ert-deftest epi-runner-ordered-pass ()\n"
      "  (princ \"EPI-RUNNER-BODY:ordered\\n\")\n"
      "  (should t))\n"))
    (epi-preflight--write-file
     unrequested
     "(error \"Runner loaded an unrequested sibling test file\")\n")
    (list :pass-only pass-only
          :raw-a raw-a
          :raw-b raw-b
          :zero-body zero-body
          :ordered-first ordered-first
          :ordered-second ordered-second
          :unrequested unrequested)))

(ert-deftest epi-preflight-runner-honors-tests-selector-truth-table ()
  (let ((directory (make-temp-file "epi-runner-contract-" t)))
    (unwind-protect
        (let* ((fixtures
                (epi-preflight--make-runner-fixtures directory))
               (pass-only (plist-get fixtures :pass-only))
               (raw-a (plist-get fixtures :raw-a))
               (raw-b (plist-get fixtures :raw-b))
               (ordered-first (plist-get fixtures :ordered-first))
               (ordered-second (plist-get fixtures :ordered-second))
               (ordered-first-relative
                (file-relative-name
                 ordered-first epi-test-repository-root))
               (ordered-second-relative
                (file-relative-name
                 ordered-second epi-test-repository-root))
               (runner (epi-preflight--runner-path))
               (read-trap-selector
                "(member epi-runner-read-trap-a epi-runner-read-trap-b)")
               (regexp-selector
                "^epi-runner-regexp-\\(?:alpha\\|beta\\)$"))
          ;; TESTS unset, SELECTOR unset: run already registered tests.
          (epi-preflight--should-succeed-with-count
           (epi-preflight--run-runner-child
            runner nil nil (list pass-only))
           1 "EPI-RUNNER-BODY:pass-only")
          ;; Empty environment values have the same no-filter/no-load meaning.
          (epi-preflight--should-succeed-with-count
           (epi-preflight--run-runner-child
            runner "" "" (list pass-only))
           1 "EPI-RUNNER-BODY:pass-only")
          ;; Whitespace-only TESTS loads no file; the preload still runs.
          (epi-preflight--should-succeed-with-count
           (epi-preflight--run-runner-child
            runner " \t\n\r " nil (list pass-only))
           1 "EPI-RUNNER-BODY:pass-only")
          ;; TESTS explicit, SELECTOR absent: load and run the requested file.
          (epi-preflight--should-succeed-with-count
           (epi-preflight--run-runner-child
            runner (list pass-only) nil)
           1 "EPI-RUNNER-BODY:pass-only")
          ;; TESTS absent, SELECTOR explicit: raw regexp over preloaded tests.
          ;; Reading this string as Lisp selects the two failing trap tests.
          (epi-preflight--should-succeed-with-count
           (epi-preflight--run-runner-child
            runner nil read-trap-selector (list raw-a raw-b))
           1 "EPI-RUNNER-BODY:raw-read-trap")
          ;; Whitespace-only SELECTOR is a raw regexp, not an absent selector;
          ;; it selects only the specially named test containing spaces.
          (epi-preflight--should-succeed-with-count
           (epi-preflight--run-runner-child
            runner nil " " (list raw-a raw-b))
           1 "EPI-RUNNER-BODY:raw-read-trap")
          ;; Both explicit: split TESTS, load no sibling, honor regexp syntax,
          ;; preselect only alpha/beta, and leave the loaded trap unexecuted.
          (epi-preflight--should-succeed-with-count
           (epi-preflight--run-runner-child
            runner (list raw-a raw-b) regexp-selector)
           2 "EPI-RUNNER-BODY:regexp-")
          ;; Relative TESTS paths are resolved from the repository root and
          ;; loaded in declared order before selection.
          (should-not (file-name-absolute-p ordered-first-relative))
          (should-not (file-name-absolute-p ordered-second-relative))
          (epi-preflight--should-succeed-with-count
           (epi-preflight--run-runner-child
            runner
            (list ordered-first-relative ordered-second-relative)
            "^epi-runner-ordered-pass$")
           1 "EPI-RUNNER-BODY:ordered"))
      (delete-directory directory t))))

(ert-deftest epi-preflight-runner-rejects-no-tests-without-selector ()
  (let ((result
         (epi-preflight--run-runner-child
          (epi-preflight--runner-path) nil nil)))
    (should (epi-preflight--no-tests-result-p result))))

(ert-deftest epi-preflight-runner-zero-selector-is-distinct ()
  (let ((directory (make-temp-file "epi-runner-zero-" t)))
    (unwind-protect
        (let* ((fixtures
                (epi-preflight--make-runner-fixtures directory))
               (raw-a (plist-get fixtures :raw-a))
               (zero-body (plist-get fixtures :zero-body))
               (runner (epi-preflight--runner-path))
               (zero
                (epi-preflight--run-runner-child
                 runner (list zero-body)
                 "^epi-runner-no-such-test$")))
          (should (epi-preflight--zero-selector-result-p zero))
          (should-not
           (string-match-p
            (regexp-quote epi-preflight--zero-body-marker)
            (plist-get zero :stdout)))
          (should-not
           (string-match-p
            (regexp-quote epi-preflight--zero-body-marker)
            (plist-get zero :stderr)))
          ;; Launch negative controls only after the primary intended-red
          ;; assertion has proved the canonical runner's zero-match behavior.
          (let* ((missing-runner
                  (epi-preflight--run-runner-child
                   (expand-file-name "missing-run-tests.el" directory)
                   (list zero-body) "^epi-runner-no-such-test$"))
                 (missing-test
                  (epi-preflight--run-runner-child
                   runner
                   (list (expand-file-name "missing-test.el" directory))
                   "^epi-runner-no-such-test$"))
                 (invalid-regexp
                  (epi-preflight--run-runner-child
                   runner (list zero-body) "["))
                 (ordinary-ert-failure
                  (epi-preflight--run-runner-child
                   runner (list raw-a) "^epi-runner-read-trap-a$")))
            (should-not
             (epi-preflight--zero-selector-result-p missing-runner))
            (should-not
             (epi-preflight--zero-selector-result-p missing-test))
            (should (integerp (plist-get invalid-regexp :status)))
            (should-not (zerop (plist-get invalid-regexp :status)))
            (should
             (= 0
                (epi-preflight--result-line-count
                 epi-preflight--zero-selector-diagnostic
                 invalid-regexp)))
            (should-not
             (string-match-p
              (regexp-quote epi-preflight--zero-body-marker)
              (plist-get invalid-regexp :stdout)))
            (should-not
             (string-match-p
              (regexp-quote epi-preflight--zero-body-marker)
              (plist-get invalid-regexp :stderr)))
            (should-not
             (epi-preflight--zero-selector-result-p invalid-regexp))
            (should (integerp (plist-get ordinary-ert-failure :status)))
            (should-not
             (zerop (plist-get ordinary-ert-failure :status)))
            (should-not
             (epi-preflight--zero-selector-result-p
              ordinary-ert-failure))))
      (delete-directory directory t))))

(provide 'epi-preflight-test)

;;; epi-preflight-test.el ends here
