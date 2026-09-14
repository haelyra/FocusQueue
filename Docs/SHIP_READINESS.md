# Ship readiness: a focused macOS beta comes first

September 13 follow-up: portable staged installation, a native setup wizard and local tmux/SSH reconnect are now implemented. See [the current beta handoff](LAUNCH_BETA.md) for current scope and qualification limits. The audit below records earlier findings; public-release gates remain open where the handoff does not explicitly close them.

TL;DR: Stabilize the task, agent, notification, and document workflow, then qualify a clean-account macOS installation. Public release remains blocked by personalized runtime configuration, connector coverage and account lifecycle gaps, and distribution and recovery work. Additional operating systems and remote control are separate milestones.

Audit date: 2026-09-13. Scope: the current, substantially modified working tree. This is an engineering release plan, with code inspection and isolated installer checks. It is not a clean-machine installation, visual usability study, security certification, or proof of signed distribution. Implementation and audit results below reflect this session; a gate closes only when its acceptance evidence is recorded.

## Contents

- [The first release needs a bounded promise](#the-first-release-needs-a-bounded-promise)
- [Immediate fixes must follow the task context](#immediate-fixes-must-follow-the-task-context)
- [Public release has concrete blockers](#public-release-has-concrete-blockers)
- [Setup should be explicit and reversible](#setup-should-be-explicit-and-reversible)
- [Compatibility needs capability contracts](#compatibility-needs-capability-contracts)
- [Interface and runtime checks need measurable evidence](#interface-and-runtime-checks-need-measurable-evidence)
- [Acceptance gates determine the release sequence](#acceptance-gates-determine-the-release-sequence)
- [Do next](#do-next)

## The first release needs a bounded promise

Proposed beta: macOS 14 or later, local task files, WezTerm integration, and the implemented Codex and Claude CLI session paths. Qualify Apple Silicon first because this checkout contains ARM build artifacts. Advertise Intel support only after a separate build and execution pass. Users of the packaged app should not need Xcode; source builders need the Swift 6.2 toolchain declared by the package.

An operational queue and document viewer must work without connector credentials or a paid agent run. Add connectors and agent execution as explicit capabilities with visible setup status. Existing declarations in [Package.swift](/Users/hira/Documents/Github/ECCFocusQueue/Package.swift) and provider and terminal code in [Integrations.swift](/Users/hira/Documents/Github/ECCFocusQueue/Sources/FocusQueueCore/Integrations.swift) establish current implementation scope, not a compatibility certification.

## Immediate fixes must follow the task context

These are acceptance requirements for the changes requested in this session. User-reported failures still require focused verification after implementation.

| Work | Required behavior | Acceptance evidence |
| --- | --- | --- |
| Notification destination | Agent updates open the exact reply or verification result, with task, agent, time, result, and reason still open. | Separate fixtures for reply, incomplete verdict, success, missing artifact, stale task, and app relaunch; central plan appears only when explicitly selected. |
| Task and agent discovery | Selecting a task reveals every registered associated agent, including active, finished, and resumable sessions. | Two providers and multiple sessions on one task; unrelated same-directory terminals stay separate; reconnect and stale registration fixtures. |
| Expansion and context | Put the disclosure below the agents, adjacent to the content it reveals. Put an obvious Context control near the task header. | Evidence, files, links, plan, and agent replies are reachable without scrolling to the card bottom. |
| Central plan and Markdown | A visible bordered “View Central Plan” button opens a document viewer; Markdown links open reusable tabs. | Relative paths, spaces, percent encoding, anchors, missing files, duplicate links, close-tab behavior, and external links tested. |
| Task actions | Every menu item performs its named action or explains why it is unavailable. | Action-by-action inventory connects menu, model mutation, persistence, and visible result. Remove unused choices. |
| Collapse and minimize | Collapse produces a small FQ control with matching window hitbox. Minimize uses normal Dock behavior and restores reliably. | Geometry/state tests plus opt-in manual checks across display scales, restart, focus, and Dock restore. |
| Terminal cleanup | First provide a visual inventory and explicit selection. Preserve active and uncertain terminals by default. | Recheck process/session identity immediately before closure; reject stale IDs and live children; report each result. |
| Telegram reliability | State exactly which account, source, chats, date range, pagination, and unread/archive scopes were checked. | A known incoming message is found by stable ID; missing permissions, partial archives, and disconnected accounts remain visible. |

Closing a terminal does not guarantee its state can be recreated. Provider transcripts can support agent resume; shell jobs, unsaved terminal programs, environment, and scrollback have different persistence. A bulk cleanup action must require proven recoverability for each candidate. An unknown process is a reason to preserve the terminal.

### Implementation checkpoint from this session

Implemented: a dedicated agent-update inspector with full summary, verifier log,
completion criteria, scoped conversation and retry; task-agent inventory on title
click; disclosure beneath agents; early context/evidence access; bordered View
Central Plan; document tabs and local link routing; a 52×44 FQ window; native Dock
minimization; task-type request feedback; and a searchable WezTerm inventory with
stale-pane validation. App-created runtimes can reopen by their exact saved identity before
provider registration arrives. Removing an association preserves subtask evidence.

Headless validation: 180 Swift tests and 127 Python tests passed, including real
windowless WebKit rendering, cross-task notification routing, selective completion
acknowledgement, type-change feedback, tmux startup-race recovery, direct-terminal
launch and recall, and exact-pane selection. The release app bundle builds and its ad hoc signature verifies.
Native interaction, appearance, Dock animation, and multi-display behavior still
need a user-driven visual pass. No UI automation was run.

The app and session helper were installed locally on September 13, 2026. The
installed executable hash matches the built release, its ad hoc signature verifies,
and the relaunched process is running. Prior app/helper versions are retained in
the local Application Support backups directory. An initial LaunchAgent bootstrap
returned code 5; rollback restored the prior running app, then a bounded delayed
bootstrap successfully installed the update. Connector worker scripts remain
source changes pending a separate integration/deployment pass; live account
configuration was preserved.

Telegram: scoped active-session collection and offline connector diagnostics are
implemented and fixture-tested. The active reader is optional and remains disabled
locally because two read-only SQLite clients could not open the existing archive.
Personal inbox login, account switching, and a complete connector setup wizard
remain open. Bulk terminal closure also remains open; the visual inventory is the
implemented first step.

Follow-on agents are preparing a deterministic, read-only setup preview and a
personal Telegram account-adapter design while the immediate UI is reviewed.
These are preparation work, not completed setup or authentication features.

The action-boundary audit identified workspace-write and network access on ordinary
chat questions and agent-writable Discord proof receipts. Public release requires
host-controlled execution and receipts, with adversarial tests. These are
code-derived risks, not claims of a reproduced exploit.

## Public release has concrete blockers

| Priority | Finding from this checkout | Required completion |
| --- | --- | --- |
| P0 | Installers and uninstaller contain fixed user-home paths. Runtime proof paths, helper paths, mailbox identity, and repository defaults also retain personal values. | Derive paths from one application environment and per-account settings. Test a second macOS user, a home path with spaces, absent tools, and an empty workspace. |
| P0 | Installation automatically provisions companion mail and automation helpers, replaces helper files, stops the app, and removes the prior bundle before copying. | User-selected integrations, manifest-based ownership, staged replacement, interruption-safe rollback, and accurate install preview. |
| P0 | Packaging uses ad hoc signatures. No notarization or update verification pipeline was found. | Developer ID signing, hardened runtime and entitlement review, notarization and stapling, Gatekeeper checks on a downloaded artifact, version metadata, and a tested rollback. Apple's [distribution guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) describes the signing and notarization requirements. |
| P0 | Telegram collection has relied on a configured archive/profile command. An archive is not proof that a personal inbox was searched. | Choose and implement an authenticated personal-account adapter or clearly scope the feature to bot/archive messages. A bot's visibility is restricted to interactions available to that bot; the [Telegram FAQ](https://core.telegram.org/bots/faq) documents its message coverage. |
| P0 | Agent chat has workspace write access and network access; instructions carry important restrictions on dashboard edits and external messages. | Enforce allowed actions outside the prompt, validate generated changes, constrain connector permissions, and test malicious source text, path escapes, and unauthorized completion attempts. |
| P1 | Atomic JSON writes, private file permissions, locks, output bounds, and timeout handling exist, but a complete recovery/migration contract was not established. | Version persistent schemas; recover corrupted state without losing the original; test concurrent writes, low disk space, interrupted migrations, and downgrade behavior. |
| P1 | No checked-in CI directory, product license, privacy notice, security reporting instructions, or release support policy was found in the audit. | Add reproducible CI and release qualification, dependency license inventory, data/retention disclosure, a support route, and documented supported versions. |

Implemented in this audit: [install.sh](/Users/hira/Documents/Github/ECCFocusQueue/Scripts/install.sh) now supports a read-only `--check` preflight. It checks required binaries, signature validity, bundle identity, conflicting app destinations, and an unrecognized or symlinked session helper before stopping services. Eight isolated fixture cases passed. This is a narrow safety improvement: companion helper ownership and full installation rollback remain open.

[build-app.sh](/Users/hira/Documents/Github/ECCFocusQueue/Scripts/build-app.sh) no longer includes the personal configuration file in the app bundle. The developer installer still seeds that configuration, and runtime defaults remain personalized. Removing one bundled file does not make setup portable.

## Setup should be explicit and reversible

Proposed setup sequence:

1. Select or create a workspace and validate its task schema. Show the exact files the app will read and write. Start with an empty example queue if none exists.
2. Detect terminal and provider executables by known application locations and PATH. Show resolved path, version, supported operations, and a harmless health check. Static shell-customization inspection may assist discovery; never execute an arbitrary startup file merely to inspect it.
3. Offer independent switches for login launch, terminal focus control, notifications, connectors, and scheduled agent work. Explain permissions at the point the feature is enabled. Denial must leave the rest of the app usable.
4. Connect one account at a time. Show account identity, authentication status, available scope, and last successful check. Use Keychain references for stored credentials and user-chosen account identifiers for caches and receipts.
5. Show a concrete change preview. Apply only chosen integrations and create an ownership manifest with prior-file backups. Preserve existing shell, terminal, IDE, agent, and connector configuration. Repeated setup must be idempotent.
6. Provide account switch, disconnect, credential revocation guidance, and optional cached-data deletion. Account switching invalidates old proof receipts and pending work. Uninstall removes only owned artifacts and preserves user task files by default.

Agent-assisted setup can interpret a request and prepare a reviewed configuration diff. Installation, account selection, credential handling, and discovery should use deterministic code. Basic setup should spend zero model tokens; any optional agent budget must be visible before execution.

Connector contract: `discover`, `authenticate`, `status`, `listScopes`, `search`, `read`, `disconnect`. Every result includes account ID, operation, source ID, timestamp, scope, pagination completeness, and structured errors. Distinguish “connected” from “this requested message was read.” Keep writes separate from read permissions. Prevent credentials and message bodies from leaking into diagnostic exports.

## Compatibility needs capability contracts

| Target | Evidence and realistic next step |
| --- | --- |
| Codex and Claude | Both providers appear in current launch and session-registration code. Qualify actual installed CLI versions, fresh tmux and direct sessions, shell aliases, cancellation, and version changes. Provider resume is intentionally outside current recall. Claude documents CLI options in its [CLI reference](https://code.claude.com/docs/en/cli-reference). |
| Kimi and other agents | A CLI existing is insufficient for runtime identity and reply capture. Add a provider adapter for launch, stable session ID, heartbeat, completion evidence, and errors. [Kimi's official docs](https://moonshotai.github.io/kimi-cli/en/) establish a CLI integration surface; this repo has no qualified Kimi adapter. |
| WezTerm | Current controller is WezTerm-specific. Its [pane listing API](https://wezterm.org/cli/cli/list.html) is a suitable identity source. Qualify terminal versions and process-discovery behavior before promising reliable cleanup. |
| kitty | A separate adapter can use [remote control](https://sw.kovidgoyal.net/kitty/remote-control/). Setup must explicitly enable the chosen control channel and retain its permission boundaries. No adapter is currently qualified. |
| Ghostty and Terminal.app | Start with opening a workspace; capability-detect deeper control before offering agent attachment or cleanup. Ghostty targets [macOS and Linux](https://ghostty.org/docs/about), but platform availability alone establishes no Focus Queue integration. |
| VS Code and Cursor | Separate opening a file/workspace from controlling integrated terminals and identifying agents. VS Code documents [CLI and URL opening](https://code.visualstudio.com/docs/configure/command-line). Existing `vscode://file` parsing is only a file-opening capability; Cursor and integrated-terminal parity need dedicated tests. |
| tmux | Optional and checked by default for New Agent when installed. Track server/socket, session, pane, process and host identity separately from the desktop terminal. The [official tmux documentation](https://github.com/tmux/tmux/wiki) covers its session model. Existing shells are not imported. |
| Tailscale | Optional private connectivity for a future remote service. Explicitly enroll a device and authorize the service; network membership alone must not grant application control. Tailscale has a [CLI](https://tailscale.com/docs/reference/tailscale-cli) and [iOS client](https://tailscale.com/docs/install/ios); Focus Queue still needs authentication, replay protection, and a remote protocol. |
| iPhone | Build a companion that reads task status and exact notification context first. Local macOS window and process APIs cannot become iPhone terminal control. Remote execution requires the separate authenticated host service. |
| Linux and Windows | No quick Xcode conversion. [Swift toolchains](https://www.swift.org/install/) exist for both, while [SwiftUI](https://developer.apple.com/swiftui/) targets Apple platforms. This repo imports AppKit, ApplicationServices, WebKit, and Darwin. Extract portable models and storage contracts, abstract process/locking/terminal APIs, then choose and prototype a new desktop or web presentation layer. |

That last portability recommendation is an architectural inference from the framework boundaries and this repository's imports. A separate frontend and host adapters are real engineering work. Avoid letting them block a qualified macOS beta.

## Interface and runtime checks need measurable evidence

The following maps the requested changes to [Nielsen's heuristics](https://www.nngroup.com/articles/ten-usability-heuristics/). It is a code-informed review plan, not a completed participant study.

| Heuristic | Focus Queue acceptance check |
| --- | --- |
| Status visibility | Show refreshing, last checked, partial coverage, waiting for review, and action failure distinctly. |
| Real-world language | Explain “verdict incomplete” with the unmet criterion and next action. |
| User control | Reliable minimize, tiny collapse, reopen, cancel, safe cleanup preview, and account disconnect. |
| Consistency | One document viewer and consistent buttons, link behavior, labels, and selected-state styling. |
| Error prevention | Recheck live terminal state, protect existing setup files, and separate provider completion from task resolution. |
| Recognition | Visible Context and View Central Plan controls; agent identity and last reply are easy to find. |
| Efficiency | Keyboard access, task search, recent document tabs, and direct navigation to an update. |
| Minimal presentation | Keep primary task actions prominent and advanced actions in a purposeful menu. |
| Recovery | Errors identify the failing source, preserve the last good state, and provide a targeted retry. |
| Help | Short contextual setup guidance, permission recovery, and an accessible support/diagnostic route. |

Before beta, conduct five observed task sessions with new users: find an agent reply, explain an unresolved task, open supporting evidence, switch accounts, and restore the collapsed/minimized app. Proposed pass target: at least four of five participants complete each workflow without coaching; zero destructive mistakes. Test keyboard navigation, VoiceOver labels, contrast, text scaling, reduced motion, and mixed display scales separately. UI automation remains opt-in under repository instructions.

Efficiency findings: the model prevents overlapping refreshes, batches context publication, throttles report reads to ten seconds, and recurring PR checks to five minutes. However, [QueueViewModel.swift](/Users/hira/Documents/Github/ECCFocusQueue/Sources/ECCFocusQueue/QueueViewModel.swift) still loads and decodes the dashboard on each refresh before comparing its modification time. Default refresh is two seconds. Measure before changing the design.

Proposed performance gates: no model calls while idle; no external connector requests unless enabled and scheduled or requested; bounded logs, transcript reads, and document caches; no sustained CPU growth or monotonic memory growth during a 30-minute idle run. Benchmark 10, 100, and 1,000 tasks with 0, 10, and 100 sessions. Record p50/p95 time to show cached task details and refresh; initially target cached detail under 100 ms and local refresh under one second on the declared reference Mac. Treat these as targets until measured.

Prompt slimming: retain the current-task scope, evidence requirements, completion rules, and external-action authorization. Move personal account details into selected connector configuration. Include only the connector contract relevant to the request. Put queue ordering, file ownership, nonce validation, and mutation authorization in code. Compare token use, latency, and correctness over fixtures for task creation, update review, source search/read, incomplete verification, and injected instructions. A shorter prompt passes only if the same boundaries hold. Token settings are targets unless the provider offers enforceable limits; report actual use and any overrun.

## Acceptance gates determine the release sequence

| Gate | Owner role | Exit evidence |
| --- | --- | --- |
| G0: immediate workflow | App implementation and reviewer | Regression cases above pass; Swift and Python tests pass; changes reviewed together; headless checks separated from unperformed visual checks. |
| G1: clean installation | Packaging and setup | Fresh user installs, launches, upgrades, rolls back, and uninstalls without overwriting unrelated files. Missing tools, denied permissions, interrupted copies, and invalid configuration are recoverable. |
| G2: trustworthy integrations | Connector and agent owners | Correct account and exact message receipts; paginated/partial sources reported honestly; account switching and disconnect tested; unauthorized writes and source injection rejected. |
| G3: private beta | Release owner and QA | Downloaded signed/notarized artifact passes Gatekeeper; defined hardware/OS matrix passes; usability sessions and performance baselines recorded; support and rollback paths exercised. |
| G4: public release | Product and release owners | Sustained beta usage has no unresolved P0 defects or confirmed data loss; privacy/license/support materials approved; reproducible artifact, dependency inventory, release notes, and update authenticity verified. |
| G5: expansion | Separate adapter teams | Independently qualified terminal/provider adapters; then remote companion and non-macOS prototypes with their own acceptance matrices. |

Audit verification performed: shell syntax checks on the three owned scripts, eight temporary-home installer preflight scenarios, source inspection, and official documentation lookup. No live installation, application restart, account connection, external message, or UI automation was performed by this audit agent. Full suite results and the final integrated app behavior must be supplied by the coordinating implementation run.

## Do next

1. Finish G0 and review the concrete interaction changes together.
2. Implement the shared application environment and setup ownership manifest, then qualify G1 on a clean macOS user.
3. Decide the first beta's connector coverage from verified account capabilities and close G2 before advertising those integrations.
