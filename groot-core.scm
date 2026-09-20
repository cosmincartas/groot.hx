;; Entry, row, and session-state data for groot.hx.
;; This module deliberately has no Helix or filesystem dependencies so it can be
;; executed by the standalone Steel test runner.

(require "groot-path.scm")

(provide GrootEntry?
         GrootRow?
         GrootTreeState?
         GrootSearchState?
         GrootNavigationState?
         GrootLifecycleState?
         GrootState?
         GrootState-tree
         GrootState-search
         GrootState-navigation
         GrootState-lifecycle
         groot-entry
         groot-entry-path
         groot-entry-name
         groot-entry-kind
         groot-directory?
         groot-entry-name-uses-theme-accent?
         groot-entry-icon-uses-glyph-color?
         groot-row
         groot-row-entry
         groot-row-depth
         groot-row-prefix
         groot-state
         groot-state-root
         set-groot-state-root!
         groot-state-children
         set-groot-state-children!
         groot-state-expanded
         set-groot-state-expanded!
         groot-state-files
         set-groot-state-files!
         groot-state-search-ready?
         set-groot-state-search-ready!
         groot-state-rows
         set-groot-state-rows!
         groot-state-ignored
         set-groot-state-ignored!
         groot-state-query
         set-groot-state-query!
         groot-state-results
         set-groot-state-results!
         groot-state-result-count
         set-groot-state-result-count!
         groot-state-result-rows
         set-groot-state-result-rows!
         groot-state-search-input?
         set-groot-state-search-input!
         groot-state-pending-g?
         set-groot-state-pending-g!
         groot-state-pending-z?
         set-groot-state-pending-z!
         groot-state-jump-active?
         set-groot-state-jump-active!
         groot-state-jump-input
         set-groot-state-jump-input!
         groot-state-jump-alphabet
         set-groot-state-jump-alphabet!
         groot-state-cursor
         set-groot-state-cursor!
         groot-state-window
         set-groot-state-window!
         groot-state-height
         set-groot-state-height!
         groot-state-scroll-lines
         set-groot-state-scroll-lines!
         groot-state-active?
         set-groot-state-active!
         groot-state-focused?
         set-groot-state-focused!
         groot-state-last-document
         set-groot-state-last-document!
         groot-expanded?
         groot-set-expanded!
         groot-sort-entries
         groot-create-destination)

