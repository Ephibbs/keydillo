# Where `kd` can fail, and how to fix it

Updated 2026-11-17 against main at 4742f66, for the kd-only design: Claude puts `kd` in front of commands itself. A pre-command check stops programs run without `kd` in keydillo projects, and a post-command check explains real provider auth errors.

**Repro folders:** each case in `~/Desktop/keydillo-breakers/<folder>/run.sh`. The pre-command probe is `kd-precheck/check.sh`.

**How it was tested:** a CLI and test proxy built from 4742f66 (scratch build, test hooks on), a mock provider, and Touch ID scripted to approve. Dummy keys only. Real providers were only called with placeholder strings, which return free 401s.

**Reproduced vs inferred:** "Reproduced" means I ran it and saw the failure. "Inferred" means from the code or the documented behaviour, but not run.

**Hours** are Claude build hours, rough.

## Summary

**Fixed since the last pass, and holding:**
- Plain `http://` works under `kd`.
- No placeholder leak on reused connections.
- The post check now explains masked provider errors (OpenAI, Anthropic, ElevenLabs, Gemini, Stripe, Resend and Groq wording all match).
- The per-run certificate lasts 30 days instead of 2.
- No more false alarms on `git log` or `cat`.
- No regressions in the earlier cases: streaming, Basic auth, aiohttp, undici, websockets, Bun, Deno, burst load, Docker through `host.docker.internal`, and import.

**Should block release:**
- **Item 1.** The pre-command check only recognises a project by a file named exactly `.env`. Next.js keeps keys in `.env.local` and wrangler in `.dev.vars`, and import rewrites both. In those projects, and after `cd web &&`, Claude's `npm run dev` is neither stopped nor explained afterwards. The app gets a placeholder and the user sees a bare 401: the "unclear failure" this design was meant to remove.

**Next:** daemons under `kd`, a hang when the app quits mid-run, and certificate errors from Go, Rust and gRPC that never mention keydillo.

## Ranked list

| # | Where it fails | Priority | Status | Error clear? | Fix | Hours |
|---|---|---|---|---|---|---|
| 1 | Pre-command check misses `.env.local`, `.dev.vars` and `cd sub &&` | P0, blocks release | Reproduced (`kd-precheck`) | No (bare 401; post check also silent) | Look for the keydillo header in every env file the importer rewrites, and follow `cd` | 0.5 |
| 2 | Pre-command check misses wrappers and chains | P1 | Reproduced (`kd-precheck`) | No (bare 401) | Unwrap common wrappers; require `kd` on every segment that runs a program | 1.5 |
| 3 | Daemons and detached processes started under `kd` | P1 | Reproduced (`routed-daemon`) | No | Keep the CA bundle; proxy token instead of the process-tree check | 3 |
| 4 | keydillo app quits during a `kd` run: keyed calls hang | P1 | Reproduced (`kd-app-quits`) | No (timeout, or a hang with no timeout) | JSON 503 with a hint at once, and reopen the app | 1 |
| 5 | TLS clients that don't trust kd's CA (Go, Rust, gRPC, `python -I`, pinning) | P1 | Reproduced for Go, gRPC, `python -I`; inferred for Rust and pinning | No | Detect failed handshakes and print the base URL; don't push Go to `kd` | 1.5 |
| 6 | Programs that bypass the proxy (edge middleware, clean-env workers, Docker `--env-file`) | P1 | Reproduced | No (provider 401) | Exit summary when no keyed request ever reached kd | 1.5 |
| 7 | Not started with `kd` (IDE run buttons, cron/launchd) | P2 | Inferred | No | Docs section; the exit summary from item 6 doesn't cover these | 0.5 |
| 8 | Signed requests (AWS, R2, Cloudinary) | P2 | Reproduced (`signed-requests`) | Yes (kept in `.env`, README) | Optional SigV4 re-signing later | 4 |
| 9 | `kd` running for more than 30 days | P3 | Inferred (CA dated +30 days) | No | Per-run CA valid for the life of the run | 0.3 |
| 10 | Key format checks (Clerk) | P3 | Reproduced (`import-format-validation`) | Partly (README) | Keep the original prefix for unknown services too | 0.5 |
| 11 | Proxy set only in macOS system settings (PAC, corporate) | P3 | Inferred | No | Read system proxy settings for passthrough traffic | 1.5 |
| 12 | `kd` with an alias, shell function or builtin | P3 | Reproduced | Partly ("env: source: No such file") | Say it isn't a program | 0.3 |

