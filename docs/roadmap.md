# Roadmap

What's planned after the first release, roughly in order.

1. **Local database proxy** (Postgres first, then MySQL and Redis). Today a launch-time key gives your program its database URL, so the program can see the password. A local proxy would accept the program's connection with a placeholder password and log in with the real one, so the password never reaches the program.
2. **Local signing and encryption service.** JWT and encryption secrets would stay in keydillo: your app asks keydillo to sign a token or decrypt a value instead of holding the secret. This needs support per library (for example a NextAuth adapter).
3. **Placeholders that explain themselves.** When a provider shows part of a rejected key, the placeholder text itself will say to run the command with `kd`.
4. **Go and Rust under `kd`.** An optional, system-wide keydillo certificate so programs that only trust the macOS Keychain work under `kd`. It needs one admin prompt and only covers sites your keys are for.
5. **Background programs under `kd`.** Programs that detach right away (pm2, tmux) will keep working after `kd` exits.
6. **Keys in shell profiles.** Find keys exported in `~/.zshrc`, `~/.zprofile`, `~/.bashrc` and similar, offer them in the import window, and swap only the value for a placeholder, with a backup and "Put my real keys back" support.
7. **Touch ID for risky API calls.** keydillo's proxy already sees every request a key is used for, so it could ask for Touch ID on calls that spend money or can't be undone, such as Stripe charges and refunds, deletes, or permission changes, and let reads through without a prompt. Per key, with sensible defaults for common providers.

Ideas or requests: open an issue.
