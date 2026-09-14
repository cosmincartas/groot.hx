;; Test worker: waits at a barrier, then invokes the public creation API.
;; Arguments are parent, filename, readiness path, release path, winner text,
;; and a result path.

(require "../groot-fs.scm")

(define arguments (command-line))
(define parent (list-ref arguments 2))
(define filename (list-ref arguments 3))
(define ready (list-ref arguments 4))
(define release (list-ref arguments 5))
(define winner (list-ref arguments 6))
(define result (list-ref arguments 7))

(define ready-port (open-output-file ready #:exists 'error))
(close-output-port ready-port)
(let wait ([attempts 10000000])
  (cond [(path-exists? release) #f]
        [(= attempts 0) (error "concurrent-create worker timed out at barrier")]
        [else (wait (- attempts 1))]))

(define succeeded?
  (with-handler
   (lambda (_) #f)
   (let ([created (groot-fs-create-entry (groot-fs-capture-create-context parent) filename)])
     (if (equal? (GrootFsCreateResult-outcome created) 'success)
         (begin
           ;; Keep the existing file-race sentinel; directories need no payload.
           (unless (equal? (string-ref filename (- (string-length filename) 1)) #\/)
             (define output (open-output-file (GrootFsCreateResult-path created) #:exists 'truncate))
             (display winner output)
             (close-output-port output))
           #t)
         #f))))
(define result-port (open-output-file result #:exists 'error))
(display (if succeeded? "success" "failure") result-port)
(close-output-port result-port)
