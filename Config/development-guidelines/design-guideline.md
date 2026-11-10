# System design guideline

**Status:** draft for sign-off, 2026-11-10 (KAI-016).

- **What:** the format and generator prompt for `design.md`, the explicit system design in writing and one flow chart.
- **Why:** the owner should be able to judge the architecture in one sitting, before the technical design adds exact versions, endpoints, and budgets.
- **How:** the AI condenses the research into components, flows, and invariants. Each component becomes a future module and each flow a future pipeline.

**Step:** `research` (with `research.md`). **Produces:** `design.md`. **Owner gate:** marks the file reviewed.

**Example:** Kairos `docs/design.md`.

## Format

| Section | Content | Limit |
|---|---|---|
| Header | Status, Authority, What/Why/How | — |
| Design summary | The architecture in prose: what runs where, who owns state, what survives a failure | ≤ 8 sentences |
| System flow chart | One Mermaid `flowchart` of components and data flows | ≤ 25 nodes |
| Components | Table: component, responsibility, owns, talks to, module IDs | 4-20 rows |
| Key flows | Numbered end-to-end flows, 2-4 sentences each, each naming its pipeline ID | 3-8 flows |
| Invariants | Numbered rules every module must keep, bold lead phrase first | ≤ 10 |
| Failure boundaries | Table: event, what survives, recovery | ≤ 10 rows |
| Design decisions | Table: decision, choice, evidence (E IDs), rejected alternatives | One row per major choice |
| Open design questions | Table: question, owner, gate | — |
| Traceability | Table: concept FC IDs → components → flows | Every FC appears |

Rules:

- **Components become modules.** Assign each component its future module IDs (M1 onward) now. Keep IDs stable when the technical design expands them.
- **Flows become pipelines.** Assign each key flow its future pipeline ID (P1 onward).
- **Cite, do not decide.** Every design decision cites E IDs from `research.md`. A choice with no evidence goes to Open design questions.
- **Name pending changes.** If an owner decision is not yet in the technical design, say so beside the affected chart or row, with the decision ID and date.
- **Whole file under 250 lines.** Endpoints, schemas, versions, and budgets belong to the technical design.

## Inputs

| Placeholder | Filled with |
|---|---|
| `{{PROJECT}}`, `{{OWNER}}`, `{{PROJECT_DIR}}` | As in every guideline |
| `{{CONCEPT}}`, `{{RESEARCH}}` | Paths of the reviewed `concept.md` and `research.md` |
| `{{DECISIONS}}` | Path of the owner's decision register, if separate. May be empty |
| `{{EXISTING}}` | The current `design.md` when regenerating. May be empty |
| `{{CONVENTIONS}}` | The shared conventions block |

## Prompt

```text
You write design.md for {{PROJECT}}: the explicit system design, in prose and one flow chart, that the technical design will expand. {{OWNER}} has already decided the choices recorded in {{RESEARCH}} and {{DECISIONS}}; you arrange them into a coherent system.

{{CONVENTIONS}}

Read {{CONCEPT}}, {{RESEARCH}}, {{DECISIONS}}, and {{EXISTING}}.

Steps:
1. List the components the decided choices imply. Split a component where it fails, scales, or is trusted differently from its neighbor. Give each a future module ID.
2. List the end-to-end flows that deliver the concept's functional criteria. Give each a future pipeline ID.
3. State the invariants that keep the system correct when a component fails or two writers race.
4. Draw one Mermaid flowchart: components as nodes, data flows as labeled edges, process boundaries as subgraphs. At most 25 nodes.
5. Write design.md in this structure:
   # {{PROJECT}} system design
   header lines and What/Why/How
   ## Design summary
   ## System flow chart
   ## Components            (Component | Responsibility | Owns | Talks to | Modules)
   ## Key flows
   ## Invariants
   ## Failure boundaries    (Event | What survives | Recovery)
   ## Design decisions      (Decision | Choice | Evidence | Rejected)
   ## Open design questions (Question | Owner | Gate)
   ## Traceability          (Concept criterion | Components | Flows)
6. If a needed choice is not in the research or decisions, do not make it. Add it to Open design questions with {{OWNER}} as owner.
7. Keep {{OWNER}}'s wording from {{EXISTING}}. Run the self-check and fix every failure before returning.
```

## Self-check

- The chart parses under the shared Mermaid rules and has at most 25 nodes.
- Every component has module IDs; every key flow has a pipeline ID.
- Every functional criterion from the concept appears in Traceability.
- Every design decision cites at least one E ID that exists in `research.md`.
- No endpoint, schema, version, or numeric budget appears; those belong to the technical design.

## Owner review checklist

- The summary matches how you picture the system.
- The chart shows every part you expect, and nothing surprising.
- The failure table makes the promises you want to make, and no more.
- Each open question is one you are willing to decide later.
