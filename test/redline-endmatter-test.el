;;; redline-endmatter-test.el --- Endmatter tests for redline -*- lexical-binding: t; -*-

;;; Commentary:

;; Reading, editing and writing the YAML review endmatter.

;;; Code:

(require 'redline-test-helpers)

(defconst redline-endmatter-test-canonical
  (concat "comments:\n"
          "  c1:\n    by: user\n    at: \"2026-01-01T00:00:00.000Z\"\n"
          "  c2:\n    body: |-\n      One.\n\n      Two.\n    by: AI\n"
          "    at: \"2026-01-01T00:00:00.000Z\"\n    re: c1\n"
          "suggestions:\n  s1:\n    by: AI\n    at: \"2026-01-01T00:00:00.000Z\"\n")
  "Endmatter in the form redline writes.")

(defun redline-endmatter-test-model (yaml)
  "Return the editable model of YAML."
  (redline-endmatter-editable-model (redline-endmatter-read yaml 1 1)))

(ert-deftest redline-endmatter-canonical-round-trip ()
  (should (equal (redline-endmatter-serialize
                  (redline-endmatter-test-model redline-endmatter-test-canonical))
                 redline-endmatter-test-canonical)))

(ert-deftest redline-endmatter-unknown-values-survive-edits ()
  (let* ((yaml (concat "comments:\n  c1:\n    by: user\n    at: \"t\"\n"
                       "    tags:\n      - a\n      - b\n    extra:\n      nested: {k: v}\n"
                       "meta:\n  - kept\n"))
         (model (redline-endmatter-put (redline-endmatter-test-model yaml)
                                       "comments" "c1" "status" "resolved"))
         (out (redline-endmatter-serialize model))
         (data (redline-endmatter--parse out))
         (entry (cdr (assoc "c1" (cdr (assoc "comments" data))))))
    (should (equal (cdr (assoc "tags" entry)) '("a" "b")))
    (should (equal (cdr (assoc "k" (cdr (assoc "nested" (cdr (assoc "extra" entry))))))
                   "v"))
    (should (equal (cdr (assoc "status" entry)) "resolved"))
    (should (equal (cdr (assoc "meta" data)) '("kept")))))

(ert-deftest redline-endmatter-flow-style-is-read-only ()
  (let ((endmatter (redline-endmatter-read "comments: {c1: {by: user}}\n" 1 1)))
    (should endmatter)
    (should (equal (redline-endmatter-section endmatter "comments")
                   '(("c1" ("by" . "user")))))
    (should-error (redline-endmatter-editable-model endmatter) :type 'user-error)))

(ert-deftest redline-endmatter-flow-entry-is-kept-verbatim ()
  (let* ((yaml "comments:\n  c1: {by: user, at: t}\n  c2:\n    by: AI\n    at: \"t\"\n")
         (model (redline-endmatter-test-model yaml)))
    (should (eq (redline-endmatter-entry-fields model "comments" "c1") 'raw))
    (should-error (redline-endmatter-put model "comments" "c1" "status" "resolved")
                  :type 'user-error)
    (should (string-match-p "c1: {by: user, at: t}"
                            (redline-endmatter-serialize
                             (redline-endmatter-put model "comments" "c2"
                                                    "status" "resolved"))))))

(ert-deftest redline-endmatter-untouched-fields-keep-their-style ()
  (let* ((yaml (concat "comments:\n  c1:\n    by: user\n    at: 2026-01-01T00:00:00.000Z\n"
                       "  c2:\n    body: 'single quoted'\n    by: AI\n    at: \"t\"\n"))
         (model (redline-endmatter-test-model yaml))
         (out (redline-endmatter-serialize
               (redline-endmatter-put
                (redline-endmatter-put model "comments" "c1" "by" "user")
                "comments" "c2" "status" "resolved"))))
    (should (string-search "    at: 2026-01-01T00:00:00.000Z\n" out))
    (should (string-search "    body: 'single quoted'\n" out))
    (should (string-search "    status: resolved" out))
    (should (string-search "    by: someone"
                           (redline-endmatter-serialize
                            (redline-endmatter-put model "comments" "c1" "by" "someone"))))))

(ert-deftest redline-endmatter-scalars-read-back ()
  (dolist (value '("user" "AI" "2026-01-01T00:00:00.000Z" "yes" "null" "a: b"
                   "with # hash" "quote \" and \\ slash" "  leading" "trailing "
                   "two\nlines" "para one\n\npara two" "ends with newline\n"
                   "tab\there" "- dash" "[bracket" "émoji ✓" "123"))
    (let* ((yaml (concat "comments:\n  c1:\n    body: "
                         (redline-endmatter-scalar value 6) "\n"))
           (comments (redline-endmatter-section (redline-endmatter-read yaml 1 1)
                                                "comments"))
           (entry (cdr (assoc "c1" comments))))
      (should (equal (cdr (assoc "body" entry)) value)))))

(ert-deftest redline-endmatter-delete-last-entry ()
  (let ((model (redline-endmatter-test-model
                "comments:\n  c1:\n    by: user\n    at: \"t\"\n")))
    (should-not (redline-endmatter-serialize
                 (redline-endmatter-delete model "comments" "c1")))))

(ert-deftest redline-endmatter-not-review-data ()
  (should-not (redline-endmatter-read "title: x\n" 1 1))
  (should-not (redline-endmatter-read "comments: [a, b]\n" 1 1))
  (should-not (redline-endmatter-read "not: [valid\n" 1 1)))

;;; redline-endmatter-test.el ends here
