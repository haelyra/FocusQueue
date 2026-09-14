# Nielsen heuristic evaluation of ECC Focus Queue

Evaluation date: 2026-09-14

## TL;DR

Agent status and window actions were the main usability failure. This pass replaces ambiguous circles with named controls, status badges, loading feedback, task-scoped deletion, and recoverable archives. The highest remaining risk is that deterministic-looking field changes can still invoke a broadly capable freeform agent.

## Contents

- [Scope and method](#scope-and-method)
- [Executive assessment](#executive-assessment)
- [Changes applied](#changes-applied)
- [Ten-heuristic findings](#ten-heuristic-findings)
- [Accessibility review](#accessibility-review)
- [Prioritized follow-up](#prioritized-follow-up)
- [Verification coverage](#verification-coverage)
- [Do next](#do-next)

## Scope and method

This review covers the queue, task cards, agent and terminal controls, plan inspector, agent update inspector, daily reports, settings, and setup wizard. It combines a source-level interaction walkthrough with headless state and persistence tests. Pointer-driven UI automation was excluded because the repository requires explicit `ECC_FOCUS_QUEUE_UI_TESTS=1` opt-in.

Severity uses the standard 0 to 4 scale:

- 0: no usability issue
- 1: cosmetic issue
- 2: minor friction
- 3: major friction that can cause failure or abandonment
- 4: critical risk to user data, authority, or task completion

## Executive assessment

The app has strong foundations for visibility and recovery: it preserves plans, records launch diagnostics, distinguishes exact terminal sessions, and exposes several long-running operations. Its main usability weakness was action ambiguity around agents. Status, unread completion, opening a window, requesting completion review, and removing an association were represented by small circles or by click areas with hidden meaning. This pass addresses that cluster.

The highest remaining product risk is that some apparently deterministic UI actions still delegate broad work to a freeform agent. The most visible example is changing task type. The control looks like an ordinary field selector, but the implementation asks a write-capable agent to make the change. That violates predictable control behavior and is already analyzed in [ACTION_BOUNDARIES.md](ACTION_BOUNDARIES.md).

## Changes applied

| Principle | Before | After |
| --- | --- | --- |
| Agent status | A spinner represented active work, plain text carried status, and a tiny green dot meant unread completion | Each agent has a labeled badge with an icon and color: yellow Working, red Issue, green Done and New, gray Done and Seen, gray Queued, or gray No recent update |
| Session opening | Open actions kept their normal appearance while WezTerm discovery and activation ran | Agent rows, the agent update inspector, managed-session rows, terminal browsing, launch, and dashboard refresh show progress indicators and disable duplicate requests |
| Completion action | An unlabeled empty circle requested agent completion review | A green `Verify done` button states the action and preserves the evidence-review behavior |
| Task checkboxes | Submitted completion controls used warning or information colors | Checked controls use the success green; the adjacent review pill still reports Pending, Running, or Accepted |
| Deletion | One trash glyph required a double-click and individual subtasks had no visible remove action | Semantic trash buttons ask for confirmation, describe the effect, retain history, and leave the process running |
| Bulk removal | `Clear queue` inside one task removed agent entries from every task | `Remove all` names the destructive action and affects only the selected task |
| Hidden click target | Clicking a ticket title opened the agent manager, duplicating the named Manage agents button | Ticket titles are informational and named controls own agent and detail disclosure |
| Error recovery | A failed session open appeared as secondary body text | The affected agent receives a red Issue badge and the detailed error is presented with an error icon and color |

Primary implementation: [QueueView.swift](../Sources/ECCFocusQueue/QueueView.swift), [QueueViewModel.swift](../Sources/ECCFocusQueue/QueueViewModel.swift), [TerminalBrowserView.swift](../Sources/ECCFocusQueue/TerminalBrowserView.swift), and [AgentUpdateView.swift](../Sources/ECCFocusQueue/AgentUpdateView.swift).

Deletion and archive behavior: [TaskContext.swift](../Sources/FocusQueueCore/TaskContext.swift).

## Ten-heuristic findings

### 1. Visibility of system status

Baseline severity: 3. Agent-window discovery, activation, and recovery could take time while the originating control appeared idle. A card message changed, but it could sit below the user's attention. Agent work and unread completion also competed for the same small icon area.

Resolved in this pass: opening and finding sessions now produce local progress indicators. Status badges state the current condition in words, icons, and color. Opening failures remain attached to the affected agent.

Remaining severity: 2. Daily report generation and queue chat show activity, but the app has no unified place to inspect or cancel active operations. Long setup saves also disable the button without changing its label.

### 2. Match between the system and the real world

Baseline severity: 3. `Idle`, live terminal state, unread completion, and completion review were easy to conflate. `Clear queue` sounded local to the open task but acted globally.

Resolved in this pass: user-facing labels now say Working, Issue, Done and New, Done and Seen, Queued, No recent update, Finding session, Verify done, Remove agent, and Remove all. The removal dialogs explain that removing an entry does not terminate its process.

Remaining severity: 2. Browse terminals still leads with window, tab, and pane IDs. Grouping saved agent terminals by task and assignment before listing raw terminal identifiers would better match the user's goal of finding an agent.

### 3. User control and freedom

Baseline severity: 3. Individual agent records could not be removed from the main task card, and the session manager used a double-click gesture. Bulk clearing had broad scope.

Resolved in this pass: each agent can be removed with confirmation, and bulk removal is scoped to one task. Archived context provides a recovery record.

Remaining severity: 3. Agent launch, queue-agent response, completion review, and report generation have no visible Cancel or Stop action. Moving a task between Today and Rest has no short-lived Undo. Restoring a removed agent requires archive-level recovery rather than a user-facing Restore action.

### 4. Consistency and standards

Baseline severity: 3. Small circles represented completion request, unread state, live work, or status depending on location. A custom double-click trash glyph did not behave like a standard button.

Resolved in this pass: status is consistently a labeled badge, completion review is a named action, and removal uses semantic destructive buttons with confirmation. The hidden ticket-title action was removed.

Remaining severity: 1. Capitalization varies between `New agent`, `View Central Plan`, `Queue chat`, and sentence-style settings labels. Standardizing sentence case would give the app a more settled voice.

### 5. Error prevention

Baseline severity: 4. The task-local `Clear queue` control removed agent data globally. Removing a session used a precise double-click gesture with limited confirmation feedback.

Resolved in this pass: task-scoped and individual removal require confirmation, preserve a pre-delete archive snapshot, and have regression coverage proving sibling tasks remain intact.

Remaining severity: 4. The task-type menu presents a deterministic field edit but routes it through a broadly capable agent. The host should validate and apply the exact typed field change. New Agent also accepts any absolute repository string and reports path problems after submission; inline existence and repository validation should happen before Start agent becomes available.

### 6. Recognition rather than recall

Baseline severity: 3. Users had to remember what the green dot, spinner, terminal icon, and empty circle meant. Terminal lookup required translating assignments into low-level window details.

Resolved in this pass: status labels and named actions carry their meaning without relying on memory or tooltips. The last report time and progress summary remain visible beside the status.

Remaining severity: 2. A task can expose Central Plan, Context and evidence, Task details, Manage agents, diagnostics, an agent update inspector, and Queue chat. A single task-focused inspector with clear tabs would reduce the need to remember where each artifact opens.

### 7. Flexibility and efficiency of use

Current severity: 2. Filtering in Browse terminals, remembered launch preferences, drag ordering, and persistent drafts help repeat users. Frequent actions lack documented keyboard shortcuts, including refresh, new agent, open selected agent, switch task tabs, and close inspector. Adding standard shortcuts and a command menu would help keyboard-heavy use.

### 8. Aesthetic and minimalist design

Current severity: 2. Task cards can show title, IDs, multiple pills, summary, plan, evidence, type, progress, several agents, action messages, cleanup messages, and details. Attention and report banners can further compress the queue. Keep the default card focused on title, task state, next action, and agent state. Move configuration and forensic controls into a consistent disclosure or inspector.

The updated agent card is taller because its actions are now explicit. After live use, consider a two-line layout with one primary Open agent button and a trailing More menu for Diagnostics, Rename, and Verify. Keep Remove visible enough to discover while preserving its confirmation.

### 9. Help users recognize, diagnose, and recover from errors

Baseline severity: 3. Session-open failures were plain secondary text and could look like ordinary progress.

Resolved in this pass: failed agent-window actions receive a red Issue status, an error icon, the system detail, and a direct Open agent retry path. Launch diagnostics remain available.

Remaining severity: 2. Several errors expose raw localized descriptions. Translate known WezTerm, tmux, permissions, connector, and file-validation failures into: what failed, whether the agent is still running, and one recommended next action. Keep raw details under Diagnostics.

### 10. Help and documentation

Current severity: 2. Tooltips and setup explanations are extensive, launch diagnostics are retained, and the plan provides durable context. Help is distributed across tooltips, setup prose, diagnostics, and repository documents. Add a compact in-app status legend and a short Agent sessions help link. Explain the five-minute Working heartbeat threshold beside the legend.

## Accessibility review

The new status component avoids color-only meaning by combining text, symbols, and accessible labels. Icon-only destructive controls are real buttons with descriptive labels, confirmation, and expanded hit targets. Opening controls announce their busy state and prevent duplicate activation.

Remaining accessibility severity: 3. Much of the queue uses fixed 10 to 12 point text and dense layouts. Several older controls use 32 to 40 point frames, below the preferred 44 point native target. A dedicated pass should test VoiceOver order, Full Keyboard Access, increased contrast, reduced motion, text enlargement, monochrome accent mode, and both appearance modes. Dynamic Type behavior and contrast ratios remain unverified by this source review.

## Prioritized follow-up

1. Replace freeform-agent field changes with typed, host-validated actions. Severity 4.
2. Add Cancel or Stop for agent launch, queue chat, reviews, and report runs. Severity 3.
3. Validate repository and executable paths inline before launch or setup save. Severity 3.
4. Rework Browse terminals around task and assignment names, with raw pane details secondary. Severity 2.
5. Add keyboard shortcuts and Full Keyboard Access verification. Severity 2.
6. Consolidate task artifacts into one predictable inspector structure. Severity 2.
7. Add Undo or Restore for queue movement and recently removed agent entries. Severity 2.
8. Run an opt-in live UI pass for sizing, contrast, VoiceOver order, and multi-window behavior. Severity 2.

## Verification coverage

Headless tests cover opening-state publication, successful and failed agent recall, single-agent removal, task-scoped bulk removal, sibling preservation, and pre-delete archive retention. The full package test suite and installed-app artifact checks are recorded in the delivery handoff for this change.

## Do next

Use the installed build during normal agent work and record any agent status that feels inaccurate. The next implementation should replace freeform task-type changes with typed host actions, then add cancellation for long-running operations.
