# A/B scoring sheet: output contract insert

Use one sheet per session output. Score the final report (or the longest
status report) from each run. Time the 10-second test with a watch if you can.

## 10-second test (do first, before reading closely)

After 10 seconds of looking at the output, can you state:

- [ ] What task this is and what stage it is in
- [ ] What the result was
- [ ] What you need to do next

## Contract compliance (field by field)

| Field | Present | Notes |
|---|---|---|
| Stage badge with artifact | ☐ | Derived from artifacts, or self-declared? |
| BLUF ≤2 sentences, cold-readable | ☐ | |
| What/Why/How ≤100 words | ☐ | Concrete paths/IDs, or abstractions? |
| "How we know" is command + result | ☐ | Or prose assertion? |
| Decision log: what / why / how-verified | ☐ | |
| Justification present per major choice | ☐ | Rejected alternatives named? |
| "Not verified" items explicit | ☐ | Named stage that closes each gap? |
| Big-picture fit: N/A with reason, or earned | ☐ | |
| QA instructions executable cold | ☐ | Exact commands + expected result? |
| Next steps with decision/diagnostics | ☐ | |
| Omitted sections marked `N/A — reason` | ☐ | Any silently dropped? |

## Language spot-checks

- [ ] No sentence over ~25 words in the summary sections
- [ ] No filler: restated request, self-praise, "great question"
- [ ] No unsupported "works" / "done" / "should be fixed"
- [ ] Facts stated once (no prose re-narrating a table)
- [ ] Code cited as `path:line`

## Comparison

| | Without insert | With insert |
|---|---|---|
| Time to answer: what changed? | | |
| Time to answer: is it verified? | | |
| Time to answer: what do I do next? | | |
| Claims lacking evidence (count) | | |
| Total report length (lines) | | |

Watch for failure modes of the insert itself: dense fragments routing around
the word budget, boilerplate justifications ("this improves code quality"),
N/A used to dodge required justification, stage badge asserted without an
artifact.
