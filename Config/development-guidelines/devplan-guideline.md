# Development plan guideline

**Status:** draft for sign-off, 2026-11-10 (KAI-016).

- **What:** the format and generator prompt for `devplan.md`: a rough phase outline, a dependency tree, task triage, and a ready-to-create task set.
- **Why:** the owner creates tasks from this file and checks them off. Each leaf must therefore be one task with a measurable gate and explicit dependencies.
- **How:** the AI breaks the technical design's phases into leaves and orders them by dependency. It proposes a task title and summary for each leaf. The plan stays a draft that changes as phases land.

**Step:** `devplan`. **Produces:** `devplan.md`. **Owner gate:** creates tasks from leaves and checks each leaf off when its task closes.

**Example:** Kairos `docs/development-plan-outline.md`, mirrored as `devplan.md` (it predates this guideline; see the README's conformance table)

## Format

| Section | Content | Limit |
|---|---|---|
| Header | Status ("rough outline, subject to change"), Authority (the technical design wins), What/Why/How | — |
| How to use | One paragraph, then the leaf conventions | — |
| Phases | Table: phase, outcome, exit gate, starts when | One row per phase |
| One section per phase | The phase's exit gate, then its leaves | — |
| Dependency tree | One Mermaid flowchart of leaves and dependencies, then the critical path as one line | ≤ 25 nodes per chart; split by phase if larger |
| Triage | Table: leaf, priority, wave, parallel with, model size, risk | One row per leaf of the next two phases |
| Task set | Table: leaf, task title, task summary, task ID | Next phase only |
| Cross-cutting tracks | Work that runs beside phases | — |
| Out of scope | What this plan excludes | — |

**Leaf format.** Each leaf is one future task:

```markdown
- [ ] **<phase>.<n>. <Title>.** Task: <TASK-ID or —>
  Scope: <one or two sentences, citing technical-design sections>. Modules: <M IDs>.
  Deps: <leaf IDs or none>. Docs: <module files that must exist first>.
  Gate: <the measurable exit criterion>.
```

Rules:

- **One leaf, one task.** A leaf one agent cannot finish in one task splits into more leaves.
- **Gates are measurable.** Each gate cites a technical-design MVP gate, a budget row, or a module criterion ID.
- **Dependencies form a tree.** No cycles. Every Deps entry names an existing leaf.
- **The owner checks leaves.** The AI never ticks a checkbox. It fills `Task:` only when the owner asks it to create the task.
- **Task set fits Focus Queue.** Titles are at most 80 characters and summaries at most 200. Summaries answer what and why in plain words, without commit hashes or internal jargon.
- **Triage values.** Priority is `critical`, `high`, `medium`, or `low`. Wave is the order in which leaves can start. Model size is `large` for design or ambiguous work and `small` for mechanical work.
- **No dates** unless the owner set them.
- **Whole file under 4,000 words.** Detail lives in task plans, which put success criteria first.

## Inputs

| Placeholder | Filled with |
|---|---|
| `{{PROJECT}}`, `{{OWNER}}`, `{{PROJECT_DIR}}` | As in every guideline |
| `{{TECHNICAL_DESIGN}}` | Path of the technical design; read its phases, modules, pipelines, budgets, and open decisions |
| `{{MODULES}}` | Paths of accepted module files. May be partial |
| `{{TASKS}}` | Existing tasks for the project, with IDs, titles, and status. May be empty |
| `{{EXISTING}}` | The current `devplan.md` when regenerating. May be empty |
| `{{CONVENTIONS}}` | The shared conventions block |

## Prompt

```text
You write devplan.md for {{PROJECT}}: a rough, dependency-ordered outline that {{OWNER}} turns into tasks and checks off. It is a draft that will change; the technical design wins any conflict.

{{CONVENTIONS}}

Read the phases, module specifications, pipelines, budgets, and open decisions in {{TECHNICAL_DESIGN}}. Read {{MODULES}}, {{TASKS}}, and {{EXISTING}}.

Steps:
1. Add a planning-completion phase first if any module file, open decision, or environment prerequisite blocks the first build phase.
2. Break each phase into leaves in the leaf format. One leaf is one task one agent can finish. Cite the technical-design sections that bound each leaf's scope.
3. Give every leaf a measurable gate: a technical-design gate, a budget row, or a module criterion ID.
4. Record dependencies. Check that they form a tree with no cycles.
5. Draw the dependency tree in Mermaid, split by phase if a chart would exceed 25 nodes. State the critical path as one line of leaf IDs.
6. Triage every leaf of the next two phases: priority, wave, what it can run in parallel with, model size, and its main risk.
7. Propose a task title (at most 80 characters) and summary (at most 200 characters) for every leaf of the next phase. Where {{TASKS}} already covers a leaf, put its task ID in the leaf and the task set, and do not propose a duplicate.
8. Write devplan.md in the guideline's format. Leave every checkbox unticked unless {{EXISTING}} has it ticked.
9. Keep {{OWNER}}'s wording and ticks from {{EXISTING}}. Run the self-check and fix every failure before returning.
```

## Self-check

- Every leaf has Scope, Modules, Deps, Docs, and Gate lines.
- Every Deps entry exists; the dependency graph has no cycle.
- Every chart has at most 25 nodes and parses under the shared Mermaid rules.
- Every proposed title is at most 80 characters and every summary at most 200.
- No checkbox changed from {{EXISTING}}; no leaf duplicates an existing task.

## Owner review checklist

- The phase order and exit gates match how you want to proceed.
- The critical path is the work you want staffed first.
- Each task-set row is a task you would create as written.
- Nothing out of scope has slipped into a leaf.
