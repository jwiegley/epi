;;; checkdoc.el --- Batch Checkdoc driver for Epi -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Wiegley

;; Author: John Wiegley
;; Keywords: tools

;;; Commentary:

;; Check each Epi production source in a temporary Emacs Lisp buffer.  The
;; Makefile loads Emacs's Checkdoc library before adding this directory to
;; `load-path', avoiding the shared `checkdoc.el' basename.

;;; Code:

(unless (featurep 'checkdoc)
  (error "Load Emacs's Checkdoc library before test/checkdoc.el"))

(require 'subr-x)

(defun epi-test-checkdoc--files ()
  "Return production files named by EPI_CHECKDOC_FILES."
  (let ((value (getenv "EPI_CHECKDOC_FILES")))
    (unless (and value (not (string-empty-p value)))
      (error "EPI_CHECKDOC_FILES is required"))
    (split-string value "[[:space:]]+" t)))

(defun epi-test-checkdoc--file (file)
  "Run `checkdoc-current-buffer' against production FILE."
  (let ((expanded (expand-file-name file)))
    (unless (file-regular-p expanded)
      (error "Checkdoc input is not a regular file: %s" file))
    (let ((absolute (file-truename expanded)))
      (condition-case condition
          (with-temp-buffer
            (insert-file-contents absolute)
            (setq buffer-file-name absolute
                  default-directory (file-name-directory absolute))
            (emacs-lisp-mode)
            (let ((diagnostics nil)
                  (original-create-error checkdoc-create-error-function)
                  (checkdoc-autofix-flag 'never)
                  (checkdoc-bouncy-flag nil)
                  (checkdoc-spellcheck-documentation-flag nil))
              (let ((checkdoc-create-error-function
                     (lambda (text start end &optional unfixable)
                       (push text diagnostics)
                       (funcall original-create-error
                                text start end unfixable))))
                (checkdoc-current-buffer t))
              (when diagnostics
                (error "%s" (mapconcat #'identity
                                        (nreverse diagnostics) "; ")))))
        (error
         (error "Checkdoc failed for %s: %s"
                file (error-message-string condition)))))))

(let ((files (epi-test-checkdoc--files)))
  (dolist (file files)
    (epi-test-checkdoc--file file))
  (princ (format "Checkdoc passed for %d production file%s\n"
                 (length files)
                 (if (= 1 (length files)) "" "s"))))

;;; checkdoc.el ends here
