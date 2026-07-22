;;; generate-jcs-goldens.el --- Regenerate pinned JCS fixtures -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley
;; Keywords: tools

;;; Commentary:

;; Development-only fixture generator.  It sends fixed JSON inputs to the
;; pinned upstream canonicalizer in a separate Node process.  Runtime tests
;; consume the checked-in result and never execute JavaScript.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(load (expand-file-name
       "fixtures/jcs/appendix-b.el"
       (file-name-directory (file-truename (or load-file-name buffer-file-name))))
      nil t)

(defconst epi-golden--repository-root
  (file-name-directory
   (directory-file-name
    (file-name-directory
     (file-truename (or load-file-name buffer-file-name)))))
  "Repository root containing the checked-in JCS fixture.")

(defconst epi-golden--oracle-commit
  "19d51d7fe467d4706a3ff08adf8a748f29fc21e0"
  "Pinned upstream JCS oracle commit.")

(defconst epi-golden--canonicalize-sha256
  "f9f498b55c99eefe348c99018ddcfe08efa6f7ff96b9ba9dce4b7090b33c4438"
  "Pinned canonicalizer source hash.")

(defconst epi-golden--verify-sha256
  "314898c8f08ed5b14a3f5903b27ec4789ac5dc7fd59a168e72a6d876f192be6f"
  "Pinned vector verifier source hash.")

(defconst epi-golden--vector-corpus-sha256
  "823c07e7e1b1bbfc903354435b508026e43d2bf3183450a8773cf6cab7668933"
  "Pinned bytewise-sorted shipped-vector corpus digest.")

(defconst epi-golden--verifier-files
  '("arrays.json" "french.json" "structures.json"
    "unicode.json" "values.json" "weird.json")
  "Exact shipped-vector files emitted by the pinned verifier.")

(defconst epi-golden--node-driver
  (concat
   "const fs=require('fs');"
   "const canonicalize=require(process.argv[1]);"
   "const request=JSON.parse(fs.readFileSync(0,'utf8'));"
   "const appendix=request.appendix.map((hex)=>{"
   "const value=Buffer.from(hex,'hex').readDoubleBE();"
   "if(!Number.isFinite(value)){return {hex:hex,outcome:'reject'};}"
   "const canonical=canonicalize(value);"
   "return {hex:hex,outcome:'canonical',canonical:canonical};});"
   "const custom=request.custom.map((x)=>canonicalize(JSON.parse(x)));"
   "process.stdout.write(JSON.stringify({appendix_b:appendix,custom:custom})+'\\n');")
  "JavaScript expression run outside the repository to invoke the oracle.")

(defconst epi-golden--cases
  '(("unicode-key-order" .
     "{\"€\":\"Euro Sign\",\"\\r\":\"Carriage Return\",\"דּ\":\"Hebrew Letter Dalet With Dagesh\",\"1\":\"One\",\"😀\":\"Emoji: Grinning Face\",\"\":\"Control\",\"ö\":\"Latin Small Letter O With Diaeresis\"}")
    ("escaping" .
     "{\"slash\":\"/\",\"controls\":\"\\b\\t\\n\\f\\r\\u0000\\u001f\",\"quote\":\"\\\"\\\\\"}")
    ("nested" .
     "{\"z\":[3,{\"b\":false,\"a\":null}],\"a\":true}")
    ("number-boundaries" .
     "[-0,0.000001,0.0000001,100000000000000000000.0,1e21,9.999999999999997e22]"))
  "Named fixed inputs independently canonicalized by the pinned oracle.")

(defvar epi-golden-skip-main nil
  "When non-nil, define generator helpers without rewriting the fixture.")

