---
schema_version: 1
artifact: intent
subject: "groot-collapse-all"
status: validated
repository_baseline: "66878c8"
exploration: "none"
created: "2026-09-14"
updated: "2026-09-14"
---

# Groot Collapse All Intent

## Initial Request

Could we add a command `groot-collapse-all` that would basically restore the tree to its initial state?

## Problem

Groot users can collapse directories individually, but they cannot restore the complete tree through one command. [User statement and repository evidence]

## Proposed outcome

- Add the public Helix command `groot-collapse-all`. [User statement]
- Keep the workspace root open and show its direct children. [Confirmed user interpretation]
- Collapse every directory below the workspace root. [Confirmed user interpretation]
- Exit search and display the tree. [Confirmed user interpretation]
- Select the workspace root and reset the viewport. [Confirmed user interpretation]
- Redraw the active explorer. [Confirmed user interpretation]
- Do nothing when the explorer is inactive. [Confirmed user interpretation]

## Affected users

- Groot users gain one command that restores a predictable tree view. [Inference from user statement]

## Affected components

- `groot.scm:groot-collapse-all` is the new public command trigger. [Proposed from repository evidence]
- `groot.scm:groot-visible-tree` converts collapse state into visible rows. [Repository evidence]
- `groot.scm:groot-rebuild-tree!` updates the rendered tree after state changes. [Repository evidence]
- `groot-core.scm:groot-state-ref` and `groot-state-set!` expose affected session fields. [Repository evidence]
- `groot.scm:groot-request-redraw!` schedules the visible update. [Repository evidence]
- `groot.scm:groot-post-command-sync!` can reopen current-file ancestors after commands. [Repository evidence and approved correction]
- `tests/integration-test.scm` provides standalone behavior checks without Helix. [Repository evidence]
- `README.md` documents public commands and explorer behavior. [Repository evidence]

## Constraints

- Preserve cached directory listings and the built search index. [Confirmed user interpretation]
- Preserve explorer focus and document synchronization state. [Confirmed user interpretation]
- Suppress only this command's immediate synchronization pass. [Approved correction]
- Keep later document synchronization active. [Approved correction]
- Add no keyboard binding. [Confirmed scope]
- Change no filesystem contents. [Confirmed scope]
- Keep the existing standalone Steel test command. [Repository evidence]

## Open Questions

None.
