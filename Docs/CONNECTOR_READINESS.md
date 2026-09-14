# Connector readiness, September 13, 2026

Telegram personal inbox coverage remains a release blocker. The implemented connector reads Hermes agent conversations, so a message sent to the person's Telegram account can be absent even when the archive command succeeds.

## Immediate fixes and verification

- Telegram archive results now report `status: partial`, `coverage: agent_session_archive`, and `errorCode: telegram_archive_only`. Existing daily report sections and completion checks consume this status, preventing an archive-only pass from claiming complete reconciliation.
- Malformed JSON, non-object rows, and rows without stable session/message identities are counted and skipped. Duplicate identities are removed. Null message IDs fall back to the export's stable prompt index.
- Optional `telegramArchiveDatabasePath` selects recent Telegram user-message session IDs from SQLite using read-only mode, `query_only`, schema checks, parameter binding, a five-second query budget, and a 50-session cap. Both active and ended sessions are eligible. Each selected session is then exported through the existing Hermes `--redact --only user-prompts` path. Only messages inside the lookback window are retained. This avoids exporting unrelated sources or bypassing the existing redactor.
- The archive export has a shared 120-second budget, 16 MB output cap, and 5,001-record cap. Reaching a cap is surfaced as truncation. The JSONL subprocess reader now enforces its deadline even when a child writes a partial line and stalls.
- Configured archive database errors remain visible. The collector does not silently revert to a less complete transport.
- A standalone offline connector diagnostic returns JSON for Telegram, Discord, email, and GitHub. It examines selected configuration fields and file metadata without launching helpers, reading credentials, logging account identities, authenticating, or accessing inboxes. The morning installer includes it.

Headless verification: 50 morning collector tests and 3 connector diagnostic tests passed. Coverage includes active-session selection, source and timestamp isolation, original database byte preservation, missing database protection, unsupported schema rejection, session limits, visible configured-reader failure, redacted per-session export, identity validation, deadline enforcement, and safe diagnostic output. Installer syntax and diff whitespace checks passed. No UI automation, live inbox collection, messages, login, or account changes were performed.

## Local findings and unresolved evidence

The configured Telegram executable is a wrapper for a Hermes profile. Its existing filtered export calls `list_prune_candidates`. In the installed Hermes implementation, that query requires `s.ended_at IS NOT NULL`, which excludes active agent sessions. This explains an additional source of omissions independently of the personal inbox limitation.

The local profile archive exists, but both Python SQLite `mode=ro` and the system SQLite CLI `-readonly` failed schema inspection with `unable to open database file` (SQLite code 14). No database modifications or repairs were attempted. The new active-session reader is implemented and tested with temporary databases, but it is not enabled in the user's ingestion settings or verified against that archive. The exact remaining prerequisite is a readable archive path for `telegramArchiveDatabasePath`; do not describe local active-session collection as verified until this succeeds. Do not use SQLite `immutable=1` as a shortcut on a live archive, because ignoring its write-ahead log could hide recent messages.

Telegram bots receive private messages addressed to the bot and eligible messages from groups the bot participates in. That scope does not include arbitrary personal chats. A complete inbox reader needs Telegram user authorization and paginated dialog/history retrieval. [Telegram bot visibility](https://core.telegram.org/bots/faq#what-messages-will-my-bot-get), [user authorization](https://core.telegram.org/api/auth), [dialog retrieval](https://core.telegram.org/method/messages.getDialogs).

The missed messages from Affaan were not read during this investigation. Their individual delivery or synchronization history remains unverified. The architecture establishes why those personal messages can fall outside the current collector.

## Swift integration contract

Run the packaged offline diagnostic through the existing controlled subprocess mechanism:

```sh
python3 focus_queue_connectors.py --config /path/to/ingestion.json
```

Its version-1 JSON has `mode`, `authenticationVerified`, and `connectors`. Each connector contains `id`, `status`, `coverage`, `accountSwitchSupported`, and `nextStep`. Telegram also includes `personalInboxSupported` and `activeArchiveConfigured`. Diagnostic statuses are `setup_required`, `limited`, and `configured_unverified`. These describe offline readiness only. Invalid configuration returns exit code 1 and `errorCode: invalid_connector_config`, without echoing input or parser exceptions.

Use a Connectors settings surface that displays selected account, actual collection scope, last verified sync, last error, and Connect/Reconnect/Switch account/Disconnect actions. Keep offline configuration separate from a completed authentication check. Surface archive-only Telegram coverage and incomplete daily report status in the app immediately.

Future collector output should standardize `accountId`, `scope`, `lastAttemptAt`, `lastSuccessAt`, `cursor`, `truncated`, and structured error codes across providers. Persisted message identities and cursors must include the provider account identity before switching accounts can ship.

## Production gates

| Priority | Work | Acceptance evidence |
| --- | --- | --- |
| P0 | Telegram user-account adapter with explicit login and 2FA | Messages from personal chats, archived chats, and groups appear with the correct author, exact message link where supported, account identity, and timestamp; pagination reaches the selected cutoff |
| P0 | Connector account lifecycle and Keychain-backed credentials | New user can connect, switch, revoke, and reconnect; old-account cursors and cached content stay isolated; canceled login preserves prior configuration |
| P0 | Transactional setup | Validate a staged account before replacing the active configuration; retain a recoverable previous version; never overwrite unrelated user settings |
| P0 | Collection completeness and privacy | Fixture tests cover multiple accounts, deleted or expired credentials, permission loss, rate limits, partial pages, duplicates, edits, empty inboxes, and stale syncs; no credentials appear in reports or logs |
| P1 | Incremental ingestion | Per-account and per-dialog cursors, bounded retries, overlap for clock skew, deduplication, and visible backlog prevent high-volume sources from silently starving older messages |
| P1 | Deployment portability | Remove personal absolute paths and Homebrew-only assumptions from connector installation and executable discovery; verify a clean macOS account with stock system tools |
| P1 | Low-cost setup | Deterministic capability detection and connection checks work without spending agent tokens; agent assistance is optional and limited to explaining failures |

An actual Telegram account installation wizard and authenticated personal inbox adapter remain to be implemented. The diagnostic is infrastructure for that wizard, rather than a completed account connector. Login, code entry, and selection of the account belong in an explicit user-controlled flow.
