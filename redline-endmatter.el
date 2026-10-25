;;; redline-endmatter.el --- Read and write review endmatter -*- lexical-binding: t; -*-

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

;; The review endmatter is a YAML map with `comments' and `suggestions'
;; sections.  Reading uses the `yaml' package.  Writing uses an editable
;; model built from the block-style source: known fields are re-emitted
;; from their values, and anything else keeps its original source text,
;; so values this package does not understand survive an edit.  When
;; the source cannot be split this way, the model is nil and the
;; endmatter is read-only.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'yaml)

(cl-defstruct (redline-endmatter (:constructor redline-endmatter-create)
                                 (:copier nil))
  "Review endmatter located in a buffer.
BEG and END delimit the whole block.  DATA is the parsed YAML as an
alist with string keys.  MODEL is the editable model, or nil when the
source is not in a form this package can rewrite safely."
  beg end data model)

(defconst redline-endmatter-known-fields
  '("body" "by" "at" "re" "status" "resolved" "reaction")
  "Entry fields whose values this package reads and writes.")

(defconst redline-endmatter-sections '("comments" "suggestions")
  "The review sections of the endmatter, in writing order.")

;;;; Reading

(defun redline-endmatter-read (yaml beg end)
  "Return a `redline-endmatter' for YAML found between BEG and END.
