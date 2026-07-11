;; Filesystem adapter for groot.hx.  Directory metadata is classified once here.

(require "groot/groot-core.scm")

(provide groot-fs-read-directory)

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
