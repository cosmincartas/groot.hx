;; groot.hx: a cached, lazy file explorer for Helix.
;; This file is the Helix adapter: component lifecycle, rendering, input
;; events, hooks, and prompts.  The tree, search, path, prompt, and viewport
;; models live in their own modules and are tested without Helix.
;;
;; Steel JIT note: a four-argument (- ...) panics the JIT, so wider
;; differences are written as nested calls.

(require "helix/components.scm")
(require "helix/editor.scm")
(require "helix/ext.scm")
(require "helix/misc.scm")
(require "helix/static.scm")
(require (prefix-in helix.config. "helix/configuration.scm"))
(require (prefix-in helix. "helix/commands.scm"))
(require "glyph/glyph.scm")
(require "groot/groot-core.scm")
(require "groot/groot-path.scm")
(require "groot/groot-prompt.scm")
(require "groot/groot-view.scm")
(require "groot/groot-fs.scm")
(require "groot/groot-tree.scm")
(require "groot/groot-search.scm")
(require "groot/groot-integration.scm")

(provide groot-open groot-refresh groot-collapse-all groot-configure!)

;; Typed-command name of groot-collapse-all.  Its post-command hook must not
;; re-sync the tree it just collapsed.
(define *groot-collapse-all-command* "groot-collapse-all")

