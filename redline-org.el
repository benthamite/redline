;;; redline-org.el --- Org adapter for redline -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Pablo Stafforini

;; Author: Pablo Stafforini <pablo@stafforini.com>
;; URL: https://github.com/benthamite/redline

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; In Org, review markers are literal inside source, example, export
;; and comment blocks, fixed-width lines, keyword and comment lines,
;; drawers, inline source and Babel calls, and verbatim and code
;; objects.  A review opener outside those contexts wins over the Org
;; emphasis it resembles.  The endmatter is the same YAML inside a final
;; `#+begin_comment redline' block, comma-escaped as Org escapes code.
;; On export the markup is rewritten according to
;; `redline-org-export-style' before Org expands macros and includes.

;;; Code:

(require 'redline-parse)
(require 'org-src)

(defgroup redline-org nil
  "Org support for redline."
  :group 'redline)

(defcustom redline-org-export-style 'original
  "How CriticMarkup in Org buffers is exported.
`original' exports the text as it was before the suggestions: pending
insertions are dropped and deleted text is kept.  `accepted' exports
the text as if every suggestion were accepted.  Both drop comments and
highlight delimiters.  `markup' exports the CriticMarkup unchanged."
  :type '(choice (const :tag "Text before suggestions" original)
                 (const :tag "Text with suggestions accepted" accepted)
                 (const :tag "Raw CriticMarkup" markup))
  :group 'redline-org)

(defconst redline-org--block-regexp
  "^[ \t]*#\\+begin_\\(src\\|example\\|export\\|comment\\)\\b"
  "Regexp matching the start of a block whose contents are literal.")

(defconst redline-org--line-regexp
  "^[ \t]*\\(?:#\\+\\|#\\(?:[ \t]\\|$\\)\\|:\\(?:[ \t]\\|$\\)\\).*\n?"
  "Regexp matching a keyword, comment or fixed-width line.")

(defconst redline-org--drawer-regexp "^[ \t]*:[A-Za-z0-9_-]+:[ \t]*$"
  "Regexp matching a drawer opening line.")

(defun redline-org--code-regions ()
  "Return the literal regions of the current Org buffer."
  (redline-merge-regions
   (append (redline-org--blocks)
           (redline-org--lines)
           (redline-org--drawers))))

(defun redline-org--blocks ()
  "Return the regions of literal blocks in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search t) regions)
      (while (re-search-forward redline-org--block-regexp nil t)
        (let ((beg (line-beginning-position))
              (end-regexp (format "^[ \t]*#\\+end_%s[ \t]*$"
                                  (regexp-quote (match-string 1)))))
          (push (cons beg (if (re-search-forward end-regexp nil t)
                              (min (point-max) (1+ (point)))
                            (goto-char (point-max))))
                regions)))
      (nreverse regions))))

(defun redline-org--lines ()
  "Return the regions of keyword, comment and fixed-width lines."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search t) regions)
      (while (re-search-forward redline-org--line-regexp nil t)
        (push (cons (match-beginning 0) (match-end 0)) regions))
      (nreverse regions))))

(defun redline-org--drawers ()
  "Return the regions of drawers in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search t) regions)
      (while (re-search-forward redline-org--drawer-regexp nil t)
        (let ((beg (line-beginning-position)))
          (unless (string-match-p "\\`[ \t]*:end:" (match-string 0))
            (when (re-search-forward "^[ \t]*:end:[ \t]*$" nil t)
              (push (cons beg (min (point-max) (1+ (point)))) regions)))))
      (nreverse regions))))

(defconst redline-org--inline-regexp "[=~]\\|\\_<\\(?:src\\|call\\)_"
  "Regexp matching the start of an inline literal object.")

(defconst redline-org--src-regexp
  "src_[^ \t\n[{]+\\(?:\\[[^]\n]*\\]\\)?{"
  "Regexp matching the start of an inline source block.")

(defconst redline-org--call-regexp
  "call_[^ \t\n([]+\\(?:\\[[^]\n]*\\]\\)?([^)\n]*)\\(?:\\[[^]\n]*\\]\\)?"
  "Regexp matching an inline Babel call.")

