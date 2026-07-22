;;; epi-gptel-contract-test.el --- Pinned GPTel seam tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley
;; Keywords: tools

;;; Commentary:

;; Contract tests for GPTel 0.9.9.5 at commit
;; 8701e2bd80c5d2091ce2decef5d34d6fce4a3ada.  Exact source-form anchors and
;; SHA-256 hashes are duplicated below as the independent test oracle.  The
;; runtime-object hashes are deliberately separate: source hashes prove the
;; inspected forms, while `eq' plus printed hashes prove the three function
;; objects to which Epi actually delegates.

;;; Code:

(require 'ert)
(require 'seq)
(require 'epi-test-helper)
(require 'epi)
(require 'epi-gptel nil t)
(require 'epi-gptel-fixture-transport)

(defconst epi-gptel-contract--source-form-hashes
  '((request/parse-tools . "ccd67eb7632f0b136e55cf57202c2da45b516ddac8a0fbe919d6874045d24d65") ; gptel-request.el:1688-1738
    (request/parse-tool-results . "e59587b7684a337c50eda977dc99eeb361567af09ac170359465e86419588141") ; 1740-1744
    (request/transitions . "e6b039a74bd7987e8bf61a2c755857e60fa2cc636223414801a3cad854fc2268") ; 1799-1817
    (request/handlers . "8debd6c5a7eda019a41ae6c77b59e14875cfacaa2f8f028087ff909ece9cc4cc") ; 1819-1841
    (request/fsm-transition . "d564e89e7d24d549fd36d8398a55d3e4ed51207fe52609d806dab73877672d35") ; 1869-1881
    (request/fsm-next . "12144b5e9b9cbf4d946d293d3535a176126400f2a5c25f69dc2127e13e761236") ; 1883-1893
    (request/wait . "c7328acba2cde68ec4c77f6182bd687246207471f8c16e1646196ab356f957de") ; 1899-1913
    (request/process-tool-call . "1d6371e3756a73e1294eefa96a1f5567e5a7f57842f2132b475500692d386a73") ; 1915-1939
    (request/tool . "cadcec014c144abd9951b701b0ba34392f5adeadb94beb360962862010e76c5c") ; 1941-1993
    (request/map-tool-args . "64b5ddb101e38385460804baf47c765c69c9e7cf46376b99a77114fa2442d41b") ; 1995-2004
    (request/tool-result . "fbc5aaf2832cfcab9203e03fcb545d3e113677f48dda964630e5396e43c1fb59") ; 2006-2018
    (request/post . "c1d8566e09ab9d8e8a05853eca3018f5e17f8dfabc9d16cb23986b58fa1b3c9a") ; 2020-2024
    (request/request . "e9f9f2d08ea24c0b2cb2e6a772817fa3ec6536f7d7cdd945f48b217b91a6e384") ; 2038-2314
    (request/realize . "75861daf2fd2a4ff79a2d3f569248c8dcabc63dc61dd0269cf7744860aa163ed") ; 2316-2366
    (request/abort . "8adbfa59142d064365fe53296626edb574dce5c87f842bbfc06d99d2420601dd") ; 2368-2394
    (request/parse-buffer-generic . "5089f1b14e3186edef8218c26370292eee75b8f70645fab78c235fcb8888d1b4") ; 2438-2444
    (request/parse-list-and-insert . "cd64b550c3fa4058c674d51fe7670609e531dc2b55e65e2ad476c4797fffb072") ; 2446-2480
    (request/parse-list-generic . "4bdde434b72c9ab865ee790c1b6cbac8236d9b69d3b1b2b6dbc22e3aa88c7032") ; 2482-2489
    (request/request-data-generic . "7bd39399f1e47f20124f01df852dcd4e8ded503614607643481af8b52bbc19c1") ; 2597-2602
    (request/curl-get-response . "e64e4bb925c4d7f5b0fe0e2793e4aef7a67a5b1c7b93d812236fd51ed413a3d7") ; 2856-2925
    (request/stream-cleanup . "6754b8f0d1bf539af170cb8512d0a8865a73ff0006a4f187f29aaea220353af1") ; 2966-3014
    (request/stream-filter . "72858653817d194096b16dc0c717f3595396a1b3b05ea5ee7f0cc32ad0424c0b") ; 3016-3103
    (request/parse-stream-generic . "4181fc8df29a6897a7a5e2e42f986e26ca92ba3bd82f38da3d9a45dcdcf46893") ; 3105-3115
    (openai/parse-stream . "2dca0b34c3d6ddda8187c5018b9cb52a75b9e75134050578c9339e8f00332d26") ; gptel-openai.el:94-181
    (openai/request-data . "557d3bcf8637302b9acc8cbcd51decd921b645e77c2fdedb4b6504178599ec53") ; 217-250
    (openai/parse-tool-results . "5cbd1f73886ee0bbeab338f2d4f6e28320a50ddef726a09118a87f34326ea802") ; 300-309
    (openai/format-tool-id . "13375d8d8b390649630699a07d4ce5f20a9b0f6108bfd4e441c625f8ede45fc4") ; 312-323
    (openai/parse-list . "90230ddd955253aec297f3109315d3f7c5d7d95994a2717d2f0a1eae0f07827e") ; 334-363
    (openai/parse-buffer . "2ab106d4a9de6e4a9892101a19d1ebdf7870ab6837a6c7788ae7a1d6a157a879")) ; 365-418
  "Independent exact source-form hash oracle for the pinned GPTel seam.")

(defconst epi-gptel-contract--runtime-object-hashes
  '((gptel--handle-wait
     . "71dc413a2e4f3aee78796dd03c6512d4d4c3c4286710a368fe1097d6000c1913")
    (gptel--handle-tool-use
     . "7733e71173e4f948915954451ea410f7e26f130cd074fecf2725ff7a85049bbe")
    (gptel-curl--stream-filter
     . "0933daa08e1d0315e35f47511b5ed14579f9e4c0079f096e9f564c00cce915db")
    (gptel--parse-list-and-insert
     . "5a98d9ff32a7cdb0faa9d4511e563424f99e174934dc87c0f4901f0abdc56ebc")
    (openai/parse-stream-primary
     . "94bc25848ab0331246cf87f30221fa7ff52ad6b06d5fe36a0d6c84b66120c648"))
  "Printed hashes for the captured runtime objects; identity is also `eq'.")

(defun epi-gptel-contract--condition-plist (condition)
  "Return the one structured plist stored in CONDITION."
  (car (cdr condition)))

(defun epi-gptel-contract--event (events kind)
  "Return the first event of KIND in EVENTS."
  (seq-find (lambda (event) (eq kind (epi-gptel-event-kind event))) events))

(defun epi-gptel-contract--tool-body (id name arguments &optional index)
  "Return one complete tool SSE body for ID, NAME, ARGUMENTS, and INDEX.
The sentinel `omit' leaves the corresponding ID, NAME, or INDEX member out."
  (let* ((function-data
          (append (unless (eq name 'omit) `((name . ,name)))
                  `((arguments . ,arguments))))
         (call
          (append (unless (eq index 'omit) `((index . ,(or index 0))))
                  (unless (eq id 'omit) `((id . ,id)))
                  `((type . "function") (function . ,function-data))))
         (payload
          (json-encode
           `((choices . [((index . 0)
                          (delta . ((tool_calls . [,call])))
                          (finish_reason . nil))])))))
    (epi-test-gptel-sse payload "[DONE]")))

(defun epi-gptel-contract--request-failed-p (events)
  "Return non-nil when EVENTS end in one request failure."
  (eq 'request-failed
      (epi-gptel-event-kind (car (last events)))))

(defun epi-gptel-contract--active-process-for-request-p (request)
  "Return non-nil when GPTel still registers a process for REQUEST."
  (seq-some
   (lambda (entry)
     (eq (cadr entry) (epi-gptel-request-fsm request)))
   gptel--request-alist))

