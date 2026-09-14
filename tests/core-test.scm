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
(check-equal "rows expose named entry, depth, and tree-prefix fields"
             (let ([row (groot-row (car entries) 2 "├╴")])
               (list (GrootRow? row) (groot-entry-name (groot-row-entry row)) (groot-row-depth row) (groot-row-prefix row)))
             '(#t "z" 2 "├╴"))

(check-equal "ancestor chains keep the last directories, outermost first"
             (list (groot-ancestor-chain "/repo" "/repo/a/b/c" "/" 2)
                   (groot-ancestor-chain "/repo" "/repo/src" "/" 2)
                   (groot-ancestor-chain "/repo" "/repo" "/" 2)
                   (groot-ancestor-chain "/repo" "/repo/a/b/c" "/" 1))
             '(("/repo/a/b" "/repo/a/b/c") ("/repo/src") ("/repo") ("/repo/a/b/c")))

(check-equal "input truncation keeps the tail rather than the head"
             (list (groot-truncate-start "abcdefgh" 4)
                   (groot-truncate-start "abc" 8)
                   (groot-truncate-start "abcdefgh" 1)
                   (groot-truncate-start "abc" 0))
             '("…fgh" "abc" "…" ""))

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
;; Reveal must match host-returned Windows casing while preserving POSIX exactness.
(check-equal "Windows reveal path matching ignores case"
             (groot-path=? "C:\\repo\\Foo\\child" "C:\\repo\\foo\\child" "\\") #t)
(check-equal "POSIX reveal path matching preserves case"
             (groot-path=? "/repo/Foo/child" "/repo/foo/child" "/") #f)

;; Ancestor calculation required for current-file reveal.
(check-equal "file ancestors" (groot-ancestor-paths "/repo" "/repo/src/ui/a.scm" "/")
             '("/repo" "/repo/src" "/repo/src/ui"))
(check-equal "filesystem-root ancestors terminate" (groot-ancestor-paths "/" "/a.scm" "/") '("/"))
;; Windows drive roots are lexical roots, not removable separators.
(check-equal "Windows drive roots are indivisible parents"
             (list (groot-parent-path "C:\\new.txt" "\\")
                   (groot-parent-path "C:\\" "\\"))
             '("C:\\" "C:\\"))
(check-equal "Windows drive root ancestors and chains include root and terminate"
             (list (groot-ancestor-paths "C:\\" "C:\\new.txt" "\\")
                   (groot-ancestor-chain "C:\\" "C:\\" "\\" 2))
             '(("C:\\") ("C:\\")))

;; Rename labels describe the captured name only; native prompt input is empty.
(check-equal "rename labels retain spaces and Unicode"
             (list (groot-rename-prompt-label "main.scm" 80)
                   (groot-rename-prompt-label "資料 file.scm" 80))
             '("Rename main.scm:" "Rename 資料 file.scm:"))
(check-equal "narrow rename labels retain a name tail and editor space"
             (groot-rename-prompt-label "main.scm" 22)
             "Rename …m:")
(check-equal "narrow all-Unicode rename labels stay bounded"
             (list (groot-rename-prompt-label "😀😀" 22)
                   (groot-create-prompt-remaining-input
                    22 (groot-rename-prompt-label "😀😀" 22)))
             '("Rename …:" 9))
;; Rename labels use the same UTF-8 byte and display-cell safeguards as create
;; labels, so a narrow emoji filename cannot consume the native empty editor.
(define narrow-rename-emoji-label
  (groot-rename-prompt-label "😀😀😀.scm" 30))
(check-equal "narrow emoji rename label leaves usable native input"
             (list narrow-rename-emoji-label
                   (groot-create-prompt-host-byte-width narrow-rename-emoji-label)
                   (groot-create-prompt-cell-width narrow-rename-emoji-label)
                   (groot-create-prompt-remaining-input 30 narrow-rename-emoji-label))
             '("Rename …😀.scm:" 19 16 9))

;; A rename destination is a lexical sibling and does not reinterpret its name.
(check-equal "rename destination preserves spaces and Unicode"
             (groot-rename-destination "/repo/src/main.scm" "資料 file.scm" "/")
             "/repo/src/資料 file.scm")
(check-equal "Windows rename destination preserves its platform separator"
             (groot-rename-destination "C:\\repo\\main.scm" "next name.scm" "\\")
             "C:\\repo\\next name.scm")

;; Open documents conflict only at the source path or beneath a component boundary.
(check-equal "exact source document blocks rename"
             (groot-rename-open-document-conflict? "/repo/src/main.scm"
                                                   '("/repo/src/main.scm") "/")
             #t)
(check-equal "descendant document blocks directory rename"
             (groot-rename-open-document-conflict? "/repo/src"
                                                   '("/repo/src/lib/main.scm") "/")
             #t)
(check-equal "unrelated document does not block rename"
             (groot-rename-open-document-conflict? "/repo/src"
                                                   '("/repo/tests/main.scm" #f) "/")
             #f)
(check-equal "prefix-collision document does not block rename"
             (groot-rename-open-document-conflict? "/repo/src"
                                                   '("/repo/src-old/main.scm") "/")
             #f)

;; A create destination is captured from tree context, never from a link target.
(check-equal "selected directory is the create destination"
             (groot-create-destination "/repo" (groot-entry "/repo/src" "src" 'directory) "/")
             "/repo/src")
(check-equal "selected file uses its parent as the create destination"
             (groot-create-destination "/repo" (groot-entry "/repo/src/a.scm" "a.scm" 'file) "/")
             "/repo/src")
(check-equal "Windows root leaf uses the drive root as its create destination"
             (groot-create-destination "C:\\" (groot-entry "C:\\new.txt" "new.txt" 'file) "\\")
             "C:\\")
(check-equal "selected symlink uses its lexical parent as the create destination"
             (groot-create-destination "/repo" (groot-entry "/repo/src/link" "link" 'symlink) "/")
             "/repo/src")
(check-equal "empty tree falls back to explorer root"
             (groot-create-destination "/repo" #f "/")
             "/repo")
;; Prompt labels use the actual viewport width, reserve the native prompt's
;; right margin and a usable filename editor, and fall back to one cell safely.
(check-equal "create prompt budgets derive from narrow and wide live widths"
             (list (groot-create-prompt-label-budget 22)
                   (groot-create-prompt-label-budget 80)
                   (groot-create-prompt-label-budget 0))
             '(12 70 1))
(check-equal "narrow create label retains a destination tail and editor space"
             (groot-create-prompt-label "/repo/src" 22)
             "Create:…c:")
(check-equal "wide create label uses the approved destination wording"
             (groot-create-prompt-label "/repo/src" 80)
             "Create in /repo/src:")
(check-equal "unicode create labels preserve a tail when the compact prefix cannot"
             (groot-create-prompt-label "/repo/資料" 22)
             "…資料:")
(check-equal "wide unicode create label uses approved wording and retains its full path"
             (groot-create-prompt-label "/repo/資料/長い名前" 80)
             "Create in /repo/資料/長い名前:")

;; Helix clip_left uses Rust String::len() byte offsets, unlike the display-cell
;; budget. Labels must therefore leave the native margin and eight input cells
;; under both measures, even for UTF-8 ellipses and four-byte emoji.
(define narrow-emoji-label (groot-create-prompt-label "/repo/😀😀😀/tail" 22))
(define wide-emoji-label
  (groot-create-prompt-label "/repo/😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀/tail" 80))
(check-equal "narrow ellipsis label fits Helix byte budget and leaves input"
             (list (groot-create-prompt-host-byte-width narrow-emoji-label)
                   (groot-create-prompt-cell-width narrow-emoji-label)
                   (groot-create-prompt-remaining-input 22 narrow-emoji-label))
             '(12 11 8))
(check-equal "wide emoji ellipsis preserves the destination tail"
             wide-emoji-label
             "Create in …😀😀😀😀😀😀😀😀😀😀😀😀/tail:")
(check-equal "wide emoji ellipsis fits byte and display budgets and leaves input"
             (list (<= (groot-create-prompt-host-byte-width wide-emoji-label)
                       (groot-create-prompt-label-budget 80))
                   (<= (groot-create-prompt-cell-width wide-emoji-label)
                       (groot-create-prompt-label-budget 80))
                   (groot-create-prompt-remaining-input 80 wide-emoji-label))
             '(#t #t 11))
(check-equal "ellipsis host byte width is distinct from its display width"
             (list (groot-create-prompt-host-byte-width "…")
                   (groot-create-prompt-cell-width "…"))
             '(3 2))

;; Delete labels retain the permanent-deletion warning and the entry kind's
;; safety wording while leaving room for exact `yes` and the native cursor.
(check-equal "delete labels identify files, links, and directory contents"
             (list (groot-delete-prompt-label "main.scm" 'file 80)
                   (groot-delete-prompt-label "current" 'symlink 80)
                   (groot-delete-prompt-label "src" 'directory 80))
             '("Permanently delete main.scm? Type yes:"
               "Permanently delete current current? Type yes:"
               "Permanently delete src/ and ALL contents? Type yes:"))
(check-equal "Unicode delete label preserves its target tail and confirmation input"
             (let ([label (groot-delete-prompt-label "資料😀" 'file 80)])
               (list label
                     (groot-create-prompt-remaining-input 80 label)))
             '("Permanently delete 資料😀? Type yes:" 38))
(check-equal "narrow delete labels preserve kind warnings, Unicode tails, and usable input"
             (list (groot-delete-prompt-label "very-long-file-name" 'file 40)
                   (groot-delete-prompt-label "資料😀tail" 'file 46)
                   (groot-delete-prompt-label "very-long-link-name" 'symlink 50)
                   (groot-delete-prompt-label "very-long-directory-name" 'directory 58))
             '("Permanently delete …e? Type yes:"
               "Permanently delete …tail? Type yes:"
               "Permanently delete …ame current? Type yes:"
               "Permanently delete …e/ and ALL contents? Type yes:"))
(check-equal "delete labels explicitly reject widths without warning and input space"
             (list (groot-delete-prompt-label "a" 'file 36)
                   (groot-delete-prompt-label "src" 'directory 52)
                   (groot-delete-prompt-label "link" 'symlink 43))
             '(insufficient-space insufficient-space insufficient-space))

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
