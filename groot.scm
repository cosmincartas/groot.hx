;; groot.hx: a cached, lazy file explorer for Helix.

(require "helix/components.scm")
(require "helix/editor.scm")
(require "helix/ext.scm")
(require "helix/misc.scm")
(require "helix/static.scm")
(require (prefix-in helix.config. "helix/configuration.scm"))
(require (prefix-in helix. "helix/commands.scm"))
(require "glyph/glyph.scm")
(require "groot/groot-core.scm")
(require "groot/groot-fs.scm")
(require "groot/groot-integration.scm")

(provide groot-open groot-refresh groot-configure!)

;; Sidebar width in terminal cells.
(define *groot-width* 32)
;; Sidebar placement; valid values are 'left and 'right.
(define *groot-side* 'left)
;; Directory names excluded from both the tree and the deferred search index.
;; Result rows built per keystroke. Ranked matches past this point are
;; unreachable by scrolling long before they are worth the cost of building.
(define *groot-max-results* 200)
(define *groot-ignored-names* '(".git" ".hg" ".direnv" "node_modules" "target" "__pycache__"))
;; Set form used for per-entry lookups while the list form is passed to the finder.
(define *groot-ignored-set* (apply hashset *groot-ignored-names*))
;; First row of the results list, below the three-row input frame.
(define *groot-list-top* 3)
;; Title centred on the input frame's top border.
(define *groot-input-title* "Explore")
;; Prompt glyph and caret for the search input, mirroring a picker input line.
(define *groot-search-icon* "")
(define *groot-search-caret* "▌")
;; Icon shown for an expanded directory; glyph.hx only ships closed-folder variants.
(define *groot-open-dir-icon* "󰝰")
;; Current named explorer state, or false before the first session opens.
(define *groot-state* #f)
;; Prevents duplicate global hook registration.
(define *groot-hooks-installed?* #f)
;; Last rendered terminal rectangle used by mouse event handling.
(define *groot-last-rect* #f)
;; Terminal mouse kind emitted for a left-button press.
(define *groot-mouse-left-down* 0)
;; Terminal mouse kind emitted for a downward wheel tick.
(define *groot-mouse-scroll-down* 10)
;; Terminal mouse kind emitted for an upward wheel tick.
(define *groot-mouse-scroll-up* 11)
;; Commands that may remove the focused editor view before post-command hooks run.
(define *groot-view-teardown-commands*
  (hashset "quit" "q" "quit!" "q!" "quit-all" "qa" "quit-all!" "qa!"
           "write-quit" "wq" "write-quit!" "wq!" "write-quit-all" "wqa" "xa"
           "write-quit-all!" "wqa!" "xa!" "exit" "x" "xit" "exit!" "x!" "xit!"
           "cquit" "cq" "cquit!" "cq!" "buffer-close" "bc" "bclose"
           "buffer-close!" "bc!" "bclose!" "buffer-close-others" "bco" "bcloseother"
           "buffer-close-others!" "bco!" "bcloseother!" "buffer-close-all" "bca"
           "bcloseall" "buffer-close-all!" "bca!" "bcloseall!" "write-buffer-close"
           "wbc" "write-buffer-close!" "wbc!"))
;; Fallback labels used when Helix does not expose a usable jump-label alphabet.
(define *groot-default-jump-alphabet* "abcdefghijklmnopqrstuvwxyz")

;; Reads a state field with a default for defensive event handling.
(define (groot-get key default)
  (groot-state-ref *groot-state* key default))

;; Replaces one named state field in the current session.
(define (groot-put! key value) (groot-state-set! *groot-state* key value))

;; Requests a redraw after queued component or clipping mutations have completed.
(define (groot-request-redraw!)
  (enqueue-thread-local-callback (lambda () (helix.redraw))))

;; Normalizes the public side configuration value.
(define (groot-configure! side)
  (unless (or (equal? side 'left) (equal? side 'right))
    (error "groot-configure!: side must be 'left or 'right"))
  (set! *groot-side* side))

;; Returns the workspace root once per session rather than per rendered row.
(define (groot-workspace) (helix-find-workspace))

;; Reads Helix's wheel distance once for this explorer session.
(define (groot-config-scroll-lines)
  (with-handler (lambda (_) 3)
    (let ([value (helix.config.get-config-option-value "scroll-lines")])
      (if (number? value) (max 1 (inexact->exact (floor (abs value)))) 3))))

;; Returns the state root.
(define (groot-root) (groot-get 'root ""))

;; Returns true when the explorer is displaying search results.
(define (groot-searching?) (not (equal? (groot-get 'query "") "")))

;; Returns the currently active vector, materialized only at state transitions.
(define (groot-active-items)
  (if (groot-searching?) (groot-get 'result-rows #()) (groot-get 'rows #())))

;; Returns the number of active rows without repeatedly traversing a list during movement.
(define (groot-active-count) (vector-length (groot-active-items)))

;; Reads and caches one directory only once during a session.
(define (groot-load-directory! path)
  (define children (groot-get 'children (hash)))
  (unless (hash-contains? children path)
    (groot-put! 'children (hash-insert children path (groot-fs-read-directory path)))))

;; Reports whether an entry name is excluded by the explorer's fixed safe defaults.
(define (groot-ignored? entry) (hashset-contains? *groot-ignored-set* (groot-entry-name entry)))

;; Returns cached children for path, loading them lazily when first expanded.
(define (groot-children path)
  (groot-load-directory! path)
  (let ([children (groot-get 'children (hash))])
    (filter (lambda (entry) (not (groot-ignored? entry)))
            (if (hash-contains? children path) (hash-try-get children path) '()))))

;; Recursively materializes only expanded cached directories into display rows.
(define (groot-visible-tree)
  (define expanded (groot-get 'expanded (hash)))
  ;; prefix carries the ancestor guides; last? picks this row's elbow.
  (define (walk entry depth prefix last? acc)
    (define next
      (cons (groot-row entry depth
                       (if (= depth 0) "" (string-append prefix (if last? "└╴" "├╴"))))
            acc))
    (if (and (groot-directory? entry)
             (not (if (hash-contains? expanded (groot-entry-path entry))
                      (hash-try-get expanded (groot-entry-path entry))
                      #t)))
        (let ([child-prefix
               (if (= depth 0) "" (string-append prefix (if last? "  " "│ ")))])
          (let loop ([items (groot-children (groot-entry-path entry))] [rows next])
            (if (null? items)
                rows
                (loop (cdr items)
                      (walk (car items) (+ depth 1) child-prefix (null? (cdr items)) rows)))))
        next))
  (define root-entry (groot-entry (groot-root) (file-name (groot-root)) 'directory))
  (reverse (walk root-entry 0 "" #t '())))

;; Rebuilds the vector rendered by the tree only after a cache or fold transition.
(define (groot-rebuild-tree!) (groot-put! 'rows (list->vector (groot-visible-tree))))

;; Opens each cached ancestor needed to reveal a document path.
(define (groot-open-ancestors! path)
  (define root (groot-root))
  (define separator (path-separator))
  (when (groot-path-inside? root path separator)
    (define expanded (groot-get 'expanded (hash)))
    (for-each (lambda (ancestor)
                (groot-load-directory! ancestor)
                (set! expanded (hash-insert expanded ancestor #f)))
              (groot-ancestor-paths root path separator))
    (groot-put! 'expanded expanded)
    (groot-rebuild-tree!)))

;; Finds a path inside the current active vector.
(define (groot-find-index path)
  (define items (groot-active-items))
  (let loop ([idx 0])
    (cond [(>= idx (vector-length items)) #f]
          [(equal? (groot-entry-path (groot-row-entry (vector-ref items idx))) path) idx]
          [else (loop (+ idx 1))])))

;; Keeps cursor and viewport valid after any state transition or terminal resize.
(define (groot-clamp! )
  (define position (groot-clamp-position (groot-get 'cursor 0) (groot-get 'window 0)
                                         (groot-active-count) (groot-get 'height 1)))
  (groot-put! 'cursor (car position))
  (groot-put! 'window (cadr position)))

;; Reveals path when it belongs to this workspace and remembers failed attempts too.
(define (groot-reveal! path)
  (groot-put! 'last-document path)
  (when (and (string? path) (groot-path-inside? (groot-root) path (path-separator)))
    (groot-open-ancestors! path)
    (let ([idx (groot-find-index path)])
      (when idx (groot-put! 'cursor idx) (groot-clamp!)))))

;; Reads the focused editor document path without allowing UI errors to escape.
(define (groot-current-document-path)
  (with-handler (lambda (_) #f)
    (if (editor-focused-buffer-area)
        (let ([focus (editor-focus)]) (editor-document->path (editor->doc-id focus)))
        #f)))

;; Synchronizes selection only when the document actually changed.
(define (groot-sync-current-file!)
  (when (and (groot-get 'active? #f) (not (groot-get 'focused? #f)) (not (groot-searching?)))
    (define path (groot-current-document-path))
    (unless (equal? path (groot-get 'last-document #f)) (groot-reveal! path))))

;; Converts hook command payloads to names accepted by the teardown command set.
(define (groot-command-name command)
  (cond [(string? command) command]
        [(symbol? command) (symbol->string command)]
        [else ""]))

;; Synchronizes only after commands that leave a valid focused editor view.
(define (groot-post-command-sync! command)
  (unless (hashset-contains? *groot-view-teardown-commands* (groot-command-name command))
    (groot-sync-current-file!)))

;; Walks the tree in process, skipping symlink recursion. Correct but single
;; threaded, so it also caches every directory it visits; only used as a fallback.
(define (groot-walk-files root)
  (define files '())
  (define (walk directory)
    (for-each (lambda (entry)
                (cond [(groot-directory? entry) (walk (groot-entry-path entry))]
                      [(equal? (groot-entry-kind entry) 'file)
                       (set! files (cons (groot-entry-path entry) files))]))
              (groot-children directory)))
  (walk root)
  files)

;; Creates the complete file index on demand for search.
;; An external finder does the traversal when one exists; it is orders of
;; magnitude faster than walking a large tree from Steel and caches nothing.
(define (groot-build-search-index!)
  (unless (groot-get 'search-ready? #f)
    (define root (groot-root))
    (define found (groot-fs-find-files root *groot-ignored-names*))
    (groot-put! 'files (sort (or found (groot-walk-files root)) string<?))
    (groot-put! 'search-ready? #t)))
;; Directory levels drawn above a group's files. Two keeps a deep match
;; identifiable without indenting the whole route from the workspace root.
(define *groot-header-depth* 2)

;; Emits the header rows for one parent. Every link in the chain is an only
;; child, so each nests under the previous one. Returns the rows, the guide
;; continuation the group's files sit under, and their depth.
(define (groot-header-rows chain)
  (let loop ([links chain] [depth 0] [continuation ""] [acc '()])
    (if (null? links)
        (list (reverse acc) continuation depth)
        (loop (cdr links)
              (+ depth 1)
              (if (= depth 0) "" (string-append continuation "  "))
              (cons (groot-row (groot-entry (car links) (file-name (car links)) 'directory)
                               depth
                               (if (= depth 0) "" (string-append continuation "└╴")))
                    acc)))))

;; Emits the file rows for one parent, elbowing the final entry.
(define (groot-file-rows files continuation depth)
  (let loop ([items files] [acc '()])
    (if (null? items)
        (reverse acc)
        (loop (cdr items)
              (cons (groot-row (groot-entry (car items) (file-name (car items)) 'file)
                               depth
                               (string-append continuation
                                              (if (null? (cdr items)) "└╴" "├╴")))
                    acc)))))

;; Groups ranked result paths under the directories that contain them, drawing
;; each parent as nested rows rather than one joined path. Parents keep
;; first-match order so the best hit stays near the top.
(define (groot-search-rows paths)
  (define root (groot-root))
  (define separator (path-separator))
  (define order '())
  (define groups (hash))
  (for-each
   (lambda (path)
     (define parent (groot-parent-path path separator))
     (unless (hash-contains? groups parent) (set! order (cons parent order)))
     (set! groups
           (hash-insert groups parent
                        (cons path (if (hash-contains? groups parent)
                                       (hash-try-get groups parent)
                                       '())))))
   paths)
  (apply append
         (map (lambda (parent)
                (define header
                  (groot-header-rows
                   (groot-ancestor-chain root parent separator *groot-header-depth*)))
                (append (car header)
                        (groot-file-rows (reverse (hash-try-get groups parent))
                                         (cadr header)
                                         (caddr header))))
              (reverse order))))

;; Recomputes search results, narrowing from the previous candidate set where safe.
(define (groot-refresh-search! previous-query)
  (groot-build-search-index!)
  (define query (groot-get 'query ""))
  (define candidates (groot-filter-prefix-candidates previous-query query
                                                       (groot-get 'files '())
                                                       (groot-get 'results '())))
  (groot-put! 'results (if (equal? query "") '() (fuzzy-match query candidates)))
  ;; Counted once here; the header would otherwise walk the list on every redraw.
  (groot-put! 'result-count (length (groot-get 'results '())))
  ;; Narrowing keeps the full ranked list; only the rendered slice is built.
  ;; ponytail: row building grows superlinearly past a few thousand rows, so the
  ;; cap is what keeps this cheap. Raise it and measure before trusting it.
  (groot-put! 'result-rows
              (list->vector (groot-search-rows (take (groot-get 'results '())
                                                     *groot-max-results*))))
  ;; Headers open each group, so land on the first row that can be activated.
  (groot-put! 'cursor (groot-selectable-index 0 1))
  (groot-put! 'window 0))

;; Clears incomplete normal-mode prefixes and any active jump prompt.
(define (groot-clear-pending!)
  (groot-put! 'pending-g? #f)
  (groot-put! 'pending-z? #f))

;; Leaves jump mode and restores regular command handling.
(define (groot-clear-jump!)
  (groot-put! 'jump-active? #f)
  (groot-put! 'jump-input "")
  (groot-clear-pending!))

;; Reads Helix's configured jump alphabet, falling back for invalid or tiny values.
(define (groot-jump-alphabet)
  (define value
    (with-handler (lambda (_) *groot-default-jump-alphabet*)
      (helix.config.get-config-option-value "jump-label-alphabet")))
  (if (and (string? value) (>= (string-length value) 2)) value *groot-default-jump-alphabet*))

;; Returns the number of rows presently visible in the active viewport.
(define (groot-visible-count)
  (min (groot-get 'height 1) (max 0 (- (groot-active-count) (groot-get 'window 0)))))

;; Enters visible-row jump mode with the current Helix label alphabet.
(define (groot-enter-jump!)
  (groot-clear-pending!)
  (groot-put! 'search-input? #f)
  (groot-put! 'jump-alphabet (groot-jump-alphabet))
  (groot-put! 'jump-input "")
  (groot-put! 'jump-active? #t))

;; Implements Helix's two-key jump-label acceptance and cancellation behavior.
(define (groot-jump-type! character)
  (define alphabet (groot-get 'jump-alphabet *groot-default-jump-alphabet*))
  (define alphabet-size (string-length alphabet))
  (define character-index (groot-jump-character-index alphabet character))
  (define first-input (groot-get 'jump-input ""))
  (cond [(not character-index) (groot-clear-jump!)]
        [(equal? first-input "")
         (define outer (* character-index alphabet-size))
         ;; This mirrors Helix: reject a first character whose label group cannot exist.
         (if (groot-jump-prefix-valid? outer (groot-visible-count))
             (groot-put! 'jump-input (string character))
             (groot-clear-jump!))]
        [else
         (define first-index (groot-jump-character-index alphabet (string-ref first-input 0)))
         (define row (+ (* first-index alphabet-size) character-index))
         (when (< row (groot-visible-count))
           (groot-put! 'cursor (let ([index (+ (groot-get 'window 0) row)])
                                 (if (groot-searching?) (groot-selectable-index index 1) index)))
           (groot-clamp!))
         (groot-clear-jump!)]))

;; Appends a searchable character and refreshes the ranked result list.
(define (groot-type! character)
  (define old (groot-get 'query ""))
  (groot-put! 'query (string-append old (string character)))
  (groot-refresh-search! old))

;; Removes one query character and restores exact cached-prefix candidates when available.
(define (groot-backspace!)
  (define old (groot-get 'query ""))
  (define len (string-length old))
  (when (> len 0) (groot-put! 'query (substring old 0 (- len 1))))
  (groot-refresh-search! old))

;; Returns the selected display row or false when the explorer is empty.
(define (groot-current-row)
  (define items (groot-active-items))
  (and (> (vector-length items) 0) (vector-ref items (groot-get 'cursor 0))))

;; Toggles the selected directory and keeps the selection visible.
(define (groot-toggle-current!)
  (define row (groot-current-row))
  (when (and row (groot-directory? (groot-row-entry row)))
    (define path (groot-entry-path (groot-row-entry row)))
    (define expanded (groot-get 'expanded (hash)))
    (groot-put! 'expanded
                (hash-insert expanded path
                             (not (if (hash-contains? expanded path)
                                      (hash-try-get expanded path)
                                      #t))))
    (groot-rebuild-tree!)
    (groot-clamp!)))

;; Opens the selected file or toggles the selected directory.
(define (groot-activate!)
  (define row (groot-current-row))
  (when row
    (define entry (groot-row-entry row))
    (if (groot-directory? entry)
        ;; Search headers are labels; only tree directories toggle.
        (unless (groot-searching?) (groot-toggle-current!))
        (begin (groot-put! 'focused? #f)
               (enqueue-thread-local-callback (lambda () (helix.open (groot-entry-path entry))))))))

;; Returns the nearest selectable row, preferring the direction of travel.
;; Search headers are labels, so j/k step over them instead of landing on one.
(define (groot-selectable-index index step)
  (define items (groot-active-items))
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
(define (groot-move! delta)
  (define position (groot-window-after-move (groot-get 'cursor 0) (groot-get 'window 0)
                                             (groot-active-count) (groot-get 'height 1) delta))
  (define cursor
    (if (groot-searching?)
        (groot-selectable-index (car position) (if (< delta 0) -1 1))
        (car position)))
  (define final (groot-clamp-position cursor (cadr position)
                                      (groot-active-count) (groot-get 'height 1)))
  (groot-put! 'cursor (car final))
  (groot-put! 'window (cadr final)))

;; Moves selection to the first active row.
(define (groot-move-top!)
  (groot-put! 'cursor (if (groot-searching?) (groot-selectable-index 0 1) 0))
  (groot-put! 'window 0))

;; Moves selection to the final active row and makes it visible.
(define (groot-move-bottom!)
  (define count (groot-active-count))
  (when (> count 0)
    (groot-put! 'cursor (if (groot-searching?)
                            (groot-selectable-index (- count 1) -1)
                            (- count 1)))
    (groot-put! 'window (max 0 (- count (groot-get 'height 1))))))

;; Centers the selected row in the active viewport.
(define (groot-center-cursor!)
  (groot-put! 'window (groot-centered-window-start (groot-get 'cursor 0)
                                                     (groot-active-count)
                                                     (groot-get 'height 1))))

;; Returns the panel's left edge for the current side and terminal area.
(define (groot-panel-x0 rect)
  (define width (min *groot-width* (area-width rect)))
  (if (equal? *groot-side* 'right) (- (area-width rect) width) 0))

;; Reports whether a mouse event lands within the sidebar rectangle.
(define (groot-mouse-inside? rect event)
  (and rect (mouse-event? event)
       (let* ([width (min *groot-width* (area-width rect))]
              [x0 (groot-panel-x0 rect)]
              [row (event-mouse-row event)]
              [col (event-mouse-col event)])
         (and row col (>= row 0) (< row (area-height rect))
              (>= col x0) (< col (+ x0 width))))))

;; Converts a click row into an active item index, excluding the title row.
(define (groot-mouse-row-index event)
  (define row (event-mouse-row event))
  (define relative (and row (- row *groot-list-top*)))
  (define index (and relative (+ (groot-get 'window 0) relative)))
  (if (and relative index (>= relative 0) (< relative (groot-get 'height 1))
           (< index (groot-active-count)))
      index
      #f))

;; Selects a clicked visible row without opening or toggling it.
(define (groot-select-mouse-row! event)
  (define index (groot-mouse-row-index event))
  (when index (groot-put! 'cursor index))
  index)

;; Scrolls the cached viewport by a mouse-wheel direction.
(define (groot-scroll! direction)
  (define position (groot-scroll-position (groot-get 'cursor 0) (groot-get 'window 0)
                                           (groot-active-count) (groot-get 'height 1)
                                           (groot-get 'scroll-lines 3) direction))
  (groot-put! 'cursor (car position))
  (groot-put! 'window (cadr position)))

;; Handles panel-local mouse focus, selection, and wheel scrolling.
(define (groot-handle-mouse-event event)
  (if (not (mouse-event? event))
      #f
      (let* ([raw-kind (event-mouse-kind event)]
             [kind (cond [(equal? raw-kind *groot-mouse-left-down*) 'left]
                         [(equal? raw-kind *groot-mouse-scroll-up*) 'up]
                         [(equal? raw-kind *groot-mouse-scroll-down*) 'down]
                         [else 'other])]
             [result
              (groot-route-mouse!
               kind
               (groot-mouse-inside? *groot-last-rect* event)
               (groot-get 'focused? #f)
               (lambda (focused?) (groot-put! 'focused? focused?))
               (lambda () (groot-select-mouse-row! event))
               groot-scroll!)])
        (cond [(equal? result 'consume) event-result/consume]
              [(equal? result 'ignore) event-result/ignore]
              [else #f]))))

;; Clears every filesystem cache and reconstructs the root listing.
(define (groot-refresh)
  (groot-refresh-effects!
   (and *groot-state* (groot-get 'active? #f))
   (groot-searching?)
   (lambda ()
     (define root (groot-root))
     (groot-put! 'children (hash))
     (groot-put! 'files '())
     (groot-put! 'search-ready? #f)
     (groot-load-directory! root)
     (groot-rebuild-tree!)
     (groot-clamp!))
   (lambda () (groot-refresh-search! ""))
   (lambda () (helix.redraw))))

;; Closes the component and releases the editor clipping owned by this sidebar.
(define (groot-close!)
  (groot-put! 'active? #f)
  (groot-put! 'focused? #f)
  (groot-close-effects!
   (lambda () (pop-last-component-by-name! "groot"))
   (lambda ()
     (enqueue-thread-local-callback
      (lambda ()
        (if (equal? *groot-side* 'right) (set-editor-clip-right! 0) (set-editor-clip-left! 0))
        (helix.redraw))))))

;; Installs minimal, permanently registered hooks guarded by active state.
(define (groot-install-hooks!)
  (unless *groot-hooks-installed?*
    (set! *groot-hooks-installed?* #t)
    (register-hook 'document-opened (lambda (_id) (groot-sync-current-file!)))
    (register-hook 'post-command groot-post-command-sync!)))

;; Draws the rounded input frame and centres its title on the top border.
(define (groot-render-box! frame content-x content-width border-style title-style)
  (define inner (max 0 (- content-width 2)))
  (define fill (make-string inner #\─))
  (frame-set-string! frame content-x 0
                     (groot-truncate (string-append "╭" fill "╮") content-width) border-style)
  (frame-set-string! frame content-x 2
                     (groot-truncate (string-append "╰" fill "╯") content-width) border-style)
  (frame-set-string! frame content-x 1 "│" border-style)
  (frame-set-string! frame (+ content-x (- content-width 1)) 1 "│" border-style)
  ;; The title only goes on when both corners still have a border segment left.
  (define label (string-append " " *groot-input-title* " "))
  (when (>= inner (+ (string-length label) 2))
    (frame-set-string! frame
                       (+ content-x (quotient (- content-width (string-length label)) 2))
                       0 label title-style)))

;; Draws the search input: a prompt glyph, the query with a caret, and the
;; right-aligned match counts. Outside search mode it is just the panel name.
;; The counts report rendered rows against total matches, so a capped result
;; set is visible rather than silently short.
(define (groot-render-header! frame content-x content-width text-style directory-fg guide-fg)
  (define accent-style (if directory-fg (style-fg text-style directory-fg) text-style))
  (define muted-style (if guide-fg (style-fg text-style guide-fg) text-style))
  (define prompt-idle (groot-truncate (string-append *groot-search-icon* " ") content-width))
  (if (or (groot-get 'search-input? #f) (groot-searching?))
      (let* ([total (groot-get 'result-count 0)]
             [counts (if (> total 0)
                         (string-append (to-string (min total *groot-max-results*))
                                        "/" (to-string total))
                         "")]
             [prompt (string-append *groot-search-icon* " ")]
             ;; One blank column keeps the caret off the counts. Nested on purpose:
             ;; a four-argument (- ...) panics the Steel JIT.
             [reserved (+ (string-length prompt) (string-length counts) 1)]
             [budget (max 1 (- content-width reserved))]
             [typed (string-append
                     (groot-truncate-start (groot-get 'query "") (- budget 1))
                     *groot-search-caret*)])
        (frame-set-string! frame content-x 1 prompt accent-style)
        (frame-set-string! frame (+ content-x (string-length prompt)) 1
                           (groot-truncate typed budget) text-style)
        ;; Drop the counts rather than let them collide with the prompt.
        (unless (or (equal? counts "") (< (- content-width reserved) 2))
          (frame-set-string! frame
                             (- (+ content-x content-width) (string-length counts)) 1
                             counts muted-style)))
      ;; Idle input still shows its prompt, so the field never reads as absent.
      (frame-set-string! frame content-x 1 prompt-idle accent-style)))

;; Renders the sidebar and records the terminal geometry for input handling.
(define (groot-render state rect frame)
  (set! *groot-last-rect* rect)
  (define width (min *groot-width* (area-width rect)))
  (define height (area-height rect))
  (define x0 (if (equal? *groot-side* 'right) (- (area-width rect) width) 0))
  ;; The separator owns one column, keeping panel text out of the editor area.
  (define separator-x (if (equal? *groot-side* 'right) x0 (+ x0 (- width 1))))
  ;; One column of padding keeps rows off the panel edge; the other is the separator.
  (define content-x (+ x0 1))
  (define content-width (max 1 (- width 2)))
  (groot-put! 'height (max 1 (- height *groot-list-top*)))
  (groot-clamp!)
  (if (equal? *groot-side* 'right) (set-editor-clip-right! width) (set-editor-clip-left! width))
  (define text-style (theme-scope-ref "ui.text"))
  (define selected-style (theme-scope-ref "ui.menu.selected"))
  ;; The semantic info scope is Foam in Rose Pine and the equivalent accent elsewhere.
  (define directory-style (theme-scope-ref "info"))
  (define directory-fg (style->fg directory-style))
  ;; Style used for virtual two-character jump labels, matching Helix's editor UI.
  (define jump-style (theme-scope-ref "ui.virtual.jump-label"))
  ;; Tree guides borrow Helix's indent-guide accent so they stay quieter than the rows.
  (define guide-fg
    (or (style->fg (theme-scope-ref "ui.virtual.indent-guide"))
        (style->fg (theme-scope-ref "comment"))))
  ;; Focus uses normal text; an unfocused panel inherits the directory foreground.
  (define separator-style
    (if (groot-get 'focused? #f)
        text-style
        (if directory-fg (style-fg text-style directory-fg) text-style)))
  (buffer/clear-with frame (area x0 0 width height) (theme-scope-ref "ui.background"))
  (groot-render-box! frame content-x content-width
                     (if guide-fg (style-fg text-style guide-fg) text-style)
                     (if directory-fg (style-fg text-style directory-fg) text-style))
  (groot-render-header! frame (+ content-x 1) (max 1 (- content-width 2)) text-style
                        directory-fg guide-fg)
  (define items (groot-active-items))
  (for-each
   (lambda (pair)
     (define index (car pair))
     (define row (vector-ref items index))
     (define entry (groot-row-entry row))
     (define selected? (= index (groot-get 'cursor 0)))
     (define directory? (groot-directory? entry))
     (define style (if selected? selected-style text-style))
     ;; Tree guides are precomputed per row; no per-row fold marker is drawn.
     (define prefix (groot-row-prefix row))
     (define expanded?
       (and directory?
            (not (groot-searching?))
            (not (let ([expanded (groot-get 'expanded (hash))]
                       [path (groot-entry-path entry)])
                   (if (hash-contains? expanded path) (hash-try-get expanded path) #t)))))
     (define name (groot-entry-name entry))
     ;; Search headers display a root-relative path; icons still key off the basename.
     (define icon-name (file-name (groot-entry-path entry)))
     ;; An open folder marks expansion; collapsed directories keep their glyph.hx icon.
     (define icon
       (cond [expanded? *groot-open-dir-icon*]
             [directory? (glyph-dir-icon icon-name)]
             [else (glyph-icon icon-name)]))
     (define theme-accent-style
       (if (and directory? directory-fg) (style-fg style directory-fg) style))
     ;; Directory names use the current theme accent; file names use Helix text styling.
     (define name-style
       (if (groot-entry-name-uses-theme-accent? entry)
           theme-accent-style
           style))
     ;; File icons keep glyph colors; directory icons share the theme's directory accent.
     (define icon-style
       (if (groot-entry-icon-uses-glyph-color? entry)
           (glyph-style (glyph-color icon-name) #:base style)
           theme-accent-style))
     ;; Labels overlay the filename itself, never participate in row layout.
     (define icon-x (+ content-x (string-length prefix)))
     (define name-x (+ icon-x (string-length icon) 1))
     (define y (+ *groot-list-top* (- index (groot-get 'window 0))))
     (define jump-row (- index (groot-get 'window 0)))
     (define jump-label
       (if (groot-get 'jump-active? #f)
           (groot-jump-label (groot-get 'jump-alphabet *groot-default-jump-alphabet*) jump-row)
           ""))
     (define row-text
       (string-append prefix icon " " name))
     (when selected? (frame-set-string! frame content-x y (make-string content-width #\space) selected-style))
     (frame-set-string! frame content-x y
                        (groot-truncate row-text content-width)
                        name-style)
     ;; Guides stay muted instead of inheriting the row's text or directory accent.
     (when (> (string-length prefix) 0)
       (frame-set-string! frame content-x y (groot-truncate prefix content-width)
                          (if guide-fg (style-fg style guide-fg) style)))
     (when (< icon-x (+ content-x content-width))
       (frame-set-string! frame icon-x y
                          (groot-truncate icon (- (+ content-x content-width) icon-x))
                          icon-style))
     (when (and (not (equal? jump-label "")) (< name-x (+ content-x content-width)))
       (frame-set-string! frame name-x y
                          (groot-truncate jump-label (- (+ content-x content-width) name-x))
                          jump-style)))
   (map (lambda (index) (cons index index))
        (let ([start (groot-get 'window 0)] [end (min (vector-length items) (+ (groot-get 'window 0) (groot-get 'height 1)))])
          (let loop ([i start] [acc '()]) (if (>= i end) (reverse acc) (loop (+ i 1) (cons i acc)))))))
  ;; Draw this last so no row can overwrite the boundary column.
  (let loop ([y 0])
    (when (< y height)
      (frame-set-string! frame separator-x y "│" separator-style)
      (loop (+ y 1)))))

;; Handles keyboard input while the explorer owns focus.
(define (groot-handle-jump-event event)
  (define character (key-event-char event))
  (cond [(key-event-escape? event) (groot-clear-jump!) event-result/consume]
        [(key-event-backspace? event) (groot-clear-jump!) event-result/consume]
        [(char? character) (groot-jump-type! character) event-result/consume]
        [else (groot-clear-jump!) event-result/consume]))

;; Handles keyboard input while the explorer owns focus.
(define (groot-handle-event state event)
  (define character (key-event-char event))
  (define mouse-result (groot-handle-mouse-event event))
  (cond [mouse-result mouse-result]
        [(not (groot-get 'focused? #f)) event-result/ignore]
        [(groot-get 'jump-active? #f) (groot-handle-jump-event event)]
        [(groot-get 'search-input? #f)
      (cond [(key-event-escape? event) (groot-put! 'search-input? #f) event-result/consume]
            ;; Enter leaves the query in place and hands the results to the
            ;; navigation keys; opening takes a second Enter on a chosen row.
            [(key-event-enter? event) (groot-put! 'search-input? #f) event-result/consume]
            [(key-event-backspace? event) (groot-backspace!) event-result/consume]
            [(char? character) (groot-type! character) event-result/consume]
            [else event-result/consume])]
        [else
        (cond [(and (groot-get 'pending-g? #f) (char? character) (equal? character #\w))
              (groot-enter-jump!) event-result/consume]
            [(and (groot-get 'pending-g? #f) (char? character) (equal? character #\e))
              (groot-clear-pending!) (groot-move-bottom!) event-result/consume]
            [(and (char? character) (equal? character #\g))
              (if (groot-get 'pending-g? #f)
                  (begin (groot-clear-pending!) (groot-move-top!))
                  (begin (groot-put! 'pending-g? #t) (groot-put! 'pending-z? #f)))
              event-result/consume]
            [(and (char? character) (equal? character #\G))
              (groot-clear-pending!) (groot-move-bottom!) event-result/consume]
            [(and (groot-get 'pending-z? #f) (char? character) (equal? character #\z))
              (groot-clear-pending!) (groot-center-cursor!) event-result/consume]
            [(and (char? character) (equal? character #\z))
              (groot-put! 'pending-g? #f) (groot-put! 'pending-z? #t) event-result/consume]
            [(key-event-down? event) (groot-clear-pending!) (groot-move! 1) event-result/consume]
            [(key-event-up? event) (groot-clear-pending!) (groot-move! -1) event-result/consume]
            [(and (char? character) (groot-navigation-delta character))
             (groot-clear-pending!)
             (groot-move! (groot-navigation-delta character))
             event-result/consume]
            [(key-event-enter? event) (groot-clear-pending!) (groot-activate!) event-result/consume]
            [(key-event-tab? event) (groot-clear-pending!) (groot-toggle-current!) event-result/consume]
            [(and (char? character) (equal? character #\/))
             (groot-clear-pending!) (groot-put! 'query "") (groot-put! 'search-input? #t) event-result/consume]
            [(and (char? character) (equal? character #\q))
             (groot-clear-pending!) (groot-close!) event-result/consume]
            [(and (char? character) (equal? character #\R)) (groot-clear-pending!) (groot-refresh) event-result/consume]
            ;; Let Helix own its command prompt even while the explorer has focus.
            [(and (char? character) (equal? character #\:))
             (groot-clear-pending!) event-result/ignore]
            [else (groot-clear-pending!) event-result/consume])]))

;; Creates the component used by Helix's compositor.
(define (groot-make-component)
  (new-component! "groot" void groot-render (hash "handle_event" groot-handle-event)))

;; Opens the explorer, caches the root listing, and reveals the current document once.
(define (groot-open)
  (groot-install-hooks!)
  (if (groot-get 'active? #f)
      (begin
        (groot-put! 'focused? #f)
        (groot-sync-current-file!)
        (groot-put! 'focused? #t)
        (groot-request-redraw!))
      (let ([root (groot-workspace)])
        (set! *groot-state* (groot-state root *groot-default-jump-alphabet*))
        (groot-put! 'scroll-lines (groot-config-scroll-lines))
        (groot-load-directory! root)
        (groot-rebuild-tree!)
        (groot-put! 'focused? #f)
        (groot-reveal! (groot-current-document-path))
        (groot-put! 'focused? #t)
        (groot-open-effects!
         (lambda () (push-component! (groot-make-component)))
         groot-request-redraw!))))
