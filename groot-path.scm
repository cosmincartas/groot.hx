;; Lexical path algebra for groot.hx.  Nothing here touches the filesystem, and
;; every function takes the separator explicitly so Windows rules can be tested
;; on POSIX.

(provide groot-path=?
         groot-path-inside?
         groot-windows-drive-root?
         groot-path-ends-with-separator?
         groot-path-join
         groot-parent-path
         groot-path-basename
         groot-ancestor-paths
         groot-ancestor-chain
         groot-rename-destination
         groot-rename-open-document-conflict?)

;; Windows paths identify the same entry regardless of case; POSIX paths do not.
(define (groot-path=? left right separator)
  (and (string? left) (string? right)
       (if (equal? separator "\\") (string-ci=? left right) (equal? left right))))

;; Reports whether path already ends with the one-character separator.
(define (groot-path-ends-with-separator? path separator)
  (and (> (string-length path) 0)
       (equal? (string-ref path (- (string-length path) 1)) (string-ref separator 0))))

;; Appends one component, adding a separator only when parent lacks one.
(define (groot-path-join parent name separator)
  (string-append parent
                 (if (groot-path-ends-with-separator? parent separator) "" separator)
                 name))

;; Reports whether path is root itself or a descendant on a path-component boundary.
(define (groot-path-inside? root path separator)
  (or (groot-path=? root path separator)
      (let ([prefix (if (groot-path-ends-with-separator? root separator)
                        root
                        (string-append root separator))])
        (and (>= (string-length path) (string-length prefix))
             (groot-path=? (substring path 0 (string-length prefix)) prefix separator)))))

;; Reports whether path is a Windows drive root such as C:\\.
(define (groot-windows-drive-root? path separator)
  (and (equal? separator "\\")
       (= (string-length path) 3)
       (equal? (string-ref path 1) #\:)
       (equal? (string-ref path 2) (string-ref separator 0))))

;; Removes one final path component without depending on filesystem state.
(define (groot-parent-path path separator)
  (if (groot-windows-drive-root? path separator)
      path
      (let loop ([idx (- (string-length path) 1)])
        (cond [(< idx 0) path]
              [(equal? (string-ref path idx) (string-ref separator 0))
               (cond [(= idx 0) separator]
                     [(and (= idx 2)
                           (equal? separator "\\")
                           (equal? (string-ref path 1) #\:))
                      (substring path 0 3)]
                     [else (substring path 0 idx)])]
              [else (loop (- idx 1))]))))

;; Returns the final component of path.
(define (groot-path-basename path separator)
  (define parent (groot-parent-path path separator))
  (substring path
             (if (groot-path-ends-with-separator? parent separator)
                 (string-length parent)
                 (+ (string-length parent) 1))
             (string-length path)))

;; Returns directory ancestors from root through the selected file's parent.
(define (groot-ancestor-paths root path separator)
  (if (not (groot-path-inside? root path separator))
      '()
      (let loop ([current (groot-parent-path path separator)] [acc '()])
        (cond [(equal? current root) (cons root acc)]
              [(equal? current path) '()]
              [else (loop (groot-parent-path current separator) (cons current acc))]))))

;; Returns the last count ancestors of path, outermost first, never above root.
;; Search headers use this so a deep parent reads as its own final directories
;; instead of as the whole route from the workspace root.
(define (groot-ancestor-chain root path separator count)
  (let loop ([current path] [remaining count] [acc '()])
    (cond [(equal? current root) (if (null? acc) (list root) acc)]
          [(not (groot-path-inside? root current separator)) (if (null? acc) (list root) acc)]
          [(<= remaining 0) acc]
          [else (loop (groot-parent-path current separator) (- remaining 1) (cons current acc))])))

;; Constructs a renamed entry beside source without normalizing its name.
(define (groot-rename-destination source submitted-name separator)
  (groot-path-join (groot-parent-path source separator) submitted-name separator))

;; Reports whether any open filesystem-backed document is source itself or a
;; descendant on an exact component boundary.
(define (groot-rename-open-document-conflict? source document-paths separator)
  (let loop ([remaining document-paths])
    (and (not (null? remaining))
         (or (and (string? (car remaining))
                  (groot-path-inside? source (car remaining) separator))
             (loop (cdr remaining))))))
