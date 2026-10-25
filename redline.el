;;; redline.el --- Review threads and suggestions in Markdown and Org -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Pablo Stafforini

;; Author: Pablo Stafforini <pablo@stafforini.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (yaml "1.0"))
;; Keywords: wp, text, convenience
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

;; redline lets you comment on passages, reply in threads, suggest
;; insertions, deletions and replacements, accept or reject them, and
;; hand the file to an AI agent that answers the review.  The review
;; lives in the file itself as CriticMarkup plus a YAML endmatter block,
;; following Roughdraft Flavored Markdown 0.2, so Markdown files stay
;; compatible with Roughdraft (https://github.com/peterhartree/roughdraft)
;; and with agents that read its format.  Org files use the same data
;; with the endmatter inside a `#+begin_comment redline' block.
;;
;; Enable `redline-mode' in a Markdown or Org buffer and bind
;; `redline-command-map' to a prefix key, for example:
;;
;;   (keymap-set redline-mode-map "C-c r" 'redline-command-map)

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'redline-parse)
(require 'redline-endmatter)

;;;; Customization

(defgroup redline nil
  "Review threads and suggestions in Markdown and Org."
  :group 'text
  :prefix "redline-")

(defcustom redline-author "user"
  "Author label written as `by' on new comments and suggestions.
Roughdraft labels people `user' and agents `AI'."
  :type 'string)

(defcustom redline-adapter-alist
  '((markdown-mode redline-markdown redline-markdown-adapter)
    (org-mode redline-org redline-org-adapter))
  "Adapters by major mode.
Each element is (MODE FEATURE VARIABLE): in buffers derived from MODE,
FEATURE is loaded and the adapter in VARIABLE is used.  Other buffers
use the plain adapter."
  :type '(repeat (list (symbol :tag "Major mode")
                       (symbol :tag "Feature")
                       (symbol :tag "Adapter variable"))))

