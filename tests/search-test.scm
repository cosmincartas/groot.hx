;; Search model tests: grouped result rows, prefix narrowing, and query editing.

(require "../groot-core.scm")
(require "../groot-tree.scm")
(require "../groot-search.scm")
(require "harness.scm")

;; Rows as (name depth prefix) triples.
(define (describe rows)
  (map (lambda (row)
         (list (groot-entry-name (groot-row-entry row)) (groot-row-depth row) (groot-row-prefix row)))
       rows))

(check-equal "results group under their parents, keep first-match order, and show two header levels"
             (describe (groot-search-rows "/r" '("/r/src/ui/view.rs" "/r/README.md"
                                                 "/r/src/ui/panel.rs" "/r/a/b/c/d.rs")))
             '(("src" 0 "") ("ui" 1 "└╴") ("view.rs" 2 "  ├╴") ("panel.rs" 2 "  └╴")
               ("r" 0 "") ("README.md" 1 "└╴")
               ("b" 0 "") ("c" 1 "└╴") ("d.rs" 2 "  └╴")))
(check-equal "headers are directories and results are files"
             (map (lambda (row) (groot-entry-kind (groot-row-entry row)))
                  (groot-search-rows "/r" '("/r/src/main.rs")))
             '(directory file))

;; A substring ranker records the candidates it receives so narrowing is visible.
(define ranked-from '())
(define (rank query candidates)
  (set! ranked-from candidates)
  (filter (lambda (path) (string-contains? path query)) candidates))

(define files '("/r/lib/util.rs" "/r/src/main.rs" "/r/src/ui/view.rs" "/r/README.md"))
(define state (groot-state "/r" "abc"))
(set-groot-state-files! state files)
(set-groot-state-search-ready! state #t)
(set-groot-state-height! state 10)

(groot-start-search! state)
(check-equal "starting a search opens an empty input"
             (list (groot-state-query state) (groot-state-search-input? state)) '("" #t))

(groot-type! state #\s rank)
(check-equal "the first character ranks every indexed file" ranked-from files)
(check-equal "matches are counted once"
             (list (groot-state-results state) (groot-state-result-count state))
             '(("/r/lib/util.rs" "/r/src/main.rs" "/r/src/ui/view.rs") 3))
(check-equal "the cursor skips the first header and lands on a result"
             (groot-entry-name (groot-row-entry (groot-current-row state))) "util.rs")

(groot-type! state #\r rank)
(check-equal "an extended query narrows from the previous results"
             ranked-from '("/r/lib/util.rs" "/r/src/main.rs" "/r/src/ui/view.rs"))
(check-equal "the narrowed query keeps only matching files"
             (groot-state-results state) '("/r/src/main.rs" "/r/src/ui/view.rs"))

(groot-backspace! state rank)
(check-equal "backspace ranks the full index again" ranked-from files)
(check-equal "backspace shortens the query" (groot-state-query state) "s")

(groot-move! state 1)
(check-equal "movement in results steps over header rows"
             (groot-entry-name (groot-row-entry (groot-current-row state))) "main.rs")

(check-equal "prefix candidates narrow only when the query extends the previous one"
             (list (groot-filter-prefix-candidates "a" "ab" '("a" "b") '("a"))
                   (groot-filter-prefix-candidates "ab" "a" '("a" "b") '("a"))
                   (groot-filter-prefix-candidates "" "a" '("a" "b") '()))
             '(("a") ("a" "b") ("a" "b")))

(displayln "groot search tests finished")
