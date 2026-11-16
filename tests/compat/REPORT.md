# keydillo compatibility report

Generated 2026-11-16 14:00 by `tests/compat/run_compat.py`.
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
| Auth: key in URL path (Telegram) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Auth: key in JSON body (OAuth) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Auth: key in form body | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Auth: key in cookie | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
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
| 20 parallel calls share one Touch ID | ❌ | invalid literal for int() with base 10: 'Mon,' |
| Denied → clear 403 | ✅ |  |
| Mac locked → clear 423 | ✅ |  |
| Unknown key → hint to request_secret | ✅ |  |
| Path rule blocks | ✅ |  |
| Upstream down → 502 | ✅ |  |
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

## `keydillo run` (live, postman-echo.com)

| Case | Result | Detail |
|---|---|---|
| keydillo run + curl | ✅ |  |
| keydillo run + python requests | ✅ |  |
| keydillo run + node fetch (Node 22) | ❌ | {"args":{},"headers":{"host":"postman-echo.com","accept-encoding":"gzip, br","user-agent":"node","sec-fetch-mode":"cors","accept-language":"*","x-forwarded-prot |
| keydillo run chains through an existing HTTPS_PROXY | ❌ | 200 CONNECT example.com:443 HTTP/1.1
 |
