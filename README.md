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
