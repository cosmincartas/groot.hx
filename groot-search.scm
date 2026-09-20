;; Search model for groot.hx: the deferred file index, ranked result rows
;; grouped under their parent directories, and query editing.  The ranking
;; function is a parameter because fuzzy-match exists only inside Helix.

(require "groot-core.scm")
(require "groot-path.scm")
(require "groot-fs.scm")
(require "groot-tree.scm")

(provide *groot-max-results*
         groot-build-search-index!
         groot-search-rows
         groot-refresh-search!
         groot-start-search!
         groot-type!
         groot-backspace!
         groot-filter-prefix-candidates)

;; Result rows built per keystroke. Ranked matches past this point are
;; unreachable by scrolling long before they are worth the cost of building.
(define *groot-max-results* 200)

;; Directory levels drawn above a group's files. Two keeps a deep match
;; identifiable without indenting the whole route from the workspace root.
(define *groot-header-depth* 2)

;; Walks the tree in process, skipping symlink recursion. Correct but single
;; threaded, so it also caches every directory it visits; only used as a fallback.
(define (groot-walk-files state root)
  (define files '())
  (define (walk directory)
    (for-each (lambda (entry)
                (cond [(groot-directory? entry) (walk (groot-entry-path entry))]
                      [(equal? (groot-entry-kind entry) 'file)
                       (set! files (cons (groot-entry-path entry) files))]))
              (groot-children state directory)))
  (walk root)
  files)

;; Creates the complete file index on demand for search.
;; An external finder does the traversal when one exists; it is orders of
;; magnitude faster than walking a large tree from Steel and caches nothing.
(define (groot-build-search-index! state)
  (unless (groot-state-search-ready? state)
    (define root (groot-state-root state))
    (define found (groot-fs-find-files root (hashset->list (groot-state-ignored state))))
    (set-groot-state-files! state (sort (or found (groot-walk-files state root)) string<?))
    (set-groot-state-search-ready! state #t)))

;; Emits the header rows for one parent. Every link in the chain is an only
;; child, so each nests under the previous one. Returns the rows, the guide
;; continuation the group's files sit under, and their depth.
(define (groot-header-rows chain)
  (let loop ([links chain] [depth 0] [continuation ""] [acc '()])
    (if (null? links)
        (list (reverse acc) continuation depth)
        (loop (cdr links)
              (+ depth 1)
              (if (= depth 0) "" (string-append continuation "  "))
              (cons (groot-row (groot-entry (car links) (file-name (car links)) 'directory)
                               depth
                               (if (= depth 0) "" (string-append continuation "└╴")))
                    acc)))))

;; Emits the file rows for one parent, elbowing the final entry.
(define (groot-file-rows files continuation depth)
  (let loop ([items files] [acc '()])
    (if (null? items)
        (reverse acc)
        (loop (cdr items)
              (cons (groot-row (groot-entry (car items) (file-name (car items)) 'file)
                               depth
                               (string-append continuation
                                              (if (null? (cdr items)) "└╴" "├╴")))
                    acc)))))

;; Groups ranked result paths under the directories that contain them, drawing
;; each parent as nested rows rather than one joined path. Parents keep
;; first-match order so the best hit stays near the top.
(define (groot-search-rows root paths)
  (define separator (path-separator))
  (define order '())
  (define groups (hash))
  (for-each
   (lambda (path)
     (define parent (groot-parent-path path separator))
     (unless (hash-contains? groups parent) (set! order (cons parent order)))
     (set! groups
           (hash-insert groups parent
                        (cons path (if (hash-contains? groups parent)
                                       (hash-try-get groups parent)
                                       '())))))
   paths)
  (apply append
         (map (lambda (parent)
                (define header
                  (groot-header-rows
                   (groot-ancestor-chain root parent separator *groot-header-depth*)))
                (append (car header)
                        (groot-file-rows (reverse (hash-try-get groups parent))
                                         (cadr header)
                                         (caddr header))))
              (reverse order))))

;; Narrows a candidate list after a query grows; callers keep ranking in their matcher.
(define (groot-filter-prefix-candidates previous-query query all-files previous-results)
  (if (and (not (equal? previous-query ""))
           (>= (string-length query) (string-length previous-query))
           (equal? (substring query 0 (string-length previous-query)) previous-query))
      previous-results
      all-files))

;; Recomputes search results, narrowing from the previous candidate set where safe.
;; RANK orders candidates for a query; Helix passes its fuzzy-match.
(define (groot-refresh-search! state previous-query rank)
  (groot-build-search-index! state)
  (define query (groot-state-query state))
  (define candidates (groot-filter-prefix-candidates previous-query query
                                                     (groot-state-files state)
                                                     (groot-state-results state)))
  (set-groot-state-results! state (if (equal? query "") '() (rank query candidates)))
  ;; Counted once here; the header would otherwise walk the list on every redraw.
  (set-groot-state-result-count! state (length (groot-state-results state)))
  ;; Narrowing keeps the full ranked list; only the rendered slice is built.
  ;; TODO: row building grows superlinearly past a few thousand rows, so the
  ;; cap is what keeps this cheap. Raise it and measure before trusting it.
  (set-groot-state-result-rows!
   state
   (list->vector (groot-search-rows (groot-state-root state)
                                    (take (groot-state-results state) *groot-max-results*))))
  ;; Headers open each group, so land on the first row that can be activated.
  (set-groot-state-cursor! state (groot-selectable-index state 0 1))
  (set-groot-state-window! state 0))

;; Starts typing a new search query.
(define (groot-start-search! state)
  (set-groot-state-query! state "")
  (set-groot-state-search-input! state #t))

;; Appends a searchable character and refreshes the ranked result list.
(define (groot-type! state character rank)
  (define old (groot-state-query state))
  (set-groot-state-query! state (string-append old (string character)))
  (groot-refresh-search! state old rank))

;; Removes one query character and restores exact cached-prefix candidates when available.
(define (groot-backspace! state rank)
  (define old (groot-state-query state))
  (define len (string-length old))
  (when (> len 0) (set-groot-state-query! state (substring old 0 (- len 1))))
  (groot-refresh-search! state old rank))
