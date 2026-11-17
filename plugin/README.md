# keydillo plugin for Claude Code

Adds keydillo's skill, MCP tools (`status`, `list_services`, `request_secret`) and its PreToolUse guard hook to Claude Code.

It needs the keydillo Mac app, which holds the keys. If the app is missing, Claude is told how to install it at the start of each session and the hook stays out of the way.

```
/plugin marketplace add Ephibbs/keydillo
/plugin install keydillo@keydillo
```

The skill text is generated from `App/Sources/ClaudeConnector.swift` by `scripts/sync-plugin-skill.py`. Edit it there.
