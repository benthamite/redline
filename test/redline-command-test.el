;;; redline-command-test.el --- Command tests for redline -*- lexical-binding: t; -*-

;;; Commentary:

;; Each command's effect on the file text, its single undo step, and
;; its refusal to make unsafe changes.

;;; Code:

(require 'redline-test-helpers)

(defun redline-command-test-entry (id &rest fields)
  "Return the endmatter lines for entry ID with FIELDS.
FIELDS alternate names and already formatted values."
  (concat "  " id ":\n"
          (mapconcat (lambda (pair) (format "    %s: %s\n" (car pair) (cadr pair)))
                     (seq-partition fields 2) "")))

(defconst redline-command-test-at "\"2026-01-01T00:00:00.000Z\""
  "The fixed timestamp as written in endmatter.")

(ert-deftest redline-command-comment-on-region ()
  (redline-test-with-buffer #'markdown-mode "A sentence here.\n"
    (redline-test-select "sentence")
    (redline-test-with-input '("Needs a source.")
      (redline-comment))
    (should (equal (buffer-string)
                   (concat "A {==sentence==}{>>Needs a source.<<}{#c1} here.\n\n---\n"
                           "comments:\n"
                           (redline-command-test-entry
                            "c1" "by" "user" "at" redline-command-test-at))))))

(ert-deftest redline-command-comment-is-one-undo-step ()
  (redline-test-with-buffer #'markdown-mode "A sentence here.\n"
    (undo-boundary)
    (redline-test-select "sentence")
    (redline-test-with-input '("Note")
      (redline-comment))
    (undo-boundary)
    (undo)
    (should (equal (buffer-string) "A sentence here.\n"))))

(ert-deftest redline-command-multiline-comment-goes-to-body ()
  (redline-test-with-buffer #'markdown-mode "Text.\n"
    (goto-char (point-max))
    (redline-test-with-input '("One.\n\nTwo.")
      (redline-comment))
    (should (string-prefix-p "Text.\n{>><<}{#c1}" (buffer-string)))
    (let ((item (car (redline-doc-items (redline-doc)))))
      (should (equal (redline-item-body item) "One.\n\nTwo.")))))

(ert-deftest redline-command-document-comment ()
  (redline-test-with-buffer #'markdown-mode "Text.\n"
    (redline-test-with-input '("Overall good.")
      (redline-comment t))
    (should (equal (buffer-string)
                   (concat "Text.\n\n---\ncomments:\n"
                           (redline-command-test-entry
                            "c1" "body" "Overall good." "by" "user"
                            "at" redline-command-test-at))))))

(ert-deftest redline-command-reply-and-resolve ()
  (redline-test-with-buffer #'markdown-mode "A sentence here.\n"
    (redline-test-select "sentence")
    (redline-test-with-input '("Why?" "Because.")
      (redline-comment)
      (redline-test-goto "sentence")
      (redline-reply))
    (redline-test-goto "sentence")
    (redline-resolve)
    (let* ((doc (redline-doc))
           (c1 (redline-item-by-id doc "c1"))
           (c2 (redline-item-by-id doc "c2")))
      (should (equal (redline-item-parent c2) "c1"))
      (should (equal (redline-item-body c2) "Because."))
      (should (redline-item-resolved-p c1)))
    (redline-test-goto "sentence")
    (redline-unresolve)
    (should-not (redline-item-resolved-p (redline-item-by-id (redline-doc) "c1")))))

(ert-deftest redline-command-delete-restores-text ()
  (redline-test-with-buffer #'markdown-mode "A sentence here.\n"
    (redline-test-select "sentence")
    (redline-test-with-input '("Why?" "Because.")
      (redline-comment)
      (redline-test-goto "sentence")
      (redline-reply)
      (redline-test-goto "sentence")
      (redline-delete))
    (should (equal (buffer-string) "A sentence here.\n"))))

(ert-deftest redline-command-remove-resolved ()
  (redline-test-with-buffer #'markdown-mode "One two three.\n"
    (redline-test-with-input '("First" "Second")
      (redline-test-select "One")
      (redline-comment)
      (redline-test-select "three")
      (redline-comment))
    (redline-test-goto "One")
    (redline-resolve)
    (redline-test-with-input nil
      (redline-remove-resolved))
    (should (equal (mapcar #'redline-item-id (redline-doc-items (redline-doc)))
                   '("c2")))
    (should (string-prefix-p "One two {==three==}" (buffer-string)))))

(ert-deftest redline-command-suggestions-accept-and-reject ()
  (dolist (case '((accept "Add {++more ++}{#s1}text." "Add more text.")
                  (reject "Add {++more ++}{#s1}text." "Add text.")
                  (accept "Drop {--this --}{#s1}text." "Drop text.")
                  (reject "Drop {--this --}{#s1}text." "Drop this text.")
                  (accept "Use {~~old~>new~~}{#s1} text." "Use new text.")
                  (reject "Use {~~old~>new~~}{#s1} text." "Use old text.")))
    (pcase-let ((`(,action ,text ,expected) case))
      (redline-test-with-buffer #'markdown-mode
          (concat text "\n\n---\nsuggestions:\n"
                  (redline-command-test-entry "s1" "by" "AI" "at" "\"t\""))
        (redline-test-goto "{")
        (if (eq action 'accept) (redline-accept) (redline-reject))
        (should (equal (buffer-string) (concat expected "\n")))))))

(ert-deftest redline-command-settling-removes-attached-comments ()
  (redline-test-with-buffer #'markdown-mode
      (concat "Add {++more ++}{#s1}{>>Why?<<}{#c1}text.\n\n---\ncomments:\n"
              (redline-command-test-entry "c1" "by" "user" "at" "\"t\"")
              (redline-command-test-entry "c2" "body" "Reply" "by" "AI" "at" "\"t\""
                                          "re" "c1")
              "suggestions:\n"
              (redline-command-test-entry "s1" "by" "AI" "at" "\"t\""))
    (redline-test-goto "{++")
    (redline-accept)
    (should (equal (buffer-string) "Add more text.\n"))))

(ert-deftest redline-command-suggest-and-accept-all ()
  (redline-test-with-buffer #'markdown-mode "Alpha beta gamma.\n"
    (redline-test-with-input '("delta")
      (redline-test-select "beta")
      (redline-suggest-replacement (region-beginning) (region-end)))
    (redline-test-select "gamma")
    (redline-suggest-deletion (region-beginning) (region-end))
    (redline-test-goto "Alpha")
    (redline-test-with-input '("Very ")
      (redline-suggest-insertion))
    (should (string-prefix-p "{++Very ++}{#s3}Alpha {~~beta~>delta~~}{#s1} {--gamma--}{#s2}."
                             (buffer-string)))
    (redline-test-with-input nil
      (redline-accept-all))
    (should (equal (buffer-string) "Very Alpha delta .\n"))))

(ert-deftest redline-command-rejects-unsafe-changes ()
  (let ((text (concat "Para {++one++} here.\n\nTwo `code {==x==}` end ~> y.\n\n"
                      "```\nfenced\n```\n")))
    (redline-test-with-buffer #'markdown-mode text
      (dolist (attempt
               (list (lambda () (redline-test-select "Para {++one")
                       (redline-test-with-input '("c") (redline-comment)))
                     (lambda () (redline-test-select "here.\n\nTwo")
                       (redline-test-with-input '("c") (redline-comment)))
                     (lambda () (redline-test-select "end ~> y")
                       (redline-suggest-deletion (region-beginning) (region-end)))
                     (lambda () (redline-test-goto "x==}")
                       (redline-test-with-input '("c") (redline-comment)))
                     (lambda () (redline-test-goto "fenced")
                       (redline-test-with-input '("x") (redline-suggest-insertion)))
                     (lambda () (redline-test-goto "ne++}")
                       (redline-test-with-input '("x") (redline-suggest-insertion)))
                     (lambda () (redline-test-select "here")
                       (redline-test-with-input '("bad <<} text") (redline-comment)))
                     (lambda () (redline-test-select "here")
                       (redline-test-with-input '("a {++b") (redline-suggest-replacement
                                                             (region-beginning) (region-end))))))
        (deactivate-mark)
        (should-error (funcall attempt) :type 'user-error)
        (should (equal (buffer-string) text))))))

(ert-deftest redline-command-reply-assigns-id-to-plain-markup ()
  (redline-test-with-buffer #'markdown-mode "A {==b==}{>>plain<<} c.\n"
    (redline-test-goto "b==")
    (redline-test-with-input '("Answer")
      (redline-reply))
    (should (string-prefix-p "A {==b==}{>>plain<<}{#c1} c.\n\n---\ncomments:\n  c1:\n"
                             (buffer-string)))
    (let ((doc (redline-doc)))
      (should (equal (redline-item-parent (redline-item-by-id doc "c2")) "c1")))))

(ert-deftest redline-command-resolve-migrates-inline-attributes ()
  (redline-test-with-buffer #'markdown-mode
      "A {>>old<<}{id=\"c4\" by=\"AI\" at=\"t\" mood=\"calm\"} b.\n"
    (redline-test-goto "old")
    (redline-resolve)
    (should (equal (buffer-string)
                   (concat "A {>>old<<}{#c4} b.\n\n---\ncomments:\n"
                           (redline-command-test-entry
                            "c4" "by" "AI" "at" "t" "mood" "calm"
                            "status" "resolved"))))))

(ert-deftest redline-command-preserves-unknown-yaml ()
  (redline-test-with-buffer #'markdown-mode
      (concat "A {>>x<<}{#c1} b.\n\n---\ncomments:\n  c1:\n    by: user\n"
              "    at: \"t\"\n    tags:\n      - one\n      - two\n"
              "custom:\n  keep: [1, 2]\n")
    (redline-test-goto "x<<")
    (redline-resolve)
    (should (string-match-p "    tags:\n      - one\n      - two\n" (buffer-string)))
    (should (string-match-p "^custom:\n  keep: \\[1, 2\\]" (buffer-string)))
    (should (string-match-p "status: resolved" (buffer-string)))))

(ert-deftest redline-command-unreferenced-metadata-is-pruned ()
  (redline-test-with-buffer #'markdown-mode
      (concat "A {>>x<<}{#c1} b.\n\n---\ncomments:\n"
              (redline-command-test-entry "c1" "by" "u" "at" "\"t\"")
              (redline-command-test-entry "c7" "by" "u" "at" "\"t\"")
              (redline-command-test-entry "c8" "body" "Doc note" "by" "u" "at" "\"t\""))
    (redline-test-goto "x<<")
    (redline-resolve)
    (should-not (string-match-p "c7:" (buffer-string)))
    (should (string-match-p "c8:" (buffer-string)))))

(ert-deftest redline-command-next-and-previous ()
  (redline-test-with-buffer #'markdown-mode
      "A {++b++} c {==d==}{>>e<<} f {--g--}.\n"
    (redline-next)
    (should (looking-at-p "{\\+\\+b"))
    (redline-next)
    (should (looking-at-p "{==d"))
    (redline-next)
    (should (looking-at-p "{--g"))
    (should-error (redline-next) :type 'user-error)
    (redline-previous)
    (should (looking-at-p "{==d"))))

(ert-deftest redline-command-thread-and-list-buffers ()
  (redline-test-with-buffer #'markdown-mode "A sentence here.\n"
    (redline-test-select "sentence")
    (redline-test-with-input '("Why?" "Because.")
      (redline-comment)
      (redline-test-goto "sentence")
      (redline-reply))
    (redline-test-goto "sentence")
    (redline-show-thread)
    (let ((thread (get-buffer (redline--thread-buffer-name (current-buffer)))))
      (with-current-buffer thread
        (should (string-match-p "“sentence”" (buffer-string)))
        (should (string-match-p "Because\\." (buffer-string)))
        (goto-char (point-min))
        (search-forward "Because.")
        (redline-test-with-input '("Thanks")
          (redline-reply)))
      (should (equal (redline-item-parent (redline-item-by-id (redline-doc) "c3")) "c2"))
      (kill-buffer thread))
    (redline-list)
    (let ((list (current-buffer)))
      (should (string-match-p "c1" (buffer-string)))
      (goto-char (point-min))
      (search-forward "c1")
      (redline-resolve)
      (with-current-buffer redline--source-buffer
        (should (redline-item-resolved-p (redline-item-by-id (redline-doc) "c1"))))
      (kill-buffer list))))

(ert-deftest redline-command-agent-prompt ()
  (should (string-match-p "Roughdraft Flavored Markdown 0.2"
                          (redline-agent-prompt "/tmp/x.md" 'markdown)))
  (should (string-match-p "#\\+begin_comment redline"
                          (redline-agent-prompt "/tmp/x.org" 'org))))

;;; redline-command-test.el ends here
