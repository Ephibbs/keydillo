# Where `kd` can fail, and how to fix it

Updated 2026-11-17 against main at 5849d2d, for the kd-only design: Claude puts `kd` in front of commands itself. A pre-command check stops programs run without `kd` in keydillo projects, and a post-command check explains real provider auth errors.

**Repro folders:** each case in `~/Desktop/keydillo-breakers/<folder>/run.sh`. The pre-command probe is `kd-precheck/check.sh`.

**How it was tested:**
- A CLI and test proxy built from 5849d2d (scratch build, test hooks on), a mock provider, and Touch ID scripted to approve.
- Import and put-back use keydillo's own `ImportScanner` with the same line logic as the app (`harness/import-sim`).
- Dummy keys only, and never the user's real store.

**Not tested end to end:** anything that needs the signed app and a real Touch ID. That covers the new-host prompt, the Ask once project setting, folder-less key settings, and the Touch ID setting migration. For those I read the code.

**Hours** are Claude build hours, rough.

## Summary

- **Compatibility suite:** 225 of 225 pass. All earlier breakers hold, with no regressions.
- **Last pass's blocker is fixed:** the pre-command check now stops `npm run dev` in `.env.local` (Next.js) and `.dev.vars` (wrangler) projects, and after `cd web &&`.
- **Also fixed:**
  - `kd` answers at once with a clear `keydillo_not_running` 503 when the app is gone, instead of hanging.
  - After Quit, `kd` refuses with "keydillo was quit. Open it to use keys." instead of reopening the app.
  - Go commands get base-URL advice instead of `kd`.

**Should block release** (both cheap):
1. **A launch-time secret that isn't filled in becomes a public, guessable value.** If the program reloads `.env` with override, reads the file itself, is started from a monorepo root, or runs in a clean-environment worker, it gets the placeholder text. A JWT or session secret then equals `keydillo:<name>:start-with-keydillo-run`, so anyone can forge sessions. This is the same silent security downgrade the earlier import fix removed, now back through launch-time keys.
2. **"Put my real keys back" corrupts values that contain `#` or `$`.** It writes them unquoted, so Node `dotenv` reads `DB_PASSWORD="p#ss$word"` back as `p`. Database passwords hit this often, and this is the way out of keydillo.

**Next (P1):**
- Keys with no host make `kd` intercept whole domains guessed from the key's name. One `GITHUB_TOKEN` breaks `git` and Go tools talking to github.com under `kd`.
- The pre-command check still misses wrappers (`bash -c`, `make`, `nohup`, `env X=1`, `kd true && …`).
- Daemons under `kd`.
- Go, Rust and gRPC certificate errors under `kd`.

## Ranked list

