# Where `kd` can fail, and how to fix it

Written 2026-11-17 against main at 0855999, for the kd-only design: Claude puts `kd` in front of commands itself, and the post-command check is the safety net.

**Repro folders:** each case in `~/Desktop/keydillo-breakers/<folder>/run.sh`.

**How it was tested:** a CLI and test proxy built from 0855999 (scratch build, test hooks on), a mock provider, and Touch ID scripted to approve. Dummy keys only. Real providers were only called with placeholder strings, which return free 401s.

**Reproduced vs inferred:** "Reproduced" means I ran it and saw the failure. "Inferred" means from the code or the documented behaviour, but not run.

**Hours** are Claude build hours, rough.

## Summary

The original 18 breaks are mostly fixed:

- **Fixed:** streaming, Basic auth, aiohttp, `undici.request`, websockets, Docker through `host.docker.internal`, and all the import breaks. Locally used secrets are left alone, `${VAR}` lines are skipped, and placeholders keep key prefixes.
- **Now a clear error:** keys in the query, path or body get a `placeholder_misplaced` 400 that says what to do.

What's left falls into three groups:

1. **The safety net doesn't fire.** When a program skips keydillo, none of the seven real providers I tried echo the placeholder back. So the post-command check stays silent, and Claude sees a plain "invalid API key". This matters most now that everything depends on Claude remembering `kd`.
2. **`kd` breaks things that worked without it.** Plain `http://` gets an empty 405. Daemons lose their network. A keyed request that reuses a connection after an unkeyed one leaks the placeholder. The per-run certificate expires after 2 days.
3. **Documented gaps fail without saying why.** Go, Rust, gRPC and `python -I` show certificate errors that never mention keydillo. Next.js edge middleware, clean-env workers and IDE run buttons show the provider's 401.

## Ranked list

| # | Where it fails | Priority | Status | Error clear? | Fix | Hours |
|---|---|---|---|---|---|---|
| 1 | Safety net silent on real 401s | P0 | Reproduced (`kd-post-check`) | No | Detect 401s by provider wording when the project has placeholders | 2 |
| 2 | Plain `http://` returns an empty 405 | P0 | Reproduced (`routed-plain-http`) | No | Forward plain HTTP; add `0.0.0.0` to `NO_PROXY` | 1.5 |
| 3 | Keyed request after an unkeyed one on the same connection | P0 | Reproduced (`kd-keepalive`) | No (provider 401) | Inspect every request, or close after unkeyed ones | 2 |
| 4 | Daemons and detached processes | P1 | Reproduced (`routed-daemon`) | No | Keep the CA bundle; proxy token instead of process-tree check | 3 |
| 5 | TLS clients that don't trust kd's CA (Go, Rust, gRPC, `python -I`, pinning) | P1 | Reproduced for Go, gRPC, `python -I`; inferred for Rust and pinning | No | Detect failed handshakes and print the base URL | 1.5 |
| 6 | Programs that bypass the proxy (edge middleware, clean-env workers, Docker `--env-file`) | P1 | Reproduced | No (provider 401) | Exit summary when no placeholder ever came through | 1.5 |
| 7 | Not started with `kd` (IDE run buttons, cron/launchd, Claude forgets) | P1 | Inferred | No | Same fix as 1 and 6, plus docs | 1 |
| 8 | keydillo app quits during a `kd` run | P2 | Reproduced (session proxy, same code) | No (empty reply) | JSON 503 with a hint, and reopen the app | 1 |
| 9 | `kd` running for more than 2 days | P2 | Inferred (CA dated +48 h) | No | Per-run CA valid for the life of the run | 0.5 |
| 10 | Signed requests (AWS, R2, Cloudinary) | P2 | Reproduced (`signed-requests`) | Yes (kept in `.env`, README) | Optional SigV4 re-signing later | 4 |
| 11 | Key format checks (Clerk) | P3 | Reproduced (`import-format-validation`) | Partly (README) | Prefix placeholders for unknown services | 0.5 |
| 12 | Proxy only set in macOS system settings (PAC, corporate) | P3 | Inferred | No | Read system proxy settings for passthrough traffic | 1.5 |
| 13 | `kd` with an alias, shell function or builtin | P3 | Reproduced | Partly ("env: source: No such file") | Say it isn't a program | 0.3 |
| 14 | Post check fires on text that merely mentions a 401 | P3 | Reproduced | n/a (noise) | Only check the output of commands that call the network | 0.5 |

## Details

