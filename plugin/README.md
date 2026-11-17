# keydillo for Claude Code

Let Claude use your API keys without seeing them.

[keydillo](https://github.com/Ephibbs/keydillo) is a free, open-source Mac menu-bar app that keeps API keys in your Mac's Keychain, behind Touch ID. Your `.env` files hold placeholders instead of keys. When a program you run with `kd` in front calls an API, keydillo asks for Touch ID and adds the real key on the way out, only to that key's site. Claude never sees the key.

This plugin connects Claude Code to the keydillo app. It needs the app, which you can install with Homebrew:

```
brew install --cask ephibbs/keydillo/keydillo
```

Then add the plugin in Claude Code:

```
/plugin marketplace add Ephibbs/keydillo
/plugin install keydillo@keydillo
```

## What the plugin adds

- **A skill** that tells Claude how to work with keydillo: put `kd` in front of commands that call APIs, treat `keydillo:` values in `.env` files as normal, never ask you to paste a key into the chat, and keep secret keys out of frontend code.
- **MCP tools** from the keydillo app: `status`, `list_services` (key names and sites only, never values), `request_secret` (opens keydillo's window so you can paste a key yourself), `open_project` and `request_key_change`. Every action that uses or changes a key asks you for Touch ID in the app.
- **Hooks**:
  - At session start, checks whether the keydillo app is installed. If it isn't, Claude is told where to get it.
  - Before a Bash or WebFetch call, checks whether the command runs a program in a keydillo project without `kd`, and if so asks Claude to add it. It never changes the command itself.
  - After a Bash call, if a provider rejected a placeholder, adds a short note for Claude on how to fix it.

## What it runs, and what it sends

- Every hook and the MCP server run `bin/keydillo-cli`, a short shell script in this plugin. It looks for the keydillo app in `/Applications`, `~/Applications`, or the link keydillo keeps in `~/.local/bin`, checks with `codesign` that it is signed by keydillo's developer team (2JARAJYAYY), and then runs the app's own `keydillo` command. If the app is missing or the signature doesn't match, nothing runs and no command is blocked.
- The plugin itself makes no network requests. The keydillo app talks to Claude Code only on your Mac, over a local socket and `localhost`. The only requests that leave your Mac are the API calls you approve, which go straight to the provider you configured for each key.
- No telemetry, analytics or crash reporting.
- Keys and settings stay in your Mac's Keychain. The plugin never reads or stores a key value.

## Building keydillo yourself

The plugin only runs a keydillo signed by team 2JARAJYAYY, the official builds. If you build keydillo from source with your own signing team, change `TEAM` in `bin/keydillo-cli` to your team ID.

The skill text is generated from `App/Sources/ClaudeConnector.swift` by `scripts/sync-plugin-skill.py`.

## License

MIT. See [LICENSE](LICENSE).