;; Named filesystem entry used across the core, filesystem, and UI layers.
(struct GrootEntry (path name kind) #:transparent)

;; Named rendered row containing an entry, its tree depth, and its drawn tree prefix.
(struct GrootRow (entry depth prefix) #:transparent)

;; Mutable filesystem and flattened-tree state. expanded maps each expanded
;; directory path to #t; a missing path is collapsed. ignored is the hashset of
;; entry names hidden from both the tree and the search index.
(struct GrootTreeState (root children expanded files search-ready rows ignored)
  #:mutable #:transparent)

;; Mutable search query, match, and search-mode state.
(struct GrootSearchState (query results result-count result-rows input)
  #:mutable #:transparent)

;; Mutable keyboard, jump-label, cursor, and viewport state.
(struct GrootNavigationState
  (pending-g pending-z jump-active jump-input jump-alphabet cursor window height scroll-lines)
  #:mutable #:transparent)

;; Mutable component activation, focus, and synchronization state.
(struct GrootLifecycleState (active focused last-document)
  #:mutable #:transparent)

;; Named top-level state groups concerns without relying on symbol-keyed hash storage.
(struct GrootState (tree search navigation lifecycle) #:transparent)

;; Creates the canonical named entry representation.
(define (groot-entry path name kind) (GrootEntry path name kind))

;; Returns an entry's absolute filesystem path.
(define (groot-entry-path entry) (GrootEntry-path entry))

;; Returns an entry's display name.
(define (groot-entry-name entry) (GrootEntry-name entry))

;; Returns an entry kind: 'directory, 'file, or 'symlink.
(define (groot-entry-kind entry) (GrootEntry-kind entry))

;; Reports whether an entry may be expanded in the explorer.
(define (groot-directory? entry) (equal? (groot-entry-kind entry) 'directory))

;; Reports whether an entry name should inherit the theme's semantic accent.
(define (groot-entry-name-uses-theme-accent? entry) (groot-directory? entry))

;; Reports whether an entry icon should retain its glyph palette color.
(define (groot-entry-icon-uses-glyph-color? entry) (not (groot-directory? entry)))

;; Creates a named rendered tree row; prefix holds the drawn branch guides.
(define (groot-row entry depth prefix) (GrootRow entry depth prefix))

;; Returns a rendered row's filesystem entry.
(define (groot-row-entry row) (GrootRow-entry row))

;; Returns a rendered row's indentation depth.
(define (groot-row-depth row) (GrootRow-depth row))

;; Returns a rendered row's tree-guide prefix string.
(define (groot-row-prefix row) (GrootRow-prefix row))

;; Creates a fresh typed session state rooted at root.
(define (groot-state root default-jump-alphabet)
  (GrootState
    (GrootTreeState root (hash) (hash-insert (hash) root #t) '() #f #() (hashset))
    (GrootSearchState "" '() 0 #() #f)
    (GrootNavigationState #f #f #f "" default-jump-alphabet 0 0 20 3)
    (GrootLifecycleState #t #t #f)))

;; Defines a flat getter and setter for one field of a grouped state struct.
;; A misspelled field is a compile-time free identifier, not a runtime error.
(define-syntax define-groot-field
  (syntax-rules ()
    [(_ getter setter group group-get group-set!)
     (begin (define (getter state) (group-get (group state)))
            (define (setter state value) (group-set! (group state) value)))]))

(define-groot-field groot-state-root set-groot-state-root!
  GrootState-tree GrootTreeState-root set-GrootTreeState-root!)

(define-groot-field groot-state-children set-groot-state-children!
  GrootState-tree GrootTreeState-children set-GrootTreeState-children!)

(define-groot-field groot-state-expanded set-groot-state-expanded!
  GrootState-tree GrootTreeState-expanded set-GrootTreeState-expanded!)

(define-groot-field groot-state-files set-groot-state-files!
  GrootState-tree GrootTreeState-files set-GrootTreeState-files!)

(define-groot-field groot-state-search-ready? set-groot-state-search-ready!
  GrootState-tree GrootTreeState-search-ready set-GrootTreeState-search-ready!)

(define-groot-field groot-state-rows set-groot-state-rows!
  GrootState-tree GrootTreeState-rows set-GrootTreeState-rows!)
(define-groot-field groot-state-ignored set-groot-state-ignored!
  GrootState-tree GrootTreeState-ignored set-GrootTreeState-ignored!)

(define-groot-field groot-state-query set-groot-state-query!
  GrootState-search GrootSearchState-query set-GrootSearchState-query!)

(define-groot-field groot-state-results set-groot-state-results!
  GrootState-search GrootSearchState-results set-GrootSearchState-results!)

(define-groot-field groot-state-result-count set-groot-state-result-count!
  GrootState-search GrootSearchState-result-count set-GrootSearchState-result-count!)

(define-groot-field groot-state-result-rows set-groot-state-result-rows!
  GrootState-search GrootSearchState-result-rows set-GrootSearchState-result-rows!)

(define-groot-field groot-state-search-input? set-groot-state-search-input!
  GrootState-search GrootSearchState-input set-GrootSearchState-input!)

(define-groot-field groot-state-pending-g? set-groot-state-pending-g!
  GrootState-navigation GrootNavigationState-pending-g set-GrootNavigationState-pending-g!)

(define-groot-field groot-state-pending-z? set-groot-state-pending-z!
  GrootState-navigation GrootNavigationState-pending-z set-GrootNavigationState-pending-z!)

(define-groot-field groot-state-jump-active? set-groot-state-jump-active!
  GrootState-navigation GrootNavigationState-jump-active set-GrootNavigationState-jump-active!)

(define-groot-field groot-state-jump-input set-groot-state-jump-input!
  GrootState-navigation GrootNavigationState-jump-input set-GrootNavigationState-jump-input!)

(define-groot-field groot-state-jump-alphabet set-groot-state-jump-alphabet!
  GrootState-navigation GrootNavigationState-jump-alphabet set-GrootNavigationState-jump-alphabet!)

(define-groot-field groot-state-cursor set-groot-state-cursor!
  GrootState-navigation GrootNavigationState-cursor set-GrootNavigationState-cursor!)

(define-groot-field groot-state-window set-groot-state-window!
  GrootState-navigation GrootNavigationState-window set-GrootNavigationState-window!)

(define-groot-field groot-state-height set-groot-state-height!
  GrootState-navigation GrootNavigationState-height set-GrootNavigationState-height!)

(define-groot-field groot-state-scroll-lines set-groot-state-scroll-lines!
  GrootState-navigation GrootNavigationState-scroll-lines set-GrootNavigationState-scroll-lines!)

(define-groot-field groot-state-active? set-groot-state-active!
  GrootState-lifecycle GrootLifecycleState-active set-GrootLifecycleState-active!)

(define-groot-field groot-state-focused? set-groot-state-focused!
  GrootState-lifecycle GrootLifecycleState-focused set-GrootLifecycleState-focused!)

(define-groot-field groot-state-last-document set-groot-state-last-document!
  GrootState-lifecycle GrootLifecycleState-last-document set-GrootLifecycleState-last-document!)

;; Reports whether directory path is expanded; absent paths are collapsed.
(define (groot-expanded? state path)
  (hash-contains? (groot-state-expanded state) path))

;; Expands or collapses one directory path.
(define (groot-set-expanded! state path expanded?)
  (set-groot-state-expanded!
   state
   (if expanded?
       (hash-insert (groot-state-expanded state) path #t)
       (hash-remove (groot-state-expanded state) path))))

;; Sorts entries with directories first and names second.
(define (groot-sort-entries entries)
  (sort entries
        (lambda (left right)
          (cond [(and (groot-directory? left) (not (groot-directory? right))) #t]
                [(and (not (groot-directory? left)) (groot-directory? right)) #f]
                [else (string<? (groot-entry-name left) (groot-entry-name right))]))))

;; Captures the directory where a new child belongs. Symlinks are leaves, so
;; like files they use their lexical parent rather than their target.
(define (groot-create-destination root entry separator)
  (cond [(not entry) root]
        [(groot-directory? entry) (groot-entry-path entry)]
        [else (groot-parent-path (groot-entry-path entry) separator)]))
