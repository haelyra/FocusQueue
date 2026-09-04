# Daily Message Report TDD Record

Date: 2026-09-03

## Scope

This record covers the interactive daily report, missed-schedule approval,
platform-scoped chat dispatch, message deduplication, exact token accounting,
portable worker state, and crash-safe dashboard/report commits.

## RED evidence

The implementation was driven by failing or missing regression cases for:

- missed runs versus the normal polling grace, including launch or wake after
  the scheduled instant;
- report persistence, exact platform scope, report history, and approval state;
- deterministic source-key deduplication and explicit recheck semantics;
- negated, unsupported, and mixed-platform chat commands;
- token-budget deferral using the full serialized message envelope;
- Discord and GitHub pagination past a single source page;
- full Mail fallback pagination;
- process-tree cleanup after timeout or cancellation;
- crash recovery before dashboard apply, after atomic replace, and before
  report/ledger publication;
- trusted source-link binding, proposal redaction, and source-driven priority
  limits;
- report panel anchoring on both screen edges.

During the final hardening pass, the full Python suite exposed one expected
failure when budget accounting changed from message text only to the complete
serialized envelope. The fixture was updated to assert the same newest-first
deferral behavior at the correct byte allowance. A sanitizer regression also
exposed that bare `Token:` values were not redacted; the redaction rule was
expanded before the suite returned green.

## GREEN evidence

The final headless verification completed successfully:

- `python3 -m py_compile` for all report, mail, Discord, lock, and Codex worker
  scripts;
- 39 Python unit tests in the isolated feature snapshot;
- 51 Swift tests in the isolated feature snapshot;
- Swift debug package build;
- JSON parsing for the proposal schema and both configuration examples;
- zsh syntax checks for the installer scripts;
- `git diff --check`.

UI automation was intentionally skipped because
`ECC_FOCUS_QUEUE_UI_TESTS=1` was not set. This follows the repository safety
policy. Window expansion and anchoring are covered by deterministic geometry
tests, and the installed app is verified headlessly.

## Design result

The report worker, schedule state, approval contract, report documents, and
deduplication ledger are Python and JSON so a future Windows host can reuse
them. Swift is limited to the current macOS window, local notification bridge,
wake detection, and app lifecycle. The current build delivers approval actions
to the Mac. Phone delivery remains an integration point because no phone push
provider or companion client has been selected.

The configured token value is a conservative consumption target, not a hard
server-side cutoff. Codex reports exact usage only after its turn completes, so
the worker defers input before the call, records exact observed usage, and adds
an explicit overage warning if the final total exceeds the target.
