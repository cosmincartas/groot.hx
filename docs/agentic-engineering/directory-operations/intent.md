---
schema_version: 1
artifact: intent
subject: "directory-operations"
status: validated
repository_baseline: "94f56a9387d19ff44f11945d1b04c351ede9fb7f"
exploration: "none"
created: "2026-09-13"
updated: "2026-09-13"
---

# Directory Operations Intent

## Initial Request

next step would be to add support to create and rename directories aswell

## Problem

Users cannot create directories through Groot. File creation also rejects nested paths instead of creating missing parent directories.

These problems come from the user request, its later clarification, and repository evidence.

Groot already renames selected directories. The user confirmed that this behavior must remain unchanged.

## Proposed outcome

Groot users can create nested directory paths through the explorer. They can also create missing parent directories and one final empty file.

Groot interprets submitted paths relative to the captured destination. It ignores one leading separator instead of using the filesystem root.

After successful creation, Groot refreshes the tree and selects the final created entry. It does not expand a final directory automatically.

Existing directory rename behavior remains available and does not regress. These outcomes combine user decisions with repository evidence.

## Affected users

- Groot users gain nested file and directory creation without leaving Helix. Source: user request and clarification.
- Groot users retain the current directory rename behavior. Source: user confirmation.

## Affected components

- `groot-integration.scm:groot-key-dispatch` owns create-action keyboard routing. Source: repository evidence.
- `groot.scm:groot-handle-event` routes the selected action. Source: repository evidence.
- `groot.scm:groot-open-create-prompt!` captures the destination and opens the current file prompt. Source: repository evidence.
- New directory-create prompt wiring must capture the destination and creation type. Source: proposed interpretation.
- `groot-integration.scm:groot-create-prompt-effects!` coordinates prompt submission and creation effects. Source: repository evidence.
- `groot-fs.scm:groot-fs-create-empty-file` currently creates one empty file and rejects nested paths. Source: repository evidence.
- New nested creation behavior must create missing directories and the selected final entry type. Source: user clarification.
- `groot-integration.scm:groot-created-file-effects!` currently coordinates refresh and reveal after file creation. Source: repository evidence.
- New or shared created-entry display behavior must select the final entry. Source: proposed interpretation.
- `groot.scm:groot-open-rename-prompt!` already permits selected directories. Source: repository evidence.
- `groot-fs.scm:groot-fs-rename-entry` already renames regular directories. Source: repository evidence.
- `tests/core-test.scm`, `tests/fs-test.scm`, and `tests/integration-test.scm` cover affected behavior. Source: repository evidence.
- `README.md` documents create and rename behavior. Source: repository evidence.

## Constraints

- Creation must support nested paths and create missing directories. Source: user decision.
- File creation must create one empty final file. Source: user clarification and existing behavior.
- Submitted paths must remain beneath the destination captured when the prompt opens. Source: user decision.
- Creation must not overwrite existing files, directories, symbolic links, or special entries. Source: repository evidence and proposed interpretation.
- Successful creation must reveal and select the final entry. A final directory must remain collapsed. Source: user decision.
- Existing directory rename rules must remain unchanged. Source: user confirmation.
- Rename must remain sibling-only and reject occupied destinations. Source: repository evidence.
- Rename must continue to reject the workspace root, symbolic links, special entries, and open descendant documents. Source: repository evidence.
- Copy, cut, paste, and deletion changes are outside this topic. Source: proposed scope boundary.

## Open Questions

- Phase 2 must choose how users select file creation or directory creation. Consequence: this choice controls key routing and prompt presentation.
- Phase 2 must define path syntax and existing intermediate-directory behavior. Consequence: this choice controls validation and collisions.
- Phase 2 must define partial-failure behavior after creating some parent directories. Consequence: this choice controls recovery and user feedback.
