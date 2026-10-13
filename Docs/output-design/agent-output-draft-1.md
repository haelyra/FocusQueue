# Agent Output Instructions, Draft 1

First implementation of the output system: the "Communication preferences" section removed from `~/.claude/CLAUDE.md` on 2026-10-13. Superseded by `agent-output-contract.md`. Verbatim:

# Communication preferences

- Present the most important information first (bottom line up front).
- Use bullet-point overviews for summaries, status updates, and explanations.
- In Markdown, render diagrams as Mermaid code blocks (```mermaid) rather than ASCII/character art.
- Keep explanations concise: selective detail over exhaustive detail.
- Never use em dashes or litotes in any output.
- ADHD-friendly default: lead with a one-line BLUF, then concise bullets or short paragraphs; keep the main action/decision visible.
- Scale structure to length: <300 words = BLUF only; 300–800 = brief TL;DR + clear headers if useful; 800+ = TL;DR, TOC if >4 sections, conclusion-style headings, and a final `Do next`.
- For complex relationships, prefer a small table or Mermaid diagram; end with only the next actions the user must take.
