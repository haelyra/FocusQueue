# Concept declaration guideline

**Status:** experimental (2026-11-10). Shown when a project turns on Planning guidelines.

- **What:** the format and generator prompt for `concept.md`, the project's one-page statement of the main idea and its functional criteria.
- **Why:** every later planning file traces to these criteria. A vague concept shows up later as scope drift and untestable gates.
- **How:** the AI asks clarifying questions first, then drafts from the owner's answers and any existing notes. The owner marks the draft reviewed.

**Step:** `concept`. **Produces:** `concept.md`. **Owner gate:** answers the question form, then marks the file reviewed.

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
