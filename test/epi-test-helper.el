;;; epi-test-helper.el --- Shared deterministic Epi test support -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley
;; Keywords: tools

;;; Commentary:

;; Shared support loaded before any Epi production file exists.  Loading this
;; library must not load GPTel.  The explicit preflight entry point starts a
;; clean child Emacs when dependency validation is requested.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function comp-el-to-eln-filename "comp.c" (filename &optional base-dir))

(defconst epi-test-repository-root
  (file-name-directory
   (directory-file-name
    (file-name-directory
     (file-truename (or load-file-name buffer-file-name)))))
  "Absolute path to the Epi repository root used by the test process.")

(defvar epi-test--id-values nil
  "Remaining deterministic identifiers for `epi-test-next-id'.")

(defvar epi-test--wall-time-values nil
  "Remaining deterministic wall timestamps for `epi-test-wall-time'.")

(defvar epi-test--deadline-values nil
  "Remaining deterministic deadline samples for `epi-test-deadline-time'.")

(defun epi-test--take-value (variable description)
  "Take the next value from VARIABLE, or fail mentioning DESCRIPTION."
  (let ((values (symbol-value variable)))
    (unless values
      (error "No deterministic %s values remain" description))
    (set variable (cdr values))
    (car values)))

(defun epi-test-next-id ()
  "Return the next dynamically supplied deterministic identifier."
  (epi-test--take-value 'epi-test--id-values "identifier"))

(defun epi-test-wall-time ()
  "Return the next dynamically supplied deterministic wall timestamp."
  (epi-test--take-value 'epi-test--wall-time-values "wall-time"))

(defun epi-test-deadline-time ()
  "Return the next dynamically supplied deterministic deadline sample."
  (epi-test--take-value 'epi-test--deadline-values "deadline"))

(cl-defmacro epi-test-with-temporary-root ((variable) &rest body)
  "Bind VARIABLE to a private temporary directory while evaluating BODY."
  (declare (indent 1) (debug ((symbolp) body)))
  (let ((cleanup-root (make-symbol "cleanup-root")))
    `(let* ((,cleanup-root (make-temp-file "epi-test-" t))
            (,variable ,cleanup-root))
       (unwind-protect
           (progn ,@body)
         (when (file-directory-p ,cleanup-root)
           (delete-directory ,cleanup-root t))))))

(defmacro epi-test-with-epi-loaded (&rest body)
  "Require Epi only when the selected test executes, then evaluate BODY."
  (declare (indent 0) (debug t))
  `(progn
     (require 'epi)
     ,@body))

(defconst epi-test--preflight-gptel-commit
  "8701e2bd80c5d2091ce2decef5d34d6fce4a3ada"
  "Required GPTel revision for the first Epi slice.")

(defconst epi-test--preflight-gptel-hashes
  '(("gptel.el" .
     "2a1a7aba6bb4d7af7bf302ebed75ad74c598ccb7383fc5f5318b15295c42bbe5")
    ("gptel-request.el" .
     "f4a42353208dc52ac14cd90e77e06d6b656d00c6bc5ee5a72cb9d517e088d66b")
    ("gptel-openai.el" .
     "8467b1693a768230d6fa7f57f636756282c613626b94b0ff05f656b212d69677"))
  "Required GPTel source hashes for the first Epi slice.")

(defconst epi-test--preflight-pi-commit
  "dd6bea41efa8caa7a10fe5a6401676dc5699f83f"
  "Required Pi behavioral-oracle revision.")

(defconst epi-test--preflight-pi-hashes
  '(("packages/coding-agent/src/core/session-manager.ts" .
     "5ca662efec88c135559630deda469fcf022035ddfb61b4610de8d74cee5c8b39")
    ("packages/coding-agent/src/core/agent-session.ts" .
     "7fe22be86e251af9f820c816f0c847e6db390682e33882f8fce388715fea4dc5")
    ("packages/coding-agent/src/core/resource-loader.ts" .
     "e2b999d280fcf640a995fadca84cfc9ddfd83aef1d3748f29dd71edae0c408a8")
    ("packages/coding-agent/src/core/tools/read.ts" .
     "1acc6fcb88a29317d4f800fa1e9e1ff3d13d32527dd8c6f1cdbeeab5107ae06d")
    ("packages/coding-agent/src/core/tools/edit.ts" .
     "a42f745488ab89553173479986efc222544eeac26e1820692954031c63c27fdd"))
  "Required Pi source hashes for the first Epi slice.")

(defconst epi-test--preflight-jcs-commit
  "19d51d7fe467d4706a3ff08adf8a748f29fc21e0"
  "Required JSON canonicalization oracle revision.")

(defconst epi-test--preflight-jcs-hashes
  '(("node-es6/canonicalize.js" .
     "f9f498b55c99eefe348c99018ddcfe08efa6f7ff96b9ba9dce4b7090b33c4438")
    ("node-es6/verify-canonicalization.js" .
     "314898c8f08ed5b14a3f5903b27ec4789ac5dc7fd59a168e72a6d876f192be6f"))
  "Required JSON canonicalization oracle source hashes.")

(defconst epi-test--preflight-jcs-vector-digest
  "823c07e7e1b1bbfc903354435b508026e43d2bf3183450a8773cf6cab7668933"
  "Required aggregate digest of the official JCS vectors.")

(defvar epi-test--preflight-mismatches nil
  "Dynamically accumulated preflight mismatch diagnostics.")

(defun epi-test--preflight-record-mismatch (subject observed required)
  "Record that SUBJECT has OBSERVED instead of REQUIRED."
  (push (format "%s observed: %S required: %S"
                subject observed required)
        epi-test--preflight-mismatches))

(defun epi-test--preflight-path-separator ()
  "Return `path-separator' as a one-character string."
  (if (characterp path-separator)
      (char-to-string path-separator)
    path-separator))

(defun epi-test--preflight-environment-paths (name)
  "Split path-list environment variable NAME without dropping its order."
  (let ((value (getenv name)))
    (and value
         (split-string value
                       (regexp-quote
                        (epi-test--preflight-path-separator))
                       t))))

(defun epi-test--preflight-normalize-path-list (paths)
  "Return PATHS as a list of expanded directory names."
  (mapcar #'expand-file-name
          (cond
           ((null paths) nil)
           ((stringp paths)
            (split-string paths
                          (regexp-quote
                           (epi-test--preflight-path-separator))
                          t))
           ((listp paths) paths)
           (t (list paths)))))

(defun epi-test--preflight-path (root relative)
  "Return RELATIVE below ROOT, or a descriptive unavailable value."
  (if (stringp root)
      (expand-file-name relative root)
    (format "<unavailable root %S>" root)))

(defun epi-test--preflight-truename (file)
  "Return FILE's truename, or its expanded name if it does not exist."
  (condition-case nil
      (file-truename file)
    (file-error (expand-file-name file))))

(defun epi-test--preflight-file-sha256 (file)
  "Return the SHA-256 of the literal bytes in FILE."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer) (point-min) (point-max))))

