# keydillo compatibility report

Generated 2026-11-17 11:51 by `tests/compat/run_compat.py`.
Real proxy engine (test build with a scripted approver), mock API on localhost.

## Request and auth types × clients

| Case | curl | python urllib | python requests | python httpx | python aiohttp | node fetch | node undici | node axios |
|---|---|---|---|---|---|---|---|---|
| Auth: custom header (xi-api-key) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Auth: Bearer | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Auth: Basic, key as user (Stripe) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Auth: Basic user:password (Twilio) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Auth: query parameter (?key=) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Auth: two headers (Supabase) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Auth: key in URL path (Telegram, opt-in) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Auth: key in JSON body (OAuth, opt-in) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Auth: key in form body (opt-in) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Auth: key in cookie (opt-in) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Agent-supplied key is replaced | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| All HTTP methods incl. HEAD/OPTIONS | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| JSON with Unicode, byte-exact | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Multipart upload 3 MB | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 20 MB request body | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Chunked (streamed) upload | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 10 MB binary download, byte-exact | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| gzip response | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| SSE streaming arrives live | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 20 s slow request | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Redirect returned, key not forwarded | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Upstream 4xx/5xx passed through | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 401 explained to the agent | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Set-Cookie passed through | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Idempotency-Key forwarded | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| localhost resolves (IPv4/IPv6) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

## Failure modes and safety (curl)

| Case | Result | Detail |
|---|---|---|
| 20 parallel calls share one Touch ID | ✅ |  |
| Denied → clear 403 | ✅ |  |
| Mac locked → clear 423 | ✅ |  |
| Unknown key → hint to request_secret | ✅ |  |
| Path rule blocks | ✅ |  |
| Upstream down → 502 | ✅ |  |
| Placeholder outside its spot refused | ✅ |  |
| Web page (Origin) blocked | ✅ |  |
| DNS rebinding Host blocked | ✅ |  |
| IPv6 [::1] works | ✅ |  |

## Official SDKs

| SDK | Result | Detail |
|---|---|---|
| Node SDK: openai | ✅ |  |
| Node SDK: anthropic | ✅ |  |
| Node SDK: stripe | ✅ |  |
| Node SDK: ws | ✅ |  |
| Python SDK: openai | ✅ |  |
| Python SDK: anthropic | ✅ |  |
| Python SDK: ws | ✅ |  |