| # | Where it fails | Priority | Status | Error clear? | Fix | Hours |
|---|---|---|---|---|---|---|
| 1 | Unfilled launch-time secret falls back to the public placeholder | P0, blocks release | Reproduced (`kd-launch-keys`) | No (silent; sessions forgeable) | Unguessable placeholder for launch-time keys; kd warns | 1 |
| 2 | Put back writes `#` and `$` values unquoted | P0, blocks release | Reproduced (`import-putback-cycle`) | No (wrong password, app fails later) | Re-quote values, keeping the original quote style | 0.5 |
| 3 | Guessed-domain interception breaks git and Go under `kd` | P1 | Reproduced (`kd-host-first-use`) | No ("SSL certificate problem", x509) | Don't intercept guessed domains for clients that ignore kd's CA, or ask for the host up front | 1.5 |
| 4 | Pre-command check misses wrappers and chains | P1 | Reproduced (`kd-precheck`) | No (bare 401) | Unwrap wrappers; require `kd` on each segment | 1.5 |
| 5 | Daemons and detached processes started under `kd` | P1 | Reproduced (`routed-daemon`) | No | Keep the CA bundle; proxy token instead of the process-tree check | 3 |
| 6 | TLS clients that don't trust kd's CA (Go, Rust, gRPC, `python -I`, pinning) under `kd` | P1 | Reproduced for Go, gRPC, `python -I` | No | Print a keydillo line when a client aborts the handshake | 1 |
| 7 | Programs that bypass the proxy (edge middleware, clean-env workers, Docker `--env-file`) | P1 | Reproduced | No (provider 401) | Exit summary when no keyed request ever reached kd | 1.5 |
| 8 | "Real keys are back" fires after the user's own put back | P2 | Reproduced in sim, inferred in the app | Misleading | Stop managing (untrack) keys that were put back | 0.5 |
| 9 | After Quit, Claude can't run anything in a keydillo project | P2 | Inferred from code; the `kd` refusal is reproduced | Partly | Skip the pre-command check, or let `kd` run without keys, while quit | 0.5 |
| 10 | Repair may give a folder-less key another project's value | P2 | Inferred | No | Only repair folder-less keys from a single matching backup, or ask | 0.5 |
| 11 | Not started with `kd` (IDE run buttons, cron, launchd) | P2 | Inferred | No | README section | 0.5 |
| 12 | Signed requests (AWS, R2, Cloudinary) | P2 | Reproduced | Yes (left in `.env`, README) | Optional SigV4 re-signing later | 4 |
| 13 | Touch ID setting migration can drop "every time" | P3 | Inferred | Silent | Delete the old preference only after the new setting is saved | 0.2 |
| 14 | `needs_host` tells you to use `kd` even when you did (unsigned or source builds) | P3 | Reproduced with a scratch build | Misleading | Say the kd binary isn't keydillo's signed one | 0.3 |
| 15 | `kd` running for more than 30 days | P3 | Inferred | No | CA valid for the life of the run | 0.3 |
| 16 | Key format checks for unknown services (Clerk) | P3 | Reproduced | Partly (README) | Keep the original prefix for every key | 0.5 |
| 17 | Proxy set only in macOS system settings (PAC) | P3 | Inferred | No | Read system proxy settings | 1.5 |
| 18 | `kd` with an alias or builtin | P3 | Reproduced | Partly | Say it isn't a program | 0.3 |

## Details

### 1. An unfilled launch-time secret becomes a public value (P0, blocks release)
`kd` puts the real value of a launch-time key into the program's environment, and `.env` loaders normally don't overwrite it. When the value doesn't arrive, the program silently uses the placeholder text as its secret. From `kd-launch-keys/run.sh` (`JWT_SECRET`, approved value `REAL-jwt-secret-123`):

| How the app loads `.env` | What the program got |
|---|---|
| dotenv default, `node --env-file`, python-dotenv default, Bun, `deno --env-file` | real value |
| dotenv `override: true` | placeholder |
| python-dotenv `override=True` | placeholder |
| reads the file itself (`dotenv.parse(fs.readFileSync)`) | placeholder |
| `kd` started from the monorepo root, `.env` in `web/` | placeholder, and `kd` prints nothing |
| a worker started with `env -i` | placeholder |

With the placeholder as `JWT_SECRET` or `NEXTAUTH_SECRET`, tokens are signed with a string anyone can guess from the variable name. The app works, so nobody notices.

**Fix.**
1. Give launch-time keys an unguessable placeholder, for example `keydillo:jwt:<32 random characters>`. It still parses as a placeholder, but it can't be forged against.
2. Have `kd` look for launch-time placeholders in env files below the working folder too (monorepos), and print a warning when one wasn't filled.
3. In the import window, say plainly that apps loading `.env` with override get the placeholder.

**Hours:** 1.

### 2. Put back corrupts values with `#` or `$` (P0, blocks release)
Put back writes `NAME=value` with no quotes. Import had stripped the original quotes. From `import-putback-cycle/run.sh`:

| | Before import | After put back |
|---|---|---|
| File | `DB_PASSWORD="FAKEp#ss$word2026!"` | `DB_PASSWORD=FAKEp#ss$word2026!` |
| Node `dotenv` reads | `FAKEp#ss$word2026!` | `FAKEp` (the rest is treated as a comment) |
| Node `dotenv` reads, `SESSION_SECRET` | `FAKE$ecret#with$dollars99` | `FAKE$ecret` |

