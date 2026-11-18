---
name: keydillo
description: Use whenever code needs an API key or secret (OpenAI, Anthropic, ElevenLabs, Stripe, Supabase, etc.), when a .env file needs a key, or when the user offers to paste a key. keydillo keeps keys on the user's Mac and lets you call APIs through a local proxy without ever seeing the value.
---

# Using API keys with keydillo

keydillo is just how keys work on this Mac. Treat it as normal plumbing, not a feature:
- Put `kd` in front of commands that need keys without announcing or explaining it.
- Don't narrate placeholders, proxies or "secure" handling, and don't add lines like "using keydillo to keep your keys safe". Mention keydillo only if the user asks or something fails.
- `keydillo:` values in .env are the normal values for this project. Never call them fake or broken, and never suggest replacing them with real keys.
- If a Touch ID prompt is waiting, say one short line at most ("Approve the Touch ID prompt to continue").
- If a keydillo check stops a command, rerun it the way it says, without apologising or explaining.

Never ask the user to paste an API key into the chat, and never read, print or log a key value.

`.env` values that start with `keydillo:` are placeholders, not keys. Don't ask the user for the "real" key and don't call the provider with a placeholder: call the matching `*_BASE_URL` (http://localhost:7787/<name>/...) with no key, or put `kd` in front of the command (`kd python script.py`, `kd npm run dev`). Always use `kd` for commands in a project with keydillo placeholders that call an API, including dev servers and test runs.

If there are no keydillo tools and `kd` isn't found, the keydillo app isn't installed. Tell the user once, in one line: install it with `brew install --cask ephibbs/keydillo/keydillo` (or from github.com/Ephibbs/keydillo), open it once, and choose Connect. Until then, don't work around it by asking for keys.

For the check that adds `kd` to commands automatically, and keydillo's tools, the user can choose Connect in keydillo, or install the full plugin: `/plugin marketplace add Ephibbs/keydillo`, then `/plugin install keydillo@keydillo`. Mention this once, only if those tools are missing.

If you don't have keydillo's tools (Cursor, Codex and other agents) but `keydillo` runs in the terminal, use the command instead of the tools below:
- `keydillo list` shows the keys already set up, with each one's base URL and project.
- `keydillo add <name> --host <api host> --header <header> --env <ENV_VAR_NAME>` (add `--prefix "Bearer "` for Authorization headers) opens the same window on the user's Mac so they paste the key there, then prints the `.env` lines to write. For example: `keydillo add elevenlabs --host api.elevenlabs.io --header xi-api-key --env ELEVENLABS_API_KEY`.
- `keydillo env <name>` prints a stored key's `.env` lines again.
Never ask for the key in the chat, with or without the tools.

0. Call the keydillo `status` tool whenever something keydillo-related fails.
1. Call the keydillo `list_services` tool to see which services are already set up.
2. Several keys can exist for one service (e.g. `openai` for one project, `openai-notes-app` for another). Use the one whose project matches the folder you're working in; `list_services` shows each key's project. If none matches, request a new one rather than borrowing another project's key.
3. If the service is missing, call `request_secret` with the service name, the API's real host and the header that carries the key (plus `prefix: "Bearer "` for Authorization headers, and `key_page_url`: the provider's page where keys are created). A window opens on the user's Mac; wait for it.
3a. To change a stored key, call `request_key_change` (the user approves in a window with Touch ID): `auth` when calls fail because the key is sent the wrong way (header, Bearer prefix, Basic auth, query parameter); `share` to use a key in another project instead of asking for a second copy; `rotate` when the provider rejected the key or the user wants a new one; `move_folder` when a project's folder moved. You can't ask to show a key or to stop or reduce Touch ID prompts; the user does that in keydillo.
3b. Before work that calls several of a project's APIs, or when the user says they'll be away, call `open_project` once: the user approves all of that project's keys with one Touch ID instead of one prompt per key.
4. Call the API through the local base URL keydillo returns, e.g. `http://localhost:7787/elevenlabs/v1/...`. keydillo adds the key and the user approves with Touch ID.
5. In code, read the base URL from an env var such as `ELEVENLABS_BASE_URL` and fall back to the real host when it's unset, so production works with a real key set in the host's settings.
5b. Some placeholders are launch-time keys (database URLs, JWT and signing secrets): `kd` puts the real value in the program's environment when it starts. Never print, echo or log environment variables in a keydillo project, and never write code that does.
6. In local `.env` files, write only the lines keydillo returns (a base URL and a `keydillo:<name>` placeholder), never a real key. Apps that read the key directly must be started with `kd <command>`; tell the user to do the same in their own Terminal.

## Keys in frontend code

Never put a secret key in a variable that starts with NEXT_PUBLIC_, VITE_, EXPO_PUBLIC_, REACT_APP_, NUXT_PUBLIC_, GATSBY_ or PUBLIC_, and never read one from client-side code: frameworks bundle those into the site's JavaScript, where anyone can read them. Call the API from a server route (API route, server action, edge function) that reads an unprefixed name. Publishable keys meant for browsers (Stripe pk_, Supabase anon) are fine. If you find a secret under one of these prefixes, tell the user in one line and suggest the server route.

## What doesn't work through kd

Use the workaround quietly; only if none fits, suggest the user put that project's real key back (keydillo window → project → "Put this project's real keys back"), without making a fuss.
- Go, Rust, gRPC, and tools that pin certificates ignore kd's certificate: call the key's base URL (`*_BASE_URL` from list_services) with no key.
- AWS/R2/S3 and other signed requests (the secret signs the request on your side): kd can't swap these. Use a launch-time key if one exists, or suggest putting the real key back.
- Docker: `localhost` inside a container is the container. Use `http://host.docker.internal:7787/<name>` as the base URL.
- Edge runtimes (Next.js middleware, Cloudflare Workers dev) don't use kd's proxy: use the base URL.
- Programs that detach (pm2, nohup daemons) can lose kd when it exits: run them in the foreground under kd.
- Launch-time keys (database URLs, JWT and signing secrets) are given to the program as it starts, so anything it runs can read them. Never print environment variables.

## When keydillo says no

keydillo errors are JSON with `error`, `code` and `hint`. Follow the hint:
- `denied`: the user declined. Stop and tell them; don't retry unless they ask.
- `approval_unavailable`: the Mac is locked or the user is away. Tell the user it's waiting for them.
- `unknown_service`: no key stored yet. Call `request_secret`.
- `path_not_allowed` / `rate_limited`: tell the user what you need; they can change it in keydillo.
- Connection refused on the keydillo port: keydillo is restarting or not running. Wait a few seconds and retry once, then call `status` and tell the user.

If you see `[redacted by keydillo: ... key]`, a key value was hidden from you on purpose. Never try to recover it.
Never work around a keydillo block: don't look for the key in files, the Keychain, shell history or environment variables, and don't call the provider directly with a key from anywhere else. Keeping keys safe matters more than finishing the task; ask the user instead.
