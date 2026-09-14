# Personal Telegram account adapter design

TL;DR: Build an isolated TDLib reader with a native account setup flow, encrypted account storage, complete main/archive pagination, and exact local message receipts. Automatic AI processing needs a separately established permitted basis; connecting an inbox does not establish that basis for every sender. This is a reviewed implementation proposal with an executable offline contract, not a deployed connector.

Research date: September 13, 2026. All provider and platform references below are primary sources. No packages, accounts, source implementations, or live messages were changed during this design work.

Contents: [Client choice](#tdlib-fits-the-shipping-macos-app), [Account lifecycle](#login-is-a-staged-native-flow), [Secret storage](#each-account-has-its-own-encrypted-storage), [Collection](#main-and-archived-chats-have-independent-completion), [Trust boundary](#receipts-preserve-evidence-without-authorizing-ai-use), [Budgets](#limits-defer-work-with-visible-progress), [Switching](#switching-and-disconnection-preserve-a-recoverable-state), [Fixture](#the-offline-contract-is-executable), [Acceptance](#acceptance-tests-reproduce-the-missed-private-message), [Decisions](#decisions-before-live-implementation).

## TDLib fits the shipping macOS app

| Choice | Fit | Cost and decision |
| --- | --- | --- |
| Official TDLib through its C JSON interface | Native Swift bridge, supported desktop/mobile platforms, ordered updates and encrypted database support | Recommended. Bundle a pinned, signed build rather than relying on a user's Homebrew installation. Measure package size and idle resource use before enabling startup collection. |
| Telethon stable Python client | Fits the current Python collector and provides dialog/history iterators | Viable prototype alternative. Adds Python packaging and custom secure session persistence. Pin a tested stable release, rather than mixing stable and v2 alpha examples. |
| Implement MTProto directly | Maximum protocol control | Reject for this release. Adds authorization, encryption, update consistency, and migration maintenance that TDLib already owns. |
| Telegram Bot API or Hermes archive | Reuses existing integration | Retain as explicitly limited transports. Neither establishes access to a person's ordinary private inbox. |

TDLib exposes a C JSON interface and supports macOS, iOS, Windows, and Linux. The JSON binary interface and the underlying API schema have different compatibility guarantees, so ship the matching schema with a pinned build. TDLib's library license is Boost; audit the shipped dependency notices separately. [TDLib maintainer documentation](https://github.com/tdlib/td/blob/master/README.md), [TDLib license](https://github.com/tdlib/td/blob/master/LICENSE_1_0.txt).

Telethon's session stores authorization material, and its default store is SQLite. Its documented dialog iterator supports explicit archived and non-archived scopes. A Python spike would therefore use a reviewed custom session implementation and the same receipt contract described below. [Telethon sessions](https://docs.telethon.dev/en/stable/concepts/sessions.html), [Telethon dialog iterator](https://docs.telethon.dev/en/stable/modules/client.html#telethon.client.dialogs.DialogMethods.iter_dialogs).

Proposed components: a Swift `TelegramAccountCoordinator` owns configuration and lifecycle; a signed `TelegramReaderService` wraps TDLib behind typed operations; a `TelegramReceiptStore` owns encrypted local receipts, collection state, and eligibility; existing report ingestion requests eligible receipts through this service. The agent-facing interface never exposes generic TDLib JSON, Keychain reads, login codes, or outbound messaging methods. The transport is replaceable without changing account identities or report receipts.

## Login is a staged native flow

The product owner registers the application and supplies its own application API ID/hash. These identify the application and differ from a bot token or a user's session authorization. End users should not need to create developer applications for the normal setup flow. [Application registration requirements](https://core.telegram.org/api/obtaining_api_id).

1. Connect creates a pending connection UUID and private temporary account directory. The active account remains untouched.
2. The service receives `authorizationStateWaitTdlibParameters`, initializes the pinned build, and waits for state updates. Do not assume a fixed phone-code-password sequence.
3. Native secure fields handle phone number, verification code, optional email/email code, and 2FA password when the corresponding state requests them. Support an explicit unsupported-state result for newly introduced authorization challenges. Account registration is out of first-release scope and directs the user to the official app.
4. Secrets move over the app's authenticated local IPC channel, never command arguments, environment variables, logs, task evidence, or agent prompts. Retain verification codes/passwords only for the current request. Cancellation clears pending memory and state.
5. `authorizationStateReady` is followed by `getMe`. Bind the immutable provider user ID and production/test environment to this pending connection. Reject an unexpected identity; show the selected account to the user before activation.
6. Perform a bounded read-only scope probe. Show account, selected chat scope, coverage limitations, and AI eligibility separately. Activate by a local transaction only after the setup flow's final Connect action.

TDLib drives authorization using asynchronous state changes, including phone, email, code, and password states. The application supplies initialization parameters and reacts to updates. [TDLib authorization lifecycle](https://core.telegram.org/tdlib/getting-started#user-authorization).

Unknown state, expired code, wrong password, denied Keychain access, revoked authorization, and canceled setup each have distinct retryable or terminal UI states. Resending a code is an explicit user action subject to the provider's timing; background collection never triggers fresh login attempts.

## Each account has its own encrypted storage

Configuration stores only an account record and opaque secret reference:

```json
{
  "version": 1,
  "provider": "telegram",
  "environment": "production",
  "accountKey": "telegram:production:10001",
  "connectionId": "connection-uuid",
  "generation": 4,
  "secretRef": "connection-uuid:database-key",
  "scope": {"lists": ["main", "archive"], "types": ["private"], "lookbackHours": 168},
  "aiPolicy": "blocked_pending_basis"
}
```

Store a random per-connection TDLib database key as a generic-password Keychain item under a fixed app-owned service name and the opaque connection UUID. Use Security.framework off the main thread, `SecItemAdd` for first creation, explicit update for rotation, and no replace-on-error behavior. The app resolves the secret reference internally; receipt consumers cannot turn arbitrary strings into Keychain queries. [Apple Keychain insertion and ownership](https://developer.apple.com/documentation/security/secitemadd(_:_:)).

Use the macOS data protection Keychain for the signed app/service, with the narrow required access group. A proposed background mode uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; an unlocked-only mode instead pauses when the key is unavailable. Validate both on the actual signed macOS distribution, including reboot and upgrade, rather than extrapolating from iOS behavior. [Apple background item accessibility](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly), [data protection Keychain selector](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain).

The reader passes a nonempty random encryption key to `setTdlibParameters`, a private account-specific database directory, and `use_secret_chats=false`. Retain the message database for consistent restart handling. Do not expose raw session export. TDLib explicitly accepts the database encryption key and cache/secret-chat flags. [TDLib initialization contract](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1set_tdlib_parameters.html).

Set account directories to mode 0700 and application-owned artifacts to 0600. Keep attachments disabled initially; encrypted TDLib databases do not automatically guarantee that separately downloaded files are encrypted. Receipt previews and normalized content require their own encrypted storage or a proven shared encrypted store. The product retention default is seven days of message previews, with longer-lived minimal source identities only where needed for user-retained tasks. Removed or expired source content must also expire from receipts and derived previews.

## Main and archived chats have independent completion

"Active chat" means an ordinary current Telegram conversation, not an active Hermes agent session. Discovery must never depend on bot participation, contacts membership, unread count, mentions, folder visibility, or whether an agent conversation has ended.

Maintain TDLib's ordered update stream and chat cache. Load `chatListMain` and `chatListArchive` independently with `loadChats(limit=100)` until each returns its documented end-of-list 404. A short batch does not mean complete. Custom folders are views over chats; deduplicate their membership rather than treating a user's currently selected folder as the inbox. [Chat-list pagination](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1load_chats.html).

The first release's reviewable default is cloud private chats from both lists, with groups enabled by explicit scope selection and channels deferred. Label it "Private chats, including archived". Secret chats from other devices are outside this scope. TDLib describes secret chats as device-specific and distinguishes main, archive, and folder lists. [TDLib chat model](https://core.telegram.org/tdlib/getting-started).

For every eligible dialog, start `getChatHistory` at zero with `offset=0`, `limit=100`, `only_local=false`. Continue from the oldest returned message ID, deduplicating the repeated boundary item. If a page makes no progress, record an incomplete cursor and retry within budget; never loop forever or label that dialog complete. Continue until the requested cutoff is crossed or an authoritative empty history response is received. A short page alone is insufficient. [History pagination parameters](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1get_chat_history.html).

Use string-encoded identifiers across IPC and JSON. Primary identity is `(provider, environment, providerUserId, chatId, messageId)`. Store TDLib message IDs without converting them to Bot API IDs or inventing URL IDs. Deduplication is stable across profile changes, usernames, and phone-number changes. Treat edited content as a new revision of that identity using `edit_date` plus a content digest. Keep source timestamp, receipt timestamp, and last classified revision separate.

Collection state is keyed by account and dialog. Keep `newestObserved`, `oldestCovered`, a pending page anchor, and the interval verified complete. Commit receipts and page progress atomically before acknowledging the page. The report ledger advances only after report handling is durably recorded, independently of collection progress. On restart, replay a small overlap and consume TDLib updates; periodically revisit the configured lookback to catch edits and recovery gaps. A completed account sweep requires both list enumerations and all included dialogs to be complete through the run's fixed cutoff.

## Receipts preserve evidence without authorizing AI use

Telegram's current API terms explicitly cover AI use, and its content terms describe possible exceptions involving all relevant users' continued, context-specific consent. This is a material product constraint. Broad account-login consent is not demonstrated permission to send every correspondent's messages to an AI system. The specific legal applicability and permitted basis need a product/legal determination before that handoff ships. [Telegram API terms §1.5](https://core.telegram.org/api/terms), [content licensing and AI exceptions](https://telegram.org/tos/content-licensing).

Keep `aiEligibility=blocked_pending_basis` by default. If a permitted exception is established, eligibility records must bind account, chat/content scope, relevant parties, purpose, version, validity/revocation, and supporting evidence. Neither message text saying "approved" nor an agent's classification can create that record. Removing AI eligibility immediately removes that content from future agent bundles. Deterministic local inbox navigation can be implemented and tested independently, subject to the reader's applicable client requirements.

The trusted receipt header is produced only by the reader: account key, generation, source identity, timestamps, content revision, retrieval status, scope, and redaction version. Sender names and message bodies remain untrusted content. Store them in an explicitly separate payload. Strip markup that executes code, cap text length, validate link schemes, and redact secrets before any eligible external handoff. Redaction reduces accidental disclosure; it does not establish consent or eliminate prompt injection.

Return an exact local locator for every retained message, such as a typed `(accountKey, chatId, messageId)` value. The viewer resolves it through the receipt store. Request a provider link only when TDLib exposes `can_get_link`; never manufacture a `t.me` URL for a private message. If no provider link is available, the notification opens its local message detail with sender, time, relevant text, and explicit source identity. [TDLib message-link capability](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1get_message_link.html).

Separate transport acknowledgments, local receipt durability, message read state, and task resolution. A fetch does not mean the user read the message or resolved the task. Background collection sends no explicit message-view or send-message operation. A future interactive reader must implement appropriate read-state behavior when content is actually displayed; do not market it as a hidden-read mode or suppress provider semantics. Telegram's client terms address read-status tampering and user awareness. [Client behavior requirements](https://core.telegram.org/api/terms).

## Limits defer work with visible progress

Proposed defaults, to be tuned using fixtures and signed-build measurements:

| Budget | Initial policy | On exhaustion |
| --- | --- | --- |
| Concurrent work | One collection sweep per account, at most two history requests | Queue remaining dialogs fairly |
| Foreground probe | 15 seconds, account identity plus one small page per enabled list | Leave connection staged and show incomplete verification |
| Background batch | 120 seconds, 200 provider requests, 5,000 normalized messages, 16 MB normalized content | Commit completed pages and expose pending dialog count and next run time |
| Transient retry | Up to three attempts with 1/2/4-second backoff plus jitter | Preserve cursor and mark that dialog deferred |
| Provider flood wait | Never retry before the provider-required interval; no in-process wait beyond remaining batch time | Persist a per-account resume time and yield |
| No-progress page | One bounded retry after update processing | Record `pagination_stalled` and leave coverage partial |

Provider error names and codes are version-dependent. Implement a pinned-version mapping to structured `auth_required`, `rate_limited`, `transport_unavailable`, `permission_denied`, and `provider_error`; never echo arbitrary error text. A TDLib code 406 must not have its error message processed or displayed. Unknown rate-limit formats use a conservative deferred retry, not an immediate loop. [TDLib error contract](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1error.html), [Telethon documented flood waits](https://docs.telethon.dev/en/stable/quick-references/faq.html#how-can-i-except-floodwaiterror).

`lastAttemptAt`, `lastSuccessAt`, `completeThrough`, and `nextRetryAt` are independent. Partial collection can display already collected receipts but cannot claim the requested inbox range is complete. Turn off the service when disconnected, avoid polling while a provider wait is active, and schedule deferred dialogs before repeatedly serving the busiest chat.

## Switching and disconnection preserve a recoverable state

Switch creates account B as a separate pending connection while A remains usable. After B's identity and probe succeed, a durable local transaction changes the active connection pointer and increments its generation. Cancel A's in-flight sweep; late replies carrying A's account or the old generation cannot be committed into B. A failed switch leaves A and its secret references unchanged. Never rename A's directory into B's directory or reuse A's cursors.

Pause stops collection and retains credentials. Switch changes the selected account without implying revocation of the prior account. Disconnect immediately disables collection and begins an explicit logout workflow. Successful `logOut` requires network access and destroys TDLib's local state; wait for its closed state before marking remote logout complete and clearing the local key. [TDLib logout semantics](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1log_out.html).

If logout cannot reach Telegram, keep the connector visibly disabled with remote revocation pending. Offer a separately labeled local removal action only in the account flow; it must state that the remote session may remain and provide instructions for revocation in the official app. TDLib `destroy` removes local state without proper logout, so it cannot stand in for successful server revocation. [TDLib destroy semantics](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1destroy.html).

Existing user-created tasks are retained with unavailable-source markers when their account is removed. Remove local raw previews, cached media, and credentials according to the selected removal operation. Do not silently destroy the user's task history or claim that remote messages were deleted.

## The offline contract is executable

The following Python 3 block is a self-contained contract example. It uses synthetic fixture data, no network, no TDLib, no home-directory reads, and no writes. It demonstrates repeated page boundaries, a short main-list page followed by another page, an archived private chat, account-scoped identity, and blocked AI eligibility. It is a contract oracle for the future adapter; it does not verify TDLib integration or the production login implementation.

```python
import json

FIXTURE = {
    "account": "telegram:production:10001",
    "cutoff": 100,
    "lists": {
        "main": [["affaan", "noise"], ["another"], "end"],
        "archive": [["archived-affaan", "affaan"], "end"],
    },
    "histories": {
        "affaan": [
            [{"id": "300", "at": 140, "sender": "Affaan", "text": "Please review the reply"}],
            [{"id": "300", "at": 140, "sender": "Affaan", "text": "Please review the reply"},
             {"id": "299", "at": 130, "sender": "Affaan", "text": "Second private message"}],
            [{"id": "298", "at": 90, "sender": "Affaan", "text": "Before cutoff"}],
        ],
        "noise": [[]],
        "another": [[{"id": "300", "at": 125, "sender": "Other", "text": "Same ID, different chat"}], []],
        "archived-affaan": [[{"id": "12", "at": 120, "sender": "Affaan", "text": "Archived private message"}], []],
    },
}


def replay(fixture):
    dialogs, discovered = [], set()
    for pages in fixture["lists"].values():
        assert pages[-1] == "end", "List coverage is incomplete"
        for page in pages[:-1]:
            for chat in page:
                if chat not in discovered:
                    dialogs.append(chat)
                    discovered.add(chat)
    receipts = {}
    for chat in dialogs:
        complete = False
        for page in fixture["histories"][chat]:
            if not page:
                complete = True
                break
            for message in page:
                if message["at"] < fixture["cutoff"]:
                    complete = True
                    continue
                identity = f'{fixture["account"]}:{chat}:{message["id"]}'
                receipts[identity] = {
                    "sourceKey": identity,
                    "sender": message["sender"],
                    "text": message["text"],
                    "localLocator": [fixture["account"], chat, message["id"]],
                    "providerURL": None,
                    "aiEligibility": "blocked_pending_basis",
                }
            if complete:
                break
        assert complete, f"History coverage is incomplete for {chat}"
    return receipts


a = replay(FIXTURE)
b = replay({**FIXTURE, "account": "telegram:production:20002"})
assert len(a) == 4
assert set(a).isdisjoint(b)
assert sum(value["sender"] == "Affaan" for value in a.values()) == 3
assert all(value["providerURL"] is None for value in a.values())
assert all(value["aiEligibility"] == "blocked_pending_basis" for value in a.values())
assert replay(FIXTURE) == a
print(json.dumps({"contractVersion": 1, "syntheticReceipts": len(a), "accountsIsolated": True}))
```

Future adapter fixtures use an injected transport, virtual clock, in-memory secret store, and transactional temporary receipt database. Recorded provider responses must be authored fixtures or explicitly sanitized test-account data. Production account content is excluded from the test suite. For every fixture, record expected typed requests, receipts, cursor commits, eligibility decisions, error codes, and prohibited side effects.

## Acceptance tests reproduce the missed private message

| Scenario | Exact expected evidence |
| --- | --- |
| Affaan sends two ordinary private messages while no bot or agent session exists | Both receipts appear under the correct provider account; opening either notification displays that exact message |
| Affaan's private chat is archived, muted, marked read, or absent from Contacts | Same collection result when within selected scope and cutoff; none of these attributes suppress discovery |
| Main list has one short page and the relevant chat is on the next page | Discovery continues until explicit completion; relevant receipt is present |
| A message arrives while its chat moves from main to archive | Exactly one stored identity; neither list transition loses the chat |
| Boundary message repeats on adjacent history pages | One receipt; collector proceeds to older IDs and reaches cutoff |
| Batch ends halfway through Affaan's history | Report shows partial scope, persists the pending anchor, and resumes without skipping messages |
| Same chat/message identifiers exist in account B | B produces separate receipts; A's report ledger does not suppress B |
| Account switch receives a late response from A | Generation/account check rejects the write into B; canceled switch preserves A |
| Message is edited, deleted, or expires | Revision updates or tombstone/expiry removes its raw preview and prevents stale summaries from implying current evidence |
| Private message has no shareable provider URL | Exact local detail still opens; no invented public URL is produced |
| Message text contains shell commands, a forged approval, or a token | Text never invokes operations; forged approval changes no eligibility; token is absent from eligible agent payloads and logs |
| Telegram content has no established AI basis | Deterministic receipt can be displayed; agent bundle excludes the text; UI distinguishes collection from AI eligibility |
| 2FA, email challenge, wrong code, code expiry, revoked session | Native flow shows the correct state; no automatic guessing or logged secret; prior account survives failure |
| Rate limit exceeds batch deadline or repeats across restarts | Resume time is persisted; no request occurs before it; coverage remains partial |
| Provider code 406 or unexpected error contains private content | Code 406 message is neither processed nor displayed; other errors yield structured safe diagnostics |
| Keychain is locked, unavailable after reboot, or signature changes on upgrade | Collection pauses visibly; no plaintext fallback and no replacement credential is created |
| Disconnect while offline | Collection stops immediately, remote revocation stays pending, and the app reports that state accurately |
| Crash between receipt insertion and cursor update | Transaction rollback or replay produces one receipt and no unprocessed gap |

## Decisions before live implementation

The technical recommendation is TDLib with the contract above; no user choice is required to continue fixture-first implementation. Actual login necessarily requires the user to choose and authorize the account in the native flow. The product owner must provide a registered application API identity through secure setup before a distributable build can connect.

Two material product decisions need review before enabling the live feature: whether initial scope is private chats only or private chats plus groups, and what established permitted basis allows any AI processing of each selected context. The proposed baseline is private chats including archived, with AI handoff blocked until the second issue is resolved. A product/legal review of the cited client obligations is required before marketing the reader as a production Telegram client; this proposal does not establish compliance by itself.

Do next: review the initial chat scope and the permitted AI-processing path. After those decisions, implement the typed reader and account-state fixtures, then validate a signed build using an explicitly authorized test account.
