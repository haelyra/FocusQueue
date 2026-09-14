# Agent actions need host-owned authority

TL;DR: Ordinary queue questions currently enter the same write-capable execution path as requested edits. The host checks some resulting claims and completion state, but those checks occur after tools may have acted. Introduce typed request authority, default questions to a tool-free snapshot answer, and keep connector execution, evidence receipts, and canonical mutations under host control.

Review date: 2026-09-13. Scope: current working-tree Swift chat/review paths and the Python Codex harness. This document proposes changes; it does not implement them. No private connector was queried, no credentials were accessed, and no exploit was executed. References describe the inspected snapshot; concurrent edits may move line numbers.

## Contents

- [Questions currently receive write authority](#questions-currently-receive-write-authority)
- [Evidence needs a separate trust boundary](#evidence-needs-a-separate-trust-boundary)
- [Completion checks happen after agent mutation](#completion-checks-happen-after-agent-mutation)
- [A minimal host contract can close the gaps](#a-minimal-host-contract-can-close-the-gaps)
- [Tests must prove denied effects](#tests-must-prove-denied-effects)
- [Do next](#do-next)

## Questions currently receive write authority

| Location | Observed behavior | Consequence |
| --- | --- | --- |
| [QueueViewModel.swift:313](/Users/hira/Documents/Github/ECCFocusQueue/Sources/ECCFocusQueue/QueueViewModel.swift:313), `sendQueueAgentMessage` | Guards empty/busy input and intercepts recognized report commands. Other messages call the same `queueAgent.send` interface. | A question such as “Why is this task unresolved?” has no host-enforced read-only permission mode. |
| [QueueViewModel.swift:334](/Users/hira/Documents/Github/ECCFocusQueue/Sources/ECCFocusQueue/QueueViewModel.swift:334) | Global chat passes the full tasks context directory. A scoped chat passes one task's context directory and prepends an instruction to change it only when requested. | Task scoping narrows an additional writable directory but still passes the common workspace. The natural-language instruction carries the intent restriction. |
| [Integrations.swift:1330](/Users/hira/Documents/Github/ECCFocusQueue/Sources/FocusQueueCore/Integrations.swift:1330), `CodexQueueAgent.send` | Starts the helper's `chat` command with session, workspace, prompt, timeout, and optional context directory. | Its API and command contain no action grant, field allowlist, account binding, or write prohibition. |
| [focus_queue_codex.py:652](/Users/hira/Documents/Github/ECCFocusQueue/Scripts/focus_queue_codex.py:652), `chat` | Both initial/resumed execution and missing-thread retry hard-code `sandbox="workspace-write"` and expose evidence directories. | Fresh questions, follow-up questions, and retry paths all retain write capability. |
| [focus_queue_codex.py:519](/Users/hira/Documents/Github/ECCFocusQueue/Scripts/focus_queue_codex.py:519), `run_codex` | Passes `--ask-for-approval never`; enables network for workspace-write; adds proof, mail-command, and supplied context paths as writable directories. | The app delegates broad local tool capability, and can enable network side effects, before determining a concrete authorized mutation. |
| [focus_queue_codex.py:726](/Users/hira/Documents/Github/ECCFocusQueue/Scripts/focus_queue_codex.py:726) | `chat` accepts neither a sandbox flag nor the existing `--disable-tools` control exposed by `run`. | The available restricted classification path cannot currently be selected for chat. |

The prompt in `CodexQueueAgent.prompt` correctly asks for explicit dashboard-edit requests, prohibits unauthorized external messages, and tells the agent to use narrow connectors. These remain behavioral instructions. Literal message delimiters and positional arguments help separate prompt text from shell arguments, but do not create an authorization boundary inside the model's available tools.

Additional exposure: [ProcessRunner.swift:103](/Users/hira/Documents/Github/ECCFocusQueue/Sources/FocusQueueCore/ProcessRunner.swift:103) merges supplied environment values into the app's inherited environment, and [focus_queue_codex.py:577](/Users/hira/Documents/Github/ECCFocusQueue/Scripts/focus_queue_codex.py:577) inherits again. The review did not inspect environment values. A release policy should explicitly select required authentication/runtime variables instead of assuming the small Swift override is an environment allowlist.

The `read-only` label alone would address only part of the design. Qualify the actual provider version's enforcement, including child processes, extra directories, network access, and inherited configuration. Broad readable paths and arbitrary tool execution still need intentional scope.

## Evidence needs a separate trust boundary

High-priority finding: the Discord proof producer and the party being verified share write access to the proof location.

- [focus_queue_codex.py:25](/Users/hira/Documents/Github/ECCFocusQueue/Scripts/focus_queue_codex.py:25) defines the connector proof directory. `run_codex` grants it through `--add-dir` and exposes it in the child environment.
- [focus_queue_discord.py:238](/Users/hira/Documents/Github/ECCFocusQueue/Scripts/focus_queue_discord.py:238) writes a nonce and response to `discord-response.json` in that directory.
- [Integrations.swift:1592](/Users/hira/Documents/Github/ECCFocusQueue/Sources/FocusQueueCore/Integrations.swift:1592), `verifyDiscordEvidence`, accepts a matching output nonce, sufficiently recent modification time, expected JSON flags/connector name, a nonempty guild ID, and operation/message fields.

A writer of that file can construct those fields and echo the same nonce. Therefore these checks do not independently establish that the Discord connector performed the claimed operation. This is a code-derived forgery path, not a demonstrated live attack. Private Unix file permissions do not separate two processes running as the same user when one is explicitly granted that directory.

Mail is different: the harness intentionally grants the mail **command** directory while excluding the mail **receipt** directory from its explicit extra writable paths. The existing test confirms that distinction. This review does not assert the identical direct mail-receipt forgery path. However, the mail helper still exposes an `open` command, and its [implementation](/Users/hira/Documents/Github/ECCFocusQueue/Scripts/focus_queue_mail.py:643) can launch Mail. Prompt text is the current restriction that reserves that action for explicit requests. A receipt rejection afterward cannot undo an already opened application or other side effect.

Mail and Discord evidence requirements are selected by message substrings in [Integrations.swift:1475](/Users/hira/Documents/Github/ECCFocusQueue/Sources/FocusQueueCore/Integrations.swift:1475). Pronoun-only follow-ups can omit those substrings. Substring matching also confuses words such as “open” with actual authorization. Bind proof requirements to the host's requested operation and the connector actions performed, rather than to lexical guesses about the latest message.

Use a per-request receipt store outside every agent-writable root, or keep receipts in the host process. Bind each receipt to request ID, account, exact operation and arguments, source/message IDs, requested scope, coverage, and retrieval time. The host should invoke the connector and validate its result directly. A nonce in a writable JSON file is insufficient. If receipts cross a service boundary, authenticate the channel or signatures with keys unavailable to the agent. Guard against reuse, concurrent-turn receipt replacement, symlinks, and changed account selection.

## Completion checks happen after agent mutation

[CodexCompletionVerifier.verify](/Users/hira/Documents/Github/ECCFocusQueue/Sources/FocusQueueCore/Integrations.swift:1043) explicitly launches a workspace-write run. The prompt permits canonical updates under workspace rules and instructs the agent to call the session helper to record subtask completion after checking evidence.

[QueueViewModel.runReview](/Users/hira/Documents/Github/ECCFocusQueue/Sources/ECCFocusQueue/QueueViewModel.swift:1339) then refreshes state and accepts a successful review only if the canonical task is closed or the subtask is persisted as completed. This is stronger than accepting a prose assertion alone. It still trusts the effects of the same write-capable reviewer: success plus a state mutation is not an independent proof of satisfied criteria. The explicit unmerged-PR restriction is in the verifier prompt; this inspected path has no corresponding host-owned PR predicate before the canonical mutation.

For release, split review into evidence collection, structured verdict, and host commit. The host validates task identity, current revision, remaining subtasks, customer-review requirements, and authoritative PR status. It then applies the allowed transition exactly once. The reviewer should never acquire generic workspace write authority merely to explain why completion is pending.

## A minimal host contract can close the gaps

Introduce an immutable request object owned by the app:

```swift
struct AgentRequest {
    let id: UUID
    let taskID: String?
    let expectedRevision: String
    let accountID: String?
    let operation: AuthorizedOperation
    let readableResources: [ResourceID]
}

enum AuthorizedOperation {
    case answer
    case connectorRead(ConnectorReadRequest)
    case proposeTaskEdit(TaskEditScope)
    case applyTaskEdit(ValidatedTaskPatch)
    case reviewCompletion(CompletionScope)
}
```

These types are proposed contracts. `ValidatedTaskPatch` must be created by host validation, not deserialized directly from an agent response. Resource IDs resolve through the host's existing stores, with canonical path and ownership checks.

| Operation | Agent authority | Host responsibility |
| --- | --- | --- |
| Answer | Tool-free model call over a bounded snapshot. | Read only the selected task/context and relevant prior replies; keep receipts and credentials out of the prompt. |
| Connector read | Tool-free interpretation; optionally propose a structured query. | Validate query, selected account, operation and bounds; call an allowlisted connector; retain trusted receipt; return bounded source data. |
| Propose edit | Tool-free structured patch generation. | Validate schema, task identity, allowed fields, revision and intent; present a concrete diff when a new decision is required. |
| Apply edit | No model execution required. | Atomically apply exactly the validated patch using existing store APIs and record the change. |
| Review completion | Tool-free verdict over host-collected evidence, or an isolated explicitly authorized check runner. | Enforce closure predicates and commit the approved transition. Checks that need writes run in a disposable worktree and never write the canonical dashboard. |

Preserve existing authorization: a user clicking a typed “change task type” action has authorized that exact field change. Apply it deterministically without another approval round trip. Freeform ambiguous instructions can produce a proposed patch; the model's own intent classification must not grant itself write authority. Previously authorized work remains authorized, with task/field/scope constraints carried in the host request.

A small implementation sequence is available because the harness already has a tested tool-free `run` path:

1. Add a Swift request policy and route ordinary questions through tool-free execution using host-collected snapshots. Supply bounded transcript context instead of resuming a formerly privileged thread. Keep fresh/resumed/retry authority identical and fail closed if the provider cannot enforce the selected mode.
2. Move simple existing actions, beginning with task-type changes, into direct typed store mutations. Add revision checks and exact field allowlists.
3. Move connector calls and proof retention into a broker owned by the host. Grant the agent neither proof-directory writes nor connector credentials. Opening an external app is a separate typed action.
4. Convert completion to a structured proposal and host validation. Separate task state, evidence, connector state, and arbitrary workspace operations in the permission model.
5. Reduce prompts to purpose, selected task facts, permitted output schema, and evidence IDs. Retain behavioral instructions as defense in depth.

## Tests must prove denied effects

| Test boundary | Required cases and assertion |
| --- | --- |
| View model | Ordinary question, task-scoped question, global question, pronoun-only connector follow-up, and prior authorized edit followed by a question. Assert exact immutable policy and selected resource scope. |
| Harness command | Initial turn, resume, missing-thread retry, unknown capability/version, and conflicting CLI flags. Assert questions have no writable context/proof grants or tools; inability to enforce policy prevents launch. |
| Real execution boundary | In a temporary fixture workspace, attempt sentinel writes, sibling-task reads, symlink escapes, subprocess execution, and network egress under each restricted mode. Assert prohibited operations fail and original files remain unchanged. Run against supported CLI versions without private data. |
| Mutation broker | Reject extra task IDs, unknown fields, duplicate/replayed request IDs, stale revisions, unsupported status changes, and injected instructions in source files. Apply an authorized exact field change once. |
| Connector broker | Reject write/open operations under read authority; bind account and scope; handle disconnect mid-turn, partial pagination, malformed receipts, mismatched arguments, concurrent turns, and forged agent output. An agent-written file must never establish verified evidence. |
| Completion | A successful process and a plausible verdict cannot close an unresolved task. Unmerged PRs, incomplete subtasks, missing customer review, and stale evidence block host commit. |
| Environment | Child receives an approved environment list. Arbitrary sentinel credentials in the parent environment do not appear in the child or logs. |

Verification performed during this review: five existing Python harness tests passed for tool-free classification controls, mail command/receipt separation, extra writable context rules, prompt path non-escalation, and context forwarding through retry. These are mocked invocation tests. They substantiate current command construction and do not prove OS sandbox behavior, provider compatibility, or the proposed host policy. No production source was changed by this review.

## Do next

1. Add the immutable request policy and tool-free question route, with initial/resume/retry regression coverage.
2. Move Discord proof production and all connector execution behind host-owned read capabilities.
3. Implement deterministic field edits and host-validated completion transitions before public release.
