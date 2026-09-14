;; Filesystem adapter for groot.hx.  Directory metadata is classified once here.

(require "groot-core.scm")
(require-builtin steel/process)

(provide groot-fs-read-directory groot-fs-read-directory/strict groot-fs-find-files groot-fs-find-args
         groot-fs-create-empty-file groot-fs-rename-entry
         groot-fs-capture-delete-context groot-fs-delete-entry
         groot-fs-delete-entry/with-operations
         GrootFsDeleteContext? GrootFsDeleteContext-kind GrootFsDeleteResult?
         GrootFsDeleteResult-outcome GrootFsDeleteResult-detail
         GrootFsDeleteResult-native-started? GrootFsDeleteResult-address groot-fs-live-entry-kind
         GrootFsCreateContext? GrootFsCreateContext-destination GrootFsCreateContext-canonical-destination
         GrootFsCreateResult GrootFsCreateResult? GrootFsCreateResult-outcome GrootFsCreateResult-path
         GrootFsCreateResult-detail GrootFsCreateResult-mutation-started?
         groot-fs-capture-create-context groot-fs-create-entry groot-fs-create-entry/with-operations
         groot-fs-create-entry/with-operations-and-mode)

(define (groot-fs-single-entry-name? name separator)
  (and (string? name) (> (string-length name) 0)
       (not (equal? name ".")) (not (equal? name ".."))
       (not (string-contains? name separator))
       (not (and (equal? separator "\\") (string-contains? name "/")))
       (not (and (equal? separator "\\") (string-contains? name ":")))
       (not (string-contains? name "\0"))))

(define (groot-fs-join parent name separator)
  (string-append parent
                 (if (or (equal? parent separator)
                         (and (> (string-length parent) 0)
                              (equal? (string-ref parent (- (string-length parent) 1))
                                      (string-ref separator 0))))
                     "" separator)
                 name))

