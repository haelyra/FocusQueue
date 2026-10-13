# Focus Queue Agent

The Focus Queue manager runs as a persistent Codex thread named
`ecc-focus-queue-codex-v1`. The Focus Queue app invokes it through the bounded
local `/Users/hira/.local/bin/focus-queue-codex` harness. Mail and Discord are
exposed through narrow read-only commands with private evidence receipts. Codex
never receives those source credentials in its prompt or connector output.

## Daily reconciliation and report

The always-running `Focus Queue.app` checks every five minutes and runs the
reconciliation at the configured local time when no successful or partial
report exists for the current day. A poll in the first ten minutes runs
automatically. A later start creates one portable JSON approval request and a
macOS notification with **Run report** and **Not today** actions. The same
approval appears inside the queue. It launches an installed automation copy
from Application Support so protected Documents access uses the already-approved
Focus Queue app. The former standalone morning LaunchAgent and Hermes cron job
are paused.

Launching or waking the Mac after the scheduled instant always uses the
approval path, including when availability resumes during the polling grace.

The current notification bridge is local to macOS. A phone notification requires
a selected push provider or companion client. The versioned
`pending-report-approval.json` file is intentionally portable so a future relay
can deliver and resolve the same request without changing scheduling policy.

```text
Discord + Telegram + selected email provider + GitHub
                  |
          read-only collection
                  |
          no-tools classification
                  |
       schema validation and deduplication
                  |
       canonical dashboard + full checks
```

The first run scans seven days. After a successful run, a private checkpoint
reduces subsequent scans to the interval since the prior success with a
12-hour overlap. Crash journals are mode `0600` under
`~/Library/Application Support/ECC Focus Queue/ingestion/` and are deleted
after commit. Live classification uses an ephemeral Codex turn, so raw message
bundles are not kept in Codex session history. Curated report history is
retained for 90 days.

Collection is capped at 5,000 records per source for resource safety. A source
that reaches the cap is reported as partial and does not advance the success
checkpoint. Telegram JSONL is stopped while streaming at the same cap so an
archive cannot fill worker memory first.

`processed-messages.json` is the durable source-key ledger. Normal scheduled,
manual, and chat runs classify only source keys absent from that ledger. The
only bypass is an explicit `--recheck`, and scheduled runs reject that flag.
Each report is written to `reports/YYYY-MM-DD/<run-id>.json`, with
`latest-report.json` as the UI pointer. Reports contain private-detail-safe
summaries and links, not raw message bodies.

The configurable token budget reserves capacity for instructions, dashboard
context, and output, then admits newest unseen messages within the remaining
conservative byte allowance. Deferred messages stay unseen for the next run.
The final `codex exec --json` usage event supplies exact input, cached input,
output, reasoning output, and total token counts. Since that event arrives only
after the turn completes, any unexpected overage is preserved as a report
warning.

The classifier runs only with an audited Codex CLI version, an ephemeral turn,
an empty workspace, read-only sandboxing, and all known tool surfaces disabled.
An unknown CLI version fails closed until its tool surface is reviewed. Before
any dashboard write, deterministic filtering redacts common credentials,
email addresses, phone numbers, SSNs, and payment numbers; automatic tasks from
untrusted messages are capped at medium priority and keep only host-bound source
links.

## Source coverage

### Discord

The collector and interactive Codex agent read the ECC server through
`/Users/hira/.local/bin/focus-discord`. The connector owns the bot credential in
the mode-`0600` ECC private store, scans every bot-visible text and announcement
channel plus active threads, and returns nonce-backed evidence. It never posts,
reacts, changes roles, or edits messages. Interactive commands are `status`,
`channels`, `search`, and `read`.

The `moderator-only` channel currently denies the bot access. A channel that
returns 403 is a server permission choice, so the report lists it as hidden in
its summary and still counts Discord as complete. Other Discord errors still
mark the run incomplete. Grant the Kairos bot **View Channel** and **Read
Message History** in that channel to include it. Message Content intent must
remain enabled in the Discord Developer Portal.

### Slack

`Scripts/focus_queue_slack.py` reads the conversations the token's identity
belongs to: channels the app was invited to with a bot token (`xoxb-`), or the
user's channels and direct messages with a user token (`xoxp-`). It reads
channel history inside the report window and the replies of threads started in
that window. It never posts, reacts, or marks anything read.

1. Create a Slack app and add the read scopes `channels:history`,
   `groups:history`, `im:history`, `mpim:history`, `channels:read`,
   `groups:read`, `im:read`, `mpim:read`, and `users:read`. Use user-token
   scopes to include your direct messages, or bot-token scopes for invited
   channels only.