(defcustom redline-send-function nil
  "Function that hands a reviewed file to an AI agent.
It is called with the file name and a prompt asking the agent to answer
the review.  When nil, `redline-send-to-agent' copies the prompt to the
kill ring instead."
  :type '(choice (const :tag "Copy the prompt" nil) function))

(defcustom redline-refresh-delay 0.3
  "Seconds of idle time before the review display is refreshed."
  :type 'number)

(defcustom redline-spec-url
  "https://github.com/peterhartree/roughdraft/blob/main/docs/spec/roughdraft-flavored-markdown.md"
  "URL of the Roughdraft Flavored Markdown specification."
  :type 'string)

(defface redline-highlight
  '((((background light)) :background "#fff3b0" :extend nil)
    (t :background "#5c5326" :extend nil))
  "Face for commented passages.")

(defface redline-insertion
  '((((background light)) :foreground "#116611" :underline t)
    (t :foreground "#8fdc8f" :underline t))
  "Face for suggested insertions.")

(defface redline-deletion
  '((((background light)) :foreground "#aa2222" :strike-through t)
    (t :foreground "#f08080" :strike-through t))
  "Face for suggested deletions.")

(defface redline-indicator
  '((t :inherit font-lock-comment-face :weight bold))
  "Face for comment indicators.")

(defface redline-resolved
  '((t :inherit shadow))
  "Face for resolved review items.")

;;;; Buffer state

(defvar-local redline--doc nil
  "The cached `redline-doc' of the current buffer.")

(defvar-local redline--raw nil
  "Non-nil when review markup is shown raw.")

(defvar-local redline--timer nil
  "Idle timer for the pending display refresh.")

(defvar-local redline--revealed nil
  "Overlays currently revealed because point is on their item.")

(defvar-local redline--enabled-auto-revert nil
  "Non-nil if `redline-mode' turned on `auto-revert-mode'.")

(defvar-local redline--source-buffer nil
  "In a thread or list buffer, the reviewed buffer.")

(defvar-local redline--source-tick nil
  "In a thread or list buffer, the source tick it was drawn from.")

(defun redline-adapter ()
  "Return the adapter for the current buffer."
  (let ((entry (cl-find-if (lambda (entry) (derived-mode-p (car entry)))
                           redline-adapter-alist)))
    (if entry
        (progn (require (nth 1 entry)) (symbol-value (nth 2 entry)))
      (require 'redline-markdown)
      (symbol-value 'redline-plain-adapter))))

(defun redline-doc ()
  "Return the parsed review state of the current buffer, parsing if stale."
  (unless (and redline--doc
               (eql (redline-doc-tick redline--doc) (buffer-chars-modified-tick)))
    (setq redline--doc (redline-parse (redline-adapter))))
  redline--doc)

;;;; Minor mode

(defvar-keymap redline-command-map
  :doc "Keymap for redline commands."
  :prefix 'redline-command-map
  "c" #'redline-comment
  "r" #'redline-reply
  "e" #'redline-edit
  "d" #'redline-delete
  "i" #'redline-suggest-insertion
  "k" #'redline-suggest-deletion
  "s" #'redline-suggest-replacement
  "a" #'redline-accept
  "x" #'redline-reject
  "A" #'redline-accept-all
  "X" #'redline-reject-all
  "R" #'redline-resolve
  "U" #'redline-unresolve
  "D" #'redline-remove-resolved
  "+" #'redline-react
  "n" #'redline-next
  "p" #'redline-previous
  "N" #'redline-next-unresolved
  "P" #'redline-previous-unresolved
  "l" #'redline-list
  "t" #'redline-show-thread
  "m" #'redline-toggle-markup
  "S" #'redline-send-to-agent)

(defvar-keymap redline-mode-map
  :doc "Keymap for `redline-mode'.  Bind `redline-command-map' in it.")

;;;###autoload
(define-minor-mode redline-mode
  "Show and edit CriticMarkup review threads and suggestions.
Commands are in `redline-command-map'."
  :lighter " Redline"
  :keymap redline-mode-map
  (if redline-mode
      (redline--enable)
    (redline--disable)))

(defun redline--enable ()
  "Set up `redline-mode' in the current buffer."
  (add-to-invisibility-spec 'redline)
  (add-hook 'after-change-functions #'redline--after-change nil t)
  (add-hook 'post-command-hook #'redline--post-command nil t)
  (add-hook 'after-revert-hook #'redline-refresh nil t)
  (when (and buffer-file-name (not (bound-and-true-p auto-revert-mode)))
    (auto-revert-mode 1)
    (setq redline--enabled-auto-revert t))
  (redline-refresh))

(defun redline--disable ()
  "Tear down `redline-mode' in the current buffer."
  (remove-from-invisibility-spec 'redline)
  (remove-hook 'after-change-functions #'redline--after-change t)
  (remove-hook 'post-command-hook #'redline--post-command t)
  (remove-hook 'after-revert-hook #'redline-refresh t)
  (when redline--timer (cancel-timer redline--timer))
  (when redline--enabled-auto-revert
    (auto-revert-mode -1)
    (setq redline--enabled-auto-revert nil))
  (redline--delete-overlays)
  (setq redline--doc nil redline--timer nil redline--revealed nil))

(defun redline--after-change (&rest _)
  "Schedule a display refresh after a buffer change."
  (unless redline--timer
    (setq redline--timer
          (run-with-idle-timer redline-refresh-delay nil
                               #'redline--refresh-buffer (current-buffer)))))

(defun redline--refresh-buffer (buffer)
  "Refresh the review display of BUFFER if it is live."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq redline--timer nil)
      (when redline-mode
        (redline-refresh)))))

(defun redline-refresh ()
  "Reparse the buffer and redraw the review display."
  (interactive)
  (redline--delete-overlays)
  (let ((doc (redline-doc)))
    (dolist (token (redline-doc-tokens doc))
      (redline--draw-token doc token))
    (when-let* ((endmatter (redline-doc-endmatter doc)))
      (redline--draw-endmatter doc endmatter)))
  (setq redline--revealed nil)
  (redline--reveal)
  (redline--update-views))

;;;; Display

(defun redline--delete-overlays ()
  "Delete all redline overlays in the current buffer."
  (remove-overlays (point-min) (point-max) 'redline t))

(defun redline--overlay (beg end token &rest properties)
  "Make an overlay from BEG to END for TOKEN with PROPERTIES."
  (when (< beg end)
    (let ((overlay (make-overlay beg end nil t nil)))
      (overlay-put overlay 'redline t)
      (overlay-put overlay 'redline-token token)
      (overlay-put overlay 'priority 100)
      (while properties
        (overlay-put overlay (pop properties) (pop properties)))
      overlay)))

(defun redline--hide (beg end token)
  "Hide the markup from BEG to END belonging to TOKEN."
  (unless redline--raw
    (redline--overlay beg end token 'invisible 'redline)))

(defun redline--draw-token (doc token)
  "Draw the overlays for TOKEN of DOC."
  (let* ((item (redline--item-for-position doc token))
         (resolved (and item (redline-item-resolved-p
                              (redline-item-root doc item))))
         (beg (redline-token-beg token))
         (end (redline-token-end token)))
    (pcase (redline-token-kind token)
      ('comment (redline--draw-comment doc token item resolved))
      ('substitution
       (redline--hide beg (redline-token-open-end token) token)
       (redline--face token (redline-token-body-beg token) (redline-token-body-end token)
                      'redline-deletion resolved)
       (redline--hide (redline-token-sep-beg token) (redline-token-new-beg token) token)
       (redline--face token (redline-token-new-beg token) (redline-token-new-end token)
                      'redline-insertion resolved)
       (redline--hide (redline-token-new-end token) end token))
      (kind
       (redline--hide beg (redline-token-open-end token) token)
       (redline--face token (redline-token-body-beg token) (redline-token-body-end token)
                      (pcase kind
                        ('highlight 'redline-highlight)
                        ('addition 'redline-insertion)
                        ('deletion 'redline-deletion))
                      resolved)
       (redline--hide (redline-token-body-end token) end token)))))

(defun redline--face (token beg end face resolved)
  "Give the text of TOKEN from BEG to END FACE, dimmed if RESOLVED."
  (redline--overlay beg end token 'face (if resolved (list 'redline-resolved face) face)))

(defun redline--draw-comment (doc token item resolved)
  "Draw comment TOKEN of DOC, whose item is ITEM, dimmed if RESOLVED."
  (redline--overlay
   (redline-token-beg token) (redline-token-end token) token
   'display (unless redline--raw (redline--indicator doc item))
   'face (if resolved 'redline-resolved 'redline-indicator)
   'help-echo (redline-item-body item)))

(defun redline--indicator (doc item)
  "Return the indicator string for comment ITEM of DOC."
  (let ((replies (length (redline-item-descendants doc item))))
    (propertize (format "[%s%s%s]"
                        (or (redline-item-id item) "comment")
                        (if (> replies 0) (format "·%d" replies) "")
                        (if (redline-item-resolved-p item) " ✓" ""))
                'face (if (redline-item-resolved-p item)
                          'redline-resolved
                        'redline-indicator))))

(defun redline--draw-endmatter (doc endmatter)
  "Fold ENDMATTER of DOC behind a summary line."
  (unless redline--raw
    (let ((items (redline-doc-items doc)))
      (redline--overlay
       (redline-endmatter-beg endmatter) (redline-endmatter-end endmatter) nil
       'display (propertize
                 (format "[redline: %d comments, %d suggestions]\n"
                         (cl-count 'comment items :key #'redline-item-kind)
                         (cl-count-if #'redline-suggestion-p items))
                 'face 'shadow)))))

(defun redline--post-command ()
  "Reveal the item at point and follow it in the thread window."
  (redline--reveal)
  (redline--follow-thread))

(defun redline--reveal ()
  "Show the raw markup of the items at point and hide the others again."
  (unless redline--raw
    (let ((wanted (cl-remove-if-not
                   (lambda (overlay) (overlay-get overlay 'redline-token))
                   (redline--overlays-for-tokens (redline--tokens-at (point))))))
      (dolist (overlay redline--revealed)
        (unless (memq overlay wanted)
          (redline--conceal overlay)))
      (dolist (overlay wanted)
        (unless (memq overlay redline--revealed)
          (redline--unconceal overlay)))
      (setq redline--revealed wanted))))

(defun redline--tokens-at (pos)
  "Return the tokens of the cached doc that touch POS."
  (when redline--doc
    (cl-remove-if-not (lambda (token)
                        (and (<= (redline-token-beg token) pos)
                             (<= pos (redline-token-end token))))
                      (redline-doc-tokens redline--doc))))

(defun redline--overlays-for-tokens (tokens)
  "Return the redline overlays drawn for TOKENS."
  (when tokens
    (cl-remove-if-not (lambda (overlay)
                        (memq (overlay-get overlay 'redline-token) tokens))
                      (overlays-in (apply #'min (mapcar #'redline-token-beg tokens))
                                   (apply #'max (mapcar #'redline-token-end tokens))))))

(defun redline--unconceal (overlay)
  "Show the markup OVERLAY hides."
  (overlay-put overlay 'redline-saved
               (list (overlay-get overlay 'invisible) (overlay-get overlay 'display)))
  (overlay-put overlay 'invisible nil)
  (overlay-put overlay 'display nil))

(defun redline--conceal (overlay)
  "Hide again the markup OVERLAY hid before it was revealed."
  (when-let* ((saved (overlay-get overlay 'redline-saved)))
    (overlay-put overlay 'invisible (nth 0 saved))
    (overlay-put overlay 'display (nth 1 saved))
    (overlay-put overlay 'redline-saved nil)))

(defun redline-toggle-markup ()
  "Toggle between the review display and the raw markup."
  (interactive)
  (setq redline--raw (not redline--raw))
  (redline-refresh)
  (message "Review markup %s" (if redline--raw "shown raw" "hidden")))

;;;; Targets

(defun redline--item-at-point ()
  "Return the review item at point in the source buffer."
  (let* ((doc (redline-doc))
         (tokens (redline--tokens-in doc (point))))
    (or (cl-loop for token in tokens
                 for item = (redline--item-for-position doc token)
                 when item return item)
        (user-error "No review item at point"))))

(defun redline--tokens-in (doc pos)
  "Return the tokens of DOC touching POS, those containing it first."
  (let ((touching (cl-remove-if-not
                   (lambda (token)
                     (and (<= (redline-token-beg token) pos)
                          (<= pos (redline-token-end token))))
                   (redline-doc-tokens doc))))
    (append (cl-remove-if (lambda (token) (= pos (redline-token-end token))) touching)
            (cl-remove-if-not (lambda (token) (= pos (redline-token-end token))) touching))))

(defun redline--item-for-position (doc token)
  "Return the item DOC associates with TOKEN for commands at point.
A highlight stands for the first comment attached to it."
  (if (eq (redline-token-kind token) 'highlight)
      (cl-find token (redline-doc-items doc) :key #'redline-item-anchor)
    (redline-item-for-token doc token)))

(defun redline--item-key (item)
  "Return a key identifying ITEM for thread and list buffers."
  (or (redline-item-id item)
      (list :beg (redline-token-beg (redline-item-token item)))))

(defun redline--item-from-key (key)
  "Return the item of the current buffer identified by KEY."
  (let ((doc (redline-doc)))
    (or (if (stringp key)
            (redline-item-by-id doc key)
          (cl-find (plist-get key :beg) (redline-doc-items doc)
                   :key (lambda (item)
                          (and (redline-item-token item)
                               (redline-token-beg (redline-item-token item))))))
        (user-error "That review item no longer exists"))))

(defun redline--call (function)
  "Call FUNCTION with the target item in its source buffer.
In a thread or list buffer the target is the entry at point; elsewhere
it is the item at point."
  (if (derived-mode-p 'redline-thread-mode 'redline-list-mode)
      (let ((key (get-text-property (point) 'redline-key))
            (source redline--source-buffer)
            (tick redline--source-tick))
        (unless key (user-error "No review item on this line"))
        (unless (buffer-live-p source) (user-error "The reviewed buffer is gone"))
        (with-current-buffer source
          (unless (eql tick (buffer-chars-modified-tick))
            (redline--update-views)
            (user-error "The buffer changed; check the updated view and retry"))
          (funcall function (redline--item-from-key key))))
    (unless redline-mode (user-error "`redline-mode' is not enabled"))
    (funcall function (redline--item-at-point))))

;;;; Transactions

(cl-defstruct (redline--tx (:constructor redline--tx-create) (:copier nil))
  "A pending change: inline EDITS and the endmatter MODEL for DOC."
  doc edits model)

(defun redline--tx-begin ()
  "Start a change from a fresh parse of the current buffer."
  (let ((doc (redline-doc)))
    (redline--tx-create :doc doc
                        :model (redline-endmatter-editable-model
                                (redline-doc-endmatter doc)))))

(defun redline--tx-edit (tx beg end text)
  "Record in TX the replacement of BEG..END by TEXT."
  (push (list beg end text) (redline--tx-edits tx)))

(defun redline--tx-put (tx section id &rest fields)
  "Set FIELDS, a plist of field names and values, on entry ID in TX.
SECTION is \"comments\" or \"suggestions\"."
  (while fields
    (setf (redline--tx-model tx)
          (redline-endmatter-put (redline--tx-model tx) section id
                                 (pop fields) (pop fields)))))

(defun redline--tx-delete (tx section id)
  "Delete entry ID of SECTION in TX."
  (setf (redline--tx-model tx)
        (redline-endmatter-delete (redline--tx-model tx) section id)))

(defmacro redline--with-edit (&rest body)
  "Run BODY as one undoable change that is reverted if it fails."
  (declare (indent 0) (debug t))
  (let ((group (make-symbol "group"))
        (success (make-symbol "success")))
    `(let ((,group (prepare-change-group))
           (,success nil))
       (unwind-protect
           (progn
             (activate-change-group ,group)
             (prog1 (save-excursion ,@body)
               (setq ,success t)))
         (if ,success
             (progn (undo-amalgamate-change-group ,group)
                    (accept-change-group ,group))
           (cancel-change-group ,group))))))

(defun redline--tx-commit (tx)
  "Apply TX to the current buffer as one undoable change."
  (let ((adapter (redline-doc-adapter (redline--tx-doc tx)))
        (edits (sort (copy-sequence (redline--tx-edits tx))
                     (lambda (a b) (> (car a) (car b))))))
    (redline--check-edits edits)
    (redline--with-edit
      (dolist (edit edits)
        (goto-char (nth 0 edit))
        (delete-region (nth 0 edit) (nth 1 edit))
        (insert (nth 2 edit)))
      (redline--write-endmatter adapter (redline--prune tx adapter))))
  (redline-refresh))

(defun redline--check-edits (edits)
  "Signal an error if EDITS, sorted by descending start, overlap."
  (cl-loop for (later earlier) on edits
           when (and earlier (> (nth 1 earlier) (nth 0 later)))
           do (error "Overlapping redline edits")))

(defun redline--prune (tx adapter)
  "Return TX's model without metadata-only entries no text refers to.
Parse the edited buffer with ADAPTER to find the remaining references."
  (let* ((doc (redline-parse adapter))
         (referenced (delq nil (mapcar (lambda (token)
                                         (cdr (assoc "id" (redline-token-attrs token))))
                                       (redline-doc-tokens doc))))
         (model (redline--tx-model tx)))
    (dolist (section redline-endmatter-sections)
      (dolist (id (redline-endmatter-ids model section))
        (let ((fields (redline-endmatter-entry-fields model section id)))
          (unless (or (eq fields 'raw)
                      (assoc "body" fields)
                      (member id referenced))
            (setq model (redline-endmatter-delete model section id))))))
    model))

(defun redline--write-endmatter (adapter model)
  "Write MODEL as the endmatter of the current buffer using ADAPTER."
  (let* ((old (when-let* ((found (funcall (redline-adapter-endmatter-locate-function
                                           adapter))))
                (and (redline-endmatter-read (plist-get found :yaml) 0 0) found)))
         (yaml (redline-endmatter-serialize model))
         (text (and yaml (funcall (redline-adapter-endmatter-wrap-function adapter)
                                  yaml))))
    (cond
     ((and old text)
      (unless (equal text (buffer-substring-no-properties
                           (plist-get old :beg) (plist-get old :end)))
        (goto-char (plist-get old :beg))
        (delete-region (plist-get old :beg) (plist-get old :end))
        (insert text)))
     (old (redline--delete-endmatter (plist-get old :beg) (plist-get old :end)))
     (text (redline--append-endmatter text)))))

(defun redline--delete-endmatter (beg end)
  "Delete the endmatter from BEG to END and the blank lines before it."
  (goto-char beg)
  (skip-chars-backward " \t\n")
  (delete-region (point) end)
  (unless (bobp) (insert "\n")))

(defun redline--append-endmatter (text)
  "Append endmatter TEXT after a blank line."
  (goto-char (point-max))
  (unless (or (bobp) (eq (char-before) ?\n)) (insert "\n"))
  (unless (or (bobp) (looking-back "\n\n" (- (point) 2))) (insert "\n"))
  (insert text))

;;;; Ids and metadata

(defun redline--now ()
  "Return the current time as an ISO 8601 UTC string."
  (format-time-string "%Y-%m-%dT%H:%M:%S.%3NZ" nil t))

(defun redline--next-id (tx prefix)
  "Return the next free id with PREFIX, \"c\" or \"s\", for TX."
  (let ((ids (append (delq nil (mapcar #'redline-item-id
                                       (redline-doc-items (redline--tx-doc tx))))
                     (delq nil (mapcar (lambda (token)
                                         (cdr (assoc "id" (redline-token-attrs token))))
                                       (redline-doc-tokens (redline--tx-doc tx))))
                     (mapcan (lambda (section)
                               (redline-endmatter-ids (redline--tx-model tx) section))
                             redline-endmatter-sections)))
        (regexp (format "\\`%s\\([0-9]+\\)\\'" prefix)))
    (format "%s%d" prefix
            (1+ (apply #'max 0 (mapcar (lambda (id)
                                         (if (string-match regexp id)
                                             (string-to-number (match-string 1 id))
                                           0))
                                       ids))))))

(defun redline--section (item)
  "Return the endmatter section ITEM belongs to."
  (if (redline-suggestion-p item) "suggestions" "comments"))

(defun redline--ensure-id (tx item)
  "Make sure ITEM has an id and endmatter entry in TX; return the id.
Plain markup gets a new id; inline attribute metadata is migrated to a
compact reference."
  (let ((token (redline-item-token item))
        (section (redline--section item)))
    (cond
     ((null token) (redline-item-id item))
     ((eq (redline-token-meta-style token) 'ref) (redline-item-id item))
     ((redline-token-meta-style token) (redline--migrate tx item section))
     (t (let ((id (redline--next-id tx (if (redline-suggestion-p item) "s" "c"))))
          (redline--tx-edit tx (redline-token-close-end token)
                            (redline-token-close-end token) (format "{#%s}" id))
          (redline--tx-put tx section id "by" "user" "at" (redline--now))
          id)))))

(defun redline--migrate (tx item section)
  "Move ITEM's inline metadata into the endmatter of TX; return its id.
SECTION is ITEM's endmatter section."
  (let* ((token (redline-item-token item))
         (attrs (redline-token-attrs token))
         (id (or (redline-item-id item)
                 (redline--next-id tx (if (redline-suggestion-p item) "s" "c")))))
    (redline--tx-edit tx (redline-token-meta-beg token) (redline-token-meta-end token)
                      (format "{#%s}" id))
    (redline--tx-put tx section id
                     "by" (or (redline-item-by item) "user")
                     "at" (or (redline-item-at item) (redline--now)))
    (when (redline-item-parent item)
      (redline--tx-put tx section id "body" (redline-item-body item)
                       "re" (redline-item-parent item)))
    (dolist (attr attrs)
      (unless (member (car attr) '("id" "by" "at" "re"))
        (redline--tx-put tx section id (car attr) (cdr attr))))
    id))

;;;; Validation

(defconst redline--delimiters
  '("{==" "==}" "{>>" "<<}" "{++" "++}" "{--" "--}" "{~~" "~~}" "~>")
  "Delimiters that may not appear in anchor or suggestion text.")

(defun redline--check-text (text)
  "Signal an error unless TEXT can sit inside a highlight or suggestion."
  (when (string-empty-p text)
    (user-error "Empty text"))
  (when-let* ((found (cl-find-if (lambda (delimiter) (string-search delimiter text))
                                 redline--delimiters)))
    (user-error "Text contains the CriticMarkup delimiter `%s'" found))
  (when (string-match-p redline--blank-line-regexp text)
    (user-error "Text spans more than one paragraph")))

(defun redline--check-comment (text)
  "Signal an error unless TEXT can be a comment."
  (when (string-blank-p text)
    (user-error "Empty comment"))
  (when (string-search "<<}" text)
    (user-error "Comment contains the CriticMarkup delimiter `<<}'")))

(defun redline--check-region (doc beg end)
  "Signal an error unless BEG..END in DOC can be marked up."
  (when (>= beg end) (user-error "Empty region"))
  (redline--check-outside-review doc beg end)
  (save-excursion
    (goto-char beg)
    (when (or (re-search-forward redline--blank-line-regexp end t)
              (when-let* ((boundary (redline-adapter-boundary-regexp
                                     (redline-doc-adapter doc))))
                (goto-char beg)
                (re-search-forward boundary end t)))
      (user-error "The region spans more than one paragraph")))
  (redline--check-text (buffer-substring-no-properties beg end)))

(defun redline--check-point (doc pos)
  "Signal an error unless review markup can be inserted at POS in DOC."
  (redline--check-outside-review doc pos pos))

(defun redline--check-outside-review (doc beg end)
  "Signal an error if BEG..END in DOC touches review markup or code.
A position on the edge of a span is outside it."
  (cl-flet ((overlaps (rbeg rend &optional inclusive)
              (if (= beg end)
                  (and (if inclusive (<= rbeg beg) (< rbeg beg)) (< beg rend))
                (and (< rbeg end) (< beg rend)))))
    (when (cl-some (lambda (token)
                     (overlaps (redline-token-beg token) (redline-token-end token)))
                   (redline-doc-tokens doc))
      (user-error "That would overlap existing review markup"))
    (when (cl-some (lambda (region) (overlaps (car region) (cdr region) t))
                   (redline-doc-literals doc))
      (user-error "That would put review markup in code or metadata"))
    (when-let* ((endmatter (redline-doc-endmatter doc))
                ((> end (1- (redline-endmatter-beg endmatter)))))
      (user-error "That would put review markup in the endmatter"))))

;;;; Reading input

(defvar-keymap redline--minibuffer-map
  :doc "Minibuffer keymap for review text; \\`C-j' inserts a newline."
  :parent minibuffer-local-map
  "C-j" #'newline
  "S-<return>" #'newline)

(defun redline--read (prompt &optional initial)
  "Read review text with PROMPT, starting from INITIAL."
  (string-trim (read-from-minibuffer prompt initial redline--minibuffer-map)))

;;;; Comment commands

(defun redline-comment (&optional document)
  "Comment on the region, or at point when no region is active.
With prefix argument DOCUMENT, add a document-level comment."
  (interactive "P")
  (unless redline-mode (user-error "`redline-mode' is not enabled"))
  (let* ((tx (redline--tx-begin))
         (doc (redline--tx-doc tx))
         (region (and (not document) (use-region-p)
                      (cons (region-beginning) (region-end)))))
    (cond (region (redline--check-region doc (car region) (cdr region)))
          ((not document) (redline--check-point doc (point))))
    (let ((text (redline--read "Comment: "))
          (id (redline--next-id tx "c")))
      (redline--check-comment text)
      (cond
       (document
        (redline--tx-put tx "comments" id "body" text "by" redline-author
                         "at" (redline--now)))
       (region
        (redline--tx-edit tx (cdr region) (cdr region)
                          (concat "==}" (redline--inline-comment tx id text)))
        (redline--tx-edit tx (car region) (car region) "{=="))
       (t (redline--tx-edit tx (point) (point) (redline--inline-comment tx id text))))
      (deactivate-mark)
      (redline--tx-commit tx))))

(defun redline--inline-comment (tx id text)
  "Return the inline comment ID with TEXT, recording its metadata in TX.
Text with a line break goes to the endmatter body."
  (let ((multiline (string-search "\n" text)))
    (apply #'redline--tx-put tx "comments" id
           "by" redline-author "at" (redline--now)
           (and multiline (list "body" text)))
    (format "{>>%s<<}{#%s}" (if multiline "" text) id)))

(defun redline-reply ()
  "Reply to the review item at point."
  (interactive)
  (redline--call #'redline--reply))

(defun redline--reply (item)
  "Reply to ITEM."
  (let* ((tx (redline--tx-begin))
         (parent (redline--ensure-id tx item))
         (text (redline--read (format "Reply to %s: " parent)))
         (id (redline--next-id tx "c")))
    (redline--check-comment text)
    (redline--tx-put tx "comments" id "body" text "by" redline-author
                     "at" (redline--now) "re" parent)
    (redline--tx-commit tx)))

(defun redline-edit ()
  "Edit the comment at point."
  (interactive)
  (redline--call #'redline--edit))

(defun redline--edit (item)
  "Edit the text of comment ITEM."
  (when (redline-suggestion-p item)
    (user-error "Suggestions are edited by rejecting them and suggesting again"))
  (let* ((tx (redline--tx-begin))
         (text (redline--read "Comment: " (redline-item-body item)))
         (token (redline-item-token item)))
    (redline--check-comment text)
    (if (or (null token) (string-search "\n" text)
            (= (redline-token-body-beg token) (redline-token-body-end token)))
        (let ((id (redline--ensure-id tx item)))
          (when token
            (redline--tx-edit tx (redline-token-body-beg token)
                              (redline-token-body-end token) ""))
          (redline--tx-put tx "comments" id "body" text))
      (redline--tx-edit tx (redline-token-body-beg token) (redline-token-body-end token)
                        text)
      (when (and (eq (redline-token-meta-style token) 'ref)
                 (redline--entry-has-body tx (redline-item-id item)))
        (redline--tx-put tx "comments" (redline-item-id item) "body" text)))
    (redline--tx-commit tx)))

(defun redline--entry-has-body (tx id)
  "Return non-nil if comment ID has a body field in TX's model."
  (let ((fields (redline-endmatter-entry-fields (redline--tx-model tx) "comments" id)))
    (and (listp fields) (assoc "body" fields))))

(defun redline-delete ()
  "Delete the comment at point with its replies."
  (interactive)
  (redline--call #'redline--delete))

(defun redline--delete (item)
  "Delete comment ITEM and its replies."
  (when (redline-suggestion-p item)
    (user-error "Accept or reject a suggestion instead of deleting it"))
  (let* ((tx (redline--tx-begin))
         (doc (redline--tx-doc tx))
         (replies (redline-item-descendants doc item)))
    (when (or (null replies)
              (yes-or-no-p (format "Delete this comment and %d repl%s? "
                                   (length replies)
                                   (if (= (length replies) 1) "y" "ies"))))
      (redline--remove-items tx (cons item replies))
      (redline--tx-commit tx))))

(defun redline--remove-items (tx items)
  "Remove ITEMS from the text and endmatter in TX.
A highlight left without comments is unwrapped."
  (let ((doc (redline--tx-doc tx)))
    (dolist (item items)
      (when-let* ((token (redline-item-token item)))
        (redline--tx-edit tx (redline-token-beg token) (redline-token-end token) ""))
      (when (redline-item-id item)
        (redline--tx-delete tx (redline--section item) (redline-item-id item))))
    (dolist (anchor (delete-dups (delq nil (mapcar #'redline-item-anchor items))))
      (when (and (eq (redline-token-kind anchor) 'highlight)
                 (cl-every (lambda (other)
                             (or (not (eq (redline-item-anchor other) anchor))
                                 (memq other items)))
                           (redline-doc-items doc)))
        (redline--tx-edit tx (redline-token-beg anchor) (redline-token-open-end anchor) "")
        (redline--tx-edit tx (redline-token-body-end anchor)
                          (redline-token-close-end anchor) "")))))

(defun redline-react ()
  "Set or clear your reaction to the comment at point."
  (interactive)
  (redline--call #'redline--react))

(defun redline--react (item)
  "Set or clear the reaction on comment ITEM."
  (when (redline-suggestion-p item)
    (user-error "Reactions apply to comments only"))
  (let* ((tx (redline--tx-begin))
         (choice (completing-read "Reaction: " '("up" "down" "clarify" "none") nil t))
         (id (redline--ensure-id tx item)))
    (redline--tx-put tx "comments" id "reaction"
                     (unless (equal choice "none") choice))
    (redline--tx-commit tx)))

;;;; Resolving

(defun redline-resolve (&optional summary)
  "Mark the thread at point resolved.
With prefix argument SUMMARY, also record a short resolution summary."
  (interactive "P")
  (redline--call (lambda (item) (redline--set-resolved item t summary))))

(defun redline-unresolve ()
  "Mark the thread at point unresolved."
  (interactive)
  (redline--call (lambda (item) (redline--set-resolved item nil nil))))

(defun redline--set-resolved (item resolved summary)
  "Mark the thread of ITEM RESOLVED, asking for a SUMMARY if non-nil."
  (let* ((tx (redline--tx-begin))
         (root (redline-item-root (redline--tx-doc tx) item))
         (text (and resolved summary (redline--read "Resolution: ")))
         (id (redline--ensure-id tx root)))
    (redline--tx-put tx (redline--section root) id
                     "status" (and resolved "resolved")
                     "resolved" (and text (not (string-empty-p text)) text))
    (redline--tx-commit tx)))

(defun redline-remove-resolved ()
  "Delete every resolved comment thread; suggestions are kept."
  (interactive)
  (unless redline-mode (user-error "`redline-mode' is not enabled"))
  (let* ((tx (redline--tx-begin))
         (doc (redline--tx-doc tx))
         (roots (cl-remove-if-not
                 (lambda (item) (redline-item-resolved-p item))
                 (cl-remove-if #'redline-suggestion-p
                               (redline-doc-items doc))))
         (items (delete-dups
                 (mapcan (lambda (root) (cons root (redline-item-descendants doc root)))
                         roots))))
    (cond
     ((null roots) (message "No resolved threads"))
     ((yes-or-no-p (format "Delete %d resolved thread%s? " (length roots)
                           (if (= (length roots) 1) "" "s")))
      (redline--remove-items tx items)
      (redline--tx-commit tx)))))

;;;; Suggestions

(defun redline-suggest-insertion ()
  "Suggest inserting text at point."
  (interactive)
  (unless redline-mode (user-error "`redline-mode' is not enabled"))
  (let ((tx (redline--tx-begin)))
    (redline--check-point (redline--tx-doc tx) (point))
    (let ((text (redline--read "Insert: ")))
      (redline--check-text text)
      (redline--tx-edit tx (point) (point)
                        (format "{++%s++}%s" text (redline--new-suggestion tx)))
      (redline--tx-commit tx))))

(defun redline-suggest-deletion (beg end)
  "Suggest deleting the text from BEG to END."
  (interactive "r")
  (redline--suggest-wrap beg end (lambda (ref) (list "{--" (concat "--}" ref)))))

(defun redline-suggest-replacement (beg end)
  "Suggest replacing the text from BEG to END."
  (interactive "r")
  (let ((new (redline--read "Replace with: ")))
    (redline--check-text new)
    (redline--suggest-wrap beg end
                           (lambda (ref) (list "{~~" (concat "~>" new "~~}" ref))))))

(defun redline--suggest-wrap (beg end delimiters)
  "Wrap BEG..END in the pair of strings DELIMITERS gives a new reference."
  (unless redline-mode (user-error "`redline-mode' is not enabled"))
  (unless (use-region-p) (user-error "No active region"))
  (let ((tx (redline--tx-begin)))
    (redline--check-region (redline--tx-doc tx) beg end)
    (let ((strings (funcall delimiters (redline--new-suggestion tx))))
      (redline--tx-edit tx end end (nth 1 strings))
      (redline--tx-edit tx beg beg (nth 0 strings))
      (deactivate-mark)
      (redline--tx-commit tx))))

(defun redline--new-suggestion (tx)
  "Record a new suggestion entry in TX and return its reference."
  (let ((id (redline--next-id tx "s")))
    (redline--tx-put tx "suggestions" id "by" redline-author "at" (redline--now))
    (format "{#%s}" id)))

(defun redline-accept ()
  "Accept the suggestion at point."
  (interactive)
  (redline--call (lambda (item) (redline--settle (list item) t))))

(defun redline-reject ()
  "Reject the suggestion at point."
  (interactive)
  (redline--call (lambda (item) (redline--settle (list item) nil))))

(defun redline-accept-all ()
  "Accept every suggestion in the buffer."
  (interactive)
  (redline--settle-all t))

(defun redline-reject-all ()
  "Reject every suggestion in the buffer."
  (interactive)
  (redline--settle-all nil))

(defun redline--settle-all (accept)
  "Accept every suggestion if ACCEPT is non-nil, else reject them all."
  (unless redline-mode (user-error "`redline-mode' is not enabled"))
  (let ((suggestions (cl-remove-if-not #'redline-suggestion-p
                                       (redline-doc-items (redline-doc)))))
    (cond
     ((null suggestions) (message "No suggestions"))
     ((yes-or-no-p (format "%s %d suggestion%s? " (if accept "Accept" "Reject")
                           (length suggestions)
                           (if (= (length suggestions) 1) "" "s")))
      (redline--settle suggestions accept)))))

(defun redline--settle (items accept)
  "Accept the suggestions ITEMS if ACCEPT is non-nil, else reject them.
Comments on a suggestion are removed with it."
  (let* ((tx (redline--tx-begin))
         (doc (redline--tx-doc tx))
         (suggestions (mapcar (lambda (item)
                                (let ((root (redline-item-root doc item)))
                                  (unless (redline-suggestion-p root)
                                    (user-error "No suggestion at point"))
                                  root))
                              items)))
    (dolist (item (delete-dups suggestions))
      (let* ((token (redline-item-token item))
             (comments (redline-item-descendants doc item))
             (end (apply #'max (redline-token-end token)
                         (mapcar (lambda (comment)
                                   (if (eq (redline-item-anchor comment) token)
                                       (redline-token-end (redline-item-token comment))
                                     0))
                                 comments))))
        (redline--tx-edit tx (redline-token-beg token) end
                          (redline--settled-text token accept))
        (when (redline-item-id item)
          (redline--tx-delete tx "suggestions" (redline-item-id item)))
        (dolist (comment comments)
          (unless (eq (redline-item-anchor comment) token)
            (when-let* ((other (redline-item-token comment)))
              (redline--tx-edit tx (redline-token-beg other) (redline-token-end other) "")))
          (when (redline-item-id comment)
            (redline--tx-delete tx "comments" (redline-item-id comment))))))
    (redline--tx-commit tx)))

(defun redline--settled-text (token accept)
  "Return the text left by suggestion TOKEN once settled.
The suggestion is accepted if ACCEPT is non-nil, else rejected."
  (cl-flet ((text (beg end) (buffer-substring-no-properties beg end)))
    (let ((body (text (redline-token-body-beg token) (redline-token-body-end token))))
      (pcase (redline-token-kind token)
        ('addition (if accept body ""))
        ('deletion (if accept "" body))
        ('substitution
         (if accept
             (text (redline-token-new-beg token) (redline-token-new-end token))
           body))))))

;;;; Navigation

(defun redline-next (&optional unresolved)
  "Move to the next review item.
With UNRESOLVED non-nil, skip resolved threads."
  (interactive)
  (redline--move #'> unresolved))

(defun redline-previous (&optional unresolved)
  "Move to the previous review item.
With UNRESOLVED non-nil, skip resolved threads."
  (interactive)
  (redline--move #'< unresolved))

(defun redline-next-unresolved ()
  "Move to the next unresolved review item."
  (interactive)
  (redline-next t))

(defun redline-previous-unresolved ()
  "Move to the previous unresolved review item."
  (interactive)
  (redline-previous t))

(defun redline--move (direction unresolved)
  "Move to the nearest item position in DIRECTION, `>' or `<'.
With UNRESOLVED non-nil, skip resolved threads."
  (let* ((doc (redline-doc))
         (positions (sort (delete-dups (redline--item-positions doc unresolved))
                          (if (eq direction #'>) #'< #'>)))
         (target (cl-find-if (lambda (pos) (funcall direction pos (point))) positions)))
    (if target
        (goto-char target)
      (user-error "No %s review item" (if (eq direction #'>) "next" "previous")))))

(defun redline--item-positions (doc unresolved)
  "Return the start positions of DOC's inline items.
A comment's position is its anchor's start.  With UNRESOLVED non-nil,
leave out resolved threads."
  (delq nil
        (mapcar (lambda (item)
                  (when-let* ((token (or (redline-item-anchor item)
                                         (redline-item-token item)))
                              ((not (and unresolved
                                         (redline-item-resolved-p
                                          (redline-item-root doc item))))))
                    (redline-token-beg token)))
                (redline-doc-items doc))))

;;;; Thread window

(defun redline--thread-buffer-name (buffer)
  "Return the name of the thread buffer for BUFFER."
  (format "*redline: %s*" (buffer-name buffer)))

(defun redline-show-thread ()
  "Show the thread at point in a side window that follows point."
  (interactive)
  (unless redline-mode (user-error "`redline-mode' is not enabled"))
  (let ((buffer (get-buffer-create (redline--thread-buffer-name (current-buffer))))
        (source (current-buffer)))
    (with-current-buffer buffer
      (redline-thread-mode)
      (setq redline--source-buffer source))
    (display-buffer buffer '(display-buffer-in-side-window
                             (side . right) (window-width . 0.35)))
    (redline--render-thread buffer (ignore-errors (redline--item-at-point)))))

(defvar-local redline--thread-root nil
  "In a thread buffer, the key of the root shown.")

(defun redline--follow-thread ()
  "Show the thread at point in the visible thread window, if any."
  (when-let* ((buffer (get-buffer (redline--thread-buffer-name (current-buffer))))
              ((get-buffer-window buffer))
              ((and redline--doc (eql (redline-doc-tick redline--doc)
                                      (buffer-chars-modified-tick))))
              (item (ignore-errors (redline--item-at-point))))
    (let ((key (redline--item-key (redline-item-root redline--doc item))))
      (unless (equal key (buffer-local-value 'redline--thread-root buffer))
        (redline--render-thread buffer item)))))

(defun redline--render-thread (buffer item)
  "Render the thread of ITEM, from the current buffer, in BUFFER."
  (let* ((doc (redline-doc))
         (root (and item (redline-item-root doc item)))
         (entries (and root (redline--thread-entries doc root 0)))
         (tick (buffer-chars-modified-tick)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq redline--source-tick tick
              redline--thread-root (and root (redline--item-key root)))
        (if root
            (mapc #'redline--insert-entry entries)
          (insert (propertize "No review item at point." 'face 'shadow)))
        (goto-char (point-min))))))

(defun redline--thread-entries (doc item depth)
  "Return the thread entries for ITEM of DOC and its replies at DEPTH.
Each entry is (ITEM DEPTH TEXT ANCHOR-TEXT), with texts read from the
current buffer."
  (cons (list item depth (redline--entry-text item)
              (and (= depth 0) (redline-item-anchor item)
                   (redline--token-text (redline-item-anchor item))))
        (mapcan (lambda (child) (redline--thread-entries doc child (1+ depth)))
                (redline-item-children doc item))))

(defun redline--insert-entry (entry)
  "Insert thread ENTRY, as returned by `redline--thread-entries'."
  (pcase-let* ((`(,item ,depth ,text ,anchor) entry)
               (start (point))
               (indent (make-string (* 2 depth) ?\s)))
    (when anchor
      (insert (propertize (format "“%s”\n\n" anchor) 'face 'redline-highlight)))
    (insert indent
            (propertize (format "%s  %s  %s" (or (redline-item-id item) "—")
                                (or (redline-item-by item) "?")
                                (redline--format-time (redline-item-at item)))
                        'face 'bold)
            (if (redline-item-resolved-p item)
                (propertize "  resolved" 'face 'redline-resolved)
              "")
            (if (redline-item-reaction item)
                (format "  [%s]" (redline-item-reaction item))
              "")
            "\n")
    (insert (redline--indent-lines text (concat indent "  ")) "\n")
    (when (redline-item-resolved item)
      (insert indent "  " (propertize (concat "Resolution: " (redline-item-resolved item))
                                      'face 'redline-resolved)
              "\n"))
    (insert "\n")
    (put-text-property start (point) 'redline-key (redline--item-key item))))

(defun redline--entry-text (item)
  "Return the text shown for ITEM in a thread."
  (let ((token (redline-item-token item)))
    (pcase (redline-item-kind item)
      ('addition (concat "Insert: " (redline--token-text token)))
      ('deletion (concat "Delete: " (redline--token-text token)))
      ('substitution
       (format "Replace: %s → %s" (redline--token-text token)
               (buffer-substring-no-properties (redline-token-new-beg token)
                                               (redline-token-new-end token))))
      (_ (concat (if (eq (redline-item-scope item) 'document) "(document) " "")
                 (or (redline-item-body item) ""))))))

(defun redline--token-text (token)
  "Return the body text of TOKEN."
  (buffer-substring-no-properties (redline-token-body-beg token)
                                  (redline-token-body-end token)))

(defun redline--indent-lines (text indent)
  "Return TEXT with each line prefixed by INDENT."
  (mapconcat (lambda (line) (concat indent line)) (split-string text "\n") "\n"))

(defun redline--format-time (time)
  "Return ISO TIME shortened for display, or an empty string."
  (if (and time (string-match "\\`\\([0-9-]+\\)T\\([0-9]+:[0-9]+\\)" time))
      (format "%s %s" (match-string 1 time) (match-string 2 time))
    (or time "")))

(defvar-keymap redline-view-mode-map
  :doc "Keymap shared by redline thread and list buffers."
  :parent special-mode-map
  "RET" #'redline-goto
  "r" #'redline-reply
  "e" #'redline-edit
  "d" #'redline-delete
  "a" #'redline-accept
  "x" #'redline-reject
  "R" #'redline-resolve
  "U" #'redline-unresolve
  "+" #'redline-react
  "g" #'redline-view-refresh)

(defvar-keymap redline-thread-mode-map
  :doc "Keymap for `redline-thread-mode'."
  :parent redline-view-mode-map)

(define-derived-mode redline-thread-mode special-mode "Redline Thread"
  "Major mode for a redline thread.
\\{redline-thread-mode-map}"
  (setq-local truncate-lines nil)
  (visual-line-mode 1))

(defun redline-goto ()
  "Jump to the review item on this line in the reviewed buffer."
  (interactive)
  (let ((key (get-text-property (point) 'redline-key))
        (source redline--source-buffer))
    (unless key (user-error "No review item on this line"))
    (pop-to-buffer source)
    (let* ((item (redline--item-from-key key))
           (token (or (redline-item-anchor (redline-item-root (redline-doc) item))
                      (redline-item-token (redline-item-root (redline-doc) item)))))
      (if token
          (goto-char (redline-token-beg token))
        (message "This comment applies to the whole document")))))

(defun redline-view-refresh ()
  "Redraw the current thread or list buffer."
  (interactive)
  (when (buffer-live-p redline--source-buffer)
    (with-current-buffer redline--source-buffer
      (redline--update-views))))

(defun redline--update-views ()
  "Redraw the thread and list buffers of the current buffer."
  (let ((source (current-buffer)))
    (when-let* ((buffer (get-buffer (redline--thread-buffer-name source))))
      (let ((key (buffer-local-value 'redline--thread-root buffer)))
        (redline--render-thread
         buffer (or (and key (ignore-errors (redline--item-from-key key)))
                    (ignore-errors (redline--item-at-point))))))
    (when-let* ((buffer (get-buffer (redline--list-buffer-name source))))
      (redline--render-list buffer source))))

;;;; List buffer

(defun redline--list-buffer-name (buffer)
  "Return the name of the list buffer for BUFFER."
  (format "*redline list: %s*" (buffer-name buffer)))

(defvar-keymap redline-list-mode-map
  :doc "Keymap for `redline-list-mode'."
  :parent (make-composed-keymap redline-view-mode-map tabulated-list-mode-map))

(define-derived-mode redline-list-mode tabulated-list-mode "Redline List"
  "Major mode listing the review threads of a buffer.
\\{redline-list-mode-map}"
  (setq tabulated-list-format [("Id" 6 t) ("Kind" 12 t) ("By" 8 t)
                               ("Status" 9 t) ("Replies" 7 t) ("Text" 0 nil)])
  (tabulated-list-init-header))

(defun redline-list ()
  "List the review threads of the current buffer."
  (interactive)
  (unless redline-mode (user-error "`redline-mode' is not enabled"))
  (let ((buffer (get-buffer-create (redline--list-buffer-name (current-buffer))))
        (source (current-buffer)))
    (with-current-buffer buffer
      (redline-list-mode)
      (setq redline--source-buffer source))
    (redline--render-list buffer source)
    (pop-to-buffer buffer)))

(defun redline--render-list (buffer source)
  "Fill list BUFFER with the threads of SOURCE."
  (let* ((doc (with-current-buffer source (redline-doc)))
         (tick (with-current-buffer source (buffer-chars-modified-tick)))
         (entries (with-current-buffer source
                    (mapcar (lambda (root) (redline--list-entry doc root))
                            (redline-thread-roots doc)))))
    (with-current-buffer buffer
      (setq redline--source-tick tick
            tabulated-list-entries entries)
      (tabulated-list-print t)
      (redline--propertize-list-keys))))

(defun redline--list-entry (doc root)
  "Return the tabulated list entry for thread ROOT of DOC."
  (list (redline--item-key root)
        (vector (or (redline-item-id root) "—")
                (if (eq (redline-item-scope root) 'document)
                    "document"
                  (symbol-name (redline-item-kind root)))
                (or (redline-item-by root) "?")
                (if (redline-item-resolved-p root) "resolved" "open")
                (number-to-string (length (redline-item-descendants doc root)))
                (truncate-string-to-width
                 (replace-regexp-in-string "\n" " " (redline--entry-text root))
                 80 nil nil "…"))))

(defun redline--propertize-list-keys ()
  "Copy each tabulated list entry's id to a `redline-key' property."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((id (tabulated-list-get-id)))
          (put-text-property (line-beginning-position) (line-end-position)
                             'redline-key id))
        (forward-line 1)))))

;;;; Agent hand-off

(defun redline-send-to-agent ()
  "Save the buffer and hand it to an AI agent to answer the review.
Use `redline-send-function', or copy the prompt when it is nil."
  (interactive)
  (unless buffer-file-name (user-error "The buffer is not visiting a file"))
  (save-buffer)
  (let ((prompt (redline-agent-prompt buffer-file-name
                                      (redline-adapter-name (redline-adapter)))))
    (if redline-send-function
        (funcall redline-send-function buffer-file-name prompt)
      (kill-new prompt)
      (message "Agent prompt copied to the kill ring"))))

(defun redline-agent-prompt (file format)
  "Return the prompt asking an agent to answer the review in FILE.
FORMAT is the adapter name, such as `markdown' or `org'."
  (concat
   (format "Please answer the open review threads in %s.\n\n" file)
   (if (eq format 'org)
       (format "The file is Org and uses redline's Org variant of Roughdraft Flavored Markdown 0.2 (%s): the same CriticMarkup comments and suggestions with compact {#id} references, but the YAML endmatter lives in a final `#+begin_comment redline' ... `#+end_comment' block instead of after a `---' line, and YAML lines starting with `*' or `#+' are comma-escaped as in Org source blocks.\n\n"
               redline-spec-url)
     (format "It uses Roughdraft Flavored Markdown 0.2 (%s): CriticMarkup comments and suggestions with compact {#id} references and a final YAML endmatter block.\n\n"
             redline-spec-url))
   "Reply to each open thread by adding an entry under `comments' in the endmatter, with `body', `by: AI', `at' (ISO 8601 UTC) and `re' set to the id you answer. Use the next free id (c1, c2, ...). Do not accept, reject or apply suggestions, and do not change the prose, unless a comment asks you to."))

(provide 'redline)
;;; redline.el ends here
