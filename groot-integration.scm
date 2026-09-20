;; Dependency-injected Helix integration orchestration for groot.hx.
;; Keeping these effects pure enough to load outside Helix gives lifecycle and
;; mouse behavior a small, fast regression harness.

(require "groot-core.scm")
(require "groot-path.scm")
(require "groot-fs.scm")

(provide GrootHost GrootHost? GrootMouseHost GrootMouseHost?
         groot-open-effects! groot-close-effects! groot-route-mouse! groot-resized-width groot-refresh-effects!
         groot-collapse-all-effects!
         groot-key-dispatch groot-created-entry-effects! groot-create-prompt-effects!
         groot-rename-prompt-effects! groot-renamed-entry-effects!
         groot-delete-target-label groot-delete-surviving-ancestors
         groot-delete-request-effects! groot-delete-prompt-effects! groot-deleted-entry-effects!)

;; Host effects shared by the prompt and display seams below.  One record keeps
;; the call sites short and guarantees every seam sees the same host behavior.
;;   refresh-tree!        rebuilds the tree from the filesystem
;;   reveal!              selects a path, returning #t when a row now shows it
;;   redraw!              requests a sidebar redraw
;;   report-error!        shows a message in the host error area
;;   get-last-document    reads the document-sync bookkeeping value
;;   set-last-document!   restores that value after a reveal changed it
;;   make-prompt          builds a native prompt from a label and submit callback
;;   push!                mounts a component such as that prompt
;;   document-paths!      lists every open document path
(struct GrootHost (refresh-tree! reveal! redraw! report-error! get-last-document set-last-document!
                   make-prompt push! document-paths!)
  #:transparent)

;; Mouse effects: focus ownership, drag capture, row selection, wheel, resize.
(struct GrootMouseHost (set-focus! set-resizing! select! scroll! resize!) #:transparent)

;; Mounts the component before requesting the redraw that makes it visible.
(define (groot-open-effects! mount! request-redraw!)
  (mount!)
  (request-redraw!))

;; Unmounts the component before scheduling clip release and editor redraw.
(define (groot-close-effects! unmount! schedule-cleanup!)
  (unmount!)
  (schedule-cleanup!))

;; Converts a separator column to the persistent requested pane width.
(define (groot-resized-width side terminal-width column)
  (max 20 (if (equal? side 'right) (- terminal-width column) (+ column 1))))

;; Routes normalized mouse input, retaining separator drag capture until release.
(define (groot-route-mouse! host kind inside? separator? focused? resizing?)
  (define set-focus! (GrootMouseHost-set-focus! host))
  (define set-resizing! (GrootMouseHost-set-resizing! host))
  (define select! (GrootMouseHost-select! host))
  (define scroll! (GrootMouseHost-scroll! host))
  (define resize! (GrootMouseHost-resize! host))
  (cond [(equal? kind 'left)
         (cond [separator? (set-focus! #t) (set-resizing! #t) 'consume]
               [inside? (set-focus! #t) (select!) 'consume]
               [else (set-focus! #f) 'ignore])]
        [(equal? kind 'drag)
         (if resizing? (begin (resize!) 'consume) 'unhandled)]
        [(equal? kind 'release)
         (if resizing? (begin (set-resizing! #f) 'consume) 'unhandled)]
        [(or (equal? kind 'up) (equal? kind 'down))
         (if inside?
             (begin (when focused? (scroll! kind)) 'consume)
             (begin (set-focus! #f) 'ignore))]
        [else 'unhandled]))

;; Rebuilds active data before redraw and refreshes matches only in search mode.
(define (groot-refresh-effects! active? searching? refresh-tree! refresh-search! redraw!)
  (if (not active?)
      'inactive
      (begin
        (refresh-tree!)
        (when searching? (refresh-search!))
        (redraw!)
        'refreshed)))

;; Restores active transient tree-view state before rebuilding the displayed rows.
(define (groot-collapse-all-effects! state rebuild-tree! redraw!)
  (if (or (not state) (not (groot-state-active? state)))
      'inactive
      (begin
        (set-groot-state-expanded! state (hash-insert (hash) (groot-state-root state) #t))
        (set-groot-state-query! state "")
        (set-groot-state-results! state '())
        (set-groot-state-result-count! state 0)
        (set-groot-state-result-rows! state #())
        (set-groot-state-search-input! state #f)
        (set-groot-state-pending-g! state #f)
        (set-groot-state-pending-z! state #f)
        (set-groot-state-jump-active! state #f)
        (set-groot-state-jump-input! state "")
        (set-groot-state-cursor! state 0)
        (set-groot-state-window! state 0)
        (rebuild-tree!)
        (redraw!)
        'collapsed)))

;; Maps one normalized key to the explorer action it triggers.  KEY is a
;; character or one of 'escape 'enter 'tab 'up 'down 'backspace 'other.
;; groot-handle-event runs exactly the returned action, so every binding and
;; its mode precedence is decided here and tested without Helix.
;;
;; Pending g/z prefixes never own a key: any other action clears them.  Search
;; results keep a/r/d as ordinary keys so a result row is never mutated.
(define (groot-key-dispatch focused? jump-active? search-input? searching? pending-g? pending-z? key)
  (cond [(not focused?) 'ignore]
        [jump-active? 'jump]
        [search-input?
         (cond [(equal? key 'escape) 'search-leave]
               ;; Enter keeps the query and hands the results to navigation.
               [(equal? key 'enter) 'search-leave]
               [(equal? key 'backspace) 'search-backspace]
               [(char? key) 'search-type]
               [else 'consume])]
        [(and (equal? key 'escape) (not searching?) (not pending-g?) (not pending-z?)) 'focus-editor]
        [(and (equal? key #\a) (not searching?)) 'create]
        [(and (equal? key #\r) (not searching?)) 'rename]
        [(and (equal? key #\d) (not searching?)) 'delete]
        [(equal? key #\R) 'refresh]
        [(or (equal? key #\j) (equal? key 'down)) 'move-down]
        [(or (equal? key #\k) (equal? key 'up)) 'move-up]
        [(and pending-g? (equal? key #\w)) 'jump-start]
        [(and pending-g? (equal? key #\e)) 'move-bottom]
        [(equal? key #\g) (if pending-g? 'move-top 'pending-g)]
        [(equal? key #\G) 'move-bottom]
        [(and pending-z? (equal? key #\z)) 'center]
        [(equal? key #\z) 'pending-z]
        [(equal? key 'enter) 'activate]
        [(equal? key 'tab) 'toggle]
        [(equal? key #\/) 'search-start]
        [(equal? key #\q) 'close]
        ;; Helix owns its command prompt even while the explorer has focus.
        [(equal? key #\:) 'command-prompt]
        [else 'clear]))

;; Builds and pushes a native prompt after its destination has been captured.
;; The host only invokes CALLBACK on submission, so aborting needs no cleanup or
;; retained operation state. Creation errors are reported after prompt closure.
(define (groot-create-prompt-effects! host context label create! completed!)
  (define report-error! (GrootHost-report-error! host))
  ((GrootHost-push! host)
   ((GrootHost-make-prompt host)
    label
    (lambda (submitted-path)
      (with-handler
       (lambda (error) (report-error! (to-string error)))
       (completed! (create! context submitted-path)))))))

;; Builds and pushes the rename prompt for a captured source.
;; The document enumeration is deliberately inside the submitted callback: it
;; observes every open document immediately before the one filesystem boundary.
(define (groot-rename-prompt-effects! host source label conflict? rename! renamed!)
  (define report-error! (GrootHost-report-error! host))
  ((GrootHost-push! host)
   ((GrootHost-make-prompt host)
    label
    (lambda (submitted-name)
      (with-handler
       (lambda (error) (report-error! (to-string error)))
       (let ([document-paths ((GrootHost-document-paths! host))])
         (if (conflict? source document-paths)
             (report-error! "Cannot rename an entry that contains an open document.")
             (renamed! (rename! source submitted-name)))))))))

;; Refreshes, reveals, and redraws after a successful filesystem mutation.  The
;; reveal callback normally updates document-sync bookkeeping, so its prior
;; value is restored after every outcome: mutation does not open an editor
;; buffer.  Failures only report a display problem and never compensate by
;; undoing the mutation.
(define (groot-reveal-display-effects! host path failure-prefix)
  (define refresh-tree! (GrootHost-refresh-tree! host))
  (define reveal! (GrootHost-reveal! host))
  (define redraw! (GrootHost-redraw! host))
  (define report-error! (GrootHost-report-error! host))
  (define set-last-document! (GrootHost-set-last-document! host))
  (define previous-last-document ((GrootHost-get-last-document host)))
  (define result
    (with-handler
     (lambda (error) (list 'error error))
     (begin (refresh-tree!) (if (reveal! path) 'revealed 'missing))))
  (set-last-document! previous-last-document)
  (unless (equal? result 'revealed)
    (report-error! (string-append failure-prefix
                                  (if (equal? result 'missing)
                                      "."
                                      (string-append ": " (to-string (cadr result)))))))
  (define redraw-result
    (with-handler
     (lambda (error) (list 'redraw-error error))
     (begin (redraw!) 'redrawn)))
  (cond [(not (equal? redraw-result 'redrawn))
         (report-error!
          (string-append failure-prefix
                         (if (equal? result 'revealed) "" "; additionally, refresh or selection failed")
                         "; the tree could not redraw: " (to-string (cadr redraw-result))))
         'display-failed]
        [(equal? result 'revealed) 'revealed]
        [else 'display-failed]))

;; Coordinates the UI work after the filesystem rename has succeeded. As with
;; create, display failure is reported without attempting a compensating rename.
(define (groot-renamed-entry-effects! host source destination)
  (groot-reveal-display-effects!
   host destination
   (string-append "Renamed " source " to " destination ", but the tree could not display it")))

;; Produces an unambiguous root-relative deletion target for the prompt.
(define (groot-delete-target-label root source separator)
  (substring source
             (+ (string-length root) (if (groot-path-ends-with-separator? root separator) 0 1))
             (string-length source)))

;; Produces the nearest-first fallback list used by the host deletion adapter.
(define (groot-delete-surviving-ancestors root source separator)
  (reverse (groot-ancestor-paths root source separator)))

;; Classifies a displayed delete request before capture or prompt allocation.
;; No row is an intentional no-op; root and unexpected displayed kinds are
;; rejected through the host error area.
(define (groot-delete-request-effects! entry root open! report-error!)
  (cond [(not entry) 'empty]
        [(equal? (groot-entry-path entry) root)
         (report-error! "Cannot delete the workspace root.")
         'rejected]
        [(or (equal? (groot-entry-kind entry) 'file)
             (equal? (groot-entry-kind entry) 'symlink)
             (groot-directory? entry))
         (open!)
         'opened]
        [else
         (report-error! (string-append "Cannot delete " (groot-entry-name entry)
                                      ": unsupported entry."))
         'rejected]))

;; Opens a confirmation only when its warning can fit.  The callback repeats
;; that check before enumerating documents, so a resize cannot authorize a
;; mutation.  Native prompts do not call CALLBACK for Escape/Ctrl-C.
(define (groot-delete-prompt-effects! host context name kind current-width label! delete! completed!)
  (define report-error! (GrootHost-report-error! host))
  (define document-paths! (GrootHost-document-paths! host))
  ;; A rendered row can be stale while the prompt opens.  When the caller has
  ;; the filesystem capture, its live kind is the sole warning authority.
  (define authoritative-kind
    (if (GrootFsDeleteContext? context) (GrootFsDeleteContext-kind context) kind))
  (define (usable-label)
    (label! name authoritative-kind (current-width)))
  (define label (usable-label))
  (if (not (string? label))
      (report-error! "Cannot delete: the editor needs more width for confirmation.")
      ((GrootHost-push! host)
       ((GrootHost-make-prompt host)
        label
        (lambda (submitted)
          ;; Do not trim, fold case, or enumerate documents before exact approval.
          (when (equal? submitted "yes")
            (if (not (string? (usable-label)))
                (report-error! "Cannot delete: the editor needs more width for confirmation.")
                (let ([result
                       (with-handler
                        (lambda (error) (list 'rejected (to-string error)))
                        ;; Bind first so Scheme argument evaluation order cannot
                        ;; move enumeration behind the filesystem boundary.
                        (let ([documents (document-paths!)])
                          (delete! context documents)))])
                  (cond [(and (pair? result) (equal? (car result) 'rejected))
                         (report-error! (string-append "Cannot delete " name ": " (cadr result)))]
                        [(and (GrootFsDeleteResult? result)
                              (equal? (GrootFsDeleteResult-outcome result) 'rejected))
                         (report-error!
                          (string-append "Cannot delete " name ": "
                                         (GrootFsDeleteResult-detail result)))]
                        [else (completed! result)])))))))))

;; A native attempt always gets one display recovery attempt.  Rejections and
;; cancellations never reach this seam.  PROBE? must inspect the live filesystem
;; rather than trusting the synthetic root row.  Redraw is part of that attempt:
;; its error must not escape after a native outcome has already been recorded.
(define (groot-deleted-entry-effects! host source result ancestors invalidate! probe?)
  (define refresh-tree! (GrootHost-refresh-tree! host))
  (define reveal! (GrootHost-reveal! host))
  (define redraw! (GrootHost-redraw! host))
  (define report-error! (GrootHost-report-error! host))
  (define set-last-document! (GrootHost-set-last-document! host))
  (define previous-last-document ((GrootHost-get-last-document host)))
  (define native-failure? (equal? (GrootFsDeleteResult-outcome result) 'native-failure))
  (define recovery
    (with-handler
     (lambda (error) (list 'recovery-error error))
     (begin
       (invalidate!)
       (let ([refresh-result (refresh-tree!)])
         ;; The deletion-only host adapter returns this when its strict root
         ;; listing fails. Ordinary explorer refresh intentionally suppresses
         ;; listing errors, but that synthetic root row is not recovery proof.
         (if (and (pair? refresh-result)
                  (equal? (car refresh-result) 'root-unavailable))
             refresh-result
             (let loop ([paths ancestors])
               (cond [(null? paths) 'unavailable]
                     ;; A successful strict root listing is authoritative proof
                     ;; that the final captured ancestor survives.  Do not probe
                     ;; it through its parent: / has none and a readable root's
                     ;; parent may be unavailable.
                     [(null? (cdr paths))
                      (if (reveal! (car paths)) 'revealed 'unavailable)]
                     [(probe? (car paths))
                      (if (reveal! (car paths)) 'revealed (loop (cdr paths)))]
                     [else (loop (cdr paths))])))))))
  ;; Reveal can update document-sync state; deletion must leave it unchanged even
  ;; when the subsequent redraw fails.
  (set-last-document! previous-last-document)
  (define redraw-result
    (with-handler
     (lambda (error) (list 'redraw-error error))
     (begin (redraw!) 'redrawn)))
  (define (native-prefix)
    (string-append "Deletion of " source
                   " failed; some contents may already be deleted and no rollback occurred: "
                   (GrootFsDeleteResult-detail result)))
  (define (report-display! problem)
    (report-error!
     (string-append (if native-failure?
                        (string-append (native-prefix) "; additionally, " problem)
                        (string-append "Deletion succeeded, but " problem)))))
  (cond [(not (equal? redraw-result 'redrawn))
         (report-display! (string-append "the tree could not redraw: "
                                         (to-string (cadr redraw-result))))
         'display-failed]
        [(equal? recovery 'revealed)
         (when native-failure? (report-error! (native-prefix)))
         (if native-failure? 'native-failure 'deleted)]
        [(and (pair? recovery) (equal? (car recovery) 'root-unavailable))
         (report-display! (string-append "the workspace root is unavailable for display: " source
                                         ": " (to-string (cadr recovery))))
         'display-failed]
        [(equal? recovery 'unavailable)
         (report-display! (string-append "the workspace root is unavailable for display: " source))
         'display-failed]
        [else
         (report-display! (string-append "the tree could not refresh or select a surviving parent: "
                                         (to-string (cadr recovery))))
         'display-failed]))

(define (groot-created-entry-effects! host result collapse-directory!)
  (define refresh-tree! (GrootHost-refresh-tree! host))
  (define redraw! (GrootHost-redraw! host))
  (define report-error! (GrootHost-report-error! host))
  (define outcome (GrootFsCreateResult-outcome result))
  (define path (GrootFsCreateResult-path result))
  (define detail (GrootFsCreateResult-detail result))
  (cond [(equal? outcome 'success)
         ;; Collapse before refresh so a recreated path cannot retain expansion
         ;; state from an externally removed directory. It is display recovery,
         ;; so an exception cannot bypass refresh and redraw.
         (define collapse-result
           (with-handler (lambda (error) (list 'collapse-error error))
             (begin (collapse-directory! path) 'collapsed)))
         (define display-result
           (groot-reveal-display-effects!
            host path
            (string-append "Entry was created at " path ", but the tree could not display it")))
         (if (equal? collapse-result 'collapsed)
             display-result
             (begin
               (report-error! (string-append "Entry was created at " path
                                            ", but its collapsed state could not be restored: "
                                            (to-string (cadr collapse-result))))
               'display-failed))]
        [(GrootFsCreateResult-mutation-started? result)
         ;; A failed native call can still have changed the filesystem. Refresh
         ;; once, retain created parents, and never compensate.
         (define refresh-result
           (with-handler (lambda (error) (list 'refresh-error error))
             (begin (refresh-tree!) 'refreshed)))
         (define redraw-result
           (with-handler (lambda (error) (list 'redraw-error error))
             (begin (redraw!) 'redrawn)))
         (report-error!
          (string-append "Creation " (if (equal? outcome 'partial-failure) "partially completed" "failed")
                         ": " (or detail "filesystem operation failed")
                         (if (equal? refresh-result 'refreshed) ""
                             (string-append "; the tree could not refresh: "
                                            (to-string (cadr refresh-result))))
                         (if (equal? redraw-result 'redrawn) ""
                             (string-append "; the tree could not redraw: "
                                            (to-string (cadr redraw-result))))))
         outcome]
        [else
         (report-error! (string-append "Cannot create entry: " (or detail "invalid path")))
         outcome]))
