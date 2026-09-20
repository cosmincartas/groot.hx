;; Tree and navigation model for groot.hx: cached directory listings, the
;; flattened visible rows, expansion, reveal, cursor movement, and jump labels.
;; Every function takes the session state first.  Nothing here needs Helix, so
;; the standalone test runner exercises it against real fixture directories.

(require "groot-core.scm")
(require "groot-path.scm")
(require "groot-view.scm")
(require "groot-fs.scm")

(provide groot-searching?
         groot-active-items
         groot-active-count
         groot-current-row
         groot-ignored?
         groot-cache-listing!
         groot-load-directory!
         groot-children
         groot-visible-tree
         groot-rebuild-tree!
         groot-open-ancestors!
         groot-find-index
         groot-clamp!
         groot-reveal!
         groot-toggle-current!
         groot-refresh-tree!
         groot-refresh-tree-after-deletion!
         groot-migrate-expanded-subtree!
         groot-drop-expanded-subtree!
         groot-selectable-index
         groot-move!
         groot-move-top!
         groot-move-bottom!
         groot-center-cursor!
         groot-scroll!
         groot-visible-count
         groot-clear-pending!
         groot-clear-jump!
         groot-enter-jump!
         groot-jump-type!)

;; Returns true when the explorer is displaying search results.
(define (groot-searching? state) (not (equal? (groot-state-query state) "")))

;; Returns the currently active vector, materialized only at state transitions.
(define (groot-active-items state)
  (if (groot-searching? state) (groot-state-result-rows state) (groot-state-rows state)))

;; Returns the number of active rows without repeatedly traversing a list during movement.
(define (groot-active-count state) (vector-length (groot-active-items state)))

;; Returns the selected display row or false when the explorer is empty.
(define (groot-current-row state)
  (define items (groot-active-items state))
  (and (> (vector-length items) 0) (vector-ref items (groot-state-cursor state))))

;; Reports whether an entry name is excluded by the explorer's fixed safe defaults.
(define (groot-ignored? state entry)
  (hashset-contains? (groot-state-ignored state) (groot-entry-name entry)))

;; Caches one directory listing with ignored names already removed, so every
;; later lookup is a single hash read.
(define (groot-cache-listing! state path entries)
  (set-groot-state-children! state
                             (hash-insert (groot-state-children state) path
                                          (filter (lambda (entry) (not (groot-ignored? state entry)))
                                                  entries))))

;; Reads and caches one directory only once during a session.
(define (groot-load-directory! state path)
  (unless (hash-contains? (groot-state-children state) path)
    (groot-cache-listing! state path (groot-fs-read-directory path))))

