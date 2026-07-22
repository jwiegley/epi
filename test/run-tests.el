;;; run-tests.el --- Stable Epi ERT batch runner -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley
;; Keywords: tools

;;; Commentary:

;; Load the exact test files named by TESTS, select tests with the raw regular
;; expression in SELECTOR, and run the selected ERT tests in batch mode.  TESTS
;; is an ASCII-whitespace-separated list.  An absent or empty SELECTOR selects
;; every loaded test; any other value, including whitespace, is a regexp.

;;; Code:

(require 'ert)

(defconst epi-test-runner--ascii-whitespace-regexp
  "[ \t\n\v\f\r]+"
  "Regular expression matching one or more ASCII whitespace characters.")

(defconst epi-test-runner--repository-root
  (file-name-directory
   (directory-file-name
    (file-name-directory (file-truename (or load-file-name buffer-file-name)))))
  "Absolute root of the Epi repository containing this runner.")

(defun epi-test-runner--test-files ()
  "Return the exact test files declared by the TESTS environment variable."
  (split-string (or (getenv "TESTS") "")
                epi-test-runner--ascii-whitespace-regexp t))

(defun epi-test-runner--load-test-files ()
  "Load every TESTS file exactly, in its declared order."
  (dolist (file (epi-test-runner--test-files))
    (load (expand-file-name file epi-test-runner--repository-root) nil t t)))

(defun epi-test-runner--fail (diagnostic)
  "Print DIAGNOSTIC as a standalone line and exit unsuccessfully."
  (princ (concat diagnostic "\n"))
  (kill-emacs 1))

(defun epi-test-runner-main ()
  "Load, preselect, count, and run the ERT tests requested by the environment."
  (epi-test-runner--load-test-files)
  (let* ((raw-selector (getenv "SELECTOR"))
         (explicit-selector-p
          (and raw-selector (> (length raw-selector) 0)))
         (selector (if explicit-selector-p raw-selector t))
         ;; Select before running anything so an empty selection cannot turn a
         ;; red or green gate into a successful no-op.
         (selected-tests (ert-select-tests selector t)))
    (cond
     ((and explicit-selector-p (null selected-tests))
      (epi-test-runner--fail "SELECTOR matched zero loaded ERT tests"))
     ((null selected-tests)
      (epi-test-runner--fail "No loaded ERT tests")))
    (princ (format "%d loaded ERT tests\n" (length selected-tests)))
    (ert-run-tests-batch-and-exit selector)))

(provide 'run-tests)

(epi-test-runner-main)

;;; run-tests.el ends here
