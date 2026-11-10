# Technical design guideline

**Status:** experimental (2026-11-10). Shown when a project turns on Planning guidelines.

- **What:** the format and generator prompt for `technical-design.md`, the master specification of modules, pipelines, gates, and decisions.
- **Why:** module files are spawned from it and must never contradict it. Every choice in it is either final or explicitly open, with an owner and a gate.
- **How:** the AI solidifies the design and research into exact choices. It lists each still-open decision with options for the owner to ratify, then links out to module files as they appear.

**Step:** `prd` (with `prd.md`). **Produces:** `technical-design.md`. **Owner gate:** ratifies each open decision, then marks the file reviewed.

## Format

| § | Section | Content |
|---|---|---|
| — | Header | Status, Authority (this file wins design conflicts), What/Why/How, and "How to use this document" |
| 0 | Authority and stack | The decision rule for conflicts, then a stack table: layer, exact choice and version, source. Date the version check |
| 1 | Product definition and MVP contract | One table per MVP group: ID, item, modules and pipelines, success criteria gate. Then explicit non-goals |
| 2 | System architecture | Process topology chart, numbered design rules, trust zones, platform contract table |
| 3 | Module specifications | Per module M1 onward: Purpose, Owns, Functionality, Interfaces, Failure behavior, MVP items. Link the module file once it exists |
| 4 | Pipelines | Per pipeline P1 onward: a sequence or flow chart, ordering guarantees, failure semantics |
| 5 | Cross-cutting contracts | Recovery guarantees per event; performance budgets (workload, gate, method); data classification; concurrency and scheduling |
| 6 | Repository layout | Planned tree and dependency rules between packages |
| 7 | Phases and gates | Table: phase, outcome, exit gate |
| 8 | Decision register | Table: decision, value, source of authority (owner and date, or evidence ID) |
| 9 | Open decisions and risks | Table: item, state, owner and gate |
| 10 | Evidence disposition | Table: source, adopted, adapted, rejected, or deferred |

Rules:

- **Solid or open, never vague.** Each choice is final with a source, or it sits in §9 with an owner and a gate. No "TBD" elsewhere.
- **Gates are measurable.** Every MVP gate and budget names a threshold, a workload, and a method. Unmeasured numbers say "budget" and name the phase that re-baselines them.
- **Exact versions.** Pin each dependency to an exact version with the date it was checked.
- **Module sections stay short.** Section 3 states what a module is for and owns. Endpoints and schemas live in the module files; link to them.
- **One record per decision.** Each decision appears once in §8. Other sections link to it.
- **Amend in place.** When an owner decision changes the design, update every affected section in the same change and record the decision in §8.

## Inputs

| Placeholder | Filled with |
|---|---|
| `{{PROJECT}}`, `{{OWNER}}`, `{{PROJECT_DIR}}` | As in every guideline |
| `{{CONCEPT}}`, `{{RESEARCH}}`, `{{DESIGN}}`, `{{PRD}}` | Paths of the reviewed earlier files |
| `{{DECISIONS}}` | Path of the owner's decision register. May be empty |
| `{{ANSWERS}}` | The owner's ratification form. Empty on the first run |
| `{{EXISTING}}` | The current technical design when regenerating or amending. May be empty |
| `{{CONVENTIONS}}` | The shared conventions block |

## Prompt

```text
You write technical-design.md for {{PROJECT}}: the master specification that every module file is spawned from and must not contradict. You solidify choices; {{OWNER}} ratifies any choice not already decided.

{{CONVENTIONS}}

Read {{CONCEPT}}, {{RESEARCH}}, {{DESIGN}}, {{PRD}}, {{DECISIONS}}, {{ANSWERS}}, and {{EXISTING}}.

Round 1 (when {{ANSWERS}} is empty).
1. List every choice the PRD's requirements force: stack layers, process boundaries, protocols, storage, budgets, phases.
2. Mark each choice decided (cite the owner decision or E ID) or open.
3. Check upstream versions for every stack layer and record the date.
4. If any choice is open, return a ratification form in the shared question format. For each open choice, give options with pros and cons, a recommendation, and why. Stop after the form.

Round 2 (all choices decided, or the rest deliberately left open by {{OWNER}}).
Write technical-design.md with sections 0 to 10 as listed in the guideline:
  0 Authority, provenance, and decision rule (with the stack table)
  1 Product definition and MVP scope (MVP contract tables, non-goals)
  2 System architecture (topology chart, design rules, trust zones, platform contract)
  3 Module specifications (M1 onward; keep module IDs from {{DESIGN}})
  4 Pipelines (P1 onward; keep pipeline IDs from {{DESIGN}})
  5 Cross-cutting contracts (recovery, budgets with methods, data classes, concurrency)
  6 Repository and module layout
  7 Development phases and gates
  8 Decision register
  9 Open decisions and risks
  10 Evidence disposition
Every MVP item in {{PRD}} appears in §1 with a measurable gate. Every open item appears in §9 with an owner and a gate.
Keep {{OWNER}}'s wording from {{EXISTING}}. When amending, change every affected section and add the §8 record in the same edit.

Run the self-check and fix every failure before returning.
```

## Self-check

- Every PRD MVP item appears in §1 with a gate that names a threshold or observable condition.
- Every module from `design.md` has a §3 entry with the same ID; every flow has a §4 pipeline.
- Every stack row has an exact version and a check date.
- No "TBD" outside §9; every §9 row has an owner and a gate.
- Every §8 row names its source of authority.

## Owner review checklist

- Each decided choice in §8 is one you made or accept.
- Each §9 item is acceptable to leave open until its gate.
- The phase gates in §7 are the go/no-go tests you want.
- Nothing in §1 commits to more than the PRD asks for.