Return nil unless YAML parses as a map with a review section."
  (when-let* ((data (redline-endmatter--parse yaml))
              ((consp data))
              ((cl-every #'consp data))
              ((cl-some (lambda (section)
                          (let ((cell (assoc section data)))
                            (and cell (redline-endmatter--map-p (cdr cell)))))
                        redline-endmatter-sections)))
    (redline-endmatter-create :beg beg :end end :data data
                              :model (redline-endmatter--segment yaml))))

(defun redline-endmatter--parse (yaml)
  "Parse YAML into an alist, or return nil if it is not valid."
  (condition-case nil
      (yaml-parse-string yaml :object-type 'alist :object-key-type 'string
                         :sequence-type 'list :string-values t
                         :null-object nil :false-object nil)
    (error nil)))

(defun redline-endmatter-section (endmatter name)
  "Return section NAME of ENDMATTER as an alist of (ID . FIELDS).
Entries whose value is not a map are left out.  Known fields are read
from the model when there is one, since it decodes quoted strings
correctly."
  (when endmatter
    (let ((section (cdr (assoc name (redline-endmatter-data endmatter))))
          (model (redline-endmatter-model endmatter)))
      (and (redline-endmatter--map-p section)
           (mapcar (lambda (entry)
                     (cons (car entry)
                           (redline-endmatter--entry-values model name entry)))
                   (cl-remove-if-not (lambda (entry)
                                       (and (stringp (car entry))
                                            (redline-endmatter--map-p (cdr entry))))
                                     section))))))

(defun redline-endmatter--map-p (value)
  "Return non-nil if VALUE is a parsed YAML map, possibly empty."
  (and (listp value) (cl-every #'consp value)))

(defun redline-endmatter--entry-values (model section entry)
  "Return the fields of ENTRY, preferring decoded values from MODEL.
SECTION names the section ENTRY belongs to."
  (let ((fields (redline-endmatter-entry-fields model section (car entry))))
    (if (and fields (listp fields))
        (append (delq nil (mapcar (lambda (field)
                                    (when (eq (nth 1 field) :value)
                                      (cons (car field) (nth 2 field))))
                                  fields))
                (cl-remove-if (lambda (cell)
                                (cl-find (car cell) fields :key #'car :test #'equal))
                              (cdr entry)))
      (cdr entry))))

;;;; Segmenting source into a model

;; The model is a list of top-level segments.  A segment is
;; (KEY :raw TEXT) or, for a review section, (KEY :map ENTRIES).  An
;; entry is (ID :raw TEXT) or (ID :fields FIELDS), and a field is
;; (KEY :value STRING) or (KEY :raw TEXT).  Raw TEXT starts at column 0.

(defconst redline-endmatter--key-regexp
  "\\`\\([^-?:,[{}#&*!|>'\"%@` \t][^:\n]*?\\|\"[^\"\n]*\"\\):\\(?:[ \t]+\\(.*\\)\\)?\\'"
  "Regexp matching a block mapping key line, without indentation.")

(defun redline-endmatter--segment (yaml)
  "Return the editable model of YAML, or nil if it cannot be built."
  (catch 'redline-endmatter--unsegmentable
    (let ((groups (redline-endmatter--groups
                   (split-string (string-trim-right yaml "\n+") "\n") 0)))
      (mapcar #'redline-endmatter--top-segment groups))))

(defun redline-endmatter--fail ()
  "Abandon segmentation."
  (throw 'redline-endmatter--unsegmentable nil))

(defun redline-endmatter--indent (line)
  "Return the indentation of LINE, failing on tabs in it."
  (string-match "\\`\\([ \t]*\\)" line)
  (let ((indent (match-string 1 line)))
    (when (string-search "\t" indent)
      (redline-endmatter--fail))
    (length indent)))

(defun redline-endmatter--blank-p (line)
  "Return non-nil if LINE is blank."
  (string-match-p "\\`[ \t]*\\'" line))

(defun redline-endmatter--groups (lines indent)
  "Split LINES into key groups at INDENT.
Each group is (KEY VALUE BODY) where BODY lists the continuation lines,
dedented by INDENT."
  (let (groups current)
    (dolist (line lines)
      (cond
       ((redline-endmatter--blank-p line)
        (when current (push "" (nth 2 current))))
       ((= (redline-endmatter--indent line) indent)
        (let ((text (substring line indent)))
          (unless (string-match redline-endmatter--key-regexp text)
            (redline-endmatter--fail))
          (when current (push current groups))
          (setq current (list (redline-endmatter--key (match-string 1 text))
                              (match-string 2 text) nil text))))
       ((and current (> (redline-endmatter--indent line) indent))
        (push (substring line indent) (nth 2 current)))
       (t (redline-endmatter--fail))))
    (when current (push current groups))
    (mapcar (lambda (group)
              (list (nth 0 group) (nth 1 group)
                    (redline-endmatter--trim-blank (reverse (nth 2 group)))
                    (nth 3 group)))
            (nreverse groups))))

(defun redline-endmatter--key (text)
  "Return the key named by TEXT, unquoting it."
  (if (string-prefix-p "\"" text) (substring text 1 -1) text))

(defun redline-endmatter--trim-blank (lines)
  "Drop trailing blank strings from LINES."
  (let ((reversed (reverse lines)))
    (while (and reversed (string-empty-p (car reversed)))
      (pop reversed))
    (nreverse reversed)))

(defun redline-endmatter--raw (group)
  "Return the raw source of GROUP, a key group."
  (string-join (cons (nth 3 group) (nth 2 group)) "\n"))

(defun redline-endmatter--empty-map-p (value)
  "Return non-nil if VALUE, a key line's value, denotes an empty map."
  (or (null value) (string-match-p "\\`[ \t]*\\({[ \t]*}\\)?[ \t]*\\'" value)))

(defun redline-endmatter--top-segment (group)
  "Return the model segment for top-level GROUP."
  (let ((key (car group)))
    (if (member key redline-endmatter-sections)
        (progn
          (unless (redline-endmatter--empty-map-p (nth 1 group))
            (redline-endmatter--fail))
          (list key :map (redline-endmatter--entries (nth 2 group))))
      (list key :raw (redline-endmatter--raw group)))))

(defun redline-endmatter--entries (lines)
  "Return the model entries for section body LINES."
  (when-let* ((first (cl-find-if-not #'redline-endmatter--blank-p lines)))
    (mapcar #'redline-endmatter--entry
            (redline-endmatter--groups lines (redline-endmatter--indent first)))))

(defun redline-endmatter--entry (group)
  "Return the model entry for entry GROUP."
  (let ((fields (and (redline-endmatter--empty-map-p (nth 1 group))
                     (catch 'redline-endmatter--unsegmentable
                       (list (redline-endmatter--fields (nth 2 group)))))))
    (if fields
        (list (car group) :fields (car fields))
      (list (car group) :raw (redline-endmatter--raw group)))))

(defun redline-endmatter--fields (lines)
  "Return the model fields for entry body LINES."
  (when-let* ((first (cl-find-if-not #'redline-endmatter--blank-p lines)))
    (mapcar #'redline-endmatter--field
            (redline-endmatter--groups lines (redline-endmatter--indent first)))))

(defun redline-endmatter--field (group)
  "Return the model field for field GROUP."
  (let* ((raw (redline-endmatter--raw group))
         (value (and (member (car group) redline-endmatter-known-fields)
                     (redline-endmatter--field-value group raw))))
    (if (stringp value)
        (list (car group) :value value)
      (list (car group) :raw raw))))

(defun redline-endmatter--field-value (group raw)
  "Return the string value of field GROUP whose source is RAW, or nil.
Double-quoted scalars are decoded here, because the `yaml' package
mishandles some of their escapes."
  (let ((value (or (nth 1 group) "")))
    (if (string-prefix-p "\"" value)
        (redline-endmatter--double-quoted
         (string-join (cons value (nth 2 group)) "\n"))
      (let ((parsed (cdr (assoc (car group) (redline-endmatter--parse raw)))))
        (and (stringp parsed) parsed)))))

(defun redline-endmatter--double-quoted (text)
  "Decode TEXT, a double-quoted YAML scalar, or return nil if malformed."
  (when-let* ((close (redline-endmatter--closing-quote text))
              ((string-match-p "\\`[ \t]*\\(?:#.*\\)?\\'"
                               (replace-regexp-in-string "\n" " "
                                                         (substring text (1+ close))))))
    (redline-endmatter--unescape
     (redline-endmatter--fold (substring text 1 close)))))

(defun redline-endmatter--closing-quote (text)
  "Return the index of the quote closing the scalar that opens TEXT."
  (let ((index 1) close)
    (while (and (not close) (< index (length text)))
      (pcase (aref text index)
        (?\\ (setq index (+ index 2)))
        (?\" (setq close index))
        (_ (setq index (1+ index)))))
    close))

(defun redline-endmatter--fold (content)
  "Apply YAML double-quoted line folding to CONTENT."
  (let* ((lines (split-string content "\n"))
         (result (car lines))
         (blank 0))
    (dolist (line (cdr lines))
      (let ((trimmed (string-trim-left line "[ \t]+")))
        (if (string-empty-p (string-trim trimmed))
            (setq blank (1+ blank))
          (setq result
                (cond
                 ((redline-endmatter--escaped-break-p result)
                  (concat (substring result 0 -1) trimmed))
                 ((> blank 0)
                  (concat (string-trim-right result "[ \t]+")
                          (make-string blank ?\n) trimmed))
                 (t (concat (string-trim-right result "[ \t]+") " " trimmed)))
                blank 0))))
    (concat result (make-string blank ?\n))))

(defun redline-endmatter--escaped-break-p (text)
  "Return non-nil if TEXT ends with an odd number of backslashes."
  (and (string-match "\\(\\\\+\\)\\'" text)
       (cl-oddp (length (match-string 1 text)))))

(defconst redline-endmatter--escapes
  '((?0 . "\0") (?a . "\a") (?b . "\b") (?t . "\t") (?\t . "\t")
    (?n . "\n") (?v . "\v") (?f . "\f") (?r . "\r") (?e . "\e")
    (?\s . " ") (?\" . "\"") (?/ . "/") (?\\ . "\\")
    (?N . "\u0085") (?_ . "\u00a0") (?L . "\u2028") (?P . "\u2029"))
  "Single-character YAML escapes and their meanings.")

(defun redline-endmatter--unescape (text)
  "Replace the YAML escape sequences in TEXT."
  (replace-regexp-in-string
   "\\\\\\(x[0-9a-fA-F]\\{2\\}\\|u[0-9a-fA-F]\\{4\\}\\|U[0-9a-fA-F]\\{8\\}\\|.\\)"
   (lambda (match)
     (let ((code (substring match 1)))
       (if (> (length code) 1)
           (string (string-to-number (substring code 1) 16))
         (or (cdr (assq (aref code 0) redline-endmatter--escapes)) match))))
   text t t))

;;;; Editing the model

(defun redline-endmatter-editable-model (endmatter)
  "Return a fresh editable copy of ENDMATTER's model.
A nil ENDMATTER gives an empty model.  Signal an error when the
endmatter exists but cannot be rewritten safely."
  (cond ((null endmatter) nil)
        ((redline-endmatter-model endmatter)
         (copy-tree (redline-endmatter-model endmatter)))
        (t (user-error "The review endmatter is not in a form redline can rewrite; edit it by hand"))))

(defun redline-endmatter--section-cell (model section create)
  "Return the segment of MODEL for SECTION.
When CREATE is non-nil, add a missing section and return (MODEL
. SEGMENT); otherwise return the segment or nil."
  (let ((segment (assoc section model)))
    (cond
     (segment (if create (cons model segment) segment))
     ((not create) nil)
     (t (let ((new (list section :map nil)))
          (cons (if (equal section "comments")
                    (cons new model)
                  (append model (list new)))
                new))))))

(defun redline-endmatter-ids (model section)
  "Return the entry ids in SECTION of MODEL."
  (mapcar #'car (nth 2 (assoc section model))))

(defun redline-endmatter-entry-fields (model section id)
  "Return the fields of entry ID in SECTION of MODEL, or nil.
Return the symbol `raw' when the entry cannot be edited."
  (when-let* ((entry (assoc id (nth 2 (assoc section model)))))
    (if (eq (nth 1 entry) :raw) 'raw (nth 2 entry))))

(defun redline-endmatter-put (model section id key value)
  "Set KEY to VALUE in entry ID of SECTION in MODEL and return MODEL.
Create the section and entry when missing.  A nil VALUE removes KEY."
  (pcase-let* ((`(,model . ,segment)
                (redline-endmatter--section-cell model section t))
               (entry (or (assoc id (nth 2 segment))
                          (let ((new (list id :fields nil)))
                            (setf (nth 2 segment) (append (nth 2 segment) (list new)))
                            new))))
    (when (eq (nth 1 entry) :raw)
      (user-error "Endmatter entry %s is not in a form redline can rewrite" id))
    (let ((field (assoc key (nth 2 entry))))
      (cond ((null value)
             (setf (nth 2 entry) (delq field (nth 2 entry))))
            (field (setf (cdr field) (list :value value)))
            (t (setf (nth 2 entry)
                     (append (nth 2 entry) (list (list key :value value)))))))
    model))

(defun redline-endmatter-delete (model section id)
  "Remove entry ID from SECTION of MODEL and return MODEL."
  (when-let* ((segment (assoc section model)))
    (setf (nth 2 segment) (cl-remove id (nth 2 segment) :key #'car :test #'equal)))
  model)

;;;; Writing

(defun redline-endmatter-serialize (model)
  "Return the YAML text of MODEL, or nil when MODEL is empty."
  (let ((parts (delq nil (mapcar #'redline-endmatter--serialize-segment model))))
    (when parts
      (concat (string-join parts "\n") "\n"))))

(defun redline-endmatter--serialize-segment (segment)
  "Return the YAML text of top-level SEGMENT, or nil if it is empty."
  (pcase segment
    (`(,_ :raw ,text) text)
    (`(,_ :map nil) nil)
    (`(,key :map ,entries)
     (concat (redline-endmatter--key-text key) ":\n"
             (string-join (mapcar #'redline-endmatter--serialize-entry entries)
                          "\n")))))

(defun redline-endmatter--serialize-entry (entry)
  "Return the YAML text of section ENTRY, indented for its section."
  (pcase entry
    (`(,_ :raw ,text) (redline-endmatter--indent-text text 2))
    (`(,id :fields nil) (concat "  " (redline-endmatter--key-text id) ": {}"))
    (`(,id :fields ,fields)
     (concat "  " (redline-endmatter--key-text id) ":\n"
             (string-join (mapcar #'redline-endmatter--serialize-field fields)
                          "\n")))))

(defun redline-endmatter--serialize-field (field)
  "Return the YAML text of entry FIELD, indented for its entry."
  (pcase field
    (`(,_ :raw ,text) (redline-endmatter--indent-text text 4))
    (`(,key :value ,value)
     (concat "    " (redline-endmatter--key-text key) ": "
             (redline-endmatter-scalar value 6)))))

(defun redline-endmatter--key-text (key)
  "Return KEY as it should appear before a colon."
  (if (string-match-p "\\`[A-Za-z0-9_][A-Za-z0-9_.-]*\\'" key)
      key
    (redline-endmatter--quote key)))

(defun redline-endmatter--indent-text (text indent)
  "Return TEXT with every non-empty line indented by INDENT spaces."
  (let ((prefix (make-string indent ?\s)))
    (mapconcat (lambda (line) (if (string-empty-p line) line (concat prefix line)))
               (split-string text "\n") "\n")))

(defconst redline-endmatter--plain-regexp
  "\\`[A-Za-z_][A-Za-z0-9_ .,'!?()/-]*\\'"
  "Regexp matching strings that can be written as plain scalars.")

(defconst redline-endmatter--reserved-regexp
  "\\`\\(?:true\\|false\\|yes\\|no\\|on\\|off\\|null\\|y\\|n\\)\\'"
  "Regexp matching plain words YAML could read as non-strings.")

(defun redline-endmatter-scalar (value indent)
  "Return VALUE as a YAML scalar for a field whose body is at INDENT."
  (cond
   ((and (string-search "\n" value)
         (not (string-suffix-p "\n" value))
         (not (string-match-p "\\`[ \t\n]" value))
         (not (string-match-p "[\r\t]" value)))
    (concat "|-\n" (redline-endmatter--indent-text value indent)))
   ((and (string-match-p redline-endmatter--plain-regexp value)
         (not (string-suffix-p " " value))
         (not (string-match-p redline-endmatter--reserved-regexp (downcase value))))
    value)
   (t (redline-endmatter--quote value))))

(defun redline-endmatter--quote (value)
  "Return VALUE as a double-quoted YAML scalar."
  (concat "\""
          (replace-regexp-in-string
           "[\\\"\n\t\r]"
           (lambda (char)
             (pcase char
               ("\\" "\\\\") ("\"" "\\\"") ("\n" "\\n")
               ("\t" "\\t") ("\r" "\\r")))
           value t t)
          "\""))

(provide 'redline-endmatter)
;;; redline-endmatter.el ends here
