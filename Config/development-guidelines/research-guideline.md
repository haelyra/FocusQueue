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