## Details

### 1. The pre-command check misses the most common project layouts (P0, blocks release)
**What happens.** `keydilloProject` walks up from the working folder looking only for `.env` with keydillo's header. From `kd-precheck/check.sh`:

| Command (cwd) | Result |
|---|---|
| `npm run dev` in a project whose keys are in `.env.local` (Next.js, Vite) | allowed |
| `npx wrangler dev` with keys in `.dev.vars` | allowed |
| `cd web && npm run dev` from the repo root | allowed |
| `npm --prefix web run dev` | allowed |
| `python app.py`, `npm run dev`, `pnpm dev`, `bun run dev` in a folder with `.env` | stopped (correct) |

The post check uses the same lookup, so it also stays silent for the same commands even when the output says "Incorrect API key".

**Fix.**
1. Accept the header in any file `ImportScanner.isEnvFile` accepts: `.env`, `.env.*` and `.dev.vars`.
2. For `cd X && …`, resolve `X` against the cwd before walking up.
3. For `--prefix X` and `-C X`, do the same.

**Hours:** 0.5.

### 2. Wrappers and chains slip past the pre-command check (P1)
**Allowed today, should be stopped:**
- `bash -c 'python app.py'`, `sh ./run.sh`, `make dev`
- `env DEBUG=1 node server.js`, `nohup node server.js &`, `timeout 30 python app.py`
- `docker compose up` (needs the base-URL hint, not `kd`)
- `kd true && python app.py` (one `kd` anywhere counts for the whole line)

**Fix.**
1. Strip `env VAR=…`, `nohup`, `timeout N`, `time` and `exec` before deciding.
2. Treat `make`, `just`, `bash -c` and `sh <script>` as runners.
3. Require `kd` on each segment that runs a program, not just one.
4. For `docker compose` and `docker run`, return the `host.docker.internal` base-URL advice instead.

**Hours:** 1.5.

### 3. Daemons and detached processes lose their network (P1, unchanged)
A process that outlives the `kd` command keeps `HTTPS_PROXY` and `SSL_CERT_FILE` after kd's proxy exits and its folder is deleted. Examples: pm2, tmux, `nohup … &`, turbo or gradle daemons, a script that backgrounds its server. Every HTTPS call then fails; in Python with "Could not find a suitable TLS CA certificate bundle … keydillo-run-…/bundle.pem". Only the path hints at keydillo.

**Fix.**
1. Leave `bundle.pem` (public roots plus the public CA certificate) in place after exit; only the CA key needs deleting.
2. Put a random per-run token in the proxy URL, and keep the proxy alive while token-holding clients remain, or until idle for N minutes.
3. Document: for long-running daemons, use the base URL.

**Hours:** 3.

### 4. keydillo app quits during a `kd` run (P1, worse than before)
Keyed requests now hang instead of getting an empty reply. `requests` with a 10 s timeout raised `ReadTimeout`. Programs without a timeout wait until their SDK's own limit, which is 10 minutes for the OpenAI SDK. Other traffic keeps working, and `kd` reopens the app only at startup.

**Fix.** On a refused or closed app port, answer at once with the JSON 503 the base-URL path already uses ("keydillo isn't answering, retry"), and run `open -g -b` once.

**Hours:** 1.

### 5. TLS clients that don't trust kd's certificate (P1, documented)
The errors:
- Go: "x509: certificate is not trusted"
- gRPC: `TSI_PROTOCOL_FAILURE`
- `python3 -I`: `CERTIFICATE_VERIFY_FAILED`

