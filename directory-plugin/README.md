# keydillo

Let Claude use your API keys without seeing them.

[keydillo](https://github.com/Ephibbs/keydillo) is a free, open-source Mac menu-bar app. Your API keys stay in your Mac's Keychain, behind Touch ID, and your `.env` files hold placeholders instead. When a program you run with `kd` in front calls an API, keydillo asks for Touch ID and adds the real key on the way out, only to that key's site. Claude never sees the key, and committing your `.env` leaks nothing.

## What this plugin does

It adds one skill that teaches Claude how to work with keydillo:

- Put `kd` in front of commands that call APIs (`kd npm run dev`, `kd python app.py`), without making a fuss about it.
- Treat `keydillo:` values in `.env` files as the normal values for the project, and never ask you to paste a key into the chat.
- Use a key's local base URL for tools `kd` can't cover, such as Go, Rust and Docker.
- Keep secret keys out of frontend code (`NEXT_PUBLIC_`, `VITE_` and similar) and suggest a server route instead.
- If the keydillo app isn't installed, tell you how to get it.

The plugin contains only that skill. It runs nothing, makes no network requests and stores nothing.

## Setup

1. Install the keydillo app:

   ```
   brew install --cask ephibbs/keydillo/keydillo
   ```

   Or download it from the [latest release](https://github.com/Ephibbs/keydillo/releases/latest).
2. Open keydillo and choose **Connect** in its setup. That adds keydillo's tools to Claude Code and a check that reminds Claude to put `kd` in front of commands.

## Privacy

keydillo has no telemetry. Keys never leave your Mac except in the API requests you approve, sent straight to the provider you set for each key.

## License

MIT. See [LICENSE](LICENSE).