### 1. The safety net is silent on real provider 401s (P0)
**What the user sees.** OpenAI, Anthropic, ElevenLabs, Gemini, Stripe, Resend and Groq all reject a placeholder without echoing it back. OpenAI and Stripe mask it (`sk-proj-****-run`); the others say "invalid x-api-key" or "API key not valid". The post check requires the literal text `keydillo:`, so it said nothing in 7 out of 7 cases. When Claude forgets `kd`, it sees an ordinary invalid-key error and may ask for the key or go looking for it.

**Fix.**
1. Fire the post check on known provider auth-error wording, or any 401 or 403, when the command wasn't prefixed with `kd` and the working folder's `.env` contains placeholders.
2. Better still, before the command runs: if the project has placeholders and the command runs a program (npm, python, node, bun, curl…) without `kd`, tell Claude to add it. This is cheap and avoids the failed call altogether.

**Hours:** 2.

### 2. Plain `http://` calls get an empty 405 (P0)
**What the user sees.** Under `kd`, any `http://` request to a host other than `localhost` or `127.0.0.1` gets `405 Method Not Allowed` with an empty body. That includes `http://example.com`, `http://0.0.0.0:8000` as printed by uvicorn and Flask, `http://host.docker.internal`, LAN devices, `.local` names, and http→https redirects. This works without keydillo, so `kd` breaks the app.

**Why.** The proxy only handles CONNECT. `HTTP_PROXY` is still set, and `NO_PROXY` lacks `0.0.0.0`.

**Fix.** Forward absolute-form HTTP requests untouched. keydillo never needs to see plain HTTP, since keys only go over HTTPS. Add `0.0.0.0` to `NO_PROXY`. At minimum, return a JSON body that explains.

**Hours:** 1.5.

### 3. Placeholder leaks on a reused connection (P0)
**What the user sees.** If a program's first request on a connection to a stored host has no placeholder (a public or status endpoint, or a different key), kd pipes the rest of that connection straight through. A later keyed request on it goes to the provider unswapped and fails with 401. Any SDK that pools connections does this.

Examples: supabase-js using the public anon key and then a service-role call on the same host, or Google APIs serving several keys on one host.

`kd` does print one stderr line ("carried no keydillo placeholder"), but it blames the wrong thing.

**Fix.** Keep parsing each request on intercepted connections instead of piping after the first. Or force `Connection: close` on unkeyed requests to stored hosts.

**Hours:** 2.

### 4. Daemons and detached processes lose their network (P1)
**What the user sees.**
- **Under `kd`:** a process that outlives the command (pm2, tmux, `nohup … &`, turbo or gradle daemons, a dev script that backgrounds its server) keeps `HTTPS_PROXY` and `SSL_CERT_FILE`. kd's proxy exits and its folder is deleted. Every HTTPS call then fails, in Python with "Could not find a suitable TLS CA certificate bundle". That error never mentions keydillo.
- **Under a routed session:** the reparented daemon isn't a descendant any more, so the proxy answers 403 for every site.

**Fix.**
1. Leave `bundle.pem` (public roots plus the public CA certificate) in place after exit; only the CA key needs deleting. Python, curl and Node then fail with a connection error rather than a missing-file error.
2. Instead of the process-tree check, put a random per-run token in the proxy URL (`http://kd:<token>@127.0.0.1:port`). Clients send it as `Proxy-Authorization`.
3. Keep the proxy alive while connections or token-holding processes remain, or until it has been idle for N minutes.
4. Document: for long-running daemons, use the base URL.

**Hours:** 3.

### 5. TLS clients that don't trust kd's certificate (P1, documented)
**What the user sees.** "x509: certificate is not trusted" from Go, `TSI_PROTOCOL_FAILURE` from gRPC, and `CERTIFICATE_VERIFY_FAILED` from `python3 -I`. Rust (reqwest, both TLS backends) and certificate pinning should fail the same way; that part is inferred. None of the messages mention keydillo or the base URL.

**Fix.** kd's TLS listener sees the client abort the handshake. Print one line naming the host and the program: "`<program>` doesn't accept keydillo's certificate (Go, Rust, gRPC or pinned). Call `http://localhost:7787/<name>` instead." gRPC needs HTTP/2, which isn't worth it now.

**Hours:** 1.5.

### 6. Programs that bypass the proxy (P1, documented)
**What the user sees.** The provider's 401, and kd can't see the request at all. Cases:
- Next.js edge middleware (the Node route works);
- workers started with a clean environment;
- Docker with `--env-file`;
- any SDK that ignores `HTTPS_PROXY` and isn't shimmed.

