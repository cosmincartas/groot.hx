---
schema_version: 1
artifact: implementation-plan
subject: "directory-operations"
status: validated
spec: "spec.md"
spec_sha256: "83d97bc9b1e1572543cb85e28e2c02b07018e9ca24723840f0ee1d20e685e41d"
repository_baseline: "94f56a9387d19ff44f11945d1b04c351ede9fb7f"
working_tree: "Uncommitted file-operation changes exist in production, tests, README, and docs. Preserve all existing changes and untracked support files."
created: "2026-09-13"
updated: "2026-09-13"
---

# Directory Operations Implementation Plan

Before execution, verify `spec_sha256` and its upstream `intent_sha256` against their files. Stop on a mismatch. Execution state belongs to the implementer.

Preserve approved behavior, required contract signatures, invariants, and architecture. Choose private helpers, structure, and incidental wiring within those constraints.

Check existing code, standard libraries, native capabilities, and installed dependencies before adding an abstraction or dependency. Justify each addition through a present requirement.

For consequential deviations, invoke `sdlc` with this plan path before dependent work. Reopen the earliest affected approval, then reassess later approvals.

Private structural changes within approved constraints require verification without another design approval.

## Repository Findings

- `groot-fs.scm:groot-fs-create-empty-file` creates one exclusive file and rejects nested input.
- `groot-core.scm:groot-create-destination` already selects the correct captured destination.
- `groot-integration.scm:groot-create-prompt-effects!` owns submission and error sequencing.
- `groot.scm:groot-open-create-prompt!` connects `a`, destination capture, prompt creation, and filesystem creation.
- `groot.scm:groot-reveal!` opens ancestors and selects the target without expanding a final directory.
- `tests/fs-test.scm` contains exclusive file creation, collision, concurrency, and directory rename checks.
- `tests/integration-test.scm` contains prompt effects, display order, and keyboard ownership checks.
- Current Steel directory creation provides recursive creation without exclusive final-directory ownership.
- Existing uncommitted changes and untracked support files must remain intact.

## Tasks

### Task 1: Create context preserves the destination anchor

- **Requirements:** FR-002, NFR-001.
- **Entry point:** `groot-fs.scm:groot-fs-capture-create-context`.
- **Depends on:** none.
- **RED:** Add fixture checks for lexical capture, canonical anchor capture, and unavailable destinations. Run `steel tests/fs-test.scm`; expect missing contracts.
- **GREEN:** Add `GrootFsCreateContext` and capture the lexical destination with its canonical anchor.
- **REFACTOR:** Reuse current path helpers and keep private validation local to the filesystem module.
- **Verification:** Run `steel tests/fs-test.scm`; context checks pass and all existing checks remain green.

### Task 2: Submitted creation paths validate before mutation

- **Requirements:** FR-003, FR-004, NFR-001, NFR-004.
- **Entry point:** `groot-fs.scm:groot-fs-create-entry`.
- **Depends on:** Task 1.
- **RED:** Add syntax checks and changed-destination checks. Cover separators, dot components, parent components, NUL, POSIX, and Windows forms. Expect failures.
- **GREEN:** Parse all input before mutation and return mutation-free rejection for every invalid form.
- **REFACTOR:** Keep parsing private unless a shared contract becomes necessary. Do not widen rename or deletion validators.
- **Verification:** Run `steel tests/fs-test.scm`; path syntax checks pass without created entries.

### Task 3: Nested file creation handles intermediate entries safely

- **Requirements:** FR-005, FR-006, FR-007, NFR-002, NFR-003.
- **Entry point:** `groot-fs.scm:groot-fs-create-entry`.
- **Depends on:** Task 2.
- **RED:** Add checks for missing parents, reused directories, unsupported intermediates, outside links, final collisions, and an empty final file. Expect failures.
- **GREEN:** Process components sequentially, reject unsafe intermediates, and create the final file exclusively.
- **REFACTOR:** Reuse strict entry classification, joining, and exclusive file creation without adding a filesystem framework.
- **Verification:** Run `steel tests/fs-test.scm`; nested file and safety checks pass with unchanged sentinels.

### Task 4: Partial nested creation reports retained parents

- **Requirements:** FR-012, NFR-006.
- **Entry point:** `groot-fs.scm:GrootFsCreateResult`.
- **Depends on:** Task 3.
- **RED:** Inject failure after one parent creation. Expect a missing partial-failure result and missing mutation state.
- **GREEN:** Return truthful outcomes, details, final paths, and mutation state. Keep every created parent.
- **REFACTOR:** Use one small result record. Avoid rollback helpers and generic operation abstractions.
- **Verification:** Run `steel tests/fs-test.scm`; partial failure retains parents and reports mutation.

### Task 5: Trailing separators create final directories

- **Requirements:** FR-008, NFR-002, NFR-007.
- **Entry point:** `groot-fs.scm:groot-fs-create-entry`.
- **Depends on:** Task 4.
- **RED:** Add final-directory checks for success, observed collisions, unsupported entries, and concurrent directory creation. Expect missing directory outcomes.
- **GREEN:** Create the final directory after a best-effort collision check and verify its live kind.
- **REFACTOR:** Reuse the component traversal from Task 3. Keep the accepted directory race ceiling explicit.
- **Verification:** Run `steel tests/fs-test.scm`; directory checks pass without replacing observed entries.

### Task 6: Creation orchestration preserves filesystem outcomes

- **Requirements:** FR-009, FR-010, FR-012, FR-013, NFR-006.
- **Entry point:** `groot-integration.scm:groot-create-prompt-effects!`.
- **Depends on:** Task 5.
- **RED:** Add checks for cancellation, success, rejection, partial mutation, refresh failure, reveal failure, and redraw failure. Expect result-routing failures.
- **GREEN:** Submit once, refresh after possible mutation, redraw once, and report combined outcomes without compensation.
- **REFACTOR:** Reuse created-entry display handling and preserve document bookkeeping.
- **Verification:** Run `steel tests/integration-test.scm`; effect order and combined outcomes match the specification.

### Task 7: Helix uses one generic nested creation prompt

- **Requirements:** FR-001, FR-002, FR-010, FR-011, NFR-005, NFR-008.
- **Entry point:** `groot.scm:groot-open-create-prompt!`.
- **Depends on:** Task 6.
- **RED:** Add focused checks for generic prompt text, captured context wiring, directory selection, collapsed state, and unchanged dispatch. Expect wiring failures.
- **GREEN:** Capture create context, open `Create in …:`, invoke nested creation, and connect its result to refresh and reveal.
- **REFACTOR:** Keep `a` as the only trigger and preserve existing search, jump, rename, and refresh routing.
- **Verification:** Run `steel tests/core-test.scm` and `steel tests/integration-test.scm`; prompt, selection, and compatibility checks pass.

### Task 8: Documentation and full verification describe shipped behavior

- **Requirements:** NFR-005, NFR-006, NFR-007, NFR-008.
- **Entry point:** `README.md`.
- **Depends on:** Task 7.
- **TDD does not apply because:** This task changes documentation and performs final verification without changing production behavior.
- **Verification:** Update creation documentation, then run `steel tests/run.scm`; all suites pass.
- **Verification:** In Helix, create a nested file and trailing-separator directory. Verify selection, collapse, cancellation, errors, and unchanged directory rename.
