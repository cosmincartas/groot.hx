---
schema_version: 1
artifact: intent
subject: "file-operations"
status: validated
repository_baseline: "94f56a9387d19ff44f11945d1b04c351ede9fb7f"
exploration: "none"
created: "2026-09-12"
updated: "2026-09-12"
---

# File Operations Intent

## Initial Request

# Goal
We need to add file operations in our extension:
- create
- rename
- delete
# Constraints
- Keybindings: d for delete, a for create and r for rename;

## Problem

User statement: Add file operations to the extension.

Repository evidence: The explorer supports navigation and opening files, but it has no filesystem modification operations.

Confirmed interpretation: Users need to manage entries directly from the explorer instead of switching to another tool.

## Proposed outcome

User revision: Include copy, cut, and paste alongside create, rename, and delete.

User clarification: Support files and directories, including copying and deleting directory contents.

Confirmed interpretation: Users can complete these operations from the explorer and see the resulting filesystem state in its tree.

Confirmed interpretation: Copy preserves the source. Cut followed by paste moves the source.

Confirmed interpretation: Existing navigation, file opening, and search remain available.

## Affected users

- Repository evidence: Users run this sidebar explorer inside the plugin-enabled Helix fork.
- Confirmed interpretation: These users gain direct file and directory management through keyboard commands.

## Affected components

This confirmed component map derives from Scout repository evidence. New entries identify capabilities absent from the repository.

- `groot.scm:groot-handle-event`: Dispatch the operation keys when the explorer has focus.
- `groot.scm:groot-type!`: Preserve character entry during search input.
- `groot.scm:groot-current-row`: Identify the selected entry for an operation.
- `groot.scm:groot-visible-tree`: Supply displayed entries and selection context.
- `groot-core.scm:GrootEntry`: Represent file, directory, and symbolic link entries.
- `groot-fs.scm:groot-fs-read-directory`: Read filesystem entries after operations.
- `groot.scm:groot-refresh`: Invalidate cached state and refresh tree and search results.
- `groot.scm:groot-rebuild-tree!`: Rebuild the visible tree after changes.
- New: Operation input and feedback for names, destinations, failures, and destructive actions.
- New: Filesystem modification support for create, rename, delete, copy, and move.
- New: Pending copy or cut state consumed by paste.
- New: Operation tests alongside `tests/core-test.scm`, `tests/fs-test.scm`, and `tests/integration-test.scm`.
- `README.md`: Document the added operations and keybindings; this file has no code symbol.

## Constraints

- User statement: Delete must use `d`, create must use `a`, and rename must use `r`.
- User revision: Copy must use `y`, cut must use `x`, and paste must use `p`.
- User clarification: Operations must support both files and directories.
- Repository evidence: Uppercase `R` currently refreshes the explorer; lowercase `r` has no operation.
- Repository evidence: Search input currently treats the requested operation keys as query characters.
- Repository evidence: Symbolic link directories appear as leaves rather than expandable directories.

## Open Questions

- Phase 2: Define creation and paste destinations. Consequence: This determines how selection controls operation targets.
- Phase 2: Define deletion safeguards and recovery expectations. Consequence: This determines destructive-action safety and reversibility.
- Phase 2: Define collision and failure handling. Consequence: This determines overwrite protection and partial-operation behavior.
- Phase 2: Define symbolic link behavior and filesystem boundaries. Consequence: This determines which entries operations can affect.
- Phase 2: Define operation availability during search and empty-tree states. Consequence: This determines valid interaction contexts.
- Phase 2: Define copy and cut state lifetime. Consequence: This determines repeated paste and cancellation behavior.
- Phase 2: Verify available host filesystem and input capabilities. Consequence: Unsupported capabilities can constrain the design.
