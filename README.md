# keydillo

A macOS menu-bar app that lets AI coding agents use API keys without seeing them.
Keys live in the Keychain; agents call a localhost proxy that injects auth headers
after Touch ID approval.

Status: pre-milestone 1. See docs/decisions.md.

## keydillo run

`keydillo run -- <command>` starts a command with its HTTPS traffic going through a small per-run proxy.
Requests to a stored service's host that carry a `keydillo:<name>` placeholder (as written by import or
`request_secret`) are handed to the keydillo app, which asks for Touch ID and adds the real key.
Everything else passes through untouched. The proxy's certificate is trusted only by that command.

Tested: curl, Python `requests`, Node (proxy env support needed: Node 24+, or code that honours HTTPS_PROXY).
Known gaps: Apple's bundled Python 3.9 `urllib` ignores `SSL_CERT_FILE` (use `requests` or a Homebrew Python);
Node 22's built-in `fetch` ignores proxy settings; tools that pin certificates won't work. Use the base-URL
approach (`<NAME>_BASE_URL`) for those.

## Credits

Service logos are from [Simple Icons](https://simpleicons.org) (CC0-1.0). Logos are trademarks of their owners and are used only to identify each service.

## Security model and limits

keydillo is responsible for keys **while it's installed**. Copies that existed before you installed it (old
`.env` files, shell history, git history, provider dashboards, chat transcripts) and copies you make yourself
afterwards (the Readout, Show key, `keydillo run` raw mode) are outside what it can protect.

What it does protect while installed:
- Keys live in a private Keychain access group that only keydillo's signed binary can use, with Touch ID required to read them. `security find-generic-password` and other apps can't see them.
- Agents only get local addresses and `keydillo:<name>` placeholders. The proxy adds the key on the way out, only to that key's host, and scrubs the key from responses.
- Web pages can't use keydillo: cross-site browser requests and non-localhost Host headers are refused.

Known limits, in scope:
- macOS lets your login password stand in for Touch ID. Anyone who knows it can approve requests.
- During an approval window (e.g. "every 15 minutes" or "once per session"), a program can *use* the key through the proxy without a new prompt. It still can't *read* the key.
- Parallel calls from the same program within 3 seconds of an approval share it, instead of prompting once per call.
- A program you approve can do anything that key allows with the provider. keydillo guards the key, not what you do with it.
