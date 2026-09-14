;; Dependency-injected Helix integration orchestration for groot.hx.
;; Keeping these effects pure enough to load outside Helix gives lifecycle and
;; mouse behavior a small, fast regression harness.

(require "groot-core.scm")
(require "groot-fs.scm")

(provide groot-open-effects! groot-close-effects! groot-route-mouse! groot-refresh-effects!
         groot-collapse-all-effects!
         groot-key-dispatch groot-created-file-effects! groot-created-entry-effects! groot-create-prompt-effects!
         groot-rename-prompt-effects! groot-renamed-entry-effects!
         groot-delete-target-label groot-delete-surviving-ancestors
         groot-delete-request-effects! groot-delete-prompt-effects! groot-deleted-entry-effects!)

;; Mounts the component before requesting the redraw that makes it visible.
(define (groot-open-effects! mount! request-redraw!)
  (mount!)
  (request-redraw!))

;; Unmounts the component before scheduling clip release and editor redraw.
(define (groot-close-effects! unmount! schedule-cleanup!)
  (unmount!)
  (schedule-cleanup!))

;; Routes a normalized mouse kind and returns 'consume, 'ignore, or 'unhandled.
(define (groot-route-mouse! kind inside? focused? set-focus! select! scroll!)
  (cond [(equal? kind 'left)
         (if inside?
             (begin (set-focus! #t) (select!) 'consume)
             (begin (set-focus! #f) 'ignore))]
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
  (if (or (not state) (not (groot-state-ref state 'active? #f)))
      'inactive
      (begin
        (groot-state-set! state 'expanded
                          (hash-insert (hash) (groot-state-ref state 'root #f) #f))
        (groot-state-set! state 'query "")
        (groot-state-set! state 'results '())
        (groot-state-set! state 'result-count 0)
        (groot-state-set! state 'result-rows #())
        (groot-state-set! state 'search-input? #f)
        (groot-state-set! state 'pending-g? #f)
        (groot-state-set! state 'pending-z? #f)
        (groot-state-set! state 'jump-active? #f)
        (groot-state-set! state 'jump-input "")
        (groot-state-set! state 'cursor 0)
        (groot-state-set! state 'window 0)
        (rebuild-tree!)
        (redraw!)
        'collapsed)))

;; Selects the top-level keyboard owner.  groot-handle-event uses this seam so
;; prompt availability cannot drift from the dispatch tested without Helix.
(define (groot-key-dispatch focused? jump-active? search-input? searching? pending-g? pending-z? character)
  ;; Pending prefixes deliberately do not take ownership of `a`; the create
  ;; action tells the live handler to clear both before opening the prompt.
  (cond [(not focused?) 'ignore]
        [jump-active? 'jump]
        [search-input? 'search-input]
        [(and (equal? character 'escape) (not searching?)
              (not pending-g?) (not pending-z?)) 'focus-editor]
        [(and (char? character) (equal? character #\a) (not searching?))
         (if (or pending-g? pending-z?) 'create-clear-pending 'create)]
        [(and (char? character) (equal? character #\r) (not searching?))
         (if (or pending-g? pending-z?) 'rename-clear-pending 'rename)]
        [(and (char? character) (equal? character #\d) (not searching?))
         (if (or pending-g? pending-z?) 'delete-clear-pending 'delete)]
        [(and (char? character) (equal? character #\R)) 'refresh]
        [(and (char? character) (or (equal? character #\j) (equal? character #\k))) 'navigation]
        [else 'normal]))

;; Builds and pushes a native prompt after its destination has been captured.
;; The host only invokes CALLBACK on submission, so aborting needs no cleanup or
;; retained operation state. Creation errors are reported after prompt closure.
(define (groot-create-prompt-effects! context label make-prompt push! create! completed! report-error!)
  (push!
   (make-prompt
    label
    (lambda (submitted-path)
      (with-handler
       (lambda (error) (report-error! (to-string error)))
       (completed! (create! context submitted-path)))))))

;; Coordinates the UI work that follows a successful filesystem creation. The
;; reveal callback normally updates document-sync bookkeeping, so restore its
;; prior value after every outcome: creation does not open an editor buffer.
;; Failures only report a display problem and deliberately never compensate by
;; removing the newly created entry.
;; The document enumeration is deliberately inside the submitted callback: it
;; observes every open document immediately before the one filesystem boundary.
(define (groot-rename-prompt-effects! source label make-prompt push! document-paths!
                                      conflict? rename! renamed! report-error!)
  (push!
   (make-prompt
    label
    (lambda (submitted-name)
      (with-handler
       (lambda (error) (report-error! (to-string error)))
       (let ([document-paths (document-paths!)])
         (if (conflict? source document-paths)
             (report-error! "Cannot rename an entry that contains an open document.")
             (renamed! (rename! source submitted-name)))))))))

(define (groot-reveal-display-effects! path failure-prefix refresh-tree! reveal! redraw! report-error!
                                      get-last-document set-last-document!)
  (define previous-last-document (get-last-document))
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
(define (groot-renamed-entry-effects! source destination refresh-tree! reveal! redraw! report-error!
                                      get-last-document set-last-document!)
  (groot-reveal-display-effects!
   destination
   (string-append "Renamed " source " to " destination ", but the tree could not display it")
   refresh-tree! reveal! redraw! report-error! get-last-document set-last-document!))

;; Produces an unambiguous root-relative deletion target for the prompt.
(define (groot-delete-target-label root source separator)
  (substring source
             (+ (string-length root)
                (if (and (> (string-length root) 0)
                         (equal? (string-ref root (- (string-length root) 1))
                                 (string-ref separator 0)))
                    0 1))
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
(define (groot-delete-prompt-effects! context name kind current-width label! make-prompt push!
                                      document-paths! delete! completed! report-error!)
  ;; A rendered row can be stale while the prompt opens.  When the caller has
  ;; the filesystem capture, its live kind is the sole warning authority.
  (define authoritative-kind
    (if (GrootFsDeleteContext? context) (GrootFsDeleteContext-kind context) kind))
  (define (usable-label)
    (label! name authoritative-kind (current-width)))
  (define label (usable-label))
  (if (not (string? label))
      (report-error! "Cannot delete: the editor needs more width for confirmation.")
      (push!
       (make-prompt
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
(define (groot-deleted-entry-effects! source result ancestors invalidate! refresh-tree! probe? reveal!
                                      redraw! report-error! get-last-document set-last-document!)
  (define previous-last-document (get-last-document))
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

(define (groot-created-entry-effects! result collapse-directory! refresh-tree! reveal! redraw! report-error!
                                      get-last-document set-last-document!)
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
            path
            (string-append "Entry was created at " path ", but the tree could not display it")
            refresh-tree! reveal! redraw! report-error! get-last-document set-last-document!))
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

;; Compatibility seam retained for callers that already have a successful file
;; path; nested creation uses groot-created-entry-effects! above.
(define (groot-created-file-effects! path refresh-tree! reveal! redraw! report-error!
                                    get-last-document set-last-document!)
  (groot-reveal-display-effects!
   path
   (string-append "File was created at " path ", but the tree could not display it")
   refresh-tree! reveal! redraw! report-error! get-last-document set-last-document!))
