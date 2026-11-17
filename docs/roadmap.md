# keydillo roadmap after launch

Rough sizes are Claude build hours.

1. **Local database proxy (Postgres first, 6 to 10 h; then MySQL and Redis).** Launch-time keys give a program its database URL, so the program can see the password. A proxy on localhost would accept the program's connection with a placeholder password and log in to the real database with the real one, so the password never enters the program.
2. **Readable placeholders that say "run with kd".** Make the placeholder text itself the hint wherever a provider shows part of a rejected key.
3. **Per-project "use real keys in .env" switch** (undecided), paired with a Claude Code hook that blocks reading `.env` files in those projects.
4. **Opt-in system-wide keydillo certificate for Go and Rust**, so `kd` works for programs that only trust the macOS Keychain. Needs one admin prompt; limited to stored hosts.
5. **Claude can request key changes** (site, header, how often it asks, project folder): a window showing the change, approved with Touch ID (1 to 1.5 h).
6. **Daemons under `kd`** that detach right away (pm2, tmux): keep their access after `kd` exits. See docs/kd-known-failures.md.
