# keydillo-login (prototype)

Lets Claude Code sign in to websites with your saved logins, and create API keys on provider sites, without the password or key ever reaching Claude.

It is [Playwright MCP](https://github.com/microsoft/playwright-mcp) (Microsoft, Apache-2.0, used unmodified as an npm dependency) wrapped with extra tools and a filter:

- `list_logins`: names, sites and usernames of your saved logins. No passwords.
- `fill_login { login }`: checks the open page is on the login's saved site, asks for Touch ID, fills the username and password (and a 2FA code if you saved a TOTP secret), and submits.
- Each login is locked to the sign-in pages you've approved. The first use on any page, even on the same site, gets a Touch ID prompt that names the page and where its form sends.
- `start_key_capture`, then `save_new_key { name, host? }`: Claude clicks "Create key" on a provider's site, every new value on the page is hidden from it, and `save_new_key` stores the key after Touch ID and returns only `keydillo:<name>`.
- Every result Claude gets back is masked: password values in page snapshots and saved files become `••••••••`. Network and console tools are removed.

Separate from the keydillo app for now. Logins live in your login Keychain under `keydillo-login`, and `bin/kdlogin` releases one only after Touch ID.

## Why Playwright MCP rather than Chrome DevTools MCP

Both are Apache-2.0. Playwright MCP exports `createConnection(config, contextGetter)`, so this server runs it in-process on a browser it owns and fills logins in that same browser. Chrome DevTools MCP has no embedding API, so it would mean running two processes against one Chrome over CDP. Playwright MCP is also older and more widely used.

## Setup (about 2 minutes)

```sh
cd ~/Desktop/keydillo-login
npm install
npm run build          # compiles bin/kdlogin (Touch ID + Keychain helper)
```

Save a login. Run this yourself in Terminal; it only reads passwords from a terminal, never from a pipe:

```sh
bin/kdlogin add github --site https://github.com
```

It asks for the username, the password (hidden) and an optional TOTP secret. For GitHub's 2FA, that's the setup key shown under "unable to scan?" when you add an authenticator app. Skip it and you type the 2FA code in the browser yourself.

Add the server to Claude Code:

```sh
claude mcp add keydillo-login -- node ~/Desktop/keydillo-login/src/server.mjs
```

If you already use Playwright MCP, remove or disable it in that session. Otherwise Claude may drive that unfiltered browser instead.

## Test it with GitHub

1. Start `claude` in any folder and ask: "Log in to my GitHub account and tell me how many repositories I have."
2. A Chrome window opens (its own profile, in `~/Library/Application Support/keydillo-login`). Claude should call `list_logins`, open github.com/login and call `fill_login`.
3. Touch ID asks to "sign in to github.com as <you> in the agent's browser". Approve.
4. The first time, the prompt says it's a NEW sign-in page and names it. After that it doesn't.
5. Things to try:
   - Ask Claude for the password afterwards. It can't see it.
   - Ask it to take a snapshot of the sign-in page after you type something into the password box yourself. The value shows as `••••••••`.
   - Ask it to run JavaScript on github.com. It's refused.
   - Save a login for one site and open another site's sign-in page. `fill_login` refuses.
6. Log out at github.com, or delete `~/Library/Application Support/keydillo-login/chrome-profile` to start fresh.

Other commands: `bin/kdlogin list`, `bin/kdlogin remove github`.

## Test creating an API key

1. In Claude Code: "Sign in to <provider> and create an API key for this project, then save it." Any provider works; OpenAI, Anthropic, GitHub, Stripe and ElevenLabs also have built-in recipes (key page and API host).
2. Claude should call `start_key_capture`, click Create, see the key as `[key hidden …abcd]`, and call `save_new_key`. Touch ID asks to "save a new API key as "<name>" for <host>".
3. Check it: `bin/kdlogin keys` lists names and hosts. The value is in Keychain Access under `keydillo-login.keys`.
4. Prototype limit: the key is stored here, not in the keydillo app yet, so `kd` won't resolve `keydillo:<name>` until the two are joined.

### How key pages are spotted

1. Claude calls `start_key_capture` before clicking Create (the tool description tells it to).
2. Automatically: the URL, title, headings, buttons or links mention API keys, tokens, secrets or credentials; the site is a known provider; or Claude clicks a button whose text or description is like "Create key" / "Generate token" / "Reveal secret".
3. Backstop: after saving, keydillo checks everything it sent Claude this session for any 12-character piece of the key. If it finds one, it warns that the key was visible and should be rotated, with the provider's key page.

On a key page, everything already there is the baseline. Anything new that isn't an ordinary word (12+ characters with a digit, or 24+ without spaces) is hidden, in text, input values, attributes and iframes, including keys split across several elements. Known key formats (`sk-`, `sk-ant-`, `ghp_`, `github_pat_`, `sk_live_`, `AKIA` and others) are hidden on every page. Screenshots and JavaScript are off on key pages until the key is saved or Claude leaves the page.

## Security status

| Item | Status |
|---|---|
| Lock each login to its sign-in page and form endpoint, saved on first use; a new page needs Touch ID that names it | Done, tested with a same-site fake form |
| Ask again for each new page in multi-step sign-ins (username page, password page, 2FA page) | Done, tested |
| Network-layer lock: any request carrying the password, in URL or body, is aborted unless it goes to an approved endpoint | Done, tested with a form retargeted by page script and a `fetch` copy. WebSockets aren't covered |
| Ban network and console tools (`browser_network_requests`, `browser_network_request`, `browser_console_messages`); console log files deleted | Done, tested |
| No traces, HAR, video or saved sessions (`capabilities: ['core']`, `saveSession: false`) | Done by config. Not separately tested |
| Pages can't register their own tools (`webmcp: false`) | Done by config |
| Block Chrome extensions: `--disable-extensions`, `chrome://`, `chrome-extension://` and Web Store URLs refused | Done, tested for URLs. A tool call that loads an extension some other way isn't specifically checked |
| `browser_run_code_unsafe` removed; `browser_evaluate` refused on password pages and signed-in sites | Done, tested |
| Password values masked in snapshots, tool results and saved files; screenshot refused when a password shows as text | Done, tested |
| Field emptied after a failed sign-in; tool calls run one at a time | Done, tested |
| Node debugger can't be opened with SIGUSR1 (server re-runs itself with `--disable-sigusr1`) | Done. Not separately tested |
| No remote-debugging port: Playwright launches Chrome with `--remote-debugging-pipe` | Playwright's default. Not verified on this machine |
| Chrome's own password saving off in the profile | Set in the profile's Preferences on first launch. Not verified in Chrome's UI |
| Touch ID text comes from saved data (site, username) and the real frame URL, never the page title | Done by design |
| Session cookies and the Chrome profile on disk (`~/Library/Application Support/keydillo-login`), readable by any program you run; Playwright's mock Keychain leaves cookies effectively unencrypted | Open |
| Claude's shell can run `bin/kdlogin get` itself and trigger the same Touch ID prompt | Open: fixed by moving storage into the signed app |
| Claude can edit this plain JavaScript to remove the masking, or point Claude Code's config at another copy | Open: fixed by shipping the tool signed inside the app |
| `browser_evaluate` still works on pages without a password field, on sites not signed in this session | Open, by design for now |
| Masking is by exact value: a password drawn in an image or canvas, or transformed by the page, isn't caught | Open |
| API keys: new values on key pages hidden (no prefix needed), split text, iframes, inputs and attributes; known formats hidden everywhere | Done, tested on a fake provider |
| API keys: clipboard writes, copy/cut shortcuts and downloads blocked | Done, tested (downloads by config) |
| API keys: screenshots refused on key pages until saved; a key drawn on a canvas can't be read or saved | Done, tested |
| API keys: exposure check after save, with a rotate warning | Done, tested |
| API keys: a key shown on a page that doesn't look like a key page, with no known format, before Claude clicks anything that sounds like "create key" | Open: visible to Claude. The exposure check catches it afterwards |
| API keys: over-hiding on key pages (new IDs, dates, long names that appear with the key) | Accepted |
| API keys: saved in this prototype's Keychain store, not the keydillo app, so `kd` can't use them yet | Open |
| Real provider tested | Open: needs your account. Only the fake provider and Claude Code's headless run are tested |
| Captchas, passkeys, SSO pop-ups and Google (which blocks automated browsers) aren't handled | Open |

## Path to product: signed inside keydillo

1. Store logins in keydillo's private Data Protection Keychain group, next to API keys. Only the signed app can read them, which closes the shell-calls-the-helper gap.
2. Ship this MCP server inside the signed app bundle, launched by the app, so Claude can't edit it. The app hands the password to the browser filler over its control socket only for an approved page, the same check as API key hosts.
3. Reuse keydillo's approval UI for "new sign-in page" prompts and list approved pages per login in the app.
4. Keep the Chrome profile in the app's container and decide how sessions are kept: per project, or cleared on quit.

## Development

```sh
npm test                      # 27 end-to-end tests: real server, local test sites, fake helper instead of Touch ID
node tools/claude-check.mjs   # runs `claude -p` against the local site and prints which tools it called
```

`src/server.mjs` wraps Playwright MCP, `src/guard.mjs` does the masking and blocking, `src/fill.mjs` finds and fills the form, and `helper/kdlogin.swift` holds the Keychain and Touch ID code.

MIT. Playwright MCP is Apache-2.0 (see `node_modules/@playwright/mcp/LICENSE`).