(defun epi-test--preflight-read-source-snapshot (file)
  "Read FILE once and return its literal bytes as a snapshot."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun epi-test--preflight-source-snapshot-sha256 (snapshot)
  "Return the SHA-256 of literal byte string SNAPSHOT."
  (unless (and (stringp snapshot) (not (multibyte-string-p snapshot)))
    (error "Source snapshot must be a unibyte string"))
  (secure-hash 'sha256 snapshot))

(defun epi-test--preflight-eval-source-snapshot (snapshot source)
  "Evaluate byte SNAPSHOT as UTF-8 Elisp with provenance SOURCE."
  (unless (and (stringp source) (file-name-absolute-p source))
    (error "Source provenance must be an absolute file name"))
  (with-temp-buffer
    (insert (decode-coding-string snapshot 'utf-8-unix))
    (setq-local buffer-file-name source)
    (setq-local default-directory (file-name-directory source))
    (setq-local lexical-binding t)
    (eval-buffer (current-buffer) nil source)))

(defun epi-test--preflight-observe-hashes (subject root required-hashes)
  "Validate SUBJECT files below ROOT against REQUIRED-HASHES.

Return an alist containing every observed hash or read error."
  (let (observed-hashes)
    (dolist (entry required-hashes)
      (let* ((relative (car entry))
             (required (cdr entry))
             (file (epi-test--preflight-path root relative))
             (observed
              (condition-case condition
                  (epi-test--preflight-file-sha256 file)
                (error
                 (format "<hash error: %s>"
                         (error-message-string condition))))))
        (push (cons relative observed) observed-hashes)
        (unless (equal observed required)
          (epi-test--preflight-record-mismatch
           (format "%s source %s" subject relative)
           observed required))))
    (nreverse observed-hashes)))

(defun epi-test--preflight-git-head (subject root)
  "Return the Git HEAD at ROOT, recording failures for SUBJECT as a value."
  (condition-case condition
      (if (not (and (stringp root) (file-directory-p root)))
          (format "<invalid Git root %S>" root)
        (with-temp-buffer
          (let ((status
                 (process-file "git" nil (current-buffer) nil
                               "-C" root "rev-parse" "HEAD")))
            (if (and (integerp status) (zerop status))
                (string-trim (buffer-string))
              (format "<git exited %S for %s>" status subject)))))
    (error (format "<git error: %s>" (error-message-string condition)))))

(defun epi-test--preflight-version-at-least-p (observed required)
  "Return non-nil when version OBSERVED is at least REQUIRED."
  (and (stringp observed)
       (condition-case nil
           (version<= required observed)
         (error nil))))

(defun epi-test--preflight-library-source (library)
  "Return a readable source file corresponding to located LIBRARY."
  (let ((located (locate-library library)))
    (cond
     ((not (stringp located)) nil)
     ((string-suffix-p ".el" located) located)
     ((and (string-suffix-p ".elc" located)
           (file-readable-p (substring located 0 -1)))
      (substring located 0 -1))
     ((and (string-suffix-p ".eln" located)
           (file-readable-p
            (concat (file-name-sans-extension located) ".el")))
      (concat (file-name-sans-extension located) ".el"))
     (t located))))

(defun epi-test--preflight-library-version (library)
  "Read LIBRARY's Version or Package-Version header from source bytes."
  (let ((source (epi-test--preflight-library-source library)))
    (if (not (and source (file-readable-p source)))
        (format "<source unavailable for %s>" library)
      (with-temp-buffer
        (insert-file-contents source nil 0 16384)
        (goto-char (point-min))
        (if (re-search-forward
             "^;;[ \t]+\\(?:Package-\\)?Version:[ \t]*\\([^ \t\r\n]+\\)"
             nil t)
            (match-string-no-properties 1)
          (format "<version header unavailable in %s>" source))))))

(defun epi-test--preflight-native-artifacts (source)
  "Return loadable native artifacts corresponding to Elisp SOURCE."
  (let (artifacts)
    (condition-case condition
        (progn
          (unless (fboundp 'comp-el-to-eln-filename)
            (require 'comp))
          (if (not (fboundp 'comp-el-to-eln-filename))
              (epi-test--preflight-record-mismatch
               "GPTel native-artifact inspection"
               "comp-el-to-eln-filename unavailable"
               "successful native-artifact inspection")
            (dolist (directory
                     (and (boundp 'native-comp-eln-load-path)
                          (symbol-value 'native-comp-eln-load-path)))
              (when (stringp directory)
                (let ((candidate
                       (comp-el-to-eln-filename
                        source
                        (expand-file-name directory invocation-directory))))
                  (when (file-exists-p candidate)
                    (push (epi-test--preflight-truename candidate)
                          artifacts)))))))
      (error
       (epi-test--preflight-record-mismatch
        "GPTel native-artifact inspection"
        (error-message-string condition)
        "successful native-artifact inspection")))
    (delete-dups (nreverse artifacts))))

(defun epi-test--preflight-require (feature)
  "Require FEATURE and record an actionable mismatch on failure."
  (condition-case condition
      (require feature)
    (error
     (epi-test--preflight-record-mismatch
      (format "Loadable dependency %s" feature)
      (error-message-string condition)
      "load succeeds under --batch -Q with declared paths")
     nil)))

(defun epi-test--preflight-child-probe (options)
  "Run the source-only GPTel probe described by OPTIONS in this child."
  ;; Load built-ins on the pristine --batch -Q path before even the declared
  ;; package directories can participate.  Then load only Compat and
  ;; Transient from the declared paths.  Keep that resulting trusted path for
  ;; snapshot evaluation; neither probe paths nor dependency shadows may
  ;; satisfy a `require' issued by verified GPTel bytes.
  (let* ((default-load-path (copy-sequence load-path))
         (extra-load-path
          (epi-test--preflight-normalize-path-list
           (plist-get options :extra-load-path)))
         (trusted-load-path (append extra-load-path default-load-path))
         trusted-transient-version
         trusted-compat-version)
    (let ((load-path default-load-path))
      (dolist (feature
               '(org comp cl-lib subr-x url text-property-search
                     cl-generic map mailcap cond-let eieio edmacro
                     format-spec llama pcase pp seq))
        (epi-test--preflight-require feature)))
    (let ((load-path trusted-load-path))
      (epi-test--preflight-require 'compat)
      (epi-test--preflight-require 'transient)
      (setq trusted-transient-version
            (epi-test--preflight-library-version "transient"))
      (setq trusted-compat-version
            (epi-test--preflight-library-version "compat")))
    (let* ((gptel-root (plist-get options :gptel-root))
         (probe-root (or (plist-get options :gptel-probe-root)
                         gptel-root))
         (load-path-prefix
          (epi-test--preflight-normalize-path-list
           (plist-get options :load-path-prefix)))
         (overrides (plist-get options :native-artifact-overrides))
         (load-path
          (append load-path-prefix
                  (and probe-root (list (expand-file-name probe-root)))
                  trusted-load-path))
         library-files
         source-snapshots
         source-hashes
         symbol-files
         provenance-valid-p)
    ;; These assignments occur before any dependency is loaded.  The child is
    ;; disposable, so changing its process-local native compilation policy is
    ;; intentional.
    (when (boundp 'native-comp-jit-compilation)
      (set 'native-comp-jit-compilation nil))
    (when (boundp 'native-comp-deferred-compilation)
      (set 'native-comp-deferred-compilation nil))
    ;; Resolve everything before loading any GPTel source.
    (dolist (library '("gptel" "gptel-request" "gptel-openai"))
      (let* ((relative (concat library ".el"))
             (required
              (epi-test--preflight-path probe-root relative))
             (required-hash
              (alist-get relative epi-test--preflight-gptel-hashes
                         nil nil #'string=))
             (located (locate-library library))
             (observed (and located
                            (epi-test--preflight-truename located)))
             (required-truename
              (epi-test--preflight-truename required))
             (sibling (concat required "c"))
             (override
              (alist-get library overrides nil nil #'string=)))
        (push (cons library observed) library-files)
        (unless (equal observed required-truename)
          (epi-test--preflight-record-mismatch
           (format "GPTel source resolution for %s" library)
           observed required-truename))
        (unless (file-readable-p required)
          (epi-test--preflight-record-mismatch
           (format "GPTel readable source for %s" library)
           required "readable exact .el source"))
        (let ((observed-hash
               (condition-case condition
                   (let ((snapshot
                          (epi-test--preflight-read-source-snapshot required)))
                     (push (list library required snapshot) source-snapshots)
                     (epi-test--preflight-source-snapshot-sha256 snapshot))
                 (error
                  (format "<hash error: %s>"
                          (error-message-string condition))))))
          (push (cons relative observed-hash) source-hashes)
          (unless (equal observed-hash required-hash)
            (epi-test--preflight-record-mismatch
             (format "GPTel probe source %s" relative)
             observed-hash required-hash)))
        (when (file-exists-p sibling)
          (epi-test--preflight-record-mismatch
           (format "GPTel sibling byte-code for %s" library)
           (epi-test--preflight-truename sibling) "absent"))
        (dolist (artifact
                 (append
                  (and (file-readable-p required)
                       (epi-test--preflight-native-artifacts required))
                  (and override (file-exists-p override)
                       (list (epi-test--preflight-truename override)))))
          (epi-test--preflight-record-mismatch
           (format "GPTel native artifact for %s" library)
           artifact "absent"))))
    (setq library-files (nreverse library-files))
    (setq source-hashes (nreverse source-hashes))
    (setq provenance-valid-p (null epi-test--preflight-mismatches))
    (if provenance-valid-p
        (let ((load-path trusted-load-path))
          ;; Evaluate the exact bytes that were hashed, in dependency order.
          ;; SOURCE is metadata for load history; its path is never reopened,
          ;; and unverified resolution paths are no longer present.
          (dolist (library '("gptel-request" "gptel-openai" "gptel"))
            (let* ((entry (assoc-string library source-snapshots))
                   (source (nth 1 entry))
                   (snapshot (nth 2 entry)))
              (condition-case condition
                  (if entry
                      (epi-test--preflight-eval-source-snapshot
                       snapshot source)
                    (error "Verified source snapshot is unavailable"))
                (error
                 (epi-test--preflight-record-mismatch
                  (format "GPTel absolute source load for %s" library)
                  (error-message-string condition) "load succeeds")))))
          (dolist (entry '((gptel . "gptel.el")
                           (gptel-request . "gptel-request.el")
                           (gptel-make-openai . "gptel-openai.el")))
            (let* ((symbol (car entry))
                   (observed-file (symbol-file symbol 'defun))
                   (observed
                    (and observed-file
                         (epi-test--preflight-truename observed-file)))
                   (required
                    (epi-test--preflight-truename
                     (epi-test--preflight-path probe-root (cdr entry)))))
              (push (cons symbol observed) symbol-files)
              (unless (equal observed required)
                (epi-test--preflight-record-mismatch
                 (format "GPTel symbol-file for %s" symbol)
                 observed required)))))
      (dolist (entry '((gptel . "gptel.el")
                       (gptel-request . "gptel-request.el")
                       (gptel-make-openai . "gptel-openai.el")))
        (let ((required
               (epi-test--preflight-truename
                (epi-test--preflight-path probe-root (cdr entry)))))
          (push (cons (car entry) nil) symbol-files)
          (epi-test--preflight-record-mismatch
           (format "GPTel symbol-file for %s" (car entry))
           "not inspected because pre-load provenance failed"
           required))))
    (list
     :emacs-version emacs-version
     :org-version
     (if (fboundp 'org-version)
         (org-version)
       "<org-version unavailable>")
     :gptel-version
     (if (boundp 'gptel-version)
         (symbol-value 'gptel-version)
       "<gptel-version unavailable>")
     :transient-version trusted-transient-version
     :compat-version trusted-compat-version
     :source-only t
     :native-jit-disabled
     (not (and (boundp 'native-comp-jit-compilation)
               (symbol-value 'native-comp-jit-compilation)))
     :child-probe t
     :gptel-library-files library-files
     :gptel-source-hashes source-hashes
     :gptel-symbol-files (nreverse symbol-files)))))

(defun epi-test--preflight-read-form-string (string)
  "Read exactly one Lisp form from STRING."
  (unless (stringp string)
    (error "Missing serialized preflight request"))
  (let* ((parsed (read-from-string string))
         (value (car parsed))
         (end (cdr parsed)))
    (unless (string-empty-p (string-trim (substring string end)))
      (error "Trailing data in serialized preflight request"))
    value))

(defun epi-test--preflight-write-form (file value)
  "Write VALUE as one readable Lisp form to FILE."
  (with-temp-file file
    (let ((print-circle t)
          (print-length nil)
          (print-level nil))
      (prin1 value (current-buffer))
      (insert "\n"))))

(defun epi-test--preflight-child-main ()
  "Run the child dependency probe and write its structured response."
  (let* ((result-file (getenv "EPI_TEST_PREFLIGHT_RESULT"))
         (epi-test--preflight-mismatches nil)
         (response
          (condition-case condition
              (let ((options
                     (epi-test--preflight-read-form-string
                      (getenv "EPI_TEST_PREFLIGHT_REQUEST"))))
                (list
                 :report (epi-test--preflight-child-probe options)
                 :mismatches
                 (nreverse epi-test--preflight-mismatches)))
            (error
             (list
              :report nil
              :mismatches
              (append
               (nreverse epi-test--preflight-mismatches)
               (list
                (format
                 "Clean child probe observed: %S required: %S"
                 (error-message-string condition)
                 "successful structured probe"))))))))
    (unless (and result-file (file-name-absolute-p result-file))
      (error "EPI_TEST_PREFLIGHT_RESULT must be an absolute path"))
    (epi-test--preflight-write-form result-file response)))

(defun epi-test--preflight-read-form-file (file)
  "Read exactly one Lisp form from FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (epi-test--preflight-read-form-string (buffer-string))))

(defun epi-test--preflight-child-response
    (emacs gptel-root probe-root extra-load-path load-path-prefix overrides)
  "Launch clean EMACS and return its GPTel probe response."
  (let ((result-file (make-temp-file "epi-preflight-result-"))
        (stderr-file (make-temp-file "epi-preflight-stderr-"))
        (process-environment (copy-sequence process-environment))
        (helper-file
         (epi-test--preflight-truename
          (or (symbol-file 'epi-test-preflight-validate 'defun)
              load-file-name
              buffer-file-name))))
    (unwind-protect
        (progn
          (setenv
           "EPI_TEST_PREFLIGHT_REQUEST"
           (prin1-to-string
            (list :gptel-root gptel-root
                  :gptel-probe-root probe-root
                  :extra-load-path extra-load-path
                  :load-path-prefix load-path-prefix
                  :native-artifact-overrides overrides)))
          (setenv "EPI_TEST_PREFLIGHT_RESULT" result-file)
          (setenv "EMACSLOADPATH" nil)
          (with-temp-buffer
            (let ((status
                   (call-process
                    emacs nil (list (current-buffer) stderr-file) nil
                    "--batch" "-Q"
                    "--eval" "(setq native-comp-jit-compilation nil)"
                    "--load" helper-file
                    "--eval" "(epi-test--preflight-child-main)")))
              (if (and (integerp status) (zerop status))
                  (condition-case condition
                      (epi-test--preflight-read-form-file result-file)
                    (error
                     (epi-test--preflight-record-mismatch
                      "Clean child response"
                      (error-message-string condition)
                      "one readable structured result")
                     nil))
                (let ((stderr
                       (with-temp-buffer
                         (insert-file-contents stderr-file)
                         (string-trim (buffer-string)))))
                  (epi-test--preflight-record-mismatch
                   "Clean child process"
                   (list :status status :stderr stderr
                         :stdout (string-trim (buffer-string)))
                   "exit status 0 and a structured result")
                  nil)))))
      (when (file-exists-p result-file)
        (delete-file result-file))
      (when (file-exists-p stderr-file)
        (delete-file stderr-file)))))

(defun epi-test--preflight-byte-string-less-p (left right)
  "Return non-nil when LEFT's UTF-8 bytes sort before RIGHT's."
  (let* ((left-bytes (encode-coding-string left 'utf-8 t))
         (right-bytes (encode-coding-string right 'utf-8 t))
         (left-length (length left-bytes))
         (right-length (length right-bytes))
         (limit (min left-length right-length))
         (index 0)
         result decided)
    (while (and (< index limit) (not decided))
      (let ((left-byte (aref left-bytes index))
            (right-byte (aref right-bytes index)))
        (unless (= left-byte right-byte)
          (setq result (< left-byte right-byte)
                decided t)))
      (setq index (1+ index)))
    (if decided result (< left-length right-length))))

(defun epi-test--preflight-jcs-vector-files (root)
  "Return bytewise-sorted relative JSON vector paths below ROOT."
  (let (relative-files)
    (dolist (directory '("testdata/input" "testdata/output"))
      (let ((absolute (epi-test--preflight-path root directory)))
        (dolist (file (directory-files-recursively absolute "\\.json\\'"))
          (push (file-relative-name file root) relative-files))))
    (sort relative-files #'epi-test--preflight-byte-string-less-p)))

(defun epi-test--preflight-jcs-vector-digest (root)
  "Return the frozen aggregate digest of JCS vectors below ROOT."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (dolist (relative (epi-test--preflight-jcs-vector-files root))
      (insert (epi-test--preflight-file-sha256
               (epi-test--preflight-path root relative))
              "  "
              (encode-coding-string relative 'utf-8 t)
              "\n"))
    (secure-hash 'sha256 (current-buffer) (point-min) (point-max))))

(defun epi-test--preflight-check-version (report key required exact)
  "Check REPORT version KEY against REQUIRED, using EXACT comparison if set."
  (let ((observed (plist-get report key)))
    (unless (if exact
                (equal observed required)
              (epi-test--preflight-version-at-least-p observed required))
      (epi-test--preflight-record-mismatch
       (format "%s version" key)
       observed
       (if exact required (format "%s or later" required))))))

(defun epi-test--preflight-check-directory (subject directory)
  "Require DIRECTORY to be an existing directory for SUBJECT."
  (unless (and (stringp directory)
               (file-name-absolute-p directory)
               (file-directory-p directory))
    (epi-test--preflight-record-mismatch
     subject directory "an existing absolute directory")))

(cl-defun epi-test-preflight-validate
    (&key emacs gptel-root pi-root jcs-oracle-root extra-load-path
          (scope 'all) gptel-probe-root load-path-prefix
          native-artifact-overrides)
  "Validate the exact dependency roots and return a structured report.

With omitted arguments, read EPI_EMACS, GPTEL_ROOT, PI_ROOT,
JCS_ORACLE_ROOT, and EPI_EXTRA_LOAD_PATH.  SCOPE is either `all' or
`gptel-source-resolution'.  The remaining keywords inject isolated failures
for the preflight contract and are not used by production preflight."
  (let* ((emacs (or emacs (getenv "EPI_EMACS")))
         (gptel-root (or gptel-root (getenv "GPTEL_ROOT")))
         (pi-root (or pi-root (getenv "PI_ROOT")))
         (jcs-oracle-root
          (or jcs-oracle-root (getenv "JCS_ORACLE_ROOT")))
         (extra-load-path
          (epi-test--preflight-normalize-path-list
           (or extra-load-path
               (epi-test--preflight-environment-paths
                "EPI_EXTRA_LOAD_PATH"))))
         (gptel-probe-root (or gptel-probe-root gptel-root))
         (load-path-prefix
          (epi-test--preflight-normalize-path-list load-path-prefix))
         (epi-test--preflight-mismatches nil)
         report child-response)
    (unless (memq scope '(all gptel-source-resolution))
      (epi-test--preflight-record-mismatch
       "Preflight scope" scope "all or gptel-source-resolution"))
    (unless (and (stringp emacs)
                 (file-name-absolute-p emacs)
                 (file-executable-p emacs))
      (epi-test--preflight-record-mismatch
       "EPI_EMACS" emacs "an absolute executable Emacs"))
    (epi-test--preflight-check-directory "GPTEL_ROOT" gptel-root)
    (epi-test--preflight-check-directory
     "GPTel probe root" gptel-probe-root)
    (if extra-load-path
        (dolist (directory extra-load-path)
          (epi-test--preflight-check-directory
           "EPI_EXTRA_LOAD_PATH entry" directory))
      (epi-test--preflight-record-mismatch
       "EPI_EXTRA_LOAD_PATH" nil "one or more declared dependency directories"))
    (dolist (entry native-artifact-overrides)
      (unless (and (stringp (cdr entry)) (file-exists-p (cdr entry)))
        (epi-test--preflight-record-mismatch
         (format "Injected native artifact for %s" (car entry))
         (cdr entry) "an existing test artifact")))
    (when (and (stringp emacs)
               (file-name-absolute-p emacs)
               (file-executable-p emacs)
               (stringp gptel-probe-root)
               (file-directory-p gptel-probe-root))
      (setq child-response
            (epi-test--preflight-child-response
             (epi-test--preflight-truename emacs)
             gptel-root gptel-probe-root extra-load-path load-path-prefix
             native-artifact-overrides))
      (dolist (mismatch (plist-get child-response :mismatches))
        (push mismatch epi-test--preflight-mismatches))
      (setq report (plist-get child-response :report)))
    (if report
        (progn
          (epi-test--preflight-check-version report :emacs-version "30.1" nil)
          (epi-test--preflight-check-version report :org-version "9.7" nil)
          (epi-test--preflight-check-version
           report :gptel-version "0.9.9.5" t)
          (epi-test--preflight-check-version
           report :transient-version "0.7.8" nil)
          (epi-test--preflight-check-version
           report :compat-version "30.1.0.0" nil))
      (epi-test--preflight-record-mismatch
       "Clean child report" nil "a complete dependency report"))
    (when report
      (dolist (entry '((:source-only . t)
                       (:native-jit-disabled . t)
                       (:child-probe . t)))
        (unless (eq (plist-get report (car entry)) (cdr entry))
          (epi-test--preflight-record-mismatch
           (format "Clean child report flag %s" (car entry))
           (plist-get report (car entry)) (cdr entry)))))
    (when (eq scope 'all)
      (epi-test--preflight-check-directory "PI_ROOT" pi-root)
      (epi-test--preflight-check-directory
       "JCS_ORACLE_ROOT" jcs-oracle-root)
      (let ((gptel-commit
             (epi-test--preflight-git-head "GPTel" gptel-root))
            (pi-commit (epi-test--preflight-git-head "Pi" pi-root))
            (jcs-commit
             (epi-test--preflight-git-head "JCS" jcs-oracle-root)))
        (setq report (plist-put report :gptel-commit gptel-commit))
        (setq report (plist-put report :pi-commit pi-commit))
        (setq report (plist-put report :jcs-commit jcs-commit))
        (unless (equal gptel-commit epi-test--preflight-gptel-commit)
          (epi-test--preflight-record-mismatch
           "GPTel commit" gptel-commit epi-test--preflight-gptel-commit))
        (unless (equal pi-commit epi-test--preflight-pi-commit)
          (epi-test--preflight-record-mismatch
           "Pi commit" pi-commit epi-test--preflight-pi-commit))
        (unless (equal jcs-commit epi-test--preflight-jcs-commit)
          (epi-test--preflight-record-mismatch
           "JCS commit" jcs-commit epi-test--preflight-jcs-commit)))
      (setq report
            (plist-put
             report :gptel-source-hashes
             (epi-test--preflight-observe-hashes
              "GPTel" gptel-root epi-test--preflight-gptel-hashes)))
      (setq report
            (plist-put
             report :pi-source-hashes
             (epi-test--preflight-observe-hashes
              "Pi" pi-root epi-test--preflight-pi-hashes)))
      (setq report
            (plist-put
             report :jcs-source-hashes
             (epi-test--preflight-observe-hashes
              "JCS" jcs-oracle-root epi-test--preflight-jcs-hashes)))
      (let ((observed-digest
             (condition-case condition
                 (epi-test--preflight-jcs-vector-digest jcs-oracle-root)
               (error
                (format "<vector digest error: %s>"
                        (error-message-string condition))))))
        (setq report
              (plist-put report :jcs-vector-digest observed-digest))
        (unless (equal observed-digest
                       epi-test--preflight-jcs-vector-digest)
          (epi-test--preflight-record-mismatch
           "JCS vector digest" observed-digest
           epi-test--preflight-jcs-vector-digest))))
    (when epi-test--preflight-mismatches
      (error "Preflight validation failed:\n%s"
             (mapconcat #'identity
                        (nreverse epi-test--preflight-mismatches)
                        "\n")))
    report))

(provide 'epi-test-helper)

;;; epi-test-helper.el ends here