(defun epi-golden--process-output (program &rest arguments)
  "Return trimmed output from PROGRAM invoked with ARGUMENTS."
  (with-temp-buffer
    (let ((status (apply #'process-file program nil t nil arguments)))
      (unless (and (integerp status) (zerop status))
        (error "%s exited %S: %s" program status (buffer-string)))
      (string-trim-right (buffer-string)))))

(defun epi-golden--canonicalize (oracle appendix-hex custom-inputs)
  "Canonicalize APPENDIX-HEX and CUSTOM-INPUTS through ORACLE source."
  (let ((payload
         (json-serialize
          (list :appendix appendix-hex :custom custom-inputs))))
    (with-temp-buffer
      (insert payload)
      (let ((status
             (call-process-region
              (point-min) (point-max) "node" t t nil
              "--eval" epi-golden--node-driver oracle)))
        (unless (and (integerp status) (zerop status))
          (error "Node JCS oracle exited %S: %s" status (buffer-string)))
        (cons payload
              (json-parse-string
               (buffer-string)
               :object-type 'hash-table :array-type 'array
               :null-object :null
               :false-object :false))))))

(defun epi-golden--verifier-output-valid-p (output)
  "Return non-nil when verifier OUTPUT proves every shipped vector passed."
  (and (= 1 (cl-count "All tests succeeded!"
                      (split-string output "\n" t)
                      :test #'equal))
       (not (string-match-p
             "THE TEST ABOVE FAILED\\|\\*\\*\\*\\*\\*\\* ERRORS:"
             output))))

(defun epi-golden--normalize-verifier-output (output)
  "Return deterministic file-sorted evidence from verifier OUTPUT."
  (unless (epi-golden--verifier-output-valid-p output)
    (error "Pinned JCS shipped-vector verification did not succeed"))
  (let ((blocks (make-hash-table :test #'equal))
        current-name current-lines marker-seen)
    (cl-labels
        ((finish-block
          ()
          (when current-name
            (when (gethash current-name blocks)
              (error "Duplicate JCS verifier block: %s" current-name))
            (unless current-lines
              (error "Empty JCS verifier block: %s" current-name))
            (puthash current-name (nreverse current-lines) blocks)
            (setq current-name nil current-lines nil))))
      (dolist (line (split-string output "\n" nil))
        (cond
         ((string-match "\\`File: \\(.+\\)\\'" line)
          (finish-block)
          (setq current-name (match-string 1 line))
          (unless (member current-name epi-golden--verifier-files)
            (error "Unexpected JCS verifier file: %s" current-name)))
         ((equal line "All tests succeeded!")
          (finish-block)
          (setq marker-seen t))
         ((string-empty-p line))
         ((and current-name
               (string-match-p
                "\\`[0-9a-f][0-9a-f]\\(?: [0-9a-f][0-9a-f]\\)*\\'"
                line))
          (push line current-lines))
         (t (error "Unrecognized JCS verifier output line: %s" line))))
      (finish-block))
    (unless marker-seen
      (error "JCS verifier success marker is missing"))
    (dolist (name epi-golden--verifier-files)
      (unless (gethash name blocks)
        (error "Missing JCS verifier block: %s" name)))
    (concat
     (mapconcat
      (lambda (name)
        (concat "File: " name "\n"
                (mapconcat #'identity (gethash name blocks) "\n")))
      epi-golden--verifier-files
      "\n\n")
     "\n\nAll tests succeeded!\n")))

(defun epi-golden--verify-oracle-vectors (root)
  "Run ROOT's shipped-vector verifier and require its success marker."
  (let ((output
         (epi-golden--process-output
          "node" (expand-file-name "node-es6/verify-canonicalization.js"
                                    root))))
    (unless (epi-golden--verifier-output-valid-p output)
      (error "Pinned JCS shipped-vector verification did not succeed"))
    (epi-golden--normalize-verifier-output output)))

(defun epi-golden--fixture-bytes ()
  "Return deterministic bytes for the independently generated fixture."
  (let* ((root (or (getenv "JCS_ORACLE_ROOT")
                   (error "JCS_ORACLE_ROOT is required")))
         (canonicalizer (expand-file-name "node-es6/canonicalize.js" root))
         (appendix-file
          (expand-file-name "test/fixtures/jcs/appendix-b.el"
                            epi-golden--repository-root))
         (appendix-bytes (epi-golden--literal-bytes appendix-file))
         (appendix-hex
          (vconcat (mapcar #'car epi-test-jcs-appendix-b)))
         (inputs (vconcat (mapcar #'cdr epi-golden--cases)))
         (normalized-verifier-output
          (epi-golden--verify-oracle-vectors root))
         (result
          (epi-golden--canonicalize canonicalizer appendix-hex inputs))
         (payload (car result))
         (oracle-result (cdr result))
         (appendix-results (gethash "appendix_b" oracle-result))
         (canonical (gethash "custom" oracle-result))
         (node-version (epi-golden--process-output "node" "--version"))
         (appendix
          (vconcat
           (mapcar
            (lambda (entry)
              (let ((outcome (gethash "outcome" entry))
                    (canonical-number (gethash "canonical" entry)))
                (append
                 `(("hex" . ,(gethash "hex" entry))
                   ("outcome" . ,outcome))
                 (when canonical-number
                   `(("canonical" . ,canonical-number)
                     ("sha256" . ,(secure-hash 'sha256
                                                canonical-number)))))))
            (append appendix-results nil))))
         (cases
          (vconcat
           (cl-mapcar
            (lambda (source bytes)
              `(("name" . ,(car source))
                ("input" . ,(cdr source))
                ("canonical" . ,bytes)
                ("sha256" . ,(secure-hash 'sha256 bytes))))
            epi-golden--cases (append canonical nil))))
         (document
          `(("metadata" .
             (("repository" . "https://github.com/cyberphone/json-canonicalization")
              ("commit" . ,epi-golden--oracle-commit)
              ("canonicalize_sha256" . ,epi-golden--canonicalize-sha256)
              ("verify_canonicalization_sha256" . ,epi-golden--verify-sha256)
              ("node_version" . ,node-version)
              ("canonicalizer_command_argv" .
               ["node" "--eval" ,epi-golden--node-driver
                "$JCS_ORACLE_ROOT/node-es6/canonicalize.js"])
              ("verifier_command_argv" .
               ["node"
                "$JCS_ORACLE_ROOT/node-es6/verify-canonicalization.js"])
              ("verifier_success_marker" . "All tests succeeded!")
              ("verifier_output_normalization" . "sort-file-blocks-v1")
              ("shipped_vector_corpus_sha256" .
               ,epi-golden--vector-corpus-sha256)
              ("driver_sha256" . ,(secure-hash 'sha256
                                                epi-golden--node-driver))
              ("input_sha256" . ,(secure-hash 'sha256 appendix-bytes))
              ("oracle_request_sha256" . ,(secure-hash 'sha256 payload))
              ("normalized_verifier_output_sha256" .
               ,(secure-hash 'sha256 normalized-verifier-output))))
            ("appendix_b" . ,appendix)
            ("cases" . ,cases))))
    (unless (= (length appendix) (length epi-test-jcs-appendix-b))
      (error "JCS oracle returned %d Appendix B rows, required %d"
             (length appendix) (length epi-test-jcs-appendix-b)))
    (unless (= (length cases) (length epi-golden--cases))
      (error "JCS oracle returned %d custom rows, required %d"
             (length cases) (length epi-golden--cases)))
    (encode-coding-string (concat (json-encode document) "\n")
                          'utf-8-unix t)))

(defun epi-golden--literal-bytes (file)
  "Return literal unibyte contents of FILE, or nil when absent."
  (when (file-exists-p file)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun epi-golden-main ()
  "Regenerate or verify the pinned independent JCS fixture."
  (let* ((file (expand-file-name "test/fixtures/jcs/independent-goldens.json"
                                 epi-golden--repository-root))
         (bytes (epi-golden--fixture-bytes))
         (before (epi-golden--literal-bytes file)))
    (if (equal (getenv "EPI_UPDATE_GOLDENS") "1")
        (let ((coding-system-for-write 'no-conversion)
              (write-region-annotate-functions nil)
              (write-region-post-annotation-function nil))
          (make-directory (file-name-directory file) t)
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert bytes)
            (write-region (point-min) (point-max) file nil 'silent))
          (princ (format "Wrote %s\n" file)))
      (unless (equal before bytes)
        (error "JCS golden fixture differs; rerun with EPI_UPDATE_GOLDENS=1"))
      (princ "JCS golden fixture is current\n"))))

(unless epi-golden-skip-main
  (epi-golden-main))

(provide 'generate-jcs-goldens)
;;; generate-jcs-goldens.el ends here
