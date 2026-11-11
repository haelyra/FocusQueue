# Module design guideline

**Status:** experimental and optional (2026-11-10). Shown when a project turns on Planning guidelines. Module files never block a phase.

- **What:** the format and generator prompt for the per-module design files. Each holds a one-line description, foundation, I/O, success criteria, and debug logs.
- **Why:** each module file is the contract its implementer builds and its reviewer tests against. The owner accepts each module's success criteria in order, so the criteria must be exact.
- **How:** the AI spawns one stub per technical-design module, in dependency order. A file reaches implementation depth only when the phase that builds its module starts; later content stays a heading with its owning phase.

**Step:** `modules` (optional). **Produces:** `modules/<id>-<slug>.md`, for example `modules/m6-context-scoped-data.md`. **Owner gate:** optional; accepts each module's success criteria in the Project tab, in listed order. Neither the step nor acceptance blocks a phase.

## Distribution and maturity

- **One file per module, not per task or feature.** Module IDs come from the technical design's §3. Several tasks can serve one module; a task links to it with `focus-queue-session development <PROJECT-ID> link <TASK-ID> <step-id> <module-id>`.
- **Location.** The repository's `docs/modules/` when the project has a repository, otherwise the project folder's `modules/`. The repository copy is the source of truth. Focus Queue shows both folders in the Project tab's module files, so never copy a file between them.
- **Fill just in time.** Software plans change, so depth follows the work, not the calendar. The file's **Status** line names its maturity:

| Maturity | When | Filled sections | Rule |
|---|---|---|---|
| `stub` | The module is registered, usually in Planning | Header, §1 Foundation purpose, §7 open questions | Every other section is a heading only |
| `phase-ready` | The first task of the phase that builds the module starts | Everything that phase builds or tests, to implementation depth | No "TBD" in that phase's content |
| `criteria accepted` | The owner accepts §5 | Unchanged | Criteria freeze; changes need a logged reason |

A stub is a valid file. Phase-ready content is written by the task that implements the module, before it writes code.

## Format

```markdown
# M<n>: <Module name>

**One line:** <what the module does, at most 20 words>
**Status:** <stub | phase-ready | criteria accepted> <date> (<task ID>). **Phase:** <phase that implements it>
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
| `{{PHASE}}` | The phase whose work this file must specify to implementation depth. Empty writes a stub |
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
2. If {{PHASE}} is empty, write a stub: the header, §1 purpose, and §7 open questions, with every other section as a heading. Set Status to stub and skip to step 8. Otherwise specify {{PHASE}} content to implementation depth: every endpoint with request, response, and errors; every schema typed; every event with its ordering guarantee. A cold implementer must be able to build it without asking a question.
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
- A stub fills only the header, §1 purpose, and §7; other sections are headings.
- A phase-ready file has no "TBD" in {{PHASE}} content.
- Every endpoint, schema, and event used is defined here or linked to a neighbor.
- Every failure row has a criterion; every criterion has threshold, method, suite, when, and source.
- Every technical-design gate naming the module maps to a criterion; every technical-design bullet maps to a section.
- The debug log table names no secret, prompt content, terminal bytes, or file contents.

## Owner review checklist

- The one line says what you expect the module to do.
- Each success criterion is a test you would accept as proof, at a threshold you accept.
- Nothing in the failure table promises more than the technical design.
- Open questions and amendment proposals are ones you are ready to decide.
