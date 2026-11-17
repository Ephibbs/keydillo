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
# The directory plugin can't carry hooks or tools, so it points to Connect (or the full plugin) for those.
extra = ("For the check that adds `kd` to commands automatically, and keydillo's tools, the user can choose Connect in keydillo, "
         "or install the full plugin: `/plugin marketplace add Ephibbs/keydillo`, then `/plugin install keydillo@keydillo`. Mention this once, only if those tools are missing.\n")
anchor = "Until then, don't work around it by asking for keys.\n"
assert anchor in out
(root / "directory-plugin/skills/keydillo/SKILL.md").write_text(out.replace(anchor, anchor + "\n" + extra, 1))
print("directory-plugin/skills/keydillo/SKILL.md updated")
