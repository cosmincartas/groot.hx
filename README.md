# groot.hx

`groot.hx` is a cached, lazy file explorer for the plugin-enabled Helix fork.

## Design

- `groot-core.scm` contains pure, documented data and viewport logic.
- `groot-fs.scm` owns filesystem access, classifies each directory entry once, and
  shells out to an external finder for the search index.
- `groot-integration.scm` orchestrates dependency-injected lifecycle and mouse effects.
- `groot.scm` is the Helix UI and event adapter.
- `tests/` runs without Helix and covers core state, finder arguments, initial
  search, navigation, focus, redraw, mouse routing, and component lifecycle:
  `steel tests/run.scm`.

Rows carry a precomputed tree-guide prefix (`├╴`, `└╴`, `│`) instead of a fold marker.

Entries, rendered rows, and session concerns use named structures. Tree, search,
navigation, and lifecycle state are kept separate while the Helix adapter exposes
one small compatibility boundary for state access.

Symlink directories are intentionally rendered as leaves, directory listings are loaded only when needed, and the recursive file index is deferred until the first search.

## Search index

The first `/` builds a file index. `fd`, `fdfind`, or `rg` does the traversal when
one is on `PATH`; the probe runs once per session. Without any of them the
explorer falls back to walking the tree from Steel, which is correct but far
slower on large directories.

Results group under the directories that contain them, drawn as nested rows.
A group shows at most the final two directory levels rather than the whole route
from the root, so a deep match stays readable in a narrow sidebar:

```
 commands
 └╴ engine
   ├╴ main.rs
   └╴ steel.rs
```

Header rows are labels: navigation steps over them and `Enter` does nothing.

The input sits in a rounded frame titled `Explore`, above the results:

```
╭───────── Explore ──────────╮
│ groot▌             200/1834│
╰────────────────────────────╯
```

The frame line shows a prompt glyph, the query with a caret, and the rendered
count against the total match count on the right, so a capped result set is
visible rather than silently short. The title is dropped before it can eat its
own corners, and the counts before they can collide with the prompt. A long query truncates from the front to
keep what you are typing on screen.

Each keystroke re-ranks the full index but builds rows only for the top 200
matches. Narrowing still uses the complete ranked list, so a longer query can
surface a match that fell outside the previous slice.

The finder is invoked with `--hidden --no-ignore` plus one exclude per ignored
name, so search sees exactly what the tree shows: dotfiles are included and
`.gitignore` is not consulted. Dropping `--no-ignore` would be faster still, at
the cost of hits the tree can display but search would no longer find.

## Installation

```scheme
(require "groot/groot.scm")
(keymap (global) (normal (space (g ":groot-open"))))
```

## Commands

Run `:groot-collapse-all` to exit search and restore the active explorer to its root view, with direct children visible and the cursor at the top. It leaves cached data intact and does nothing when Groot is closed.

## Keys

`j`/`k` or arrows navigate; `gg` jumps to the top; `ge` or `G` jumps to the bottom; `zz` centers the selection; `gw` shows two-key labels for visible rows; `Enter` opens or toggles; `Tab` toggles; `/` starts search; `Backspace` edits it; `r` renames; `d` permanently deletes; `R` refreshes; `Esc` returns focus to the editor when no operation is active; `q` closes. `:` falls through to Helix's command prompt.

## Create a file or directory

In focused tree navigation, lowercase `a` opens Helix's native `Create in …:` prompt. The destination is captured before input: it is the selected directory; for a selected file or symlink it is that entry's lexical parent; and when the explorer is empty it is the explorer root.

Enter `one/file.txt` to create one exclusive empty file, or `one/directory/` to create the final directory. Missing intermediate directories are created and existing real directories are reused. One leading separator is relative to the captured destination. Repeated separators, empty paths, `.`, `..`, NUL, unsafe Windows syntax, links, files, and special intermediate entries are rejected. `/` works everywhere; Windows also accepts `\`.

Press `Escape` or `Ctrl-C` before submission to cancel without filesystem changes. Existing final entries are never replaced; final-directory collision detection is best effort during concurrent changes. After success Groot refreshes, reveals and selects the final visible entry, and leaves a new directory collapsed. If a later step fails, created parents remain and Groot reports the partial creation; display failures never delete created entries.

## Rename an entry

In focused tree navigation, lowercase `r` opens Helix's native prompt for a selected regular file or directory. The prompt label identifies the captured entry and its input starts empty: enter the complete replacement name. `r` remains ordinary search or jump input in those modes; uppercase `R` still refreshes.

`Escape` or `Ctrl-C` cancels before submission without filesystem changes. On submission Groot checks all open document paths and refuses to rename an open file or a directory containing an open document. Invalid or unchanged names, existing destinations, filesystem failures, and display failures are reported through Helix; press `r` again to retry. A successful rename refreshes the tree, reveals the new entry, and keeps editor document focus unchanged. If refresh or reveal fails after the rename, Groot reports that display failure and does not rename back.

Destination collision detection is a best-effort pre-check: another process can still create the destination between that check and the native rename. Symbolic-link rename and open-document retargeting are unsupported.

## Permanently delete an entry

In focused tree navigation only, lowercase `d` requests deletion of the selected file, symbolic link, or directory. It is not a delete command while searching or entering a jump. Groot captures the target and kind before prompting, and the prompt identifies that captured target relative to the explorer root: `Permanently delete src/main.scm? Type yes:`. A directory prompt says `Permanently delete src/ and ALL contents? Type yes:`; a link is identified as `link current`.

The native prompt starts empty. Only the exact lowercase input `yes` authorizes deletion—there is no trimming or case folding. Empty input, any other text (including `YES` or spaced `yes`), `Escape`, and `Ctrl-C` cancel without filesystem changes. If the warning and confirmation input cannot fit, Groot refuses to open the prompt and reports that more editor width is needed; it shortens the target label when possible without removing the permanent, directory-contents, or confirmation warnings. Width is checked again on submission, so a resize can also refuse deletion.

Deletion is permanent. A directory deletion is recursive, including hidden and explorer-excluded descendants, and does not stop at mount boundaries; mounted contents are not automatically excluded. It does not follow symbolic links, so deleting a link or a tree containing one leaves its external referent unchanged. Groot rejects the explorer root, unsupported or changed/missing targets, detected outside-root or containment conflicts, and unresolved safety checks. It also blocks detected open-document conflicts with the target, its descendants, resolved aliases, and link-path prefixes.

After every native deletion attempt, Groot refreshes and selects the nearest surviving ancestor within the captured root, without changing editor document focus. A native failure can leave a directory partially deleted: Groot reports that possibility truthfully, performs no rollback, and still attempts refresh. If refresh, ancestor selection, or redraw fails, Groot reports whether deletion succeeded and the display-recovery failure; use `R` to refresh or `d` to make a separately confirmed request.

There is no trash, undo/rollback, secure-erasure guarantee, or protection against hostile concurrent filesystem races. Safety is path-based and cannot identify hard-link equivalence. Automated Steel tests passed on Linux; disposable interactive Helix smoke checks were not run; non-Linux deletion behavior remains unverified.

## Mouse

Click a visible row to focus Groot and select it. While focused, the mouse wheel scrolls Groot using Helix's `scroll-lines` setting. Clicking or scrolling outside the sidebar releases focus back to Helix.