;; Sidebar width in terminal cells.
(define *groot-width* 32)
;; Sidebar placement; valid values are 'left and 'right.
(define *groot-side* 'left)
;; Directory names excluded from both the tree and the deferred search index.
(define *groot-ignored-names* (hashset ".git" ".hg" ".direnv" "node_modules" "target" "__pycache__"))
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
;; Terminal mouse kinds emitted while dragging or releasing the left button.
(define *groot-mouse-left-up* 3)
(define *groot-mouse-left-drag* 6)
;; True from a separator press until its left-button release.
(define *groot-resizing?* #f)
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

;; Reports whether a session exists and its component is mounted.
(define (groot-active?) (and *groot-state* (groot-state-active? *groot-state*)))

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

;; Reads the focused editor document path without allowing UI errors to escape.
(define (groot-current-document-path)
  (with-handler (lambda (_) #f)
    (if (editor-focused-buffer-area)
        (let ([focus (editor-focus)]) (editor-document->path (editor->doc-id focus)))
        #f)))

;; Synchronizes selection only when the document actually changed.
(define (groot-sync-current-file!)
  (when (and (groot-active?) (not (groot-state-focused? *groot-state*)) (not (groot-searching? *groot-state*)))
    (define path (groot-current-document-path))
    (unless (equal? path (groot-state-last-document *groot-state*)) (groot-reveal! *groot-state* path))))

;; Converts hook command payloads to names accepted by the teardown command set.
(define (groot-command-name command)
  (cond [(string? command) command]
        [(symbol? command) (symbol->string command)]
        [else ""]))

;; Synchronizes only after commands that leave a valid focused editor view.
(define (groot-post-command-sync! command)
  (define name (groot-command-name command))
  (unless (or (hashset-contains? *groot-view-teardown-commands* name)
              (equal? name *groot-collapse-all-command*))
    (groot-sync-current-file!)))

;; Reads Helix's configured jump alphabet, falling back for invalid or tiny values.
(define (groot-jump-alphabet)
  (define value
    (with-handler (lambda (_) *groot-default-jump-alphabet*)
      (helix.config.get-config-option-value "jump-label-alphabet")))
  (if (and (string? value) (>= (string-length value) 2)) value *groot-default-jump-alphabet*))

;; Opens the selected file or toggles the selected directory.
(define (groot-activate!)
  (define row (groot-current-row *groot-state*))
  (when row
    (define entry (groot-row-entry row))
    (if (groot-directory? entry)
        ;; Search headers are labels; only tree directories toggle.
        (unless (groot-searching? *groot-state*) (groot-toggle-current! *groot-state*))
        (begin (set-groot-state-focused! *groot-state* #f)
               (enqueue-thread-local-callback (lambda () (helix.open (groot-entry-path entry))))))))

;; Returns the rendered width, keeping a persistent requested width within the terminal.
(define (groot-effective-width rect) (min *groot-width* (area-width rect)))

;; Returns the panel's left edge for the current side and terminal area.
(define (groot-panel-x0 rect)
  (define width (groot-effective-width rect))
  (if (equal? *groot-side* 'right) (- (area-width rect) width) 0))

;; Reports whether a mouse event lands within the sidebar rectangle.
(define (groot-mouse-inside? rect event)
  (and rect (mouse-event? event)
       (let* ([width (groot-effective-width rect)]
              [x0 (groot-panel-x0 rect)]
              [row (event-mouse-row event)]
              [col (event-mouse-col event)])
         (and row col (>= row 0) (< row (area-height rect))
              (>= col x0) (< col (+ x0 width))))))

;; Reports whether a press lands on the rendered separator column.
(define (groot-mouse-on-separator? rect event)
  (and (groot-mouse-inside? rect event)
       (= (event-mouse-col event)
          (if (equal? *groot-side* 'right)
              (groot-panel-x0 rect)
              (+ (groot-panel-x0 rect) (- (groot-effective-width rect) 1))))))

;; Converts a click row into an active item index, excluding the title row.
(define (groot-mouse-row-index event)
  (define row (event-mouse-row event))
  (define relative (and row (- row *groot-list-top*)))
  (define index (and relative (+ (groot-state-window *groot-state*) relative)))
  (if (and relative index (>= relative 0) (< relative (groot-state-height *groot-state*))
           (< index (groot-active-count *groot-state*)))
      index
      #f))

;; Selects a clicked visible row without opening or toggling it.
(define (groot-select-mouse-row! event)
  (define index (groot-mouse-row-index event))
  (when index (set-groot-state-cursor! *groot-state* index))
  index)

;; Handles panel-local mouse focus, selection, and wheel scrolling.
(define (groot-handle-mouse-event event)
  (if (not (mouse-event? event))
      #f
      (let* ([raw-kind (event-mouse-kind event)]
             [kind (cond [(equal? raw-kind *groot-mouse-left-down*) 'left]
                         [(equal? raw-kind *groot-mouse-left-drag*) 'drag]
                         [(equal? raw-kind *groot-mouse-left-up*) 'release]
                         [(equal? raw-kind *groot-mouse-scroll-up*) 'up]
                         [(equal? raw-kind *groot-mouse-scroll-down*) 'down]
                         [else 'other])]
             [result
              (groot-route-mouse!
               (GrootMouseHost
                (lambda (focused?) (set-groot-state-focused! *groot-state* focused?))
                (lambda (resizing?) (set! *groot-resizing?* resizing?))
                (lambda () (groot-select-mouse-row! event))
                (lambda (direction) (groot-scroll! *groot-state* direction))
                (lambda ()
                  (set! *groot-width*
                        (groot-resized-width *groot-side*
                                             (area-width *groot-last-rect*)
                                             (event-mouse-col event)))
                  (groot-request-redraw!)))
               kind
               (groot-mouse-inside? *groot-last-rect* event)
               (groot-mouse-on-separator? *groot-last-rect* event)
               (groot-state-focused? *groot-state*)
               *groot-resizing?*)])
        (cond [(equal? result 'consume) event-result/consume]
              [(equal? result 'ignore) event-result/ignore]
              [else #f]))))

;; Refreshes normally, including search results and redraw.
(define (groot-refresh)
  (groot-refresh-effects!
   (groot-active?)
   (and (groot-active?) (groot-searching? *groot-state*))
   (lambda () (groot-refresh-tree! *groot-state*))
   (lambda () (groot-refresh-search! *groot-state* "" fuzzy-match))
   groot-request-redraw!))

;; Restores the active tree view without clearing filesystem or search caches.
(define (groot-collapse-all)
  (groot-collapse-all-effects! *groot-state* (lambda () (groot-rebuild-tree! *groot-state*))
                               groot-request-redraw!))

;; Builds the host effects for the integration seams.  REFRESH-TREE! takes the
;; session state and differs only for deletion recovery, which needs the strict
;; root listing.
(define (groot-host refresh-tree!)
  (GrootHost (lambda () (refresh-tree! *groot-state*))
             (lambda (path) (groot-reveal! *groot-state* path))
             groot-request-redraw!
             set-error!
             (lambda () (groot-state-last-document *groot-state*))
             (lambda (path) (set-groot-state-last-document! *groot-state* path))
             prompt
             push-component!
             groot-open-document-paths))

;; Handles a completed rename without activating an editor buffer.
(define (groot-renamed-entry! source destination)
  (groot-migrate-expanded-subtree! *groot-state* source destination)
  (groot-renamed-entry-effects! (groot-host groot-refresh-tree!) source destination))

;; Displays the recorded native outcome without changing Helix's focused
;; document.  The ancestor list is captured from the original root/source and
;; live probes ensure the synthetic root row is never treated as evidence.
(define (groot-deleted-entry! root source result)
  (groot-deleted-entry-effects!
   (groot-host groot-refresh-tree-after-deletion!)
   source result
   (groot-delete-surviving-ancestors root source (path-separator))
   (lambda () (groot-drop-expanded-subtree! *groot-state* source))
   (lambda (path)
     (with-handler (lambda (_) #f)
       (equal? (groot-fs-live-entry-kind path) 'directory)))))

;; Displays a creation outcome; a new directory starts collapsed.
(define (groot-created-entry! result)
  (groot-created-entry-effects! (groot-host groot-refresh-tree!) result
                                (lambda (path) (groot-drop-expanded-subtree! *groot-state* path))))

;; Uses the viewport that rendered the live sidebar.  Opening before its first
;; render falls back to the configured sidebar width rather than assuming a
;; terminal geometry that may not exist yet.
(define (groot-prompt-width)
  (with-handler
   (lambda (_) *groot-width*)
   (if *groot-last-rect*
       (max 1 (area-width *groot-last-rect*))
       *groot-width*)))

;; Captures the selected directory (or a leaf's lexical parent) before native
;; prompt input can change focus or selection.
(define (groot-open-create-prompt!)
  (define row (groot-current-row *groot-state*))
  (define destination
    (groot-create-destination
     (groot-state-root *groot-state*)
     (and row (groot-row-entry row))
     (path-separator)))
  ;; Capture before allocating the prompt: later focus or filesystem changes
  ;; cannot redirect submitted components.
  (with-handler
   (lambda (error) (set-error! (string-append "Cannot create in " destination ": " (to-string error))))
   (let ([context (groot-fs-capture-create-context destination)])
     (groot-create-prompt-effects!
      (groot-host groot-refresh-tree!)
      context
      (groot-create-prompt-label destination (groot-prompt-width))
      groot-fs-create-entry groot-created-entry!))))

;; Reads every filesystem-backed open document immediately before rename.
(define (groot-open-document-paths)
  (map editor-document->path (editor-all-documents)))

;; Captures the root, source, kind, and resolved address facts before the native
;; prompt owns input.  The filesystem boundary repeats those checks after yes.
(define (groot-open-delete-prompt!)
  (define row (groot-current-row *groot-state*))
  (define entry (and row (groot-row-entry row)))
  (define root (groot-state-root *groot-state*))
  (groot-delete-request-effects!
   entry root
   (lambda ()
     (define source (groot-entry-path entry))
     (with-handler
      (lambda (error) (set-error! (string-append "Cannot delete " (groot-entry-name entry) ": " (to-string error))))
      (let ([context (groot-fs-capture-delete-context root source)])
        (groot-delete-prompt-effects!
         (groot-host groot-refresh-tree!)
         context (groot-delete-target-label root source (path-separator))
         (GrootFsDeleteContext-kind context)
         groot-prompt-width groot-delete-prompt-label
         groot-fs-delete-entry
         (lambda (result) (groot-deleted-entry! root source result))))))
   set-error!))

;; Captures only a regular file or directory; symbolic links deliberately remain
;; unsupported because their target and document ownership are ambiguous.
(define (groot-open-rename-prompt!)
  (define row (groot-current-row *groot-state*))
  (define entry (and row (groot-row-entry row)))
  (when (and entry
             ;; The synthetic workspace-root row has no lexical parent in this
             ;; explorer.  Reject it before allocating a prompt or retaining a
             ;; stale root path.
             (not (equal? (groot-entry-path entry) (groot-state-root *groot-state*)))
             (or (equal? (groot-entry-kind entry) 'file) (groot-directory? entry)))
    (define source (groot-entry-path entry))
    (groot-rename-prompt-effects!
     (groot-host groot-refresh-tree!)
     source
     (groot-rename-prompt-label (groot-entry-name entry) (groot-prompt-width))
     (lambda (source document-paths)
       (groot-rename-open-document-conflict? source document-paths (path-separator)))
     groot-fs-rename-entry
     (lambda (destination) (groot-renamed-entry! source destination)))))

;; Closes the component and releases the editor clipping owned by this sidebar.
(define (groot-close!)
  (set! *groot-resizing?* #f)
  (set-groot-state-active! *groot-state* #f)
  (set-groot-state-focused! *groot-state* #f)
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
  (if (or (groot-state-search-input? *groot-state*) (groot-searching? *groot-state*))
      (let* ([total (groot-state-result-count *groot-state*)]
             [counts (if (> total 0)
                         (string-append (to-string (min total *groot-max-results*))
                                        "/" (to-string total))
                         "")]
             [prompt (string-append *groot-search-icon* " ")]
             ;; One blank column keeps the caret off the counts.
             [reserved (+ (string-length prompt) (string-length counts) 1)]
             [budget (max 1 (- content-width reserved))]
             [typed (string-append
                     (groot-truncate-start (groot-state-query *groot-state*) (- budget 1))
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
  (define width (groot-effective-width rect))
  (define height (area-height rect))
  (define x0 (if (equal? *groot-side* 'right) (- (area-width rect) width) 0))
  ;; The separator owns one column, keeping panel text out of the editor area.
  (define separator-x (if (equal? *groot-side* 'right) x0 (+ x0 (- width 1))))
  ;; One column of padding keeps rows off the panel edge; the other is the separator.
  (define content-x (+ x0 1))
  (define content-width (max 1 (- width 2)))
  (set-groot-state-height! *groot-state* (max 1 (- height *groot-list-top*)))
  (groot-clamp! *groot-state*)
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
    (if (groot-state-focused? *groot-state*)
        text-style
        (if directory-fg (style-fg text-style directory-fg) text-style)))
  (buffer/clear-with frame (area x0 0 width height) (theme-scope-ref "ui.background"))
  (groot-render-box! frame content-x content-width
                     (if guide-fg (style-fg text-style guide-fg) text-style)
                     (if directory-fg (style-fg text-style directory-fg) text-style))
  (groot-render-header! frame (+ content-x 1) (max 1 (- content-width 2)) text-style
                        directory-fg guide-fg)
  ;; Read session state once per frame rather than once per visible row.
  (define items (groot-active-items *groot-state*))
  (define cursor (groot-state-cursor *groot-state*))
  (define window (groot-state-window *groot-state*))
  (define searching? (groot-searching? *groot-state*))
  (define jump-alphabet
    (and (groot-state-jump-active? *groot-state*) (groot-state-jump-alphabet *groot-state*)))
  (define content-end (+ content-x content-width))
  (define (render-row! index)
    (define row (vector-ref items index))
    (define entry (groot-row-entry row))
    (define selected? (= index cursor))
    (define directory? (groot-directory? entry))
    (define style (if selected? selected-style text-style))
    ;; Tree guides are precomputed per row; no per-row fold marker is drawn.
    (define prefix (groot-row-prefix row))
    (define expanded?
      (and directory? (not searching?) (groot-expanded? *groot-state* (groot-entry-path entry))))
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
      (if (groot-entry-name-uses-theme-accent? entry) theme-accent-style style))
    ;; File icons keep glyph colors; directory icons share the theme's directory accent.
    (define icon-style
      (if (groot-entry-icon-uses-glyph-color? entry)
          (glyph-style (glyph-color icon-name) #:base style)
          theme-accent-style))
    ;; Labels overlay the filename itself, never participate in row layout.
    (define icon-x (+ content-x (string-length prefix)))
    (define name-x (+ icon-x (string-length icon) 1))
    (define jump-row (- index window))
    (define y (+ *groot-list-top* jump-row))
    (define jump-label (if jump-alphabet (groot-jump-label jump-alphabet jump-row) ""))
    (when selected? (frame-set-string! frame content-x y (make-string content-width #\space) selected-style))
    (frame-set-string! frame content-x y
                       (groot-truncate (string-append prefix icon " " name) content-width)
                       name-style)
    ;; Guides stay muted instead of inheriting the row's text or directory accent.
    (when (> (string-length prefix) 0)
      (frame-set-string! frame content-x y (groot-truncate prefix content-width)
                         (if guide-fg (style-fg style guide-fg) style)))
    (when (< icon-x content-end)
      (frame-set-string! frame icon-x y (groot-truncate icon (- content-end icon-x)) icon-style))
    (when (and (not (equal? jump-label "")) (< name-x content-end))
      (frame-set-string! frame name-x y (groot-truncate jump-label (- content-end name-x)) jump-style)))
  (let ([end (min (vector-length items) (+ window (groot-state-height *groot-state*)))])
    (let loop ([index window])
      (when (< index end)
        (render-row! index)
        (loop (+ index 1)))))
  ;; Draw this last so no row can overwrite the boundary column.
  (let loop ([y 0])
    (when (< y height)
      (frame-set-string! frame separator-x y "│" separator-style)
      (loop (+ y 1)))))

;; Handles keyboard input while two-key jump labels are shown.
(define (groot-handle-jump-event event)
  (define character (key-event-char event))
  (cond [(key-event-escape? event) (groot-clear-jump! *groot-state*) event-result/consume]
        [(key-event-backspace? event) (groot-clear-jump! *groot-state*) event-result/consume]
        [(char? character) (groot-jump-type! *groot-state* character) event-result/consume]
        [else (groot-clear-jump! *groot-state*) event-result/consume]))

;; Reduces a key event to a character or a named special key.
(define (groot-normalize-key event)
  (cond [(key-event-escape? event) 'escape]
        [(key-event-enter? event) 'enter]
        [(key-event-backspace? event) 'backspace]
        [(key-event-tab? event) 'tab]
        [(key-event-down? event) 'down]
        [(key-event-up? event) 'up]
        [(char? (key-event-char event)) (key-event-char event)]
        [else 'other]))

;; Runs one action from groot-key-dispatch and returns the event result.
(define (groot-run-action! action key event)
  (cond [(equal? action 'ignore) event-result/ignore]
        [(equal? action 'jump) (groot-handle-jump-event event)]
        [(equal? action 'search-leave) (set-groot-state-search-input! *groot-state* #f) event-result/consume]
        [(equal? action 'search-backspace) (groot-backspace! *groot-state* fuzzy-match) event-result/consume]
        [(equal? action 'search-type) (groot-type! *groot-state* key fuzzy-match) event-result/consume]
        [(equal? action 'consume) event-result/consume]
        [(equal? action 'focus-editor) (set-groot-state-focused! *groot-state* #f) event-result/consume]
        [(equal? action 'pending-g)
         (set-groot-state-pending-g! *groot-state* #t)
         (set-groot-state-pending-z! *groot-state* #f)
         event-result/consume]
        [(equal? action 'pending-z)
         (set-groot-state-pending-g! *groot-state* #f)
         (set-groot-state-pending-z! *groot-state* #t)
         event-result/consume]
        [(equal? action 'jump-start) (groot-enter-jump! *groot-state* (groot-jump-alphabet)) event-result/consume]
        [else
         ;; Every remaining action completes or abandons a pending prefix.
         (groot-clear-pending! *groot-state*)
         (cond [(equal? action 'create) (groot-open-create-prompt!)]
               [(equal? action 'rename) (groot-open-rename-prompt!)]
               [(equal? action 'delete) (groot-open-delete-prompt!)]
               [(equal? action 'refresh) (groot-refresh)]
               [(equal? action 'move-down) (groot-move! *groot-state* 1)]
               [(equal? action 'move-up) (groot-move! *groot-state* -1)]
               [(equal? action 'move-top) (groot-move-top! *groot-state*)]
               [(equal? action 'move-bottom) (groot-move-bottom! *groot-state*)]
               [(equal? action 'center) (groot-center-cursor! *groot-state*)]
               [(equal? action 'activate) (groot-activate!)]
               [(equal? action 'toggle) (groot-toggle-current! *groot-state*)]
               [(equal? action 'search-start) (groot-start-search! *groot-state*)]
               [(equal? action 'close) (groot-close!)])
         (if (equal? action 'command-prompt) event-result/ignore event-result/consume)]))

;; Handles mouse and keyboard input for the mounted explorer.
(define (groot-handle-event state event)
  (define mouse-result (groot-handle-mouse-event event))
  (if mouse-result
      mouse-result
      (let ([key (groot-normalize-key event)])
        (groot-run-action!
         (groot-key-dispatch (groot-state-focused? *groot-state*)
                             (groot-state-jump-active? *groot-state*)
                             (groot-state-search-input? *groot-state*)
                             (groot-searching? *groot-state*)
                             (groot-state-pending-g? *groot-state*)
                             (groot-state-pending-z? *groot-state*)
                             key)
         key event))))

;; Creates the component used by Helix's compositor.
(define (groot-make-component)
  (new-component! "groot" void groot-render (hash "handle_event" groot-handle-event)))

;; Opens the explorer, caches the root listing, and reveals the current document once.
(define (groot-open)
  (groot-install-hooks!)
  (if (groot-active?)
      (begin
        (set-groot-state-focused! *groot-state* #f)
        (groot-sync-current-file!)
        (set-groot-state-focused! *groot-state* #t)
        (groot-request-redraw!))
      (let ([root (groot-workspace)])
        (set! *groot-state* (groot-state root *groot-default-jump-alphabet*))
        (set-groot-state-ignored! *groot-state* *groot-ignored-names*)
        (set-groot-state-scroll-lines! *groot-state* (groot-config-scroll-lines))
        (groot-load-directory! *groot-state* root)
        (groot-rebuild-tree! *groot-state*)
        (set-groot-state-focused! *groot-state* #f)
        (groot-reveal! *groot-state* (groot-current-document-path))
        (set-groot-state-focused! *groot-state* #t)
        (groot-open-effects!
         (lambda () (push-component! (groot-make-component)))
         groot-request-redraw!))))
