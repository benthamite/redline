;;; redline-parse-test.el --- Parser tests for redline -*- lexical-binding: t; -*-

;;; Commentary:

;; Reading Roughdraft Flavored Markdown 0.2.  The cases restate the
;; spec's rules in this package's own words and examples.

;;; Code:

(require 'redline-test-helpers)

(ert-deftest redline-parse-anchored-comment ()
  (with-temp-buffer
    (insert "Check {==the claim==}{>>Source?<<}{#c1} today.\n\n---\n"
            "comments:\n  c1:\n    by: user\n    at: \"2026-02-03T04:05:06.000Z\"\n")
    (let* ((doc (redline-parse redline-markdown-adapter))
           (item (car (redline-doc-items doc))))
      (should (equal (redline-item-id item) "c1"))
      (should (equal (redline-item-body item) "Source?"))
      (should (equal (redline-item-by item) "user"))
      (should (equal (redline-item-at item) "2026-02-03T04:05:06.000Z"))
      (should (equal (redline--token-text (redline-item-anchor item)) "the claim"))
      (should (redline-doc-endmatter doc)))))

(ert-deftest redline-parse-multiparagraph-body ()
  (should (equal (redline-test-items
                  (concat "Text {==here==}{>><<}{#c1}.\n\n---\ncomments:\n  c1:\n"
                          "    by: user\n    at: \"x\"\n    body: |-\n      One.\n\n      Two.\n"))
                 '((comment "c1" "One.\n\nTwo." nil)))))

(ert-deftest redline-parse-replies-and-document-comments ()
  (should (equal (redline-test-items
                  (concat "A {==b==}{>>Why?<<}{#c1}.\n\n---\ncomments:\n"
                          "  c1:\n    by: user\n    at: \"t1\"\n"
                          "  c2:\n    body: Because.\n    by: AI\n    at: \"t2\"\n    re: c1\n"
                          "  c3:\n    body: Overall fine.\n    by: user\n    at: \"t3\"\n"))
                 '((comment "c1" "Why?" nil)
                   (comment "c2" "Because." "c1")
                   (comment "c3" "Overall fine." nil)))))

(ert-deftest redline-parse-document-scope ()
  (let ((doc (redline-test-parse
              "Text.\n\n---\ncomments:\n  c1:\n    body: Hi.\n    by: user\n    at: \"t\"\n")))
    (should (eq (redline-item-scope (car (redline-doc-items doc))) 'document))))

(ert-deftest redline-parse-suggestions ()
  (should (equal (redline-test-items
                  (concat "Add {++more++}{#s1}, drop {--less--}{#s2}, "
                          "swap {~~old~>new~~}{#s3}.\n\n---\nsuggestions:\n"
                          "  s1:\n    by: AI\n    at: \"t\"\n  s2:\n    by: AI\n    at: \"t\"\n"
                          "  s3:\n    by: AI\n    at: \"t\"\n"))
                 '((addition "s1" "more" nil) (deletion "s2" "less" nil)
                   (substitution "s3" "old" nil)))))

(ert-deftest redline-parse-comment-on-suggestion ()
  (should (equal (redline-test-items
                  (concat "Add {++more++}{#s1}{>>Why?<<}{#c1}.\n\n---\n"
                          "comments:\n  c1:\n    by: user\n    at: \"t\"\n"
                          "suggestions:\n  s1:\n    by: AI\n    at: \"t\"\n"))
                 '((addition "s1" "more" nil) (comment "c1" "Why?" "s1")))))

(ert-deftest redline-parse-inline-attributes ()
  (with-temp-buffer
    (insert "A {>>Say \\\"hi\\\"<<}{id=\"c1\" by=\"AI\" at=\"t\" note=\"a \\\"b\\\" \\\\ c\"}.\n")
    (let* ((doc (redline-parse redline-markdown-adapter))
           (item (car (redline-doc-items doc))))
      (should (equal (redline-item-id item) "c1"))
      (should (equal (redline-item-by item) "AI"))
      (should (equal (cdr (assoc "note" (redline-token-attrs (redline-item-token item))))
                     "a \"b\" \\ c")))))

(ert-deftest redline-parse-legacy-metadata ()
  (with-temp-buffer
    (insert "A {>>Old<<}{@id:c9; by:AI; at:2020-01-01T00:00:00Z@}.\n")
    (let ((item (car (redline-doc-items (redline-parse redline-markdown-adapter)))))
      (should (equal (redline-item-id item) "c9"))
      (should (equal (redline-item-at item) "2020-01-01T00:00:00Z")))))

(ert-deftest redline-parse-code-is-literal ()
  (should-not (redline-test-items
               (concat "Use `{++x++}` inline.\n\n```md\n{==a==}{>>b<<}\n```\n\n"
                       "~~~~\n{--c--}\n~~~~\n\n<!-- {++d++} -->\n")))
  (should (equal (mapcar #'car (redline-test-items "`a` {++x++} `b`\n"))
                 '(addition))))

(ert-deftest redline-parse-frontmatter-is-literal ()
  (should-not (redline-test-items "---\ntitle: \"{++x++}\"\n---\n\nBody.\n")))

(ert-deftest redline-parse-span-ends-at-paragraph ()
  (should-not (redline-test-items "{++one\n\ntwo++}\n"))
  (should (equal (mapcar #'car (redline-test-items "{++one\ntwo++}\n")) '(addition))))

(ert-deftest redline-parse-endmatter-needs-references ()
  (let ((doc (redline-test-parse
              "Text.\n\n---\ncomments:\n  c1:\n    by: user\n    at: \"t\"\n")))
    (should-not (redline-doc-endmatter doc))))

(ert-deftest redline-parse-endmatter-in-fence-is-ignored ()
  (should-not (redline-doc-endmatter
               (redline-test-parse
                "A {>>x<<}{#c1}\n\n```\n---\ncomments:\n  c1:\n    by: user\n"))))

(ert-deftest redline-parse-orphans-and-cycles ()
  (let ((doc (redline-test-parse
              (concat "A {>>x<<}{#c1}.\n\n---\ncomments:\n"
                      "  c1:\n    by: u\n    at: \"t\"\n"
                      "  c2:\n    body: a\n    by: u\n    at: \"t\"\n    re: c3\n"
                      "  c3:\n    body: b\n    by: u\n    at: \"t\"\n    re: c2\n"
                      "  c4:\n    body: c\n    by: u\n    at: \"t\"\n    re: missing\n"
                      "  c5:\n    body: d\n    by: u\n    at: \"t\"\n    re: c5\n"))))
    (should (equal (mapcar #'redline-item-id (redline-thread-roots doc))
                   '("c1" "c4" "c5")))
    (let ((c2 (redline-item-by-id doc "c2")))
      (should (memq (redline-item-root doc c2)
                    (list c2 (redline-item-by-id doc "c3"))))
      (should (= (length (redline-item-descendants doc c2)) 1)))))

(ert-deftest redline-parse-stale-re-is-ignored ()
  (should (equal (redline-test-items
                  (concat "A {>>New text<<}{#c2}.\n\n---\ncomments:\n"
                          "  c1:\n    by: u\n    at: \"t\"\n    body: Other\n"
                          "  c2:\n    by: u\n    at: \"t\"\n    body: Old text\n    re: c1\n"))
                 '((comment "c2" "New text" nil) (comment "c1" "Other" nil)))))

(ert-deftest redline-parse-highlight-chain ()
  (let ((doc (redline-test-parse
              (concat "A {==b==}{>>one<<}{#c1}{>>two<<}{#c2} c {>>three<<}{#c3}.\n\n"
                      "---\ncomments:\n  c1:\n    by: u\n    at: \"t\"\n"
                      "  c2:\n    by: u\n    at: \"t\"\n  c3:\n    by: u\n    at: \"t\"\n"))))
    (should (redline-item-anchor (redline-item-by-id doc "c1")))
    (should (eq (redline-item-anchor (redline-item-by-id doc "c2"))
                (redline-item-anchor (redline-item-by-id doc "c1"))))
    (should-not (redline-item-anchor (redline-item-by-id doc "c3")))))

;;; redline-parse-test.el ends here
