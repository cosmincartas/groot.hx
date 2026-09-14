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
         groot-path=?
         groot-path-inside?
         groot-parent-path
         groot-rename-prompt-label
         groot-rename-destination
         groot-rename-open-document-conflict?
         groot-create-destination
         groot-create-prompt-label-budget
         groot-create-prompt-host-byte-width
         groot-create-prompt-cell-width
         groot-create-prompt-remaining-input
         groot-create-prompt-label
         groot-delete-prompt-label
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

;; Windows paths identify the same entry regardless of case; POSIX paths do not.
(define (groot-path=? left right separator)
  (and (string? left) (string? right)
       (if (equal? separator "\\") (string-ci=? left right) (equal? left right))))

;; Reports whether path is root itself or a descendant on a path-component boundary.
(define (groot-path-inside? root path separator)
  (or (groot-path=? root path separator)
      (let ([prefix (if (and (> (string-length root) 0)
                             (equal? (string-ref root (- (string-length root) 1))
                                     (string-ref separator 0)))
                        root
                        (string-append root separator))])
        (and (>= (string-length path) (string-length prefix))
             (groot-path=? (substring path 0 (string-length prefix)) prefix separator)))))

;; Reports whether path is a Windows drive root such as C:\\.
(define (groot-windows-drive-root? path separator)
  (and (equal? separator "\\")
       (= (string-length path) 3)
       (equal? (string-ref path 1) #\:)
       (equal? (string-ref path 2) (string-ref separator 0))))

;; Removes one final path component without depending on filesystem state.
(define (groot-parent-path path separator)
  (if (groot-windows-drive-root? path separator)
      path
      (let loop ([idx (- (string-length path) 1)])
        (cond [(< idx 0) path]
              [(equal? (string-ref path idx) (string-ref separator 0))
               (cond [(= idx 0) separator]
                     [(and (= idx 2)
                           (equal? separator "\\")
                           (equal? (string-ref path 1) #\:))
                      (substring path 0 3)]
                     [else (substring path 0 idx)])]
              [else (loop (- idx 1))]))))

;; Produces the native prompt label while reserving room for filename input.
(define (groot-rename-prompt-label name prompt-width)
  (define prefix "Rename ")
  (define suffix ":")
  (define width (groot-create-prompt-label-budget prompt-width))
  (string-append
   prefix
   (groot-truncate-start-prompt
    name
    (max 0 (- width (groot-create-prompt-cell-width prefix)
              (groot-create-prompt-cell-width suffix)))
    (max 0 (- width (groot-create-prompt-byte-budget-width prefix)
              (groot-create-prompt-byte-budget-width suffix))))
   suffix))

;; Constructs a renamed entry beside source without normalizing its name.
(define (groot-rename-destination source submitted-name separator)
  (define parent (groot-parent-path source separator))
  (string-append parent
                 (if (and (>= (string-length parent) (string-length separator))
                          (equal? (substring parent
                                             (- (string-length parent) (string-length separator))
                                             (string-length parent))
                                  separator))
                     ""
                     separator)
                 submitted-name))

;; Reports whether any open filesystem-backed document is source itself or a
;; descendant on an exact component boundary.
(define (groot-rename-open-document-conflict? source document-paths separator)
  (let loop ([remaining document-paths])
    (and (not (null? remaining))
         (or (and (string? (car remaining))
                  (groot-path-inside? source (car remaining) separator))
             (loop (cdr remaining))))))

;; Captures the directory where a new child belongs. Symlinks are leaves, so
;; like files they use their lexical parent rather than their target.
(define (groot-create-destination root entry separator)
  (cond [(not entry) root]
        [(groot-directory? entry) (groot-entry-path entry)]
        [else (groot-parent-path (groot-entry-path entry) separator)]))

;; The native prompt keeps two columns clear at its right edge.  Each caller
;; reserves the input it requires from the remaining label budget.
(define (groot-prompt-label-budget prompt-width input-width)
  (max 0 (- (max 1 prompt-width) 2 input-width)))

;; Leave eight columns for a usable filename editor, even when a narrow UI
;; supplies the prompt. This preserves the existing create and rename budget.
(define (groot-create-prompt-label-budget prompt-width)
  (max 1 (groot-prompt-label-budget prompt-width 8)))

;; Builds a deletion confirmation label or returns the explicit
;; `insufficient-space` outcome.  Four columns remain after the label for the
;; exact `yes` confirmation and the native prompt cursor; Helix reserves two
;; additional columns at the right edge.
(define (groot-delete-prompt-label name kind prompt-width)
  (define prefix "Permanently delete ")
  (define suffix
    (cond [(equal? kind 'file) "? Type yes:"]
          [(equal? kind 'symlink) " current? Type yes:"]
          [(equal? kind 'directory) "/ and ALL contents? Type yes:"]
          [else #f]))
  (define label-budget (groot-prompt-label-budget prompt-width 4))
  (define (fits? label)
    (and (>= label-budget 0)
         (<= (groot-create-prompt-cell-width label) label-budget)
         (<= (groot-create-prompt-byte-budget-width label) label-budget)
         (>= (groot-create-prompt-remaining-input prompt-width label) 4)))
  (if (or (not suffix) (= (string-length name) 0))
      'insufficient-space
      (let* ([final-character (string (string-ref name (- (string-length name) 1)))]
             [target-cell-budget (- label-budget
                                    (groot-create-prompt-cell-width prefix)
                                    (groot-create-prompt-cell-width suffix))]
             [target-byte-budget (- label-budget
                                    (groot-create-prompt-byte-budget-width prefix)
                                    (groot-create-prompt-byte-budget-width suffix))]
             ;; Refuse instead of replacing the target with only an ellipsis:
             ;; confirmation must still identify the captured entry.
             [minimum-label (string-append prefix final-character suffix)])
        (if (or (not (fits? minimum-label))
                (<= target-cell-budget 0)
                (<= target-byte-budget 0))
            'insufficient-space
            (let ([label (string-append
                          prefix
                          (groot-truncate-start-prompt name target-cell-budget target-byte-budget)
                          suffix)])
              (if (fits? label) label 'insufficient-space))))))

;; Helix clips prompt text using Rust String::len(), which is a UTF-8 byte
;; offset. This is the actual host offset, not Steel's character count.
(define (groot-create-prompt-host-byte-width text)
  (let loop ([index 0] [width 0])
    (if (>= index (string-length text))
        width
        (let ([codepoint (char->integer (string-ref text index))])
          (loop (+ index 1)
                (+ width (cond [(< codepoint #x80) 1]
                               [(< codepoint #x800) 2]
                               [(< codepoint #x10000) 3]
                               [else 4])))))))

;; Conservatively estimates terminal cells without a host Unicode-width API:
;; ASCII consumes one cell and every other scalar is budgeted as two. This can
;; shorten ambiguous-width text, but cannot let it steal editor columns.
(define (groot-create-prompt-cell-width text)
  (let loop ([index 0] [width 0])
    (if (>= index (string-length text))
        width
        (loop (+ index 1)
              (+ width (if (< (char->integer (string-ref text index)) 128) 1 2))))))

;; Budget UTF-8 conservatively: non-ASCII may occupy four host bytes, except
;; the truncation ellipsis, whose UTF-8 representation is exactly three bytes.
(define (groot-create-prompt-byte-budget-width text)
  (let loop ([index 0] [width 0])
    (if (>= index (string-length text))
        width
        (let ([codepoint (char->integer (string-ref text index))])
          (loop (+ index 1)
                (+ width (cond [(< codepoint #x80) 1]
                               [(= codepoint #x2026) 3]
                               [else 4])))))))

;; Retains the identifying tail while respecting display cells and Helix's
;; UTF-8 byte offset. The ellipsis itself costs two conservative cells and
;; three bytes.
(define (groot-truncate-start-prompt text cell-width byte-width)
  (cond [(or (<= cell-width 0) (<= byte-width 0)) ""]
        [(and (<= (groot-create-prompt-cell-width text) cell-width)
              (<= (groot-create-prompt-byte-budget-width text) byte-width)) text]
        [(or (< cell-width 1) (< byte-width 3)) "."]
        [else
         (let loop ([index (- (string-length text) 1)] [tail ""] [cells 2] [bytes 3])
           (if (< index 0)
               (string-append "…" tail)
               (let* ([character (string (string-ref text index))]
                      [character-cells (groot-create-prompt-cell-width character)]
                      [character-bytes (groot-create-prompt-byte-budget-width character)])
                 (if (or (> (+ cells character-cells) cell-width)
                         (> (+ bytes character-bytes) byte-width))
                     (string-append "…" tail)
                     (loop (- index 1) (string-append character tail)
                           (+ cells character-cells) (+ bytes character-bytes))))))]))

;; Reports the editor width left after Helix's right margin and its byte-based
;; prompt offset have been accounted for.
(define (groot-create-prompt-remaining-input prompt-width label)
  (max 0 (- (max 1 prompt-width) 2 (groot-create-prompt-host-byte-width label))))

;; Keeps a native prompt label bounded, retaining the destination tail that
;; identifies the selected directory while reserving a filename editor.
(define (groot-create-prompt-label destination prompt-width)
  (define width (groot-create-prompt-label-budget prompt-width))
  (define suffix ":")
  ;; Preserve UI-1's approved wording whenever it and a meaningful destination
  ;; tail fit. Narrow prompts use the compact label to retain input space.
  (define prefix (cond [(<= width 12) "Create:"]
                       [(<= width 18) "Create: "]
                       [else "Create in "]))
  (define (truncate-destination label-prefix)
    (groot-truncate-start-prompt
     destination
     (max 0 (- width (groot-create-prompt-cell-width label-prefix)
               (groot-create-prompt-cell-width suffix)))
     (max 0 (- width (groot-create-prompt-byte-budget-width label-prefix)
               (groot-create-prompt-byte-budget-width suffix)))))
  (define shortened-destination (truncate-destination prefix))
  ;; A four-byte destination tail cannot accompany even the compact prefix at
  ;; 22 columns. Prefer the identifying tail to that cosmetic prompt prefix.
  (define label-prefix
    (if (and (equal? shortened-destination "…") (> (string-length destination) 0))
        ""
        prefix))
  (groot-truncate-start-prompt
   (string-append label-prefix (truncate-destination label-prefix) suffix)
   width width))

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
