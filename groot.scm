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
(define *groot-ignored-names* (hashset ".git" ".hg" ".direnv" "node_modules" "target" "__pycache__"))
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
(define (groot-ignored? entry) (hashset-contains? *groot-ignored-names* (groot-entry-name entry)))

;; Returns cached children for path, loading them lazily when first expanded.
(define (groot-children path)
  (groot-load-directory! path)
  (let ([children (groot-get 'children (hash))])
    (filter (lambda (entry) (not (groot-ignored? entry)))
            (if (hash-contains? children path) (hash-try-get children path) '()))))

;; Recursively materializes only expanded cached directories into display rows.
(define (groot-visible-tree)
  (define expanded (groot-get 'expanded (hash)))
  (define (walk entry depth acc)
    (define next (cons (groot-row entry depth) acc))
    (if (and (groot-directory? entry)
             (not (if (hash-contains? expanded (groot-entry-path entry))
                      (hash-try-get expanded (groot-entry-path entry))
                      #t)))
        (let loop ([items (groot-children (groot-entry-path entry))] [rows next])
          (if (null? items) rows (loop (cdr items) (walk (car items) (+ depth 1) rows))))
        next))
  (define root-entry (groot-entry (groot-root) (file-name (groot-root)) 'directory))
  (reverse (walk root-entry 0 '())))

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

;; Creates the complete file index on demand for search, skipping symlink recursion.
(define (groot-build-search-index!)
  (unless (groot-get 'search-ready? #f)
    (define root (groot-root))
    (define files '())
    (define (walk directory)
      (for-each (lambda (entry)
                  (cond [(groot-directory? entry) (walk (groot-entry-path entry))]
                        [(equal? (groot-entry-kind entry) 'file)
                         (set! files (cons (groot-entry-path entry) files))]))
                (groot-children directory)))
    (walk root)
    (groot-put! 'files (sort files string<?))
    (groot-put! 'search-ready? #t)))

;; Recomputes search results, narrowing from the previous candidate set where safe.
(define (groot-refresh-search! previous-query)
  (groot-build-search-index!)
  (define query (groot-get 'query ""))
  (define candidates (groot-filter-prefix-candidates previous-query query
                                                       (groot-get 'files '())
                                                       (groot-get 'results '())))
  (groot-put! 'results (if (equal? query "") '() (fuzzy-match query candidates)))
  (groot-put! 'result-rows
              (list->vector
               (map (lambda (path) (groot-row (groot-entry path (file-name path) 'file) 0))
                    (groot-get 'results '()))))
  (groot-put! 'cursor 0)
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
           (groot-put! 'cursor (+ (groot-get 'window 0) row))
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
        (groot-toggle-current!)
        (begin (groot-put! 'focused? #f)
               (enqueue-thread-local-callback (lambda () (helix.open (groot-entry-path entry))))))))

;; Moves selection by delta rows.
(define (groot-move! delta)
  (define position (groot-window-after-move (groot-get 'cursor 0) (groot-get 'window 0)
                                             (groot-active-count) (groot-get 'height 1) delta))
  (groot-put! 'cursor (car position))
  (groot-put! 'window (cadr position)))

;; Moves selection to the first active row.
(define (groot-move-top!)
  (groot-put! 'cursor 0)
  (groot-put! 'window 0))

;; Moves selection to the final active row and makes it visible.
(define (groot-move-bottom!)
  (define count (groot-active-count))
  (when (> count 0)
    (groot-put! 'cursor (- count 1))
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
  (define relative (and row (- row 2)))
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

;; Renders the sidebar and records the terminal geometry for input handling.
(define (groot-render state rect frame)
  (set! *groot-last-rect* rect)
  (define width (min *groot-width* (area-width rect)))
  (define height (area-height rect))
  (define x0 (if (equal? *groot-side* 'right) (- (area-width rect) width) 0))
  ;; The separator owns one column, keeping panel text out of the editor area.
  (define separator-x (if (equal? *groot-side* 'right) x0 (+ x0 (- width 1))))
  (define content-x (if (equal? *groot-side* 'right) (+ x0 1) x0))
  (define content-width (max 1 (- width 1)))
  (groot-put! 'height (max 1 (- height 2)))
  (groot-clamp!)
  (if (equal? *groot-side* 'right) (set-editor-clip-right! width) (set-editor-clip-left! width))
  (define text-style (theme-scope-ref "ui.text"))
  (define selected-style (theme-scope-ref "ui.menu.selected"))
  ;; The semantic info scope is Foam in Rose Pine and the equivalent accent elsewhere.
  (define directory-style (theme-scope-ref "info"))
  (define directory-fg (style->fg directory-style))
  ;; Style used for virtual two-character jump labels, matching Helix's editor UI.
  (define jump-style (theme-scope-ref "ui.virtual.jump-label"))
  ;; Focus uses normal text; an unfocused panel inherits the directory foreground.
  (define separator-style
    (if (groot-get 'focused? #f)
        text-style
        (if directory-fg (style-fg text-style directory-fg) text-style)))
  (buffer/clear-with frame (area x0 0 width height) (theme-scope-ref "ui.background"))
  (frame-set-string! frame content-x 0
                     (groot-truncate (if (groot-searching?) (groot-get 'query "") "groot") content-width)
                     text-style)
  (define items (groot-active-items))
  (for-each
   (lambda (pair)
     (define index (car pair))
     (define row (vector-ref items index))
     (define entry (groot-row-entry row))
     (define depth (groot-row-depth row))
     (define selected? (= index (groot-get 'cursor 0)))
     (define directory? (groot-directory? entry))
     (define style (if selected? selected-style text-style))
     (define expanded (groot-get 'expanded (hash)))
     (define marker
       (if directory?
           (if (if (hash-contains? expanded (groot-entry-path entry))
                   (hash-try-get expanded (groot-entry-path entry))
                   #t)
               "▶ " "▼ ")
           "  "))
     (define name (if (groot-searching?) (groot-entry-path entry) (groot-entry-name entry)))
     (define icon (if directory? (glyph-dir-icon name) (glyph-icon name)))
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
           (glyph-style (glyph-color name) #:base style)
           theme-accent-style))
     ;; Labels overlay the filename itself, never participate in row layout.
     (define icon-x (+ content-x (* 2 depth) (string-length marker)))
     (define name-x (+ icon-x (string-length icon) 1))
     (define y (+ 2 (- index (groot-get 'window 0))))
     (define jump-row (- index (groot-get 'window 0)))
     (define jump-label
       (if (groot-get 'jump-active? #f)
           (groot-jump-label (groot-get 'jump-alphabet *groot-default-jump-alphabet*) jump-row)
           ""))
     (define row-text
       (string-append (make-string (* 2 depth) #\space) marker icon " " name))
     (when selected? (frame-set-string! frame content-x y (make-string content-width #\space) selected-style))
     (frame-set-string! frame content-x y
                        (groot-truncate row-text content-width)
                        name-style)
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
            [(key-event-enter? event) (groot-put! 'search-input? #f) (groot-activate!) event-result/consume]
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
