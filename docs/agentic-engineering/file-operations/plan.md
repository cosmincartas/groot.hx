---
schema_version: 1
artifact: implementation-plan
subject: "file-operations"
status: validated
spec: "spec.md"
spec_sha256: "31f40bd9953b69b999d55e50c086fb0fabe28f0467f7ea789aa85acf9944b05a"
repository_baseline: "94f56a9387d19ff44f11945d1b04c351ede9fb7f"
working_tree: "Uncommitted create and rename changes exist across production, tests, README, and support files. Preserve them and unrelated untracked files."
created: "2026-09-12"
updated: "2026-09-13"
---

# File Operations: Delete Implementation Plan

Before execution, verify `spec_sha256` and its upstream `intent_sha256` against their files. Stop on a mismatch.
Execution state belongs to the implementer.

Preserve approved behavior, required contracts, invariants, and architecture. Choose private helpers and incidental wiring within those constraints.
An important internal safety contract remains binding even when its representation is discretionary.
Check existing code, standard libraries, native capabilities, and installed dependencies before adding an abstraction or dependency.
Justify additions through a present requirement and explain why existing options are insufficient.

For consequential deviations, invoke `sdlc` with this plan path before dependent work.
Apply its shared correction rule, reopen the earliest affected approval, and reassess later approvals.
Private structural changes within approved constraints require verification, not another design approval.
Trace downstream from each task entry point. The entries do not freeze a downstream file map.

## Repository Findings

- The validated delete specification replaces the rename-only specification with explicit user approval.
- The previous plan recorded specification hash `19d0dc2dd5c53cfafa379a686cc011f1946323e90d9efd65fc98269359d4ec4f`.
- This plan replaces that stale rename plan and records the validated delete specification hash above.
- `groot-core.scm` contains component-boundary comparisons, parent-path helpers, and conservative prompt byte/cell budgets.
- `groot-integration.scm:groot-key-dispatch` preserves focus, jump, and search precedence before create and rename commands.
- `groot.scm:groot-handle-event` clears pending prefixes before opening operation prompts.
- `groot.scm:groot-open-document-paths` enumerates current filesystem-backed document paths.
- `groot-fs.scm:groot-fs-live-entry-kind` distinguishes files, directories, links, missing entries, and unsupported entries without suppressing errors.
- `groot-fs.scm:groot-fs-read-directory` suppresses display read errors. Do not reuse it for deletion safety checks.
- `groot-fs-internal.scm` provides existing injected filesystem seams. Preserve create and rename behavior while adding deletion tests.
- `groot-integration.scm` provides injected prompt, mutation, display, and error callbacks.
- `groot.scm:groot-refresh` rebuilds cached state. `groot-reveal!` changes document-sync bookkeeping, which result handling needs to restore.
- The synthetic root row does not prove that the root directory exists or remains readable.
- `tests/fs-fixtures.scm` provides temporary directories, nested entries, symlinks, sentinel contents, and cleanup.
- `tests/run.scm` runs the core, filesystem, and integration suites.
- The inspected host's Steel provides `canonicalize-path`, `delete-file!`, and `delete-directory!`. Verify the execution runtime before implementation claims.
- No delete boundary, delete dispatch, or delete test coverage exists yet.
- Scout found no planning-blocking incompatibility with the validated specification.

## Tasks

### Task 1: Delete confirmations preserve safety information within the available width

- **Requirements:** FR-2, FR-12, NFR-3.
- **Entry point:** `groot-core.scm:groot-create-prompt-label-budget`.
- **Depends on:** none.
- **RED:** Add core tests for file, link, directory, Unicode, and narrow delete labels. Expect missing delete-label behavior to fail.
- **GREEN:** Produce warning-preserving labels and an explicit insufficient-space outcome using existing byte/cell helpers.
- **GREEN:** Reserve usable input for exact `yes` and the cursor. Preserve the directory contents warning.
- **REFACTOR:** Share private budgeting calculations without changing create or rename label behavior.
- **Verification:** Run `steel tests/core-test.scm`; all label and existing core checks pass.

### Task 2: Captured deletion context rejects invalid or changed target addresses

- **Requirements:** FR-6, FR-8, NFR-1, NFR-5.
- **Entry point:** `groot-fs.scm:groot-fs-live-entry-kind`.
- **Depends on:** none.
- **RED:** Add filesystem tests for root equality, outside paths, traversal, unsupported kinds, missing entries, and changed resolved parents or roots.
- **RED:** Require rejected cases to leave injected native-call counts at zero; expect absent validation to fail.
- **GREEN:** Capture and revalidate the specification's logical paths, resolved root/parent, basename, and exact entry kind.
- **GREEN:** Construct the deletion address from the resolved parent and unchanged basename. Reject unresolved safety checks.
- **GREEN:** Keep valid dangling and external-target symlink entries eligible without resolving their final referent.
- **REFACTOR:** Reuse existing strict directory-entry probes and pure comparisons. Keep captured representation discretionary.
- **Verification:** Run `steel tests/fs-test.scm`; rejection fixtures remain unchanged and supported captured addresses pass validation.

