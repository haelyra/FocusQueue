# Data extractor experiments (FOC-010)

Small-model extraction of durable facts from user prompts, routed to user /
project / task / new-task / inbox scopes. Design and policy rules come from
FOC-014 (`Docs/Experiments/Context-Routing-Plan.md`, branch
`experiment/proactive-context-routing`). Implementation:
`Scripts/focus_queue_extractor.py`, modeled on the agent-placement classifier
`Scripts/focus_queue_placement.py`: one structured CLI model call, then
deterministic policy guards before anything is recorded. Shadow mode remains
the default: proposals go to `extraction-ledger.sqlite`. Explicit
`extract --apply` writes accepted memories to scoped `data.md` files and
creates deferred tasks through the queue backend. No app hook calls it yet.

## Fixtures

`fixtures/` holds six labeled cases: the FOC-014 landing-page dry run (4 gold
placements), a coding-preference + deferred-deliverable mix, an explicit
user-scope preference, a scope-inflation trap (strong wording, project scope
only), a pure-work prompt with zero gold placements, and a
deferred-to-existing-task + speculation mix (speculation must be abstained).

## Results (2026-10-19, live CLI calls)

| Model | Runs | Mean recall | Mean precision | Avg latency | Tokens per call |
| --- | --- | --- | --- | --- | --- |
| claude/haiku (v3, 2 samples × 6 fixtures) | 12 | 0.958 | 1.000 | 5.0 s | ~4 uncached in, ~660 cache-created, ~2.9 k cache-read, **~750 out** |
| codex/gpt-6-luna (1 × 6) | 6 | 0.833 | 0.945 | 4.0 s | ~18–19 k total (reasoning included, as reported by CLI) |

Raw reports: `results/eval-claude-haiku*.json`, `results/eval-codex-gpt6luna.json`.

### Average token count (claude/haiku, warm cache)

- **Fresh tokens per extraction: ~1.0–1.5 k** (cache-created ≈ 365–870 +
  uncached input ≈ 2–8 + output ≈ 140–690). The static catalog/instructions
  prefix rides the prompt cache (cache-read is billed at a fraction of fresh
  input).
- Long prompts raise output cost: the landing-page fixture (≈1.2 k chars)
  produced 1.8–2.6 k output tokens because every atom carries a verbatim
  quote. Output dominates cost, not input.
- codex/gpt-6-luna reports ~13× more total tokens (reasoning tokens) with
  worse precision: it over-extracted (created tasks out of current-work
  discussion) and once extracted nothing at all.

## Findings

1. **Confidence calibration on new_task is the weak spot.** v1 instructions
   scored explicit deferrals 0.5–0.7 and the threshold guard correctly
   inboxed them, but recall suffered. Adding "explicit postponement of a
   concrete deliverable ⇒ confidence ≥ 0.9" raised recall 0.833 → 0.958 with
   no precision loss (v2 → v3).
2. **Policy guards earn their keep.** The scope-inflation trap never reached
   user scope (guard requires explicit cross-project wording), and the
   low-confidence deferrals were abstained rather than misplaced — inbox
   abstentions hurt recall, never precision.
3. **Instability is real but bounded.** Across 4 landing-page runs, the
   Instagram new_task was extracted twice and missed twice (the prompt says
   "I need to make" — arguably the user's own action). The all-gray theme
   dipped to 0.80 confidence once and was abstained. 10/12 v3 runs were
   perfect; no run produced a wrong durable placement.
4. **Grader needs text coverage, not just destination+target.** Two
   new_task golds in one project cross-matched until grading required ≥ 0.5
   gold content-word coverage (fixed in v3).

## Reproduce

```sh
python3 -m unittest Tests.test_focus_queue_extractor
python3 Scripts/focus_queue_extractor.py eval --fixtures Experiments/DataExtractor/fixtures \
  --provider claude --samples 2 --output Experiments/DataExtractor/results/eval-claude-haiku.json
```

The FOC-010 evidence PDF records a live landing-page run in a scratch project:
the gray-theme sentence went to project data, the short-video sentence went
to WEB-002 data, and WEB-003/WEB-004 were created. Replaying the same accepted
record added no duplicate facts or tasks.

## Next

- Corpus expansion (the FOC-014 plan targets ~600 labeled prompts; six
  fixtures is a smoke test, not a gate).
- Capture hook (UserPromptSubmit → normalized event) feeding `extract` in
  shadow mode on real sessions.
- Broader calibration before automatic apply on live prompts.
