#!/usr/bin/env python3
"""Render Docs/TOKEN_AUDIT.md to Docs/TOKEN_AUDIT.pdf.

Uses a small stdlib markdown converter (the report uses only headings, tables,
lists, bold, code, links, and fenced blocks) and the system WeasyPrint CLI.
Mermaid sources are typeset as monospace diagrams; WeasyPrint runs no
JavaScript. Fully offline; no model calls.
"""
import html
import re
import subprocess
import sys
from pathlib import Path


def inline(text):
    text = html.escape(text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    return text


def convert(markdown_text):
    lines = markdown_text.split("\n")
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("```"):
            lang = line[3:].strip()
            block = []
            i += 1
            while i < len(lines) and not lines[i].startswith("```"):
                block.append(lines[i])
                i += 1
            i += 1
            cls = "diagram" if lang == "mermaid" else "code"
            out.append(f'<pre class="{cls}">{html.escape(chr(10).join(block))}</pre>')
            continue
        if line.startswith("|"):
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                rows.append(lines[i])
                i += 1
            header = [c.strip() for c in rows[0].strip("|").split("|")]
            body = [r for r in rows[1:] if not re.match(r"^\|[\s:|-]+\|$", r)]
            out.append("<table><thead><tr>"
                       + "".join(f"<th>{inline(c)}</th>" for c in header)
                       + "</tr></thead><tbody>"
                       + "".join(
                           "<tr>" + "".join(f"<td>{inline(c.strip())}</td>"
                                            for c in r.strip("|").split("|")) + "</tr>"
                           for r in body)
                       + "</tbody></table>")
            continue
        match = re.match(r"^(#{1,4})\s+(.*)$", line)
        if match:
            level = len(match.group(1))
            out.append(f"<h{level}>{inline(match.group(2))}</h{level}>")
            i += 1
            continue
        if re.match(r"^\s*(-|\d+\.)\s+", line):
            tag = "ul" if line.lstrip().startswith("-") else "ol"
            items = []
            while i < len(lines) and re.match(r"^\s*(-|\d+\.)\s+", lines[i]):
                items.append(re.sub(r"^\s*(-|\d+\.)\s+", "", lines[i]))
                i += 1
            out.append(f"<{tag}>" + "".join(f"<li>{inline(t)}</li>" for t in items) + f"</{tag}>")
            continue
        if line.strip() == "":
            i += 1
            continue
        out.append(f"<p>{inline(line)}</p>")
        i += 1
    return "\n".join(out)


STYLE = """
body { font-family: -apple-system, Helvetica, sans-serif; font-size: 10.5pt;
       margin: 2.2cm; color: #1a1a1a; line-height: 1.45; }
h1 { font-size: 17pt; border-bottom: 2px solid #444; padding-bottom: 6px; }
h2 { font-size: 13.5pt; margin-top: 1.4em; }
h3 { font-size: 11.5pt; margin-top: 1.2em; }
table { border-collapse: collapse; width: 100%; font-size: 8.5pt; margin: 0.8em 0; }
th, td { border: 1px solid #999; padding: 4px 6px; text-align: left; vertical-align: top; }
th { background: #eee; }
pre { border: 1px solid #ccc; border-radius: 4px; padding: 8px 10px;
      font-size: 8pt; white-space: pre-wrap; word-wrap: break-word; }
pre.diagram { background: #f6f8fa; font-family: Menlo, monospace; }
pre.code { background: #f0f0f0; font-family: Menlo, monospace; }
code { font-family: Menlo, monospace; font-size: 9pt; background: #f0f0f0;
       padding: 1px 3px; border-radius: 3px; }
a { color: #1a5fb4; text-decoration: none; }
"""


def render(markdown_path, pdf_path):
    markdown_path = Path(markdown_path)
    pdf_path = Path(pdf_path)
    body = convert(markdown_path.read_text())
    html_path = pdf_path.with_suffix(".html")
    html_path.write_text(
        f"<html><head><meta charset='utf-8'><style>{STYLE}</style></head>"
        f"<body>{body}</body></html>"
    )
    subprocess.run(["weasyprint", str(html_path), str(pdf_path)], check=True)
    html_path.unlink()
    return pdf_path


if __name__ == "__main__":
    root = Path(__file__).parents[1]
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "Docs/TOKEN_AUDIT.md"
    target = Path(sys.argv[2]) if len(sys.argv) > 2 else source.with_suffix(".pdf")
    print(render(source, target))