### Task 3: Current document paths prevent detected deletion conflicts

- **Requirements:** FR-7, FR-8, NFR-1, NFR-5.
- **Entry point:** `groot-fs.scm`.
- **Depends on:** Task 2.
- **RED:** Add filesystem tests for direct open paths, directory descendants, resolved aliases, link-path prefixes, and missing named document suffixes.
- **RED:** Add independent-referent and component-prefix lookalikes as non-conflicts. Expect missing conflict policy to fail.
- **GREEN:** Implement specification section 9.2 using lexical checks, resolved referents, and resolved-parent entry addresses.
- **GREEN:** Preserve missing suffixes only when absence is established reliably. Reject unresolved required checks instead of ignoring errors.
- **GREEN:** Keep hard-link identity and unrepresentable host paths within the approved documented limitations.
- **REFACTOR:** Share resolution logic with target checks without weakening link-entry semantics or broadening the guarantee.
- **Verification:** Run `steel tests/fs-test.scm`; conflicting cases reach no native operation, while independent link referents remain eligible.

### Task 4: Validated deletion invokes exactly one native operation

- **Requirements:** FR-4, FR-5, FR-6, FR-7, FR-8, FR-10, NFR-1, NFR-2, NFR-5.
- **Entry point:** `groot-fs.scm`.
- **Depends on:** Task 2, Task 3.
- **RED:** Add fixture tests for files, empty directories, nested hidden contents, explorer-excluded entries, and valid or dangling links.
- **RED:** Inject a native failure after fixture-child removal. Expect absent native dispatch or incorrect outcome classification to fail.
- **GREEN:** Expose the shared validated boundary and use one `delete-file!` or `delete-directory!` call as specified.
- **GREEN:** Preserve rejection, success, and attempted-native-failure distinctions with available error details.
- **GREEN:** Do not retry, compensate, invoke subprocesses, or traverse filtered explorer rows.
- **REFACTOR:** Consolidate injected native seams while retaining the authoritative validation boundary and unchanged create/rename APIs.
- **Verification:** Run `steel tests/fs-test.scm`; external sentinels survive, removed entries disappear, and partial failure produces no second deletion call.

### Task 5: Only exact confirmation reaches current safety checks

- **Requirements:** FR-2, FR-3, FR-7, FR-8, FR-12, NFR-1, NFR-3.
- **Entry point:** `groot-integration.scm`.
- **Depends on:** Task 1, Task 4.
- **RED:** Add injected prompt tests for exact `yes`, empty input, case variants, spaces, abort, stale selection, and insufficient resized width.
- **RED:** Assert current document enumeration follows confirmation and precedes deletion. Expect missing sequencing to fail.
- **GREEN:** Capture the original target, push the native empty prompt, and gate submission on exact confirmation and current width.
- **GREEN:** Read current document paths only for authorized submission, then call the validated filesystem boundary.
- **GREEN:** Keep cancellation and rejected width checks mutation-free; never substitute the current tree selection for the captured target.
- **REFACTOR:** Reuse the existing injected effect style without introducing a generic operation framework.
- **Verification:** Run `steel tests/integration-test.scm`; only authorized submissions reach safety checks, and all cancellation paths preserve contents.

### Task 6: Every native attempt produces truthful refresh and selection outcomes

- **Requirements:** FR-9, FR-10, FR-11, NFR-2.
- **Entry point:** `groot-integration.scm:groot-renamed-entry-effects!`.
- **Depends on:** Task 4.
- **RED:** Add effect-order tests for success, partial native failure, missing parents, unavailable roots, and injected display failures.
- **RED:** Assert preserved document bookkeeping and no deletion retries. Expect missing delete-result orchestration to fail.
- **GREEN:** Add deletion-specific result sequencing that refreshes after native success or failure, but not after cancellation.
- **GREEN:** Select the nearest surviving in-root ancestor and retain separate filesystem and display outcomes.
- **GREEN:** Report unavailable roots without recreating entries. Restore prior document-sync state after every display outcome.
- **REFACTOR:** Share private result utilities only where create and rename retain their existing behavior.
- **Verification:** Run `steel tests/integration-test.scm`; observed callback order, error text, selection fallback, and native-call counts match the specification.

### Task 7: Focused tree input exposes the complete delete workflow in Helix