(defun redline-org--inline-literal (limit)
  "Return the end of the inline literal object starting at point, or nil.
Do not look past LIMIT."
  (cond
   ((looking-at redline-org--src-regexp)
    (redline-org--balanced-brace (1- (match-end 0))))
   ((looking-at redline-org--call-regexp)
    (match-end 0))
   ((memq (char-after) '(?= ?~))
    (redline-org--emphasis-end limit))))

(defun redline-org--balanced-brace (open)
  "Return the position after the brace matching the one at OPEN, or nil.
Search only to the end of the line."
  (save-excursion
    (goto-char (1+ open))
    (let ((depth 1) (eol (line-end-position)))
      (while (and (> depth 0) (re-search-forward "[{}]" eol t))
        (setq depth (if (eq (char-before) ?{) (1+ depth) (1- depth))))
      (and (= depth 0) (point)))))

(defun redline-org--emphasis-end (limit)
  "Return the end of the verbatim or code object starting at point, or nil.
Follow Org's emphasis rules, searching up to the paragraph end or LIMIT."
  (let ((mark (char-after))
        (pre (char-before)))
    (when (and (or (null pre) (memq pre '(?\s ?\t ?\n ?- ?\( ?' ?\" ?{)))
               (not (memq (char-after (1+ (point))) '(nil ?\s ?\t ?\n))))
      (save-excursion
        (let ((bound (save-excursion
                       (if (re-search-forward redline--blank-line-regexp limit t)
                           (match-beginning 0)
                         limit))))
          (forward-char 1)
          (when (re-search-forward
                 (format "[^ \t\n]\\(%s\\)\\(?:[- \t\n.,;:!?'\")}\\[]\\|\\'\\)"
                         (regexp-quote (char-to-string mark)))
                 bound t)
            (match-end 1)))))))

(defconst redline-org--begin-regexp
  "^[ \t]*#\\+begin_comment[ \t]+redline[ \t]*$"
  "Regexp matching the start of the redline endmatter block.")

(defun redline-org--endmatter ()
  "Locate the final redline comment block of the current buffer."
  (save-excursion
    (let ((case-fold-search t))
      (goto-char (point-max))
      (skip-chars-backward " \t\n")
      (when (and (> (point) (point-min))
                 (progn (beginning-of-line)
                        (looking-at "[ \t]*#\\+end_comment[ \t]*$")))
        (let ((end-line (point)))
          (when (and (re-search-backward "^[ \t]*#\\+begin_comment\\b" nil t)
                     (looking-at redline-org--begin-regexp))
            (let ((beg (point)))
              (forward-line 1)
              (list :beg beg :end (point-max)
                    :yaml (org-unescape-code-in-string
                           (buffer-substring-no-properties (point) end-line))))))))))

(defun redline-org--wrap (yaml)
  "Return the redline comment block holding YAML."
  (concat "#+begin_comment redline\n" (org-escape-code-in-string yaml)
          "#+end_comment\n"))

(defvar redline-org-adapter
  (redline-adapter-create
   :name 'org
   :code-regions-function #'redline-org--code-regions
   :inline-literal-regexp redline-org--inline-regexp
   :inline-literal-function #'redline-org--inline-literal
   :boundary-regexp "\n\\*+[ \t]"
   :endmatter-locate-function #'redline-org--endmatter
   :endmatter-wrap-function #'redline-org--wrap)
  "The redline adapter for Org buffers.")

;;;; Export

;;;###autoload
(defun redline-org-export-rewrite (&optional _backend)
  "Rewrite CriticMarkup in the current export buffer.
Follow `redline-org-export-style'.  Literal contexts are left alone."
  (unless (eq redline-org-export-style 'markup)
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward redline--open-regexp nil t)
        (let ((doc (redline-parse redline-org-adapter)))
          (dolist (token (reverse (redline-doc-tokens doc)))
            (redline-org--rewrite-token token)))))))

(defun redline-org--rewrite-token (token)
  "Replace TOKEN with its exported text."
  (let ((text (redline-org--export-text token)))
    (goto-char (redline-token-beg token))
    (delete-region (redline-token-beg token) (redline-token-end token))
    (insert text)))

(defun redline-org--export-text (token)
  "Return the text TOKEN exports to under `redline-org-export-style'."
  (let ((accepted (eq redline-org-export-style 'accepted))
        (body (buffer-substring-no-properties (redline-token-body-beg token)
                                              (redline-token-body-end token))))
    (pcase (redline-token-kind token)
      ('comment "")
      ('highlight body)
      ('addition (if accepted body ""))
      ('deletion (if accepted "" body))
      ('substitution
       (if accepted
           (buffer-substring-no-properties (redline-token-new-beg token)
                                           (redline-token-new-end token))
         body)))))

;;;###autoload
(add-hook 'org-export-before-processing-functions #'redline-org-export-rewrite)
;;;###autoload
(add-hook 'org-export-before-parsing-functions #'redline-org-export-rewrite)

(provide 'redline-org)
;;; redline-org.el ends here
