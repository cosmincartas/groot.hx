;; Standalone unit tests for all pure groot-core behavior.

(require "../groot-core.scm")

;; Fails the Steel process with an actionable assertion message.
(define (check-equal name actual expected)
  (unless (equal? actual expected)
    (error (string-append name "\n expected: " (to-string expected) "\n actual: " (to-string actual)))))

;; Entry classification and deterministic directory-first sorting.
(define entries (list (groot-entry "/r/z" "z" 'file)
                      (groot-entry "/r/a" "a" 'directory)
                      (groot-entry "/r/b" "b" 'file)))
(check-equal "directory-first sort" (map groot-entry-name (groot-sort-entries entries)) '("a" "b" "z"))
(check-equal "entries use a named representation" (GrootEntry? (car entries)) #t)
(check-equal "regular files use the theme text color"
             (groot-entry-name-uses-theme-accent? (groot-entry "/r/a.scm" "a.scm" 'file)) #f)
(check-equal "regular file icons retain their glyph color"
             (groot-entry-icon-uses-glyph-color? (groot-entry "/r/a.scm" "a.scm" 'file)) #t)
(check-equal "directory names use the theme accent"
             (groot-entry-name-uses-theme-accent? (groot-entry "/r/src" "src" 'directory)) #t)
(check-equal "directory icons use the theme accent instead of the glyph palette"
             (groot-entry-icon-uses-glyph-color? (groot-entry "/r/src" "src" 'directory)) #f)
(check-equal "rows expose named entry and depth fields"
             (let ([row (groot-row (car entries) 2)])
               (list (GrootRow? row) (groot-entry-name (groot-row-entry row)) (groot-row-depth row)))
             '(#t "z" 2))

;; Typed mutable session state replaces symbol-keyed hash storage.
(define state (groot-state "/repo" "abc"))
(check-equal "state groups concerns in named structures"
             (list (GrootState? state)
                   (GrootTreeState? (GrootState-tree state))
                   (GrootSearchState? (GrootState-search state))
                   (GrootNavigationState? (GrootState-navigation state))
                   (GrootLifecycleState? (GrootState-lifecycle state)))
             '(#t #t #t #t #t))
(groot-state-set! state 'cursor 7)
(check-equal "typed state fields are mutable" (groot-state-ref state 'cursor 0) 7)

;; Component-aware workspace containment.
(check-equal "descendant path is inside" (groot-path-inside? "/repo" "/repo/src/a.scm" "/") #t)
(check-equal "prefix collision is outside" (groot-path-inside? "/repo" "/repository/a.scm" "/") #f)
(check-equal "filesystem-root descendant is inside" (groot-path-inside? "/" "/a.scm" "/") #t)

;; Ancestor calculation required for current-file reveal.
(check-equal "file ancestors" (groot-ancestor-paths "/repo" "/repo/src/ui/a.scm" "/")
             '("/repo" "/repo/src" "/repo/src/ui"))
(check-equal "filesystem-root ancestors terminate" (groot-ancestor-paths "/" "/a.scm" "/") '("/"))

;; Viewport clamping across empty, small, and deep result sets.
(check-equal "empty viewport" (groot-clamp-position 10 10 0 5) '(0 0))
(check-equal "deep cursor scrolls into view" (groot-clamp-position 20 0 100 5) '(20 16))
(check-equal "oversized window clamps" (groot-clamp-position 99 99 100 5) '(99 95))
(check-equal "movement preserves a visible cursor" (groot-window-after-move 3 0 10 4 1) '(4 1))
(check-equal "wheel scroll follows the viewport" (groot-scroll-position 0 0 20 5 3 'down) '(3 3))
(check-equal "wheel scroll clamps at the start" (groot-scroll-position 8 5 20 5 9 'up) '(4 0))
(check-equal "centering respects the final viewport" (groot-centered-window-start 99 100 20) 80)
(check-equal "jump labels are two-character base-N values" (groot-jump-label "abc" 5) "bc")
(check-equal "jump input validates against the configured alphabet" (groot-jump-character-index "abc" #\b) 1)
(check-equal "invalid jump input is rejected" (groot-jump-character-index "abc" #\z) #f)
(check-equal "jump prefix with no visible label is rejected" (groot-jump-prefix-valid? 3 3) #f)
(check-equal "jump prefix with a visible label is accepted" (groot-jump-prefix-valid? 2 3) #t)

;; Rendering truncation preserves the requested width.
(check-equal "row truncation reserves ellipsis" (groot-truncate "abcdef" 4) "abc…")

;; Incremental search may narrow only when the next query extends the previous query.
(check-equal "extended query narrows candidates"
             (groot-filter-prefix-candidates "a" "ab" '("a" "b") '("a")) '("a"))
(check-equal "backspace restores full candidate source"
             (groot-filter-prefix-candidates "ab" "a" '("a" "b") '("a")) '("a" "b"))
(check-equal "first search character starts from all files"
             (groot-filter-prefix-candidates "" "a" '("a" "b") '()) '("a" "b"))

;; Normal-mode character navigation mirrors the documented Helix bindings.
(check-equal "j moves down one row" (groot-navigation-delta #\j) 1)
(check-equal "k moves up one row" (groot-navigation-delta #\k) -1)
(check-equal "other characters are not movement" (groot-navigation-delta #\x) #f)

(displayln "groot core tests passed")
