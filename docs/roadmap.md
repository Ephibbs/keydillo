# keydillo roadmap after launch

Rough sizes are Claude build hours.

1. **Local database proxy (Postgres first, 6 to 10 h; then MySQL and Redis).** Launch-time keys give a program its database URL, so the program can see the password. A proxy on localhost would accept the program's connection with a placeholder password and log in to the real database with the real one, so the password never enters the program.
2. **Local signing and encryption service (KMS-style), after the database proxy.** JWT and encryption secrets never enter the app: the app asks keydillo to sign a token or decrypt a value. Not drop-in; it needs per-library support (for example a NextAuth adapter) or changes to the app.
3. **Readable placeholders that say "run with kd".** Make the placeholder text itself the hint wherever a provider shows part of a rejected key.
4. **Per-project "use real keys in .env" switch** (undecided), paired with a Claude Code hook that blocks reading `.env` files in those projects.
5. **Opt-in system-wide keydillo certificate for Go and Rust**, so `kd` works for programs that only trust the macOS Keychain. Needs one admin prompt; limited to stored hosts.
6. **Daemons under `kd`** that detach right away (pm2, tmux): keep their access after `kd` exits. See docs/kd-known-failures.md.