;; Returns cached children for path, loading them lazily when first expanded.
(define (groot-children state path)
  (groot-load-directory! state path)
  (or (hash-try-get (groot-state-children state) path) '()))

;; Recursively materializes only expanded cached directories into display rows.
(define (groot-visible-tree state)
  ;; prefix carries the ancestor guides; last? picks this row's elbow.
  (define (walk entry depth prefix last? acc)
    (define next
      (cons (groot-row entry depth
                       (if (= depth 0) "" (string-append prefix (if last? "└╴" "├╴"))))
            acc))
    (if (and (groot-directory? entry)
             (groot-expanded? state (groot-entry-path entry)))
        (let ([child-prefix
               (if (= depth 0) "" (string-append prefix (if last? "  " "│ ")))])
          (let loop ([items (groot-children state (groot-entry-path entry))] [rows next])
            (if (null? items)
                rows
                (loop (cdr items)
                      (walk (car items) (+ depth 1) child-prefix (null? (cdr items)) rows)))))
        next))
  (define root-entry (groot-entry (groot-state-root state) (file-name (groot-state-root state)) 'directory))
  (reverse (walk root-entry 0 "" #t '())))

;; Rebuilds the vector rendered by the tree only after a cache or fold transition.
(define (groot-rebuild-tree! state) (set-groot-state-rows! state (list->vector (groot-visible-tree state))))

;; Opens each cached ancestor needed to reveal a document path.
(define (groot-open-ancestors! state path)
  (define root (groot-state-root state))
  (define separator (path-separator))
  (when (groot-path-inside? root path separator)
    (define expanded (groot-state-expanded state))
    (define (cached-path parent expected)
      (let loop ([entries (groot-children state parent)])
        (cond [(null? entries) expected]
              [(groot-path=? (groot-entry-path (car entries)) expected separator)
               (groot-entry-path (car entries))]
              [else (loop (cdr entries))])))
    (let loop ([ancestors (groot-ancestor-paths root path separator)] [parent root])
      (unless (null? ancestors)
        (define ancestor (if (groot-path=? (car ancestors) root separator)
                             root
                             (cached-path parent (car ancestors))))
        (groot-load-directory! state ancestor)
        (set! expanded (hash-insert expanded ancestor #t))
        (loop (cdr ancestors) ancestor)))
    (set-groot-state-expanded! state expanded)
    (groot-rebuild-tree! state)))

;; Finds a path inside the current active vector.
(define (groot-find-index state path)
  (define items (groot-active-items state))
  (define separator (path-separator))
  (let loop ([idx 0])
    (cond [(>= idx (vector-length items)) #f]
          [(groot-path=? (groot-entry-path (groot-row-entry (vector-ref items idx)))
                         path separator) idx]
          [else (loop (+ idx 1))])))

;; Keeps cursor and viewport valid after any state transition or terminal resize.
(define (groot-clamp! state)
  (define position (groot-clamp-position (groot-state-cursor state) (groot-state-window state)
                                         (groot-active-count state) (groot-state-height state)))
  (set-groot-state-cursor! state (car position))
  (set-groot-state-window! state (cadr position)))

;; Reveals path when it belongs to this workspace and remembers failed attempts too.
;; A true result means the rebuilt active rows actually contain and select path.
(define (groot-reveal! state path)
  (set-groot-state-last-document! state path)
  (define root (groot-state-root state))
  (define separator (path-separator))
  (and (string? path) (groot-path-inside? root path separator)
       (let ([idx (if (groot-path=? path root separator)
                      ;; Root is already the rebuilt tree's synthetic row.  Do not
                      ;; derive its parent: at / that traversal cannot progress.
                      (groot-find-index state root)
                      (begin
                        (groot-open-ancestors! state path)
                        (groot-find-index state path)))])
         (and idx (begin (set-groot-state-cursor! state idx) (groot-clamp! state) #t)))))

;; Toggles the selected directory and keeps the selection visible.
(define (groot-toggle-current! state)
  (define row (groot-current-row state))
  (when (and row (groot-directory? (groot-row-entry row)))
    (define path (groot-entry-path (groot-row-entry row)))
    (groot-set-expanded! state path (not (groot-expanded? state path)))
    (groot-rebuild-tree! state)
    (groot-clamp! state)))

;; Clears every filesystem cache and reconstructs the root listing.
(define (groot-refresh-tree! state)
  (define root (groot-state-root state))
  (set-groot-state-children! state (hash))
  (set-groot-state-files! state '())
  (set-groot-state-search-ready! state #f)
  (groot-load-directory! state root)
  (groot-rebuild-tree! state)
  (groot-clamp! state))

;; Deletion recovery cannot use the display reader: its suppressed error and
;; synthetic root row would falsely prove the root is available. On failure,
;; leave an empty, clamped tree state without recreating anything and return an
;; explicit result for the integration layer's combined outcome message.
(define (groot-refresh-tree-after-deletion! state)
  (define root (groot-state-root state))
  (set-groot-state-children! state (hash))
  (set-groot-state-files! state '())
  (set-groot-state-search-ready! state #f)
  (with-handler
   (lambda (error)
     ;; Cache an explicitly unavailable empty root so rebuilding cannot fall
     ;; through to groot-fs-read-directory's display-only suppression.
     (groot-cache-listing! state root '())
     (groot-rebuild-tree! state)
     (groot-clamp! state)
     (list 'root-unavailable (to-string error)))
   (begin
     (groot-cache-listing! state root (groot-fs-read-directory/strict root))
     (groot-rebuild-tree! state)
     (groot-clamp! state)
     'refreshed)))

;; Moves cached expansion state with a renamed directory.  The next refresh
;; drops listings, but expansion keys must retain their new identities so reveal
;; can rebuild the same expanded destination subtree without stale source keys.
(define (groot-migrate-expanded-subtree! state source destination)
  (define separator (path-separator))
  (define (migrate path)
    (if (groot-path-inside? source path separator)
        (string-append destination (substring path (string-length source) (string-length path)))
        path))
  (define (copy pairs expanded)
    (if (null? pairs)
        expanded
        (let ([pair (car pairs)])
          (copy (cdr pairs)
                (hash-insert expanded (migrate (car pair)) (cdr pair))))))
  (set-groot-state-expanded! state (copy (hash->list (groot-state-expanded state)) (hash))))

;; Drops folded-state identities at and beneath a deleted entry.  Listings and
;; search indexes are cleared separately by the refresh below.
(define (groot-drop-expanded-subtree! state source)
  (define separator (path-separator))
  (define (copy pairs result)
    (if (null? pairs)
        result
        (let ([pair (car pairs)])
          (copy (cdr pairs)
                (if (groot-path-inside? source (car pair) separator)
                    result
                    (hash-insert result (car pair) (cdr pair)))))))
  (set-groot-state-expanded! state (copy (hash->list (groot-state-expanded state)) (hash))))

;; Returns the nearest selectable row, preferring the direction of travel.
;; Search headers are labels, so j/k step over them instead of landing on one.
(define (groot-selectable-index state index step)
  (define items (groot-active-items state))
  (define count (vector-length items))
  (define (header? i) (groot-directory? (groot-row-entry (vector-ref items i))))
  (define (scan i direction)
    (cond [(or (< i 0) (>= i count)) #f]
          [(not (header? i)) i]
          [else (scan (+ i direction) direction)]))
  (if (or (< index 0) (>= index count) (not (header? index)))
      index
      (or (scan index step) (scan index (- 0 step)) index)))

;; Moves selection by delta rows.
(define (groot-move! state delta)
  (define position (groot-window-after-move (groot-state-cursor state) (groot-state-window state)
                                             (groot-active-count state) (groot-state-height state) delta))
  (define cursor
    (if (groot-searching? state)
        (groot-selectable-index state (car position) (if (< delta 0) -1 1))
        (car position)))
  (define final (groot-clamp-position cursor (cadr position)
                                      (groot-active-count state) (groot-state-height state)))
  (set-groot-state-cursor! state (car final))
  (set-groot-state-window! state (cadr final)))

;; Moves selection to the first active row.
(define (groot-move-top! state)
  (set-groot-state-cursor! state (if (groot-searching? state) (groot-selectable-index state 0 1) 0))
  (set-groot-state-window! state 0))

;; Moves selection to the final active row and makes it visible.
(define (groot-move-bottom! state)
  (define count (groot-active-count state))
  (when (> count 0)
    (set-groot-state-cursor! state (if (groot-searching? state)
                                       (groot-selectable-index state (- count 1) -1)
                                       (- count 1)))
    (set-groot-state-window! state (max 0 (- count (groot-state-height state))))))

;; Centers the selected row in the active viewport.
(define (groot-center-cursor! state)
  (set-groot-state-window! state (groot-centered-window-start (groot-state-cursor state)
                                                              (groot-active-count state)
                                                              (groot-state-height state))))

;; Scrolls the cached viewport by a mouse-wheel direction.
(define (groot-scroll! state direction)
  (define position (groot-scroll-position (groot-state-cursor state) (groot-state-window state)
                                           (groot-active-count state) (groot-state-height state)
                                           (groot-state-scroll-lines state) direction))
  (set-groot-state-cursor! state (car position))
  (set-groot-state-window! state (cadr position)))

;; Returns the number of rows presently visible in the active viewport.
(define (groot-visible-count state)
  (min (groot-state-height state) (max 0 (- (groot-active-count state) (groot-state-window state)))))

;; Clears incomplete normal-mode g and z prefixes.
(define (groot-clear-pending! state)
  (set-groot-state-pending-g! state #f)
  (set-groot-state-pending-z! state #f))

;; Leaves jump mode and restores regular command handling.
(define (groot-clear-jump! state)
  (set-groot-state-jump-active! state #f)
  (set-groot-state-jump-input! state "")
  (groot-clear-pending! state))

;; Enters visible-row jump mode labelled from alphabet.
(define (groot-enter-jump! state alphabet)
  (groot-clear-pending! state)
  (set-groot-state-search-input! state #f)
  (set-groot-state-jump-alphabet! state alphabet)
  (set-groot-state-jump-input! state "")
  (set-groot-state-jump-active! state #t))

;; Implements Helix's two-key jump-label acceptance and cancellation behavior.
(define (groot-jump-type! state character)
  (define alphabet (groot-state-jump-alphabet state))
  (define alphabet-size (string-length alphabet))
  (define character-index (groot-jump-character-index alphabet character))
  (define first-input (groot-state-jump-input state))
  (cond [(not character-index) (groot-clear-jump! state)]
        [(equal? first-input "")
         (define outer (* character-index alphabet-size))
         ;; This mirrors Helix: reject a first character whose label group cannot exist.
         (if (groot-jump-prefix-valid? outer (groot-visible-count state))
             (set-groot-state-jump-input! state (string character))
             (groot-clear-jump! state))]
        [else
         (define first-index (groot-jump-character-index alphabet (string-ref first-input 0)))
         (define row (+ (* first-index alphabet-size) character-index))
         (when (< row (groot-visible-count state))
           (set-groot-state-cursor! state
                                    (let ([index (+ (groot-state-window state) row)])
                                      (if (groot-searching? state) (groot-selectable-index state index 1) index)))
           (groot-clamp! state))
         (groot-clear-jump! state)]))
