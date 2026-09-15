# Map spacing and activity rules

The default map uses a five-column, ten-row envelope. The task card occupies the first row; the graph shares the remaining nine rows. Expansion drills into a representative using the same envelope. It does not turn a small map into an unbounded scroll of file boxes.

## Visual contract

- No parent has more than four outgoing connections. Larger lists show three ranked children and a fourth “more items” representative. Additional levels use the same rule.
- Every structural parent has a collapse control. A branch that exceeds the depth or row budget becomes a representative with an expansion control. That control opens a focused branch, preserving the task workspace. Blank space and the Typical button return to the normal view.
- Context generally occupies the left, agents the middle, and output paths the right. Physical directory paths are compressed into a single folder card where this saves space. Root cards display their full path as text, with truncation and a hover disclosure for long paths. The Focus Queue workspace is exempt from path display.
- The workspace and repo context are groups. There is one group-to-agent connection. Individual instruction files do not create parallel agent connections. The task workspace connects to worktree groups; no redundant task-context-to-agent edges are drawn.
- Repo context initially exposes AGENTS.md and README.md as compact clickable entries. Its additional-context control reveals other known repository context. Other files remain available in the separate browsing option.
- Orthogonal routes use the gaps between columns and rows. A route through a card is rejected. Crossing or overlapping unrelated routes is penalized; shared branches from the same parent may share a channel. Feedback cycles may still require crossings, so this is a routing preference rather than a claim that every graph is planar.
- Expansion controls use a subdued gray. View changes animate card positions, route endpoints, and scale with a 0.28-second ease-in/out transition. Reduce Motion disables the animation.

The reusable pieces are `MapTree`, `MapCompactLayout`, `MapDiagram`, and `MapEdgeRouter`. Task semantics remain in `WorkspaceMapProjection`; navigation stays in `WorkspaceMapModel`. Default layout budgets are independent of how much data is present in a snapshot.

## Agent and subagent semantics

A saved tmux identity is an agent runtime attribute. It does not generate an infrastructure card. A subagent is an agent instance with an explicit parent-session relationship. It can have its own input/output records, state, workspace, and focused view. Parent relationships are cycle checked. An unknown parent can remain unresolved without inventing a relationship to an unrelated task agent.

Current reports are ranked first. The active window is thirty minutes and requires a working agent state. If fewer than four distinct current paths exist, important historical writes fill the remaining positions. Importance is an optional producer-supplied number from 0 to 100; ties use recency and a stable identity. Declared outputs provide a fallback where actual writes have not been recorded. An idle agent therefore still has up to four useful representatives instead of an empty map. The UI labels both declared and reported evidence.

The Agent view's Changed files toggle shows recorded writes for that exact provider session. It does not convert Git changes or declared intentions into proof of authorship. Compaction and expansion still apply. Records from a replacement session are separate, so file history does not migrate to a new agent just because a subtask was reassigned.

## Activity reporting contract

```sh
Scripts/focus-queue-map activity TASK-ID --import /path/to/activity.json
Scripts/focus-queue-map diagram TASK-ID --view agent --agent SESSION-ID --retrospective
Scripts/focus-queue-map diagram TASK-ID --view agent --agent SESSION-ID --focus GROUP-ID
```

Use the [fictional activity example](activity.example.json) as the input shape, replacing identifiers, paths, and timestamps. A reporter supplies successful read/write events only. The map never executes report contents or contacts an instance.

Imports merge the most recent event for each path and operation into a private per-session record. Historical writes survive subsequent reports. Each session retains up to 500 entries, each task up to 100 recorded instances, and each report is limited to 256 KB. A separate nonblocking task-activity lock protects merges; a busy writer returns a retry error. The lock is independent of conversations and provider runs. Rejected imports preserve the previous record.

Collection and rendering make no new model calls. Reports can be produced by a provider adapter or another local script. **Automatic provider event capture is still a separate integration:** an agent or subagent without supplied activity can only show registered state and declared scope. Historical changes before recording began cannot be reconstructed reliably from a shared worktree's Git diff.

## Verification

Headless tests cover the viewport envelope, fan-out cap, parent collapse, drill-in, deterministic positions, paths clear of cards, background navigation, subagent collection, runtime attributes, exact-session history isolation, ranked fallback, and retrospective exclusion of declared-only outputs. Native hover and transition appearance remain for manual review; no pointer or keyboard automation is used.
