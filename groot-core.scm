;; Pure data and navigation helpers for groot.hx.
;; This module deliberately has no Helix or filesystem dependencies so it can be
;; executed by the standalone Steel test runner.

(provide GrootEntry?
         GrootRow?
         GrootTreeState?
         GrootSearchState?
         GrootNavigationState?
         GrootLifecycleState?
         GrootState?
         GrootState-tree
         GrootState-search
         GrootState-navigation
         GrootState-lifecycle
         groot-entry
         groot-entry-path
         groot-entry-name
         groot-entry-kind
         groot-directory?
         groot-entry-name-uses-theme-accent?
         groot-entry-icon-uses-glyph-color?
         groot-row
         groot-row-entry
         groot-row-depth
         groot-row-prefix
         groot-state
         groot-state-ref
         groot-state-set!
         groot-sort-entries
         groot-path-inside?
         groot-parent-path
         groot-ancestor-paths
         groot-ancestor-chain
         groot-clamp-position
         groot-window-after-move
         groot-scroll-position
         groot-centered-window-start
         groot-jump-label
         groot-jump-character-index
         groot-jump-prefix-valid?
         groot-navigation-delta
         groot-truncate
         groot-truncate-start
         groot-filter-prefix-candidates)

;; Named filesystem entry used across the core, filesystem, and UI layers.
(struct GrootEntry (path name kind) #:transparent)

;; Named rendered row containing an entry, its tree depth, and its drawn tree prefix.
(struct GrootRow (entry depth prefix) #:transparent)

;; Mutable filesystem and flattened-tree state.
(struct GrootTreeState (root children expanded files search-ready rows)
  #:mutable #:transparent)

;; Mutable search query, match, and search-mode state.
(struct GrootSearchState (query results result-count result-rows input)
  #:mutable #:transparent)

;; Mutable keyboard, jump-label, cursor, and viewport state.
(struct GrootNavigationState
  (pending-g pending-z jump-active jump-input jump-alphabet cursor window height scroll-lines)
  #:mutable #:transparent)

;; Mutable component activation, focus, and synchronization state.
(struct GrootLifecycleState (active focused last-document)
  #:mutable #:transparent)

;; Named top-level state groups concerns without relying on symbol-keyed hash storage.
(struct GrootState (tree search navigation lifecycle) #:transparent)

;; Creates the canonical named entry representation.
(define (groot-entry path name kind) (GrootEntry path name kind))

;; Returns an entry's absolute filesystem path.
(define (groot-entry-path entry) (GrootEntry-path entry))

;; Returns an entry's display name.
(define (groot-entry-name entry) (GrootEntry-name entry))

;; Returns an entry kind: 'directory, 'file, or 'symlink.
(define (groot-entry-kind entry) (GrootEntry-kind entry))

;; Reports whether an entry may be expanded in the explorer.
(define (groot-directory? entry) (equal? (groot-entry-kind entry) 'directory))

;; Reports whether an entry name should inherit the theme's semantic accent.
(define (groot-entry-name-uses-theme-accent? entry) (groot-directory? entry))

;; Reports whether an entry icon should retain its glyph palette color.
(define (groot-entry-icon-uses-glyph-color? entry) (not (groot-directory? entry)))

;; Creates a named rendered tree row; prefix holds the drawn branch guides.
(define (groot-row entry depth prefix) (GrootRow entry depth prefix))

;; Returns a rendered row's filesystem entry.
(define (groot-row-entry row) (GrootRow-entry row))

;; Returns a rendered row's indentation depth.
(define (groot-row-depth row) (GrootRow-depth row))

;; Returns a rendered row's tree-guide prefix string.
(define (groot-row-prefix row) (GrootRow-prefix row))

;; Creates a fresh typed session state rooted at root.
(define (groot-state root default-jump-alphabet)
  (GrootState
    (GrootTreeState root (hash) (hash-insert (hash) root #f) '() #f #())
    (GrootSearchState "" '() 0 #() #f)
    (GrootNavigationState #f #f #f "" default-jump-alphabet 0 0 20 3)
    (GrootLifecycleState #t #t #f)))

;; Reads one documented session field through a compatibility boundary.
(define (groot-state-ref state key default)
  (cond [(not state) default]
        [(equal? key 'root) (GrootTreeState-root (GrootState-tree state))]
        [(equal? key 'children) (GrootTreeState-children (GrootState-tree state))]
        [(equal? key 'expanded) (GrootTreeState-expanded (GrootState-tree state))]
        [(equal? key 'files) (GrootTreeState-files (GrootState-tree state))]
        [(equal? key 'search-ready?) (GrootTreeState-search-ready (GrootState-tree state))]
        [(equal? key 'rows) (GrootTreeState-rows (GrootState-tree state))]
        [(equal? key 'query) (GrootSearchState-query (GrootState-search state))]
        [(equal? key 'results) (GrootSearchState-results (GrootState-search state))]
        [(equal? key 'result-count) (GrootSearchState-result-count (GrootState-search state))]
        [(equal? key 'result-rows) (GrootSearchState-result-rows (GrootState-search state))]
        [(equal? key 'search-input?) (GrootSearchState-input (GrootState-search state))]
        [(equal? key 'pending-g?) (GrootNavigationState-pending-g (GrootState-navigation state))]
        [(equal? key 'pending-z?) (GrootNavigationState-pending-z (GrootState-navigation state))]
        [(equal? key 'jump-active?) (GrootNavigationState-jump-active (GrootState-navigation state))]
        [(equal? key 'jump-input) (GrootNavigationState-jump-input (GrootState-navigation state))]
        [(equal? key 'jump-alphabet) (GrootNavigationState-jump-alphabet (GrootState-navigation state))]
        [(equal? key 'cursor) (GrootNavigationState-cursor (GrootState-navigation state))]
        [(equal? key 'window) (GrootNavigationState-window (GrootState-navigation state))]
        [(equal? key 'height) (GrootNavigationState-height (GrootState-navigation state))]
        [(equal? key 'scroll-lines) (GrootNavigationState-scroll-lines (GrootState-navigation state))]
        [(equal? key 'active?) (GrootLifecycleState-active (GrootState-lifecycle state))]
        [(equal? key 'focused?) (GrootLifecycleState-focused (GrootState-lifecycle state))]
        [(equal? key 'last-document) (GrootLifecycleState-last-document (GrootState-lifecycle state))]
        [else (error (string-append "unknown GrootState field: " (to-string key)))]))

;; Mutates one documented session field through a compatibility boundary.
(define (groot-state-set! state key value)
  (cond [(equal? key 'root) (set-GrootTreeState-root! (GrootState-tree state) value)]
        [(equal? key 'children) (set-GrootTreeState-children! (GrootState-tree state) value)]
        [(equal? key 'expanded) (set-GrootTreeState-expanded! (GrootState-tree state) value)]
        [(equal? key 'files) (set-GrootTreeState-files! (GrootState-tree state) value)]
        [(equal? key 'search-ready?) (set-GrootTreeState-search-ready! (GrootState-tree state) value)]
        [(equal? key 'rows) (set-GrootTreeState-rows! (GrootState-tree state) value)]
        [(equal? key 'query) (set-GrootSearchState-query! (GrootState-search state) value)]
        [(equal? key 'results) (set-GrootSearchState-results! (GrootState-search state) value)]
        [(equal? key 'result-count) (set-GrootSearchState-result-count! (GrootState-search state) value)]
        [(equal? key 'result-rows) (set-GrootSearchState-result-rows! (GrootState-search state) value)]
        [(equal? key 'search-input?) (set-GrootSearchState-input! (GrootState-search state) value)]
        [(equal? key 'pending-g?) (set-GrootNavigationState-pending-g! (GrootState-navigation state) value)]
        [(equal? key 'pending-z?) (set-GrootNavigationState-pending-z! (GrootState-navigation state) value)]
        [(equal? key 'jump-active?) (set-GrootNavigationState-jump-active! (GrootState-navigation state) value)]
        [(equal? key 'jump-input) (set-GrootNavigationState-jump-input! (GrootState-navigation state) value)]
        [(equal? key 'jump-alphabet) (set-GrootNavigationState-jump-alphabet! (GrootState-navigation state) value)]
        [(equal? key 'cursor) (set-GrootNavigationState-cursor! (GrootState-navigation state) value)]
        [(equal? key 'window) (set-GrootNavigationState-window! (GrootState-navigation state) value)]
        [(equal? key 'height) (set-GrootNavigationState-height! (GrootState-navigation state) value)]
        [(equal? key 'scroll-lines) (set-GrootNavigationState-scroll-lines! (GrootState-navigation state) value)]
        [(equal? key 'active?) (set-GrootLifecycleState-active! (GrootState-lifecycle state) value)]
        [(equal? key 'focused?) (set-GrootLifecycleState-focused! (GrootState-lifecycle state) value)]
        [(equal? key 'last-document) (set-GrootLifecycleState-last-document! (GrootState-lifecycle state) value)]
        [else (error (string-append "unknown GrootState field: " (to-string key)))]))

;; Sorts entries with directories first and names second.
(define (groot-sort-entries entries)
  (sort entries
        (lambda (left right)
          (cond [(and (groot-directory? left) (not (groot-directory? right))) #t]
                [(and (not (groot-directory? left)) (groot-directory? right)) #f]
                [else (string<? (groot-entry-name left) (groot-entry-name right))]))))

;; Reports whether path is root itself or a descendant on a path-component boundary.
(define (groot-path-inside? root path separator)
  (or (equal? root path)
      (let ([prefix (if (and (> (string-length root) 0)
                             (equal? (string-ref root (- (string-length root) 1))
                                     (string-ref separator 0)))
                        root
                        (string-append root separator))])
        (and (>= (string-length path) (string-length prefix))
             (equal? (substring path 0 (string-length prefix)) prefix)))))

;; Removes one final path component without depending on filesystem state.
(define (groot-parent-path path separator)
  (let loop ([idx (- (string-length path) 1)])
    (cond [(< idx 0) path]
          [(equal? (string-ref path idx) (string-ref separator 0))
           (if (= idx 0) separator (substring path 0 idx))]
          [else (loop (- idx 1))])))

;; Returns directory ancestors from root through the selected file's parent.
(define (groot-ancestor-paths root path separator)
  (if (not (groot-path-inside? root path separator))
      '()
      (let loop ([current (groot-parent-path path separator)] [acc '()])
        (cond [(equal? current root) (cons root acc)]
              [(equal? current path) '()]
              [else (loop (groot-parent-path current separator) (cons current acc))]))))

;; Returns the last count ancestors of path, outermost first, never above root.
;; Search headers use this so a deep parent reads as its own final directories
;; instead of as the whole route from the workspace root.
(define (groot-ancestor-chain root path separator count)
  (let loop ([current path] [remaining count] [acc '()])
    (cond [(equal? current root) (if (null? acc) (list root) acc)]
          [(not (groot-path-inside? root current separator)) (if (null? acc) (list root) acc)]
          [(<= remaining 0) acc]
          [else (loop (groot-parent-path current separator) (- remaining 1) (cons current acc))])))

;; Clamps cursor and window start for count rows and a viewport of height rows.
(define (groot-clamp-position cursor window-start count height)
  (if (<= count 0)
      (list 0 0)
      (let* ([safe-height (max 1 height)]
             [safe-cursor (min (max 0 cursor) (- count 1))]
             [max-start (max 0 (- count safe-height))]
             [safe-start (min (max 0 window-start) max-start safe-cursor)]
             [visible-start (if (< safe-cursor safe-start) safe-cursor safe-start)]
             [visible-end (+ visible-start (- safe-height 1))]
             [final-start (if (> safe-cursor visible-end)
                              (min max-start (- safe-cursor (- safe-height 1)))
                              visible-start)])
        (list safe-cursor final-start))))

;; Moves a cursor by delta and returns the corresponding clamped position.
(define (groot-window-after-move cursor window-start count height delta)
  (groot-clamp-position (+ cursor delta) window-start count height))

;; Scrolls a viewport by amount rows and keeps the selected row inside it.
(define (groot-scroll-position cursor window-start count height amount direction)
  (if (<= count 0)
      '(0 0)
      (let* ([safe-height (max 1 height)]
             [max-start (max 0 (- count safe-height))]
             [delta (max 1 amount)]
             [next-start (cond [(equal? direction 'up) (max 0 (- window-start delta))]
                               [(equal? direction 'down) (min max-start (+ window-start delta))]
                               [else window-start])]
             [next-cursor (cond [(< cursor next-start) next-start]
                                [(> cursor (+ next-start (- safe-height 1)))
                                 (min (- count 1) (+ next-start (- safe-height 1)))]
                                [else cursor])])
        (groot-clamp-position next-cursor next-start count safe-height))))

;; Centers cursor in a viewport while respecting the first and final row bounds.
(define (groot-centered-window-start cursor count height)
  (let* ([safe-height (max 1 height)]
         [max-start (max 0 (- count safe-height))])
    (min max-start (max 0 (- cursor (quotient safe-height 2))))))

;; Returns a stable two-character jump label for a visible row, or an empty string when exhausted.
(define (groot-jump-label alphabet index)
  (define base (string-length alphabet))
  (if (<= base 0)
      ""
      (let ([first (quotient index base)] [second (remainder index base)])
        (if (< first base)
            (string-append (string (string-ref alphabet first)) (string (string-ref alphabet second)))
            ""))))

;; Returns a configured jump character's alphabet index, or false when it is invalid.
(define (groot-jump-character-index alphabet character)
  (let loop ([index 0])
    (cond [(>= index (string-length alphabet)) #f]
          [(equal? (string-ref alphabet index) character) index]
          [else (loop (+ index 1))])))

;; Reports whether a first jump-label group contains at least one visible row.
(define (groot-jump-prefix-valid? group-start visible-count)
  (< group-start visible-count))

;; Maps normal-mode j/k characters to their signed row movement.
(define (groot-navigation-delta character)
  (cond [(equal? character #\j) 1]
        [(equal? character #\k) -1]
        [else #f]))

;; Truncates text to a cell budget, reserving one cell for an ellipsis when needed.
(define (groot-truncate text width)
  (cond [(<= width 0) ""]
        [(<= (string-length text) width) text]
        [(= width 1) "…"]
        [else (string-append (substring text 0 (- width 1)) "…")]))

;; Truncates text from the front, keeping the tail visible. An input grows at
;; its end, so the newest characters are the ones that must stay on screen.
(define (groot-truncate-start text width)
  (define length (string-length text))
  (cond [(<= width 0) ""]
        [(<= length width) text]
        [(= width 1) "…"]
        [else (string-append "…" (substring text (- length (- width 1)) length))]))

;; Narrows a candidate list after a query grows; callers keep ranking in their matcher.
(define (groot-filter-prefix-candidates previous-query query all-files previous-results)
  (if (and (not (equal? previous-query ""))
           (>= (string-length query) (string-length previous-query))
           (equal? (substring query 0 (string-length previous-query)) previous-query))
      previous-results
      all-files))
