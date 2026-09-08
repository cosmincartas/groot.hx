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

## Keys

`j`/`k` or arrows navigate; `gg` jumps to the top; `ge` or `G` jumps to the bottom; `zz` centers the selection; `gw` shows two-key labels for visible rows; `Enter` opens or toggles; `Tab` toggles; `/` starts search; `Backspace` edits it; `R` refreshes; `q` closes. `:` falls through to Helix's command prompt.

## Mouse

Click a visible row to focus Groot and select it. While focused, the mouse wheel scrolls Groot using Helix's `scroll-lines` setting. Clicking or scrolling outside the sidebar releases focus back to Helix.
