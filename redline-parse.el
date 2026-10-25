;;; redline-parse.el --- Parse CriticMarkup review data -*- lexical-binding: t; -*-

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

;; Scan a buffer for CriticMarkup review spans and merge them with the
;; review endmatter into a list of items.  The scanner is markup
;; independent: an adapter (see `redline-adapter') says which regions
;; are literal code and where the endmatter lives.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'redline-endmatter)

;;;; Adapters

(cl-defstruct (redline-adapter (:constructor redline-adapter-create)
                               (:copier nil))
  "Markup-specific behaviour used by the scanner and the writers.
NAME is a symbol.  CODE-REGIONS-FUNCTION returns a sorted list of
\(BEG . END) regions whose text is literal, excluding the endmatter.
INLINE-LITERAL-REGEXP matches the start of an inline literal object and
INLINE-LITERAL-FUNCTION, called with point at the start of a match,
returns the end of that object or nil.  BOUNDARY-REGEXP matches, besides
blank lines, text that ends a paragraph.  ENDMATTER-LOCATE-FUNCTION
returns a plist (:beg BEG :end END :yaml YAML) for the candidate review
block, or nil.  ENDMATTER-WRAP-FUNCTION turns YAML text into the block
text.  STRICT-ENDMATTER non-nil applies the spec's reference condition
before accepting the block."
  name
  code-regions-function
  inline-literal-regexp
  inline-literal-function
  boundary-regexp
  endmatter-locate-function
  endmatter-wrap-function
  strict-endmatter)

;;;; Regions

(defun redline-merge-regions (regions)
  "Return REGIONS, a list of (BEG . END), sorted and merged."
  (let (merged)
    (dolist (region (sort (copy-sequence regions) #'car-less-than-car))
      (if (and merged (<= (car region) (cdar merged)))
          (setcdr (car merged) (max (cdar merged) (cdr region)))
        (push (cons (car region) (cdr region)) merged)))
    (nreverse merged)))

(defun redline-region-member (pos regions)
  "Return the region in REGIONS containing POS, or nil."
  (cl-find-if (lambda (region) (and (<= (car region) pos) (< pos (cdr region))))
              regions))

;;;; Data model

(cl-defstruct (redline-token (:constructor redline-token-create)
                             (:copier nil))
  "One CriticMarkup span in the buffer.
KIND is one of `comment', `addition', `deletion', `substitution' or
`highlight'.  BEG and END delimit the whole span including metadata.
OPEN-END is the end of the opening delimiter and CLOSE-END the end of the
closing one.  BODY-BEG and BODY-END delimit the text (the old text for a
substitution).  SEP-BEG is the start of `~>' and NEW-BEG/NEW-END delimit
the new text of a substitution.  META-BEG and META-END delimit the
metadata block, META-STYLE is `ref', `attr', `legacy' or nil, and ATTRS
is an alist of inline attributes."
  kind beg end open-end close-end body-beg body-end sep-beg new-beg new-end
  meta-beg meta-end meta-style attrs)

(cl-defstruct (redline-item (:constructor redline-item-create)
                            (:copier nil))
  "A comment or suggestion with its merged metadata.
KIND is the token kind, or `comment' for an endmatter-only comment.
TOKEN is the inline token or nil.  ANCHOR is the token a comment is
attached to (a highlight or a suggestion), or nil.  ID is the item id or
nil.  BODY is the comment text or the suggestion's text.  PARENT is the
id of the parent item.  ENTRY is the endmatter entry alist.  SCOPE is
`document' for a document-level comment."
  kind token anchor id body parent entry by at status resolved reaction
  scope)

