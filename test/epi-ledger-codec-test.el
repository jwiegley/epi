;;; epi-ledger-codec-test.el --- Canonical Epi ledger codec tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley
;; Keywords: tools

;;; Commentary:

;; Independent byte goldens for JCS and the version-one Org ledger codec.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'subr-x)
(require 'epi-test-helper)
(require 'epi)
(load (expand-file-name "test/fixtures/jcs/appendix-b.el"
                        epi-test-repository-root)
      nil t)

;; The first TDD run deliberately happens before `epi-ledger.el' exists.
(when (locate-library "epi-ledger")
  (require 'epi-ledger))

(defvar epi-golden-skip-main)

(let ((epi-golden-skip-main t))
  (load (expand-file-name "test/generate-jcs-goldens.el"
                          epi-test-repository-root)
        nil t))

(defun epi-test-jcs-unicode-order-object ()
  "Return the RFC 8785 UTF-16 property-order example."
  '(("€" . "Euro Sign")
    ("\r" . "Carriage Return")
    ("דּ" . "Hebrew Letter Dalet With Dagesh")
    ("1" . "One")
    ("😀" . "Emoji: Grinning Face")
    ("" . "Control")
    ("ö" . "Latin Small Letter O With Diaeresis")))

(defun epi-test-jcs-unicode-order-golden ()
  "Return the independent canonical UTF-8 bytes for the order example."
  (encode-coding-string
   "{\"\\r\":\"Carriage Return\",\"1\":\"One\",\"\":\"Control\",\"ö\":\"Latin Small Letter O With Diaeresis\",\"€\":\"Euro Sign\",\"😀\":\"Emoji: Grinning Face\",\"דּ\":\"Hebrew Letter Dalet With Dagesh\"}"
   'utf-8-unix t))

(ert-deftest epi-jcs-rfc-boundaries ()
  (dolist (case '((-0.0 . "0")
                  (0.000001 . "0.000001")
                  (0.0000001 . "1e-7")
                  (1e20 . "100000000000000000000")
                  (1e21 . "1e+21")
                  (9007199254740991 . "9007199254740991")
                  (-9007199254740991 . "-9007199254740991")))
    (should (equal (cdr case)
                   (epi-ledger--jcs-encode (car case))))))

(ert-deftest epi-jcs-sorts-keys-by-utf16 ()
  (should
   (equal (epi-test-jcs-unicode-order-golden)
          (epi-ledger--jcs-encode
           (epi-test-jcs-unicode-order-object)))))

(defun epi-test-ledger--fixture-bytes (relative)
  "Return literal unibyte fixture bytes at RELATIVE."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally
     (expand-file-name (concat "test/fixtures/" relative)
                       epi-test-repository-root))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun epi-test-ledger--condition-code (condition)
  "Return the structured Epi code from CONDITION."
  (plist-get (car (cdr condition)) :code))

(defun epi-test-ledger--header ()
  "Return the fixed header used by the ledger byte fixtures."
  (epi-ledger-seal-header
   :session-id "11111111-1111-4111-8111-111111111111"
   :created-at "2026-07-21T18:42:17-07:00"
   :project-root "/tmp/epi-project/"))

(defun epi-test-ledger--message-draft (&optional text)
  "Return the fixed user-message draft containing TEXT."
  (make-epi-draft
   :id "22222222-2222-4222-8222-222222222222"
   :type 'message
   :at "2026-07-21T18:43:02-07:00"
   :turn "33333333-3333-4333-8333-333333333333"
   :payload
   (list
    (cons "role" "user")
    (cons "content"
          (vector
           (list (cons "type" "text")
                 (cons "text" (or text "Hello, Epi.\n* not Org"))))))))

(defun epi-test-ledger--seal-message (&optional text)
  "Seal the fixed user message containing TEXT."
  (epi-ledger-seal-record
   (epi-test-ledger--message-draft text)
   "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
   1))

(defun epi-test-ledger--parse-frame (bytes &optional sequence)
  "Parse complete frame BYTES at SEQUENCE and return its record."
  (let ((scan (epi-ledger--scan-frame bytes 0 (or sequence 1))))
    (should (eq (plist-get scan :state) 'complete))
    (plist-get scan :record)))

(defun epi-test-ledger--golden-document ()
  "Read and decode the independent JCS golden document."
  (let ((json-object-type 'alist)
        (json-key-type 'string)
        (json-array-type 'vector)
        (json-null epi-json-null)
        (json-false epi-json-false))
    (json-read-from-string
     (decode-coding-string
      (epi-test-ledger--fixture-bytes "jcs/independent-goldens.json")
      'utf-8-unix t))))

(defun epi-test-ledger--decode-json (text)
  "Decode JSON TEXT to canonical string-keyed test data."
  (let ((json-object-type 'alist)
        (json-key-type 'string)
        (json-array-type 'vector)
        (json-null epi-json-null)
        (json-false epi-json-false))
    (json-read-from-string text)))

(ert-deftest epi-jcs-complete-rfc-appendix-b ()
  (should (= 26 (length epi-test-jcs-appendix-b)))
  (dolist (case epi-test-jcs-appendix-b)
    (pcase-let ((`(,hex ,expected ,input) case))
      (let ((value (read input)))
        (if (eq expected :reject)
            (should-error (epi-ledger--jcs-encode value)
                          :type 'epi-ledger-format-error)
          (let ((bytes (encode-coding-string expected 'utf-8-unix t)))
            (should (equal bytes (epi-ledger--jcs-encode value)))
            (should (epi-ledger--jcs-validate-bytes bytes))
            (let ((decoded (epi-ledger--decode-json bytes)))
              (should (equal bytes (epi-ledger--jcs-encode decoded)))
              (when (and (integerp decoded)
                         (> (abs decoded) 9007199254740991))
                (ert-fail "Out-of-safe decoded integer retained"))))))
      (should (= 16 (length hex))))))

(ert-deftest epi-jcs-independent-byte-and-digest-goldens ()
  (let* ((document (epi-test-ledger--golden-document))
         (metadata (alist-get "metadata" document nil nil #'equal))
         (appendix (alist-get "appendix_b" document nil nil #'equal))
         (cases (alist-get "cases" document nil nil #'equal)))
    (should (equal "https://github.com/cyberphone/json-canonicalization"
                   (alist-get "repository" metadata nil nil #'equal)))
    (should (equal "19d51d7fe467d4706a3ff08adf8a748f29fc21e0"
                   (alist-get "commit" metadata nil nil #'equal)))
    (should (equal "f9f498b55c99eefe348c99018ddcfe08efa6f7ff96b9ba9dce4b7090b33c4438"
                   (alist-get "canonicalize_sha256" metadata nil nil
                              #'equal)))
    (should (equal "314898c8f08ed5b14a3f5903b27ec4789ac5dc7fd59a168e72a6d876f192be6f"
                   (alist-get "verify_canonicalization_sha256"
                              metadata nil nil #'equal)))
    (should (equal "v26.5.0"
                   (alist-get "node_version" metadata nil nil #'equal)))
    (should
     (equal
      (vector "node" "--eval" epi-golden--node-driver
              "$JCS_ORACLE_ROOT/node-es6/canonicalize.js")
      (alist-get "canonicalizer_command_argv" metadata nil nil #'equal)))
    (should
     (equal
      ["node" "$JCS_ORACLE_ROOT/node-es6/verify-canonicalization.js"]
      (alist-get "verifier_command_argv" metadata nil nil #'equal)))
    (should (equal "All tests succeeded!"
                   (alist-get "verifier_success_marker"
                              metadata nil nil #'equal)))
    (should (equal "sort-file-blocks-v1"
                   (alist-get "verifier_output_normalization"
                              metadata nil nil #'equal)))
    (should (equal "823c07e7e1b1bbfc903354435b508026e43d2bf3183450a8773cf6cab7668933"
                   (alist-get "shipped_vector_corpus_sha256"
                              metadata nil nil #'equal)))
    (should (equal "7b166d2a3e6ed1e94b91a374f8761ed698bb7d70eb552bbcc9696994db82bc17"
                   (alist-get "driver_sha256" metadata nil nil #'equal)))
    (should (equal (secure-hash 'sha256 epi-golden--node-driver)
                   (alist-get "driver_sha256" metadata nil nil #'equal)))
    (should (equal "ba090f500f1aa2293f10da943318769ba775a60aaaad478cbf420061299b2867"
                   (alist-get "oracle_request_sha256" metadata nil nil
                              #'equal)))
    (should (epi-ledger--hash-p
             (alist-get "normalized_verifier_output_sha256"
                        metadata nil nil #'equal)))
    (should
     (equal
      (secure-hash
       'sha256
       (epi-test-ledger--fixture-bytes "jcs/appendix-b.el"))
      (alist-get "input_sha256" metadata nil nil #'equal)))
    (should (= 26 (length appendix)))
    (cl-mapc
     (lambda (fixture source)
       (pcase-let ((`(,hex ,expected ,_input) source))
         (should (equal hex (alist-get "hex" fixture nil nil #'equal)))
         (if (eq expected :reject)
             (should (equal "reject"
                            (alist-get "outcome" fixture nil nil #'equal)))
           (let ((canonical
                  (alist-get "canonical" fixture nil nil #'equal)))
             (should (equal "canonical"
                            (alist-get "outcome" fixture nil nil #'equal)))
             (should (equal expected canonical))
             (should
              (equal (secure-hash 'sha256 canonical)
                     (alist-get "sha256" fixture nil nil #'equal)))))))
     (append appendix nil) epi-test-jcs-appendix-b)
    (seq-doseq (case cases)
      (let* ((input (alist-get "input" case nil nil #'equal))
             (expected (alist-get "canonical" case nil nil #'equal))
             (digest (alist-get "sha256" case nil nil #'equal))
             (value (epi-test-ledger--decode-json input))
             (actual (epi-ledger--jcs-encode value)))
        (should (equal (encode-coding-string expected 'utf-8-unix t)
                       actual))
        (should (equal digest (secure-hash 'sha256 actual)))))))

(ert-deftest epi-ledger-measures-bounded-nonpreemptible-units ()
  (let ((clock '(10.0 10.25))
        (clock-calls 0)
        trace event
        (original-secure-hash (symbol-function 'secure-hash)))
    (let ((epi-ledger-work-time-budget 0.1)
          (epi-ledger--nonpreemptible-observer
           (lambda (value)
             (setq event value)
             (push 'observer trace))))
      (cl-letf (((symbol-function 'epi--deadline-time)
                 (lambda ()
                   (push (if (zerop clock-calls) 'start 'end) trace)
                   (setq clock-calls (1+ clock-calls))
                   (pop clock)))
                ((symbol-function 'epi--yield)
                 (lambda () (push 'yield trace)))
                ((symbol-function 'secure-hash)
                 (lambda (&rest arguments)
                   (push 'primitive trace)
                   (apply original-secure-hash arguments))))
        (should (= 64 (length (epi-ledger--hash "abc" 'test-hash))))))
    (should (equal '(yield start primitive end yield observer)
                   (nreverse trace)))
    (should (equal '(:kind hash :field test-hash :bytes 3
                            :elapsed 0.25 :outcome success :exceptional t)
                   event)))
  (let ((clock '(20.0 20.05))
        (yields 0)
        event)
    (let ((epi-ledger-work-time-budget 0.1)
          (epi-ledger--nonpreemptible-observer
           (lambda (value) (setq event value))))
      (cl-letf (((symbol-function 'epi--deadline-time)
                 (lambda () (pop clock)))
                ((symbol-function 'epi--yield)
                 (lambda () (setq yields (1+ yields)))))
        (should-not (epi-ledger--decode-json
                     (string-make-unibyte "{}")))))
    (should (= yields 2))
    (should (eq 'decode (plist-get event :kind)))
    (should (eq 'record-json (plist-get event :field)))
    (should (= 2 (plist-get event :bytes)))
    (should (< (abs (- 0.05 (plist-get event :elapsed))) 0.000001))
    (should (eq 'success (plist-get event :outcome)))
    (should-not (plist-get event :exceptional))))

(ert-deftest epi-ledger-decoder-uses-native-parser-without-interning-keys ()
  (let ((key (make-temp-name "epi-decoder-uninterned-key-"))
        (native-calls 0)
        (legacy-calls 0)
        native-arguments
        (original-native (symbol-function 'json-parse-string))
        (original-legacy (symbol-function 'json-read-from-string)))
    (while (intern-soft key)
      (setq key (make-temp-name "epi-decoder-uninterned-key-")))
    (let ((bytes
           (encode-coding-string
            (format
             "{\"%s\":{\"array\":[null,false,true,9007199254740992]}}"
             key)
            'utf-8-unix t)))
      (cl-letf (((symbol-function 'json-parse-string)
                 (lambda (&rest arguments)
                   (setq native-calls (1+ native-calls)
                         native-arguments arguments)
                   (apply original-native arguments)))
                ((symbol-function 'json-read-from-string)
                 (lambda (&rest arguments)
                   (setq legacy-calls (1+ legacy-calls))
                   (apply original-legacy arguments))))
        (let* ((decoded (epi-ledger--decode-json bytes))
               (nested (alist-get key decoded nil nil #'equal))
               (array (alist-get "array" nested nil nil #'equal)))
          (should (stringp (caar decoded)))
          (should (vectorp array))
          (should (eq epi-json-null (aref array 0)))
          (should (eq epi-json-false (aref array 1)))
          (should (eq t (aref array 2)))
          (should (floatp (aref array 3))))))
    (should (= native-calls 1))
    (should (= legacy-calls 0))
    (should (eq 'hash-table
                (plist-get (cdr native-arguments) :object-type)))
    (should (eq 'array
                (plist-get (cdr native-arguments) :array-type)))
    (should-not (intern-soft key))))

(ert-deftest epi-ledger-nonpreemptible-observer-errors-are-inert ()
  (let ((clock '(1.0 1.2))
        (yields 0)
        observed)
    (let ((epi-ledger-work-time-budget 0.1)
          (epi-ledger--nonpreemptible-observer
           (lambda (event)
             (setq observed event)
             (error "observer failure"))))
      (cl-letf (((symbol-function 'epi--deadline-time)
                 (lambda () (pop clock)))
                ((symbol-function 'epi--yield)
                 (lambda () (setq yields (1+ yields)))))
        (should-error
         (epi-ledger--decode-json (string-make-unibyte "{"))
         :type 'epi-ledger-format-error)))
    (should (= yields 2))
    (should (eq 'decode (plist-get observed :kind)))
    (should (eq 'error (plist-get observed :outcome)))
    (should (plist-get observed :exceptional)))
  (let ((clock '(2.0 2.01))
        (epi-ledger--nonpreemptible-observer
         (lambda (_event) (error "observer failure"))))
    (cl-letf (((symbol-function 'epi--deadline-time)
               (lambda () (pop clock)))
              ((symbol-function 'epi--yield) #'ignore))
      (should (= 64 (length (epi-ledger--hash "abc" 'test-hash)))))))

(ert-deftest epi-jcs-generator-requires-positive-shipped-vector-output ()
  (should (epi-golden--verifier-output-valid-p
           "File: values.json\nAll tests succeeded!"))
  (dolist (output '(""
                    "All tests succeeded!\nAll tests succeeded!"
                    "THE TEST ABOVE FAILED!\nAll tests succeeded!"
                    "****** ERRORS: 1 *******"))
    (should-not (epi-golden--verifier-output-valid-p output))))

(ert-deftest epi-jcs-verifier-evidence-normalization-sorts-file-blocks ()
  (cl-labels
      ((output
        (names)
        (concat
         (mapconcat (lambda (name) (format "File: %s\n00" name))
                    names "\n\n")
         "\n\nAll tests succeeded!")))
    (let* ((forward (output epi-golden--verifier-files))
           (backward
            (output (reverse (copy-sequence epi-golden--verifier-files))))
           (normalized (epi-golden--normalize-verifier-output forward)))
      (should (equal normalized
                     (epi-golden--normalize-verifier-output backward)))
      (should (string-suffix-p "\n\nAll tests succeeded!\n" normalized))))
  (should-error
   (epi-golden--normalize-verifier-output
    (concat "File: arrays.json\n00\n\n"
            "File: arrays.json\n00\n\nAll tests succeeded!"))))

(ert-deftest epi-jcs-golden-main-write-gate-is-exact-and-offline ()
  (let ((temporary-root (make-temp-file "epi-golden-gate-" t))
        (old-update (getenv "EPI_UPDATE_GOLDENS"))
        (generated (string-make-unibyte "deterministic-golden\n")))
    (unwind-protect
        (let ((file (expand-file-name
                     "test/fixtures/jcs/independent-goldens.json"
                     temporary-root)))
          (cl-letf (((symbol-value 'epi-golden--repository-root)
                     (file-name-as-directory temporary-root))
                    ((symbol-function 'epi-golden--fixture-bytes)
                     (lambda () generated))
                    ((symbol-function 'process-file)
                     (lambda (&rest _arguments)
                       (ert-fail "Golden write-gate test invoked Node")))
                    ((symbol-function 'call-process-region)
                     (lambda (&rest _arguments)
                       (ert-fail "Golden write-gate test invoked Node"))))
            (dolist (setting '(nil "" "0" "true"))
              (setenv "EPI_UPDATE_GOLDENS" setting)
              (should-error (epi-golden-main))
              (should-not (file-exists-p file)))
            (setenv "EPI_UPDATE_GOLDENS" "1")
            (epi-golden-main)
            (let ((first (epi-golden--literal-bytes file)))
              (should (equal generated first))
              (epi-golden-main)
              (should (equal first (epi-golden--literal-bytes file))))
            (setenv "EPI_UPDATE_GOLDENS" nil)
            (epi-golden-main)
            (setq generated (string-make-unibyte "mismatch\n"))
            (should-error (epi-golden-main))
            (should (equal (string-make-unibyte "deterministic-golden\n")
                           (epi-golden--literal-bytes file)))))
      (setenv "EPI_UPDATE_GOLDENS" old-update)
      (delete-directory temporary-root t))))

(ert-deftest epi-jcs-escapes-only-required-characters ()
  (should
   (equal "\"\\b\\t\\n\\f\\r\\u0000\\u001f\\\"\\\\/\""
          (epi-ledger--jcs-encode
           (concat "\b\t\n\f\r" (string 0 31) "\"\\/")))))

(ert-deftest epi-jcs-rejects-noncanonical-input-values ()
  (let ((cyclic (list nil)))
    (setcar cyclic (cons "cycle" cyclic))
    (dolist
        (value
         (list
          9007199254740992
          -9007199254740992
          (read "1.0e+INF")
          (read "0.0e+NaN")
          'false
          '("not-an-object")
          '(("a" . 1) ("a" . 2))
          `(("bad" . ,(string #xd800)))
          `(("bad" . ,(string #x110000)))
          `(("bad" . ,(unibyte-string #x80)))
          `(("bad" . ,(string-as-multibyte (unibyte-string #xc3))))
          cyclic))
      (should-error (epi-ledger--jcs-encode value)
                    :type 'epi-ledger-format-error)))
  (should (equal "\"ASCII\""
                 (epi-ledger--jcs-encode
                  (string-make-unibyte "ASCII"))))
  (should (equal (encode-coding-string "\"􏿿\"" 'utf-8-unix t)
                 (epi-ledger--jcs-encode (string #x10ffff)))))

(ert-deftest epi-jcs-enforces-live-depth-and-cumulative-item-limits ()
  (let ((epi-json-depth-limit 2)
        (epi-json-item-limit 3))
    (should (equal "[[0]]" (epi-ledger--jcs-encode [[0]])))
    (should-error (epi-ledger--jcs-encode [[[0]]])
                  :type 'epi-limit-exceeded)
    (should (equal "{\"a\":[1],\"b\":2}"
                   (epi-ledger--jcs-encode
                    '(("a" . [1]) ("b" . 2)))))
    (should-error (epi-ledger--jcs-encode
                   '(("a" . [1 2]) ("b" . 3)))
                  :type 'epi-limit-exceeded)))

(ert-deftest epi-jcs-enforces-output-cap-while-streaming-escaped-strings ()
  (let ((original (symbol-function 'epi-ledger--jcs-add))
        (calls 0)
        (largest 0))
    (cl-letf (((symbol-function 'epi-ledger--jcs-add)
               (lambda (state bytes)
                 (setq calls (1+ calls)
                       largest (max largest (length bytes)))
                 (funcall original state bytes))))
      (should (= 6002
                 (length (epi-ledger--jcs-encode
                          (make-string 1000 31) 6002))))
      (should (> calls 0))
      (should (<= largest 4096))
      (setq calls 0
            largest 0)
      (should-error
       (epi-ledger--jcs-encode (make-string 100000 31) 1024)
       :type 'epi-limit-exceeded)
      (should (= calls 0))
      (should (= largest 0)))))

(ert-deftest epi-jcs-proves-default-depth-and-item-boundaries ()
  (let ((epi-json-depth-limit 32)
        (epi-json-item-limit 131072)
        (nested 0))
    (dotimes (_ epi-json-depth-limit)
      (setq nested (vector nested)))
    (let ((exact-depth (epi-ledger--jcs-encode nested)))
      (should (epi-ledger--jcs-validate-bytes exact-depth))
      (setq nested (vector nested))
      (should-error (epi-ledger--jcs-encode nested)
                    :type 'epi-limit-exceeded)
      (should-error
       (epi-ledger--jcs-validate-bytes
        (concat "[" exact-depth "]"))
       :type 'epi-ledger-format-error))
    (let* ((exact-value (make-vector epi-json-item-limit 0))
           (exact-items (epi-ledger--jcs-encode exact-value)))
      (should (epi-ledger--jcs-validate-bytes exact-items))
      (should-error
       (epi-ledger--jcs-encode
        (make-vector (1+ epi-json-item-limit) 0))
       :type 'epi-limit-exceeded)
      (should-error
       (epi-ledger--jcs-validate-bytes
        (concat (substring exact-items 0 -1) ",0]"))
       :type 'epi-ledger-format-error))))

(ert-deftest epi-jcs-lexical-validator-rejects-equivalent-noncanonical-json ()
  (dolist (text '("{\"b\":1,\"a\":2}"
                  "{\"a\":1,\"a\":2}"
                  "\"\\/\""
                  "\"\\u0061\""
                  "1.0"
                  "1e0"
                  "01"
                  " true"))
    (should-error
     (epi-ledger--jcs-validate-bytes (string-make-unibyte text))
     :type 'epi-ledger-format-error))
  (should-error
   (epi-ledger--jcs-validate-bytes
    (concat (string-make-unibyte "\"raw") (unibyte-string 1)
            (string-make-unibyte "control\"")))
   :type 'epi-ledger-format-error)
  (should (epi-ledger--jcs-validate-bytes
           (string-make-unibyte
            "{\"a\":[0,1e-7],\"b\":\"\\n\"}"))))

(ert-deftest epi-jcs-lexical-validator-recognizes-real-number-and-object-prefixes ()
  (dolist (prefix '("{" "{\"a\":0," "-" "1." "1e" "1e+" "1e-"))
    (should (eq 'incomplete
                (plist-get
                 (epi-ledger--jcs-lex-result
                  (string-make-unibyte prefix))
                 :kind)))))

(ert-deftest epi-jcs-object-key-prefix-must-still-be-sortable ()
  (should (eq 'invalid
              (plist-get
               (epi-ledger--jcs-lex-result
                (string-make-unibyte "{\"b\":0,\"a"))
               :kind)))
  (should (eq 'invalid
              (plist-get
               (epi-ledger--jcs-lex-result
                (encode-coding-string "{\"z\":0,\"aé" 'utf-8-unix t))
               :kind)))
  (should (eq 'incomplete
              (plist-get
               (epi-ledger--jcs-lex-result
                (string-make-unibyte "{\"a\":0,\"a"))
               :kind)))
  (should (eq 'invalid
              (plist-get
               (epi-ledger--jcs-lex-result
                (concat (string-make-unibyte "{\"z\":0,\"a")
                        (unibyte-string #xc2)))
               :kind)))
  (should (eq 'incomplete
              (plist-get
               (epi-ledger--jcs-lex-result
                (concat (string-make-unibyte "{\"a\":0,\"z")
                        (unibyte-string #xc2)))
               :kind)))
  (dolist (suffix '("\\" "\\u" "\\u000"))
    (should (eq 'invalid
                (plist-get
                 (epi-ledger--jcs-lex-result
                  (string-make-unibyte (concat "{\"z\":0,\"a" suffix)))
                 :kind))))
  (dolist (suffix '("\\" "\\u" "\\u000"))
    (should (eq 'incomplete
                (plist-get
                 (epi-ledger--jcs-lex-result
                  (string-make-unibyte (concat "{\"a\":0,\"z" suffix)))
                 :kind))))
  (should
   (eq 'invalid
       (plist-get
        (epi-ledger--jcs-lex-result
         (concat (encode-coding-string "{\"a😀\":0,\"a" 'utf-8-unix t)
                 (unibyte-string #xc2)))
        :kind)))
  (should
   (eq 'incomplete
       (plist-get
        (epi-ledger--jcs-lex-result
         (concat (encode-coding-string
                  (concat "{\"a" (string #x80) "\":0,\"a")
                  'utf-8-unix t)
                 (unibyte-string #xc2)))
        :kind)))
  (should (eq 'invalid
              (plist-get
               (epi-ledger--jcs-lex-result
                (string-make-unibyte "{\"a \":0,\"a\\u"))
               :kind)))
  (should (eq 'incomplete
              (plist-get
               (epi-ledger--jcs-lex-result
                (string-make-unibyte "{\"a\\u0000\":0,\"a\\u"))
               :kind))))

(ert-deftest epi-jcs-object-key-capture-batches-decoded-escapes ()
  (let* ((json (string-make-unibyte
                (concat "{\""
                        (apply #'concat (make-list 10000 "\\u0001"))
                        "\":0}")))
         (original-concat (symbol-function 'concat))
         (largest-argument-count 0))
    (cl-letf (((symbol-function 'concat)
               (lambda (&rest strings)
                 (setq largest-argument-count
                       (max largest-argument-count (length strings)))
                 (apply original-concat strings))))
      (should (epi-ledger--jcs-validate-bytes json)))
    (should (< largest-argument-count 100))))

(ert-deftest epi-jcs-object-key-capture-does-not-preallocate-large-scratch ()
  (let* ((json (string-make-unibyte
                (concat "{\""
                        (mapconcat (lambda (index) (format "k%06d\":0,\"" index))
                                   (number-sequence 0 999) "")
                        "z\":0}")))
         (original-make-string (symbol-function 'make-string))
         (largest-scratch 0))
    (cl-letf (((symbol-function 'make-string)
               (lambda (length character &optional multibyte)
                 (when (zerop character)
                   (setq largest-scratch (max largest-scratch length)))
                 (funcall original-make-string length character multibyte))))
      (should (epi-ledger--jcs-validate-bytes json)))
    (should (<= largest-scratch 64))))

(ert-deftest epi-jcs-key-successor-cost-yields-on-long-predecessors ()
  (let* ((previous
          (epi-ledger--utf16be-key (make-string 5000 #xffff)))
         (epi-ledger-work-byte-limit 1000)
         (epi-ledger-work-time-budget 1000.0)
         (yields 0))
    (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
              ((symbol-function 'epi--yield)
               (lambda () (setq yields (1+ yields)))))
      (should (= 15001
                 (epi-ledger--key-successor-content-byte-cost
                  "" previous))))
    (should (= yields 10))))

(ert-deftest epi-jcs-key-successor-prefix-skip-obeys-work-budget ()
  (let* ((prefix (epi-ledger--utf16be-key (make-string 100000 ?a)))
         (previous
          (epi-ledger--utf16be-key (concat (make-string 100000 ?a) "z")))
         (epi-ledger-work-byte-limit 5000)
         (epi-ledger-work-time-budget 1000.0)
         (yields 0))
    (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
              ((symbol-function 'epi--yield)
               (lambda () (setq yields (1+ yields)))))
      (should (= 1
                 (epi-ledger--key-successor-content-byte-cost
                  prefix previous))))
    (should (>= yields 40))))

(ert-deftest epi-jcs-large-object-key-postscan-obeys-work-budget ()
  (let* ((prefix (make-string 100000 ?a))
         (json
          (string-make-unibyte
           (concat "{\"" prefix "\":0,\"" prefix "b\":0}")))
         (epi-ledger-work-byte-limit 5000)
         (epi-ledger-work-time-budget 1000.0)
         (yields 0))
    (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
              ((symbol-function 'epi--yield)
               (lambda () (setq yields (1+ yields)))))
      (should (epi-ledger--jcs-validate-bytes json)))
    (should (>= yields 80))))

(defun epi-test-ledger--buffering-physical-maximum (source thunk)
  "Return maximum physical work between yields while THUNK handles SOURCE."
  (let* ((epi-ledger-work-byte-limit 64)
         (epi-ledger-work-time-budget 1000.0)
         (original-aref (symbol-function 'aref))
         (original-aset (symbol-function 'aset))
         (original-substring (symbol-function 'substring))
         (original-store-substring (symbol-function 'store-substring))
         (original-setcdr (symbol-function 'setcdr))
         (original-compare-strings (symbol-function 'compare-strings))
         (since-yield 0)
         (maximum 0))
    (cl-labels
        ((physical
          (amount)
          (setq since-yield (+ since-yield amount)
                maximum (max maximum since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum (max maximum since-yield)
                         since-yield 0)))
                ((symbol-function 'aref)
                 (lambda (sequence index)
                   (prog1 (funcall original-aref sequence index)
                     (when (eq sequence source)
                       (physical 1)))))
                ((symbol-function 'aset)
                 (lambda (sequence index value)
                   (prog1 (funcall original-aset sequence index value)
                     (when (stringp sequence)
                       (physical 1)))))
                ((symbol-function 'substring)
                 (lambda (sequence &optional start end)
                   (let ((result
                          (funcall original-substring sequence start end)))
                     (when (and (stringp sequence)
                                (not (eq sequence source)))
                       (physical (length result)))
                     result)))
                ((symbol-function 'store-substring)
                 (lambda (string index object
                                 &optional object-start object-end)
                   (prog1
                       (funcall original-store-substring
                                string index object object-start object-end)
                     (physical
                      (- (or object-end (length object))
                         (or object-start 0))))))
                ((symbol-function 'setcdr)
                 (lambda (cell value)
                   (prog1 (funcall original-setcdr cell value)
                     (physical 1))))
                ((symbol-function 'compare-strings)
                 (lambda (left left-start left-end
                          right right-start right-end &optional ignore-case)
                   (prog1
                       (funcall original-compare-strings
                                left left-start left-end
                                right right-start right-end ignore-case)
                     (physical
                      (min (- left-end left-start)
                           (- right-end right-start)))))))
        (setq since-yield 0 maximum 0)
        (funcall thunk)))
    (max maximum since-yield)))

(defun epi-test-ledger--copy-scan-physical-maximum (source thunk)
  "Return maximum copy and scan work between yields in THUNK for SOURCE."
  (let* ((epi-ledger-work-byte-limit 64)
         (epi-ledger-work-time-budget 1000.0)
         (original-aref (symbol-function 'aref))
         (original-substring (symbol-function 'substring))
         (original-string-match-p (symbol-function 'string-match-p))
         (since-yield 0)
         (maximum 0))
    (cl-labels
        ((physical
          (amount)
          (setq since-yield (+ since-yield amount)
                maximum (max maximum since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum (max maximum since-yield)
                         since-yield 0)))
                ((symbol-function 'aref)
                 (lambda (sequence index)
                   (prog1 (funcall original-aref sequence index)
                     (when (eq sequence source)
                       (physical 1)))))
                ((symbol-function 'substring)
                 (lambda (sequence &optional start end)
                   (let ((result
                          (funcall original-substring sequence start end)))
                     (when (stringp sequence)
                       (physical (length result)))
                     result)))
                ((symbol-function 'string-match-p)
                 (lambda (regexp string &optional start)
                   (prog1
                       (funcall original-string-match-p regexp string start)
                     (physical (- (length string) (or start 0)))))))
        (setq since-yield 0 maximum 0)
        (funcall thunk)))
    (max maximum since-yield)))

(defun epi-test-ledger--string-run-physical-maximum (source thunk)
  "Return maximum SOURCE scan-and-copy work between yields in THUNK."
  (let* ((epi-ledger-work-byte-limit 1000)
         (epi-ledger-work-time-budget 1000.0)
         (original-aref (symbol-function 'aref))
         (original-substring
          (symbol-function 'substring-no-properties))
         (since-yield 0)
         (maximum 0))
    (cl-labels
        ((physical
          (amount)
          (setq since-yield (+ since-yield amount)
                maximum (max maximum since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum (max maximum since-yield)
                         since-yield 0)))
                ((symbol-function 'aref)
                 (lambda (sequence index)
                   (prog1 (funcall original-aref sequence index)
                     (when (eq sequence source)
                       (physical 1)))))
                ((symbol-function 'substring-no-properties)
                 (lambda (string &optional from to)
                   (let ((result
                          (funcall original-substring string from to)))
                     (when (eq string source)
                       (physical (string-bytes result)))
                     result))))
        (setq since-yield 0 maximum 0)
        (funcall thunk)))
    (max maximum since-yield)))

(defun epi-test-ledger--list-sort-physical-maximum (thunk)
  "Return maximum modeled list-sort work between yields in THUNK."
  (let* ((epi-ledger-work-byte-limit 64)
         (epi-ledger-work-time-budget 1000.0)
         (original-sort (symbol-function 'sort))
         (since-yield 0)
         (maximum 0))
    (cl-labels
        ((physical
          (amount)
          (setq since-yield (+ since-yield amount)
                maximum (max maximum since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum (max maximum since-yield)
                         since-yield 0)))
                ((symbol-function 'sort)
                 (lambda (sequence predicate)
                   (if (not (listp sequence))
                       (funcall original-sort sequence predicate)
                     (let ((items (length sequence)))
                       ;; Emacs converts a list to a temporary vector before
                       ;; the first comparison, then writes every cell back.
                       (physical (* 2 items))
                       (prog1 (funcall original-sort sequence predicate)
                         (physical items)))))))
        (setq since-yield 0 maximum 0)
        (funcall thunk)))
    (max maximum since-yield)))

(defun epi-test-ledger--vector-sort-physical-maximum (thunk)
  "Return maximum modeled vector-sort movement between THUNK's yields."
  (let* ((epi-ledger-work-byte-limit 64)
         (epi-ledger-work-time-budget 1000.0)
         (original-sort (symbol-function 'sort))
         (since-yield 0)
         (maximum 0))
    (cl-labels
        ((physical
          (amount)
          (setq since-yield (+ since-yield amount)
                maximum (max maximum since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum (max maximum since-yield)
                         since-yield 0)))
                ((symbol-function 'sort)
                 (lambda (sequence predicate)
                   (prog1 (funcall original-sort sequence predicate)
                     (when (vectorp sequence)
                       ;; A descending Timsort run is reversed after its last
                       ;; predicate call, without another Lisp-visible yield.
                       (physical (length sequence)))))))
        (setq since-yield 0 maximum 0)
        (funcall thunk)))
    (max maximum since-yield)))

(defun epi-test-ledger--concat-aggregate-physical-maximum (thunk)
  "Return maximum modeled aggregate `concat' work between THUNK's yields."
  (let* ((epi-ledger-work-byte-limit 64)
         (epi-ledger-work-time-budget 1000.0)
         (original-concat (symbol-function 'concat))
         (since-yield 0)
         (maximum 0))
    (cl-labels
        ((physical
          (amount)
          (setq since-yield (+ since-yield amount)
                maximum (max maximum since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum (max maximum since-yield)
                         since-yield 0)))
                ((symbol-function 'concat)
                 (lambda (&rest strings)
                   (let ((result (apply original-concat strings)))
                     ;; `apply' walks its final list, and `concat' scans every
                     ;; argument before copying the output bytes.
                     (physical (+ (* 2 (length strings)) (length result)))
                     result))))
        (setq since-yield 0 maximum 0)
        (funcall thunk)))
    (max maximum since-yield)))

(defun epi-test-ledger--raw-input-physical-work (source limit thunk)
  "Return physical work metrics for THUNK reading SOURCE under LIMIT."
  (let* ((epi-ledger-work-byte-limit limit)
         (epi-ledger-work-time-budget 1000.0)
         (original-aref (symbol-function 'aref))
         (original-substring (symbol-function 'substring))
         (since-yield 0)
         (maximum 0)
         (reads 0)
         (copies 0))
    (cl-labels
        ((physical
          (amount)
          (setq since-yield (+ since-yield amount)
                maximum (max maximum since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum (max maximum since-yield)
                         since-yield 0)))
                ((symbol-function 'aref)
                 (lambda (sequence index)
                   (prog1 (funcall original-aref sequence index)
                     (when (eq sequence source)
                       (setq reads (1+ reads))
                       (physical 1)))))
                ((symbol-function 'substring)
                 (lambda (sequence &optional start end)
                   (let ((result
                          (funcall original-substring sequence start end)))
                     (when (eq sequence source)
                       (setq copies (+ copies (length result)))
                       (physical (length result)))
                     result))))
        (setq since-yield 0 maximum 0 reads 0 copies 0)
        (funcall thunk)))
    (list :maximum (max maximum since-yield)
          :reads reads :copies copies)))

(defun epi-test-ledger--trusted-copy-physical-maximum (value source)
  "Return maximum modeled work copying VALUE whose large string is SOURCE."
  (let* ((epi-ledger-work-byte-limit 64)
         (epi-ledger-work-time-budget 1000.0)
         (original-substring (symbol-function 'substring-no-properties))
         (original-aset (symbol-function 'aset))
         (original-setcdr (symbol-function 'setcdr))
         (since-yield 0)
         (maximum 0))
    (cl-labels
        ((physical
          (amount)
          (setq since-yield (+ since-yield amount)
                maximum (max maximum since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum (max maximum since-yield)
                         since-yield 0)))
                ((symbol-function 'substring-no-properties)
                 (lambda (string &optional from to)
                   (let ((result
                          (funcall original-substring string from to)))
                     (when (eq string source)
                       (physical (string-bytes result)))
                     result)))
                ((symbol-function 'aset)
                 (lambda (sequence index item)
                   (prog1 (funcall original-aset sequence index item)
                     (when (vectorp sequence) (physical 1)))))
                ((symbol-function 'setcdr)
                 (lambda (cell new-cdr)
                   (prog1 (funcall original-setcdr cell new-cdr)
                     (physical 1)))))
        (setq since-yield 0 maximum 0)
        (epi-ledger--trusted-value-copy value)))
    (max maximum since-yield)))

(defun epi-test-ledger--renderer-composite-physical-maximum (thunk)
  "Return maximum large composite primitive work between THUNK's yields."
  (let* ((epi-ledger-work-byte-limit 1000)
         (epi-ledger-work-time-budget 1000.0)
         (original-concat (symbol-function 'concat))
         (original-mapconcat (symbol-function 'mapconcat))
         (original-format (symbol-function 'format))
         (original-encode (symbol-function 'encode-coding-string))
         (since-yield 0)
         (maximum 0))
    (cl-labels
        ((physical-result
          (result)
          (let ((amount (and (stringp result) (string-bytes result))))
            (when (and amount (> amount 100))
              (setq since-yield (+ since-yield amount)
                    maximum (max maximum since-yield))))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum (max maximum since-yield)
                         since-yield 0)))
                ((symbol-function 'concat)
                 (lambda (&rest strings)
                   (let ((result (apply original-concat strings)))
                     (physical-result result)
                     result)))
                ((symbol-function 'mapconcat)
                 (lambda (function sequence separator)
                   (let ((result
                          (funcall original-mapconcat
                                   function sequence separator)))
                     (physical-result result)
                     result)))
                ((symbol-function 'format)
                 (lambda (format-string &rest objects)
                   (let ((result
                          (apply original-format format-string objects)))
                     (physical-result result)
                     result)))
                ((symbol-function 'encode-coding-string)
                 (lambda (string coding-system &optional nocopy buffer)
                   (let ((result
                          (funcall original-encode
                                   string coding-system nocopy buffer)))
                     (physical-result result)
                     result))))
        (setq since-yield 0 maximum 0)
        (funcall thunk)))
    (max maximum since-yield)))

(defun epi-test-ledger--sort-tail-physical-maximum (function)
  "Return maximum chunk comparison and tail work for FUNCTION."
  (let* ((epi-ledger-work-byte-limit 64)
         (epi-ledger-work-time-budget 1000.0)
         (left (list (make-string 64 ?a)))
         (right (list (make-string 64 ?a)))
         (original-compare (symbol-function 'compare-strings))
         (original-cdr (symbol-function 'cdr))
         (since-yield 0)
         (maximum 0))
    (cl-labels
        ((physical
          (amount)
          (setq since-yield (+ since-yield amount)
                maximum (max maximum since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum (max maximum since-yield)
                         since-yield 0)))
                ((symbol-function 'compare-strings)
                 (lambda (a as ae b bs be &optional ignore-case)
                   (prog1
                       (funcall original-compare
                                a as ae b bs be ignore-case)
                     (physical (min (- ae as) (- be bs))))))
                ((symbol-function 'cdr)
                 (lambda (cell)
                   (prog1 (funcall original-cdr cell)
                     (when (or (eq cell left) (eq cell right))
                       (physical 1))))))
        (setq since-yield 0 maximum 0)
        (funcall function left right)))
    (max maximum since-yield)))

(defun epi-test-ledger--post-key-helper-physical-maximum (thunk)
  "Return maximum modeled work when THUNK's key helper fills its slice."
  (let* ((epi-ledger-work-byte-limit 64)
         (epi-ledger-work-time-budget 1000.0)
         (original-key-helper
          (symbol-function 'epi-ledger--utf16be-key-chunks))
         (original-cons (symbol-function 'cons))
         (since-yield 0)
         (maximum 0)
         awaiting-cons)
    (cl-labels
        ((physical
          (amount)
          (setq since-yield (+ since-yield amount)
                maximum (max maximum since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum (max maximum since-yield)
                         since-yield 0)))
                ((symbol-function 'epi-ledger--utf16be-key-chunks)
                 (lambda (value &optional work)
                   (let ((result (funcall original-key-helper value work)))
                     (when work
                       (epi-ledger--work-charge
                        work epi-ledger-work-byte-limit)
                       (setq since-yield epi-ledger-work-byte-limit
                             awaiting-cons t))
                     result)))
                ((symbol-function 'cons)
                 (lambda (car cdr)
                   (prog1 (funcall original-cons car cdr)
                     (when awaiting-cons
                       (setq awaiting-cons nil)
                       (physical 1))))))
        (setq since-yield 0 maximum 0 awaiting-cons nil)
        (funcall thunk)
        (should-not awaiting-cons)))
    (max maximum since-yield)))

(defun epi-test-ledger--empty-key-fallback-physical-work (bytes)
  "Return maximum work and fallback count validating empty-key BYTES."
  (let* ((epi-ledger-work-byte-limit 1)
         (epi-ledger-work-time-budget 1000.0)
         (original-aref (symbol-function 'aref))
         (original-work-cons (symbol-function 'epi-ledger--work-cons))
         (since-yield 0)
         (maximum 0)
         (fallbacks 0))
    (cl-labels
        ((physical
          ()
          (setq since-yield (1+ since-yield)
                maximum (max maximum since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum (max maximum since-yield)
                         since-yield 0)))
                ((symbol-function 'aref)
                 (lambda (sequence index)
                   (prog1 (funcall original-aref sequence index)
                     (when (eq sequence bytes) (physical)))))
                ((symbol-function 'epi-ledger--work-cons)
                 (lambda (car cdr work)
                   (prog1 (funcall original-work-cons car cdr work)
                     (when (and (stringp car)
                                (string-empty-p car)
                                (null cdr))
                       (setq fallbacks (1+ fallbacks))
                       (physical))))))
        (setq since-yield 0 maximum 0 fallbacks 0)
        (should (epi-ledger--jcs-validate-bytes bytes))))
    (list :maximum (max maximum since-yield) :fallbacks fallbacks)))

(defun epi-test-ledger--list-helper-physical-maximum
    (source thunk &optional capture-utf16-chunks)
  "Return maximum physical work for THUNK over SOURCE's cons cells.
When CAPTURE-UTF16-CHUNKS is non-nil, also track the chunk list returned by
`epi-ledger--utf16be-key-chunks'."
  (let* ((epi-ledger-work-byte-limit 64)
         (epi-ledger-work-time-budget 1000.0)
         (cells (make-hash-table :test #'eq))
         (original-car (symbol-function 'car))
         (original-cdr (symbol-function 'cdr))
         (original-aset (symbol-function 'aset))
         (original-setcdr (symbol-function 'setcdr))
         (original-work-cons (symbol-function 'epi-ledger--work-cons))
         (original-key-chunks
          (symbol-function 'epi-ledger--utf16be-key-chunks))
         (tail source)
         (since-yield 0)
         (maximum 0))
    (while (consp tail)
      (puthash tail t cells)
      (setq tail (funcall original-cdr tail)))
    (cl-labels
        ((physical
          ()
          (setq since-yield (1+ since-yield)
                maximum (max maximum since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum (max maximum since-yield)
                         since-yield 0)))
                ((symbol-function 'car)
                 (lambda (cell)
                   (prog1 (funcall original-car cell)
                     (when (gethash cell cells) (physical)))))
                ((symbol-function 'cdr)
                 (lambda (cell)
                   (prog1 (funcall original-cdr cell)
                     (when (gethash cell cells) (physical)))))
                ((symbol-function 'aset)
                 (lambda (sequence index value)
                   (prog1 (funcall original-aset sequence index value)
                     (when (vectorp sequence) (physical)))))
                ((symbol-function 'setcdr)
                 (lambda (cell value)
                   (prog1 (funcall original-setcdr cell value)
                     (physical))))
                ((symbol-function 'epi-ledger--work-cons)
                 (lambda (car cdr work)
                   (prog1 (funcall original-work-cons car cdr work)
                     (physical))))
                ((symbol-function 'epi-ledger--utf16be-key-chunks)
                 (lambda (value &optional work)
                   (let ((chunks (funcall original-key-chunks value work)))
                     (when capture-utf16-chunks
                       (let ((chunk-tail chunks))
                         (while (consp chunk-tail)
                           (puthash chunk-tail t cells)
                           (setq chunk-tail
                                 (funcall original-cdr chunk-tail)))))
                     chunks))))
        (setq since-yield 0 maximum 0)
        (funcall thunk)))
    (max maximum since-yield)))

(defun epi-test-ledger--decode-postscan-physical-maximum (bytes)
  "Return maximum decoded scan and validity-read work for BYTES."
  (let* ((epi-ledger-work-byte-limit 1)
         (epi-ledger-work-time-budget 1000.0)
         (original-cons (symbol-function 'cons))
         (original-cdr (symbol-function 'cdr))
         (original-aref (symbol-function 'aref))
         target decoded
         (since-yield 0)
         (maximum 0))
    (cl-labels
        ((physical
          ()
          (setq since-yield (1+ since-yield)
                maximum (max maximum since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum (max maximum since-yield)
                         since-yield 0)))
                ((symbol-function 'cons)
                 (lambda (car-value cdr-value)
                   (let ((cell
                          (funcall original-cons car-value cdr-value)))
                     (when (and (stringp car-value)
                                (memq cdr-value '(t nil)))
                       (setq target cell decoded car-value))
                     cell)))
                ((symbol-function 'aref)
                 (lambda (sequence index)
                   (prog1 (funcall original-aref sequence index)
                     (when (eq sequence decoded) (physical)))))
                ((symbol-function 'cdr)
                 (lambda (cell)
                   (prog1 (funcall original-cdr cell)
                     (when (eq cell target) (physical))))))
        (setq since-yield 0 maximum 0)
        (should (equal "a" (epi-ledger--decode-utf8 bytes 'test)))))
    (max maximum since-yield)))

(defun epi-test-ledger--line-postcopy-physical-maximum
    (bytes post-return-work thunk)
  "Return maximum line work, adding POST-RETURN-WORK after THUNK."
  (let* ((epi-ledger-work-byte-limit 64)
         (epi-ledger-work-time-budget 1000.0)
         (original-aref (symbol-function 'aref))
         (original-substring (symbol-function 'substring))
         (since-yield 0)
         (maximum 0))
    (cl-labels
        ((physical
          (amount)
          (setq since-yield (+ since-yield amount)
                maximum (max maximum since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum (max maximum since-yield)
                         since-yield 0)))
                ((symbol-function 'aref)
                 (lambda (sequence index)
                   (prog1 (funcall original-aref sequence index)
                     (when (eq sequence bytes) (physical 1)))))
                ((symbol-function 'substring)
                 (lambda (sequence &optional start end)
                   (let ((result
                          (funcall original-substring sequence start end)))
                     (when (eq sequence bytes)
                       (physical (length result)))
                     result))))
        (setq since-yield 0 maximum 0)
        (funcall thunk)
        (physical post-return-work)))
    (max maximum since-yield)))

(defun epi-test-ledger--line-caller-physical-maximum (thunk)
  "Return maximum tuple work between yields in production caller THUNK."
  (let* ((epi-ledger-work-byte-limit 1)
         (epi-ledger-work-time-budget 1000.0)
         (original-line (symbol-function 'epi-ledger--line-at))
         (original-car (symbol-function 'car))
         (original-cdr (symbol-function 'cdr))
         outer inner
         (tuple-reads 0)
         (since-yield 0)
         (maximum 0))
    (cl-labels
        ((physical
          ()
          (setq since-yield (1+ since-yield)
                maximum (max maximum since-yield)))
         (tuple-cell-p
          (cell)
          (and outer (or (eq cell outer) (eq cell inner))))
         (after-read
          (cell)
          (when (tuple-cell-p cell)
            (physical)
            (setq tuple-reads (1+ tuple-reads))
            (when (= tuple-reads 3)
              (setq outer nil inner nil)))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum (max maximum since-yield)
                         since-yield 0)))
                ((symbol-function 'epi-ledger--line-at)
                 (lambda (&rest arguments)
                   (let ((result (apply original-line arguments)))
                     (setq outer result
                           inner (funcall original-cdr result)
                           tuple-reads 0
                           since-yield 1)
                     result)))
                ((symbol-function 'car)
                 (lambda (cell)
                   (prog1 (funcall original-car cell)
                     (after-read cell))))
                ((symbol-function 'cdr)
                 (lambda (cell)
                   (prog1 (funcall original-cdr cell)
                     (after-read cell)))))
        (setq since-yield 0 maximum 0)
        (funcall thunk)))
    (max maximum since-yield)))

(defun epi-test-ledger--header-collector-physical-work (bytes)
  "Return maximum work and value-collection count parsing header BYTES."
  (let* ((epi-ledger-work-byte-limit 1)
         (epi-ledger-work-time-budget 1000.0)
         (original-decode-coding (symbol-function 'decode-coding-string))
         (original-decode (symbol-function 'epi-ledger--decode-utf8))
         (original-aref (symbol-function 'aref))
         (original-cons (symbol-function 'cons))
         decoded collect-next
         (since-yield 0)
         (maximum 0)
         (collects 0))
    (cl-labels
        ((physical
          ()
          (setq since-yield (1+ since-yield)
                maximum (max maximum since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum (max maximum since-yield)
                         since-yield 0)))
                ((symbol-function 'decode-coding-string)
                 (lambda (&rest arguments)
                   (let ((result (apply original-decode-coding arguments)))
                     (when (stringp result) (setq decoded result))
                     result)))
                ((symbol-function 'aref)
                 (lambda (sequence index)
                   (prog1 (funcall original-aref sequence index)
                     (when (eq sequence decoded) (physical)))))
                ((symbol-function 'epi-ledger--decode-utf8)
                 (lambda (&rest arguments)
                   (prog1 (apply original-decode arguments)
                     (setq collect-next t))))
                ((symbol-function 'cons)
                 (lambda (car cdr)
                   (prog1 (funcall original-cons car cdr)
                     (when collect-next
                       (physical)
                       (setq collects (1+ collects)
                             collect-next nil))))))
        (setq since-yield 0 maximum 0 collects 0)
        (should (epi-header-p (epi-ledger-parse-header bytes)))))
    (list :maximum (max maximum since-yield) :collects collects)))

(defun epi-test-ledger--drawer-collector-physical-work
    (bytes expected-id expected-type timestamp)
  "Return work metrics parsing drawer BYTES containing TIMESTAMP."
  (let* ((epi-ledger-work-byte-limit 64)
         (epi-ledger-work-time-budget 1000.0)
         (original-copy
          (symbol-function 'epi-ledger--copy-owned-unibyte-range))
         (original-puthash (symbol-function 'puthash))
         (original-cons (symbol-function 'cons))
         (since-yield 0)
         (maximum 0)
         active
         (collector-conses 0))
    (cl-labels
        ((physical
          (amount)
          (setq since-yield (+ since-yield amount)
                maximum (max maximum since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum (max maximum since-yield)
                         since-yield 0)))
                ((symbol-function 'epi-ledger--copy-owned-unibyte-range)
                 (lambda (source start end field &optional work)
                   (let ((result
                          (funcall original-copy
                                   source start end field work)))
                     (when (and (eq field 'drawer-value)
                                (equal result timestamp))
                       (physical (length result))
                       (setq active t))
                     result)))
                ((symbol-function 'puthash)
                 (lambda (key value table)
                   (prog1 (funcall original-puthash key value table)
                     (when active (physical 1)))))
                ((symbol-function 'cons)
                 (lambda (car cdr)
                   (prog1 (funcall original-cons car cdr)
                     (when active
                       (physical 1)
                       (setq collector-conses (1+ collector-conses))
                       (when (= collector-conses 2)
                         (setq active nil)))))))
        (setq since-yield 0 maximum 0 collector-conses 0 active nil)
        (let ((result
               (epi-ledger--parse-drawer
                bytes 0 0 expected-id expected-type)))
          (should (= (cadr result) (length bytes))))))
    (list :maximum (max maximum since-yield)
          :collector-conses collector-conses)))

(ert-deftest epi-jcs-key-capture-buffering-obeys-physical-cadence ()
  (let ((bytes
         (string-make-unibyte
          (concat "{\"" (make-string 2000 ?a) "\":0}"))))
    (should
     (<= (epi-test-ledger--buffering-physical-maximum
          bytes
          (lambda ()
            (should (epi-ledger--jcs-validate-bytes bytes))))
         64))))

(ert-deftest epi-jcs-utf16-key-buffering-obeys-physical-cadence ()
  (let ((value (make-string 2000 ?a)))
    (should
     (<= (epi-test-ledger--buffering-physical-maximum
          value
          (lambda ()
            (should (> (length (epi-ledger--utf16be-key-chunks value)) 1))))
         64))))

(ert-deftest epi-jcs-unibyte-validation-scan-obeys-physical-cadence ()
  (let ((value (string-make-unibyte (make-string 2000 ?a))))
    (should
     (<= (epi-test-ledger--copy-scan-physical-maximum
          value
          (lambda ()
            (should (epi-ledger--canonical-string-p value))))
         64))))

(ert-deftest epi-jcs-unibyte-length-scan-obeys-physical-cadence ()
  (let ((value (string-make-unibyte (make-string 2000 ?a))))
    (should
     (<= (epi-test-ledger--copy-scan-physical-maximum
          value
          (lambda ()
            (should (= (+ 2 (length value))
                       (epi-ledger--jcs-string-byte-length value 10000)))))
         64))))

(ert-deftest epi-jcs-timestamp-fraction-scan-obeys-physical-cadence ()
  (let ((value (string-make-unibyte
                (concat (make-string 2000 ?1) "Z"))))
    (should
     (<= (epi-test-ledger--copy-scan-physical-maximum
          value
          (lambda ()
            (should (= 2000
                       (epi-ledger--timestamp-fraction-zone-start
                        value 0 (length value))))))
         64))))

(ert-deftest epi-jcs-copy-scan-cap-one-fallback-obeys-physical-cadence ()
  (let ((canonical (string-make-unibyte "plain"))
        (length-value (string-make-unibyte "value"))
        (fraction (string-make-unibyte "111Z")))
    (dolist
        (case
         (list
          (cons canonical
                (lambda ()
                  (should (epi-ledger--canonical-string-p canonical))))
          (cons length-value
                (lambda ()
                  (should (= 7
                             (epi-ledger--jcs-string-byte-length
                              length-value 100)))))
          (cons fraction
                (lambda ()
                  (should (= 3
                             (epi-ledger--timestamp-fraction-zone-start
                              fraction 0 (length fraction))))))))
      (let ((metrics
             (epi-test-ledger--raw-input-physical-work
              (car case) 1 (cdr case))))
        (should (= (length (car case)) (plist-get metrics :reads)))
        (should (= 0 (plist-get metrics :copies)))
        (should (<= (plist-get metrics :maximum) 1))))))

(ert-deftest epi-jcs-string-run-copy-obeys-physical-cadence ()
  (let ((value (make-string 600 ?a)))
    (should
     (<= (epi-test-ledger--string-run-physical-maximum
          value
         (lambda ()
            (should (stringp (epi-ledger--jcs-encode value)))))
         1000))))

(ert-deftest epi-jcs-trusted-recursive-copy-obeys-physical-cadence ()
  (let ((vector-source (make-string 64 ?v))
        (object-source (make-string 64 ?o)))
    (should
     (<= (epi-test-ledger--trusted-copy-physical-maximum
          (vector vector-source) vector-source)
         64))
    (should
     (<= (epi-test-ledger--trusted-copy-physical-maximum
          `(("a" . "x") ("b" . ,object-source)) object-source)
         64))))

(ert-deftest epi-ledger-renderers-avoid-unbounded-composite-copies ()
  (let* ((header
          (epi-ledger-seal-header
           :session-id "11111111-1111-4111-8111-111111111111"
           :created-at "2026-07-21T18:42:17-07:00"
           :project-root (concat "/" (make-string 600 ?p) "/")))
         (draft (epi-test-ledger--message-draft))
         (_timestamp
          (setf (epi-draft-at draft)
                (concat "2026-07-21T18:43:02."
                        (make-string 600 ?7) "Z")))
         (record
          (epi-ledger-seal-record
           draft
           "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
           1)))
    (dolist (thunk
             (list (lambda () (should (stringp
                                       (epi-ledger-render-header header))))
                   (lambda () (should (stringp
                                       (epi-ledger-render-record record))))))
      (should
       (<= (epi-test-ledger--renderer-composite-physical-maximum thunk)
           1000)))))

(ert-deftest epi-jcs-object-collection-charges-before-cooperative-sort ()
  (let* ((object (cl-loop repeat 200 collect (cons "" 0)))
         (epi-ledger-work-byte-limit 64)
         (epi-ledger-work-time-budget 1000.0)
         (original-sort
          (symbol-function 'epi-ledger--work-sort-list-to-vector))
         (yields 0)
         pre-sort-yields
         reached-sort)
    (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
              ((symbol-function 'epi--yield)
               (lambda () (setq yields (1+ yields))))
              ((symbol-function 'epi-ledger--work-sort-list-to-vector)
               (lambda (&rest arguments)
                 (setq reached-sort t
                       pre-sort-yields yields)
                 (apply original-sort arguments))))
      (should-error (epi-ledger--jcs-encode object nil t)
                    :type 'epi-ledger-format-error))
    (should reached-sort)
    (should (> pre-sort-yields 0))))

(ert-deftest epi-jcs-key-collectors-reserve-after-helper-yields ()
  (let ((object '(("a" . 0))))
    (dolist
        (thunk
         (list (lambda ()
                 (should (equal '("a")
                                (epi-ledger--object-keys object 'test))))
               (lambda ()
                 (should (eq object
                             (epi-ledger--preflight-canonical-value object))))
               (lambda ()
                 (should (stringp (epi-ledger--jcs-encode object nil t))))))
      (should
       (<= (epi-test-ledger--post-key-helper-physical-maximum thunk) 64)))))

(ert-deftest epi-jcs-sort-comparators-reserve-chunk-tail-reads ()
  (dolist (function '(epi-ledger--sort-key-compare
                      epi-ledger--sort-key-prefix-relation))
    (should
     (<= (epi-test-ledger--sort-tail-physical-maximum function) 64))))

(ert-deftest epi-jcs-empty-key-fallback-cons-is-freshly-reserved ()
  (let ((metrics
         (epi-test-ledger--empty-key-fallback-physical-work
          (string-make-unibyte "{\"\":0}"))))
    (should (= 1 (plist-get metrics :fallbacks)))
    (should (<= (plist-get metrics :maximum) 1))))

(ert-deftest epi-jcs-wide-object-spine-uses-no-growing-hash-table ()
  (let* ((object
          (cl-loop for index below 512
                   collect (cons (format "k%04d" index) index)))
         (original-puthash (symbol-function 'puthash))
         (puthash-calls 0))
    (cl-letf (((symbol-function 'puthash)
               (lambda (key value table)
                 (setq puthash-calls (1+ puthash-calls))
                 (funcall original-puthash key value table))))
      (should (= 512 (length (epi-ledger--object-keys object 'wide-spine)))))
    (should (= 0 puthash-calls))))

(ert-deftest epi-jcs-list-helpers-reserve-each-physical-operation ()
  (dolist (name '(nreverse reverse append-one list-to-vector
                           concat-empty member-miss utf16-key))
    (let* ((source
            (pcase name
              ('concat-empty (make-list 100 ""))
              ('utf16-key (make-string 3200 ?a))
              (_ (number-sequence 1 100))))
           (thunk
            (pcase name
              ('nreverse
               (lambda ()
                 (epi-ledger--work-nreverse-list
                  source (epi-ledger--new-work-state))))
              ('reverse
               (lambda ()
                 (epi-ledger--work-reverse-list
                  source (epi-ledger--new-work-state))))
              ('append-one
               (lambda ()
                 (epi-ledger--work-append-one
                  source 101 (epi-ledger--new-work-state))))
              ('list-to-vector
               (lambda ()
                 (epi-ledger--work-list-to-vector
                  source (epi-ledger--new-work-state) 'test)))
              ('concat-empty
               (lambda ()
                 (epi-ledger--work-concat-chunks
                  source 0 (epi-ledger--new-work-state) 'test)))
              ('member-miss
               (lambda ()
                 (epi-ledger--work-member-p
                  101 source (epi-ledger--new-work-state))))
              ('utf16-key
               (lambda () (epi-ledger--utf16be-key source)))))
           (maximum
            (epi-test-ledger--list-helper-physical-maximum
             source thunk (eq name 'utf16-key))))
      (should (<= maximum 64)))))

(ert-deftest epi-ledger-decoded-validity-read-precedes-cooperative-scan ()
  (should
   (<= (epi-test-ledger--decode-postscan-physical-maximum
        (string-make-unibyte "a"))
       1)))

(ert-deftest epi-ledger-line-results-reserve-postcopy-conses ()
  (let ((complete
         (string-make-unibyte (concat (make-string 64 ?a) "\n")))
        (incomplete (string-make-unibyte (make-string 64 ?a))))
    (should
     (<= (epi-test-ledger--line-postcopy-physical-maximum
          complete 2
          (lambda ()
            (let ((result (epi-ledger--line-at complete 0 65)))
              (should (= 2 (length result)))
              (should (= 64 (length (car result)))))))
         64))
    (should
     (<= (epi-test-ledger--line-postcopy-physical-maximum
          incomplete 3
          (lambda ()
            (should-error
             (epi-ledger--line-at
              incomplete 0 65 (lambda (_fragment) t))
             :type 'end-of-file)))
         64))))

(ert-deftest epi-ledger-all-schema-record-types-render-unibyte ()
  (dolist (descriptor (epi-ledger-schema-descriptor))
    (let* ((draft (epi-test-ledger--valid-draft (car descriptor)))
           (record
            (epi-ledger-seal-record
             draft
             "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
             1))
           (frame (epi-ledger-render-record record)))
      (should-not (multibyte-string-p frame)))))

(ert-deftest epi-ledger-production-line-callers-reserve-tuple-reads ()
  (let ((header (epi-test-ledger--fixture-bytes "ledger/header.org"))
        (frame (epi-ledger-render-record (epi-test-ledger--seal-message))))
    (dolist
        (thunk
         (list (lambda ()
                 (should (epi-header-p (epi-ledger-parse-header header))))
               (lambda ()
                 (should
                  (eq 'complete
                      (plist-get (epi-ledger--scan-frame frame 0 1)
                                 :state))))))
      (should
       (<= (epi-test-ledger--line-caller-physical-maximum thunk) 1)))))

(ert-deftest epi-ledger-header-value-collector-is-freshly-reserved ()
  (let* ((header
          (epi-ledger-seal-header
           :session-id "11111111-1111-4111-8111-111111111111"
           :created-at "2026-07-21T18:42:17-07:00"
           :project-root "/tmp/epi-review/"))
         (metrics
          (epi-test-ledger--header-collector-physical-work
           (epi-ledger-render-header header))))
    (should (= 7 (plist-get metrics :collects)))
    (should (<= (plist-get metrics :maximum) 1))))

(ert-deftest epi-ledger-drawer-collector-is-freshly-reserved ()
  (let* ((id "22222222-2222-4222-8222-222222222222")
         (timestamp
          (concat "2026-01-01T00:00:00." (make-string 43 ?1) "Z"))
         (hash (make-string 64 ?a))
         (bytes
          (string-make-unibyte
           (concat ":EPI_ID: " id "\n"
                   ":EPI_TYPE: message\n"
                   ":EPI_SCHEMA: 1\n"
                   ":EPI_AT: " timestamp "\n"
                   ":EPI_TURN: " id "\n"
                   ":EPI_PREV_SHA256: " hash "\n"
                   ":EPI_RECORD_SHA256: " hash "\n"
                   ":END:\n")))
         (metrics
          (epi-test-ledger--drawer-collector-physical-work
           bytes id "message" timestamp)))
    (should (= 2 (plist-get metrics :collector-conses)))
    (should (<= (plist-get metrics :maximum) 64))))

(ert-deftest epi-jcs-list-sort-setup-and-writeback-obey-physical-cadence ()
  (let ((object
         (cl-loop for index below 200
                  collect (cons (format "k%03d" index) index))))
    (dolist (thunk
             (list (lambda ()
                     (should (eq object
                                 (epi-ledger--preflight-canonical-value
                                  object))))
                   (lambda ()
                     (should (stringp
                              (epi-ledger--jcs-encode object nil t))))))
      (should
       (<= (epi-test-ledger--list-sort-physical-maximum thunk) 64)))))

(ert-deftest epi-jcs-vector-sort-movement-obeys-physical-cadence ()
  (should
   (<= (epi-test-ledger--vector-sort-physical-maximum
        (lambda ()
          (let* ((work (epi-ledger--new-work-state))
                 (values (number-sequence 200 1 -1))
                 (ordered
                  (epi-ledger--work-sort-list-to-vector
                   values #'< work 'test-order)))
            (should (= 1 (aref ordered 0)))
            (should (= 200 (aref ordered 199))))))
       64)))

(ert-deftest epi-jcs-chunk-flattening-obeys-physical-cadence ()
  (dolist (thunk
           (list (lambda ()
                   (should (stringp
                            (epi-ledger--jcs-encode
                             (vconcat (make-list 20 0)) nil t))))
                 (lambda ()
                   (should (stringp
                            (epi-ledger--jcs-encode
                             (make-string 20 ?\n) nil t))))))
    (should
     (<= (epi-test-ledger--concat-aggregate-physical-maximum thunk) 64))))

(ert-deftest epi-jcs-raw-lexer-reads-each-input-byte-at-most-once ()
  (let* ((bytes
          (string-make-unibyte
           (concat "[" (mapconcat #'identity (make-list 200 "true") ",")
                   "]")))
         (metrics
          (epi-test-ledger--raw-input-physical-work
           bytes 64
           (lambda ()
             (should (epi-ledger--jcs-validate-bytes bytes))))))
    (should (= (length bytes) (plist-get metrics :reads)))
    (should (<= (plist-get metrics :maximum) 64))))

(ert-deftest epi-jcs-number-copy-obeys-raw-input-physical-cadence ()
  (let* ((bytes (string-make-unibyte "1.2345678901234567e+100"))
         (metrics
          (epi-test-ledger--raw-input-physical-work
           bytes 32
           (lambda ()
             (should (epi-ledger--jcs-validate-bytes bytes))))))
    (should (= (length bytes) (plist-get metrics :reads)))
    (should (= (length bytes) (plist-get metrics :copies)))
    (should (<= (plist-get metrics :maximum) 32))))

(ert-deftest epi-jcs-physical-key-work-never-crosses-the-byte-cadence ()
  (let* ((prefix (make-string 20000 ?a))
         (bytes
          (string-make-unibyte
           (concat "{\"" prefix "0\":0,\"" prefix "1\":0}")))
         (epi-ledger-work-byte-limit 1000)
         (epi-ledger-work-time-budget 1000.0)
         (original-byte (symbol-function 'epi-ledger--lex-byte))
         (original-compare (symbol-function 'compare-strings))
         (since-yield 0)
         (maximum-between-yields 0))
    (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
              ((symbol-function 'epi--yield)
               (lambda ()
                 (setq maximum-between-yields
                       (max maximum-between-yields since-yield)
                       since-yield 0)))
              ((symbol-function 'epi-ledger--lex-byte)
               (lambda (state)
                 (prog1 (funcall original-byte state)
                   (setq since-yield (1+ since-yield)))))
              ((symbol-function 'compare-strings)
               (lambda (left left-start left-end
                        right right-start right-end &optional ignore-case)
                 (prog1
                     (funcall original-compare
                              left left-start left-end
                              right right-start right-end ignore-case)
                   (setq since-yield
                         (+ since-yield
                            (min (- left-end left-start)
                                 (- right-end right-start))))))))
      (should (epi-ledger--jcs-validate-bytes bytes)))
    (setq maximum-between-yields
          (max maximum-between-yields since-yield))
    (should (<= maximum-between-yields epi-ledger-work-byte-limit))))

(ert-deftest epi-jcs-ordinary-run-is-reserved-before-physical-scanning ()
  (let ((value (make-string 200 ?a))
        (epi-ledger-work-byte-limit 1000)
        (epi-ledger-work-time-budget 1000.0)
        (original-aref (symbol-function 'aref))
        (since-yield 801)
        (maximum-between-yields 0)
        (yields 0))
    (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
              ((symbol-function 'epi--yield)
               (lambda ()
                 (setq maximum-between-yields
                       (max maximum-between-yields since-yield)
                       since-yield 0
                       yields (1+ yields))))
              ((symbol-function 'aref)
               (lambda (sequence index)
                 (prog1 (funcall original-aref sequence index)
                   (when (eq sequence value)
                     (setq since-yield (1+ since-yield)))))))
      (let* ((work (epi-ledger--new-work-state))
             (state
              (epi-ledger--make-jcs-state
               :chunks nil :bytes 0 :items 0
               :active (make-hash-table :test #'eq)
               :max-bytes 4096 :work work :trusted t)))
        (epi-ledger--work-charge work 801)
        (epi-ledger--jcs-write-string value state)))
    (setq maximum-between-yields
          (max maximum-between-yields since-yield))
    (should (> yields 0))
    (should (<= maximum-between-yields epi-ledger-work-byte-limit))))

(ert-deftest epi-jcs-key-capture-finalization-shares-lexical-work-cursor ()
  (let* ((bytes (string-make-unibyte
                 (concat "{\"" (make-string 2000 ?a) "\":0}")))
         (epi-ledger-work-byte-limit 64)
         (epi-ledger-work-time-budget 1000.0)
         (original-byte (symbol-function 'epi-ledger--lex-byte))
         (original-nreverse (symbol-function 'nreverse))
         (original-setcdr (symbol-function 'setcdr))
         (since-yield 0)
         (maximum-between-yields 0))
    (cl-labels
        ((physical-work
          (amount)
          (setq since-yield (+ since-yield amount)
                maximum-between-yields
                (max maximum-between-yields since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum-between-yields
                         (max maximum-between-yields since-yield)
                         since-yield 0)))
                ((symbol-function 'epi-ledger--lex-byte)
                 (lambda (state)
                   (prog1 (funcall original-byte state)
                     (physical-work 1))))
                ((symbol-function 'nreverse)
                 (lambda (list)
                   (let ((amount (length list)))
                     (prog1 (funcall original-nreverse list)
                       (when (> amount 10)
                         (physical-work amount))))))
                ((symbol-function 'setcdr)
                 (lambda (cell new-cdr)
                   (prog1 (funcall original-setcdr cell new-cdr)
                     (physical-work 1)))))
        (should (epi-ledger--jcs-validate-bytes bytes))))
    (setq maximum-between-yields
          (max maximum-between-yields since-yield))
    (should (<= maximum-between-yields epi-ledger-work-byte-limit))))

(ert-deftest epi-jcs-encoder-chunk-reversal-shares-work-cursor ()
  (let ((value (vconcat (make-list 200 0)))
        (epi-ledger-work-byte-limit 64)
        (epi-ledger-work-time-budget 1000.0)
        (original-add (symbol-function 'epi-ledger--jcs-add))
        (original-nreverse (symbol-function 'nreverse))
        (original-setcdr (symbol-function 'setcdr))
        (since-yield 0)
        (maximum-between-yields 0))
    (cl-labels
        ((physical-work
          (amount)
          (setq since-yield (+ since-yield amount)
                maximum-between-yields
                (max maximum-between-yields since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum-between-yields
                         (max maximum-between-yields since-yield)
                         since-yield 0)))
                ((symbol-function 'epi-ledger--jcs-add)
                 (lambda (state bytes)
                   (prog1 (funcall original-add state bytes)
                     (physical-work (length bytes)))))
                ((symbol-function 'nreverse)
                 (lambda (list)
                   (let ((amount (length list)))
                     (prog1 (funcall original-nreverse list)
                       (when (> amount 10)
                         (physical-work amount))))))
                ((symbol-function 'setcdr)
                 (lambda (cell new-cdr)
                   (prog1 (funcall original-setcdr cell new-cdr)
                     (physical-work 1)))))
        (should (stringp (epi-ledger--jcs-encode value)))))
    (setq maximum-between-yields
          (max maximum-between-yields since-yield))
    (should (<= maximum-between-yields epi-ledger-work-byte-limit))))

(ert-deftest epi-jcs-closed-object-list-walks-share-work-cursor ()
  (let* ((object
          (cl-loop for index below 200
                   collect (cons (format "k%03d" index) index)))
         (required '("k000"))
         (optional (mapcar #'car (cdr object)))
         (epi-ledger-work-byte-limit 64)
         (epi-ledger-work-time-budget 1000.0)
         (original-equal (symbol-function 'equal))
         (original-member (symbol-function 'member))
         (original-nreverse (symbol-function 'nreverse))
         (original-setcdr (symbol-function 'setcdr))
         (since-yield 0)
         (maximum-between-yields 0))
    (cl-labels
        ((physical-work
          (amount)
          (setq since-yield (+ since-yield amount)
                maximum-between-yields
                (max maximum-between-yields since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum-between-yields
                         (max maximum-between-yields since-yield)
                         since-yield 0)))
                ((symbol-function 'equal)
                 (lambda (left right)
                   (prog1 (funcall original-equal left right)
                     (when (and (stringp left) (stringp right))
                       (physical-work 1)))))
                ((symbol-function 'member)
                 (lambda (item list)
                   (let ((tail list)
                         (steps 0)
                         found)
                     (while (and tail (not found))
                       (setq steps (1+ steps)
                             found (funcall original-equal item (car tail))
                             tail (cdr tail)))
                     (prog1 (funcall original-member item list)
                       (physical-work steps)))))
                ((symbol-function 'nreverse)
                 (lambda (list)
                   (let ((amount (length list)))
                     (prog1 (funcall original-nreverse list)
                       (when (> amount 10)
                         (physical-work amount))))))
                ((symbol-function 'setcdr)
                 (lambda (cell new-cdr)
                   (prog1 (funcall original-setcdr cell new-cdr)
                     (physical-work 1)))))
        (should-not
         (epi-ledger--closed-object
          object required optional "wide-object"))))
    (setq maximum-between-yields
          (max maximum-between-yields since-yield))
    (should (<= maximum-between-yields epi-ledger-work-byte-limit))))

(ert-deftest epi-jcs-multibyte-read-is-reserved-before-physical-work ()
  (let* ((value (string #x1f600))
         (epi-ledger-work-byte-limit 64)
         (epi-ledger-work-time-budget 1000.0)
         (work (epi-ledger--new-work-state))
         (original-aref (symbol-function 'aref))
         (since-yield epi-ledger-work-byte-limit)
         (maximum-between-yields 0)
         (yields 0))
    (cl-letf (((symbol-function 'epi--yield) #'ignore))
      (epi-ledger--work-charge work epi-ledger-work-byte-limit))
    (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
              ((symbol-function 'epi--yield)
               (lambda ()
                 (setq maximum-between-yields
                       (max maximum-between-yields since-yield)
                       since-yield 0
                       yields (1+ yields))))
              ((symbol-function 'aref)
               (lambda (sequence index)
                 (prog1 (funcall original-aref sequence index)
                   (when (eq sequence value)
                     (setq since-yield (1+ since-yield)))))))
      (let ((epi-ledger--canonical-value-preflighted t))
        (should (equal (list (unibyte-string #xd8 #x3d #xde #x00))
                       (epi-ledger--utf16be-key-chunks value work)))))
    (setq maximum-between-yields
          (max maximum-between-yields since-yield))
    (should (> yields 0))
    (should (<= maximum-between-yields epi-ledger-work-byte-limit))))

(ert-deftest epi-jcs-backward-key-read-is-reserved-before-physical-work ()
  (let* ((chunk (unibyte-string 0 ?a))
         (previous (list chunk))
         (epi-ledger-work-byte-limit 64)
         (epi-ledger-work-time-budget 1000.0)
         (work (epi-ledger--new-work-state))
         (original-aref (symbol-function 'aref))
         (original-cooperative-reverse
          (and (fboundp 'epi-ledger--work-reverse-list)
               (symbol-function 'epi-ledger--work-reverse-list)))
         (since-yield epi-ledger-work-byte-limit)
         (maximum-between-yields 0)
         (yields 0))
    (cl-letf (((symbol-function 'epi--yield) #'ignore))
      (epi-ledger--work-charge work epi-ledger-work-byte-limit))
    (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
              ((symbol-function 'epi--yield)
               (lambda ()
                 (setq maximum-between-yields
                       (max maximum-between-yields since-yield)
                       since-yield 0
                       yields (1+ yields))))
              ((symbol-function 'epi-ledger--work-reverse-list)
               (lambda (list state)
                 (let ((result
                        (if original-cooperative-reverse
                            (funcall original-cooperative-reverse list state)
                          (reverse list))))
                   (epi-ledger--work-charge
                    state epi-ledger-work-byte-limit)
                   (setq since-yield epi-ledger-work-byte-limit)
                   result)))
              ((symbol-function 'aref)
               (lambda (sequence index)
                 (prog1 (funcall original-aref sequence index)
                   (when (eq sequence chunk)
                     (setq since-yield (1+ since-yield)))))))
      (should (= 1 (epi-ledger--key-successor-content-byte-cost
                    nil previous work))))
    (setq maximum-between-yields
          (max maximum-between-yields since-yield))
    (should (> yields 0))
    (should (<= maximum-between-yields epi-ledger-work-byte-limit))))

(ert-deftest epi-jcs-lex-peek-reserves-raw-input-before-reading ()
  (let* ((bytes (string-make-unibyte "0"))
         (epi-ledger-work-byte-limit 1000)
         (epi-ledger-work-time-budget 1000.0)
         (work (epi-ledger--new-work-state))
         (original-aref (symbol-function 'aref))
         (since-yield 999)
         (maximum-between-yields 0)
         (yields 0))
    (cl-letf (((symbol-function 'epi--yield) #'ignore))
      (epi-ledger--work-charge work 999))
    (let ((epi-ledger--operation-work-state work))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum-between-yields
                         (max maximum-between-yields since-yield)
                         since-yield 0
                         yields (1+ yields))))
                ((symbol-function 'aref)
                 (lambda (sequence index)
                   (prog1 (funcall original-aref sequence index)
                     (when (eq sequence bytes)
                       (setq since-yield (1+ since-yield)))))))
        (should (eq 'complete
                    (plist-get (epi-ledger--jcs-lex-result bytes) :kind)))))
    (setq maximum-between-yields
          (max maximum-between-yields since-yield))
    (should (> yields 0))
    (should (<= maximum-between-yields epi-ledger-work-byte-limit))))

(ert-deftest epi-jcs-partial-key-escape-reread-reserves-before-aref ()
  (let* ((bytes (string-make-unibyte "{\"a\":0,\"z\\u000"))
         (epi-ledger-work-byte-limit 1)
         (epi-ledger-work-time-budget 1000.0)
         (original-aref (symbol-function 'aref))
         (original-maximum
          (symbol-function 'epi-ledger--lex-partial-escape-maximum))
         (target-reread nil)
         (since-yield 0)
         (maximum-between-yields 0)
         (yields 0))
    (cl-labels
        ((physical-work
          ()
          (setq since-yield (1+ since-yield)
                maximum-between-yields
                (max maximum-between-yields since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum-between-yields
                         (max maximum-between-yields since-yield)
                         since-yield 0
                         yields (1+ yields))))
                ((symbol-function 'aref)
                 (lambda (sequence index)
                   (prog1 (funcall original-aref sequence index)
                     (when (and target-reread (eq sequence bytes))
                       (physical-work)))))
                ((symbol-function 'epi-ledger--lex-partial-escape-maximum)
                 (lambda (state start)
                   (setq since-yield epi-ledger-work-byte-limit
                         target-reread t)
                   (unwind-protect (funcall original-maximum state start)
                     (setq target-reread nil)))))
        (should (eq 'incomplete
                    (plist-get (epi-ledger--jcs-lex-result bytes) :kind)))))
    (setq maximum-between-yields
          (max maximum-between-yields since-yield))
    (should (> yields 0))
    (should (<= maximum-between-yields epi-ledger-work-byte-limit))))

(ert-deftest epi-jcs-partial-key-utf8-rereads-reserve-before-aref ()
  (let* ((bytes
          (concat (string-make-unibyte "{\"a\":0,\"z")
                  (unibyte-string #xe2 #x82)))
         (epi-ledger-work-byte-limit 1)
         (epi-ledger-work-time-budget 1000.0)
         (original-aref (symbol-function 'aref))
         (original-maximum
          (symbol-function 'epi-ledger--lex-partial-utf8-maximum))
         (original-minimum
          (symbol-function 'epi-ledger--lex-partial-utf8-minimum))
         (target-reread nil)
         (since-yield 0)
         (maximum-between-yields 0)
         (yields 0))
    (cl-labels
        ((physical-work
          ()
          (setq since-yield (1+ since-yield)
                maximum-between-yields
                (max maximum-between-yields since-yield))))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda ()
                   (setq maximum-between-yields
                         (max maximum-between-yields since-yield)
                         since-yield 0
                         yields (1+ yields))))
                ((symbol-function 'aref)
                 (lambda (sequence index)
                   (prog1 (funcall original-aref sequence index)
                     (when (and target-reread (eq sequence bytes))
                       (physical-work)))))
                ((symbol-function 'epi-ledger--lex-partial-utf8-maximum)
                 (lambda (state start)
                   (setq since-yield epi-ledger-work-byte-limit
                         target-reread t)
                   (unwind-protect (funcall original-maximum state start)
                     (setq target-reread nil))))
                ((symbol-function 'epi-ledger--lex-partial-utf8-minimum)
                 (lambda (state start)
                   (setq since-yield epi-ledger-work-byte-limit
                         target-reread t)
                   (unwind-protect (funcall original-minimum state start)
                     (setq target-reread nil)))))
        (should (eq 'incomplete
                    (plist-get (epi-ledger--jcs-lex-result bytes) :kind)))))
    (setq maximum-between-yields
          (max maximum-between-yields since-yield))
    (should (> yields 0))
    (should (<= maximum-between-yields epi-ledger-work-byte-limit))))

(ert-deftest epi-jcs-large-sort-key-tail-copy-is-measured ()
  (let* ((previous (epi-ledger--utf16be-key (make-string 200 ?a)))
         (prefix (substring previous 0 2))
         (epi-ledger-work-byte-limit 64)
         (epi-ledger-work-time-budget 1000.0)
         events)
    (let ((epi-ledger--nonpreemptible-observer
           (lambda (event) (push event events))))
      (should (= 1 (epi-ledger--key-successor-content-byte-cost
                    prefix previous))))
    (should
     (seq-some
      (lambda (event)
        (and (eq 'copy (plist-get event :kind))
             (eq 'sort-key-tail (plist-get event :field))
             (= (- (length previous) (length prefix))
                (plist-get event :bytes))))
      events))))

(ert-deftest epi-ledger-utf8-roundtrip-comparison-is-measured ()
  (let ((bytes (string-make-unibyte (make-string 200 ?a)))
        (original-equal (symbol-function 'equal))
        (original-run (symbol-function 'epi-ledger--run-nonpreemptible))
        (inside-measured-unit nil)
        comparison-seen comparison-inside)
    (cl-letf
        (((symbol-function 'epi-ledger--run-nonpreemptible)
          (lambda (kind field size thunk)
            (funcall original-run kind field size
                     (lambda ()
                       (let ((old inside-measured-unit))
                         (setq inside-measured-unit t)
                         (unwind-protect (funcall thunk)
                           (setq inside-measured-unit old)))))))
         ((symbol-function 'equal)
          (lambda (left right)
            (when (or (eq left bytes) (eq right bytes))
              (setq comparison-seen t
                    comparison-inside inside-measured-unit))
            (funcall original-equal left right))))
      (should (= (length bytes)
                 (length (epi-ledger--decode-utf8 bytes 'test-field)))))
    (should comparison-seen)
    (should comparison-inside)))

(ert-deftest epi-ledger-path-validation-is-one-measured-owned-unit ()
  (let ((path (concat "/tmp/" (make-string 200 ?p) "/"))
        events)
    (let ((epi-ledger--nonpreemptible-observer
           (lambda (event) (push event events))))
      (should-not
       (epi-ledger--require-canonical-directory path 'project-root)))
    (should
     (seq-some
      (lambda (event)
        (and (eq 'validate (plist-get event :kind))
             (eq 'project-root (plist-get event :field))
             (= (string-bytes path) (plist-get event :bytes))))
      events))))

(ert-deftest epi-jcs-canonical-multibyte-scan-reads-each-character-once ()
  (let ((value (string-to-multibyte (make-string 2000 ?a)))
        (epi-ledger-work-byte-limit 1000)
        (epi-ledger-work-time-budget 1000.0)
        (original-aref (symbol-function 'aref))
        (since-yield 0)
        (maximum-between-yields 0)
        (reads 0))
    (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
              ((symbol-function 'epi--yield)
               (lambda ()
                 (setq maximum-between-yields
                       (max maximum-between-yields since-yield)
                       since-yield 0)))
              ((symbol-function 'aref)
               (lambda (sequence index)
                 (prog1 (funcall original-aref sequence index)
                   (when (eq sequence value)
                     (setq reads (1+ reads)
                           since-yield (1+ since-yield)))))))
      (should (epi-ledger--canonical-string-p value)))
    (setq maximum-between-yields
          (max maximum-between-yields since-yield))
    (should (= (length value) reads))
    (should (<= maximum-between-yields epi-ledger-work-byte-limit))))

(ert-deftest epi-jcs-duplicate-check-avoids-equal-hash-collision-chains ()
  (let* ((keys
          (cl-loop for index below 200
                   collect
                   (let ((key (make-string 100 ?a)))
                     (aset key 80 (+ 32 (% index 90)))
                     (aset key 81 (+ 32 (/ index 90)))
                     key)))
         (hash (sxhash-equal (car keys)))
         (object (mapcar (lambda (key) (cons key 0)) keys))
         (original-make-hash-table (symbol-function 'make-hash-table))
         (equal-key-tables 0))
    (should (cl-every (lambda (key) (= hash (sxhash-equal key))) keys))
    (should (= (length keys) (length (delete-dups (copy-sequence keys)))))
    (cl-letf (((symbol-function 'make-hash-table)
               (lambda (&rest arguments)
                 (when (eq (plist-get arguments :test) #'equal)
                   (setq equal-key-tables (1+ equal-key-tables)))
                 (apply original-make-hash-table arguments))))
      (let ((snapshot (epi-ledger--snapshot-canonical-value object)))
        (should (epi-ledger--preflight-canonical-value snapshot))
        (should (stringp (epi-ledger--jcs-encode snapshot)))
        (should (= (length keys)
                   (length
                    (epi-ledger--object-keys snapshot 'collision))))))
    (should (= 0 equal-key-tables))))

(ert-deftest epi-jcs-cooperative-key-sort-still-rejects-duplicates ()
  (let ((duplicate-a (copy-sequence "duplicate"))
        (duplicate-b (copy-sequence "duplicate")))
    (should-not (eq duplicate-a duplicate-b))
    (dolist (operation
             (list
              (lambda ()
                (epi-ledger--object-keys
                 (list (cons duplicate-a 0) (cons duplicate-b 1))
                 'duplicate))
              (lambda ()
                (epi-ledger--preflight-canonical-value
                 (list (cons duplicate-a 0) (cons duplicate-b 1))))
              (lambda ()
                (epi-ledger--jcs-encode
                 (list (cons duplicate-a 0) (cons duplicate-b 1))))))
      (let ((condition
             (should-error (funcall operation)
                           :type 'epi-ledger-format-error)))
        (should (eq 'duplicate-key
                    (epi-test-ledger--condition-code condition))))))
  (let ((object
         (cl-loop repeat 200
                  collect (cons (copy-sequence "") 0)))
        (epi-ledger-work-byte-limit 1)
        (epi-ledger-work-time-budget 1000.0)
        (yields 0))
    (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
              ((symbol-function 'epi--yield)
               (lambda () (setq yields (1+ yields)))))
      (let ((condition
             (should-error
              (epi-ledger--object-keys object 'duplicate-empty)
              :type 'epi-ledger-format-error)))
        (should (eq 'duplicate-key
                    (epi-test-ledger--condition-code condition)))))
    (should (> yields 0))))

(ert-deftest epi-ledger-large-drawer-equality-is-measured ()
  (let* ((at (concat "2026-07-21T18:43:02."
                     (make-string 200 ?7) "Z"))
         (record
          (epi-ledger--make-record
           :id "11111111-1111-4111-8111-111111111111"
           :type 'message :schema 1 :at at
           :parent nil :target nil
           :turn "22222222-2222-4222-8222-222222222222"
           :operation nil
           :previous-hash (make-string 64 ?a)
           :hash (make-string 64 ?b)))
         (drawer
          `(("EPI_ID" . "11111111-1111-4111-8111-111111111111")
            ("EPI_TYPE" . "message")
            ("EPI_SCHEMA" . "1")
            ("EPI_AT" . ,at)
            ("EPI_TURN" . "22222222-2222-4222-8222-222222222222")
            ("EPI_PREV_SHA256" . ,(make-string 64 ?a))
            ("EPI_RECORD_SHA256" . ,(make-string 64 ?b))))
         (epi-ledger-work-byte-limit 64)
         events)
    (let ((epi-ledger--nonpreemptible-observer
           (lambda (event) (push event events))))
      (should-not
       (epi-ledger--validate-drawer-agreement
        "message" "11111111-1111-4111-8111-111111111111"
        drawer record)))
    (should
     (seq-some
      (lambda (event)
        (and (eq 'compare (plist-get event :kind))
             (eq 'drawer-agreement (plist-get event :field))
             (= (string-bytes at) (plist-get event :bytes))))
      events))))

(ert-deftest epi-jcs-positive-tiny-work-caps-handle-unicode-and-escapes ()
  (let* ((value `(("😀" . ,(concat "€" (string 0)))))
         (expected
          (encode-coding-string "{\"😀\":\"€\\u0000\"}" 'utf-8-unix t)))
    (dolist (cap '(1 2))
      (let ((epi-ledger-work-byte-limit cap)
            (epi-ledger-work-time-budget 1000.0))
        (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0)))
          (should (equal expected (epi-ledger--jcs-encode value)))
          (should (epi-ledger--jcs-validate-bytes expected)))))))

(ert-deftest epi-jcs-lexical-clock-checks-are-bounded-by-checkpoint-cadence ()
  (let ((bytes (concat "\"" (make-string 1000000 ?a) "\""))
        (clock-calls 0))
    (cl-letf (((symbol-function 'epi--deadline-time)
               (lambda ()
                 (setq clock-calls (1+ clock-calls))
                 0.0)))
      (should (epi-ledger--jcs-validate-bytes bytes)))
    (should (< clock-calls 300))))

(ert-deftest epi-jcs-lexical-byte-limit-remains-exact-between-clock-checkpoints ()
  (let ((bytes (concat "\"" (make-string 10000 ?a) "\""))
        (epi-ledger-work-byte-limit 5000)
        (epi-ledger-work-time-budget 1000.0)
        (yields 0))
    (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
              ((symbol-function 'epi--yield)
               (lambda () (setq yields (1+ yields)))))
      (should (epi-ledger--jcs-validate-bytes bytes)))
    (should (= yields 2))))

(ert-deftest epi-jcs-lexical-validator-consumes-raw-string-bytes-once ()
  (let* ((bytes (encode-coding-string
                 (concat "\"" (make-string 4096 ?a) "€😀\"")
                 'utf-8-unix t))
         (byte-consumptions 0)
         (original-byte (symbol-function 'epi-ledger--lex-byte)))
    (cl-letf (((symbol-function 'epi-ledger--lex-byte)
               (lambda (state)
                 (setq byte-consumptions (1+ byte-consumptions))
                 (funcall original-byte state))))
      (should (epi-ledger--jcs-validate-bytes bytes)))
    (should (= byte-consumptions (length bytes)))))

(ert-deftest epi-jcs-lexical-validator-preserves-incomplete-utf8-prefixes ()
  (dolist (suffix (list (unibyte-string #xc2)
                        (unibyte-string #xe0 #xa0)
                        (unibyte-string #xf0 #x90 #x80)))
    (should
     (eq 'incomplete
         (plist-get
          (epi-ledger--jcs-lex-result (concat (unibyte-string ?\") suffix))
          :kind)))))

(ert-deftest epi-jcs-lexical-validator-rejects-impossible-string-prefixes ()
  (should
   (eq 'invalid
       (plist-get
        (epi-ledger--jcs-lex-result
         (concat (string-make-unibyte "\"x") (unibyte-string #xff)))
        :kind)))
  (dolist (prefix '("\"\\u2" "\"\\ud" "\"\\u01"
                    "\"\\u002" "\"\\u00f"))
    (should (eq 'invalid
                (plist-get
                 (epi-ledger--jcs-lex-result
                  (string-make-unibyte prefix))
                 :kind))))
  (dolist (prefix '("\"\\u" "\"\\u0" "\"\\u00"
                    "\"\\u000" "\"\\u001"))
    (should (eq 'incomplete
                (plist-get
                 (epi-ledger--jcs-lex-result
                  (string-make-unibyte prefix))
                 :kind)))))

(ert-deftest epi-jcs-number-prefixes-are-possible-canonical-numbers ()
  (dolist (prefix '("1E" "0e" "-0e+" "10e" "1.0e" "1e2"
                    "1e+0" "1e-0" "2e+308" "9e+308"
                    "1e+309" "1e+310" "1e-324" "1e-325"
                    "1000000000000000000000."
                    "99999999999999999999"
                    "99999999999999999999."
                    "9.9999999999999999e"
                    "9.99999999999999999e"))
    (should (eq 'invalid
                (plist-get
                 (epi-ledger--jcs-lex-result
                  (string-make-unibyte prefix))
                 :kind))))
  (dolist (prefix '("-0" "0.0" "1.0" "1.20" "1e" "1e+" "1e-"
                    "1.2e" "1e+2" "1e-1" "1e-6"
                    "98197197682250180000"))
    (should (eq 'incomplete
                (plist-get
                 (epi-ledger--jcs-lex-result
                 (string-make-unibyte prefix))
                 :kind))))
  (should (epi-ledger--jcs-validate-bytes
           (string-make-unibyte "981971976822501800000"))))

(ert-deftest epi-jcs-object-and-array-prefixes-enforce-item-cap-equally ()
  (let ((epi-json-item-limit 1))
    (dolist (prefix '("{\"a\":0," "[0,"))
      (let ((result
             (epi-ledger--jcs-lex-result (string-make-unibyte prefix))))
        (should (eq 'invalid (plist-get result :kind)))
        (should (eq 'json-item-limit (plist-get result :code))))))
  (let ((epi-json-item-limit 2))
    (dolist (prefix '("{\"a\":0," "[0,"))
      (should (eq 'incomplete
                  (plist-get
                   (epi-ledger--jcs-lex-result
                   (string-make-unibyte prefix))
                   :kind))))))

(ert-deftest epi-jcs-minimum-completion-includes-container-context ()
  (dolist (case '(("{\"a\"" . 3)
                  ("{\"a\":{\"b\"" . 4)
                  ("[{\"a\"" . 4)
                  ("{\"a\":[" . 2)
                  ("[0," . 2)
                  ("{\"a\":0," . 6)
                  ("{\"a\":0,\"a" . 5)))
    (let ((result
           (epi-ledger--jcs-lex-result
            (string-make-unibyte (car case)))))
      (should (eq 'incomplete (plist-get result :kind)))
      (should (= (cdr case)
                 (plist-get result :minimum-completion-bytes))))))

(ert-deftest epi-jcs-key-order-minimum-completion-is-exact ()
  (let* ((maximum-key (make-string 3 #xffff))
         (comma-prefix
          (encode-coding-string (concat "{\"" maximum-key "\":0,")
                                'utf-8-unix t))
         (open-key-prefix (concat comma-prefix (unibyte-string ?\"))))
    (dolist (case `((,comma-prefix . 15)
                    (,open-key-prefix . 14)))
      (let ((result (epi-ledger--jcs-lex-result (car case))))
        (should (eq 'incomplete (plist-get result :kind)))
        (should (= (cdr case)
                   (plist-get result :minimum-completion-bytes))))))
  (let ((cases
         (list
          (concat "{" (epi-ledger--jcs-encode "\\") ":0,"
                  (unibyte-string ?\" ?\\))
          (concat "{" (epi-ledger--jcs-encode (string #x00bf)) ":0,"
                  (unibyte-string ?\" #xc2))
          (string-make-unibyte
           (concat "{" (epi-ledger--jcs-encode (string #x001f))
                   ":0,\"\\u001")))))
    (dolist (prefix cases)
      (let ((result (epi-ledger--jcs-lex-result prefix)))
        (should (eq 'incomplete (plist-get result :kind)))
        (should (= 6 (plist-get result :minimum-completion-bytes)))))))

(ert-deftest epi-jcs-mantissa-minimum-has-an-exact-canonical-witness ()
  (let* ((token (string-make-unibyte "9.999999999999999"))
         (result (epi-ledger--jcs-lex-result token)))
    (should (eq 'incomplete (plist-get result :kind)))
    (should (= 3 (plist-get result :minimum-completion-bytes)))
    (should (epi-ledger--canonical-number-token-p
             (concat token "e-9")))))

(ert-deftest epi-jcs-mantissa-minimum-chooses-the-best-appended-digit ()
  (let* ((token (string-make-unibyte "-5.630303225990190"))
         (result (epi-ledger--jcs-lex-result token)))
    (should (eq 'incomplete (plist-get result :kind)))
    (should (= 4 (plist-get result :minimum-completion-bytes)))
    (should (epi-ledger--canonical-number-token-p
             (concat token "4e-8")))
    (should (= 4 (epi-ledger--json-prefix-with-cap-p
                  token (+ (length token) 4) 0)))
    (should-error
     (epi-ledger--json-prefix-with-cap-p token (+ (length token) 3) 0)
     :type 'epi-limit-exceeded)))

(ert-deftest epi-jcs-number-witness-search-obeys-shared-work-budget ()
  (dolist (token '("99999999999999999" "9.9999999999999999e"))
    (let ((epi-ledger-work-byte-limit 64)
          (epi-ledger-work-time-budget 1000.0)
          (yields 0))
      (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                ((symbol-function 'epi--yield)
                 (lambda () (setq yields (1+ yields)))))
        (should-not (epi-ledger--incomplete-number-prefix-minimum token)))
      (should (> yields 0)))))

(ert-deftest epi-ledger-timestamp-scanners-bound-large-fraction-work ()
  (let* ((fraction (make-string 100000 ?7))
         (prefix (concat "2026-07-21T18:43:02." fraction))
         (complete (concat prefix "Z"))
         (epi-ledger-work-byte-limit 5000)
         (epi-ledger-work-time-budget 1000.0)
         (original-substring (symbol-function 'substring))
         (largest-substring 0)
         (yields 0))
    (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
              ((symbol-function 'epi--yield)
               (lambda () (setq yields (1+ yields))))
              ((symbol-function 'substring)
               (lambda (string from &optional to)
                 (setq largest-substring
                       (max largest-substring
                            (- (or to (length string)) from)))
                 (funcall original-substring string from to))))
      (should (epi-ledger--timestamp-p complete))
      (should (= 1 (epi-ledger--timestamp-prefix-minimum prefix)))
      (should-not
       (epi-ledger--timestamp-prefix-p (concat prefix "x"))))
    (should (>= yields 60))
    (should (<= largest-substring 65536))))

(ert-deftest epi-ledger-timestamp-prefixes-are-calendar-completable ()
  (dolist (prefix '("2026-02-3" "2024-02-3"))
    (should-not (epi-ledger--timestamp-prefix-p prefix)))
  (dolist (prefix '("2026-02-2" "2026-04-3" "2026-01-3"))
    (should (epi-ledger--timestamp-prefix-p prefix)))
  (should (epi-ledger--timestamp-p "2024-02-29T00:00:00Z"))
  (should (epi-ledger--timestamp-p "0000-02-29T00:00:00Z"))
  (should (epi-ledger--timestamp-p "9999-12-31T23:59:59Z"))
  (dolist (timestamp '("2026-02-29T00:00:00Z"
                       "2026-04-31T00:00:00Z"
                       "0000-02-30T00:00:00Z"
                       "10000-01-01T00:00:00Z"))
    (should-not (epi-ledger--timestamp-p timestamp))))

(ert-deftest epi-ledger-near-cap-timestamp-prefix-has-exact-frame-boundary ()
  (let* ((uuid "22222222-2222-4222-8222-222222222222")
         (base
          (string-make-unibyte
           (concat "* message " uuid "\n:PROPERTIES:\n"
                   ":EPI_ID: " uuid "\n"
                   ":EPI_TYPE: message\n"
                   ":EPI_SCHEMA: 1\n"
                   ":EPI_AT: 2026-07-21T18:43:02.")))
         (seen (make-hash-table :test #'equal))
         (_seen
          (dolist (name '("EPI_ID" "EPI_TYPE" "EPI_SCHEMA"))
            (puthash name t seen)))
         (at-order
          (cl-position "EPI_AT" epi-ledger--drawer-property-order
                       :test #'equal))
         (minimum
          (+ 2
             (epi-ledger--drawer-tail-minimum
              at-order seen "message" "EPI_AT")))
         (fraction-length
          (- epi-record-frame-byte-limit (length base) minimum))
         (frame
          (concat base (make-string fraction-length ?7)))
         (epi-ledger-work-byte-limit 1048576)
         (epi-ledger-work-time-budget 1000.0)
         (yields 0))
    (should (= epi-record-frame-byte-limit (+ (length frame) minimum)))
    (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
              ((symbol-function 'epi--yield)
               (lambda () (setq yields (1+ yields)))))
      (should (eq 'incomplete
                  (plist-get (epi-ledger--scan-frame frame 0 1) :state)))
      (let ((epi-record-frame-byte-limit
             (1- epi-record-frame-byte-limit)))
        (let ((result (epi-ledger--scan-frame frame 0 1)))
          (should (eq 'invalid (plist-get result :state)))
          (should (eq 'record-frame-byte-limit
                      (plist-get result :code))))))
    (should (> yields 0))))

(ert-deftest epi-ledger-owned-preflight-and-encoder-share-work-cadence ()
  (let ((value `(("data" . ,(make-string 1100000 ?a)))))
    (dolist (function '(epi-ledger--preflight-canonical-value
                        epi-ledger--jcs-encode))
      (let ((epi-ledger-work-byte-limit 262144)
            (epi-ledger-work-time-budget 1000.0)
            (yields 0))
        (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
                  ((symbol-function 'epi--yield)
                   (lambda () (setq yields (1+ yields)))))
          (funcall function value))
        (should (>= yields 4))))))

(ert-deftest epi-ledger-semantic-string-and-object-walks-yield ()
  (let ((epi-ledger-work-byte-limit 5000)
        (epi-ledger-work-time-budget 1000.0)
        (yields 0))
    (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
              ((symbol-function 'epi--yield)
               (lambda () (setq yields (1+ yields)))))
      (epi-ledger--require-string (make-string 200000 ?a) "large")
      (epi-ledger--object-keys
       (mapcar (lambda (index) (cons (format "k%05d" index) index))
               (number-sequence 0 9999))
       "large-object"))
    (should (>= yields 50))))

(ert-deftest epi-ledger-utf8-decode-validation-yields-on-large-input ()
  (let ((epi-ledger-work-byte-limit 5000)
        (epi-ledger-work-time-budget 1000.0)
        (yields 0))
    (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
              ((symbol-function 'epi--yield)
               (lambda () (setq yields (1+ yields)))))
      (should (= 200000
                 (length
                  (epi-ledger--decode-utf8
                   (make-string 200000 ?a) 'large-header-value)))))
    (should (>= yields 40))))

(ert-deftest epi-ledger-large-object-key-uses-bounded-sort-key-chunks ()
  (let* ((key (make-string 200000 ?a))
         (value (list (cons key 0)))
         (epi-ledger-work-byte-limit 5000)
         (epi-ledger-work-time-budget 1000.0)
         (original-make-string (symbol-function 'make-string))
         (original-key-chunks
          (symbol-function 'epi-ledger--utf16be-key-chunks))
         (inside-key-chunks nil)
         (largest-zero-buffer 0)
         (yields 0))
    (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
              ((symbol-function 'epi--yield)
               (lambda () (setq yields (1+ yields))))
              ((symbol-function 'epi-ledger--utf16be-key-chunks)
               (lambda (&rest arguments)
                 (let ((old inside-key-chunks))
                   (setq inside-key-chunks t)
                   (unwind-protect
                       (apply original-key-chunks arguments)
                     (setq inside-key-chunks old)))))
              ((symbol-function 'make-string)
               (lambda (length character &optional multibyte)
                 (when (and inside-key-chunks (zerop character))
                   (setq largest-zero-buffer
                         (max largest-zero-buffer length)))
                 (funcall original-make-string length character multibyte))))
      (should (stringp (epi-ledger--jcs-encode value))))
    (should (<= largest-zero-buffer 4096))
    (should (> yields 0))))

(ert-deftest epi-jcs-lex-and-key-comparison-share-one-work-cursor ()
  ;; Raw lexing is just under 1 MiB, and comparing the two UTF-16 keys adds
  ;; almost another 1 MiB.  Fresh helper-local cursors previously yielded zero
  ;; times even though one real work slice was almost twice the configured cap.
  (let* ((prefix (make-string 500000 ?a))
         (bytes
          (string-make-unibyte
           (concat "{\"" prefix "0\":0,\"" prefix "1\":0}")))
         (epi-ledger-work-byte-limit 1048576)
         (epi-ledger-work-time-budget 1000.0)
         (original-charge (symbol-function 'epi-ledger--work-charge))
         (since-yield 0)
         (maximum-between-yields 0)
         (yields 0))
    (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
              ((symbol-function 'epi--yield)
               (lambda ()
                 (setq yields (1+ yields)
                       since-yield 0)))
              ((symbol-function 'epi-ledger--work-charge)
               (lambda (state amount)
                 (funcall original-charge state amount)
                 ;; Callers reserve each bounded unit before doing that work.
                 (setq since-yield (+ since-yield amount)
                       maximum-between-yields
                       (max maximum-between-yields since-yield)))))
      (should (epi-ledger--jcs-validate-bytes bytes)))
    (should (= 1000013 (length bytes)))
    (should (> yields 0))
    (should (<= maximum-between-yields epi-ledger-work-byte-limit))))

(ert-deftest epi-ledger-snapshot-memoizes-one-shared-large-string ()
  ;; Without identity memoization this legal-shape value copied 580 bytes
  ;; 131072 times (76,021,760 retained bytes) before exact preflight rejected
  ;; its 61,210,625-byte canonical form.
  (let* ((shared (make-string 116 #x10ffff))
         (value (make-vector epi-json-item-limit shared))
         (original-substring
          (symbol-function 'substring-no-properties))
         (shared-copy-calls 0)
         snapshot)
    (cl-letf (((symbol-function 'substring-no-properties)
               (lambda (&rest arguments)
                 (when (eq (car arguments) shared)
                   (setq shared-copy-calls (1+ shared-copy-calls)))
                 (apply original-substring arguments))))
      (setq snapshot
            (epi-ledger--snapshot-canonical-value
             value epi-record-json-byte-limit 'record-json-byte-limit)))
    (should (= shared-copy-calls 1))
    (should (eq (aref snapshot 0) (aref snapshot (1- (length snapshot)))))
    (should-error
     (epi-ledger--preflight-canonical-value
      snapshot epi-record-json-byte-limit 'record-json-byte-limit)
     :type 'epi-limit-exceeded)))

(ert-deftest epi-ledger-snapshot-bounds-aggregate-distinct-string-storage ()
  (let* ((byte-limit 100)
         (maximum-storage (/ (+ (* 5 byte-limit) 3) 4))
         (prototype (make-string 10 #x10ffff))
         (sources (cl-loop repeat 20 collect (copy-sequence prototype)))
         (source-set (make-hash-table :test #'eq))
         (original-substring
          (symbol-function 'substring-no-properties))
         (copied-storage 0))
    (dolist (source sources)
      (puthash source t source-set))
    (cl-letf (((symbol-function 'substring-no-properties)
               (lambda (&rest arguments)
                 (when (gethash (car arguments) source-set)
                   (setq copied-storage
                         (+ copied-storage (string-bytes (car arguments)))))
                 (apply original-substring arguments))))
      (should-error
       (epi-ledger--snapshot-canonical-value
        (vconcat sources) byte-limit 'record-json-byte-limit)
       :type 'epi-limit-exceeded))
    (should (> copied-storage 0))
    (should (<= copied-storage maximum-storage))))

(ert-deftest epi-ledger-snapshot-suppresses-automatic-gc-callbacks ()
  ;; With a 1000-byte GC threshold this graph used to run one post-GC hook
  ;; halfway through copying and return a mixture of the a and B generations.
  (let* ((sources
          (vconcat
           (cl-loop repeat 20000 collect (copy-sequence "aaaaaaaa"))))
         (gc-hooks 0)
         snapshot)
    (garbage-collect)
    (let ((gc-cons-threshold 1000)
          (post-gc-hook
           (list
            (lambda ()
              (setq gc-hooks (1+ gc-hooks))
              (dotimes (index (length sources))
                (aset (aref sources index) 0 ?B))))))
      (setq snapshot (epi-ledger--snapshot-canonical-value sources))
      (setq post-gc-hook nil))
    (should (= gc-hooks 0))
    (dotimes (index (length snapshot))
      (should (= ?a (aref (aref snapshot index) 0))))))

(ert-deftest epi-ledger-header-snapshots-before-timestamp-yields ()
  (let* ((session-id
          (copy-sequence "11111111-1111-4111-8111-111111111111"))
         (created-at
          (concat "2026-07-21T18:42:17." (make-string 100000 ?7) "Z"))
         (project-root (copy-sequence "/tmp/epi-project/"))
         (expected-at (copy-sequence created-at))
         (expected-root (copy-sequence project-root))
         (epi-ledger-work-byte-limit 5000)
         (epi-ledger-work-time-budget 1000.0)
         (mutated nil)
         (epi--yield-function
          (lambda ()
            (unless mutated
              (setq mutated t)
              (aset created-at 0 ?0)
              (aset project-root 1 ?x))))
         (header
          (epi-ledger-seal-header
           :session-id session-id :created-at created-at
           :project-root project-root)))
    (should mutated)
    (should (equal expected-at (epi-header-created-at header)))
    (should (equal expected-root (epi-header-project-root header)))))

(ert-deftest epi-ledger-record-snapshots-before-timestamp-yields ()
  (let* ((draft (epi-test-ledger--valid-draft 'reasoning))
         (payload (epi-draft-payload draft))
         (text-entry (assoc "text" payload))
         (at (concat "2026-07-21T18:43:02."
                     (make-string 100000 ?7) "Z"))
         (text (copy-sequence "stable sibling"))
         (id (copy-sequence (epi-draft-id draft)))
         (turn (copy-sequence (epi-draft-turn draft)))
         (previous
          (copy-sequence
           "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"))
         (expected-at (copy-sequence at))
         (expected-text (copy-sequence text))
         (epi-ledger-work-byte-limit 5000)
         (epi-ledger-work-time-budget 1000.0)
         (mutated nil)
         (epi--yield-function
          (lambda ()
            (unless mutated
              (setq mutated t)
              (aset at 0 ?0)
              (aset text 0 ?X)
              (aset previous 0 ?f)
              (setcar text-entry "changed-key")
              (setcdr text-entry "changed-value")
              (setcdr payload nil)
              (setf (epi-draft-id draft)
                    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
                    (epi-draft-at draft) "2026-01-01T00:00:00Z"
                    (epi-draft-turn draft)
                    "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
                    (epi-draft-payload draft)
                    '(("text" . "replacement") ("leg" . 1)
                      ("replay" . epi-json-false)))))))
    (setf (epi-draft-at draft) at)
    (setcdr (assoc "text" payload) text)
    (let ((record
           (epi-ledger-seal-record
            draft previous 1)))
      (should mutated)
      (should (equal id (epi-record-id record)))
      (should (equal turn (epi-record-turn record)))
      (should (equal
               "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
               (epi-record-previous-hash record)))
      (should (equal expected-at (epi-record-at record)))
      (should (equal expected-text
                     (epi-ledger--object-value
                      (epi-record-payload record) "text"))))))

(ert-deftest epi-ledger-header-parser-snapshots-before-line-yields ()
  ;; Initial A/P1/hash(A,P2) and final B/P2/hash(A,P2) are both invalid.  A
  ;; parser that retained caller bytes across the project-line yield accepted
  ;; the impossible hybrid A/P2/hash(A,P2).
  (let* ((session-a "11111111-1111-4111-8111-111111111111")
         (session-b "21111111-1111-4111-8111-111111111111")
         (project-1 (concat "/" (make-string 20000 ?a) "/"))
         (project-2 (concat "/" (make-string 20000 ?b) "/"))
         (target
          (epi-ledger-render-header
           (epi-ledger-seal-header
            :session-id session-a
            :created-at "2026-07-21T18:42:17-07:00"
            :project-root project-2)))
         (bytes (copy-sequence target))
         (session-start (string-match (regexp-quote session-a) bytes))
         (project-start (string-match (regexp-quote project-2) bytes))
         (epi-ledger-work-byte-limit 1000)
         (epi-ledger-work-time-budget 1000.0)
         (yield-count 0)
         mutated)
    (cl-replace bytes project-1 :start1 project-start)
    (let ((epi--yield-function
           (lambda ()
             (setq yield-count (1+ yield-count))
             (when (and (not mutated) (= yield-count 9))
               (setq mutated t)
               (cl-replace bytes session-b :start1 session-start)
               (cl-replace bytes project-2 :start1 project-start)))))
      (let ((condition
             (should-error (epi-ledger-parse-header bytes)
                           :type 'epi-ledger-format-error)))
        (should (eq 'header-hash-mismatch
                    (epi-test-ledger--condition-code condition)))))
    (should mutated)
    (should-error (epi-ledger-parse-header bytes)
                  :type 'epi-ledger-format-error)))

(ert-deftest epi-ledger-frame-parser-snapshots-before-line-yields ()
  ;; Initial drawer(T1)/JSON(T2) and final headline(B)/envelope(A) are invalid.
  ;; Retaining caller bytes across the long EPI_AT scan accepted the hybrid
  ;; headline(A)/drawer(T2)/JSON(T2).
  (let* ((id-a "22222222-2222-4222-8222-222222222222")
         (id-b "32222222-2222-4222-8222-222222222222")
         (at-1 (concat "2026-07-21T18:43:02."
                       (make-string 20000 ?1) "Z"))
         (at-2 (concat "2026-07-21T18:43:02."
                       (make-string 20000 ?2) "Z"))
         (draft (epi-test-ledger--message-draft))
         (_ (setf (epi-draft-at draft) at-2))
         (target (epi-ledger-render-record
                  (epi-ledger-seal-record
                   draft
                   "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
                   1)))
         (bytes (copy-sequence target))
         (headline-id-start (string-match (regexp-quote id-a) bytes))
         (drawer-at-start (string-match (regexp-quote at-2) bytes))
         (epi-ledger-work-byte-limit 1000)
         (epi-ledger-work-time-budget 1000.0)
         mutated)
    (cl-replace bytes at-1 :start1 drawer-at-start)
    (let ((epi--yield-function
           (lambda ()
             (unless mutated
               (setq mutated t)
               (cl-replace bytes id-b :start1 headline-id-start)
               (cl-replace bytes at-2 :start1 drawer-at-start)))))
      (let ((result (epi-ledger--scan-frame bytes 0 1)))
        (should (eq 'invalid (plist-get result :state)))
        (should (eq 'drawer-json-disagreement
                    (plist-get result :code)))))
    (should mutated)
    (let ((result (epi-ledger--scan-frame bytes 0 1)))
      (should (eq 'invalid (plist-get result :state)))
      (should (eq 'invalid-property-value
                  (plist-get result :code))))))

(ert-deftest epi-ledger-parser-offsets-are-validated-and-translated ()
  (let* ((header (epi-ledger-render-header (epi-test-ledger--header)))
         (frame (epi-ledger-render-record (epi-test-ledger--seal-message)))
         (prefix "xx")
         (parsed-header
          (epi-ledger-parse-header (concat prefix header) (length prefix)))
         (parsed-frame
          (epi-ledger--scan-frame (concat prefix frame) (length prefix) 1)))
    (should (= (+ (length prefix) (length header))
               (epi-header-end-offset parsed-header)))
    (should (= (+ (length prefix) (length frame))
               (plist-get parsed-frame :end-offset)))
    (dolist (offset (list -1 (1+ (length header)) "0"))
      (let ((condition
             (should-error (epi-ledger-parse-header header offset)
                           :type 'epi-ledger-format-error)))
        (should (eq 'invalid-offset
                    (epi-test-ledger--condition-code condition)))))
    (dolist (offset (list -1 (1+ (length frame)) "0"))
      (let ((result (epi-ledger--scan-frame frame offset 1)))
        (should (eq 'invalid (plist-get result :state)))
        (should (eq 'invalid-offset (plist-get result :code)))))))

(ert-deftest epi-ledger-frame-json-errors-use-absolute-offsets ()
  (let* ((prefix "xx")
         (frame (copy-sequence
                 (epi-ledger-render-record (epi-test-ledger--seal-message))))
         (begin "#+begin_epi-json\n")
         (json-start (+ (string-match (regexp-quote begin) frame)
                        (length begin)))
         (json-end
          (string-match (regexp-quote "\n#+end_epi-json\n")
                        frame json-start))
         (hash-prefix ":EPI_RECORD_SHA256: ")
         (hash-start (+ (string-match (regexp-quote hash-prefix) frame)
                        (length hash-prefix))))
    (aset frame json-start ?\s)
    (let ((hash (epi-ledger--hash (substring frame json-start json-end)
                                  'record)))
      (cl-replace frame hash :start1 hash-start))
    (let ((result (epi-ledger--scan-frame
                   (concat prefix frame) (length prefix) 1)))
      (should (eq 'invalid (plist-get result :state)))
      (should (eq 'value-required (plist-get result :code)))
      (should (= (+ (length prefix) json-start)
                 (plist-get result :offset))))))

(ert-deftest epi-ledger-complete-drawer-bounds-multimegabyte-timestamp-work ()
  (let* ((id "22222222-2222-4222-8222-222222222222")
         (turn "33333333-3333-4333-8333-333333333333")
         (at (concat "2026-07-21T18:43:02."
                     (make-string (* 2 1024 1024) ?7) "Z"))
         (bytes
          (string-make-unibyte
           (concat ":EPI_ID: " id "\n"
                   ":EPI_TYPE: message\n"
                   ":EPI_SCHEMA: 1\n"
                   ":EPI_AT: " at "\n"
                   ":EPI_TURN: " turn "\n"
                   ":EPI_PREV_SHA256: " (make-string 64 ?a) "\n"
                   ":EPI_RECORD_SHA256: " (make-string 64 ?b) "\n"
                   ":END:\n")))
         (epi-ledger-work-byte-limit 5000)
         (epi-ledger-work-time-budget 1000.0)
         (yields 0)
         events drawer)
    (let ((epi--yield-function (lambda () (setq yields (1+ yields))))
          (epi-ledger--nonpreemptible-observer
           (lambda (event) (push event events))))
      (setq drawer
            (car
             (epi-ledger--with-operation-work-state
               (epi-ledger--parse-drawer bytes 0 0 id "message")))))
    (should (equal at (epi-ledger--drawer-value drawer "EPI_AT")))
    (should (> yields 20))
    (should (cl-some
             (lambda (event)
               (and (eq (plist-get event :kind) 'copy)
                    (eq (plist-get event :field) 'drawer-value)
                    (= (plist-get event :bytes) (length at))))
             events))))

(ert-deftest epi-ledger-public-projection-copies-max-shape-cooperatively ()
  (let* ((large (make-string (* 4 1024 1024) ?x))
         (items (make-vector epi-json-item-limit 0))
         (payload `(("large" . ,large) ("items" . ,items)))
         (record (epi-ledger--make-record :payload payload))
         (epi-ledger-work-byte-limit 5000)
         (epi-ledger-work-time-budget 1000.0)
         (yields 0)
         events copy)
    (let ((epi--yield-function (lambda () (setq yields (1+ yields))))
          (epi-ledger--nonpreemptible-observer
           (lambda (event) (push event events))))
      (setq copy (epi-record-payload record)))
    (should-not (eq payload copy))
    (should-not (eq large (epi-ledger--object-value copy "large")))
    (should-not (eq items (epi-ledger--object-value copy "items")))
    (should (> yields 20))
    (should (cl-some
             (lambda (event)
               (and (eq (plist-get event :kind) 'copy)
                    (eq (plist-get event :field) 'trusted-string)
                    (= (plist-get event :bytes) (string-bytes large))))
             events))
    (aset (epi-ledger--object-value copy "large") 0 ?y)
    (should (= ?x (aref large 0)))))

(ert-deftest epi-jcs-empty-object-counts-as-a-container ()
  (let ((epi-json-depth-limit 2))
    (should (equal "[{}]" (epi-ledger--jcs-encode [nil])))
    (should (epi-ledger--jcs-validate-bytes
             (string-make-unibyte "[{}]")))
    (should-error (epi-ledger--jcs-encode [[nil]])
                  :type 'epi-limit-exceeded)
    (should-error
     (epi-ledger--jcs-validate-bytes (string-make-unibyte "[[{}]]"))
     :type 'epi-ledger-format-error)))

(ert-deftest epi-jcs-rejects-overlong-number-before-number-materialization ()
  (let ((parse-calls 0)
        (original-json-parse-string (symbol-function 'json-parse-string)))
    (cl-letf (((symbol-function 'json-parse-string)
               (lambda (&rest arguments)
                 (setq parse-calls (1+ parse-calls))
                 (apply original-json-parse-string arguments))))
      (should-error
       (epi-ledger--jcs-validate-bytes (make-string 1000 ?9))
       :type 'epi-ledger-format-error))
    (should (= parse-calls 0)))
  (dolist (case epi-test-jcs-appendix-b)
    (let ((expected (cadr case)))
      (unless (eq expected :reject)
        (should (<= (length expected)
                    epi-ledger--maximum-canonical-number-byte-length))))))

(ert-deftest epi-jcs-encoder-batches-large-ordinary-string-runs ()
  (let ((value (make-string 1000000 ?a))
        (character-conversions 0)
        (original-char-to-string (symbol-function 'char-to-string)))
    (cl-letf (((symbol-function 'char-to-string)
               (lambda (character)
                 (setq character-conversions (1+ character-conversions))
                 (funcall original-char-to-string character))))
      (should (equal (concat "\"" value "\"")
                     (epi-ledger--jcs-encode value))))
    (should (< character-conversions 1000))))

(ert-deftest epi-jcs-object-item-limit-precedes-full-key-allocation ()
  (let ((epi-json-item-limit 2)
        (key-conversions 0)
        (original-utf16be-key-chunks
         (symbol-function 'epi-ledger--utf16be-key-chunks))
        (object (cl-loop for index below 100
                         collect (cons (format "k%03d" index) index))))
    (cl-letf (((symbol-function 'epi-ledger--utf16be-key-chunks)
               (lambda (&rest arguments)
                 (setq key-conversions (1+ key-conversions))
                 (apply original-utf16be-key-chunks arguments))))
      (should-error (epi-ledger--jcs-encode object)
                    :type 'epi-limit-exceeded))
    (should (= key-conversions 2))))

(ert-deftest epi-jcs-object-output-cap-precedes-utf16-key-allocation ()
  (let ((key-conversions 0)
        (original-utf16be-key-chunks
         (symbol-function 'epi-ledger--utf16be-key-chunks)))
    (cl-letf (((symbol-function 'epi-ledger--utf16be-key-chunks)
               (lambda (&rest arguments)
                 (setq key-conversions (1+ key-conversions))
                 (apply original-utf16be-key-chunks arguments))))
      (should-error
       (epi-ledger--jcs-encode
        (list (cons (make-string 1000 ?k) 0)) 64)
       :type 'epi-limit-exceeded))
    (should (= key-conversions 0))))

(ert-deftest epi-jcs-canonical-string-validation-does-not-copy ()
  (let ((value (make-string 100000 ?a)))
    (should (eq value (epi-ledger--canonical-string value 'test)))))

(defconst epi-test-ledger--record-types
  '(session-info operation-started turn-started message reasoning leaf
    tool-planned tool-approved tool-denied tool-started tool-finished
    turn-finished turn-failed turn-cancelled turn-interrupted
    operation-finished operation-failed operation-cancelled
    operation-interrupted recovery-origin)
  "The exact twenty first-slice record types.")

(defconst epi-test-ledger--recovery-origin-keys
  '("source_path" "source_session_id" "source_file_size"
    "source_header_sha256" "source_valid_prefix_head_sha256" "fragment_offset"
    "fragment_sha256" "fragment_size" "fragment_object"
    "destination_valid_prefix_head_sha256" "source_evidence_sha256")
  "Frozen recovery-origin payload keys.")

(ert-deftest epi-ledger-schema-descriptor-is-closed-and-shared ()
  (let ((descriptor (epi-ledger-schema-descriptor)))
    (should (equal epi-test-ledger--record-types
                   (mapcar #'car descriptor)))
    (should
     (equal epi-test-ledger--recovery-origin-keys
            (plist-get (cdr (assq 'recovery-origin descriptor))
                       :required-payload)))))

(ert-deftest epi-ledger-schema-descriptor-copies-key-strings ()
  (let* ((descriptor (epi-ledger-schema-descriptor))
         (keys (plist-get (cdr (assq 'recovery-origin descriptor))
                          :required-payload)))
    (aset (car keys) 0 ?X)
    (should
     (equal "source_path"
            (car (plist-get
                  (cdr (assq 'recovery-origin
                             (epi-ledger-schema-descriptor)))
                  :required-payload))))))

(ert-deftest epi-ledger-header-rendering-is-byte-exact ()
  (let* ((header (epi-test-ledger--header))
         (expected (epi-test-ledger--fixture-bytes "ledger/header.org"))
         (actual (epi-ledger-render-header header))
         (parsed (epi-ledger-parse-header expected)))
    (should (equal expected actual))
    (should (equal "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
                   (epi-header-hash header)))
    (should (equal (epi-header-hash header) (epi-header-hash parsed)))
    (should (= (length expected) (epi-header-end-offset parsed)))
    (let ((epi-record-frame-byte-limit (length expected)))
      (should (epi-header-p (epi-ledger-parse-header expected))))
    (let ((epi-record-frame-byte-limit (1- (length expected))))
      (should-error (epi-ledger-parse-header expected)
                    :type 'epi-limit-exceeded))))

(ert-deftest epi-ledger-header-rejects-malformed-utf8-before-hash-validation ()
  (let* ((bytes (epi-test-ledger--fixture-bytes "ledger/header.org"))
         (prefix "#+EPI_PROJECT_ROOT: ")
         (start (+ (string-match (regexp-quote prefix) bytes)
                   (length prefix)))
         (hostile (concat (substring bytes 0 start)
                          (unibyte-string #xff)
                          (substring bytes (1+ start))))
         (condition
          (should-error (epi-ledger-parse-header hostile)
                        :type 'epi-ledger-format-error)))
    (should (eq 'malformed-utf8
                (epi-test-ledger--condition-code condition)))))

(ert-deftest epi-ledger-path-validation-rejects-nul-with-structured-errors ()
  (let ((condition
         (should-error
          (epi-ledger-seal-header
           :session-id "11111111-1111-4111-8111-111111111111"
           :created-at "2026-07-21T18:42:17-07:00"
           :project-root (concat "/tmp/project" (string 0) "/"))
          :type 'epi-ledger-format-error)))
    (should (eq 'canonical-directory-required
                (epi-test-ledger--condition-code condition))))
  (dolist (type '(session-info turn-started))
    (let* ((draft (epi-test-ledger--valid-draft type))
           (payload (epi-draft-payload draft)))
      (setcdr (assoc "working_directory" payload)
              (concat "/tmp/work" (string 0) "/"))
      (let ((condition (epi-test-ledger--seal-draft-condition draft)))
        (should (eq 'canonical-directory-required
                    (epi-test-ledger--condition-code condition))))))
  (let* ((draft (epi-test-ledger--valid-draft 'recovery-origin))
         (payload (epi-draft-payload draft)))
    (setcdr (assoc "source_path" payload)
            (concat "/tmp/source" (string 0) ".org"))
    (let ((condition (epi-test-ledger--seal-draft-condition draft)))
      (should (eq 'absolute-path-required
                  (epi-test-ledger--condition-code condition))))))

(ert-deftest epi-ledger-source-path-handler-errors-remain-structured ()
  (let* ((draft (epi-test-ledger--valid-draft 'recovery-origin))
         (payload (epi-draft-payload draft))
         (handler 'epi-test-ledger--exploding-file-handler)
         (file-name-handler-alist `(("\\`/hostile:" . ,handler))))
    (setcdr (assoc "source_path" payload) "/hostile:source.org")
    (cl-letf (((symbol-function handler)
               (lambda (operation &rest arguments)
                 (if (eq operation 'expand-file-name)
                     (error "hostile expand-file-name handler")
                   (let ((inhibit-file-name-handlers
                          (cons handler inhibit-file-name-handlers))
                         (inhibit-file-name-operation operation))
                     (apply operation arguments))))))
      (let ((condition (epi-test-ledger--seal-draft-condition draft)))
        (should (eq 'canonical-absolute-file-required
                    (epi-test-ledger--condition-code condition)))))))

(ert-deftest epi-ledger-path-handlers-only-receive-disposable-copies ()
  (let ((handler 'epi-test-ledger--mutating-path-argument-handler)
        (file-name-handler-alist
         '(("\\`/hostile:" . epi-test-ledger--mutating-path-argument-handler))))
    (cl-letf (((symbol-function handler)
               (lambda (operation &rest arguments)
                 (if (eq operation 'expand-file-name)
                     (let ((canonical (substring-no-properties
                                       (car arguments))))
                       (aset (car arguments) 1 ?x)
                       canonical)
                   (let ((inhibit-file-name-handlers
                          (cons handler inhibit-file-name-handlers))
                         (inhibit-file-name-operation operation))
                     (apply operation arguments))))))
      (dolist (case '((session-info "working_directory" "/hostile:work/")
                      (turn-started "working_directory" "/hostile:turn/")
                      (recovery-origin "source_path" "/hostile:source.org")))
        (pcase-let ((`(,type ,field ,path) case))
          (let* ((draft (epi-test-ledger--valid-draft type))
                 (payload (epi-draft-payload draft)))
            (setcdr (assoc field payload) (copy-sequence path))
            (let ((record
                   (epi-ledger-seal-record
                    draft
                    "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
                    1)))
              (should (equal path
                             (epi-ledger--object-value
                              (epi-record-payload record) field))))))))))

(ert-deftest epi-ledger-record-snapshots-all-inputs-before-path-handlers ()
  (let* ((draft (epi-test-ledger--valid-draft 'session-info))
         (payload (epi-draft-payload draft))
         (id (copy-sequence (epi-draft-id draft)))
         (at (copy-sequence (epi-draft-at draft)))
         (prompt (copy-sequence
                  (epi-ledger--object-value payload "base_system_prompt")))
         (expected-id (copy-sequence id))
         (expected-at (copy-sequence at))
         (expected-prompt (copy-sequence prompt))
         (handler 'epi-test-ledger--mutating-caller-handler)
         (file-name-handler-alist
          '(("\\`/hostile:" . epi-test-ledger--mutating-caller-handler)))
         (handler-calls 0))
    (setf (epi-draft-id draft) id
          (epi-draft-at draft) at)
    (setcdr (assoc "base_system_prompt" payload) prompt)
    (setcdr (assoc "working_directory" payload) "/hostile:work/")
    (cl-letf (((symbol-function handler)
               (lambda (operation &rest arguments)
                 (if (eq operation 'expand-file-name)
                     (let ((canonical
                            (substring-no-properties (car arguments))))
                       (setq handler-calls (1+ handler-calls))
                       (aset id 0 ?f)
                       (aset at 0 ?1)
                       (aset prompt 0 ?X)
                       (aset (car arguments) 1 ?x)
                       canonical)
                   (let ((inhibit-file-name-handlers
                          (cons handler inhibit-file-name-handlers))
                         (inhibit-file-name-operation operation))
                     (apply operation arguments))))))
      (let* ((record
              (epi-ledger-seal-record
               draft
               "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
               1))
             (sealed-payload (epi-record-payload record)))
        (should (> handler-calls 0))
        (should (equal expected-id (epi-record-id record)))
        (should (equal expected-at (epi-record-at record)))
        (should (equal expected-prompt
                       (epi-ledger--object-value
                        sealed-payload "base_system_prompt")))
        (should (equal "/hostile:work/"
                       (epi-ledger--object-value
                        sealed-payload "working_directory")))))))

(ert-deftest epi-ledger-record-rendering-is-byte-exact ()
  (let* ((whole (epi-test-ledger--fixture-bytes "ledger/one-message.org"))
         (header-bytes (epi-test-ledger--fixture-bytes "ledger/header.org"))
         (expected (substring whole (length header-bytes)))
         (record (epi-test-ledger--seal-message))
         (actual (epi-ledger-render-record record))
         (parsed (epi-test-ledger--parse-frame expected)))
    (should (equal expected actual))
    (should (equal "c6ec993f1728a55484b31019f76a1374dd4d1f47ae30827107c7631d779b0c74"
                   (epi-record-hash record)))
    (should (equal (epi-record-hash record) (epi-record-hash parsed)))
    (should (= 1 (epi-record-sequence parsed)))
    (should (= 0 (epi-record-start-offset parsed)))
    (should (< (epi-record-json-start-offset parsed)
               (epi-record-json-end-offset parsed)
               (epi-record-end-offset parsed)))
    (should-not (epi-record-sealed-json parsed))))

(ert-deftest epi-ledger-near-cap-render-primitives-stay-within-frame-limit ()
  (let* ((epi-record-frame-byte-limit 4096)
         (epi-record-json-byte-limit 3500)
         (epi-ledger-work-byte-limit 64)
         (epi-ledger-work-time-budget 1000.0)
         (header
          (epi-ledger--make-header
           :title "Epi session" :format 1
           :session-id "11111111-1111-4111-8111-111111111111"
           :created-at "0000-02-29T00:00:00Z"
           :project-root (concat "/" (make-string 3500 ?p) "/")
           :coding-system "utf-8-unix" :hash (make-string 64 ?a)))
         (draft (epi-test-ledger--valid-draft 'message))
         (content (epi-ledger--object-value
                   (epi-draft-payload draft) "content"))
         events)
    (setcdr (assoc "text" (aref content 0)) (make-string 2500 ?x))
    (let ((record
           (epi-ledger-seal-record
            draft
            "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
            1))
          (epi-ledger--nonpreemptible-observer
           (lambda (event) (push event events))))
      (should (<= (length (epi-ledger-render-header header))
                  epi-record-frame-byte-limit))
      (should (<= (length (epi-ledger-render-record record))
                  epi-record-frame-byte-limit)))
    (dolist (field '(ledger-header-value ledger-header ledger-record))
      (let ((event (seq-find (lambda (candidate)
                               (eq field (plist-get candidate :field)))
                             events)))
        (should event)
        (should (<= (plist-get event :bytes)
                    epi-record-frame-byte-limit))))))

(ert-deftest epi-ledger-codec-round-trips-org-looking-text ()
  (let* ((text "* forged headline\n:END:\n#+end_epi-json\nNUL? no")
         (draft (make-epi-draft
                 :id "44444444-4444-4444-8444-444444444444"
                 :type 'message
                 :at "2026-07-21T18:44:02-07:00"
                 :turn "55555555-5555-4555-8555-555555555555"
                 :payload `(("role" . "user")
                            ("content" .
                             [( ("type" . "text")
                                ("text" . ,text)) ]))))
         (record
          (epi-ledger-seal-record
           draft
           "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
           1))
         (bytes (epi-ledger-render-record record))
         (parsed (epi-test-ledger--parse-frame bytes))
         (content (alist-get "content" (epi-record-payload parsed)
                             nil nil #'equal)))
    (should (equal (epi-test-ledger--fixture-bytes
                    "ledger/adversarial-text.org")
                   bytes))
    (should (equal text
                   (alist-get "text" (aref content 0) nil nil #'equal)))
    (should (equal (epi-record-hash record) (epi-record-hash parsed)))))

(ert-deftest epi-ledger-frame-scanner-distinguishes-all-three-states ()
  (let* ((frame (epi-ledger-render-record
                 (epi-test-ledger--seal-message)))
         (complete (epi-ledger--scan-frame frame 0 1))
         (incomplete (epi-ledger--scan-frame
                      (substring frame 0 (1- (length frame))) 0 1))
         (invalid (epi-ledger--scan-frame
                   (concat "** " (substring frame 2)) 0 1))
         (eof (epi-ledger--scan-frame "" 0 1)))
    (should (eq 'complete (plist-get complete :state)))
    (should (= (length frame) (plist-get complete :next-offset)))
    (should (= (length frame) (plist-get complete :end-offset)))
    (should (eq 'incomplete (plist-get incomplete :state)))
    (should (eq 'truncated-frame (plist-get incomplete :code)))
    (should (equal '(:code truncated-frame)
                   (plist-get incomplete :cause)))
    (should (= (1- (length frame))
               (plist-get incomplete :fragment-byte-size)))
    (should (eq 'invalid (plist-get invalid :state)))
    (should (eq 'invalid-headline (plist-get invalid :code)))
    (should (equal '(:code invalid-headline) (plist-get invalid :cause)))
    (should (eq 'eof (plist-get eof :state)))
    (should (eq 'clean-eof (plist-get eof :code)))
    (should (= 0 (plist-get eof :next-offset)))))

(ert-deftest epi-ledger-frame-scanner-accepts-only-grammar-prefixes-as-torn ()
  (let* ((frame (epi-ledger-render-record
                 (epi-test-ledger--seal-message)))
         (headline-end (1+ (string-match "\n" frame)))
         (drawer-position (string-match ":EPI_ID:" frame))
         (json-position
          (+ (string-match (regexp-quote "#+begin_epi-json\n") frame)
             (length "#+begin_epi-json\n")))
         (end-position
          (string-match (regexp-quote "#+end_epi-json\n") frame)))
    (dolist (cut (list 1 (+ headline-end 4) (+ drawer-position 4)
                       (+ json-position 10) (+ end-position 4)))
      (let ((result (epi-ledger--scan-frame (substring frame 0 cut) 0 1)))
        (should (eq 'incomplete (plist-get result :state)))
        (should (eq 'truncated-frame (plist-get result :code)))))
    (dolist (fragment '("garbage" "** message" "* MESSAGE"))
      (let ((result (epi-ledger--scan-frame
                     (string-make-unibyte fragment) 0 1)))
        (should (eq 'invalid (plist-get result :state)))
        (should (eq 'invalid-headline (plist-get result :code)))))))

(ert-deftest epi-ledger-complete-frame-lines-are-validated-before-next-eof ()
  (let ((uuid "22222222-2222-4222-8222-222222222222")
        (at "2026-07-21T18:43:02-07:00")
        (hash
         "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"))
    (dolist (headline
             (list "* message a\n"
                   (concat "* unknown " uuid "\n")))
      (let ((result
             (epi-ledger--scan-frame
              (string-make-unibyte headline) 0 1)))
        (should (eq 'invalid (plist-get result :state)))
        (should (eq 'invalid-headline (plist-get result :code)))))
    (let ((start (concat "* message " uuid "\n:PROPERTIES:\n")))
      (dolist
          (lines
           (list
            '(":EPI_ID: x\n")
            `(,(concat ":EPI_ID: " uuid "\n") ":EPI_TYPE: unknown\n")
            `(,(concat ":EPI_ID: " uuid "\n") ":EPI_TYPE: message\n"
              ":EPI_SCHEMA: 2\n")
            `(,(concat ":EPI_ID: " uuid "\n") ":EPI_TYPE: message\n"
              ":EPI_SCHEMA: 1\n" ":EPI_AT: 2026-02-30T00:00:00Z\n")
            `(,(concat ":EPI_ID: " uuid "\n") ":EPI_TYPE: message\n"
              ":EPI_SCHEMA: 1\n" ,(concat ":EPI_AT: " at "\n")
              ":EPI_PARENT: x\n")
            `(,(concat ":EPI_ID: " uuid "\n") ":EPI_TYPE: message\n"
              ":EPI_SCHEMA: 1\n" ,(concat ":EPI_AT: " at "\n")
              ":EPI_PREV_SHA256: x\n")
            `(,(concat ":EPI_ID: " uuid "\n") ":EPI_TYPE: message\n"
              ":EPI_SCHEMA: 1\n" ,(concat ":EPI_AT: " at "\n")
              ,(concat ":EPI_PREV_SHA256: " hash "\n")
              ":EPI_RECORD_SHA256: x\n")
            (list (concat ":EPI_ID: " (make-string 100000 ?x) "\n"))))
        (let ((result
               (epi-ledger--scan-frame
                (string-make-unibyte (concat start (apply #'concat lines)))
                0 1)))
          (should (eq 'invalid (plist-get result :state)))
          (should (eq 'invalid-property-value
                      (plist-get result :code))))))))

(ert-deftest epi-ledger-frame-cap-accounts-for-every-mandatory-stage ()
  (let* ((frame (epi-ledger-render-record (epi-test-ledger--seal-message)))
         (headline-end (string-match "\n" frame))
         (properties-end (string-match "\n" frame (1+ headline-end)))
         (id-start (string-match (regexp-quote ":EPI_ID: ") frame))
         (drawer-end
          (+ (string-match (regexp-quote ":END:\n") frame)
             (length ":END:\n")))
         (fragments
          (list (string-make-unibyte "*")
                (substring frame 0 headline-end)
                (substring frame 0 properties-end)
                (substring frame 0 (+ id-start (length ":EPI_ID: ") 3))
                (substring frame 0 (+ drawer-end 5)))))
    (dolist (fragment fragments)
      (let ((epi-record-frame-byte-limit (length frame)))
        (should (eq 'incomplete
                    (plist-get (epi-ledger--scan-frame fragment 0 1)
                               :state))))
      (let* ((epi-record-frame-byte-limit
              (if (= (length fragment) 1) 2 (+ (length fragment) 10)))
             (result (epi-ledger--scan-frame fragment 0 1)))
        (should (eq 'invalid (plist-get result :state)))
        (should (eq 'record-frame-byte-limit (plist-get result :code)))))))

(ert-deftest epi-ledger-drawer-fields-are-type-closed-before-next-eof ()
  (let* ((previous
          "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1")
         (session-frame
          (epi-ledger-render-record
           (epi-ledger-seal-record
            (epi-test-ledger--valid-draft 'session-info) previous 1)))
         (insertion (string-match (regexp-quote ":EPI_PREV_SHA256: ")
                                  session-frame))
         (base (substring session-frame 0 insertion))
         (parent "44444444-4444-4444-8444-444444444444"))
    (let ((partial
           (epi-ledger--scan-frame
            (concat base ":EPI_PARENT: " (substring parent 0 4)) 0 1))
          (complete
           (epi-ledger--scan-frame
            (concat base ":EPI_PARENT: " parent "\n") 0 1)))
      (should (eq 'invalid (plist-get partial :state)))
      (should (eq 'invalid-property-prefix (plist-get partial :code)))
      (should (eq 'invalid (plist-get complete :state)))
      (should (eq 'forbidden-property (plist-get complete :code))))
    (let ((draft (epi-test-ledger--message-draft)))
      (setf (epi-draft-parent draft) parent)
      (should (eq 'complete
                  (plist-get
                   (epi-ledger--scan-frame
                    (epi-ledger-render-record
                     (epi-ledger-seal-record draft previous 1))
                    0 1)
                   :state))))))

(ert-deftest epi-ledger-every-proper-frame-byte-prefix-is-torn-not-invalid ()
  (let* ((frame (epi-ledger-render-record
                 (epi-test-ledger--seal-message
                  "* forged\n:END:\n#+end_epi-json\n😀")))
         (id-start (string-match (regexp-quote ":EPI_ID: ") frame))
         (type-start (string-match (regexp-quote ":EPI_TYPE: ") frame))
         (schema-start (string-match (regexp-quote ":EPI_SCHEMA: ") frame))
         (at-start (string-match (regexp-quote ":EPI_AT: ") frame))
         (hash-start
          (string-match (regexp-quote ":EPI_PREV_SHA256: ") frame)))
    (cl-loop for cut from 1 below (length frame)
             do (ert-info ((format "frame byte cut %d" cut))
                  (should
                   (eq 'incomplete
                       (plist-get
                        (epi-ledger--scan-frame
                         (substring frame 0 cut) 0 1)
                        :state)))))
    (dolist (fragment
             (list (concat (substring frame 0 id-start) ":EPI_ID: $$$")
                   (concat (substring frame 0 type-start)
                           ":EPI_TYPE: MESSAGE")
                   (concat (substring frame 0 schema-start)
                           ":EPI_SCHEMA: 2")
                   (concat (substring frame 0 at-start)
                           ":EPI_AT: 2026-02-30T")
                   (concat (substring frame 0 hash-start)
                           ":EPI_PREV_SHA256: A")))
      (let ((result (epi-ledger--scan-frame fragment 0 1)))
        (should (eq 'invalid (plist-get result :state)))
        (should (eq 'invalid-property-prefix (plist-get result :code)))))))

(defun epi-test-ledger--replace-frame-json (frame replacement)
  "Return FRAME with its JSON body changed to REPLACEMENT and rehashed."
  (let* ((begin "#+begin_epi-json\n")
         (end-marker "\n#+end_epi-json\n")
         (start (+ (string-match (regexp-quote begin) frame)
                   (length begin)))
         (end (string-match (regexp-quote end-marker) frame start))
         (hash (secure-hash 'sha256 replacement))
         (changed (concat (substring frame 0 start)
                          replacement
                          (substring frame end))))
    (replace-regexp-in-string
     ":EPI_RECORD_SHA256: [0-9a-f]+"
     (concat ":EPI_RECORD_SHA256: " hash)
     changed t t)))

(ert-deftest epi-ledger-envelope-presence-distinguishes-empty-object-from-omitted ()
  (let* ((previous
          "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1")
         (message
          (epi-ledger-render-record
           (epi-ledger-seal-record
            (epi-test-ledger--valid-draft 'message) previous 1)))
         (session
          (epi-ledger-render-record
           (epi-ledger-seal-record
            (epi-test-ledger--valid-draft 'session-info) previous 1))))
    (dolist (frame (list message session))
      (should (eq 'complete
                  (plist-get (epi-ledger--scan-frame frame 0 1) :state))))
    (dolist (case `((,message "parent" invalid-id)
                    (,session "parent" forbidden-envelope-field)
                    (,session "target" forbidden-envelope-field)
                    (,session "turn" forbidden-envelope-field)
                    (,session "operation" forbidden-envelope-field)))
      (pcase-let ((`(,frame ,field ,expected-code) case))
        (let* ((begin "#+begin_epi-json\n")
               (json-start
                (+ (string-match (regexp-quote begin) frame)
                   (length begin)))
               (json-end
                (string-match (regexp-quote "\n#+end_epi-json\n")
                              frame json-start))
               (envelope
                (epi-ledger--decode-json
                 (substring frame json-start json-end))))
          (push (cons field nil) envelope)
          (let ((result
                 (epi-ledger--scan-frame
                  (epi-test-ledger--replace-frame-json
                   frame (epi-ledger--jcs-encode envelope))
                  0 1)))
            (should (eq 'invalid (plist-get result :state)))
            (should (eq expected-code (plist-get result :code)))))))))

(ert-deftest epi-ledger-oversized-torn-fields-reject-before-bounded-substrings ()
  (let* ((epi-record-frame-byte-limit 4096)
         (oversized (make-string 4000 ?x))
         (seen (make-hash-table :test #'equal))
         (original-substring (symbol-function 'substring))
         (largest-substring 0))
    (cl-letf (((symbol-function 'substring)
               (lambda (string from &optional to)
                 (setq largest-substring
                       (max largest-substring
                            (- (or to (length string)) from)))
                 (funcall original-substring string from to))))
      (should-not
       (epi-ledger--drawer-prefix-minimum
        (concat ":EPI_ID: " oversized) -1 seen
        "22222222-2222-4222-8222-222222222222" "message"))
      (dolist (name '("EPI_ID" "EPI_TYPE" "EPI_SCHEMA" "EPI_AT" "EPI_TURN"))
        (puthash name t seen))
      (should-not
       (epi-ledger--drawer-prefix-minimum
        (concat ":EPI_PREV_SHA256: " oversized) 6 seen
        "22222222-2222-4222-8222-222222222222" "message"))
      (should-not
       (epi-ledger--headline-prefix-candidates (concat "* " oversized))))
    (should (zerop largest-substring))))

(ert-deftest epi-ledger-oversized-complete-headline-rejects-before-regexp ()
  (let* ((epi-record-frame-byte-limit 4096)
         (line (string-make-unibyte
                (concat "* " (make-string 4092 ?x) "\n")))
         (original-string-match (symbol-function 'string-match))
         (largest-regexp-input 0))
    (cl-letf (((symbol-function 'string-match)
               (lambda (regexp string &optional start)
                 (setq largest-regexp-input
                       (max largest-regexp-input (length string)))
                 (funcall original-string-match regexp string start))))
      (let ((result (epi-ledger--scan-frame line 0 1)))
        (should (eq 'invalid (plist-get result :state)))
        (should (eq 'invalid-headline (plist-get result :code)))))
    (should (<= largest-regexp-input
                epi-ledger--maximum-headline-byte-length))))

(ert-deftest epi-ledger-frame-rejects-hostile-or-disagreeing-input ()
  (let* ((frame (epi-ledger-render-record
                 (epi-test-ledger--seal-message)))
         (begin "#+begin_epi-json\n")
         (json-start (+ (string-match (regexp-quote begin) frame)
                        (length begin)))
         (json-end (string-match
                    (regexp-quote "\n#+end_epi-json\n") frame json-start))
         (json (substring frame json-start json-end)))
    (dolist
        (bad
         (list
          (replace-regexp-in-string "\n" "\r\n" frame t t)
          (replace-regexp-in-string
           ":EPI_TURN: [^\n]+" ":EPI_TURN: 66666666-6666-4666-8666-666666666666"
           frame t t)
          (replace-regexp-in-string
           ":EPI_RECORD_SHA256: [0-9a-f]+"
           ":EPI_RECORD_SHA256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
           frame t t)
          (epi-test-ledger--replace-frame-json
           frame (replace-regexp-in-string
                  "{\"at\":" "{\"schema\":1,\"at\":" json t t))
          (epi-test-ledger--replace-frame-json
           frame (replace-regexp-in-string
                  ",\"schema\":"
                  (concat ",\"record_hash\":\""
                          (make-string 64 ?a)
                          "\",\"schema\":")
                  json t t))
          (epi-test-ledger--replace-frame-json
           frame (replace-regexp-in-string
                  "{\"at\":" "{ \"at\":" json t t))
          (epi-test-ledger--replace-frame-json
           frame (replace-regexp-in-string
                  "\"schema\":1" "\"schema\":1.0" json t t))
          (epi-test-ledger--replace-frame-json
           frame (replace-regexp-in-string
                  "\"schema\":1" "\"schema\":2" json t t))
          (epi-test-ledger--replace-frame-json
           frame (replace-regexp-in-string
                  "\"type\":\"message\"" "\"type\":\"unknown\"" json t t))))
      (should (eq 'invalid
                  (plist-get (epi-ledger--scan-frame bad 0 1) :state))))
    (let ((malformed-json (copy-sequence json))
          (control-json (copy-sequence json)))
      (aset malformed-json 10 #xff)
      (aset control-json 10 1)
      (dolist (bad-json (list malformed-json control-json))
        (let ((result
               (epi-ledger--scan-frame
                (epi-test-ledger--replace-frame-json frame bad-json) 0 1)))
          (should (eq 'invalid (plist-get result :state)))
          (should (memq (plist-get result :code)
                        '(malformed-utf8 unescaped-control-character))))))))

(ert-deftest epi-ledger-sealing-enforces-json-and-frame-byte-caps ()
  (let* ((text (make-string 80 31))
         (record (epi-test-ledger--seal-message text))
         (json-size (length (epi-record-sealed-json record)))
         (frame (epi-ledger-render-record record))
         (frame-size (length frame)))
    (should (> json-size (* 5 (length text))))
    (let ((epi-record-json-byte-limit json-size))
      (should (epi-record-p (epi-test-ledger--seal-message text))))
    (let ((epi-record-json-byte-limit (1- json-size)))
      (should-error (epi-test-ledger--seal-message text)
                    :type 'epi-limit-exceeded))
    (let ((epi-record-frame-byte-limit frame-size))
      (should (= frame-size
                 (length (epi-ledger-render-record record)))))
    (let ((epi-record-frame-byte-limit (1- frame-size)))
      (should-error (epi-ledger-render-record record)
                    :type 'epi-limit-exceeded))
    (let ((epi-record-json-byte-limit json-size)
          (epi-record-frame-byte-limit frame-size))
      (should (eq 'complete
                  (plist-get (epi-ledger--scan-frame frame 0 1) :state))))
    (dolist (case `((,(1- json-size) ,frame-size
                      record-json-byte-limit)
                    (,json-size ,(1- frame-size)
                     record-frame-byte-limit)))
      (pcase-let ((`(,json-limit ,frame-limit ,code) case))
        (let ((epi-record-json-byte-limit json-limit)
              (epi-record-frame-byte-limit frame-limit)
              (hash-calls 0)
              (decode-calls 0)
              (original-hash (symbol-function 'epi-ledger--hash))
              (original-decode (symbol-function 'epi-ledger--decode-json)))
          (cl-letf (((symbol-function 'epi-ledger--hash)
                     (lambda (&rest arguments)
                       (setq hash-calls (1+ hash-calls))
                       (apply original-hash arguments)))
                    ((symbol-function 'epi-ledger--decode-json)
                     (lambda (&rest arguments)
                       (setq decode-calls (1+ decode-calls))
                       (apply original-decode arguments))))
            (let ((result (epi-ledger--scan-frame frame 0 1)))
              (should (eq 'invalid (plist-get result :state)))
              (should (eq code (plist-get result :code)))))
          (should (= hash-calls 0))
          (should (= decode-calls 0)))))))

(ert-deftest epi-ledger-record-frame-cap-precedes-drawer-encoding ()
  (let* ((draft (epi-test-ledger--valid-draft 'tool-planned))
         (payload (epi-draft-payload draft))
         (fraction (make-string 100000 ?7))
         (previous
          "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"))
    (setf (epi-draft-at draft)
          (concat "2026-07-21T18:43:02." fraction "-07:00"))
    (setcdr (assoc "arguments" payload)
            `(("escaped" . ,(make-string 10000 31))))
    (let* ((record (epi-ledger-seal-record draft previous 1))
           (frame-size (length (epi-ledger-render-record record)))
           (epi-record-frame-byte-limit (1- frame-size))
           (encode-calls 0)
           (original-encode (symbol-function 'encode-coding-string)))
      (let ((epi-record-frame-byte-limit frame-size))
        (should (= frame-size (length (epi-ledger-render-record record)))))
      (cl-letf (((symbol-function 'encode-coding-string)
                 (lambda (&rest arguments)
                   (setq encode-calls (1+ encode-calls))
                   (apply original-encode arguments))))
        (let ((condition
               (should-error (epi-ledger-render-record record)
                             :type 'epi-limit-exceeded)))
          (should (eq 'record-frame-byte-limit
                      (epi-test-ledger--condition-code condition)))))
      (should (= encode-calls 0)))))

(ert-deftest epi-ledger-message-projection-owns-its-content ()
  (let* ((record (epi-test-ledger--seal-message))
         (message (epi-ledger-message-from-record record))
         (record-content
          (alist-get "content" (epi-record-payload record) nil nil #'equal))
         (message-content (epi-message-content message)))
    (should (equal (epi-record-id record) (epi-message-record-id message)))
    (should (equal "user" (epi-message-role message)))
    (should (equal (epi-record-turn record) (epi-message-turn message)))
    (should (= 1 (epi-message-sequence message)))
    (should (equal record-content message-content))
    (should-not (eq record-content message-content))
    (setcdr (assoc "text" (aref message-content 0)) "changed")
    (should (equal "Hello, Epi.\n* not Org"
                   (cdr (assoc "text" (aref record-content 0)))))
    (should (equal "Hello, Epi.\n* not Org"
                   (cdr (assoc "text"
                               (aref (epi-message-content message) 0)))))))

(ert-deftest epi-ledger-sealed-record-owns-every-input-string ()
  (let* ((id (copy-sequence "22222222-2222-4222-8222-222222222222"))
         (at (copy-sequence "2026-07-21T18:43:02-07:00"))
         (turn (copy-sequence "33333333-3333-4333-8333-333333333333"))
         (previous
          (copy-sequence
           "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"))
         (draft (epi-test-ledger--message-draft))
         record baseline)
    (setf (epi-draft-id draft) id
          (epi-draft-at draft) at
          (epi-draft-turn draft) turn)
    (setq record (epi-ledger-seal-record draft previous 1)
          baseline (epi-ledger-render-record record))
    (aset id 0 ?f)
    (aset at 0 ?1)
    (aset turn 0 ?f)
    (aset previous 0 ?f)
    (should (equal baseline (epi-ledger-render-record record)))
    (should-not (eq id (epi-record-id record)))
    (should-not (eq at (epi-record-at record)))
    (should-not (eq turn (epi-record-turn record)))
    (should-not (eq previous (epi-record-previous-hash record)))))

(ert-deftest epi-ledger-sealed-values-expose-only-defensive-reads ()
  (let* ((record (epi-test-ledger--seal-message))
         (baseline (epi-ledger-render-record record))
         (id (epi-record-id record))
         (payload (epi-record-payload record))
         (json (epi-record-sealed-json record)))
    (aset id 0 ?f)
    (setcdr (assoc "role" payload) "assistant")
    (aset json 0 ?x)
    (should (equal baseline (epi-ledger-render-record record)))
    (should (equal "user"
                   (epi-ledger--object-value
                    (epi-record-payload record) "role")))
    (should-error (setf (epi-record-schema record) 2)))
  (let* ((hash (make-string 64 ?a))
         (ref (make-epi-object-ref
               :hash hash :size 3 :media-type "text/plain" :role "test"))
         (read-hash (epi-object-ref-hash ref)))
    (aset hash 0 ?b)
    (aset read-hash 1 ?b)
    (should (equal (make-string 64 ?a) (epi-object-ref-hash ref)))
    (should-error (setf (epi-object-ref-size ref) 4))))

(ert-deftest epi-ledger-object-reference-copies-share-one-work-cursor ()
  (let ((epi-ledger-work-byte-limit 10)
        (epi-ledger-work-time-budget 1000.0)
        (yields 0))
    (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
              ((symbol-function 'epi--yield)
               (lambda () (setq yields (1+ yields)))))
      (let ((ref (make-epi-object-ref
                  :hash (make-string 64 ?a) :size 9
                  :media-type (make-string 9 ?m) :role (make-string 9 ?r))))
        (should (epi-object-ref-p ref))))
    (should (> yields 0))))

(ert-deftest epi-ledger-object-reference-constructor-validates-canonical-fields ()
  (dolist
      (case
       `(((:hash ,(make-string 63 ?a) :size 1
           :media-type "text/plain" :role "attachment") invalid-hash)
         ((:hash ,(make-string 64 ?a) :size -1
           :media-type "text/plain" :role "attachment") invalid-integer)
         ((:hash ,(make-string 64 ?a) :size ,(1+ epi-object-byte-limit)
           :media-type "text/plain" :role "attachment") object-byte-limit)
         ((:hash ,(make-string 64 ?a) :size 1
           :media-type "" :role "attachment") empty-string)
         ((:hash ,(make-string 64 ?a) :size 1
           :media-type "text/plain" :role "") empty-string)))
    (pcase-let ((`(,arguments ,expected-code) case))
      (let ((condition
             (should-error (apply #'make-epi-object-ref arguments)
                           :type 'epi-error)))
        (should (eq expected-code
                    (epi-test-ledger--condition-code condition)))))))

(ert-deftest epi-ledger-object-reference-snapshots-before-validation-yields ()
  (let* ((hash (make-string 64 ?a))
         (media-type (make-string 20 ?m))
         (role (make-string 20 ?r))
         (expected-hash (copy-sequence hash))
         (expected-media-type (copy-sequence media-type))
         (expected-role (copy-sequence role))
         (epi-ledger-work-byte-limit 10)
         (epi-ledger-work-time-budget 1000.0)
         mutated)
    (let ((epi--yield-function
           (lambda ()
             (unless mutated
               (setq mutated t)
               (aset hash 0 ?b)
               (aset media-type 0 ?x)
               (aset role 0 ?x)))))
      (let ((ref (make-epi-object-ref
                  :hash hash :size 20
                  :media-type media-type :role role)))
        (should mutated)
        (should (equal expected-hash (epi-object-ref-hash ref)))
        (should (equal expected-media-type (epi-object-ref-media-type ref)))
        (should (equal expected-role (epi-object-ref-role ref)))))))

(ert-deftest epi-ledger-header-copies-callers-before-hash-yields ()
  (let* ((session-id
          (copy-sequence "11111111-1111-4111-8111-111111111111"))
         (created-at (copy-sequence "2026-07-21T18:42:17-07:00"))
         (project-root (copy-sequence "/tmp/epi-project/"))
         (mutated nil)
         (epi--yield-function
          (lambda ()
            (unless mutated
              (setq mutated t)
              (aset session-id 0 ?f)
              (aset created-at 0 ?1)
              (aset project-root 1 ?x))))
         (header (epi-ledger-seal-header
                  :session-id session-id :created-at created-at
                  :project-root project-root))
         (baseline (epi-ledger-render-header header))
         (read-session-id (epi-header-session-id header)))
    (should mutated)
    (should (equal "11111111-1111-4111-8111-111111111111"
                   (epi-header-session-id header)))
    (aset read-session-id 0 ?f)
    (should (equal baseline (epi-ledger-render-header header)))
    (should-error (setf (epi-header-format header) 2))))

(ert-deftest epi-ledger-header-snapshots-before-file-name-handlers ()
  (let* ((session-id
          (copy-sequence "11111111-1111-4111-8111-111111111111"))
         (created-at (copy-sequence "2026-07-21T18:42:17-07:00"))
         (project-root (copy-sequence "/hostile:epi-project/"))
         (handler 'epi-test-ledger--mutating-file-handler)
         (file-name-handler-alist `(("\\`/hostile:" . ,handler))))
    (cl-letf (((symbol-function handler)
               (lambda (operation &rest arguments)
                 (if (eq operation 'expand-file-name)
                     (let ((canonical
                            (substring-no-properties (car arguments))))
                       (aset session-id 0 ?f)
                       (aset created-at 0 ?1)
                       (aset (car arguments) 1 ?x)
                       canonical)
                   (let ((inhibit-file-name-handlers
                          (cons handler inhibit-file-name-handlers))
                         (inhibit-file-name-operation operation))
                     (apply operation arguments))))))
      (let ((header
             (epi-ledger-seal-header
              :session-id session-id :created-at created-at
              :project-root project-root)))
        (should (equal "11111111-1111-4111-8111-111111111111"
                       (epi-header-session-id header)))
        (should (equal "2026-07-21T18:42:17-07:00"
                       (epi-header-created-at header)))
        (should (equal "/hostile:epi-project/"
                       (epi-header-project-root header)))))))

(ert-deftest epi-ledger-header-byte-cap-precedes-ownership-copy ()
  (let ((epi-record-frame-byte-limit 128)
        (owned-string-calls 0)
        (original-owned-string (symbol-function 'epi-ledger--owned-string)))
    (cl-letf (((symbol-function 'epi-ledger--owned-string)
               (lambda (value)
                 (setq owned-string-calls (1+ owned-string-calls))
                 (funcall original-owned-string value))))
      (should-error
       (epi-ledger-seal-header
        :session-id "11111111-1111-4111-8111-111111111111"
        :created-at "2026-07-21T18:42:17-07:00"
        :project-root (concat "/" (make-string 1000 ?x) "/"))
       :type 'epi-limit-exceeded))
    (should (= owned-string-calls 0))))

(ert-deftest epi-ledger-header-sealing-proves-exact-rendered-size-before-copy ()
  (let* ((fixture-size
          (length (epi-test-ledger--fixture-bytes "ledger/header.org")))
         (arguments
          '(:session-id "11111111-1111-4111-8111-111111111111"
            :created-at "2026-07-21T18:42:17-07:00"
            :project-root "/tmp/epi-project/")))
    (let ((epi-record-frame-byte-limit fixture-size))
      (should (= fixture-size
                 (length
                  (epi-ledger-render-header
                   (apply #'epi-ledger-seal-header arguments))))))
    (let ((epi-record-frame-byte-limit (1- fixture-size))
          (owned-string-calls 0)
          (original-owned-string
           (symbol-function 'epi-ledger--owned-string)))
      (cl-letf (((symbol-function 'epi-ledger--owned-string)
                 (lambda (value)
                   (setq owned-string-calls (1+ owned-string-calls))
                   (funcall original-owned-string value))))
        (let ((condition
               (should-error
                (apply #'epi-ledger-seal-header arguments)
                :type 'epi-limit-exceeded)))
          (should (eq 'header-byte-limit
                      (epi-test-ledger--condition-code condition)))))
      (should (= owned-string-calls 0)))))

(ert-deftest epi-ledger-sealing-preflights-depth-before-ownership-copy ()
  (let ((draft (epi-test-ledger--message-draft))
        (deep "leaf"))
    (dotimes (_ 2000)
      (setq deep (vector deep)))
    (setcdr (assoc "content" (epi-draft-payload draft)) deep)
    (should-error
     (epi-ledger-seal-record
      draft
      "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
      1)
     :type 'epi-limit-exceeded)))

(ert-deftest epi-ledger-message-content-matrix-is-first-slice-closed ()
  (let ((text '(("type" . "text") ("text" . "hello")))
        (call '(("type" . "tool-call") ("call_id" . "call-1")
                ("name" . "read_file") ("arguments" . nil)
                ("order" . 0) ("group_id" . :null))))
    (dolist (case `(("tool" . [,text])
                    ("assistant" . [,text ,call])
                    ("assistant" . [,call ,call])
                    ("user" . [])))
      (let* ((draft (epi-test-ledger--message-draft))
             (payload (epi-draft-payload draft)))
        (setcdr (assoc "role" payload) (car case))
        (setcdr (assoc "content" payload) (cdr case))
        (should-error
         (epi-ledger-seal-record
          draft
          "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
          1)
         :type 'epi-ledger-format-error)))))

(ert-deftest epi-ledger-line-scanning-bounds-unterminated-prefix-work ()
  (let ((largest-fragment 0))
    (should-error
     (epi-ledger--line-at
      (make-string 1000000 ?x) 0 16
      (lambda (fragment)
        (setq largest-fragment (max largest-fragment (length fragment)))
        t))
     :type 'epi-limit-exceeded)
    (should (<= largest-fragment 16))))

(ert-deftest epi-ledger-line-scanning-yields-and-reports-limit-boundary ()
  (let ((epi-ledger-work-byte-limit 1000)
        (epi-ledger-work-time-budget 1000.0)
        (yields 0)
        condition)
    (cl-letf (((symbol-function 'epi--deadline-time) (lambda () 0.0))
              ((symbol-function 'epi--yield)
               (lambda () (setq yields (1+ yields)))))
      (setq condition
            (should-error
             (epi-ledger--line-at (make-string 6000 ?x) 0 5000)
             :type 'epi-limit-exceeded)))
    (should (= yields 5))
    (should (= 5000 (plist-get (car (cdr condition)) :offset)))))

(ert-deftest epi-ledger-json-line-cap-precedes-prefix-validation ()
  (let* ((frame (epi-ledger-render-record (epi-test-ledger--seal-message)))
         (begin "#+begin_epi-json\n")
         (json-start (+ (string-match (regexp-quote begin) frame)
                        (length begin)))
         (oversized (concat (substring frame 0 json-start)
                            "\"" (make-string 32 ?a) "\""))
         (prefix-validations 0)
         (original-prefix
          (symbol-function 'epi-ledger--json-prefix-with-cap-p))
         result)
    (let ((epi-record-json-byte-limit 16))
      (cl-letf (((symbol-function 'epi-ledger--json-prefix-with-cap-p)
                 (lambda (fragment limit offset)
                   (setq prefix-validations (1+ prefix-validations))
                   (funcall original-prefix fragment limit offset))))
        (setq result (epi-ledger--scan-frame oversized 0 1))))
    (should (eq 'invalid (plist-get result :state)))
    (should (eq 'record-json-byte-limit (plist-get result :code)))
    (should (= prefix-validations 0))))

(ert-deftest epi-ledger-json-prefix-must-fit-minimum-completion ()
  (let* ((frame (epi-ledger-render-record (epi-test-ledger--seal-message)))
         (begin "#+begin_epi-json\n")
         (json-start (+ (string-match (regexp-quote begin) frame)
                        (length begin)))
         (frame-prefix (substring frame 0 json-start)))
    (dolist (case `((,(concat "\"" (make-string 15 ?a)) 16 invalid)
                    (,(concat "\"" (make-string 13 ?a) "\\") 16 invalid)
                    ("{\"a\"" 5 invalid)
                    ("{\"a\"" 6 invalid)
                    ("{\"a\"" 7 incomplete)
                    ("{\"a\":0," 12 invalid)
                    ("{\"a\":0," 13 incomplete)
                    ("{\"a\":0,\"a" 13 invalid)
                    ("{\"a\":0,\"a" 14 incomplete)
                    ("9.999999999999999" 18 invalid)
                    ("9.999999999999999" 19 invalid)
                    ("9.999999999999999" 20 incomplete)))
      (pcase-let ((`(,json-prefix ,limit ,state) case))
        (let* ((epi-record-json-byte-limit limit)
               (result
                (epi-ledger--scan-frame
                 (concat frame-prefix (string-make-unibyte json-prefix))
                 0 1)))
          (should (eq state (plist-get result :state)))
          (when (eq state 'invalid)
            (should (eq 'record-json-byte-limit
                        (plist-get result :code)))))))))

(ert-deftest epi-ledger-payload-byte-cap-precedes-ownership-copy ()
  (let* ((draft (epi-test-ledger--message-draft))
         (content (epi-ledger--object-value
                   (epi-draft-payload draft) "content"))
         (canonical-copy-calls 0)
         (original-copy (symbol-function 'epi--canonical-copy))
         (epi-record-json-byte-limit 128))
    (setcdr (assoc "text" (aref content 0)) (make-string 1000 ?a))
    (cl-letf (((symbol-function 'epi--canonical-copy)
               (lambda (&rest arguments)
                 (setq canonical-copy-calls (1+ canonical-copy-calls))
                 (apply original-copy arguments))))
      (should-error
       (epi-ledger-seal-record
        draft
        "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
        1)
       :type 'epi-limit-exceeded))
    (should (= canonical-copy-calls 0))))

(ert-deftest epi-ledger-full-envelope-caps-precede-ownership-copy ()
  (let* ((previous
          "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1")
         (baseline (epi-ledger-seal-record
                    (epi-test-ledger--message-draft) previous 1))
         (full-size (length (epi-record-sealed-json baseline))))
    (dolist (limits `((:bytes ,(1- full-size) nil nil)
                      (:depth nil 3 nil)
                      (:items nil nil 5)))
      (pcase-let ((`(,_ ,byte-limit ,depth-limit ,item-limit) limits))
        (let ((epi-record-json-byte-limit
               (or byte-limit epi-record-json-byte-limit))
              (epi-json-depth-limit (or depth-limit epi-json-depth-limit))
              (epi-json-item-limit (or item-limit epi-json-item-limit))
              (canonical-copy-calls 0)
              (original-copy (symbol-function 'epi--canonical-copy)))
          (cl-letf (((symbol-function 'epi--canonical-copy)
                     (lambda (&rest arguments)
                       (setq canonical-copy-calls (1+ canonical-copy-calls))
                       (apply original-copy arguments))))
            (should-error
             (epi-ledger-seal-record
              (epi-test-ledger--message-draft) previous 1)
             :type 'epi-limit-exceeded))
          (should (= canonical-copy-calls 0)))))))

(ert-deftest epi-ledger-frame-cap-reserves-mandatory-suffix-bytes ()
  (let* ((frame (epi-ledger-render-record (epi-test-ledger--seal-message)))
         (end-marker "\n#+end_epi-json\n")
         (json-end (string-match (regexp-quote end-marker) frame))
         (json-only-prefix (substring frame 0 json-end))
         (short-end-prefix (substring frame 0 (- (length frame) 10))))
    (dolist (case `((,json-only-prefix . ,(1+ (length json-only-prefix)))
                    (,short-end-prefix . ,(+ 5 (length short-end-prefix)))))
      (let* ((epi-record-frame-byte-limit (cdr case))
             (result (epi-ledger--scan-frame (car case) 0 1)))
        (should (eq 'invalid (plist-get result :state)))
        (should (eq 'record-frame-byte-limit (plist-get result :code)))))))

(ert-deftest epi-ledger-envelope-validation-precedes-ownership-copy ()
  (dolist (field '(id at))
    (let* ((draft (epi-test-ledger--message-draft))
           (owned-string-calls 0)
           (original-owned-string
            (symbol-function 'epi-ledger--owned-string)))
      (pcase field
        ('id (setf (epi-draft-id draft) (make-string 100000 ?x)))
        ('at (setf (epi-draft-at draft) (make-string 100000 ?x))))
      (cl-letf (((symbol-function 'epi-ledger--owned-string)
                 (lambda (value)
                   (setq owned-string-calls (1+ owned-string-calls))
                   (funcall original-owned-string value))))
        (should-error
         (epi-ledger-seal-record
          draft
          "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
          1)
         :type 'epi-ledger-format-error))
      (should (= owned-string-calls 0)))))

(ert-deftest epi-ledger-multibyte-ascii-inputs-render-exact-unibyte-frames ()
  (let* ((draft (epi-test-ledger--message-draft))
         (previous
          (string-to-multibyte
           "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1")))
    (setf (epi-draft-id draft)
          (string-to-multibyte (epi-draft-id draft))
          (epi-draft-at draft)
          (string-to-multibyte (epi-draft-at draft))
          (epi-draft-turn draft)
          (string-to-multibyte (epi-draft-turn draft)))
    (let ((frame (epi-ledger-render-record
                  (epi-ledger-seal-record draft previous 1))))
      (should-not (multibyte-string-p frame))
      (should (equal frame
                     (substring
                      (epi-test-ledger--fixture-bytes
                       "ledger/one-message.org")
                      (length (epi-test-ledger--fixture-bytes
                               "ledger/header.org"))))))))

(defun epi-test-ledger--base-draft (type payload &rest envelope)
  "Return a draft of TYPE with PAYLOAD and ENVELOPE keyword fields."
  (apply #'make-epi-draft
         :id "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
         :type type
         :at "2026-07-21T18:45:02-07:00"
         :payload payload
         envelope))

(defun epi-test-ledger--valid-draft (type)
  "Return an individually valid schema-one draft of TYPE."
  (let ((operation "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        (turn "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
        (target "dddddddd-dddd-4ddd-8ddd-dddddddddddd")
        (hash "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"))
    (let ((draft
           (pcase type
      ('session-info
       (epi-test-ledger--base-draft
        type `(("session_id" . "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
               ("working_directory" . "/tmp/epi-project/")
               ("base_system_prompt" . "Be exact.")
               ("backend" . "test-backend") ("model" . "test-model")
               ("request_params" . nil) ("tools" . [])
               ("capability" . "openai-chat-completions/sequential-tools-v1"))))
      ('operation-started
       (epi-test-ledger--base-draft
        type `(("operation_id" . ,operation) ("kind" . "prompt"))
        :operation operation))
      ('turn-started
       (epi-test-ledger--base-draft
        type `(("turn_id" . ,turn) ("operation_id" . ,operation)
               ("attempt_id" . "ffffffff-ffff-4fff-8fff-ffffffffffff")
               ("message_id" . "11111111-1111-4111-8111-111111111111")
               ("working_directory" . "/tmp/epi-project/")
               ("base_system_prompt" . "Base") ("resources" . [])
               ("system_prompt" . "Base") ("backend" . "test-backend")
               ("model" . "test-model") ("request_params" . nil)
               ("tools" . []) ("snapshot_hash" . ,hash))
        :turn turn :operation operation))
      ('message
       (epi-test-ledger--base-draft
        type '(("role" . "assistant")
               ("content" . [( ("type" . "text") ("text" . "ok"))]))
        :turn turn))
      ('reasoning
       (epi-test-ledger--base-draft
        type `(("text" . "thinking") ("leg" . 0)
               ("replay" . ,epi-json-false)) :turn turn))
      ('leaf
       (epi-test-ledger--base-draft type nil :target target
                                    :operation operation))
      ('tool-planned
       (epi-test-ledger--base-draft
        type '(("call_id" . "call-1") ("name" . "read_file")
               ("arguments" . (("path" . "/tmp/a")))
               ("authority" . nil) ("order" . 0))
        :target target :turn turn :operation operation))
      ('tool-approved
       (epi-test-ledger--base-draft
        type '(("call_id" . "call-1") ("policy" . nil))
        :target target :turn turn :operation operation))
      ('tool-denied
       (epi-test-ledger--base-draft
        type '(("call_id" . "call-1") ("reason" . "policy")
               ("model_result" . "Denied"))
        :target target :turn turn :operation operation))
      ('tool-started
       (epi-test-ledger--base-draft
        type '(("call_id" . "call-1") ("tool_version" . "1"))
        :target target :turn turn :operation operation))
      ('tool-finished
       (epi-test-ledger--base-draft
        type '(("call_id" . "call-1") ("status" . "success")
               ("details" . nil) ("model_result" . "contents"))
        :target target :turn turn :operation operation))
      ((or 'turn-finished 'turn-failed 'turn-cancelled 'turn-interrupted)
       (epi-test-ledger--base-draft
        type (pcase type
               ('turn-finished `(("turn_id" . ,turn) ("status" . "success")))
               ('turn-failed `(("turn_id" . ,turn) ("code" . "provider")
                               ("details" . nil)))
               (_ `(("turn_id" . ,turn) (,(if (eq type 'turn-cancelled)
                                              "reason" "reason") . "user"))))
        :turn turn :operation operation))
      ((or 'operation-finished 'operation-failed 'operation-cancelled
           'operation-interrupted)
       (epi-test-ledger--base-draft
        type (pcase type
               ('operation-finished
                `(("operation_id" . ,operation) ("status" . "success")))
               ('operation-failed
                `(("operation_id" . ,operation) ("code" . "provider")
                  ("details" . nil)))
               (_ `(("operation_id" . ,operation) ("reason" . "user"))))
        :operation operation))
      ('recovery-origin
       (epi-test-ledger--base-draft
        type `(("source_path" . "/tmp/source.org")
               ("source_session_id" . "11111111-1111-4111-8111-111111111111")
               ("source_file_size" . 1024)
               ("source_header_sha256" . ,hash)
               ("source_valid_prefix_head_sha256" . ,hash)
               ("fragment_offset" . 1000) ("fragment_sha256" . ,hash)
               ("fragment_size" . 24)
               ("fragment_object" .
                (("hash" . ,hash) ("size" . 24)
                 ("media_type" . "application/octet-stream")
                 ("role" . "recovery-fragment")))
               ("destination_valid_prefix_head_sha256" . ,hash)
               ("source_evidence_sha256" . ,hash))))
             (_ (error "No test draft for %S" type)))))
      (setf (epi-draft-payload draft)
            (copy-tree (epi-draft-payload draft) t))
      draft)))

(defun epi-test-ledger--seal-draft-condition (draft &optional previous)
  "Return the structured condition raised while sealing DRAFT after PREVIOUS."
  (should-error
   (epi-ledger-seal-record
    draft
    (or previous
        "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1")
    1)
   :type 'epi-error))

(ert-deftest epi-ledger-focused-field-validators-fail-closed ()
  (let ((draft (epi-test-ledger--message-draft)))
    (setf (epi-draft-at draft) "2026-02-30T18:43:02-07:00")
    (should (eq 'invalid-timestamp
                (epi-test-ledger--condition-code
                 (epi-test-ledger--seal-draft-condition draft)))))
  (let ((draft (epi-test-ledger--message-draft)))
    (setf (epi-draft-id draft) "not-a-uuid")
    (should (eq 'invalid-id
                (epi-test-ledger--condition-code
                 (epi-test-ledger--seal-draft-condition draft)))))
  (let ((condition
         (epi-test-ledger--seal-draft-condition
          (epi-test-ledger--message-draft) (make-string 64 ?A))))
    (should (eq 'invalid-hash
                (epi-test-ledger--condition-code condition))))
  (dolist (case '((session-info . "/tmp/not-a-directory")
                  (turn-started . "relative/")))
    (let* ((draft (epi-test-ledger--valid-draft (car case)))
           (payload (epi-draft-payload draft)))
      (setcdr (assoc "working_directory" payload) (cdr case))
      (should (eq 'canonical-directory-required
                  (epi-test-ledger--condition-code
                   (epi-test-ledger--seal-draft-condition draft))))))
  (let ((record
         (epi-ledger--make-record
          :id "22222222-2222-4222-8222-222222222222" :schema "1")))
    (let ((condition
           (should-error (epi-ledger--validate-record-fields record)
                         :type 'epi-ledger-format-error)))
      (should (eq 'unknown-schema
                  (epi-test-ledger--condition-code condition)))))
  (let* ((draft (epi-test-ledger--message-draft))
         (payload (epi-draft-payload draft)))
    (setcdr (assoc "role" payload) "system")
    (should (eq 'invalid-role
                (epi-test-ledger--condition-code
                 (epi-test-ledger--seal-draft-condition draft)))))
  (let* ((draft (epi-test-ledger--message-draft))
         (payload (epi-draft-payload draft)))
    (setcdr (assoc "content" payload)
            [( ("type" . "image") ("url" . "https://invalid/"))])
    (should (eq 'unknown-content-type
                (epi-test-ledger--condition-code
                 (epi-test-ledger--seal-draft-condition draft)))))
  (let* ((draft (epi-test-ledger--valid-draft 'tool-planned))
         (payload (epi-draft-payload draft)))
    (setcdr (assoc "order" payload) -1)
    (should (eq 'invalid-integer
                (epi-test-ledger--condition-code
                 (epi-test-ledger--seal-draft-condition draft)))))
  (let* ((draft (epi-test-ledger--valid-draft 'reasoning))
         (payload (epi-draft-payload draft)))
    (setcdr (assoc "replay" payload) t)
    (should (eq 'false-required
                (epi-test-ledger--condition-code
                 (epi-test-ledger--seal-draft-condition draft)))))
  (let* ((draft (epi-test-ledger--valid-draft 'message))
         (payload (epi-draft-payload draft)))
    (setcdr (assoc "content" payload)
            `[( ("type" . "tool-call") ("call_id" . "call-1")
                ("name" . "read_file") ("arguments" . nil)
                ("order" . 0) ("group_id" . nil))])
    (should (eq 'null-required
                (epi-test-ledger--condition-code
                 (epi-test-ledger--seal-draft-condition draft)))))
  (let* ((draft (epi-test-ledger--valid-draft 'recovery-origin))
         (object (cdr (assoc "fragment_object"
                             (epi-draft-payload draft)))))
    (setcdr (assoc "role" object) "attachment")
    (should (eq 'invalid-role
                (epi-test-ledger--condition-code
                 (epi-test-ledger--seal-draft-condition draft))))))

(ert-deftest epi-ledger-rfc3339-validator-rejects-impossible-values ()
  (dolist (timestamp '("2026-00-01T00:00:00Z"
                       "2026-02-30T00:00:00Z"
                       "2026-01-01T24:00:00Z"
                       "2026-01-01T00:60:00Z"
                       "2026-01-01T00:00:60Z"
                       "1990-12-31T23:59:60Z"
                       "1990-12-31T15:59:60-08:00"
                       "2026-01-01t00:00:00z"
                       "2026-01-01T00:00:00"
                       "2026-01-01T00:00:00+24:00"
                       "2026-01-01T00:00:00+01:60"))
    (should-error
     (epi-ledger-seal-header
      :session-id "11111111-1111-4111-8111-111111111111"
      :created-at timestamp :project-root "/tmp/epi-project/")
     :type 'epi-ledger-format-error))
  (should
   (epi-header-p
    (epi-ledger-seal-header
     :session-id "11111111-1111-4111-8111-111111111111"
     :created-at "2024-02-29T23:59:59.123456+14:00"
     :project-root "/tmp/epi-project/")))
  (should
   (epi-header-p
    (epi-ledger-seal-header
     :session-id "11111111-1111-4111-8111-111111111111"
     :created-at "0000-02-29T00:00:00Z"
     :project-root "/tmp/epi-project/"))))

(ert-deftest epi-ledger-object-reference-size-honors-storage-cap ()
  (let* ((draft (epi-test-ledger--valid-draft 'recovery-origin))
         (payload (epi-draft-payload draft))
         (object (cdr (assoc "fragment_object" payload))))
    (setcdr (assoc "fragment_size" payload) epi-object-byte-limit)
    (setcdr (assoc "source_file_size" payload)
            (+ 1000 epi-object-byte-limit))
    (setcdr (assoc "size" object) epi-object-byte-limit)
    (should (epi-record-p
             (epi-ledger-seal-record
              draft
              "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
              1))))
  (let* ((draft (epi-test-ledger--valid-draft 'recovery-origin))
         (object (cdr (assoc "fragment_object"
                             (epi-draft-payload draft)))))
    (setcdr (assoc "size" object) (1+ epi-object-byte-limit))
    (should-error
     (epi-ledger-seal-record
      draft
      "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
      1)
     :type 'epi-limit-exceeded))
  (let* ((draft (epi-test-ledger--valid-draft 'recovery-origin))
         (payload (epi-draft-payload draft)))
    (setcdr (assoc "fragment_size" payload) (1+ epi-object-byte-limit))
    (setcdr (assoc "source_file_size" payload)
            (+ 1001 epi-object-byte-limit))
    (should-error
     (epi-ledger-seal-record
      draft
      "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
      1)
     :type 'epi-limit-exceeded))
  (let* ((draft (epi-test-ledger--valid-draft 'recovery-origin))
         (payload (epi-draft-payload draft))
         (object (cdr (assoc "fragment_object" payload))))
    (setcdr (assoc "size" object) 23)
    (let ((condition
           (epi-test-ledger--seal-draft-condition draft)))
      (should (eq 'fragment-size-mismatch
                  (epi-test-ledger--condition-code condition))))
    (setcdr (assoc "size" object) 24)
    (setcdr (assoc "hash" object) (make-string 64 ?a))
    (let ((condition
           (epi-test-ledger--seal-draft-condition draft)))
      (should (eq 'fragment-hash-mismatch
                  (epi-test-ledger--condition-code condition)))))
  (let ((epi-object-byte-limit 32)
        (epi-recovery-fragment-byte-limit 24))
    (let* ((draft (epi-test-ledger--valid-draft 'recovery-origin))
           (payload (epi-draft-payload draft))
           (object (cdr (assoc "fragment_object" payload))))
      (setcdr (assoc "fragment_size" payload) 25)
      (setcdr (assoc "source_file_size" payload) 1025)
      (setcdr (assoc "size" object) 25)
      (should-error
       (epi-ledger-seal-record
        draft
        "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
        1)
       :type 'epi-limit-exceeded)))
  (let ((epi-object-byte-limit 24)
        (epi-recovery-fragment-byte-limit 32))
    (let* ((draft (epi-test-ledger--valid-draft 'recovery-origin))
           (payload (epi-draft-payload draft))
           (object (cdr (assoc "fragment_object" payload))))
      (setcdr (assoc "fragment_size" payload) 25)
      (setcdr (assoc "source_file_size" payload) 1025)
      (setcdr (assoc "size" object) 25)
      (should-error
       (epi-ledger-seal-record
        draft
        "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
       1)
       :type 'epi-limit-exceeded))))

(ert-deftest epi-ledger-recovery-origin-is-an-exact-nonempty-tail ()
  (let* ((draft (epi-test-ledger--valid-draft 'recovery-origin))
         (payload (epi-draft-payload draft)))
    (setcdr (assoc "source_path" payload) "/tmp/a/../source.org")
    (should-error
     (epi-ledger-seal-record
      draft
      "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
      1)
     :type 'epi-ledger-format-error))
  (let* ((draft (epi-test-ledger--valid-draft 'recovery-origin))
         (payload (epi-draft-payload draft)))
    (setcdr (assoc "fragment_offset" payload) 999)
    (should-error
     (epi-ledger-seal-record
      draft
      "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
      1)
     :type 'epi-ledger-format-error))
  (let* ((draft (epi-test-ledger--valid-draft 'recovery-origin))
         (payload (epi-draft-payload draft))
         (object (cdr (assoc "fragment_object" payload))))
    (setcdr (assoc "fragment_offset" payload) 1024)
    (setcdr (assoc "fragment_size" payload) 0)
    (setcdr (assoc "size" object) 0)
    (should-error
     (epi-ledger-seal-record
      draft
      "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
      1)
     :type 'epi-ledger-format-error))
  (let* ((draft (epi-test-ledger--valid-draft 'recovery-origin))
         (object (cdr (assoc "fragment_object"
                             (epi-draft-payload draft)))))
    (setcdr (assoc "hash" object) (make-string 64 ?b))
    (should-error
     (epi-ledger-seal-record
      draft
      "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
      1)
     :type 'epi-ledger-format-error)))

(ert-deftest epi-ledger-all-first-slice-record-schemas-are-individually-closed ()
  (dolist (type epi-test-ledger--record-types)
    (let* ((draft (epi-test-ledger--valid-draft type))
           (record
            (epi-ledger-seal-record
             draft
             "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
             1)))
      (should (eq type (epi-record-type record)))
      (setf (epi-draft-payload draft)
            (cons '("unknown" . "forbidden")
                  (epi-draft-payload draft)))
      (should-error
       (epi-ledger-seal-record
        draft
        "42a532655547cb5af87ee33d3df6fd60944b3d5f44411063d73f4ade5dc661b1"
        1)
       :type 'epi-ledger-format-error))))

(provide 'epi-ledger-codec-test)
;;; epi-ledger-codec-test.el ends here