**Fix.** When the command exits non-zero, its environment or the folder's `.env` held placeholders, and no keyed request ever reached kd, print: "No request carried a keydillo placeholder through kd. Part of this program likely skipped keydillo (edge runtime, Docker, a worker with a cleaned environment). Use `<NAME>_BASE_URL`." The hook from item 1 catches the same thing for Claude.

**Hours:** 1.5.

### 7. Not started with `kd` (P1)
**What the user sees.** The provider's 401. This covers IDE run buttons (VS Code launch configs, PyCharm, Xcode schemes), cron and launchd jobs, `npm` scripts started by other tools, and Claude forgetting `kd`. The `.env` header explains `kd`, but nobody reads it when an IDE shows "401".

**Fix.** Mainly items 1 and 6. Also add a short "IDE and background jobs" section to the README: use the base URL, or set the run config's command to `kd …`.

**Hours:** 1.

### 8. keydillo app quits during a `kd` run (P2)
**What the user sees.** Keyed requests get an empty reply (curl: "Empty reply" or exit 52). Other traffic keeps working. `kd` reopens the app only at startup.

**Fix.** On a refused app port, return the JSON 503 the base-URL path already uses ("keydillo isn't answering, retry"), and run `open -g -b` once.

**Hours:** 1.

### 9. `kd` running for more than 2 days (P2)
**What the user sees.** The per-run CA is valid for 48 hours (`-days 2`; checked: notAfter = start + 48 h). After that, keyed calls from a long-running `kd npm run dev` fail with certificate-expired errors. Not run to expiry.

**Fix.** Make the per-run CA valid for as long as the run, such as 1 year. It is already name-constrained, unique per run, and its key is deleted at exit.

**Hours:** 0.5.

### 10. Signed requests (P2, documented)
AWS SigV4 (S3, R2, SES, Bedrock) and Cloudinary signatures never carry the placeholder. Import now leaves these keys in `.env`, and the README says so. A SigV4 re-signing mode is the only real fix. Later, about 4 hours.

### 11. Key format checks (P3, documented)
Placeholders now keep known prefixes, so T3 env and zod schemas pass. Clerk still rejects its key ("The provided Clerk Secret Key is invalid") because Clerk isn't a known service. Fix: keep the original value's prefix for every key, not only known services (0.5 h).

### 12. Proxy set only in macOS system settings (P3, inferred)
kd chains to a proxy in `HTTPS_PROXY`, but passthrough traffic otherwise connects directly. On networks that require a proxy configured only in System Settings (PAC files, some corporate setups), traffic that worked without kd fails. Python `requests` reads system proxy settings itself, so it loses them under kd. Fix: read `CFNetworkCopySystemProxySettings` for passthrough connections (1.5 h). VPNs that route at the network level are unaffected.

### 13. `kd` with an alias, shell function or builtin (P3)
`kd source .env` and `kd <alias>` print "env: source: No such file or directory". Fix: if the command isn't on PATH, say "`kd` runs programs, not shell aliases or builtins" (0.3 h).

### 14. Post check fires on text, not failures (P3)
Seen in this session. `git log`, a `cat` of keydillo's own source, and kd's own stderr warning (which contains "401") made the check tell Claude a provider rejected a placeholder when nothing was called. Fix: require the output to look like an HTTP error response, or only check commands that ran a network program (0.5 h).

## Survived (no action)
- Load: 100 MB download through kd at the same speed as direct (10.3 s vs 9.7 s); a 30 MB keyed upload; 120 requests 60 at a time, all fine.
- Bun, Deno, certifi or truststore contexts, connection pools of keyed-only calls, npm, uv and git under kd.
- Chaining through an existing `HTTPS_PROXY` (compat suite).
- Mac locked: a clear 423 (compat suite).

## Appendix: automatic session routing (being dropped)
Recorded for whoever picks this up again.
- **Breaks in every project.** Routing was on in every Claude Code session, including projects with no keys, so items 2 and 4 hit everything Claude ran.
- **No recovery after the proxy dies.** This session's own proxy died while I was working, cause unknown. From then on every HTTPS command failed with "connection refused", and `SSL_CERT_FILE` pointed at a deleted file, until I unset the variables by hand. The env file is sourced once per session, so nothing can recover from this.
- **Keys added mid-session.** The session proxy takes its list of hosts at session start, so a key added later through `request_secret` isn't intercepted until the next session.
