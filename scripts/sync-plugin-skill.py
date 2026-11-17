#!/usr/bin/env python3
"""Copies the skill text from App/Sources/ClaudeConnector.swift into the Claude Code plugin and skills/, so both stay identical."""
import re, pathlib, textwrap
root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "App/Sources/ClaudeConnector.swift").read_text()
body = re.search(r'static let skill = """\n(.*?)\n\s*"""', src, re.S).group(1)
out = textwrap.dedent(body).replace('\\(', '(') + "\n"
# plugin/ for the Claude Code plugin; skills/ at the top so `npx skills add Ephibbs/keydillo` finds it.
for rel in ["plugin/skills/keydillo/SKILL.md", "skills/keydillo/SKILL.md"]:
    (root / rel).parent.mkdir(parents=True, exist_ok=True)
    (root / rel).write_text(out)
    print(rel, "updated")
