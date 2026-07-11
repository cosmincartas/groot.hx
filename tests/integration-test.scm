;; Thin integration tests for component lifecycle, redraw, focus, and mouse routing.

(require "../groot-integration.scm")

;; Fails the Steel process with an actionable assertion message.
(define (check-equal name actual expected)
  (unless (equal? actual expected)
    (error (string-append name "\n expected: " (to-string expected) "\n actual: " (to-string actual)))))

;; Records dependency-injected effects without loading Helix.
(define effects '())
(define (record! effect) (set! effects (append effects (list effect))))

(groot-open-effects! (lambda () (record! 'mount)) (lambda () (record! 'redraw)))
(check-equal "opening mounts before requesting redraw" effects '(mount redraw))

(set! effects '())
(groot-close-effects! (lambda () (record! 'unmount)) (lambda () (record! 'cleanup)))
(check-equal "closing unmounts before scheduling cleanup" effects '(unmount cleanup))

(set! effects '())
(check-equal "inside click is consumed"
             (groot-route-mouse! 'left #t #f
                                 (lambda (focused?) (record! (list 'focus focused?)))
                                 (lambda () (record! 'select))
                                 (lambda (_) (record! 'scroll)))
             'consume)
(check-equal "inside click focuses and selects" effects '((focus #t) select))

(set! effects '())
(check-equal "outside click returns control to Helix"
             (groot-route-mouse! 'left #f #t
                                 (lambda (focused?) (record! (list 'focus focused?)))
                                 (lambda () (record! 'select))
                                 (lambda (_) (record! 'scroll)))
             'ignore)
(check-equal "outside click releases focus" effects '((focus #f)))

(set! effects '())
(check-equal "focused wheel is consumed"
             (groot-route-mouse! 'up #t #t
                                 (lambda (focused?) (record! (list 'focus focused?)))
                                 (lambda () (record! 'select))
                                 (lambda (direction) (record! (list 'scroll direction))))
             'consume)
(check-equal "focused wheel scrolls the tree" effects '((scroll up)))

(set! effects '())
(check-equal "unfocused wheel is consumed without scrolling"
             (groot-route-mouse! 'down #t #f
                                 (lambda (focused?) (record! (list 'focus focused?)))
                                 (lambda () (record! 'select))
                                 (lambda (direction) (record! (list 'scroll direction))))
             'consume)
(check-equal "unfocused wheel has no side effect" effects '())

(set! effects '())
(check-equal "refresh before open is ignored"
             (groot-refresh-effects! #f #f
                                     (lambda () (record! 'tree))
                                     (lambda () (record! 'search))
                                     (lambda () (record! 'redraw)))
             'inactive)
(check-equal "inactive refresh has no side effects" effects '())

(set! effects '())
(check-equal "tree refresh completes"
             (groot-refresh-effects! #t #f
                                     (lambda () (record! 'tree))
                                     (lambda () (record! 'search))
                                     (lambda () (record! 'redraw)))
             'refreshed)
(check-equal "tree refresh rebuilds before redraw" effects '(tree redraw))

(set! effects '())
(check-equal "search refresh completes"
             (groot-refresh-effects! #t #t
                                     (lambda () (record! 'tree))
                                     (lambda () (record! 'search))
                                     (lambda () (record! 'redraw)))
             'refreshed)
(check-equal "search refresh rebuilds tree and results before redraw" effects '(tree search redraw))

(displayln "groot integration tests passed")
