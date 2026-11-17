#!/usr/bin/env python3
"""Copies the skill text from App/Sources/ClaudeConnector.swift into the Claude Code plugin, so both stay identical."""
import re, pathlib, textwrap
root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "App/Sources/ClaudeConnector.swift").read_text()
body = re.search(r'static let skill = """\n(.*?)\n\s*"""', src, re.S).group(1)
out = textwrap.dedent(body).replace('\\(', '(') + "\n"
(root / "plugin/skills/keydillo/SKILL.md").write_text(out)
print("plugin/skills/keydillo/SKILL.md updated")
