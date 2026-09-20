;; Viewport, jump-label, and text-fitting arithmetic for groot.hx.  Pure
;; functions over integers and strings; no state, Helix, or filesystem access.

(provide groot-clamp-position
         groot-window-after-move
         groot-scroll-position
         groot-centered-window-start
         groot-jump-label
         groot-jump-character-index
         groot-jump-prefix-valid?
         groot-truncate
         groot-truncate-start)

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
