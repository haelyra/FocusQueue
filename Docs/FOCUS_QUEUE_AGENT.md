# Focus Queue Agent

The ECC Focus Queue manager runs as a persistent Codex thread named
`ecc-focus-queue-codex-v1`. The Focus Queue app invokes it through the bounded
local `/Users/hira/.local/bin/focus-queue-codex` harness. Mail and Discord are
exposed through narrow read-only commands with private evidence receipts. Codex
never receives those source credentials in its prompt or connector output.

## Morning reconciliation

The always-running `ECC Focus Queue.app` checks every five minutes and runs the
morning reconciliation after 8:00 AM local time when today's successful
checkpoint is absent. It launches an installed automation copy from Application
Support so protected Documents access uses the already-approved Focus Queue app.
The former standalone morning LaunchAgent and Hermes cron job are paused.

```text
Discord + Telegram + Apple Mail + GitHub
                  |
          read-only collection
                  |
        tool-restricted classification
                  |
       schema validation and deduplication
                  |
       canonical dashboard + full checks
```

The first run scans seven days. After a successful run, a private checkpoint
reduces subsequent scans to the interval since the prior success with a
12-hour overlap. Source and proposal artifacts are mode `0600` under
`~/Library/Application Support/ECC Focus Queue/ingestion/`.

## Source coverage

### Discord

The collector and interactive Codex agent read the ECC server through
`/Users/hira/.local/bin/focus-discord`. The connector owns the bot credential in
the mode-`0600` ECC private store, scans every bot-visible text and announcement
channel plus active threads, and returns nonce-backed evidence. It never posts,
reacts, changes roles, or edits messages. Interactive commands are `status`,
`channels`, `search`, and `read`.

The `moderator-only` channel currently denies the bot access. Grant the Kairos
bot **View Channel** and **Read Message History** in that channel if it should
be included in whole-server ingestion. Message Content intent must remain
enabled in the Discord Developer Portal.

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

`haley@ecc.tools` is read through its already-authenticated iCloud account in
Apple Mail. The collector includes Inbox, Junk, Archive, and Deleted Messages,
filters every result for the ECC address, and never marks mail read, moves,
deletes, drafts, or sends messages. Drafts, Sent, Outbox, and Notes are excluded
because they are not inbound requests. It first reads Mail's synchronized local
store in read-only mode. macOS denies that protected directory to background
processes, so the scheduled path falls back to the installed
`/Users/hira/Applications/ECC Focus Mail Reader.app`, which has a stable,
separate macOS privacy identity and writes a private local snapshot by invoking
the same read-only collector.
No email password or session token is copied into Codex.

#### Interactive Queue mail

Queue chat uses the same permission-stable reader through the local
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
interval. An inaccessible Discord channel is handled the same way.

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

Inspect the scheduled job:

```bash
launchctl print gui/$(id -u)/com.haelyra.ecc-focus-queue-morning
tail -100 "$HOME/Library/Application Support/ECC Focus Queue/morning.stdout.log"
```

Rebuild the permission-stable Mail reader after changing its source:

```bash
Scripts/install-mail-reader.sh
```

The Queue manager, completion verifier, Discord connector, mail connector, and
morning classifier no longer depend on a Hermes agent. The optional Hermes
gateway remains running only if Telegram transport is still desired.
