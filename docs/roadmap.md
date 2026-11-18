# Roadmap

What's planned after the first release, roughly in order.

1. **Local database proxy** (Postgres first, then MySQL and Redis). Today a launch-time key gives your program its database URL, so the program can see the password. A local proxy would accept the program's connection with a placeholder password and log in with the real one, so the password never reaches the program.
2. **Dev values for app secrets.** JWT, session and encryption secrets get a random development-only value written straight into `.env`, so local work needs no `kd` and the real secret never touches your machine's files. The real value stays in the Keychain for deploys, behind Touch ID. If you need the real value locally (a shared production database or auth service, or data you already encrypted locally), keydillo offers to keep the current value, and per-key put-back still works. Webhook signing secrets stay launch-time keys, because they must match the forwarder's own secret (for example `stripe listen`). A signing and encryption service that keeps secrets out of apps entirely comes later, only if people ask for it.
3. **Placeholders that explain themselves.** When a provider shows part of a rejected key, the placeholder text itself will say to run the command with `kd`.
4. **Go and Rust under `kd`.** `kd` sets each provider's base-URL variable (`OPENAI_BASE_URL`, `ANTHROPIC_BASE_URL` and so on) to keydillo's local address, and keydillo makes the real HTTPS call, so SDKs that read those variables work without trusting any certificate. A system-wide keydillo certificate for the rest stays parked until people ask for it.
5. **Background programs under `kd`.** Programs that detach right away (pm2, tmux) will keep working after `kd` exits.
6. **Keys in shell profiles.** Find keys exported in `~/.zshrc`, `~/.zprofile`, `~/.bashrc` and similar, offer them in the import window, and swap only the value for a placeholder, with a backup and "Put my real keys back" support.
7. **Touch ID for every change an API call makes (opt-in, per key).** A per-key option to ask for Touch ID on each mutating request (POST, PUT, PATCH, DELETE), such as Stripe charges and refunds, deletes or permission changes, while reads (GET) go through on the usual approval. Many APIs use POST for reads, such as OpenAI and Anthropic completions, so this suits APIs like Stripe and GitHub more than LLM APIs, and it stays off by default.
   - **Touch ID for a new kind of action.** keydillo would ask the first time a key does something it hasn't done before, grouping requests into patterns because IDs sit in paths (for example `POST /v1/refunds` or `/v1/customers/*`), and then remember it. A key that has only ever made charges couldn't quietly start issuing refunds.

## Exploring

- **Node and Python packages** (`npm i keydillo`, `pip install keydillo`): one import routes the app's requests through keydillo, so keys work where `kd` doesn't, such as IDE run buttons, notebooks and test runners.
- **Logins for browser agents, starting with Claude in Chrome.** The agent types a placeholder such as `keydillo:github-password` into the password field. When the form is submitted, a keydillo browser extension asks for Touch ID, checks that the page belongs to the site the password is for (the same idea as a key's host lock), swaps in the real password and lets the submit through. The agent only ever sees the placeholder and gets the logged-in session, not the password. A `keydillo fill <name>` tool would be a second way in, and the skill would teach agents to use placeholders. This needs the extension plus a native bridge to the app.

Ideas or requests: open an issue.
