;; Temporary filesystem fixtures for groot-fs tests.

(require-builtin steel/random)
(require-builtin steel/process)

(provide with-fs-fixture
         fs-fixture-path
         fs-fixture-write!
         fs-fixture-mkdir!
         fs-fixture-symlink!
         fs-fixture-entry-kind
         fs-fixture-file-contents
         fs-fixture-empty?)

(define (fs-fixture-path parent name)
  (string-append parent (path-separator) name))

;; Steel has no temporary-directory primitive.  Keep the randomly named,
;; short-lived fixture directory below the test process's current directory and
;; remove it with Steel's native recursive delete API.
(define (fs-fixture-temporary-directory)
  (let loop ([attempts 100])
    (when (= attempts 0)
      (error "could not allocate a temporary filesystem fixture directory"))
    (define directory
      (fs-fixture-path
       (current-directory)
       (string-append ".groot-fs-test-" (to-string (rng->gen-usize)))))
    (if (path-exists? directory)
        (loop (- attempts 1))
        (begin (create-directory! directory) directory))))

(define (with-fs-fixture test)
  (define directory (fs-fixture-temporary-directory))
  (dynamic-wind
   (lambda () #f)
   (lambda () (test directory))
   (lambda () (delete-directory! directory))))

(define (fs-fixture-write! path contents)
  (define port (open-output-file path #:exists 'truncate))
  (display contents port)
  (close-output-port port))

(define (fs-fixture-mkdir! path)
  (create-directory! path))

;; Steel exposes symlink inspection but not creation.  Use the operating
;; system's native link utility only for this required fixture: POSIX uses ln
;; without a shell; Windows uses cmd's mklink and may require Developer Mode or
;; elevated symlink permission.  Failure is deliberately propagated, never
;; treated as a skipped collision test.
(define (fs-fixture-symlink! target link)
  (define windows? (equal? (path-separator) "\\"))
  (define process
    (if windows?
        (command "cmd" (list "/c"
                             (string-append "mklink \"" link "\" \"" target "\"")))
        (command "ln" (list "-s" target link))))
  (with-handler
   (lambda (error)
     (error (string-append
             "unable to create required symbolic-link fixture"
             (if windows?
                 "; enable Windows Developer Mode or grant symlink permission: "
                 ": ")
             (to-string error))))
   (let ([exit-code (Ok->value (wait (Ok->value (spawn-process process))))])
     (unless (= exit-code 0)
       (error (string-append "native link utility exited with status "
                             (to-string exit-code))))
     #f)))

(define (fs-fixture-entry-kind parent name)
  (let ([iterator (read-dir-iter parent)])
    (let loop ()
      (define entry (read-dir-iter-next! iterator))
      (cond [(not entry) #f]
            [(equal? (read-dir-entry-file-name entry) name)
             (cond [(read-dir-entry-is-symlink? entry) 'symlink]
                   [(read-dir-entry-is-dir? entry) 'directory]
                   [(read-dir-entry-is-file? entry) 'file]
                   [else 'special])]
            [else (loop)]))))

(define (fs-fixture-file-contents path)
  (define port (open-input-file path))
  (dynamic-wind
   (lambda () #f)
   (lambda () (read-port-to-string port))
   (lambda () (close-input-port port))))

(define (fs-fixture-empty? directory)
  (not (read-dir-iter-next! (read-dir-iter directory))))