(ert-deftest epi-gptel-contract-capability-is-explicit-and-pinned ()
  (should (eq 'openai-chat-completions/sequential-tools-v1
              epi-gptel-capability))
  (let ((report (epi-gptel-check-compatibility)))
    (should (equal "0.9.9.5" (plist-get report :gptel-version)))
    (should
     (equal "8701e2bd80c5d2091ce2decef5d34d6fce4a3ada"
            (plist-get report :gptel-commit)))
    (should (eq 'classic-openai-chat-completions
                (plist-get report :backend-family)))
    (should (eq 'curl-streaming (plist-get report :streaming-mode)))
    (should (eq 'advanced-typed-history
                (plist-get report :typed-history-mode)))
    (should (= epi-provider-tool-call-limit
               (plist-get report :sequential-tool-limit)))
    (should
     (equal '(parallel-tools responses-api other-providers media
              replayed-reasoning steering configuration-refresh)
            (plist-get report :disabled-features)))))

(ert-deftest epi-gptel-contract-source-forms-and-runtime-objects-are-distinct ()
  (let ((report (epi-gptel-check-compatibility)))
    (should (equal epi-gptel-contract--source-form-hashes
                   (plist-get report :source-form-hashes)))
    (should (equal epi-gptel-contract--runtime-object-hashes
                   (plist-get report :runtime-object-hashes)))))

(ert-deftest epi-gptel-contract-runtime-delegate-redefinition-fails-closed ()
  (cl-letf (((symbol-function 'gptel--handle-wait) (lambda (_fsm) nil)))
    (let ((condition
           (should-error (epi-gptel-check-compatibility)
                         :type 'epi-gptel-incompatible)))
      (should (eq 'gptel-runtime-object-mismatch
                  (plist-get (epi-gptel-contract--condition-plist condition)
                             :code))))))

(ert-deftest epi-gptel-contract-runtime-primary-method-redefinition-fails-closed ()
  (let* ((generic (cl--generic 'gptel-curl--parse-stream))
         (method
          (car (cl--generic-member-method
                '(gptel-openai t) nil
                (cl--generic-method-table generic))))
         (original (cl--generic-method-function method)))
    (unwind-protect
        (progn
          (cl-generic-define-method
           #'gptel-curl--parse-stream nil '((_backend gptel-openai) info)
           nil (lambda (_backend _info) "replacement"))
      (let ((condition
             (should-error (epi-gptel-check-compatibility)
                           :type 'epi-gptel-incompatible)))
        (should (eq 'gptel-runtime-object-mismatch
                    (plist-get
                     (epi-gptel-contract--condition-plist condition)
                     :code)))))
      (cl-generic-define-method
       #'gptel-curl--parse-stream nil '((_backend gptel-openai) info)
       nil original))))

(ert-deftest epi-gptel-contract-dry-run-selects-exact-backend-model-and-stream ()
  (epi-test-with-gptel-fixtures nil
    (let ((data (epi-test-gptel-dry-run-data (epi-test-text-snapshot))))
      (should (equal "epi-fixture-model" (plist-get data :model)))
      (should (eq t (plist-get data :stream)))
      (should-not (plist-member data :tools)))))

(ert-deftest epi-gptel-contract-dry-run-recursively-owns-nested-strings ()
  (let ((real-copy (symbol-function 'epi-gptel--copy-request-data))
        internal output)
    (cl-letf (((symbol-function 'epi-gptel--copy-request-data)
               (lambda (data)
                 (setq internal data)
                 (funcall real-copy data))))
      (epi-test-with-gptel-fixtures nil
        (setq output
              (epi-test-gptel-dry-run-data (epi-test-text-snapshot)))))
    (let ((internal-content
           (plist-get (aref (plist-get internal :messages) 1) :content))
          (output-content
           (plist-get (aref (plist-get output :messages) 1) :content)))
      (should-not (eq internal-content output-content))
      (aset output-content 0 ?X)
      (should (equal "Hello" internal-content)))))

(ert-deftest epi-gptel-contract-hostile-request-globals-are-inert ()
  (let ((gptel-mode t)
        (gptel-track-response nil)
        (gptel--num-messages-to-send 1)
        (gptel-temperature 0.77)
        (gptel-max-tokens 321)
        (gptel-cache t)
        (gptel--schema '(:type object)))
    (epi-test-with-gptel-fixtures nil
      (let ((data (epi-test-gptel-dry-run-data (epi-test-text-snapshot))))
        (should (= 2 (length (plist-get data :messages))))
        (dolist (key '(:temperature :max_tokens :response_format))
          (should-not (plist-member data key)))))))

(ert-deftest epi-gptel-contract-dry-run-disables-parallel-tools ()
  (epi-test-with-gptel-fixtures nil
    (let ((data (epi-test-gptel-dry-run-data (epi-test-tool-snapshot))))
      (should (epi-test-gptel-json-false-p
               (plist-get data :parallel_tool_calls)))
      (should (= 2 (length (plist-get data :tools)))))))

(ert-deftest epi-gptel-contract-zero-property-schema-is-repaired-and-compared ()
  (epi-test-with-gptel-fixtures nil
    (let* ((snapshot
            (epi-test-text-snapshot
             nil
             (list (epi-test-gptel-tool
                    "ping" (epi-test-gptel-zero-property-schema)))))
           (data (epi-test-gptel-dry-run-data snapshot))
           (parameters
            (plist-get (plist-get (aref (plist-get data :tools) 0) :function)
                       :parameters)))
      (should (equal [] (plist-get parameters :required)))
      (should (epi-test-gptel-json-false-p
               (plist-get parameters :additionalProperties))))))

(ert-deftest epi-gptel-contract-false-sentinel-translates-in-schema-and-request ()
  (let* ((schema
          '(("type" . "object")
            ("properties" .
             (("enabled" . (("type" . "boolean")
                             ("enum" . [epi-json-false t])))))
            ("required" . ["enabled"])
            ("additionalProperties" . epi-json-false)))
         (snapshot
          (epi-gptel-snapshot-create
           :backend "epi-fixture" :model 'epi-fixture-model
           :system "System" :prompt "Hello"
           :tools (list (epi-test-gptel-tool "toggle" schema))
           :request-params (list :store epi-json-false)
           :transport 'curl))
         (body
          (epi-gptel-contract--tool-body
           "toggle-id" "toggle" "{\"enabled\":false}" 0)))
    (epi-test-with-gptel-fixtures nil
      (let* ((data (epi-test-gptel-dry-run-data snapshot))
             (parameters
              (plist-get
               (plist-get (aref (plist-get data :tools) 0) :function)
               :parameters))
             (enum
              (plist-get (cadr (plist-get parameters :properties)) :enum)))
        (should (equal [:json-false t] enum))
        (should (eq :json-false (plist-get data :store)))))
    (epi-gptel-fixture-call-with-transport
     (list body)
     (lambda ()
       (let ((proposal
              (epi-gptel-contract--event
               (epi-test-run-gptel-contract snapshot) 'tool-proposed)))
         (should proposal)
         (should (eq epi-json-false
                     (cdr (assoc "enabled"
                                 (epi-gptel-event-arguments proposal))))))))))

(ert-deftest epi-gptel-contract-typed-history-preserves-whitespace-and-raw-id ()
  (epi-test-with-gptel-fixtures nil
    (let* ((history
            '((("role" . "user") ("text" . "  keep user whitespace\n"))
              (("role" . "assistant") ("text" . "\tkeep response\t"))
              (("role" . "tool")
               ("call_id" . "opaque-id-without-call-prefix")
               ("name" . "read_file")
               ("arguments" . (("path" . " README.md ")))
               ("result" . "  exact tool result\n"))))
           (data (epi-test-gptel-dry-run-data
                  (epi-test-tool-snapshot history)))
           (messages (plist-get data :messages)))
      (should (equal "  keep user whitespace\n"
                     (plist-get (aref messages 1) :content)))
      (should (equal "\tkeep response\t"
                     (plist-get (aref messages 2) :content)))
      (should
       (equal "opaque-id-without-call-prefix"
              (plist-get (aref (plist-get (aref messages 3) :tool_calls) 0)
                         :id)))
      (should (equal "  exact tool result\n"
                     (plist-get (aref messages 4) :content))))))

(ert-deftest epi-gptel-contract-history-projection-is-linear-and-ordered ()
  (let* ((history
          (cl-loop for index below 200
                   collect
                   (list (cons "role" (if (zerop (% index 2))
                                          "user" "assistant"))
                         (cons "text" (format "message-%03d" index)))))
         (snapshot (epi-test-text-snapshot history))
         (real-append (symbol-function 'append))
         (append-calls 0)
         projection)
    (cl-letf (((symbol-function 'append)
               (lambda (&rest sequences)
                 (cl-incf append-calls)
                 (apply real-append sequences))))
      (setq projection (epi-gptel--history-projection snapshot nil)))
    (should (< append-calls 10))
    (should (= 200 (length (plist-get projection :advanced))))
    (should (equal "message-000"
                   (cdar (plist-get projection :advanced))))
    (should (equal "message-199"
                   (cdr (car (last (plist-get projection :advanced))))))
    (should (equal "message-000"
                   (plist-get (aref (plist-get projection :messages) 1)
                              :content)))
    (should (equal "message-199"
                   (plist-get (aref (plist-get projection :messages) 200)
                              :content)))))

(ert-deftest epi-gptel-contract-hostile-backend-parallel-override-fails ()
  (epi-test-with-gptel-fixtures/options
      nil '(:request-params (:parallel_tool_calls t))
    (let ((condition
           (should-error
            (epi-test-gptel-dry-run-data (epi-test-tool-snapshot))
            :type 'epi-gptel-incompatible)))
      (should (eq 'parallel-tools-not-disabled
                  (plist-get (epi-gptel-contract--condition-plist condition)
                             :code))))))

(ert-deftest epi-gptel-contract-missing-model-fails-before-transport ()
  (epi-test-with-gptel-fixtures nil
    (let ((snapshot (epi-test-text-snapshot)))
      (setf (epi-gptel-snapshot-model snapshot) 'missing-model)
      (should-error (epi-gptel-start snapshot #'ignore)
                    :type 'epi-gptel-incompatible))))

(ert-deftest epi-gptel-contract-noncurl-transport-fails ()
  (epi-test-with-gptel-fixtures nil
    (let ((snapshot (epi-test-text-snapshot)))
      (setf (epi-gptel-snapshot-transport snapshot) 'url)
      (should-error (epi-gptel-start snapshot #'ignore)
                    :type 'epi-gptel-incompatible))))

(ert-deftest epi-gptel-contract-responses-api-and-other-provider-fail ()
  (dolist (family '(responses other))
    (epi-test-with-gptel-fixtures/options nil (list :family family)
      (should-error
       (epi-test-gptel-dry-run-data (epi-test-text-snapshot))
       :type 'epi-gptel-incompatible))))

(ert-deftest epi-gptel-contract-openai-subclass-fails-exact-family-check ()
  (require 'gptel-openai-extras)
  (let* ((name "epi-openai-subclass")
         (old-entry (assoc-string name gptel--known-backends t))
         (old-backend (cdr old-entry)))
    (unwind-protect
        (progn
          (gptel-make-deepseek
              name
            :models '(epi-fixture-model) :stream t :header nil)
          (let ((snapshot (epi-test-text-snapshot)))
            (setf (epi-gptel-snapshot-backend snapshot) name)
            (should-error (epi-gptel-dry-run snapshot)
                          :type 'epi-gptel-incompatible)))
      (if old-entry
          (setf (alist-get name gptel--known-backends nil nil #'equal)
                old-backend)
        (setf (alist-get name gptel--known-backends nil 'remove #'equal)
              nil)))))

(ert-deftest epi-gptel-contract-unsupported-nested-schema-fails ()
  (epi-test-with-gptel-fixtures nil
    (let ((snapshot
           (epi-test-text-snapshot
            nil
            (list
             (epi-test-gptel-tool
              "nested"
              '(("type" . "object")
                ("properties" .
                 (("value" . (("type" . "object")
                                ("properties" . nil)))))
                ("required" . ["value"])
                ("additionalProperties" . epi-json-false)))))))
      (should-error (epi-test-gptel-dry-run-data snapshot)
                    :type 'epi-gptel-incompatible))))

(ert-deftest epi-gptel-contract-request-params-are-owned-json-plists ()
  (let* ((leaf (copy-sequence "owned"))
         (items (vector leaf))
         (nested (list :items items))
         (params (list :metadata nested))
         (snapshot
          (epi-gptel-snapshot-create
           :backend "epi-fixture" :model 'epi-fixture-model
           :prompt "Hello" :request-params params :transport 'curl)))
    (aset leaf 0 ?X)
    (aset items 0 "replaced")
    (setcar (cdr nested) nil)
    (should
     (equal '(:metadata (:items ["owned"]))
            (epi-gptel-snapshot-request-params snapshot))))
  (let ((cycle (list :metadata nil)))
    (setcar (cdr cycle) cycle)
    (should-error
     (epi-gptel-snapshot-create
      :backend "epi-fixture" :model 'epi-fixture-model
      :prompt "Hello" :request-params cycle :transport 'curl)
     :type 'epi-gptel-incompatible))
  (dolist (params (list '(:metadata)
                        (list :metadata (current-buffer))
                        (list :metadata (string-make-unibyte "\377"))))
    (should-error
     (epi-gptel-snapshot-create
      :backend "epi-fixture" :model 'epi-fixture-model
      :prompt "Hello" :request-params params :transport 'curl)
     :type 'epi-gptel-incompatible)))

(ert-deftest epi-gptel-contract-empty-root-arguments-round-trip ()
  (let* ((body
          (epi-test-gptel-sse
           "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"empty-args-id\",\"type\":\"function\",\"function\":{\"name\":\"optional_label\",\"arguments\":\"{}\"}}]}}]}"
           "[DONE]"))
         (snapshot
          (epi-test-text-snapshot
           nil
           (list (epi-test-gptel-tool
                  "optional_label"
                  (epi-test-gptel-empty-argument-schema))))))
    (epi-gptel-fixture-call-with-transport
     (list body)
     (lambda ()
       (let* ((state (epi-test-open-gptel-request snapshot))
              (proposal
               (epi-gptel-contract--event
                (epi-test-gptel-events state) 'tool-proposed)))
         (should (equal nil (epi-gptel-event-arguments proposal))))))))

(ert-deftest epi-gptel-contract-leg-finish-is-not-terminal ()
  (epi-test-with-gptel-fixtures '("text.sse")
    (let ((events (epi-test-run-gptel-contract
                   (epi-test-text-snapshot))))
      (should (= 1 (epi-test-count-kind events 'leg-finished)))
      (should (= 1 (epi-test-count-kind events 'request-finished)))
      (should (< (epi-test-event-index events 'leg-finished)
                 (epi-test-event-index events 'request-finished))))))

(ert-deftest epi-gptel-contract-reasoning-callback-forms-are-distinct ()
  (epi-test-with-gptel-fixtures '("reasoning.sse")
    (let ((events (epi-test-run-gptel-contract
                   (epi-test-text-snapshot))))
      (should (equal '(reasoning-delta reasoning-finished text-delta
                       leg-finished request-finished)
                     (epi-test-gptel-event-kinds events))))))

(ert-deftest epi-gptel-contract-two-leg-tool-request-is-sequential ()
  (epi-test-with-gptel-fixtures '("read-tool.sse" "final.sse")
    (let ((events (epi-test-run-gptel-contract
                   (epi-test-tool-snapshot) '("contents"))))
      (should
       (equal '(leg-finished tool-proposed tool-result-observed
                text-delta leg-finished request-finished)
              (epi-test-gptel-event-kinds events)))
      (should (equal "call_read_17"
                     (epi-gptel-event-call-id
                      (epi-gptel-contract--event events 'tool-proposed)))))))

(ert-deftest epi-gptel-contract-three-leg-tool-request-preserves-each-id ()
  (epi-test-with-gptel-fixtures
      '("read-tool.sse" "write-tool.sse" "final.sse")
    (let* ((events (epi-test-run-gptel-contract
                    (epi-test-tool-snapshot) '("contents" "updated")))
           (ids
            (mapcar #'epi-gptel-event-call-id
                    (seq-filter
                     (lambda (event)
                       (eq 'tool-proposed (epi-gptel-event-kind event)))
                     events))))
      (should (equal '("call_read_17" "opaque-write-id") ids))
      (should (= 3 (epi-test-count-kind events 'leg-finished)))
      (should (= 1 (epi-test-count-kind events 'request-finished))))))

(ert-deftest epi-gptel-contract-leg-index-advances-only-at-next-wait ()
  (epi-test-with-gptel-fixtures '("read-tool.sse" "final.sse")
    (let (request observed)
      (setq request
            (epi-gptel-start
             (epi-test-tool-snapshot)
             (lambda (event)
               (push (cons (epi-gptel-request-leg-index request) event)
                     observed))))
      (epi-gptel-fixture-pump)
      (let* ((proposal
              (epi-gptel-contract--event
               (mapcar #'cdr observed) 'tool-proposed))
             (call-id (epi-gptel-event-call-id proposal)))
        (should (= 0 (epi-gptel-request-leg-index request)))
        (epi-gptel-submit-tool-result request call-id "contents")
        (let ((entry
               (seq-find
                (lambda (pair)
                  (eq 'tool-result-observed
                      (epi-gptel-event-kind (cdr pair))))
                observed)))
          (should entry)
          (should (= 0 (car entry))))
        (should (= 1 (epi-gptel-request-leg-index request)))
        (epi-gptel-fixture-pump)
        (should (eq 'request-finished
                    (epi-gptel-request-terminal-kind request)))))))

(ert-deftest epi-gptel-contract-sequential-call-id-survives-replay ()
  (epi-test-with-gptel-fixtures nil
    (let* ((history
            '((("role" . "tool")
               ("call_id" . "call_read_17")
               ("name" . "read_file")
               ("arguments" . (("path" . "README.md")))
               ("result" . "contents"))))
           (data (epi-test-gptel-dry-run-data
                  (epi-test-tool-snapshot history)))
           (messages (plist-get data :messages)))
      (should (equal "call_read_17"
                     (plist-get
                      (aref (plist-get (aref messages 1) :tool_calls) 0)
                      :id)))
      (should (equal "call_read_17"
                     (plist-get (aref messages 2) :tool_call_id))))))

(ert-deftest epi-gptel-contract-duplicate-inner-argument-key-fails-before-tool ()
  (let ((body
         (epi-test-gptel-sse
          "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"dup\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"one\\\",\\\"path\\\":\\\"two\\\"}\"}}]}}]}"
          "[DONE]")))
    (epi-gptel-fixture-call-with-transport
     (list body)
     (lambda ()
       (let ((events (epi-test-run-gptel-contract
                      (epi-test-tool-snapshot))))
         (should-not (memq 'tool-proposed
                           (epi-test-gptel-event-kinds events)))
         (should (memq 'request-failed
                       (epi-test-gptel-event-kinds events))))))))

(ert-deftest epi-gptel-contract-duplicate-outer-key-fails-before-tool ()
  (let ((body
         (epi-test-gptel-sse
          "{\"choices\":[],\"choices\":[{\"index\":0,\"delta\":{\"content\":\"bad\"}}]}"
          "[DONE]")))
    (epi-gptel-fixture-call-with-transport
     (list body)
     (lambda ()
       (let ((events (epi-test-run-gptel-contract
                      (epi-test-text-snapshot))))
         (should (equal '(request-failed)
                        (epi-test-gptel-event-kinds events))))))))

(ert-deftest epi-gptel-contract-parallel-or-nonzero-tool-index-fails ()
  (dolist
      (body
       (list
        (epi-test-gptel-sse
         "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"one\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{}\"}},{\"index\":1,\"id\":\"two\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{}\"}}]}}]}"
         "[DONE]")
        (epi-test-gptel-sse
         "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"one\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{}\"}}]}}]}"
         "[DONE]")))
    (epi-gptel-fixture-call-with-transport
     (list body)
     (lambda ()
       (let ((events (epi-test-run-gptel-contract
                      (epi-test-tool-snapshot))))
         (should (equal '(request-failed)
                        (epi-test-gptel-event-kinds events))))))))

(ert-deftest epi-gptel-contract-mixed-text-and-tool-fails ()
  (let ((body
         (epi-test-gptel-sse
          "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"mixed\",\"tool_calls\":[{\"index\":0,\"id\":\"mix\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"README.md\\\"}\"}}]}}]}"
          "[DONE]")))
    (epi-gptel-fixture-call-with-transport
     (list body)
     (lambda ()
       (let ((events (epi-test-run-gptel-contract
                      (epi-test-tool-snapshot))))
         (should (equal '(request-failed)
                        (epi-test-gptel-event-kinds events))))))))

(ert-deftest epi-gptel-contract-undeclared-tool-fails-before-continuation ()
  (let ((body
         (epi-test-gptel-sse
          "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"unknown\",\"function\":{\"name\":\"not_declared\",\"arguments\":\"{}\"}}]}}]}"
          "[DONE]")))
    (epi-gptel-fixture-call-with-transport
     (list body)
     (lambda ()
       (let ((events (epi-test-run-gptel-contract
                      (epi-test-tool-snapshot))))
         (should-not (memq 'tool-proposed
                           (epi-test-gptel-event-kinds events)))
         (should (memq 'request-failed
                       (epi-test-gptel-event-kinds events))))))))

(ert-deftest epi-gptel-contract-call-id-limit-is-inclusive ()
  (let* ((body (epi-test-gptel-fixture "read-tool.sse"))
         (id "call_read_17")
         (exact (string-bytes id)))
    (let ((epi-provider-call-id-byte-limit exact))
      (epi-gptel-fixture-call-with-transport
       (list body)
       (lambda ()
         (should (memq 'tool-proposed
                       (epi-test-gptel-event-kinds
                        (epi-test-run-gptel-contract
                         (epi-test-tool-snapshot))))))))
    (let ((epi-provider-call-id-byte-limit (1- exact)))
      (epi-gptel-fixture-call-with-transport
       (list body)
       (lambda ()
         (should (equal '(request-failed)
                        (epi-test-gptel-event-kinds
                         (epi-test-run-gptel-contract
                         (epi-test-tool-snapshot))))))))))

(ert-deftest epi-gptel-contract-replay-call-id-limit-is-inclusive ()
  (let* ((limit 12)
         (exact (make-string limit ?i))
         (history
          (lambda (call-id)
            `((("role" . "tool") ("call_id" . ,call-id)
               ("name" . "read_file")
               ("arguments" . (("path" . "README.md")))
               ("result" . "contents"))))))
    (let ((epi-provider-call-id-byte-limit limit))
      (epi-test-with-gptel-fixtures nil
        (should (epi-test-gptel-dry-run-data
                 (epi-test-tool-snapshot (funcall history exact))))
        (should-error
         (epi-test-gptel-dry-run-data
          (epi-test-tool-snapshot (funcall history (concat exact "x"))))
         :type 'epi-gptel-incompatible)))))

(ert-deftest epi-gptel-contract-raw-leg-limit-rejects-crossing-chunk ()
  (let* ((body (epi-test-gptel-fixture "text.sse"))
         (wire (epi-test-gptel-fixture-wire-byte-count body)))
    (let ((epi-provider-leg-raw-byte-limit wire)
          (epi-provider-turn-raw-byte-limit wire))
      (epi-gptel-fixture-call-with-transport
       (list body)
       (lambda ()
         (should (memq 'request-finished
                       (epi-test-gptel-event-kinds
                        (epi-test-run-gptel-contract
                         (epi-test-text-snapshot))))))))
    (let ((epi-provider-leg-raw-byte-limit (1- wire))
          (epi-provider-turn-raw-byte-limit wire))
      (epi-gptel-fixture-call-with-transport
       (list body)
       (lambda ()
         (should (equal '(request-failed)
                        (epi-test-gptel-event-kinds
                         (epi-test-run-gptel-contract
                          (epi-test-text-snapshot))))))))))

(ert-deftest epi-gptel-contract-malformed-sse-and-provider-error-are-redacted ()
  (dolist (fixture '("malformed.sse" "error.json"))
    (epi-test-with-gptel-fixtures (list fixture)
      (let* ((events (epi-test-run-gptel-contract
                      (epi-test-text-snapshot)))
             (failure (epi-gptel-contract--event events 'request-failed)))
        (should failure)
        (should-not
         (string-match-p "secret provider detail"
                         (prin1-to-string failure)))))))

(ert-deftest epi-gptel-contract-stream-requires-one-final-terminal-marker ()
  (dolist
      (body
       (list
        (epi-test-gptel-sse
         "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"no terminal\"}}]}")
        (epi-test-gptel-sse
         "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"first\"}}]}"
         "[DONE]"
         "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"late\"}}]}")))
    (epi-gptel-fixture-call-with-transport
     (list body)
     (lambda ()
       (let ((events
              (epi-test-run-gptel-contract (epi-test-text-snapshot))))
         (should (epi-gptel-contract--request-failed-p events))
         (should-not (epi-gptel-contract--event events 'request-finished)))))))

(ert-deftest epi-gptel-contract-submit-continuation-is-exactly-once ()
  (epi-test-with-gptel-fixtures '("read-tool.sse" "final.sse")
    (let* ((state (epi-test-open-gptel-request (epi-test-tool-snapshot)))
           (request (epi-test-gptel-request state))
           (proposal
            (epi-gptel-contract--event
             (epi-test-gptel-events state) 'tool-proposed))
           (call-id (epi-gptel-event-call-id proposal)))
      (epi-gptel-submit-tool-result request call-id "contents")
      (should-error
       (epi-gptel-submit-tool-result request call-id "duplicate")
       :type 'epi-gptel-error))))

(ert-deftest epi-gptel-contract-continuation-exception-fails-closed ()
  (let ((transport-calls 0)
        (abort-calls 0)
        (real-abort (symbol-function 'gptel-abort)))
    (epi-test-with-gptel-fixtures/options
        '("read-tool.sse" "final.sse")
        (list :transport-hook
              (lambda (_info) (cl-incf transport-calls)))
      (let* ((state (epi-test-open-gptel-request
                     (epi-test-tool-snapshot)))
             (request (epi-test-gptel-request state))
             (proposal
              (epi-gptel-contract--event
               (epi-test-gptel-events state) 'tool-proposed))
             (call-id (epi-gptel-event-call-id proposal))
             (entry (gethash call-id
                             (epi-gptel-request-continuations request))))
        (plist-put entry :callback
                   (lambda (_result)
                     (error "opaque continuation secret")))
        (cl-letf (((symbol-function 'gptel-abort)
                   (lambda (buffer)
                     (cl-incf abort-calls)
                     (funcall real-abort buffer))))
          (epi-gptel-submit-tool-result request call-id "contents")
          (epi-gptel--fixture-drain-abort-timer request))
        (should (eq 'request-failed
                    (epi-gptel-request-terminal-kind request)))
        (should (eq 'tool-continuation-failed
                    (epi-gptel-request-terminal-code request)))
        (should-not (string-match-p
                     "opaque continuation secret"
                     (prin1-to-string (epi-test-gptel-events state))))
        (should (= 0 (hash-table-count
                      (epi-gptel-request-continuations request))))
        (should-not (epi-gptel-request-watchdog request))
        (should-not (epi-gptel-request-next-leg-p request))
        (should (= 1 (length epi-gptel--fixture-legs)))))
    (should (= 1 transport-calls))
    (should (= 1 abort-calls))))

(ert-deftest epi-gptel-contract-submit-rejects-noncanonical-values ()
  (epi-test-with-gptel-fixtures '("read-tool.sse")
    (let* ((state (epi-test-open-gptel-request (epi-test-tool-snapshot)))
           (request (epi-test-gptel-request state))
           (proposal
            (epi-gptel-contract--event
             (epi-test-gptel-events state) 'tool-proposed))
           (call-id (epi-gptel-event-call-id proposal)))
      (should-error
       (epi-gptel-submit-tool-result
        request (string-make-unibyte "\377") "contents")
       :type 'epi-gptel-error)
      (should-error
       (epi-gptel-submit-tool-result
        request call-id (string-make-unibyte "\377"))
       :type 'epi-gptel-error)
      (should (= 1 (hash-table-count
                    (epi-gptel-request-continuations request)))))))

(ert-deftest epi-gptel-contract-abort-while-paused-in-tool-is-terminal ()
  (epi-test-with-gptel-fixtures '("read-tool.sse")
    (let* ((state (epi-test-open-gptel-request (epi-test-tool-snapshot)))
           (request (epi-test-gptel-request state)))
      (should (memq 'tool-proposed
                    (epi-test-gptel-event-kinds
                     (epi-test-gptel-events state))))
      (epi-gptel-abort request)
      (should (eq 'request-aborted
                  (car (last (epi-test-gptel-event-kinds
                              (epi-test-gptel-events state)))))))))

(ert-deftest epi-gptel-contract-abort-during-transport-is-terminal ()
  (epi-test-with-gptel-fixtures/options
      '("text.sse") '(:filter-mode stall)
    (let* ((state (epi-test-open-gptel-request (epi-test-text-snapshot)))
           (request (epi-test-gptel-request state)))
      (should-not (epi-gptel-request-terminal-p request))
      (should-not (epi-test-gptel-events state))
      (epi-gptel-abort request)
      (should (epi-gptel-request-terminal-p request))
      (should (equal '(request-aborted)
                     (epi-test-gptel-event-kinds
                      (epi-test-gptel-events state))))
      (should (= 0 (hash-table-count
                    (epi-gptel-request-continuations request)))))))

(ert-deftest epi-gptel-contract-approval-wait-does-not-use-leg-watchdog ()
  (let ((epi-gptel-no-progress-timeout 0.001))
    (epi-test-with-gptel-fixtures '("read-tool.sse")
      (let ((state (epi-test-open-gptel-request (epi-test-tool-snapshot))))
        (sleep-for 0.01)
        (should-not (epi-gptel-request-terminal-p
                     (epi-test-gptel-request state)))
        (should (equal '(leg-finished tool-proposed)
                       (epi-test-gptel-event-kinds
                        (epi-test-gptel-events state))))))))

(ert-deftest epi-gptel-contract-callback-exception-takes-fail-stop-path ()
  (epi-test-with-gptel-fixtures '("text.sse")
    (let ((calls 0))
      (let ((request
             (epi-gptel-start
              (epi-test-text-snapshot)
              (lambda (_event)
                (cl-incf calls)
                (error "hostile callback secret")))))
        (epi-gptel-fixture-pump)
        (should (epi-gptel-request-terminal-p request))
        (should (eq 'request-failed
                    (epi-gptel-request-terminal-kind request)))
        (should (= calls 1))))))

(ert-deftest epi-gptel-contract-hostile-global-post-hook-never-runs ()
  (let ((ran nil))
    (epi-test-with-gptel-fixtures/options
        '("text.sse") (list :global-post-hook (lambda () (setq ran t)))
      (epi-test-run-gptel-contract (epi-test-text-snapshot))
      (should-not ran))))

(ert-deftest epi-gptel-contract-wait-filter-installation-is-exact ()
  (dolist (mode '(none twice unexpected))
    (epi-test-with-gptel-fixtures/options
        '("text.sse") (list :filter-mode mode)
      (let ((events (epi-test-run-gptel-contract
                     (epi-test-text-snapshot))))
        (should (equal '(request-failed)
                       (epi-test-gptel-event-kinds events)))))))

(ert-deftest epi-gptel-contract-shadowed-or-compiled-source-fails-closed ()
  (let ((real-locate (symbol-function 'locate-library)))
    (cl-letf (((symbol-function 'locate-library)
               (lambda (library &rest arguments)
                 (if (equal library "gptel-request")
                     "/var/tmp/shadow/gptel-request.elc"
                   (apply real-locate library arguments)))))
      (let ((condition
             (should-error (epi-gptel-check-compatibility)
                           :type 'epi-gptel-incompatible)))
        (should (eq 'gptel-source-provenance-mismatch
                    (plist-get
                     (epi-gptel-contract--condition-plist condition)
                     :code))))))
  (let ((real-symbol-file (symbol-function 'symbol-file)))
    (cl-letf (((symbol-function 'symbol-file)
               (lambda (symbol &optional type)
                 (if (eq symbol 'gptel--handle-wait)
                     "/var/tmp/shadow/gptel-request.elc"
                   (funcall real-symbol-file symbol type)))))
      (let ((condition
             (should-error (epi-gptel-check-compatibility)
                           :type 'epi-gptel-incompatible)))
        (should (eq 'gptel-source-provenance-mismatch
                    (plist-get
                     (epi-gptel-contract--condition-plist condition)
                     :code)))))))

(ert-deftest epi-gptel-contract-ineffective-backend-streaming-fails ()
  (epi-test-with-gptel-fixtures/options nil '(:stream nil)
    (let ((condition
           (should-error
            (epi-test-gptel-dry-run-data (epi-test-text-snapshot))
            :type 'epi-gptel-incompatible)))
      (should (memq
               (plist-get (epi-gptel-contract--condition-plist condition)
                          :code)
               '(streaming-not-supported effective-request-selection-mismatch))))))

(ert-deftest epi-gptel-contract-missing-id-and-later-index-fail-pre-parse ()
  (let ((missing-id
         (epi-gptel-contract--tool-body
          'omit "read_file" "{\"path\":\"README.md\"}" 0))
        (later-index
         (epi-test-gptel-sse
          "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"same\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\"}}]}}]}"
          "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"same\",\"function\":{\"arguments\":\"\\\"path\\\":\\\"README.md\\\"}\"}}]}}]}"
          "[DONE]")))
    (dolist (body (list missing-id later-index))
      (epi-gptel-fixture-call-with-transport
       (list body)
       (lambda ()
         (let ((events (epi-test-run-gptel-contract
                        (epi-test-tool-snapshot))))
           (should (epi-gptel-contract--request-failed-p events))
           (should-not (epi-gptel-contract--event events 'tool-proposed))))))))

(ert-deftest epi-gptel-contract-distinct-calls-across-deltas-fail ()
  (let ((body
         (epi-test-gptel-sse
          "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"first\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\"}}]}}]}"
          "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"second\",\"function\":{\"name\":\"read_file\",\"arguments\":\"}\"}}]}}]}"
          "[DONE]")))
    (epi-gptel-fixture-call-with-transport
     (list body)
     (lambda ()
       (let ((events (epi-test-run-gptel-contract
                      (epi-test-tool-snapshot))))
         (should (equal '(request-failed)
                        (epi-test-gptel-event-kinds events))))))))

(ert-deftest epi-gptel-contract-repeated-or-late-tool-identity-fails-pre-parse ()
  (dolist
      (body
       (list
        (epi-test-gptel-sse
         "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"same\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\"}}]}}]}"
         "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"same\",\"function\":{\"name\":\"read_file\",\"arguments\":\"\\\"README.md\\\"}\"}}]}}]}"
         "[DONE]")
        (epi-test-gptel-sse
         "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"path\\\":\"}}]}}]}"
         "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"late\",\"function\":{\"name\":\"read_file\",\"arguments\":\"\\\"README.md\\\"}\"}}]}}]}"
         "[DONE]")))
    (let ((real-json-parse-string (symbol-function 'json-parse-string))
          (inner-argument-parses 0))
      (cl-letf (((symbol-function 'json-parse-string)
                 (lambda (string &rest arguments)
                   (when (eq (plist-get arguments :object-type) 'plist)
                     (cl-incf inner-argument-parses))
                   (apply real-json-parse-string string arguments))))
        (epi-gptel-fixture-call-with-transport
         (list body)
         (lambda ()
           (let ((events
                  (epi-test-run-gptel-contract
                   (epi-test-tool-snapshot))))
             (should (equal '(request-failed)
                            (epi-test-gptel-event-kinds events)))
             (should (= 0 inner-argument-parses)))))))))

(ert-deftest epi-gptel-contract-missing-tool-type-fails-pre-parse ()
  (let ((body
         (epi-test-gptel-sse
          "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"missing-type\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"README.md\\\"}\"}}]}}]}"
          "[DONE]"))
        (real-inner (symbol-function 'gptel--json-read-string))
        (real-tool epi-gptel--stock-handle-tool-use)
        (inner-calls 0)
        (tool-calls 0))
    (cl-letf (((symbol-function 'gptel--json-read-string)
               (lambda (&rest arguments)
                 (cl-incf inner-calls)
                 (apply real-inner arguments))))
      (let ((epi-gptel--stock-handle-tool-use
             (lambda (fsm)
               (cl-incf tool-calls)
               (funcall real-tool fsm))))
        (epi-gptel-fixture-call-with-transport
         (list body)
         (lambda ()
           (should
            (equal '(request-failed)
                   (epi-test-gptel-event-kinds
                    (epi-test-run-gptel-contract
                     (epi-test-tool-snapshot)))))))))
    (should (= 0 inner-calls))
    (should (= 0 tool-calls))))

(ert-deftest epi-gptel-contract-one-call-may-fragment-only-arguments ()
  (let ((body
         (epi-test-gptel-sse
          "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"split-ok\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\"}}]}}]}"
          "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"README.md\\\"}\"}}]}}]}"
          "[DONE]")))
    (epi-gptel-fixture-call-with-transport
     (list body)
     (lambda ()
       (let ((proposal
              (epi-gptel-contract--event
               (epi-test-run-gptel-contract (epi-test-tool-snapshot))
               'tool-proposed)))
         (should proposal)
         (should (equal "split-ok" (epi-gptel-event-call-id proposal))))))))

(ert-deftest epi-gptel-contract-fragment-byte-limit-rejects-before-copy ()
  (let* ((first "{\"path\":")
         (second "\"README.md\"}")
         (raw (concat first second))
         (body
          (epi-test-gptel-sse
           "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"split-limit\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\"}}]}}]}"
           "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"README.md\\\"}\"}}]}}]}"
           "[DONE]")))
    (let ((epi-tool-argument-byte-limit (string-bytes raw)))
      (epi-gptel-fixture-call-with-transport
       (list body)
       (lambda ()
         (should
          (epi-gptel-contract--event
           (epi-test-run-gptel-contract (epi-test-tool-snapshot))
           'tool-proposed)))))
    (let ((epi-tool-argument-byte-limit (1- (string-bytes raw)))
          (real-copy (symbol-function 'epi--plain-string-copy))
          (real-inner (symbol-function 'gptel--json-read-string))
          (second-copies 0)
          (inner-calls 0))
      (cl-letf (((symbol-function 'epi--plain-string-copy)
                 (lambda (value)
                   (when (equal value second) (cl-incf second-copies))
                   (funcall real-copy value)))
                ((symbol-function 'gptel--json-read-string)
                 (lambda (&rest arguments)
                   (cl-incf inner-calls)
                   (apply real-inner arguments))))
        (epi-gptel-fixture-call-with-transport
         (list body)
         (lambda ()
           (should
            (equal '(request-failed)
                   (epi-test-gptel-event-kinds
                    (epi-test-run-gptel-contract
                     (epi-test-tool-snapshot))))))))
      (should (= 0 second-copies))
      (should (= 0 inner-calls)))))

(ert-deftest epi-gptel-contract-later-text-after-tool-fails ()
  (let ((body
         (epi-test-gptel-sse
          "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"mixed-later\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"README.md\\\"}\"}}]}}]}"
          "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"not allowed\"}}]}"
          "[DONE]")))
    (epi-gptel-fixture-call-with-transport
     (list body)
     (lambda ()
       (should (equal '(request-failed)
                      (epi-test-gptel-event-kinds
                       (epi-test-run-gptel-contract
                        (epi-test-tool-snapshot)))))))))

(ert-deftest epi-gptel-contract-mixed-declared-and-undeclared-vector-fails ()
  (let ((body
         (epi-test-gptel-sse
          "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"declared\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"README.md\\\"}\"}},{\"index\":1,\"id\":\"unknown\",\"function\":{\"name\":\"not_declared\",\"arguments\":\"{}\"}}]}}]}"
          "[DONE]")))
    (epi-gptel-fixture-call-with-transport
     (list body)
     (lambda ()
       (let ((events (epi-test-run-gptel-contract
                      (epi-test-tool-snapshot))))
         (should (equal '(request-failed)
                        (epi-test-gptel-event-kinds events)))
         (should-not (epi-gptel-contract--event events 'tool-proposed)))))))

(ert-deftest epi-gptel-contract-unknown-envelope-keys-never-intern ()
  (let ((counter 0))
    (dolist
        (template
         '("{\"choices\":[],\"%s\":1}"
           "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\",\"%s\":1}}]}"
           "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"unknown-key\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{}\"},\"%s\":1}]}}]}"
           "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"unknown-key\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{}\",\"%s\":1}}]}}]}"))
      (let* ((key (format "epi_unknown_%d_%s"
                          (cl-incf counter) (secure-hash 'sha256 template)))
             (body (epi-test-gptel-sse (format template key) "[DONE]")))
        (should-not (intern-soft key))
        (unwind-protect
            (epi-gptel-fixture-call-with-transport
             (list body)
             (lambda ()
               (should
                (equal '(request-failed)
                       (epi-test-gptel-event-kinds
                        (epi-test-run-gptel-contract
                         (epi-test-tool-snapshot)))))))
            (should-not (intern-soft key))
          (when (intern-soft key) (unintern key)))
        (should-not (intern-soft key))))))

(ert-deftest epi-gptel-contract-unsupported-argument-shapes-fail ()
  (dolist (raw '("{\"path\":{\"nested\":true}}"
                 "{\"path\":[\"README.md\"]}"
                 "{\"path\":null}"
                 "{\"path\":\"README.md\"} trailing"
                 "{\"unknown\":\"README.md\"}"
                 "{}"
                 "{\"path\":42}"))
    (epi-gptel-fixture-call-with-transport
     (list (epi-gptel-contract--tool-body
            "bad-arguments" "read_file" raw 0))
     (lambda ()
       (let ((events (epi-test-run-gptel-contract
                      (epi-test-tool-snapshot))))
         (should (equal '(request-failed)
                        (epi-test-gptel-event-kinds events))))))))

(ert-deftest epi-gptel-contract-flat-primitives-round-trip ()
  (let* ((schema
          '(("type" . "object")
            ("properties" .
             (("label" . (("type" . "string")))
              ("count" . (("type" . "integer")))
              ("ratio" . (("type" . "number")))
              ("enabled" . (("type" . "boolean")))))
            ("required" . ["label" "count" "ratio" "enabled"])
            ("additionalProperties" . epi-json-false)))
         (snapshot
          (epi-test-text-snapshot
           nil (list (epi-test-gptel-tool "primitive_tool" schema))))
         (raw
          "{\"label\":\" exact \",\"count\":42,\"ratio\":1.5,\"enabled\":false}")
         (body
          (epi-gptel-contract--tool-body
           "primitive-id" "primitive_tool" raw 0)))
    (epi-gptel-fixture-call-with-transport
     (list body)
     (lambda ()
       (let* ((state (epi-test-open-gptel-request snapshot))
              (proposal
               (epi-gptel-contract--event
                (epi-test-gptel-events state) 'tool-proposed)))
         (should
          (equal '(("label" . " exact ") ("count" . 42)
                   ("ratio" . 1.5) ("enabled" . epi-json-false))
                 (epi-gptel-event-arguments proposal))))))))

(ert-deftest epi-gptel-contract-name-and-raw-argument-limits-are-inclusive ()
  (let* ((raw "{\"path\":\"README.md\"}")
         (raw-bytes (string-bytes raw))
         (name "read_file")
         (name-bytes (string-bytes name))
         (snapshot
          (epi-test-text-snapshot
           nil (list (epi-test-gptel-tool
                      "read_file" (epi-test-gptel-string-schema)))))
         (body (epi-gptel-contract--tool-body "bounded" name raw 0)))
    (let ((epi-provider-tool-name-byte-limit name-bytes)
          (epi-tool-argument-byte-limit raw-bytes))
      (epi-gptel-fixture-call-with-transport
       (list body)
       (lambda ()
         (should (memq 'tool-proposed
                       (epi-test-gptel-event-kinds
                        (epi-test-run-gptel-contract snapshot)))))))
    (let ((epi-provider-tool-name-byte-limit name-bytes))
      (epi-gptel-fixture-call-with-transport
       (list (epi-gptel-contract--tool-body
              "too-long-name" (concat name "x") raw 0))
       (lambda ()
         (should (epi-gptel-contract--request-failed-p
                  (epi-test-run-gptel-contract snapshot))))))
    (let ((epi-tool-argument-byte-limit (1- raw-bytes)))
      (epi-gptel-fixture-call-with-transport
       (list body)
       (lambda ()
         (should (epi-gptel-contract--request-failed-p
                  (epi-test-run-gptel-contract snapshot))))))))

(ert-deftest epi-gptel-contract-multileg-turn-raw-limit-is-inclusive ()
  (let* ((first (epi-test-gptel-fixture "read-tool.sse"))
         (second (epi-test-gptel-fixture "final.sse"))
         (first-wire (epi-test-gptel-fixture-wire-byte-count first))
         (second-wire (epi-test-gptel-fixture-wire-byte-count second))
         (total (+ first-wire second-wire)))
    (let ((epi-provider-leg-raw-byte-limit (max first-wire second-wire))
          (epi-provider-turn-raw-byte-limit total))
      (epi-gptel-fixture-call-with-transport
       (list first second)
       (lambda ()
         (should (eq 'request-finished
                     (epi-gptel-event-kind
                      (car (last
                            (epi-test-run-gptel-contract
                             (epi-test-tool-snapshot) '("contents"))))))))))
    (let ((epi-provider-leg-raw-byte-limit (max first-wire second-wire))
          (epi-provider-turn-raw-byte-limit (1- total)))
      (epi-gptel-fixture-call-with-transport
       (list first second)
       (lambda ()
         (let ((events
                (epi-test-run-gptel-contract
                 (epi-test-tool-snapshot) '("contents"))))
           (should (epi-gptel-contract--request-failed-p events))
           (should-not (epi-gptel-contract--event
                        events 'request-finished))))))))

(ert-deftest epi-gptel-contract-malformed-provider-scalars-fail-pre-parse ()
  (dolist
      (payload
       '("{\"choices\":[{\"index\":0,\"delta\":{\"content\":7}}]}"
         "{\"choices\":[{\"index\":0,\"delta\":{\"reasoning\":7}}]}"
         "{\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":7}}]}"
         "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":7}}]}"))
    (epi-gptel-fixture-call-with-transport
     (list (epi-test-gptel-sse payload "[DONE]"))
     (lambda ()
       (let ((events
              (epi-test-run-gptel-contract (epi-test-text-snapshot))))
         (should (equal '(request-failed)
                        (epi-test-gptel-event-kinds events))))))))

(ert-deftest epi-gptel-contract-disabled-input-surfaces-fail-closed ()
  (dolist (feature '(:media :replayed-reasoning :steering
                     :configuration-refresh))
    (should-error
     (apply #'epi-gptel-snapshot-create
            (append
             '(:backend "epi-fixture" :model epi-fixture-model
               :prompt "Hello" :transport curl)
             (list feature t)))))
  (epi-test-with-gptel-fixtures nil
    (should-error
     (epi-test-gptel-dry-run-data
      (epi-test-text-snapshot
       '((("role" . "reasoning") ("text" . "do not replay")))))
     :type 'epi-gptel-incompatible))
  (let ((gptel-track-media t)
        (gptel-context '((:media "/secret/image.png")))
        (gptel-use-context t))
    (epi-test-with-gptel-fixtures nil
      (let ((messages
             (plist-get
              (epi-test-gptel-dry-run-data (epi-test-text-snapshot))
              :messages)))
        (should (= 2 (length messages)))
        (should (equal "Hello" (plist-get (aref messages 1) :content)))))))

(ert-deftest epi-gptel-contract-replay-rejects-undeclared-or-nested-arguments ()
  (dolist
      (history
       '(((("role" . "tool") ("call_id" . "nested")
           ("name" . "read_file")
           ("arguments" . (("path" . (("nested" . "bad")))))
           ("result" . "no")))
         ((("role" . "tool") ("call_id" . "unknown")
           ("name" . "not_declared") ("arguments" . nil)
           ("result" . "no")))))
    (epi-test-with-gptel-fixtures nil
      (should-error
       (epi-test-gptel-dry-run-data (epi-test-tool-snapshot history))
       :type 'epi-gptel-incompatible))))

(ert-deftest epi-gptel-contract-rejected-envelope-stops-before-gptel-semantics ()
  (let* ((body
          (epi-test-gptel-sse
           "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"dup-stop\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"one\\\",\\\"path\\\":\\\"two\\\"}\"}}]}}]}"
           "[DONE]"))
         (second (epi-test-gptel-fixture "final.sse"))
         (real-json-parse-string (symbol-function 'json-parse-string))
         (real-stock epi-gptel--stock-handle-tool-use)
         (real-stub (symbol-function 'epi-gptel--tool-stub))
         (inner-calls 0)
         (tool-handler-calls 0)
         (tool-function-calls 0))
    (cl-letf (((symbol-function 'json-parse-string)
               (lambda (string &rest arguments)
                 (when (eq (plist-get arguments :object-type) 'plist)
                   (cl-incf inner-calls))
                 (apply real-json-parse-string string arguments)))
              ((symbol-function 'epi-gptel--tool-stub)
               (lambda (&rest arguments)
                 (cl-incf tool-function-calls)
                 (apply real-stub arguments))))
      (let ((epi-gptel--stock-handle-tool-use
             (lambda (fsm)
               (cl-incf tool-handler-calls)
               (funcall real-stock fsm))))
        (epi-gptel-fixture-call-with-transport
         (list body second)
         (lambda ()
           (let* ((state
                   (epi-test-open-gptel-request (epi-test-tool-snapshot)))
                  (request (epi-test-gptel-request state)))
             (should (equal '(request-failed)
                            (epi-test-gptel-event-kinds
                             (epi-test-gptel-events state))))
             (should (= 1 (length epi-gptel--fixture-legs)))
             (should (= 0 (hash-table-count
                           (epi-gptel-request-continuations request)))))))))
    (should (= 0 inner-calls))
    (should (= 0 tool-handler-calls))
    (should (= 0 tool-function-calls))))

(ert-deftest epi-gptel-contract-outer-json-requires-exact-end-of-input ()
  (dolist
      (suffix
       '(" trailing-token"
         " {\"choices\":[]}"))
    (let* ((payload
            (concat
             "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":["
             "{\"index\":0,\"id\":\"trailing\",\"type\":\"function\","
             "\"function\":{\"name\":\"read_file\","
             "\"arguments\":\"{\\\"path\\\":\\\"README.md\\\"}\"}}]}}]}"
             suffix))
           (body (epi-test-gptel-sse payload "[DONE]"))
           (second (epi-test-gptel-fixture "final.sse"))
           (real-parser epi-gptel--stock-openai-stream-parser)
           (real-tool epi-gptel--stock-handle-tool-use)
           (parser-calls 0)
           (tool-calls 0))
      (epi-gptel-fixture-call-with-transport
       (list body second)
       (lambda ()
         (let* ((state (vector nil nil))
                (request
                 (epi-gptel-start
                  (epi-test-tool-snapshot)
                  (lambda (event)
                    (aset state 1 (append (aref state 1) (list event)))))))
           (aset state 0 request)
           (let ((epi-gptel--stock-openai-stream-parser
                  (lambda (&rest arguments)
                    (cl-incf parser-calls)
                    (apply real-parser arguments)))
                 (epi-gptel--stock-handle-tool-use
                  (lambda (fsm)
                    (cl-incf tool-calls)
                    (funcall real-tool fsm))))
             (epi-gptel-fixture-pump))
             (should (equal '(request-failed)
                            (epi-test-gptel-event-kinds
                             (epi-test-gptel-events state))))
             (should (= 1 (length epi-gptel--fixture-legs)))
             (should (= 0 (hash-table-count
                           (epi-gptel-request-continuations request))))
             (should-not (epi-gptel-request-next-leg-p request)))))
      (should (= 0 parser-calls))
      (should (= 0 tool-calls)))))

(ert-deftest epi-gptel-contract-every-nonempty-choice-has-index-zero ()
  (dolist
      (body
       (list
        (epi-test-gptel-sse
         "{\"choices\":[{\"delta\":{\"content\":\"missing\"}}]}"
         "[DONE]")
        (epi-test-gptel-sse
         "{\"choices\":[{\"index\":1,\"delta\":{\"content\":\"one\"}}]}"
         "[DONE]")
        (epi-test-gptel-sse
         "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"zero\"}}]}"
         "{\"choices\":[{\"index\":1,\"delta\":{\"content\":\"one\"}}]}"
         "[DONE]")))
    (let ((real-parser epi-gptel--stock-openai-stream-parser)
          (parser-calls 0))
      (epi-gptel-fixture-call-with-transport
       (list body)
       (lambda ()
         (let* ((state (vector nil nil))
                (request
                 (epi-gptel-start
                  (epi-test-text-snapshot)
                  (lambda (event)
                    (aset state 1 (append (aref state 1) (list event)))))))
           (aset state 0 request)
           (let ((epi-gptel--stock-openai-stream-parser
                  (lambda (&rest arguments)
                    (cl-incf parser-calls)
                    (apply real-parser arguments))))
             (epi-gptel-fixture-pump))
           (should (equal '(request-failed)
                          (epi-test-gptel-event-kinds
                           (epi-test-gptel-events state)))))))
      (should (= 0 parser-calls)))))

(ert-deftest epi-gptel-contract-callback-correlates-gptel-retained-raw-bytes ()
  (let ((real-stock epi-gptel--stock-handle-tool-use))
    (let ((epi-gptel--stock-handle-tool-use
           (lambda (fsm)
             (let* ((info (gptel-fsm-info fsm))
                    (messages (plist-get (plist-get info :data) :messages))
                    (assistant (aref messages (1- (length messages))))
                    (call (aref (plist-get assistant :tool_calls) 0))
                    (function (plist-get call :function)))
               (plist-put function :arguments
                          "{ \"path\" : \"README.md\" }")
               (funcall real-stock fsm)))))
      (epi-test-with-gptel-fixtures '("read-tool.sse")
        (let ((events
               (epi-test-run-gptel-contract
                (epi-test-tool-snapshot))))
          (should (equal '(leg-finished request-failed)
                         (epi-test-gptel-event-kinds events)))
          (should-not (epi-gptel-contract--event events 'tool-proposed)))))))

(ert-deftest epi-gptel-contract-raw-audit-state-is-erased-before-enqueue ()
  (epi-test-with-gptel-fixtures '("read-tool.sse")
    (let* ((state (epi-test-open-gptel-request (epi-test-tool-snapshot)))
           (request (epi-test-gptel-request state)))
      (should (epi-gptel-contract--event
               (epi-test-gptel-events state) 'tool-proposed))
      (should-not (epi-gptel-request-audit-fragments request))
      (should-not (epi-gptel-request-audit-call-id request))
      (should-not (epi-gptel-request-audit-name request))
      (should (= 0 (hash-table-count
                    (epi-gptel-request-attestations request))))))
  (let ((body
         (epi-test-gptel-sse
          "{\"choices\":[],\"choices\":[{\"index\":0,\"delta\":{\"content\":\"bad\"}}]}"
          "[DONE]")))
    (epi-gptel-fixture-call-with-transport
     (list body)
     (lambda ()
       (let* ((state (epi-test-open-gptel-request (epi-test-text-snapshot)))
              (request (epi-test-gptel-request state)))
         (should (epi-gptel-request-terminal-p request))
         (should-not (epi-gptel-request-audit-fragments request))
         (should (= 0 (hash-table-count
                       (epi-gptel-request-attestations request)))))))))

(ert-deftest epi-gptel-contract-every-copied-argument-fragment-is-scrubbed ()
  (let ((first "{\"path\":")
        (second "\"README.md\"}"))
    (dolist
        (body
         (list
          (epi-test-gptel-sse
           "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"scrub-ok\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\"}}]}}]}"
           "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"type\":\"function\",\"function\":{\"arguments\":\"\\\"README.md\\\"}\"}}]}}]}"
           "[DONE]")
          (epi-test-gptel-sse
           "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"scrub-bad\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\"}}]}}]}"
           "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"type\":\"function\",\"function\":{\"arguments\":\"\\\"README.md\\\"}\"}}]}}]}"
           "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"late\",\"type\":\"function\",\"function\":{\"arguments\":\"\"}}]}}]}"
           "[DONE]")))
      (let ((real-copy (symbol-function 'epi--plain-string-copy))
            captured)
        (cl-letf (((symbol-function 'epi--plain-string-copy)
                   (lambda (value)
                     (let ((copy (funcall real-copy value)))
                       (when (member value (list first second))
                         (push copy captured))
                       copy))))
          (epi-gptel-fixture-call-with-transport
           (list body)
           (lambda ()
             (epi-test-run-gptel-contract (epi-test-tool-snapshot)))))
        (should (= 2 (length captured)))
        (should
         (cl-every
          (lambda (string)
            (cl-every #'zerop (append string nil)))
          captured))))))

(ert-deftest epi-gptel-contract-fail-stop-aborts-and-unregisters-transport ()
  (let* ((body
          (epi-test-gptel-sse
           "{\"choices\":[],\"choices\":[{\"index\":0,\"delta\":{\"content\":\"bad\"}}]}"
           "[DONE]"))
         (real-abort (symbol-function 'gptel-abort))
         (real-guard (symbol-function 'epi-gptel--guarded-stream-filter))
         process process-buffer
         (abort-calls 0)
         in-filter abort-during-filter)
    (cl-letf (((symbol-function 'epi-gptel--guarded-stream-filter)
               (lambda (&rest arguments)
                 (setq in-filter t)
                 (unwind-protect
                     (apply real-guard arguments)
                   (setq in-filter nil))))
              ((symbol-function 'gptel-abort)
               (lambda (&rest arguments)
                 (cl-incf abort-calls)
                 (when in-filter (setq abort-during-filter t))
                 (apply real-abort arguments))))
      (epi-gptel-fixture-call-with-transport
       (list body)
       (lambda ()
         (unwind-protect
             (let ((state
                    (epi-test-open-gptel-request
                     (epi-test-tool-snapshot))))
               (should (equal '(request-failed)
                              (epi-test-gptel-event-kinds
                               (epi-test-gptel-events state))))
               (should (= 1 abort-calls))
               (should-not abort-during-filter)
               (should-not (process-live-p process))
               (should-not (assq process gptel--request-alist))
               (should-not (buffer-live-p process-buffer)))
           (setf (alist-get process gptel--request-alist nil 'remove) nil)
           (when (process-live-p process) (delete-process process))
           (when (buffer-live-p process-buffer)
             (kill-buffer process-buffer))))
       (list :retain-transport t
             :process-hook
             (lambda (fixture-process)
               (setq process fixture-process
                     process-buffer (process-buffer fixture-process))))))))

(ert-deftest epi-gptel-contract-stock-wait-clears-each-leg-and-runs-hook-once ()
  (let ((keys '(:tool-result :tool-use :error :http-status :reasoning :tokens))
        (transport-snapshots nil)
        (wait-hook-calls 0)
        (before-next-calls 0)
        (real-run-hooks (symbol-function 'run-hooks)))
    (cl-letf (((symbol-function 'run-hooks)
               (lambda (&rest hooks)
                 (when (memq 'gptel-post-request-hook hooks)
                   (cl-incf wait-hook-calls))
                 (apply real-run-hooks hooks))))
      (epi-test-with-gptel-fixtures/options
          '("read-tool.sse" "final.sse")
          (list
           :transport-hook
           (lambda (info)
             (push (mapcar (lambda (key) (plist-get info key)) keys)
                   transport-snapshots))
           :before-next-leg-hook
           (lambda (info)
             (cl-incf before-next-calls)
             (cl-loop for key in keys
                      for value in '(one two three four five six)
                      do (plist-put info key value))))
        (let ((events
               (epi-test-run-gptel-contract
                (epi-test-tool-snapshot) '("contents"))))
          (should (epi-gptel-contract--event events 'request-finished)))))
    (should (= 1 before-next-calls))
    (should (= 2 wait-hook-calls))
    (should (equal '((nil nil nil nil nil nil)
                     (nil nil nil nil nil nil))
                   (nreverse transport-snapshots)))))

(ert-deftest epi-gptel-contract-filter-faults-restore-and-clean-up ()
  (dolist (mode '(none twice unexpected))
    (let ((original (symbol-function 'set-process-filter))
          (unexpected-calls 0)
          state)
      (epi-test-with-gptel-fixtures/options
          '("text.sse")
          (list :filter-mode mode
                :unexpected-filter
                (lambda (&rest _ignored) (cl-incf unexpected-calls)))
        (setq state (epi-test-open-gptel-request (epi-test-text-snapshot)))
        (let ((request (epi-test-gptel-request state)))
          (should (equal '(request-failed)
                         (epi-test-gptel-event-kinds
                          (epi-test-gptel-events state))))
          (should (= 0 (hash-table-count
                        (epi-gptel-request-continuations request))))
          (should-not (epi-gptel-contract--active-process-for-request-p
                       request))))
      (should (eq original (symbol-function 'set-process-filter)))
      (should (= 0 unexpected-calls)))))

(ert-deftest epi-gptel-contract-one-filter-install-delegates-stock-once ()
  (let ((real-guard (symbol-function 'epi-gptel--guarded-stream-filter))
        (guard-calls 0))
    (cl-letf (((symbol-function 'epi-gptel--guarded-stream-filter)
               (lambda (&rest arguments)
                 (cl-incf guard-calls)
                 (apply real-guard arguments))))
      (epi-test-with-gptel-fixtures '("text.sse")
        (should (epi-gptel-contract--event
                 (epi-test-run-gptel-contract (epi-test-text-snapshot))
                 'request-finished))))
    (should (= 1 guard-calls))))

(ert-deftest epi-gptel-contract-fixture-delivers-after-wait-interception ()
  (let* ((original (symbol-function 'set-process-filter))
         (payload
          "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"héllo\"}}]}")
         (body (epi-test-gptel-sse payload "[DONE]"))
         (wire (concat epi-gptel--fixture-header-ok body))
         (header-end (length epi-gptel--fixture-header-ok))
         (json-start (string-match "{" wire header-end))
         (record-end (string-match "\n\n" wire json-start))
         (done-start (string-match "\[DONE\]" wire record-end))
         (boundaries
          (list 1 (1- header-end) (+ header-end 2)
                (1+ json-start) (1+ record-end) (1+ done-start)
                (1- (length wire))))
         (delivery-calls 0)
         start-returned state)
    (epi-gptel-fixture-call-with-transport
     (list body)
     (lambda ()
       (setq state (vector nil nil))
       (aset state 0
             (epi-gptel-start
              (epi-test-text-snapshot)
              (lambda (event)
                (aset state 1 (append (aref state 1) (list event))))))
       (setq start-returned t)
       (should-not (epi-test-gptel-events state))
       (epi-gptel-fixture-pump)
       (let ((events (epi-test-gptel-events state)))
         (should (equal "héllo"
                        (epi-gptel-event-text
                         (epi-gptel-contract--event events 'text-delta))))
         (should (epi-gptel-contract--event events 'request-finished))))
     (list :chunk-boundaries boundaries
           :delivery-hook
           (lambda ()
             (should start-returned)
             (should (eq original (symbol-function 'set-process-filter)))
             (cl-incf delivery-calls))))
    (should (= 1 delivery-calls))))

(ert-deftest epi-gptel-contract-stuck-tool-without-proposal-times-out ()
  (let ((real-callback (symbol-function 'epi-gptel--callback))
        (real-abort (symbol-function 'gptel-abort))
        (abort-calls 0)
        (epi-gptel-no-progress-timeout 0.001))
    (cl-letf (((symbol-function 'epi-gptel--callback)
               (lambda (request response info)
                 (unless (and (consp response) (eq (car response) 'tool-call))
                   (funcall real-callback request response info))))
              ((symbol-function 'gptel-abort)
               (lambda (buffer)
                 (cl-incf abort-calls)
                 (funcall real-abort buffer))))
      (epi-test-with-gptel-fixtures '("read-tool.sse")
        (let* ((state (epi-test-open-gptel-request
                       (epi-test-tool-snapshot)))
               (request (epi-test-gptel-request state)))
          (sleep-for 0.01)
          (sleep-for 0.001)
          (should (epi-gptel-request-terminal-p request))
          (should (eq 'provider-no-progress
                      (epi-gptel-request-terminal-code request)))
          (should-not (epi-gptel-contract--event
                       (epi-test-gptel-events state) 'tool-proposed)))))
    (should (= 1 abort-calls))))

(ert-deftest epi-gptel-contract-concurrent-requests-keep-continuations-separate ()
  (epi-test-with-gptel-fixtures
      '("read-tool.sse" "text.sse" "final.sse")
    (let* ((first (epi-test-open-gptel-request (epi-test-tool-snapshot)))
           (second (epi-test-open-gptel-request (epi-test-text-snapshot)))
           (first-request (epi-test-gptel-request first))
           (second-request (epi-test-gptel-request second))
           (proposal
            (epi-gptel-contract--event
             (epi-test-gptel-events first) 'tool-proposed)))
      (should proposal)
      (should (epi-gptel-contract--event
               (epi-test-gptel-events second) 'request-finished))
      (should-not (epi-gptel-request-terminal-p first-request))
      (epi-gptel-submit-tool-result
       first-request (epi-gptel-event-call-id proposal) "contents")
      (epi-gptel-fixture-pump)
      (should (eq 'request-finished
                  (epi-gptel-request-terminal-kind first-request)))
      (should (eq 'request-finished
                  (epi-gptel-request-terminal-kind second-request)))
      (epi-gptel-close first-request)
      (epi-gptel-close second-request))))

(ert-deftest epi-gptel-contract-unrelated-gptel-request-remains-stock ()
  (epi-test-with-gptel-fixtures '("text.sse")
    (let (responses)
      (with-temp-buffer
        (setq-local gptel-backend
                    (alist-get "epi-fixture" gptel--known-backends
                               nil nil #'equal))
        (setq-local gptel-model 'epi-fixture-model)
        (setq-local gptel-system-prompt nil)
        (setq-local gptel-use-curl t)
        (setq-local gptel-stream t)
        (setq-local gptel-use-context nil)
        (setq-local gptel-use-tools nil)
        (setq-local gptel-post-request-hook nil)
        (gptel-request
            "Hello"
          :stream t
          :callback (lambda (response _info) (push response responses)))
        (epi-gptel-fixture-pump))
      (should (equal '("Hello from GPTel." t) (nreverse responses))))))

(ert-deftest epi-gptel-contract-inplace-prompt-mutation-cannot-reach-leg-two ()
  (let (transport-prompts)
    (epi-test-with-gptel-fixtures/options
        '("read-tool.sse" "final.sse")
        (list
         :transport-hook
         (lambda (info)
           (let* ((messages (plist-get (plist-get info :data) :messages))
                  (content (plist-get (aref messages 1) :content)))
             (push (epi--plain-string-copy content) transport-prompts))))
      (let* ((snapshot (epi-test-tool-snapshot))
             (state (epi-test-open-gptel-request snapshot))
             (request (epi-test-gptel-request state))
             (proposal
              (epi-gptel-contract--event
               (epi-test-gptel-events state) 'tool-proposed)))
        (should-not (eq snapshot (epi-gptel-request-snapshot request)))
        (aset (epi-gptel-snapshot-prompt snapshot) 0 ?X)
        (epi-gptel-submit-tool-result
         request (epi-gptel-event-call-id proposal) "contents")
        (epi-gptel-fixture-pump)
        (should (eq 'request-finished
                    (epi-gptel-request-terminal-kind request)))))
    (should (equal '("Hello" "Hello") (nreverse transport-prompts)))))

(ert-deftest epi-gptel-contract-inflight-snapshot-mutation-cannot-refresh ()
  (epi-test-with-gptel-fixtures '("read-tool.sse" "final.sse")
    (let* ((snapshot (epi-test-tool-snapshot))
           (state (epi-test-open-gptel-request snapshot))
           (request (epi-test-gptel-request state))
           (proposal
            (epi-gptel-contract--event
             (epi-test-gptel-events state) 'tool-proposed)))
      (setf (epi-gptel-snapshot-backend snapshot) "changed"
            (epi-gptel-snapshot-model snapshot) 'changed
            (epi-gptel-snapshot-system snapshot) "changed"
            (epi-gptel-snapshot-tools snapshot) nil
            (epi-gptel-snapshot-request-params snapshot) '(:stream :json-false))
      (epi-gptel-submit-tool-result
       request (epi-gptel-event-call-id proposal) "contents")
      (epi-gptel-fixture-pump)
      (should (eq 'request-finished
                  (epi-gptel-request-terminal-kind request))))))

(provide 'epi-gptel-contract-test)

;;; epi-gptel-contract-test.el ends here
