;; Tests for the external file finder and its argument shaping.
;; The traversal itself is exercised against this repository checkout.

(require "../groot-fs.scm")

;; Fails the Steel process with an actionable assertion message.
(define (check-equal name actual expected)
  (unless (equal? actual expected)
    (error (string-append name "\n expected: " (to-string expected) "\n actual: " (to-string actual)))))

(define ignored '(".git" "node_modules"))

(check-equal "fd arguments exclude each ignored name and scan the root last"
             (groot-fs-find-args "fd" "/repo" ignored)
             '("--type" "f" "--hidden" "--no-ignore" "--color" "never"
               "--exclude" ".git" "--exclude" "node_modules" "." "/repo"))

(check-equal "rg arguments negate each ignored name as a glob"
             (groot-fs-find-args "rg" "/repo" ignored)
             '("--files" "--hidden" "--no-ignore" "--no-messages" "--color" "never"
               "--glob" "!.git" "--glob" "!node_modules" "/repo"))

(check-equal "an empty exclude list adds no flags"
             (groot-fs-find-args "fd" "/repo" '())
             '("--type" "f" "--hidden" "--no-ignore" "--color" "never" "." "/repo"))

;; The finder is optional, so a machine without one must still pass the suite.
(define found (groot-fs-find-files "." ignored))
(when found
  (check-equal "every returned line is a non-empty path"
               (filter (lambda (p) (equal? p "")) found) '())
  (check-equal "ignored directories are never traversed"
               (filter (lambda (p) (string-contains? p "/.git/")) found) '())
  (check-equal "this test file is part of its own repository listing"
               (> (length (filter (lambda (p) (string-contains? p "groot-fs.scm")) found)) 0)
               #t))

(displayln (if found
               (string-append "groot fs tests passed (finder found " (to-string (length found)) " files)")
               "groot fs tests passed (no external finder; fallback path in use)"))
