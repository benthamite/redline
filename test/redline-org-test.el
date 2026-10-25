;;; redline-org-test.el --- Org adapter tests for redline -*- lexical-binding: t; -*-

;;; Commentary:

;; CriticMarkup against Org emphasis, literal Org contexts, the comment
;; block container and export.

;;; Code:

(require 'redline-test-helpers)
(require 'ox-ascii)
(require 'ox-html)

(defun redline-org-test-kinds (text)
  "Return the token kinds of TEXT parsed as Org."
  (with-temp-buffer
    (insert text)
    (mapcar #'redline-token-kind
            (redline-doc-tokens (redline-parse redline-org-adapter)))))

(ert-deftest redline-org-markup-beats-emphasis ()
  (should (equal (redline-org-test-kinds "A {==x==}{>>c<<} b.\n") '(highlight comment)))
  (should (equal (redline-org-test-kinds "A {++x++} b.\n") '(addition)))
  (should (equal (redline-org-test-kinds "A {~~a~>b~~} c.\n") '(substitution)))
  (should (equal (redline-org-test-kinds "=v= then {++x++} and ~c~.\n") '(addition))))

(ert-deftest redline-org-open-literal-suppresses-markup ()
  (should-not (redline-org-test-kinds "Use ={++x++}= literally.\n"))
  (should-not (redline-org-test-kinds "Use ~{==x==}~ literally.\n"))
  (should-not (redline-org-test-kinds "Write =a {--b--} c= here.\n")))

(ert-deftest redline-org-literal-contexts ()
  (should-not (redline-org-test-kinds
               (concat "#+begin_src emacs-lisp\n\"{++x++}\"\n#+end_src\n"
                       "#+BEGIN_EXAMPLE\n{--y--}\n#+END_EXAMPLE\n"
                       ": {==fixed==}\n"
                       "#+title: {++kw++}\n"
                       "# {++comment line++}\n"
                       ":PROPERTIES:\n:note: {++p++}\n:END:\n"
                       "Inline src_emacs-lisp{\"{++s++}\"} here.\n")))
  (should (equal (redline-org-test-kinds "#+begin_quote\n{++q++}\n#+end_quote\n")
                 '(addition))))

(ert-deftest redline-org-endmatter-block ()
  (let* ((text (concat "A {==b==}{>>c<<}{#c1} d.\n\n#+begin_comment redline\n"
                       "comments:\n  c1:\n    by: user\n    at: \"t\"\n#+end_comment\n"))
         (doc (with-temp-buffer
                (insert text)
                (redline-parse redline-org-adapter))))
    (should (redline-doc-endmatter doc))
    (should (equal (redline-item-by (car (redline-doc-items doc))) "user"))))

(ert-deftest redline-org-comment-command-writes-block ()
  (redline-test-with-buffer #'org-mode "* Heading\nSome text here.\n"
    (redline-test-select "text")
    (redline-test-with-input '("Note")
      (redline-comment))
    (should (equal (buffer-string)
                   (concat "* Heading\nSome {==text==}{>>Note<<}{#c1} here.\n\n"
                           "#+begin_comment redline\ncomments:\n  c1:\n    by: user\n"
                           "    at: \"2026-01-01T00:00:00.000Z\"\n#+end_comment\n")))))

(ert-deftest redline-org-body-cannot-end-the-block ()
  (redline-test-with-buffer #'org-mode "Some text here.\n"
    (redline-test-with-input '("See:\n#+end_comment\n* not a heading")
      (redline-comment t))
    (should (string-match-p "^ *,#\\+end_comment" (buffer-string)))
    (should (string-match-p "^ *,\\* not a heading" (buffer-string)))
    (let ((item (car (redline-doc-items (redline-parse redline-org-adapter)))))
      (should (equal (redline-item-body item) "See:\n#+end_comment\n* not a heading")))
    (let ((out (let ((org-export-show-temporary-export-buffer nil))
                 (org-export-as 'ascii nil nil t))))
      (should-not (string-match-p "not a heading\\|end_comment\\|by: user" out)))))

(defconst redline-org-test-document
  (concat "Keep {++new ++}{#s1}text {--old --}{#s2}and {~~this~>that~~}{#s3} "
          "{==here==}{>>note<<}{#c1}.\n\n"
          "#+begin_src text\nliteral {++x++}\n#+end_src\n\n"
          "#+begin_comment redline\ncomments:\n  c1:\n    by: user\n    at: \"t\"\n"
          "suggestions:\n  s1:\n    by: AI\n    at: \"t\"\n  s2:\n    by: AI\n"
          "    at: \"t\"\n  s3:\n    by: AI\n    at: \"t\"\n#+end_comment\n")
  "An Org document with every kind of review markup.")

(defun redline-org-test-export (style backend)
  "Export `redline-org-test-document' to BACKEND under STYLE."
  (with-temp-buffer
    (insert redline-org-test-document)
    (org-mode)
    (let ((redline-org-export-style style))
      (org-export-as backend nil nil t))))

(ert-deftest redline-org-export-styles ()
  (dolist (backend '(ascii html))
    (let ((original (redline-org-test-export 'original backend))
          (accepted (redline-org-test-export 'accepted backend))
          (markup (redline-org-test-export 'markup backend)))
      (should (string-match-p "Keep text old and this here\\." original))
      (should (string-match-p "Keep new text and that here\\." accepted))
      (dolist (out (list original accepted))
        (should (string-match-p "literal {\\+\\+x\\+\\+}" out))
        (should-not (string-match-p "note\\|{#\\|by: user" out)))
      (should (string-match-p "{#s1}" markup)))))

(defvar redline-org-test-flag nil
  "Set by a macro in a test document.")

(ert-deftest redline-org-export-drops-before-macros ()
  (let ((text (concat "#+macro: mark (eval (progn (setq redline-org-test-flag t) \"m\"))\n"
                      "Text {++{{{mark}}}++}.\n")))
    (dolist (case '((original . nil) (markup . t)))
      (setq redline-org-test-flag nil)
      (with-temp-buffer
        (insert text)
        (org-mode)
        (let ((redline-org-export-style (car case)))
          (org-export-as 'ascii nil nil t)))
      (should (eq redline-org-test-flag (cdr case))))))

;;; redline-org-test.el ends here
