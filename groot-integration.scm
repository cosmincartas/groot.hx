;; Dependency-injected Helix integration orchestration for groot.hx.
;; Keeping these effects pure enough to load outside Helix gives lifecycle and
;; mouse behavior a small, fast regression harness.

(provide groot-open-effects! groot-close-effects! groot-route-mouse! groot-refresh-effects!)

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