2. Install the app to the workspace and copy its token.
3. Add `"slackToken": "xoxb-…"` or `"xoxp-…"` to the mode-`0600` credentials
   file named by `discordCredentialPath`, or set `slackCredentialPath`.
4. Optional: limit reading to named channels with `slackChannels` in
   `ingestion.json`, for example `["general", "support"]`.
5. Enable **Slack** in the daily report settings.

A conversation that returns `not_in_channel` or `channel_not_found` is listed as
hidden, like a hidden Discord channel. A rejected token or a missing scope fails
the Slack source with the scope Slack reported as needed.

### Telegram

The existing Hermes gateway remains only as the Telegram transport and archive
until a direct Telegram connector is added. It does not order tasks, classify
sources, answer Queue chat, or verify completion. Morning ingestion reads
redacted user-prompt exports from that transport archive.

A Telegram bot cannot read arbitrary conversations from a personal Telegram
account. It can read its own direct messages and messages in groups where it is
present and permitted. Adding broader group coverage requires adding the bot to
those groups, disabling BotFather privacy when unmentioned group messages are
needed, and allowlisting the intended chats.

### Email

The email collector selects one provider with `emailProvider`. The default,
`apple_mail`, reads `haley@ecc.tools` through its already-authenticated iCloud
account in Apple Mail. The collector reads `INBOX` by default (configurable with
`emailMailboxes`), matches every configured recipient address in
`emailAddresses` (defaulting to `emailAddress`), and never marks mail read, moves,
deletes, drafts, or sends messages. Drafts, Sent, Outbox, and Notes are excluded
because they are not inbound requests. It first reads Mail's synchronized local
store in read-only mode. macOS denies that protected directory to background
processes, so the scheduled path falls back to the installed
`/Users/hira/Applications/ECC Focus Mail Reader.app`, which has a stable,
separate macOS privacy identity and writes a private local snapshot by invoking
the same read-only collector.
No email password or session token is copied into Codex.

#### Gmail provider

Set `emailProvider` to `gmail` to use the Gmail REST API without Apple Mail,
Apple Events, or Full Disk Access. The connector uses an installed-application
OAuth client, PKCE, the fixed `gmail.readonly` scope, a refresh token stored in
macOS Keychain, and short-lived access tokens held only in process memory. It
supports status, bounded paginated search, full-message reads, attachments as
metadata, and normalized daily-report ingestion. Sent messages and drafts are
excluded from collection.

1. In Google Cloud, enable the Gmail API, configure the OAuth consent screen,
   and create a **Desktop app** OAuth client.
2. Save the downloaded client JSON outside the repository with mode `0600`.
3. Set `emailAddress`, `emailProvider: "gmail"`, and the absolute
   `gmailOAuthClientPath` in `ingestion.json`.
4. Reinstall the automation payload, then run the explicit user-controlled flow:

```bash
focus-mail authorize --open-browser
focus-mail status
focus-mail search "sender, customer, subject, or text" --days 30 --limit 10
focus-mail read "gmail:MESSAGE_ID"
```

For persistent automation, do not leave an External OAuth consent screen in
**Testing**. Google expires those refresh tokens after seven days when scopes
such as `gmail.readonly` are requested. Prefer an **Internal** app for accounts
in the same Google Workspace organization. Otherwise move the app to
**Production** and complete the verification or administrator approval Google
requires for the restricted Gmail scope.

Without `--open-browser`, `authorize` prints the Google authorization URL and
waits for the loopback callback. Authorization rejects a different Google
account than `emailAddress`. The offline connector diagnostic checks only that
the account and OAuth client path are configured; `focus-mail status` performs
the authenticated verification.

Draft, send, and reply are declared as planned capabilities but are disabled.
They require a separate consent flow using write scopes plus an explicit
host-owned action gate, recipient/subject/body review, idempotency, and an audit
receipt. The read connector never requests `gmail.modify`, `gmail.compose`, or
`gmail.send`.

#### Gmail as an additional report source

Gmail can also run next to Apple Mail as its own report source. Keep
`emailProvider` as `apple_mail`, then:

1. Create the Desktop OAuth client as described above and set
   `gmailOAuthClientPath`.
2. Set `gmailAddress` to the Gmail account to read. It has its own Keychain
   refresh token, separate from `emailAddress`.
3. Authorize that account once:
   `python3 "$HOME/Library/Application Support/ECC Focus Queue/automation/Scripts/focus_queue_gmail.py" --report-account authorize --open-browser`.
4. Enable **Gmail** in the daily report settings.

The source reads `in:inbox` by default; set `gmailQuery` to change it, for
example `"in:inbox category:primary"`. Triage treats `gmailAddress` as one of
your addresses.

