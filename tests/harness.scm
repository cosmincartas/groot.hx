;; Shared assertions for the groot.hx test suites.  A failed check is reported
;; and counted instead of aborting, so one run shows every failure;
;; harness-report! fails the process once at the end if any check failed.

(provide check-equal check-true raises? check-raises harness-report!)

(define *checks* 0)
(define *failures* 0)

;; Records one check; prints an actionable message when it fails.
(define (check-equal name actual expected)
  (set! *checks* (+ *checks* 1))
  (unless (equal? actual expected)
    (set! *failures* (+ *failures* 1))
    (displayln (string-append "FAIL: " name
                              "\n  expected: " (to-string expected)
                              "\n  actual:   " (to-string actual)))))

(define (check-true name value) (check-equal name value #t))

;; Reports whether calling thunk raises an error.
(define (raises? thunk)
  (with-handler (lambda (_) #t)
    (begin (thunk) #f)))

(define (check-raises name thunk) (check-true name (raises? thunk)))

;; Prints the totals and fails the process when any check failed.
(define (harness-report!)
  (displayln (string-append (to-string *checks*) " checks, "
                            (to-string *failures*) " failed"))
  (unless (= *failures* 0)
    (error (string-append (to-string *failures*) " groot test check(s) failed"))))
