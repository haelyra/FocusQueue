# Compact architecture context

Architecture context is an explicit local indexing operation. It helps an agent choose the relevant source files before reading a large repository. It does not call an LLM, invoke a provider, use an API key, or submit a prompt. The normal signed-in subscription CLI remains the route for agent work.

## Generate beside a task plan

Run `focus-queue-session architecture <TASK-ID> [repository-path]` after a task context exists. The CLI places the generated index and checksum state beside the task's central plan. Existing authored module cards remain in the repository under `Docs/Architecture`.

The service API is `ArchitectureContextService.generate(repositoryRoot:outputDirectory:cardDirectory:budget:)`. It is synchronous and throwing. `cardDirectory` defaults to the repository's `Docs/Architecture` and must remain inside that repository. The returned report identifies the generated files and accepted authored card files for explicit registration in durable history.

The output files are:

- `architecture-index.generated.md`: compact navigation, authored overview paragraphs, source references, checksum prefixes, and status.
- `architecture-state.generated.json`: complete accepted source references, baseline/current SHA256 values, skipped-card notes, budget and truncation metadata.

Only output files carrying the expected generator identity are refreshed. A conflicting authored file or symbolic link causes an error before outputs are written. Ordinary indexing does not modify baselines or mark a summary reviewed.

## Author a module card

A card starts with one JSON metadata comment, followed by its title and a compact explanatory paragraph:

```markdown
<!-- fq-architecture: {"id":"example","title":"Example module","sources":[{"path":"Sources/Example.swift","sha256":"FULL_64_CHARACTER_SHA256"}]} -->

# Example module

Describe the actual entry point, the mechanism it delegates to, and the main boundary a contributor must preserve.

## Follow the code

Link the relevant source files and name concrete symbols. Include meaningful existing checks and one important failure mode.
```

Use repository-relative source paths. Compute a baseline with `shasum -a 256 Sources/Example.swift` after reviewing that source and the card together. A missing or malformed baseline is accepted as unverified. Refresh a baseline only after reviewing the changed source and adjusting the explanation as needed. Hash matching proves byte equality to that baseline, not correctness of the explanation.

The checked-in [module index](Architecture/index.md) links four initial cards. Their summaries were authored from the source present when their baseline checksums were recorded. Their semantic accuracy still requires review for the task at hand.

## Staleness and budgets

| Status | Meaning |
| --- | --- |
| `source-current` | Every accepted source matches its recorded SHA256; summary semantics remain unverified. |
| `stale` | At least one referenced file changed or is missing. Read source before relying on the summary. |
| `unverified` | A baseline, readable reference, or budget coverage is incomplete. |

Individual source references report `matching`, `changed`, `missing`, `excluded`, or `unverified`. The default budget is 12 cards, 12 source references per card, 8 KiB per authored card, 1 MiB per source file, and 8,000 bytes for the generated Markdown index. The JSON state records omissions and accepted reference details. Repeated runs with unchanged inputs produce identical output bytes.

Indexing reads only source references explicitly listed in authored cards. It skips hidden paths, secret/credential names, generated/vendor/build directories, unsupported source extensions, path traversal, and source symlinks. It never copies source file contents into the index. These exclusions are intentionally conservative; an excluded reference requires direct source review rather than an automatically trusted summary.

This is a navigation layer, not a semantic code search engine or automatic architecture inference system. Read the compact index, choose the relevant card, inspect stale or important source paths, and keep the central plan focused on decisions and acceptance evidence.