- **Requirements:** FR-1, FR-2, FR-3, FR-6, FR-7, FR-9, FR-10, FR-11, FR-12, NFR-3, NFR-4.
- **Entry point:** `groot.scm:groot-handle-event`.
- **Depends on:** Task 1, Task 5, Task 6.
- **RED:** Add dispatch regressions for focus, search input/results, jump mode, pending prefixes, and existing operation keys.
- **RED:** Add adapter-effect tests for capture, document enumeration, cache invalidation, ancestor probes, and restored document state.
- **RED:** Expect missing `d` routing and live delete wiring to fail before integration.
- **GREEN:** Wire tree-only `d`, native confirmation, current width/documents, the validated boundary, and delete-result effects.
- **GREEN:** Clear pending prefixes, reject empty/root selections, invalidate stale caches/expansion state, and preserve editor document focus.
- **GREEN:** Do not enable deletion from search results or change existing create/rename behavior.
- **REFACTOR:** Keep host-only wiring thin. Extract injectable effects only where required to verify actual production sequencing.
- **Verification:** Run `steel tests/run.scm`; all existing and new tests pass. Complete the disposable Helix smoke checks below.

### Task 8: User documentation accurately describes permanent deletion and its limitations

- **Requirements:** FR-1, FR-2, FR-3, FR-5, FR-7, FR-11, FR-12, NFR-2, NFR-3, NFR-4, NFR-5.
- **Entry point:** `README.md`.
- **Depends on:** Task 7.
- **TDD:** TDD does not apply because this task changes documentation rather than production behavior.
- **Action:** Document `d`, exact `yes`, tree-only availability, recursive hidden contents, symlink preservation, document guards, and partial-failure recovery.
- **Action:** State no trash, rollback, secure-erasure guarantee, or hostile-race protection. Describe Linux validation and prompt-width refusal.
- **Action:** Preserve existing create, rename, navigation, and test instructions.
- **Verification:** Compare README instructions against a completed disposable Helix smoke run and the validated specification.

## Verification Commands

Run each focused command after its task. Run the complete suite after every completed behavior task.

```bash
steel tests/core-test.scm
steel tests/fs-test.scm
steel tests/integration-test.scm
steel tests/run.scm
```

Use an isolated Steel home when local cog resolution otherwise loads another installed checkout:

```bash
python3 - <<'PY'
import os, pathlib, subprocess, tempfile
with tempfile.TemporaryDirectory(prefix='groot-test-home-') as directory:
    home = pathlib.Path(directory)
    (home / 'cogs').mkdir()
    (home / 'cogs/groot').symlink_to(pathlib.Path.cwd(), target_is_directory=True)
    result = subprocess.run(
        ['steel', 'tests/run.scm'],
        env={**os.environ, 'STEEL_HOME': directory},
    )
    raise SystemExit(result.returncode)
PY
```

Use only disposable fixtures for destructive tests. Never target repository source files, real documents, or user directories.
A simulated race test verifies detected changes, not elimination of the approved external replacement races.
Record runtime versions and observed results. Report unavailable Helix verification instead of treating automated tests as host certification.

## Disposable Helix Smoke Checks

1. Create a temporary workspace with a file, nested directory, hidden child, and link to an external temporary sentinel.
2. Cancel each entry-kind prompt and verify unchanged contents and selection.
3. Submit invalid confirmation variants and verify no deletion.
4. Confirm each supported entry kind and inspect actual filesystem contents.
5. Verify recursive deletion removes hidden contents but preserves linked sentinel contents.
6. Open a target document and an aliased descendant; verify deletion refusal.
7. Delete a final child and verify parent selection without changing editor document focus.
8. Check narrow prompts and resize before submission; verify refusal when the warning and input cannot fit.
9. Check search, jump, unfocused input, create, rename, navigation, and uppercase `R` behavior.
10. Inspect injected partial-failure and display-failure results through automated tests; verify truthful host error rendering with disposable failures where feasible.

## Requirement Coverage

- **FR-1:** Task 7, Task 8.
- **FR-2:** Task 1, Task 5, Task 7, Task 8.
- **FR-3:** Task 5, Task 7, Task 8.
- **FR-4:** Task 4.
- **FR-5:** Task 4, Task 8.
- **FR-6:** Task 2, Task 4, Task 7.
- **FR-7:** Task 3, Task 4, Task 5, Task 7, Task 8.
- **FR-8:** Task 2, Task 3, Task 4, Task 5.
- **FR-9:** Task 6, Task 7.
- **FR-10:** Task 4, Task 6, Task 7.
- **FR-11:** Task 6, Task 7, Task 8.
- **FR-12:** Task 1, Task 5, Task 7, Task 8.
- **NFR-1:** Task 2, Task 3, Task 4, Task 5.
- **NFR-2:** Task 4, Task 6, Task 8.
- **NFR-3:** Task 1, Task 5, Task 7, Task 8.
- **NFR-4:** Task 7, Task 8.
- **NFR-5:** Task 2, Task 3, Task 4, Task 8.
