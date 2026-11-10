# Product requirements guideline

**Status:** experimental (2026-11-10). Shown when a project turns on Planning guidelines.

- **What:** the format and generator prompt for `prd.md`, the product scope and testable requirements of the first release.
- **Why:** the technical design solidifies choices to meet these requirements, and module success criteria refine them. A requirement that cannot be tested cannot gate a phase.
- **How:** the AI turns the concept's functional criteria into workflows, MVP items, and numbered requirements. The technical design is then written to meet them, in the same step.

**Step:** `prd` (with the technical design). **Produces:** `prd.md`. **Owner gate:** marks the file reviewed.

## Format

| Section | Content | Limit |
|---|---|---|
| Header | Status, Authority (the technical design wins design conflicts until this file is amended), What/Why/How | — |
| Product and user | What the product is, who uses it, supported platforms with release tiers | ≤ 8 sentences |
| Problem | The pains from the concept, with evidence | ≤ 6 bullets |
| User flow | One Mermaid flowchart of the main loop through the product | ≤ 15 nodes |
| Required first-release outcomes | Table: workflow, intended outcome, acceptance, concept FC IDs | One row per workflow |
| MVP functionality | MVP items with IDs (B for backend, F for frontend, R for reports, or project-specific prefixes), each linking to the technical design | — |
| Functional requirements | Numbered FR1 onward; each one testable sentence | — |
| Reliability and performance requirements | Bullets; each names what is measured and points to the budget table | — |
| Exclusions and deferred capabilities | Bullets | — |
| Planning authority | Links to the decision register, technical design, and evidence index | — |

Rules:

- **Every workflow traces to the concept.** Each outcome row cites at least one FC ID. Every FC appears in some row or in the exclusions.
- **Requirements are testable.** No "fast", "robust", "seamless", or "intuitive" without a number or an observable condition.
- **Intent, not mechanism.** Name a technology only where the owner fixed it. The technical design says how.
- **No measured claims.** The PRD records intended behavior. Mark it so in the Status line until a release ships.
- **Whole file under 2,000 words.**

## Inputs

| Placeholder | Filled with |
|---|---|
| `{{PROJECT}}`, `{{OWNER}}`, `{{PROJECT_DIR}}` | As in every guideline |
| `{{CONCEPT}}`, `{{RESEARCH}}`, `{{DESIGN}}` | Paths of the reviewed earlier files |
| `{{DECISIONS}}` | Path of the owner's decision register. May be empty |
| `{{EXISTING}}` | The current `prd.md` when regenerating. May be empty |
| `{{CONVENTIONS}}` | The shared conventions block |

## Prompt

```text
You write prd.md for {{PROJECT}}: the first release's scope and testable requirements. The technical design will be written to meet it, and module success criteria will refine it.

{{CONVENTIONS}}

Read {{CONCEPT}}, {{RESEARCH}}, {{DESIGN}}, {{DECISIONS}}, and {{EXISTING}}.

Steps:
1. Turn each concept functional criterion into a user workflow with an intended outcome and an acceptance condition. Merge criteria only when one workflow fully covers them.
2. List MVP items under stable IDs, grouped as backend, frontend, and reports unless the project needs other groups. Link each to the module and pipeline IDs from {{DESIGN}}.
3. Write numbered functional requirements. Each is one sentence a tester could check. Carry every owner constraint from {{CONCEPT}} and {{DECISIONS}}.
4. Write reliability and performance requirements that name what is measured. Leave the numbers to the technical design's budget table and link to it.
5. Draw one Mermaid flowchart of the main user loop, at most 15 nodes.
6. Write prd.md in this structure:
   # {{PROJECT}} product requirements
   header lines and What/Why/How
   ## Product and user
   ## Problem
   ## User flow
   ## Required first-release outcomes  (Workflow | Intended outcome | Acceptance | Concept)
   ## MVP functionality
   ## Functional requirements
   ## Reliability and performance requirements
   ## Initial exclusions and deferred capabilities
   ## Planning authority
7. Keep {{OWNER}}'s wording from {{EXISTING}}. Put any requirement you cannot ground in the inputs into a final "Questions for {{OWNER}}" list instead of the file.
8. Run the self-check and fix every failure before returning.
```

## Self-check

- Every concept FC appears in an outcome row or in the exclusions.
- Every MVP item links to the technical design or to a module or pipeline ID in `design.md`.
- No requirement uses an unquantified quality word.
- The user flow parses under the shared Mermaid rules.
- The Status line says the file records intended behavior.

## Owner review checklist

- The outcomes table is the release you want to ship.
- Every exclusion is one you accept.
- No requirement commits you to something you have not decided.
