;;; redline-markdown.el --- Markdown adapter for redline -*- lexical-binding: t; -*-

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

;; Markdown follows Roughdraft Flavored Markdown: review markers are
;; literal inside fenced code blocks, code spans, YAML frontmatter and
;; HTML comments, and the endmatter is the final `---' YAML block.  The
;; plain adapter, for other modes, uses the same endmatter and treats no
;; text as literal.

;;; Code:

(require 'redline-parse)

(defconst redline-markdown--fence-regexp
  "^[ \t]*\\(`\\{3,\\}\\|~\\{3,\\}\\)\\(.*\\)$"
  "Regexp matching an opening code fence line.")

(defun redline-markdown--code-regions ()
  "Return the literal regions of the current Markdown buffer."
  (redline-merge-regions
   (append (redline-markdown--frontmatter)
           (redline-markdown--fences)
           (redline-markdown--html-comments))))

(defun redline-markdown--frontmatter ()
  "Return the YAML frontmatter region as a list, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (and (looking-at "---[ \t]*$")
               (progn (forward-line 1)
                      (re-search-forward "^\\(?:---\\|\\.\\.\\.\\)[ \t]*$" nil t)))
      (list (cons (point-min) (min (point-max) (1+ (point))))))))

(defun redline-markdown--fences ()
  "Return the fenced code block regions of the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search nil) regions)
      (while (re-search-forward redline-markdown--fence-regexp nil t)
        (let ((fence (match-string 1))
              (info (match-string 2))
              (beg (line-beginning-position)))
          (unless (and (eq (aref fence 0) ?`) (string-search "`" info))
            (forward-line 1)
            (push (cons beg (redline-markdown--fence-end fence)) regions))))
      (nreverse regions))))

(defun redline-markdown--fence-end (fence)
  "Return the end of the block opened by FENCE, moving point there."
  (if (re-search-forward
       (format "^[ \t]*%s\\{%d,\\}[ \t]*$"
               (regexp-quote (substring fence 0 1)) (length fence))
       nil t)
      (progn (forward-line 1) (point))
    (goto-char (point-max))))

(defun redline-markdown--html-comments ()
  "Return the HTML comment regions of the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let (regions)
      (while (search-forward "<!--" nil t)
        (let ((beg (match-beginning 0)))
          (when (search-forward "-->" nil t)
            (push (cons beg (point)) regions))))
      (nreverse regions))))

(defun redline-markdown--code-span (limit)
  "Return the end of the code span opened by the backtick run at point.
Return nil when the run is not closed before the paragraph ends or
LIMIT."
  (let* ((start (point))
         (length (progn (skip-chars-forward "`") (- (point) start)))
         (bound (save-excursion
                  (if (re-search-forward redline--blank-line-regexp limit t)
                      (match-beginning 0)
                    limit)))
         end)
    (while (and (not end) (re-search-forward "`+" bound t))
      (when (= (- (match-end 0) (match-beginning 0)) length)
        (setq end (match-end 0))))
    (goto-char start)
    end))

(defun redline-markdown--endmatter ()
  "Locate the final `---' block of the current buffer."
  (save-excursion
    (goto-char (point-max))
    (when (re-search-backward "^---[ \t]*$" nil t)
      (let ((beg (point)))
        (unless (or (= beg (point-min))
                    (redline-region-member beg (redline-markdown--code-regions)))
          (forward-line 1)
          (list :beg beg :end (point-max)
                :yaml (buffer-substring-no-properties (point) (point-max))))))))

(defun redline-markdown--plain-endmatter ()
  "Locate the final `---' block of the current buffer, ignoring code."
  (save-excursion
    (goto-char (point-max))
    (when (re-search-backward "^---[ \t]*$" nil t)
      (let ((beg (point)))
        (unless (= beg (point-min))
          (forward-line 1)
          (list :beg beg :end (point-max)
                :yaml (buffer-substring-no-properties (point) (point-max))))))))

(defun redline-markdown--wrap (yaml)
  "Return the endmatter block holding YAML."
  (concat "---\n" yaml))

(defvar redline-markdown-adapter
  (redline-adapter-create
   :name 'markdown
   :code-regions-function #'redline-markdown--code-regions
   :inline-literal-regexp "`+"
   :inline-literal-function #'redline-markdown--code-span
   :endmatter-locate-function #'redline-markdown--endmatter
   :endmatter-wrap-function #'redline-markdown--wrap
   :strict-endmatter t)
  "The redline adapter for Markdown buffers.")

(defvar redline-plain-adapter
  (redline-adapter-create
   :name 'plain
   :code-regions-function #'ignore
   :endmatter-locate-function #'redline-markdown--plain-endmatter
   :endmatter-wrap-function #'redline-markdown--wrap
   :strict-endmatter t)
  "The redline adapter for buffers in other modes.")

(provide 'redline-markdown)
;;; redline-markdown.el ends here
