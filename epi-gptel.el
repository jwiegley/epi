;;; epi-gptel.el --- Pinned GPTel compatibility seam -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (gptel "0.9.9.5"))
;; Keywords: tools
;; URL: https://github.com/jwiegley/dot-emacs

;;; Commentary:

;; This is Epi's sole version-sensitive GPTel boundary.  It realizes requests
;; through the pinned GPTel request machinery, then guards the classic OpenAI
;; streaming seam closely enough to support one sequential tool call per HTTP
;; leg.  Provider communication, response parsing, and the request FSM remain
;; GPTel-owned.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'lisp-mode)
(require 'map)
(require 'seq)
(require 'subr-x)
(require 'epi)
(require 'gptel)
(require 'gptel-request)
(require 'gptel-openai)

(defconst epi-gptel-capability
  'openai-chat-completions/sequential-tools-v1
  "The only provider capability enabled by the first Epi slice.")

(defconst epi-gptel--required-version "0.9.9.5"
  "Exact GPTel version required by this adapter.")

(defconst epi-gptel--required-commit
  "8701e2bd80c5d2091ce2decef5d34d6fce4a3ada"
  "Exact GPTel source commit required by this adapter.")

(defconst epi-gptel-source-contract
  '((request/parse-tools
     :name gptel--parse-tools :kind cl-defgeneric
     :file "gptel-request.el" :lines "1688-1738"
     :source-sha256 "ccd67eb7632f0b136e55cf57202c2da45b516ddac8a0fbe919d6874045d24d65")
    (request/parse-tool-results
     :name gptel--parse-tool-results :kind cl-defgeneric
     :file "gptel-request.el" :lines "1740-1744"
     :source-sha256 "e59587b7684a337c50eda977dc99eeb361567af09ac170359465e86419588141")
    (request/transitions
     :name gptel-request--transitions :kind defvar
     :file "gptel-request.el" :lines "1799-1817"
     :source-sha256 "e6b039a74bd7987e8bf61a2c755857e60fa2cc636223414801a3cad854fc2268")
    (request/handlers
     :name gptel-request--handlers :kind defvar
     :file "gptel-request.el" :lines "1819-1841"
     :source-sha256 "8debd6c5a7eda019a41ae6c77b59e14875cfacaa2f8f028087ff909ece9cc4cc")
    (request/fsm-transition
     :name gptel--fsm-transition :kind defun
     :file "gptel-request.el" :lines "1869-1881"
     :source-sha256 "d564e89e7d24d549fd36d8398a55d3e4ed51207fe52609d806dab73877672d35")
    (request/fsm-next
     :name gptel--fsm-next :kind defun
     :file "gptel-request.el" :lines "1883-1893"
     :source-sha256 "12144b5e9b9cbf4d946d293d3535a176126400f2a5c25f69dc2127e13e761236")
    (request/wait
     :name gptel--handle-wait :kind defun
     :file "gptel-request.el" :lines "1899-1913"
     :source-sha256 "c7328acba2cde68ec4c77f6182bd687246207471f8c16e1646196ab356f957de")
    (request/process-tool-call
     :name gptel--process-tool-call :kind defun
     :file "gptel-request.el" :lines "1915-1939"
     :source-sha256 "1d6371e3756a73e1294eefa96a1f5567e5a7f57842f2132b475500692d386a73")
    (request/tool
     :name gptel--handle-tool-use :kind defun
     :file "gptel-request.el" :lines "1941-1993"
     :source-sha256 "cadcec014c144abd9951b701b0ba34392f5adeadb94beb360962862010e76c5c")
    (request/map-tool-args
     :name gptel--map-tool-args :kind defun
     :file "gptel-request.el" :lines "1995-2004"
     :source-sha256 "64b5ddb101e38385460804baf47c765c69c9e7cf46376b99a77114fa2442d41b")
    (request/tool-result
     :name gptel--handle-tool-result :kind defun
     :file "gptel-request.el" :lines "2006-2018"
     :source-sha256 "fbc5aaf2832cfcab9203e03fcb545d3e113677f48dda964630e5396e43c1fb59")
    (request/post
     :name gptel--handle-post :kind defun
     :file "gptel-request.el" :lines "2020-2024"
     :source-sha256 "c1d8566e09ab9d8e8a05853eca3018f5e17f8dfabc9d16cb23986b58fa1b3c9a")
    (request/request
     :name gptel-request :kind cl-defun
     :file "gptel-request.el" :lines "2038-2314"
     :source-sha256 "e9f9f2d08ea24c0b2cb2e6a772817fa3ec6536f7d7cdd945f48b217b91a6e384")
    (request/realize
     :name gptel--realize-query :kind defun
     :file "gptel-request.el" :lines "2316-2366"
     :source-sha256 "75861daf2fd2a4ff79a2d3f569248c8dcabc63dc61dd0269cf7744860aa163ed")
    (request/abort
     :name gptel-abort :kind defun
     :file "gptel-request.el" :lines "2368-2394"
     :source-sha256 "8adbfa59142d064365fe53296626edb574dce5c87f842bbfc06d99d2420601dd")
    (request/parse-buffer-generic
     :name gptel--parse-buffer :kind cl-defgeneric
     :file "gptel-request.el" :lines "2438-2444"
     :source-sha256 "5089f1b14e3186edef8218c26370292eee75b8f70645fab78c235fcb8888d1b4")
    (request/parse-list-and-insert
     :name gptel--parse-list-and-insert :kind defun
     :file "gptel-request.el" :lines "2446-2480"
     :source-sha256 "cd64b550c3fa4058c674d51fe7670609e531dc2b55e65e2ad476c4797fffb072")
    (request/parse-list-generic
     :name gptel--parse-list :kind cl-defgeneric
     :file "gptel-request.el" :lines "2482-2489"
     :source-sha256 "4bdde434b72c9ab865ee790c1b6cbac8236d9b69d3b1b2b6dbc22e3aa88c7032")
    (request/request-data-generic
     :name gptel--request-data :kind cl-defgeneric
     :file "gptel-request.el" :lines "2597-2602"
     :source-sha256 "7bd39399f1e47f20124f01df852dcd4e8ded503614607643481af8b52bbc19c1")
    (request/curl-get-response
     :name gptel-curl-get-response :kind defun
     :file "gptel-request.el" :lines "2856-2925"
     :source-sha256 "e64e4bb925c4d7f5b0fe0e2793e4aef7a67a5b1c7b93d812236fd51ed413a3d7")
    (request/stream-cleanup
     :name gptel-curl--stream-cleanup :kind defun
     :file "gptel-request.el" :lines "2966-3014"
     :source-sha256 "6754b8f0d1bf539af170cb8512d0a8865a73ff0006a4f187f29aaea220353af1")
    (request/stream-filter
     :name gptel-curl--stream-filter :kind defun
     :file "gptel-request.el" :lines "3016-3103"
     :source-sha256 "72858653817d194096b16dc0c717f3595396a1b3b05ea5ee7f0cc32ad0424c0b")
    (request/parse-stream-generic
     :name gptel-curl--parse-stream :kind cl-defgeneric
     :file "gptel-request.el" :lines "3105-3115"
     :source-sha256 "4181fc8df29a6897a7a5e2e42f986e26ca92ba3bd82f38da3d9a45dcdcf46893")
    (openai/parse-stream
     :name gptel-curl--parse-stream :kind cl-defmethod
     :file "gptel-openai.el" :lines "94-181"
     :source-sha256 "2dca0b34c3d6ddda8187c5018b9cb52a75b9e75134050578c9339e8f00332d26")
    (openai/request-data
     :name gptel--request-data :kind cl-defmethod
     :file "gptel-openai.el" :lines "217-250"
     :source-sha256 "557d3bcf8637302b9acc8cbcd51decd921b645e77c2fdedb4b6504178599ec53")
    (openai/parse-tool-results
     :name gptel--parse-tool-results :kind cl-defmethod
     :file "gptel-openai.el" :lines "300-309"
     :source-sha256 "5cbd1f73886ee0bbeab338f2d4f6e28320a50ddef726a09118a87f34326ea802")
    (openai/format-tool-id
     :name gptel--openai-format-tool-id :kind defun
     :file "gptel-openai.el" :lines "312-323"
     :source-sha256 "13375d8d8b390649630699a07d4ce5f20a9b0f6108bfd4e441c625f8ede45fc4")
    (openai/parse-list
     :name gptel--parse-list :kind cl-defmethod
     :file "gptel-openai.el" :lines "334-363"
     :source-sha256 "90230ddd955253aec297f3109315d3f7c5d7d95994a2717d2f0a1eae0f07827e")
    (openai/parse-buffer
     :name gptel--parse-buffer :kind cl-defmethod
     :file "gptel-openai.el" :lines "365-418"
     :source-sha256 "2ab106d4a9de6e4a9892101a19d1ebdf7870ab6837a6c7788ae7a1d6a157a879"))
  "Exact pinned source forms on which the adapter's GPTel seam depends.")

(defconst epi-gptel--fixture-header-ok
  "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
  "Synthetic successful HTTP header used by the offline fixture transport.")

(defconst epi-gptel--fixture-header-error
  "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n"
  "Synthetic error HTTP header used by the offline fixture transport.")

(defun epi-gptel--classic-openai-stream-method ()
  "Return GPTel's unqualified classic OpenAI stream parser method."
  (let* ((generic (cl--generic 'gptel-curl--parse-stream))
         (entry
          (and generic
               (cl--generic-member-method
                '(gptel-openai t) nil
                (cl--generic-method-table generic)))))
    (car entry)))

(defconst epi-gptel--stock-openai-stream-parser
  (when-let* ((method (epi-gptel--classic-openai-stream-method)))
    (cl--generic-method-function method))
  "Captured primary classic OpenAI stream parser method.")

(defconst epi-gptel--stock-handle-wait
  (symbol-function 'gptel--handle-wait)
  "Captured pinned GPTel WAIT handler.")

(defconst epi-gptel--stock-handle-tool-use
  (symbol-function 'gptel--handle-tool-use)
  "Captured pinned GPTel TOOL handler.")

(defconst epi-gptel--stock-stream-filter
  (symbol-function 'gptel-curl--stream-filter)
  "Captured pinned GPTel Curl stream filter.")

(defconst epi-gptel--stock-parse-list-and-insert
  (symbol-function 'gptel--parse-list-and-insert)
  "Captured pinned GPTel typed-history insertion helper.")

(defconst epi-gptel-runtime-contract
  `((gptel--handle-wait
     :object ,epi-gptel--stock-handle-wait
     :printed-sha256 "71dc413a2e4f3aee78796dd03c6512d4d4c3c4286710a368fe1097d6000c1913")
    (gptel--handle-tool-use
     :object ,epi-gptel--stock-handle-tool-use
     :printed-sha256 "7733e71173e4f948915954451ea410f7e26f130cd074fecf2725ff7a85049bbe")
    (gptel-curl--stream-filter
     :object ,epi-gptel--stock-stream-filter
     :printed-sha256 "0933daa08e1d0315e35f47511b5ed14579f9e4c0079f096e9f564c00cce915db")
    (gptel--parse-list-and-insert
     :object ,epi-gptel--stock-parse-list-and-insert
     :printed-sha256 "5a98d9ff32a7cdb0faa9d4511e563424f99e174934dc87c0f4901f0abdc56ebc"))
  "Captured runtime objects delegated to exactly, with diagnostic hashes.")

(defconst epi-gptel--stock-openai-stream-parser-hash
  "94bc25848ab0331246cf87f30221fa7ff52ad6b06d5fe36a0d6c84b66120c648"
  "Printed SHA-256 of the captured classic OpenAI primary parser method.")

(defvar epi-gptel--fixture-legs nil
  "Dynamically bound raw legs consumed by the offline fixture transport.")

(defvar epi-gptel--fixture-options nil
  "Dynamically bound options for the offline fixture transport.")

(defvar epi-gptel--fixture-pending nil
  "Dynamically bound FIFO of offline fixture delivery jobs.")

(defvar epi-gptel--fixture-processes nil
  "Dynamically bound fixture processes requiring final cleanup.")

(cl-defstruct (epi-gptel-snapshot
               (:constructor epi-gptel--snapshot-create-raw)
               (:copier nil))
  "Provider-neutral immutable input to one GPTel request loop."
  backend model system history prompt tools request-params transport)

(cl-defstruct (epi-gptel-event
               (:constructor epi-gptel--event-create-raw)
               (:copier nil))
  "A copied provider event emitted by the GPTel seam."
  kind text call-id name arguments result code raw-byte-count member-count)

(cl-defstruct (epi-gptel-request
               (:constructor epi-gptel--request-create)
               (:copier nil))
  "Opaque state for one live GPTel request loop."
  buffer fsm snapshot enqueue tools
  (continuations (make-hash-table :test #'equal))
  (attestations (make-hash-table :test #'equal))
  (seen-call-ids (make-hash-table :test #'equal))
  terminal-p terminal-kind terminal-code abort-requested
  watchdog abort-timer next-leg-p
  (leg-raw-bytes 0) (turn-raw-bytes 0)
  (leg-output-bytes 0) (turn-output-bytes 0)
  (audit-offset 1) audit-call-id audit-name audit-fragments
  (audit-argument-bytes 0)
  audit-saw-text audit-saw-tool audit-done
  (leg-index 0) leg-finished-p (tool-count 0))

(cl-defun epi-gptel-snapshot-create
    (&key backend model system history prompt tools request-params
          (transport 'curl))
  "Create a copied provider-neutral GPTel snapshot.
BACKEND is an exact registered backend name and MODEL its exact model symbol.
SYSTEM, HISTORY, PROMPT, TOOLS, and REQUEST-PARAMS describe one frozen turn.
TRANSPORT must be `curl' for the first-slice capability."
  (unless (and (proper-list-p history) (proper-list-p tools))
    (epi-gptel--signal-incompatible 'invalid-snapshot-sequence))
  (epi-gptel--snapshot-create-raw
   :backend (and backend (epi--plain-string-copy backend))
   :model model
   :system (and system (epi--plain-string-copy system))
   :history (mapcar #'epi--canonical-copy history)
   :prompt (and prompt (epi--plain-string-copy prompt))
   :tools (mapcar #'epi--canonical-copy tools)
   :request-params (epi-gptel--copy-request-value request-params)
   :transport transport))

(defun epi-gptel-request-false-sentinel ()
  "Return GPTel's request-local representation of JSON false."
  :json-false)

(defun epi-gptel--signal-incompatible (code &rest fields)
  "Signal a structured incompatibility CODE with redacted FIELDS."
  (epi--signal 'epi-gptel-incompatible (append (list :code code) fields)))

(defun epi-gptel--private-snapshot (snapshot)
  "Return a fully owned request-local copy of caller-visible SNAPSHOT."
  (condition-case nil
      (epi-gptel-snapshot-create
       :backend (epi-gptel-snapshot-backend snapshot)
       :model (epi-gptel-snapshot-model snapshot)
       :system (epi-gptel-snapshot-system snapshot)
       :history (epi-gptel-snapshot-history snapshot)
       :prompt (epi-gptel-snapshot-prompt snapshot)
       :tools (epi-gptel-snapshot-tools snapshot)
       :request-params (epi-gptel-snapshot-request-params snapshot)
       :transport (epi-gptel-snapshot-transport snapshot))
    (error (epi-gptel--signal-incompatible 'invalid-snapshot))))

(defun epi-gptel--runtime-object-hash (object)
  "Return a diagnostic SHA-256 for loaded function OBJECT."
  (secure-hash 'sha256 (prin1-to-string object)))

(defun epi-gptel--copy-request-value (value)
  "Validate and recursively copy JSON-plist request VALUE.
Objects must be proper keyword plists and arrays must be vectors."
  (let ((visiting (make-hash-table :test #'eq)))
    (cl-labels
        ((invalid ()
           (epi-gptel--signal-incompatible 'invalid-request-params))
         (copy-composite
          (object copier)
          (when (gethash object visiting) (invalid))
          (puthash object t visiting)
          (unwind-protect (funcall copier)
            (remhash object visiting)))
         (copy-value
          (item)
          (cond
           ((or (null item) (eq item t)
                (eq item epi-json-false) (eq item epi-json-null))
            item)
           ((stringp item)
            (unless (epi--canonical-string-p item) (invalid))
            (epi--plain-string-copy item))
           ((integerp item)
            (unless (<= (- epi--maximum-safe-integer)
                        item epi--maximum-safe-integer)
              (invalid))
            item)
           ((floatp item)
            (unless (epi--finite-number-p item) (invalid))
            item)
           ((vectorp item)
            (copy-composite
             item
             (lambda ()
               (vconcat
                (cl-loop for child across item
                         collect (copy-value child))))))
           ((consp item)
            (unless (and (proper-list-p item)
                         (zerop (% (length item) 2)))
              (invalid))
            (copy-composite
             item
             (lambda ()
               (let ((seen (make-hash-table :test #'eq)) copied)
                 (cl-loop for (key child) on item by #'cddr
                          do
                          (unless (and (keywordp key)
                                       (not (gethash key seen)))
                            (invalid))
                          (puthash key t seen)
                          (push key copied)
                          (push (copy-value child) copied))
                 (nreverse copied)))))
           (t (invalid)))))
      (copy-value value))))

(defun epi-gptel--translate-json-sentinels (value)
  "Copy VALUE while translating Epi JSON sentinels for GPTel."
  (cond
   ((eq value epi-json-false) :json-false)
   ((eq value epi-json-null) :null)
   ((stringp value) (epi--plain-string-copy value))
   ((vectorp value)
    (vconcat
     (mapcar #'epi-gptel--translate-json-sentinels (append value nil))))
   ((consp value)
    (cons (epi-gptel--translate-json-sentinels (car value))
          (epi-gptel--translate-json-sentinels (cdr value))))
   (t value)))

(defun epi-gptel--verified-runtime-identities ()
  "Return hashes for the exact captured runtime objects after verifying them."
  (let ((verified
         (mapcar
          (lambda (entry)
            (let* ((symbol (car entry))
                   (captured (plist-get (cdr entry) :object))
                   (current (and (fboundp symbol) (symbol-function symbol)))
                   (expected (plist-get (cdr entry) :printed-sha256))
                   (observed
                    (and current (epi-gptel--runtime-object-hash current))))
              (unless (and (eq captured current) (equal expected observed))
                (epi-gptel--signal-incompatible
                 'gptel-runtime-object-mismatch :function symbol))
              (cons symbol observed)))
          epi-gptel-runtime-contract))
        (current-primary
         (when-let* ((method (epi-gptel--classic-openai-stream-method)))
           (cl--generic-method-function method))))
    (unless (and (eq epi-gptel--stock-openai-stream-parser current-primary)
                 (equal epi-gptel--stock-openai-stream-parser-hash
                        (and current-primary
                             (epi-gptel--runtime-object-hash
                              current-primary))))
      (epi-gptel--signal-incompatible
       'gptel-runtime-object-mismatch
       :function 'openai/parse-stream-primary))
    (append
     verified
     (list (cons 'openai/parse-stream-primary
                 epi-gptel--stock-openai-stream-parser-hash)))))

(defun epi-gptel--source-root ()
  "Return the exact source root from which pinned GPTel was loaded."
  (let* ((configured (getenv "GPTEL_ROOT"))
         (loaded (symbol-file 'gptel--handle-wait 'defun))
         (candidate
          (if (and configured (not (string-empty-p configured)))
              configured
            (and loaded (file-name-directory loaded)))))
    (unless (and candidate (file-name-absolute-p candidate)
                 (file-directory-p candidate))
      (epi-gptel--signal-incompatible 'gptel-source-root-missing))
    (file-name-as-directory (file-truename candidate))))

(defun epi-gptel--read-source-form (file kind name)
  "Read the unique top-level KIND form named NAME from exact-byte FILE."
  (let (failure matches)
    (condition-case nil
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert-file-contents-literally file)
          (set-syntax-table emacs-lisp-mode-syntax-table)
          (goto-char (point-min))
          (while (progn
                   (forward-comment (point-max))
                   (< (point) (point-max)))
            (let* ((start (point))
                   (form (read (current-buffer)))
                   (end (point)))
              (when (and (eq (car-safe form) kind)
                         (eq (cadr form) name))
                (let ((source (buffer-substring-no-properties start end)))
                  (push
                   (list :lines
                         (format "%d-%d"
                                 (line-number-at-pos start)
                                 (line-number-at-pos end))
                         :source-sha256 (secure-hash 'sha256 source))
                   matches))))))
      (error (setq failure t)))
    (when (or failure (/= (length matches) 1))
      (epi-gptel--signal-incompatible
       'gptel-source-form-unreadable :function name))
    (car matches)))

(defun epi-gptel--verified-source-form-hashes (root)
  "Return exact source-form hashes under pinned GPTel ROOT."
  (mapcar
   (lambda (entry)
     (let* ((label (car entry))
            (contract (cdr entry))
            (name (plist-get contract :name))
            (file (expand-file-name (plist-get contract :file) root))
            (observed
             (epi-gptel--read-source-form
              file (plist-get contract :kind) name)))
       (unless (and (equal (plist-get contract :lines)
                           (plist-get observed :lines))
                    (equal (plist-get contract :source-sha256)
                           (plist-get observed :source-sha256)))
         (epi-gptel--signal-incompatible
          'gptel-source-form-mismatch :function name))
       (cons label (plist-get observed :source-sha256))))
   epi-gptel-source-contract))

(defun epi-gptel--verify-source-provenance ()
  "Require pinned GPTel libraries and delegates to be exact source files."
  (let ((root (epi-gptel--source-root)))
    (dolist (library '("gptel" "gptel-request" "gptel-openai"))
      (let* ((expected (file-truename
                        (expand-file-name (concat library ".el") root)))
             (located (locate-library library))
             (actual (and located (file-truename located))))
        (unless (and actual (string-suffix-p ".el" actual)
                     (equal expected actual))
          (epi-gptel--signal-incompatible
           'gptel-source-provenance-mismatch :library library))))
    (dolist (entry epi-gptel-runtime-contract)
      (let* ((symbol (car entry))
             (expected (file-truename
                        (expand-file-name "gptel-request.el" root)))
             (loaded (symbol-file symbol 'defun))
             (actual (and loaded (file-truename loaded))))
        (unless (and actual (string-suffix-p ".el" actual)
                     (equal expected actual))
          (epi-gptel--signal-incompatible
           'gptel-source-provenance-mismatch :function symbol))))
    root))

(defun epi-gptel-check-compatibility ()
  "Verify the pinned GPTel seam and return a capability diagnostic plist."
  (unless (equal gptel-version epi-gptel--required-version)
    (epi-gptel--signal-incompatible 'gptel-version-mismatch))
  (let* ((root (epi-gptel--verify-source-provenance))
         (source-hashes (epi-gptel--verified-source-form-hashes root))
         (runtime-hashes (epi-gptel--verified-runtime-identities)))
    (list
     :capability epi-gptel-capability
     :gptel-version gptel-version
     :gptel-commit epi-gptel--required-commit
     :backend-family 'classic-openai-chat-completions
     :streaming-mode 'curl-streaming
     :typed-history-mode 'advanced-typed-history
     :sequential-tool-limit epi-provider-tool-call-limit
     :disabled-features
     '(parallel-tools responses-api other-providers media replayed-reasoning
       steering configuration-refresh)
     :source-form-hashes source-hashes
     :runtime-object-hashes runtime-hashes)))

(defun epi-gptel--object-entries (object code)
  "Return validated string-keyed OBJECT entries or signal CODE."
  (unless (proper-list-p object)
    (epi-gptel--signal-incompatible code))
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (entry object)
      (unless (and (consp entry) (stringp (car entry)))
        (epi-gptel--signal-incompatible code))
      (when (gethash (car entry) seen)
        (epi-gptel--signal-incompatible code))
      (puthash (car entry) t seen)))
  object)

(defun epi-gptel--object-member (key object)
  "Return the association for string KEY in OBJECT."
  (assoc-string key object nil))

(defun epi-gptel--object-value (key object)
  "Return the value stored under string KEY in OBJECT."
  (cdr (epi-gptel--object-member key object)))

(defun epi-gptel--same-json-type-p (value type)
  "Return non-nil when VALUE belongs to frozen primitive TYPE."
  (pcase type
    ("string" (stringp value))
    ("integer" (and (integerp value)
                     (<= (- epi--maximum-safe-integer)
                         value epi--maximum-safe-integer)))
    ("number" (and (numberp value)
                    (epi--finite-number-p value)
                    (or (floatp value)
                        (<= (- epi--maximum-safe-integer)
                            value epi--maximum-safe-integer))))
    ("boolean" (or (eq value t) (eq value epi-json-false)))
    (_ nil)))

(defun epi-gptel--schema-to-argument-specs (schema)
  "Validate frozen SCHEMA and return GPTel argument specs plus expected data."
  (epi-gptel--object-entries schema 'unsupported-tool-schema)
  (let* ((allowed '("type" "properties" "required" "additionalProperties"))
         (keys (mapcar #'car schema))
         (type-entry (epi-gptel--object-member "type" schema))
         (properties-entry (epi-gptel--object-member "properties" schema))
         (required-entry (epi-gptel--object-member "required" schema))
         (additional-entry
          (epi-gptel--object-member "additionalProperties" schema)))
    (unless (and (cl-every (lambda (key) (member key allowed)) keys)
                 (= (length keys) (length allowed))
                 type-entry properties-entry required-entry additional-entry
                 (equal "object" (cdr type-entry))
                 (eq epi-json-false (cdr additional-entry))
                 (vectorp (cdr required-entry)))
      (epi-gptel--signal-incompatible 'unsupported-tool-schema))
    (let* ((properties
            (epi-gptel--object-entries
             (cdr properties-entry) 'unsupported-tool-schema))
           (required (cdr required-entry))
           (required-seen (make-hash-table :test #'equal))
           (enum-total 0)
           specs expected-properties)
      (when (> (length properties) epi-tool-schema-property-limit)
        (epi-gptel--signal-incompatible 'tool-schema-property-limit))
      (when (> (length required) epi-tool-schema-required-limit)
        (epi-gptel--signal-incompatible 'tool-schema-required-limit))
      (seq-doseq (name required)
        (unless (and (stringp name)
                     (epi-gptel--object-member name properties)
                     (not (gethash name required-seen)))
          (epi-gptel--signal-incompatible 'unsupported-tool-schema))
        (puthash name t required-seen))
      (dolist (property properties)
        (let* ((name (car property))
               (definition
                (epi-gptel--object-entries
                 (cdr property) 'unsupported-tool-schema))
               (definition-keys (mapcar #'car definition))
               (property-type (epi-gptel--object-value "type" definition))
               (description-entry
                (epi-gptel--object-member "description" definition))
               (enum-entry (epi-gptel--object-member "enum" definition))
               (enum (cdr enum-entry)))
          (unless (and (member property-type
                               '("string" "integer" "number" "boolean"))
                       (cl-every (lambda (key)
                                   (member key '("type" "description" "enum")))
                                 definition-keys)
                       (= (length definition-keys)
                          (+ 1 (if description-entry 1 0)
                             (if enum-entry 1 0)))
                       (or (not description-entry)
                           (stringp (cdr description-entry)))
                       (or (not enum-entry) (vectorp enum)))
            (epi-gptel--signal-incompatible 'unsupported-tool-schema))
          (when enum-entry
            (when (> (length enum) epi-tool-schema-enum-per-property-limit)
              (epi-gptel--signal-incompatible
               'tool-schema-enum-property-limit))
            (cl-incf enum-total (length enum))
            (seq-doseq (value enum)
              (unless (epi-gptel--same-json-type-p value property-type)
                (epi-gptel--signal-incompatible 'unsupported-tool-schema))))
          (let ((spec (list :name name :type (intern property-type))))
            (when description-entry
              (setq spec (append spec
                                 (list :description (cdr description-entry)))))
            (when enum-entry
              (setq spec
                    (append
                     spec
                     (list :enum
                           (epi-gptel--translate-json-sentinels enum)))))
            (unless (gethash name required-seen)
              (setq spec (append spec (list :optional t))))
            (push spec specs))
          (let ((expected (list :type property-type)))
            (when description-entry
              (setq expected
                    (append expected
                            (list :description (cdr description-entry)))))
            (when enum-entry
              (setq expected
                    (append
                     expected
                     (list :enum
                           (epi-gptel--translate-json-sentinels enum)))))
            (setq expected-properties
                  (append expected-properties
                          (list (make-symbol (concat ":" name)) expected))))))
      (when (> enum-total epi-tool-schema-enum-total-limit)
        (epi-gptel--signal-incompatible 'tool-schema-enum-total-limit))
      (let* ((expected
              (list :type "object"
                    :properties expected-properties
                    :required (copy-sequence required)
                    :additionalProperties :json-false))
             (encoded (gptel--json-encode expected)))
        (when (> (string-bytes encoded) epi-tool-schema-byte-limit)
          (epi-gptel--signal-incompatible 'tool-schema-byte-limit))
        (list :args (nreverse specs)
              :expected expected
              :fingerprint (secure-hash 'sha256 encoded))))))

(defun epi-gptel--tool-stub (&rest _arguments)
  "Fail closed if GPTel attempts to execute an Epi-owned tool directly."
  (epi--signal 'epi-gptel-error (list :code 'unauthorized-tool-execution)))

(defun epi-gptel--compile-tools (descriptors)
  "Compile provider-neutral DESCRIPTORS into unregistered GPTel tools."
  (let ((names (make-hash-table :test #'equal))
        compiled metadata)
    (dolist (descriptor descriptors)
      (epi-gptel--object-entries descriptor 'invalid-tool-descriptor)
      (let* ((name (epi-gptel--object-value "name" descriptor))
             (description
              (epi-gptel--object-value "description" descriptor))
             (schema (epi-gptel--object-value "schema" descriptor)))
        (unless (and (stringp name) (not (string-empty-p name))
                     (<= (string-bytes name)
                         epi-provider-tool-name-byte-limit)
                     (stringp description) schema
                     (= (length descriptor) 3)
                     (not (gethash name names)))
          (epi-gptel--signal-incompatible 'invalid-tool-descriptor))
        (puthash name t names)
        (let* ((schema-data (epi-gptel--schema-to-argument-specs schema))
               (tool
                (gptel--make-tool
                 :name name
                 :description description
                 :args (copy-tree (plist-get schema-data :args))
                 :function #'epi-gptel--tool-stub
                 :async t
                 :confirm t)))
          (push tool compiled)
          (push (cons name
                      (list :schema (epi--canonical-copy schema)
                            :expected (plist-get schema-data :expected)
                            :fingerprint (plist-get schema-data :fingerprint)))
                metadata))))
    (list :compiled (nreverse compiled) :metadata (nreverse metadata))))

(defun epi-gptel--canonical-to-gptel (value)
  "Translate frozen canonical VALUE into GPTel's JSON representation."
  (cond
   ((eq value epi-json-false) :json-false)
   ((eq value epi-json-null) :null)
   ((vectorp value)
    (vconcat (mapcar #'epi-gptel--canonical-to-gptel (append value nil))))
   ((consp value)
    (cl-loop for (key . item) in value
             append (list (intern (concat ":" key))
                          (epi-gptel--canonical-to-gptel item))))
   (t value)))

(defun epi-gptel--history-projection (snapshot metadata)
  "Return GPTel input and exact messages for SNAPSHOT using tool METADATA."
  (let (advanced expected)
    (when-let* ((system (epi-gptel-snapshot-system snapshot)))
      (unless (epi--canonical-string-p system)
        (epi-gptel--signal-incompatible 'unsupported-history))
      (push (list :role "system" :content system) expected))
    (dolist (entry (epi-gptel-snapshot-history snapshot))
      (epi-gptel--object-entries entry 'unsupported-history)
      (let ((role (epi-gptel--object-value "role" entry)))
        (pcase role
          ((or "user" "assistant")
           (let ((text (epi-gptel--object-value "text" entry)))
             (unless (and (epi--canonical-string-p text)
                          (= (length entry) 2))
               (epi-gptel--signal-incompatible 'unsupported-history))
             (push (cons (if (equal role "user") 'prompt 'response) text)
                   advanced)
             (push (list :role role :content text) expected)))
          ("tool"
           (let* ((call-id (epi-gptel--object-value "call_id" entry))
                  (name (epi-gptel--object-value "name" entry))
                  (arguments (epi-gptel--object-value "arguments" entry))
                  (result (epi-gptel--object-value "result" entry))
                  (details (and (stringp name)
                                (assoc-string name metadata nil))))
             (unless (and (epi--canonical-string-p call-id)
                          (not (string-empty-p call-id))
                          (<= (string-bytes call-id)
                              epi-provider-call-id-byte-limit)
                          (epi--canonical-string-p name)
                          (not (string-empty-p name))
                          (<= (string-bytes name)
                              epi-provider-tool-name-byte-limit)
                          details (epi--canonical-string-p result)
                          (= (length entry) 5))
               (epi-gptel--signal-incompatible 'unsupported-history))
             (let* ((gptel-arguments
                     (epi-gptel--canonical-to-gptel arguments))
                    (arguments-json
                     (decode-coding-string
                      (gptel--json-encode gptel-arguments) 'utf-8 t))
                    (scan
                     (epi-gptel--scan-arguments
                      arguments-json (plist-get (cdr details) :schema)))
                    (call (list :id call-id :name name
                                :args gptel-arguments :result result)))
               (unless (plist-get scan :ok)
                 (epi-gptel--signal-incompatible 'unsupported-history))
               (push (cons 'tool call) advanced)
               (push (list :role "assistant" :tool_calls
                           (vector
                            (list :type "function" :id call-id
                                  :function
                                  (list :name name
                                        :arguments arguments-json))))
                     expected)
               (push (list :role "tool" :tool_call_id call-id
                           :content result)
                     expected))))
          (_ (epi-gptel--signal-incompatible 'unsupported-history)))))
    (when-let* ((prompt (epi-gptel-snapshot-prompt snapshot)))
      (unless (epi--canonical-string-p prompt)
        (epi-gptel--signal-incompatible 'unsupported-history))
      (push (cons 'prompt prompt) advanced)
      (push (list :role "user" :content prompt) expected))
    (unless advanced
      (epi-gptel--signal-incompatible 'empty-provider-context))
    (list :advanced (nreverse advanced)
          :messages (vconcat (nreverse expected)))))

(defun epi-gptel--message-shape-compatible-p (actual expected)
  "Return non-nil if ACTUAL differs from EXPECTED only in lossy typed fields."
  (and (vectorp actual)
       (= (length actual) (length expected))
       (cl-loop for left across actual
                for right across expected
                always
                (and (equal (plist-get left :role) (plist-get right :role))
                     (pcase (plist-get right :role)
                       ("assistant"
                        (let ((right-calls (plist-get right :tool_calls))
                              (left-calls (plist-get left :tool_calls)))
                          (if right-calls
                              (and (vectorp left-calls)
                                   (= 1 (length left-calls))
                                   (equal
                                    (plist-get
                                     (plist-get (aref left-calls 0) :function)
                                     :name)
                                    (plist-get
                                     (plist-get (aref right-calls 0) :function)
                                     :name)))
                            (stringp (plist-get left :content)))))
                       ((or "system" "user" "tool") t)
                       (_ nil))))))

(defun epi-gptel--json-normalize (value)
  "Return VALUE normalized through GPTel's request JSON representation."
  (json-parse-string
   (gptel--json-encode value)
   :object-type 'alist :array-type 'array
   :null-object epi-json-null :false-object epi-json-false))

(defun epi-gptel--repair-and-check-tools (data metadata)
  "Repair the pinned zero-property omission in DATA, then compare METADATA."
  (let ((actual-tools (plist-get data :tools)))
    (unless (and (vectorp actual-tools)
                 (= (length actual-tools) (length metadata)))
      (epi-gptel--signal-incompatible 'effective-tool-schema-mismatch))
    (cl-loop
     for tool across actual-tools
     for (name . details) in metadata
     for function = (plist-get tool :function)
     for parameters = (plist-get function :parameters)
     for expected = (plist-get details :expected)
     do
     (unless (equal name (plist-get function :name))
       (epi-gptel--signal-incompatible 'effective-tool-schema-mismatch))
     ;; GPTel 0.9.9.5 emits only type/properties for a zero-argument tool.  Add
     ;; precisely the two frozen root constraints and compare the full object.
     (when (and (null (plist-get parameters :properties))
                (not (plist-member parameters :required))
                (not (plist-member parameters :additionalProperties)))
       (setq parameters
             (append parameters
                     (list :required [] :additionalProperties :json-false)))
       (plist-put function :parameters parameters))
     (unless (equal (epi-gptel--json-normalize parameters)
                    (epi-gptel--json-normalize expected))
       (epi-gptel--signal-incompatible 'effective-tool-schema-mismatch)))))

(defun epi-gptel--resolve-backend (snapshot)
  "Resolve and validate SNAPSHOT's exact classic OpenAI backend and model."
  (unless (eq (epi-gptel-snapshot-transport snapshot) 'curl)
    (epi-gptel--signal-incompatible 'curl-required))
  (let* ((name (epi-gptel-snapshot-backend snapshot))
         (backend (and name (alist-get name gptel--known-backends
                                       nil nil #'equal)))
         (model (epi-gptel-snapshot-model snapshot)))
    (unless backend
      (epi-gptel--signal-incompatible 'backend-not-found))
    (unless (and (eq (type-of backend) 'gptel-openai)
                 (not (gptel-openai-responses-p backend)))
      (epi-gptel--signal-incompatible 'unsupported-backend-family))
    (unless (and (symbolp model) (memq model (gptel-backend-models backend)))
      (epi-gptel--signal-incompatible 'model-not-found))
    (unless (gptel-backend-stream backend)
      (epi-gptel--signal-incompatible 'streaming-not-supported))
    backend))

(defun epi-gptel--copy-request-data (data)
  "Return an ownership-isolated copy of realized GPTel DATA."
  (cl-labels
      ((copy-value
        (value)
        (cond
         ((stringp value) (epi--plain-string-copy value))
         ((vectorp value)
          (vconcat (mapcar #'copy-value (append value nil))))
         ((consp value)
          (cons (copy-value (car value)) (copy-value (cdr value))))
         (t value))))
    (copy-value data)))

(defun epi-gptel--make-handlers ()
  "Return request handlers with only Epi's WAIT and TOOL guards replaced."
  (let ((handlers (copy-tree gptel-request--handlers)))
    (setcdr (assq 'WAIT handlers) (list #'epi-gptel--handle-wait))
    (setcdr (assq 'TOOL handlers) (list #'epi-gptel--handle-tool-use))
    handlers))

(defun epi-gptel--prepare-request (snapshot enqueue)
  "Realize SNAPSHOT through GPTel without starting it, using ENQUEUE."
  (epi-gptel-check-compatibility)
  (unless (epi-gptel-snapshot-p snapshot)
    (epi-gptel--signal-incompatible 'invalid-snapshot))
  (unless (functionp enqueue)
    (epi-gptel--signal-incompatible 'invalid-enqueue))
  (setq snapshot (epi-gptel--private-snapshot snapshot))
  (let* ((backend (epi-gptel--resolve-backend snapshot))
         (tool-data (epi-gptel--compile-tools
                     (epi-gptel-snapshot-tools snapshot)))
         (compiled-tools (plist-get tool-data :compiled))
         (metadata (plist-get tool-data :metadata))
         (projection (epi-gptel--history-projection snapshot metadata))
         (buffer (generate-new-buffer " *epi-gptel-request*" t))
         (fsm (gptel-make-fsm :handlers (epi-gptel--make-handlers)))
         (request
          (epi-gptel--request-create
           :buffer buffer :fsm fsm :snapshot snapshot :enqueue enqueue
           :tools metadata)))
    (condition-case error-data
        (progn
          (with-current-buffer buffer
            (setq-local gptel-backend backend)
            (setq-local gptel-model (epi-gptel-snapshot-model snapshot))
            (setq-local gptel-system-prompt
                        (epi-gptel-snapshot-system snapshot))
            (setq-local gptel-use-curl t)
            (setq-local gptel-stream t)
            (setq-local gptel-mode nil)
            (setq-local gptel-track-response t)
            (setq-local gptel-use-context nil)
            (setq-local gptel-context nil)
            (setq-local gptel--num-messages-to-send nil)
            (setq-local gptel-track-media nil)
            (setq-local gptel--schema nil)
            (setq-local gptel-temperature nil)
            (setq-local gptel-max-tokens nil)
            (setq-local gptel-cache nil)
            (setq-local gptel-prompt-transform-functions nil)
            (setq-local gptel-include-reasoning 'ignore)
            (setq-local gptel-use-tools (and compiled-tools t))
            (setq-local gptel-tools compiled-tools)
            (setq-local gptel-confirm-tool-calls t)
            (setq-local gptel-post-request-hook nil)
            (setq-local gptel--request-params
                        (append
                         (epi-gptel--translate-json-sentinels
                          (epi-gptel--copy-request-value
                           (epi-gptel-snapshot-request-params snapshot)))
                         (and compiled-tools
                              (list :parallel_tool_calls :json-false))))
            (setq fsm
                  (gptel-request
                      (plist-get projection :advanced)
                    :callback
                    (lambda (response info)
                      (epi-gptel--callback request response info))
                    :buffer buffer
                    :stream t
                    :system (epi-gptel-snapshot-system snapshot)
                    :dry-run t
                    :fsm fsm)))
          (setf (epi-gptel-request-fsm request) fsm)
          (let* ((info (gptel-fsm-info fsm))
                 (data (plist-get info :data))
                 (expected-messages (plist-get projection :messages))
                 (actual-messages (plist-get data :messages)))
            (unless (and (eq backend (plist-get info :backend))
                         (eq (epi-gptel-snapshot-model snapshot)
                             (plist-get info :model))
                         (equal (symbol-name
                                 (epi-gptel-snapshot-model snapshot))
                                (plist-get data :model))
                         (eq t (plist-get data :stream)))
              (epi-gptel--signal-incompatible
               'effective-request-selection-mismatch))
            (when compiled-tools
              (unless (eq :json-false
                          (plist-get data :parallel_tool_calls))
                (epi-gptel--signal-incompatible
                 'parallel-tools-not-disabled))
              (epi-gptel--repair-and-check-tools data metadata))
            (unless (epi-gptel--message-shape-compatible-p
                     actual-messages expected-messages)
              (epi-gptel--signal-incompatible 'typed-history-mismatch))
            ;; Repair only GPTel's documented typed-history losses: surrounding
            ;; text and non-call_ IDs.  The role/tool skeleton was checked above.
            (plist-put data :messages (copy-tree expected-messages t))
            (unless (equal (plist-get data :messages) expected-messages)
              (epi-gptel--signal-incompatible 'typed-history-mismatch))
            (plist-put info :epi-request request)
            (plist-put info :post
                       (append (plist-get info :post)
                               (list
                                (lambda (terminal-info)
                                  (epi-gptel--terminal-post
                                   request terminal-info)))))
            request))
      (error
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (signal (car error-data) (cdr error-data))))))

(defun epi-gptel-dry-run (snapshot)
  "Return copied effective GPTel request data for SNAPSHOT without transport."
  (let* ((request (epi-gptel--prepare-request snapshot #'ignore))
         (data
          (epi-gptel--copy-request-data
           (plist-get (gptel-fsm-info (epi-gptel-request-fsm request))
                      :data))))
    (when (buffer-live-p (epi-gptel-request-buffer request))
      (kill-buffer (epi-gptel-request-buffer request)))
    data))

(defun epi-gptel--fixture-backend (options)
  "Create and register the fixture backend described by OPTIONS."
  (let ((family (or (plist-get options :family) 'classic))
        (request-params (plist-get options :request-params))
        (stream (if (plist-member options :stream)
                    (plist-get options :stream)
                  t)))
    (pcase family
      ('classic
       (gptel-make-openai
           "epi-fixture"
         :host "fixture.invalid"
         :models '(epi-fixture-model)
         :stream stream
         :header nil
         :request-params request-params))
      ('responses
       (gptel-make-openai
           "epi-fixture"
         :host "api.openai.com"
         :models '(epi-fixture-model)
         :stream stream
         :header nil
         :request-params request-params))
      ('other
       (let ((backend
              (gptel--make-backend
               :name "epi-fixture" :host "fixture.invalid"
               :protocol "https" :endpoint "/v1/messages"
               :url "https://fixture.invalid/v1/messages"
               :stream stream :models '(epi-fixture-model)
               :request-params request-params)))
         (setf (alist-get "epi-fixture" gptel--known-backends
                          nil nil #'equal)
               backend)
         backend))
      (_ (error "Unknown fixture backend family")))))

(defun epi-gptel--fixture-clean-process (process)
  "Unregister and destroy fixture PROCESS and its buffer."
  (when (processp process)
    (let ((buffer (process-buffer process)))
      (setf (alist-get process gptel--request-alist nil 'remove) nil)
      (ignore-errors (set-process-sentinel process #'ignore))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p buffer) (kill-buffer buffer))))
  (setq epi-gptel--fixture-processes
        (delq process epi-gptel--fixture-processes)))

(defun epi-gptel--fixture-enqueue (job)
  "Append fixture delivery JOB to the dynamically scoped FIFO."
  (setq epi-gptel--fixture-pending
        (nconc epi-gptel--fixture-pending (list job))))

(defun epi-gptel--fixture-wire-chunks (wire boundaries)
  "Split WIRE at strictly increasing character BOUNDARIES."
  (let ((start 0) chunks)
    (dolist (boundary boundaries)
      (unless (and (integerp boundary) (> boundary start)
                   (< boundary (length wire)))
        (error "Invalid fixture chunk boundary"))
      (push (substring wire start boundary) chunks)
      (setq start boundary))
    (push (substring wire start) chunks)
    (nreverse chunks)))

(defun epi-gptel--fixture-drain-abort-timer (request)
  "Run REQUEST's immediate deferred abort timer before fixture assertions."
  (let ((attempts 0))
    (while (and (epi-gptel-request-abort-timer request)
                (< attempts 50))
      (cl-incf attempts)
      (sleep-for 0.001))))

(defun epi-gptel-fixture-pump ()
  "Deliver one queued offline fixture leg after GPTel WAIT has yielded."
  (let ((job (pop epi-gptel--fixture-pending)))
    (when job
      (let* ((process (plist-get job :process))
             (fsm (plist-get job :fsm))
             (request (plist-get job :request))
             (body (plist-get job :body))
             (cleanup-only (plist-get job :cleanup-only))
             (retain (plist-get epi-gptel--fixture-options
                                :retain-transport)))
        (unwind-protect
            (unless cleanup-only
              (when-let* ((hook (plist-get epi-gptel--fixture-options
                                           :delivery-hook)))
                (funcall hook))
              (if (not body)
                  (epi-gptel--fail-stop request 'fixture-leg-missing)
                (let* ((info (gptel-fsm-info fsm))
                       (error-response
                        (and (> (length body) 0) (= (aref body 0) ?{)))
                       (wire
                        (concat (if error-response
                                    epi-gptel--fixture-header-error
                                  epi-gptel--fixture-header-ok)
                                body))
                       (chunks
                        (epi-gptel--fixture-wire-chunks
                         wire (or (plist-get epi-gptel--fixture-options
                                             :chunk-boundaries)
                                  nil))))
                  (dolist (chunk chunks)
                    (unless (and (epi-gptel-request-p request)
                                 (epi-gptel-request-terminal-p request))
                      (funcall (process-filter process) process chunk)))
                  (unless (and (epi-gptel-request-p request)
                               (epi-gptel-request-terminal-p request))
                    (if error-response
                        (progn
                          (plist-put info :error "Provider fixture error")
                          (plist-put info :status
                                     "HTTP/1.1 400 Bad Request")
                          (funcall (plist-get info :callback) nil info))
                      (funcall (plist-get info :callback) t info))
                    (unless (and (epi-gptel-request-p request)
                                 (epi-gptel-request-terminal-p request))
                      (gptel--fsm-transition fsm))))))
          (unless (and retain (not cleanup-only))
            (epi-gptel--fixture-clean-process process)))
        (when (epi-gptel-request-p request)
          (epi-gptel--fixture-drain-abort-timer request)))
      t)))

(defun epi-gptel-fixture-call-with-transport (legs function &optional options)
  "Call FUNCTION with raw fixture LEGS as the only GPTel transport input.
OPTIONS controls only the offline backend and deliberate interception faults."
  (let* ((old-entry (assoc-string "epi-fixture" gptel--known-backends t))
         (old-backend (cdr old-entry))
         (gptel-post-request-hook
          (and-let* ((hook (plist-get options :global-post-hook)))
            (list hook)))
         (epi-gptel--fixture-legs (copy-sequence legs))
         (epi-gptel--fixture-options options)
         (epi-gptel--fixture-pending nil)
         (epi-gptel--fixture-processes nil))
    (unwind-protect
        (progn
          (epi-gptel--fixture-backend options)
          (cl-letf (((symbol-function 'gptel-curl-get-response)
                     #'epi-gptel--fixture-get-response))
            (funcall function)))
      (setq epi-gptel--fixture-pending nil)
      (dolist (process (copy-sequence epi-gptel--fixture-processes))
        (epi-gptel--fixture-clean-process process))
      (if old-entry
          (setf (alist-get "epi-fixture" gptel--known-backends
                           nil nil #'equal)
                old-backend)
        (setf (alist-get "epi-fixture" gptel--known-backends
                         nil 'remove #'equal)
              nil)))))

(defun epi-gptel-fixture-wire-byte-count (body)
  "Return bytes charged when successful fixture BODY is delivered."
  (string-bytes (concat epi-gptel--fixture-header-ok body)))

(defun epi-gptel--event-create (&rest slots)
  "Create an ownership-isolated adapter event from SLOTS."
  (let ((text (plist-get slots :text))
        (call-id (plist-get slots :call-id))
        (name (plist-get slots :name))
        (result (plist-get slots :result))
        (arguments (plist-get slots :arguments)))
    (apply
     #'epi-gptel--event-create-raw
     (append
      (list :kind (plist-get slots :kind)
            :text (and text (epi--plain-string-copy text))
            :call-id (and call-id (epi--plain-string-copy call-id))
            :name (and name (epi--plain-string-copy name))
            :arguments (epi--canonical-copy arguments)
            :result (and result (epi--plain-string-copy result))
            :code (plist-get slots :code)
            :raw-byte-count (plist-get slots :raw-byte-count)
            :member-count (plist-get slots :member-count))))))

(defun epi-gptel--emit (request event)
  "Deliver EVENT to REQUEST's copied enqueue callback.
An enqueue exception disables the callback and takes the fail-stop path."
  (when-let* ((enqueue (epi-gptel-request-enqueue request)))
    (condition-case nil
        (funcall enqueue event)
      (error
       (setf (epi-gptel-request-enqueue request) nil)
       (epi-gptel--fail-stop request 'callback-exception)))))

(defun epi-gptel--cancel-watchdog (request)
  "Cancel REQUEST's active provider-leg watchdog, if any."
  (when-let* ((timer (epi-gptel-request-watchdog request)))
    (cancel-timer timer)
    (setf (epi-gptel-request-watchdog request) nil)))

(defun epi-gptel--clear-raw-audit-state (request)
  "Erase every retained raw provider argument byte from REQUEST."
  (dolist (fragment (epi-gptel-request-audit-fragments request))
    (when (stringp fragment) (clear-string fragment)))
  (maphash
   (lambda (_id attestation)
     (when-let* ((raw (plist-get attestation :raw))
                 ((stringp raw)))
       (clear-string raw)))
   (epi-gptel-request-attestations request))
  (clrhash (epi-gptel-request-attestations request))
  (setf (epi-gptel-request-audit-fragments request) nil
        (epi-gptel-request-audit-call-id request) nil
        (epi-gptel-request-audit-name request) nil
        (epi-gptel-request-audit-argument-bytes request) 0))

(defun epi-gptel--clear-continuations (request)
  "Invalidate all pending continuations and raw attestations in REQUEST."
  (clrhash (epi-gptel-request-continuations request))
  (epi-gptel--clear-raw-audit-state request))

(defun epi-gptel--settle (request kind &optional code)
  "Settle REQUEST exactly once with terminal KIND and optional CODE."
  (unless (epi-gptel-request-terminal-p request)
    (epi-gptel--cancel-watchdog request)
    (epi-gptel--clear-continuations request)
    (setf (epi-gptel-request-terminal-p request) t
          (epi-gptel-request-terminal-kind request) kind
          (epi-gptel-request-terminal-code request) code)
    (epi-gptel--emit
     request
     (epi-gptel--event-create :kind kind :code code))))

(defun epi-gptel--terminal-post (request info)
  "Observe GPTel terminal INFO and settle REQUEST exactly once."
  (let ((state (gptel-fsm-state (epi-gptel-request-fsm request))))
    (cond
     ((or (epi-gptel-request-abort-requested request) (eq state 'ABRT))
      (if (epi-gptel-request-terminal-code request)
          (epi-gptel--settle
           request 'request-failed
           (epi-gptel-request-terminal-code request))
        (epi-gptel--settle request 'request-aborted 'aborted)))
     ((or (eq state 'ERRS) (plist-get info :error)
          (epi-gptel-request-terminal-code request))
      (epi-gptel--settle
       request 'request-failed
       (or (epi-gptel-request-terminal-code request) 'provider-error)))
     ((eq state 'DONE)
      (epi-gptel--settle request 'request-finished))
     (t
     (epi-gptel--settle request 'request-failed 'unexpected-terminal)))))

(defun epi-gptel--deferred-fail-stop-abort (request leg-index code)
  "Abort REQUEST transport after the rejecting parser stack has unwound.
LEG-INDEX and CODE prevent a stale timer from touching another generation."
  (setf (epi-gptel-request-abort-timer request) nil)
  (when (and (epi-gptel-request-terminal-p request)
             (= leg-index (epi-gptel-request-leg-index request))
             (eq code (epi-gptel-request-terminal-code request)))
    (ignore-errors (gptel-abort (epi-gptel-request-buffer request)))))

(defun epi-gptel--schedule-fail-stop-abort (request code)
  "Schedule REQUEST's public GPTel abort exactly once for CODE."
  (unless (epi-gptel-request-abort-timer request)
    (setf (epi-gptel-request-abort-timer request)
          (run-at-time
           0 nil #'epi-gptel--deferred-fail-stop-abort
           request (epi-gptel-request-leg-index request) code))))

(defun epi-gptel--fail-stop (request code)
  "Take REQUEST's exactly-once redacted failure path with CODE."
  (unless (epi-gptel-request-terminal-p request)
    (setf (epi-gptel-request-terminal-code request) code)
    (epi-gptel--cancel-watchdog request)
    (epi-gptel--clear-continuations request)
    (let* ((fsm (epi-gptel-request-fsm request))
           (info (and fsm (gptel-fsm-info fsm))))
      (when info
        (plist-put info :error "Epi rejected an incompatible provider response")
        (plist-put info :status "Epi compatibility failure"))
      (condition-case nil
          (if (and fsm (not (memq (gptel-fsm-state fsm)
                                  '(DONE ERRS ABRT))))
              (gptel--fsm-transition fsm 'ERRS)
            (epi-gptel--settle request 'request-failed code))
        (error (epi-gptel--settle request 'request-failed code)))
      (unless (epi-gptel-request-terminal-p request)
        (epi-gptel--settle request 'request-failed code))
      (epi-gptel--schedule-fail-stop-abort request code))))

(defun epi-gptel--watchdog-expired (request leg-index)
  "Fail REQUEST if provider LEG-INDEX still has no documented completion."
  (when (and (not (epi-gptel-request-terminal-p request))
             (= leg-index (epi-gptel-request-leg-index request))
             (epi-gptel-request-watchdog request))
    (epi-gptel--fail-stop request 'provider-no-progress)))

(defun epi-gptel--start-watchdog (request)
  "Start REQUEST's resettable no-progress watchdog for its current leg."
  (epi-gptel--cancel-watchdog request)
  (setf (epi-gptel-request-watchdog request)
        (run-at-time
         epi-gptel-no-progress-timeout nil
         #'epi-gptel--watchdog-expired
         request (epi-gptel-request-leg-index request))))

(defun epi-gptel--guarded-stream-filter (request stock-filter process output)
  "Count REQUEST raw bytes, then delegate safe OUTPUT to STOCK-FILTER.
PROCESS is the exact GPTel transport process."
  (unless (epi-gptel-request-terminal-p request)
    (let* ((bytes (string-bytes output))
           (leg (+ bytes (epi-gptel-request-leg-raw-bytes request)))
           (turn (+ bytes (epi-gptel-request-turn-raw-bytes request))))
      (if (or (> leg epi-provider-leg-raw-byte-limit)
              (> turn epi-provider-turn-raw-byte-limit))
          (epi-gptel--fail-stop request 'provider-raw-byte-limit)
        (setf (epi-gptel-request-leg-raw-bytes request) leg
              (epi-gptel-request-turn-raw-bytes request) turn)
        (epi-gptel--start-watchdog request)
        (condition-case nil
            (funcall stock-filter process output)
          (error (epi-gptel--fail-stop request 'stream-filter-error)))))))

(defun epi-gptel--handle-wait (fsm)
  "Delegate Epi FSM's WAIT state to GPTel with one guarded filter install."
  (let* ((info (gptel-fsm-info fsm))
         (request (plist-get info :epi-request)))
    (if (not (epi-gptel-request-p request))
        (funcall epi-gptel--stock-handle-wait fsm)
      (when (epi-gptel-request-next-leg-p request)
        (setf (epi-gptel-request-next-leg-p request) nil)
        (epi-gptel--reset-next-leg request))
      (when (and (> (epi-gptel-request-leg-index request) 0)
                 (plist-get epi-gptel--fixture-options
                            :before-next-leg-hook))
        (funcall (plist-get epi-gptel--fixture-options
                            :before-next-leg-hook)
                 info))
      (setf (epi-gptel-request-leg-finished-p request) nil)
      (epi-gptel--start-watchdog request)
      (let ((original-set-process-filter (symbol-function 'set-process-filter))
            (installations 0)
            unexpected-filter
            dispatch-error)
        (cl-letf
            (((symbol-function 'set-process-filter)
              (lambda (process filter)
                (cl-incf installations)
                (if (and (= installations 1)
                         (eq filter 'gptel-curl--stream-filter)
                         (eq (symbol-function filter)
                             epi-gptel--stock-stream-filter))
                    (funcall
                     original-set-process-filter process
                     (lambda (guarded-process output)
                       (epi-gptel--guarded-stream-filter
                        request epi-gptel--stock-stream-filter
                        guarded-process output)))
                  (setq unexpected-filter t)))))
          (condition-case nil
              (funcall epi-gptel--stock-handle-wait fsm)
            (error (setq dispatch-error t))))
        (when (or dispatch-error unexpected-filter (/= installations 1))
          (epi-gptel--fail-stop request 'wait-filter-interception))))))

(defun epi-gptel--audit-reject (code)
  "Abort the current pre-parse audit with redacted CODE."
  (throw 'epi-gptel--audit code))

(defun epi-gptel--outer-duplicates-p (value)
  "Return non-nil when parsed outer JSON VALUE has duplicate object keys."
  (cond
   ((vectorp value)
    (seq-some #'epi-gptel--outer-duplicates-p value))
   ((consp value)
    (let ((seen (make-hash-table :test #'equal))
          duplicate)
      (dolist (entry value)
        (when (or (not (consp entry))
                  (gethash (car entry) seen)
                  (epi-gptel--outer-duplicates-p (cdr entry)))
          (setq duplicate t))
        (puthash (car entry) t seen))
      duplicate))
   (t nil)))

(defun epi-gptel--audit-closed-object (object allowed code)
  "Require string-keyed OBJECT to contain only ALLOWED keys or reject CODE."
  (unless (proper-list-p object)
    (epi-gptel--audit-reject code))
  (dolist (entry object)
    (unless (and (consp entry) (stringp (car entry))
                 (member (car entry) allowed))
      (epi-gptel--audit-reject code)))
  object)

(defun epi-gptel--audit-token-count-object (object allowed)
  "Validate a bounded OpenAI token count OBJECT with ALLOWED keys."
  (epi-gptel--audit-closed-object object allowed 'usage-shape-invalid)
  (dolist (entry object)
    (unless (or (eq (cdr entry) epi-json-null)
                (and (integerp (cdr entry)) (>= (cdr entry) 0)))
      (epi-gptel--audit-reject 'usage-shape-invalid))))

(defun epi-gptel--audit-envelope-shape (outer)
  "Validate the closed classic OpenAI streaming envelope OUTER."
  (epi-gptel--audit-closed-object
   outer
   '("id" "object" "created" "model" "system_fingerprint"
     "service_tier" "choices" "usage")
   'outer-envelope-key-invalid)
  (dolist (key '("id" "object" "model" "system_fingerprint"
                 "service_tier"))
    (when-let* ((entry (assoc key outer)))
      (unless (or (eq (cdr entry) epi-json-null)
                  (epi--canonical-string-p (cdr entry)))
        (epi-gptel--audit-reject 'provider-string-invalid))))
  (when-let* ((entry (assoc "created" outer)))
    (unless (or (eq (cdr entry) epi-json-null)
                (and (integerp (cdr entry)) (>= (cdr entry) 0)))
      (epi-gptel--audit-reject 'outer-envelope-shape-invalid)))
  (let* ((choices-entry (assoc "choices" outer))
         (choices (cdr choices-entry)))
    (unless (and choices-entry (vectorp choices) (<= (length choices) 1))
      (epi-gptel--audit-reject 'multiple-provider-choices))
    (seq-doseq (choice choices)
      (epi-gptel--audit-closed-object
       choice '("index" "delta" "logprobs" "finish_reason")
       'choice-envelope-key-invalid)
      (let ((entry (assoc "index" choice)))
        (unless (and entry (integerp (cdr entry)) (zerop (cdr entry)))
          (epi-gptel--audit-reject 'choice-envelope-shape-invalid)))
      (when-let* ((entry (assoc "finish_reason" choice)))
        (unless (or (eq (cdr entry) epi-json-null)
                    (epi--canonical-string-p (cdr entry)))
          (epi-gptel--audit-reject 'provider-string-invalid)))
      (when-let* ((entry (assoc "logprobs" choice)))
        (unless (eq (cdr entry) epi-json-null)
          (epi-gptel--audit-reject 'unsupported-provider-field)))
      (when-let* ((delta-entry (assoc "delta" choice)))
        (let ((delta (cdr delta-entry)))
          (epi-gptel--audit-closed-object
           delta
           '("role" "content" "refusal" "tool_calls"
             "reasoning" "reasoning_content")
           'delta-envelope-key-invalid)
          (when-let* ((role-entry (assoc "role" delta)))
            (unless (or (eq (cdr role-entry) epi-json-null)
                        (equal (cdr role-entry) "assistant"))
              (epi-gptel--audit-reject 'provider-role-invalid)))
          (when-let* ((refusal-entry (assoc "refusal" delta)))
            (unless (eq (cdr refusal-entry) epi-json-null)
              (epi-gptel--audit-reject 'unsupported-provider-field)))
          (when-let* ((calls-entry (assoc "tool_calls" delta)))
            (let ((calls (cdr calls-entry)))
              (unless (vectorp calls)
                (epi-gptel--audit-reject 'tool-calls-shape-invalid))
              (seq-doseq (call calls)
                (epi-gptel--audit-closed-object
                 call '("index" "id" "type" "function")
                 'tool-call-envelope-key-invalid)
                (when-let* ((function-entry (assoc "function" call)))
                  (epi-gptel--audit-closed-object
                   (cdr function-entry) '("name" "arguments")
                   'tool-function-envelope-key-invalid)))))))))
  (when-let* ((usage-entry (assoc "usage" outer))
              (usage (cdr usage-entry))
              ((not (eq usage epi-json-null))))
    (epi-gptel--audit-closed-object
     usage
     '("prompt_tokens" "completion_tokens" "total_tokens"
       "prompt_tokens_details" "completion_tokens_details")
     'usage-shape-invalid)
    (dolist (key '("prompt_tokens" "completion_tokens" "total_tokens"))
      (when-let* ((entry (assoc key usage)))
        (unless (and (integerp (cdr entry)) (>= (cdr entry) 0))
          (epi-gptel--audit-reject 'usage-shape-invalid))))
    (when-let* ((entry (assoc "prompt_tokens_details" usage)))
      (epi-gptel--audit-token-count-object
       (cdr entry) '("cached_tokens" "audio_tokens")))
    (when-let* ((entry (assoc "completion_tokens_details" usage)))
      (epi-gptel--audit-token-count-object
       (cdr entry)
       '("reasoning_tokens" "audio_tokens" "accepted_prediction_tokens"
         "rejected_prediction_tokens")))))

(defun epi-gptel--json-whitespace-p (character)
  "Return non-nil when CHARACTER is JSON whitespace."
  (memq character '(9 10 13 32)))

(defun epi-gptel--skip-json-whitespace (text position)
  "Return first non-whitespace position in TEXT at or after POSITION."
  (while (and (< position (length text))
              (epi-gptel--json-whitespace-p (aref text position)))
    (setq position (1+ position)))
  position)

(defun epi-gptel--scan-json-string (text position)
  "Decode one JSON string in TEXT at POSITION and return (VALUE . END)."
  (unless (and (< position (length text)) (= (aref text position) ?\"))
    (epi-gptel--audit-reject 'argument-string-required))
  (let ((start position)
        (escaped nil)
        end)
    (cl-incf position)
    (while (and (< position (length text)) (not end))
      (let ((character (aref text position)))
        (cond
         (escaped (setq escaped nil))
         ((= character ?\\) (setq escaped t))
         ((= character ?\") (setq end (1+ position)))
         ((< character 32)
          (epi-gptel--audit-reject 'argument-control-character))))
      (cl-incf position))
    (unless (and end (not escaped))
      (epi-gptel--audit-reject 'argument-string-malformed))
    (let ((value
           (condition-case nil
               (json-parse-string (substring text start end))
             (error (epi-gptel--audit-reject
                     'argument-string-malformed)))))
      (unless (and (stringp value) (epi--canonical-string-p value))
        (epi-gptel--audit-reject 'argument-string-malformed))
      (cons value end))))

(defun epi-gptel--scan-json-number (text position)
  "Decode one bounded JSON number in TEXT at POSITION as (VALUE . END)."
  (let ((start position))
    (while (and (< position (length text))
                (not (or (epi-gptel--json-whitespace-p
                          (aref text position))
                         (memq (aref text position) '(?, ?})))))
      (cl-incf position))
    (let ((token (substring text start position)))
      (unless (string-match-p
               "\\`-?\\(?:0\\|[1-9][0-9]*\\)\\(?:\\.[0-9]+\\)?\\(?:[eE][+-]?[0-9]+\\)?\\'"
               token)
        (epi-gptel--audit-reject 'argument-number-malformed))
      (let ((value
             (condition-case nil
                 (json-parse-string token)
               (error (epi-gptel--audit-reject
                       'argument-number-malformed)))))
        (unless (and (numberp value) (epi--finite-number-p value))
          (epi-gptel--audit-reject 'argument-number-malformed))
        (cons value position)))))

(defun epi-gptel--scan-json-value (text position type)
  "Decode one primitive TYPE value from TEXT at POSITION."
  (pcase type
    ("string" (epi-gptel--scan-json-string text position))
    ("boolean"
     (cond
      ((and (<= (+ position 4) (length text))
            (equal "true" (substring text position (+ position 4))))
       (cons t (+ position 4)))
      ((and (<= (+ position 5) (length text))
            (equal "false" (substring text position (+ position 5))))
       (cons epi-json-false (+ position 5)))
      (t (epi-gptel--audit-reject 'argument-boolean-malformed))))
    ((or "integer" "number")
     (epi-gptel--scan-json-number text position))
    (_ (epi-gptel--audit-reject 'argument-type-unsupported))))

(defun epi-gptel--scan-arguments (raw schema)
  "Validate bounded RAW flat JSON arguments against SCHEMA.
Return a plist containing `:ok', canonical `:arguments', and `:members'."
  (catch 'epi-gptel--audit
    (when (> (string-bytes raw) epi-tool-argument-byte-limit)
      (epi-gptel--audit-reject 'tool-argument-byte-limit))
    (let* ((position (epi-gptel--skip-json-whitespace raw 0))
           (properties (epi-gptel--object-value "properties" schema))
           (required (epi-gptel--object-value "required" schema))
           (seen (make-hash-table :test #'equal))
           (members 0)
           arguments
           done)
      (unless (and (< position (length raw)) (= (aref raw position) ?{))
        (epi-gptel--audit-reject 'argument-root-object-required))
      (setq position
            (epi-gptel--skip-json-whitespace raw (1+ position)))
      (if (and (< position (length raw)) (= (aref raw position) ?}))
          (progn (setq done t) (cl-incf position))
        (while (not done)
          (let* ((key-data (epi-gptel--scan-json-string raw position))
                 (key (car key-data))
                 (property (epi-gptel--object-member key properties)))
            (setq position
                  (epi-gptel--skip-json-whitespace raw (cdr key-data)))
            (unless (and (< position (length raw))
                         (= (aref raw position) ?:))
              (epi-gptel--audit-reject 'argument-colon-required))
            (setq position
                  (epi-gptel--skip-json-whitespace raw (1+ position)))
            (when (gethash key seen)
              (epi-gptel--audit-reject 'argument-duplicate-key))
            (unless property
              (epi-gptel--audit-reject 'argument-unknown-key))
            (puthash key t seen)
            (cl-incf members)
            (when (> members epi-tool-argument-member-limit)
              (epi-gptel--audit-reject 'tool-argument-member-limit))
            (let* ((definition (cdr property))
                   (type (epi-gptel--object-value "type" definition))
                   (value-data
                    (epi-gptel--scan-json-value raw position type))
                   (value (car value-data))
                   (enum-entry (epi-gptel--object-member "enum" definition)))
              (unless (epi-gptel--same-json-type-p value type)
                (epi-gptel--audit-reject 'argument-type-mismatch))
              (when (and enum-entry
                         (not (seq-some
                               (lambda (candidate) (equal candidate value))
                               (cdr enum-entry))))
                (epi-gptel--audit-reject 'argument-enum-mismatch))
              (push (cons key value) arguments)
              (setq position
                    (epi-gptel--skip-json-whitespace
                     raw (cdr value-data)))))
          (unless (< position (length raw))
            (epi-gptel--audit-reject 'argument-object-unterminated))
          (pcase (aref raw position)
            (?,
             (setq position
                   (epi-gptel--skip-json-whitespace raw (1+ position))))
            (?}
             (setq done t)
             (cl-incf position))
            (_ (epi-gptel--audit-reject 'argument-separator-required)))))
      (setq position (epi-gptel--skip-json-whitespace raw position))
      (unless (= position (length raw))
        (epi-gptel--audit-reject 'argument-trailing-data))
      (seq-doseq (key required)
        (unless (gethash key seen)
          (epi-gptel--audit-reject 'argument-required-key-missing)))
      (list :ok t :arguments (nreverse arguments) :members members))))

(defun epi-gptel--audit-tool-delta (request tool-calls)
  "Audit TOOL-CALLS for REQUEST before GPTel argument parsing."
  (unless (and (vectorp tool-calls) (= (length tool-calls) 1))
    (epi-gptel--audit-reject 'parallel-tool-call))
  (let* ((call (aref tool-calls 0))
         (index (cdr (assoc "index" call)))
         (id (cdr (assoc "id" call)))
         (type-entry (assoc "type" call))
         (type (cdr type-entry))
         (function-data (cdr (assoc "function" call)))
         (name (and (consp function-data)
                    (cdr (assoc "name" function-data))))
         (arguments-entry (and (consp function-data)
                               (assoc "arguments" function-data)))
         (fragment (cdr arguments-entry)))
    (unless (and (consp call) (consp function-data)
                 (or (null index) (and (integerp index) (zerop index))))
      (epi-gptel--audit-reject 'nonzero-tool-index))
    (let ((first (not (epi-gptel-request-audit-saw-tool request)))
          (id-present (and id (not (eq id epi-json-null))))
          (name-present (and name (not (eq name epi-json-null)))))
      (if first
          (unless (and id-present name-present (equal type "function"))
            (epi-gptel--audit-reject 'tool-identity-missing))
        (progn
          (when (or id-present name-present)
            (epi-gptel--audit-reject 'multiple-tool-calls))
          (when (and type-entry (not (equal type "function")))
            (epi-gptel--audit-reject 'tool-type-invalid)))))
    (when (and id (not (eq id epi-json-null)))
      (unless (and (stringp id) (not (string-empty-p id))
                   (epi--canonical-string-p id)
                   (<= (string-bytes id) epi-provider-call-id-byte-limit))
        (epi-gptel--audit-reject 'provider-call-id-limit))
      (setf (epi-gptel-request-audit-call-id request)
            (epi--plain-string-copy id)))
    (when (and name (not (eq name epi-json-null)))
      (unless (and (stringp name) (not (string-empty-p name))
                   (not (equal name "null"))
                   (epi--canonical-string-p name)
                   (<= (string-bytes name)
                       epi-provider-tool-name-byte-limit))
        (epi-gptel--audit-reject 'provider-tool-name-limit))
      (setf (epi-gptel-request-audit-name request)
            (epi--plain-string-copy name)))
    (unless (and arguments-entry (epi--canonical-string-p fragment))
      (epi-gptel--audit-reject 'argument-fragment-not-string))
    (let ((total (+ (epi-gptel-request-audit-argument-bytes request)
                    (string-bytes fragment))))
      (when (> total epi-tool-argument-byte-limit)
        (epi-gptel--audit-reject 'tool-argument-byte-limit))
      (setf (epi-gptel-request-audit-argument-bytes request) total)
      (push (epi--plain-string-copy fragment)
            (epi-gptel-request-audit-fragments request)))
    (setf (epi-gptel-request-audit-saw-tool request) t)))

(defun epi-gptel--finalize-audit (request)
  "Complete REQUEST's current raw tool attestation before GPTel parsing."
  (when (epi-gptel-request-audit-saw-tool request)
    (let* ((id (epi-gptel-request-audit-call-id request))
           (name (epi-gptel-request-audit-name request))
           (details (and name (assoc-string name
                                            (epi-gptel-request-tools request)
                                            nil)))
           (raw (apply #'concat
                       (reverse
                        (epi-gptel-request-audit-fragments request))))
           (scan (and details
                      (epi-gptel--scan-arguments
                       raw (plist-get (cdr details) :schema)))))
      (unless (and id name details (plist-get scan :ok))
        (epi-gptel--audit-reject
         (or (and (symbolp scan) scan) 'tool-argument-invalid)))
      (when (or (gethash id (epi-gptel-request-seen-call-ids request))
                (gethash id (epi-gptel-request-attestations request)))
        (epi-gptel--audit-reject 'duplicate-call-id))
      (cl-incf (epi-gptel-request-tool-count request))
      (when (> (epi-gptel-request-tool-count request)
               epi-provider-tool-call-limit)
        (epi-gptel--audit-reject 'sequential-tool-call-limit))
      (puthash id t (epi-gptel-request-seen-call-ids request))
      (puthash
       id
       (list :raw raw
             :name (epi--plain-string-copy name)
             :bytes (string-bytes raw)
             :sha256 (secure-hash 'sha256
                                  (encode-coding-string raw 'utf-8 t))
             :members (plist-get scan :members)
             :fingerprint (plist-get (cdr details) :fingerprint)
             :generation (epi-gptel-request-leg-index request))
       (epi-gptel-request-attestations request)))))

(defun epi-gptel--read-exact-outer-json (payload)
  "Read one string-keyed JSON value from PAYLOAD and require exact EOF."
  (with-temp-buffer
    (insert payload)
    (goto-char (point-min))
    (let ((json-object-type 'alist)
          (json-key-type 'string)
          (json-array-type 'vector)
          (json-null epi-json-null)
          (json-false epi-json-false))
      (prog1 (json-read)
        (while (and (not (eobp))
                    (epi-gptel--json-whitespace-p (char-after)))
          (forward-char))
        (unless (eobp)
          (error "Trailing outer JSON data"))))))

(defun epi-gptel--audit-data-line (request payload)
  "Audit one complete SSE data PAYLOAD for REQUEST."
  (when (epi-gptel-request-audit-done request)
    (epi-gptel--audit-reject
     (if (equal payload "[DONE]")
         'duplicate-stream-terminal
       'data-after-stream-terminal)))
  (if (equal payload "[DONE]")
      (progn
        (setf (epi-gptel-request-audit-done request) t)
        (epi-gptel--finalize-audit request))
    (let ((outer
           (condition-case nil
               (epi-gptel--read-exact-outer-json payload)
             (error (epi-gptel--audit-reject 'malformed-outer-json)))))
      (when (epi-gptel--outer-duplicates-p outer)
        (epi-gptel--audit-reject 'duplicate-outer-key))
      (epi-gptel--audit-envelope-shape outer)
      (let ((choices (cdr (assoc "choices" outer))))
        (when (and (vectorp choices) (= (length choices) 1))
          (let* ((delta (cdr (assoc "delta" (aref choices 0))))
                 (content-entry (and (consp delta)
                                     (assoc "content" delta)))
                 (content (cdr content-entry))
                 (reasoning-entry (and (consp delta)
                                       (assoc "reasoning" delta)))
                 (reasoning-content-entry
                  (and (consp delta) (assoc "reasoning_content" delta)))
                 (tool-calls-entry
                  (and (consp delta) (assoc "tool_calls" delta)))
                 (tool-calls (cdr tool-calls-entry))
                 (text-p (and (stringp content)
                              (not (string-empty-p content))))
                 (tools-p (and (vectorp tool-calls)
                               (> (length tool-calls) 0))))
            (dolist (entry
                     (list content-entry reasoning-entry
                           reasoning-content-entry))
              (when (and entry
                         (not (eq (cdr entry) epi-json-null))
                         (not (epi--canonical-string-p (cdr entry))))
                (epi-gptel--audit-reject 'provider-string-invalid)))
            (when (and tool-calls-entry (not (vectorp tool-calls)))
              (epi-gptel--audit-reject 'tool-calls-shape-invalid))
            (when (or (and text-p tools-p)
                      (and text-p (epi-gptel-request-audit-saw-tool request))
                      (and tools-p (epi-gptel-request-audit-saw-text request)))
              (epi-gptel--audit-reject 'mixed-text-and-tool))
            (when text-p
              (setf (epi-gptel-request-audit-saw-text request) t))
            (when tools-p
              (epi-gptel--audit-tool-delta request tool-calls))))))))

(defun epi-gptel--audit-new-envelopes (request)
  "Audit complete new SSE envelopes for REQUEST in the process buffer."
  (catch 'epi-gptel--audit
    (save-excursion
      (goto-char (min (point-max) (epi-gptel-request-audit-offset request)))
      (let ((line-start (point)))
        (while (search-forward "\n" nil t)
          (let* ((line-end (1- (point)))
                 (line (buffer-substring-no-properties line-start line-end)))
            (when (string-suffix-p "\r" line)
              (setq line (substring line 0 -1)))
            (when (string-prefix-p "data:" line)
              (epi-gptel--audit-data-line
               request (string-trim-left (substring line 5))))
            (setq line-start (point))
            (setf (epi-gptel-request-audit-offset request) (point)))))
      nil)))

(cl-defmethod gptel-curl--parse-stream :around
  ((backend gptel-openai) info)
  "Audit Epi INFO before delegating unchanged bytes to GPTel's parser."
  (let ((request (plist-get info :epi-request)))
    (if (not (epi-gptel-request-p request))
        (cl-call-next-method)
      (let ((failure (epi-gptel--audit-new-envelopes request)))
        (if failure
            (progn
              (epi-gptel--fail-stop request failure)
              "")
          (funcall epi-gptel--stock-openai-stream-parser
                   backend info))))))

(defun epi-gptel--handle-tool-use (fsm)
  "Guard one attested Epi tool call in FSM, then delegate to GPTel."
  (let* ((info (gptel-fsm-info fsm))
         (request (plist-get info :epi-request)))
    (if (not (epi-gptel-request-p request))
        (funcall epi-gptel--stock-handle-tool-use fsm)
      (let* ((tool-use (plist-get info :tool-use))
             (call (and (proper-list-p tool-use)
                        (= (length tool-use) 1)
                        (car tool-use)))
             (id (and call (plist-get call :id)))
             (name (and call (plist-get call :name)))
             (attestation
              (and (stringp id)
                   (gethash id (epi-gptel-request-attestations request)))))
        (if (and call attestation
                 (equal name (plist-get attestation :name))
                 (assoc-string name (epi-gptel-request-tools request) nil)
                 (epi-gptel-request-audit-saw-tool request)
                 (not (epi-gptel-request-audit-saw-text request)))
            (funcall epi-gptel--stock-handle-tool-use fsm)
          (epi-gptel--fail-stop request 'tool-state-attestation-failed))))))

(defun epi-gptel--check-output-limit (request text)
  "Charge TEXT to REQUEST output limits and return non-nil when admitted."
  (let* ((bytes (string-bytes text))
         (leg (+ bytes (epi-gptel-request-leg-output-bytes request)))
         (turn (+ bytes (epi-gptel-request-turn-output-bytes request))))
    (if (or (> leg epi-provider-leg-output-byte-limit)
            (> turn epi-provider-turn-output-byte-limit))
        (progn (epi-gptel--fail-stop request 'provider-output-byte-limit) nil)
      (setf (epi-gptel-request-leg-output-bytes request) leg
            (epi-gptel-request-turn-output-bytes request) turn)
      t)))

(defun epi-gptel--retained-assistant-tool-call (info)
  "Return the exact final assistant tool call retained in GPTel INFO."
  (let* ((messages (plist-get (plist-get info :data) :messages))
         (message (and (vectorp messages) (> (length messages) 0)
                       (aref messages (1- (length messages)))))
         (calls (and (equal "assistant" (plist-get message :role))
                     (plist-get message :tool_calls)))
         (call (and (vectorp calls) (= (length calls) 1) (aref calls 0)))
         (function-data (and (consp call) (plist-get call :function))))
    (when (and (consp function-data)
               (equal "function" (plist-get call :type)))
      (list :id (plist-get call :id)
            :name (plist-get function-data :name)
            :raw (plist-get function-data :arguments)))))

(defun epi-gptel--accepted-tool-callback (request pending info)
  "Normalize one GPTel-accepted PENDING tool proposal from INFO for REQUEST."
  (let* ((tool-use (plist-get info :tool-use))
         (call (and (proper-list-p tool-use)
                    (= (length tool-use) 1)
                    (car tool-use)))
         (pending-call (and (proper-list-p pending)
                            (= (length pending) 1)
                            (car pending)))
         (tool (car-safe pending-call))
         (accepted-args (cadr pending-call))
         (continuation (caddr pending-call))
         (id (and call (plist-get call :id)))
         (name (and call (plist-get call :name)))
         (attestation
          (and (stringp id)
               (gethash id (epi-gptel-request-attestations request))))
         (details (and (stringp name)
                       (assoc-string name
                                     (epi-gptel-request-tools request) nil)))
         (retained (epi-gptel--retained-assistant-tool-call info))
         (raw (and attestation (plist-get attestation :raw)))
         (scan (and raw details
                    (epi-gptel--scan-arguments
                     raw (plist-get (cdr details) :schema)))))
    (unless (and call pending-call (gptel-tool-p tool)
                 (functionp continuation)
                 (equal name (gptel-tool-name tool))
                 (equal id (plist-get retained :id))
                 (equal name (plist-get retained :name))
                 (equal raw (plist-get retained :raw))
                 attestation details (plist-get scan :ok)
                 (= (string-bytes raw) (plist-get attestation :bytes))
                 (equal (secure-hash 'sha256
                                     (encode-coding-string raw 'utf-8 t))
                        (plist-get attestation :sha256))
                 (= (plist-get scan :members)
                    (plist-get attestation :members))
                 (equal (plist-get (cdr details) :fingerprint)
                        (plist-get attestation :fingerprint))
                 (= (epi-gptel-request-leg-index request)
                    (plist-get attestation :generation))
                 (equal
                  (epi-gptel--json-normalize accepted-args)
                  (epi-gptel--json-normalize
                   (epi-gptel--canonical-to-gptel
                    (plist-get scan :arguments)))))
      (epi-gptel--fail-stop request 'tool-callback-attestation-failed)
      (cl-return-from epi-gptel--accepted-tool-callback nil))
    (remhash id (epi-gptel-request-attestations request))
    (puthash id (list :callback continuation :consumed nil)
             (epi-gptel-request-continuations request))
    (let ((raw-bytes (plist-get attestation :bytes))
          (members (plist-get attestation :members)))
      (clear-string raw)
      (epi-gptel--clear-raw-audit-state request)
      (epi-gptel--emit
       request
       (epi-gptel--event-create
        :kind 'tool-proposed :call-id id :name name
        :arguments (plist-get scan :arguments)
        :raw-byte-count raw-bytes :member-count members)))))

(defun epi-gptel--callback (request response info)
  "Normalize one documented GPTel RESPONSE with INFO for REQUEST."
  (unless (epi-gptel-request-terminal-p request)
    (condition-case nil
        (cond
         ((stringp response)
          (if (not (epi--canonical-string-p response))
              (epi-gptel--fail-stop request 'provider-string-invalid)
            (when (epi-gptel--check-output-limit request response)
              (epi-gptel--emit
               request
               (epi-gptel--event-create :kind 'text-delta :text response)))))
         ((eq response t)
          (if (not (epi-gptel-request-audit-done request))
              (epi-gptel--fail-stop request 'stream-terminal-missing)
            (unless (plist-get info :tool-use)
              (epi-gptel--cancel-watchdog request))
            (setf (epi-gptel-request-leg-finished-p request) t)
            (epi-gptel--emit
             request (epi-gptel--event-create :kind 'leg-finished))))
         ((eq response 'abort)
          (setf (epi-gptel-request-abort-requested request) t))
         ((and (consp response) (eq (car response) 'reasoning))
          (if (eq (cdr response) t)
              (epi-gptel--emit
               request
               (epi-gptel--event-create :kind 'reasoning-finished))
            (let ((text (cdr response)))
              (unless (stringp text)
                (error "Invalid reasoning callback"))
              (if (not (epi--canonical-string-p text))
                  (epi-gptel--fail-stop request 'provider-string-invalid)
                (when (epi-gptel--check-output-limit request text)
                  (epi-gptel--emit
                   request
                   (epi-gptel--event-create
                    :kind 'reasoning-delta :text text)))))))
         ((and (consp response) (eq (car response) 'tool-call))
          (epi-gptel--cancel-watchdog request)
          (epi-gptel--accepted-tool-callback request (cdr response) info))
         ((and (consp response) (eq (car response) 'tool-result))
          (let* ((tool-use (plist-get info :tool-use))
                 (call (car tool-use))
                 (result-entry (car (cdr response))))
            (unless (and (= (length tool-use) 1)
                         (= (length (cdr response)) 1))
              (error "Invalid tool result callback"))
            (epi-gptel--emit
             request
             (epi-gptel--event-create
              :kind 'tool-result-observed
              :call-id (plist-get call :id)
              :name (plist-get call :name)
              :result (nth 2 result-entry)))))
         ((null response)
          (setf (epi-gptel-request-terminal-code request) 'provider-error)
          (epi-gptel--emit
           request
           (epi-gptel--event-create
            :kind 'transport-error :code 'provider-error)))
         (t (error "Unsupported GPTel callback")))
      (error (epi-gptel--fail-stop request 'callback-normalization-failed)))))

(defun epi-gptel--reset-next-leg (request)
  "Reset per-leg REQUEST guard state immediately before network dispatch."
  (epi-gptel--clear-raw-audit-state request)
  (setf (epi-gptel-request-leg-raw-bytes request) 0
        (epi-gptel-request-leg-output-bytes request) 0
        (epi-gptel-request-audit-offset request) 1
        (epi-gptel-request-audit-argument-bytes request) 0
        (epi-gptel-request-audit-saw-text request) nil
        (epi-gptel-request-audit-saw-tool request) nil
        (epi-gptel-request-audit-done request) nil
        (epi-gptel-request-leg-finished-p request) nil)
  (cl-incf (epi-gptel-request-leg-index request)))

(defun epi-gptel-start (snapshot enqueue)
  "Start SNAPSHOT through GPTel and deliver copied events to ENQUEUE."
  (let ((request (epi-gptel--prepare-request snapshot enqueue)))
    (with-current-buffer (epi-gptel-request-buffer request)
      (gptel--fsm-transition (epi-gptel-request-fsm request)))
    request))

(defun epi-gptel-submit-tool-result (request call-id result)
  "Release REQUEST's opaque continuation for CALL-ID with string RESULT once."
  (unless (and (epi-gptel-request-p request)
               (not (epi-gptel-request-terminal-p request))
               (epi--canonical-string-p call-id)
               (not (string-empty-p call-id))
               (<= (string-bytes call-id)
                   epi-provider-call-id-byte-limit)
               (epi--canonical-string-p result))
    (epi--signal 'epi-gptel-error (list :code 'invalid-tool-result)))
  (let ((entry (gethash call-id (epi-gptel-request-continuations request))))
    (unless (and entry (not (plist-get entry :consumed))
                 (epi-gptel-request-leg-finished-p request))
      (epi--signal 'epi-gptel-error (list :code 'stale-tool-continuation)))
    (plist-put entry :consumed t)
    (remhash call-id (epi-gptel-request-continuations request))
    (setf (epi-gptel-request-next-leg-p request) t)
    (condition-case nil
        (with-current-buffer (epi-gptel-request-buffer request)
          (funcall (plist-get entry :callback)
                   (epi--plain-string-copy result)))
      (error
       (setf (epi-gptel-request-next-leg-p request) nil)
       (epi-gptel--fail-stop request 'tool-continuation-failed)))))

(defun epi-gptel-abort (request)
  "Abort REQUEST and invalidate every continuation before touching GPTel."
  (unless (epi-gptel-request-p request)
    (epi--signal 'epi-gptel-error (list :code 'invalid-request)))
  (unless (epi-gptel-request-terminal-p request)
    (setf (epi-gptel-request-abort-requested request) t)
    (epi-gptel--cancel-watchdog request)
    (epi-gptel--clear-continuations request)
    (ignore-errors (gptel-abort (epi-gptel-request-buffer request)))
    (unless (epi-gptel-request-terminal-p request)
      (epi-gptel--settle request 'request-aborted 'aborted)))
  t)

(defun epi-gptel-close (request)
  "Close REQUEST, aborting it first if it remains live."
  (unless (epi-gptel-request-p request)
    (epi--signal 'epi-gptel-error (list :code 'invalid-request)))
  (unless (epi-gptel-request-terminal-p request)
    (epi-gptel-abort request))
  (when (buffer-live-p (epi-gptel-request-buffer request))
    (kill-buffer (epi-gptel-request-buffer request)))
  t)

(defun epi-gptel--fixture-get-response (fsm)
  "Queue the next offline fixture leg after configuring transport for FSM."
  (let* ((info (gptel-fsm-info fsm))
         (request (plist-get info :epi-request))
         (body (pop epi-gptel--fixture-legs))
         (mode (or (plist-get epi-gptel--fixture-options :filter-mode)
                   'normal))
         (process-buffer (generate-new-buffer " *epi-gptel-fixture-curl*" t))
         (process (make-pipe-process
                   :name "epi-gptel-fixture-curl"
                   :buffer process-buffer :noquery t)))
    (push process epi-gptel--fixture-processes)
    (set-process-query-on-exit-flag process nil)
    (set-process-coding-system process 'utf-8-unix 'utf-8-unix)
    (when-let* ((hook (plist-get epi-gptel--fixture-options :process-hook)))
      (funcall hook process))
    (when-let* ((hook (plist-get epi-gptel--fixture-options :transport-hook)))
      (funcall hook info))
    (pcase mode
      ('none
       (epi-gptel--fixture-enqueue
        (list :process process :fsm fsm :request request
              :cleanup-only t)))
      ('twice
       (set-process-filter process #'gptel-curl--stream-filter)
       (set-process-filter process #'gptel-curl--stream-filter)
       (epi-gptel--fixture-enqueue
        (list :process process :fsm fsm :request request
              :cleanup-only t)))
      ('unexpected
       (set-process-filter
        process
        (or (plist-get epi-gptel--fixture-options :unexpected-filter)
            #'ignore))
       (epi-gptel--fixture-enqueue
        (list :process process :fsm fsm :request request
              :cleanup-only t)))
      (_
       (set-process-filter process #'gptel-curl--stream-filter)
       (setf (alist-get process gptel--request-alist)
             (cons fsm
                   (lambda ()
                     (epi-gptel--fixture-clean-process process))))
       (unless (eq mode 'stall)
         (epi-gptel--fixture-enqueue
          (list :process process :fsm fsm :request request :body body)))))))

(provide 'epi-gptel)

;;; epi-gptel.el ends here