python-dotenv happens to read both correctly. Tools that expand `$VAR`, such as dotenv-expand, Next.js and Docker Compose, would also corrupt `$word`. Inline comments on the line are dropped.

**Fix.** When writing a value back, quote it the way the original line did. When the original quoting isn't known, single-quote any value containing `#`, `$`, spaces or quotes.

**Hours:** 0.5.

### 3. Host on first use intercepts whole domains (P1)
A key with no host gets "host tokens" from its name. `kd` then terminates TLS for `<token>.com/.ai/.io/.xyz/.co/.dev/.app/.net/.org/.cloud/.sh/.so`, `<token>cloud.*`, and every subdomain of these. With a hostless `GITHUB_TOKEN` (`kd-host-first-use`):

| Call under `kd` | Result |
|---|---|
| `git ls-remote https://github.com/...` | **fails**: "SSL certificate problem: unable to get local issuer certificate". Apple's git uses `/etc/ssl/cert.pem` and ignores kd's CA. |
| Go client to `api.github.com` (`gh`, terraform…) | **fails**: x509 not trusted |
| curl, Python, Node | work |

Other likely names: `SLACK_BOT_TOKEN`, `HUGGINGFACE_TOKEN` (`git lfs` to huggingface.co), `CLOUDFLARE_API_TOKEN` (terraform), `SENTRY_AUTH_TOKEN` (sentry-cli during `kd npm run build`). These tools worked before the key was imported.

**Fix.** Either of:
- Intercept guessed domains only for programs known to trust kd's CA (node, python, ruby, bun, deno, curl), and tunnel everything else.
- Ask for the host at import, with a suggested domain, so guessing isn't needed.

Either way, when a handshake to an intercepted host fails, print one keydillo line.

**Hours:** 1.5.

**Also noted, for the security review:** an approval prompt for a lookalike domain (for example `togethercloud.sh`) names the host, but users may approve it by habit.

### 4. Pre-command check misses wrappers and chains (P1, unchanged)
Still allowed:
- `bash -c 'python app.py'`, `sh ./run.sh`, `make dev`
- `env DEBUG=1 node server.js`, `nohup node server.js &`, `timeout 30 python app.py`
- `npm --prefix web run dev`
- `kd true && python app.py` (one `kd` excuses the whole line)
- `docker compose up` (needs base-URL advice)

**Fix.** Strip `env VAR=`, `nohup`, `timeout N`, `time` and `exec`. Treat `make`, `just`, `bash -c` and `sh <script>` as runners. Require `kd` on each segment that runs a program.

**Hours:** 1.5.

### 5. Daemons and detached processes under `kd` (P1, unchanged)
pm2, tmux, `nohup … &` and similar keep `HTTPS_PROXY` and `SSL_CERT_FILE` after `kd` exits and deletes its folder. Every HTTPS call then fails with "Could not find a suitable TLS CA certificate bundle … keydillo-run-…".

**Fix.** Leave `bundle.pem` after exit; use a proxy token instead of the process-tree check; keep the proxy alive while in use; document the base URL for daemons.

**Hours:** 3.

### 6. TLS clients that don't trust kd's certificate (P1, documented)
Go ("x509: certificate is not trusted"), gRPC (`TSI_PROTOCOL_FAILURE`) and `python3 -I` (`CERTIFICATE_VERIFY_FAILED`) fail under `kd` with nothing about keydillo. Rust and pinned clients are inferred to fail the same way. The pre-command check now gives Go base-URL advice, which helps Claude. A person running `kd go run .` still gets the bare x509 error.

**Fix.** Print one keydillo line when a client aborts the handshake.

**Hours:** 1.

### 7. Programs that bypass the proxy (P1, documented)
Next.js edge middleware, clean-env workers and Docker `--env-file` show the provider's 401 under `kd`.

**Fix.** When the command exits non-zero, its env files held placeholders, and no keyed request reached `kd`, print one line pointing at `<NAME>_BASE_URL`.

