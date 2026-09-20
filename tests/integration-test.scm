;; Thin integration tests for component lifecycle, redraw, focus, and mouse routing.

(require "../groot-core.scm")
(require "../groot-integration.scm")
(require "../groot-fs.scm")
(require "harness.scm")

;; Records dependency-injected effects without loading Helix.
(define effects '())
(define (record! effect) (set! effects (append effects (list effect))))

;; Mouse host recording every effect; scroll records its direction.
(define mouse-host
  (GrootMouseHost (lambda (focused?) (record! (list 'focus focused?)))
                  (lambda (resizing?) (record! (list 'resizing resizing?)))
                  (lambda () (record! 'select))
                  (lambda (direction) (record! (list 'scroll direction)))
                  (lambda () (record! 'resize))))

;; Creation reveal must not replace the document path used by the next sync.
(define last-document #f)
(define (get-last-document) last-document)
(define (set-last-document! path) (set! last-document path))

;; Display host whose error reporting and document bookkeeping are recorded.
(define (test-host refresh-tree! reveal! redraw!)
  (GrootHost refresh-tree! reveal! redraw!
             (lambda (message) (record! (list 'error message)))
             get-last-document set-last-document!
             #f #f #f))

(groot-open-effects! (lambda () (record! 'mount)) (lambda () (record! 'redraw)))
(check-equal "opening mounts before requesting redraw" effects '(mount redraw))

(set! effects '())
(groot-close-effects! (lambda () (record! 'unmount)) (lambda () (record! 'cleanup)))
(check-equal "closing unmounts before scheduling cleanup" effects '(unmount cleanup))

(set! effects '())
(check-equal "inside click is consumed"
             (groot-route-mouse! mouse-host 'left #t #f #f #f)
             'consume)
(check-equal "inside click focuses and selects" effects '((focus #t) select))

(set! effects '())
(check-equal "separator drag captures and resizes"
             (groot-route-mouse! mouse-host 'left #t #t #f #f)
             'consume)
(check-equal "separator drag focuses without selecting a row" effects '((focus #t) (resizing #t)))

(set! effects '())
(check-equal "captured drag resizes outside the sidebar"
             (groot-route-mouse! mouse-host 'drag #f #f #t #t)
             'consume)
(check-equal "captured outside drag only resizes" effects '(resize))

(set! effects '())
(check-equal "release ends captured drag"
             (groot-route-mouse! mouse-host 'release #f #f #t #t)
             'consume)
(check-equal "release clears drag capture" effects '((resizing #f)))
(set! effects '())
(check-equal "drag after release is ignored"
             (groot-route-mouse! mouse-host 'drag #f #f #t #f)
             'unhandled)
(check-equal "drag after release has no resize effect" effects '())
(check-equal "left separator grows toward the right" (groot-resized-width 'left 100 49) 50)
(check-equal "right separator grows toward the left" (groot-resized-width 'right 100 50) 50)
(check-equal "requested width clamps at twenty cells" (groot-resized-width 'left 100 0) 20)
(check-equal "right requested width clamps at twenty cells" (groot-resized-width 'right 100 99) 20)

(set! effects '())
(check-equal "outside click returns control to Helix"
             (groot-route-mouse! mouse-host 'left #f #f #t #f)
             'ignore)
(check-equal "outside click releases focus" effects '((focus #f)))

(set! effects '())
(check-equal "focused wheel is consumed"
             (groot-route-mouse! mouse-host 'up #t #f #t #f)
             'consume)
(check-equal "focused wheel scrolls the tree" effects '((scroll up)))

(set! effects '())
(check-equal "unfocused wheel is consumed without scrolling"
             (groot-route-mouse! mouse-host 'down #t #f #f #f)
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

;; Collapse restores only transient tree-view state before rebuilding once.
;; Each field is a (name getter setter) triple so the snapshot helpers stay
;; data-driven without a symbol-keyed state boundary.
(define-syntax field
  (syntax-rules ()
    [(_ name getter setter) (list 'name getter setter)]))
(define all-fields
  (list (field root groot-state-root set-groot-state-root!)
        (field children groot-state-children set-groot-state-children!)
        (field expanded groot-state-expanded set-groot-state-expanded!)
        (field files groot-state-files set-groot-state-files!)
        (field search-ready? groot-state-search-ready? set-groot-state-search-ready!)
        (field rows groot-state-rows set-groot-state-rows!)
        (field ignored groot-state-ignored set-groot-state-ignored!)
        (field query groot-state-query set-groot-state-query!)
        (field results groot-state-results set-groot-state-results!)
        (field result-count groot-state-result-count set-groot-state-result-count!)
        (field result-rows groot-state-result-rows set-groot-state-result-rows!)
        (field search-input? groot-state-search-input? set-groot-state-search-input!)
        (field pending-g? groot-state-pending-g? set-groot-state-pending-g!)
        (field pending-z? groot-state-pending-z? set-groot-state-pending-z!)
        (field jump-active? groot-state-jump-active? set-groot-state-jump-active!)
        (field jump-input groot-state-jump-input set-groot-state-jump-input!)
        (field jump-alphabet groot-state-jump-alphabet set-groot-state-jump-alphabet!)
        (field cursor groot-state-cursor set-groot-state-cursor!)
        (field window groot-state-window set-groot-state-window!)
        (field height groot-state-height set-groot-state-height!)
        (field scroll-lines groot-state-scroll-lines set-groot-state-scroll-lines!)
        (field active? groot-state-active? set-groot-state-active!)
        (field focused? groot-state-focused? set-groot-state-focused!)
        (field last-document groot-state-last-document set-groot-state-last-document!)))
(define (fields-named names)
  (filter (lambda (f) (member (car f) names)) all-fields))
(define (field-named name) (car (fields-named (list name))))
(define (state-put! state name value) ((caddr (field-named name)) state value))
(define collapse-reset-fields
  (fields-named '(expanded query results result-count result-rows search-input?
                  pending-g? pending-z? jump-active? jump-input cursor window)))
(define collapse-preserved-fields
  (fields-named '(root children files search-ready? rows ignored jump-alphabet height scroll-lines
                  active? focused? last-document)))
(define (collapse-state-snapshot state fields)
  (map (lambda (f) (list (car f) ((cadr f) state))) fields))

(define collapse-state (groot-state "/fixture" "asdf"))
(define preserved-children (hash-insert (hash) "/fixture" '(child)))
(define preserved-files '(/fixture/file.txt))
(for-each (lambda (name+value) (state-put! collapse-state (car name+value) (cadr name+value)))
          `((children ,preserved-children) (files ,preserved-files) (search-ready? #t)
            (rows (cached-row))
            (expanded ,(hash-insert (hash-insert (hash) "/fixture" #t) "/fixture/nested" #t))
            (query "needle") (results (match)) (result-count 1) (result-rows #("match"))
            (search-input? #t) (pending-g? #t) (pending-z? #t) (jump-active? #t) (jump-input "a")
            (jump-alphabet "qwer") (cursor 9) (window 4) (height 42) (scroll-lines 8)
            (active? #t) (focused? #f) (last-document "/fixture/open.txt")))
(define collapse-preserved-before
  (collapse-state-snapshot collapse-state collapse-preserved-fields))
(define collapse-reset-state
  (list (list 'expanded (hash-insert (hash) "/fixture" #t))
        '(query "") '(results ()) '(result-count 0) '(result-rows #()) '(search-input? #f)
        '(pending-g? #f) '(pending-z? #f) '(jump-active? #f) '(jump-input "") '(cursor 0) '(window 0)))
(set! effects '())
(check-equal "collapse resets the active tree view"
             (groot-collapse-all-effects! collapse-state
                                          (lambda ()
                                            (check-equal "collapse resets state before rebuild"
                                                         (collapse-state-snapshot collapse-state collapse-reset-fields)
                                                         collapse-reset-state)
                                            (record! 'rebuild))
                                          (lambda () (record! 'redraw)))
             'collapsed)
(check-equal "collapse rebuilds once before one redraw" effects '(rebuild redraw))
(check-equal "collapse preserves every unspecified state field"
             (collapse-state-snapshot collapse-state collapse-preserved-fields)
             collapse-preserved-before)

(set! effects '())
(check-equal "absent collapse is ignored"
             (groot-collapse-all-effects! #f
                                          (lambda () (record! 'rebuild))
                                          (lambda () (record! 'redraw)))
             'inactive)
(check-equal "absent collapse has no effects" effects '())

(define inactive-collapse-state (groot-state "/inactive" "asdf"))
(for-each (lambda (name+value) (state-put! inactive-collapse-state (car name+value) (cadr name+value)))
          `((root "/other") (children ,preserved-children)
            (expanded ,(hash-insert (hash) "/inactive/nested" #t)) (files ,preserved-files)
            (search-ready? #t) (rows (cached-row))
            (query "needle") (results (match)) (result-count 1) (result-rows #("match")) (search-input? #t)
            (pending-g? #t) (pending-z? #t) (jump-active? #t) (jump-input "a") (jump-alphabet "qwer")
            (cursor 7) (window 4) (height 42) (scroll-lines 8)
            (active? #f) (focused? #f) (last-document "/inactive/open.txt")))
(define inactive-collapse-before (collapse-state-snapshot inactive-collapse-state all-fields))
(set! effects '())
(check-equal "inactive collapse is ignored"
             (groot-collapse-all-effects! inactive-collapse-state
                                          (lambda () (record! 'rebuild))
                                          (lambda () (record! 'redraw)))
             'inactive)
(check-equal "inactive collapse makes no mutation or effects"
             (list (collapse-state-snapshot inactive-collapse-state all-fields) effects)
             (list inactive-collapse-before '()))

;; Keep integration tests thin: one success path, one failure path, and dispatch ownership.
(set! effects '())
(set! last-document "/fixture/open.txt")
(check-equal "created file refreshes selects and redraws"
             (groot-created-entry-effects!
              (test-host (lambda () (record! 'refresh))
                         (lambda (path) (set-last-document! path) (record! (list 'select path)) #t)
                         (lambda () (record! 'redraw)))
              (GrootFsCreateResult 'success "/fixture/nested/new.txt" #f #t)
              (lambda (_) #f))
             'revealed)
(check-equal "created file preserves document bookkeeping" last-document "/fixture/open.txt")
(check-equal "created file display effect order" effects '(refresh (select "/fixture/nested/new.txt") redraw))

;; Created directories are collapsed before refresh, so a removed and recreated
;; path cannot inherit expansion state from its prior identity.
(set! effects '())
(define created-directory
  (GrootFsCreateResult 'success "/fixture/recreated" #f #t))
(check-equal "created entry collapses then refreshes reveals and redraws"
             (groot-created-entry-effects!
              (test-host (lambda () (record! 'refresh))
                         (lambda (path) (record! (list 'select path)) #t)
                         (lambda () (record! 'redraw)))
              created-directory
              (lambda (path) (record! (list 'collapse path))))
             'revealed)
(check-equal "created entry collapse happens before display refresh"
             effects
             '((collapse "/fixture/recreated") refresh (select "/fixture/recreated") redraw))

(set! effects '())
(check-equal "created-entry display failure preserves filesystem success"
             (groot-created-entry-effects!
              (test-host (lambda () (record! 'refresh))
                         (lambda (path) (record! (list 'reveal path)) #f)
                         (lambda () (record! 'redraw)))
              created-directory
              (lambda (path) (record! (list 'collapse path))))
             'display-failed)
(check-equal "created-entry display failure does not compensate"
             effects
             '((collapse "/fixture/recreated") refresh (reveal "/fixture/recreated")
               (error "Entry was created at /fixture/recreated, but the tree could not display it.") redraw))

(set! effects '())
(check-equal "created-entry filesystem failure only reports its outcome"
             (groot-created-entry-effects!
              (test-host (lambda () (record! 'refresh))
                         (lambda (path) (record! (list 'reveal path)) #t)
                         (lambda () (record! 'redraw)))
              (GrootFsCreateResult 'native-failure "/fixture/uncertain" "native failed" #f)
              (lambda (path) (record! (list 'collapse path))))
             'native-failure)
(check-equal "mutation-free filesystem failure has no display effects"
             effects
             '((error "Cannot create entry: native failed")))

(set! effects '())
(check-equal "rejected creation reports feedback without display or compensation effects"
             (groot-created-entry-effects!
              (test-host (lambda () (record! 'refresh))
                         (lambda (path) (record! (list 'reveal path)) #t)
                         (lambda () (record! 'redraw)))
              (GrootFsCreateResult 'rejected "/fixture/rejected" "unsafe component" #f)
              (lambda (path) (record! (list 'collapse path))))
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
              (test-host (lambda () (record! 'refresh) (when (equal? phase 'refresh) (error "refresh failed")))
                         (lambda (_) (record! 'reveal) (when (equal? phase 'reveal) (error "reveal failed")) #t)
                         (lambda () (record! 'redraw) (when (equal? phase 'redraw) (error "redraw failed"))))
              created-file
              (lambda (_) (record! 'collapse)))
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
              (test-host (lambda () (record! 'refresh))
                         (lambda (_) (record! 'reveal) #t)
                         (lambda () (record! 'redraw)))
              created-file
              (lambda (_) (error "collapse failed")))
             'display-failed)
(check-equal "collapse exception still refreshes and redraws"
             (filter (lambda (effect) (or (equal? effect 'refresh) (equal? effect 'redraw))) effects)
             '(refresh redraw))

;; Partial filesystem mutation refreshes and redraws without reveal.
(set! effects '())
(check-equal "partial creation refreshes and redraws"
             (groot-created-entry-effects!
              (test-host (lambda () (record! 'refresh))
                         (lambda (_) (record! 'reveal) #t)
                         (lambda () (record! 'redraw)))
              (GrootFsCreateResult 'partial-failure "/fixture/parent/file" "verify failed" #t)
              (lambda (_) (record! 'collapse)))
             'partial-failure)
(check-equal "partial creation skips reveal after refresh" (car effects) 'refresh)

;; Prompt submission passes the already captured context unchanged; cancellation
;; never invokes this callback because the native prompt owns Escape/Ctrl-C.
(set! effects '())
(define captured-context '(captured destination))
(define captured-submit #f)
(groot-create-prompt-effects!
 (GrootHost #f #f #f (lambda (message) (record! (list 'error message))) #f #f
            (lambda (label callback) (list label callback))
            (lambda (component)
   (record! (car component))
   ((cadr component) "nested/file")) #f)
 captured-context "Create in /fixture:"
 (lambda (context submitted)
   (set! captured-submit (list context submitted))
   'result)
 (lambda (result) (record! result)))
(check-equal "create prompt submits the captured destination context once"
             (list captured-submit effects)
             '(((captured destination) "nested/file") ("Create in /fixture:" result)))

;; Every documented key, per mode.  Columns: key, idle tree, pending g,
;; pending z, search results (query set, input closed).
(define (dispatch-in mode key)
  (cond [(equal? mode 'idle) (groot-key-dispatch #t #f #f #f #f #f key)]
        [(equal? mode 'pending-g) (groot-key-dispatch #t #f #f #f #t #f key)]
        [(equal? mode 'pending-z) (groot-key-dispatch #t #f #f #f #f #t key)]
        [(equal? mode 'results) (groot-key-dispatch #t #f #f #t #f #f key)]))
(define dispatch-table
  (list
   ;; key      idle            pending-g      pending-z      results
   (list #\j    'move-down      'move-down     'move-down     'move-down)
   (list 'down  'move-down      'move-down     'move-down     'move-down)
   (list #\k    'move-up        'move-up       'move-up       'move-up)
   (list 'up    'move-up        'move-up       'move-up       'move-up)
   (list #\g    'pending-g      'move-top      'pending-g     'pending-g)
   (list #\e    'clear          'move-bottom   'clear         'clear)
   (list #\G    'move-bottom    'move-bottom   'move-bottom   'move-bottom)
   (list #\z    'pending-z      'pending-z     'center        'pending-z)
   (list #\w    'clear          'jump-start    'clear         'clear)
   (list 'enter 'activate       'activate      'activate      'activate)
   (list 'tab   'toggle         'toggle        'toggle        'toggle)
   (list #\/    'search-start   'search-start  'search-start  'search-start)
   (list 'backspace 'clear      'clear         'clear         'clear)
   (list #\a    'create         'create        'create        'clear)
   (list #\r    'rename         'rename        'rename        'clear)
   (list #\d    'delete         'delete        'delete        'clear)
   (list #\R    'refresh        'refresh       'refresh       'refresh)
   (list 'escape 'focus-editor  'clear         'clear         'clear)
   (list #\q    'close          'close         'close         'close)
   (list #\:    'command-prompt 'command-prompt 'command-prompt 'command-prompt)
   (list #\x    'clear          'clear         'clear         'clear)))
(for-each
 (lambda (row)
   (define key (car row))
   (check-equal (string-append "dispatch table: " (to-string key))
                (map (lambda (mode) (dispatch-in mode key)) '(idle pending-g pending-z results))
                (cdr row)))
 dispatch-table)

;; Mode precedence: focus, then jump labels, then the open search input.
(check-equal "unfocused explorer ignores every key"
             (map (lambda (key) (groot-key-dispatch #f #f #f #f #f #f key)) (list #\j 'escape #\q))
             '(ignore ignore ignore))
(check-equal "jump labels own every key, including a search input underneath"
             (map (lambda (key) (groot-key-dispatch #t #t #t #t #f #f key)) (list #\a 'escape 'enter))
             '(jump jump jump))
(check-equal "an open search input owns text, escape, enter, and backspace"
             (map (lambda (key) (groot-key-dispatch #t #f #t #t #t #f key))
                  (list #\a #\q #\: 'escape 'enter 'backspace 'tab 'down))
             '(search-type search-type search-type search-leave search-leave search-backspace
               consume consume))

(displayln "groot integration tests finished")
