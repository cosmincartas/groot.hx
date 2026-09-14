;; Thin integration tests for component lifecycle, redraw, focus, and mouse routing.

(require "../groot-integration.scm")
(require "../groot-fs.scm")

;; Fails the Steel process with an actionable assertion message.
(define (check-equal name actual expected)
  (unless (equal? actual expected)
    (error (string-append name "\n expected: " (to-string expected) "\n actual: " (to-string actual)))))

;; Records dependency-injected effects without loading Helix.
(define effects '())
(define (record! effect) (set! effects (append effects (list effect))))

;; Creation reveal must not replace the document path used by the next sync.
(define last-document #f)
(define (get-last-document) last-document)
(define (set-last-document! path) (set! last-document path))

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

;; Keep integration tests thin: one success path, one failure path, and dispatch ownership.
(set! effects '())
(set! last-document "/fixture/open.txt")
(check-equal "created file refreshes selects and redraws"
             (groot-created-file-effects!
              "/fixture/nested/new.txt"
              (lambda () (record! 'refresh))
              (lambda (path) (set-last-document! path) (record! (list 'select path)) #t)
              (lambda () (record! 'redraw))
              (lambda (message) (record! (list 'error message)))
              (lambda () last-document) (lambda (path) (set! last-document path)))
             'revealed)
(check-equal "created file preserves document bookkeeping" last-document "/fixture/open.txt")
(check-equal "created file display effect order" effects '(refresh (select "/fixture/nested/new.txt") redraw))

(set! effects '())
(check-equal "missing created row reports and redraws"
             (groot-created-file-effects!
              "/fixture/missing.txt" (lambda () (record! 'refresh))
              (lambda (path) (record! (list 'reveal path)) #f)
              (lambda () (record! 'redraw))
              (lambda (message) (record! (list 'error message)))
              (lambda () last-document) (lambda (path) (set! last-document path)))
             'display-failed)
(check-equal "missing created row effects"
             effects
             '(refresh (reveal "/fixture/missing.txt")
               (error "File was created at /fixture/missing.txt, but the tree could not display it.")
               redraw))

;; Created directories are collapsed before refresh, so a removed and recreated
;; path cannot inherit expansion state from its prior identity.
(set! effects '())
(define created-directory
  (GrootFsCreateResult 'success "/fixture/recreated" #f #t))
(check-equal "created entry collapses then refreshes reveals and redraws"
             (groot-created-entry-effects!
              created-directory
              (lambda (path) (record! (list 'collapse path)))
              (lambda () (record! 'refresh))
              (lambda (path) (record! (list 'select path)) #t)
              (lambda () (record! 'redraw))
              (lambda (message) (record! (list 'error message)))
              (lambda () last-document) (lambda (path) (set! last-document path)))
             'revealed)
(check-equal "created entry collapse happens before display refresh"
             effects
             '((collapse "/fixture/recreated") refresh (select "/fixture/recreated") redraw))

(set! effects '())
(check-equal "created-entry display failure preserves filesystem success"
             (groot-created-entry-effects!
              created-directory
              (lambda (path) (record! (list 'collapse path)))
              (lambda () (record! 'refresh))
              (lambda (path) (record! (list 'reveal path)) #f)
              (lambda () (record! 'redraw))
              (lambda (message) (record! (list 'error message)))
              (lambda () last-document) (lambda (path) (set! last-document path)))
             'display-failed)
(check-equal "created-entry display failure does not compensate"
             effects
             '((collapse "/fixture/recreated") refresh (reveal "/fixture/recreated")
               (error "Entry was created at /fixture/recreated, but the tree could not display it.") redraw))

(set! effects '())
(check-equal "created-entry filesystem failure only reports its outcome"
             (groot-created-entry-effects!
              (GrootFsCreateResult 'native-failure "/fixture/uncertain" "native failed" #f)
              (lambda (path) (record! (list 'collapse path)))
              (lambda () (record! 'refresh))
              (lambda (path) (record! (list 'reveal path)) #t)
              (lambda () (record! 'redraw))
              (lambda (message) (record! (list 'error message)))
              (lambda () last-document) (lambda (path) (set! last-document path)))
             'native-failure)
(check-equal "mutation-free filesystem failure has no display effects"
             effects
             '((error "Cannot create entry: native failed")))

(set! effects '())
(check-equal "rejected creation reports feedback without display or compensation effects"
             (groot-created-entry-effects!
              (GrootFsCreateResult 'rejected "/fixture/rejected" "unsafe component" #f)
              (lambda (path) (record! (list 'collapse path)))
              (lambda () (record! 'refresh))
              (lambda (path) (record! (list 'reveal path)) #t)
              (lambda () (record! 'redraw))
              (lambda (message) (record! (list 'error message)))
              (lambda () last-document) (lambda (path) (set! last-document path)))
             'rejected)
(check-equal "rejected creation only emits actionable feedback"
             effects
             '((error "Cannot create entry: unsafe component")))

;; Exceptions in every display phase retain the filesystem result and still run
;; the remaining recovery effects.
(define created-file (GrootFsCreateResult 'success "/fixture/new" #f #t))
(for-each
 (lambda (phase)
   (set! effects '())
   (check-equal "created-entry display exceptions are reported"
                (groot-created-entry-effects!
                 created-file
                 (lambda (_) (record! 'collapse))
                 (lambda () (record! 'refresh) (when (equal? phase 'refresh) (error "refresh failed")))
                 (lambda (_) (record! 'reveal) (when (equal? phase 'reveal) (error "reveal failed")) #t)
                 (lambda () (record! 'redraw) (when (equal? phase 'redraw) (error "redraw failed")))
                 (lambda (message) (record! (list 'error message)))
                 (lambda () last-document) (lambda (path) (set! last-document path)))
                'display-failed)
   (check-equal "created-entry display exceptions still redraw"
                (length (filter (lambda (effect) (equal? effect 'redraw)) effects)) 1)
   (check-equal "created-entry display exceptions report their failure"
                (not (null? (filter (lambda (effect) (and (pair? effect) (equal? (car effect) 'error))) effects)))
                #t))
 '(refresh reveal redraw))

(set! effects '())
(check-equal "created-entry collapse exception remains display recovery"
             (groot-created-entry-effects!
              created-file (lambda (_) (error "collapse failed"))
              (lambda () (record! 'refresh)) (lambda (_) (record! 'reveal) #t)
              (lambda () (record! 'redraw)) (lambda (message) (record! (list 'error message)))
              (lambda () last-document) (lambda (path) (set! last-document path)))
             'display-failed)
(check-equal "collapse exception still refreshes and redraws"
             (filter (lambda (effect) (or (equal? effect 'refresh) (equal? effect 'redraw))) effects)
             '(refresh redraw))

;; Partial filesystem mutation refreshes and redraws without reveal.
(set! effects '())
(check-equal "partial creation refreshes and redraws"
             (groot-created-entry-effects!
              (GrootFsCreateResult 'partial-failure "/fixture/parent/file" "verify failed" #t)
              (lambda (_) (record! 'collapse)) (lambda () (record! 'refresh))
              (lambda (_) (record! 'reveal) #t) (lambda () (record! 'redraw))
              (lambda (message) (record! (list 'error message)))
              (lambda () last-document) (lambda (path) (set! last-document path)))
             'partial-failure)
(check-equal "partial creation skips reveal after refresh" (car effects) 'refresh)

;; Prompt submission passes the already captured context unchanged; cancellation
;; never invokes this callback because the native prompt owns Escape/Ctrl-C.
(set! effects '())
(define captured-context '(captured destination))
(define captured-submit #f)
(groot-create-prompt-effects!
 captured-context "Create in /fixture:"
 (lambda (label callback) (list label callback))
 (lambda (component)
   (record! (car component))
   ((cadr component) "nested/file"))
 (lambda (context submitted)
   (set! captured-submit (list context submitted))
   'result)
 (lambda (result) (record! result))
 (lambda (message) (record! (list 'error message))))
(check-equal "create prompt submits the captured destination context once"
             (list captured-submit effects)
             '(((captured destination) "nested/file") ("Create in /fixture:" result)))

(check-equal "ordinary focused tree a creates"
             (groot-key-dispatch #t #f #f #f #f #f #\a) 'create)
(check-equal "search input a remains query text"
             (groot-key-dispatch #t #f #t #t #f #f #\a) 'search-input)
(check-equal "ordinary focused tree r renames"
             (groot-key-dispatch #t #f #f #f #f #f #\r) 'rename)
(check-equal "ordinary focused tree d deletes"
             (groot-key-dispatch #t #f #f #f #f #f #\d) 'delete)
(check-equal "search result d never deletes"
             (groot-key-dispatch #t #f #f #t #f #f #\d) 'normal)
(check-equal "escape focuses the editor only from idle tree navigation"
             (list (groot-key-dispatch #t #f #f #f #f #f 'escape)
                   (groot-key-dispatch #t #f #f #f #t #f 'escape)
                   (groot-key-dispatch #t #f #f #t #f #f 'escape)
                   (groot-key-dispatch #t #t #f #f #f #f 'escape))
             '(focus-editor normal normal jump))

(displayln "groot integration tests passed")
