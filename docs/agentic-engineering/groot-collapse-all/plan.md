---
schema_version: 1
artifact: implementation-plan
subject: "groot-collapse-all"
status: validated
spec: "spec.md"
spec_sha256: "ba400d35c5a172471a6e2975a020ce4fa9b11529b644fd0a47ed8368e7a34075"
repository_baseline: "66878c8"
working_tree: "Untracked docs/agentic-engineering/groot-collapse-all/ planning artifacts only"
created: "2026-09-14"
updated: "2026-09-14"
---

# Groot Collapse All Implementation Plan

Before execution, verify `spec_sha256` and its upstream `intent_sha256` against their files; stop on a mismatch. Execution state belongs to the implementer.

Preserve approved behavior, required contract signatures, invariants, and architecture. Choose private helpers, class structure, and incidental wiring within those constraints. Illustrative skeletons are optional; a required internal contract remains binding. Check existing code, standard libraries, native capabilities, and installed dependencies before adding an abstraction or dependency. Justify additions through a present requirement and why existing options are insufficient.

For consequential deviations, invoke `sdlc` with this plan path to apply its shared correction rule before dependent work. Reopen the earliest affected approval, then reassess later approvals. Private structural changes within approved constraints require verification, without a design approval round.

## Repository Findings

- `groot.scm` exports public Helix commands as provided Scheme functions.
- `groot-core.scm:GrootState` already owns every field that this command resets or preserves.
- `groot-integration.scm:groot-refresh-effects!` provides the nearest dependency-injected effect pattern.
- `groot.scm:groot-refresh` clears caches, so this command cannot reuse it.
- `groot.scm:groot-post-command-sync!` currently synchronizes after every non-teardown command.
- `tests/integration-test.scm` exercises integration effects without Helix.
- `tests/run.scm` already loads the integration test suite.
- `README.md` documents public command invocation and explorer behavior.
- No command, collapse effect, regression test, or documentation exists for `groot-collapse-all`.

## Tasks

### Task 1: Collapse Effects Reset Only Approved Active State

- **Requirements:** FR-1, FR-2, FR-3, FR-4, FR-5, FR-6, FR-8, NFR-1
- **Entry point:** `groot-integration.scm:groot-collapse-all-effects!`
- **Depends on:** none
- **RED:** Add integration tests that seed every affected state group and record callbacks. Run `steel tests/run.scm`; expect the missing effect to fail.
- **GREEN:** Implement the required effect signature. Guard inactive state, reset approved fields, then call rebuild and redraw once in order.
- **REFACTOR:** Reuse `groot-state-ref` and `groot-state-set!`. Remove duplication only when the tests remain readable.
- **Verification:** Run `steel tests/run.scm`. Observe active reset, preserved fields, callback order, inactive no-op, and a successful exit.

Trace downstream from the entry point before editing. Preserve the required return outcomes and avoid new dependencies.

### Task 2: Public Command Restores the Tree Without Immediate Reveal

- **Requirements:** FR-1, FR-2, FR-3, FR-4, FR-5, FR-6, FR-7, FR-8, NFR-1
- **Entry point:** `groot.scm:groot-collapse-all`
- **Depends on:** Task 1
- **RED:** Load the current plugin in Helix and invoke `:groot-collapse-all`; expect an unknown command and no restored tree.
- **GREEN:** Export and wire the command. Skip only its immediate post-command synchronization. Document its invocation and behavior in `README.md`.
- **REFACTOR:** Keep one direct command-name condition. Reuse existing rebuild, redraw, normalization, and integration functions.
- **Verification:** Run `steel tests/run.scm` and observe success. Invoke the command before opening Groot and observe no error. Open Groot, expand nested directories, start search, and invoke the command. Observe direct root children, root selection, top viewport, no query, and no immediate reveal.

Trace downstream from the entry point through public export, post-command handling, and user documentation. Add no keyboard binding or refresh call.
