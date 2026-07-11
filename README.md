# groot.hx

`groot.hx` is a cached, lazy file explorer for the plugin-enabled Helix fork.

## Design

- `groot-core.scm` contains pure, documented data and viewport logic.
- `groot-fs.scm` owns filesystem access and classifies each directory entry once.
- `groot-integration.scm` orchestrates dependency-injected lifecycle and mouse effects.
- `groot.scm` is the Helix UI and event adapter.
- `tests/` runs without Helix and covers core state, initial search, navigation,
  focus, redraw, mouse routing, and component lifecycle: `steel tests/run.scm`.

Entries, rendered rows, and session concerns use named structures. Tree, search,
navigation, and lifecycle state are kept separate while the Helix adapter exposes
one small compatibility boundary for state access.

Symlink directories are intentionally rendered as leaves, directory listings are loaded only when needed, and the recursive file index is deferred until the first search.

## Installation

```scheme
(require "groot/groot.scm")
(keymap (global) (normal (space (g ":groot-open"))))
```

## Keys

`j`/`k` or arrows navigate; `gg` jumps to the top; `ge` or `G` jumps to the bottom; `zz` centers the selection; `gw` shows two-key labels for visible rows; `Enter` opens or toggles; `Tab` toggles; `/` starts search; `Backspace` edits it; `R` refreshes; `q` closes.

## Mouse

Click a visible row to focus Groot and select it. While focused, the mouse wheel scrolls Groot using Helix's `scroll-lines` setting. Clicking or scrolling outside the sidebar releases focus back to Helix.
