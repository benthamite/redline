;;; redline-test-helpers.el --- Helpers for redline tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Buffers set up for redline, with fixed timestamps and scripted input.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'redline)
(require 'redline-markdown)
(require 'redline-org)
(require 'markdown-mode)
(require 'org)

(defconst redline-test-now "2026-01-01T00:00:00.000Z"
  "Timestamp written by commands under test.")

(defmacro redline-test-with-buffer (mode text &rest body)
  "Run BODY in a buffer in major MODE holding TEXT with `redline-mode' on.
Point starts at the beginning, undo is enabled and time is fixed."
  (declare (indent 2) (debug t))
  `(with-temp-buffer
     (insert ,text)
     (funcall ,mode)
     (buffer-enable-undo)
     (setq-local transient-mark-mode t)
     (redline-mode 1)
     (goto-char (point-min))
     (cl-letf (((symbol-function 'redline--now) (lambda () redline-test-now)))
       ,@body)))

(defmacro redline-test-with-input (inputs &rest body)
  "Run BODY answering text prompts with INPUTS in turn and confirming."
  (declare (indent 1) (debug t))
  `(let ((answers ,inputs))
     (cl-letf (((symbol-function 'redline--read)
                (lambda (&rest _) (or (pop answers) (error "No scripted input"))))
               ((symbol-function 'completing-read)
                (lambda (&rest _) (or (pop answers) (error "No scripted input"))))
               ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
       ,@body)))

(defun redline-test-select (text)
  "Select the first occurrence of TEXT in the buffer."
  (goto-char (point-min))
  (search-forward text)
  (set-mark (match-beginning 0))
  (activate-mark))

(defun redline-test-goto (text)
  "Move point to the start of the first occurrence of TEXT."
  (goto-char (point-min))
  (search-forward text)
  (goto-char (match-beginning 0)))

(defun redline-test-parse (text &optional adapter)
  "Parse TEXT with ADAPTER, the Markdown adapter by default."
  (with-temp-buffer
    (insert text)
    (redline-parse (or adapter redline-markdown-adapter))))

(defun redline-test-items (text &optional adapter)
  "Return the items of TEXT parsed with ADAPTER as (KIND ID BODY PARENT)."
  (with-temp-buffer
    (insert text)
    (let ((doc (redline-parse (or adapter redline-markdown-adapter))))
      (mapcar (lambda (item)
                (list (redline-item-kind item) (redline-item-id item)
                      (redline-item-body item)
                      (redline-item-parent-id doc item)))
              (redline-doc-items doc)))))

(provide 'redline-test-helpers)
;;; redline-test-helpers.el ends here