;; Creates one empty child without allowing a submitted name to name a path.
(define (groot-fs-create-empty-file parent filename)
  (define separator (path-separator))
  (unless (and (string? parent) (groot-fs-single-entry-name? filename separator))
    (error "expected a non-empty single-entry filename"))
  (define destination (groot-fs-join parent filename separator))
  (define port (open-output-file destination #:exists 'error))
  (close-output-port port)
  destination)

;; Directory iteration also detects dangling symlinks, for which path-exists?
;; is false despite an occupied destination entry.
(define (groot-fs-destination-exists? destination)
  (or (path-exists? destination)
      (let ([iterator (read-dir-iter
                       (groot-parent-path destination (path-separator)))])
        (let loop ()
          (define entry (read-dir-iter-next! iterator))
          (and entry
               (or (equal? (read-dir-entry-path entry) destination)
                   (loop)))))))

;; Classifies a directory entry without treating devices, FIFOs, sockets, or
;; other special nodes as regular files.
(define (groot-fs-directory-entry-kind entry)
  (cond [(read-dir-entry-is-symlink? entry) 'symlink]
        [(read-dir-entry-is-dir? entry) 'directory]
        [(read-dir-entry-is-file? entry) 'file]
        [else 'special]))

;; Windows resolves directory-entry names case-insensitively; POSIX does not.
(define (groot-fs-entry-name=? actual expected separator)
  (and (string? actual) (string? expected)
       (if (equal? separator "\\")
           (string-ci=? actual expected)
           (equal? actual expected))))

;; Only filesystem roots have no basename to enumerate. Relative paths with no
;; separator still require ordinary directory-entry classification.
(define (groot-fs-filesystem-root? source separator)
  (or (equal? source separator)
      (and (equal? separator "\\")
           (= (string-length source) 3)
           (equal? (string-ref source 1) #\:)
           (equal? (string-ref source 2) #\\))))

;; Re-reads SOURCE immediately before rename so a captured regular entry cannot
;; be swapped for a link or special node while the native prompt is open.
(define (groot-fs-live-entry-kind source)
  (define separator (path-separator))
  (define parent (groot-parent-path source separator))
  ;; Filesystem roots have no basename to enumerate. They are directories when
  ;; live; ordinary destinations still use strict directory-entry classification.
  (if (groot-fs-filesystem-root? source separator)
      (if (path-exists? source) 'directory 'missing)
      (let ([iterator (read-dir-iter parent)]
            ;; Directory-entry paths can be unavailable (#<void>) for otherwise
            ;; valid entries. Compare the already-validated final component instead.
            [basename (groot-fs-basename source separator)])
        (let loop ()
          (define entry (read-dir-iter-next! iterator))
          (cond [(not entry) 'missing]
                [(groot-fs-entry-name=? (read-dir-entry-file-name entry) basename separator)
                 (groot-fs-directory-entry-kind entry)]
                [else (loop)])))))

;; A deletion context deliberately records the entry address, rather than its
;; referent: canonicalizing a symlink here would make unlinking it unsafe.
(struct GrootFsDeleteContext (root source basename kind canonical-root canonical-parent)
  #:transparent)
(struct GrootFsDeleteResult (outcome detail native-started? address) #:transparent)

(define (groot-fs-error-detail error)
  ;; Native Steel errors can carry #<void>; report a usable detail rather than
  ;; letting that value masquerade as a successful operation.
  (if (void? error)
      "filesystem operation failed"
      (with-handler
       (lambda (_) "filesystem operation failed")
       (let ([detail (to-string error)])
         (if (string-contains? detail "#<void>")
             "filesystem operation failed"
             detail)))))

(define (groot-fs-supported-delete-kind? kind)
  (or (equal? kind 'file) (equal? kind 'directory) (equal? kind 'symlink)))

(define (groot-fs-strictly-inside? root path separator)
  (and (groot-path-inside? root path separator) (not (equal? root path))))

(define (groot-fs-basename path separator)
  (define parent (groot-parent-path path separator))
  (substring path
             (if (and (> (string-length parent) 0)
                      (equal? (string-ref parent (- (string-length parent) 1))
                              (string-ref separator 0)))
                 (string-length parent)
                 (+ (string-length parent) 1))
             (string-length path)))

(define (groot-fs-has-traversal? path separator)
  (or (not (string? path))
      (not (null? (filter (lambda (component)
                            (or (equal? component ".") (equal? component "..")))
                          (split-many path separator))))))

;; This is called before the prompt opens.  The same facts are checked again by
;; the boundary below, because they may have changed while the prompt was open.
(define (groot-fs-capture-delete-context root source)
  (define separator (path-separator))
  (unless (and (string? root) (string? source)
               (not (groot-fs-has-traversal? root separator))
               (not (groot-fs-has-traversal? source separator))
               (groot-fs-strictly-inside? root source separator))
    (error "invalid deletion root or source"))
  (define basename (groot-fs-basename source separator))
  (unless (groot-fs-single-entry-name? basename separator)
    (error "invalid deletion basename"))
  (define kind (groot-fs-live-entry-kind source))
  (unless (groot-fs-supported-delete-kind? kind)
    (error "deletion source is missing or unsupported"))
  (GrootFsDeleteContext root source basename kind
                        (canonicalize-path root)
                        (canonicalize-path (groot-parent-path source separator))))

;; Resolves an existing document, or reconstructs its missing suffix from the
;; nearest resolvable ancestor.  A missing suffix is accepted only after its
;; first component is independently found absent in an enumerable parent;
;; resolution failures for an existing or inaccessible component remain errors.
(define (groot-fs-document-address path canonicalize kind-of)
  (define separator (path-separator))
  (let loop ([current path] [suffix '()])
    (define address
      (let ([candidate
             (with-handler (lambda (_) #f)
               (canonicalize current))])
        (and (string? candidate) candidate)))
    (if address
        (if (null? suffix)
            address
            (let ([first-child
                   (string-append current
                                  (if (and (> (string-length current) 0)
                                           (equal? (string-ref current (- (string-length current) 1))
                                                   (string-ref separator 0)))
                                      "" separator)
                                  (car suffix))])
              (unless (equal? (kind-of first-child) 'missing)
                (error "document path cannot be safely resolved"))
              (let append-suffix ([resolved address] [remaining suffix])
                (if (null? remaining)
                    resolved
                    (append-suffix
                     (string-append resolved
                                    (if (and (> (string-length resolved) 0)
                                             (equal? (string-ref resolved (- (string-length resolved) 1))
                                                     (string-ref separator 0)))
                                        "" separator)
                                    (car remaining))
                     (cdr remaining))))))
        (let ([parent (groot-parent-path current separator)])
          (if (equal? parent current)
              (error "document path has no resolvable ancestor")
              (loop parent
                    (cons (groot-fs-basename current separator) suffix)))))))

(define (groot-fs-delete-entry/with-operations context documents canonicalize kind-of remove-file! remove-directory!)
  (define separator (path-separator))
  (define (symlink-document-conflict? context document address)
    (define basename (GrootFsDeleteContext-basename context))
    (let loop ([candidate document])
      (define parent (groot-parent-path candidate separator))
      (cond [(equal? candidate parent) #f]
            [(equal? basename (groot-fs-basename candidate separator))
             (or (equal? address
                         (groot-fs-join
                          (groot-fs-document-address parent canonicalize kind-of)
                          basename separator))
                 (loop parent))]
            [else (loop parent)])))
  (define (document-conflict? context documents address)
    (define source (GrootFsDeleteContext-source context))
    (define kind (GrootFsDeleteContext-kind context))
    (let loop ([remaining documents])
      (and (not (null? remaining))
           (let ([document (car remaining)])
             (if (not (string? document))
                 (loop (cdr remaining))
                 (or (if (equal? kind 'directory)
                         (groot-path-inside? source document separator)
                         (or (equal? source document)
                             (and (equal? kind 'symlink)
                                  (groot-path-inside? source document separator))))
                     (if (equal? kind 'symlink)
                         (symlink-document-conflict? context document address)
                         (let ([resolved-document
                                (groot-fs-document-address document canonicalize kind-of)])
                           (if (equal? kind 'directory)
                               (groot-path-inside? address resolved-document separator)
                               (equal? address resolved-document))))
                     (loop (cdr remaining))))))))
  (with-handler
   (lambda (failure) (GrootFsDeleteResult 'rejected (groot-fs-error-detail failure) #f #f))
   (let* ([root (GrootFsDeleteContext-root context)]
          [source (GrootFsDeleteContext-source context)]
          [basename (GrootFsDeleteContext-basename context)]
          [kind (GrootFsDeleteContext-kind context)])
     (unless (and (GrootFsDeleteContext? context) (list? documents)
                  (groot-fs-supported-delete-kind? kind)
                  (not (groot-fs-has-traversal? root separator))
                  (not (groot-fs-has-traversal? source separator))
                  (groot-fs-strictly-inside? root source separator)
                  (groot-fs-single-entry-name? basename separator)
                  (equal? basename (groot-fs-basename source separator)))
       (error "invalid deletion context"))
     (let* ([resolved-root (canonicalize root)]
            [resolved-parent (canonicalize (groot-parent-path source separator))]
            [address (groot-fs-join resolved-parent basename separator)])
       (unless (and (equal? resolved-root (GrootFsDeleteContext-canonical-root context))
                    (equal? resolved-parent (GrootFsDeleteContext-canonical-parent context)))
         (error "deletion root or parent changed"))
       (unless (and (groot-path-inside? resolved-root resolved-parent separator)
                    (groot-fs-strictly-inside? resolved-root address separator)
                    (equal? kind (kind-of address)))
         (error "deletion target changed, escaped root, or is unsupported"))
       (if (and (not (null? documents)) (document-conflict? context documents address))
           (error "deletion conflicts with an open document")
           (let ([native-failed? #f] [native-error #f])
             (with-handler
              (lambda (failure) (set! native-failed? #t) (set! native-error failure) #f)
              (if (or (equal? kind 'file) (equal? kind 'symlink))
                  (begin (remove-file! address) #t)
                  (begin (remove-directory! address) #t)))
             (if native-failed?
                 (GrootFsDeleteResult 'native-failure (groot-fs-error-detail native-error) #t address)
                 (GrootFsDeleteResult 'success #f #t address))))))))

(define (groot-fs-delete-entry context documents)
  (define separator (path-separator))
  (define (symlink-document-conflict? context document address)
    (define basename (GrootFsDeleteContext-basename context))
    (let loop ([candidate document])
      (define parent (groot-parent-path candidate separator))
      (cond [(equal? candidate parent) #f]
            [(equal? basename (groot-fs-basename candidate separator))
             (or (equal? address
                         (groot-fs-join
                          (groot-fs-document-address parent canonicalize-path groot-fs-live-entry-kind)
                          basename separator))
                 (loop parent))]
            [else (loop parent)])))
  (define (document-conflict? context documents address)
    (define source (GrootFsDeleteContext-source context))
    (define kind (GrootFsDeleteContext-kind context))
    (let loop ([remaining documents])
      (and (not (null? remaining))
           (let ([document (car remaining)])
             (if (not (string? document))
                 (loop (cdr remaining))
                 (or (if (equal? kind 'directory)
                         (groot-path-inside? source document separator)
                         (or (equal? source document)
                             (and (equal? kind 'symlink)
                                  (groot-path-inside? source document separator))))
                     (if (equal? kind 'symlink)
                         (symlink-document-conflict? context document address)
                         (let ([resolved-document
                                (groot-fs-document-address document canonicalize-path groot-fs-live-entry-kind)])
                           (if (equal? kind 'directory)
                               (groot-path-inside? address resolved-document separator)
                               (equal? address resolved-document))))
                     (loop (cdr remaining))))))))
  (with-handler
   (lambda (failure) (GrootFsDeleteResult 'rejected (groot-fs-error-detail failure) #f #f))
   (let* ([root (GrootFsDeleteContext-root context)]
          [source (GrootFsDeleteContext-source context)]
          [basename (GrootFsDeleteContext-basename context)]
          [kind (GrootFsDeleteContext-kind context)])
     (unless (and (GrootFsDeleteContext? context) (list? documents)
                  (groot-fs-supported-delete-kind? kind)
                  (not (groot-fs-has-traversal? root separator))
                  (not (groot-fs-has-traversal? source separator))
                  (groot-fs-strictly-inside? root source separator)
                  (groot-fs-single-entry-name? basename separator)
                  (equal? basename (groot-fs-basename source separator)))
       (error "invalid deletion context"))
     (let* ([resolved-root (canonicalize-path root)]
            [resolved-parent (canonicalize-path (groot-parent-path source separator))]
            [address (groot-fs-join resolved-parent basename separator)])
       (unless (and (equal? resolved-root (GrootFsDeleteContext-canonical-root context))
                    (equal? resolved-parent (GrootFsDeleteContext-canonical-parent context)))
         (error "deletion root or parent changed"))
       (unless (and (groot-path-inside? resolved-root resolved-parent separator)
                    (groot-fs-strictly-inside? resolved-root address separator)
                    (equal? kind (groot-fs-live-entry-kind address)))
         (error "deletion target changed, escaped root, or is unsupported"))
       (if (and (not (null? documents)) (document-conflict? context documents address))
           (error "deletion conflicts with an open document")
           (let ([native-failed? #f] [native-error #f])
             (with-handler
              (lambda (failure) (set! native-failed? #t) (set! native-error failure) #f)
              (if (or (equal? kind 'file) (equal? kind 'symlink))
                  (begin (delete-file! address) #t)
                  (begin (delete-directory! address) #t)))
             (if native-failed?
                 (GrootFsDeleteResult 'native-failure (groot-fs-error-detail native-error) #t address)
                 (GrootFsDeleteResult 'success #f #t address))))))))


;; Renames one captured regular file or directory to a validated sibling.
(define (groot-fs-rename-entry source submitted-name)
  (define separator (path-separator))
  (define source-kind (groot-fs-live-entry-kind source))
  (unless (or (equal? source-kind 'file) (equal? source-kind 'directory))
    (error "rename source is no longer a regular file or directory"))
  (unless (and (string? source) (groot-fs-single-entry-name? submitted-name separator))
    (error "expected a changed non-empty single-entry filename"))
  (define destination (groot-rename-destination source submitted-name separator))
  (when (equal? source destination) (error "expected a changed filename"))
  (when (groot-fs-destination-exists? destination) (error "rename destination already exists"))
  (rename-file-or-directory! source destination)
  destination)

;; A create context captures the selected lexical directory and its resolved
;; anchor before the native prompt can change focus.
(struct GrootFsCreateContext (destination canonical-destination) #:transparent)
(struct GrootFsCreateResult (outcome path detail mutation-started?) #:transparent)

(define (groot-fs-create-separator? character separator)
  (or (equal? character #\/)
      (and (equal? separator "\\") (equal? character #\\))))

(define (groot-fs-windows-trailing-name? component)
  (and (> (string-length component) 0)
       (let ([last (string-ref component (- (string-length component) 1))])
         (or (equal? last #\space) (equal? last #\.)))))

(define (groot-fs-windows-device-name? component)
  (define (ascii-downcase string)
    (list->string
     (map (lambda (character)
            (let ([code (char->integer character)])
              (if (and (>= code 65) (<= code 90))
                  (integer->char (+ code 32))
                  character)))
          (string->list string))))
  (define base
    (let loop ([index 0])
      (if (or (= index (string-length component))
              (equal? (string-ref component index) #\.))
          (substring component 0 index)
          (loop (+ index 1)))))
  (let ([name (ascii-downcase base)])
    (or (member name '("con" "prn" "aux" "nul"))
        (and (= (string-length name) 4)
             (or (equal? (substring name 0 3) "com")
                 (equal? (substring name 0 3) "lpt"))
             (let ([number (char->integer (string-ref name 3))])
               (or (and (>= number 49) (<= number 57))
                   (member number '(185 178 179))))))))

;; Returns validated components and whether one final separator requests a
;; directory.  Prompt syntax is intentionally separate from rename syntax.
(define (groot-fs-parse-create-path submitted separator)
  (unless (and (string? submitted) (> (string-length submitted) 0))
    (error "create path is empty"))
  (when (string-contains? submitted "\0") (error "create path contains NUL"))
  (define length (string-length submitted))
  (define leading? (groot-fs-create-separator? (string-ref submitted 0) separator))
  (define trailing? (groot-fs-create-separator? (string-ref submitted (- length 1)) separator))
  (define start (if leading? 1 0))
  (define end (if trailing? (- length 1) length))
  (when (>= start end) (error "create path is empty"))
  (let loop ([index start] [component ""] [components '()])
    (if (= index end)
        (let ([all (reverse (cons component components))])
          (for-each
           (lambda (part)
             (unless (and (> (string-length part) 0)
                          (not (equal? part "."))
                          (not (equal? part ".."))
                          (not (and (equal? separator "\\")
                                    (or (groot-fs-windows-trailing-name? part)
                                        (groot-fs-windows-device-name? part)
                                        (not (null? (filter (lambda (character)
                                                             (let ([code (char->integer character)])
                                                               (or (< code 32) (= code 127))))
                                                           (string->list part))))
                                        (string-contains? part ":")
                                        (string-contains? part "<")
                                        (string-contains? part ">")
                                        (string-contains? part "\"")
                                        (string-contains? part "|")
                                        (string-contains? part "?")
                                        (string-contains? part "*")))))
               (error "create path has an unsafe component")))
           all)
          (list all trailing?))
        (let ([character (string-ref submitted index)])
          (if (groot-fs-create-separator? character separator)
              (if (= (string-length component) 0)
                  (error "create path has repeated separators")
                  (loop (+ index 1) "" (cons component components)))
              (loop (+ index 1) (string-append component (string character)) components))))))

(define (groot-fs-capture-create-context destination)
  (unless (and (string? destination)
               (equal? (groot-fs-live-entry-kind destination) 'directory))
    (error "create destination is unavailable or not a directory"))
  (GrootFsCreateContext destination (canonicalize-path destination)))

;; Internal test seam: production uses the host separator via the wrapper
;; below, while parser tests can exercise Windows syntax on POSIX.
(define (groot-fs-create-entry/with-operations-and-mode context submitted canonicalize kind-of mkdir! create-file! separator)
  (define mutation-started? #f)
  (define native-started? #f)
  (define created-parent? #f)
  (define final-path #f)
  (define (failure outcome detail)
    (GrootFsCreateResult outcome final-path detail mutation-started?))
  (with-handler
   (lambda (error)
     (failure (cond [created-parent? 'partial-failure]
                    [native-started? 'native-failure]
                    [else 'rejected])
              (groot-fs-error-detail error)))
   (unless (GrootFsCreateContext? context) (error "invalid create context"))
   (define parsed (groot-fs-parse-create-path submitted separator))
   (define components (car parsed))
   (define directory? (cadr parsed))
   (define destination (GrootFsCreateContext-destination context))
   ;; Recheck both identity and live kind before any mutation.
   (unless (and (equal? (canonicalize destination)
                        (GrootFsCreateContext-canonical-destination context))
                (equal? (kind-of destination) 'directory))
     (error "create destination changed or is unavailable"))
   (let loop ([parent destination] [remaining components])
     (define name (car remaining))
     (define candidate (groot-fs-join parent name separator))
     (if (null? (cdr remaining))
         (begin
           (set! final-path candidate)
           (unless (equal? (kind-of candidate) 'missing)
             (error "create destination already exists"))
           (if directory?
               (begin
                 ;; ponytail: this is an observed-collision check only; use an
                 ;; exclusive mkdir binding if Steel exposes one.
                 (set! native-started? #t)
                 (mkdir! candidate)
                 (set! mutation-started? #t)
                 (unless (equal? (kind-of candidate) 'directory)
                   (error "created directory changed or is unsupported")))
               (begin (set! native-started? #t) (create-file! candidate) (set! mutation-started? #t)))
           (GrootFsCreateResult 'success final-path #f mutation-started?))
         (let ([kind (kind-of candidate)])
           (cond [(equal? kind 'directory) (loop candidate (cdr remaining))]
                 [(equal? kind 'missing)
                  (set! native-started? #t)
                  (mkdir! candidate)
                  (set! mutation-started? #t)
                  (set! created-parent? #t)
                  (unless (equal? (kind-of candidate) 'directory)
                    (error "created parent changed or is unsupported"))
                  (loop candidate (cdr remaining))]
                 [else (error "create path has a non-directory intermediate entry")]))))))

(define (groot-fs-create-entry/with-operations context submitted canonicalize kind-of mkdir! create-file!)
  (groot-fs-create-entry/with-operations-and-mode
   context submitted canonicalize kind-of mkdir! create-file! (path-separator)))

(define (groot-fs-create-native-canonicalize path) (canonicalize-path path))
(define (groot-fs-create-native-kind path) (groot-fs-live-entry-kind path))
(define (groot-fs-create-native-directory! path) (create-directory! path))
(define (groot-fs-create-native-file! path)
  (define port (open-output-file path #:exists 'error))
  (close-output-port port))

(define (groot-fs-create-entry context submitted)
  (groot-fs-create-entry/with-operations
   context submitted groot-fs-create-native-canonicalize groot-fs-create-native-kind
   groot-fs-create-native-directory! groot-fs-create-native-file!))

;; Reads one directory into cached entry records. Symlinks are leaves, never recursion targets.
;; Unlike the ordinary display reader below, this propagates listing errors for
;; deletion recovery, where an empty listing cannot establish root availability.
(define (groot-fs-read-directory/strict path)
  (let ([iterator (read-dir-iter path)])
    (let loop ([acc '()])
      (define raw (read-dir-iter-next! iterator))
      (if (not raw)
          (groot-sort-entries (reverse acc))
          (let* ([child-path (read-dir-entry-path raw)]
                 [name (read-dir-entry-file-name raw)]
                 [kind (groot-fs-directory-entry-kind raw)])
            ;; Steel reports non-UTF-8 paths as #false; omit them rather than
            ;; allowing one entry to make the whole sidebar unusable.
            (if (and (string? child-path) (string? name))
                (loop (cons (groot-entry child-path name kind) acc))
                (loop acc)))))))

;; Ordinary explorer rendering deliberately keeps its historical best-effort
;; behavior. Deletion recovery uses the strict reader instead.
(define (groot-fs-read-directory path)
  (with-handler (lambda (_) '()) (groot-fs-read-directory/strict path)))

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