(cl-defstruct (redline-doc (:constructor redline-doc-create)
                           (:copier nil))
  "The parsed review state of a buffer.
ITEMS lists comments and suggestions, inline ones in buffer order then
endmatter-only ones.  TOKENS lists all inline tokens.  LITERALS lists
\(BEG . END) literal regions.  ENDMATTER is a `redline-endmatter' or nil.
TICK is the buffer's character modification tick when parsed."
  items tokens literals endmatter adapter tick)

;;;; Scanning

(defconst redline--open-regexp "{\\(==\\|>>\\|\\+\\+\\|--\\|~~\\)"
  "Regexp matching a CriticMarkup opening delimiter.")

(defconst redline--blank-line-regexp "\n[ \t]*\n"
  "Regexp matching a blank line, which ends a paragraph.")

(defconst redline--ref-regexp "{#\\([A-Za-z][A-Za-z0-9_-]*\\)}"
  "Regexp matching a compact metadata reference.")

(defconst redline--attr-regexp
  (concat "{\\(?:[ \t\n]*[A-Za-z][A-Za-z0-9_-]*=\""
          "\\(?:\\\\\\(?:.\\|\n\\)\\|[^\"\\\\]\\)*\"\\)+[ \t\n]*}")
  "Regexp matching an inline attribute metadata block.")

(defconst redline--attr-pair-regexp
  "\\([A-Za-z][A-Za-z0-9_-]*\\)=\"\\(\\(?:\\\\\\(?:.\\|\n\\)\\|[^\"\\\\]\\)*\\)\""
  "Regexp matching one attribute in an attribute metadata block.")

(defconst redline--legacy-regexp "{@\\(\\(?:.\\|\n\\)+?\\)@}"
  "Regexp matching legacy comment metadata.")

(defun redline-parse (adapter)
  "Parse the current buffer with ADAPTER and return a `redline-doc'."
  (save-excursion
    (save-restriction
      (widen)
      (let* ((candidate (redline--endmatter-candidate adapter))
             (doc (redline--parse-with-endmatter adapter candidate)))
        (if (or (null candidate)
                (not (redline-adapter-strict-endmatter adapter))
                (redline--endmatter-referenced-p doc))
            doc
          (redline--parse-with-endmatter adapter nil))))))

(defun redline--endmatter-candidate (adapter)
  "Return the endmatter ADAPTER locates, if its YAML is review data."
  (when-let* ((found (funcall (redline-adapter-endmatter-locate-function
                               adapter))))
    (redline-endmatter-read (plist-get found :yaml)
                            (plist-get found :beg)
                            (plist-get found :end))))