Rust (reqwest) and pinned clients should fail the same way; that part is inferred. kd prints nothing about keydillo. The pre-command check also now tells Claude to run `kd go run .`, which then fails this way.

**Fix.** kd's TLS listener sees the client abort the handshake. Print: "`<program>` doesn't accept keydillo's certificate (Go, Rust, gRPC or pinned). Call `http://localhost:7787/<name>` instead." In the pre-command check, give Go and Cargo commands the base-URL advice instead of `kd`.

**Hours:** 1.5.

### 6. Programs that bypass the proxy (P1, documented)
The provider's 401, and kd can't see the request at all. Cases:
- Next.js edge middleware (the Node route works);
- workers started with a clean environment;
- Docker with `--env-file`.

**Fix.** When the command exits non-zero, the folder's env files held placeholders, and no keyed request reached kd, print one line pointing at `<NAME>_BASE_URL`.

**Hours:** 1.5.

### 7. Not started with `kd` (P2)
IDE run buttons, cron and launchd jobs. The post check only covers Claude's commands.

**Fix.** Add an "IDE and background jobs" section to the README: set the run config to `kd …`, or use the base URL.

**Hours:** 0.5.

### 8. Signed requests (P2, documented, no change)
AWS SigV4 and Cloudinary signatures never carry the placeholder. Import leaves these keys in `.env`, and the README says so. SigV4 re-signing later, about 4 hours.

### 9. `kd` running for more than 30 days (P3)
The per-run CA is now valid for 30 days (checked: notAfter = start + 30 days). A dev server left under `kd` for longer would get certificate-expired errors on keyed calls.

**Fix.** Make it valid for the life of the run.

**Hours:** 0.3.

### 10. Key format checks (P3, documented)
T3 env and zod schemas pass. Clerk still rejects its key ("The provided Clerk Secret Key is invalid") because Clerk isn't a known service.

**Fix.** Keep the original value's prefix for every key.

**Hours:** 0.5.

### 11. Proxy set only in macOS system settings (P3, inferred, no change)
Passthrough traffic connects directly, so networks that require a PAC or system-only proxy lose access under `kd`.

**Fix.** Read `CFNetworkCopySystemProxySettings`.

**Hours:** 1.5.

### 12. `kd` with an alias, shell function or builtin (P3, no change)
`kd source .env` prints "env: source: No such file or directory".

**Fix.** Say "`kd` runs programs, not shell aliases or builtins".

**Hours:** 0.3.

## Fixed and verified this pass
- **Plain `http://` under `kd`:** `http://example.com` and `http://0.0.0.0:<port>` return 200 (`routed-plain-http`).
- **Reused connections:** a keyed call after an unkeyed one on the same connection is now swapped (`kd-keepalive`).
- **Post check:** it now matches masked provider errors when the command ran without `kd` in a detected project, and no longer fires on `git log` or `cat` output.
- **Certificate lifetime:** the per-run CA lasts 30 days instead of 2.
- **Import:** locally used secrets, `${VAR}` lines and key prefixes all still hold (`import-*`).

## Survived (no action)
- Load: 100 MB download at direct speed, a 30 MB keyed upload, 120 requests 60 at a time.
- Bun, Deno, certifi or truststore contexts, connection pools, npm, uv and git under `kd`.
- Chaining through an existing `HTTPS_PROXY`, and a clear 423 when the Mac is locked (compat suite).

## Appendix: automatic session routing (parked on `claude-session-routing`)
If it comes back:
- **Breaks in every project.** It was on in every project, so plain-HTTP and daemon problems hit everything Claude ran.
- **No recovery after the proxy dies.** A dead session proxy left every HTTPS command failing for the rest of the session. This happened to this test session.
- **Keys added mid-session.** Hosts were fixed at session start, so a key added later wasn't intercepted until the next session.
