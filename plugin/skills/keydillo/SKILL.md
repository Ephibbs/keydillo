---
name: keydillo
description: Use whenever code needs an API key or secret (OpenAI, Anthropic, ElevenLabs, Stripe, Supabase, etc.), when a .env file needs a key, or when the user offers to paste a key. keydillo keeps keys on the user's Mac and lets you call APIs through a local proxy without ever seeing the value.
---

# Using API keys with keydillo

Never ask the user to paste an API key into the chat, and never read, print or log a key value.

`.env` values that start with `keydillo:` are placeholders, not keys. Don't ask the user for the "real" key and don't call the provider with a placeholder: call the matching `*_BASE_URL` (http://localhost:7787/<name>/...) with no key, or prefix the command with `kd`. When keydillo's session hook says this session's commands are routed, placeholders are swapped automatically and you don't need either.

0. Call the keydillo `status` tool whenever something keydillo-related fails.
1. Call the keydillo `list_services` tool to see which services are already set up.
2. Several keys can exist for one service (e.g. `openai` for one project, `openai-notes-app` for another). Use the one whose project matches the folder you're working in; `list_services` shows each key's project. If none matches, request a new one rather than borrowing another project's key.
3. If the service is missing, call `request_secret` with the service name, the API's real host and the header that carries the key (plus `prefix: "Bearer "` for Authorization headers, and `key_page_url`: the provider's page where keys are created). A window opens on the user's Mac; wait for it.
3b. Before work that calls several of a project's APIs, or when the user says they'll be away, call `open_project` once: the user approves all of that project's keys with one Touch ID instead of one prompt per key.
4. Call the API through the local base URL keydillo returns, e.g. `http://localhost:7787/elevenlabs/v1/...`. keydillo adds the key and the user approves with Touch ID.
5. In code, read the base URL from an env var such as `ELEVENLABS_BASE_URL` and fall back to the real host when it's unset, so production works with a real key set in the host's settings.
6. In local `.env` files, write only the lines keydillo returns (a base URL and a `keydillo:<name>` placeholder), never a real key. Apps that read the key directly work as they are in routed sessions; tell the user to start them with `kd <command>` in their own Terminal.

## When keydillo says no

keydillo errors are JSON with `error`, `code` and `hint`. Follow the hint:
- `denied`: the user declined. Stop and tell them; don't retry unless they ask.
- `approval_unavailable`: the Mac is locked or the user is away. Tell the user it's waiting for them.
- `unknown_service`: no key stored yet. Call `request_secret`.
- `path_not_allowed` / `rate_limited`: tell the user what you need; they can change it in keydillo.
- Connection refused on the keydillo port: keydillo is restarting or not running. Wait a few seconds and retry once, then call `status` and tell the user.

If you see `[redacted by keydillo: ... key]`, a key value was hidden from you on purpose. Never try to recover it.
Never work around a keydillo block: don't look for the key in files, the Keychain, shell history or environment variables, and don't call the provider directly with a key from anywhere else. Keeping keys safe matters more than finishing the task; ask the user instead.