**Hours:** 1.5.

### 8. "Real keys are back" after the user's own put back (P2)
Put back writes the real values into the tracked files but leaves the keys stored and the files tracked. The detector, which re-checks every 60 s, then lists every key the user just put back (cycle sim: all 5). The user is warned about what they deliberately did.

**Fix.** When putting back, stop treating those env vars as managed in that folder, or untrack the file.

**Hours:** 0.5.

### 9. After Quit, Claude is stuck in keydillo projects (P2)
After Quit, `kd` refuses with a clear message ("keydillo was quit. Open it to use keys."). But the pre-command check runs before it looks at the app, so Claude is still told to put `kd` in front of every `python`, `npm test` or `npm run dev`. `kd` then refuses, so Claude can't run the project's tests or dev server at all until keydillo is reopened, including commands that use no keys.

**Fix.** Skip the pre-command check while the quit marker exists. Or let `kd` run the command without keys and print one warning line.

**Hours:** 0.5.

### 10. Repair can give a folder-less key another project's value (P2, inferred)
The one-time repair takes the newest backup line with the key's env var name. For a key with no folder, that can come from any project's backup, and many projects share names like `OPENAI_API_KEY`. The key would quietly hold a different project's key.

**Fix.** For folder-less keys, repair only when exactly one backup matches; otherwise list the key as "couldn't repair".

**Hours:** 0.5.

### 11. Not started with `kd` (P2)
IDE run buttons, cron and launchd jobs. The post check only covers Claude's commands.

**Fix.** README section: set the run config to `kd …`, or use the base URL.

**Hours:** 0.5.

### 12. Signed requests (P2, documented, no change)
Import leaves AWS and Cloudinary signing keys in `.env`. SigV4 re-signing later, about 4 hours.

### 13. Touch ID setting migration (P3, inferred)
`loadAccessSettings` deletes the old `defaultApproval` preference before saving the new setting, and the save is `try?`. If the Keychain write fails on that launch, a user who chose "every time" silently ends up on the default.

**Fix.** Remove the old preference only after the save succeeds.

**Hours:** 0.2.

### 14. `needs_host` hint with an unsigned `kd` (P3)
With my unsigned scratch build, a request with a placeholder to a new host got `needs_host` with the hint "Run the program with `kd` in front", although it was run with `kd`. The app correctly ignores the target-host header from unsigned binaries. This only matters for source builds.

**Fix.** Say "this kd isn't keydillo's signed build".

**Hours:** 0.3.

### 15–18. Unchanged (P3)
- **CA lifetime:** 30 days; make it last the whole run (0.3 h).
- **Clerk:** still rejects the unprefixed placeholder; keep the prefix for every key (0.5 h).
- **PAC or system-only proxies:** not used for passthrough traffic (1.5 h).
- **Aliases:** `kd source .env` prints "env: source: No such file or directory" (0.3 h).

## Fixed and verified this pass
- **Pre-command check:** stops `npm run dev` in `.env.local` and `.dev.vars` projects and after `cd web &&`. The post check explains masked provider errors there too.
- **App quits during `kd`:** keyed calls get an immediate 503 `keydillo_not_running` with a hint, instead of hanging.
- **Quit:** `kd` refuses with a clear message instead of reopening the app.
- **Import:** locally used secrets, `${VAR}` lines and prefixed placeholders hold. `sk_test_keydillo:…` values are never re-imported as keys.
- **Earlier breakers:** all still pass: plain `http://`, reused connections, streaming, websockets, Basic auth, aiohttp, undici, Bun, Deno, burst load. Misplaced keys still get a clear error.
- **Compatibility suite:** 225 of 225.

## Appendix: automatic session routing (parked on `claude-session-routing`)
If it comes back:
- **Breaks in every project.** It was on in every project, so plain-HTTP and daemon problems hit everything Claude ran.
- **No recovery after the proxy dies.** A dead session proxy left every HTTPS command failing for the rest of the session.
- **Keys added mid-session.** Hosts were fixed at session start, so a key added later wasn't intercepted.