(defun redline--parse-with-endmatter (adapter endmatter)
  "Scan the buffer with ADAPTER, treating ENDMATTER as review data."
  (let* ((limit (if endmatter (redline-endmatter-beg endmatter) (point-max)))
         (code (funcall (redline-adapter-code-regions-function adapter)))
         (scan (redline--scan adapter code limit))
         (tokens (car scan)))
    (redline-doc-create
     :items (redline--items tokens endmatter)
     :tokens tokens
     :literals (sort (append code (cdr scan)) #'car-less-than-car)
     :endmatter endmatter
     :adapter adapter
     :tick (buffer-chars-modified-tick))))

(defun redline--endmatter-referenced-p (doc)
  "Return non-nil if DOC meets the spec's endmatter reference condition.
That is, some token uses a compact reference or some comment entry has
a body, an author and a time."
  (or (cl-some (lambda (token) (eq (redline-token-meta-style token) 'ref))
               (redline-doc-tokens doc))
      (cl-some (lambda (entry)
                 (let ((fields (cdr entry)))
                   (and (redline--string (alist-get "body" fields nil nil #'equal))
                        (redline--string (alist-get "by" fields nil nil #'equal))
                        (redline--string (alist-get "at" fields nil nil #'equal)))))
               (redline-endmatter-section
                (redline-doc-endmatter doc) "comments"))))

(defun redline--scan (adapter code limit)
  "Scan from the buffer start to LIMIT with ADAPTER, skipping CODE.
Return (TOKENS . LITERALS), where LITERALS are inline literal regions."
  (let ((regexp (concat redline--open-regexp
                        (when-let* ((literal (redline-adapter-inline-literal-regexp
                                              adapter)))
                          (concat "\\|" literal))))
        (case-fold-search nil)
        tokens literals)
    (goto-char (point-min))
    (while (and (< (point) limit) (re-search-forward regexp limit t))
      (let ((start (match-beginning 0))
            (marker (match-string 1)))
        (while (and code (<= (cdar code) start))
          (setq code (cdr code)))
        (cond
         ((and code (<= (caar code) start))
          (goto-char (cdar code)))
         (marker
          (if-let* ((token (redline--read-token start marker adapter limit code)))
              (progn (push token tokens)
                     (goto-char (redline-token-end token)))
            (goto-char (1+ start))))
         (t
          (goto-char start)
          (if-let* ((end (funcall (redline-adapter-inline-literal-function adapter)
                                  limit)))
              (progn (push (cons start end) literals)
                     (goto-char end))
            (goto-char (max (match-end 0) (1+ start))))))))
    (cons (nreverse tokens) (nreverse literals))))

(defun redline--paragraph-limit (pos adapter limit code)
  "Return where the paragraph containing POS ends, at most LIMIT.
ADAPTER supplies extra boundaries; CODE regions also end it."
  (save-excursion
    (goto-char pos)
    (let ((ends (list limit)))
      (when (re-search-forward redline--blank-line-regexp limit t)
        (push (1+ (match-beginning 0)) ends))
      (goto-char pos)
      (when-let* ((boundary (redline-adapter-boundary-regexp adapter))
                  ((re-search-forward boundary limit t)))
        (push (1+ (match-beginning 0)) ends))
      (when-let* ((next (cl-find-if (lambda (region) (>= (car region) pos)) code)))
        (push (car next) ends))
      (apply #'min ends))))

(defun redline--read-token (start marker adapter limit code)
  "Read the token opened at START by the delimiter MARKER.
ADAPTER, LIMIT and CODE bound the paragraph.  Return a `redline-token'
or nil when the span is not closed within its paragraph."
  (let* ((open-end (+ start 3))
         (bound (redline--paragraph-limit open-end adapter limit code))
         (kind (pcase marker
                 ("==" 'highlight) (">>" 'comment) ("++" 'addition)
                 ("--" 'deletion) ("~~" 'substitution)))
         (token (if (eq kind 'substitution)
                    (redline--read-substitution start open-end bound)
                  (redline--read-simple kind start open-end bound))))
    (when token
      (unless (eq kind 'highlight)
        (redline--read-metadata token limit))
      token)))

(defun redline--read-simple (kind start open-end bound)
  "Read a non-substitution token of KIND opened at START.
OPEN-END is the end of its opening delimiter and BOUND the paragraph end."
  (let ((close (pcase kind
                 ('highlight "==}") ('comment "<<}")
                 ('addition "++}") ('deletion "--}"))))
    (goto-char (if (eq kind 'comment) open-end (1+ open-end)))
    (when (search-forward close bound t)
      (redline-token-create
       :kind kind :beg start :open-end open-end
       :body-beg open-end :body-end (match-beginning 0)
       :close-end (match-end 0) :end (match-end 0)))))

(defun redline--read-substitution (start open-end bound)
  "Read a substitution opened at START.
OPEN-END is the end of its opening delimiter and BOUND the paragraph end."
  (goto-char (1+ open-end))
  (when-let* (((search-forward "~>" bound t))
              (sep (match-beginning 0))
              (new-beg (match-end 0))
              ((progn (goto-char (1+ new-beg)) (search-forward "~~}" bound t))))
    (redline-token-create
     :kind 'substitution :beg start :open-end open-end
     :body-beg open-end :body-end sep :sep-beg sep
     :new-beg new-beg :new-end (match-beginning 0)
     :close-end (match-end 0) :end (match-end 0))))

(defun redline--read-metadata (token limit)
  "Read the metadata block after TOKEN, if any, and update TOKEN.
Do not read past LIMIT."
  (goto-char (redline-token-close-end token))
  (cond
   ((redline--looking-at redline--ref-regexp limit)
    (redline--set-meta token 'ref (lambda () (list (cons "id" (match-string 1))))))
   ((redline--looking-at redline--attr-regexp limit)
    (redline--set-meta token 'attr (lambda () (redline--parse-attrs (match-string 0)))))
   ((and (eq (redline-token-kind token) 'comment)
         (redline--looking-at redline--legacy-regexp limit))
    (redline--set-meta token 'legacy
                       (lambda () (redline--parse-legacy (match-string 1)))))))

(defun redline--looking-at (regexp limit)
  "Return non-nil if REGEXP matches at point and ends by LIMIT."
  (and (looking-at regexp) (<= (match-end 0) limit)))

(defun redline--set-meta (token style read-attrs)
  "Record metadata of STYLE on TOKEN from the last match.
READ-ATTRS returns the attributes; it may change the match data, so it
is called after the match positions are saved."
  (let ((beg (match-beginning 0))
        (end (match-end 0)))
    (setf (redline-token-attrs token) (funcall read-attrs)
          (redline-token-meta-beg token) beg
          (redline-token-meta-end token) end
          (redline-token-end token) end
          (redline-token-meta-style token) style)))

(defun redline--parse-attrs (text)
  "Return the attributes of the attribute block TEXT as an alist."
  (let ((start 0) attrs)
    (while (string-match redline--attr-pair-regexp text start)
      (push (cons (match-string 1 text)
                  (replace-regexp-in-string
                   "\\\\\\(\\(?:.\\|\n\\)\\)" "\\1" (match-string 2 text) t))
            attrs)
      (setq start (match-end 0)))
    (nreverse attrs)))

(defun redline--parse-legacy (text)
  "Return the fields of legacy metadata TEXT as an alist."
  (let (attrs)
    (dolist (part (split-string text ";"))
      (when (string-match "\\`[ \t\n]*\\([^:]+?\\)[ \t\n]*:\\(\\(?:.\\|\n\\)*\\)\\'" part)
        (let ((key (match-string 1 part))
              (value (string-trim (match-string 2 part))))
          (unless (string-empty-p value)
            (push (cons key value) attrs)))))
    (nreverse attrs)))

;;;; Items

(defconst redline--suggestion-kinds '(addition deletion substitution)
  "Token kinds that are suggestions.")

(defun redline--items (tokens endmatter)
  "Build items from TOKENS and the ENDMATTER data."
  (let ((comments (redline-endmatter-section endmatter "comments"))
        (suggestions (redline-endmatter-section endmatter "suggestions"))
        anchor anchor-end items used)
    (dolist (token tokens)
      (pcase (redline-token-kind token)
        ('highlight (setq anchor token anchor-end (redline-token-end token)))
        ('comment
         (let* ((adjacent (and anchor (eql (redline-token-beg token) anchor-end)))
                (item (redline--comment-item token (and adjacent anchor) comments)))
           (if adjacent
               (setq anchor-end (redline-token-end token))
             (setq anchor nil))
           (push (redline-item-id item) used)
           (push item items)))
        (_
         (let ((item (redline--suggestion-item token suggestions)))
           (setq anchor token anchor-end (redline-token-end token))
           (push item items)))))
    (dolist (entry comments)
      (unless (member (car entry) used)
        (when-let* ((item (redline--endmatter-comment (car entry) (cdr entry))))
          (push item items))))
    (nreverse items)))

(defun redline--field (fields key)
  "Return the string value of KEY in FIELDS, or nil."
  (redline--string (alist-get key fields nil nil #'equal)))

(defun redline--string (value)
  "Return VALUE if it is a non-empty string, else nil."
  (and (stringp value) (not (string-empty-p value)) value))

(defun redline--comment-item (token anchor comments)
  "Return the item for comment TOKEN attached to ANCHOR.
COMMENTS is the endmatter comments section."
  (let* ((attrs (redline-token-attrs token))
         (style (redline-token-meta-style token))
         (id (redline--field attrs "id"))
         (entry (and (eq style 'ref) (cdr (assoc id comments))))
         (inline (buffer-substring-no-properties (redline-token-body-beg token)
                                                 (redline-token-body-end token)))
         (body (if (and (string-empty-p inline) (redline--field entry "body"))
                   (redline--field entry "body")
                 inline))
         (fields (if (eq style 'ref) entry attrs))
         (parent (and (or (not (redline--field entry "body"))
                          (string-empty-p inline)
                          (equal (redline--field entry "body") inline))
                      (redline--field fields "re"))))
    (redline--fill-item
     (redline-item-create :kind 'comment :token token :anchor anchor :id id
                          :body body :parent parent :entry entry)
     fields)))

(defun redline--suggestion-item (token suggestions)
  "Return the item for suggestion TOKEN with SUGGESTIONS endmatter."
  (let* ((attrs (redline-token-attrs token))
         (id (redline--field attrs "id"))
         (entry (and (eq (redline-token-meta-style token) 'ref)
                     (cdr (assoc id suggestions)))))
    (redline--fill-item
     (redline-item-create
      :kind (redline-token-kind token) :token token :id id :entry entry
      :body (buffer-substring-no-properties (redline-token-body-beg token)
                                            (redline-token-body-end token)))
     (if (eq (redline-token-meta-style token) 'ref) entry attrs))))

(defun redline--endmatter-comment (id fields)
  "Return the item for endmatter-only comment ID with FIELDS, or nil."
  (when-let* ((body (redline--field fields "body")))
    (let ((parent (redline--field fields "re")))
      (redline--fill-item
       (redline-item-create :kind 'comment :id id :body body :parent parent
                            :entry fields :scope (unless parent 'document))
       fields))))

(defun redline--fill-item (item fields)
  "Copy author, time and review state from FIELDS into ITEM and return it."
  (setf (redline-item-by item) (redline--field fields "by")
        (redline-item-at item) (redline--field fields "at")
        (redline-item-status item) (redline--field fields "status")
        (redline-item-resolved item) (redline--field fields "resolved")
        (redline-item-reaction item) (redline--field fields "reaction"))
  item)

;;;; Threads

(defun redline-suggestion-p (item)
  "Return non-nil if ITEM is a suggestion."
  (memq (redline-item-kind item) redline--suggestion-kinds))

(defun redline-item-parent-id (doc item)
  "Return the id of ITEM's parent in DOC, or nil for a thread root.
A comment attached to a suggestion has that suggestion as parent.  A
missing or self-referencing parent makes ITEM a root."
  (let ((parent (or (redline-item-parent item)
                    (when-let* ((anchor (redline-item-anchor item))
                                ((memq (redline-token-kind anchor)
                                       redline--suggestion-kinds)))
                      (redline-item-id (redline-item-for-token doc anchor))))))
    (and parent
         (not (equal parent (redline-item-id item)))
         (redline-item-by-id doc parent)
         parent)))

(defun redline-item-root (doc item)
  "Return the root of ITEM's thread in DOC, following parents safely."
  (let ((seen (list item)) (current item) parent)
    (while (and (setq parent (redline-item-by-id
                              doc (redline-item-parent-id doc current)))
                (not (memq parent seen)))
      (push parent seen)
      (setq current parent))
    current))

(defun redline-item-children (doc item)
  "Return the items in DOC whose parent is ITEM."
  (let ((id (redline-item-id item)))
    (cl-remove-if-not
     (lambda (other)
       (and (not (eq other item))
            (if id
                (equal (redline-item-parent-id doc other) id)
              (and (null (redline-item-parent other))
                   (eq (redline-item-anchor other) (redline-item-token item))))))
     (redline-doc-items doc))))

(defun redline-item-descendants (doc item)
  "Return all items below ITEM in DOC, without cycles."
  (let ((queue (list item)) seen)
    (while queue
      (let ((current (pop queue)))
        (dolist (child (redline-item-children doc current))
          (unless (or (eq child item) (memq child seen))
            (push child seen)
            (setq queue (append queue (list child)))))))
    (nreverse seen)))

(defun redline-thread-roots (doc)
  "Return the thread roots in DOC in document order."
  (cl-remove-if (lambda (item) (redline-item-parent-id doc item))
                (redline-doc-items doc)))

(defun redline-item-by-id (doc id)
  "Return the item in DOC with ID, or nil."
  (and id (cl-find id (redline-doc-items doc)
                   :key #'redline-item-id :test #'equal)))

(defun redline-item-for-token (doc token)
  "Return the item in DOC for TOKEN."
  (cl-find token (redline-doc-items doc) :key #'redline-item-token))

(defun redline-item-resolved-p (item)
  "Return non-nil if ITEM is marked resolved."
  (equal (redline-item-status item) "resolved"))

(provide 'redline-parse)
;;; redline-parse.el ends here
