;; Native prompt labels for groot.hx.  Labels must identify their target while
;; leaving the Helix prompt enough room for input, measured both in terminal
;; cells and in the UTF-8 byte offsets Helix uses to clip prompt text.

(provide groot-prompt-filename-label-budget
         groot-prompt-host-byte-width
         groot-prompt-cell-width
         groot-prompt-remaining-input
         groot-create-prompt-label
         groot-rename-prompt-label
         groot-delete-prompt-label)

;; The native prompt keeps two columns clear at its right edge.  Each caller
;; reserves the input it requires from the remaining label budget.
(define (groot-prompt-label-budget prompt-width input-width)
  (max 0 (- (max 1 prompt-width) 2 input-width)))

;; Leave eight columns for a usable filename editor, even when a narrow UI
;; supplies the prompt. This preserves the existing create and rename budget.
(define (groot-prompt-filename-label-budget prompt-width)
  (max 1 (groot-prompt-label-budget prompt-width 8)))

;; Helix clips prompt text using Rust String::len(), which is a UTF-8 byte
;; offset. This is the actual host offset, not Steel's character count.
(define (groot-prompt-host-byte-width text)
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
(define (groot-prompt-cell-width text)
  (let loop ([index 0] [width 0])
    (if (>= index (string-length text))
        width
        (loop (+ index 1)
              (+ width (if (< (char->integer (string-ref text index)) 128) 1 2))))))

;; Budget UTF-8 conservatively: non-ASCII may occupy four host bytes, except
;; the truncation ellipsis, whose UTF-8 representation is exactly three bytes.
(define (groot-prompt-byte-budget-width text)
  (let loop ([index 0] [width 0])
    (if (>= index (string-length text))
        width
        (let ([codepoint (char->integer (string-ref text index))])
          (loop (+ index 1)
                (+ width (cond [(< codepoint #x80) 1]
                               [(= codepoint #x2026) 3]
                               [else 4])))))))

;; Reports the editor width left after Helix's right margin and its byte-based
;; prompt offset have been accounted for.
(define (groot-prompt-remaining-input prompt-width label)
  (max 0 (- (max 1 prompt-width) 2 (groot-prompt-host-byte-width label))))

;; Retains the identifying tail while respecting display cells and Helix's
;; UTF-8 byte offset. The ellipsis itself costs two conservative cells and
;; three bytes.
(define (groot-prompt-truncate-start text cell-width byte-width)
  (cond [(or (<= cell-width 0) (<= byte-width 0)) ""]
        [(and (<= (groot-prompt-cell-width text) cell-width)
              (<= (groot-prompt-byte-budget-width text) byte-width)) text]
        [(or (< cell-width 1) (< byte-width 3)) "."]
        [else
         (let loop ([index (- (string-length text) 1)] [tail ""] [cells 2] [bytes 3])
           (if (< index 0)
               (string-append "…" tail)
               (let* ([character (string (string-ref text index))]
                      [character-cells (groot-prompt-cell-width character)]
                      [character-bytes (groot-prompt-byte-budget-width character)])
                 (if (or (> (+ cells character-cells) cell-width)
                         (> (+ bytes character-bytes) byte-width))
                     (string-append "…" tail)
                     (loop (- index 1) (string-append character tail)
                           (+ cells character-cells) (+ bytes character-bytes))))))]))

;; Keeps a native prompt label bounded, retaining the destination tail that
;; identifies the selected directory while reserving a filename editor.
(define (groot-create-prompt-label destination prompt-width)
  (define width (groot-prompt-filename-label-budget prompt-width))
  (define suffix ":")
  ;; Use the full "Create in" wording whenever it and a meaningful destination
  ;; tail fit. Narrow prompts use the compact label to retain input space.
  (define prefix (cond [(<= width 12) "Create:"]
                       [(<= width 18) "Create: "]
                       [else "Create in "]))
  (define (truncate-destination label-prefix)
    (groot-prompt-truncate-start
     destination
     (max 0 (- width (groot-prompt-cell-width label-prefix)
               (groot-prompt-cell-width suffix)))
     (max 0 (- width (groot-prompt-byte-budget-width label-prefix)
               (groot-prompt-byte-budget-width suffix)))))
  (define shortened-destination (truncate-destination prefix))
  ;; A four-byte destination tail cannot accompany even the compact prefix at
  ;; 22 columns. Prefer the identifying tail to that cosmetic prompt prefix.
  (define label-prefix
    (if (and (equal? shortened-destination "…") (> (string-length destination) 0))
        ""
        prefix))
  (groot-prompt-truncate-start
   (string-append label-prefix (truncate-destination label-prefix) suffix)
   width width))

;; Produces the native prompt label while reserving room for filename input.
(define (groot-rename-prompt-label name prompt-width)
  (define prefix "Rename ")
  (define suffix ":")
  (define width (groot-prompt-filename-label-budget prompt-width))
  (string-append
   prefix
   (groot-prompt-truncate-start
    name
    (max 0 (- width (groot-prompt-cell-width prefix)
              (groot-prompt-cell-width suffix)))
    (max 0 (- width (groot-prompt-byte-budget-width prefix)
              (groot-prompt-byte-budget-width suffix))))
   suffix))

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
         (<= (groot-prompt-cell-width label) label-budget)
         (<= (groot-prompt-byte-budget-width label) label-budget)
         (>= (groot-prompt-remaining-input prompt-width label) 4)))
  (if (or (not suffix) (= (string-length name) 0))
      'insufficient-space
      (let* ([final-character (string (string-ref name (- (string-length name) 1)))]
             [target-cell-budget (- label-budget
                                    (groot-prompt-cell-width prefix)
                                    (groot-prompt-cell-width suffix))]
             [target-byte-budget (- label-budget
                                    (groot-prompt-byte-budget-width prefix)
                                    (groot-prompt-byte-budget-width suffix))]
             ;; Refuse instead of replacing the target with only an ellipsis:
             ;; confirmation must still identify the captured entry.
             [minimum-label (string-append prefix final-character suffix)])
        (if (or (not (fits? minimum-label))
                (<= target-cell-budget 0)
                (<= target-byte-budget 0))
            'insufficient-space
            (let ([label (string-append
                          prefix
                          (groot-prompt-truncate-start name target-cell-budget target-byte-budget)
                          suffix)])
              (if (fits? label) label 'insufficient-space))))))