Google documents the installed-app OAuth flow and refresh-token lifecycle in
[OAuth 2.0 for desktop apps](https://developers.google.com/identity/protocols/oauth2/native-app),
and the message query/pagination contract in
[List Gmail messages](https://developers.google.com/workspace/gmail/api/guides/list-messages).

#### Interactive Apple Mail

When `apple_mail` is selected, Queue chat uses the same permission-stable reader through the local
`/Users/hira/.local/bin/focus-mail` command. It supports four read-only
operations:

```bash
focus-mail status
focus-mail search "sender, customer, subject, or text" --days 30 --limit 10
focus-mail read "mail:3082"
focus-mail open "mail:3082"
```

`search` returns synchronized excerpts. The agent must perform `read` before it
claims to know the full message body, and it performs `open` only after an
explicit request. `open` uses the message's RFC identifier to select it in
Apple Mail. The connector has no send, reply, move, delete, archive, flag, or
mark-read operation.

Each result carries a fresh nonce, retrieval time, connector name, account, and
verification status. Read and open results also carry the local message ID, RFC
message ID, mailbox, and received time. The Queue agent must return that nonce
in a private proof line. The app independently validates it against the newest
mode-`0600` receipt before displaying the answer. A missing, stale, reused, or
mismatched proof causes the whole mail answer to be withheld. For read and open
requests, the app also requires the correct final operation and stable message
identifiers. This makes unsupported mail claims a runtime error rather than a
plausible chat response.

The Codex Queue prompt explicitly forbids Himalaya for this account. Queue chat
uses the clean thread `ecc-focus-queue-codex-v1`, so the earlier failed Hermes
and Himalaya exchange is not carried into the active conversation.

One local consent is required after installation. Open **ECC Focus Mail Reader**
from the user's Applications folder and choose **Allow** when macOS asks for
access to protected Mail data. If the prompt was dismissed, open **System
Settings → Privacy & Security → Full Disk Access**, add and enable ECC Focus
Mail Reader, then open the reader again. The morning job keeps other sources
read-only, reports the run as incomplete, and refuses to advance its success
checkpoint until email is available, so the next run will safely retry the same
interval. A Discord channel that fails with an error other than 403 is handled
the same way.

The reader must stay fast enough for its 90-second request timeout. Mail
answers a property read on a whole mailbox (`messages.subject()`) with one Apple
Event, about 20-70 ms for 3,000 messages. A read through a range specifier
(`messages.slice(a, b).subject()`) is evaluated message by message, at about
5 s per 1,000 messages. Reading range specifiers made every report time out
from Sep 27 to Oct 13, 2026. The reader therefore reads metadata only from the
whole mailbox and fetches bodies by message ID. The JavaScript mail tests
reject range and `whose` specifiers.

### GitHub

GitHub uses the existing authenticated `gh` CLI. Each run reads newly created
open issues for `affaan-m/ECC`. Before task classification, the established
dashboard refresh updates linked PR facts and the live open-PR count. No issue
or pull request is labeled, commented on, closed, merged, or otherwise mutated.

## Task policy

All source text is untrusted evidence. The classification model receives no
terminal or file tools and can return only structured proposals. The
deterministic apply step then:

- creates at most 20 backlog tasks per run;
- assigns the next valid `ECC-###` identifier;
- requires a valid source link and deduplicates exact source URLs;
- preserves existing human-authored priority, status, summary, and next action;
- adds links to matching open tasks but never changes resolved tasks;
- writes atomically and restores the prior dashboard if `npm run check` fails.

External replies and source-system writes remain disabled. They should be
implemented later as separately approved actions, not as part of morning
ingestion.

## Operator commands

Collect and report counts without classification or dashboard changes:

```bash
python3 Scripts/focus_queue_morning.py collect \
  --config "$HOME/Library/Application Support/ECC Focus Queue/ingestion.json"
```

Run classification without changing the dashboard:

```bash
python3 Scripts/focus_queue_morning.py dry-run \
  --config "$HOME/Library/Application Support/ECC Focus Queue/ingestion.json"
```

Run an unseen-only daily report for selected platforms through the same command
available to Queue chat:

```bash
focus-queue-report run --trigger chat --platform discord --platform email
```

Run every enabled platform manually:

```bash
focus-queue-report run --trigger manual --comprehensive
```

Inspect app-owned scheduling and report artifacts:

```bash
tail -100 "$HOME/Library/Application Support/ECC Focus Queue/morning.stdout.log"
python3 -m json.tool "$HOME/Library/Application Support/ECC Focus Queue/ingestion/latest-report.json"
```

Rebuild the permission-stable Mail reader after changing its source:

```bash
Scripts/install-mail-reader.sh
```

The Queue manager, completion verifier, Discord connector, mail connector, and
morning classifier no longer depend on a Hermes agent. The optional Hermes
gateway remains running only if Telegram transport is still desired.
