;; Tree and navigation model tests against real fixture directories.

(require "../groot-core.scm")
(require "../groot-tree.scm")
(require "fs-fixtures.scm")
(require "harness.scm")

;; Visible rows as (name prefix) pairs, the shape a reader sees in the sidebar.
(define (rows-of state)
  (map (lambda (row) (list (groot-entry-name (groot-row-entry row)) (groot-row-prefix row)))
       (vector->list (groot-state-rows state))))

(define (selected-name state)
  (groot-entry-name (groot-row-entry (groot-current-row state))))

;; root/
;;   lib/util.rs
;;   node_modules/pkg.js   (ignored)
;;   src/main.rs
;;   src/ui/view.rs
;;   README.md
(define (build-fixture! root)
  (for-each (lambda (name) (fs-fixture-mkdir! (fs-fixture-path root name)))
            '("lib" "node_modules" "src"))
  (fs-fixture-mkdir! (fs-fixture-path (fs-fixture-path root "src") "ui"))
  (fs-fixture-write! (fs-fixture-path (fs-fixture-path root "lib") "util.rs") "")
  (fs-fixture-write! (fs-fixture-path (fs-fixture-path root "node_modules") "pkg.js") "")
  (fs-fixture-write! (fs-fixture-path (fs-fixture-path root "src") "main.rs") "")
  (fs-fixture-write! (fs-fixture-path (fs-fixture-path (fs-fixture-path root "src") "ui") "view.rs") "")
  (fs-fixture-write! (fs-fixture-path root "README.md") ""))

(define (open-state root)
  (define state (groot-state root "abcdefghijklmnopqrstuvwxyz"))
  (set-groot-state-ignored! state (hashset "node_modules"))
  (set-groot-state-height! state 10)
  (groot-refresh-tree! state)
  state)

(with-fs-fixture
 (lambda (root)
   (build-fixture! root)
   (define state (open-state root))
   (define root-name (file-name root))

   (check-equal "a new session lists the root's children, directories first, ignored names hidden"
                (rows-of state)
                (list (list root-name "") '("lib" "├╴") '("src" "├╴") '("README.md" "└╴")))

   ;; Select src and expand it.
   (groot-move! state 2)
   (check-equal "movement selects the requested row" (selected-name state) "src")
   (groot-toggle-current! state)
   (check-equal "expanding a directory draws nested guides under a continuing parent"
                (rows-of state)
                (list (list root-name "") '("lib" "├╴") '("src" "├╴")
                      '("ui" "│ ├╴") '("main.rs" "│ └╴") '("README.md" "└╴")))
   (groot-toggle-current! state)
   (check-equal "toggling again collapses the directory" (length (rows-of state)) 4)

   ;; Reveal opens every ancestor and selects the path.
   (define view (fs-fixture-path (fs-fixture-path (fs-fixture-path root "src") "ui") "view.rs"))
   (check-equal "reveal reports a selected row" (groot-reveal! state view) #t)
   (check-equal "reveal selects the revealed file" (selected-name state) "view.rs")
   (check-equal "reveal expands each ancestor"
                (map car (rows-of state))
                (list root-name "lib" "src" "ui" "view.rs" "main.rs" "README.md"))
   (check-equal "reveal remembers the path for document sync" (groot-state-last-document state) view)

   (check-equal "an ignored path is never revealed"
                (groot-reveal! state (fs-fixture-path (fs-fixture-path root "node_modules") "pkg.js"))
                #f)
   (check-equal "an outside path is never revealed" (groot-reveal! state "/definitely/not/here") #f)

   ;; Viewport navigation over the revealed tree.
   (groot-move-top! state)
   (check-equal "top selects the root row" (selected-name state) root-name)
   (groot-move-bottom! state)
   (check-equal "bottom selects the final row" (selected-name state) "README.md")
   (groot-move! state -100)
   (check-equal "movement clamps at the first row" (groot-state-cursor state) 0)

   ;; Renaming a directory carries its expansion to the new path.
   (define src (fs-fixture-path root "src"))
   (define renamed (fs-fixture-path root "source"))
   (groot-migrate-expanded-subtree! state src renamed)
   (check-equal "migrated expansion follows the renamed directory and its descendants"
                (list (groot-expanded? state src) (groot-expanded? state renamed)
                      (groot-expanded? state (fs-fixture-path renamed "ui")))
                '(#f #t #t))
   (groot-drop-expanded-subtree! state renamed)
   (check-equal "dropping a subtree forgets it and its descendants"
                (list (groot-expanded? state renamed) (groot-expanded? state (fs-fixture-path renamed "ui"))
                      (groot-expanded? state root))
                '(#f #f #t))))

;; Deletion recovery distinguishes a readable root from an unavailable one.
(with-fs-fixture
 (lambda (root)
   (build-fixture! root)
   (define state (open-state root))
   (delete-file! (fs-fixture-path root "README.md"))
   (check-equal "strict refresh succeeds on a readable root"
                (groot-refresh-tree-after-deletion! state) 'refreshed)
   (check-equal "strict refresh drops the deleted entry"
                (map car (rows-of state)) (list (file-name root) "lib" "src"))
   (set-groot-state-root! state (fs-fixture-path root "missing"))
   (check-equal "strict refresh reports an unavailable root"
                (car (groot-refresh-tree-after-deletion! state)) 'root-unavailable)
   (check-equal "an unavailable root leaves only its synthetic row" (length (rows-of state)) 1)))

(displayln "groot tree tests finished")
