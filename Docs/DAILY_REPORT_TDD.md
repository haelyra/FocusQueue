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

## Reliability hardening, 2026-09-09

### User journeys and failure causes

| Journey | Failure reproduced | Preventive contract |
| --- | --- | --- |
| Check Mail from Queue chat or the report worker | The Python client waited in `connector-proofs`, while the installed helper watched legacy `ingestion`; direct database access made this intermittent | Separate canonical command and helper-only proof directories, always refresh the helper during install, replace stale helper processes, and preserve structured errors |
| Collect more than one Mail page | The JXA helper ignored `offset`, so repeated first pages could run until the 15-minute report timeout or silently omit mail | Offset-aware sorted pages, stable-key progress checks, duplicate rejection, and a 5,000-message bound |
| Run the comprehensive report after a Codex CLI patch update | The classifier accepted only `codex-cli 0.153.0`, while the installed CLI was `0.153.4` | Pin `gpt-5.2`, disable every advertised feature, and inspect the complete loopback outbound request to require the exact recognized schema and an effective zero-tool manifest before inference |
| Recover from a transient classifier or source failure | Semantic validation was outside the retry and partial reports counted as complete | Retry classify plus semantic validation, discard invalid cached proposals, persist unsuccessful attempts, and retry them automatically every 15 minutes until success |
| Understand a failure safely | The app displayed only an exit code, or could expose raw multiline worker output | Allowlisted actionable UI guidance, private raw logs, structured Mail error codes, and visible warning state |

### RED evidence

- Swift compilation failed because failed-run retry state and schedule eligibility did not exist.
- The partial-report regression reused a same-day partial receipt instead of running again.
- Mail path, pagination, stale-helper, nonzero structured-error, and taxonomy tests failed against the old contracts.
- The installed Codex patch release was rejected, and the first dynamic harness still exposed effective tools despite disabling feature flags.
- The multiline worker diagnostic regression produced an unsafe or meaningless final-line message.

### GREEN and sanity evidence

- 71 Python tests pass, including helper IPC, pagination, bounded and accurately reported scoped collection, exact fallback-process cleanup, error taxonomy, complete classifier retries, and zero-tool manifest validation.
- 70 Swift tests pass, including failed-run scheduling, partial eligibility, operation-bound Mail receipts, safe daily-report and Queue-chat process presentation, and Queue Mail timeout behavior.
- A live no-inference preflight against `codex-cli 0.153.4` disabled 135 advertised features and captured `tools=[]` with no `additional_tools` input.
- The installed Mail helper passed three consecutive verified status calls, returned distinct offset pages, and an installed email-only collection completed with five messages and no false warnings for skipped sources.
- The installed Python workers match the repository copies, IPC files are `0600`, the helper signature verifies, and independent code and security gates pass with no blocker.
- Native JXA compilation and signature verification pass.
- Python compilation, Node syntax, zsh syntax, and `git diff --check` pass.
- Standard-library Python tracing reports 100% statement coverage for the three changed production modules. LLVM line coverage is 84.81% across the changed/testable Swift core files: `Integrations.swift` 85.55%, `Models.swift` 82.60%, and `MorningRunPolicy.swift` 100%.

UI automation remains skipped because `ECC_FOCUS_QUEUE_UI_TESTS=1` was not set. The app and helper are verified through headless builds, process checks, persisted-state checks, and connector calls.
