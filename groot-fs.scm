;; Filesystem adapter for groot.hx.  Directory metadata is classified once here.

(require "groot/groot-core.scm")
(require-builtin steel/process)

(provide groot-fs-read-directory groot-fs-find-files groot-fs-find-args)

;; Reads one directory into cached entry records. Symlinks are leaves, never recursion targets.
(define (groot-fs-read-directory path)
  (with-handler
   (lambda (_) '())
   (let ([iterator (read-dir-iter path)])
     (let loop ([acc '()])
       (define raw (read-dir-iter-next! iterator))
       (if (not raw)
           (groot-sort-entries (reverse acc))
           (let* ([child-path (read-dir-entry-path raw)]
                  [name (read-dir-entry-file-name raw)]
                  [kind (cond [(read-dir-entry-is-symlink? raw) 'symlink]
                              [(read-dir-entry-is-dir? raw) 'directory]
                              [else 'file])])
             ;; Steel reports non-UTF-8 paths as #false; omit them rather than
             ;; allowing one entry to make the whole sidebar unusable.
             (if (and (string? child-path) (string? name))
                 (loop (cons (groot-entry child-path name kind) acc))
                 (loop acc))))))))

;; External finders in preference order, mirroring snacks.nvim's cascade.
;; #f once probed and none were found; a program name once one was.
(define *groot-fs-finder* 'unprobed)

;; Probes for a finder once per session; repeat searches reuse the answer.
(define (groot-fs-finder)
  (when (equal? *groot-fs-finder* 'unprobed)
    (set! *groot-fs-finder*
          (let loop ([candidates '("fd" "fdfind" "rg")])
            (cond [(null? candidates) #f]
                  [(which (car candidates)) (car candidates)]
                  [else (loop (cdr candidates))]))))
  *groot-fs-finder*)

;; Repeats flag before each excluded name, producing one flat argument list.
(define (groot-fs-exclude-args flag names)
  (apply append (map (lambda (name) (list flag name)) names)))

;; Builds finder arguments that reproduce the explorer's own visibility rules:
;; dotfiles are listed, .gitignore is not consulted, and only excluded is skipped.
(define (groot-fs-find-args program root excluded)
  (if (equal? program "rg")
      (append (list "--files" "--hidden" "--no-ignore" "--no-messages" "--color" "never")
              (groot-fs-exclude-args "--glob" (map (lambda (n) (string-append "!" n)) excluded))
              (list root))
      (append (list "--type" "f" "--hidden" "--no-ignore" "--color" "never")
              (groot-fs-exclude-args "--exclude" excluded)
              (list "." root))))

;; Returns every file under root as absolute paths, or false when no finder ran.
;; A false result tells the caller to fall back to the in-process walk.
(define (groot-fs-find-files root excluded)
  (define program (groot-fs-finder))
  (and program
       (with-handler
        (lambda (_) #f)
        (let ([process (command program (groot-fs-find-args program root excluded))])
          (set-piped-stdout! process)
          (let ([output (Ok->value (wait->stdout (Ok->value (spawn-process process))))])
            (and (string? output)
                 (filter (lambda (line) (not (equal? line "")))
                         (split-many output "\n"))))))))
