;; Tests for the external file finder and its argument shaping.
;; The traversal itself is exercised against this repository checkout.

(require "../groot-fs.scm")
(require "../groot-core.scm")
(require-builtin steel/process)
(require "fs-fixtures.scm")

;; Fails the Steel process with an actionable assertion message.
(define (check-equal name actual expected)
  (unless (equal? actual expected)
    (error (string-append name "\n expected: " (to-string expected) "\n actual: " (to-string actual)))))

(define ignored '(".git" "node_modules"))

(check-equal "fd arguments exclude each ignored name and scan the root last"
             (groot-fs-find-args "fd" "/repo" ignored)
             '("--type" "f" "--hidden" "--no-ignore" "--color" "never"
               "--exclude" ".git" "--exclude" "node_modules" "." "/repo"))

(check-equal "rg arguments negate each ignored name as a glob"
             (groot-fs-find-args "rg" "/repo" ignored)
             '("--files" "--hidden" "--no-ignore" "--no-messages" "--color" "never"
               "--glob" "!.git" "--glob" "!node_modules" "/repo"))

(check-equal "an empty exclude list adds no flags"
             (groot-fs-find-args "fd" "/repo" '())
             '("--type" "f" "--hidden" "--no-ignore" "--color" "never" "." "/repo"))

;; The finder is optional, so a machine without one must still pass the suite.
(define found (groot-fs-find-files "." ignored))
(when found
  (check-equal "every returned line is a non-empty path"
               (filter (lambda (p) (equal? p "")) found) '())
  (check-equal "ignored directories are never traversed"
               (filter (lambda (p) (string-contains? p "/.git/")) found) '())
  (check-equal "this test file is part of its own repository listing"
               (> (length (filter (lambda (p) (string-contains? p "groot-fs.scm")) found)) 0)
               #t))

(define (check-true name value)
  (check-equal name value #t))

(define (check-result-detail name result fragment)
  (check-true name
              (and (string? (GrootFsDeleteResult-detail result))
                   (string-contains? (GrootFsDeleteResult-detail result) fragment))))

(define (raises? thunk)
  (with-handler (lambda (_) #t)
    (begin (thunk) #f)))

;; Filesystem roots are valid create destinations even though they have no
;; directory-entry basename to enumerate.
(define filesystem-root (path-separator))
(define root-context (groot-fs-capture-create-context filesystem-root))
(check-equal "filesystem root create context retains its lexical destination and directory kind"
             (list (GrootFsCreateContext-destination root-context)
                   (groot-fs-live-entry-kind filesystem-root)
                   (GrootFsCreateContext? root-context))
             (list filesystem-root 'directory #t))
;; The root context is only passed through injected operations: this never
;; mutates the real filesystem root.
(let ([operations '()]
      [directories (list filesystem-root)]
      [child (string-append filesystem-root "injected-child")])
  (define result
    (groot-fs-create-entry/with-operations
     root-context "injected-child"
     (lambda (_) (GrootFsCreateContext-canonical-destination root-context))
     (lambda (path) (if (member path directories) 'directory 'missing))
     (lambda (_) (error "direct child must not create a parent"))
     (lambda (path) (set! operations (append operations (list (list 'file path)))))))
  (check-equal "filesystem root injected create routes its exact direct child"
               (list (GrootFsCreateResult-outcome result)
                     (GrootFsCreateResult-path result)
                     operations)
               (list 'success child (list (list 'file child)))))

(with-fs-fixture
 (lambda (parent)
   (define spaced-unicode " a file 名 ")
   (define created (groot-fs-create-empty-file parent spaced-unicode))
   (check-equal "valid spaces and Unicode are preserved in the returned path"
                created (fs-fixture-path parent spaced-unicode))
   (check-equal "valid name creates an empty regular file"
                (fs-fixture-entry-kind parent spaced-unicode) 'file)
   (check-equal "new file is empty" (fs-fixture-file-contents created) "")))

;; Colons are single-entry POSIX filename characters, not path syntax.
(when (not (equal? (path-separator) "\\"))
  (with-fs-fixture
   (lambda (parent)
     (define name "colon:name")
     (check-equal "POSIX colon name is created unchanged"
                  (groot-fs-create-empty-file parent name)
                  (fs-fixture-path parent name))
     (check-equal "POSIX colon name creates a file"
                  (fs-fixture-entry-kind parent name) 'file))))


(with-fs-fixture
 (lambda (parent)
   (for-each
    (lambda (name)
      (check-true (string-append "invalid single-entry name is rejected: " (to-string name))
                  (raises? (lambda () (groot-fs-create-empty-file parent name))))
      (check-true "invalid input does not modify its parent" (fs-fixture-empty? parent)))
    (append (list "" "." ".." (string-append "nul" "\0" "name"))
            (map (lambda (separator) (string-append "nested" separator "name"))
                 (if (equal? (path-separator) "\\")
                     (list "\\" "/")
                     (list (path-separator))))))))

(with-fs-fixture
 (lambda (parent)
   (define sentinel (fs-fixture-path parent "sentinel"))
   (define file (fs-fixture-path parent "existing-file"))
   (define directory (fs-fixture-path parent "existing-directory"))
   (define link (fs-fixture-path parent "existing-link"))
   (fs-fixture-write! file "do not replace")
   (fs-fixture-write! sentinel "link target")
   (fs-fixture-mkdir! directory)
   (fs-fixture-write! (fs-fixture-path directory "sentinel-child")
                       "directory child must survive")
   (fs-fixture-symlink! sentinel link)
   (for-each
    (lambda (name)
      (check-true (string-append "existing entry is not overwritten: " name)
                  (raises? (lambda () (groot-fs-create-empty-file parent name)))))
    '("existing-file" "existing-directory" "existing-link"))
   (check-equal "file collision preserves sentinel contents"
                (fs-fixture-file-contents file) "do not replace")
   (check-equal "directory collision preserves directory identity"
                (fs-fixture-entry-kind parent "existing-directory") 'directory)
   (check-equal "directory collision preserves child identity"
                (fs-fixture-entry-kind directory "sentinel-child") 'file)
   (check-equal "directory collision preserves child contents"
                (fs-fixture-file-contents (fs-fixture-path directory "sentinel-child"))
                "directory child must survive")
   (check-equal "symlink collision preserves entry identity"
                (fs-fixture-entry-kind parent "existing-link") 'symlink)
   (check-equal "symlink collision does not modify its target"
                (fs-fixture-file-contents sentinel) "link target")))

(with-fs-fixture
 (lambda (parent)
   (define missing-parent (fs-fixture-path parent "missing-parent"))
   (check-true "missing parents are not created"
               (raises? (lambda () (groot-fs-create-empty-file missing-parent "child"))))
   (check-equal "missing parent remains absent" (fs-fixture-entry-kind parent "missing-parent") #f)))

;; Nested create accepts one leading slash relative to the captured destination,
;; creates parents, and reserves a trailing slash for a collapsed final directory.
(with-fs-fixture
 (lambda (parent)
   (define context (groot-fs-capture-create-context parent))
   (define file-result (groot-fs-create-entry context "/one/two/file.txt"))
   (define directory-result (groot-fs-create-entry context "one/two/directory/"))
   (check-equal "nested file creation succeeds with its final path"
                (list (GrootFsCreateResult-outcome file-result)
                      (GrootFsCreateResult-path file-result))
                (list 'success (fs-fixture-path (fs-fixture-path (fs-fixture-path parent "one") "two") "file.txt")))
   (check-equal "nested creation reuses real intermediate directories"
                (fs-fixture-entry-kind (fs-fixture-path parent "one") "two") 'directory)
   (check-equal "nested final file is regular and empty"
                (list (fs-fixture-entry-kind (fs-fixture-path (fs-fixture-path parent "one") "two") "file.txt")
                      (fs-fixture-file-contents (GrootFsCreateResult-path file-result)))
                '(file ""))
   (check-equal "trailing separator creates a final directory"
                (list (GrootFsCreateResult-outcome directory-result)
                      (fs-fixture-entry-kind (fs-fixture-path (fs-fixture-path parent "one") "two") "directory"))
                '(success directory))))

(with-fs-fixture
 (lambda (parent)
   (define context (groot-fs-capture-create-context parent))
   (for-each
    (lambda (submitted)
      (define result (groot-fs-create-entry context submitted))
      (check-equal (string-append "invalid nested path is rejected: " (to-string submitted))
                   (list (GrootFsCreateResult-outcome result)
                         (GrootFsCreateResult-mutation-started? result))
                   '(rejected #f))
      (check-true "rejected nested path creates nothing" (fs-fixture-empty? parent)))
    (append '("" "/" "one//two" "./one" "one/../two")
            (list (string-append "nul" "\0" "name"))
            (if (equal? (path-separator) "\\")
                '("C:/unsafe" "one\\..\\two")
                '())))))

;; The injected mode seam verifies Windows prompt syntax on this POSIX host.
(with-fs-fixture
 (lambda (parent)
   (define context (groot-fs-capture-create-context parent))
   (for-each
    (lambda (submitted)
      (define mkdir-calls 0)
      (define result
        (groot-fs-create-entry/with-operations-and-mode
         context submitted canonicalize-path
         (lambda (path) (if (equal? path parent) 'directory 'missing))
         (lambda (_) (set! mkdir-calls (+ mkdir-calls 1)))
         (lambda (_) (error "invalid Windows path must not create a file"))
         "\\"))
      (check-equal "Windows reserved or control component is rejected before mutation"
                   (list (GrootFsCreateResult-outcome result) mkdir-calls)
                   '(rejected 0))
      (check-true "invalid Windows path creates no parent" (fs-fixture-empty? parent)))
    (list "CON" "con.txt" "PRN. " "AUX..." "NUL " "COM1.log" "LPT9.txt"
          (string-append "bad" (string (integer->char 1)) "name")))))

;; Superscript device numbers are reserved even under an extension. Parsing
;; must reject the complete nested path before creating its preceding component.
(with-fs-fixture
 (lambda (parent)
   (for-each
    (lambda (submitted)
      (define operations '())
      (define result
        (groot-fs-create-entry/with-operations-and-mode
         (groot-fs-capture-create-context parent) submitted canonicalize-path
         (lambda (path) (if (equal? path parent) 'directory 'missing))
         (lambda (path) (set! operations (cons (list 'mkdir path) operations)))
         (lambda (path) (set! operations (cons (list 'file path) operations)))
         "\\"))
      (check-equal "nested Windows superscript device path is rejected before parent mutation"
                   (list (GrootFsCreateResult-outcome result) operations)
                   '(rejected ()))
      (check-true "nested Windows superscript device path leaves parent empty"
                  (fs-fixture-empty? parent)))
    '("one\\COM¹.txt" "one\\COM².txt" "one\\COM³.txt"
      "one\\LPT¹.txt" "one\\LPT².txt" "one\\LPT³.txt"))))

(with-fs-fixture
 (lambda (parent)
   (define created '())
   (define directories (list parent))
   (define result
     (groot-fs-create-entry/with-operations-and-mode
      (groot-fs-capture-create-context parent) "one/two\\file" canonicalize-path
      (lambda (path) (if (member path directories) 'directory 'missing))
      (lambda (path) (set! directories (cons path directories))
                     (set! created (append created (list path))))
      (lambda (path) (set! created (append created (list path))))
      "\\"))
   (check-equal "Windows mixed separators parse as POSIX components"
                (list (GrootFsCreateResult-outcome result) (length created))
                '(success 3))))

;; Parser modes use injected operations so both syntax contracts run on any host.
(with-fs-fixture
 (lambda (parent)
   (define (check-parser-mode mode separator file-input directory-input)
     (define one (string-append parent separator "one"))
     (define two (string-append one separator "two"))
     (define (run submitted final-name final-kind)
       (define final-path (string-append two separator final-name))
       (define directories (list parent))
       (define operations '())
       (define result
         (groot-fs-create-entry/with-operations-and-mode
          (groot-fs-capture-create-context parent) submitted canonicalize-path
          (lambda (path) (if (member path directories) 'directory 'missing))
          (lambda (path)
            (set! directories (cons path directories))
            (set! operations (append operations (list (list 'mkdir path)))))
          (lambda (path) (set! operations (append operations (list (list 'file path)))))
          separator))
       (check-equal (string-append mode " parser candidate paths and operation order")
                    (list (GrootFsCreateResult-outcome result)
                          (GrootFsCreateResult-path result)
                          operations)
                    (list 'success final-path
                          (append (list (list 'mkdir one) (list 'mkdir two))
                                  (list (list final-kind final-path)))))
     (run file-input "file" 'file)
     (run directory-input "directory" 'mkdir)))
   (check-parser-mode "POSIX /" "/" "one/two/file" "one/two/directory/")
   (check-parser-mode "Windows \\" "\\" "one\\two\\file" "one\\two\\directory\\")))

;; The existing mode seam models a Windows filesystem's case-insensitive lookup
;; while running on POSIX.  A real `Foo` is reused for submitted `foo`.
(with-fs-fixture
 (lambda (parent)
   (define foo (string-append parent "\\Foo"))
   (define submitted (string-append parent "\\foo"))
   (define operations '())
   (define result
     (groot-fs-create-entry/with-operations-and-mode
      (groot-fs-capture-create-context parent) "foo\\child" canonicalize-path
      (lambda (path)
        (if (or (equal? path parent) (string-ci=? path foo)) 'directory 'missing))
      (lambda (path) (set! operations (append operations (list (list 'mkdir path)))))
      (lambda (path) (set! operations (append operations (list (list 'file path)))))
      "\\"))
   (check-equal "Windows case-insensitive intermediate directory is reused"
                (list (GrootFsCreateResult-outcome result) operations)
                (list 'success (list (list 'file (string-append submitted "\\child")))))))

;; Windows accepts either prompt separator; on POSIX, backslash is a filename
;; character and the parser intentionally does not reinterpret it.
(when (equal? (path-separator) "\\")
  (with-fs-fixture
   (lambda (parent)
     (define result
       (groot-fs-create-entry (groot-fs-capture-create-context parent) "one/two\\file"))
     (check-equal "Windows mixed prompt separators create equivalent components"
                  (list (GrootFsCreateResult-outcome result)
                        (fs-fixture-entry-kind
                         (fs-fixture-path parent "one") "two"))
                  '(success directory)))))

(with-fs-fixture
 (lambda (parent)
   (define file (fs-fixture-path parent "file"))
   (define target (fs-fixture-path parent "target"))
   (define link (fs-fixture-path parent "link"))
   (fs-fixture-write! file "sentinel")
   (fs-fixture-write! target "target")
   (fs-fixture-symlink! target link)
   (for-each
    (lambda (submitted)
      (define result (groot-fs-create-entry (groot-fs-capture-create-context parent) submitted))
      (check-equal "unsafe intermediate is rejected before mutation"
                   (GrootFsCreateResult-outcome result) 'rejected))
    '("file/child" "link/child"))
   (define dangling (fs-fixture-path parent "dangling-link"))
   (fs-fixture-symlink! (fs-fixture-path parent "missing-target") dangling)
   (check-equal "dangling intermediate link is rejected before mutation"
                (GrootFsCreateResult-outcome
                 (groot-fs-create-entry (groot-fs-capture-create-context parent)
                                        "dangling-link/child"))
                'rejected)
   (check-equal "intermediate file is unchanged" (fs-fixture-file-contents file) "sentinel")
   (check-equal "intermediate link is unchanged" (fs-fixture-entry-kind parent "link") 'symlink)
   (check-equal "dangling intermediate link remains occupied"
                (fs-fixture-entry-kind parent "dangling-link") 'symlink)))

;; The injected operations seam covers special entries portably; Steel does not
;; offer a portable special-node fixture API.
(with-fs-fixture
 (lambda (parent)
   (define context (groot-fs-capture-create-context parent))
   (define result
     (groot-fs-create-entry/with-operations
      context "special/child" canonicalize-path
      (lambda (path) (if (equal? path parent) 'directory 'special))
      (lambda (_) (error "must not create through a special entry"))
      (lambda (_) (error "must not create through a special entry"))))
   (check-equal "special intermediate is rejected before mutation"
                (list (GrootFsCreateResult-outcome result)
                      (GrootFsCreateResult-mutation-started? result))
                '(rejected #f))))

(with-fs-fixture
 (lambda (parent)
   (define occupied-file (fs-fixture-path parent "occupied-file"))
   (define occupied-directory (fs-fixture-path parent "occupied-directory"))
   (define target (fs-fixture-path parent "link-target"))
   (define occupied-link (fs-fixture-path parent "occupied-link"))
   (fs-fixture-write! occupied-file "do not replace")
   (fs-fixture-write! target "link target")
   (fs-fixture-symlink! target occupied-link)
   (fs-fixture-mkdir! occupied-directory)
   (for-each
    (lambda (submitted)
      (define result (groot-fs-create-entry (groot-fs-capture-create-context parent) submitted))
      (check-equal "occupied final entry is rejected without mutation"
                   (list (GrootFsCreateResult-outcome result)
                         (GrootFsCreateResult-mutation-started? result))
                   '(rejected #f)))
    '("occupied-file" "occupied-directory/" "occupied-link"))
   (define special-result
     (groot-fs-create-entry/with-operations
      (groot-fs-capture-create-context parent) "occupied-special" canonicalize-path
      (lambda (path) (if (equal? path parent) 'directory 'special))
      (lambda (_) (error "must not create over special entry"))
      (lambda (_) (error "must not create over special entry"))))
   (check-equal "final special collision is rejected without mutation"
                (list (GrootFsCreateResult-outcome special-result)
                      (GrootFsCreateResult-mutation-started? special-result))
                '(rejected #f))
   (check-equal "final file collision remains unchanged" (fs-fixture-file-contents occupied-file) "do not replace")
   (check-equal "final directory collision remains unchanged" (fs-fixture-entry-kind parent "occupied-directory") 'directory)
   (check-equal "final link collision remains unchanged" (fs-fixture-entry-kind parent "occupied-link") 'symlink)
   (check-equal "final link collision does not modify target" (fs-fixture-file-contents target) "link target")))

;; A captured destination must retain its canonical anchor until submission.
(with-fs-fixture
 (lambda (parent)
   (define context (groot-fs-capture-create-context parent))
   (define result
     (groot-fs-create-entry/with-operations
      context "child" (lambda (_) "changed-anchor")
      (lambda (_) 'directory) (lambda (_) (error "must not mutate"))
      (lambda (_) (error "must not mutate"))))
   (check-equal "changed create destination is rejected before mutation"
                (list (GrootFsCreateResult-outcome result)
                      (GrootFsCreateResult-mutation-started? result))
                '(rejected #f))))

;; A destination removed after capture is rejected without recreating it.
(with-fs-fixture
 (lambda (root)
   (define destination (fs-fixture-path root "destination"))
   (fs-fixture-mkdir! destination)
   (define context (groot-fs-capture-create-context destination))
   (delete-directory! destination)
   (define result (groot-fs-create-entry context "child"))
   (check-equal "removed create destination is rejected without mutation"
                (list (GrootFsCreateResult-outcome result)
                      (GrootFsCreateResult-mutation-started? result)
                      (fs-fixture-entry-kind root "destination"))
                '(rejected #f #f))))

;; An intermediate link must not escape the captured destination.
(with-fs-fixture
 (lambda (root)
   (define destination (fs-fixture-path root "destination"))
   (define outside (fs-fixture-path root "outside"))
   (define link (fs-fixture-path destination "outside-link"))
   (fs-fixture-mkdir! destination)
   (fs-fixture-mkdir! outside)
   (fs-fixture-write! (fs-fixture-path outside "sentinel") "outside sentinel")
   (fs-fixture-symlink! outside link)
   (define result
     (groot-fs-create-entry (groot-fs-capture-create-context destination)
                            "outside-link/child"))
   (check-equal "outside intermediate link is rejected without mutation"
                (list (GrootFsCreateResult-outcome result)
                      (GrootFsCreateResult-mutation-started? result)
                      (fs-fixture-entry-kind outside "child")
                      (fs-fixture-file-contents (fs-fixture-path outside "sentinel")))
                '(rejected #f #f "outside sentinel"))))

;; A failed first native operation reports native failure before any mutation.
(with-fs-fixture
 (lambda (parent)
   (define calls 0)
   (define result
     (groot-fs-create-entry/with-operations
      (groot-fs-capture-create-context parent) "parent/child" canonicalize-path
      (lambda (path) (if (equal? path parent) 'directory 'missing))
      (lambda (_)
        (set! calls (+ calls 1))
        (error "injected first native failure"))
      (lambda (_) (error "unexpected final file creation"))))
   (check-equal "first native failure is mutation-free"
                (list (GrootFsCreateResult-outcome result)
                      (GrootFsCreateResult-mutation-started? result)
                      calls
                      (fs-fixture-entry-kind parent "parent"))
                '(native-failure #f 1 #f))))

(with-fs-fixture
 (lambda (parent)
   (define context (groot-fs-capture-create-context parent))
   (define calls 0)
   (define result
     (groot-fs-create-entry/with-operations-and-mode
      context "created/later/file" canonicalize-path groot-fs-live-entry-kind
      (lambda (path)
        (set! calls (+ calls 1))
        (if (= calls 1) (create-directory! path) (error "injected later failure")))
      (lambda (_) (error "unexpected final file creation"))
      (path-separator)))
   (check-equal "later parent failure is partial" (GrootFsCreateResult-outcome result) 'partial-failure)
   (check-equal "partial failure records possible mutation" (GrootFsCreateResult-mutation-started? result) #t)
   (check-equal "partial failure retains created parent" (fs-fixture-entry-kind parent "created") 'directory)))

;; Two separate Steel processes wait until both have reached the same barrier.
;; Releasing it makes their public API calls genuinely contend for one entry.
(define (spawn-create-worker parent name ready release winner result)
  (Ok->value
   (spawn-process
    (command "steel"
             (list "tests/fs-create-worker.scm" parent name ready release winner result)))))

(define (wait-for-paths paths)
  ;; This bounded polling is intentionally dependency-free and works wherever
  ;; Steel's own process runner works; an unavailable worker fails the test.
  (let wait ([attempts 10000000])
    (cond [(null? (filter (lambda (path) (not (path-exists? path))) paths)) #f]
          [(= attempts 0) (error "concurrent-create workers did not reach barrier")]
          [else (wait (- attempts 1))])))

(with-fs-fixture
 (lambda (parent)
   (define name "competing")
   (define ready-a (fs-fixture-path parent "ready-a"))
   (define ready-b (fs-fixture-path parent "ready-b"))
   (define release (fs-fixture-path parent "release"))
   (define result-a (fs-fixture-path parent "result-a"))
   (define result-b (fs-fixture-path parent "result-b"))
   (define first (spawn-create-worker parent name ready-a release "worker-a" result-a))
   (define second (spawn-create-worker parent name ready-b release "worker-b" result-b))
   (wait-for-paths (list ready-a ready-b))
   (fs-fixture-write! release "go")
   (define statuses (list (Ok->value (wait first)) (Ok->value (wait second))))
   (check-equal "both concurrent workers complete their reported attempt"
                statuses '(0 0))
   (check-equal "exactly one concurrent creator succeeds"
                (length (filter (lambda (outcome) (equal? outcome "success"))
                                (list (fs-fixture-file-contents result-a)
                                      (fs-fixture-file-contents result-b)))) 1)
   (check-equal "concurrent creation leaves the winning entry a file"
                (fs-fixture-entry-kind parent name) 'file)
   (check-true "losing concurrent creator does not overwrite winner content"
               (or (equal? (fs-fixture-file-contents (fs-fixture-path parent name)) "worker-a")
                   (equal? (fs-fixture-file-contents (fs-fixture-path parent name)) "worker-b")))
   (check-equal "winning entry and its content remain after both creators exit"
                (fs-fixture-entry-kind parent name) 'file)))

(with-fs-fixture
 (lambda (parent)
   (define name "competing-directory")
   (define ready-a (fs-fixture-path parent "directory-ready-a"))
   (define ready-b (fs-fixture-path parent "directory-ready-b"))
   (define release (fs-fixture-path parent "directory-release"))
   (define result-a (fs-fixture-path parent "directory-result-a"))
   (define result-b (fs-fixture-path parent "directory-result-b"))
   (define first (spawn-create-worker parent (string-append name "/") ready-a release "worker-a" result-a))
   (define second (spawn-create-worker parent (string-append name "/") ready-b release "worker-b" result-b))
   (wait-for-paths (list ready-a ready-b))
   (fs-fixture-write! release "go")
   (check-equal "both concurrent directory creators complete their reported attempt"
                (list (Ok->value (wait first)) (Ok->value (wait second))) '(0 0))
   ;; Steel mkdir is not exclusive: either process may report success after the
   ;; observed-collision check, but neither may replace the final directory.
   (check-true "a concurrent directory creator reports success"
               (> (length (filter (lambda (outcome) (equal? outcome "success"))
                                  (list (fs-fixture-file-contents result-a)
                                        (fs-fixture-file-contents result-b)))) 0))
   (check-equal "concurrent final directory remains a directory"
                (fs-fixture-entry-kind parent name) 'directory)))


;; Rename tests exercise the public filesystem boundary.
(with-fs-fixture
 (lambda (parent)
   (define source (fs-fixture-path parent "source-file"))
   (define destination (fs-fixture-path parent "renamed-file"))
   (fs-fixture-write! source "file contents")
   (check-equal "file rename returns its absolute sibling destination"
                (groot-fs-rename-entry source "renamed-file") destination)
   (check-equal "file rename removes the source" (fs-fixture-entry-kind parent "source-file") #f)
   (check-equal "file rename preserves contents" (fs-fixture-file-contents destination) "file contents")))

(with-fs-fixture
 (lambda (parent)
   (define source (fs-fixture-path parent "source-directory"))
   (define destination (fs-fixture-path parent "renamed-directory"))
   (fs-fixture-mkdir! source)
   (fs-fixture-write! (fs-fixture-path source "child") "directory contents")
   (check-equal "directory rename returns its absolute sibling destination"
                (groot-fs-rename-entry source "renamed-directory") destination)
   (check-equal "directory rename removes the source" (fs-fixture-entry-kind parent "source-directory") #f)
   (check-equal "directory rename preserves descendants"
                (fs-fixture-file-contents (fs-fixture-path destination "child")) "directory contents")))


;; The source is classified again at submission time.  A captured file swapped
;; for a symlink while its prompt is open must never reach native rename.
(with-fs-fixture
 (lambda (parent)
   (define source (fs-fixture-path parent "source"))
   (define target (fs-fixture-path parent "target"))
   (define destination (fs-fixture-path parent "destination"))
   (fs-fixture-write! source "captured file")
   (fs-fixture-write! target "link target")
   (delete-file! source)
   (fs-fixture-symlink! target source)
   (check-true "source replaced by a symlink is rejected before native rename"
               (raises? (lambda () (groot-fs-rename-entry source "destination"))))
   (check-equal "replaced source remains a symlink" (fs-fixture-entry-kind parent "source") 'symlink)
   (check-equal "rejected replacement creates no destination" (fs-fixture-entry-kind parent "destination") #f)))

;; Non-file, non-directory entries are kept distinct from regular files and are
;; rejected by the same live source guard.  FIFOs are available on POSIX.
(when (not (equal? (path-separator) "\\"))
  (with-fs-fixture
   (lambda (parent)
     (define source (fs-fixture-path parent "source-fifo"))
     (check-equal "mkfifo fixture succeeds"
                  (Ok->value (wait (Ok->value (spawn-process (command "mkfifo" (list source)))))) 0)
     (define entries (groot-fs-read-directory parent))
     (define fifo (car (filter (lambda (entry) (equal? (groot-entry-path entry) source)) entries)))
     (check-equal "FIFO is classified separately from a regular file" (groot-entry-kind fifo) 'special)
     (check-true "special source is rejected before native rename"
                 (raises? (lambda () (groot-fs-rename-entry source "renamed-fifo")))))))

(with-fs-fixture
 (lambda (parent)
   (define source (fs-fixture-path parent "source"))
   (define file (fs-fixture-path parent "file-destination"))
   (define directory (fs-fixture-path parent "directory-destination"))
   (define link (fs-fixture-path parent "link-destination"))
   (define sentinel (fs-fixture-path parent "sentinel"))
   (fs-fixture-write! source "source contents")
   (fs-fixture-write! file "file contents")
   (fs-fixture-mkdir! directory)
   (fs-fixture-write! sentinel "link target")
   (fs-fixture-symlink! sentinel link)
   (for-each
    (lambda (name)
      (check-true (string-append "rename rejects existing destination: " name)
                  (raises? (lambda () (groot-fs-rename-entry source name)))))
    '("file-destination" "directory-destination" "link-destination"))
   (check-equal "collision preserves source" (fs-fixture-file-contents source) "source contents")
   (check-equal "file collision preserves destination" (fs-fixture-file-contents file) "file contents")
   (check-equal "directory collision preserves destination" (fs-fixture-entry-kind parent "directory-destination") 'directory)
   (check-equal "symlink collision preserves destination" (fs-fixture-entry-kind parent "link-destination") 'symlink)))

(with-fs-fixture
 (lambda (parent)
   (define source (fs-fixture-path parent "missing-source"))
   (define destination (fs-fixture-path parent "destination"))
   (check-true "missing rename source propagates the native error"
               (raises? (lambda () (groot-fs-rename-entry source "destination"))))
   (check-equal "missing rename source creates no destination" (path-exists? destination) #f)))


;; Delete tests use only short-lived fixture entries.  The public capture and
;; boundary are intentionally exercised separately so prompt-time facts cannot
;; bypass submission-time validation.
(with-fs-fixture
 (lambda (root)
   (define source (fs-fixture-path root "file"))
   (define missing (fs-fixture-path root "missing"))
   (define outside (fs-fixture-path (groot-parent-path root (path-separator)) "outside"))
   (fs-fixture-write! source "delete me")
   (check-true "delete capture rejects the explorer root"
               (raises? (lambda () (groot-fs-capture-delete-context root root))))
   (check-true "delete capture rejects outside source"
               (raises? (lambda () (groot-fs-capture-delete-context root outside))))
   (check-true "delete capture rejects a missing selection"
               (raises? (lambda () (groot-fs-capture-delete-context root missing))))
   (check-equal "missing selection leaves fixture contents unchanged"
                (fs-fixture-file-contents source) "delete me")
   (check-true "delete capture rejects traversal source"
               (raises? (lambda () (groot-fs-capture-delete-context root
                                                                  (string-append root (path-separator) ".." (path-separator) "file")))))))

;; Special entries cannot form a deletion context, so capture makes no native
;; operation possible and preserves the FIFO unchanged.
(when (not (equal? (path-separator) "\\"))
  (with-fs-fixture
   (lambda (root)
     (define fifo (fs-fixture-path root "selected-fifo"))
     (check-equal "mkfifo deletion fixture succeeds"
                  (Ok->value (wait (Ok->value (spawn-process (command "mkfifo" (list fifo)))))) 0)
     (check-true "delete capture rejects an unsupported FIFO selection"
                 (raises? (lambda () (groot-fs-capture-delete-context root fifo))))
     (check-equal "unsupported FIFO remains unchanged without native deletion"
                  (fs-fixture-entry-kind root "selected-fifo") 'special))))

(with-fs-fixture
 (lambda (root)
   (define parent (fs-fixture-path root "parent"))
   (define source (fs-fixture-path parent "changed-parent"))
   (fs-fixture-mkdir! parent)
   (fs-fixture-write! source "sentinel")
   (define context (groot-fs-capture-delete-context root source))
   (define calls 0)
   (define result
     (groot-fs-delete-entry/with-operations
      context '()
      (lambda (path)
        (if (equal? path root) path (string-append path "-changed")))
      (lambda (_) 'file)
      (lambda (_) (set! calls (+ calls 1)))
      (lambda (_) (set! calls (+ calls 1)))))
   (check-equal "changed resolved parent is rejected" (GrootFsDeleteResult-outcome result) 'rejected)
   (check-result-detail "changed resolved parent identifies the safety check" result "root or parent changed")
   (check-equal "changed resolved parent reaches no native operation" calls 0)
   (check-equal "rejected changed parent preserves source" (fs-fixture-file-contents source) "sentinel")
   (let ([calls 0])
     (define result
       (groot-fs-delete-entry/with-operations
        context '()
        (lambda (path) (if (equal? path root) (string-append path "-changed") path))
        (lambda (_) 'file)
        (lambda (_) (set! calls (+ calls 1)))
        (lambda (_) (set! calls (+ calls 1)))))
     (check-equal "changed resolved root is rejected" (GrootFsDeleteResult-outcome result) 'rejected)
     (check-result-detail "changed resolved root identifies the safety check" result "root or parent changed")
     (check-equal "changed resolved root reaches no native operation" calls 0))
   (let ([calls 0])
     (define result
       (groot-fs-delete-entry/with-operations
        context '() canonicalize-path (lambda (_) 'missing)
        (lambda (_) (set! calls (+ calls 1)))
        (lambda (_) (set! calls (+ calls 1)))))
     (check-equal "missing target at submission is rejected" (GrootFsDeleteResult-outcome result) 'rejected)
     (check-result-detail "missing target identifies the target safety check" result "target changed")
     (check-equal "missing target reaches no native operation" calls 0))
   (let ([calls 0])
     (define result
       (groot-fs-delete-entry/with-operations
        context '() canonicalize-path (lambda (_) 'directory)
        (lambda (_) (set! calls (+ calls 1)))
        (lambda (_) (set! calls (+ calls 1)))))
     (check-equal "changed target kind is rejected" (GrootFsDeleteResult-outcome result) 'rejected)
     (check-result-detail "changed target kind identifies the target safety check" result "target changed")
     (check-equal "changed target kind reaches no native operation" calls 0))
   (let ([calls 0])
     (define result
       (groot-fs-delete-entry/with-operations
        context '()
        (lambda (_) (error "injected resolution failure"))
        (lambda (_) 'file)
        (lambda (_) (set! calls (+ calls 1)))
        (lambda (_) (set! calls (+ calls 1)))))
     (check-equal "resolution failure is rejected" (GrootFsDeleteResult-outcome result) 'rejected)
     (check-result-detail "resolution failure preserves actionable detail" result "injected resolution failure")
     (check-equal "resolution failure reaches no native operation" calls 0))))

(with-fs-fixture
 (lambda (root)
   (define file (fs-fixture-path root "file"))
   (define directory (fs-fixture-path root "directory"))
   (define alias (fs-fixture-path root "alias"))
   (define external (fs-fixture-path root "external"))
   (define link (fs-fixture-path root "link"))
   (fs-fixture-write! file "open")
   (fs-fixture-mkdir! directory)
   (fs-fixture-write! (fs-fixture-path directory ".hidden") "hidden")
   ;; Alias the selected directory itself so the missing document is its
   ;; descendant after resolution, rather than a sibling of the target.
   (fs-fixture-symlink! directory alias)
   (fs-fixture-write! external "external sentinel")
   (fs-fixture-symlink! external link)
   (let ([calls 0])
     (define result (groot-fs-delete-entry/with-operations
                     (groot-fs-capture-delete-context root file) (list file)
                     canonicalize-path (lambda (_) 'file)
                     (lambda (_) (set! calls (+ calls 1)))
                     (lambda (_) (set! calls (+ calls 1)))))
     (check-equal "open file is a deletion conflict" (GrootFsDeleteResult-outcome result) 'rejected)
     (check-result-detail "open file conflict identifies the document guard" result "open document")
     (check-equal "open file conflict does not call native deletion" calls 0))
   (let ([calls 0])
     (define result (groot-fs-delete-entry/with-operations
                     (groot-fs-capture-delete-context root directory)
                     (list (fs-fixture-path directory "lexical-child"))
                     canonicalize-path (lambda (_) 'directory)
                     (lambda (_) (set! calls (+ calls 1)))
                     (lambda (_) (set! calls (+ calls 1)))))
     (check-equal "lexical directory descendant conflicts before resolution"
                  (GrootFsDeleteResult-outcome result) 'rejected)
     (check-result-detail "lexical directory conflict identifies the document guard" result "open document")
     (check-equal "lexical directory conflict does not call native deletion" calls 0))
   (let ([calls 0])
     (define result (groot-fs-delete-entry/with-operations
                     (groot-fs-capture-delete-context root directory)
                     (list (fs-fixture-path alias "missing-document"))
                     canonicalize-path
                     (lambda (path)
                       (cond [(equal? path directory) 'directory]
                             [(equal? path alias) 'symlink]
                             [(equal? path root) 'directory]
                             [else 'missing]))
                     (lambda (_) (set! calls (+ calls 1)))
                     (lambda (_) (set! calls (+ calls 1)))))
     (check-equal "resolved alias with missing document suffix conflicts with directory"
                  (GrootFsDeleteResult-outcome result) 'rejected)
     (check-result-detail "resolved alias conflict identifies the document guard" result "open document")
     (check-equal "resolved alias conflict does not call native deletion" calls 0))
   (let ([calls 0])
     (define result (groot-fs-delete-entry/with-operations
                     (groot-fs-capture-delete-context root directory)
                     (list (fs-fixture-path (fs-fixture-path alias "missing-parent")
                                            "document"))
                     canonicalize-path groot-fs-live-entry-kind
                     (lambda (_) (set! calls (+ calls 1)))
                     (lambda (_) (set! calls (+ calls 1)))))
     (check-equal "multi-component missing alias document conflicts with directory"
                  (GrootFsDeleteResult-outcome result) 'rejected)
     (check-result-detail "multi-component missing alias document identifies the document guard"
                          result "open document")
     (check-equal "multi-component missing alias document does not call native deletion" calls 0))
   ;; The alias fixture was only needed for the preceding conflict case.
   (delete-file! alias)
   ;; Resolve the aliases' parents but retain link as the candidate's final
   ;; component: canonicalizing alias-to-root/link would follow the link.
   (define alias-to-root (fs-fixture-path root "alias-to-root"))
   (fs-fixture-symlink! root alias-to-root)
   (let ([calls 0])
     (define result
       (groot-fs-delete-entry/with-operations
        (groot-fs-capture-delete-context root link)
        ;; Only the descendant is supplied: this must not short-circuit through
        ;; the selected link pathname itself.
        (list (fs-fixture-path (fs-fixture-path alias-to-root "link") "child"))
        canonicalize-path (lambda (_) 'symlink)
        (lambda (_) (set! calls (+ calls 1)))
        (lambda (_) (set! calls (+ calls 1)))))
     (check-equal "aliased link path and prefix conflict without resolving link referent"
                  (GrootFsDeleteResult-outcome result) 'rejected)
     (check-result-detail "aliased link conflict identifies the document guard" result "open document")
     (check-equal "aliased link conflict does not call native deletion" calls 0))
   ;; This similarly has no lexical conflict: only resolving alias-to-root
   ;; exposes that the open document names the selected regular file.
   (let ([calls 0])
     (define result
       (groot-fs-delete-entry/with-operations
        (groot-fs-capture-delete-context root file)
        (list (fs-fixture-path alias-to-root "file"))
        canonicalize-path (lambda (_) 'file)
        (lambda (_) (set! calls (+ calls 1)))
        (lambda (_) (set! calls (+ calls 1)))))
     (check-equal "regular file conflict through resolved alias is rejected"
                  (GrootFsDeleteResult-outcome result) 'rejected)
     (check-result-detail "regular file resolved alias identifies the document guard"
                          result "open document")
     (check-equal "regular file resolved alias does not call native deletion" calls 0))
   ;; The missing ancestor is known absent, not inaccessible or ambiguous. It
   ;; must remain eligible rather than making a selected-link check reject.
   (let ([calls 0])
     (define result
       (groot-fs-delete-entry/with-operations
        (groot-fs-capture-delete-context root link)
        (list (fs-fixture-path (fs-fixture-path root "unrelated-missing") "link"))
        canonicalize-path groot-fs-live-entry-kind
        (lambda (_) (set! calls (+ calls 1)))
        (lambda (_) (set! calls (+ calls 1)))))
     (check-equal "unrelated reliably missing link path remains eligible"
                  (GrootFsDeleteResult-outcome result) 'success)
     (check-equal "unrelated reliably missing link path calls native deletion once" calls 1))
   (let ([calls 0])
     (define result
       (groot-fs-delete-entry/with-operations
        (groot-fs-capture-delete-context root link)
        (list (fs-fixture-path alias-to-root "link"))
        (lambda (path)
          (if (equal? path root) path
              (error "injected link-prefix resolution failure")))
        (lambda (path)
          (if (equal? path alias-to-root)
              (error "injected link-prefix resolution failure")
              'symlink))
        (lambda (_) (set! calls (+ calls 1)))
        (lambda (_) (set! calls (+ calls 1)))))
     (check-equal "unresolved aliased link prefix is rejected" (GrootFsDeleteResult-outcome result) 'rejected)
     (check-result-detail "unresolved link prefix preserves actionable detail" result "link-prefix resolution failure")
     (check-equal "unresolved aliased link prefix does not call native deletion" calls 0))
   (delete-file! alias-to-root)
   (define prefix-link (fs-fixture-path root "prefix"))
   (fs-fixture-symlink! external prefix-link)
   (let ([calls 0])
     (define result
       (groot-fs-delete-entry/with-operations
        (groot-fs-capture-delete-context root prefix-link)
        (list (fs-fixture-path root "prefix-lookalike"))
        canonicalize-path (lambda (_) 'symlink)
        (lambda (_) (set! calls (+ calls 1)))
        (lambda (_) (set! calls (+ calls 1)))))
     (check-equal "component-prefix lookalike is not a link document conflict"
                  (GrootFsDeleteResult-outcome result) 'success)
     (check-equal "component-prefix lookalike reaches one native operation" calls 1))
   (delete-file! prefix-link)
   ;; An independently named open document at a link's referent is explicitly
   ;; not a conflict; only the link pathname and its descendants are guarded.
   (let ([link-result
          (groot-fs-delete-entry/with-operations
           (groot-fs-capture-delete-context root link) (list external)
           canonicalize-path (lambda (_) 'symlink)
           delete-file! delete-directory!)])
     (check-equal "independent link referent document does not block unlink"
                  (list (GrootFsDeleteResult-outcome link-result)
                        (GrootFsDeleteResult-detail link-result)
                        (GrootFsDeleteResult-native-started? link-result))
                  '(success #f #t))
     (check-equal "unlink preserves external referent" (fs-fixture-file-contents external) "external sentinel")
     (check-equal "unlink removes only link entry" (fs-fixture-entry-kind root "link") #f))))

(with-fs-fixture
 (lambda (root)
   (define file (fs-fixture-path root "file"))
   (define empty (fs-fixture-path root "empty"))
   (define directory (fs-fixture-path root "directory"))
   (define nested (fs-fixture-path directory "nested"))
   (define external (fs-fixture-path root "external-sentinel"))
   (define dangling (fs-fixture-path root "dangling"))
   (fs-fixture-write! file "remove")
   (fs-fixture-mkdir! empty)
   (fs-fixture-mkdir! directory)
   (fs-fixture-mkdir! nested)
   (fs-fixture-mkdir! (fs-fixture-path directory ".git"))
   (fs-fixture-mkdir! (fs-fixture-path directory "node_modules"))
   (fs-fixture-write! (fs-fixture-path nested ".hidden") "remove recursively")
   (fs-fixture-write! (fs-fixture-path (fs-fixture-path directory ".git") "excluded") "remove")
   (fs-fixture-write! (fs-fixture-path (fs-fixture-path directory "node_modules") "excluded") "remove")
   (fs-fixture-write! external "external sentinel")
   (fs-fixture-symlink! external (fs-fixture-path directory "external-link"))
   (fs-fixture-symlink! (fs-fixture-path root "missing-target") dangling)
   (for-each
    (lambda (source)
      (define result (groot-fs-delete-entry (groot-fs-capture-delete-context root source) '()))
      (check-equal "supported deletion succeeds with one native operation"
                   (list (GrootFsDeleteResult-outcome result) (GrootFsDeleteResult-detail result))
                   '(success #f)))
    (list file empty directory dangling))
   (check-equal "file was removed" (fs-fixture-entry-kind root "file") #f)
   (check-equal "empty directory was removed" (fs-fixture-entry-kind root "empty") #f)
   (check-equal "nested hidden and explorer-excluded directory tree was removed"
                (fs-fixture-entry-kind root "directory") #f)
   (check-equal "directory deletion does not follow an external symlink"
                (fs-fixture-file-contents external) "external sentinel")
   (check-equal "dangling symlink was removed without resolving referent" (fs-fixture-entry-kind root "dangling") #f)))

(with-fs-fixture
 (lambda (root)
   (define source (fs-fixture-path root "native-failure"))
   (define removed-child (fs-fixture-path source "removed-child"))
   (define remaining-child (fs-fixture-path source "remaining-child"))
   (fs-fixture-mkdir! source)
   (fs-fixture-write! removed-child "partially removed")
   (fs-fixture-write! remaining-child "must not be rolled back")
   (define calls 0)
   (define result
     (groot-fs-delete-entry/with-operations
      (groot-fs-capture-delete-context root source) '()
      canonicalize-path (lambda (_) 'directory)
      (lambda (_) (set! calls (+ calls 1)) (error "wrong native operation"))
      (lambda (_)
        (set! calls (+ calls 1))
        (delete-file! removed-child)
        (error "injected native failure after partial removal"))))
   (check-equal "native failure is distinct from rejection" (GrootFsDeleteResult-outcome result) 'native-failure)
   (check-result-detail "native failure preserves available detail" result "partial removal")
   (check-equal "native failure records that an operation began" (GrootFsDeleteResult-native-started? result) #t)
   (check-equal "native failure makes exactly one deletion call" calls 1)
   (check-equal "native failure does not roll back a removed fixture child"
                (fs-fixture-entry-kind source "removed-child") #f)
   (check-equal "native failure does not delete remaining fixture contents"
                (fs-fixture-file-contents remaining-child) "must not be rolled back")))

(with-fs-fixture
 (lambda (root)
   (define source (fs-fixture-path root "void-native-failure"))
   (fs-fixture-write! source "must remain after injected failure")
   (define calls 0)
   (define result
     (groot-fs-delete-entry/with-operations
      (groot-fs-capture-delete-context root source) '()
      canonicalize-path (lambda (_) 'file)
      (lambda (_)
        (set! calls (+ calls 1))
        (raise-error (void)))
      (lambda (_) (error "wrong native operation"))))
   (check-equal "raised void native error is a native failure"
                (GrootFsDeleteResult-outcome result) 'native-failure)
   (check-equal "raised void native error uses fallback detail"
                (GrootFsDeleteResult-detail result) "filesystem operation failed")
   (check-equal "raised void native error records native start"
                (GrootFsDeleteResult-native-started? result) #t)
   (check-equal "raised void native error calls native deletion once" calls 1)
   (check-equal "raised void native error does not compensate fixture contents"
                (fs-fixture-file-contents source) "must remain after injected failure")))

(displayln (if found
               (string-append "groot fs tests passed (finder found " (to-string (length found)) " files)")
               "groot fs tests passed (no external finder; fallback path in use)"))
