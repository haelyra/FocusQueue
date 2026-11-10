import Foundation

/// The files of `Config/development-guidelines/`, compiled in so the app and
/// `focus-queue-session` share them without a resource lookup. A test keeps each
/// one identical to its Config file: edit the Config file, then regenerate this one.
enum DevelopmentGuidelineFiles {
    static let texts: [String: String] = [
        "README.md": #"""
# Planning-phase guidelines

**Status:** draft for Haelyra's sign-off, 2026-11-10 (KAI-016). Generic across projects; Kairos's planning files are the worked examples.

- **What:** one guideline per Planning file. Each holds the file's format, a generator prompt, a self-check, and an owner review checklist.
- **Why:** Focus Queue's development process names the Planning files but not their shape. Without a shared format, each agent invents one, and owner review takes longer.
- **How:** the Project tab (or an agent linked to the step) fills a guideline's placeholders and runs its prompt. The owner then reviews the draft in the document viewer and marks it reviewed.

## Planning flow

```mermaid
flowchart TB
  C["concept.md<br/>AI asks clarifying questions"]
  R["research.md<br/>evidence compendium"]
  D["design.md<br/>system design and flow chart"]
  P["prd.md and technical design<br/>AI solidifies choices"]
  M["modules/*.md<br/>one file per module"]
  V["devplan.md<br/>outline, dependency tree, task set"]
  K["agent-contract.md and orchestration.md"]
  Z["Phase 0"]
  C -->|"owner answers questions"| R
  R -->|"owner picks options"| D
  D --> P
  P -->|"owner ratifies decisions"| M
  M -->|"owner accepts criteria in order"| V
  V -->|"owner creates and checks off tasks"| K
  K -->|"owner signs both"| Z
```

## Steps, files, and guidelines

| Step (catalog ID) | File | Written by | Owner gate | Guideline |
|---|---|---|---|---|
| `concept` | `concept.md` | AI after a question round | Answers the questions; marks reviewed | [concept-guideline.md](concept-guideline.md) |
| `research` | `research.md` | Owner and AI together | Supplies sources; picks options; marks reviewed | [research-guideline.md](research-guideline.md) |
| `research` | `design.md` | AI from research | Marks reviewed | [design-guideline.md](design-guideline.md) |
| `prd` | `prd.md` | AI | Marks reviewed | [prd-guideline.md](prd-guideline.md) |
| `prd` | `technical-design.md` | AI solidifies choices | Ratifies each open decision | [technical-design-guideline.md](technical-design-guideline.md) |
| `modules` | `modules/<id>-<slug>.md` | AI, one file per module | Accepts each module's success criteria, in order | [module-guideline.md](module-guideline.md) |
| `devplan` | `devplan.md` | AI outline | Creates tasks from it and checks leaves off | [devplan-guideline.md](devplan-guideline.md) |
| `contract` | `agent-contract.md`, `orchestration.md` | Bundled generator | Reads and signs both | `Config/contract-generator-prompt.md` in the Focus Queue repository (shipped in FOC-117) |

`technical-design.md` joins the `prd` step when a project turns on Planning guidelines. A project's `artifactNames` map can point it at an older file name.

## How a guideline runs

1. **Fill.** The caller fills the placeholders in the guideline's Inputs table. `{{CONVENTIONS}}` is always the block below.
2. **Ask.** Guidelines with a question round return a question form first. The owner answers, and the caller reruns with `{{ANSWERS}}` filled. At most three rounds.
3. **Draft.** The prompt writes the file in the guideline's format and runs its self-check.
4. **Review.** The owner reads the draft against the guideline's review checklist and clicks "Mark reviewed".
5. **Regenerate.** A rerun with `{{EXISTING}}` keeps the owner's wording and flags only lines that break a rule.

## Shared conventions

Every prompt receives this block as `{{CONVENTIONS}}`.

```text
Conventions for every planning file:
- Location. Files live in the project folder under their catalog names. If the project versions planning documents in a repository, the repository copy is the source of truth and the project folder mirrors it byte for byte. Record any name difference in the project's evidence index.
- Header. An H1 title, then a **Status:** line (draft, reviewed, or accepted, with date and task ID), then an **Authority:** line naming which document wins a conflict, then What, Why, and How bullets of one or two sentences each.
- Language. One idea per sentence, at most 25 words, active voice. Lead words carry the information. Lists over prose. Each fact once. Concrete referents: paths, IDs, values. No filler, no self-praise.
- Evidence. Every factual claim cites a source. A number nobody measured says "budget" or "not measured". An owner decision names the owner and the date. Never invent a decision: an open item goes into the file's questions or open-decisions table with an owner.
- IDs. Use stable prefixed IDs: FC (functional criteria), RQ (research questions), E (evidence), M (modules), P (pipelines), C (criteria), D (decisions). Never renumber. Retire an ID with "Withdrawn <date>: <reason>".
- Links. Every shorthand ID links to the file that defines it. Link a sibling planning file by bare name; link anything else by absolute path. The viewer ignores #anchors, so name the section in text (for example "§3").
- Tables. Use <br/> for a line break inside a cell; the renderer drops a table that contains <br>. Escape any literal pipe.
- Diagrams. Mermaid only: flowchart or sequenceDiagram. Quote every label that contains punctuation. Use <br/> for line breaks. No semicolons and no unquoted parentheses in labels. At most 25 nodes per chart.
- Authority. Later files refine earlier ones and never silently contradict them. Owner decisions outrank the technical design, which outranks the PRD, the design, the research, and the concept. A conflict is a defect: propose an amendment and name who decides.
- Size. Each guideline sets a cap. Shorter is better.

Question round format (guidelines with a question round):
- At most 7 questions per round and 3 rounds in total. Ask only what the inputs cannot answer: intent, preferences, constraints, and priorities.
- Each question has one context line, two to four options, one option pre-marked [x] as the recommendation with a short reason, and a "Your answer:" line.
- End with one free-text "Overrides" question. Record every answer, with its date, in the file's questions table.
```

## Sign-off tracker

Haelyra approved the whole set for integration on 2026-11-10 ("Looks good"). In-app sign-off of owner edits is deferred; until it ships, this table is the record.

| Guideline | Signed off | Notes |
|---|---|---|
| [README conventions](#shared-conventions) | [x] | Approved as a set, 2026-11-10 |
| [concept](concept-guideline.md) | [x] | Approved as a set, 2026-11-10 |
| [research](research-guideline.md) | [x] | Approved as a set, 2026-11-10 |
| [design](design-guideline.md) | [x] | Approved as a set, 2026-11-10 |
| [prd](prd-guideline.md) | [x] | Approved as a set, 2026-11-10 |
| [technical design](technical-design-guideline.md) | [x] | Approved as a set, 2026-11-10 |
| [module](module-guideline.md) | [x] | Approved as a set, 2026-11-10 |
| [devplan](devplan-guideline.md) | [x] | Approved as a set, 2026-11-10 |

## Kairos conformance

How Kairos's current Planning files compare with these guidelines. Gaps are fixed only after sign-off.

| File | State | Gap against its guideline |
|---|---|---|
| `concept.md`, `research.md`, `design.md` | Drafted to these guidelines (KAI-016) | None known |
| `prd.md` | Finalized 2026-11-05 | No user-flow chart; workflows carry no FC trace column |
| `technical-design-master-plan.md` | Ratified 2026-11-05 | Name differs from `technical-design.md`; D1-D5 not yet merged (KAI-005) |
| `devplan.md` (mirror of `docs/development-plan-outline.md`) | Draft outline | No leaf checkboxes, no dependency chart, no triage table, no task titles |
| `modules/` | Six KAI-005 drafts on an unmerged branch | No one-line description, no Debug logs section; none registered in `development.json` |
| `agent-contract.md`, `orchestration.md` | Signed 2026-11-10 | None |

"""#,
        "concept-guideline.md": #"""
# Concept declaration guideline

**Status:** draft for sign-off, 2026-11-10 (KAI-016).

- **What:** the format and generator prompt for `concept.md`, the project's one-page statement of the main idea and its functional criteria.
- **Why:** every later planning file traces to these criteria. A vague concept shows up later as scope drift and untestable gates.
- **How:** the AI asks clarifying questions first, then drafts from the owner's answers and any existing notes. The owner marks the draft reviewed.

**Step:** `concept`. **Produces:** `concept.md`. **Owner gate:** answers the question form, then marks the file reviewed.

**Example:** Kairos `docs/concept.md`.

## Format

| Section | Content | Limit |
|---|---|---|
| Header | Status, Authority, What/Why/How (shared conventions) | — |
| Main idea | One sentence: who does what with the product, and why it beats today's way. Then up to five sentences. | 6 sentences |
| Problem | Bullets: a bold pain, then who feels it and the evidence | 3-7 bullets |
| User and context | Primary user, current tools, environment | 3-5 bullets |
| Functional criteria | Table: ID, "The user can", observable acceptance, refined in | 5-15 rows |
| Scope boundaries | In v1, out of v1, later | 3 bullets |
| Constraints and principles | Owner-fixed constraints, then numbered principles | ≤ 7 principles |
| Success signals | How the owner will know the concept worked | 3-5 bullets |
| Clarifying questions | Table: #, question, answer, source; open ones say **Open** and name who decides | All asked |
| Sources | Links to every input | — |

Rules:

- **Criteria are observable.** Each FC starts with a verb the user performs. Its acceptance can be checked without reading code.
- **No technology unless fixed.** Name a technology only when the owner set it as a constraint. Design choices belong to research and design.
- **"Refined in" may be empty.** Fill it with later IDs (PRD workflow, MVP item) once those files exist.
- **Whole file under 1,500 words.**

## Inputs

| Placeholder | Filled with |
|---|---|
| `{{PROJECT}}`, `{{OWNER}}` | Project name; the person who decides |
| `{{PROJECT_DIR}}` | Absolute path of the project folder |
| `{{NOTES}}` | Paths of any existing idea notes, briefs, or PRD drafts. May be empty |
| `{{ANSWERS}}` | The owner's answered question forms. Empty on the first run |
| `{{EXISTING}}` | The current `concept.md` when regenerating. May be empty |
| `{{CONVENTIONS}}` | The shared conventions block |

## Prompt

```text
You write concept.md for {{PROJECT}}: a one-page declaration of the main idea, the problem, the user, and the functional criteria every later planning file traces to. {{OWNER}} decides intent; you never decide it for them.

{{CONVENTIONS}}

Read {{NOTES}}, {{ANSWERS}}, and {{EXISTING}}. Do not read code.

Step 1. Decide whether to ask or draft.
- Ask when any of these is unknown: the primary user; the problem and its evidence; what the first release must let the user do; explicit non-goals; fixed constraints (platforms, budget, deadlines, required tools); and how {{OWNER}} will judge success.
- Otherwise draft.

Step 2 (ask). Return only a question form in the shared question round format. Group questions in this order: user, problem, must-have capabilities, non-goals, constraints, success. Pre-mark the option the notes best support. Stop after the form.

Step 3 (draft). Write concept.md in this structure:
  # {{PROJECT}} concept declaration
  header lines and What/Why/How per the conventions
  ## Main idea
  ## Problem
  ## User and context
  ## Functional criteria   (table: ID | The user can | Observable acceptance | Refined in)
  ## Scope boundaries      (In v1, Out of v1, Later)
  ## Constraints and principles
  ## Success signals
  ## Clarifying questions  (table: # | Question | Answer | Source)
  ## Sources
Rules for the draft:
- Number functional criteria FC1 onward, 5 to 15 of them. Each starts with a verb the user performs. Acceptance is observable without reading code.
- Name a technology only if {{OWNER}} fixed it as a constraint.
- Record every question you asked and every answer, with its date. A question nobody answered stays in the table marked Open, with who decides.
- If {{EXISTING}} is not empty, keep {{OWNER}}'s wording; change a line only when it breaks a rule, and list each change after the file.

Step 4. Run the self-check below and fix every failure before returning.
```

## Self-check

- Every section in the format table exists, in order.
- 5 to 15 functional criteria; each starts with a user verb; none names an implementation unless it is a listed constraint.
- Every answered question cites its source and date; every open question names who decides.
- No sentence exceeds 25 words; the file is under 1,500 words.

## Owner review checklist

- The main idea sentence is the pitch you would give.
- Each functional criterion is something you would test by using the product.
- Nothing you consider essential is missing; nothing listed is a non-goal.
- Constraints are yours, not the AI's assumptions.
- Open questions are truly open.

"""#,
        "research-guideline.md": #"""
# Research compendium guideline

**Status:** draft for sign-off, 2026-11-10 (KAI-016).

- **What:** the format and generator prompt for `research.md`, the compendium of evidence behind every design choice.
- **Why:** the design and technical design cite this file. Without dated, typed evidence, an owner cannot tell a measured fact from a recalled one.
- **How:** owner and AI work together. The AI proposes research questions; the owner adds sources and priorities. The AI then gathers evidence and puts options to the owner.

**Step:** `research` (with `design.md`). **Produces:** `research.md`. **Owner gate:** edits the questions, picks options, marks the file reviewed.

**Example:** Kairos `docs/research.md`.

## Format

| Section | Content | Limit |
|---|---|---|
| Header | Status, Authority (evidence only; decisions live elsewhere), What/Why/How | — |
| Research questions | Table: ID, question, why it matters (cite FC IDs where one applies), status, answered by (E IDs) | 5-20 rows |
| Evidence register | Table: ID, source link, type, date, key finding (one line), disposition | One row per source |
| Findings by topic | Bold topic with its RQ IDs, then 2-5 bullets, each citing E IDs | — |
| Options considered | Per open decision: options with pros and cons, a recommendation, and the owner's choice. May point to the project's decision register instead | — |
| Prior art | Table: project, copy, do not copy | ≤ 10 rows |
| Gaps and unverified claims | Table: claim, state, the gate that will test it | All known gaps |
| Provenance | Where superseded sources are archived, with hashes | — |

Rules:

- **Types.** Each evidence row has one type. `source` is a document; `upstream` is vendor docs, registries, or papers; `local` is a read of existing systems or data. `test` is a command that ran, with its result; `owner` is the owner's decision.
- **Dates.** Every upstream fact carries the date it was checked. Versions and prices go stale.
- **Verified means run.** Call a finding verified only when a command, measurement, or inspection produced it. Otherwise say "reported by" with the source.
- **Archive, never delete.** A superseded source moves to an archive byte for byte, with a SHA-256 hash and its disposition.
- **No decisions here.** Research recommends; the owner decides. Record the choice and its date, then carry it into the technical design.
- **Whole file under 3,000 words.** Long source detail stays in the sources.

## Inputs

| Placeholder | Filled with |
|---|---|
| `{{PROJECT}}`, `{{OWNER}}`, `{{PROJECT_DIR}}` | As in every guideline |
| `{{CONCEPT}}` | Path of the reviewed `concept.md` |
| `{{SOURCES}}` | Paths or URLs the owner already has: prior plans, notes, competitor lists. May be empty |
| `{{ANSWERS}}` | The owner's answered forms. Empty on the first run |
| `{{EXISTING}}` | The current `research.md` when regenerating. May be empty |
| `{{CONVENTIONS}}` | The shared conventions block |

## Prompt

```text
You build research.md for {{PROJECT}}: the evidence compendium that the system design and technical design will cite. You gather and weigh evidence; {{OWNER}} makes every decision.

{{CONVENTIONS}}

Read {{CONCEPT}}, {{SOURCES}}, {{ANSWERS}}, and {{EXISTING}}.

Round 1 (when {{ANSWERS}} has no research questions yet). Derive research questions from the concept's functional criteria, constraints, and the risks they imply. Each question must change a design choice if answered differently. Return a question form in the shared format that asks {{OWNER}} to: confirm, cut, or add research questions; name sources they already trust or distrust; and rank priorities. Stop after the form.

Round 2 (questions agreed). For each research question, gather evidence: read the owner's sources first, then primary upstream documentation, then local data and code if the project has any. Record each item once in the evidence register with type, date, one-line finding, and disposition. Run a check yourself where one is cheap and safe, and record it as type test. Where evidence leaves a real choice, write options with pros and cons and a recommendation, then return a question form for {{OWNER}} covering only those choices. Stop after the form.

Round 3 (choices made). Write research.md in this structure:
  # {{PROJECT}} research compendium
  header lines and What/Why/How
  ## Research questions      (ID | Question | Why it matters | Status | Answered by)
  ## Evidence register       (ID | Source | Type | Date | Key finding | Disposition)
  ## Findings by topic
  ## Options considered
  ## Prior art               (Project | Copy | Do not copy)
  ## Gaps and unverified claims  (Claim | State | Gate that tests it)
  ## Provenance
Record each of {{OWNER}}'s choices with its date as type owner. Keep {{OWNER}}'s wording from {{EXISTING}}.

Then run the self-check below and fix every failure before returning.
```

## Self-check

- Every research question links to at least one evidence row or is marked Open with a gate.
- Every evidence row has a type and date; every `test` row names what ran and its result.
- Every finding bullet cites at least one E ID.
- No row says "verified" without a test or inspection behind it.
- The file decides nothing that the owner did not decide.

## Owner review checklist

- The research questions are the ones that would change your design.
- No source you rely on is missing or misrepresented.
- Each option set includes the choice you would have considered.
- The gaps table lists what you would worry about.

"""#,
        "design-guideline.md": #"""
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

"""#,
        "prd-guideline.md": #"""
# Product requirements guideline

**Status:** draft for sign-off, 2026-11-10 (KAI-016).

- **What:** the format and generator prompt for `prd.md`, the product scope and testable requirements of the first release.
- **Why:** the technical design solidifies choices to meet these requirements, and module success criteria refine them. A requirement that cannot be tested cannot gate a phase.
- **How:** the AI turns the concept's functional criteria into workflows, MVP items, and numbered requirements. The technical design is then written to meet them, in the same step.

**Step:** `prd` (with the technical design). **Produces:** `prd.md`. **Owner gate:** marks the file reviewed.

**Example:** Kairos `prd.md`.

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

"""#,
        "technical-design-guideline.md": #"""
# Technical design guideline

**Status:** draft for sign-off, 2026-11-10 (KAI-016).

- **What:** the format and generator prompt for `technical-design.md`, the master specification of modules, pipelines, gates, and decisions.
- **Why:** module files are spawned from it and must never contradict it. Every choice in it is either final or explicitly open, with an owner and a gate.
- **How:** the AI solidifies the design and research into exact choices. It lists each still-open decision with options for the owner to ratify, then links out to module files as they appear.

**Step:** `prd` (with `prd.md`). **Produces:** `technical-design.md`. **Owner gate:** ratifies each open decision, then marks the file reviewed.

**Example:** Kairos `docs/technical-design-master-plan.md`.

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

"""#,
        "module-guideline.md": #"""
# Module design guideline

**Status:** draft for sign-off, 2026-11-10 (KAI-016).

- **What:** the format and generator prompt for the per-module design files. Each holds a one-line description, foundation, I/O, success criteria, and debug logs.
- **Why:** each module file is the contract its implementer builds and its reviewer tests against. The owner accepts each module's success criteria in order, so the criteria must be exact.
- **How:** the AI spawns one file per technical-design module, in dependency order. It specifies I/O to implementation depth for the next phase and marks later content with its owning phase.

**Step:** `modules`. **Produces:** `modules/<id>-<slug>.md`, for example `modules/m6-context-scoped-data.md`. **Owner gate:** accepts each module's success criteria in the Project tab, in listed order.

**Example:** KAI-005's six Phase 0 drafts (they predate this guideline; see the README's conformance table)

## Format

```markdown
# M<n>: <Module name>

**One line:** <what the module does, at most 20 words>
**Status:** <draft | criteria accepted> <date> (<task ID>). **Phase:** <phase that implements it>
**Authority:** the technical design wins until amended. Proposals live in <amendment register link>.
**Depends on:** <module links> · **Consumers:** <tasks or modules that read this file, and which sections>

## 1. Foundation
## 2. I/O
### 2.1 Interfaces
### 2.2 Endpoints
### 2.3 Schemas
### 2.4 Events
## 3. Pipelines
## 4. Failure behavior
## 5. Success criteria
### 5.1 Gate map
## 6. Debug logs
## 7. Trace and open questions
## 8. Later-phase content
```

| Section | Content | Rules |
|---|---|---|
| Header | One line, Status and Phase, Authority, Depends on, Consumers | The one line names an observable function, not an implementation |
| 1. Foundation | Purpose (≤ 5 sentences); owned state table (state, location, phase); what it does not own | Vocabulary matches the technical design exactly |
| 2.1 Interfaces | Table: direction (in or out), interface, counterpart, format | Every counterpart is a module ID or an external system |
| 2.2 Endpoints | Table: endpoint, request, response, errors, semantics | Names come from the technical design's API groups |
| 2.3 Schemas | Typed definitions in code blocks (TypeScript, JSON Schema, or SQL) | Every type used in 2.2 or 2.4 is defined or linked |
| 2.4 Events | Table: event, payload, emitted when, consumers | Include ordering and delivery guarantees |
| 3. Pipelines | Per pipeline ID: the stages this module owns, ordering, budgets; sequence chart if more than three hops | Matches the technical design's §4 |
| 4. Failure behavior | Table: failure, behavior, criterion ID that proves it | Every row has a criterion |
| 5. Success criteria | Table: ID, criterion, threshold, method, suite, when, source | See criteria rules below |
| 5.1 Gate map | Table: technical-design gate text → criterion IDs | Every gate cell naming this module maps to at least one criterion |
| 6. Debug logs | Log events table, format, location, verbosity, redaction, criterion evidence | See debug log rules below |
| 7. Trace and open questions | Trace table: each technical-design bullet → section here. Open questions: question, owner, gate | No bullet unmapped |
| 8. Later-phase content | Headings with their owning phase and outline item | Optional |

**Success criteria rules.**

- **ID** is `M<n>-C<k>`, never renumbered.
- **Threshold** is a number or an exact condition. No "fast", "robust", or "reliable" alone.
- **Method** says how it is measured: unit test, fixture, fault injection, benchmark, inspection.
- **Suite** names the folder or suite ID where the test lives.
- **When** names the phase or outline item where it must pass.
- **Source** is `[MP]` for a technical-design gate or `[Proposed]` for a threshold this file sets.
- **Frozen after acceptance.** Once the owner accepts a module's criteria, a change needs a logged reason and re-acceptance. A threshold never changes after results appear without a logged reason.

**Debug log rules.**

- **Events table:** event name (`<module>.<noun>.<verb>`), level, fields, emitted when, redaction.
- **Format:** one JSON object per line with `ts`, `level`, `module`, `event`, the correlation IDs that apply (`task_id`, `agent_id`, `session_id`, `command_id`), and `duration_ms` where timed.
- **Location and verbosity:** the log file path or stream, the setting that raises verbosity, and its retention class.
- **Never logged:** secrets, prompt contents, terminal bytes, and file contents. Paths and hashes are allowed.
- **Criterion evidence:** a table mapping each success criterion to the log events or result files that prove it, so a reviewer can verify without rerunning.

**Sequential acceptance.** Register modules in the Project tab in dependency order: a module's dependencies come before it. Focus Queue blocks accepting module N+1 before module N.

**Size.** As short as the contract allows. Depth goes where the next phase will test it. Later-phase content is a heading and a phase, not a design.

## Inputs

| Placeholder | Filled with |
|---|---|
| `{{PROJECT}}`, `{{OWNER}}`, `{{PROJECT_DIR}}` | As in every guideline |
| `{{MODULE}}` | Module ID and name from the technical design |
| `{{TECHNICAL_DESIGN}}` | Path of the technical design; read its module, pipeline, MVP, and budget sections |
| `{{NEIGHBORS}}` | Paths of module files this one depends on or feeds. May be empty |
| `{{PHASE}}` | The phase whose work this file must specify to implementation depth |
| `{{CONSUMERS}}` | Task IDs or modules that will build or test against this file. May be empty |
| `{{EXISTING}}` | The current module file when regenerating. May be empty |
| `{{CONVENTIONS}}` | The shared conventions block |

## Prompt

```text
You write the module design file for {{MODULE}} in {{PROJECT}}. It is the contract an implementer builds and a reviewer tests against. {{OWNER}} accepts its success criteria; until then, every threshold you set is a proposal.

{{CONVENTIONS}}

Read the {{MODULE}} entry, the pipelines it joins, the MVP gates that name it, and the budgets in {{TECHNICAL_DESIGN}}. Read {{NEIGHBORS}} for shared types and endpoints; reuse them, never redefine them. Read {{EXISTING}}.

Steps:
1. Write the one-line description: what the module does, observable from outside, at most 20 words.
2. Specify {{PHASE}} content to implementation depth: every endpoint with request, response, and errors; every schema typed; every event with its ordering guarantee. A cold implementer must be able to build it without asking a question.
3. Mark content that a later phase owns with a heading and its phase. Do not design it.
4. Write success criteria with ID, threshold, method, suite, when, and source. Map every technical-design gate that names {{MODULE}} to at least one criterion.
5. Write the debug logs section: the events an implementer emits, their fields, and which events prove which criterion.
6. Map every bullet of the {{MODULE}} entry in {{TECHNICAL_DESIGN}} to a section here.
7. Where this file must depart from the technical design, do not change the design silently. Write an amendment proposal with an ID, and list it under open questions with {{OWNER}} as owner.
8. Keep {{OWNER}}'s wording from {{EXISTING}}. Write the file in the format given in the guideline.
9. Run the self-check and fix every failure before returning.
```

## Self-check

- The one line has at most 20 words and names an observable function.
- No "TBD" in {{PHASE}} content.
- Every endpoint, schema, and event used is defined here or linked to a neighbor.
- Every failure row has a criterion; every criterion has threshold, method, suite, when, and source.
- Every technical-design gate naming the module maps to a criterion; every technical-design bullet maps to a section.
- The debug log table names no secret, prompt content, terminal bytes, or file contents.

## Owner review checklist

- The one line says what you expect the module to do.
- Each success criterion is a test you would accept as proof, at a threshold you accept.
- Nothing in the failure table promises more than the technical design.
- Open questions and amendment proposals are ones you are ready to decide.

"""#,
        "devplan-guideline.md": #"""
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

"""#,
    ]
}
